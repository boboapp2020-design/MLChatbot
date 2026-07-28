# ML Expert AI — สถาปัตยกรรมระบบ

> แพลตฟอร์ม AI ผู้เชี่ยวชาญเฉพาะทางสำหรับโรงงานน้ำตาล
> ทุกคำตอบมาจากคลังความรู้ของโรงงานผ่าน Retrieval Augmented Generation (RAG)

---

## 1. หลักการออกแบบ (Design Principles)

| หลักการ | ความหมายเชิงเทคนิค |
|---|---|
| **ไม่โหลดเอกสารทั้งหมด** | Router เลือก module ก่อน แล้วค้นเฉพาะ partition ของ module นั้น |
| **ประหยัด token** | Router ใช้ Haiku 4.5 (ถูก/เร็ว) → Answer ใช้ Opus 5 เฉพาะตอนสร้างคำตอบ |
| **ตอบจากคลังความรู้เท่านั้น** | ถ้า retrieval ไม่เจอหลักฐานเพียงพอ ระบบต้องบอกว่าไม่มีข้อมูล ไม่ใช่เดา |
| **อ้างอิงได้ทุกคำตอบ** | ทุก chunk มี `source_file` + `section` + `anchor` → แสดงเป็น citation |
| **วัดความมั่นใจได้** | Confidence คำนวณจาก retrieval score + coverage ไม่ใช่ให้ LLM เดาเปอร์เซ็นต์เอง |

---

## 2. ภาพรวมระบบ

```
ผู้ใช้ถามคำถาม
      │
      ▼
┌─────────────────────────────────────────────┐
│  AI ROUTER  (Claude Haiku 4.5)              │
│  • เข้าใจเจตนา (intent)                      │
│  • ระบุแผนก / กระบวนการ / อุปกรณ์             │
│  • เลือก module 1–2 ตัว + ขยายคำค้น (TH/EN)  │
│  • ตัดสินว่าต้อง retrieve หรือไม่              │
└──────────────────┬──────────────────────────┘
                   │  module = ["crushing"]
                   │  queries = ["extraction ต่ำ", "imbibition % fiber", ...]
                   ▼
┌─────────────────────────────────────────────┐
│  HYBRID RETRIEVAL  (Supabase / pgvector)    │
│  • Vector search  (cosine, ivfflat)          │
│  • Lexical search (tsvector + pg_trgm)       │
│  • กรองด้วย module_id  ← ค้นเฉพาะที่เกี่ยว     │
│  • รวมด้วย Reciprocal Rank Fusion  → Top 20  │
└──────────────────┬──────────────────────────┘
                   ▼
┌─────────────────────────────────────────────┐
│  RE-RANK  (Claude Haiku 4.5, batch scoring) │
│  Top 20 → Top 6  ตามความเกี่ยวข้องจริง        │
└──────────────────┬──────────────────────────┘
                   ▼
┌─────────────────────────────────────────────┐
│  ANSWER  (Claude Opus 5)                    │
│  • System prompt = persona ของ module        │
│  • Context = 6 chunks พร้อมเลขอ้างอิง [1..6]  │
│  • Output = โครง 8 ส่วน + citations           │
└──────────────────┬──────────────────────────┘
                   ▼
            คำตอบ + เอกสารอ้างอิง + Confidence
```

---

## 3. Expert Modules (12 โมดูล)

แต่ละโมดูลมี `module_id`, persona prompt, และ partition ของตัวเองใน vector DB

| # | module_id | ชื่อโมดูล | ครอบคลุม | สกิลต้นทางที่มีอยู่แล้ว |
|---|---|---|---|---|
| 1 | `cane` | Sugarcane Expert | พันธุ์ ปลูก โรค แมลง ดิน ปุ๋ย เก็บเกี่ยว CCS | ✅ `cane-brain` |
| 2 | `crushing` | Crushing Expert | เตรียมอ้อย ชุดลูกหีบ imbibition extraction bagasse | ✅ `sugar-brain` |
| 3 | `clarification` | Juice Treatment | น้ำอ้อยรวม ปูน pH clarifier mud filter sulphitation | ✅ `sugar-brain` |
| 4 | `evaporation` | Evaporation Expert | MEE steam economy scaling vacuum BPE | ✅ `sugar-brain` + `steam-brain` |
| 5 | `panboiling` | Vacuum Pan Expert | strike seed crystal growth supersaturation false grain | ✅ `sugar-brain` |
| 6 | `centrifugal` | Centrifugal Expert | batch/continuous basket screen wash molasses | ✅ `sugar-brain` |
| 7 | `quality` | Sugar Quality AI | Pol Brix Purity Color ICUMSA moisture ash RS | ✅ `sugar-qc-brain` |
| 8 | `powerplant` | Biomass Power Plant | boiler turbine generator feedwater economizer | ✅ `steam-brain` |
| 9 | `maintenance` | Maintenance AI | mechanical electrical instrument bearing vibration motor | ✅ `motor-expert` |
| 10 | `foodsafety` | Food Safety AI | FSSC22000 ISO22000 HACCP GMP audit CAR | ⬜ ต้องเพิ่มเอกสาร |
| 11 | `warehouse` | Warehouse AI | inventory FIFO/FEFO storage sugar aging safety | ⬜ ต้องเพิ่มเอกสาร |
| 12 | `dashboard` | Dashboard AI | KPI OEE recovery steam economy รายงานประจำวัน | ✅ `sugar-brain` (production-data-guide) |

**สถานะ seed:** 9 ใน 12 โมดูลมีความรู้ตั้งต้นจากสกิลที่มีอยู่แล้ว (~480 KB)
อีก 3 โมดูลรอเอกสารจริงจากโรงงาน (SOP / WI / audit report)

---

## 4. โครงสร้างข้อมูล (Data Model)

### `kb_documents` — เอกสารต้นฉบับ
| คอลัมน์ | ชนิด | คำอธิบาย |
|---|---|---|
| `id` | uuid | PK |
| `module_id` | text | โมดูลเจ้าของเอกสาร |
| `title` | text | ชื่อเอกสาร |
| `doc_type` | text | `SOP` `WI` `MANUAL` `BOOK` `STANDARD` `REPORT` `PID` `LAB` |
| `doc_code` | text | รหัสเอกสาร เช่น `WI-BOIL-001` |
| `source_path` | text | ที่มาของไฟล์ |
| `lang` | text | `th` `en` `mixed` |
| `revision` | text | เวอร์ชันเอกสาร |

### `kb_chunks` — ท่อนความรู้ที่ค้นได้
| คอลัมน์ | ชนิด | คำอธิบาย |
|---|---|---|
| `id` | bigserial | PK |
| `document_id` | uuid | FK → kb_documents |
| `module_id` | text | ทำซ้ำไว้เพื่อกรองเร็ว (denormalized) |
| `section` | text | หัวข้อที่ chunk อยู่ เช่น "5.2 การปรับ pH" |
| `page_ref` | text | อ้างอิงหน้า/ย่อหน้า สำหรับ citation |
| `content` | text | เนื้อหา |
| `token_estimate` | int | ประมาณการ token |
| `embedding` | vector(1024) | เวกเตอร์ (voyage-3 = 1024 มิติ) |
| `fts` | tsvector | ดัชนีคำ (generated column) |

**เหตุผลที่ใช้ตารางเดียวแล้วกรองด้วย `module_id` แทนการแยก DB ต่อโมดูล:**
Postgres จะใช้ index scan บน `module_id` ก่อนแล้วค่อยคำนวณ vector distance
ได้ผลลัพธ์เดียวกับการแยก DB แต่ maintain ง่ายกว่ามาก และรองรับ cross-module
query ตอนที่คำถามคาบเกี่ยวสองโมดูล (เช่น "สีน้ำตาลสูงเพราะ evaporator scale?")

---

## 5. Hybrid Retrieval — ทำไมต้องผสม

| ปัญหา | Vector search | Lexical search |
|---|---|---|
| "ทำไม CCS ต่ำ" (เชิงความหมาย) | ✅ ดี | ❌ พลาด |
| "WI-BOIL-001" (รหัสเอกสาร) | ❌ พลาด | ✅ ตรง |
| "ICUMSA 45" (ศัพท์เทคนิค) | 🔶 พอได้ | ✅ ตรง |
| คำถามภาษาไทยล้วน | ✅ ดี | 🔶 ต้องใช้ trigram |

จึงรวมผลด้วย **Reciprocal Rank Fusion**:
```
score(d) = Σ  1 / (k + rank_i(d))        โดย k = 60
```
ไม่ต้องปรับ weight ระหว่างสอง search เพราะ RRF ใช้อันดับไม่ใช่คะแนนดิบ

---

## 6. การคำนวณ Confidence

ไม่ให้ LLM เดาเปอร์เซ็นต์เอง เพราะ LLM มักให้ 95% เสมอ ใช้สูตรจากหลักฐานจริง:

```
confidence = 0.45 × top1_similarity          ความใกล้ของ chunk อันดับ 1
           + 0.25 × mean(top3_similarity)     ความสม่ำเสมอของหลักฐาน
           + 0.20 × coverage                  สัดส่วนประโยคที่มี citation กำกับ
           + 0.10 × source_agreement          จำนวนเอกสารต่างฉบับที่สอดคล้องกัน
```

| ช่วง | ความหมาย | การแสดงผล |
|---|---|---|
| ≥ 0.80 | หลักฐานชัด ตอบได้มั่นใจ | เขียว |
| 0.55–0.79 | ตอบได้ แต่ควรตรวจสอบเอกสารต้นฉบับ | เหลือง |
| < 0.55 | หลักฐานไม่พอ — ระบบต้องบอกว่าไม่มีข้อมูล | แดง + ไม่สรุปคำตอบ |

---

## 7. รูปแบบคำตอบ (Answer Contract)

```
1. สรุป (Summary)              — 2–3 บรรทัด ตอบตรงคำถามก่อน
2. คำอธิบาย (Explanation)      — หลักการทางวิศวกรรม/เคมี
3. สาเหตุราก (Root Cause)      — เรียงตามความน่าจะเป็น
4. คำแนะนำ (Recommendation)    — ทำอะไร ที่จุดไหน ค่าเป้าหมายเท่าไร
5. การป้องกัน (Preventive)     — ไม่ให้เกิดซ้ำ
6. เอกสารที่เกี่ยวข้อง          — รายการเอกสารในคลัง
7. อ้างอิง (References)        — [1] ชื่อเอกสาร → หัวข้อ/หน้า
8. Confidence                  — คำนวณจากระบบ ไม่ใช่จาก LLM
```

> ส่วนที่ 3–5 จะถูกข้ามอัตโนมัติเมื่อคำถามไม่ใช่การวินิจฉัยปัญหา
> (เช่น "CCS คำนวณยังไง") เพื่อไม่ให้คำตอบยืดเยื้อโดยไม่จำเป็น

---

## 8. Tech Stack

| ชั้น | เทคโนโลยี | เหตุผล |
|---|---|---|
| Vector DB | **Supabase Postgres + pgvector** | มีอยู่แล้ว, hybrid search ในที่เดียว, RLS พร้อม |
| Backend | **Supabase Edge Functions (Deno)** | ไม่ต้องติดตั้ง Node ในเครื่อง, API key ไม่หลุดไป browser |
| LLM | **Claude Opus 5** (ตอบ) + **Haiku 4.5** (router/rerank) | คุณภาพสูงตรงจุดที่ต้องการ ประหยัดตรงที่เหลือ |
| Embedding | **voyage-3** (1024d) หรือ **voyage-multilingual-2** | รองรับไทยดี, Anthropic แนะนำ, มี free tier |
| Frontend | **Single-file HTML + Tailwind-in-CSS** | เปิดไฟล์ก็รันได้ ไม่ต้อง build |

### ทำไมไม่ใช้ embedding จาก Anthropic
Anthropic ไม่มี embedding API — ต้องใช้ผู้ให้บริการภายนอก
ระบบออกแบบให้สลับ provider ได้ผ่าน `EMBEDDING_PROVIDER` (voyage / openai / lexical-only)
โดย **`lexical-only` ใช้ได้ทันทีโดยไม่ต้องมี key เพิ่ม** เหมาะกับการ demo

---

## 9. ประมาณการต้นทุนต่อคำถาม

| ขั้นตอน | โมเดล | Token เข้า | Token ออก | ต้นทุน (USD) |
|---|---|---|---|---|
| Router | Haiku 4.5 | ~800 | ~150 | 0.0016 |
| Rerank | Haiku 4.5 | ~4,000 | ~200 | 0.0050 |
| Answer | Opus 5 | ~6,000 | ~1,200 | 0.0600 |
| **รวม** | | | | **≈ 0.067 USD ≈ 2.3 บาท** |

**ลดต้นทุนได้อีก:**
- เปิด **prompt caching** ที่ system prompt ของแต่ละ module → ลดต้นทุน input ~90%
- ใช้ **Sonnet 5** แทน Opus 5 สำหรับคำถามที่ router บอกว่าไม่ซับซ้อน → ลง ~80%
- ตั้ง `effort: "medium"` สำหรับคำถามทั่วไป

---

## 10. โรดแมป

### Phase 1 — Demo (สถานะปัจจุบัน)
- [x] Seed KB จากสกิลที่มีอยู่ 5 ตัว → 9 โมดูล
- [x] Router + Hybrid retrieval + Answer contract
- [x] UI ครบ TH/EN/LA + dark/light
- [ ] เชื่อม Supabase จริง (รอ credential จากผู้ใช้)

### Phase 2 — Production KB
- อัปโหลดเอกสารจริง: SOP, WI, P&ID, Manual, Audit report
- OCR สำหรับเอกสารสแกน
- ระบบ approve เอกสารก่อนเข้าคลัง + versioning

### Phase 3 — Multimodal
- อ่านภาพ: SCADA screenshot, P&ID, กราฟเทรนด์, ผลแล็บ
- Vision-based inspection (สีน้ำตาล, ผลึก, สภาพอุปกรณ์)

### Phase 4 — Live Data
- เชื่อม historian/SCADA → ตอบจากค่าจริงแบบ real-time
- Predictive maintenance, production forecast, energy optimization
