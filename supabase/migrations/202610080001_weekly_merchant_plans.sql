begin;
create table if not exists public.swift_merchant_plans (
 category text primary key,
 plan text not null default 'free' check(plan in ('free','basic','pro','premium')),
 updated_at timestamptz not null default now(),
 updated_by uuid
);
alter table public.swift_merchant_plans enable row level security;
revoke all on public.swift_merchant_plans from anon,authenticated;
create or replace function public.swift_merchant_access(p_category text, p_feature text) returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
 select auth.uid() is not null and (coalesce(public.swift_worker_kind()='admin',false) or
 (exists(select 1 from public.merchant_members where user_id=auth.uid() and category=p_category)
 and case p_feature when 'inventory' then true when 'appearance' then true
 when 'revenue' then coalesce((select plan in ('pro','premium') from public.swift_merchant_plans where category=p_category),false)
 when 'campaigns' then coalesce((select plan='premium' from public.swift_merchant_plans where category=p_category),false) else false end));
$$;
create or replace function public.swift_merchant_plan(p_category text) returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare selected text; begin
 if not public.swift_merchant_access(p_category,'inventory') then raise exception 'Store access required'; end if;
 select plan into selected from public.swift_merchant_plans where category=p_category;
 selected:=coalesce(selected,'free');
 return jsonb_build_object('plan',selected,'weekly_price',case selected when 'basic' then 6.50 when 'pro' then 7.50 when 'premium' then 8.50 else 0 end,'revenue',public.swift_merchant_access(p_category,'revenue'),'campaigns',public.swift_merchant_access(p_category,'campaigns'),'admin',public.swift_worker_kind()='admin');
end $$;
create or replace function public.swift_merchant_plan_admin(p_category text default null,p_plan text default null) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if auth.uid() is null or public.swift_worker_kind() is distinct from 'admin' then raise exception 'Administrator access required'; end if;
 if p_plan is not null then
  if p_plan not in ('free','basic','pro','premium') or not exists(select 1 from public.stores where category=p_category) then raise exception 'Choose a valid store and plan'; end if;
  insert into public.swift_merchant_plans(category,plan,updated_by) values(p_category,p_plan,auth.uid()) on conflict(category) do update set plan=excluded.plan,updated_by=excluded.updated_by,updated_at=now();
 end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('category',s.category,'plan',coalesce(p.plan,'free')) order by s.category),'[]'::jsonb) from (select distinct category from public.stores where category is not null) s left join public.swift_merchant_plans p using(category));
end $$;
-- Seed once: rerunning this migration must not upgrade later free stores.
create table if not exists public.swift_merchant_plan_migrations(name text primary key);
alter table public.swift_merchant_plan_migrations enable row level security;
revoke all on public.swift_merchant_plan_migrations from public,anon,authenticated;
do $$ begin
 if not exists(select 1 from public.swift_merchant_plan_migrations where name='existing-basic-20261008') then
  insert into public.swift_merchant_plans(category,plan) select distinct category,'basic' from public.stores where category is not null on conflict(category) do nothing;
  insert into public.swift_merchant_plan_migrations values('existing-basic-20261008');
 end if;
end $$;
drop policy if exists "Merchant owns campaigns" on public.merchant_campaigns;
create policy "Merchant owns campaigns" on public.merchant_campaigns for all to authenticated using(public.swift_merchant_access(category,'campaigns')) with check(public.swift_merchant_access(category,'campaigns'));
drop policy if exists "Merchant reads own sales" on public.merchant_sales;
create policy "Merchant reads own sales" on public.merchant_sales for select to authenticated using(public.swift_merchant_access(category,'revenue'));
drop policy if exists "Merchant records own sales" on public.merchant_sales;
create policy "Merchant records own sales" on public.merchant_sales for insert to authenticated with check(created_by=auth.uid() and public.swift_merchant_access(category,'revenue'));
drop policy if exists "swift verified merchant" on public.promos;
create policy "swift verified merchant" on public.promos for all to authenticated using(public.swift_merchant_access(category,'campaigns')) with check(public.swift_merchant_access(category,'campaigns'));
create or replace function public.set_merchant_refund(sale_id uuid,refund_amount numeric) returns void
language plpgsql security definer set search_path=public,pg_temp as $$ begin
 if refund_amount is null or refund_amount<0 then raise exception 'Enter a valid refund'; end if;
 update public.merchant_sales s set refund=refund_amount where s.id=sale_id and refund_amount<=s.amount and public.swift_merchant_access(s.category,'revenue');
 if not found then raise exception 'Sale not found, invalid refund, or Pro plan required'; end if;
end $$;
revoke all on function public.swiftshop_plan_request(text,text,text) from public,anon,authenticated;
revoke all on function public.swift_merchant_access(text,text),public.swift_merchant_plan(text),public.swift_merchant_plan_admin(text,text),public.set_merchant_refund(uuid,numeric) from public,anon;
grant execute on function public.swift_merchant_access(text,text),public.swift_merchant_plan(text),public.swift_merchant_plan_admin(text,text),public.set_merchant_refund(uuid,numeric) to authenticated;
notify pgrst,'reload schema';
commit;
create or replace function public.swiftshop_campaign_plan_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not public.swift_merchant_access(new.category,'campaigns') then raise exception 'Premium plan required to manage ads'; end if;
 if new.ends_at is not null and new.ends_at<=new.starts_at then raise exception 'Campaign end must be after its start'; end if;
 return new;
end $$;
notify pgrst,'reload schema';
commit;
