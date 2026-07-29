-- =====================================================================
--  ML Expert AI — ค้นหาภาษาไทยฝั่งเซิร์ฟเวอร์
-- ---------------------------------------------------------------------
--  ปัญหา: Postgres แยกคำไทยไม่ออก เพราะภาษาไทยไม่มีช่องว่างระหว่างคำ
--    to_tsvector('simple','ค่า pH หลังทำใสน้ำอ้อยควรอยู่เท่าไร')
--      -> 'ค่า':1 'ph':2 'หลังทำใสน้ำอ้อยควรอยู่เท่าไร':3
--    ก้อนยาวก้อนนั้นไม่มีทางตรงกับอะไรในเอกสารเลย
--    ขาค้นด้วยคำ (full-text) จึงใช้ไม่ได้กับภาษาไทย เหลือแค่ trigram
--    ผลคือคำถามไทยได้ความมั่นใจ 13% ทั้งที่ฝั่งเบราว์เซอร์ได้ 84%
--
--  วิธีแก้: ใช้วิธีเดียวกับฝั่งเบราว์เซอร์ — ตัดข้อความไทยเป็น 4-gram
--    "หลังทำใส" -> "หลัง ลังท ังทำ งทำใ ทำใส"
--    แล้วให้ Postgres ทำ full-text บน gram เหล่านั้นแทน
--
--  รันหลัง 001_init.sql
-- =====================================================================

begin;

-- ── ตัวตัดคำไทยเป็น n-gram ────────────────────────────────────────────
-- ต้องเป็น immutable เพราะจะเอาไปใช้ใน generated column
-- คำที่สั้นกว่า 4 ตัวอักษร (เช่น "ค่า" "ปูน") เก็บทั้งคำ ไม่งั้นจะหายไปเฉยๆ
create or replace function th_grams(txt text) returns text
language sql immutable parallel safe as $fn$
  select coalesce(string_agg(g, ' '), '')
  from (
    select case
             when length(r.run) <= 4 then r.run
             else substring(r.run from i for 4)
           end as g
    from (select (regexp_matches(lower(coalesce(txt,'')), '[ก-๙]{2,}', 'g'))[1] as run) r,
         lateral generate_series(1, greatest(1, length(r.run) - 3)) as i
  ) x
$fn$;

-- ── คอลัมน์ดัชนีคำไทย ────────────────────────────────────────────────
alter table kb_chunks
  add column if not exists fts_th tsvector
  generated always as (to_tsvector('simple', th_grams(coalesce(section,'') || ' ' || content))) stored;

create index if not exists idx_chunks_fts_th on kb_chunks using gin(fts_th);

commit;

-- ── ค้นหาแบบผสม เพิ่มขาที่ 4 ──────────────────────────────────────────
-- เดิมมี 3 ขา: เวกเตอร์ + คำ (อังกฤษ) + substring
-- เพิ่มขาไทยแบบ n-gram ซึ่งเป็นขาหลักเมื่อผู้ใช้พิมพ์ไทย
-- หัวฟังก์ชันต้องเหมือน 001_init.sql ทุกตัวอักษร ไม่งั้น Edge Function เรียกไม่ได้
-- (kb_chunks.id เป็น bigint ไม่ใช่ uuid — เคยเขียนผิดตรงนี้มาแล้ว)
create or replace function hybrid_search (
  p_query      text,
  p_embedding  vector(1024) default null,
  p_modules    text[]       default null,
  p_limit      int          default 20,
  p_rrf_k      int          default 60
)
returns table (
  chunk_id     bigint,
  document_id  uuid,
  module_id    text,
  section      text,
  page_ref     text,
  content      text,
  doc_title    text,
  doc_code     text,
  doc_type     text,
  similarity   float,
  rrf_score    float
)
language sql stable
as $$
with
q_th as (select th_grams(p_query) as g),

-- ค้นเชิงความหมาย (ทำงานเมื่อมี embedding เท่านั้น)
vec as (
  select c.id,
         1 - (c.embedding <=> p_embedding) as sim,
         row_number() over (order by c.embedding <=> p_embedding) as rank
  from kb_chunks c
  where p_embedding is not null
    and c.embedding is not null
    and (p_modules is null or c.module_id = any(p_modules))
  limit p_limit * 3
),
-- ค้นด้วยคำ: ดีกับอังกฤษ รหัสเอกสาร ตัวเลข
lex as (
  select c.id,
         ts_rank_cd(c.fts, websearch_to_tsquery('simple', p_query)) as sim,
         row_number() over (
           order by ts_rank_cd(c.fts, websearch_to_tsquery('simple', p_query)) desc
         ) as rank
  from kb_chunks c
  where (p_modules is null or c.module_id = any(p_modules))
    and c.fts @@ websearch_to_tsquery('simple', p_query)
  limit p_limit * 3
),
-- ค้นคำไทยแบบ n-gram (ขาหลักสำหรับคำถามภาษาไทย)
-- ต้องใช้ to_tsquery ต่อด้วย | ไม่ใช่ websearch_to_tsquery
-- เพราะ websearch ตีความช่องว่างเป็น "และ" คือต้องมีครบทุก gram ถึงจะแมตช์
-- คำถามหนึ่งประโยคแตกได้ 20-30 gram ไม่มีเอกสารไหนมีครบ ผลลัพธ์จึงเป็นศูนย์เสมอ
-- ใช้ | (หรือ) แล้วให้ ts_rank_cd จัดอันดับตามจำนวน gram ที่ตรงแทน
lex_th as (
  select c.id,
         ts_rank_cd(c.fts_th, q.tsq) as sim,
         row_number() over (order by ts_rank_cd(c.fts_th, q.tsq) desc) as rank
  from kb_chunks c,
       (select to_tsquery('simple', replace(g, ' ', ' | ')) as tsq
        from q_th where g <> '') q
  where (p_modules is null or c.module_id = any(p_modules))
    and c.fts_th @@ q.tsq
  limit p_limit * 3
),
-- ค้นแบบ substring
trg as (
  select c.id,
         similarity(c.content, p_query) as sim,
         row_number() over (order by similarity(c.content, p_query) desc) as rank
  from kb_chunks c
  where (p_modules is null or c.module_id = any(p_modules))
    and c.content % p_query
  limit p_limit * 3
),
-- รวมอันดับด้วย Reciprocal Rank Fusion
-- ขาไทยได้น้ำหนัก 1.3 เพราะเป็นขาที่ตรงที่สุดเมื่อคำถามเป็นไทย
fused as (
  select id,
         sum(w) as rrf,
         max(sim_v) as sim_v
  from (
    select id, 1.0 / (p_rrf_k + rank) as w, sim as sim_v from vec
    union all
    select id, 1.0 / (p_rrf_k + rank) as w, null::float   from lex
    union all
    select id, 1.3 / (p_rrf_k + rank) as w, null::float   from lex_th
    union all
    select id, 0.5 / (p_rrf_k + rank) as w, null::float   from trg
  ) u
  group by id
)
select c.id,
       c.document_id,
       c.module_id,
       c.section,
       c.page_ref,
       c.content,
       d.title,
       d.doc_code,
       d.doc_type,
       coalesce(f.sim_v, 0)::float as similarity,
       f.rrf::float                as rrf_score
from fused f
join kb_chunks   c on c.id = f.id
join kb_documents d on d.id = c.document_id
order by f.rrf desc
limit p_limit;
$$;
