-- ============================================================
-- المرحلة 3: الخزينة والحسابات (الجزء الأول)
-- شغّلها بعد 05-phase2-templates.sql. الملف idempotent.
-- القرارات اللي اتاخدت هنا (تقدر تغيّرها):
--  • القيد مايتعدلش ولا يتحذف أبداً. التصحيح بقيد عكسي (reverse_entry).
--  • الفترة المقفولة بتتمنع على الكل، والمدير بيفتحها بتغيير تاريخ القفل.
--  • الرصيد مايبقاش بالسالب، والتحقق بيتم على السيرفر وتحت قفل الصف.
--  • الحركات بتتسجل بالدوال بس، مفيش إدخال مباشر في الجدول.
-- ============================================================

-- ---------- الحسابات ----------
create table if not exists public.accounts (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  kind text not null default 'other' check (kind in ('cash','bank','ewallet','instapay','fawry','other')),
  opening_balance numeric(14,2) not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- القيود (دفتر الحركات) ----------
create table if not exists public.ledger (
  id uuid primary key default gen_random_uuid(),
  entry_date date not null default current_date,
  account_id uuid not null references public.accounts(id) on delete restrict,
  direction text not null check (direction in ('in','out')),
  amount numeric(14,2) not null check (amount > 0),
  category text not null,
  party_type text not null default 'none' check (party_type in ('none','customer','supplier','employee')),
  party_id uuid,
  document_id uuid references public.documents(id) on delete restrict,
  note text,
  transfer_group uuid,
  is_fee boolean not null default false,
  reverses uuid references public.ledger(id),
  created_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_ledger_account on public.ledger (account_id, entry_date);
create index if not exists idx_ledger_party on public.ledger (party_type, party_id);

-- ---------- قفل الفترات ----------
create table if not exists public.period_locks (
  id uuid primary key default gen_random_uuid(),
  locked_until date not null,
  set_by uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---------- رصيد الحساب ----------
create or replace function public.account_balance(p_account uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
begin
  -- الرصيد معلومة مالية: المدير والحسابات بس (الدالة security definer فلازم الفحص هنا)
  if coalesce(public.my_role(), '') not in ('gm','accounting') then
    raise exception 'forbidden';
  end if;
  return (
    select a.opening_balance + coalesce((
      select sum(case when l.direction = 'in' then l.amount else -l.amount end)
      from public.ledger l where l.account_id = a.id
    ), 0)
    from public.accounts a where a.id = p_account
  );
end;
$$;

-- ---------- تسجيل قيد (الطريقة الوحيدة لإضافة حركة) ----------
create or replace function public.post_entry(
  p_account uuid, p_direction text, p_amount numeric, p_category text,
  p_party_type text, p_party_id uuid, p_note text, p_date date,
  p_document uuid default null, p_group uuid default null, p_fee boolean default false,
  p_reverses uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.my_role();
  v_emp uuid := public.my_employee_id();
  v_lock date;
  v_date date := coalesce(p_date, current_date);
  v_bal numeric;
  v_id uuid;
begin
  if coalesce(v_role, '') not in ('gm','accounting') or v_emp is null then
    raise exception 'forbidden';
  end if;
  if p_direction not in ('in','out') then raise exception 'bad direction'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'المبلغ لازم يكون أكبر من صفر'; end if;
  if coalesce(trim(p_category), '') = '' then raise exception 'البند مطلوب'; end if;
  if coalesce(p_party_type, 'none') <> 'none' and p_party_id is null then
    raise exception 'لازم تحدد الطرف (عميل أو مورد أو موظف)';
  end if;

  select locked_until into v_lock from public.period_locks order by created_at desc limit 1;
  if v_lock is not null and v_date <= v_lock then
    raise exception 'الفترة دي مقفولة لحد %. المدير بس يفتحها', v_lock;
  end if;

  -- قفل صف الحساب علشان لو اتنين بيسجلوا في نفس اللحظة الرصيد يفضل صح
  perform 1 from public.accounts where id = p_account and is_active for update;
  if not found then raise exception 'الحساب مش موجود أو موقوف'; end if;

  if p_direction = 'out' then
    v_bal := public.account_balance(p_account);
    if v_bal < p_amount then
      raise exception 'الرصيد مش كفاية. المتاح: %', v_bal;
    end if;
  end if;

  insert into public.ledger (entry_date, account_id, direction, amount, category, party_type, party_id,
                             document_id, note, transfer_group, is_fee, reverses, created_by)
  values (v_date, p_account, p_direction, p_amount, p_category, coalesce(p_party_type, 'none'), p_party_id,
          p_document, p_note, p_group, coalesce(p_fee, false), p_reverses, v_emp)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------- تحويل بين حسابين (برسوم اختيارية على المُرسِل) ----------
create or replace function public.transfer_funds(
  p_from uuid, p_to uuid, p_amount numeric, p_fee numeric, p_note text, p_date date
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  g uuid := gen_random_uuid();
begin
  if p_from = p_to then raise exception 'الحسابين لازم يكونوا مختلفين'; end if;
  perform public.post_entry(p_from, 'out', p_amount, 'تحويل بين حسابات', 'none', null, p_note, p_date, null, g, false);
  perform public.post_entry(p_to, 'in', p_amount, 'تحويل بين حسابات', 'none', null, p_note, p_date, null, g, false);
  if coalesce(p_fee, 0) > 0 then
    perform public.post_entry(p_from, 'out', p_fee, 'رسوم تحويل', 'none', null, p_note, p_date, null, g, true);
  end if;
  return g;
end;
$$;

-- ---------- تصحيح قيد: قيد عكسي مش حذف ----------
create or replace function public.reverse_entry(p_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  e record;
  v_new uuid;
begin
  select * into e from public.ledger where id = p_id;
  if not found then raise exception 'القيد مش موجود'; end if;
  if e.reverses is not null then raise exception 'ماينفعش نعكس قيد تصحيح'; end if;
  if exists (select 1 from public.ledger where reverses = p_id) then raise exception 'القيد ده اتعكس قبل كده'; end if;

  v_new := public.post_entry(
    e.account_id,
    case when e.direction = 'in' then 'out' else 'in' end,
    e.amount,
    'تصحيح: ' || e.category,
    e.party_type, e.party_id,
    'عكس قيد ' || e.id::text,
    null, null, e.transfer_group, e.is_fee, e.id
  );
  return v_new;
end;
$$;

-- ---------- قفل الفترة (المدير بس) ----------
create or replace function public.set_period_lock(p_until date)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.my_role(), '') <> 'gm' then raise exception 'المدير العام بس'; end if;
  insert into public.period_locks (locked_until, set_by)
  values (p_until, public.my_employee_id());
end;
$$;

-- ---------- ملخص حسابات العميل: مفوتر ومحصّل وباقي ----------
create or replace view public.customer_balances
with (security_invoker = true) as
select
  c.id as customer_id,
  c.full_name,
  coalesce((select sum(d.total) from public.documents d
            where d.customer_id = c.id and d.doc_type = 'invoice' and d.status = 'issued'), 0) as invoiced,
  coalesce((select sum(case when l.direction = 'in' then l.amount else -l.amount end)
            from public.ledger l where l.party_type = 'customer' and l.party_id = c.id), 0) as received
from public.customers c;

-- ---------- منع تعديل أو حذف القيود ----------
create or replace function public.ledger_immutable()
returns trigger language plpgsql as $$
begin
  raise exception 'القيود مش بتتعدل ولا بتتحذف. استخدم قيد تصحيح';
end;
$$;

drop trigger if exists trg_ledger_immutable on public.ledger;
create trigger trg_ledger_immutable before update or delete on public.ledger
for each row execute function public.ledger_immutable();

-- ---------- Audit ----------
drop trigger if exists trg_accounts_audit on public.accounts;
create trigger trg_accounts_audit after insert or update or delete on public.accounts
for each row execute function public.audit_row();

drop trigger if exists trg_ledger_audit on public.ledger;
create trigger trg_ledger_audit after insert on public.ledger
for each row execute function public.audit_row();

-- ---------- RLS ----------
alter table public.accounts     enable row level security;
alter table public.ledger       enable row level security;
alter table public.period_locks enable row level security;

drop policy if exists acc_select on public.accounts;
create policy acc_select on public.accounts for select to authenticated
using (public.my_role() in ('gm','accounting'));

drop policy if exists acc_write on public.accounts;
create policy acc_write on public.accounts for all to authenticated
using (public.my_role() = 'gm') with check (public.my_role() = 'gm');

drop policy if exists ledger_select on public.ledger;
create policy ledger_select on public.ledger for select to authenticated
using (public.my_role() in ('gm','accounting'));
-- مفيش policy للإدخال ولا التعديل ولا الحذف: كله بالدوال

drop policy if exists locks_select on public.period_locks;
create policy locks_select on public.period_locks for select to authenticated
using (public.my_role() in ('gm','accounting'));

-- ---------- ملاحظات ----------
-- 1) تحصيل العميل: post_entry(حساب, 'in', المبلغ, 'تحصيل عميل', 'customer', customer_id, ...)
-- 2) مبلغ 'paid' في المستند (من المرحلة 2) بيتسجل وقت الإصدار بس. التحصيل الفعلي من القيود.
--    ده لازم نقرر لاحقاً: هنشيل حقل paid من المستند ولا نخليه للعرض فقط.
-- 3) المرحلة الجاية: العُهد، ورواتب الموظفين، وفواتير الموردين، والضريبة، وقائمة الدخل.
