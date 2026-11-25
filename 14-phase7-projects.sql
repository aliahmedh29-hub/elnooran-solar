-- ============================================================
-- المرحلة 7: المشاريع والتركيب
-- شغّلها بعد 13-phase6-sales.sql. الملف idempotent.
-- قرارات اتاخدت من غير رد منك (تقدر تغيّرها):
--  • دور "مشاريع" مش موجود لسه في النظام، فالوصول للمشاريع للمدير والمبيعات دلوقتي. نضيفه بعدين.
--  • المشروع بيتربط بالعميل وبفاتورة العقد (اختياري).
--  • مراحل المشروع: معاينة، تصميم، موافقة، تركيب، تشغيل تجريبي، تسليم.
--  • يومية الموقع بتتسجل ومايتعدلش (زي القيود).
--  • حاسبة المنظومة في المتصفح (حسابات بس، مش بتتسجل).
-- ============================================================

create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references public.customers(id) on delete restrict,
  document_id uuid references public.documents(id) on delete restrict,
  name text not null,
  site_address text,
  capacity_kw numeric(10,2),
  stage text not null default 'survey' check (stage in ('survey','design','approval','install','commissioning','handover')),
  stage_changed_at timestamptz not null default now(),
  start_date date,
  target_date date,
  manager_id uuid references public.employees(id) on delete set null,
  notes text,
  created_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_projects_customer on public.projects (customer_id);

create table if not exists public.project_logs (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  log_date date not null default current_date,
  crew text,
  work_done text not null,
  issues text,
  created_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_logs_project on public.project_logs (project_id, log_date);

-- ---------- إضافة مشروع ----------
create or replace function public.add_project(
  p_customer uuid, p_document uuid, p_name text, p_address text, p_capacity numeric,
  p_manager uuid, p_start date, p_target date, p_notes text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if coalesce(public.my_role(), '') not in ('gm','sales') then raise exception 'forbidden'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'اسم المشروع مطلوب'; end if;
  insert into public.projects (customer_id, document_id, name, site_address, capacity_kw, manager_id, start_date, target_date, notes, created_by)
  values (p_customer, p_document, trim(p_name), nullif(p_address,''), p_capacity, p_manager, p_start, p_target, nullif(p_notes,''), public.my_employee_id())
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------- تغيير مرحلة المشروع (بالترتيب بس، ومايرجعش) ----------
create or replace function public.advance_project(p_project uuid, p_stage text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  order_list text[] := array['survey','design','approval','install','commissioning','handover'];
  cur_stage text;
  cur_idx int;
  new_idx int;
begin
  if coalesce(public.my_role(), '') not in ('gm','sales') then raise exception 'forbidden'; end if;
  select stage into cur_stage from public.projects where id = p_project for update;
  if not found then raise exception 'المشروع مش موجود'; end if;
  cur_idx := array_position(order_list, cur_stage);
  new_idx := array_position(order_list, p_stage);
  if new_idx is null then raise exception 'مرحلة غير صحيحة'; end if;
  if new_idx <> cur_idx + 1 then raise exception 'المرحلة بتتقدم خطوة خطوة. الحالية: %', cur_stage; end if;
  update public.projects set stage = p_stage, stage_changed_at = now() where id = p_project;
end;
$$;

-- ---------- يومية الموقع ----------
create or replace function public.add_project_log(
  p_project uuid, p_date date, p_crew text, p_work text, p_issues text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if coalesce(public.my_role(), '') not in ('gm','sales') then raise exception 'forbidden'; end if;
  if coalesce(trim(p_work), '') = '' then raise exception 'اكتب الشغل اللي اتعمل'; end if;
  insert into public.project_logs (project_id, log_date, crew, work_done, issues, created_by)
  values (p_project, coalesce(p_date, current_date), nullif(p_crew,''), trim(p_work), nullif(p_issues,''), public.my_employee_id())
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------- Triggers ----------
drop trigger if exists trg_projects_audit on public.projects;
create trigger trg_projects_audit after insert or update on public.projects
for each row execute function public.audit_row();

drop trigger if exists trg_logs_audit on public.project_logs;
create trigger trg_logs_audit after insert on public.project_logs
for each row execute function public.audit_row();

create or replace function public.project_logs_immutable()
returns trigger language plpgsql as $$
begin
  raise exception 'يومية الموقع مش بتتعدل ولا بتتحذف';
end;
$$;

drop trigger if exists trg_logs_immutable on public.project_logs;
create trigger trg_logs_immutable before update or delete on public.project_logs
for each row execute function public.project_logs_immutable();

-- ---------- RLS ----------
alter table public.projects     enable row level security;
alter table public.project_logs enable row level security;

drop policy if exists proj_select on public.projects;
create policy proj_select on public.projects for select to authenticated
using (public.my_role() in ('gm','sales'));

drop policy if exists logs_select on public.project_logs;
create policy logs_select on public.project_logs for select to authenticated
using (public.my_role() in ('gm','sales'));

-- الكتابة بالدوال بس (add_project، advance_project، add_project_log)
