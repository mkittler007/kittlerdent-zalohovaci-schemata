#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VM heartbeat — součást „super agenta" (supervize).
Každých 5 min (LaunchAgent com.kittler.vm_heartbeat) zkontroluje kritické
KeepAlive služby VM + porty, drobně self-healne (kickstart) co spadlo,
a pošle na HOST tep + zdravotní souhrn (~/.kd_supervisor/vm_heartbeat.json).
Host supervisor pak podle čerstvosti tepu pozná, že VM žije / je dole.
Bez tokenů, jen stdlib. VM -> host SSH funguje (opačný směr je zavřený).
"""
import os, json, subprocess, socket
from datetime import datetime

SSH_KEY  = os.path.expanduser("~/.ssh/id_ed25519_macmini")
SSH_HOST = "martinkittler@192.168.100.24"
REMOTE   = "~/.kd_supervisor/vm_heartbeat.json"
LOG      = os.path.expanduser("~/.kd_supervisor/vm_heartbeat.log")

# Kritické KeepAlive služby (musí mít PID). label -> lidský název
KEEPALIVE = {
    "com.kittlerdent.telegram":      "Telegram listener",
    "com.kittlerdent.implantaty":    "Implantáty Django",
    "com.kittlerdent.web_vp":        "Vstupní vyšetření web",
    "com.fitness.dashboard.web":     "Fitness dashboard",
    "cz.kittlerdent.vyvoj_cen_web":  "Ceny dashboard",
    "homebrew.mxcl.mysql":           "MySQL",
    "homebrew.mxcl.nginx":           "Nginx",
    "homebrew.mxcl.postgresql@14":   "PostgreSQL",
}
# port -> název (health)
PORTS = {3306: "MySQL", 8080: "Nginx", 8000: "Django", 5000: "web_vp",
         5432: "PostgreSQL", 5050: "Fitness", 8010: "Ceny"}


def log(m):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M} {m}\n")
    except Exception:
        pass


def launchctl_pids():
    """label -> PID string ('-' když neběží), z jednoho výpisu."""
    out = subprocess.run(["launchctl", "list"], capture_output=True, text=True).stdout
    pids = {}
    for ln in out.splitlines()[1:]:
        parts = ln.split("\t")
        if len(parts) >= 3:
            pids[parts[2]] = parts[0]
    return pids


def kickstart(label):
    uid = os.getuid()
    subprocess.run(["launchctl", "kickstart", "-k", f"gui/{uid}/{label}"],
                   capture_output=True, text=True, timeout=30)


def port_open(p):
    try:
        s = socket.create_connection(("127.0.0.1", p), timeout=2)
        s.close()
        return True
    except Exception:
        return False


def main():
    pids = launchctl_pids()
    problems, healed = [], []

    for label, name in KEEPALIVE.items():
        pid = pids.get(label)
        if pid is None:
            problems.append(f"{name} ({label}) NENÍ načten")
        elif pid == "-":
            # KeepAlive spadl → zkusit nahodit
            log(f"kickstart {label}")
            kickstart(label)
            healed.append(f"{name} restartován")

    for p, name in PORTS.items():
        if not port_open(p):
            problems.append(f"port {p} ({name}) neodpovídá")

    payload = {
        "ts": datetime.now().isoformat(),
        "host": socket.gethostname(),
        "ok": len(problems) == 0,
        "problems": problems,
        "healed": healed,
    }
    data = json.dumps(payload, ensure_ascii=False)

    # push na host (mkdir + zápis přes stdin)
    cmd = ["ssh", "-i", SSH_KEY, "-o", "ConnectTimeout=12",
           "-o", "StrictHostKeyChecking=no", SSH_HOST,
           f"mkdir -p ~/.kd_supervisor && cat > {REMOTE}"]
    r = subprocess.run(cmd, input=data, capture_output=True, text=True, timeout=45)
    if r.returncode != 0:
        log(f"push na host SELHAL rc={r.returncode}: {r.stderr.strip()[:120]}")
    else:
        log(f"tep odeslán ok={payload['ok']} problémy={len(problems)} healed={len(healed)}")


if __name__ == "__main__":
    main()
