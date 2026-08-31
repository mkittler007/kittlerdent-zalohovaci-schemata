# Plánovače, watchdogy a notifikace — centrální přehled

> **Účel:** jediné autoritativní místo, kde je čitelně sepsáno **co je naplánované, co co hlídá, kdy a proč
> notifikuje a jakou má pojistku** — napříč HOSTem (Mac Mini M4 Pro `.24`) i VM (Parallels macOS guest `.82`).
> Slouží pro **kontrolu**, pro případ, že **spadne Claude / vypadne stroj** (aby šlo vyčíst, co mělo běžet a
> jak to alertuje), a jako podklad pro **případný přechod na jinou platformu**.
>
> **Zdroj pravdy = tato tabulka + živé `launchctl`.** Doplňkově existuje širší tabulka LaunchAgentů
> `Claude_nastavení/launch_agents_prehled.md` (provozní detaily) a paměť `project_launch_agents_overview`.
>
> **Poslední kompletní inventura naživo: 31.8.2026** (HOST i VM přes `launchctl list` + čtení plistů a skriptů).

---

## ⚠️ Pravidlo aktualizace (DŮLEŽITÉ)

Tento dokument je **provázaný s plánem záloh a obnovy** (`README.md`, `DR_restore_playbook.md`,
`synology_DR_konfigurace.md`, `Retence VM macOS/`, `VM_package_zaloha/`, `notify_pojistka/`, `supervisor/`).

**Při JAKÉKOLI změně plánovače / watchdogu / notifikace** (přidání, odebrání, změna času, změny kanálu/prahu)
se aktualizuje:
1. **tento soubor** (`PLANOVACE_WATCHDOGY_NOTIFIKACE.md`),
2. **a pokud se to dotýká záloh/obnovy nebo je s nimi propojené** i příslušný **plán záloh a obnovy**
   (README repa, DR playbook, dokumentace dané zálohovací větve),
3. `Claude_nastavení/launch_agents_prehled.md`,
4. commit + push (z VM `.82`, klíč `~/.ssh/github_implantaty`).

---

## Architektura notifikací — 4 vrstvy pojistky

```
                    ┌─────────────────────────────────────────────┐
   jednotlivé       │  1) notify.py  (Telegram → e-mail → iMessage)│
   skripty ────────▶│     + outbox (retry navždy)                 │
                    └─────────────────────────────────────────────┘
                                    │ když nic neprojde → outbox
                    ┌─────────────────────────────────────────────┐
                    │  2) notify.outbox  (drain á 5 min + RunAtLoad)│
                    └─────────────────────────────────────────────┘
                    ┌─────────────────────────────────────────────┐
   VM  ──heartbeat─▶│  3) supervisor (HOST) hlídá VM + sebe       │
   (á 5 min)        │     VM heartbeat (á 5 min) push přes SSH    │
                    └─────────────────────────────────────────────┘
                    ┌─────────────────────────────────────────────┐
   host+VM ─ping───▶│  4) deadman_ping → healthchecks.io          │
   (á 5 min)        │     ticho = poplach vydá EXTERNÍ služba      │
                    └─────────────────────────────────────────────┘
```

### 1) `notify.py` — jednotný odesílač s pojistkou
- Nasazen na **HOST `.24` i VM `.82`** (`~/bin/notify.py`), zdroj/mirror `notify_pojistka/notify.py`.
- Volání: `from notify import notify` nebo CLI `notify.py --to martin --subject … --body … [--priority critical] [--key <dedup>]`.
- **Tři kanály:**
  - **telegram** — přes `~/bin/telegram_send.sh` (drží časové okno Po–Pá 6–20, So–Ne 9–18; mimo okno rc=10 → padá dál; `--force` pošle vždy).
  - **email** — SMTP `mx.kittlerdent.cz:587`, odesílatel `recepce@kittlerdent.cz`; Martinovi na **externí `mkittler@me.com`** (přežije i výpadek `mx.kittlerdent.cz`).
  - **imessage** — přes SSH na host + `osascript Messages` na `mkittler@me.com`.
- **Routing:**
  - `to=martin`, normal → **telegram → email → imessage** (první úspěch vyhrává).
  - `to=martin`, **critical** → **všemi kanály zaráz**, Telegram i mimo okno (`--force`).
  - `to=recepce` → e-mail recepci; při selhání **eskalace Martinovi na Telegram** (`--force`).
- **Heartbeat:** po každém pokusu zápis `~/.claude/notify/last.json` + `keys/<key>.json`.
- **Outbox:** když neprojde žádný kanál, JSON do `~/.claude/notify/outbox/` (přežije reboot/výpadek). Retry navždy, dedup dle `--key`, stuck > 24 h křičí do logu.
- **Log:** `~/Library/Logs/notify.log`.

### 2) `com.kittler.notify.outbox` — retry fronta
- HOST **i** VM, `StartInterval 300 s + RunAtLoad`. Odbavuje `outbox/` (drain). RunAtLoad = po startu VM dožene backlog.

### 3) Supervisor + VM heartbeat (host hlídá VM i sebe)
- **`com.kittler.supervisor`** (HOST, `~/kd_supervisor.py`, á 10 min + RunAtLoad):
  - VM neběží (`prlctl status`) → `prlctl start` + **PANIKA `vm_down`**.
  - VM tep starší **> 15 min** (`HB_STALE_MIN`) a VM „running" → nejspíš čeká na FileVault heslo → **PANIKA `hb_stale`** („ODEMKNI VM").
  - VM hlásí problém služeb → běžný `alert`.
  - Spadlé host KeepAlive (podcast/fitness/ceny tunely) kickstartne; hlídá načtený `catchup`.
  - **Prahy:** `PANIC_GRACE_MIN=20` (přechodné stavy jako VM-backup suspend→klon→resume odezní → žádná falešná panika; vyřeší-li se v grace, **tiše smaže**), `PANIC_REPEAT_MIN=30`, `ANTISPAM_H=6`.
  - **PANIKA = multi-kanál** přes `notify.py --priority critical` (napojeno 31.8.2026), fallback `tg_send()`.
  - Denní „✅ vše běží" heartbeat **vypnut 31.8.2026** (stačí healthchecks.io).
- **`com.kittler.vm_heartbeat`** (VM, `~/bin/kd_heartbeat.py`, á 5 min + RunAtLoad, bez tokenů):
  - Kontroluje kritické KeepAlive (telegram listener, implantáty Django, web_vp, fitness web, ceny web, MySQL, Nginx, PostgreSQL) + porty 3306/8080/8000/5000/5432/5050/8010; spadlé kickstartne.
  - Výsledek `{ts,host,ok,problems,healed}` **push přes SSH** do hostového `~/.kd_supervisor/vm_heartbeat.json` (VM→host směr funguje, opačný je zavřený).

### 4) Externí dead-man's switch
- **`com.kittler.deadman_ping`** (`~/bin/kd_alive_ping.sh`, **na OBOU strojích**, á 5 min + RunAtLoad).
- Pinká healthchecks.io check `kd-alive`. Když Mac Mini / VM / internet spadne, pinky ztichnou a **healthchecks.io SÁM** pošle poplach (nezávisle na stroji i domácím netu → pokryje i „host dole" i „internet dole"). URL v `~/.claude/notify/notify.env` (`KD_NOTIFY_HEALTHCHECK_URL`, živé od 27.8.2026).

### Doplňkové vzory
- **2-strikes** (alarm až při 2. selhání za sebou, zdravý běh strike vynuluje): `com.fitness.heartbeat`, `com.kittler.ims_pull`, watchdog zálohy Claude_Project.
- **Catch-up dispečer** (`cz.kittlerdent.catchup`, á 15 min + RunAtLoad): dožene zmeškané naplánované akce po výpadku; sám nenotifikuje, spouští joby, které notifikují.

---

## HOST — Mac Mini M4 Pro (`192.168.100.24`)

> Přístup pro inventuru: SSH z VM s klíčem `~/.ssh/id_ed25519_macmini`.

| Label | Typ | Spouštění | Skript | Notifikuje (kanál) | Proč / podmínka | notify.py |
|---|---|---|---|---|---|---|
| `com.kittler.deadman_ping` | watchdog (dead-man) | á 5 min + RunAtLoad | `~/bin/kd_alive_ping.sh` | healthchecks.io (poplach = externě) | „dům žije" ping; ticho → externí alert | ne (externí) |
| `com.kittler.notify.outbox` | služba (retry) | á 5 min + RunAtLoad | `~/bin/notify.py` | Telegram→e-mail→iMessage | prázdní frontu nedoručených | **JE notify.py** |
| `com.kittler.supervisor` | watchdog (meta) | á 10 min + RunAtLoad | `~/kd_supervisor.py` | PANIKA multi-kanál / běžný Telegram | VM dole / tep >15 min / služby VM / host KeepAlive | ano (critical) |
| `com.kittler.timemachine_watchdog` | watchdog | denně 10:15 | `~/bin/timemachine_watchdog.py` | e-mail (SMTP) | TM záloha starší > 5 dní; antispam 24 h | ne (přímý SMTP) |
| `com.kittler.garmin_hr_guard` | plánovač (guard) | denně 10:30 | `~/bin/garmin_hr_guard.py` | Telegram (přímý) | fēnix změnil HR zóny → přenastaví + hlásí | ne (přímý TG) |
| `com.kittler.ims_pull` | plánovač (rsync) | 8:00 a 16:00 | `~/bin/ims_pull.sh` | Telegram (přímý) | pull IMS/IS zálohy; alarm až 2. selhání | ne (2-strike) |
| `com.kittler.ws_backup_watch` | watchdog | á 30 min + RunAtLoad | `~/bin/ws_backup_watch.py` | Telegram; tvrdá selhání i e-mail/iMessage | WhiteStore/Ahsay OBM selhání/kolize; antispam 6 h | ano |
| `com.kittler.ws_backup_review` | plánovač (report) | 1. den měs. 10:00 | `~/bin/ws_backup_review.py` | Telegram (fallback) | měsíční přehled WS záloh | částečně |
| `com.kittler.telfa_sms` | služba (Telfa) | á 60 s + RunAtLoad | `~/bin/telfa_sms_watch.py` | iMessage→SMS(602) + Telegram | zmeškaný hovor Telfa → přepis/notifikace | ne |
| `com.kittler.telfa_sms_summary` | plánovač | denně 20:00 | `~/bin/telfa_sms_watch.py` | iMessage/SMS + Telegram | denní souhrn zmeškaných hovorů | ne |
| `cz.kittlerdent.ff_summit_watch` | plánovač (watch) | denně 10:00 | `~/bin/ff_summit_watch.py` | Telegram + e-mail + iMessage | hlídá akci Fantastic Future Summit 16.12.2026 | ne |
| `cz.kittlerdent.catchup` | dispečer | á 15 min + RunAtLoad | `~/bin/catchup_runner.py` | — (spouští jiné) | dožene zmeškané akce po výpadku | ne |
| `cz.kittlerdent.eval_claude_backup` | plánovač (eval) | 3. den měs. 10:00 | `~/bin/eval_claude_backup.py` | Telegram (`telegram_send.sh`) | vyhodnotí běhy zálohy Claude_Project, pak self-off | ne |
| `cz.kittlerdent.backup_claude_project` | záloha | 8:00 a 20:00 | `~/bin/backup_claude_project.sh` | ne (tichý) | rsync Claude_Project → NAS; alert řeší watchdog | ne |
| `cz.kittlerdent.backup_claude_project.watchdog` | watchdog | 9:30, 13:30, 19:30 | `~/bin/watchdog_backup_claude_project.sh` | Telegram (`telegram_send.sh`) | retry + diagnóza; alarm až 2. selhání | ne (2-strike) |
| `com.kittler.vmpkg.cold` | záloha VM (cold) | 6:00 a 18:00 | `~/VM_Safety/bin/zaloha_vm_package.sh` | ne (tichý) | cold záloha VM package; alerty řeší hlidac | ne |
| `com.kittler.vmpkg.ram` | záloha VM (ram) | denně 23:00 | `~/VM_Safety/bin/zaloha_vm_package.sh` | ne (tichý) | RAM/live záloha VM package | ne |
| `com.kittler.vmpkg.wd` | přenos WD | denně 23:10 | `~/VM_Safety/bin/prenos_na_wd.sh` | Telegram (přímý) | přenos na WD/Thunderbolt; chybí FDA → skip + 1× TG | ne |
| `com.kittler.vmpkg.nas` | přenos Synology | denně 23:50 | `~/VM_Safety/bin/prenos_na_synology.sh` | ne (tichý) | přenos VM package na Synology | ne |
| `com.kittler.vmpkg.hlidac` | watchdog | á 1 h | `~/VM_Safety/bin/hlidac_zaloh.sh` | Telegram (přímý) | integrita VM záloh; vadné po retry → TG 1×/24 h | ne |
| `com.kittler.mail_indexer` | plánovač (index) | denně 3:00 | `~/mail_index/mail_indexer.py` | ne | noční reindex Apple Mailu (OCR) | ne |
| `com.kittler.mail_extract` | služba (on-demand) | RunAtLoad=false | `~/mail_index/mail_extract.py` | ne | extrakce příloh z mailu | ne |
| `com.kittler.foto_index` | plánovač (index) | neděle 6:00 | `Foto/foto_semantic_index.py` | notify.py (best-effort) | týdenní reindex foto/video | ano (best-effort) |
| `com.kittler.voicememo_note` | služba (watch) | á 30 min + WatchPaths | `~/bin/voicememo_to_note.sh` | Telegram (`--force`) + Apple Note/Reminders | nová hlasovka → přepis; dopis pacientovi na TG | ne |
| `com.kittler.voicememo_cleanup` | plánovač (úklid) | denně 4:00 | `~/bin/voicememo_cleanup.sh` | ne | mazání přepsaných hlasovek | ne |
| `com.kittler.whisper_server` | služba KeepAlive | RunAtLoad+KeepAlive | `~/whisper-cz-en/whisper_server_run.sh` | ne | whisper-cz-en server (Metal) | ne |
| `com.kittler.whisper_jobs_cleanup` | plánovač (úklid) | á 6 h + RunAtLoad | `~/bin/whisper_jobs_cleanup.sh` | ne | úklid whisper jobů | ne |
| `com.kittler.moncpuram.host` | služba (sampler) | á 60 s + RunAtLoad | `~/monitoring/cpuram/monitor_host.sh` | ne | sběr CPU/RAM á 60 s | ne |
| `com.kittler.moncpuram.nas` | plánovač (sync) | denně 4:40 | `~/monitoring/cpuram/sync_host_to_nas.sh` | ne | sync monitoringu na NAS | ne |
| `cz.kittlerdent.podcast_sync` | plánovač | denně 5:00 | `~/podcast/sync_run.sh` | ne | stahování podcastů z kanálů | ne |
| `cz.kittlerdent.podcast_server` | služba KeepAlive | RunAtLoad+KeepAlive | `~/podcast/server.py` | ne | podcast feed server | ne |
| `cz.kittlerdent.podcast_tunnel` | služba (CF tunnel) | RunAtLoad+KeepAlive | `~/podcast/tunnel.sh` | ne | tunel podcast.kittler.app | ne |
| `cz.kittlerdent.fitness_tunnel` | služba (CF tunnel) | RunAtLoad+KeepAlive | `cloudflared` | ne | tunel health.kittler.app | ne |
| `cz.kittlerdent.ceny_tunnel` | služba (CF tunnel) | RunAtLoad+KeepAlive | `cloudflared` | ne | tunel dashboardu cen skladu | ne |

**Pozn. k VM zálohám na hostu:** aktivní větev je **`com.kittler.vmpkg.*`** (cold/ram/wd/nas/hlidac). Starší plisty
`com.kittler.vm-backup`, `vm-backup-wd`, `vm-backup-watchdog`, `vm-snapshot` **existují na disku, ale NEJSOU nahrané**
v `launchctl list` (dokumentace v `Retence VM macOS/`).

---

## VM — Parallels macOS guest (`192.168.100.82`)

| Label | Typ | Spouštění | Skript | Notifikuje (kanál) | Proč / podmínka | notify.py |
|---|---|---|---|---|---|---|
| `com.kittler.notify.outbox` | služba (retry) | á 5 min | `~/bin/notify.py` | Telegram→e-mail→iMessage | odbavuje frontu odložených notifikací | **JE notify.py** |
| `com.kittler.vm_heartbeat` | heartbeat | á 5 min + RunAtLoad | `~/bin/kd_heartbeat.py` | push JSON na host (alert řeší supervisor) | tep VM + healí spadlé služby | via supervisor |
| `com.kittler.deadman_ping` | watchdog (dead-man) | á 5 min + RunAtLoad | `~/bin/kd_alive_ping.sh` | healthchecks.io | „VM žije" ping | ne (externí) |
| `com.kittlerdent.kredit` | watchdog | denně 8:00 | `~/bin/kontrola_kreditu.sh` | notify.py critical | Anthropic kredit pod prahem / API test selhal | **ano** |
| `cz.kittlerdent.implantaty.daily_check` | watchdog | Po–Pá 10:00 | `manage.py daily_stock_check` | notify.py (oba příjemci) | podkročení min. stavů zapůjčených implantátů | **ano** |
| `cz.kittlerdent.implantaty.watchdog` | watchdog | á 5 min | `~/bin/watchdog_implantaty.sh` | e-mail (martin+recepce) + Telegram | Django down po restartu / DB dump zastaralý (6–20, throttle 1 h) | ano (escalate critical) |
| `com.kittlerdent.watchdog` | watchdog | á 5 min | `VV/watchdog_web_vp.sh` | osascript (lokál VM) | web_vp spadl / dump zastaralý → restart | **ne (jen lokál)** |
| `cz.kittlerdent.disk_alert` | watchdog | á 1 h | `~/bin/disk_alert.py` | Telegram + e-mail | datové volume VM ≥ 80 % | ano |
| `com.fitness.heartbeat` | watchdog | denně 21:45 | `~/bin/fitness_heartbeat.py` | notify.py critical (key `fitness_heartbeat`) | fitness sync selhal 2 dny za sebou | ano (2-strike) |
| `com.kittler.telegram_guard` | watchdog | á 30 min + WatchPaths | `~/bin/telegram_guard_watchdog.py` | Telegram (`--force`) | update pluginu smazal outbound-only patch listeneru | ano |
| `com.kittler.zasilkovna_watch` | watchdog | 8:20 / 18:20 | `~/bin/zasilkovna_watch.py` | e-mail + iMessage | nový mail Zásilkovna → připraveno k vyzvednutí | ano |
| `com.kittler.dopravci_watch` | watchdog | 7:45 / 11:30 / 15:00 | `~/bin/dopravci_watch.py` | iMessage + Telegram + e-mail | mail dopravce (DHL/PPL/ČP); odhad vs. ordinace | ano |
| `com.kittler.balik_watch` | watchdog | á 10 min | `~/bin/balik_watch.py` | e-mail + iMessage | konkrétní balík „připraveno"; pak self-off | ano |
| `cz.kittlerdent.watch2200` | watchdog | 21:50 | `watch_2200_launcher.sh` | jen chyba copy z VirtioFS → notify.py critical | večerní snapshot procesů před 22:00 | ano (launcher) |
| `cz.kittlerdent.watch_is_crm` | watchdog (WatchPaths) | při vzniku složky | `system_health/watch_is_crm.sh` | osascript (lokál VM) | vznik IS_CRM_software21 (zachytí + smaže) | ne (lokál) |
| `com.kittler.okna_snapshot` | sampler | á 60 s | `~/bin/okna_snapshot.sh` | ne (po restartu hlásí přes catchup) | evidence běžících oken | ne |
| `com.fitness.activity_notify` | plánovač | á 15 min | `~/bin/activity_notify.py` | Telegram | nová aktivita Ride/Run ≥10 min → rozbor | ? |
| `com.fitness.dashboard.evening` | plánovač | 18:30–21:30 á 15 min | `evening_report.py` | Telegram | večerní health sumář (1×/den) | ano |
| `com.fitness.dashboard.sync` | plánovač | Po–Pá 6:00 / So–Ne 8:00 | `morning_report.py` | Telegram | ranní přehled/readiness | ano |
| `com.fitness.dashboard.sync3h` | plánovač | 9/12/15/21 h | `sync_activities.py` | ne | jen sync dat | — |
| `com.fitness.dashboard.web` | služba KeepAlive | RunAtLoad+KeepAlive | `app.py` | ne | fitness dashboard web | — |
| `com.kittler.autocontinue` | plánovač (bez tokenů gate) | á 20 min | `~/bin/kd_autocontinue.sh` | ne | autonomní pokračování po resetu tokenů | — |
| `com.kittler.channel_retry` | plánovač | á 1 h | `~/bin/channel_retry.sh` | Telegram | modul stažen → výzva pokračovat | ano |
| `com.kittler.linkedin_notify` | plánovač | Po 9:00 | `~/bin/linkedin_notify.py` | Telegram | existuje nepublikovaný LinkedIn draft | ano |
| `com.kittler.linkedin_notify_once` | plánovač (jednoráz.) | 8:00 | `linkedin_notify.py` | Telegram | jednorázový notif; pak self-off | ano |
| `com.kittlerdent.gameplan_konverze` | plánovač | 9:00 | `GamePlan/gameplan_scheduler.py` | e-mail (martin@kittler.cz) | měsíční report konverze GamePlan | ano |
| `com.kittlerdent.sklad_report` | plánovač | Po–Pá 9:00 | `~/bin/sklad_report.py` | e-mail (martin@kittlerdent.cz) | týdenní report skladu (jen když Kittler ordinuje) | ? (SMTP) |
| `cz.kittlerdent.implantaty.action_digest` | plánovač | Po–Pá 7:15 | `manage.py implant_action_digest` | e-mail (recepce) | denní digest akcí implantátů | ne (Django) |
| `cz.kittlerdent.implantaty.monthly_report` | plánovač | 1. den 8:00 | `manage.py monthly_report --send` | e-mail (recepce) | měsíční Excel report implantátů | ne (Django) |
| `cz.kittlerdent.implantaty.sync_vlastni_sklad` | plánovač | Út/Čt/So 8:03 | `manage.py sync_vlastni_sklad` | e-mail (recepce) | sync vlastního skladu | ne (Django) |
| `cz.kittlerdent.implantaty.synology` | plánovač (mount) | á 5 min | inline `mount_smbfs` | ne | udržuje SMB mount Synology | — |
| `cz.kittlerdent.narozeniny_reminder` | plánovač | Po–Pá 8:40 | `~/bin/narozeniny_reminder_runner.py` | e-mail (SMTP) | připomínka narozenin pacientů (obrat ≥70K) | ano |
| `cz.kittlerdent.chatgpt_historie` | plánovač | 9:15 | `chatgpt_historie_reminder.py` | e-mail (SMTP) | připomínka exportu ChatGPT historie | ano |
| `cz.kittlerdent.obec_udrzba_stiznost` | plánovač | 10:00 | `obec_udrzba_stiznost_mailer.py` | e-mail (martin@kittlerdent.cz) | stížnost/údržba obec | ano |
| `cz.kittlerdent.rocni_doklady` | plánovač | 9:07 | `rocni_doklady_reminder.py` | e-mail (SMTP) | roční sběr dokladů (14.12.) | ano |
| `com.kittler.telfa_tuesday` (+`_backup`) | plánovač (datum-gate) | Út 15:05 / 16:10 | `telfa_tuesday_run.sh` → `telfa_send.py` | e-mail (martin@kittler.cz + me.com) | návrh stromu Telfa PDF | ano |
| `com.kittler.telfa_vp30` (+`_backup`) | plánovač | 9:15 / 10:10 | `telfa_vp30_run.sh` → `telfa_send.py` | e-mail | měsíční VP hlášení; DEFER když dovolená | ano |
| `com.kittler.telfa_zpv` / `_zpv2` (+`_backup`) | plánovač | 9:15 / 10:10 | `telfa_zpv_run.sh` → `telfa_send.py` | e-mail s PDF | Telfa ZPV hlášení #1/#2 | ano |
| `com.kittler.telfa_dovolena_propose` | plánovač | 15:00 | `telfa_dovolena_run.sh` | Telegram (návrh, čeká na „ok") | navrhne změnu hlášky dovolená | ? |
| `com.kittler.telfa_dovolena_enforce` | plánovač | 0:05 a 6:00 | `telfa_dovolena_run.sh` | Telegram | přepne Telfa hlášku dle IS plánovače | ? |
| `com.kittler.telfa_dovolena_failsafe` | plánovač (záloha) | 23:00 | `telfa_dovolena_run.sh` | Telegram | failsafe dovolená sync | ? |
| `com.kittler.moncpuram.report` | plánovač | Po 7:30 | `report_run.sh` | ? (log/mail) | týdenní report špiček CPU/RAM | ? |
| `com.kittler.moncpuram.vm` | sampler | á 60 s | `monitor_vm.sh` | ne | sběr CPU/RAM á 60 s | — |
| `com.kittler.moncpuram.vmsync` | plánovač | 4:20 | `sync_vm_to_host.sh` | ne | sync monitoringu na host | — |
| `com.kittler.obsidian_vault_sync` | plánovač | 6:15 | `obsidian/vault_sync_all.sh` | ne | sync vaultu s pamětí | — |
| `com.kittler.video_maintenance` | plánovač | á 6 h | `obsidian/video_maintenance.py` | ne (disk ≥90 % → TG) | údržba video fronty | — |
| `com.kittler.video_srt` | plánovač (bez tokenů) | á 30 min | `obsidian/zpracuj_srt_queue.sh` | ne | stahování/přepis videí | — |
| `com.kittlerdent.autopush` | plánovač | á 5 min | `~/bin/autopush_github.sh` | ne | commit+push změn kódu | — |
| `com.kittlerdent.sync_db` | plánovač | á 1 h | `~/bin/sync_crm_db.sh` | ne | DB dump ze Synology (předchází falešný alert watchdogu) | — |
| `com.kittlerdent.sync_sklad` | plánovač | 7:00 | `~/bin/sync_sklad_db.sh` | ne | sync skladové DB | — |
| `cz.kittlerdent.vyvoj_cen` | plánovač | So 4:00 | `vyvoj_cen/run_monthly.sh` | ne | data pro dashboard cen | — |
| `cz.kittlerdent.vyvoj_cen_web` | služba KeepAlive | RunAtLoad+KeepAlive | `vyvoj_cen/app.py` | ne | dashboard cen :8010 | — |
| `com.kittlerdent.web_vp` | služba KeepAlive | RunAtLoad+KeepAlive | `VV/web_vp.py` | ne | web vstupní vyšetření :5000 | — |
| `com.kittlerdent.implantaty` | služba KeepAlive | RunAtLoad+KeepAlive | `start_implantaty.sh` | ne | Django implantáty :8000 | — |
| `homebrew.mxcl.mysql` | služba KeepAlive | RunAtLoad+KeepAlive | `mysqld_safe` | ne | MySQL 2kdent :3306 | — |
| `homebrew.mxcl.nginx` | služba | RunAtLoad | `nginx` | ne | reverzní proxy :8080 | — |
| `homebrew.mxcl.postgresql@14` | služba KeepAlive | RunAtLoad+KeepAlive | `postgres` | ne | PostgreSQL :5432 | — |

---

## Souhrn watchdogů podle toho, CO hlídají

| Watchdog | Kde | Hlídá | Práh / podmínka alertu | Kam |
|---|---|---|---|---|
| supervisor | HOST | VM + host služby | VM dole / tep >15 min / služby VM | PANIKA multi-kanál |
| vm_heartbeat | VM | KeepAlive VM + porty | spadlá služba (self-heal + push) | přes supervisor |
| deadman_ping | HOST+VM | žije stroj+net? | ticho > interval | externí (healthchecks.io) |
| notify.outbox | HOST+VM | fronta notifikací | stuck > 24 h | log + retry |
| implantaty.watchdog | VM | Django + DB dump | down po restartu / dump zastaralý | mail+TG |
| implantaty.daily_check | VM | min. stavy zapůjčených | podkročení minima | notify.py |
| watchdog (web_vp) | VM | Flask VP + dump | pád / dump starý | osascript (lokál) |
| disk_alert | VM | datový volume VM | ≥ 80 % | TG+mail |
| fitness.heartbeat | VM | fitness pipeline | 2 dny bez sumáře | notify.py (2-strike) |
| telegram_guard | VM | listener patch | update smazal patch | TG |
| ws_backup_watch | HOST | WhiteStore/Ahsay | selhání/kolize | TG(+mail/iMsg) |
| timemachine_watchdog | HOST | Time Machine | > 5 dní | mail |
| vmpkg.hlidac | HOST | integrita VM záloh | vadné po retry | TG |
| backup_claude_project.watchdog | HOST | záloha Claude_Project | 2. selhání | TG |
| ims_pull (2-strike) | HOST | IMS/IS pull | 2. selhání | TG |
| zasilkovna/dopravci/balik_watch | VM | maily zásilek | nová zásilka | mail/iMsg/TG |
| ff_summit_watch | HOST | akce 16.12.2026 | nález termínu | mail+TG+iMsg |

---

## ⚠️ Mezery / rizika (k dořešení)

Globální pravidlo (CLAUDE.md) říká: **každá notifikace přes `~/bin/notify.py`** (cross-kanál + heartbeat + outbox).
Následující zatím notifikují **mimo** tuto pojistku — pokud primární kanál selže, zpráva zmizí bez fallbacku:

- **Jen `osascript display notification` (viditelné jen na GUI VM, žádný fallback):** `com.kittlerdent.watchdog` (web_vp), `cz.kittlerdent.watch_is_crm`.
- **Jen přímý Telegram / `telegram_send.sh` (bez notify.py fallbacku):** `garmin_hr_guard`, `ims_pull`, `vmpkg.wd`, `vmpkg.hlidac`, `voicememo_note`, telfa_dovolena_*, backup_claude_project.watchdog, eval_claude_backup.
- **Jen přímý SMTP / Django `send_mail` (bez fallbacku):** `timemachine_watchdog`, `sklad_report`, implantáty `action_digest` / `monthly_report` / `sync_vlastni_sklad`.
- **Nedořešený kanál (`?`):** `moncpuram.report`, `activity_notify` (kanál .py neověřen), telfa_dovolena_* (notify.py fallback neověřen).

> Pozn.: u části z nich je přímý kanál záměr (drží časové okno / 2-strike). Sjednocení na `notify.py`
> řešit postupně; každou změnu promítnout sem.

---

## Přechod na jinou platformu — co je potřeba vzít

1. **Plánování:** všechny plisty jsou `~/Library/LaunchAgents/*.plist` (HOST i VM). Časy/intervaly viz tabulky výše. Ekvivalent jinde = cron / systemd timer / Task Scheduler.
2. **Skripty:** ostré verze žijí v `~/bin/` (HOST) a `~/bin/` + projektových složkách (VM) — **NEjsou plně verzované**; zálohovací/infra podmnožina je v tomto repu (`Retence VM macOS/`, `VM_package_zaloha/`, `supervisor/`, `notify_pojistka/`, `Claude_Project_backup_host/`, `no_problem_ims_pull/`, `vytizenost_CPU_RAM/`, `Imac_zelený_ordinace/`).
3. **Notifikační jádro:** `notify_pojistka/notify.py` + `com.kittler.notify.outbox` — přenositelné (Python), stačí env s tokeny (viz secrets).
4. **Supervize:** `supervisor/kd_supervisor.py` (host) + `supervisor/vm/kd_heartbeat.py` (VM) + `deadman_ping` (healthchecks.io URL).
5. **Secrets:** `SECRETS_zalohovaci_schemata.tar.gz.enc` (AES-256, heslo ve správci hesel) — Telegram token, SMTP heslo, healthchecks URL, SSH klíče.
6. **Zálohy a obnova:** `DR_restore_playbook.md`, `synology_DR_konfigurace.md`, `Retence VM macOS/`, `VM_package_zaloha/OBNOVA.md`.

---

## Provázání se zálohami a obnovou

Tento dokument je **součástí** repa zálohovacích schémat, protože plánovače a watchdogy z velké části **řídí a
hlídají samotné zálohy** (VM package, Claude_Project → NAS, WhiteStore/Ahsay, IMS pull, Time Machine, Synology
HyperBackup). Proto při zásahu do záloh/obnovy **VŽDY** ověřit a aktualizovat i tuto tabulku, a naopak.

Vazby: `README.md` · `DR_restore_playbook.md` · `synology_DR_konfigurace.md` · `Retence VM macOS/` ·
`VM_package_zaloha/` · `notify_pojistka/` · `supervisor/` · `Claude_nastavení/launch_agents_prehled.md`
</content>
</invoke>
