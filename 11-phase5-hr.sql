-- ============================================================
-- المرحلة 5: الحضور والإجازات
-- شغّلها بعد 10-phase4-inventory.sql. الملف idempotent.
-- قرارات اتاخدت من غير رد منك (تقدر تغيّرها):
--  • الحضور والانصراف للموظف نفسه بس، وبموقع إلزامي (المتصفح بيبلغ بيه، مش متحقق منه).
--  • نطاق المكتب بيتحسب بالمسافة من إحداثيات المكتب (لو مش متضبطة، الحضور بيتسجل بدون تحقق نطاق).
--  • الإجازة السنوية 21 يوم افتراضياً، والإجازات بتتطلب موافقة المدير أو الـ HR.
--  • التوقيت بيتحسب بتوقيت القاهرة.
-- ============================================================

-- ---------- إعدادات المكتب والإجازات ----------
alter table public.company_settings
  add column if not exists office_lat double precision,
  add column if not exists office_lng double precision,
  add column if not exists office_radius_m int not null default 150,
  add column if not exists annual_leave_days int not null default 21;

-- ---------- المسافة بالمتر ----------
create or replace function public.distance_m(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  ))
$$;

-- ---------- الحضور ----------
create table if not exists public.attendance (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete restrict,
  work_date date not null,
  check_in timestamptz,
  in_lat double precision,
  in_lng double precision,
  in_distance_m double precision,
  in_in_range boolean,
  check_out timestamptz,
  out_lat double precision,
  out_lng double precision,
  out_distance_m double precision,
  out_in_range boolean,
  created_at timestamptz not null default now(),
  unique (employee_id, work_date)
);

-- تاريخ اليوم بتوقيت القاهرة
create or replace function public.cairo_today()
returns date language sql stable as $$
  select (now() at time zone 'Africa/Cairo')::date
$$;

create or replace function public.check_in(p_lat double precision, p_lng double precision)
returns table (r_date date, r_in_range boolean, r_distance_m double precision)
language plpgsql security definer set search_path = public as $$
declare
  v_emp uuid := public.my_employee_id();
  v_today date := public.cairo_today();
  s record;
  v_dist double precision;
  v_in boolean;
begin
  if v_emp is null then raise exception 'forbidden'; end if;
  if p_lat is null or p_lng is null then raise exception 'الموقع مطلوب عشان تسجل الحضور'; end if;
  if exists (select 1 from public.attendance where employee_id = v_emp and work_date = v_today and check_in is not null) then
    raise exception 'سجلت حضور النهاردة قبل كده';
  end if;

  select office_lat, office_lng, office_radius_m into s from public.company_settings where id = 1;
  if s.office_lat is not null and s.office_lng is not null then
    v_dist := public.distance_m(p_lat, p_lng, s.office_lat, s.office_lng);
    v_in := v_dist <= s.office_radius_m;
  end if;

  insert into public.attendance (employee_id, work_date, check_in, in_lat, in_lng, in_distance_m, in_in_range)
  values (v_emp, v_today, now(), p_lat, p_lng, v_dist, v_in)
  on conflict (employee_id, work_date) do update
    set check_in = excluded.check_in, in_lat = excluded.in_lat, in_lng = excluded.in_lng,
        in_distance_m = excluded.in_distance_m, in_in_range = excluded.in_in_range;

  return query select v_today, v_in, v_dist;
end;
$$;

create or replace function public.check_out(p_lat double precision, p_lng double precision)
returns table (r_date date, r_in_range boolean, r_distance_m double precision)
language plpgsql security definer set search_path = public as $$
declare
  v_emp uuid := public.my_employee_id();
  v_today date := public.cairo_today();
  s record;
  v_dist double precision;
  v_in boolean;
begin
  if v_emp is null then raise exception 'forbidden'; end if;
  if p_lat is null or p_lng is null then raise exception 'الموقع مطلوب عشان تسجل الانصراف'; end if;
  if not exists (select 1 from public.attendance where employee_id = v_emp and work_date = v_today and check_in is not null) then
    raise exception 'لازم تسجل الحضور الأول';
  end if;
  if exists (select 1 from public.attendance where employee_id = v_emp and work_date = v_today and check_out is not null) then
    raise exception 'سجلت انصراف النهاردة قبل كده';
  end if;

  select office_lat, office_lng, office_radius_m into s from public.company_settings where id = 1;
  if s.office_lat is not null and s.office_lng is not null then
    v_dist := public.distance_m(p_lat, p_lng, s.office_lat, s.office_lng);
    v_in := v_dist <= s.office_radius_m;
  end if;

  update public.attendance
     set check_out = now(), out_lat = p_lat, out_lng = p_lng, out_distance_m = v_dist, out_in_range = v_in
   where employee_id = v_emp and work_date = v_today;

  return query select v_today, v_in, v_dist;
end;
$$;

-- ---------- الإجازات ----------
create table if not exists public.leave_requests (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete restrict,
  leave_type text not null default 'annual' check (leave_type in ('annual','sick','unpaid','other')),
  start_date date not null,
  end_date date not null,
  days int not null check (days > 0),
  note text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  decided_by uuid references public.employees(id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  check (end_date >= start_date)
);
create index if not exists idx_leaves_emp on public.leave_requests (employee_id, start_date);

-- الرصيد السنوي المستخدم والمتبقي للموظف الحالي
create or replace function public.my_leave_balance()
returns table (allowance int, used int, pending int, remaining int)
language plpgsql stable security definer set search_path = public as $$
declare
  v_emp uuid := public.my_employee_id();
  v_year int := extract(year from public.cairo_today())::int;
  v_allow int;
  v_used int;
  v_pend int;
begin
  if v_emp is null then raise exception 'forbidden'; end if;
  select annual_leave_days into v_allow from public.company_settings where id = 1;
  select coalesce(sum(days), 0) into v_used from public.leave_requests
   where employee_id = v_emp and leave_type = 'annual' and status = 'approved' and extract(year from start_date) = v_year;
  select coalesce(sum(days), 0) into v_pend from public.leave_requests
   where employee_id = v_emp and leave_type = 'annual' and status = 'pending' and extract(year from start_date) = v_year;
  return query select coalesce(v_allow, 21), v_used::int, v_pend::int, (coalesce(v_allow,21) - v_used - v_pend)::int;
end;
$$;

create or replace function public.request_leave(p_type text, p_start date, p_end date, p_note text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_emp uuid := public.my_employee_id();
  v_days int;
  v_rem int;
  v_id uuid;
begin
  if v_emp is null then raise exception 'forbidden'; end if;
  if p_end < p_start then raise exception 'تاريخ النهاية قبل البداية'; end if;
  v_days := (p_end - p_start) + 1;
  if p_type = 'annual' then
    select remaining into v_rem from public.my_leave_balance();
    if v_days > v_rem then raise exception 'الرصيد السنوي مش كفاية. المتبقي: % يوم', v_rem; end if;
  end if;
  insert into public.leave_requests (employee_id, leave_type, start_date, end_date, days, note)
  values (v_emp, p_type, p_start, p_end, v_days, nullif(p_note,''))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.decide_leave(p_id uuid, p_approve boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.my_role();
  l record;
begin
  if coalesce(v_role, '') not in ('gm','hr') then raise exception 'forbidden'; end if;
  select * into l from public.leave_requests where id = p_id for update;
  if not found then raise exception 'الطلب مش موجود'; end if;
  if l.status <> 'pending' then raise exception 'الطلب اتقفل قبل كده'; end if;
  -- المدير بس يوافق على إجازة لمدير عام، والـ HR ما يوافقش على طلب بتاع المدير
  if (select role from public.employees where id = l.employee_id) = 'gm' and v_role <> 'gm' then
    raise exception 'المدير العام بس يقرر في إجازة المدير';
  end if;
  update public.leave_requests
     set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = public.my_employee_id(), decided_at = now()
   where id = p_id;
end;
$$;

create or replace function public.cancel_leave(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.leave_requests where id = p_id and employee_id = public.my_employee_id() and status = 'pending') then
    raise exception 'مينفعش تلغي الطلب ده';
  end if;
  update public.leave_requests set status = 'cancelled' where id = p_id;
end;
$$;

-- ---------- Audit ----------
drop trigger if exists trg_attendance_audit on public.attendance;
create trigger trg_attendance_audit after insert or update on public.attendance
for each row execute function public.audit_row();

drop trigger if exists trg_leaves_audit on public.leave_requests;
create trigger trg_leaves_audit after insert or update on public.leave_requests
for each row execute function public.audit_row();

-- ---------- RLS ----------
alter table public.attendance      enable row level security;
alter table public.leave_requests  enable row level security;

drop policy if exists att_select on public.attendance;
create policy att_select on public.attendance for select to authenticated
using (public.my_role() in ('gm','hr') or employee_id = public.my_employee_id());
-- الكتابة بـ check_in و check_out بس

drop policy if exists leave_select on public.leave_requests;
create policy leave_select on public.leave_requests for select to authenticated
using (public.my_role() in ('gm','hr') or employee_id = public.my_employee_id());
-- الكتابة بالدوال بس

-- ---------- ملاحظات ----------
-- 1) الموقع المتصفح بيبلغ بيه، ومش متحقق منه. الموظف ممكن يزوّره. ده حد معروف.
-- 2) الإجازات المعتمدة مابتتخصمش من الراتب تلقائياً. ده قرار لاحق مع الرواتب.
