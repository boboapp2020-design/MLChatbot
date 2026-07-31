-- =====================================================================
--  ML Expert AI — ทะเบียน 9 Expert Modules
--  รันหลังจาก 001_init.sql
--
--  persona ในไฟล์นี้เป็นแค่ค่าตั้งต้น (คอลัมน์ persona เป็น not null)
--  ตัวจริงมาจาก 004_personas.sql ที่สร้างด้วย scripts\build-personas.ps1
--  แก้ persona ที่ scripts\build-personas.ps1 เท่านั้น อย่าแก้ที่นี่
-- =====================================================================

-- ลบห้องเดิมที่ยุบไปแล้ว (หีบ ทำใส ระเหย เคี่ยว ปั่น บำรุงรักษา คลัง วิเคราะห์ข้อมูล)
-- on delete cascade จะลบเอกสาร/ท่อนความรู้ของห้องเหล่านั้นตามไปด้วย
-- ซึ่งถูกต้องแล้ว เพราะ 003_seed_kb.sql จะโหลดใหม่ทั้งชุดโดยจัดเข้าห้อง factory
delete from modules
 where id not in ('cane','factory','quality','etreatment','powerplant',
                  'safety','foodsafety','hr','law');

insert into modules (id, name_th, name_en, icon, sort_order, keywords, persona) values

('cane', 'ผู้เชี่ยวชาญอ้อย', 'Cane Expert', '🌱', 10,
 array['อ้อย','พันธุ์','ปลูก','ตอ','ไว้ตอ','ปุ๋ย','ดิน','โรค','แมลง','วัชพืช','แปลง','ไร่',
       'เก็บเกี่ยว','CCS','ความหวาน','ตันต่อไร่','อ้อยไฟไหม้','ใบอ้อย','ratoon','variety',
       'soil','fertilizer','disease','pest','yield','harvest','ความสุกแก่','ท่อนพันธุ์'],
 'คุณคือผู้เชี่ยวชาญอ้อย (Cane Expert) ในทีม ML Expert AI'),

('factory', 'ผู้เชี่ยวชาญโรงงาน', 'Factory Expert', '🏭', 20,
 array['หีบ','ลูกหีบ','mill','milling','imbibition','extraction','ชานอ้อย','bagasse','fiber',
       'ทำใส','clarifier','clarification','ปูน','lime','flocculant','ตะกอน','mud','filter press',
       'ระเหย','evaporator','steam economy','ตะกรัน','scale','condensate','ไซรัป','syrup',
       'หม้อเคี่ยว','เคี่ยว','vacuum pan','ผลึก','crystal','supersaturation','false grain',
       'massecuite','ปั่น','centrifugal','น้ำล้าง','purging','molasses','กากน้ำตาล',
       'แบริ่ง','bearing','vibration','alignment','หล่อลื่น','ปั๊ม','pump','มอเตอร์','motor',
       'ซ่อมบำรุง','maintenance','คลัง','warehouse','สต็อก','FIFO','จัดซื้อ','procurement',
       'KPI','OEE','recovery','BHR','benchmark','downtime','undetermined loss'],
 'คุณคือผู้เชี่ยวชาญโรงงาน (Factory Expert) ในทีม ML Expert AI'),

('quality', 'ผู้เชี่ยวชาญห้องปฏิบัติการ', 'Lab & Analysis Expert', '🧪', 30,
 array['ICUMSA','Pol','Brix','Purity','ความบริสุทธิ์','สี','color','ash','เถ้า','moisture',
       'ความชื้น','reducing sugar','conductivity','มอก','spec','สเปก','dextran','starch','SO2',
       'แล็บ','laboratory','particle size','grain size','caking','ผลวิเคราะห์'],
 'คุณคือผู้เชี่ยวชาญห้องปฏิบัติการ (Lab & Analysis Expert) ในทีม ML Expert AI'),

('etreatment', 'ผู้เชี่ยวชาญสิ่งแวดล้อม', 'Environment Expert', '🌿', 40,
 array['บำบัดน้ำเสีย','wastewater','น้ำทิ้ง','BOD','COD','บ่อบำบัด','สิ่งแวดล้อม','environment',
       'effluent','aeration','เติมอากาศ','บ่อผึ่ง','คุณภาพน้ำทิ้ง','มลพิษ','recycle water',
       'น้ำหมุนเวียน','ISO 14001'],
 'คุณคือผู้เชี่ยวชาญสิ่งแวดล้อม (Environment Expert) ในทีม ML Expert AI'),

('powerplant', 'ผู้เชี่ยวชาญโรงไฟฟ้าชีวมวล', 'Power Plant Expert', '⚡', 50,
 array['หม้อไอน้ำ','boiler','กังหัน','turbine','generator','superheater','economizer',
       'deaerator','feed water','น้ำป้อน','blowdown','excess air','ไอเสีย','flue gas','GCV',
       'cogeneration','trip','condenser','โรงไฟฟ้า','เชื้อเพลิง','ผลิตไฟฟ้า'],
 'คุณคือผู้เชี่ยวชาญโรงไฟฟ้าชีวมวล (Power Plant Expert) ในทีม ML Expert AI'),

('safety', 'ผู้เชี่ยวชาญความปลอดภัย', 'Safety Expert', '🛡️', 60,
 array['ความปลอดภัย','safety','อุบัติเหตุ','accident','PPE','อุปกรณ์ป้องกัน','LOTO','lockout',
       'tagout','confined space','ที่อับอากาศ','safety valve','วาล์วนิรภัย','ตรวจสอบตามกฎหมาย',
       'อาชีวอนามัย','occupational','ดับเพลิง','fire','JSA','งานเสี่ยง','permit to work',
       'near miss'],
 'คุณคือผู้เชี่ยวชาญความปลอดภัย (Safety Expert) ในทีม ML Expert AI'),

('foodsafety', 'ผู้เชี่ยวชาญคุณภาพและมาตรฐาน', 'QA & Standards Expert', '📋', 70,
 array['FSSC','ISO 22000','ISO 9001','ISO 14001','HACCP','GMP','PRP','OPRP','SMETA','HALAL',
       'KOSHER','audit','ตรวจประเมิน','CAR','NCR','ข้อบกพร่อง','corrective action','CCP',
       'จุดวิกฤต','traceability','สอบกลับ','recall','เรียกคืน','allergen','สิ่งแปลกปลอม',
       'ความปลอดภัยอาหาร','มาตรฐาน'],
 'คุณคือผู้เชี่ยวชาญคุณภาพและมาตรฐาน (QA & Standards Expert) ในทีม ML Expert AI'),

('hr', 'ผู้เชี่ยวชาญทรัพยากรบุคคล', 'HR Expert', '👥', 80,
 array['บุคลากร','พนักงาน','HR','human resource','ทรัพยากรบุคคล','สวัสดิการ','ฝึกอบรม',
       'training','ประเมินผล','แรงงาน','กฎหมายแรงงาน','สรรหา','recruitment','โครงสร้างองค์กร',
       'กะทำงาน','shift','OT','ค่าจ้าง','competency','สมรรถนะ'],
 'คุณคือผู้เชี่ยวชาญทรัพยากรบุคคล (HR Expert) ในทีม ML Expert AI'),

('law', 'ผู้เชี่ยวชาญกฎหมาย สปป.ลาว', 'Lao Law Expert', '⚖️', 90,
 array['กฎหมาย','กฎหมายลาว','สปป.ลาว','ลาว','Lao PDR','ดำรัส','พระราชกฤษฎีกา',
       'กฎหมายว่าด้วย','รัฐบาลลาว','สัมปทาน','ใบอนุญาต','ลงทุน','ส่งเสริมการลงทุน','ภาษี',
       'อากร','ศุลกากร','นำเข้า','ส่งออก','วีซ่า','ใบอนุญาตทำงาน','นิติกรรม','สัญญา',
       'ข้อพิพาท','ที่ดิน','วิสาหกิจ','ระเบียบ'],
 'คุณคือผู้เชี่ยวชาญกฎหมาย สปป.ลาว (Lao Law Expert) ในทีม ML Expert AI')

on conflict (id) do update set
  name_th    = excluded.name_th,
  name_en    = excluded.name_en,
  icon       = excluded.icon,
  sort_order = excluded.sort_order,
  keywords   = excluded.keywords;
