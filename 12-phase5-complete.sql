-- ============================================================
-- المرحلة 5 - الجزء التاني: تقييم الأداء، وخصم الإجازة بدون راتب، وتقرير الحضور الشهري
-- شغّلها بعد 11-phase5-hr.sql. الملف idempotent.
-- قرارات اتاخدت من غير رد منك (تقدر تغيّرها):
--  • التقييم من 1 لـ 5 في 4 معايير: الالتزام، الجودة، التعاون، الأداء العام. والتقييم بيتسجل لفترة (شهر أو ربع).
--  • خصم الإجازة بدون راتب = (الأساسي ÷ 30) × عدد أيامها في الشهر. الإجازة المرضية والسنوية مش بتتخصم.
--  • التقييم بيعمله المدير أو الـ HR، والموظف يشوف تقييمه بس.
-- ============================================================

-- ---------- تقييم الأداء ----------
create table if not exists public.performance_reviews (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete restrict,
  period text not null,                         -- مثال: 2026-11 أو 2026-Q4
  commitment int not null check (commitment between 1 and 5),
  quality int not null check (quality between 1 and 5),
  teamwork int not null check (teamwork between 1 and 5),
  overall int not null check (overall between 1 and 5),
  comments text,
  reviewer_id uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (employee_id, period)
);

create or replace function public.submit_review(
  p_employee uuid, p_period text, p_commit int, p_quality int, p_team int, p_overall int, p_comments text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if coalesce(public.my_role(), '') not in ('gm','hr') then raise exception 'forbidden'; end if;
  if coalesce(trim(p_period), '') = '' then raise exception 'الفترة مطلوبة'; end if;
  insert into public.performance_reviews (employee_id, period, commitment, quality, teamwork, overall, comments, reviewer_id)
  values (p_employee, trim(p_period), p_commit, p_quality, p_team, p_overall, nullif(p_comments,''), public.my_employee_id())
  on conflict (employee_id, period) do update
    set commitment = excluded.commitment, quality = excluded.quality, teamwork = excluded.teamwork,
        overall = excluded.overall, comments = excluded.comments, reviewer_id = excluded.reviewer_id, created_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------- خصم الإجازة بدون راتب (لفترة) ----------
create or replace function public.unpaid_leave_days(p_employee uuid, p_from date, p_to date)
returns int language sql stable security definer set search_path = public as $$
  select coalesce(sum(
    (least(l.end_date, p_to) - greatest(l.start_date, p_from) + 1)
  ), 0)::int
  from public.leave_requests l
  where l.employee_id = p_employee
    and l.leave_type = 'unpaid'
    and l.status = 'approved'
    and l.start_date <= p_to and l.end_date >= p_from
$$;

-- ---------- معاينة الراتب بعد الخصم (بدل النسخة القديمة) ----------
drop function if exists public.salary_preview(uuid, date, date);

create or replace function public.salary_preview(p_employee uuid, p_from date, p_to date)
returns table (base numeric, commission_rate numeric, collected numeric, commission numeric,
               unpaid_days int, leave_deduction numeric, net numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  v_base numeric;
  v_rate numeric;
  v_collected numeric;
  v_unpaid int;
  v_deduct numeric;
  v_comm numeric;
begin
  if coalesce(public.my_role(), '') not in ('gm','accounting') then raise exception 'forbidden'; end if;

  select s.base_salary, s.commission_rate into v_base, v_rate
  from public.employee_salaries s where s.employee_id = p_employee;
  v_base := coalesce(v_base, 0);
  v_rate := coalesce(v_rate, 0);

  select coalesce(sum(case when l.direction = 'in' then l.amount else -l.amount end), 0)
    into v_collected
  from public.ledger l
  join public.customers c on c.id = l.party_id
  where l.party_type = 'customer'
    and c.owner_employee_id = p_employee
    and l.entry_date between p_from and p_to
    and l.is_fee = false;

  v_unpaid := public.unpaid_leave_days(p_employee, p_from, p_to);
  v_deduct := round((v_base / 30) * v_unpaid, 2);
  v_comm := round(v_collected * v_rate, 2);

  return query select
    v_base, v_rate, v_collected, v_comm, v_unpaid, v_deduct,
    round(greatest(v_base + v_comm - v_deduct, 0), 2);
end;
$$;

-- ---------- تقرير الحضور الشهري ----------
create or replace function public.attendance_report(p_from date, p_to date)
returns table (employee_id uuid, full_name text, days_present int, missing_checkout int, out_of_range int)
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.my_role(), '') not in ('gm','hr') then raise exception 'forbidden'; end if;
  return query
    select e.id, e.full_name,
      count(a.id)::int,
      count(a.id) filter (where a.check_out is null)::int,
      count(a.id) filter (where a.in_in_range = false or a.out_in_range = false)::int
    from public.employees e
    left join public.attendance a on a.employee_id = e.id and a.work_date between p_from and p_to
    where e.is_active
    group by e.id, e.full_name
    order by e.full_name;
end;
$$;

-- ---------- RLS ----------
alter table public.performance_reviews enable row level security;

drop policy if exists perf_select on public.performance_reviews;
create policy perf_select on public.performance_reviews for select to authenticated
using (public.my_role() in ('gm','hr') or employee_id = public.my_employee_id());
-- الكتابة بـ submit_review بس

drop trigger if exists trg_perf_audit on public.performance_reviews;
create trigger trg_perf_audit after insert or update on public.performance_reviews
for each row execute function public.audit_row();

-- ---------- ملاحظات ----------
-- 1) الإجازة غير المدفوعة بتتخصم من المعاينة تلقائياً. الصرف الفعلي بيفضل يدوي بـ pay_salary.
-- 2) تقييم الأداء معلومة حساسة: الموظف يشوف تقييمه بس. المدير والـ HR يشوفوا الكل.
