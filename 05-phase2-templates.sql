-- ============================================================
-- المرحلة 2 - الجزء 3: قوالب المستندات (فواتير، عروض، ملحق، عقد، إيصال)
-- شغّلها بعد 04-phase2-actions.sql. الملف idempotent.
-- المصدر: عقد توريد وتركيب v5 + ملحق رقم (1) + نماذج الفاتورة وعرض السعر والإيصال.
-- ============================================================

-- ---------- أعمدة إضافية للمستندات والبنود ----------
alter table public.documents
  add column if not exists due_date date,
  add column if not exists valid_days int,
  add column if not exists advance_pct numeric(5,2),
  add column if not exists capacity_kw numeric(10,2),
  add column if not exists extra jsonb not null default '{}'::jsonb;

alter table public.document_lines
  add column if not exists unit text,
  add column if not exists notes text;

-- ---------- بنود العقد في بيانات الشركة (قابلة للتعديل من المدير) ----------
alter table public.company_settings
  add column if not exists clauses jsonb not null default '[]'::jsonb;

-- البنود الافتراضية من عقد v5. بتتكتب مرة واحدة لو الحقل فاضي
update public.company_settings
set clauses = $json$[
 {"title":"موضوع العقد","body":"يتعهد الطرف الأول بتوريد وتركيب منظومة الطاقة الشمسية المحددة في الملحق المرفق بهذا العقد، وفق المواصفات والكميات والأسعار المتفق عليها كتابياً، ويلتزم الطرف الثاني بالدفع وفق الشروط الواردة في هذا العقد."},
 {"title":"الملحق الفني والبنود","body":"تُحدد أنواع الألواح والانفرتر والبطارية (إن وُجدت) وأسعارها والكميات وأي خدمات إضافية في جدول منفصل يُعد جزءاً لا يتجزأ من هذا العقد، ولا يُعتد بأي بند خارجه."},
 {"title":"الثمن وطريقة الدفع","body":"1. إجمالي ثمن العقد: {{total}} جنيه مصري، شامل / غير شامل الضرائب كما هو مذكور في الملحق.\n2. يُدفع الثمن على الدفعات المتفق عليها في جدول السداد.\n3. لا يُعتبر الدفع مستلماً إلا بإيصال أو فاتورة صادرة من الطرف الأول."},
 {"title":"التسليم والتركيب","body":"1. يلتزم الطرف الأول بتسليم المعدات والتركيب خلال المدة المتفق عليها، ويبدأ احتسابها من تاريخ استلام أول دفعة من الطرف الثاني.\n2. يوفر الطرف الثاني مكاناً صالحاً للتركيب، ويتحمل تكلفة أي أعمال إنشائية غير مشمولة في هذا العقد.\n3. يوقّع الطرفان على محضر استلام بعد اكتمال التركيب والتشغيل التجريبي."},
 {"title":"الضمان","body":"1. تخضع الألواح والانفرتر والبطارية لضمان الشركة المصنعة أو الوكيل المعتمد، ومدة الضمان كما هي مذكورة في الملحق.\n2. يغطي الضمان عيوب التصنيع فقط، ولا يشمل الأعطال الناتجة عن سوء الاستخدام أو الصيانة غير المعتمدة أو الكوارث الطبيعية أو التغيرات الكهربائية في الشبكة.\n3. يلتزم الطرف الأول بالإصلاح أو الاستبدال وفق شروط الضمان المعتمدة، ولا يتحمل أي التزام تجاه أي أعطال خارج نطاق الضمان."},
 {"title":"التزامات الطرف الثاني","body":"يلتزم الطرف الثاني على نفقته الخاصة بالآتي:\n1. تجهيز الموقع: تسوية الأرض وإزالة أي عوائق تمنع العمل، وتوفير مكان مناسب لتخزين المعدات أثناء التركيب.\n2. الأعمال الإنشائية: تنفيذ أي أعمال أو أساسات أو قواعد خرسانية مطلوبة لتثبيت المنظومة المحددة، وتوفير مواد البناء اللازمة لها.\n3. المسارات والكابلات: توفير المواسير والمجاري الخاصة بمرور الكابلات، وأي تمديدات كهربائية داخلية غير مشمولة في العقد.\n4. الكهرباء والمياه: توفير مصدر الكهرباء والمياه اللازم لأعمال التركيب والتشغيل التجريبي.\n5. الإقامة والإعاشة: توفير مكان إقامة آمن ومناسب لفريق التركيب، ووجبات طعام ومياه شرب للعمال طوال مدة التركيب، إذا كانت الأعمال تتم خارج مقر إقامتهم المعتادة.\nوفي حال تأخر الطرف الثاني في تنفيذ أي من هذه الالتزامات وتسبب ذلك في تعطل فريق العمل، يتحمل الطرف الثاني التكاليف الإضافية الناتجة عن هذا التعطل، ويمتد موعد التسليم بقدر مدة التأخير."},
 {"title":"التأخير والقوة القاهرة","body":"لا يُعد أي طرف مخلاً بالعقد إذا تأخر بسبب قوة قاهرة خارجة عن إرادته، ويُخطر الطرف الآخر بذلك كتابياً خلال {{force_days}} أيام من وقوعها."},
 {"title":"الفسخ","body":"يحق لأي طرف فسخ العقد في حال إخلال الطرف الآخر بالتزام جوهري بعد إنذار كتابي بمدة {{cure_days}} أياماً دون تصحيح. ويُسوّى الحساب بين الطرفين خلال 30 يوماً من تاريخ الفسخ. وفي حال الفسخ بسبب الطرف الثاني، يحق للطرف الأول الاحتفاظ بالدفعات المدفوعة مقابل الأعمال المنفذة والمعدات المستلمة."},
 {"title":"الضرائب والرسوم","body":"يتحمل الطرف الثاني أي ضرائب أو رسوم حكومية تُفرض على المنظومة بعد توقيع العقد، ما لم يُنص على خلاف ذلك في الملحق. ويلتزم الطرف الأول بإصدار فاتورة ضريبية متى كان ذلك مطلوباً نظامياً."},
 {"title":"ملكية المعدات حتى السداد","body":"تبقى ملكية المعدات والأجهزة المركبة للطرف الأول إلى أن يُسدد الطرف الثاني الثمن كاملاً، وللطرف الأول الحق في استعادتها في حال التخلف عن السداد بعد إنذار كتابي."},
 {"title":"التأخر في السداد","body":"في حال تأخر الطرف الثاني عن أي دفعة في موعدها لمدة تزيد على {{late_days}} أيام، يحق للطرف الأول إيقاف أعمال التركيب حتى السداد، ويُحتسب على المبلغ المتأخر فائدة تأخير بنسبة {{late_pct}}% سنوياً."},
 {"title":"الصيانة الدورية","body":"الصيانة الدورية على نفقة الطرف الثاني، وتُحدد أنواعها وتكلفتها في الملحق، ويتحمل الطرف الثاني تكلفة الصيانة وأي قطع غيار أو مكونات تُستبدل أثناء الصيانة، ما لم تكن مشمولة بالضمان المنصوص عليه في البند الخامس."},
 {"title":"الاستبدال بمنتج مكافئ","body":"إذا توقف إنتاج أي مكون من المكونات المحددة في الملحق، يحق للطرف الأول استبداله بمكون آخر مكافئ في الأداء والجودة بعد إخطار الطرف الثاني كتابياً، دون أن يؤثر ذلك على إجمالي الثمن."},
 {"title":"السرية","body":"يلتزم كل طرف بعدم إفشاء المعلومات التجارية أو الفنية أو الشخصية للطرف الآخر التي يطلع عليها بسبب هذا العقد، إلا إذا كان الإفشاء مطلوباً نظامياً."},
 {"title":"التنازل عن العقد","body":"لا يجوز لأي طرف التنازل عن هذا العقد أو أي حق من حقوقه لغيره دون موافقة كتابية مسبقة من الطرف الآخر."},
 {"title":"الإخطارات","body":"تُرسل جميع الإخطارات والمراسلات الخاصة بالعقد كتابياً إلى العناوين المذكورة في صدر العقد، أو على البريد الإلكتروني الموضح بجانب كل طرف، ويُعد الإخطار مستلماً عند وصوله إلى العنوان المذكور."},
 {"title":"الشرط الجزائي","body":"إذا فسخ الطرف الثاني العقد دون سبب مشروع، يلتزم بدفع مبلغ يعادل {{penalty_pct}}% من إجمالي الثمن كتعويض مقدَّر، دون الإخلال بحق الطرف الأول في استرداد المصروفات الفعلية."},
 {"title":"الاستقلالية والتعديل","body":"إذا قضت محكمة مختصة ببطلان أي بند من هذا العقد، تظل بقية البنود سارية ومنتجة لآثارها."},
 {"title":"المسؤولية","body":"لا تتجاوز مسؤولية الطرف الأول في أي حال إجمالي الثمن المدفوع فعلياً بموجب هذا العقد، ولا يكون مسؤولاً عن الخسائر غير المباشرة."},
 {"title":"تسوية النزاعات والقانون الواجب التطبيق","body":"يخضع هذا العقد لقوانين جمهورية مصر العربية، وتختص محاكم {{court}} بنظر أي نزاع ينشأ عنه، بعد محاولة التسوية الودية لمدة {{nego_days}} أيام."},
 {"title":"أحكام عامة","body":"يُعد هذا العقد وملاحقه الاتفاق الكامل بين الطرفين، ولا يُعتد بأي تعديل إلا إذا كان مكتوباً وموقعاً من الطرفين. حُرر هذا العقد من نسختين أصليتين، لكل طرف نسخة."}
]$json$::jsonb
where id = 1 and clauses = '[]'::jsonb;

-- ---------- حارس المستند: الحقول الجديدة ثابتة بعد الحفظ أيضاً ----------
create or replace function public.documents_guard()
returns trigger language plpgsql as $$
begin
  if (new.doc_number, new.doc_type, new.doc_date, new.customer_id, new.customer_name,
      new.subtotal, new.discount, new.tax_total, new.total, new.paid,
      new.due_date, new.valid_days, new.advance_pct, new.capacity_kw, new.extra)
     is distinct from
     (old.doc_number, old.doc_type, old.doc_date, old.customer_id, old.customer_name,
      old.subtotal, old.discount, old.tax_total, old.total, old.paid,
      old.due_date, old.valid_days, old.advance_pct, old.capacity_kw, old.extra) then
    raise exception 'المستند ماينفعش يتعدل بعد الحفظ. الإلغاء بس';
  end if;
  return new;
end;
$$;

-- ---------- إنشاء المستند (نسخة 2: تدعم كل الأنواع) ----------
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

  select full_name, phone, address, system_type into v_cust
  from public.customers
  where id = nullif(p_payload->>'customer_id', '')::uuid;

  -- الإجماليات بتتحسب قبل الإدخال، علشان المستند يتكتب مرة واحدة (الحارس بيمنع التعديل بعد الحفظ)
  select coalesce(sum(coalesce(qty,0) * coalesce(unit_price,0)), 0),
         coalesce(sum(coalesce(qty,0) * coalesce(unit_price,0) * coalesce(tax_rate,0) / 100), 0)
    into v_sub, v_tax
  from jsonb_to_recordset(p_lines) as l(qty numeric, unit_price numeric, tax_rate numeric);

  v_num := public.next_doc_number(v_prefix, v_year);

  insert into public.documents (
    doc_type, doc_number, doc_date, customer_id, customer_name, customer_phone,
    customer_address, system_type, discount, paid, notes, created_by,
    due_date, valid_days, advance_pct, capacity_kw, extra,
    subtotal, tax_total, total
  ) values (
    p_type, v_num,
    coalesce(nullif(p_payload->>'doc_date','')::date, current_date),
    nullif(p_payload->>'customer_id','')::uuid,
    coalesce(v_cust.full_name, nullif(p_payload->>'manual_name',''), 'عميل'),
    coalesce(v_cust.phone, nullif(p_payload->>'customer_phone','')),
    coalesce(v_cust.address, nullif(p_payload->>'customer_address','')),
    v_cust.system_type,
    v_disc, v_paid, nullif(p_payload->>'notes',''), v_emp,
    nullif(p_payload->>'due_date','')::date,
    nullif(p_payload->>'valid_days','')::int,
    nullif(p_payload->>'advance_pct','')::numeric,
    nullif(p_payload->>'capacity_kw','')::numeric,
    coalesce(p_payload->'extra', '{}'::jsonb),
    v_sub, v_tax, v_sub + v_tax - v_disc
  ) returning id into v_id;

  insert into public.document_lines (document_id, position, category, description, unit, qty, unit_price, tax_rate, notes)
  select v_id, ord::int,
         nullif(l->>'category',''),
         l->>'description',
         nullif(l->>'unit',''),
         (l->>'qty')::numeric,
         coalesce((l->>'unit_price')::numeric, 0),
         coalesce((l->>'tax_rate')::numeric, 0),
         nullif(l->>'notes','')
  from jsonb_array_elements(p_lines) with ordinality as t(l, ord);

  return query select v_id, v_num;
end;
$$;
