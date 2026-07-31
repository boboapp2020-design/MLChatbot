-- =====================================================================
--  ML Expert AI — แก้ค่าความมั่นใจตันที่ 30%
-- ---------------------------------------------------------------------
--  อาการ: โหมด Supabase ตอบว่า "หลักฐานไม่พอ" ทุกคำถาม ความมั่นใจ 30% เป๊ะ
--         ทั้งที่ค้นเจอเอกสารที่ถูกต้องแล้ว
--
--  สาเหตุ: hybrid_search คืนค่า similarity จาก "ขาเวกเตอร์" ขาเดียว
--            coalesce(f.sim_v, 0)   -- sim_v มาจาก vec เท่านั้น
--          แต่ท่อนความรู้ในระบบยังไม่มี embedding สักท่อน
--          ขาเวกเตอร์จึงไม่คืนอะไรเลย -> similarity = 0 ทุกท่อน
--
--          ฝั่ง Edge Function คิดความมั่นใจแบบนี้
--            0.45*top1 + 0.25*top3 + 0.20*coverage + 0.10*agreement
--          สองก้อนแรกรวมกัน 70% ผูกกับ similarity ที่เป็นศูนย์
--          เพดานจึงเหลือ 30% พอดี ต่ำกว่าเกณฑ์ 55% เสมอ
--          ไม่ว่าคลังความรู้จะดีแค่ไหนก็ไม่มีทางตอบได้
--
--  วิธีแก้: ให้ similarity ตกกลับไปใช้คะแนน RRF ที่ปรับสเกลแล้ว
--          เมื่อไม่มี embedding — RRF สะท้อนว่าท่อนนั้นติดอันดับต้นๆ
--          ของขาไหนบ้าง ซึ่งเป็นสัญญาณคุณภาพที่ใช้แทนกันได้
--          ถ้าวันหลังสร้าง embedding แล้ว greatest() จะเลือกค่าเวกเตอร์เอง
--          โดยไม่ต้องแก้อะไรอีก
--
--  ตัวหาร 3.8/(p_rrf_k+1) คือคะแนน RRF สูงสุดที่เป็นไปได้
--  (ติดอันดับ 1 ครบทั้ง 4 ขา: 1.0 + 1.0 + 1.3 + 0.5 = 3.8)
--  ผลคือท่อนที่ตรงมากได้ราว 0.7-0.8 ท่อนที่เฉียดๆ ได้ราว 0.2
--  ยังแยกดีออกจากแย่ได้ ไม่ใช่การปั๊มคะแนนให้ผ่านทุกอัน
--
--  รันหลัง 005_thai_search.sql
-- =====================================================================

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
       -- มี embedding -> ใช้ค่าเวกเตอร์  ไม่มี -> ใช้ RRF ที่ปรับสเกลแล้ว
       greatest(
         coalesce(f.sim_v, 0),
         least(1.0, f.rrf / (3.8 / (p_rrf_k + 1)))
       )::float                  as similarity,
       f.rrf::float              as rrf_score
from fused f
join kb_chunks   c on c.id = f.id
join kb_documents d on d.id = c.document_id
order by f.rrf desc
limit p_limit;
$$;
