#!/bin/bash
# ติดตั้งระบบซิงค์ CMI บนเซิร์ฟเวอร์ AlmaLinux — รันครั้งเดียว
# ใช้: sudo bash install_server.sh
set -e

REPO_URL="https://github.com/treerat1989-beep/cmi-rh1.git"
REPO=/opt/cmi-rh1
CRED=/root/.cmi-git-credentials

echo "=== 1/6 ติดตั้งโปรแกรมที่จำเป็น ==="
dnf install -y git python3 python3-pip curl >/dev/null
# lxml/requests: ลงจาก dnf ก่อน (เร็วและไม่ต้องคอมไพล์) ถ้าไม่มีค่อยใช้ pip
dnf install -y python3-lxml python3-requests >/dev/null 2>&1 || pip3 install --quiet requests lxml
python3 -c "import requests, lxml.html" && echo "  requests + lxml พร้อมใช้งาน"

echo "=== 2/6 ดึงโค้ดจาก GitHub ==="
if [ -d "$REPO/.git" ]; then
  echo "  มีอยู่แล้วที่ $REPO — ข้าม"
else
  git clone "$REPO_URL" "$REPO"
fi
cd "$REPO"

echo "=== 3/6 ตั้งค่า token สำหรับส่งข้อมูลขึ้น GitHub ==="
if [ -s "$CRED" ]; then
  echo "  มี token เก็บไว้แล้ว — ข้าม (ถ้าจะเปลี่ยน ให้ลบไฟล์ $CRED แล้วรันใหม่)"
else
  echo
  echo "  สร้าง token ที่ https://github.com/settings/personal-access-tokens/new"
  echo "    Repository access : Only select repositories -> cmi-rh1"
  echo "    Permissions       : Contents = Read and write"
  echo "    Expiration        : No expiration (หรือ 1 ปีแล้วต่ออายุ)"
  echo
  read -rsp "  วาง token ที่นี่ (จะไม่แสดงบนจอ) แล้วกด Enter: " TOKEN
  echo
  [ -n "$TOKEN" ] || { echo "  ไม่ได้ใส่ token — หยุด"; exit 1; }
  printf 'https://x-access-token:%s@github.com\n' "$TOKEN" >"$CRED"
  chmod 600 "$CRED"
  unset TOKEN
fi
git config credential.helper "store --file=$CRED"
git config pull.rebase true

echo "=== 4/6 ติดตั้งสคริปต์ซิงค์ ==="
SYNC="$REPO/server/sync_cmi.sh"
[ -f "$SYNC" ] || { echo "  ไม่พบ $SYNC — อัปโหลดโฟลเดอร์ server ขึ้น GitHub ก่อน"; exit 1; }
chmod +x "$SYNC"
touch /var/log/cmi-sync.log

echo "=== 5/6 ตั้งเวลาอัตโนมัติ (วันที่ 1 และ 16 เวลา 08:00 น.) ==="
CRONLINE="0 8 1,16 * * $SYNC"
( crontab -l 2>/dev/null | grep -v 'sync_cmi.sh' ; echo "$CRONLINE" ) | crontab -
systemctl enable --now crond >/dev/null 2>&1 || true
crontab -l | grep sync_cmi.sh

echo "=== 6/6 ทดสอบดึงข้อมูลจริง 1 รอบ (ใช้เวลา 5-10 นาที) ==="
"$SYNC" || true
echo
tail -n 20 /var/log/cmi-sync.log
echo
echo "ติดตั้งเสร็จแล้ว"
echo "  ดูล็อก      : tail -f /var/log/cmi-sync.log"
echo "  สั่งซิงค์เอง : $SYNC"
