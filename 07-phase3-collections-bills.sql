-- ============================================================
-- المرحلة 3 - الجزء 2: تحصيل الفواتير، وفواتير الموردين، والضريبة، وقائمة الدخل التقريبية
-- شغّلها بعد 06-phase3-treasury.sql. الملف idempotent.
-- القرارات (تقدر تغيّرها):
--  • التحصيل مربوط برقم الفاتورة، ومايتعداش المتبقي عليها.
--  • فواتير الموردين مربوطة بالقيود عن طريق bill_id.
--  • قائمة الدخل "تقريبية" على أساس الفواتير والمشتريات الصادرة، مش معايير محاسبية كاملة.
-- ============================================================

-- ---------- ربط القيود بفواتير الموردين ----------
alter table public.ledger
  add column if not exists bill_id uuid;

-- ---------- فواتير الموردين ----------
create table if not exists public.supplier_bills (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  bill_no text,
  bill_date date not null default current_date,
  subtotal numeric(14,2) not null default 0 check (subtotal >= 0),
  tax_total numeric(14,2) not null default 0 check (tax_total >= 0),
  total numeric(14,2) generated always as (subtotal + tax_total) stored,
  notes text,
  created_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_bills_supplier on public.supplier_bills (supplier_id, bill_date);

alter table public.ledger
  drop constraint if exists ledger_bill_fk;
alter table public.ledger
  add constraint ledger_bill_fk foreign key (bill_id) references public.supplier_bills(id) on delete restrict;

-- ---------- كام اتحصّل على فاتورة ----------
create or replace function public.invoice_received(p_doc uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.my_role(), '') not in ('gm','accounting','sales') then raise exception 'forbidden'; end if;
  return (select coalesce(sum(case when l.direction = 'in' then l.amount else -l.amount end), 0)
          from public.ledger l where l.document_id = p_doc);
end;
$$;

-- ---------- تحصيل من فاتورة (بيمنع الزيادة على المتبقي) ----------
create or replace function public.collect_invoice(
  p_doc uuid, p_account uuid, p_amount numeric, p_date date, p_note text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  d record;
  v_remaining numeric;
  v_id uuid;
begin
  if coalesce(public.my_role(), '') not in ('gm','accounting') then raise exception 'forbidden'; end if;

  -- قفل صف الفاتورة علشان التحصيلين المتزامنين ما يتجاوزوش المتبقي
  select * into d from public.documents where id = p_doc for update;
  if not found then raise exception 'الفاتورة مش موجودة'; end if;
  if d.doc_type <> 'invoice' or d.status <> 'issued' then
    raise exception 'التحصيل بيتم على فاتورة صادرة بس';
  end if;

  v_remaining := d.total - public.invoice_received(p_doc);
  if p_amount > v_remaining then
    raise exception 'المبلغ أكبر من المتبقي على الفاتورة (%)', v_remaining;
  end if;

  v_id := public.post_entry(
    p_account, 'in', p_amount, 'تحصيل فاتورة ' || d.doc_number,
    'customer', d.customer_id, p_note, p_date, p_doc, null, false, null
  );
  return v_id;
end;
$$;

-- ---------- تسجيل فاتورة مورد ----------
create or replace function public.add_supplier_bill(
  p_supplier uuid, p_bill_no text, p_date date, p_subtotal numeric, p_tax numeric, p_notes text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if coalesce(public.my_role(), '') not in ('gm','accounting','purchasing') then raise exception 'forbidden'; end if;
  if coalesce(p_subtotal, 0) <= 0 then raise exception 'قيمة الفاتورة لازم تكون أكبر من صفر'; end if;
  insert into public.supplier_bills (supplier_id, bill_no, bill_date, subtotal, tax_total, notes, created_by)
  values (p_supplier, nullif(p_bill_no,''), coalesce(p_date, current_date), p_subtotal, coalesce(p_tax,0), nullif(p_notes,''), public.my_employee_id())
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------- المتبقي على فاتورة مورد ----------
create or replace function public.bill_paid(p_bill uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.my_role(), '') not in ('gm','accounting','purchasing') then raise exception 'forbidden'; end if;
  return (select coalesce(sum(case when l.direction = 'out' then l.amount else -l.amount end), 0)
          from public.ledger l where l.bill_id = p_bill);
end;
$$;

-- ---------- دفع فاتورة مورد (بيمنع الزيادة على المتبقي) ----------
create or replace function public.pay_supplier_bill(
  p_bill uuid, p_account uuid, p_amount numeric, p_date date, p_note text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  b record;
  v_remaining numeric;
  v_id uuid;
begin
  if coalesce(public.my_role(), '') not in ('gm','accounting') then raise exception 'forbidden'; end if;
  select * into b from public.supplier_bills where id = p_bill for update;
  if not found then raise exception 'الفاتورة مش موجودة'; end if;

  v_remaining := b.total - public.bill_paid(p_bill);
  if p_amount > v_remaining then
    raise exception 'المبلغ أكبر من المتبقي على فاتورة المورد (%)', v_remaining;
  end if;

  -- نفس فحوص post_entry، بس بنكتب bill_id في نفس الإدخال (القيد immutable فمينفعش نعدله بعدين)
  perform 1 from public.accounts where id = p_account and is_active for update;
  if not found then raise exception 'الحساب مش موجود أو موقوف'; end if;

  if exists (select 1 from public.period_locks where locked_until >= coalesce(p_date, current_date)) then
    raise exception 'الفترة دي مقفولة';
  end if;
  if public.account_balance(p_account) < p_amount then
    raise exception 'الرصيد مش كفاية';
  end if;

  insert into public.ledger (entry_date, account_id, direction, amount, category, party_type, party_id, note, bill_id, created_by)
  values (coalesce(p_date, current_date), p_account, 'out', p_amount, 'دفع فاتورة مورد ' || coalesce(b.bill_no,''),
          'supplier', b.supplier_id, p_note, p_bill, public.my_employee_id())
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------- مديونية الموردين ----------
create or replace view public.supplier_balances
with (security_invoker = true) as
select
  s.id as supplier_id,
  s.name,
  coalesce((select sum(b.total) from public.supplier_bills b where b.supplier_id = s.id), 0) as billed,
  coalesce((select sum(case when l.direction = 'out' then l.amount else -l.amount end)
            from public.ledger l where l.party_type = 'supplier' and l.party_id = s.id), 0) as paid,
  coalesce((select sum(b.total) from public.supplier_bills b where b.supplier_id = s.id), 0)
  - coalesce((select sum(case when l.direction = 'out' then l.amount else -l.amount end)
            from public.ledger l where l.party_type = 'supplier' and l.party_id = s.id), 0) as owed
from public.suppliers s;

-- ---------- الضريبة لفترة ----------
create or replace function public.vat_summary(p_from date, p_to date)
returns table (output_tax numeric, input_tax numeric, payable numeric)
language sql stable security definer set search_path = public as $$
  select
    coalesce((select sum(d.tax_total) from public.documents d
              where d.doc_type = 'invoice' and d.status = 'issued'
                and d.doc_date between p_from and p_to), 0),
    coalesce((select sum(b.tax_total) from public.supplier_bills b
              where b.bill_date between p_from and p_to), 0),
    coalesce((select sum(d.tax_total) from public.documents d
              where d.doc_type = 'invoice' and d.status = 'issued'
                and d.doc_date between p_from and p_to), 0)
    - coalesce((select sum(b.tax_total) from public.supplier_bills b
              where b.bill_date between p_from and p_to), 0)
  where public.my_role() in ('gm','accounting')  -- الضريبة للمدير والحسابات بس، وإلا بيرجع فاضي
$$;

-- ---------- قائمة الدخل التقريبية لفترة ----------
create or replace function public.income_statement(p_from date, p_to date)
returns table (revenue numeric, discounts numeric, purchases numeric, gross_profit numeric)
language sql stable security definer set search_path = public as $$
  select
    coalesce((select sum(d.subtotal) from public.documents d
              where d.doc_type = 'invoice' and d.status = 'issued' and d.doc_date between p_from and p_to), 0),
    coalesce((select sum(d.discount) from public.documents d
              where d.doc_type = 'invoice' and d.status = 'issued' and d.doc_date between p_from and p_to), 0),
    coalesce((select sum(b.subtotal) from public.supplier_bills b
              where b.bill_date between p_from and p_to), 0),
    coalesce((select sum(d.subtotal) - sum(d.discount) from public.documents d
              where d.doc_type = 'invoice' and d.status = 'issued' and d.doc_date between p_from and p_to), 0)
    - coalesce((select sum(b.subtotal) from public.supplier_bills b
              where b.bill_date between p_from and p_to), 0)
  where public.my_role() in ('gm','accounting')
$$;

-- ---------- RLS ----------
alter table public.supplier_bills enable row level security;

drop policy if exists bills_select on public.supplier_bills;
create policy bills_select on public.supplier_bills for select to authenticated
using (public.my_role() in ('gm','accounting','purchasing'));

drop policy if exists bills_write on public.supplier_bills;
create policy bills_write on public.supplier_bills for all to authenticated
using (public.my_role() = 'gm') with check (public.my_role() = 'gm');
-- الإضافة بتتم بـ add_supplier_bill. مفيش تعديل أو حذف مباشر

drop trigger if exists trg_bills_audit on public.supplier_bills;
create trigger trg_bills_audit after insert on public.supplier_bills
for each row execute function public.audit_row();

-- ---------- ملاحظات ----------
-- 1) الدوال المالية كلها security definer وبتفحص الدور داخلها (الفحص مش بيعتمد على RLS بس).
-- 2) account_balance و post_entry_check بيحسبوا من القيود، ومحتاجين يتشغلوا بعد 06.
-- 3) المرحلة الجاية: العُهد، والرواتب، وربط الواجهة بالتحصيل والدفع والضريبة.
