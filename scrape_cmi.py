#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ดึงข้อมูล PDx 3 หลัก และ DRG ของทุก รพ. ในเขตสุขภาพ จาก https://cmi.moph.go.th
แล้วสร้างไฟล์ data.json ให้แดชบอร์ด (index.html) อ่าน

ใช้งาน
    python scrape_cmi.py                 # ปีงบปัจจุบัน เขต 1 ตาม config ด้านล่าง
    python scrape_cmi.py --year 2569     # ระบุปีงบ (ใส่ พ.ศ. ได้)
    python scrape_cmi.py --region 2
    python scrape_cmi.py --out data.json

หมายเหตุ: เว็บแสดงปีงบเป็น พ.ศ. แต่ต้องส่งเป็น ค.ศ. สคริปต์แปลงให้แล้ว
"""
import argparse
import csv
import datetime as dt
import json
import re
import sys
import time

import requests
from lxml import html as LH

BASE = "https://cmi.moph.go.th"
TIMEOUT = 60
RETRIES = 3
DELAY = 0.4


def fiscal_year_be(today=None):
    """ปีงบประมาณไทยของวันนี้ (ต.ค. ขึ้นปีงบใหม่)"""
    d = today or dt.date.today()
    return d.year + 543 + (1 if d.month >= 10 else 0)


class Cmi:
    def __init__(self):
        self.s = requests.Session()
        self.s.headers.update({
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) CMI-Rh1-Sync",
            "X-Requested-With": "XMLHttpRequest",
        })
        self.csrf = None
        self.refresh()

    def refresh(self):
        r = self.s.get(f"{BASE}/report/spcl/index?menu_id=18", timeout=TIMEOUT)
        r.raise_for_status()
        r.encoding = "utf-8"
        m = re.search(r'name="_csrf"[^>]*value="([^"]+)"', r.text)
        if not m:
            raise RuntimeError("หา _csrf ไม่เจอ — เว็บอาจเปลี่ยนโครงสร้าง")
        self.csrf = m.group(1)

    def post(self, endpoint, data):
        last = None
        for attempt in range(1, RETRIES + 1):
            try:
                payload = dict(data, _csrf=self.csrf)
                r = self.s.post(f"{BASE}/report/spcl/{endpoint}", data=payload, timeout=TIMEOUT)
                if r.status_code == 500:
                    raise RuntimeError("HTTP 500")
                r.raise_for_status()
                r.encoding = "utf-8"
                return r.text
            except Exception as e:  # noqa: BLE001
                last = e
                time.sleep(1.5 * attempt)
                try:
                    self.refresh()
                except Exception:  # noqa: BLE001
                    pass
        raise RuntimeError(f"ล้มเหลวหลังลอง {RETRIES} ครั้ง: {last}")

    def options(self, endpoint, data):
        txt = self.post(endpoint, data)
        return re.findall(r"<option value='(\d+)'>([^<]+)</option>", txt)


def num(s):
    s = (s or "").replace(",", "").strip()
    if s in ("", "-"):
        return None
    try:
        return float(s)
    except ValueError:
        return None


def parse_code_table(txt, pattern):
    """คืน [(code, name, patients, adjrw, deaths, refer_in, refer_out), ...]"""
    out = []
    try:
        doc = LH.fromstring(txt)
    except Exception:  # noqa: BLE001
        return out
    for tr in doc.xpath("//tr"):
        cells = [" ".join(td.text_content().split()) for td in tr.xpath("./td|./th")]
        if len(cells) < 8 or not re.fullmatch(pattern, cells[0]):
            continue
        out.append((
            cells[0], cells[1],
            int(num(cells[2]) or 0), round(num(cells[3]) or 0, 2),
            int(num(cells[5]) or 0), int(num(cells[6]) or 0), int(num(cells[7]) or 0),
        ))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--year", type=int, help="ปีงบประมาณ (พ.ศ. หรือ ค.ศ.)")
    ap.add_argument("--region", type=int, default=1)
    ap.add_argument("--master", default="hosname.csv")
    ap.add_argument("--out", default="data.json")
    args = ap.parse_args()

    fy_be = args.year or fiscal_year_be()
    if fy_be < 2400:
        fy_be += 543
    fy_ce = fy_be - 543
    region = str(args.region)

    master = {}
    with open(args.master, encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            master[row["hcode"].strip()] = row
    print(f"ปีงบ {fy_be} (ส่ง ค.ศ. {fy_ce}) · เขต {region} · master {len(master)} แห่ง", flush=True)

    cmi = Cmi()
    hospitals = []
    for chwcode, chwname in cmi.options("chwlist", {"region": region}):
        for hcode, hospname in cmi.options("hosplist", {"region": region, "chwcode": chwcode}):
            hospitals.append({"hcode": hcode, "hospname": hospname.strip(),
                              "chwcode": chwcode, "chwname": chwname.strip()})
        time.sleep(DELAY)
    print(f"พบหน่วยบริการ {len(hospitals)} แห่ง", flush=True)

    H, PDXC, PDX, DRGC, DRG, failed = [], [], [], [], [], []
    pidx, didx = {}, {}
    for n, h in enumerate(hospitals, start=1):
        m = master.get(h["hcode"], {})
        hi = len(H)
        H.append([
            h["hcode"], m.get("hospname") or h["hospname"], h["chwname"],
            m.get("type", ""), m.get("level", ""),
            int(m.get("beds") or 0), int(m.get("pop_uc") or 0), m.get("service_group", ""),
        ])
        for endpoint, codes, rows, index, pattern in (
            ("top10pdx", PDXC, PDX, pidx, r"[A-Z]\d{2}"),
            ("drg", DRGC, DRG, didx, r"\d{5}"),
        ):
            try:
                txt = cmi.post(endpoint, {
                    "year": fy_ce, "region": region, "chwcode": h["chwcode"],
                    "hcode": h["hcode"], "hosptype": "", "servplan": "", "rdorpt": "1",
                })
            except Exception as e:  # noqa: BLE001
                failed.append(f"{h['hospname']} ({h['hcode']}) / {endpoint}: {e}")
                continue
            for code, name, pat, rw, de, ri, ro in parse_code_table(txt, pattern):
                if code not in index:
                    index[code] = len(codes)
                    codes.append([code, name])
                rows.append([hi, index[code], pat, rw, de, ri, ro])
            time.sleep(DELAY)
        if n % 20 == 0 or n == len(hospitals):
            print(f"  [{n}/{len(hospitals)}] PDx {len(PDX):,} แถว · DRG {len(DRG):,} แถว", flush=True)

    data = {
        "meta": {
            "fy": fy_be, "region": int(region),
            "run": dt.date.today().isoformat(),
            "failed": sorted(set(failed)),
            "master": "HOSNAME จากไฟล์ M and E เขตสุขภาพที่ 1 (ปชก.UC 1 เม.ย. 68, เตียงจริง กบรส.)",
        },
        "H": H, "PDXC": PDXC, "PDX": PDX, "DRGC": DRGC, "DRG": DRG, "M505": {}, "G505": [],
    }
    hosp_with_data = len({r[0] for r in DRG})
    if hosp_with_data < 0.8 * len(H):
        sys.exit(f"ได้ข้อมูลแค่ {hosp_with_data}/{len(H)} แห่ง — ไม่เขียนทับไฟล์เดิม")

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    print(f"เขียน {args.out} · {len(H)} รพ. · มีข้อมูล {hosp_with_data} แห่ง · "
          f"PDx {len(PDX):,} แถว · DRG {len(DRG):,} แถว · พลาด {len(failed)} คำขอ", flush=True)
    for x in failed[:10]:
        print("  พลาด:", x)


if __name__ == "__main__":
    main()
