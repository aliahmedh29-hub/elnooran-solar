-- ============================================================
-- سيستم النوران - المرحلة 2 (المستندات: فواتير وعروض أسعار)
-- شغّلها بعد 01-schema.sql. الملف idempotent.
-- ملاحظات:
--  • الترقيم بيتم في السيرفر (دالة atomic) علشان ما يتكررش.
--  • المستند بيتحفظ مرة واحدة ومايتعدلش. الإلغاء بيكون بتغيير الحالة (المدير بس).
--  • الإجماليات بتتحسب على السيرفر من البنود، والواجهة بس بتعرض تقدير.
--  • شكل الـ PDF لسه مفتوح، وده مش بيأثر على الداتا.
-- ============================================================

-- ---------- بيانات الشركة (صف واحد) ----------
create table if not exists public.company_settings (
  id int primary key default 1 check (id = 1),
  name text not null,
  city text,
  phone text,
  email text,
  web text,
  warranty_text text,
  terms_text text,
  updated_at timestamptz not null default now()
);
insert into public.company_settings (id, name)
values (1, 'النوران سولار للطاقة الشمسية')
on conflict (id) do nothing;

-- ---------- عدادات الترقيم ----------
create table if not exists public.doc_sequences (
  prefix text not null,
  year int not null,
  last_no int not null default 0,
  primary key (prefix, year)
);

create or replace function public.next_doc_number(p_prefix text, p_year int)
returns text language plpgsql security definer set search_path = public as $$
declare
  n int;
begin
  insert into public.doc_sequences (prefix, year, last_no)
  values (p_prefix, p_year, 1)
  on conflict (prefix, year)
  do update set last_no = public.doc_sequences.last_no + 1
  returning last_no into n;
  return p_prefix || '-' || p_year::text || '-' || lpad(n::text, 4, '0');
end;
$$;

-- ---------- المستندات ----------
create table if not exists public.documents (
  id uuid primary key default gen_random_uuid(),
  doc_type text not null check (doc_type in ('invoice','quote','annex','contract','receipt')),
  doc_number text not null unique,
  doc_date date not null default current_date,
  customer_id uuid references public.customers(id) on delete restrict,
  customer_name text not null,              -- نسخة من البيانات وقت الإصدار
  customer_phone text,
  customer_address text,
  system_type text,
  subtotal numeric(14,2) not null default 0,
  discount numeric(14,2) not null default 0,
  tax_total numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  paid numeric(14,2) not null default 0,
  status text not null default 'issued' check (status in ('issued','cancelled')),
  notes text,
  created_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_documents_customer on public.documents (customer_id);
create index if not exists idx_documents_date on public.documents (doc_date);

create table if not exists public.document_lines (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.documents(id) on delete cascade,
  position int not null,
  category text,
  description text not null,
  qty numeric(12,3) not null default 0,
  unit_price numeric(14,2) not null default 0,
  tax_rate numeric(5,2) not null default 0,
  line_total numeric(14,2) generated always as (qty * unit_price) stored
);
create index if not exists idx_doc_lines_doc on public.document_lines (document_id);

-- ---------- كتالوج الخامات حسب نوع المنظومة ----------
create table if not exists public.catalog_items (
  id uuid primary key default gen_random_uuid(),
  system_type text not null,
  category text not null,
  description text not null,
  default_price numeric(14,2),
  is_active boolean not null default true,
  unique (system_type, category, description)
);

-- ---------- إنشاء المستند كله في معاملة واحدة ----------
create or replace function public.create_document(p_type text, p_payload jsonb, p_lines jsonb)
returns table (doc_id uuid, doc_number text)
language plpgsql security definer set search_path = public as $$
declare
  v_emp uuid := public.my_employee_id();
  v_role text := public.my_role();
  v_prefix text;
  v_year int := extract(year from current_date)::int;
  v_num text;
  v_id uuid;
  v_cust record;
  v_sub numeric;
  v_tax numeric;
  v_disc numeric := coalesce((p_payload->>'discount')::numeric, 0);
  v_paid numeric := coalesce((p_payload->>'paid')::numeric, 0);
begin
  if coalesce(v_role, '') not in ('gm','sales') or v_emp is null then
    raise exception 'forbidden';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'no lines';
  end if;

  v_prefix := case p_type
    when 'invoice' then 'NR'
    when 'quote' then 'QT'
    when 'annex' then 'AN'
    when 'contract' then 'CT'
    when 'receipt' then 'GR'
    else null end;
  if v_prefix is null then raise exception 'bad type'; end if;

  -- بيانات العميل: من الجدول لو اختير، وإلا الاسم اليدوي
  select full_name, phone, address, system_type into v_cust
  from public.customers
  where id = nullif(p_payload->>'customer_id', '')::uuid;

  v_num := public.next_doc_number(v_prefix, v_year);

  insert into public.documents (
    doc_type, doc_number, doc_date, customer_id, customer_name, customer_phone,
    customer_address, system_type, discount, paid, notes, created_by
  ) values (
    p_type, v_num,
    coalesce(nullif(p_payload->>'doc_date','')::date, current_date),
    nullif(p_payload->>'customer_id','')::uuid,
    coalesce(v_cust.full_name, nullif(p_payload->>'manual_name',''), 'عميل'),
    v_cust.phone, v_cust.address, v_cust.system_type,
    v_disc, v_paid, nullif(p_payload->>'notes',''), v_emp
  ) returning id into v_id;

  insert into public.document_lines (document_id, position, category, description, qty, unit_price, tax_rate)
  select v_id, ord::int,
         nullif(l->>'category',''),
         l->>'description',
         (l->>'qty')::numeric,
         (l->>'unit_price')::numeric,
         coalesce((l->>'tax_rate')::numeric, 0)
  from jsonb_array_elements(p_lines) with ordinality as t(l, ord);

  -- الإجماليات من البنود نفسها (السيرفر هو المرجع مش الواجهة)
  select coalesce(sum(qty * unit_price), 0),
         coalesce(sum(qty * unit_price * tax_rate / 100), 0)
    into v_sub, v_tax
  from public.document_lines where document_id = v_id;

  update public.documents
     set subtotal = v_sub, tax_total = v_tax, total = v_sub + v_tax - v_disc
   where id = v_id;

  return query select v_id, v_num;
end;
$$;

-- ---------- Triggers ----------
drop trigger if exists trg_documents_audit on public.documents;
create trigger trg_documents_audit after insert or update or delete on public.documents
for each row execute function public.audit_row();

drop trigger if exists trg_settings_audit on public.company_settings;
create trigger trg_settings_audit after insert or update or delete on public.company_settings
for each row execute function public.audit_row();

drop trigger if exists trg_catalog_audit on public.catalog_items;
create trigger trg_catalog_audit after insert or update or delete on public.catalog_items
for each row execute function public.audit_row();

-- ---------- RLS ----------
alter table public.company_settings enable row level security;
alter table public.doc_sequences    enable row level security;   -- مفيش policy: الوصول بالدالة بس
alter table public.documents        enable row level security;
alter table public.document_lines   enable row level security;
alter table public.catalog_items    enable row level security;

drop policy if exists settings_select on public.company_settings;
create policy settings_select on public.company_settings for select to authenticated
using (true);

drop policy if exists settings_write on public.company_settings;
create policy settings_write on public.company_settings for all to authenticated
using (public.my_role() = 'gm') with check (public.my_role() = 'gm');

drop policy if exists docs_select on public.documents;
create policy docs_select on public.documents for select to authenticated
using (public.my_role() in ('gm','sales','accounting'));

-- الإنشاء بيتم عن طريق create_document فقط. الـ policy دي للتوثيق
drop policy if exists docs_update on public.documents;
create policy docs_update on public.documents for update to authenticated
using (public.my_role() = 'gm') with check (public.my_role() = 'gm');
-- مفيش policy للحذف: المستند ماينحذفش أبداً

drop policy if exists lines_select on public.document_lines;
create policy lines_select on public.document_lines for select to authenticated
using (public.my_role() in ('gm','sales','accounting'));

drop policy if exists catalog_select on public.catalog_items;
create policy catalog_select on public.catalog_items for select to authenticated
using (public.my_role() in ('gm','sales','accounting'));

drop policy if exists catalog_write on public.catalog_items;
create policy catalog_write on public.catalog_items for all to authenticated
using (public.my_role() = 'gm') with check (public.my_role() = 'gm');

-- ---------- ملاحظات ----------
-- 1) الدالة create_document مش بتسمح لغير gm وsales.
-- 2) الفواتير والعروض بس في الواجهة دلوقتي. الملاحق والعقود والإيصالات الدالة بتقبلها، والواجهة لسه ما اتعملتش.
-- 3) الإلغاء: UPDATE documents SET status='cancelled' بواسطة المدير. الترقيم مش بيترجع.
