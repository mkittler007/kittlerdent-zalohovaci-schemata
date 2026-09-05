#!/usr/bin/env python3
"""
Hlídač ROTACE Time Machine na WD ("My Book", host Mac Mini .24).

Zadání Martina (5.9.2026): TM na WD jede 1x denně a má nastavenou kvótu.
Až se kvóta naplní, TM začne mazat nejstarší zálohy. Tenhle hlídač to detekuje
a NAPÍŠE Martinovi:
  - KDY rotace poprvé nastala,
  - OD KTERÉHO DATA se verze maže (která nejstarší verze zmizela),
  - kolik verzí se teď drží a jaký je rozsah historie,
  - kolik volného místa na disku zbývá.
Podle toho se pak zálohování případně upraví (kvóta / disk WD Backup 8 na 5 TB).

Bez root: `tmutil listbackups` i `df` fungují jako uživatel; notifikace přes notify.py.
Anti-spam: notify.py --key (heartbeat/dedup). Stav v ~/.tm_wd_rotation.state.
"""
import os, json, subprocess, shutil, sys
from datetime import datetime

STATE = os.path.expanduser("~/.tm_wd_rotation.state")
NOTIFY = os.path.expanduser("~/bin/notify.py")
TM_VOLUME = "/Volumes/My Book"
LOW_FREE_GB = 300   # když volno < tohle -> jeden včasný "blíží se ke kvótě" alert


def listbackups():
    try:
        out = subprocess.run(["/usr/bin/tmutil", "listbackups"],
                             capture_output=True, text=True, timeout=180)
    except Exception:
        return []
    stamps = []
    for line in out.stdout.splitlines():
        base = os.path.basename(line.strip().rstrip("/"))
        m = base.split(".")[0]              # 2026-09-05-085022.backup -> 2026-09-05-085022
        if len(m) == 17 and m[:4].isdigit():
            stamps.append(m)
    return sorted(set(stamps))


def free_gb(path):
    try:
        _, _, f = shutil.disk_usage(path)
        return round(f / (1024**3))
    except Exception:
        return None


def fmt(stamp):
    try:
        return datetime.strptime(stamp, "%Y-%m-%d-%H%M%S").strftime("%-d.%-m.%Y %H:%M")
    except Exception:
        return stamp


def notify(subject, body, key, critical=False):
    args = [sys.executable, NOTIFY, "--to", "martin",
            "--subject", subject, "--body", body, "--key", key]
    if critical:
        args += ["--priority", "critical"]
    try:
        subprocess.run(args, timeout=180)
    except Exception:
        pass


def main():
    stamps = listbackups()
    if not stamps:
        return  # TM disk možná odpojený; stav TM řeší jiný agent (timemachine_watchdog)
    oldest, newest, count = stamps[0], stamps[-1], len(stamps)
    free = free_gb(TM_VOLUME)

    state = {}
    if os.path.exists(STATE):
        try:
            state = json.load(open(STATE))
        except Exception:
            state = {}
    prev_oldest = state.get("oldest")
    low_warned = state.get("low_warned", False)

    rotated = bool(prev_oldest and oldest > prev_oldest)

    # 1) ROTACE: nejstarší se posunula => TM smazal starší verze
    if rotated:
        body = ("Time Machine na WD ('My Book') začala ROTOVAT — kvóta se naplnila "
                "a maže nejstarší zálohy.\n\n"
                f"Smazána nejstarší verze z: {fmt(prev_oldest)}\n"
                f"Nejstarší nyní držená:     {fmt(oldest)}\n"
                f"Nejnovější:                {fmt(newest)}\n"
                f"Drží se verzí:             {count}\n"
                f"Volno na disku:            {free} GB\n\n"
                "Od teď se každý den odmaže nejstarší den. Podle toho můžeme upravit "
                "kvótu/disk (WD Backup 8 na 5 TB TM, VM jinam).")
        notify("WD Time Machine: začala rotace (mažou se nejstarší verze)", body,
               key="tm_wd_rotation_start")

    # 2) Včasné varování: blíží se ke kvótě (jednou), jen pokud zrovna nerotovala
    if free is not None and free < LOW_FREE_GB and not low_warned and not rotated:
        notify("WD Time Machine: blíží se kvótě",
               f"Volno na 'My Book' už jen {free} GB. Rotace (mazání nejstarších) se "
               f"brzy spustí. Nejstarší verze: {fmt(oldest)}, drží se {count} verzí.",
               key="tm_wd_low_free")
        low_warned = True
    if free is not None and free >= LOW_FREE_GB:
        low_warned = False

    json.dump({"oldest": oldest, "newest": newest, "count": count,
               "free_gb": free, "low_warned": low_warned,
               "checked": datetime.now().isoformat(timespec="seconds")},
              open(STATE, "w"), ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
