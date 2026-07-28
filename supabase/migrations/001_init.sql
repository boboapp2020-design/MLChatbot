-- =====================================================================
--  ML Expert AI — Database Schema
--  รันไฟล์นี้ใน Supabase Dashboard → SQL Editor → New query → Run
-- =====================================================================

create extension if not exists vector;      -- pgvector : เวกเตอร์ค้นเชิงความหมาย
create extension if not exists pg_trgm;     -- trigram  : ค้นคำไทยแบบ substring
create extension if not exists "uuid-ossp";


-- ---------------------------------------------------------------------
-- 1) ทะเบียนโมดูลผู้เชี่ยวชาญ
-- ---------------------------------------------------------------------
create table if not exists modules (
  id            text primary key,           -- 'crushing', 'quality', ...
  name_th       text not null,
  name_en       text not null,
  icon          text,                        -- emoji สำหรับ UI
  persona       text not null,               -- system prompt เฉพาะโมดูล
  keywords      text[] default '{}',         -- คำใบ้ให้ router
  sort_order    int  default 100,
  is_active     boolean default true,
  created_at    timestamptz default now()
);


-- ---------------------------------------------------------------------
-- 2) เอกสารต้นฉบับ
-- ---------------------------------------------------------------------
create table if not exists kb_documents (
  id            uuid primary key default uuid_generate_v4(),
  module_id     text not null references modules(id) on delete cascade,
  title         text not null,
  doc_type      text not null default 'MANUAL',
                -- SOP | WI | MANUAL | BOOK | STANDARD | REPORT | PID | LAB | FAQ
  doc_code      text,                        -- 'WI-BOIL-001'
  source_path   text,
  lang          text default 'mixed',        -- th | en | mixed
  revision      text default '1.0',
  effective_date date,
  metadata      jsonb default '{}'::jsonb,
  created_at    timestamptz default now()
);

create index if not exists idx_docs_module on kb_documents(module_id);
create index if not exists idx_docs_code   on kb_documents(doc_code);


-- ---------------------------------------------------------------------
-- 3) ท่อนความรู้ (chunks) — หน่วยที่ถูกค้นและอ้างอิง
-- ---------------------------------------------------------------------
create table if not exists kb_chunks (
  id              bigserial primary key,
  document_id     uuid not null references kb_documents(id) on delete cascade,
  module_id       text not null,             -- denormalized เพื่อกรองเร็ว
  chunk_index     int  not null default 0,
  section         text,                      -- '5.2 การปรับ pH'
  page_ref        text,                      -- 'หน้า 14' | 'Section 2.5'
  content         text not null,
  token_estimate  int  default 0,

  -- เวกเตอร์ 1024 มิติ (voyage-3 / voyage-multilingual-2)
  -- ปล่อย null ได้ → ระบบจะ fallback ไปใช้ lexical search อย่างเดียว
  embedding       vector(1024),

  -- ดัชนีคำ: 'simple' จับศัพท์อังกฤษ/รหัสเอกสาร/ตัวเลขได้ดี
  fts             tsvector generated always as
                    (to_tsvector('simple', coalesce(section,'') || ' ' || content)) stored,

  created_at      timestamptz default now()
);

create index if not exists idx_chunks_module on kb_chunks(module_id);
create index if not exists idx_chunks_doc    on kb_chunks(document_id);
create index if not exists idx_chunks_fts    on kb_chunks using gin(fts);
create index if not exists idx_chunks_trgm   on kb_chunks using gin(content gin_trgm_ops);

-- สร้าง ivfflat หลังมีข้อมูลแล้วเท่านั้น (ดูขั้นตอนท้ายไฟล์)


-- ---------------------------------------------------------------------
-- 4) ประวัติการสนทนา + log สำหรับตรวจสอบย้อนหลัง
-- ---------------------------------------------------------------------
create table if not exists chat_sessions (
  id          uuid primary key default uuid_generate_v4(),
  title       text,
  user_ref    text,
  created_at  timestamptz default now()
);

create table if not exists chat_messages (
  id            bigserial primary key,
  session_id    uuid references chat_sessions(id) on delete cascade,
  role          text not null,               -- user | assistant
  content       text not null,
  module_id     text,
  router_trace  jsonb,                       -- เจตนา/โมดูลที่เลือก/คำค้นที่ขยาย
  citations     jsonb,                       -- [{n, doc_code, title, section, page_ref}]
  confidence    numeric(4,3),
  usage         jsonb,                       -- token ที่ใช้แต่ละขั้น
  latency_ms    int,
  created_at    timestamptz default now()
);

create index if not exists idx_msg_session on chat_messages(session_id, created_at);


-- =====================================================================
--  5) HYBRID SEARCH  —  Vector + Full-text + Trigram รวมด้วย RRF
-- =====================================================================
-- p_modules : กรองเฉพาะโมดูลที่ router เลือก (null = ค้นทุกโมดูล)
-- p_embedding : ส่ง null ได้ → ระบบจะใช้เฉพาะ lexical (โหมด demo ไม่ต้องมี embedding key)
-- ---------------------------------------------------------------------
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
-- ค้นเชิงความหมาย
vec as (
  select c.id,
         1 - (c.embedding <=> p_embedding) as sim,
         row_number() over (order by c.embedding <=> p_embedding) as rank
  from kb_chunks c
  where p_embedding is not null
    and c.embedding is not null
    and (p_modules is null or c.module_id = any(p_modules))
  order by c.embedding <=> p_embedding
  limit p_limit * 3
),
-- ค้นด้วยคำ (ดีกับรหัสเอกสาร ศัพท์เทคนิค ตัวเลข)
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
-- ค้นแบบ substring (จำเป็นสำหรับภาษาไทยที่ไม่มีช่องว่างระหว่างคำ)
trg as (
  select c.id,
         similarity(c.content, p_query) as sim,
         row_number() over (order by similarity(c.content, p_query) desc) as rank
  from kb_chunks c
  where (p_modules is null or c.module_id = any(p_modules))
    and c.content % p_query
  limit p_limit * 3
),
-- Reciprocal Rank Fusion : รวมอันดับจากทั้งสาม retriever
fused as (
  select id,
         sum(w) as rrf,
         max(sim_v) as sim_v
  from (
    select id, 1.0 / (p_rrf_k + rank) as w, sim as sim_v from vec
    union all
    select id, 1.0 / (p_rrf_k + rank) as w, null::float   from lex
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


-- =====================================================================
--  6) สถิติคลังความรู้ (ใช้แสดงบนหน้า UI)
-- =====================================================================
create or replace function kb_stats()
returns table (
  module_id   text,
  name_th     text,
  icon        text,
  documents   bigint,
  chunks      bigint,
  embedded    bigint
)
language sql stable
as $$
  select m.id,
         m.name_th,
         m.icon,
         count(distinct d.id),
         count(c.id),
         count(c.embedding)
  from modules m
  left join kb_documents d on d.module_id = m.id
  left join kb_chunks    c on c.document_id = d.id
  where m.is_active
  group by m.id, m.name_th, m.icon, m.sort_order
  order by m.sort_order;
$$;


-- =====================================================================
--  7) Row Level Security
-- =====================================================================
alter table modules      enable row level security;
alter table kb_documents enable row level security;
alter table kb_chunks    enable row level security;

-- อ่านได้ทุกคน (anon) — เขียนได้เฉพาะ service_role
create policy "read modules"   on modules      for select using (true);
create policy "read documents" on kb_documents for select using (true);
create policy "read chunks"    on kb_chunks    for select using (true);


-- =====================================================================
--  8) หลังนำเข้าข้อมูลแล้ว ค่อยรันบรรทัดนี้เพื่อสร้าง vector index
--     (สร้างก่อนมีข้อมูลจะได้ index ที่คุณภาพแย่)
-- =====================================================================
-- create index idx_chunks_embedding on kb_chunks
--   using ivfflat (embedding vector_cosine_ops) with (lists = 100);
