# Synology `Syno_Backup` — konfigurace pro obnovu (Disaster Recovery)

> Účel: kdyby NAS „odešel do věčných lovišť", podle tohohle ho složíme zpět —
> sdílené složky, práva, SSH, podsložky, zálohy/sync, síť.
> Stav zmapován: **16. 8. 2026** (přes SSH host .24 → NAS admin@.120, klíč `~/.ssh/synology_backup`).
> Zrcadlo v paměti: `reference_synology_konfigurace` + vault.
> ⚠️ Položky značené **[root]** se nepodařilo vyčíst bez root práv (admin sudo chce heslo) — doplnit, až bude root.

---

## 1) Identita zařízení
| Položka | Hodnota |
|---|---|
| Hostname | `Syno_Backup` |
| Model | Synology **DS418play** (`synology_apollolake_418play`) |
| CPU | Intel Celeron **J3355** 2.00 GHz, **x86_64** (2 jádra) |
| DSM | **7.1.1-42962** (Update 9), build 2025/07/29, kernel 4.4.180+ |
| IP (eth0) | **192.168.100.120/24**, MAC `00:11:32:c3:2d:47` |
| eth1 | 169.254.229.155 (link-local, nepoužito) |
| tun1000 | 169.254.208.0/21 — interní Synology tunel (replikace / C2) |
| Brána / DNS | **192.168.100.250** (router dělá i DNS) |
| SSH | **port 22**, `PasswordAuthentication yes`, klíčové přihlášení admin |
| DSM web | http **:5000**, https **:5001** |
| rsync daemon | **:873** aktivní (Network Backup Service), `use chroot=no`, `refuse options=acls` |

## 2) Úložiště
- **RAID5** přes 4 disky: `sda5 sdb5 sdc5 sdd5` → `md2` (11 706 562 368 bloků, 64k chunk, stav `[UUUU]` = zdravé).
- Systém: `md1` RAID1 (2 GB, `[UUUU]`), root `/dev/md0` 2,3 G (82 %).
- LVM: `vg1000/lv` → **`/volume1`, filesystem BTRFS** (synoacl, ssd, space_cache=v2).
- Kapacita `/volume1`: **11 T, využito 7,2 T (69 %), volných 3,4 T** (k 16.8.2026).
- Btrfs = podpora **snapshotů** (Snapshot Replication) i **reflink** (důležité pro budoucí delta-přenos zálohy VM).

## 3) Sdílené složky (`/volume1/*`) a k čemu jsou
| Složka | Účel |
|---|---|
| **VM macOS M4** | Cíl **noční 1:1 zálohy celého VM** (rsync z hostu .24, `vm-backup-synology.sh`); retence 3+1. Podsložky `macOS_YYYY-MM-DD_HHMM.macvm`. |
| **Claude_Project** | Cíl **2×/den zálohy** iCloud složky Claude_Project (rsync z hostu, `backup_claude_project.sh`). |
| **soft21backup** | Zálohy ordinačního IS (software21 / 2kdent). |
| **CBCT** | CBCT 3D snímky (zubní). |
| **RTG_OPG**, **RTG_Direct_Upload_IS**, **RTG_OLD**, **RTG_OPG_Zaloha_20230513** | Rentgen / OPG snímky, přímý upload do IS. |
| **Pictures_Direct_Upload_IS** | Fotky přímý upload do IS. |
| **Lightroom** | Foto Lightroom + obsahuje **HyperBackup vault** `Syno_Backup_1.hbk`. |
| **Loxone** | Zálohy Loxone (chytrá domácnost). |
| **Google_drive_new / Google_drive_old** | Zrcadlo Google Drive (CloudSync). |
| **HDD IMac ordinace** | Záloha iMacu v ordinaci. |
| **npgroup_backup**, **NetBackup**, **Backu_up_settings** | Různé zálohy / export nastavení. |
| **whitestore_temp** | Dočasná data balíku **WhitestorePRO** (dentální zobrazovací SW). |
| **homes** | Domovské složky uživatelů (`/volume1/homes/admin` má `.ssh/authorized_keys`). |
| **docker** | Data Container Manageru (balík instalován, ale bez našeho použití). |

## 4) Přístup / SSH
- **Administrátoři** (skupina `administrators`, gid 101): **admin, Martin, skodak, Zaloha**. Účty se shellem: admin(1024), Martin(1031), skodak(1029), Zaloha(1027). Ostatní (npgroup, Soft21, veeam, vx, guest) = nologin/servisní. Martin se hlásí účtem **`Martin`** (nebo `admin`).
- Uživatel **`admin`** (uid 1024, skupiny `users`,`administrators`). **`sudo` vyžaduje heslo** (žádný NOPASSWD).
- Klíčové přihlášení: `~/.ssh/authorized_keys` obsahuje klíč `backup_claude_project@macmini` (privátní klíč na hostu = `~/.ssh/synology_backup`). Tímtéž klíčem se připojuje i VM-backup.
- **Připojení odjinud:** z VM přes host: `ssh -i ~/.ssh/id_ed25519_macmini martinkittler@192.168.100.24` → na NASu `ssh -i ~/.ssh/synology_backup admin@192.168.100.120`.
- Root: jen `sudo -i` s admin heslem (SSH root login v DSM 7 zakázán).

## 5) Vrstvy ochrany dat (co NAS dělá)
1. ~~**Btrfs snapshoty** (Snapshot Replication)~~ — ⚠️ **NEJSOU v provozu** (ověřeno 1.9.2026): balík SnapshotReplication není nainstalovaný, `synosharesnapshot list <share>` = 0 snapshotů, `@sharesnap/<share>` obsahuje jen `desktop.ini`. Dřívější seznam složek s `@sharesnap/*.meta` byl jen placeholder, ne živé snapshoty. On-site rollback/verzování tedy chybí — viz `PREHLED_ZALOH.md` riziko E5.
2. **HyperBackup → Synology C2 cloud** (offsite): cache `@img_bkp_cache/ClientCache_cloud_image_synocloud_swift.*` (běží denně, viz timestampy 15.–16.8.).
3. **HyperBackup Vault** (balík `HyperBackupVault`) — přijímá `.hbk` zálohy (`Lightroom/Syno_Backup_1.hbk`).
4. **Shared Folder Sync** (`@S2S/event.sqlite`) — synchronizace složek na/z jiného zařízení.
5. Náš **rsync z Mac Mini** (viz `[[reference_nas_zalohy]]`): VM + Claude_Project.

## 6) Instalované balíky (Package Center)
`ActiveInsight, CloudSync, Contacts, FileStation, HybridShare, HyperBackup, HyperBackupVault, Node.js v12/v14/v18, OAuthService, Perl, Python2, SMBService, ScsiTarget, SecureSignIn, SynoFinder, SynologyApplicationService, SynologyDrive, UniversalViewer, WhitestorePRO, exFAT-Free`

## 7) Entware + novější rsync (plán, k 16.8.2026 NEHOTOVO)
Cíl: rsync ≥ 3.2.4 na NASu → povolit `--sparse` a **poloviční objem** VM zálohy (DSM rsync je jen 3.1.2, `-S`+`--inplace` nezvládá).
- Repo pro tuto architekturu: **`x64-k3.2`** (`https://bin.entware.net/x64-k3.2/installer/generic.sh`).
- `/opt` jako **bind-mount** na `/volume1/@Entware/opt` (přežije reboot přes boot-task v Plánovači úloh, uživatel root).
- Instalace (root): `mkdir -p /volume1/@Entware/opt && mount -o bind /volume1/@Entware/opt /opt` → installer → `/opt/bin/opkg update && /opt/bin/opkg install rsync`.
- Pak na hostu ve `vm-backup-synology.sh`: `REMOTE_RSYNC=/opt/bin/rsync` + vrátit `-S` + pojistka fallback na `/usr/bin/rsync` bez `-S` když `/opt/bin/rsync` chybí.
- **HOTOVO 16.8.2026:** Entware nainstalován, **rsync 3.4.1** na `/opt/bin/rsync`. `/opt` = bind-mount na Btrfs `/volume1/@Entware/opt` (přesunuto ze systémového oddílu md0). Host skript upraven (probe → `-S` s fallbackem). Sparse ověřen (50M→0 bloků). Steady-state VM záloh klesne ~3,9 T → ~2–2,5 T.
- ⚠️ **Boot-task v DSM Plánovači úloh** (uživatel root, spouštění „Boot-up") MUSÍ obsahovat POUZE:
  ```sh
  #!/bin/sh
  mkdir -p /opt
  mount -o bind /volume1/@Entware/opt /opt
  ```
  (NE migrační blok mv/rmdir — ten se pouštěl jen 1× ručně v terminálu).

## 8) Naše host-side zálohovací úlohy (Mac Mini .24) mířící sem
- **VM macOS balík** → `VM macOS M4/VM_packages/` přes `com.kittler.vmpkg.nas` (obden 23:50, retence 4). ⚠️ Starý `com.kittler.vm-backup`/`vm-backup-synology.sh` už NEjede (agent nenahraný, ověřeno 1.9.2026). Viz `PREHLED_ZALOH.md` #4, `[[project_vm_package_zaloha]]`, `[[project_vm_snapshots_parallels]]`.
- `cz.kittlerdent.backup_claude_project` (8:00, 20:00) → `Claude_Project/`.
- Watchdogy: `com.kittler.vm-backup-watchdog` (8:00), `…backup_claude_project.watchdog`.

## 8b) Naplánované úlohy + rozsah DSM `.dss` zálohy (DŮLEŽITÉ pro DR)
- **DSM Záloha konfigurace (`.dss`)** obsahuje: uživatele/skupiny, **práva a nastavení sdílených složek** (ne data), workgroup/domain/LDAP, nastavení služeb a systému/sítě. **NEobsahuje**: Task Scheduler úlohy ani konfigurace balíků (HyperBackup, CloudSync, Snapshot Replication). → `.dss` dělat, ale úlohy řešit zvlášť.
### Naplánované úlohy — kompletní (z `esynoscheduler.db`, 16.8.2026)
Skoro vše = **HyperBackup** úlohy: `dsmbackup --backup N` spustí zálohu úlohy N (do C2/cíle), `detect_monitor -k N` = týdenní kontrola integrity téže úlohy. Vše owner **root**.

**Zálohy (dsmbackup):**
| ID | Název | Plán | Příkaz |
|---|---|---|---|
| 3 | RTG_syno_backup_X120 | denně 19:30 | dsmbackup --backup 48 |
| 11 | NP_Group_Syno_backup | denně 20:40 | dsmbackup --backup 57 |
| 14 | RTG_OLD_Z_Syno_backup | Ne 20:20 | dsmbackup --backup 54 |
| 9 | Lightroom_Synobackup_X120 | denně 21:10 | dsmbackup --backup 49 |
| 16 | Loxone_syno_Backup | Pá 21:50 | dsmbackup --backup 39 |
| 7 | CBCT_Syno_Backup_X120 | denně 21:50 | dsmbackup --backup 59 |
| 18 | HDD_Backup_Syno_X120 | Ne 21:50 | dsmbackup --backup 61 |
| 5 | Soft21_Syno_X120 | denně 23:40 | dsmbackup --backup 60 |
| 21 | Backup_Settings_synology_120 | (záloha) | dsmbackup --backup 55 |
| 23 | Claude_project_Syno120 | denně 1:20 | dsmbackup --backup 62 |

**Kontroly integrity (detect_monitor, víkend večer):** 24 Claude_project So 21:20 · 4 RTG Ne 21:30 · 6 Soft21 So 21:40 · 22 Backup_Settings So 1:50 · 15 RTG_OLD Ne 22:20 · 8 CBCT So 22:30 · 12 NP_Group So 22:40 · 10 Lightroom So 23:10 · 17 Loxone So 23:50 · 19 HDD_Backup Ne 23:50.

**Systémové:** 1 DSM Auto Update (Čt 6:50, `synoupgrade --autoupdate`) · 2 Auto S.M.A.R.T. Test (So 0:00) · 13 Run security advisor (Po 20:02) · **20 Vyčištění RTG (měsíčně, `bash /volume1/RTG_OPG/archive.sh`)** ← vlastní skript, zálohovat i ten.

→ `.dss` úlohy NEobsahuje; tenhle výpis + `esynoscheduler.db` (vedle tohoto dokumentu v `synology_dump/`) je jejich DR záznam. HyperBackup→C2 se re-napojí klíčem (PEMy + přístup do C2 přes web). Interní ID cílů N = 39/48/49/54/55/57/59/60/61/62.

## 9) Co ještě doplnit (potřebuje root / DSM GUI) — [root]
- Přesná **práva sdílených složek** per uživatel (ACL) — `synoshare --get <name>` / DSM.
- **Seznam DSM uživatelů a skupin** (`synouser --enum`).
- **Plánované úlohy** (Task Scheduler) — `synoschedtask`.
- **HyperBackup úloha**: přesný cíl C2, plán, šifrovací klíč (kde je uložen!).
- **CloudSync účty** (Google Drive) — které účty, směr synchronizace.
- **Firewall / auto-block / DDNS / QuickConnect** nastavení.
- **Síť**: gateway, DNS servery, DoH.
- **Export DSM konfigurace**: Ovládací panel → Aktualizace a obnova → Záloha konfigurace → stáhnout `.dss` (uložit mimo NAS!).

---
*Sestaveno automaticky ze živého stavu NASu 16.8.2026. Při změnách (nové sdílené složky, práva, zálohy) aktualizovat + přegenerovat vault.*
