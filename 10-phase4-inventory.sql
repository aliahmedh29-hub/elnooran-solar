-- ============================================================
-- المرحلة 4: المخزون (الجزء الأول)
-- شغّلها بعد 09-phase3-salary-preview.sql. الملف idempotent.
-- قرارات اتاخدت من غير رد منك (تقدر تغيّرها):
--  • مخزن واحد دلوقتي. الحقل warehouse موجود علشان نضيف مخازن بعدين من غير تغيير كبير.
--  • التتبع بالكمية والسعر بمتوسط التكلفة المرجح.
--  • حركات المخزون مايتعدلش ولا يتحذف منها. التصحيح بحركة عكسية.
--  • الصرف مايسمحش بالرصيد بالسالب.
-- ============================================================

-- ---------- الأصناف ----------
create table if not exists public.stock_items (
  id uuid primary key default gen_random_uuid(),
  sku text unique,
  name text not null,
  category text,
  brand text,
  unit text not null default 'قطعة',
  reorder_level numeric(12,3) not null default 0,
  avg_cost numeric(14,4) not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- حركات المخزون ----------
create table if not exists public.stock_moves (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.stock_items(id) on delete restrict,
  warehouse text not null default 'main',
  move_type text not null check (move_type in ('receive','issue','adjust_in','adjust_out','reverse')),
  qty numeric(12,3) not null check (qty > 0),
  unit_cost numeric(14,4) not null default 0,
  bill_id uuid references public.supplier_bills(id) on delete restrict,
  document_id uuid references public.documents(id) on delete restrict,
  note text,
  reverses uuid references public.stock_moves(id),
  created_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_stock_moves_item on public.stock_moves (item_id, created_at);

-- ---------- الرصيد الحالي لكل صنف ----------
create or replace view public.stock_levels
with (security_invoker = true) as
select
  i.id as item_id,
  i.name,
  i.sku,
  i.unit,
  i.reorder_level,
  i.avg_cost,
  coalesce(sum(case when m.move_type in ('receive','adjust_in') then m.qty
                    when m.move_type in ('issue','adjust_out') then -m.qty
                    when m.move_type = 'reverse' then 0
                    else 0 end), 0) as on_hand
from public.stock_items i
left join public.stock_moves m on m.item_id = i.id
group by i.id, i.name, i.sku, i.unit, i.reorder_level, i.avg_cost;

-- ---------- إضافة صنف ----------
create or replace function public.add_stock_item(
  p_name text, p_sku text, p_category text, p_brand text, p_unit text, p_reorder numeric
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if coalesce(public.my_role(), '') not in ('gm','purchasing','store') then raise exception 'forbidden'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'اسم الصنف مطلوب'; end if;
  insert into public.stock_items (name, sku, category, brand, unit, reorder_level)
  values (trim(p_name), nullif(p_sku,''), nullif(p_category,''), nullif(p_brand,''),
          coalesce(nullif(p_unit,''), 'قطعة'), coalesce(p_reorder, 0))
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------- استلام بضاعة (بيحدّث متوسط التكلفة) ----------
create or replace function public.receive_stock(
  p_item uuid, p_qty numeric, p_unit_cost numeric, p_bill uuid, p_note text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_item record;
  v_on_hand numeric;
  v_new_avg numeric;
  v_id uuid;
begin
  if coalesce(public.my_role(), '') not in ('gm','purchasing','store') then raise exception 'forbidden'; end if;
  if coalesce(p_qty, 0) <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
  if coalesce(p_unit_cost, 0) < 0 then raise exception 'التكلفة مينفعش تكون بالسالب'; end if;

  -- قفل الصنف علشان متوسط التكلفة يتحسب صح لو في استلامين مع بعض
  select * into v_item from public.stock_items where id = p_item and is_active for update;
  if not found then raise exception 'الصنف مش موجود أو موقوف'; end if;

  select coalesce(sum(case when move_type in ('receive','adjust_in') then qty
                           when move_type in ('issue','adjust_out') then -qty else 0 end), 0)
    into v_on_hand
  from public.stock_moves where item_id = p_item;

  -- متوسط مرجّح: (القديم × الكمية القديمة + الجديد × الجديدة) / الإجمالي
  if v_on_hand + p_qty > 0 then
    v_new_avg := round(((v_on_hand * v_item.avg_cost) + (p_qty * p_unit_cost)) / (v_on_hand + p_qty), 4);
  else
    v_new_avg := p_unit_cost;
  end if;

  insert into public.stock_moves (item_id, move_type, qty, unit_cost, bill_id, note, created_by)
  values (p_item, 'receive', p_qty, p_unit_cost, p_bill, nullif(p_note,''), public.my_employee_id())
  returning id into v_id;

  update public.stock_items set avg_cost = v_new_avg where id = p_item;
  return v_id;
end;
$$;

-- ---------- صرف بضاعة (مايسمحش بالسالب) ----------
create or replace function public.issue_stock(
  p_item uuid, p_qty numeric, p_document uuid, p_note text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_item record;
  v_on_hand numeric;
  v_id uuid;
begin
  if coalesce(public.my_role(), '') not in ('gm','store') then raise exception 'forbidden'; end if;
  if coalesce(p_qty, 0) <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;

  select * into v_item from public.stock_items where id = p_item and is_active for update;
  if not found then raise exception 'الصنف مش موجود أو موقوف'; end if;

  select coalesce(sum(case when move_type in ('receive','adjust_in') then qty
                           when move_type in ('issue','adjust_out') then -qty else 0 end), 0)
    into v_on_hand
  from public.stock_moves where item_id = p_item;

  if v_on_hand < p_qty then
    raise exception 'الرصيد مش كفاية. المتاح: %', v_on_hand;
  end if;

  insert into public.stock_moves (item_id, move_type, qty, unit_cost, document_id, note, created_by)
  values (p_item, 'issue', p_qty, v_item.avg_cost, p_document, nullif(p_note,''), public.my_employee_id())
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------- تصحيح حركة: حركة عكسية مش تعديل ----------
create or replace function public.reverse_stock_move(p_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  m record;
  v_id uuid;
begin
  if coalesce(public.my_role(), '') not in ('gm','store') then raise exception 'forbidden'; end if;
  select * into m from public.stock_moves where id = p_id;
  if not found then raise exception 'الحركة مش موجودة'; end if;
  if m.move_type = 'reverse' or m.reverses is not null then raise exception 'ماينفعش نعكس حركة عكسية'; end if;
  if exists (select 1 from public.stock_moves where reverses = p_id) then raise exception 'الحركة اتعكست قبل كده'; end if;

  -- العكس بيكون صرف لو الأصلية استلام، وبيكون استلام لو الأصلية صرف.
  -- لو العكس هيخلي الرصيد بالسالب، بيترفض.
  if m.move_type = 'receive' then
    if (select coalesce(sum(case when move_type in ('receive','adjust_in') then qty
                                 when move_type in ('issue','adjust_out') then -qty else 0 end), 0)
        from public.stock_moves where item_id = m.item_id) < m.qty then
      raise exception 'مينفعش نعكس الاستلام: الكمية دي اتصرفت خلاص';
    end if;
    insert into public.stock_moves (item_id, move_type, qty, unit_cost, bill_id, note, reverses, created_by)
    values (m.item_id, 'issue', m.qty, m.unit_cost, m.bill_id, 'عكس استلام', p_id, public.my_employee_id())
    returning id into v_id;
  else
    insert into public.stock_moves (item_id, move_type, qty, unit_cost, document_id, note, reverses, created_by)
    values (m.item_id, 'receive', m.qty, m.unit_cost, m.document_id, 'عكس صرف', p_id, public.my_employee_id())
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

-- ---------- جرد: تسوية الرصيد الفعلي (بحركة زيادة أو نقص) ----------
create or replace function public.adjust_stock(
  p_item uuid, p_counted numeric, p_note text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_item record;
  v_on_hand numeric;
  v_diff numeric;
  v_id uuid;
begin
  if coalesce(public.my_role(), '') not in ('gm','store') then raise exception 'forbidden'; end if;
  if coalesce(p_counted, -1) < 0 then raise exception 'الكمية المعدودة مينفعش تكون بالسالب'; end if;

  select * into v_item from public.stock_items where id = p_item and is_active for update;
  if not found then raise exception 'الصنف مش موجود أو موقوف'; end if;

  select coalesce(sum(case when move_type in ('receive','adjust_in') then qty
                           when move_type in ('issue','adjust_out') then -qty else 0 end), 0)
    into v_on_hand
  from public.stock_moves where item_id = p_item;

  v_diff := p_counted - v_on_hand;
  if v_diff = 0 then return null; end if;

  if v_diff > 0 then
    insert into public.stock_moves (item_id, move_type, qty, unit_cost, note, created_by)
    values (p_item, 'adjust_in', v_diff, v_item.avg_cost, coalesce(nullif(p_note,''),'جرد - زيادة'), public.my_employee_id())
    returning id into v_id;
  else
    insert into public.stock_moves (item_id, move_type, qty, unit_cost, note, created_by)
    values (p_item, 'adjust_out', -v_diff, v_item.avg_cost, coalesce(nullif(p_note,''),'جرد - نقص'), public.my_employee_id())
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

-- ---------- منع تعديل أو حذف حركات المخزون ----------
create or replace function public.stock_moves_immutable()
returns trigger language plpgsql as $$
begin
  raise exception 'حركات المخزون مش بتتعدل ولا بتتحذف. استخدم عكس الحركة';
end;
$$;

drop trigger if exists trg_stock_moves_immutable on public.stock_moves;
create trigger trg_stock_moves_immutable before update or delete on public.stock_moves
for each row execute function public.stock_moves_immutable();

-- ---------- Audit ----------
drop trigger if exists trg_stock_items_audit on public.stock_items;
create trigger trg_stock_items_audit after insert or update on public.stock_items
for each row execute function public.audit_row();

drop trigger if exists trg_stock_moves_audit on public.stock_moves;
create trigger trg_stock_moves_audit after insert on public.stock_moves
for each row execute function public.audit_row();

-- ---------- RLS ----------
alter table public.stock_items enable row level security;
alter table public.stock_moves enable row level security;

drop policy if exists items_select on public.stock_items;
create policy items_select on public.stock_items for select to authenticated
using (public.my_role() in ('gm','purchasing','store','accounting'));

drop policy if exists items_write on public.stock_items;
create policy items_write on public.stock_items for update to authenticated
using (public.my_role() = 'gm') with check (public.my_role() = 'gm');
-- الإضافة بـ add_stock_item

drop policy if exists moves_select on public.stock_moves;
create policy moves_select on public.stock_moves for select to authenticated
using (public.my_role() in ('gm','purchasing','store','accounting'));
-- الكتابة بالدوال بس

-- ---------- ملاحظات ----------
-- 1) الأصناف اللي مخزونها أقل من حد إعادة الطلب: select where on_hand <= reorder_level (من stock_levels).
-- 2) سعر الصرف للمستندات (issue) بيتاخد من متوسط التكلفة وقت الصرف.
-- 3) الجرد: adjust_stock بيقارن الرصيد الفعلي بالدفتري ويسجل الفرق كحركة زيادة أو نقص.
-- 4) الواجهة في قسم المخزون بالـ index.html.
