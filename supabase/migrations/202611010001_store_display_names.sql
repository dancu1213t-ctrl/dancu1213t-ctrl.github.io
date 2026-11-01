begin;
alter table public.swift_store_registry add column if not exists display_name text;
create or replace function public.swift_store_set_display_name(p_category text,p_name text) returns text language plpgsql security definer set search_path='' as $$
declare label text:=btrim(p_name);
begin
 if auth.uid() is null or not(public.swift_region_admin() or exists(select 1 from public.merchant_members where category=p_category and user_id=auth.uid())) then raise exception 'Store access required';end if;
 if label is null or char_length(label) not between 1 and 120 or label ~ '[[:cntrl:]]' then raise exception 'Use a store name between 1 and 120 characters';end if;
 update public.swift_store_registry set name=label,display_name=label,updated_at=now() where category=p_category;
 if not found then raise exception 'Store not found';end if;return label;
end $$;
revoke all on function public.swift_store_set_display_name(text,text) from public,anon;
grant execute on function public.swift_store_set_display_name(text,text) to authenticated;
do $patch$ declare f text;def text;changed text;begin
 foreach f in array array['swift_region_catalogue','swift_region_catalogue_fast'] loop
  def:=pg_get_functiondef(('public.'||f||'()')::regprocedure);
  if position('r.display_name' in def)=0 then
   changed:=regexp_replace(def,'''name''[[:space:]]*,[[:space:]]*r.name','''name'',r.name,''display_name'',r.display_name','g');
   if changed=def then raise exception 'Display name catalogue mapping not found: %',f;end if;
   execute changed;
  end if;
 end loop;
end $patch$;
notify pgrst,'reload schema';
commit;