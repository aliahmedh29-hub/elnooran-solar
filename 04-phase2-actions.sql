-- ============================================================
-- المرحلة 2 - الجزء 2: تحويل عرض السعر لفاتورة + ربط التحويل
-- شغّلها بعد 03-phase2-documents.sql. الملف idempotent.
-- ============================================================

alter table public.documents
  add column if not exists converted_from uuid references public.documents(id);

create or replace function public.convert_quote_to_invoice(p_quote_id uuid)
returns table (doc_id uuid, doc_number text)
language plpgsql security definer set search_path = public as $$
declare
  v_role text := public.my_role();
  v_emp uuid := public.my_employee_id();
  q record;
  v_lines jsonb;
  v_payload jsonb;
  res record;
begin
  if coalesce(v_role, '') not in ('gm','sales') or v_emp is null then
    raise exception 'forbidden';
  end if;

  select * into q from public.documents
   where id = p_quote_id and doc_type = 'quote' and status = 'issued';
  if not found then raise exception 'quote not found'; end if;

  if exists (select 1 from public.documents where converted_from = p_quote_id) then
    raise exception 'quote already converted';
  end if;

  select jsonb_agg(jsonb_build_object(
           'category', category, 'description', description,
           'qty', qty, 'unit_price', unit_price, 'tax_rate', tax_rate)
         order by position)
    into v_lines
  from public.document_lines where document_id = p_quote_id;

  v_payload := jsonb_build_object(
    'customer_id', q.customer_id,
    'manual_name', q.customer_name,
    'doc_date', current_date,
    'discount', q.discount,
    'notes', 'محوّلة من ' || q.doc_number
  );

  select * into res from public.create_document('invoice', v_payload, v_lines);
  update public.documents set converted_from = p_quote_id where id = res.doc_id;

  return query select res.doc_id, res.doc_number;
end;
$$;

-- حارس: المستند بعد الحفظ مايتعدلش إلا الحالة (إلغاء) وربط التحويل.
create or replace function public.documents_guard()
returns trigger language plpgsql as $$
begin
  if (new.doc_number, new.doc_type, new.doc_date, new.customer_id, new.customer_name,
      new.subtotal, new.discount, new.tax_total, new.total, new.paid)
     is distinct from
     (old.doc_number, old.doc_type, old.doc_date, old.customer_id, old.customer_name,
      old.subtotal, old.discount, old.tax_total, old.total, old.paid) then
    raise exception 'المستند ماينفعش يتعدل بعد الحفظ. الإلغاء بس';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_documents_guard on public.documents;
create trigger trg_documents_guard before update on public.documents
for each row execute function public.documents_guard();

-- الإلغاء بيتم بتغيير الحالة (gm بس، عن طريق policy docs_update في الجزء 1)
-- ومفيش حذف للمستندات.
