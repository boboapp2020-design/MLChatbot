-- =====================================================================
--  ML Expert AI — เขียน pattern ของ th_grams เป็น Unicode escape
-- ---------------------------------------------------------------------
--  ไฟล์นี้ไม่ได้แก้บั๊ก — ฟังก์ชันเดิมใน 005 ทำงานถูกต้องอยู่แล้ว
--  บันทึกไว้เพื่อไม่ให้คนอ่านทีหลังเข้าใจผิดตามที่ผมเคยเข้าใจผิด
--
--  ที่มา (2026-08-03): ตอนทดสอบหลัง seed คลังใหม่ ผมเรียก
--    select th_grams('ปูนขาว')  -> ''
--    hybrid_search('ปูนขาว')     -> 0 แถว
--  แล้วสรุปว่าขาค้นภาษาไทยตาย ที่จริง **การทดสอบเองต่างหากที่ผิด**
--  Git Bash บน Windows ทำอักษรไทยที่ส่งเป็น argument ของ curl เพี้ยน
--  ฐานข้อมูลจึงได้รับข้อความที่ไม่ใช่ภาษาไทยตั้งแต่แรก
--  พอส่ง payload เป็นไฟล์ UTF-8 (curl --data-binary @file) ก็ได้ผลถูกต้องทันที
--    th_grams('ปูนขาว') -> 'ปูนข ูนขา นขาว'
--  บทเรียน: ทดสอบภาษาไทยผ่าน shell บน Windows ต้องส่งเป็นไฟล์เสมอ
--  อย่าเชื่อผลลัพธ์ว่างเปล่าจาก command line
--
--  สิ่งที่ไฟล์นี้เปลี่ยนจริง: เขียนช่วงอักษรไทยเป็น U&'[\0E01-\0E59]'
--  แทนการเขียน '[ก-๙]' ตรงๆ ผลลัพธ์เท่ากันทุกประการ (ยืนยันด้วยการทดสอบแล้ว)
--  แต่ pattern กลายเป็น ASCII ล้วน จึงไม่ต้องพึ่ง client_encoding ตอน push
--  เป็นการกันปัญหาล่วงหน้า ไม่ใช่การซ่อมของที่พัง
--
--  รันหลัง 006_confidence_fix.sql
-- =====================================================================

begin;

create or replace function th_grams(txt text) returns text
language sql immutable parallel safe as $fn$
  select coalesce(string_agg(g, ' '), '')
  from (
    select case
             when length(r.run) <= 4 then r.run
             else substring(r.run from i for 4)
           end as g
    from (
      select (regexp_matches(lower(coalesce(txt,'')),
                             U&'[\0E01-\0E59]{2,}', 'g'))[1] as run
    ) r,
    lateral generate_series(1, greatest(1, length(r.run) - 3)) as i
  ) x
$fn$;

-- บังคับให้ generated column คำนวณใหม่ทั้งตาราง
-- (index หายไปกับ drop column ด้วย จึงต้องสร้างใหม่)
alter table kb_chunks drop column if exists fts_th;

alter table kb_chunks
  add column fts_th tsvector
  generated always as (to_tsvector('simple', th_grams(coalesce(section,'') || ' ' || content))) stored;

create index if not exists idx_chunks_fts_th on kb_chunks using gin(fts_th);

commit;
