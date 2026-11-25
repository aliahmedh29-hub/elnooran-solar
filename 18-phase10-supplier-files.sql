-- ============================================================
-- المرحلة 10 (تكملة): ملفات مستندات الموردين
-- شغّلها بعد 17-phase10-parity.sql. الملف idempotent.
-- القرارات:
--  • الملف بيتخزن في bucket خاص اسمه supplier-docs (مش public). الوصول بروابط موقتة من السيرفر.
--  • الحد 5 ميجا، وأنواع PDF وJPG وPNG بس.
--  • القراءة لنفس أدوار المستندات. الرفع والحذف للمدير والمشتريات بس.
--  • الجزء الخاص بالـ storage بيشتغل بس لو schema الـ storage موجودة (Supabase فيها دايماً).
-- ============================================================

alter table public.supplier_documents add column if not exists file_path text;
alter table public.supplier_documents add column if not exists file_name text;

do $$
begin
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then
    raise notice 'schema storage مش موجودة هنا. الـ bucket هيتعمل على Supabase.';
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('supplier-docs', 'supplier-docs', false, 5242880,
          array['application/pdf','image/jpeg','image/png'])
  on conflict (id) do update set
    public = false,
    file_size_limit = 5242880,
    allowed_mime_types = array['application/pdf','image/jpeg','image/png'];

  execute 'drop policy if exists sdocfiles_select on storage.objects';
  execute 'create policy sdocfiles_select on storage.objects for select to authenticated
           using (bucket_id = ''supplier-docs'' and public.my_role() in (''gm'',''purchasing'',''accounting'',''store''))';

  execute 'drop policy if exists sdocfiles_insert on storage.objects';
  execute 'create policy sdocfiles_insert on storage.objects for insert to authenticated
           with check (bucket_id = ''supplier-docs'' and public.my_role() in (''gm'',''purchasing''))';

  execute 'drop policy if exists sdocfiles_delete on storage.objects';
  execute 'create policy sdocfiles_delete on storage.objects for delete to authenticated
           using (bucket_id = ''supplier-docs'' and public.my_role() in (''gm'',''purchasing''))';
end $$;
