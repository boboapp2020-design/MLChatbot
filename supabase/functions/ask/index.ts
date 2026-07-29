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
}

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
  }

  const res = await fetch(url, { method: 'POST', headers, body: JSON.stringify(body) });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`${PROVIDER} ${res.status}: ${text.slice(0, 500)}`);
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
): Promise<RouterResult> {

  const catalog = modules
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
    maxTokens:  1024,
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
  if (parsed.modules.length === 0) parsed.modules = ['dashboard'];
  if (!parsed.queries?.length) parsed.queries = [question];
  // โมเดลเก่าหรือคำตอบที่ไม่มีฟิลด์นี้ ให้ถือว่าอยู่ในขอบเขต แล้วไปตกที่ด่านความมั่นใจแทน
  if (typeof parsed.in_scope !== 'boolean') parsed.in_scope = true;

  return parsed;
}


// =====================================================================
//  ขั้นที่ 2 — RETRIEVAL (hybrid, กรองด้วยโมดูล)
// =====================================================================
async function embed(text: string): Promise<number[] | null> {
  if (!VOYAGE_KEY) return null;   // ไม่มี key -> ใช้ lexical อย่างเดียว
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

async function retrieve(router: RouterResult): Promise<Chunk[]> {
  const seen = new Map<number, Chunk>();

  for (const q of router.queries.slice(0, 4)) {
    const vec = await embed(q);
    const { data, error } = await supabase.rpc('hybrid_search', {
      p_query:     q,
      p_embedding: vec,
      p_modules:   router.modules,
      p_limit:     RETRIEVE_K,
    });
    if (error) { console.error('hybrid_search', error.message); continue; }

    for (const row of (data ?? []) as Chunk[]) {
      const prev = seen.get(row.chunk_id);
      // chunk ที่ถูกเจอจากหลายคำค้น = เกี่ยวข้องมากกว่า -> บวกคะแนนสะสม
      if (prev) prev.rrf_score += row.rrf_score;
      else seen.set(row.chunk_id, { ...row });
    }
  }

  return [...seen.values()]
    .sort((a, b) => b.rrf_score - a.rrf_score)
    .slice(0, RETRIEVE_K);
}


// =====================================================================
//  ขั้นที่ 3 — RE-RANK  (Top 20 -> Top 6)
// =====================================================================
async function rerank(question: string, chunks: Chunk[]): Promise<Chunk[]> {
  if (chunks.length <= CONTEXT_K) return chunks;

  const listing = chunks
    .map((c, i) => `[${i}] ${c.doc_code} · ${c.section}\n${c.content.slice(0, 420)}`)
    .join('\n\n---\n\n');

  try {
    const res = await callLLM({
      model:     MODEL_RERANK,
      maxTokens: 512,
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
    return chunks.slice(0, CONTEXT_K);
  }
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
function buildAnswerSystem(persona: string, complexity: string, lang: string) {
  const langLine = lang === 'en'
    ? 'Respond in English.'
    : lang === 'lo'
    ? 'ຕອບເປັນພາສາລາວ (ຖ້າບໍ່ແນ່ໃຈຄຳສັບເຕັກນິກ ໃຫ້ວົງເລັບພາສາອັງກິດໄວ້).'
    : 'ตอบเป็นภาษาไทย ใส่ศัพท์อังกฤษในวงเล็บเมื่อใช้ครั้งแรก';

  const shape = complexity === 'complex'
    ? `ใช้โครงนี้ (ข้ามหัวข้อที่ไม่เกี่ยวได้):
## สรุป
## คำอธิบาย
## สาเหตุที่เป็นไปได้ (เรียงตามความน่าจะเป็น)
## สิ่งที่ควรทำ
## การป้องกันไม่ให้เกิดซ้ำ`
    : `ตอบตรงคำถามก่อนใน 2-3 บรรทัด แล้วค่อยขยายความ
ไม่ต้องใส่หัวข้อ "สาเหตุ/การป้องกัน" ถ้าคำถามไม่ได้ถามถึงปัญหา`;

  return `${persona}

━━━ กติกาการตอบของแพลตฟอร์มนี้ ━━━

${langLine}

**ตอบจากเอกสารอ้างอิงที่ให้มาเท่านั้น**
- ทุกข้อความที่เป็นข้อเท็จจริงเชิงเทคนิค ต้องมีเลขอ้างอิง [1] [2] กำกับท้ายประโยค
- ถ้าเอกสารที่ให้มาไม่พอตอบ ให้บอกตรงๆ ว่า "คลังความรู้ยังไม่มีข้อมูลส่วนนี้"
  แล้วระบุว่าต้องการเอกสารประเภทใดเพิ่ม — ห้ามเติมความรู้ทั่วไปมากลบช่องว่าง
- ถ้าเอกสารขัดแย้งกัน ให้ชี้ให้เห็นว่าขัดกันตรงไหน อย่าเลือกข้างเงียบๆ

**รูปแบบ**
${shape}

**สิ่งที่ห้ามทำ**
- ห้ามใส่หัวข้อ "เอกสารอ้างอิง" หรือ "Confidence" ท้ายคำตอบ — ระบบสร้างให้เอง
- ห้ามเดาตัวเลข สเปก หรือค่ามาตรฐานที่ไม่ปรากฏในเอกสาร
- อย่าเขียนยาวเกินจำเป็น ผู้อ่านคือวิศวกรที่ต้องเอาไปใช้ต่อทันที`;
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
    const router = await runRouter(question, modules as any, history);
    if (force_module && modules.some((m: any) => m.id === force_module)) {
      router.modules = [force_module];
    }
    const tRouter = Date.now();

    // ── 2) RETRIEVE + 3) RERANK ──
    let chunks: Chunk[] = [];
    if (router.needs_kb) {
      chunks = await retrieve(router);
      chunks = await rerank(question, chunks);
    }
    const tRetrieve = Date.now();

    // นอกขอบเขต = ความมั่นใจศูนย์เสมอ ไม่ว่า router จะบอกว่าต้องใช้คลังหรือไม่
    // เดิมถ้า needs_kb=false จะได้ 1 ทันทีแล้วไปตอบจากความรู้ทั่วไปโดยไม่มีเอกสาร
    // ซึ่งขัดกับหลักการของระบบที่ต้องตอบจากคลังของโรงงานเท่านั้น
    const confidence = !router.in_scope ? 0
                     : router.needs_kb  ? computeConfidence(chunks)
                     : 1;
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
          retrieved: chunks.length,
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

        // หลักฐานไม่พอ — ตอบตามกติกา ไม่เรียก LLM ให้เดา
        if (router.needs_kb && confidence < MIN_CONFIDENCE) {
          const msg = chunks.length === 0
            ? 'ไม่พบเอกสารที่เกี่ยวข้องในคลังความรู้สำหรับคำถามนี้\n\n' +
              'ระบบตอบเฉพาะจากเอกสารของโรงงานเท่านั้น จึงยังตอบคำถามนี้ไม่ได้\n\n' +
              `**สิ่งที่ต้องเพิ่มเข้าคลัง:** เอกสารเกี่ยวกับ "${router.process ?? router.intent}" ` +
              `ในโมดูล ${primary?.name_th ?? router.modules[0]} เช่น SOP, Work Instruction หรือคู่มือเครื่อง`
            : `พบเอกสารที่พอเกี่ยวข้อง ${chunks.length} รายการ แต่หลักฐานยังไม่หนักแน่นพอจะสรุปคำตอบ ` +
              `(ความมั่นใจ ${(confidence * 100).toFixed(0)}% ต่ำกว่าเกณฑ์ ${MIN_CONFIDENCE * 100}%)\n\n` +
              'ดูรายการเอกสารที่ระบบพบด้านล่าง หรือถามให้เจาะจงขึ้น เช่น ระบุอุปกรณ์ ค่าที่วัดได้ หรือช่วงเวลา';

          send('delta', { text: msg });
          send('done', { insufficient_evidence: true, latency_ms: Date.now() - t0 });
          controller.close();
          return;
        }

        const system = buildAnswerSystem(
          primary?.persona ?? 'คุณคือผู้เชี่ยวชาญโรงงานน้ำตาล',
          router.complexity, lang,
        );

        const userContent = router.needs_kb
          ? `เอกสารอ้างอิงจากคลังความรู้:\n\n${buildContext(chunks)}\n\n` +
            `════════════════════\n\nคำถาม: ${question}`
          : question;

        let answer = '';
        let usage: any = {};

        try {
          const res = await callLLM({
            model:     MODEL_ANSWER,
            maxTokens: 8000,
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
              if (d.text) { answer += d.text; send('delta', { text: d.text }); }
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
        send('done', { usage, latency_ms: latency });

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
