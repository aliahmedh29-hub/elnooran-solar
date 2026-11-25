-- ============================================================
-- المرحلة 10: استكمال الميزات اللي كانت في النسخة القديمة
-- شغّلها بعد 16-phase9-reports.sql. الملف idempotent.
-- اللي فيه:
--  • بيانات الموردين الإضافية (التقييم، مدة التوريد) + أسعار الموردين + مستندات الموردين بتاريخ انتهاء
--  • استيراد الموردين من CSV مع تخطي المكرر والغلط
--  • سجل واتساب (تسجيل الرسايل، مش إرسال فعلي)
--  • كل الجداول الجديدة عليها سجل تدقيق وحماية من التعديل
-- ============================================================

-- ---------- توحيد رقم التليفون ----------
create or replace function public.normalize_phone(p text)
returns text language plpgsql immutable as $$
declare
  d text := regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g');
begin
  if d like '00%' then d := substr(d, 3); end if;                 -- 0020... أو 00...
  if d like '20%' and length(d) = 12 then d := substr(d, 3); end if; -- 2010... (من غير +)
  if length(d) = 10 and left(d, 1) = '1' then d := '0' || d; end if; -- 1xxxxxxxxx
  return d;
end;
$$;

-- ---------- بيانات إضافية للموردين ----------
alter table public.suppliers
  add column if not exists rating int check (rating between 1 and 5),
  add column if not exists lead_days int check (lead_days >= 0);

-- ---------- أسعار الموردين (سجل بالتاريخ) ----------
create table if not exists public.supplier_prices (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.suppliers(id) on delete cascade,
  item text not null check (length(trim(item)) > 0),
  price numeric(14,2) not null check (price >= 0),
  price_date date not null default current_date,
  created_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_supplier_prices_supplier on public.supplier_prices (supplier_id, item);

-- ---------- مستندات الموردين (اسم + تاريخ انتهاء) ----------
create table if not exists public.supplier_documents (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.suppliers(id) on delete cascade,
  doc_name text not null check (length(trim(doc_name)) > 0),
  expiry_date date,
  created_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_supplier_docs_supplier on public.supplier_documents (supplier_id);

-- ---------- سجل واتساب (تسجيل الرسايل داخل السيستم) ----------
create table if not exists public.whatsapp_messages (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  direction text not null check (direction in ('in','out')),
  body text not null check (length(trim(body)) > 0),
  created_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_wa_customer on public.whatsapp_messages (customer_id, created_at);

-- ---------- منع التعديل والحذف للسجلات دي ----------
create or replace function public.forbid_change()
returns trigger language plpgsql as $$
begin
  raise exception 'السجل ده مش بيتعدل ولا بيتحذف';
end;
$$;

drop trigger if exists trg_wa_immutable on public.whatsapp_messages;
create trigger trg_wa_immutable before update or delete on public.whatsapp_messages
for each row execute function public.forbid_change();

-- ---------- التدقيق ----------
drop trigger if exists trg_sup_prices_audit on public.supplier_prices;
create trigger trg_sup_prices_audit after insert or update or delete on public.supplier_prices
for each row execute function public.audit_row();

drop trigger if exists trg_sup_docs_audit on public.supplier_documents;
create trigger trg_sup_docs_audit after insert or update or delete on public.supplier_documents
for each row execute function public.audit_row();

drop trigger if exists trg_wa_audit on public.whatsapp_messages;
create trigger trg_wa_audit after insert on public.whatsapp_messages
for each row execute function public.audit_row();

-- ---------- RLS ----------
alter table public.supplier_prices    enable row level security;
alter table public.supplier_documents enable row level security;
alter table public.whatsapp_messages  enable row level security;

drop policy if exists sprice_select on public.supplier_prices;
create policy sprice_select on public.supplier_prices for select to authenticated
using (public.my_role() in ('gm','purchasing','accounting','store'));

drop policy if exists sprice_insert on public.supplier_prices;
create policy sprice_insert on public.supplier_prices for insert to authenticated
with check (public.my_role() in ('gm','purchasing') and created_by = public.my_employee_id());

drop policy if exists sprice_delete on public.supplier_prices;
create policy sprice_delete on public.supplier_prices for delete to authenticated
using (public.my_role() in ('gm','purchasing'));

drop policy if exists sdoc_select on public.supplier_documents;
create policy sdoc_select on public.supplier_documents for select to authenticated
using (public.my_role() in ('gm','purchasing','accounting','store'));

drop policy if exists sdoc_insert on public.supplier_documents;
create policy sdoc_insert on public.supplier_documents for insert to authenticated
with check (public.my_role() in ('gm','purchasing') and created_by = public.my_employee_id());

drop policy if exists sdoc_delete on public.supplier_documents;
create policy sdoc_delete on public.supplier_documents for delete to authenticated
using (public.my_role() in ('gm','purchasing'));

drop policy if exists wa_select on public.whatsapp_messages;
create policy wa_select on public.whatsapp_messages for select to authenticated
using (public.my_role() in ('gm','sales'));

drop policy if exists wa_insert on public.whatsapp_messages;
create policy wa_insert on public.whatsapp_messages for insert to authenticated
with check (public.my_role() in ('gm','sales') and created_by = public.my_employee_id());

-- ---------- استيراد الموردين من CSV ----------
-- بيرجع عدد اللي اتضاف واللي اتخطى وسبب كل صف متخطي. الحد 2000 صف.
create or replace function public.import_suppliers(p_rows jsonb)
returns table (inserted int, skipped int, errors jsonb)
language plpgsql security definer set search_path = public as $$
declare
  r jsonb;
  v_ins int := 0;
  v_skip int := 0;
  v_err jsonb := '[]'::jsonb;
  v_phone text;
  v_tax text;
  v_types text[];
  v_brands text[];
  v_rating int;
  v_lead int;
  v_credit numeric;
  v_name text;
  v_allowed text[] := array['ألواح','انفرترات','بطاريات','هياكل','كابلات','طلمبات','لوازم كهرباء','خدمات','تسويق / إعلانات','أخرى'];
begin
  if coalesce(public.my_role(), '') not in ('gm','purchasing') then raise exception 'forbidden'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'البيانات لازم تكون قائمة'; end if;
  if jsonb_array_length(p_rows) > 2000 then raise exception 'الحد الأقصى 2000 صف في المرة'; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_name := trim(coalesce(r->>'name', ''));
    v_phone := public.normalize_phone(r->>'phone');
    v_tax := nullif(trim(coalesce(r->>'tax', '')), '');

    if v_name = '' then
      v_skip := v_skip + 1; v_err := v_err || jsonb_build_object('row', r, 'reason', 'الاسم التجاري مطلوب'); continue;
    end if;
    if v_phone !~ '^01[0125][0-9]{8}$' then
      v_skip := v_skip + 1; v_err := v_err || jsonb_build_object('row', r, 'reason', 'رقم الهاتف غلط'); continue;
    end if;

    -- الأنواع بتتفصل بـ |، ولازم نوع واحد صحيح على الأقل
    select coalesce(array_agg(t), '{}') into v_types
      from (select distinct trim(x) as t from unnest(string_to_array(coalesce(r->>'types',''), '|')) as x) s
      where t = any(v_allowed);
    if coalesce(array_length(v_types, 1), 0) = 0 then
      v_skip := v_skip + 1; v_err := v_err || jsonb_build_object('row', r, 'reason', 'لازم نوع مورد صحيح واحد على الأقل'); continue;
    end if;

    if exists (select 1 from public.suppliers s
               where public.normalize_phone(s.phone) = v_phone
                  or (v_tax is not null and s.tax_number = v_tax)) then
      v_skip := v_skip + 1; v_err := v_err || jsonb_build_object('row', r, 'reason', 'المورد موجود قبل كده (نفس الهاتف أو الرقم الضريبي)'); continue;
    end if;

    select coalesce(array_agg(distinct trim(x)) filter (where trim(x) <> ''), '{}') into v_brands
      from unnest(regexp_split_to_array(coalesce(r->>'brands',''), '[,|]')) as x;

    v_rating := case when (r->>'rating') ~ '^[1-5]$' then (r->>'rating')::int else 3 end;
    v_lead   := case when (r->>'lead_days') ~ '^[0-9]{1,3}$' then (r->>'lead_days')::int else 0 end;
    v_credit := case when (r->>'credit') ~ '^[0-9]+(\.[0-9]+)?$' then (r->>'credit')::numeric else 0 end;

    insert into public.suppliers (name, contact_person, phone, email, address, governorate,
                                  tax_number, commercial_register, types, brands, payment_terms,
                                  credit_limit, currency, rating, lead_days, notes)
    values (v_name, nullif(trim(coalesce(r->>'person','')),''), v_phone, nullif(trim(coalesce(r->>'email','')),''),
            nullif(trim(coalesce(r->>'address','')),''), nullif(trim(coalesce(r->>'gov','')),''),
            v_tax, nullif(trim(coalesce(r->>'reg','')),''), v_types, v_brands,
            nullif(trim(coalesce(r->>'terms','')),''), v_credit,
            coalesce(nullif(trim(coalesce(r->>'currency','')),''), 'EGP'), v_rating, v_lead,
            nullif(trim(coalesce(r->>'notes','')),''));
    v_ins := v_ins + 1;
  end loop;

  return query select v_ins, v_skip, v_err;
end;
$$;

-- ---------- ملاحظة ----------
-- قيمة الفرصة في لوحة المبيعات بتتحسب من آخر عرض سعر صادر للعميل (الواجهة).
-- الرسايل المسجلة في whatsapp_messages للتتبع فقط، والإرسال الفعلي لواتساب لسه يدوي.

-- ---------- خامات مبدئية للمنظومات (أمثلة، بدون أسعار. راجع الداتاشيت وحدد الأسعار) ----------
insert into public.catalog_items (system_type, category, description) values
  ('on-grid','panel','لوح شمسي 580 وات (مثال)'),
  ('on-grid','inv','انفرتر On-Grid 10 كيلو (مثال)'),
  ('on-grid','mount','هيكل ألومنيوم للأسطح (مثال)'),
  ('on-grid','prot','لوحة حماية وقواطع DC/AC (مثال)'),
  ('on-grid','cable','كابلات DC وAC (مثال)'),
  ('on-grid','install','أعمال التركيب (حسب الاتفاق)'),
  ('on-grid','transport','النقل والتوريد (حسب الاتفاق)'),
  ('off-grid','panel','لوح شمسي 580 وات (مثال)'),
  ('off-grid','inv','انفرتر Off-Grid 5 كيلو (مثال)'),
  ('off-grid','batt','بطارية ليثيوم 5 كيلووات ساعة (مثال)'),
  ('off-grid','mount','هيكل ألومنيوم للأسطح (مثال)'),
  ('off-grid','prot','لوحة حماية وقواطع DC/AC (مثال)'),
  ('off-grid','cable','كابلات DC وAC (مثال)'),
  ('off-grid','install','أعمال التركيب (حسب الاتفاق)'),
  ('off-grid','transport','النقل والتوريد (حسب الاتفاق)'),
  ('hybrid','panel','لوح شمسي 580 وات (مثال)'),
  ('hybrid','inv','انفرتر هجين 5 كيلو (مثال)'),
  ('hybrid','batt','بطارية ليثيوم 5 كيلووات ساعة (مثال)'),
  ('hybrid','mount','هيكل ألومنيوم للأسطح (مثال)'),
  ('hybrid','prot','لوحة حماية وقواطع DC/AC (مثال)'),
  ('hybrid','cable','كابلات DC وAC (مثال)'),
  ('hybrid','install','أعمال التركيب (حسب الاتفاق)'),
  ('hybrid','transport','النقل والتوريد (حسب الاتفاق)'),
  ('pumping','panel','لوح شمسي 550 وات (مثال)'),
  ('pumping','pinv','انفرتر ضخ 3 حصان (مثال)'),
  ('pumping','pump','طلمبة غاطسة 2 حصان (مثال)'),
  ('pumping','mount','هيكل مجلفن أرضي (مثال)'),
  ('pumping','prot','لوحة حماية وقواطع (مثال)'),
  ('pumping','cable','كابلات DC وAC (مثال)'),
  ('pumping','install','أعمال التركيب (حسب الاتفاق)'),
  ('pumping','transport','النقل والتوريد (حسب الاتفاق)')
on conflict do nothing;
