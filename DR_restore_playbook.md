# DR playbook — „NAS Syno_Backup (.120) umřel, jak ho složit zpět"

Postup obnovy. Předpoklad: nový/opravený NAS (ideálně stejný model **DS418play** nebo novější DSM 7+). Podklady jsou v této složce (`Zalohovací schemata/`).

## 0) Než začneš — co máš k dispozici
| Artefakt | Co obnoví | Kde |
|---|---|---|
| `Syno_Backup_YYYYMMDD.dss` | uživatele, skupiny, **sdílené složky + práva/ACL**, síť, služby, systémová nastavení | tato složka |
| `synology_DR_konfigurace.md` | mapa: HW, RAID5/Btrfs, seznam+účel složek, SSH, vrstvy ochrany, síť | tato složka |
| `synology_dump/tasks.txt` + `esynoscheduler.db` | všech 25 naplánovaných úloh vč. příkazů | tato složka |
| `synology_dump/vlastni_skripty/RTG_OPG_archive.sh` | vlastní skript úlohy 20 (archivace RTG) | tato složka |
| `Retence VM macOS/` | schéma zálohy VM (běží ale z hostu `~/bin`) | tato složka |
| data | z **HyperBackup C2 cloudu** (Martin má PEMy + přístup přes web) + Btrfs snapshoty pokud disky přežily | C2 |

> **⚠️ Citlivé artefakty jsou zašifrované.** Soubory `.dss`, `synology_dump/HyperBackup/*.conf` (C2 credentials `remote_key`/`remote_secret`/`remote_tenant_id`), `synology_dump/SynologyDrive/*.conf`, `esynoscheduler.db` a `Retence VM macOS/.telegram.env` **nejsou v plaintextu** — jsou v archivu **`SECRETS_zalohovaci_schemata.tar.gz.enc`** (AES-256, heslo ve správci hesel; archiv NENÍ na GitHubu, jen v tomto hubu = záloha na NAS+cloud). Před obnovou rozbal ve složce `Zalohovací schemata/`:
> ```
> openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
>   -in SECRETS_zalohovaci_schemata.tar.gz.enc | tar -xzf -
> ```
> Vrátí soubory na jejich místa. Po použití plaintext zase smaž a případně přešifruj (`tar -czf - <soubory> | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass stdin -out SECRETS_zalohovaci_schemata.tar.gz.enc`).

## 1) Fyzická obnova + DSM
1. Osadit disky (RAID5, 4×). Když disky přežily → DSM je nabídne k **migraci** (data + většina nastavení zůstanou). Když ne → čistá instalace DSM 7.1+ a obnova dat z C2.
2. Nainstalovat DSM, základní síť: **IP 192.168.100.120/24, brána+DNS 192.168.100.250, hostname `Syno_Backup`**.

## 2) Obnova konfigurace z `.dss`
Ovládací panel → **Aktualizace a obnova → Záloha konfigurace → Obnovit** → nahraj `Syno_Backup_YYYYMMDD.dss`.
→ Vrátí **uživatele** (admin/Martin/skodak/Zaloha), **skupiny**, **sdílené složky + jejich práva/ACL**, síť, služby. **Zkontroluj podle** `synology_DR_konfigurace.md` sekce 3 (seznam složek) a 4 (uživatelé).

## 3) Co `.dss` NEobnoví — ručně dohrát
1. **SSH + klíč pro zálohy z Mac Mini:** povolit SSH (port 22), do `~/.ssh/authorized_keys` uživatele admin vložit veřejný klíč `backup_claude_project@macmini` (privát je na hostu `~/.ssh/synology_backup`). Bez toho neběží záloha VM ani Claude_Project.
2. **Entware + rsync 3.4.1** (pro sparse+delta zálohu VM) — viz `synology_DR_konfigurace.md` sekce 7 (instalace + boot-task).
3. **Naplánované úlohy** (Task Scheduler) — znovu vytvořit podle `synology_dump/tasks.txt`. Hlavně:
   - HyperBackup zálohy jednotlivých složek (dsmbackup) + jejich kontroly integrity (detect_monitor) — viz tabulka v DR dokumentu.
   - Systémové: DSM auto-update, S.M.A.R.T. test, security advisor.
   - Vlastní: **Vyčištění RTG** (měsíčně) = `bash /volume1/RTG_OPG/archive.sh` — skript nahrát z `synology_dump/vlastni_skripty/RTG_OPG_archive.sh`.
   - **Boot-task pro Entware** (root): `mkdir -p /opt; mount -o bind /volume1/@Entware/opt /opt`.
4. **HyperBackup úlohy → C2 cloud** (`synocloud_swift`, region **EU**, vše **šifrované + komprimované**). Na novém NASu: HyperBackup → **Restore / relink** na C2 repozitář pomocí credentials v `synology_dump/HyperBackup/synobackup.conf` (`remote_key`/`remote_secret`/`remote_tenant_id`) + šifrovací **PEM** (má Martin). HyperBackup si z repozitáře obnoví i konfiguraci úloh. Kompletní mapování úloha → zdrojové složky:

   | backup N | Zdrojové složky | Zálohy (denně/týdně) |
   |---|---|---|
   | 39 | /Loxone | Pá 21:50 |
   | 48 | /RTG_Direct_Upload_IS, /RTG_OLD, /RTG_OPG | denně 19:30 |
   | 49 | /Lightroom, /Pictures_Direct_Upload_IS | denně 21:10 |
   | 54 | /RTG_OLD | Ne 20:20 |
   | 55 | /Backu_up_settings | (záloha) |
   | 57 | /npgroup_backup | denně 20:40 |
   | 59 | /CBCT | denně 21:50 |
   | 60 | /soft21backup | denně 23:40 |
   | 61 | /HDD IMac ordinace | Ne 21:50 |
   | 62 | /Claude_Project | denně 1:20 |

   Plná konfigurace (vč. credentials, ⚠️ citlivé) v `synology_dump/HyperBackup/`.
5. **CloudSync** (Google Drive new/old) — **NENÍ potřeba obnovovat** (Martin 16.8.2026: nepotřebuji). Jen zrcadlo, ne záloha.
6. **Snapshot Replication** (Btrfs snapshoty složek) — ⚠️ **na starém NASu NEBYL v provozu** (balík neinstalován, 0 snapshotů — ověřeno 1.9.2026), takže není co obnovovat. Zvážit ho na novém NASu nově zapnout jako on-site rollback vrstvu (viz `PREHLED_ZALOH.md` riziko E5); jinak přeskočit.
7. **Synology Drive** (client sync port 6690, verzování: historie 1 měsíc / 10 verzí / max 100 MB + Shared Folder Sync) — nastavení NENÍ v `.dss`; hodnoty v `synology_dump/SynologyDrive/`. Znovu zapnout balík, nastavit verzování dle `setting.conf`, povolit Drive na příslušných složkách. Data Drive nejsou v HyperBackupu — kryje je Btrfs snapshot dané složky.

## 4) Ověření
- Sdílené složky + práva sedí (`synology_DR_konfigurace.md` sekce 3–4).
- Z Mac Mini projde `ssh -i ~/.ssh/synology_backup admin@192.168.100.120`.
- Noční záloha VM (host `~/bin/vm-backup-synology.sh`, 0:00) i Claude_Project (8/20:00) dojedou — sleduj logy na hostu.

## Stav pokrytí
- ✅ HyperBackup úlohy + config (`synology_dump/HyperBackup/`)
- ✅ Synology Drive nastavení (`synology_dump/SynologyDrive/`)
- ✅ Task Scheduler (25 úloh) + vlastní RTG skript, sdílené složky+práva (`.dss`), VM záloha
- ⏭️ CloudSync — **nepotřeba** (Martin 16.8.2026)
- (drobnost) firewall/DDNS detail — částečně v `.dss`, nekritické
- **Firewall / auto-block / DDNS / QuickConnect** pravidla (částečně v `.dss`).
