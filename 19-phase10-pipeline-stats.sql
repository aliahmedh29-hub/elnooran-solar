-- ============================================================
-- المرحلة 10 (تكملة): إحصائيات المبيعات على السيرفر
-- شغّلها بعد 18-phase10-supplier-files.sql. الملف idempotent.
-- ليه: الواجهة كانت بتحسب الإحصائيات على أول 1000 عميل بس. الدالة دي بتحسبها على كل العملاء.
-- القرارات:
--  • قيمة الفرصة = أكبر عرض سعر صادر للعميل (نفس الواجهة).
--  • المدير والمبيعات بس. الحسابات والمخزن مايشوفوش الفرص.
--  • الدالة security definer، فلازم الفحص جواها.
-- ============================================================

create or replace function public.pipeline_stats()
returns table (stage text, customers int, value numeric, late_followups int)
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.my_role(), '') not in ('gm','sales') then
    raise exception 'forbidden';
  end if;
  return query
  select c.stage,
         count(*)::int,
         coalesce(sum(coalesce(q.v, 0)), 0)::numeric,
         count(*) filter (where c.next_followup is not null
                          and c.stage in ('lead','quoted')
                          and c.next_followup < (now() at time zone 'Africa/Cairo')::date)::int
  from public.customers c
  left join lateral (
    select max(d.total) as v
    from public.documents d
    where d.customer_id = c.id and d.doc_type = 'quote' and d.status = 'issued'
  ) q on true
  group by c.stage;
end;
$$;
