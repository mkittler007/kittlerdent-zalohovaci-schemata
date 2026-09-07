#!/usr/bin/env python3
# Týdenní report vytíženosti RAM/CPU (host + VM) -> e-mail na martin@kittler.cz přes notify.py.
# Běží na HOSTU (.24) v pondělí ráno. Čte:
#   host: ~/monitoring/cpuram/{host_*.csv, peaks_host_*.log}
#   vm  : ~/monitoring/cpuram_from_vm/{vm_*.csv, peaks_vm_*.log}   (staging z VM)
import argparse, csv, glob, os, re, subprocess, sys
from collections import defaultdict
from datetime import datetime, timedelta

HOME = os.path.expanduser("~")
# Report běží ve VM (kde je notify.py). VM logy = lokální, host logy = stažené přes SSH.
_ap = argparse.ArgumentParser()
_ap.add_argument("--vm-dir", default=os.path.join(HOME, "monitoring/cpuram"))
_ap.add_argument("--host-dir", default=os.path.join(HOME, "monitoring/cpuram_host"))
_ap.add_argument("--dny", type=int, default=7)
_A = _ap.parse_args()
HOST_DIR = _A.host_dir
VM_DIR = _A.vm_dir
NOTIFY = os.path.join(HOME, "bin/notify.py")
EMAIL_TO = "martin@kittler.cz"
DAYS = _A.dny

def parse_ts(s):
    # Python 3.9 fromisoformat neumí offset '+0200' bez dvojtečky → doplníme ji.
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        if len(s) >= 5 and s[-5] in "+-" and s[-3] != ":":
            return datetime.fromisoformat(s[:-2] + ":" + s[-2:])
        raise

def load_csv(pattern, days):
    rows, cutoff = [], datetime.now().astimezone() - timedelta(days=days)
    for fp in sorted(glob.glob(pattern)):
        try:
            with open(fp, newline="") as f:
                for r in csv.DictReader(f):
                    try:
                        if parse_ts(r["ts"]) >= cutoff:
                            rows.append(r)
                    except Exception:
                        pass
        except Exception:
            pass
    return rows

def fnum(r, k, d=0.0):
    try:
        return float(r.get(k) or d)
    except Exception:
        return d

def pctl(v, p):
    if not v:
        return 0.0
    v = sorted(v); k = (len(v)-1)*p/100.0; lo = int(k); hi = min(lo+1, len(v)-1)
    return v[lo] + (v[hi]-v[lo])*(k-lo)

def parse_peaks(pattern, days):
    """Vrátí (počet_špičkových_vzorků, {proces: max_MB}, {proces: max_CPU})."""
    cutoff = datetime.now().astimezone() - timedelta(days=days)
    mem, cpu, n = defaultdict(float), defaultdict(float), 0
    for fp in sorted(glob.glob(pattern)):
        try:
            for ln in open(fp):
                parts = ln.strip().split("|")
                if len(parts) < 5:
                    continue
                try:
                    if parse_ts(parts[0]) < cutoff:
                        continue
                except Exception:
                    continue
                n += 1
                for name, val in re.findall(r'(\S+?)\((\d+)MB\)', parts[3]):
                    mem[name] = max(mem[name], float(val))
                for name, val in re.findall(r'(\S+?)\((\d+)%\)', parts[4]):
                    cpu[name] = max(cpu[name], float(val))
        except Exception:
            pass
    return n, mem, cpu

def gb(mb):
    return mb/1024.0

def machine_block(name, csv_rows, used_key, peak_pattern, total_from):
    L = [f"── {name} ──"]
    if not csv_rows:
        return "\n".join(L + ["  (žádná data za období)"])
    total_mb = fnum(csv_rows[-1], total_from, 0)
    used = [fnum(r, used_key) for r in csv_rows]
    load = [fnum(r, "load1") for r in csv_rows]
    p50, p95, p99, mx = pctl(used,50), pctl(used,95), pctl(used,99), max(used)
    L.append(f"  RAM used: p50={gb(p50):.1f} p95={gb(p95):.1f} p99={gb(p99):.1f} max={gb(mx):.1f} GB (přiděleno {gb(total_mb):.0f} GB)")
    L.append(f"  CPU load1: medián={pctl(load,50):.2f}  p95={pctl(load,95):.2f}  max={max(load):.2f}")
    if "free_pct" in csv_rows[0]:
        fp = [fnum(r, "free_pct", 100) for r in csv_rows if r.get("free_pct")]
        if fp:
            L.append(f"  Volná paměť: min={min(fp):.0f}%  medián={pctl(fp,50):.0f}%")
    npeak, mem, cpu = parse_peaks(peak_pattern, DAYS)
    mins = npeak  # 1 vzorek = 1 min (interval 60 s)
    if npeak:
        L.append(f"  Přetížení (reálná tíseň): {npeak} vzorků ≈ {mins} min za {DAYS} dní")
    else:
        L.append(f"  Přetížení (reálná tíseň): 0 min za {DAYS} dní — bez tísně")
    if mem:
        top = sorted(mem.items(), key=lambda x: -x[1])[:6]
        L.append("  Nejvíc RAM při přetížení (RSS vč. mapované): " + ", ".join(f"{k} {v:.0f}MB" for k,v in top))
    if cpu:
        top = sorted(cpu.items(), key=lambda x: -x[1])[:6]
        L.append("  Nejvíc CPU při přetížení: " + ", ".join(f"{k} {v:.0f}%" for k,v in top))
    # doporučení RAM (jen pro VM, kde total odpovídá přidělené paměti)
    if name.startswith("VM"):
        rec = max(16, gb(p99)*1.25); rec = int(-(-rec//4))*4
        L.append(f"  >> Doporučená RAM pro VM: ~{rec} GB (p99 + 25% rezerva; teď {gb(total_mb):.0f} GB)")
    return "\n".join(L)

def main():
    host = load_csv(os.path.join(HOST_DIR, "host_*.csv"), DAYS)
    vm = load_csv(os.path.join(VM_DIR, "vm_*.csv"), DAYS)
    now = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M")
    body = [f"Týdenní report vytíženosti RAM/CPU — {now}",
            f"Období: posledních {DAYS} dní. Interval vzorkování 60 s.\n",
            machine_block("HOST (Mac Mini M4 Pro, 64 GB)", host, "used_mb",
                          os.path.join(HOST_DIR, "peaks_host_*.log"), "total_mb"),
            "",
            machine_block("VM (macOS, Parallels)", vm, "used_mb",
                          os.path.join(VM_DIR, "peaks_vm_*.log"), "total_mb"),
            "",
            "Data: /volume1/Mac_mini_Pro_Logy na Synology (.120). Repo: kittlerdent-zalohovaci-schemata/vytizenost_CPU_RAM."]
    text = "\n".join(body)
    print(text)
    if os.path.exists(NOTIFY):
        # --to martin = telegram-first s plným fallbackem (Telegram→e-mail→iMessage),
        # pingne telefon; dřívější --email-to obcházelo routing (jen e-mail, bez pojistky).
        subprocess.run([sys.executable, NOTIFY, "--to", "martin",
                        "--subject", "Vytíženost RAM/CPU — týdenní report (host + VM)",
                        "--body", text, "--key", "moncpuram_weekly"], check=False)
    else:
        print("POZOR: notify.py nenalezen, report neodeslán.", file=sys.stderr)

if __name__ == "__main__":
    main()
