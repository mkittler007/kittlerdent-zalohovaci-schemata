#!/usr/bin/env python3
# Vyhodnocení vytíženosti RAM/CPU — doporučí novou hodnotu RAM pro VM
# a ověří chování během zálohy (fáze "backup").
#
# Použití:
#   python3 vyhodnot.py [--vm-dir DIR] [--host-dir DIR] [--dny N]
# Bez argumentů čte lokální ~/monitoring/cpuram (spouštět na tom stroji,
# kde logy jsou, nebo předat cesty ke staženým logům).
import argparse, csv, glob, os, statistics as st
from datetime import datetime, timedelta

def parse_ts(s):
    # Python 3.9 fromisoformat neumí offset '+0200' bez dvojtečky → doplníme ji.
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        if len(s) >= 5 and s[-5] in "+-" and s[-3] != ":":
            return datetime.fromisoformat(s[:-2] + ":" + s[-2:])
        raise

def load(pattern, days):
    rows = []
    cutoff = datetime.now().astimezone() - timedelta(days=days)
    for fp in sorted(glob.glob(pattern)):
        with open(fp, newline="") as f:
            for r in csv.DictReader(f):
                try:
                    t = parse_ts(r["ts"])
                except Exception:
                    continue
                if t >= cutoff:
                    rows.append(r)
    return rows

def pct(vals, p):
    if not vals:
        return 0.0
    vals = sorted(vals)
    k = (len(vals) - 1) * p / 100.0
    lo = int(k)
    hi = min(lo + 1, len(vals) - 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (k - lo)

def gb(mb):
    return mb / 1024.0

def main():
    ap = argparse.ArgumentParser()
    home = os.path.expanduser("~/monitoring/cpuram")
    ap.add_argument("--vm-dir", default=home)
    ap.add_argument("--host-dir", default=home)
    ap.add_argument("--dny", type=int, default=90)
    a = ap.parse_args()

    vm = load(os.path.join(a.vm_dir, "vm_*.csv"), a.dny)
    host = load(os.path.join(a.host_dir, "host_*.csv"), a.dny)

    print(f"== Vyhodnocení za posledních {a.dny} dní ==")
    if vm:
        used = [float(r["used_mb"]) for r in vm if r.get("used_mb")]
        swap = [float(r["swap_used_mb"]) for r in vm if r.get("swap_used_mb")]
        total_gb = gb(float(vm[-1]["total_mb"]))
        p50, p95, p99, mx = pct(used, 50), pct(used, 95), pct(used, 99), max(used)
        print(f"\nGUEST RAM working set (used = active+wired+compressed), přiděleno {total_gb:.0f} GB:")
        print(f"  p50={gb(p50):.1f} GB  p95={gb(p95):.1f} GB  p99={gb(p99):.1f} GB  max={gb(mx):.1f} GB")
        print(f"  swap max = {max(swap) if swap else 0:.0f} MB   vzorků: {len(used)}")
        # doporučení: p99 + 25 % rezerva, zaokrouhleno nahoru na 4 GB, min 16
        rec = max(16, gb(p99) * 1.25)
        rec = int(-(-rec // 4)) * 4
        print(f"  >> DOPORUČENÁ RAM pro VM: ~{rec} GB (p99 + 25% rezerva)")
        if max(swap) if swap else 0 > 100:
            print("  !! Guest reálně swapoval — nesnižovat pod aktuální working set.")
    else:
        print("Guest: žádná data.")

    if host:
        fp = [float(r["free_pct"]) for r in host if r.get("free_pct")]
        hsw = [float(r["swap_used_mb"]) for r in host if r.get("swap_used_mb")]
        print(f"\nHOST zdraví (64 GB):")
        print(f"  free% min={min(fp) if fp else 0:.0f}  p05={pct(fp,5):.0f}  medián={pct(fp,50):.0f}")
        print(f"  host swap max = {max(hsw) if hsw else 0:.0f} MB")
        bk = [r for r in host if r.get("phase") == "backup"]
        if bk:
            bfp = [float(r["free_pct"]) for r in bk if r.get("free_pct")]
            print(f"  během ZÁLOHY: free% min={min(bfp) if bfp else 0:.0f}  vzorků={len(bk)}")
        else:
            print("  během zálohy: zatím žádné vzorky (fáze 'backup' se ještě neoznačila).")
    else:
        print("\nHost: žádná data.")

if __name__ == "__main__":
    main()
