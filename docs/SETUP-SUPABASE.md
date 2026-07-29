# ติดตั้งโหมด Production (ผ่าน Supabase)

โหมดนี้ย้าย API key ไปไว้ฝั่งเซิร์ฟเวอร์ ผู้ใช้เปิดเว็บแล้วถามได้เลยโดยไม่ต้องมี key ของตัวเอง

**ใช้เวลาประมาณ 30–45 นาที** ทำครั้งเดียวจบ

---

## ⚠️ อ่านก่อนเริ่ม

โหมดนี้แปลว่า **คุณจ่ายค่า API ให้ทุกคนที่เข้าเว็บได้**

ถ้าเว็บยังอยู่บน GitHub Pages สาธารณะ ใครเจอ URL ก็ใช้ได้ ควรทำอย่างน้อยข้อใดข้อหนึ่งก่อน

- ตั้งเพดานค่าใช้จ่ายที่หน้า Billing ของผู้ให้บริการ AI
- เลือกผู้ให้บริการที่มีโควตาฟรี (Gemini / Groq) — เกินโควตาแล้วหยุดเอง ไม่มีบิล
- ย้ายเว็บไปหลังระบบล็อกอิน (เช่น Cloudflare Access ฟรี 50 คน)

---

## สิ่งที่ต้องมี

| รายการ | จำเป็น | หมายเหตุ |
|---|---|---|
| บัญชี Supabase | ✅ | ฟรี — supabase.com |
| API key ของผู้ให้บริการ AI 1 เจ้า | ✅ | เลือกได้ตามตารางข้างล่าง |
| Voyage AI key | ❌ | ไม่มีก็ได้ ระบบจะค้นแบบ keyword อย่างเดียว |

---

## ขั้นที่ 1 — สร้างโปรเจกต์ Supabase

1. เข้า https://supabase.com → **New project**
2. ตั้งชื่อ เช่น `ml-expert-ai` → เลือก region **Southeast Asia (Singapore)** ใกล้ไทยที่สุด
3. ตั้งรหัสฐานข้อมูล → **เก็บไว้ให้ดี** ใช้ตอนเชื่อมด้วย CLI
4. รอสร้างเสร็จ ~2 นาที

---

## ขั้นที่ 2 — สร้างตารางและใส่คลังความรู้

ไปที่เมนู **SQL Editor** ทางซ้าย แล้วรันไฟล์ตามลำดับ

### 2.1 โครงสร้างฐานข้อมูล

เปิดไฟล์ในเครื่อง → คัดลอกทั้งหมด → วางใน SQL Editor → กด **Run**

```
supabase/migrations/001_init.sql      (สร้างตาราง + ฟังก์ชันค้นหา)
supabase/migrations/002_modules.sql   (ผู้เชี่ยวชาญ 15 คน)
supabase/migrations/004_personas.sql  (บุคลิกจากสกิล)
```

### 2.2 คลังความรู้ — ต้องแบ่งไฟล์ก่อน

ไฟล์ `003_seed_kb.sql` ขนาด **5 MB / 37,000 บรรทัด** วางทีเดียวไม่ได้ หน้าเว็บจะค้าง

รันคำสั่งนี้เพื่อแบ่งเป็นไฟล์ย่อย

```bash
powershell -ExecutionPolicy Bypass -File "scripts\split-sql.ps1"
```

ได้ 6 ไฟล์ที่ `supabase/migrations/003_parts/` แล้ววางทีละไฟล์ตามลำดับ part01 → part06

> แต่ละไฟล์เป็นทรานแซกชันของตัวเอง ถ้าไฟล์ไหน error รันซ้ำเฉพาะไฟล์นั้นได้เลย
> ถ้าจะเริ่มใหม่ทั้งหมด ให้เริ่มจาก part01 (มีคำสั่งล้างข้อมูลเดิมอยู่)

### 2.3 ตรวจว่าเข้าครบ

```sql
select * from kb_stats();
```

ต้องเห็นผู้เชี่ยวชาญ 15 คน และจำนวนท่อนรวมประมาณ 2,300 กว่า

---

## ขั้นที่ 3 — เลือกผู้ให้บริการ AI

รองรับ 5 เจ้า + กำหนดเองได้ เลือก 1 อย่าง

| ผู้ให้บริการ | `LLM_PROVIDER` | ฟรีไหม | รับ key ที่ |
|---|---|---|---|
| **Google Gemini** | `gemini` | ✅ ~250–1,000 คำถาม/วัน | aistudio.google.com/apikey |
| **Groq** | `groq` | ✅ ~14,400 คำถาม/วัน | console.groq.com/keys |
| **OpenRouter** | `openrouter` | ✅ เฉพาะโมเดล `:free` | openrouter.ai/keys |
| **Anthropic (Claude)** | `anthropic` | ❌ | console.anthropic.com |
| **DeepSeek** | `deepseek` | ❌ ถูกที่สุด | platform.deepseek.com |
| อื่นๆ | `custom` | — | ต้องตั้ง `LLM_BASE_URL` เอง |

**แนะนำเริ่มที่ Gemini** เพราะฟรีและภาษาไทยดีที่สุดในกลุ่มฟรี

---

## ขั้นที่ 4 — ติดตั้ง Edge Function

### ถ้ายังไม่มี Supabase CLI

```bash
npm install -g supabase
```

ไม่มี Node ในเครื่อง? ดาวน์โหลดไฟล์ .exe จาก https://github.com/supabase/cli/releases

### เชื่อมโปรเจกต์และ deploy

```bash
supabase login
```

```bash
supabase link --project-ref YOUR_PROJECT_REF
```

> หา `project-ref` ได้จาก URL ของหน้า dashboard: `supabase.com/dashboard/project/xxxxx` ← ตรง xxxxx

```bash
supabase functions deploy ask --no-verify-jwt
```

> `--no-verify-jwt` จำเป็น เพราะผู้ใช้ไม่ได้ล็อกอิน Supabase — ใช้ anon key เรียกตรง

---

## ขั้นที่ 5 — ใส่ความลับ (Secrets)

ในหน้า Supabase → **Edge Functions** → **Secrets** → เพิ่มทีละตัว

| ชื่อ | ค่า | จำเป็น |
|---|---|---|
| `LLM_PROVIDER` | `gemini` (หรือเจ้าที่เลือก) | ✅ |
| `LLM_API_KEY` | key ของเจ้านั้น | ✅ |
| `MODEL_ANSWER` | ชื่อโมเดลที่ใช้ตอบ | ❌ มีค่าเริ่มต้นให้ |
| `MODEL_ROUTER` | โมเดลจัดเส้นทาง (ใช้ตัวถูก) | ❌ |
| `MODEL_RERANK` | โมเดลจัดอันดับ (ใช้ตัวถูก) | ❌ |
| `LLM_BASE_URL` | เฉพาะเมื่อ `LLM_PROVIDER=custom` | ❌ |
| `SITE_URL` | URL เว็บคุณ (OpenRouter ขอ) | ❌ |
| `VOYAGE_API_KEY` | เปิดการค้นเชิงความหมาย | ❌ |

หรือสั่งจากคอมมานด์ไลน์

```bash
supabase secrets set LLM_PROVIDER=gemini LLM_API_KEY=AIzaxxxxx
```

### ค่าเริ่มต้นของชื่อโมเดลแต่ละเจ้า

| เจ้า | ตอบ | จัดเส้นทาง / จัดอันดับ |
|---|---|---|
| anthropic | `claude-opus-5` | `claude-haiku-4-5` |
| gemini | `gemini-3.6-flash` | `gemini-3.5-flash-lite` |
| groq | `qwen/qwen3-32b` | `llama-3.1-8b-instant` |
| openrouter | `qwen/qwen3.7-flash` | `google/gemma-4-31b-it:free` |
| deepseek | `deepseek-chat` | `deepseek-chat` |

> ชื่อรุ่นเปลี่ยนบ่อยมาก ถ้าเจอ error 404 ให้ตั้ง `MODEL_ANSWER` ทับด้วยชื่อที่ใช้ได้จริง
> ดูรายชื่อได้จากปุ่ม "โหลดรายชื่อโมเดล" ในหน้าตั้งค่าของแอป (โหมดต่อตรง)

---

## ขั้นที่ 6 — ตั้งค่าในแอป

1. เปิดเว็บ → กดปุ่มเฟือง (หน้าตั้งค่าเปิดได้เลย ไม่มีรหัสผ่าน)
2. เลือก **Production — ผ่าน Supabase**
3. ใส่ค่า 2 ตัวจากหน้า Supabase → **Settings → API**

| ช่อง | เอามาจาก |
|---|---|
| Supabase Project URL | Project URL (`https://xxxxx.supabase.co`) |
| Supabase Anon Key | `anon` `public` key |

> ⚠️ ใช้ **anon key เท่านั้น** ห้ามใส่ `service_role` key เด็ดขาด — ตัวนั้นเปิดฐานข้อมูลได้ทั้งหมด

4. กดบันทึก แล้วลองถามคำถาม

---

## ตรวจว่าใช้ได้จริง

ถามคำถามที่รู้คำตอบอยู่แล้ว เช่น *"ค่า pH หลังทำใสควรอยู่เท่าไร"*

ต้องได้: คำตอบไหลออกมาทีละคำ + มีเอกสารอ้างอิง + มีคะแนนความมั่นใจ

### ถ้าไม่ได้ ดู log ก่อน

Supabase → **Edge Functions** → `ask` → **Logs**

| อาการ | สาเหตุที่พบบ่อย |
|---|---|
| `ยังไม่ได้ตั้ง LLM_API_KEY` | ยังไม่ได้ใส่ secret หรือใส่แล้วไม่ได้ deploy ใหม่ |
| `404` จากผู้ให้บริการ | ชื่อโมเดลผิด — ตั้ง `MODEL_ANSWER` ทับ |
| `401` | key ผิดหรือถูกเพิกถอน |
| `429` | เกินโควตา รอสักครู่ |
| ตอบว่าไม่พบเอกสาร | ยังไม่ได้รัน `003_parts` ครบทุกไฟล์ — เช็คด้วย `select * from kb_stats();` |
| CORS error ในเบราว์เซอร์ | ลืมใส่ `--no-verify-jwt` ตอน deploy |

---

## อัปเดตคลังความรู้ในภายหลัง

เมื่อเพิ่มเอกสารใหม่แล้วรัน `build-kb.ps1` ไฟล์ `003_seed_kb.sql` จะถูกสร้างใหม่

```bash
powershell -ExecutionPolicy Bypass -File "scripts\split-sql.ps1"
```

แล้วรัน part01–part06 ใหม่ทั้งชุด — part01 มีคำสั่งล้างของเดิมอยู่แล้ว จึงไม่เกิดข้อมูลซ้ำ

---

## ข้อจำกัดที่ยังเหลืออยู่

Edge Function ตอนนี้**ยังไม่มี**

- การจำกัดจำนวนคำถามต่อคน (rate limit)
- การจำกัดว่าเรียกได้จากเว็บไหน (ตอนนี้เปิดหมด)

ถ้าจะเปิดให้คนนอกใช้ ควรเพิ่ม 2 อย่างนี้ก่อน
