# Přehled záloh — master (retence · kde leží · plán obnovy)

> Jediné místo, kde je **na jednom pohledu** každé zálohovací schéma: zdroj → cíl → čas → **retence** → **plán obnovy**.
> Podrobnosti jsou v příslušných podsložkách/dokumentech (odkazy ve sloupci „obnova").
>
> **Zdroj pravdy:** živý `launchctl list` na HOSTu (.24) a VM (.82), ověřeno **1.9.2026**.
> **Pravidlo:** při JAKÉKOLI změně plánovače/retence/cíle aktualizovat i tento přehled + `PLANOVACE_WATCHDOGY_NOTIFIKACE.md` (viz [[reference_planovace_watchdogy_prehled]]).

---

## A) Master tabulka všech záloh

| # | Schéma | Zdroj | Cíl (kde leží) | Čas | Retence | Plán obnovy |
|---|---|---|---|---|---|---|
| 1 | **VM macOS — cold balík** (`vmpkg.cold`) | Parallels `macOS.macvm` (host .24, na Thunderboltu) | Thunderbolt `KD_Ext4T` | **06:00 / 13:00 / 18:00** | 4 lokálně | `VM_package_zaloha/OBNOVA.md` scénář A |
| 2 | **VM macOS — ram balík** (`vmpkg.ram`) | tentýž bundle | Thunderbolt `KD_Ext4T` | **07:00 + 23:00** denně | **2** (poslední denní + noční) | `VM_package_zaloha/OBNOVA.md` |
| 3 | **VM macOS — na WD** (`vmpkg.wd`) | nejnovější **cold + ram** z Thunderu | USB `VM_WD` `/Volumes/VM_WD/VM_packages` | 23:10 denně | **cold 3 + ram 1** (link-dest dedup) | `VM_package_zaloha/OBNOVA.md` scénář B |
| 4 | **VM macOS — na Synology** (`vmpkg.nas`) | **cold (nočně) + ram (čtvrtek)** z Thunderu | Synology **.120** `/volume1/VM macOS M4/VM_packages` | cold 23:50 **denně**; ram **čtvrtek** | **cold 3 + ram 1** | `VM_package_zaloha/OBNOVA.md` scénář C |
| 5 | **Claude_Project → NAS** (`backup_claude_project`) | iCloud `Claude_Project/` (host) | Synology **.120** `/volume1/Claude_Project/` | 08:00 + 20:00 | rsync **mirror — bez lokálních verzí**; verze jen off-site v HyperBackup C2 (#8 task 62, **200 verzí**, FIFO) | viz níže „Obnova Claude_Project" |
| 6 | **iMac zelený — VM ordinace lokální cold** | `Windows 11_Imac_zelený 2.pvm` (iMac .170) | interní SSD iMacu `~/Parallels_Backup_ordinace/backup/` | denně 12:00 | 1 | `Imac_zelený_ordinace/PLAN_OBNOVY.md` A–C |
| 7 | **iMac zelený — VM ordinace na NAS** | lokální cold záloha (#6) | Synology **.120** `/volume1/HDD IMac ordinace/Parallels_VM_zaloha/` | 1. neděle v měsíci 13:00 | 2 (vm_current + vm_prev) | `Imac_zelený_ordinace/PLAN_OBNOVY.md` scénář D |
| 8 | **Synology HyperBackup → C2 cloud** | sdílené složky NASu (RTG, CBCT, Lightroom, Soft21, Claude_Project, Loxone, NPGroup, HDD iMac, Backup_Settings) **+ nově VM macOS M4 a VM iMac zelený** (viz #18/#19) | Synology **C2 cloud** (`synocloud_swift`, EU, šifrované+komprimované) | denně/týdně 19:30–01:20 dle úlohy | **rotace zapnutá u všech**; max verzí dle úlohy — souhrn v sekci D | `DR_restore_playbook.md` bod 4 (relink na C2) |
| 9 | ~~Synology Btrfs snapshoty~~ **NEPOUŽITÉ** | — | — | — | **žádné** — balík SnapshotReplication není nainstalovaný, 0 snapshotů (ověřeno 1.9.2026) → viz riziko E5 | — |
| 10 | **Synology Drive — verzování** | Drive složky | NAS | průběžně | historie 1 měsíc / 10 verzí / max 100 MB (dle `synology_dump/SynologyDrive/setting.conf`) | `DR_restore_playbook.md` bod 7 |
| 11 | **No Problem (IMS) pull** | Synology **.120** `/volume1/npgroup_backup/database/` | iCloud `Claude_Project/Sklad/database/` | 08:00 + 16:00 | 1 (jen nejnovější) | viz níže „Obnova IMS/No Problem" |
| 12 | **Dump 2kdent → lokální MySQL na VM** (`sync_db`) | Synology `soft21backup/webroot/backup/dbbackup` (produkce dumpuje á 2 h) | dumpy v iCloud `Claude_Project/IS_KittlerDent/databaze/`; živá DB v `/opt/homebrew/var/mysql/2kdent` (VM) | každou hodinu | **3 poslední dumpy** (~830 MB/ks) | reimport dumpu přes `sync_crm_db.sh` |
| 13 | **DSM konfigurace `.dss`** | NAS DSM (uživatelé, složky+ACL, síť, služby) | tato složka (v šifrovaném `SECRETS_…enc`) + mimo NAS | **ručně** (žádná scheduler úloha); interní `configautobackup` jede denně, ale jen do NASu `/volume1/@config_backup` (nepřenositelný) | poslední ruční export 16.8.2026 (⚠️ dělat pravidelně) | `DR_restore_playbook.md` bod 2 |
| 14 | **Time Machine** (iMacy ordinace) | zelený/žlutý iMac | USB `WD Backup 8` (+ `TM_iMac_zluty`) sparsebundly | průběžně (macOS TM) | dle místa na disku | nativní TM restore; viz [[project_tm_zaloha_ordinace_usb]] |
| 15 | **CPU/RAM monitoring logy** (ne data, ale s retencí) | host + VM | lokálně + Synology **.120** `/volume1/Mac_mini_Pro_Logy/` | sběr á 60 s; sync 04:20/04:40 | 90 dní | n/a (jen logy) |
| 16 | **GitHub — infra/kód** | `Zalohovací schemata/` mirror + repa `kittlerdent-*` | GitHub (privátní, účet mkittler007) | při každé změně (autopush z VM) | plná git historie | `git clone` (push jen z VM .82, klíč `github_implantaty`) |
| 17 | **Time Machine hostu (Mac mini Pro)** | host .24 (VM vyloučená) | **týdně na 2 cíle:** WD `My Book` (disk7s2) + Synology `VM macOS M4` (smb, síťový; `.sparsebundle` v kořeni share) | **neděle** WD 03:00 + Synology 14:00 (LaunchDaemony `tm-wd-weekly`/`tm-syno-weekly`; hodinové auto VYPNUTO) | WD **kvóta 3 TB**; NAS **kvóta 1,5 TB** (nastavit po 1. záloze), pak FIFO | nativní TM restore; rotaci WD hlídá `com.kittler.tm-wd-rotation` |
| 18 | **VM macOS M4 — cold off-site → C2** (HyperBackup task 64) | cold balík VM macOS na NASu `.120` `/volume1/VM macOS M4/VM_cold_offsite/macOS_cold_current.macvm` | Synology **C2 cloud** `VM macOS M4_VM_cold_offsite.hbk` (`synocloud_swift`, EU, šifrované+komprimované, cross-file dedup) | dle HyperBackup scheduleru (sched_id 26) | Smart Recycle (hodinové 1 den → denní 28 dní → týdenní dál) | `DR_restore_playbook.md` bod 4 (relink na C2) |
| 19 | **VM iMac zelený (ordinace) — off-site → C2** (HyperBackup task 65) | NASu `.120` `/volume1/VM Imac_zelený` (exclude staré `.pvm` + `offsite_current/`) | Synology **C2 cloud** `VM_Imac_zelený_offsite_current.hbk` (`synocloud_swift`, EU, šifrované+komprimované, cross-file dedup) | dle HyperBackup scheduleru (sched_id 28) | Smart Recycle (hodinové 1 den → denní 28 dní → týdenní dál) | `Imac_zelený_ordinace/PLAN_OBNOVY.md` + relink na C2 |

**Šifrované secrety** (mimo GitHub, jen v tomto hubu = NAS+cloud): `SECRETS_zalohovaci_schemata.tar.gz.enc` (AES-256, heslo ve správci hesel) — obsahuje `.dss`, HyperBackup C2 credentials, Synology Drive conf, `.telegram.env`. Rozbalení viz `DR_restore_playbook.md`.

---

## B) Kde to fyzicky leží (podle úložiště)

| Úložiště | Co na něm je | Pozn. |
|---|---|---|
| **Interní SSD Mac Mini (.24)** | VM cold/ram balíky (retence 4) | pracovní kopie, nejrychlejší restore |
| **Thunderbolt `KD_Ext4T`** (3,6 TB, ~48 %) | VM cold balíky (Thunderbolt režim) | plný režim po připojení TB disku |
| **USB `VM_WD`** (5,5 TB, ~44 %) | VM balíky `VM_packages` (retence 5) | `vmpkg.wd` denně 23:10 |
| **USB `WD Backup 8`** (7,3 TB, ~62 %) | Time Machine sparsebundly iMaců, IMS, Claude Project kopie | **⚠️ TM svazek hlásí 100 % inodů — hlídat, ať nezačne odmítat zápisy** |
| **Synology .120** `/volume1/` | `VM macOS M4/VM_packages` (cold 3 + ram 1), `VM macOS M4/VM_cold_offsite` (zdroj C2 #18), `VM macOS M4/*.sparsebundle` (host TM #17, v kořeni share), `VM Imac_zelený` (zdroj C2 #19), `Claude_Project` (mirror), `HDD IMac ordinace/Parallels_VM_zaloha`, `npgroup_backup`, `Mac_mini_Pro_Logy`, zdrojové share pro HyperBackup | hlavní on-site NAS, RAID5/Btrfs |
| **Synology C2 cloud** (EU) | off-site kopie klíčových share (RTG/CBCT/Lightroom/Soft21/Claude_Project/…) | jediná off-site vrstva; šifrované |
| **iCloud (host)** `Claude_Project/` | zdroj všech projektů; cíl dumpu 2kdent a IMS pull | zrcadlí se na NAS 2×/den |
| **iMac zelený (.170)** | lokální cold VM ordinace (Windows/Soft21) | + měsíčně na NAS |
| **GitHub** | infra skripty + kód `kittlerdent-*` | verze, ne data; secrety NE |

---

## C) Plán obnovy — rychlý index (co otevřít podle scénáře)

| Co spadlo | Otevři | Klíč / předpoklad |
|---|---|---|
| **VM macOS (hlavní automat)** nejede | `VM_package_zaloha/OBNOVA.md` | nejbližší zdroj: lokální balík → VM_WD → NAS |
| **Mac Mini (host) mrtvý**, VM balík jen na NAS/WD | `VM_package_zaloha/OBNOVA.md` scénář C (+ B) | Parallels na jiném Macu, balík z `.120` / `VM_WD` |
| **NAS Syno_Backup (.120) mrtvý** | `DR_restore_playbook.md` + `synology_DR_konfigurace.md` | `.dss` z SECRETS + relink HyperBackup na C2 (PEM u Martina) |
| **iMac zelený / ordinace VM** spadl | `Imac_zelený_ordinace/PLAN_OBNOVY.md` | lokální cold (12:00) nebo NAS měsíční |
| **Ztráta Claude_Project dat** | níže „Obnova Claude_Project" | mirror na `.120` + Btrfs snapshot |
| **Ztráta IMS / No Problem DB** | níže „Obnova IMS/No Problem" | nejnovější dump v iCloud + zdroj na `.120` |
| **Ztráta IS/produkční DB 2kdent** | reimport přes `sync_crm_db.sh` | 3 poslední dumpy v `IS_KittlerDent/databaze/` + zdroj `soft21backup` |

### Obnova Claude_Project
Mirror leží na `.120:/volume1/Claude_Project/` (bez verzí — je to 1:1 zrcadlo). Obnova aktuálního stavu = rsync zpět do iCloudu:
`rsync -a --info=progress2 admin@192.168.100.120:/volume1/Claude_Project/ "/Volumes/My Shared Files/Claude_Project/"` (klíč `~/.ssh/synology_backup`, z hostu). **⚠️ Pozor: mirror NEdrží verze a NAS nemá Btrfs snapshoty** (ověřeno 1.9.2026). Smazaný/přepsaný soubor, který se už stihl promítnout do mirroru (`--delete`), je proto obnovitelný **jen z HyperBackup C2** — úloha 62 „Claude_project_Syno120", **200 verzí (FIFO)**, přes HyperBackup Explore/Restore z C2 repozitáře na NASu.

### Obnova IMS / No Problem
Nejnovější dump DB leží v iCloud `Claude_Project/Sklad/database/` (pull 08:00/16:00, drží se 1 kopie); primární zdroj je `.120:/volume1/npgroup_backup/database/`. Obnova aplikace = nasadit tento dump zpět do No Problem/IMS instance dle jejich postupu; pull sám je jen kopie snímku, ne aplikační restore. Viz [[project_ims_pull]], [[project_no_problem_faktury]].

---

## D) Retence — souhrn a známé mezery

**Dokumentovaná retence (lokální/on-site):** VM cold 4 (Thunderbolt) · VM ram **2** (poslední denní + noční) · VM WD **cold 3 + ram 1** · VM NAS **cold 3 + ram 1** (ram jen čtvrtek) · host TM (My Book) kvóta 3 TB/hodinově · iMac lokální 1 · iMac NAS 2 · Synology Drive 1 měsíc/10 verzí/100 MB · IMS pull 1 · dump 2kdent **3** · CPU/RAM logy 90 dní · GitHub plná historie.

**HyperBackup → C2 (off-site) — max verzí a typ rotace dle úlohy** (ověřeno na NASu 1.9.2026, doplněno 5.9.2026 o VM úlohy 64/65, `/usr/syno/etc/synobackup.conf`; rotace zapnutá u všech):

| Task | Úloha | Zdroj | Max verzí | Rotace |
|---|---|---|---|---|
| 39 | Loxone | /Loxone | 256 | Smart Recycle |
| 48 | RTG | RTG_Direct_Upload_IS + RTG_OLD + RTG_OPG | 256 | Smart Recycle |
| 49 | Lightroom | Lightroom + Pictures_Direct_Upload_IS | 256 | Smart Recycle |
| 54 | RTG_OLD | /RTG_OLD | 10 | FIFO (od nejstarší) |
| 55 | Backup_Settings | /Backu_up_settings | 256 | FIFO |
| 57 | NP_Group | /npgroup_backup | 59 | FIFO |
| 59 | CBCT | /CBCT | 256 | Smart Recycle |
| 60 | Soft21 | /soft21backup | 12 | Smart Recycle |
| 61 | HDD iMac | /HDD IMac ordinace | 10 | Smart Recycle |
| 62 | **Claude_Project** | /Claude_Project | **200** | FIFO |
| 64 | **VM macOS M4 (cold off-site)** | /VM macOS M4/VM_cold_offsite | Smart Recycle (bez pevného stropu) | Smart Recycle (hod 1d → den 28d → týden dál) |
| 65 | **VM iMac zelený (off-site)** | /VM Imac_zelený (excl. staré `.pvm` + `offsite_current/`) | Smart Recycle (bez pevného stropu) | Smart Recycle (hod 1d → den 28d → týden dál) |

Smart Recycle = ředí (hodinové verze ~1 den → denní ~28 dní → týdenní), N = horní strop počtu verzí. FIFO = drží posledních N, maže nejstarší.

**Zbývající (nekritické) k dořešení:**
- **DSM `.dss`** (#13): žádná automatická scheduler úloha pro přenositelný export — dělá se ručně (poslední 16.8.2026). Zvážit měsíční připomínku. Interní `configautobackup` (denně do `/volume1/@config_backup`) přenositelný `.dss` nenahrazuje.

---

## E) Známé problémy / rizika (k 1.9.2026)

1. **Stará generace VM zálohy je mrtvá, ne živá.** `com.kittler.vm-backup` (týdenní přímý klon → NAS, retence 7+1) a `com.kittler.vm-backup-wd` (obden → WD) **NEJSOU nahrané v launchctl** (ověřeno 1.9.2026). `vm-backup-wd.sh` navíc cílil na `/Volumes/My Book 1`, který neexistuje. Živá VM záloha = **výhradně nová `vmpkg.*` větev** (cold/ram/wd/nas, viz #1–4), všechny běžely OK 1.9. Složka `Retence VM macOS/` je proto **legacy** (viz její deprecation poznámka).
2. **`WD Backup 8` (TM svazek) hlásí 100 % inodů** — hlídat, aby nezačal odmítat zápisy Time Machine.
3. **Dump 2kdent neleží na disku VM**, jen na sdíleném iCloudu; na VM je pouze živá naimportovaná DB. Binlogy se na VM **netvoří** (`skip-log-bin`) — VM disk se jimi neplní; pravidlo o PURGE binlogů je dnes bezpředmětné (viz [[project_vm_disk_binlogy]]).
4. **Off-site vrstva je jediná = C2 cloud.** Vše ostatní je on-site (Mac Mini + NAS + USB v jedné lokalitě). Při požáru/krádeži lokality drží data jen HyperBackup C2 → jeho funkčnost a retence jsou kritické.
   - **AKTUALIZACE 5.9.2026:** off-site už kryje i **oba VM** — VM macOS M4 (task 64, zdroj `VM_cold_offsite`) a VM iMac zelený (task 65) jdou přes HyperBackup do C2 (viz #18/#19). Dřívější díra „VM jsou jen on-site" je tím zacelená; C2 zůstává jediná off-site lokalita.
5. **NAS nemá žádné lokální Btrfs snapshoty** (balík SnapshotReplication není nainstalovaný, 0 snapshotů — ověřeno 1.9.2026). Důsledek: on-site není žádná rychlá „rollback" / ransomware-recovery vrstva ani verzování mirroru. Smazaný/poškozený/zašifrovaný soubor, jakmile se promítne do mirroru, je obnovitelný **jen z off-site C2** (verze dle úlohy, viz sekce D — Claude_Project 200 verzí).
   - **ROZHODNUTÍ (Martin, 2.9.2026): snapshoty ZATÍM NEzapínat**, verzování drží C2 (dostatečné; snapshoty = jen rychlejší lokální obnova + druhá vrstva, ne díra v ochraně). Kdyby se to příště chtělo: denní snapshot / retence 30 dní na `Claude_Project` + `soft21backup`, odhad záboru **~150–300 GB** (NAS je na 44 %, 6 TB volných). Detail v paměti [[project_nas_snapshoty_odlozeno]].
6. **Retence ram u schématu #4 (`vmpkg.nas`) nepromazává.** Ke 5.9.2026 leželo v `.120:/volume1/VM macOS M4/VM_packages` **5 ram balíků místo 1** (plán = „ram 1"); navíc osamocený balík `macOS_2026-08-24_0732.macvm` (1,7 TB) přímo v kořeni `/VM macOS M4/` mimo `VM_packages/`. Ručně smazáno (orphan 1,7 TB + 3 staré ram ~1,25 TB + `.DS_Store`) → **uvolněno ~2,9 TB** (`.120` z 57 % na 29 %). **TODO:** ověřit/opravit prořezávání ram ve `vmpkg.nas`, jinak se to znovu nahromadí.

---

## Vazby
`[[reference_nas_zalohy]]` · `[[reference_synology_konfigurace]]` · `[[project_vm_snapshots_parallels]]` · `[[project_vm_package_zaloha]]` · `[[project_zaloha_wd_thunderbolt]]` · `[[project_tm_zaloha_ordinace_usb]]` · `[[project_imac_zeleny_zaloha]]` · `[[project_ims_pull]]` · `[[reference_planovace_watchdogy_prehled]]` · `[[reference_zalohovaci_schemata_repo]]`
