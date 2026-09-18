#!/bin/bash
# ซิงค์ข้อมูล CMI เขตสุขภาพที่ 1 จาก cmi.moph.go.th ขึ้น GitHub
# รันอัตโนมัติจาก cron วันที่ 1 และ 16 เวลา 08:00 น.
# รันเองได้ด้วย: /opt/cmi-rh1/sync_cmi.sh

set -uo pipefail

REPO=/opt/cmi-rh1
LOG=/var/log/cmi-sync.log
LOCK=/var/lock/cmi-sync.lock

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG"; }

# กันไม่ให้รันซ้อนกัน
exec 9>"$LOCK"
if ! flock -n 9; then
  log "มีรอบก่อนหน้ายังทำงานอยู่ ข้ามรอบนี้"
  exit 0
fi

log "=============== เริ่มรอบซิงค์ ==============="

cd "$REPO" || { log "ไม่พบโฟลเดอร์ $REPO"; exit 1; }

# 1) ดึงโค้ดล่าสุดจาก GitHub (เผื่อมีการแก้ hosname.csv หรือสคริปต์บนเว็บ)
if git pull --rebase --autostash >>"$LOG" 2>&1; then
  log "git pull สำเร็จ"
else
  log "git pull ไม่สำเร็จ — ใช้ไฟล์ที่มีอยู่เดิมต่อ"
  git rebase --abort >/dev/null 2>&1
fi

# 2) เช็คว่าเข้าเว็บกระทรวงได้ไหม
CODE=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' \
  https://cmi.moph.go.th/report/spcl/index?menu_id=18 2>>"$LOG")
if [ "$CODE" != "200" ]; then
  log "เข้า cmi.moph.go.th ไม่ได้ (HTTP $CODE) — ยกเลิกรอบนี้ ไฟล์เดิมไม่ถูกแตะ"
  exit 1
fi
log "cmi.moph.go.th ตอบ HTTP 200"

# 3) ดึงข้อมูลลงไฟล์ชั่วคราวก่อน ยังไม่เขียนทับของจริง
TMP=$(mktemp "$REPO/.data.json.XXXXXX")
trap 'rm -f "$TMP"' EXIT

if ! python3 scrape_cmi.py --region 1 --out "$TMP" >>"$LOG" 2>&1; then
  log "สคริปต์ดึงข้อมูลล้มเหลว (หรือได้ข้อมูลไม่ถึง 80% ของ รพ.) — ไม่เขียนทับ data.json"
  exit 1
fi

# 4) ตรวจไฟล์ใหม่ก่อนใช้จริง: ต้องเป็น JSON ที่อ่านได้ และมีขนาดสมเหตุสมผล
SIZE=$(stat -c%s "$TMP")
if [ "$SIZE" -lt 500000 ]; then
  log "ไฟล์ใหม่เล็กผิดปกติ ($SIZE ไบต์) — ไม่เขียนทับ"
  exit 1
fi
if ! python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if len(d.get('H',[]))>50 and len(d.get('DRG',[]))>1000 else 1)" "$TMP" >>"$LOG" 2>&1; then
  log "ไฟล์ใหม่ไม่ผ่านการตรวจโครงสร้าง — ไม่เขียนทับ"
  exit 1
fi

mv -f "$TMP" "$REPO/data.json"
trap - EXIT
log "ได้ข้อมูลใหม่เรียบร้อย ($SIZE ไบต์)"

# 5) ส่งขึ้น GitHub เฉพาะเมื่อข้อมูลเปลี่ยนจริง
if git diff --quiet -- data.json; then
  log "ข้อมูลไม่ต่างจากเดิม ไม่ต้อง commit"
else
  git add data.json
  git -c user.name="cmi-sync" -c user.email="cmi-sync@hosoffice" \
    commit -m "sync: ข้อมูล CMI $(date '+%Y-%m-%d')" >>"$LOG" 2>&1
  if git push >>"$LOG" 2>&1; then
    log "push ขึ้น GitHub สำเร็จ — หน้าเว็บจะอัปเดตภายใน 1-2 นาที"
  else
    log "push ไม่สำเร็จ (ตรวจ token หรืออินเทอร์เน็ต) — commit ค้างไว้ในเครื่อง รอบหน้าจะส่งให้เอง"
    exit 1
  fi
fi

log "=============== จบรอบซิงค์ ==============="

# ตัดล็อกไม่ให้ยาวเกิน 5000 บรรทัด
if [ "$(wc -l <"$LOG")" -gt 5000 ]; then
  tail -n 3000 "$LOG" >"$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
fi
