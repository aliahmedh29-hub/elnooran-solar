-- ============================================================
-- المرحلة 3 - الجزء 3: العُهد ورواتب الموظفين
-- شغّلها بعد 07-phase3-collections-bills.sql. الملف idempotent.
-- القرارات (تقدر تغيّرها):
--  • العهدة صرف من حساب، والتسوية رجوع فلوس للحساب. الرصيد المفتوح = المصروف - المسوّى.
--  • الراتب بيتسجل كصرف على الموظف. مفيش حساب تلقائي للراتب من الأساسي (ده قرار لاحق).
--  • الموظف مايقدرش يشوف عهدته أو رواتبه من الخزينة. بيشوفها المدير والحسابات بس.
-- ============================================================

-- ---------- قائمة الموظفين للخزينة (الحسابات مايقدروش يشوفوا جدول الموظفين كامل) ----------
create or replace function public.finance_employee_list()
returns table (id uuid, full_name text)
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.my_role(), '') not in ('gm','accounting') then raise exception 'forbidden'; end if;
  return query select e.id, e.full_name from public.employees e where e.is_active order by e.full_name;
end;
$$;

-- ---------- صرف عهدة ----------
create or replace function public.give_advance(
  p_employee uuid, p_account uuid, p_amount numeric, p_date date, p_note text
) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  return public.post_entry(p_account, 'out', p_amount, 'عهدة', 'employee', p_employee, p_note, p_date, null, null, false, null);
end;
$$;

-- ---------- تسوية عهدة (رجوع فلوس للحساب) ----------
create or replace function public.settle_advance(
  p_employee uuid, p_account uuid, p_amount numeric, p_date date, p_note text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_open numeric;
begin
  if coalesce(public.my_role(), '') not in ('gm','accounting') then raise exception 'forbidden'; end if;
  -- ما نقدرش نسوّي أكتر من المفتوح على الموظف
  select coalesce(sum(case when l.category = 'عهدة' then l.amount
                           when l.category = 'تسوية عهدة' then -l.amount else 0 end), 0)
    into v_open
  from public.ledger l
  where l.party_type = 'employee' and l.party_id = p_employee and l.category in ('عهدة','تسوية عهدة');
  if p_amount > v_open then
    raise exception 'المبلغ أكبر من العهدة المفتوحة (%)', v_open;
  end if;
  return public.post_entry(p_account, 'in', p_amount, 'تسوية عهدة', 'employee', p_employee, p_note, p_date, null, null, false, null);
end;
$$;

-- ---------- صرف راتب ----------
create or replace function public.pay_salary(
  p_employee uuid, p_account uuid, p_amount numeric, p_month date, p_date date, p_note text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_cat text := 'راتب ' || to_char(coalesce(p_month, current_date), 'YYYY-MM');
begin
  return public.post_entry(p_account, 'out', p_amount, v_cat, 'employee', p_employee, p_note, p_date, null, null, false, null);
end;
$$;

-- ---------- العهدة المفتوحة لكل موظف ----------
create or replace view public.employee_custody
with (security_invoker = true) as
select
  l.party_id as employee_id,
  sum(case when l.category = 'عهدة' then l.amount
           when l.category = 'تسوية عهدة' then -l.amount else 0 end) as open_balance
from public.ledger l
where l.party_type = 'employee' and l.category in ('عهدة','تسوية عهدة')
group by l.party_id;

-- ---------- ملاحظات ----------
-- 1) كل الدوال بتستخدم post_entry، يعني فحص الدور والفترة المقفولة والرصيد بيتطبق عليها.
-- 2) الحركات دي بتظهر في دفتر الخزينة وبتتعكس بنفس طريقة باقي القيود.
