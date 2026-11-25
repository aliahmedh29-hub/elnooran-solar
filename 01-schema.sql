-- ============================================================
-- سيستم النوران - المرحلة 1 (الدخول والصلاحيات والدليل)
-- الإصدار: 1.1 (مراجعة على مسودة المرحلة 1)
-- التنفيذ: Supabase SQL Editor على مشروع جديد (مش الإنتاج).
-- قبل أي بيانات حقيقية: نسخة احتياطية + اختبار الصلاحيات (ملف 03).
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- دوال مساعدة ----------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------- الموظفين ----------
create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  username text not null unique,
  full_name text not null,
  phone text,
  email text,
  job_title text,
  department text not null check (department in (
    'management','sales','purchasing','accounting','store','hr',
    'projects','service','marketing','pos','manufacturing'
  )),
  role text not null default 'staff' check (role in (
    'gm','sales','purchasing','accounting','store','hr','staff'
  )),
  hire_date date,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- الرواتب في جدول منفصل بصلاحية محدودة
create table if not exists public.employee_salaries (
  employee_id uuid primary key references public.employees(id) on delete cascade,
  base_salary numeric(12,2) not null default 0,
  commission_rate numeric(6,4) not null default 0.02,
  updated_at timestamptz not null default now()
);

-- دوال الهوية والدور (security definer علشان نتفادى recursion في السياسات)
create or replace function public.my_employee_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.employees
  where auth_user_id = auth.uid() and is_active
  limit 1
$$;

create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $$
  select role from public.employees
  where auth_user_id = auth.uid() and is_active
  limit 1
$$;

-- اسم الموظف بس (بدون أي بيانات تانية) علشان يظهر في العملاء والمحادثات لكل الأدوار
create or replace function public.employee_name(p_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select full_name from public.employees where id = p_id
$$;

-- نسخة دفعة واحدة من أسماء الموظفين (بدل استدعاء لكل عميل)
create or replace function public.employee_names_bulk(p_ids uuid[])
returns table (id uuid, full_name text) language sql stable security definer set search_path = public as $$
  select e.id, e.full_name from public.employees e where e.id = any(p_ids)
$$;

-- ---------- العملاء ----------
create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  phone text not null unique,               -- الرقم مش بيتكرر
  secondary_phone text,
  area text,
  address text,
  system_type text check (system_type in ('on-grid','off-grid','hybrid','pumping','other')),
  stage text not null default 'lead' check (stage in ('lead','quoted','won','lost')),
  stage_changed_at timestamptz not null default now(),
  next_followup date,
  owner_employee_id uuid references public.employees(id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_customers_owner on public.customers (owner_employee_id);
create index if not exists idx_customers_stage on public.customers (stage);

-- ملاحظات المكالمات والزيارات: سجل ثابت (مش بيتعدل ولا بيتحذف إلا من المدير)
create table if not exists public.customer_notes (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  note_type text not null default 'أخرى' check (note_type in ('مكالمة','زيارة','واتساب','متابعة','أخرى')),
  body text not null,
  created_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_notes_customer on public.customer_notes (customer_id, created_at);

-- ---------- الموردين ----------
create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  contact_person text,
  phone text,
  email text,
  address text,
  governorate text,
  tax_number text,
  commercial_register text,
  types text[] not null default '{}',       -- أنواع اللي المورد بيوفرها
  brands text[] not null default '{}',
  payment_terms text,
  credit_limit numeric(12,2) not null default 0,
  currency text not null default 'EGP',
  is_active boolean not null default true,  -- false = متوقف
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- سجل التدقيق (بيتسجل على السيرفر) ----------
create table if not exists public.audit_log (
  id bigserial primary key,
  actor_employee_id uuid,
  action text not null,                     -- INSERT / UPDATE / DELETE
  table_name text not null,
  row_id text,
  detail jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.audit_row()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  payload jsonb;
begin
  payload := case when TG_OP = 'DELETE' then to_jsonb(OLD) else to_jsonb(NEW) end;
  insert into public.audit_log (actor_employee_id, action, table_name, row_id, detail)
  values (public.my_employee_id(), TG_OP, TG_TABLE_NAME, coalesce(payload->>'id', ''), payload);
  return coalesce(NEW, OLD);
end;
$$;

-- ---------- الـ triggers ----------
drop trigger if exists trg_employees_updated on public.employees;
create trigger trg_employees_updated before update on public.employees
for each row execute function public.set_updated_at();

drop trigger if exists trg_customers_updated on public.customers;
create trigger trg_customers_updated before update on public.customers
for each row execute function public.set_updated_at();

drop trigger if exists trg_suppliers_updated on public.suppliers;
create trigger trg_suppliers_updated before update on public.suppliers
for each row execute function public.set_updated_at();

drop trigger if exists trg_audit_employees on public.employees;
create trigger trg_audit_employees after insert or update or delete on public.employees
for each row execute function public.audit_row();

drop trigger if exists trg_audit_salaries on public.employee_salaries;
create trigger trg_audit_salaries after insert or update or delete on public.employee_salaries
for each row execute function public.audit_row();

drop trigger if exists trg_audit_customers on public.customers;
create trigger trg_audit_customers after insert or update or delete on public.customers
for each row execute function public.audit_row();

drop trigger if exists trg_audit_suppliers on public.suppliers;
create trigger trg_audit_suppliers after insert or update or delete on public.suppliers
for each row execute function public.audit_row();

-- ---------- RLS: تفعيل ----------
alter table public.employees         enable row level security;
alter table public.employee_salaries enable row level security;
alter table public.customers         enable row level security;
alter table public.customer_notes    enable row level security;
alter table public.suppliers         enable row level security;
alter table public.audit_log         enable row level security;

-- ---------- RLS: الموظفين ----------
-- المدير و HR يشوفوا الكل، والموظف يشوف ملفه بس
drop policy if exists emp_select on public.employees;
create policy emp_select on public.employees for select to authenticated
using (public.my_role() in ('gm','hr') or auth_user_id = auth.uid());

-- الكتابة للمدير و HR. الحذف الفعلي ممنوع من الواجهة: الإيقاف بيكون is_active=false
drop policy if exists emp_write on public.employees;
create policy emp_write on public.employees for all to authenticated
using (public.my_role() in ('gm','hr'))
with check (public.my_role() in ('gm','hr'));

-- ---------- RLS: الرواتب ----------
drop policy if exists sal_select on public.employee_salaries;
create policy sal_select on public.employee_salaries for select to authenticated
using (
  public.my_role() in ('gm','hr','accounting')
  or employee_id = public.my_employee_id()
);

drop policy if exists sal_write on public.employee_salaries;
create policy sal_write on public.employee_salaries for all to authenticated
using (public.my_role() in ('gm','hr'))
with check (public.my_role() in ('gm','hr'));

-- ---------- RLS: العملاء ----------
-- المبيعات والمدير والحسابات يشوفوا الملف كامل (زي النسخة الحالية)
drop policy if exists cust_select on public.customers;
create policy cust_select on public.customers for select to authenticated
using (public.my_role() in ('gm','sales','accounting'));

drop policy if exists cust_insert on public.customers;
create policy cust_insert on public.customers for insert to authenticated
with check (public.my_role() in ('gm','sales'));

drop policy if exists cust_update on public.customers;
create policy cust_update on public.customers for update to authenticated
using (public.my_role() in ('gm','sales'))
with check (public.my_role() in ('gm','sales'));

-- الحذف للمدير بس
drop policy if exists cust_delete on public.customers;
create policy cust_delete on public.customers for delete to authenticated
using (public.my_role() = 'gm');

-- ---------- RLS: ملاحظات العملاء ----------
drop policy if exists note_select on public.customer_notes;
create policy note_select on public.customer_notes for select to authenticated
using (public.my_role() in ('gm','sales','accounting'));

drop policy if exists note_insert on public.customer_notes;
create policy note_insert on public.customer_notes for insert to authenticated
with check (public.my_role() in ('gm','sales') and created_by = public.my_employee_id());

-- مفيش policy للتعديل. الحذف للمدير بس
drop policy if exists note_delete on public.customer_notes;
create policy note_delete on public.customer_notes for delete to authenticated
using (public.my_role() = 'gm');

-- ---------- RLS: الموردين ----------
drop policy if exists sup_select on public.suppliers;
create policy sup_select on public.suppliers for select to authenticated
using (public.my_role() in ('gm','purchasing','accounting','store'));

drop policy if exists sup_write on public.suppliers;
create policy sup_write on public.suppliers for all to authenticated
using (public.my_role() in ('gm','purchasing'))
with check (public.my_role() in ('gm','purchasing'));

-- ---------- RLS: سجل التدقيق ----------
drop policy if exists audit_select on public.audit_log;
create policy audit_select on public.audit_log for select to authenticated
using (public.my_role() = 'gm');
-- مفيش policy للكتابة: الكتابة بتتم من الـ trigger بس

-- ---------- ملاحظات تنفيذ ----------
-- 1) أول مدير عام: بعد إنشاء المستخدم في Supabase Auth، يتضاف صف في employees
--    بـ role='gm' وauth_user_id بتاعه. ده بيتعمل مرة واحدة من SQL Editor.
-- 2) إعادة تعيين كلمة المرور: بتتعمل بـ Admin API من السيرفر (Edge Function)، مش من الواجهة.
-- 3) مفتاح service_role ممنوع يدخل الواجهة أبداً.
-- 4) الملف ده idempotent: يتنفذ أكتر من مرة من غير ما يقع.
