-- ============================================================
-- المرحلة 9: التقارير ولوحة التحكم
-- شغّلها بعد 15-phase8-service-ops.sql. الملف idempotent.
-- قرارات اتاخدت من غير رد منك (تقدر تغيّرها):
--  • لوحة التحكم للمدير بس، وبتجمع أرقام من الدالات اللي موجودة من غير ما تفتح بيانات جديدة.
--  • النسخ الاحتياطي بيتعمل من الواجهة (تصدير JSON) للمدير بس، ومعمول بالمتصفح. الجدولة التلقائية لسه ما اتعملتش.
--  • الاستيراد: العملاء بس من CSV، مع التحقق من تكرار الرقم.
-- ============================================================

create or replace function public.dashboard_summary(p_from date, p_to date)
returns table (
  sales_total numeric, invoices_count int, collected_total numeric,
  open_receivables numeric, supplier_owed numeric, cash_total numeric,
  low_stock_count int, open_tickets int, active_projects int, leads_count int
)
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.my_role(), '') <> 'gm' then raise exception 'forbidden'; end if;
  return query select
    coalesce((select sum(d.total) from public.documents d
              where d.doc_type = 'invoice' and d.status = 'issued' and d.doc_date between p_from and p_to), 0),
    coalesce((select count(*)::int from public.documents d
              where d.doc_type = 'invoice' and d.status = 'issued' and d.doc_date between p_from and p_to), 0),
    coalesce((select sum(case when l.direction = 'in' then l.amount else -l.amount end) from public.ledger l
              where l.party_type = 'customer' and l.entry_date between p_from and p_to), 0),
    coalesce((select sum(cb.invoiced - cb.received) from public.customer_balances cb), 0),
    coalesce((select sum(sb.owed) from public.supplier_balances sb), 0),
    coalesce((select sum(public.account_balance(a.id)) from public.accounts a where a.is_active), 0),
    coalesce((select count(*)::int from public.stock_levels s
              where s.reorder_level > 0 and s.on_hand <= s.reorder_level), 0),
    coalesce((select count(*)::int from public.service_tickets t where t.status <> 'closed'), 0),
    coalesce((select count(*)::int from public.projects p where p.stage <> 'handover'), 0),
    coalesce((select count(*)::int from public.customers c where c.stage = 'lead'), 0);
end;
$$;

-- ---------- استيراد العملاء من CSV (بيرجع الصفوف اللي فشلت) ----------
create or replace function public.import_customers(p_rows jsonb)
returns table (inserted int, skipped int, errors jsonb)
language plpgsql security definer set search_path = public as $$
declare
  r jsonb;
  v_ins int := 0;
  v_skip int := 0;
  v_err jsonb := '[]'::jsonb;
  v_phone text;
begin
  if coalesce(public.my_role(), '') not in ('gm','sales') then raise exception 'forbidden'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'البيانات لازم تكون قائمة'; end if;
  if jsonb_array_length(p_rows) > 2000 then raise exception 'الحد الأقصى 2000 صف في المرة'; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_phone := regexp_replace(coalesce(r->>'phone', ''), '[^0-9+]', '', 'g');
    if coalesce(trim(r->>'full_name'), '') = '' or length(v_phone) < 8 then
      v_skip := v_skip + 1;
      v_err := v_err || jsonb_build_object('row', r, 'reason', 'اسم أو رقم غلط');
      continue;
    end if;
    if exists (select 1 from public.customers where phone = v_phone) then
      v_skip := v_skip + 1;
      v_err := v_err || jsonb_build_object('row', r, 'reason', 'الرقم موجود قبل كده');
      continue;
    end if;
    insert into public.customers (full_name, phone, area, system_type, owner_employee_id)
    values (trim(r->>'full_name'), v_phone, nullif(trim(r->>'area'), ''),
            coalesce(nullif(r->>'system_type',''), 'other'), public.my_employee_id());
    v_ins := v_ins + 1;
  end loop;

  return query select v_ins, v_skip, v_err;
end;
$$;

-- ---------- ملاحظة ----------
-- تصدير النسخة الاحتياطية بيتعمل من الواجهة. الجدولة الأوتوماتيكية محتاجة pg_cron أو خدمة خارجية.
