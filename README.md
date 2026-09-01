# Zálohovací schémata — rozcestník

Centrální místo pro dokumentaci **všech zálohovacích schémat** (konsolidováno 16.8.2026, přehled záloh přidán 1.9.2026).

## Obsah složky
- **`PREHLED_ZALOH.md`** — 👉 **MASTER přehled všech záloh na jednom místě**: každé schéma × zdroj × cíl (kde leží) × čas × **retence** × **plán obnovy**, plus „kde to fyzicky leží" podle úložišť, rychlý index obnovy dle scénáře a známé mezery/rizika. **Začni tady.**
- **`PLANOVACE_WATCHDOGY_NOTIFIKACE.md`** — 👉 centrální přehled **všech plánovačů, watchdogů a notifikací** (HOST + VM): co běží, kdy, co co hlídá, **proč a jak notifikuje** a jaká je pojistka. Pro kontrolu, pro případ výpadku i pro přechod na jinou platformu. **Aktualizovat při každé změně plánovače/watchdogu/notifikace.**
- **`DR_restore_playbook.md`** — 👉 krok-za-krokem „NAS umřel → jak ho složit zpět" (co obnoví `.dss`, co dohrát ručně, ověření).
- **`Syno_Backup_YYYYMMDD.dss`** — export DSM konfigurace NASu Syno_Backup (uživatelé, sdílené složky + práva, systém/síť). ⚠️ NEobsahuje naplánované úlohy ani konfigurace balíků. Dělat občas čerstvý (DSM → Ovládací panel → Aktualizace a obnova → Záloha konfigurace) a mít i mimo NAS.
- **`synology_DR_konfigurace.md`** — kompletní disaster-recovery dokumentace NASu Syno_Backup (DS418play, .120): HW, RAID5/Btrfs, sdílené složky, SSH, vrstvy ochrany, plná tabulka naplánovaných úloh.
- **`synology_dump/`** — surová data z NASu: `esynoscheduler.db` (DB úloh) + `tasks.txt` (výpis všech 25 úloh vč. příkazů).
- **`VM_package_zaloha/`** — 👉 **živé schéma zálohy VM macOS** (agenti `vmpkg.cold/ram/wd/nas`): `PLAN.md`, `OBNOVA.md` (plán obnovy), skripty, plisty, config, hlídač.
- **`Retence VM macOS/`** — ⚠️ **LEGACY** starší schéma (`vm-backup-synology.sh` týdenní klon + `vm-backup-wd.sh`); agenti už nejsou nahraní v launchctl. Ponecháno pro historii; kontext snapshotů/kompakce platí dál.
- **`Imac_zelený_ordinace/`** — záloha VM ordinace (Windows/Soft21) na iMacu .170: lokální cold denně + měsíčně na NAS, `PLAN_OBNOVY.md`.
- **`Claude_Project_backup_host/`** — mirror `Claude_Project/` → NAS .120 (08:00/20:00) + watchdog.
- **`no_problem_ims_pull/`** — pull No Problem/IMS DB dumpu z NASu do iCloudu (08:00/16:00).
- **`supervisor/`** — meta-hlídač VM+hostu (+ `vm/` protějšek). **`notify_pojistka/`** — retry fronta notifikací. **`vytizenost_CPU_RAM/`** — monitoring CPU/RAM (logy na NAS, retence 90 dní).
- **`synology_dump/`** — surová data z NASu (DB úloh + výpis 25 úloh + vlastní skripty). **`SECRETS_zalohovaci_schemata.tar.gz.enc`** — šifrované citlivé artefakty (`.dss`, C2 credentials, `.telegram.env`).

## Kde běží co (živě, mimo tuto dokumentaci) — ověřeno 1.9.2026
- **Záloha VM macOS** běží na **HOSTu** přes agenty `com.kittler.vmpkg.{cold,ram,wd,nas}` (cold 06/18, ram 23:00, WD 23:10, Synology obden 23:50). Detaily a retence viz `PREHLED_ZALOH.md` #1–4 a `VM_package_zaloha/`.
  - ⚠️ Starší `vm-backup-synology.sh`/`vm-backup-wd.sh` (agenti `com.kittler.vm-backup*`) **NEJSOU nahrané** — nahrazeno výše. `Retence VM macOS/` je legacy.
  - Sparse+delta přenos na NAS (Entware rsync 3.4.1, `-S` + `--inplace --no-whole-file`) zůstává použit. Klíč `~/.ssh/synology_backup`.
- **HyperBackup úlohy** (RTG/CBCT/Lightroom/Soft21/Claude_project/… → C2 cloud) běží přímo na NASu (Task Scheduler) — viz tabulka v `synology_DR_konfigurace.md`.

## Vazby v paměti/vaultu
`[[reference_nas_zalohy]]` · `[[reference_synology_konfigurace]]` · `[[project_vm_snapshots_parallels]]`
