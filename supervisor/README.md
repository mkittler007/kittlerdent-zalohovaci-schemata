# Supervisor — meta-hlídač infrastruktury KittlerDent

Meta-supervize nad všemi watchdogy: hlídá běh Parallels VM (macOS), čerstvost jejího
„tepu" a klíčové hostové služby; při výpadku eskaluje **PANIKU** na 3 kanály
(Telegram + e-mail + iMessage) a spadlé věci restartuje.

## Soubory
- `kd_supervisor.py` — hlavní skript (běží na **hostu Mac Mini `.24`**, python3.13, á 10 min).
- `com.kittler.supervisor.plist` — LaunchAgent (`StartInterval 600`, RunAtLoad), loguje do
  `~/.kd_supervisor/supervisor.log`, stav v `~/.kd_supervisor/supervisor_state.json`.

## Zdroj pravdy = HOST
Ostrá verze žije na hostu (`~/kd_supervisor.py`, `~/Library/LaunchAgents/com.kittler.supervisor.plist`).
Tenhle adresář je **mirror** pro verzování. Po změně na hostu srovnat sem → commit → push.

## Secrets MIMO git
Skript **nemá** žádné secrety v sobě — SMTP heslo čte z `~/.timemachine-watchdog.env`,
Telegram token z `~/.vm-backup-telegram.env` (oba na hostu, mimo repo).

## Chování panik
- **`vm_down`** — VM neběží → `prlctl start` + PANIKA.
- **`hb_stale`** — VM běží, ale >15 min neposílá tep (nejčastěji čeká na FileVault heslo po rebootu) → PANIKA „ODEMKNI VM".
- **`PANIC_GRACE_MIN = 20`** (od 31.8.2026) — 1. notifikace až po 20 min od 1. detekce.
  Přechodné stavy (manuální suspend při přesunech úložišť, VM-backup `suspend→klon→resume`,
  restart/update) tak stihnou odeznít samy → žádná falešná panika. Vyřeší-li se to během
  grace, hlídač to **tiše smaže** (nepošle ani „dole", ani „✅ běží").
- **`PANIC_REPEAT_MIN = 30`** — dokud stav trvá, opakuje á 30 min; po obnově pošle ✅.

## Protějšek ve VM — `vm/`
VM posílá tep skriptem `kd_heartbeat.py` (LaunchAgent `com.kittler.vm_heartbeat`, á 5 min + RunAtLoad)
přes SSH na host do `~/.kd_supervisor/vm_heartbeat.json`. Kontroluje kritické KeepAlive služby VM
(telegram, mysql, nginx, postgresql, implantáty Django, web_vp, fitness/ceny web) + porty, spadlé
`launchctl kickstart`. **Ostrá verze na VM `.82`:** `~/bin/kd_heartbeat.py` +
`~/Library/LaunchAgents/com.kittler.vm_heartbeat.plist` (VM = zdroj pravdy).
