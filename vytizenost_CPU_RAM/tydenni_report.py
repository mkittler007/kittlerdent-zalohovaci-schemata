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
_ap.add_argument("--gate-workday", action="store_true",
                 help="odeslat jen když Martin dnes ordinuje (IS kalendář lekar_id=24); jinak exit 10")
_A = _ap.parse_args()
HOST_DIR = _A.host_dir
VM_DIR = _A.vm_dir
NOTIFY = os.path.join(HOME, "bin/notify.py")
EMAIL_TO = "martin@kittler.cz"
DAYS = _A.dny

def _is_env():
    env = {}
    with open(os.path.expanduser("~/.config/kittlerdent/credentials.env")) as f:
        for line in f:
            line = line.strip()
            if line.startswith("IS_DB_") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v.strip().strip('"').strip("'")
    return env

def ordinuje_dnes():
    """True = Martin dnes ordinuje (křeslo lekar_id=24 má reálné pacienty). Při chybě DB → True
    (fail-open: report je informativní, radši poslat než ztratit týden kvůli výpadku IS)."""
    try:
        import mysql.connector
        env = _is_env()
        cn = mysql.connector.connect(host=env["IS_DB_HOST"], database=env["IS_DB_NAME"],
                                     user=env["IS_DB_USER"], password=env["IS_DB_PASSWORD"],
                                     connection_timeout=15)
        cur = cn.cursor()
        cur.execute("""SELECT COUNT(*) FROM kalendar
                       WHERE lekar_id=24 AND DATE(datum)=CURDATE() AND client_id>0
                         AND stav NOT IN ('nepřišel','omluven','zrušen','storno')""")
        n = cur.fetchone()[0]
        cn.close()
        return n > 0
    except Exception as e:
        print(f"gate: IS kalendář nedostupný ({e}) → fail-open, report se odešle", file=sys.stderr)
        return True

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
    """Vrátí (text_bloku, stats_dict). stats slouží pro souhrnný Závěr."""
    L = [f"── {name} ──"]
    st = {"name": name, "data": bool(csv_rows)}
    if not csv_rows:
        return "\n".join(L + ["  (žádná data za období)"]), st
    total_mb = fnum(csv_rows[-1], total_from, 0)
    used = [fnum(r, used_key) for r in csv_rows]
    load = [fnum(r, "load1") for r in csv_rows]
    p50, p95, p99, mx = pctl(used,50), pctl(used,95), pctl(used,99), max(used)
    st.update(alloc_gb=gb(total_mb), p99_gb=gb(p99), max_gb=gb(mx),
              load_max=max(load), free_min=None, npeak=0, top_cpu=None, is_vm=name.startswith("VM"))
    L.append(f"  RAM used: p50={gb(p50):.1f} p95={gb(p95):.1f} p99={gb(p99):.1f} max={gb(mx):.1f} GB (přiděleno {gb(total_mb):.0f} GB)")
    L.append(f"  CPU load1: medián={pctl(load,50):.2f}  p95={pctl(load,95):.2f}  max={max(load):.2f}")
    if "free_pct" in csv_rows[0]:
        fp = [fnum(r, "free_pct", 100) for r in csv_rows if r.get("free_pct")]
        if fp:
            st["free_min"], st["free_med"] = min(fp), pctl(fp,50)
            L.append(f"  Volná paměť: min={min(fp):.0f}%  medián={pctl(fp,50):.0f}%")
    npeak, mem, cpu = parse_peaks(peak_pattern, DAYS)
    st["npeak"] = npeak
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
        st["top_cpu"] = f"{top[0][0]} {top[0][1]:.0f}%"
        L.append("  Nejvíc CPU při přetížení: " + ", ".join(f"{k} {v:.0f}%" for k,v in top))
    # doporučení RAM (jen pro VM, kde total odpovídá přidělené paměti)
    if name.startswith("VM"):
        rec = max(16, gb(p99)*1.25); rec = int(-(-rec//4))*4
        st["rec_gb"] = rec
        L.append(f"  >> Doporučená RAM pro VM: ~{rec} GB (p99 + 25% rezerva; teď {gb(total_mb):.0f} GB)")
    return "\n".join(L), st


def zaver(host, vm):
    """Slovní závěr + doporučená akce, odvozený z naměřených čísel (ne jen holá čísla)."""
    L = ["── ZÁVĚR ──"]
    # HOST
    if host.get("data"):
        pressure = host.get("free_min") is not None and host["free_min"] < 25
        if not pressure:
            fm = host.get("free_min")
            note = f"volná RAM neklesla pod {fm:.0f}%" if fm is not None else "bez známek nedostatku RAM"
            if host["npeak"]:
                drv = f" ({host['top_cpu']})" if host.get("top_cpu") else ""
                L.append(f"• HOST: bez paměťové tísně — {note}; {host['npeak']} min špiček byly CPU{drv}, ne RAM. Zdravý, bez zásahu.")
            else:
                L.append(f"• HOST: bez paměťové tísně — {note}. Zdravý, bez zásahu.")
        else:
            L.append(f"• HOST: POZOR — volná RAM klesla na {host['free_min']:.0f}% ({host['npeak']} min tísně, viník {host.get('top_cpu') or '?'}). Prověřit.")
    # VM — doporučení dimenzování
    if vm.get("data"):
        rec, alloc, p99 = vm.get("rec_gb"), vm.get("alloc_gb"), vm.get("p99_gb")
        swap_risk = (vm.get("free_min") is not None and vm["free_min"] < 25)
        if rec and alloc and rec <= alloc - 4 and not swap_risk:
            # konzervativní cíl: doporučení zaokrouhlené nahoru na násobek 4, ale min o 8 GB pod přiděleným
            target = max(rec, 28)  # neřezat pod 28 GB, dokud se neobjeví swap (viz paměť)
            target = min(target, ((alloc - 8) // 4) * 4) if alloc - 8 >= target else target
            L.append(f"• VM: working set p99={p99:.1f} GB, přiděleno {alloc:.0f} GB — předimenzováno o ~{alloc-target:.0f} GB. "
                     f"RAM lze snížit na {target:.0f} GB (uvolní hostu ~{alloc-target:.0f} GB). "
                     f"Akce: vypnout VM → prlctl set macOS --memsize {int(target*1024)}. Neřezat pod 28 GB, dokud se neobjeví swap.")
        elif swap_risk:
            L.append(f"• VM: working set p99={p99:.1f} GB / {alloc:.0f} GB, ale volná RAM na {vm['free_min']:.0f}% — RAM zatím NEsnižovat.")
        else:
            L.append(f"• VM: working set p99={p99:.1f} GB / {alloc:.0f} GB — přiděleno adekvátně, bez zásahu.")
    return "\n".join(L)

def main():
    # Gate: odeslat jen v pracovní den (Martin dnes ordinuje). Jinak exit 10 →
    # report_run.sh nezapíše weekstamp a zkusí to další den (viz feedback_email_jen_v_praci).
    if _A.gate_workday and not ordinuje_dnes():
        print("přeskočeno — Martin dnes neordinuje (volno/dovolená), report odložen na další pracovní den.")
        sys.exit(10)
    host = load_csv(os.path.join(HOST_DIR, "host_*.csv"), DAYS)
    vm = load_csv(os.path.join(VM_DIR, "vm_*.csv"), DAYS)
    now = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M")
    host_txt, host_st = machine_block("HOST (Mac Mini M4 Pro, 64 GB)", host, "used_mb",
                                      os.path.join(HOST_DIR, "peaks_host_*.log"), "total_mb")
    vm_txt, vm_st = machine_block("VM (macOS, Parallels)", vm, "used_mb",
                                  os.path.join(VM_DIR, "peaks_vm_*.log"), "total_mb")
    body = [f"Týdenní report vytíženosti RAM/CPU — {now}",
            f"Období: posledních {DAYS} dní. Interval vzorkování 60 s.\n",
            host_txt, "", vm_txt, "",
            zaver(host_st, vm_st), "",
            "Data: /volume1/Mac_mini_Pro_Logy na Synology (.120). Repo: kittlerdent-zalohovaci-schemata/vytizenost_CPU_RAM."]
    text = "\n".join(body)
    print(text)
    if os.path.exists(NOTIFY):
        # Jen e-mail (--email-to) — Martin výslovně chce report pouze mailem, ne na Telegram.
        # notify.py drží outbox retry i pro e-mail (pojistka zachována), jen bez cross-kanálu.
        subprocess.run([sys.executable, NOTIFY, "--email-to", EMAIL_TO,
                        "--subject", "Vytíženost RAM/CPU — týdenní report (host + VM)",
                        "--body", text, "--key", "moncpuram_weekly"], check=False)
    else:
        print("POZOR: notify.py nenalezen, report neodeslán.", file=sys.stderr)

if __name__ == "__main__":
    main()
