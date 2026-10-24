begin;
alter table public.orders add column run_kind text not null default 'pickup_dropoff' check(run_kind in('pickup_dropoff','shopping_list','multiple_pickups'));
alter table public.orders add column swift_tip_cents integer not null default 0 check(swift_tip_cents between 0 and 100000);
alter table public.orders add column run_stops jsonb not null default '[]' check(jsonb_typeof(run_stops)='array');
alter table public.orders add column next_stop integer not null default 0 check(next_stop>=0);
alter table public.orders add column dispatch_request_id uuid unique;
create function public.swift_dispatch_route_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare d jsonb;base numeric;
begin
 if tg_op='INSERT' then
  d:=nullif(current_setting('swiftshop.dispatch_v2',true),'')::jsonb;
  if d is not null then
   if public.swift_worker_kind() is distinct from 'admin' then raise exception 'Administrator access required' using errcode='42501';end if;
   new.run_kind:=d->>'kind';new.swift_tip_cents:=(d->>'tip_cents')::integer;new.run_stops:=d->'stops';new.dispatch_request_id:=(d->>'request_id')::uuid;
   base:=case new.run_kind when 'shopping_list' then 5 when 'multiple_pickups' then 6 else 3.5 end;
   new.runner_pay:=base+new.swift_tip_cents/100.0;
  end if;
 elsif tg_op='UPDATE' then
  if (new.run_kind,new.swift_tip_cents,new.run_stops,new.dispatch_request_id) is distinct from (old.run_kind,old.swift_tip_cents,old.run_stops,old.dispatch_request_id) then
   raise exception 'Dispatched route and SwiftShop tip are immutable; cancel and redispatch to correct them';
  end if;
  if new.next_stop is distinct from old.next_stop and current_setting('swiftshop.collect_stop',true) is distinct from old.order_id then raise exception 'Use the pickup confirmation action';end if;
  if new.dispatch_request_id is not null then
   new.runner_pay:=old.runner_pay;
   if new.gps_link is distinct from old.gps_link or new.pickup_location is distinct from old.pickup_location or new.dropoff_location is distinct from old.dropoff_location then raise exception 'This run has an ordered route. Cancel and redispatch to change its locations';end if;
  end if;
  if new.status='Delivered' and old.status is distinct from 'Delivered' and jsonb_array_length(new.run_stops)>0 and new.next_stop<jsonb_array_length(new.run_stops)-1 then raise exception 'Confirm every pickup before completing this run';end if;
 end if;return new;
end $$;
create trigger zzz_dispatch_route_guard before insert or update on public.orders for each row execute function public.swift_dispatch_route_guard();
revoke all on function public.swift_dispatch_route_guard() from public,anon,authenticated;
create function public.swift_dispatch_run(p_request_id uuid,p_customer_name text,p_phone text,p_brief text,p_location text,p_payment_method text,p_kind text,p_tip numeric,p_stops jsonb,p_details jsonb default '{}') returns public.orders language plpgsql security definer set search_path='' as $$
declare r public.orders;base numeric;n integer;stop jsonb;details jsonb;
begin
 if public.swift_worker_kind() is distinct from 'admin' then raise exception 'Administrator access required' using errcode='42501';end if;
 if p_request_id is null then raise exception 'Dispatch request ID required';end if;
 if length(trim(coalesce(p_brief,''))) not between 1 and 15000 or strpos(p_brief,'[SWIFTSHOP_DETAILS]')>0 then raise exception 'Enter a valid run brief';end if;
 perform pg_advisory_xact_lock(hashtext('dispatch:'||p_request_id));
 select * into r from public.orders where dispatch_request_id=p_request_id;
 if found then return r;end if;
 if p_kind is null or p_kind not in('pickup_dropoff','shopping_list','multiple_pickups') or p_tip is null or p_tip<0 or p_tip>1000 or p_tip<>round(p_tip,2) then raise exception 'Invalid run type or SwiftShop tip';end if;
 if jsonb_typeof(p_stops) is distinct from 'array' then raise exception 'Add pickup and drop-off stops';end if;
 n:=jsonb_array_length(p_stops);
 if n<2 or n>8 or (p_kind<>'multiple_pickups' and n<>2) or (p_kind='multiple_pickups' and n<3) then raise exception 'Add the required pickups and one final drop-off';end if;
 for stop in select value from jsonb_array_elements(p_stops) loop
  if jsonb_typeof(stop->'location') is distinct from 'string' or length(trim(stop->>'location')) not between 3 and 500 or length(trim(coalesce(stop->>'label',''))) not between 1 and 150 then raise exception 'Each stop needs a name and address or coordinates';end if;
 end loop;
 base:=case p_kind when 'shopping_list' then 5 when 'multiple_pickups' then 6 else 3.5 end;
 details:=p_details||jsonb_build_object('route_type','delivery','pickup_location',p_stops->0->>'location','dropoff_location',p_location);
 perform set_config('swiftshop.dispatch_v2',jsonb_build_object('kind',p_kind,'tip_cents',round(p_tip*100),'stops',p_stops,'request_id',p_request_id)::text,true);
 r:=public.dispatch_run(p_customer_name,p_phone,p_brief||E'\n[SWIFTSHOP_DETAILS]'||details::text,p_location,base+p_tip,'Standard',p_payment_method);
 perform set_config('swiftshop.dispatch_v2','',true);
 insert into public.run_events(order_reference,actor_id,event_type,detail) values(r.order_id,auth.uid(),'route_configured',jsonb_build_object('kind',p_kind,'customer_delivery_fee',base,'swift_tip',p_tip,'stops',n));
 return r;
end $$;
revoke all on function public.swift_dispatch_run(uuid,text,text,text,text,text,text,numeric,jsonb,jsonb) from public,anon;
grant execute on function public.swift_dispatch_run(uuid,text,text,text,text,text,text,numeric,jsonb,jsonb) to authenticated;
create function public.swift_runner_collect_stop(p_order_id text,p_expected_stop integer) returns public.orders language plpgsql security definer set search_path='' as $$
declare r public.orders;
begin
 if public.swift_worker_kind() is distinct from 'runner' then raise exception 'Approved runner required' using errcode='42501';end if;
 select * into r from public.orders where order_id=p_order_id for update;
 if not found or r.assigned_runner_id is distinct from auth.uid() then raise exception 'This is not your assigned run' using errcode='42501';end if;
 if r.next_stop>p_expected_stop then return r;end if;
 if r.status not in('Claimed','On the Way') or r.next_stop<>p_expected_stop or r.next_stop>=jsonb_array_length(r.run_stops)-1 then raise exception 'Pickup is no longer current';end if;
 perform set_config('swiftshop.collect_stop',r.order_id,true);
 update public.orders set next_stop=next_stop+1,updated_at=now() where order_id=r.order_id returning * into r;
 perform set_config('swiftshop.collect_stop','',true);
 if r.status='Claimed' then r:=public.set_run_status(p_order_id,'On the Way');end if;
 insert into public.run_events(order_reference,actor_id,event_type,detail) values(p_order_id,auth.uid(),'pickup_collected',jsonb_build_object('stop',p_expected_stop));
 return r;
end $$;
revoke all on function public.swift_runner_collect_stop(text,integer) from public,anon;
grant execute on function public.swift_runner_collect_stop(text,integer) to authenticated;
-- SwiftShop tips on cash runs remain payable by SwiftShop, not collected from customers.
do $patch$ declare s text;begin
 foreach s in array array['swift_legacy_get_runner_cashout_summary','swift_legacy_request_runner_cashout'] loop
  execute replace(pg_get_functiondef(('public.'||s||'()')::regprocedure),'then o.runner_pay else 0 end','then o.runner_pay-o.swift_tip_cents/100.0 else 0 end');
 end loop;
end $patch$;
create or replace function public.get_admin_runner_summary() returns table(runner_id uuid,display_name text,active boolean,dispatch_active boolean,completed_runs bigint,online_swiftpay_earned numeric,cashout_requests numeric,payable_total numeric) language plpgsql security definer set search_path='' as $$
begin
 if public.swift_worker_kind() is distinct from 'admin' then raise exception 'Administrator access required' using errcode='42501';end if;
 return query select p.id,p.display_name,p.active,p.dispatch_active,count(o.order_id) filter(where o.status='Delivered'),
 coalesce(sum(case when o.payment_method='Cash' then o.swift_tip_cents/100.0 else o.runner_pay end) filter(where o.status='Delivered'),0),
 coalesce((select sum(c.amount) from public.runner_cashouts c where c.runner_id=p.id),0),
 greatest(0,coalesce(sum(case when o.payment_method='Cash' then o.swift_tip_cents/100.0 else o.runner_pay end) filter(where o.status='Delivered'),0)-coalesce((select sum(c.amount) from public.runner_cashouts c where c.runner_id=p.id),0))
 from public.profiles p left join public.orders o on o.assigned_runner_id=p.id where p.role='runner' group by p.id order by p.dispatch_active desc,p.display_name;
end $$;
notify pgrst,'reload schema';
commit;
