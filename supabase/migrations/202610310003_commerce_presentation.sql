begin;
alter table public.products add column if not exists catalog_details jsonb not null default '{}'::jsonb;
create or replace function public.swift_catalog_details_valid(v jsonb) returns boolean language plpgsql immutable set search_path='' as $$declare x jsonb;k text;begin
 if jsonb_typeof(v)<>'object' or length(v::text)>8000 then return false;end if;
 if exists(select 1 from jsonb_object_keys(v) t where t not in('type','size_system','sizes','colors','specifications')) then return false;end if;
 if v ? 'type' and v->>'type' not in('other','tennis','apparel','technology','pharmacy') then return false;end if;
 if v ? 'size_system' and v->>'size_system' not in('US','EU','MX','Standard') then return false;end if;
 foreach k in array array['sizes','colors'] loop
 if v ? k then if jsonb_typeof(v->k)<>'array' or jsonb_array_length(v->k)>40 then return false;end if;
 for x in select value from jsonb_array_elements(v->k) loop if jsonb_typeof(x)<>'string' or length(btrim(x#>>'{}')) not between 1 and 32 or (x#>>'{}')~'[[:cntrl:]·—]' then return false;end if;end loop;
 if (select count(*)<>count(distinct lower(value#>>'{}')) from jsonb_array_elements(v->k)) then return false;end if;end if;end loop;
 if v ? 'specifications' and (jsonb_typeof(v->'specifications')<>'string' or length(v->>'specifications')>1500) then return false;end if;return true;exception when others then return false;end $$;
alter table public.products add constraint products_catalog_details_valid check(public.swift_catalog_details_valid(catalog_details));
alter table public.merchant_storefronts add column if not exists entrance_enabled boolean not null default false;
alter table public.merchant_storefronts add column if not exists entrance_image text;
create or replace function public.swift_store_entrance_guard() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.entrance_enabled and not exists(select 1 from public.swift_store_registry where category=new.category and business_type in('Apparel','Tech','Pharmacy')) then raise exception 'Store entrance is available for Apparel, Technology and Pharmacy stores only';end if;
 if new.entrance_image is not null and (length(new.entrance_image)>6000000 or new.entrance_image !~ '^(https://|data:image/(png|jpeg|webp);base64,)') then raise exception 'Upload a JPG, PNG or WebP image';end if;
 if new.entrance_enabled and nullif(new.entrance_image,'') is null then raise exception 'Upload an entrance image before enabling it';end if;return new;end $$;
create trigger swift_store_entrance_guard before insert or update on public.merchant_storefronts for each row execute function public.swift_store_entrance_guard();
create or replace function public.swift_store_entrance_index() returns jsonb language sql stable security definer set search_path='' as $$ select coalesce(jsonb_object_agg(r.category,m.entrance_enabled),'{}'::jsonb) from public.swift_store_registry r join public.swift_service_zones z on z.id=r.zone_id join public.merchant_storefronts m using(category) where r.status='live' and z.active and r.business_type in('Apparel','Tech','Pharmacy') $$;
create or replace function public.swift_store_entrance(p_category text) returns jsonb language sql stable security definer set search_path='' as $$select jsonb_build_object('category',r.category,'image',m.entrance_image) from public.swift_store_registry r join public.swift_service_zones z on z.id=r.zone_id join public.merchant_storefronts m using(category) where r.category=p_category and r.status='live' and z.active and r.business_type in('Apparel','Tech','Pharmacy') and m.entrance_enabled $$;
create or replace function public.swift_validate_product_selections() returns trigger language plpgsql security definer set search_path='' as $$declare i jsonb;p public.products;chosen jsonb;meta jsonb;result jsonb:='[]';label text;begin
 if jsonb_typeof(new.snapshot->'items') is distinct from 'array' then return new;end if;
 for i in select value from jsonb_array_elements(new.snapshot->'items') loop
 if nullif(i->>'offer_id','') is not null then result:=result||jsonb_build_array(i);continue;end if;
 select * into p from public.products where category=i->>'category' and name=i->>'name' and (nullif(i->>'product_id','') is null or id::text=i->>'product_id') limit 1;
 if not found then if nullif(i->>'product_id','') is not null then raise exception 'This product changed. Reopen the store';end if;result:=result||jsonb_build_array(i);continue;end if;
 meta:=p.catalog_details;chosen:=coalesce(i->'selected_options','{}'::jsonb);label:=p.name;
 if jsonb_typeof(chosen)<>'object' or exists(select 1 from jsonb_object_keys(chosen)t where t not in('size','size_system','color')) then raise exception 'Choose valid product options';end if;
 if jsonb_array_length(coalesce(meta->'sizes','[]'))>0 then
 if coalesce(chosen->>'size_system','')<>coalesce(meta->>'size_system','Standard') or not (meta->'sizes' ? coalesce(chosen->>'size','')) then raise exception 'Choose an available size for %',p.name;end if;label:=label||' — '||coalesce(meta->>'size_system','Standard')||' '||(chosen->>'size');
 elsif chosen ? 'size' or chosen ? 'size_system' then raise exception 'This item has no size selection';end if;
 if jsonb_array_length(coalesce(meta->'colors','[]'))>0 then if not (meta->'colors' ? coalesce(chosen->>'color','')) then raise exception 'Choose an available color for %',p.name;end if;label:=label||' · '||(chosen->>'color');elsif chosen ? 'color' then raise exception 'This item has no color selection';end if;
 i:=i||jsonb_build_object('display_name',label,'product_id',p.id,'selected_options',chosen);result:=result||jsonb_build_array(i);
 end loop;new.snapshot:=jsonb_set(new.snapshot,'{items}',result);return new;end $$;
create trigger aa_product_selections before insert on public.customer_order_tracking for each row execute function public.swift_validate_product_selections();
revoke all on function public.swift_store_entrance_guard(),public.swift_validate_product_selections() from public,anon,authenticated;
grant execute on function public.swift_store_entrance_index(),public.swift_store_entrance(text) to anon,authenticated;
do $$declare d text;begin select pg_get_functiondef(oid) into strict d from pg_proc where pronamespace='public'::regnamespace and proname='swift_merchant_auto_dispatch';if position('display_name' in d)=0 then d:=replace(d,'(i->>''name'')','coalesce(i->>''display_name'',i->>''name'')');execute d;end if;end $$;
notify pgrst,'reload schema';commit;
