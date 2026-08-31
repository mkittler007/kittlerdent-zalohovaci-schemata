# Zálohovací schémata — rozcestník

Centrální místo pro dokumentaci **všech zálohovacích schémat** (konsolidováno 16.8.2026).

## Obsah složky
- **`PLANOVACE_WATCHDOGY_NOTIFIKACE.md`** — 👉 centrální přehled **všech plánovačů, watchdogů a notifikací** (HOST + VM): co běží, kdy, co co hlídá, **proč a jak notifikuje** a jaká je pojistka. Pro kontrolu, pro případ výpadku i pro přechod na jinou platformu. **Aktualizovat při každé změně plánovače/watchdogu/notifikace.**
- **`DR_restore_playbook.md`** — 👉 krok-za-krokem „NAS umřel → jak ho složit zpět" (co obnoví `.dss`, co dohrát ručně, ověření).
- **`Syno_Backup_YYYYMMDD.dss`** — export DSM konfigurace NASu Syno_Backup (uživatelé, sdílené složky + práva, systém/síť). ⚠️ NEobsahuje naplánované úlohy ani konfigurace balíků. Dělat občas čerstvý (DSM → Ovládací panel → Aktualizace a obnova → Záloha konfigurace) a mít i mimo NAS.
- **`synology_DR_konfigurace.md`** — kompletní disaster-recovery dokumentace NASu Syno_Backup (DS418play, .120): HW, RAID5/Btrfs, sdílené složky, SSH, vrstvy ochrany, plná tabulka naplánovaných úloh.
- **`synology_dump/`** — surová data z NASu: `esynoscheduler.db` (DB úloh) + `tasks.txt` (výpis všech 25 úloh vč. příkazů).
- **`Retence VM macOS/`** — schéma zálohy celého VM na Synology: `vm-backup-synology.sh` (aktuální živá verze), plisty LaunchAgentů, watchdog, README, `.telegram.env`.

## Kde běží co (živě, mimo tuto dokumentaci)
- **Záloha VM** běží na **HOSTu** z `~/bin/vm-backup-synology.sh` (LaunchAgent `com.kittler.vm-backup`, denně 0:00). Tato složka je jeho **dokumentace/verze**, ne živý běh. Klíč `~/.ssh/synology_backup`, cíl `/volume1/VM macOS M4`.
  - 16.8.2026: Entware rsync 3.4.1 na NASu → **sparse `-S`** (poloviční kopie) + **delta přenos** (reflink předchozí kopie + `--inplace --no-whole-file` → po síti jen změněné bloky).
- **HyperBackup úlohy** (RTG/CBCT/Lightroom/Soft21/Claude_project/… → C2 cloud) běží přímo na NASu (Task Scheduler) — viz tabulka v `synology_DR_konfigurace.md`.

## Vazby v paměti/vaultu
`[[reference_nas_zalohy]]` · `[[reference_synology_konfigurace]]` · `[[project_vm_snapshots_parallels]]`
