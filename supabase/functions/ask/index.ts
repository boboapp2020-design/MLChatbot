// =====================================================================
//  ML Expert AI — RAG Pipeline (Supabase Edge Function / Deno)
// ---------------------------------------------------------------------
//  POST /functions/v1/ask
//  body: { question, session_id?, module_hint?, lang?, history? }
//  ตอบกลับเป็น SSE:  event: meta  -> router trace + citations + confidence
//                    event: delta -> ข้อความคำตอบทีละส่วน
//                    event: done  -> สรุป usage
//
//  Secrets ที่ต้องตั้งใน Supabase (Settings → Edge Functions → Secrets):
//    ANTHROPIC_API_KEY   (บังคับ)
//    VOYAGE_API_KEY      (ไม่บังคับ — ถ้าไม่มีระบบจะใช้ lexical search อย่างเดียว)
// =====================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// ── ค่าคงที่ ──────────────────────────────────────────────────────────
// ชื่อโมเดลตั้งทับได้ด้วย secret เพราะแต่ละเจ้าใช้ชื่อคนละแบบ
// และผู้ให้บริการเปลี่ยนชื่อรุ่นบ่อย ไม่ควรฝังตายในโค้ด
const DEFAULT_MODELS: Record<string, { router: string; rerank: string; answer: string }> = {
  anthropic:  { router: 'claude-haiku-4-5',  rerank: 'claude-haiku-4-5',  answer: 'claude-opus-5' },
  gemini:     { router: 'gemini-3.5-flash-lite', rerank: 'gemini-3.5-flash-lite', answer: 'gemini-3.6-flash' },
  groq:       { router: 'llama-3.1-8b-instant',  rerank: 'llama-3.1-8b-instant',  answer: 'qwen/qwen3-32b' },
  openrouter: { router: 'google/gemma-4-31b-it:free', rerank: 'google/gemma-4-31b-it:free', answer: 'qwen/qwen3.7-flash' },
  deepseek:   { router: 'deepseek-chat',     rerank: 'deepseek-chat',     answer: 'deepseek-chat' },
};
const EMBED_MODEL     = 'voyage-3';

const RETRIEVE_K      = 20;   // ดึงมาก่อน rerank
const CONTEXT_K       = 6;    // ส่งเข้า LLM จริง
const MIN_CONFIDENCE  = 0.55; // ต่ำกว่านี้ = หลักฐานไม่พอ ห้ามสรุปคำตอบ

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// รับได้ทั้ง LLM_API_KEY (ชื่อใหม่) และ ANTHROPIC_API_KEY (ของเดิม ไม่ต้องแก้ถ้าใช้ Claude อยู่)
const LLM_KEY    = Deno.env.get('LLM_API_KEY') ?? Deno.env.get('ANTHROPIC_API_KEY') ?? '';
const VOYAGE_KEY = Deno.env.get('VOYAGE_API_KEY') ?? '';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

// ── ชนิดข้อมูล ────────────────────────────────────────────────────────
interface RouterResult {
  intent:      string;
  modules:     string[];
  department:  string | null;
  process:     string | null;
  equipment:   string | null;
  doc_types:   string[];
  queries:     string[];
  complexity:  'simple' | 'moderate' | 'complex';
  needs_kb:    boolean;
  in_scope:    boolean;
}

interface Chunk {
  chunk_id:   number;
  module_id:  string;
  section:    string;
  page_ref:   string;
  content:    string;
  doc_title:  string;
  doc_code:   string;
  doc_type:   string;
  similarity: number;
  rrf_score:  number;
}


// =====================================================================
//  เรียก LLM — รองรับหลายผู้ให้บริการ
//  ---------------------------------------------------------------------
//  ทุกเจ้ายกเว้น Anthropic ใช้รูปแบบเดียวกับ OpenAI (/chat/completions)
//  จึงเขียนตัวเรียกแค่ 2 แบบก็ครอบได้หมด
//  เลือกด้วย secret ชื่อ LLM_PROVIDER — ไม่ตั้งก็ใช้ anthropic ตามเดิม
// =====================================================================
const PROVIDER_BASE: Record<string, string> = {
  anthropic:  'https://api.anthropic.com/v1',
  gemini:     'https://generativelanguage.googleapis.com/v1beta/openai',
  groq:       'https://api.groq.com/openai/v1',
  openrouter: 'https://openrouter.ai/api/v1',
  deepseek:   'https://api.deepseek.com',
};

const PROVIDER  = (Deno.env.get('LLM_PROVIDER') ?? 'anthropic').toLowerCase();
const IS_CLAUDE = PROVIDER === 'anthropic';
const LLM_BASE  = (Deno.env.get('LLM_BASE_URL') ?? PROVIDER_BASE[PROVIDER] ?? '').replace(/\/$/, '');

const M = DEFAULT_MODELS[PROVIDER] ?? DEFAULT_MODELS.anthropic;
const MODEL_ROUTER = Deno.env.get('MODEL_ROUTER') ?? M.router;
const MODEL_RERANK = Deno.env.get('MODEL_RERANK') ?? M.rerank;
const MODEL_ANSWER = Deno.env.get('MODEL_ANSWER') ?? M.answer;

interface LlmReq {
  model:      string;
  system:     string;
  messages:   { role: string; content: string }[];
  maxTokens:  number;
  stream?:    boolean;
  schema?:    Record<string, unknown>;   // ขอผลลัพธ์เป็น JSON ตามโครงที่กำหนด
  effort?:    'low' | 'medium' | 'high';
  cacheSystem?: boolean;
  reasoning?: string;   // ทับค่า REASONING เฉพาะคำขอนี้ (ใช้กับ Gemini)
  timeoutMs?: number;   // ยอมรอผู้ให้บริการนานสุดเท่าไร ก่อนเลิกแล้วบอกผู้ใช้
}

// Gemini 3 เปิดโหมดคิดก่อนตอบไว้เป็นค่าเริ่มต้น ทำให้กว่าตัวอักษรแรกจะออกมาใช้เวลานาน
// (วัดจริง 12.7 วินาทีที่ผู้ใช้เห็นเป็นจอเปล่า) คำถามที่มีเอกสารอ้างอิงครบอยู่แล้ว
// ไม่ต้องให้โมเดลคิดลึก ตั้งเป็น low ไว้ ปรับได้ด้วย secret ถ้าอยากได้คำตอบลึกขึ้น
const REASONING = Deno.env.get('REASONING_EFFORT') ?? 'low';

async function callLLM(r: LlmReq, betas: string[] = []) {
  let url: string, headers: Record<string, string>, body: Record<string, unknown>;

  if (IS_CLAUDE) {
    url = `${LLM_BASE}/messages`;
    headers = {
      'content-type':      'application/json',
      'x-api-key':         LLM_KEY,
      'anthropic-version': '2023-06-01',
    };
    if (betas.length) headers['anthropic-beta'] = betas.join(',');
    body = {
      model: r.model, max_tokens: r.maxTokens, stream: r.stream ?? false,
      system: r.cacheSystem
        ? [{ type: 'text', text: r.system, cache_control: { type: 'ephemeral' } }]
        : r.system,
      messages: r.messages,
    };
    if (r.schema) body.output_config = { format: { type: 'json_schema', schema: r.schema } };
    else if (r.effort) body.output_config = { effort: r.effort };
  } else {
    url = `${LLM_BASE}/chat/completions`;
    headers = { 'content-type': 'application/json', 'authorization': `Bearer ${LLM_KEY}` };
    // OpenRouter ขอให้ระบุที่มาของคำขอ ไม่ใส่บางโมเดลฟรีจะถูกปฏิเสธ
    if (PROVIDER === 'openrouter') {
      headers['HTTP-Referer'] = Deno.env.get('SITE_URL') ?? 'https://ml-expert-ai.local';
      headers['X-Title'] = 'ML Expert AI';
    }
    body = {
      model: r.model, max_tokens: r.maxTokens, stream: r.stream ?? false,
      messages: [{ role: 'system', content: r.system }, ...r.messages],
    };
    if (r.schema) {
      body.response_format = {
        type: 'json_schema',
        json_schema: { name: 'result', strict: true, schema: r.schema },
      };
    }
    // ส่งเฉพาะ Gemini — เจ้าอื่นบางรุ่นไม่รู้จักพารามิเตอร์นี้แล้วตอบ 400
    const eff = r.reasoning ?? REASONING;
    if (PROVIDER === 'gemini' && eff !== 'default') body.reasoning_effort = eff;
  }

  // ถ้าผู้ให้บริการค้างไม่ตอบ Supabase จะฆ่าฟังก์ชันทิ้งที่ 150 วินาที
  // ผู้ใช้ได้ HTTP 546 ที่ไม่บอกอะไรเลย ตั้งเวลาเองแล้วโยน error ที่อ่านรู้เรื่องแทน
  const ac = new AbortController();
  const timeoutMs = r.timeoutMs ?? 60000;
  const timer = setTimeout(() => ac.abort(), timeoutMs);
  let res: Response;
  try {
    res = await fetch(url, { method: 'POST', headers, body: JSON.stringify(body), signal: ac.signal });
  } catch (e) {
    if ((e as Error).name === 'AbortError') {
      throw new Error(`${PROVIDER} ไม่ตอบกลับภายใน ${timeoutMs / 1000} วินาที ` +
        `— มักเกิดจากโควตาของผู้ให้บริการเต็ม หรือระบบของเขาขัดข้อง`);
    }
    throw e;
  } finally {
    clearTimeout(timer);
  }
  if (!res.ok) {
    const text = await res.text();
    const hint = res.status === 429
      ? ' — โควตาของผู้ให้บริการเต็มแล้ว รอให้รอบโควตารีเซ็ต หรือเปลี่ยนไปใช้เจ้าอื่น'
      : '';
    throw new Error(`${PROVIDER} ${res.status}${hint}: ${text.slice(0, 400)}`);
  }
  return res;
}

// ดึงข้อความจากคำตอบแบบไม่สตรีม — โครงสร้างต่างกันคนละแบบ
function firstText(msg: any): string {
  if (Array.isArray(msg.content)) {                    // Anthropic
    for (const b of msg.content) if (b.type === 'text') return b.text;
    return '';
  }
  return msg.choices?.[0]?.message?.content ?? '';     // OpenAI-compatible
}

// อ่านสตรีมของทั้งสองรูปแบบ
function parseDelta(ev: any): { text?: string; stop?: string; usage?: any } {
  if (IS_CLAUDE) {
    if (ev.type === 'content_block_delta' && ev.delta?.type === 'text_delta') return { text: ev.delta.text };
    if (ev.type === 'message_delta') return { stop: ev.delta?.stop_reason, usage: ev.usage };
    if (ev.type === 'message_start')  return { usage: ev.message?.usage };
    return {};
  }
  const ch = ev.choices?.[0];
  return {
    text:  ch?.delta?.content ?? undefined,
    stop:  ch?.finish_reason === 'length' ? 'max_tokens' : (ch?.finish_reason ?? undefined),
    usage: ev.usage,
  };
}


// =====================================================================
//  ขั้นที่ 1 — AI ROUTER
//  เข้าใจเจตนา เลือกโมดูล ขยายคำค้น  (Haiku = เร็วและถูก)
// =====================================================================
async function runRouter(
  question: string,
  modules: { id: string; name_th: string; keywords: string[] }[],
  history: { role: string; content: string }[],
  fixedModule?: string,
): Promise<RouterResult> {

  // ถ้าผู้ใช้เลือกห้องไว้แล้ว ไม่ต้องส่งทะเบียนโมดูลทั้ง 15 ตัวไปให้โมเดลอ่าน
  // เหลือแค่ตัวเดียว prompt สั้นลงมาก router จึงตอบเร็วขึ้น
  const shown = fixedModule ? modules.filter((m) => m.id === fixedModule) : modules;
  const catalog = (shown.length ? shown : modules)
    .map((m) => `- ${m.id} (${m.name_th}): ${m.keywords.slice(0, 14).join(', ')}`)
    .join('\n');

  const convo = history.slice(-4)
    .map((h) => `${h.role === 'user' ? 'ผู้ใช้' : 'ระบบ'}: ${h.content.slice(0, 300)}`)
    .join('\n');

  const system = `คุณคือ AI Router ของแพลตฟอร์มผู้เชี่ยวชาญโรงงานน้ำตาล
หน้าที่: อ่านคำถามแล้วตัดสินว่าควรค้นคลังความรู้ของโมดูลใด และควรค้นด้วยคำอะไร

โมดูลที่มี:
${catalog}

กติกา:
- เลือก modules ให้น้อยที่สุดเท่าที่ครอบคลุมคำถาม (ปกติ 1 ตัว, สูงสุด 2 เมื่อคำถามคาบเกี่ยวจริง)
- queries คือคำค้นสำหรับค้นเอกสาร ให้แตกเป็น 2-4 ชุด ผสมทั้งไทยและอังกฤษ
  ใส่ศัพท์เทคนิคเฉพาะทางที่น่าจะปรากฏในเอกสาร (เช่น "imbibition % fiber", "pol % bagasse")
  ไม่ใช่แค่ทวนคำถามเดิม
- needs_kb = false เฉพาะเมื่อเป็นการทักทาย ขอบคุณ หรือถามว่าระบบทำอะไรได้
- in_scope = คำถามนี้เกี่ยวกับโรงงานน้ำตาลหรืองานในโรงงานหรือไม่
  true  = เรื่องอ้อย กระบวนการผลิต เครื่องจักร คุณภาพ ความปลอดภัย สิ่งแวดล้อม
          พลังงาน บุคลากร จัดซื้อ หรือการทักทาย/ถามความสามารถของระบบ
  false = เรื่องอื่นทั้งหมด เช่น ทำอาหาร กีฬา ดวง หุ้น เขียนโปรแกรม แปลเพลง
          ให้ตอบ false แม้คำถามจะสุภาพหรือดูไม่มีพิษภัย
- complexity: simple = ถามนิยาม/สูตร, moderate = อธิบายหลักการ, complex = วินิจฉัยปัญหา/วิเคราะห์ข้อมูล`;

  const res = await callLLM({
    model:      MODEL_ROUTER,
    maxTokens:  512,
    timeoutMs:  25000,
    // ทดสอบแล้ว Gemini ปฏิเสธ reasoning_effort:'none' ด้วย 400 INVALID_ARGUMENT
    // ค่าต่ำสุดที่ใช้ได้จริงคือ low — อย่าเปลี่ยนเป็น none อีก
    reasoning:  'low',
    system,
    cacheSystem: true,
    messages: [{
      role: 'user',
      content: `${convo ? `บทสนทนาก่อนหน้า:\n${convo}\n\n` : ''}คำถามล่าสุด: ${question}`,
    }],
    schema: {
      type: 'object',
      properties: {
        intent:     { type: 'string', description: 'สรุปเจตนาผู้ใช้ 1 ประโยค' },
        modules:    { type: 'array', items: { type: 'string' } },
        department: { type: ['string', 'null'] },
        process:    { type: ['string', 'null'] },
        equipment:  { type: ['string', 'null'] },
        doc_types:  { type: 'array', items: { type: 'string' } },
        queries:    { type: 'array', items: { type: 'string' } },
        complexity: { type: 'string', enum: ['simple', 'moderate', 'complex'] },
        needs_kb:   { type: 'boolean' },
        in_scope:   { type: 'boolean' },
      },
      required: ['intent', 'modules', 'queries', 'complexity', 'needs_kb', 'in_scope',
                 'department', 'process', 'equipment', 'doc_types'],
      additionalProperties: false,
    },
  });

  const msg = await res.json();
  const parsed = JSON.parse(firstText(msg)) as RouterResult;

  // กันกรณีโมเดลคืนชื่อโมดูลที่ไม่มีจริง
  const valid = new Set(modules.map((m) => m.id));
  parsed.modules = (parsed.modules ?? []).filter((m) => valid.has(m));
  if (parsed.modules.length === 0) parsed.modules = ['factory'];
  if (!parsed.queries?.length) parsed.queries = [question];
  // โมเดลเก่าหรือคำตอบที่ไม่มีฟิลด์นี้ ให้ถือว่าอยู่ในขอบเขต แล้วไปตกที่ด่านความมั่นใจแทน
  if (typeof parsed.in_scope !== 'boolean') parsed.in_scope = true;

  return parsed;
}


// =====================================================================
//  ขั้นที่ 2 — RETRIEVAL (hybrid, กรองด้วยโมดูล)
// =====================================================================
// มีคีย์ Voyage ไม่ได้แปลว่าคลังมีเวกเตอร์
// ตอนนี้คลังยังไม่มี embedding สักท่อน เพราะโควตาฟรีของ Voyage ที่ไม่ผูกบัตร
// จำกัดไว้ 3 คำขอ/นาที จึง backfill ไม่ไหว
// ถ้าไม่เช็ก ทุกคำถามจะยิง Voyage 5 ครั้งเพื่อสร้างเวกเตอร์คำถาม
// แล้วโดน 429 กลับมาทั้งหมด — เสียเวลารอฟรีโดยไม่ได้อะไรเลย
// เช็กครั้งเดียวต่อ isolate แล้วจำไว้ พอ backfill สำเร็จเมื่อไหร่ isolate ใหม่จะเห็นเอง
let vectorsReady: Promise<boolean> | null = null;
function kbHasVectors(): Promise<boolean> {
  vectorsReady ??= supabase
    .from('kb_chunks').select('id', { count: 'exact', head: true })
    .not('embedding', 'is', null)
    .then(({ count }) => (count ?? 0) > 0)
    .catch(() => false);
  return vectorsReady;
}

async function embed(text: string): Promise<number[] | null> {
  if (!VOYAGE_KEY) return null;   // ไม่มี key -> ใช้ lexical อย่างเดียว
  if (!await kbHasVectors()) return null;
  try {
    const res = await fetch('https://api.voyageai.com/v1/embeddings', {
      method: 'POST',
      headers: {
        'content-type':  'application/json',
        'authorization': `Bearer ${VOYAGE_KEY}`,
      },
      body: JSON.stringify({ model: EMBED_MODEL, input: [text], input_type: 'query' }),
    });
    if (!res.ok) return null;
    const j = await res.json();
    return j.data?.[0]?.embedding ?? null;
  } catch {
    return null;
  }
}

// ค้นด้วยคำค้นเดียว — แยกออกมาเพื่อให้ยิงหลายคำค้นพร้อมกันได้
// modules = null คือค้นทุกห้อง (ใช้ตอน fallback ข้ามห้อง)
async function searchOne(q: string, modules: string[] | null): Promise<Chunk[]> {
  const vec = await embed(q);
  const { data, error } = await supabase.rpc('hybrid_search', {
    p_query:     q,
    p_embedding: vec,
    p_modules:   modules,
    p_limit:     RETRIEVE_K,
  });
  if (error) { console.error('hybrid_search', error.message); return []; }
  return (data ?? []) as Chunk[];
}

// รวมผลจากหลายคำค้น — chunk ที่โผล่จากหลายคำค้น = เกี่ยวข้องมากกว่า จึงบวกคะแนนสะสม
//
// จำกัดจำนวนท่อนต่อเอกสารด้วย เพราะเอกสารยาวๆ อย่างเช็กลิสต์ 221 ข้อ x 21 หน่วยงาน
// มีท่อนที่ "คล้ายคำถามพอประมาณ" อยู่เป็นร้อย แล้วกินที่นั่งทั้ง 20 ช่องไปหมด
// วัดจริงจาก "GHPs คืออะไร" — อ้างอิง 6 ท่อนมาจากเอกสารเดียวกัน 5 ท่อน
// ส่วน Codex GHP ฉบับเต็มที่มีคำตอบตรงๆ ไม่ติดอันดับเลยสักท่อน
// เมื่อจำกัดแล้ว rerank จะได้เห็นเอกสารหลายฉบับให้เลือก ไม่ใช่ฉบับเดียวซ้ำๆ
// และคะแนน agreement (ความสอดคล้องข้ามเอกสาร) ก็สะท้อนความจริงมากขึ้น
const MAX_PER_DOC = 3;

function mergeHits(lists: Chunk[][]): Chunk[] {
  const seen = new Map<number, Chunk>();
  for (const list of lists) {
    for (const row of list) {
      const prev = seen.get(row.chunk_id);
      if (prev) prev.rrf_score += row.rrf_score;
      else seen.set(row.chunk_id, { ...row });
    }
  }

  const ranked = [...seen.values()].sort((a, b) => b.rrf_score - a.rrf_score);

  const perDoc = new Map<string, number>();
  const kept: Chunk[] = [];
  const spill: Chunk[] = [];
  for (const c of ranked) {
    const n = perDoc.get(c.doc_code) ?? 0;
    if (n < MAX_PER_DOC) { perDoc.set(c.doc_code, n + 1); kept.push(c); }
    else spill.push(c);
  }
  // ถ้าคลังห้องนั้นมีเอกสารน้อยจนโควตาเติมไม่เต็ม ให้เอาส่วนที่ตัดไว้กลับมาต่อท้าย
  // ดีกว่าส่ง context ไปให้ LLM แค่ 5 ท่อนทั้งที่มีของให้อ่านมากกว่านั้น
  return kept.concat(spill).slice(0, RETRIEVE_K);
}

async function retrieve(router: RouterResult): Promise<Chunk[]> {
  // เดิมยิงทีละคำค้นแบบรอต่อกัน 4 รอบ ทั้งที่แต่ละรอบไม่ได้ใช้ผลของรอบก่อน
  // ยิงพร้อมกันแล้วเวลารวมเท่ากับรอบที่ช้าที่สุด แทนที่จะเป็นผลรวมทั้งสี่รอบ
  const lists = await Promise.all(
    router.queries.slice(0, 4).map((q) => searchOne(q, router.modules)),
  );
  return mergeHits(lists);
}


// =====================================================================
//  ขั้นที่ 3 — RE-RANK  (Top 20 -> Top 6)
// =====================================================================
async function rerank(question: string, chunks: Chunk[]): Promise<Chunk[]> {
  if (chunks.length <= CONTEXT_K) return fallbackScores(chunks);

  const listing = chunks
    .map((c, i) => `[${i}] ${c.doc_code} · ${c.section}\n${c.content.slice(0, 420)}`)
    .join('\n\n---\n\n');

  try {
    const res = await callLLM({
      model:     MODEL_RERANK,
      maxTokens: 512,
      timeoutMs: 25000,
      reasoning: 'low',
      system: 'คุณคือตัวจัดอันดับความเกี่ยวข้องของเอกสาร ให้คะแนน 0-10 ว่าท่อนเอกสารนั้น' +
              'ช่วยตอบคำถามได้จริงแค่ไหน เอกสารที่พูดถึงหัวข้อเดียวกันแต่ไม่ตอบคำถามให้คะแนนต่ำ',
      messages: [{
        role: 'user',
        content: `คำถาม: ${question}\n\nท่อนเอกสาร:\n\n${listing}`,
      }],
      schema: {
        type: 'object',
        properties: {
          scores: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                index: { type: 'integer' },
                score: { type: 'integer' },
              },
              required: ['index', 'score'],
              additionalProperties: false,
            },
          },
        },
        required: ['scores'],
        additionalProperties: false,
      },
    });

    const { scores } = JSON.parse(firstText(await res.json()));
    const map = new Map<number, number>(scores.map((s: any) => [s.index, s.score]));

    return chunks
      .map((c, i) => ({ c, s: map.get(i) ?? 0 }))
      .sort((a, b) => b.s - a.s)
      .slice(0, CONTEXT_K)
      .map((x) => ({ ...x.c, similarity: Math.max(x.c.similarity, x.s / 10) }));

  } catch (e) {
    console.error('rerank failed, ใช้ลำดับเดิม:', e);
    return fallbackScores(chunks.slice(0, CONTEXT_K));
  }
}

// similarity ที่ได้จากฐานข้อมูลเป็น 0 เมื่อไม่มี embedding (ไม่ได้ตั้ง VOYAGE_KEY)
// ปกติ rerank เป็นตัวเติมคะแนนให้ แต่ถ้า rerank ล้ม คะแนนจะเป็นศูนย์ทั้งชุด
// ความมั่นใจจึงตกต่ำกว่าเกณฑ์แล้วระบบปฏิเสธตอบ ทั้งที่หาเอกสารที่ถูกต้องเจอแล้ว
// กรณีนี้ให้ประมาณคะแนนจากลำดับของ RRF แทน ดีกว่าทิ้งคำตอบทั้งคำถาม
function fallbackScores(chunks: Chunk[]): Chunk[] {
  if (chunks.some((c) => (c.similarity || 0) > 0)) return chunks;
  return chunks.map((c, i) => ({ ...c, similarity: Math.max(0.5, 0.85 - i * 0.05) }));
}


// =====================================================================
//  ขั้นที่ 4 — CONFIDENCE  (คำนวณจากหลักฐาน ไม่ให้ LLM เดา)
// =====================================================================
function computeConfidence(chunks: Chunk[]): number {
  if (!chunks.length) return 0;

  const sims  = chunks.map((c) => c.similarity || 0);
  const top1  = sims[0];
  const top3  = sims.slice(0, 3).reduce((a, b) => a + b, 0) / Math.min(3, sims.length);
  const docs  = new Set(chunks.map((c) => c.doc_code)).size;

  const coverage  = Math.min(1, chunks.length / CONTEXT_K);
  const agreement = Math.min(1, docs / 3);

  const raw = 0.45 * top1 + 0.25 * top3 + 0.20 * coverage + 0.10 * agreement;
  return Math.round(Math.min(0.97, raw) * 1000) / 1000;
}


// =====================================================================
//  ขั้นที่ 5 — ANSWER  (Opus 5, streaming)
// =====================================================================
function buildAnswerSystem(persona: string, complexity: string, lang: string,
                           weakEvidence = false) {
  const langLine = lang === 'en'
    ? 'Respond in English.'
    : lang === 'lo'
    ? 'ຕອບເປັນພາສາລາວ (ຖ້າບໍ່ແນ່ໃຈຄຳສັບເຕັກນິກ ໃຫ້ວົງເລັບພາສາອັງກິດໄວ້).'
    : 'ตอบเป็นภาษาไทย ใส่ศัพท์อังกฤษในวงเล็บเมื่อใช้ครั้งแรก';

  // เดิมบังคับ 5 หัวข้อกับคำถามวินิจฉัย ทำให้คำตอบยาว 4,000 ตัวอักษร
  // ใช้เวลาพิมพ์อย่างเดียว 7 วินาที เหลือ 3 หัวข้อและสั่งให้กระชับ
  const shape = complexity === 'complex'
    ? `ใช้โครงนี้ สั้นๆ (ข้ามหัวข้อที่ไม่เกี่ยวได้):
## สาเหตุที่เป็นไปได้
เรียงตามความน่าจะเป็น ข้อละ 1-2 บรรทัด ไม่เกิน 4 ข้อ
## ตรวจอะไรก่อน
## สิ่งที่ควรทำ`
    : `ตอบตรงคำถามใน 2-3 บรรทัด แล้วขยายความเท่าที่จำเป็น
ไม่ต้องใส่หัวข้อ "สาเหตุ/การป้องกัน" ถ้าคำถามไม่ได้ถามถึงปัญหา`;

  return `${persona}

━━━ กติกาการตอบของแพลตฟอร์มนี้ ━━━

${langLine}

**เอกสารของโรงงานมาก่อนเสมอ**
- ทุกข้อความที่เป็นข้อเท็จจริงเชิงเทคนิค ต้องมีเลขอ้างอิง [1] [2] กำกับท้ายประโยค
- ถ้าเอกสารขัดแย้งกัน ให้ชี้ให้เห็นว่าขัดกันตรงไหน อย่าเลือกข้างเงียบๆ

**เมื่อเอกสารไม่พอตอบ — ตอบได้ แต่ต้องติดป้ายบอกที่มา**
เดิมระบบถูกสั่งให้ปฏิเสธทันทีเมื่อไม่เจอเอกสาร ทำให้ตอบคำถามพื้นฐานอย่าง
"GHPs คืออะไร" ไม่ได้เลย ตอนนี้เปลี่ยนเป็น
- **ส่วนที่มาจากเอกสารของโรงงาน** ใส่เลขอ้างอิง [1] [2] ตามปกติ
- **ส่วนที่มาจากความรู้ทั่วไปหรือหลักการสากล** ขึ้นต้นย่อหน้านั้นด้วย
  \`> ไม่พบในคลังของโรงงาน — ตอบจากหลักการสากล:\`
  แล้วอธิบายได้ตามปกติ
- ปิดท้ายด้วยบรรทัดเดียวว่าถ้าต้องการคำตอบที่อ้างอิงได้ ควรเพิ่มเอกสารประเภทใดเข้าคลัง
- **ยังคงห้ามเด็ดขาด** สำหรับสิ่งที่เดาไม่ได้ — ตัวเลข ค่าควบคุม สเปก เกณฑ์ตัดสิน
  รหัสเอกสาร ML-xx เลขข้อกำหนด เลขมาตรากฎหมาย และรอบการตรวจ
  ของเหล่านี้ถ้าไม่มีในเอกสารให้บอกว่าไม่มี ห้ามยกจากความรู้ทั่วไปมาตอบ
  เพราะผู้ใช้เอาไปสั่งงานหน้างานและอ้างกับผู้ตรวจจริง${weakEvidence ? `

**รอบนี้หลักฐานอ่อน** — เอกสารที่ค้นเจอเกี่ยวข้องไม่มากพอ
ให้ขึ้นต้นคำตอบด้วยบรรทัดนี้ก่อนเลย
\`> เอกสารในคลังที่ตรงกับคำถามนี้มีน้อย คำตอบด้านล่างส่วนใหญ่มาจากหลักการทั่วไป\`
แล้วค่อยตอบตามกติกาข้างบน` : ''}

**รูปแบบ**
${shape}

**ความยาว — สำคัญ**
ผู้ใช้บอกว่าคำตอบยาวเกินและรอนาน ให้ตอบ**ไม่เกิน 250 คำ**
- เอาเฉพาะสิ่งที่เอาไปทำต่อได้ทันที ตัดคำอธิบายพื้นฐานที่วิศวกรรู้อยู่แล้วออก
- ข้อละ 1-2 บรรทัด ไม่ต้องขยายความทุกข้อ
- ถ้าเรื่องใหญ่จริงจนย่อไม่ได้ ให้ตอบส่วนที่สำคัญที่สุดก่อน
  แล้วปิดท้ายบรรทัดเดียวว่ายังมีประเด็นอะไรให้ถามต่อได้

**สิ่งที่ห้ามทำ**
- ห้ามใส่หัวข้อ "เอกสารอ้างอิง" หรือ "Confidence" ท้ายคำตอบ — ระบบสร้างให้เอง
- ห้ามเดาตัวเลข สเปก หรือค่ามาตรฐานที่ไม่ปรากฏในเอกสาร`;
}

function buildContext(chunks: Chunk[]) {
  return chunks
    .map((c, i) =>
      `[${i + 1}] ${c.doc_title} (${c.doc_code}) — ${c.page_ref}\n${c.content}`)
    .join('\n\n════════════════════\n\n');
}


// =====================================================================
//  HANDLER
// =====================================================================
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const t0 = Date.now();

  try {
    const { question, session_id, lang = 'th', history = [], force_module } = await req.json();

    if (!question?.trim()) {
      return new Response(JSON.stringify({ error: 'ต้องระบุ question' }), {
        status: 400, headers: { ...CORS, 'content-type': 'application/json' },
      });
    }
    if (!LLM_KEY) {
      return new Response(JSON.stringify({
        error: `ยังไม่ได้ตั้ง LLM_API_KEY ใน Edge Function secrets (ผู้ให้บริการที่เลือก: ${PROVIDER})`,
      }), { status: 500, headers: { ...CORS, 'content-type': 'application/json' } });
    }
    if (!LLM_BASE) {
      return new Response(JSON.stringify({
        error: `ไม่รู้จักผู้ให้บริการ "${PROVIDER}" — ตั้ง LLM_BASE_URL เองถ้าใช้เจ้าอื่น`,
      }), { status: 500, headers: { ...CORS, 'content-type': 'application/json' } });
    }

    // โหลดทะเบียนโมดูล
    const { data: modules } = await supabase
      .from('modules').select('id,name_th,name_en,icon,persona,keywords')
      .eq('is_active', true).order('sort_order');

    if (!modules?.length) throw new Error('ยังไม่มีข้อมูลในตาราง modules — รัน 002_modules.sql ก่อน');

    // ── 1) ROUTER ──
    // ผู้ใช้เลือกห้องผู้เชี่ยวชาญไว้แล้ว router จึงมีหน้าที่แค่ขยายคำค้น
    // ไม่ต้องเลือกโมดูลใหม่ (ไม่งั้นจะขัดกับห้องที่ผู้ใช้ตั้งใจถาม)
    const fixed = force_module && modules.some((m: any) => m.id === force_module)
      ? force_module : undefined;

    // ค้นด้วยคำถามดิบไปพร้อมกับที่ router กำลังคิด — สองอย่างนี้ไม่ต้องรอกัน
    // เดิมรอ router เสร็จก่อนถึงเริ่มค้น เสียเวลาฟรีไปสองวินาทีทุกคำถาม
    const headStart = fixed ? searchOne(question, [fixed]) : Promise.resolve([] as Chunk[]);

    // router ล้มไม่ควรทำให้ทั้งคำขอพัง — ห้องถูกเลือกไว้แล้วและคำถามดิบก็ใช้ค้นได้
    // (เคยตั้งค่าพารามิเตอร์ผิดแล้วผู้ใช้ได้ 500 ทั้งที่คลังความรู้ไม่มีปัญหาเลย)
    let router: RouterResult;
    try {
      router = await runRouter(question, modules as any, history, fixed);
    } catch (e) {
      console.error('router ล้ม ใช้คำถามดิบแทน:', e);
      router = {
        intent: question, modules: fixed ? [fixed] : ['factory'],
        department: null, process: null, equipment: null, doc_types: [],
        queries: [question], complexity: 'moderate', needs_kb: true, in_scope: true,
      };
    }
    if (fixed) router.modules = [fixed];

    // router เดาไม่แน่นอน — คำถามเดียวกันบางครั้งได้ needs_kb=true บางครั้ง false
    // (วัดจริง "ลาคลอดได้กี่วัน" รอบแรกค้นเจอกฎระเบียบบริษัท รอบสองตอบเองเฉยๆ
    //  แล้วรายงานความมั่นใจ 100% ทั้งที่ไม่ได้เปิดเอกสารสักฉบับ)
    // ความมั่นใจ 100% ที่ไม่มีหลักฐานรองรับ อันตรายกว่าการตอบไม่ได้
    // จึงค้นคลังทุกครั้งที่คำถามอยู่ในขอบเขต ปล่อยให้คะแนนหลักฐานเป็นตัวตัดสินเอง
    // การทักทายที่ค้นแล้วไม่เจออะไรก็ยังตอบได้ตามปกติ แค่ไม่มีเลขอ้างอิงเท่านั้น
    if (router.in_scope) router.needs_kb = true;
    const tRouter = Date.now();

    // ── 2) RETRIEVE + 3) RERANK ──
    let chunks: Chunk[] = [];
    let crossRoom = false;
    if (router.needs_kb) {
      const [early, lists] = await Promise.all([
        headStart,
        Promise.all(router.queries.slice(0, 4).map((q) => searchOne(q, router.modules))),
      ]);
      chunks = mergeHits([early, ...lists]);

      // ค้นซ้ำข้ามห้องเมื่อห้องที่เปิดอยู่ให้ของไม่พอ
      // ผู้ใช้ไม่ได้แยกห้องในหัวเวลาถาม — ถามเรื่องความปลอดภัยอาหารในห้องโรงงาน
      // ก็มีสิทธิ์เกิดขึ้นทุกวัน เดิมระบบล็อกไว้ห้องเดียวแล้วตอบว่าไม่มีข้อมูล
      // ทั้งที่ห้องข้างๆ มีเอกสารตรงคำถามอยู่
      // ทำเฉพาะตอนของไม่พอจริง จึงไม่กระทบเวลาตอบของคำถามปกติ
      const weakSoFar = chunks.length < CONTEXT_K ||
                        computeConfidence(chunks.slice(0, CONTEXT_K)) < MIN_CONFIDENCE;
      if (weakSoFar && router.modules.length < (modules as any[]).length) {
        const wide = await Promise.all(
          router.queries.slice(0, 4).map((q) => searchOne(q, null)),
        );
        chunks = mergeHits([chunks, ...wide]);
        crossRoom = true;
      }

      chunks = await rerank(question, chunks);
    }
    const tRetrieve = Date.now();

    // ความมั่นใจมาจากหลักฐานที่ค้นได้เท่านั้น ไม่มีทางลัดให้เต็ม 100 โดยไม่มีเอกสาร
    const confidence = router.in_scope ? computeConfidence(chunks) : 0;
    const primary    = modules.find((m: any) => m.id === router.modules[0]) as any;

    const citations = chunks.map((c, i) => ({
      n:         i + 1,
      doc_code:  c.doc_code,
      doc_title: c.doc_title,
      doc_type:  c.doc_type,
      section:   c.section,
      page_ref:  c.page_ref,
      module:    c.module_id,
      score:     Math.round((c.similarity || 0) * 100) / 100,
    }));

    // ── 4) ANSWER (streaming) ──
    const enc = new TextEncoder();
    const stream = new ReadableStream({
      async start(controller) {
        const send = (event: string, data: unknown) =>
          controller.enqueue(enc.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));

        // ส่ง metadata ก่อน เพื่อให้ UI แสดง badge/citation ได้ทันที
        send('meta', {
          router: {
            intent:     router.intent,
            modules:    router.modules,
            department: router.department,
            process:    router.process,
            equipment:  router.equipment,
            queries:    router.queries,
            complexity: router.complexity,
          },
          module: primary
            ? { id: primary.id, name_th: primary.name_th, name_en: primary.name_en, icon: primary.icon }
            : null,
          citations,
          confidence,
          cross_room: crossRoom,
          retrieved: chunks.length,
          // บอกว่าใช้โมเดลอะไรตอบจริง ฝั่งหน้าเว็บเคยเขียนตายตัวว่า Opus 5
          // พอเปลี่ยนผู้ให้บริการเป็น Gemini ป้ายจึงแสดงผิด
          model:    MODEL_ANSWER,
          provider: PROVIDER,
          timing: { router_ms: tRouter - t0, retrieval_ms: tRetrieve - tRouter },
        });

        // คำถามนอกขอบเขตโรงงาน — ปฏิเสธตั้งแต่ต้น ไม่เรียก LLM เลย
        // ประหยัดค่า API ด้วย เพราะไม่ต้องส่งอะไรไปให้โมเดลตอบ
        if (!router.in_scope) {
          send('delta', { text:
            'คำถามนี้อยู่นอกขอบเขตของระบบครับ\n\n' +
            'ML Expert AI ตอบเฉพาะเรื่องที่เกี่ยวกับโรงงานน้ำตาล — อ้อย กระบวนการผลิต ' +
            'เครื่องจักร คุณภาพ ความปลอดภัย สิ่งแวดล้อม พลังงาน และงานสนับสนุน ' +
            'โดยอ้างอิงจากเอกสารในคลังความรู้ของโรงงานเท่านั้น' });
          send('done', { out_of_scope: true, latency_ms: Date.now() - t0 });
          controller.close();
          return;
        }

        // หลักฐานอ่อน — เดิมปฏิเสธทันทีโดยไม่เรียก LLM เลย
        // ผลคือคำถามพื้นฐานอย่าง "GHPs คืออะไร" ตอบไม่ได้ ทั้งที่ Codex GHP อยู่ในคลัง
        // (สาเหตุจริงคือเพดานคะแนนต่ำกว่าเกณฑ์ ดู migration 008)
        // ตอนนี้เปลี่ยนเป็นตอบต่อ แต่สั่งให้ติดป้ายบอกที่มาให้ชัด
        // และยังห้ามเดาตัวเลข ค่าควบคุม รหัสเอกสาร หรือเลขข้อกำหนดเหมือนเดิม
        const weakEvidence = router.needs_kb && confidence < MIN_CONFIDENCE;

        const system = buildAnswerSystem(
          primary?.persona ?? 'คุณคือผู้เชี่ยวชาญโรงงานน้ำตาล',
          router.complexity, lang, weakEvidence,
        );

        // บอกให้รู้ว่าบางท่อนมาจากห้องอื่น จะได้เขียนกำกับไว้ ไม่ใช่ยกมาเนียนๆ
        const roomNote = crossRoom
          ? 'หมายเหตุ: ห้องที่ผู้ใช้เปิดอยู่มีเอกสารตรงคำถามไม่พอ ระบบจึงไปดึงจากห้องอื่นมาด้วย ' +
            'ถ้าใช้ท่อนจากห้องอื่นให้บอกไว้สั้นๆ ว่ามาจากเอกสารของหน่วยงานใด\n\n'
          : '';
        const userContent = router.needs_kb
          ? `${roomNote}เอกสารอ้างอิงจากคลังความรู้:\n\n${buildContext(chunks)}\n\n` +
            `════════════════════\n\nคำถาม: ${question}`
          : question;

        let answer = '';
        let usage: any = {};
        let ttft = 0;   // เวลาจนตัวอักษรแรกออก = ช่วงที่ผู้ใช้เห็นจอนิ่ง ต้องเฝ้าตัวนี้

        try {
          const res = await callLLM({
            model:     MODEL_ANSWER,
            // ห้ามลดต่ำกว่านี้เพื่อบังคับให้ตอบสั้น — max_tokens ครอบโควตาการคิดของโมเดลด้วย
            // เคยลดเหลือ 2600 แล้วบางครั้งโมเดลใช้โควตาไปกับการคิดจนหมด
            // ส่งข้อความกลับมา 0 ตัวอักษร ผู้ใช้เห็นการ์ดเปล่า
            // คุมความยาวด้วยคำสั่งใน system prompt แทน
            maxTokens: 8000,
            timeoutMs: 75000,
            stream:    true,
            system,
            cacheSystem: true,
            // Claude: thinking เปิดโดยปริยาย คุมความลึกด้วย effort
            // เจ้าอื่นไม่มีพารามิเตอร์นี้ callLLM จะข้ามให้เอง
            effort: router.complexity === 'complex' ? 'high' : 'medium',
            messages: [
              ...history.slice(-6).map((h: any) => ({ role: h.role, content: h.content })),
              { role: 'user', content: userContent },
            ],
          });

          const reader = res.body!.getReader();
          const dec = new TextDecoder();
          let buf = '';

          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            buf += dec.decode(value, { stream: true });

            const lines = buf.split('\n');
            buf = lines.pop() ?? '';

            for (const line of lines) {
              if (!line.startsWith('data: ')) continue;
              const payload = line.slice(6).trim();
              if (!payload || payload === '[DONE]') continue;

              let ev: any;
              try { ev = JSON.parse(payload); } catch { continue; }

              const d = parseDelta(ev);
              if (d.text) {
                if (!ttft) ttft = Date.now() - t0;
                answer += d.text; send('delta', { text: d.text });
              }
              if (d.usage) usage = { ...usage, ...d.usage };
              if (d.stop === 'refusal') {
                send('delta', { text: '\n\n_ระบบไม่สามารถตอบคำถามนี้ได้ตามนโยบายความปลอดภัย_' });
              } else if (d.stop === 'max_tokens') {
                send('delta', { text: '\n\n_(คำตอบยาวเกินโควตา ถูกตัดกลางคัน)_' });
              }
            }
          }
        } catch (e) {
          send('delta', { text: `\n\n**เกิดข้อผิดพลาดขณะสร้างคำตอบ:** ${String(e).slice(0, 300)}` });
        }

        const latency = Date.now() - t0;
        send('done', { usage, latency_ms: latency, ttft_ms: ttft, answer_chars: answer.length });

        // บันทึกลง log (ไม่ให้ error ตรงนี้ทำให้คำตอบพัง)
        if (session_id) {
          supabase.from('chat_messages').insert([
            { session_id, role: 'user', content: question },
            {
              session_id, role: 'assistant', content: answer,
              module_id: router.modules[0], router_trace: router,
              citations, confidence, usage, latency_ms: latency,
            },
          ]).then(({ error }) => error && console.error('log', error.message));
        }

        controller.close();
      },
    });

    return new Response(stream, {
      headers: {
        ...CORS,
        'content-type':  'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache',
        'connection':    'keep-alive',
      },
    });

  } catch (e) {
    console.error(e);
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500, headers: { ...CORS, 'content-type': 'application/json' },
    });
  }
});
