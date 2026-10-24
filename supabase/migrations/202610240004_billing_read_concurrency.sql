begin;
create or replace function public.swift_merchant_order_fees(p_category text,p_action text default 'report',p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare total bigint;pending bigint;cid uuid;amount bigint;ref text;today date:=(now() at time zone 'America/Belize')::date;ws date:=date_trunc('week',now() at time zone 'America/Belize')::date;
begin
 if not public.swift_merchant_access(p_category,'orders') then raise exception 'Store access required' using errcode='42501';end if;
 if p_action='submit' then perform pg_advisory_xact_lock(hashtext('order-fees:'||p_category));end if;
 select coalesce(sum(outstanding_cents),0) into total from public.swift_merchant_order_fee_balances where category=p_category;
 if p_action='submit' then
  cid:=(p_data->>'id')::uuid;amount:=round((p_data->>'amount')::numeric*100);ref:=trim(p_data->>'reference');
  if cid is null or amount is null or amount<=0 or ref is null or length(ref) not between 1 and 100 then raise exception 'Enter a payment amount within your outstanding balance and a reference';end if;
  if exists(select 1 from public.swift_merchant_payment_claims where id=cid) then
   if not exists(select 1 from public.swift_merchant_payment_claims where id=cid and category=p_category and amount_cents=amount and reference=ref) then raise exception 'Payment reference conflict';end if;
  else
   if amount>total then raise exception 'Payment exceeds outstanding balance';end if;
   if exists(select 1 from public.swift_merchant_payment_claims where category=p_category and status='pending') then raise exception 'Your previous payment is awaiting confirmation';end if;
   insert into public.swift_merchant_payment_claims(id,category,amount_cents,reference,created_by) values(cid,p_category,amount,ref,auth.uid());
   insert into public.swift_merchant_audit(category,actor,action,detail) values(p_category,auth.uid(),'payment_submitted',jsonb_build_object('id',cid,'amount_cents',amount));
  end if;
 elsif p_action<>'report' then raise exception 'Invalid action';end if;
 select coalesce(sum(amount_cents),0) into pending from public.swift_merchant_payment_claims where category=p_category and status='pending';
 return jsonb_build_object('balance',total/100.0,'pending',pending/100.0,'week_start',ws,'due_on',ws+6,'is_sunday',extract(isodow from today)=7,'rate',0.50,
 'this_week',coalesce((select sum(amount_cents)/100.0 from public.swift_merchant_order_fee_balances where category=p_category and (incurred_at at time zone 'America/Belize')::date between ws and ws+6),0),
 'weeks',coalesce((select jsonb_agg(to_jsonb(w) order by w.week_start desc) from(select date_trunc('week',incurred_at at time zone 'America/Belize')::date week_start,(date_trunc('week',incurred_at at time zone 'America/Belize')::date+6) due_on,count(*) orders,sum(amount_cents)/100.0 fees,sum(outstanding_cents)/100.0 outstanding from public.swift_merchant_order_fee_balances where category=p_category group by 1,2)w),'[]'),
 'orders',coalesce((select jsonb_agg(jsonb_build_object('id',tracking_id,'date',incurred_at,'fee',amount_cents/100.0,'outstanding',outstanding_cents/100.0) order by incurred_at desc) from public.swift_merchant_order_fee_balances where category=p_category),'[]'),
 'history',coalesce((select jsonb_agg(to_jsonb(h) order by h.created_at desc) from(select id,amount_cents/100.0 amount,reference,status,created_at,reviewed_at,note from public.swift_merchant_payment_claims where category=p_category)h),'[]'));
end $$;
revoke all on function public.swift_merchant_order_fees(text,text,jsonb) from public,anon;
grant execute on function public.swift_merchant_order_fees(text,text,jsonb) to authenticated;
create or replace function public.swift_merchant_billing_admin(p_category text default null,p_action text default 'report',p_data jsonb default '{}',p_from date default current_date-30,p_to date default current_date) returns jsonb language plpgsql security definer set search_path='' as $$
declare claim public.swift_merchant_payment_claims;r record;remaining bigint;take bigint;
begin
 if auth.uid() is null or public.swift_worker_kind() is distinct from 'admin' then raise exception 'Administrator access required' using errcode='42501';end if;
 if p_action in('confirm','reject') then
  select * into claim from public.swift_merchant_payment_claims where id=(p_data->>'id')::uuid;
  if not found then raise exception 'Payment not found';end if;
  perform pg_advisory_xact_lock(hashtext('order-fees:'||claim.category));
  select * into claim from public.swift_merchant_payment_claims where id=claim.id for update;
  if claim.status='pending' then
   if p_action='confirm' then
    select coalesce(sum(outstanding_cents),0) into remaining from public.swift_merchant_order_fee_balances where category=claim.category;
    if claim.amount_cents>remaining then raise exception 'Payment exceeds outstanding fees';end if;
    insert into public.swift_merchant_receipts(id,category,kind,reference,amount_cents,created_by) values(claim.id,claim.category,'payment','claim:'||claim.id,claim.amount_cents,auth.uid());
    remaining:=claim.amount_cents;
    for r in select * from public.swift_merchant_order_fee_balances where category=claim.category and outstanding_cents>0 order by incurred_at,id loop
     take:=least(remaining,r.outstanding_cents);exit when take<=0;
     insert into public.swift_merchant_charge_allocations values(claim.id,r.id,take);remaining:=remaining-take;
    end loop;
   end if;
   update public.swift_merchant_payment_claims set status=case when p_action='confirm' then 'confirmed' else 'rejected' end,reviewed_by=auth.uid(),reviewed_at=now(),note=left(coalesce(p_data->>'note',''),500) where id=claim.id;
   insert into public.swift_merchant_audit(category,actor,action,detail) values(claim.category,auth.uid(),'payment_'||p_action,jsonb_build_object('id',claim.id,'amount_cents',claim.amount_cents));
  elsif claim.status<>(case when p_action='confirm' then 'confirmed' else 'rejected' end) then raise exception 'Payment was already reviewed';end if;
 elsif p_action<>'report' then raise exception 'Invalid action';end if;
 return jsonb_build_object('billing_enabled',true,
 'stores',coalesce((select jsonb_agg(jsonb_build_object('category',s.category,'report',jsonb_build_object(
 'this_week',coalesce((select sum(b.amount_cents)/100.0 from public.swift_merchant_order_fee_balances b where b.category=s.category and b.incurred_at>=date_trunc('week',now() at time zone 'America/Belize') at time zone 'America/Belize'),0),
 'balance',coalesce((select sum(b.outstanding_cents)/100.0 from public.swift_merchant_order_fee_balances b where b.category=s.category),0),
 'pending',coalesce((select sum(c.amount_cents)/100.0 from public.swift_merchant_payment_claims c where c.category=s.category and c.status='pending'),0),
 'due_on',date_trunc('week',now() at time zone 'America/Belize')::date+6)) order by s.category) from(select distinct category from public.stores where p_category is null or category=p_category)s),'[]'),
 'claims',coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at) from public.swift_merchant_payment_claims c where c.status='pending' and (p_category is null or c.category=p_category)),'[]'),
 'daily',coalesce((select jsonb_agg(to_jsonb(x) order by x.day desc) from(select (incurred_at at time zone 'America/Belize')::date as day,count(*) orders,sum(amount_cents)/100.0 revenue from public.swift_merchant_order_fee_balances where (incurred_at at time zone 'America/Belize')::date between p_from and p_to group by 1)x),'[]'),
 'weekly',coalesce((select jsonb_agg(to_jsonb(x) order by x.week_start desc) from(select date_trunc('week',incurred_at at time zone 'America/Belize')::date week_start,count(*) orders,sum(amount_cents)/100.0 revenue from public.swift_merchant_order_fee_balances group by 1)x),'[]'));
end $$;

notify pgrst,'reload schema';commit;
