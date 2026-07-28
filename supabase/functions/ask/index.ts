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
const ANTHROPIC_URL   = 'https://api.anthropic.com/v1/messages';
const MODEL_ROUTER    = 'claude-haiku-4-5';
const MODEL_RERANK    = 'claude-haiku-4-5';
const MODEL_ANSWER    = 'claude-opus-5';
const EMBED_MODEL     = 'voyage-3';

const RETRIEVE_K      = 20;   // ดึงมาก่อน rerank
const CONTEXT_K       = 6;    // ส่งเข้า LLM จริง
const MIN_CONFIDENCE  = 0.55; // ต่ำกว่านี้ = หลักฐานไม่พอ ห้ามสรุปคำตอบ

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const ANTHROPIC_KEY = Deno.env.get('ANTHROPIC_API_KEY') ?? '';
const VOYAGE_KEY    = Deno.env.get('VOYAGE_API_KEY') ?? '';

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
//  เรียก Anthropic API
// =====================================================================
async function anthropic(body: Record<string, unknown>, betas: string[] = []) {
  const headers: Record<string, string> = {
    'content-type':      'application/json',
    'x-api-key':         ANTHROPIC_KEY,
    'anthropic-version': '2023-06-01',
  };
  if (betas.length) headers['anthropic-beta'] = betas.join(',');

  const res = await fetch(ANTHROPIC_URL, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Anthropic ${res.status}: ${text.slice(0, 500)}`);
  }
  return res;
}

function firstText(msg: any): string {
  for (const b of msg.content ?? []) {
    if (b.type === 'text') return b.text;
  }
  return '';
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
- complexity: simple = ถามนิยาม/สูตร, moderate = อธิบายหลักการ, complex = วินิจฉัยปัญหา/วิเคราะห์ข้อมูล`;

  const res = await anthropic({
    model:      MODEL_ROUTER,
    max_tokens: 1024,
    system:     [{ type: 'text', text: system, cache_control: { type: 'ephemeral' } }],
    messages: [{
      role: 'user',
      content: `${convo ? `บทสนทนาก่อนหน้า:\n${convo}\n\n` : ''}คำถามล่าสุด: ${question}`,
    }],
    output_config: {
      format: {
        type: 'json_schema',
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
          },
          required: ['intent', 'modules', 'queries', 'complexity', 'needs_kb',
                     'department', 'process', 'equipment', 'doc_types'],
          additionalProperties: false,
        },
      },
    },
  });

  const msg = await res.json();
  const parsed = JSON.parse(firstText(msg)) as RouterResult;

  // กันกรณีโมเดลคืนชื่อโมดูลที่ไม่มีจริง
  const valid = new Set(modules.map((m) => m.id));
  parsed.modules = (parsed.modules ?? []).filter((m) => valid.has(m));
  if (parsed.modules.length === 0) parsed.modules = ['dashboard'];
  if (!parsed.queries?.length) parsed.queries = [question];

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
    const res = await anthropic({
      model:      MODEL_RERANK,
      max_tokens: 512,
      system: 'คุณคือตัวจัดอันดับความเกี่ยวข้องของเอกสาร ให้คะแนน 0-10 ว่าท่อนเอกสารนั้น' +
              'ช่วยตอบคำถามได้จริงแค่ไหน เอกสารที่พูดถึงหัวข้อเดียวกันแต่ไม่ตอบคำถามให้คะแนนต่ำ',
      messages: [{
        role: 'user',
        content: `คำถาม: ${question}\n\nท่อนเอกสาร:\n\n${listing}`,
      }],
      output_config: {
        format: {
          type: 'json_schema',
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
        },
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
    if (!ANTHROPIC_KEY) {
      return new Response(JSON.stringify({ error: 'ยังไม่ได้ตั้ง ANTHROPIC_API_KEY ใน Edge Function secrets' }), {
        status: 500, headers: { ...CORS, 'content-type': 'application/json' },
      });
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

    const confidence = router.needs_kb ? computeConfidence(chunks) : 1;
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
          const res = await anthropic({
            model:      MODEL_ANSWER,
            max_tokens: 8000,
            stream:     true,
            // Opus 5: thinking เปิดโดยปริยาย ควบคุมความลึกด้วย effort
            output_config: { effort: router.complexity === 'complex' ? 'high' : 'medium' },
            // safety classifier ปฏิเสธ -> ให้ระบบส่งต่อโมเดลสำรองเองในคอลเดียว
            fallbacks: 'default',
            system: [
              { type: 'text', text: system, cache_control: { type: 'ephemeral' } },
            ],
            messages: [
              ...history.slice(-6).map((h: any) => ({ role: h.role, content: h.content })),
              { role: 'user', content: userContent },
            ],
          }, ['server-side-fallback-2026-07-01']);

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

              if (ev.type === 'content_block_delta' && ev.delta?.type === 'text_delta') {
                answer += ev.delta.text;
                send('delta', { text: ev.delta.text });
              } else if (ev.type === 'message_delta') {
                if (ev.usage) usage = { ...usage, ...ev.usage };
                if (ev.delta?.stop_reason === 'refusal') {
                  send('delta', { text: '\n\n_ระบบไม่สามารถตอบคำถามนี้ได้ตามนโยบายความปลอดภัย_' });
                }
              } else if (ev.type === 'message_start') {
                usage = { ...usage, ...(ev.message?.usage ?? {}) };
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
