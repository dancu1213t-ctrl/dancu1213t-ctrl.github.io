begin;
set local lock_timeout='10s';
-- Retire merchant charges, retaining the original financial/audit records.
lock table public.swift_merchant_charges in share row exclusive mode;
create or replace function public.swift_merchant_fee_retired_guard() returns trigger
language plpgsql security definer set search_path='' as $$begin return null;end $$;
revoke all on function public.swift_merchant_fee_retired_guard() from public,anon,authenticated;
drop trigger if exists swift_merchant_no_new_fees on public.swift_merchant_charges;
create trigger swift_merchant_no_new_fees before insert on public.swift_merchant_charges for each row execute function public.swift_merchant_fee_retired_guard();
create table if not exists public.swift_merchant_fee_retirements(
 charge_id uuid primary key references public.swift_merchant_charges(id),
 waived_cents bigint not null check(waived_cents>0),
 retired_at timestamptz not null default now(),
 reason text not null default 'All merchant fees retired on 2026-10-24'
);
alter table public.swift_merchant_fee_retirements enable row level security;
revoke all on public.swift_merchant_fee_retirements from public,anon,authenticated;
insert into public.swift_merchant_fee_retirements(charge_id,waived_cents)
select c.id,c.amount_cents-coalesce((select sum(a.amount_cents) from public.swift_merchant_charge_allocations a where a.charge_id=c.id),0)
from public.swift_merchant_charges c
where c.amount_cents>coalesce((select sum(a.amount_cents) from public.swift_merchant_charge_allocations a where a.charge_id=c.id),0)
on conflict(charge_id) do nothing;

create or replace function public.swift_merchant_access(p_category text,p_feature text) returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null
 and p_feature in('inventory','appearance','orders','revenue','campaigns','delivery')
 and (coalesce(public.swift_worker_kind()='admin',false)
 or exists(select 1 from public.merchant_members where user_id=auth.uid() and category=p_category));
$$;
create or replace function public.swift_merchant_plan(p_category text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not public.swift_merchant_access(p_category,'inventory') then raise exception 'Store access required' using errcode='42501';end if;
 return jsonb_build_object('plan','free','name','Full access','weekly_price',0,'order_fee',0,'billing_enabled',false,
 'ads_enabled',true,'revenue',true,'campaigns',true,'delivery',true,'admin',coalesce(public.swift_worker_kind()='admin',false));
end $$;
create or replace function public.swift_merchant_billing_tick() returns void
language plpgsql security definer set search_path='' as $$begin return;end $$;
create or replace function public.swift_merchant_billing_plan_change() returns trigger
language plpgsql security definer set search_path='' as $$begin return new;end $$;
create or replace function public.swift_merchant_billing_quote() returns trigger
language plpgsql security definer set search_path='' as $$begin new.billing_plan:='free';new.billing_order_cents:=0;return new;end $$;
create or replace function public.swift_merchant_billing_complete() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if new.phase='delivered' and old.phase is distinct from 'delivered' then
  update public.swift_merchant_order_parts set completed_at=coalesce(completed_at,now()) where tracking_id=new.id and decision<>'rejected';
 end if;return new;
end $$;
update public.swift_merchant_rates set weekly_cents=0,order_cents=0;
update public.swift_merchant_order_parts p set billing_order_cents=0,billing_plan='free'
from public.customer_order_tracking t where t.id=p.tracking_id and t.phase not in('delivered','cancelled');
-- The job can be recreated from the previous migration; no payment history is deleted.
do $$declare j record;begin
 for j in select jobid from cron.job where jobname='swift-merchant-weekly-billing' loop perform cron.unschedule(j.jobid);end loop;
end $$;

create or replace function public.swift_merchant_billing_report(p_category text,p_from date,p_to date) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; today date:=(now() at time zone 'America/Belize')::date; week date; gross numeric; direct numeric; extra numeric; fees numeric; subs numeric; charges bigint; paid bigint;
begin
 if not public.swift_merchant_access(p_category,'orders') then raise exception 'Store access required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_from>p_to or p_to-p_from>3660 then raise exception 'Choose a valid date range';end if;
 
 week:=date_trunc('week',today::timestamp)::date;
 select coalesce(sum(p.item_total),0) into gross from public.swift_merchant_order_parts p join public.customer_order_tracking t on t.id=p.tracking_id
 where p.category=p_category and t.phase='delivered' and p.decision<>'rejected' and (coalesce(p.completed_at,t.updated_at) at time zone 'America/Belize')::date between p_from and p_to;
 select coalesce(sum(amount) filter(where kind='direct_order'),0),coalesce(sum(amount) filter(where kind='income'),0) into direct,extra
 from public.swift_merchant_entries where category=p_category and not voided and entry_date between p_from and p_to;
 fees:=0;subs:=0;charges:=0;paid:=0;
 result:=jsonb_build_object('gross',gross,'direct',direct,'income',extra,'fees',fees,'subscriptions',subs,'revenue',gross+direct+extra-fees-subs,
 'balance',greatest(charges-paid,0)/100.0,'collected',paid/100.0,'next_billing',null,'billing_enabled',false,
 'charges','[]'::jsonb,'receipts','[]'::jsonb,
 'sales',coalesce((select jsonb_agg(to_jsonb(x) order by x.completed_at desc) from(
 select p.tracking_id,p.items,p.item_total,coalesce(p.completed_at,t.updated_at) completed_at,t.snapshot->>'payment' payment,
 0::numeric fee,p.item_total net
 from public.swift_merchant_order_parts p join public.customer_order_tracking t on t.id=p.tracking_id
 where p.category=p_category and t.phase='delivered' and p.decision<>'rejected' and (coalesce(p.completed_at,t.updated_at) at time zone 'America/Belize')::date between p_from and p_to)x),'[]'),
 'top_items',coalesce((select jsonb_agg(to_jsonb(x)) from(
 select i->>'name' name,sum((i->>'quantity')::numeric) quantity,sum((i->>'quantity')::numeric*(i->>'price')::numeric) sales
 from public.swift_merchant_order_parts p join public.customer_order_tracking t on t.id=p.tracking_id cross join lateral jsonb_array_elements(p.items)i
 where p.category=p_category and t.phase='delivered' and p.decision<>'rejected' and (coalesce(p.completed_at,t.updated_at) at time zone 'America/Belize')::date between p_from and p_to
 group by i->>'name' order by quantity desc,name limit 10)x),'[]'),
 'weeks',coalesce((select jsonb_agg(to_jsonb(x) order by x.week_start) from(
 select date_trunc('week',coalesce(p.completed_at,t.updated_at) at time zone 'America/Belize')::date week_start,count(*) orders,sum(p.item_total) sales
 from public.swift_merchant_order_parts p join public.customer_order_tracking t on t.id=p.tracking_id where p.category=p_category and t.phase='delivered' and p.decision<>'rejected'
 and (coalesce(p.completed_at,t.updated_at) at time zone 'America/Belize')::date>=week-7 group by 1)x),'[]'));
 return result;
end $$;

create or replace function public.swift_merchant_billing_admin(p_category text default null,p_action text default 'report',p_data jsonb default '{}',p_from date default current_date-30,p_to date default current_date) returns jsonb
language plpgsql security definer set search_path='' as $$begin
 if auth.uid() is null or public.swift_worker_kind() is distinct from 'admin' then raise exception 'Administrator access required' using errcode='42501';end if;
 if p_action<>'report' then raise exception 'Merchant billing has been retired; no fees are due';end if;
 return jsonb_build_object('billing_enabled',false,'daily','[]'::jsonb,'weekly','[]'::jsonb,'stores','[]'::jsonb,'collected',0,'balance',0);
end $$;
create or replace function public.swift_merchant_plan_admin(p_category text default null,p_plan text default null) returns jsonb
language plpgsql security definer set search_path='' as $$begin
 if auth.uid() is null or public.swift_worker_kind() is distinct from 'admin' then raise exception 'Administrator access required' using errcode='42501';end if;
 if p_plan is not null then raise exception 'Merchant plans have been retired; every merchant has full access';end if;
 return '[]'::jsonb;
end $$;
create or replace function public.swift_merchant_request(p_category text,p_plan text default null) returns jsonb
language plpgsql security definer set search_path='' as $$begin
 if not public.swift_merchant_access(p_category,'inventory') then raise exception 'Store access required' using errcode='42501';end if;
 if p_plan is not null then raise exception 'Merchant plans have been retired; every merchant has full access';end if;
 return '[]'::jsonb;
end $$;
create or replace function public.swift_merchant_request_ads(p_category text,p_plan text default null,p_ads boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$begin
 return public.swift_merchant_request(p_category,p_plan);
end $$;
create or replace function public.swift_merchant_requests_admin(p_action text default 'list',p_id uuid default null,p_note text default '') returns jsonb
language plpgsql security definer set search_path='' as $$begin
 if auth.uid() is null or public.swift_worker_kind() is distinct from 'admin' then raise exception 'Administrator access required' using errcode='42501';end if;
 if p_action<>'list' then raise exception 'Merchant plans have been retired';end if;
 return jsonb_build_object('plans','[]'::jsonb,'rejections',coalesce((select jsonb_agg(jsonb_build_object('tracking_id',p.tracking_id,'category',p.category,'items',p.items,'item_total',p.item_total,'reason',p.reason,'created_at',p.decision_at)) from public.swift_merchant_order_parts p where p.review_needed),'[]'::jsonb));
end $$;
-- Delivery is a separate customer service. Keep existing configured delivery prices.
create or replace function public.swift_merchant_delivery_fees() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_object_agg(d.category,d.fee),'{}'::jsonb) from public.swift_merchant_delivery d where d.fee is not null;
$$;
create or replace function public.swiftshop_campaign_plan_guard() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if not public.swift_merchant_access(new.category,'campaigns') then raise exception 'Store access required' using errcode='42501';end if;
 if new.ends_at is not null and new.ends_at<=new.starts_at then raise exception 'Campaign end must be after its start';end if;
 return new;
end $$;
revoke all on function public.swiftshop_plan_request(text,text,text),public.swiftshop_plan_admin(text,text,text,uuid) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
