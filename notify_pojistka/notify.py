#!/usr/bin/env python3
"""
notify.py — JEDNOTNÝ odesílač notifikací KittlerDent s POJISTKOU (cross-kanálový fallback).

PRAVIDLO: každá notifikace (tobě i recepci) jde přes tohle. Když primární kanál selže,
automaticky se zkusí náhradní, takže žádná notifikace nezmizí tiše. Každý pokus se loguje
a úspěch/selhání se zapíše do heartbeatu, na kterém staví externí "hlídač ticha".

Kanály:
  telegram  — přes ~/bin/telegram_send.sh (drží časové okno; mimo okno padne na e-mail)
  email     — SMTP mx.kittlerdent.cz:587 (recepce@kittlerdent.cz); Martinovi na mkittler@me.com
              (schválně EXTERNÍ schránka — přežije i výpadek mx.kittlerdent.cz)
  imessage  — přes SSH na host .24 + osascript Messages (funguje jen když host + net jedou)

Pořadí fallbacku:
  to=martin  : telegram -> email(mkittler@me.com) -> imessage(mkittler@me.com)
  to=recepce : email(recepce@kittlerdent.cz)  a když SELŽE -> eskalace Martinovi na Telegram
  to=both    : recepce + martin
  priority=critical: pošle VŠEMI kanály zaráz (redundance), Telegram i mimo okno (--force)

CLI:
  notify.py --to martin  --subject "Sklad" --body "text"
  notify.py --to recepce --subject "Akce"  --body "text" --attach a.pdf --attach b.xlsx
  notify.py --to martin  --body "IS spadl" --priority critical --key is_watchdog

Python:
  from notify import notify
  res = notify("Předmět", "Tělo", to="martin", key="sklad_report",
               priority="normal", attachments=["/cesta/a.pdf"])
  # res = {"ok": bool, "delivered": [...], "failed": [(kanal, chyba), ...]}
"""
import os
import sys
import json
import glob
import shlex
import argparse
import smtplib
import subprocess
from datetime import datetime
from email.mime.multipart import MIMEMultipart
from email.mime.base import MIMEBase
from email.mime.text import MIMEText
from email import encoders
from email.utils import formatdate, make_msgid

# ── Konfigurace (ověřené konstanty z fungujících skriptů) ──────────────────────
SMTP_HOST = "mx.kittlerdent.cz"
SMTP_PORT = 587
SMTP_USER = "recepce@kittlerdent.cz"
SMTP_FROM = '"KittlerDent" <recepce@kittlerdent.cz>'
# Tajemství: primárně ~/.config/kittlerdent/credentials.env, fallback projektový .env.
ENV_FILES = [
    os.path.expanduser("~/.config/kittlerdent/credentials.env"),
    "/Volumes/My Shared Files/Claude_Project/Implantáty_sklad/.env",
]

MARTIN_EMAIL   = "mkittler@me.com"          # EXTERNÍ schránka (nezávislá na mx.kittlerdent.cz)
RECEPCE_EMAIL  = "recepce@kittlerdent.cz"
MARTIN_IMSG    = "mkittler@me.com"          # Apple ID pro iMessage
TELEGRAM_SEND  = os.path.expanduser("~/bin/telegram_send.sh")

# iMessage přes host (Mac Mini) — VM sama iMessage neumí
SSH_KEY   = os.path.expanduser("~/.ssh/id_ed25519_macmini")
SSH_HOST  = "martinkittler@192.168.100.24"

# Heartbeat + log pro externí hlídač ticha
NOTIFY_DIR   = os.path.expanduser("~/.claude/notify")
KEYS_DIR     = os.path.join(NOTIFY_DIR, "keys")
OUTBOX_DIR   = os.path.join(NOTIFY_DIR, "outbox")   # trvalá fronta nedoručených → retry navždy
STUCK_HOURS  = 24                                    # po kolika h zaseknuté zprávy křičet do logu
LOG_FILE     = os.path.expanduser("~/Library/Logs/notify.log")
# Volitelný externí dead-man ping (healthchecks.io apod.) — když prázdné, neděje se nic.
# Bere se z env NEBO z ~/.claude/notify/notify.env (sdílené s pingerem kd_alive_ping.sh).
NOTIFY_ENV = os.path.expanduser("~/.claude/notify/notify.env")

def _healthcheck_url():
    url = os.environ.get("KD_NOTIFY_HEALTHCHECK_URL", "")
    if url:
        return url
    try:
        with open(NOTIFY_ENV) as f:
            for ln in f:
                ln = ln.strip()
                if ln.startswith("KD_NOTIFY_HEALTHCHECK_URL="):
                    return ln.split("=", 1)[1].strip().strip('"').strip("'")
    except Exception:
        pass
    return ""


def log(msg):
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass
    print(line, file=sys.stderr)


def _load_env():
    # Primární soubor vyhrává; fallback jen doplní chybějící klíče.
    env = {}
    for path in ENV_FILES:
        try:
            with open(path) as f:
                for ln in f:
                    ln = ln.strip()
                    if ln and not ln.startswith("#") and "=" in ln:
                        k, v = ln.split("=", 1)
                        env.setdefault(k.strip(), v.strip().strip('"').strip("'"))
        except FileNotFoundError:
            continue
        except Exception as e:
            log(f"POZOR: nelze číst {path}: {e}")
    return env


# ── Jednotlivé kanály (každý vrací True/False, nikdy nevyhazuje) ────────────────
def _send_email(to_addr, subject, body, attachments=None):
    try:
        password = _load_env().get("EMAIL_HOST_PASSWORD", "")
        if not password:
            log("email: chybí EMAIL_HOST_PASSWORD v .env")
            return False
        msg = MIMEMultipart()
        msg["From"] = SMTP_FROM
        msg["To"] = to_addr
        msg["Subject"] = subject
        msg["Date"] = formatdate(localtime=True)
        msg["Message-ID"] = make_msgid(domain="kittlerdent.cz")
        msg.attach(MIMEText(body, "plain", "utf-8"))
        for path in (attachments or []):
            try:
                with open(path, "rb") as fp:
                    part = MIMEBase("application", "octet-stream")
                    part.set_payload(fp.read())
                encoders.encode_base64(part)
                # název s diakritikou VŽDY přes filename= (RFC2231), nikdy natvrdo do hlavičky
                part.add_header("Content-Disposition", "attachment",
                                filename=os.path.basename(path))
                msg.attach(part)
            except Exception as e:
                log(f"email: přílohu {path} nelze přiložit: {e}")
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30) as s:
            s.starttls()
            s.login(SMTP_USER, password)
            s.sendmail(SMTP_USER, [to_addr], msg.as_string())
        log(f"email OK -> {to_addr}: {subject}")
        return True
    except Exception as e:
        log(f"email CHYBA -> {to_addr}: {e}")
        return False


def _send_telegram(text, force=False):
    try:
        args = [TELEGRAM_SEND]
        if force:
            args.append("--force")
        args.append(text)
        r = subprocess.run(args, capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            log("telegram OK")
            return True
        if r.returncode == 10:
            log("telegram: mimo časové okno (padám na další kanál)")
            return False
        log(f"telegram CHYBA rc={r.returncode}: {r.stdout.strip()} {r.stderr.strip()}")
        return False
    except Exception as e:
        log(f"telegram výjimka: {e}")
        return False


def _as_quote(s):
    """AppleScript-bezpečný řetězcový literál: escapuje jen \\ a ", zbaví se konců
    řádků a diakritiku nechá jako reálné UTF-8 (json.dumps by ji rozbil na \\uXXXX,
    což AppleScript neumí a spadne na syntax error)."""
    s = (s or "").replace("\\", "\\\\").replace('"', '\\"').replace("\r", " ").replace("\n", " ")
    return '"' + s + '"'


def _on_host():
    """True kdyz bezime primo na hostu .24 (pak iMessage jde lokalne, ne pres SSH na sebe)."""
    try:
        out = subprocess.run(["/sbin/ifconfig"], capture_output=True, text=True, timeout=5).stdout
        return "192.168.100.24" in out
    except Exception:
        return False


def _send_imessage(target, text):
    try:
        applescript = (
            'tell application "Messages"\n'
            '  set svc to 1st account whose service type = iMessage\n'
            f'  send {_as_quote(text)} to participant {_as_quote(target)} of svc\n'
            'end tell'
        )
        # Přes SSH musí být celý osascript JEDEN kvótovaný token pro vzdálený shell,
        # jinak se \n předá doslova a AppleScript spadne na syntax error. shlex.quote
        # zabalí skript do apostrofů a zachová skutečné konce řádků.
        if _on_host():
            cmd = ["osascript", "-e", applescript]
        else:
            remote = "osascript -e " + shlex.quote(applescript)
            cmd = ["ssh", "-i", SSH_KEY, "-o", "ConnectTimeout=12",
                   "-o", "StrictHostKeyChecking=no", SSH_HOST, remote]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=40)
        if r.returncode == 0:
            log(f"imessage OK -> {target}")
            return True
        log(f"imessage CHYBA -> {target} rc={r.returncode}: {r.stderr.strip()[:160]}")
        return False
    except Exception as e:
        log(f"imessage výjimka -> {target}: {e}")
        return False


# ── Heartbeat / externí dead-man ──────────────────────────────────────────────
def _record(key, ok, delivered, failed):
    stamp = {
        "key": key,
        "ok": ok,
        "delivered": delivered,
        "failed": [c for c, _ in failed],
        "ts": datetime.now().isoformat(timespec="seconds"),
    }
    try:
        os.makedirs(KEYS_DIR, exist_ok=True)
        with open(os.path.join(NOTIFY_DIR, "last.json"), "w") as f:
            json.dump(stamp, f, ensure_ascii=False)
        if key:
            safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in key)
            with open(os.path.join(KEYS_DIR, f"{safe}.json"), "w") as f:
                json.dump(stamp, f, ensure_ascii=False)
    except Exception as e:
        log(f"heartbeat zápis selhal: {e}")
    # externí dead-man ping (jen když je nastavená URL) — signál "odesílač žije"
    hc = _healthcheck_url()
    if hc:
        try:
            subprocess.run(["curl", "-fsS", "--max-time", "10", hc],
                           capture_output=True, timeout=15)
        except Exception:
            pass


# ── Trvalá fronta (outbox) — nedoručené zprávy se posílají znovu, dokud neprojdou ──
def _enqueue(payload):
    """Uloží nedoručenou zprávu na disk. Přežije reboot/vypnutí VM/výpadek netu.
    Keyované zprávy se deduplikují (stejný key přepíše starší nedoručenou)."""
    try:
        os.makedirs(OUTBOX_DIR, exist_ok=True)
        key = payload.get("key")
        if key:
            safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in key)
            name = f"{safe}.json"
        else:
            name = f"{datetime.now().strftime('%Y%m%dT%H%M%S')}_{os.getpid()}_{abs(hash(payload.get('subject',''))) % 100000}.json"
        payload.setdefault("created", datetime.now().astimezone().isoformat())
        payload.setdefault("attempts", 0)
        with open(os.path.join(OUTBOX_DIR, name), "w") as f:
            json.dump(payload, f, ensure_ascii=False)
        log(f"outbox: zpráva uložena k opětovnému odeslání → {name}")
    except Exception as e:
        log(f"outbox: ULOŽENÍ SELHALO ({e}) — zpráva: {payload.get('subject')}")


def drain_outbox():
    """Zkusí znovu doručit vše z fronty. Úspěch → smaže; neúspěch → nechá na příště.
    Volá LaunchAgent com.kittler.notify.outbox (á 5 min + při startu)."""
    if not os.path.isdir(OUTBOX_DIR):
        return {"drained": 0, "left": 0}
    drained = left = 0
    for fp in sorted(glob.glob(os.path.join(OUTBOX_DIR, "*.json"))):
        try:
            with open(fp) as f:
                p = json.load(f)
        except Exception as e:
            log(f"outbox: nečitelný {fp} ({e}) — mažu"); os.remove(fp); continue
        if p.get("email_to"):
            ok = _send_email(p["email_to"], p.get("subject") or "(bez předmětu)",
                             p.get("body") or "", p.get("attachments"))
        else:
            res = notify(p.get("subject",""), p.get("body",""), to=p.get("to","martin"),
                         priority=p.get("priority","normal"),
                         attachments=p.get("attachments"), key=p.get("key"),
                         _from_outbox=True)
            ok = res["ok"]
        if ok:
            os.remove(fp); drained += 1
            log(f"outbox: DORUČENO po {p.get('attempts',0)+1} pokusech → {os.path.basename(fp)}")
        else:
            left += 1
            p["attempts"] = p.get("attempts", 0) + 1
            p["last_try"] = datetime.now().astimezone().isoformat()
            try:
                age_h = (datetime.now().astimezone() - datetime.fromisoformat(p["created"])).total_seconds() / 3600
            except Exception:
                age_h = 0
            if age_h >= STUCK_HOURS:
                log(f"outbox: !!! ZASEKNUTÁ zpráva {age_h:.0f} h, {p['attempts']} pokusů → '{p.get('subject')}' (kanály stále nedostupné)")
            with open(fp, "w") as f:
                json.dump(p, f, ensure_ascii=False)
    if drained or left:
        log(f"outbox: doručeno {drained}, zbývá {left}")
    return {"drained": drained, "left": left}


# ── Veřejné API ────────────────────────────────────────────────────────────────
def notify(subject, body, to="martin", priority="normal",
           attachments=None, key=None, _from_outbox=False):
    """Pošle notifikaci s pojistkou. priority: 'normal' | 'critical'.
    Vrací dict {ok, delivered, failed}."""
    subject = subject or "(bez předmětu)"
    body = body or ""
    critical = (priority == "critical")
    delivered, failed = [], []

    def try_channel(name, fn):
        if fn():
            delivered.append(name)
            return True
        failed.append((name, "selhalo"))
        return False

    tg_text = f"<b>{subject}</b>\n{body}" if subject else body

    if to in ("recepce", "both"):
        # Recepce = e-mail; když selže, eskalace Martinovi na Telegram (jiný kanál).
        if not try_channel("email:recepce",
                           lambda: _send_email(RECEPCE_EMAIL, subject, body, attachments)):
            _send_telegram(f"⚠️ <b>Recepci NEDOŠEL e-mail</b>: {subject}\n"
                           f"(SMTP selhal — vyřiď ručně)", force=True)
            failed.append(("eskalace_recepce->martin_tg", "primární e-mail selhal"))
            delivered.append("telegram:martin(eskalace)")

    if to in ("martin", "both"):
        if critical:
            # redundance: všechny kanály zaráz, Telegram i mimo okno
            try_channel("telegram", lambda: _send_telegram(tg_text, force=True))
            try_channel("email:martin", lambda: _send_email(MARTIN_EMAIL, subject, body, attachments))
            try_channel("imessage", lambda: _send_imessage(MARTIN_IMSG, f"{subject}\n{body}"))
        else:
            # fallback: první, co projde, vyhrává
            (try_channel("telegram", lambda: _send_telegram(tg_text))
             or try_channel("email:martin", lambda: _send_email(MARTIN_EMAIL, subject, body, attachments))
             or try_channel("imessage", lambda: _send_imessage(MARTIN_IMSG, f"{subject}\n{body}")))

    ok = len(delivered) > 0
    _record(key, ok, delivered, failed)
    if not ok:
        log(f"!!! ŽÁDNÝ kanál neprošel pro '{subject}' (to={to}) — selhalo: {failed}")
        if not _from_outbox:
            # ulož do trvalé fronty — retry agent to pošle znovu, dokud neprojde
            _enqueue({"subject": subject, "body": body, "to": to,
                      "priority": priority, "attachments": attachments, "key": key})
    return {"ok": ok, "delivered": delivered, "failed": failed}


def main():
    p = argparse.ArgumentParser(description="Jednotný odesílač notifikací s pojistkou")
    p.add_argument("--to", default="martin", choices=["martin", "recepce", "both"])
    p.add_argument("--subject", default="")
    p.add_argument("--body", default="")
    p.add_argument("--priority", default="normal", choices=["normal", "critical"])
    p.add_argument("--attach", action="append", default=[], help="cesta k příloze (lze víckrát)")
    p.add_argument("--key", default=None, help="klíč pro heartbeat/dedup")
    p.add_argument("--email-to", dest="email_to", default=None,
                   help="pošli přímo e-mailem na tuto adresu (obejde telegram-first routing)")
    p.add_argument("--drain", action="store_true",
                   help="zkus znovu doručit vše z fronty (volá retry agent)")
    a = p.parse_args()
    if a.drain:
        print(json.dumps(drain_outbox(), ensure_ascii=False))
        return
    if not a.subject and not a.body:
        p.error("zadej aspoň --subject nebo --body")
    if a.email_to:
        # přímý e-mail na konkrétní adresu, stále přes notify.py (log + heartbeat)
        ok = _send_email(a.email_to, a.subject or "(bez předmětu)", a.body or "", a.attach)
        ch = f"email:{a.email_to}"
        _record(a.key, ok, [ch] if ok else [], [] if ok else [(ch, "selhalo")])
        if not ok:
            _enqueue({"email_to": a.email_to, "subject": a.subject, "body": a.body,
                      "attachments": a.attach, "key": a.key})
        res = {"ok": ok, "delivered": [ch] if ok else [], "failed": [] if ok else [ch]}
        print(json.dumps(res, ensure_ascii=False))
        return
    res = notify(a.subject, a.body, to=a.to, priority=a.priority,
                 attachments=a.attach, key=a.key)
    print(json.dumps(res, ensure_ascii=False))
    sys.exit(0 if res["ok"] else 1)


if __name__ == "__main__":
    main()
