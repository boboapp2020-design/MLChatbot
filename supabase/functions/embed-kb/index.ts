// =====================================================================
//  ML Expert AI — Embedding Backfill
// ---------------------------------------------------------------------
//  สร้างเวกเตอร์ให้ chunk ที่ยังไม่มี embedding
//  เรียกซ้ำได้จนกว่า remaining = 0
//
//  POST /functions/v1/embed-kb   body: { batch?: number }
//
//  ต้องตั้ง secret: VOYAGE_API_KEY
//  (ข้ามขั้นตอนนี้ได้ — ระบบจะใช้ full-text + trigram search แทน)
// =====================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const VOYAGE_KEY = Deno.env.get('VOYAGE_API_KEY') ?? '';
const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body, null, 2), {
      status, headers: { ...CORS, 'content-type': 'application/json' },
    });

  if (!VOYAGE_KEY) {
    return json({
      error: 'ยังไม่ได้ตั้ง VOYAGE_API_KEY',
      note:  'ข้ามขั้นตอนนี้ได้ — ระบบจะค้นด้วย full-text + trigram แทน (คุณภาพต่ำกว่าเล็กน้อย)',
      signup: 'https://dash.voyageai.com',
    }, 400);
  }

  try {
    const { batch = 96 } = await req.json().catch(() => ({}));

    const { data: rows, error } = await supabase
      .from('kb_chunks')
      .select('id, section, content')
      .is('embedding', null)
      .limit(Math.min(batch, 128));

    if (error) throw error;
    if (!rows?.length) {
      const { count } = await supabase
        .from('kb_chunks').select('*', { count: 'exact', head: true });
      return json({ done: true, remaining: 0, total_chunks: count, message: 'สร้าง embedding ครบทุก chunk แล้ว' });
    }

    // นำ section มาต่อหน้า content เพื่อให้เวกเตอร์มีบริบทหัวข้อด้วย
    const inputs = rows.map((r) =>
      `${r.section ?? ''}\n${r.content}`.slice(0, 8000));

    const res = await fetch('https://api.voyageai.com/v1/embeddings', {
      method: 'POST',
      headers: {
        'content-type':  'application/json',
        'authorization': `Bearer ${VOYAGE_KEY}`,
      },
      body: JSON.stringify({ model: 'voyage-3', input: inputs, input_type: 'document' }),
    });

    if (!res.ok) throw new Error(`Voyage ${res.status}: ${(await res.text()).slice(0, 300)}`);

    const { data: embeddings } = await res.json();

    // อัปเดตทีละแถว (Supabase ยังไม่รองรับ bulk update บน vector column)
    let ok = 0;
    for (let i = 0; i < rows.length; i++) {
      const { error: e } = await supabase
        .from('kb_chunks')
        .update({ embedding: embeddings[i].embedding })
        .eq('id', rows[i].id);
      if (e) console.error(`chunk ${rows[i].id}:`, e.message); else ok++;
    }

    const { count: remaining } = await supabase
      .from('kb_chunks').select('*', { count: 'exact', head: true }).is('embedding', null);

    return json({
      done:      remaining === 0,
      embedded:  ok,
      remaining,
      message:   remaining === 0
        ? 'เสร็จแล้ว — อย่าลืมสร้าง index: create index idx_chunks_embedding on kb_chunks using ivfflat (embedding vector_cosine_ops) with (lists = 100);'
        : `เหลืออีก ${remaining} chunks — เรียกฟังก์ชันนี้ซ้ำ`,
    });

  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
