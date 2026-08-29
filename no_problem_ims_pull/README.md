# No Problem (IMS) — pull zálohy DB na Mac Mini + watchdog

Denní záloha databáze aplikace **No Problem / IMS** (skladové hospodářství + objednávkový
systém, dodavatel No Problem Group s.r.o.) ze Synology `.120` na Mac Mini.

## Kontext
No Problem app zapisuje svou DB zálohu **každých 10 min** přímo na Synology `.120` do
samostatného SMB share `/volume1/npgroup_backup/database/` (soubory `ims_backup_YYYY-MM-DD_HH-MM-SS`,
timestamp v UTC). Do 28.8.2026 se denní snímek (05:00 UTC = 07:00 SELČ) dostával na Mac Mini
přes jiný iCloud stroj, ten ale přestal dodávat → 29.8. chyběl. Tenhle job tu závislost nahrazuje.

## Co dělá `ims_pull.sh`
- Přes **rsync** (ne scp — Synology nemá sftp subsystém) přes SSH klíč `~/.ssh/synology_backup`
  (`admin@192.168.100.120`, `--rsync-path=/usr/bin/rsync`) stáhne **jen nejnovější** denní
  snímek `ims_backup_*_05-00-01` do iCloud `Claude_Project/Sklad/database/`.
- **`.120` se jen ČTE — nikdy se na něj nezapisuje ani nemaže.** Zdroj si drží svou historii
  (~30 dní × 10-min snímků) beze změny.
- Na Mac Mini se drží **jen 1 verze** (nejnovější); starší lokální snímky se mažou.

## Watchdog (IMS + IS) — pravidlo „2 zásahy"
Nedělá paniku kvůli chvilkovému zpoždění:
1. běh: zkus stáhnout (+ okamžitý retry) → diagnostika → pokus o opravu
2. **1. neúspěšný běh = tichý strike** (jen log), žádný Telegram
3. **Telegram alarm až když selže i DRUHÝ běh za sebou** (strike 2); alarm jen 1× za výpadek
4. po úspěchu se počítadlo resetuje

Hlídá i **čerstvost IS dumpu** (`Claude_Project/IS_KittlerDent/databaze/is.2kdent*gz`, limit 36 h).
Strike soubory: `~/Library/Logs/ims_pull.{ims,is}.strike`. Telegram kanál jako ostatní watchdogy
(`~/.vm-backup-telegram.env` + Bot API). Log `~/Library/Logs/ims_pull.log`.

## Nasazení
- Skript → `~/bin/ims_pull.sh` (host Mac Mini `.24`)
- LaunchAgent → `~/Library/LaunchAgents/com.kittler.ims_pull.plist`, běží **2× denně 08:00 a 16:00**
- Nahradil mrtvý `com.is_crm.sync_db` (prázdný skript, odstraněn 30.8.2026)

Viz paměť `[[project_ims_pull]]`, `[[feedback_notifikace_2_strikes]]`, `[[project_no_problem_faktury]]`.
