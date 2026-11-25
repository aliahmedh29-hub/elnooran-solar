-- ============================================================
-- المرحلة 6: المبيعات الكاملة (مراحل، ترقية تلقائية، بيع سريع، فلاتر)
-- شغّلها بعد 12-phase5-complete.sql. الملف idempotent.
-- قرارات اتاخدت من غير رد منك (تقدر تغيّرها):
--  • المرحلة "استفسار" (lead) بتتحول لـ "عرض سعر" (quoted) تلقائياً بعد 30 يوم من غير بيع.
--    الترقية دي بتتشغل بدالة، ومفيش جدولة تلقائية دلوقتي (ممكن نضيف pg_cron بعدين).
--  • البيع السريع = إصدار فاتورة، والمرحلة بتتحول لـ "تم البيع" (won). التحصيل بيفضل عند الحسابات.
--  • "مكتمل" = الفاتورة اتحصّلت بالكامل. "غير مكتمل" = لسه فيها متبقي أو مفيش فاتورة.
-- ============================================================

-- ---------- ترقية الاستفسارات القديمة لعرض سعر ----------
create or replace function public.advance_stale_leads()
returns int
language plpgsql security definer set search_path = public as $$
declare
  n int;
begin
  if coalesce(public.my_role(), '') not in ('gm','sales') then raise exception 'forbidden'; end if;
  update public.customers
     set stage = 'quoted', stage_changed_at = now()
   where stage = 'lead' and stage_changed_at < now() - interval '30 days';
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ---------- تغيير المرحلة يدوياً ----------
create or replace function public.set_customer_stage(p_customer uuid, p_stage text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.my_role(), '') not in ('gm','sales') then raise exception 'forbidden'; end if;
  if p_stage not in ('lead','quoted','won','lost') then raise exception 'مرحلة غير صحيحة'; end if;
  update public.customers
     set stage = p_stage, stage_changed_at = now()
   where id = p_customer;
  if not found then raise exception 'العميل مش موجود'; end if;
end;
$$;

-- ---------- بيع سريع: فاتورة + تحصيل في خطوة واحدة ----------
-- المبيعات بتصدر الفاتورة بس. التحصيل بيفضل عند الحسابات من الخزينة (المبيعات مش بتسجل قبض).
drop function if exists public.quick_sale(uuid, jsonb, numeric, uuid, numeric, text);

create or replace function public.quick_sale(
  p_customer uuid, p_lines jsonb, p_discount numeric, p_note text
) returns table (doc_id uuid, doc_number text)
language plpgsql security definer set search_path = public as $$
declare
  v_res record;
begin
  if coalesce(public.my_role(), '') not in ('gm','sales') then raise exception 'forbidden'; end if;

  select * into v_res from public.create_document('invoice', jsonb_build_object(
    'customer_id', p_customer, 'discount', coalesce(p_discount, 0), 'notes', p_note), p_lines);

  update public.customers set stage = 'won', stage_changed_at = now() where id = p_customer;

  return query select v_res.doc_id, v_res.doc_number;
end;
$$;

-- ---------- عرض المبيعات للفلاتر ----------
create or replace view public.sales_deals
with (security_invoker = true) as
select
  d.id as document_id,
  d.doc_number,
  d.doc_date,
  extract(month from d.doc_date)::int as sale_month,
  extract(day from d.doc_date)::int as sale_day,
  d.customer_id,
  d.customer_name,
  d.system_type,
  d.total,
  public.invoice_received(d.id) as received,
  case when public.invoice_received(d.id) >= d.total
       then 'completed' else 'not_completed' end as status
from public.documents d
where d.doc_type = 'invoice' and d.status = 'issued';

-- ---------- ملاحظة ----------
-- 1) الفلاتر (نوع المنظومة، الحالة، الشهر، اليوم) بتتعمل على sales_deals في الواجهة.
-- 2) لو عايزين الترقية التلقائية تشتغل يومياً: pg_cron يشغّل advance_stale_leads (لو متاح في المشروع).
