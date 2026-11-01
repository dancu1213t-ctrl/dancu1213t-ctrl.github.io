begin;
create or replace function public.swift_store_set_business_type(p_category text,p_type text) returns text language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not (public.swift_region_admin() or exists(select 1 from public.merchant_members where category=p_category and user_id=auth.uid())) then raise exception 'Store access required';end if;
 if p_type is null or p_type not in('Food','Cafes','Pharmacy','Apparel','Tech','Groceries','Shops') then raise exception 'Choose a store category';end if;
 if not exists(select 1 from public.swift_store_registry where category=p_category) then raise exception 'Store not found';end if;
 if p_type not in('Apparel','Tech','Pharmacy') then update public.merchant_storefronts set entrance_enabled=false where category=p_category and entrance_enabled;end if;
 update public.swift_store_registry set business_type=p_type,updated_at=now() where category=p_category;
 return p_type;
end $$;
revoke all on function public.swift_store_set_business_type(text,text) from public,anon;
grant execute on function public.swift_store_set_business_type(text,text) to authenticated;
update public.swift_store_registry r set business_type=v.kind,updated_at=now() from (values
('Breakfast','Food'),('Lunch','Food'),('Aroma','Food'),('Leo Meatpies','Food'),('Dinner House','Food'),('Dinner','Food'),('Dumpling','Food'),('La Fonda','Food'),('Salsas','Food'),('Burger But','Food'),('TFC','Food'),('Guerrero','Food'),('Neeyas Backyard','Food'),
('Brew','Cafes'),('Urban','Cafes'),('Sarita','Cafes'),('Saritas','Cafes'),('HomeSweetBakes','Cafes'),('Maria','Cafes'),('Shaken','Cafes'),
('Better Life Pharmacy','Pharmacy'),('DeLaFuentePharmacy','Pharmacy'),
('Bree','Apparel'),('Brees','Apparel'),('Doppex','Apparel'),('Faye','Apparel'),('Sister','Apparel'),
('AddToCart','Tech'),('Electronics','Tech')
) v(category,kind) where r.category=v.category;
notify pgrst,'reload schema';
commit;
select category,business_type from public.swift_store_registry where category in('Aroma','AddToCart','Electronics','Faye','Sister');