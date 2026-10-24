begin;
create function public.swift_funded_run_tip(p_source text,p_kind text) returns numeric language sql stable security definer set search_path='' as $$
 select coalesce((select swift_tip_cents/100.0 from public.orders where order_id=p_source and p_kind='runner' and status='Delivered'),0);
$$;
revoke all on function public.swift_funded_run_tip(text,text) from public,anon,authenticated;
do $patch$ declare s text;old_text text;new_text text;begin
 s:=pg_get_functiondef('public.swift_admin_payments()'::regprocedure);
 old_text:='select p.*,coalesce(pr.display_name';new_text:='select p.*,public.swift_funded_run_tip(p.source_id,p.worker_kind) swift_tip,coalesce(pr.display_name';
 if position(old_text in s)=0 then raise exception 'Admin report shape changed';end if;s:=replace(s,old_text,new_text);
 old_text:=$old$case when p.payment_method in ('Online','SwiftPay') and p.customer_paid then greatest(0,p.worker_amount-coalesce(e.paid,0)) else 0 end payout_due$old$;
 new_text:=$new$case when p.payment_method='Cash' then greatest(0,public.swift_funded_run_tip(p.source_id,p.worker_kind)-coalesce(e.paid,0)) when p.payment_method in ('Online','SwiftPay') and p.customer_paid then greatest(0,p.worker_amount-coalesce(e.paid,0)) else 0 end payout_due$new$;
 if position(old_text in s)=0 then raise exception 'Payout report shape changed';end if;s:=replace(s,old_text,new_text);execute s;
 s:=pg_get_functiondef('public.swift_admin_payment_record(uuid,text,numeric,text,uuid)'::regprocedure);
 old_text:=$old$if p.payment_method not in ('Online','SwiftPay') or not p.customer_paid or p.worker_amount is null then raise exception 'Only confirmed Online/SwiftPay payments with a worker amount qualify for a payout'; end if;
    due=p.worker_amount-settled;$old$;
 -- Match whitespace without changing any other payment validation.
 if position(old_text in s)=0 then
  old_text:=$old$if p.payment_method not in ('Online','SwiftPay') or not p.customer_paid or p.worker_amount is null then raise exception 'Only confirmed Online/SwiftPay payments with a worker amount qualify for a payout'; end if; due=p.worker_amount-settled;$old$;
 end if;
 new_text:=$new$if p.payment_method='Cash' then due=public.swift_funded_run_tip(p.source_id,p.worker_kind)-settled;
 else if p.payment_method not in ('Online','SwiftPay') or not p.customer_paid or p.worker_amount is null then raise exception 'Only confirmed Online/SwiftPay payments with a worker amount qualify for a payout'; end if;due=p.worker_amount-settled;end if;$new$;
 -- Function source contains its original newlines; normalize only this small known section.
 if position(old_text in s)=0 then
  s:=regexp_replace(s,'if p.payment_method not in \(''Online'',''SwiftPay''\) or not p.customer_paid or p.worker_amount is null then raise exception ''Only confirmed Online/SwiftPay payments with a worker amount qualify for a payout''; end if;\s*due=p.worker_amount-settled;',new_text);
  if position('due=public.swift_funded_run_tip' in s)=0 then raise exception 'Payout validation shape changed';end if;
 else s:=replace(s,old_text,new_text);end if;
 execute s;
end $patch$;
notify pgrst,'reload schema';
commit;
