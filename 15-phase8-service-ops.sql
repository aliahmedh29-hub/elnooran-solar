-- ============================================================
-- المرحلة 8: الخدمة والشكاوى، والتسويق، والتصنيع، والجودة
-- شغّلها بعد 14-phase7-projects.sql. الملف idempotent.
-- قرارات اتاخدت من غير رد منك (تقدر تغيّرها):
--  • التذكرة بتعدّي بالترتيب: مفتوحة ← جاري الشغل ← مغلقة. والإغلاق لازم يكون فيه حل مكتوب.
--  • التسويق: حملات بميزانية، والعميل ممكن يتربط بحملة. مفيش حساب ROI تلقائي.
--  • التصنيع: كل منتج ليه تركيبة (BOM) من أصناف المخزون. الإنتاج بيخصم المكونات ويضيف المنتج بمتوسط تكلفة محسوب.
--  • الجودة: فحوصات بتتسجل ومايتعدلش. الفشل مايمنعش الإنتاج تلقائياً، بس بيظهر في التقرير.
-- ============================================================

-- ---------- الخدمة والشكاوى ----------
create table if not exists public.service_tickets (
  id uuid primary key default gen_random_uuid(),
  ticket_no bigint generated always as identity,
  customer_id uuid not null references public.customers(id) on delete restrict,
  project_id uuid references public.projects(id) on delete restrict,
  kind text not null default 'maintenance' check (kind in ('complaint','maintenance','warranty','other')),
  description text not null,
  status text not null default 'open' check (status in ('open','in_progress','closed')),
  assignee_id uuid references public.employees(id) on delete set null,
  resolution text,
  opened_at timestamptz not null default now(),
  closed_at timestamptz
);
create index if not exists idx_tickets_status on public.service_tickets (status);

create or replace function public.open_ticket(p_customer uuid, p_project uuid, p_kind text, p_desc text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_no bigint;
begin
  if coalesce(public.my_role(), '') not in ('gm','sales') then raise exception 'forbidden'; end if;
  if coalesce(trim(p_desc), '') = '' then raise exception 'وصف المشكلة مطلوب'; end if;
  insert into public.service_tickets (customer_id, project_id, kind, description)
  values (p_customer, p_project, p_kind, trim(p_desc))
  returning ticket_no into v_no;
  return v_no;
end;
$$;

create or replace function public.update_ticket(p_id uuid, p_status text, p_assignee uuid, p_resolution text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  t record;
begin
  if coalesce(public.my_role(), '') not in ('gm','sales') then raise exception 'forbidden'; end if;
  select * into t from public.service_tickets where id = p_id for update;
  if not found then raise exception 'التذكرة مش موجودة'; end if;
  if t.status = 'closed' then raise exception 'التذكرة مقفولة'; end if;
  if p_status not in ('open','in_progress','closed') then raise exception 'حالة غير صحيحة'; end if;
  if p_status = 'open' and t.status <> 'open' then raise exception 'مينفعش ترجع التذكرة لمفتوحة'; end if;
  if p_status = 'closed' and coalesce(trim(p_resolution), '') = '' then
    raise exception 'لازم تكتب الحل قبل الإغلاق';
  end if;
  update public.service_tickets
     set status = p_status,
         assignee_id = coalesce(p_assignee, assignee_id),
         resolution = case when p_status = 'closed' then trim(p_resolution) else resolution end,
         closed_at = case when p_status = 'closed' then now() else closed_at end
   where id = p_id;
end;
$$;

-- ---------- التسويق ----------
create table if not exists public.campaigns (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  channel text not null default 'other' check (channel in ('facebook','instagram','google','whatsapp','referral','other')),
  budget numeric(14,2) not null default 0,
  starts_on date,
  ends_on date,
  created_at timestamptz not null default now()
);

alter table public.customers
  add column if not exists campaign_id uuid references public.campaigns(id);

create or replace function public.add_campaign(p_name text, p_channel text, p_budget numeric, p_start date, p_end date)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if coalesce(public.my_role(), '') not in ('gm','sales') then raise exception 'forbidden'; end if;
  insert into public.campaigns (name, channel, budget, starts_on, ends_on)
  values (trim(p_name), p_channel, coalesce(p_budget,0), p_start, p_end)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------- التصنيع: تركيبات المنتجات ----------
create table if not exists public.bom_lines (
  product_item_id uuid not null references public.stock_items(id) on delete restrict,
  component_item_id uuid not null references public.stock_items(id) on delete restrict,
  qty_per_unit numeric(12,3) not null check (qty_per_unit > 0),
  primary key (product_item_id, component_item_id),
  check (product_item_id <> component_item_id)
);

create or replace function public.set_bom_line(p_product uuid, p_component uuid, p_qty numeric)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.my_role(), '') not in ('gm','store') then raise exception 'forbidden'; end if;
  if coalesce(p_qty, 0) <= 0 then
    delete from public.bom_lines where product_item_id = p_product and component_item_id = p_component;
    return;
  end if;
  insert into public.bom_lines (product_item_id, component_item_id, qty_per_unit)
  values (p_product, p_component, p_qty)
  on conflict (product_item_id, component_item_id) do update set qty_per_unit = excluded.qty_per_unit;
end;
$$;

-- إنتاج: يخصم المكونات (حركات صرف) ويضيف المنتج (استلام) بتكلفة المكونات
create or replace function public.produce(p_product uuid, p_qty numeric, p_note text)
returns numeric
language plpgsql security definer set search_path = public as $$
declare
  c record;
  v_on_hand numeric;
  v_cost numeric := 0;
  v_prod record;
  v_prod_on_hand numeric;
  v_unit numeric;
  v_new_avg numeric;
begin
  if coalesce(public.my_role(), '') not in ('gm','store') then raise exception 'forbidden'; end if;
  if coalesce(p_qty, 0) <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
  if not exists (select 1 from public.bom_lines where product_item_id = p_product) then
    raise exception 'المنتج ملوش تركيبة';
  end if;

  -- تحقق من كل المكونات الأول، وبعدين الخصم (عشان ما يتخصمش نص حاجة)
  for c in
    select b.component_item_id, b.qty_per_unit * p_qty as need, i.name, i.avg_cost
    from public.bom_lines b join public.stock_items i on i.id = b.component_item_id
    where b.product_item_id = p_product
  loop
    select coalesce(sum(case when move_type in ('receive','adjust_in') then qty
                             when move_type in ('issue','adjust_out') then -qty else 0 end), 0)
      into v_on_hand from public.stock_moves where item_id = c.component_item_id;
    if v_on_hand < c.need then
      raise exception 'مكون ناقص: % (محتاج %، المتاح %)', c.name, c.need, v_on_hand;
    end if;
  end loop;

  for c in
    select b.component_item_id, b.qty_per_unit * p_qty as need, i.avg_cost
    from public.bom_lines b join public.stock_items i on i.id = b.component_item_id
    where b.product_item_id = p_product
  loop
    insert into public.stock_moves (item_id, move_type, qty, unit_cost, note, created_by)
    values (c.component_item_id, 'issue', c.need, c.avg_cost, 'إنتاج: ' || coalesce(p_note,''), public.my_employee_id());
    v_cost := v_cost + c.need * c.avg_cost;
  end loop;

  v_unit := round(v_cost / p_qty, 4);

  select * into v_prod from public.stock_items where id = p_product for update;
  select coalesce(sum(case when move_type in ('receive','adjust_in') then qty
                           when move_type in ('issue','adjust_out') then -qty else 0 end), 0)
    into v_prod_on_hand from public.stock_moves where item_id = p_product;
  if v_prod_on_hand + p_qty > 0 then
    v_new_avg := round(((v_prod_on_hand * v_prod.avg_cost) + (p_qty * v_unit)) / (v_prod_on_hand + p_qty), 4);
  else
    v_new_avg := v_unit;
  end if;

  insert into public.stock_moves (item_id, move_type, qty, unit_cost, note, created_by)
  values (p_product, 'receive', p_qty, v_unit, 'إنتاج: ' || coalesce(p_note,''), public.my_employee_id());
  update public.stock_items set avg_cost = v_new_avg where id = p_product;

  return v_unit;
end;
$$;

-- ---------- الجودة ----------
create table if not exists public.qa_checks (
  id uuid primary key default gen_random_uuid(),
  item_id uuid references public.stock_items(id) on delete restrict,
  batch text,
  check_name text not null,
  result text not null check (result in ('pass','fail')),
  note text,
  checked_by uuid references public.employees(id) on delete set null,
  checked_at timestamptz not null default now()
);

create or replace function public.add_qa_check(p_item uuid, p_batch text, p_name text, p_pass boolean, p_note text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if coalesce(public.my_role(), '') not in ('gm','store') then raise exception 'forbidden'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'اسم الفحص مطلوب'; end if;
  insert into public.qa_checks (item_id, batch, check_name, result, note, checked_by)
  values (p_item, nullif(p_batch,''), trim(p_name), case when p_pass then 'pass' else 'fail' end, nullif(p_note,''), public.my_employee_id())
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------- Triggers + immutability ----------
create or replace function public.qa_immutable()
returns trigger language plpgsql as $$
begin
  raise exception 'فحوصات الجودة مش بتتعدل ولا بتتحذف';
end;
$$;

drop trigger if exists trg_qa_immutable on public.qa_checks;
create trigger trg_qa_immutable before update or delete on public.qa_checks
for each row execute function public.qa_immutable();

drop trigger if exists trg_tickets_audit on public.service_tickets;
create trigger trg_tickets_audit after insert or update on public.service_tickets
for each row execute function public.audit_row();

drop trigger if exists trg_campaigns_audit on public.campaigns;
create trigger trg_campaigns_audit after insert on public.campaigns
for each row execute function public.audit_row();

-- ---------- RLS ----------
alter table public.service_tickets enable row level security;
alter table public.campaigns       enable row level security;
alter table public.bom_lines       enable row level security;
alter table public.qa_checks       enable row level security;

drop policy if exists tick_select on public.service_tickets;
create policy tick_select on public.service_tickets for select to authenticated
using (public.my_role() in ('gm','sales'));

drop policy if exists camp_select on public.campaigns;
create policy camp_select on public.campaigns for select to authenticated
using (public.my_role() in ('gm','sales'));

drop policy if exists bom_select on public.bom_lines;
create policy bom_select on public.bom_lines for select to authenticated
using (public.my_role() in ('gm','store','purchasing'));

drop policy if exists qa_select on public.qa_checks;
create policy qa_select on public.qa_checks for select to authenticated
using (public.my_role() in ('gm','store'));
