-- ============================================================
-- المرحلة 3 - الجزء 4: معاينة حساب الراتب
-- شغّلها بعد 08-phase3-custody-salaries.sql. الملف idempotent.
-- افتراضات مؤقتة (اتاخدت من غير رد منك، وتقدر تغيّرها):
--  • العمولة = نسبة العمولة في employee_salaries × المحصّل من العملاء اللي الموظف مسؤول عنهم، في الفترة.
--  • الخصومات والمكافآت يدوية في الفترة دي (مفيش حساب تلقائي ليها دلوقتي).
--  • المعاينة للعرض بس. الصرف الفعلي بيتم بـ pay_salary بمبلغ يدخله المدير.
-- ============================================================

create or replace function public.salary_preview(p_employee uuid, p_from date, p_to date)
returns table (base numeric, commission_rate numeric, collected numeric, commission numeric, net numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  v_base numeric;
  v_rate numeric;
  v_collected numeric;
begin
  if coalesce(public.my_role(), '') not in ('gm','accounting') then raise exception 'forbidden'; end if;

  select s.base_salary, s.commission_rate into v_base, v_rate
  from public.employee_salaries s where s.employee_id = p_employee;
  v_base := coalesce(v_base, 0);
  v_rate := coalesce(v_rate, 0);

  -- المحصّل من العملاء اللي الموظف مسؤول عنهم في الفترة (تحصيلات بس، مش تحويلات ولا رسوم)
  select coalesce(sum(case when l.direction = 'in' then l.amount else -l.amount end), 0)
    into v_collected
  from public.ledger l
  join public.customers c on c.id = l.party_id
  where l.party_type = 'customer'
    and c.owner_employee_id = p_employee
    and l.entry_date between p_from and p_to
    and l.is_fee = false;

  return query select
    v_base,
    v_rate,
    v_collected,
    round(v_collected * v_rate, 2),
    round(v_base + v_collected * v_rate, 2);
end;
$$;

-- ملاحظة: الحسابات دي معاينة. مفيش قيد بيتسجل تلقائياً.
