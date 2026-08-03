-- =====================================================================
--  ML Expert AI — แก้เพดานคะแนนความมั่นใจที่ต่ำกว่าเกณฑ์ผ่าน
-- ---------------------------------------------------------------------
--  อาการ: แชทบอทตอบว่า "หลักฐานไม่พอ" แทบทุกคำถาม แม้คำถามง่ายๆ
--         อย่าง "GHPs คืออะไร" ทั้งที่ Codex GHP ฉบับเต็ม 77 ท่อนอยู่ในคลัง
--         และค้นก็เจอเอกสารถูกต้อง
--
--  การวัดจริง (3 ส.ค. 2569)
--    "GHPs คืออะไร"          -> top1 similarity 0.342
--    "GHP"                    -> top1 similarity 0.263
--    "ค่า pH น้ำอ้อยใสควรเท่าไร" -> top1 similarity 0.342
--    ไม่มีคำถามใดที่ similarity เกิน 0.35 เลย
--
--  สาเหตุ: 006 ตั้งตัวหารของ similarity ไว้ที่ 3.8/(k+1)
--    ซึ่งคือคะแนน RRF สูงสุดเมื่อ chunk ติดอันดับ 1 ครบ **ทั้งสี่ขา**
--      เวกเตอร์ 1.0 + คำอังกฤษ 1.0 + n-gram ไทย 1.3 + substring 0.5 = 3.8
--    แต่ **ขาเวกเตอร์ยังว่างเปล่า** เพราะคลังยังไม่มี embedding สักท่อน
--    (ตรวจแล้ว: kb_chunks ที่ embedding not null = 0 จาก 5,781)
--    เพดานที่เป็นไปได้จริงจึงเหลือ 2.8/(k+1) ไม่ใช่ 3.8/(k+1)
--    ทำให้ similarity ถูกหารด้วยตัวเลขที่ใหญ่เกินจริง 36%
--
--  ผลต่อความมั่นใจ: สูตรคือ 0.45*top1 + 0.25*top3 + 0.20*coverage + 0.10*agreement
--    ค่าดีที่สุดที่ระบบทำได้ = 0.45(0.34) + 0.25(0.33) + 0.20(1) + 0.10(1) = 0.536
--    เกณฑ์ผ่านคือ 0.55 -> **เพดานอยู่ต่ำกว่าประตู 0.014** จึงไม่มีทางผ่านเลย
--
--  วิธีแก้: ให้ตัวหารสะท้อนขาที่ร่วมจริง
--    ถ้าไม่ได้ส่ง embedding มา (หรือคลังยังไม่มี) ใช้ 2.8 แทน 3.8
--    ถ้ามี embedding ใช้ 3.8 ตามเดิม
--  ผลที่คาด: top1 ของคำถามเดิมขยับจาก 0.34 เป็นราว 0.46
--            ความมั่นใจขยับจาก 0.48 เป็นราว 0.62 ซึ่งผ่านเกณฑ์
--
--  หมายเหตุ: นี่คือการแก้สเกลให้ตรงกับความจริง ไม่ใช่การปั๊มคะแนนให้ผ่าน
--            เมื่อสร้าง embedding แล้วขาเวกเตอร์จะกลับมาและตัวหารกลับเป็น 3.8 เอง
--            ท่อนที่ไม่เกี่ยวข้องยังได้คะแนนต่ำเหมือนเดิม เพราะ RRF ของมันต่ำอยู่แล้ว
--
--  รันหลัง 007_thai_grams_fix.sql
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
language sql stable as $$
  with
  vec as (
    select c.id, 1 - (c.embedding <=> p_embedding) as sim,
           row_number() over (order by c.embedding <=> p_embedding) as rank
    from kb_chunks c
    where p_embedding is not null
      and c.embedding is not null
      and (p_modules is null or c.module_id = any(p_modules))
    order by c.embedding <=> p_embedding
    limit 60
  ),
  lex as (
    select c.id,
           row_number() over (
             order by ts_rank_cd(c.fts, websearch_to_tsquery('simple', p_query)) desc
           ) as rank
    from kb_chunks c
    where c.fts @@ websearch_to_tsquery('simple', p_query)
      and (p_modules is null or c.module_id = any(p_modules))
    limit 60
  ),
  lex_th as (
    select c.id,
           row_number() over (
             order by ts_rank_cd(c.fts_th, plainto_tsquery('simple', th_grams(p_query))) desc
           ) as rank
    from kb_chunks c
    where th_grams(p_query) <> ''
      and c.fts_th @@ plainto_tsquery('simple', th_grams(p_query))
      and (p_modules is null or c.module_id = any(p_modules))
    limit 60
  ),
  trg as (
    select c.id,
           row_number() over (order by similarity(c.content, p_query) desc) as rank
    from kb_chunks c
    where c.content % p_query
      and (p_modules is null or c.module_id = any(p_modules))
    limit 60
  ),
  fused as (
    select id, sum(w) as rrf, max(sim_v) as sim_v
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
  select c.id, c.document_id, c.module_id, c.section, c.page_ref, c.content,
         d.title, d.doc_code, d.doc_type,
         greatest(
           coalesce(f.sim_v, 0),
           -- ตัวหาร = คะแนน RRF สูงสุดที่เป็นไปได้ "จากขาที่ร่วมจริง"
           -- มี embedding: 1.0+1.0+1.3+0.5 = 3.8 · ไม่มี: 1.0+1.3+0.5 = 2.8
           least(1.0, f.rrf / ((case when p_embedding is null then 2.8 else 3.8 end)
                               / (p_rrf_k + 1)))
         )::float as similarity,
         f.rrf::float
  from fused f
  join kb_chunks c    on c.id = f.id
  join kb_documents d on d.id = c.document_id
  order by f.rrf desc
  limit p_limit;
$$;
