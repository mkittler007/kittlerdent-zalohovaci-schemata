#!/opt/homebrew/bin/python3.13
# -*- coding: utf-8 -*-
"""
HOST supervisor — „super agent" nad celou infrastrukturou KittlerDent.
Běží na hostu (ten se po výpadku proudu obnoví sám: autorestart + auto-login),
takže hlídá VM i sebe zvenčí. Každých 10 min (LaunchAgent com.kittler.supervisor):

  1) VM běží? (prlctl) — když ne, spustí ji (prlctl start).
  2) Čerstvost VM tepu (~/.kd_supervisor/vm_heartbeat.json od com.kittler.vm_heartbeat):
     - chybí/starý > 15 min a VM „běží" => nejspíš čeká na FileVault odemčení po
       rebootu (nebo spadl heartbeat) => KRITICKÝ alert.
     - tep hlásí problémy služeb => alert (VM se je snažila sama nahodit).
  3) Host KeepAlive služby (tunely, catchup) — spadlé zkusí kickstartnout.
  4) 1×/den „✅ vše běží" heartbeat na Telegram (tichem se pozná i mrtvý host).
Anti-spam 6 h/klíč, zprávy o obnově. Alerty přes Telegram (~/.vm-backup-telegram.env).
"""
import os, json, subprocess, ssl, smtplib, urllib.request, urllib.parse
from datetime import datetime, timedelta
from email.mime.text import MIMEText
from email.utils import formatdate, make_msgid

PRLCTL = "/Applications/Parallels Desktop.app/Contents/MacOS/prlctl"
VM = "macOS"
STATE_DIR = os.path.expanduser("~/.kd_supervisor")
HB   = os.path.join(STATE_DIR, "vm_heartbeat.json")
STATE = os.path.join(STATE_DIR, "supervisor_state.json")
LOG  = os.path.join(STATE_DIR, "supervisor.log")
TG_ENV = os.path.expanduser("~/.vm-backup-telegram.env")
TM_ENV = os.path.expanduser("~/.timemachine-watchdog.env")   # SMTP heslo

# Panic kanály (host JE stroj s iMessage i SMTP → posílá přímo)
EMAIL_TO  = "mkittler@me.com"
IMSG_TO   = "mkittler@me.com"
SMTP_HOST = "mx.kittlerdent.cz"; SMTP_PORT = 587
SMTP_USER = "recepce@kittlerdent.cz"
SMTP_FROM = '"KittlerDent Supervisor" <recepce@kittlerdent.cz>'

HB_STALE_MIN = 15          # tep starší = problém
ANTISPAM_H = 6             # běžný alert max 1×/6 h
PANIC_REPEAT_MIN = 30      # PANIKA: opakovat každých 30 min, dokud trvá
PANIC_GRACE_MIN  = 20      # PANIKA: 1. notifikace az po tolika min od 1. detekce (prechodne suspendy/zaloha/restart/update stihnou odeznit -> zadna falesna panika)

# Host KeepAlive kandidáti (kontroluje jen ty, co JSOU načtené, aby nefalšoval)
HOST_KEEPALIVE = {
    "cz.kittlerdent.podcast_server": "Podcast server",
    "cz.kittlerdent.podcast_tunnel": "Podcast tunel",
    "cz.kittlerdent.fitness_tunnel": "Fitness tunel",
    "cz.kittlerdent.ceny_tunnel":    "Ceny tunel",
}
HOST_MUST = {"cz.kittlerdent.catchup": "Catchup dispečer"}


def log(m):
    os.makedirs(STATE_DIR, exist_ok=True)
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M} {m}\n")
    except Exception:
        pass


def load_state():
    try:
        s = json.load(open(STATE, encoding="utf-8"))
    except Exception:
        s = {}
    s.setdefault("alerts", {})
    s.setdefault("panic", {})
    s.setdefault("heartbeat_date", "")
    return s


def save_state(s):
    os.makedirs(STATE_DIR, exist_ok=True)
    json.dump(s, open(STATE, "w", encoding="utf-8"), ensure_ascii=False, indent=0)


def in_window(now):
    wd = now.weekday()
    h = now.hour
    if wd <= 4:
        return 6 <= h < 20
    return 9 <= h < 18


def _notify_py(text, critical=False):
    """Pojistka: primarne ~/bin/notify.py (cross-kanal Telegram->e-mail->iMessage + outbox retry navzdy).
    Fallback = puvodni tg_send() Telegram, kdyz notify.py chybi/selze. Napojeno 31.8.2026."""
    np = os.path.expanduser("~/bin/notify.py")
    if not os.access(np, os.X_OK):
        return False
    try:
        cmd = ["/usr/bin/python3", np, "--to", "martin", "--subject", "Supervisor", "--body", text]
        if critical:
            cmd += ["--priority", "critical"]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60).returncode == 0
    except Exception:
        return False


def tg_send(text, force=False):
    if _notify_py(text, critical=force):
        return True
    try:
        env = {}
        for ln in open(TG_ENV, encoding="utf-8"):
            ln = ln.strip()
            if "=" in ln and not ln.startswith("#"):
                k, v = ln.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
        tok = env.get("TELEGRAM_BOT_TOKEN"); chat = env.get("TELEGRAM_CHAT_ID")
        if not tok or not chat:
            log("Telegram: chybí token/chat")
            return False
        data = urllib.parse.urlencode({"chat_id": chat, "text": text}).encode()
        url = f"https://api.telegram.org/bot{tok}/sendMessage"
        urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=20).read()
        return True
    except Exception as e:
        log(f"Telegram CHYBA: {e}")
        return False


def _smtp_pw():
    try:
        for ln in open(TM_ENV, encoding="utf-8"):
            ln = ln.strip()
            if ln.startswith("EMAIL_HOST_PASSWORD="):
                return ln.split("=", 1)[1].strip().strip('"').strip("'")
    except Exception:
        pass
    return ""


def send_email(subject, body):
    try:
        msg = MIMEText(body, "plain", "utf-8")
        msg["Subject"] = subject
        msg["From"] = SMTP_FROM
        msg["To"] = EMAIL_TO
        msg["Date"] = formatdate(localtime=True)
        msg["Message-ID"] = make_msgid(domain="kittlerdent.cz")
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30) as s:
            s.starttls(context=ssl.create_default_context())
            s.login(SMTP_USER, _smtp_pw())
            s.sendmail(SMTP_USER, [EMAIL_TO], msg.as_string())
        return True
    except Exception as e:
        log(f"e-mail CHYBA: {e}")
        return False


def send_imessage(text):
    applescript = (
        'on run argv\n'
        '  tell application "Messages"\n'
        '    set svc to 1st account whose service type = iMessage\n'
        '    send (item 1 of argv) to participant (item 2 of argv) of svc\n'
        '  end tell\n'
        'end run'
    )
    try:
        r = subprocess.run(["osascript", "-e", applescript, text, IMSG_TO],
                           capture_output=True, text=True, timeout=45)
        if r.returncode != 0:
            log(f"iMessage CHYBA: {r.stderr.strip()[:120]}")
        return r.returncode == 0
    except Exception as e:
        log(f"iMessage CHYBA: {e}")
        return False


def panic(state, key, make_text, now, grace_min=0):
    """PANIKA: multi-kanál (Telegram+e-mail+iMessage), opakuje á PANIC_REPEAT_MIN.
    grace_min = 1. notifikaci pošli až po tolika minutách od 1. detekce
    (přechodné suspendy/záloha/restart/update stihnou odeznít → žádná falešná panika).
    make_text(mins_down, attempt) -> text zprávy."""
    p = state["panic"].get(key)
    if p:
        try:
            since = datetime.fromisoformat(p["since"])
        except Exception:
            since = now
        last = None
        if p.get("last"):
            try:
                last = datetime.fromisoformat(p["last"])
            except Exception:
                last = None
        mins_down = int((now - since).total_seconds() / 60)
        notified = bool(p.get("notified"))
        # jeste v grace okne a nikdy neodeslano -> jen drz zaznam a cekej
        if not notified and mins_down < grace_min:
            state["panic"][key] = {"since": since.isoformat(), "last": None,
                                   "count": 0, "notified": False}
            return
        # uz jsme nekdy poslali -> drz repeat interval
        if notified and last and now - last < timedelta(minutes=PANIC_REPEAT_MIN):
            return
        attempt = int(p.get("count", 0)) + 1
    else:
        since = now
        attempt = 1
        # prvni detekce a je grace -> zatim neposilej, jen si zapis zacatek
        if grace_min > 0:
            state["panic"][key] = {"since": since.isoformat(), "last": None,
                                   "count": 0, "notified": False}
            log(f"PANIC-PENDING [{key}] detekováno, grace {grace_min} min – zatím neposílám")
            return
    mins_down = int((now - since).total_seconds() / 60)
    text = make_text(mins_down, attempt)
    tg_send("‼️ PANIKA — " + text, force=True)
    send_email("‼️ PANIKA: KittlerDent supervisor", text)
    send_imessage("‼️ PANIKA — " + text)
    state["panic"][key] = {"since": since.isoformat(), "last": now.isoformat(),
                           "count": attempt, "notified": True}
    log(f"PANIC [{key}] pokus {attempt}, {mins_down} min: {text}")


def clear_panic(state, key, now, recovered_text):
    p = state["panic"].get(key)
    if p:
        was_notified = p.get("notified", True)   # stare zaznamy bez flagu = ber jako notifikovane
        del state["panic"][key]
        if was_notified:
            tg_send("✅ Supervisor: " + recovered_text, force=True)
            send_imessage("✅ " + recovered_text)
            log(f"PANIC-RECOVERED [{key}] {recovered_text}")
        else:
            log(f"PANIC-CLEARED [{key}] vyřešeno během grace – bez notifikace")


def alert(state, key, text, now, critical=False):
    """Pošle alert s anti-spamem; kritický jde i mimo okno."""
    last = state["alerts"].get(key)
    if last:
        try:
            if now - datetime.fromisoformat(last) < timedelta(hours=ANTISPAM_H):
                return
        except Exception:
            pass
    if not critical and not in_window(now):
        # mimo okno necháme na příště (ale kritické projde)
        return
    if tg_send("🔴 Supervisor: " + text, force=critical):
        state["alerts"][key] = now.isoformat()
        log(f"ALERT [{key}] {text}")


def clear_alert(state, key, now, recovered_text):
    if key in state["alerts"]:
        del state["alerts"][key]
        if in_window(now):
            tg_send("✅ Supervisor: " + recovered_text)
        log(f"RECOVERED [{key}] {recovered_text}")


def launchctl_pids():
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


def vm_status():
    r = subprocess.run([PRLCTL, "status", VM], capture_output=True, text=True, timeout=30)
    return (r.stdout + r.stderr).strip().lower()


def vm_start():
    subprocess.run([PRLCTL, "start", VM], capture_output=True, text=True, timeout=60)


def main():
    now = datetime.now()
    state = load_state()
    problems = []

    # 1) VM stav
    st = vm_status()
    if "running" not in st:
        log(f"VM není running ({st}) → prlctl start")
        vm_start()
        panic(state, "vm_down",
              lambda m, a, s=st: (f"VM je DOLE ({s}). Zkouším ji spustit (prlctl start) — "
                                  f"a už {m} min pořád neběží. Za tu dobu by případný "
                                  f"restart / update / suspend musel dojet, takže to nevypadá "
                                  f"na přechodný stav. {a}. výzva. Zkontroluj Mac Mini / Parallels."),
              now, grace_min=PANIC_GRACE_MIN)
        problems.append("vm_down")
    else:
        clear_panic(state, "vm_down", now, "VM zase běží.")

        # 2) čerstvost tepu
        hb = None
        try:
            hb = json.load(open(HB, encoding="utf-8"))
            ts = datetime.fromisoformat(hb["ts"])
            age_min = (now - ts).total_seconds() / 60
        except Exception:
            age_min = 9999
        if age_min > HB_STALE_MIN:
            panic(state, "hb_stale",
                  lambda m, a: (f"VM běží, ale {m} min NEPOSÍLÁ TEP. Nejspíš po rebootu/updatu "
                                f"čeká na FileVault heslo — ODEMKNI VM na Mac Mini. ({a}. výzva)"),
                  now, grace_min=PANIC_GRACE_MIN)
            problems.append("hb_stale")
        else:
            clear_panic(state, "hb_stale", now, "VM zase posílá tep — odemčeno, běží.")
            # 2b) problémy služeb hlášené VM
            probs = hb.get("problems", []) if hb else []
            if probs:
                alert(state, "vm_services",
                      "Služby ve VM hlásí problém: " + "; ".join(probs[:6]), now)
                problems.append("vm_services")
            else:
                clear_alert(state, "vm_services", now, "Služby ve VM zase v pořádku.")

    # 3) host služby
    pids = launchctl_pids()
    host_down = []
    # POVINNÉ intervalové (catchup) — stačí, že jsou NAČTENÉ; PID '-' je u nich normální
    for label, name in HOST_MUST.items():
        if label not in pids:
            log(f"host: {label} NENÍ načten")
            host_down.append(name + " (není načten)")
    # KeepAlive tunely/servery — musí mít PID; když spadly, kickstart
    for label, name in HOST_KEEPALIVE.items():
        pid = pids.get(label)
        if pid is None:
            continue          # nenačtený nepovinný → nefalšovat
        if pid == "-":
            log(f"host: {label} spadl (KeepAlive bez PID) → kickstart")
            kickstart(label)
            host_down.append(name)
    if host_down:
        alert(state, "host_agents",
              "Host služby spadly (zkusil jsem restart): " + ", ".join(host_down), now)
        problems.append("host_agents")
    else:
        clear_alert(state, "host_agents", now, "Host služby zase běží.")

    # 4) denní heartbeat „vše OK"
    today = now.strftime("%Y-%m-%d")
    if False and not problems and state.get("heartbeat_date") != today and in_window(now):  # denni OK vypnut 2026-08-31 (staci externi dead-man healthchecks.io)
        n_ok = 0
        try:
            n_ok = len(json.load(open(HB, encoding="utf-8")).get("problems", [])) == 0
        except Exception:
            pass
        if tg_send("✅ Supervisor: vše běží — VM i host OK, služby v pořádku."):
            state["heartbeat_date"] = today
            log("denní heartbeat odeslán")

    save_state(state)
    log(f"cyklus hotov, problémy={problems or 'žádné'}")


if __name__ == "__main__":
    main()
