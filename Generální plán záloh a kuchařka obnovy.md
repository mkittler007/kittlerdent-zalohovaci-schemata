# Generální plán záloh a kuchařka obnovy

> **Master dokument — STROJOVĚ orientovaný.** Pro každý stroj: co na něm žije, jak/kdy/kam se zálohuje,
> a **kuchařka obnovy** včetně klíčové věci — *co přesně ztrácím, když obnovím tuto konkrétní verzi*.
>
> **Zdroj pravdy:** živý `launchctl list` na hostu (.24) a VM (.82) + tento dokument. Doprovodné dokumenty:
> `PREHLED_ZALOH.md` (index schémat po řádcích), `DR_restore_playbook.md`, `PLANOVACE_WATCHDOGY_NOTIFIKACE.md`,
> a per-stroj „podložky" ve složkách (`VM_package_zaloha/`, `Imac_zelený_ordinace/`, `synology_dump/`, …).
>
> **Pravidlo údržby:** při JAKÉKOLI změně plánovače/retence/cíle/stroje aktualizovat **tento dokument**
> + příslušnou per-stroj podložku + `PREHLED_ZALOH.md`. Týdenní **konzistenci a osiřelost hlídá Knihovník**
> (modul „Zálohovací hygiena", pondělí 06:00 — jen reportuje).
>
> **Aktuálnost:** 22.9.2026 (varianta 2 VM záloh + cutover na kanonický `macOS.macvm`).

---

## Legenda typů záloh (klíč k „co ztrácím")

| Typ | Co zachytí | Obnova | Co ztrácím |
|---|---|---|---|
| **VM cold balík** | disk v okamžiku zálohy (VM pauznutá pár s) | čistý boot | jen běžící paměť = neuložená rozdělaná práce; data na disku jsou |
| **VM ram balík** | disk **+ paměť** (suspend) | 1:1 resume | nic (pokračuje přesně) — ALE ze **zatuhlé** VM je neobnovitelný (22.9. `CANNOT_RESTORE_SUSPEND_STATE`) |
| **rsync mirror** (bez verzí) | poslední stav | rsync zpět | změny od poslední synchronizace; smazané soubory (verze jen v C2) |
| **DB dump** | snímek DB (ne binlog) | reimport | transakce mezi dumpem a pádem (žádná point-in-time recovery) |
| **Time Machine** | průběžné verze | nativní TM restore | od poslední TM zálohy |
| **HyperBackup → C2** | off-site verze (šifrované) | relink + restore | nejstarší verze (dle retence FIFO/Smart Recycle) |

---

# ČÁST 1 — SOUPIS STROJŮ A JEJICH ZÁLOH

## 1) Mac Mini M4 Pro — HOST (`192.168.100.24`)
**Role:** hypervisor Parallels (běží v něm automatizační VM), hlavní plánovač launchd, host Time Machine, sběr monitoringu.
**Co žije:** Parallels + VM `macOS.macvm` (na Thunderboltu), balík launchd agentů (zálohy, watchdogy), Apple Mail index, podcast/fitness/web služby.

| Co se zálohuje | Cíl | Metoda | Kdy | Retence | Watchdog |
|---|---|---|---|---|---|
| VM cold balík | Thunderbolt `KD_Ext4T/VM_packages` | COW `cp -cR` | 06/13/18 | **4** | `vmpkg.hlidac` |
| VM ram balík | Thunderbolt `KD_Ext4T/VM_packages` | suspend→clone | **jen 23:00** | **1** | `vmpkg.hlidac` |
| VM cold → WD | `VM_WD/VM_packages` | rsync `--link-dest` | 23:10 | **cold 3** (ram vypnut) | `vmpkg.hlidac` |
| VM cold → NAS | `.120:/volume1/VM macOS M4/VM_packages` | rsync loopback tunel `-S` | 23:50 | **cold 3** (ram vypnut) | `vmpkg.hlidac` |
| VM cold → C2 (off-site) | Synology C2 `synocloud_swift` | NAS HyperBackup task 64 | ne 13:00 feeder → 17:00 C2 | Smart Recycle | HyperBackup |
| **Host Time Machine** | WD `My Book` + `.120` (SMB) | nativní TM | ne 03:00 (WD) + 14:00 (NAS) | WD 3 TB / NAS 1,5 TB, FIFO | `tm_backup_check`, `tm-wd-rotation` |
| Claude_Project → NAS | `.120:/volume1/Claude_Project` | rsync mirror | 08:00 + 20:00 | mirror (verze v C2 #62, 200×) | `backup_claude_project.watchdog` |
| IS 2kdent dump → iCloud | `Claude_Project/IS_KittlerDent/databaze` | sync z `.120` | á 1 h | 3 dumpy | implantáty watchdog |
| IMS/No Problem → iCloud | `Claude_Project/Sklad/database` | rsync z `.120` | 08/12/16/20 h | 1 | `ims_pull` (2-strike) |
| Monitoring CPU/RAM | host + `.120:/Mac_mini_Pro_Logy` | sampler á 60 s | sync 04:40 | 90 dní | — |

**Off-site:** VM cold + Claude_Project + IS/IMS drží verze v C2. Host TM NENÍ off-site (WD+NAS lokálně).
**Rizika:** Thunderbolt SSD = jediný lokální zdroj VM balíků (odpojení = VM nenabootuje; pojistka WD+NAS+C2). WD sdílí kontejner s TM → hlídat kapacitu.
**Podložka:** `VM_package_zaloha/`, `time_machine_wd/`, `Claude_Project_backup_host/`.

## 2) VM macOS — automatizační stroj (`192.168.100.82`, běží na hostu .24)
**Role:** Claude Code, Django (implantáty/web), noční skripty, GitHub, e-mail, whisper.
**Co žije:** Django apps, GitHub CLI, ffmpeg/whisper, lokální MySQL `2kdent` (reimport dumpů), Synology Drive mount.
**Zálohuje se:** jako **celý VM bundle** (viz stroj #1 — cold/ram/WD/NAS/C2). Uvnitř VM se nic zvlášť nezálohuje (kód je na GitHubu, DB se reimportuje z dumpu).
**Off-site:** ano — VM cold balík → C2 (task 64).
**Rizika:** ram ze zatuhlé VM neobnovitelný (proto varianta 2 = off-disk jen cold). Snapshoty VM jsou **zrušené** (nafukovaly bundle) — má být jen kořen „start-up bezclaude".
**Podložka:** `VM_package_zaloha/` (`PLAN.md`, `OBNOVA.md`).

## 3) iMac zelený — ordinace (`192.168.100.170`)
**Role:** ordinační VM Windows/Soft21 (klinický SW).
**Co žije:** Parallels VM `Windows 11_Imac_zelený 2.pvm` (UUID `5ed2e4d7…`).

| Co se zálohuje | Cíl | Metoda | Kdy | Retence | Watchdog |
|---|---|---|---|---|---|
| VM cold (lokální) | iMac SSD `~/Parallels_Backup_ordinace/backup` | `cp -Rpc` clonefile | pátek 16:45 | 1 | `parallels-cold-backup` |
| VM → NAS | `.120:/volume1/VM Imac_zelený/daily` | openrsync + hardlink dedup | pátek 16:45 | 10 dní + `offsite_current` | `parallels-nas-daily` |
| VM → C2 (off-site) | Synology C2 | HyperBackup task 65 | Po–Pá | Smart Recycle | HyperBackup |

**Off-site:** ano (C2 task 65).
**Rizika:** lokální cold = retence 1; disk iMacu bývá plný (hlídat).
**Podložka:** `Imac_zelený_ordinace/PLAN_OBNOVY.md`.

## 4) iMac žlutý — ordinace
**Role:** ordinační stroj (sestry). **Zálohuje se:** Time Machine → WD Backup 8 (sparsebundle), nativní TM. **Off-site:** ne. **Watchdog:** `tm_backup_check`.

## 5) Synology DS418play (`192.168.100.120`) — HLAVNÍ ON-SITE NAS
**Role:** datové centrum, HyperBackup hub, SMB/NFS pro ordinaci, RAID5 Btrfs (~11 TB).
**Co žije:** sdílené složky (VM balíky, Claude_Project mirror, soft21backup=zdroj IS dumpů, npgroup_backup=IMS, RTG/CBCT/Lightroom/Loxone, HDD iMac ordinace, monitoring logy), DSM konfig.
**Zálohuje se ODCHOZÍ → C2 cloud (jediná off-site vrstva):** HyperBackup úlohy (RTG 256×, CBCT 256×, Lightroom 256×, Soft21 12×, NP_Group 59×, Loxone, HDD iMac, **Claude_Project 200× #62**, **VM macOS cold #64**, **VM iMac zelený #65**). Šifrované + cross-file dedup, EU.
**DSM konfigurace:** ruční export `.dss` (v šifrovaném `SECRETS_zalohovaci_schemata.tar.gz.enc`) — ⚠️ dělat pravidelně (poslední 16.8.2026).
**Off-site:** ano (C2).
**Rizika:** RAID5 bez sekundárního zrcadla (ztráta 2 disků = ztráta on-site; pojistka jen C2). **Btrfs snapshoty VYPNUTÉ** (žádná lokální ransomware vrstva — verze drží jen C2, rozhodnutí MK 2.9.).
**Podložka:** `synology_dump/`, `synology_DR_konfigurace.md`, `KUCHARKA_ZALOH_NAS120.md`.

> **⚠️ ZMĚNA PROBÍHÁ (22.9.2026) — nové VM cold → C2 sady.** Martin založil dvě nové HyperBackup sady místo/vedle starých #64/#65: **`VM M4_Pro_Synology` (repo 66)** a **`VM Zelený_Imac_Synology` (repo 67)**, cíl = 1×/týden cold VM do C2. Stará „VM Maco M4 sada ze synology" **SMAZÁNA** (dělala problémy). Cílový stav: M4 zdroj jen `VM_cold_offsite`, rozvrh **týdně Ne 03:00**; Zelený jen aktuální VM (potřeba `offsite_current`), rozvrh **týdně St 03:30**. **Teď jsou obě omylem DENNÍ** (M4 23:10, Zelený 21:20) a M4 zálohuje celý share → **nutno doladit v DSM UI** (`synoschedtask` neumí `--set`). **Řešit duplikát:** pokud 66/67 nahrazují #64/#65, staré vypnout. Detail + postup → `KUCHARKA_ZALOH_NAS120.md` §4c. (Pravidlo: změna zálohy = vždy update tohoto plánu, memory `feedback_zalohy_aktualizuj_schema`.)

## 6) Synology DS218j (`192.168.100.104`) — SynoVeeam
**Role:** sekundární NAS, fakticky **legacy/nevyužitý** pro klinická data. Bez aktivní zálohovací role. *(Kandidát: buď zapojit jako druhý off-site cíl, nebo vyřadit — k rozhodnutí.)*

## 7) Recepční Macy — iMac `.62`, iMac `.64` (sestry), MacBook recepce `.90`
**Role:** recepce, IS aplikace, `recepce@kittlerdent.cz`.
**Zálohuje se:** **Time Machine → lokální Synology (ordinace)** — nativní TM, celý stroj (systém, lokální nastavení, mailová pravidla/cache). Mail navíc drží IMAP cloud (mx.kittlerdent.cz). ✅ **Pokryto** (potvrzeno MK 22.9.2026).
**Off-site:** ne (TM je na on-site NAS; požár/krádež pokrývá jen to, co jde do C2).

## 8) Domácí Mac Mini OLD (`Tailscale 100.86.128.57`) + NEW (`100.113.103.26`)
**Zálohuje se:** Time Machine → **domácí Synology Bedřichov** (`synoplay`, `100.124.205.123`) — OLD obden (>40 h), NEW týdně (>150 h); + iCloud drží online kopii. **Off-site vůči ordinaci:** ano (jsou doma/v Bedřichově).
**Podložka:** `project_tm_home_macs_wd`, `reference_domaci_synology`.

## 9) Domácí Synology synoplay (`100.124.205.123`)
**Role:** domácí archiv videa + cíl domácích TM. **Zálohuje se:** příchozí domácí TM (Macy OLD/NEW) + video sync (USB→synoplay, částečně, TBD). **Off-site:** ne (domácí).

---

## Matice pokrytí — který stroj → kam

| Stroj | Lokální | WD USB | Thunderbolt | Synology .120 | C2 (off-site) |
|---|---|---|---|---|---|
| **VM macOS (.82)** | — | cold 3 | cold 4 + ram 1 | cold 3 | ✅ cold (#64) |
| **Host .24** | — | TM | (VM balíky) | TM + Claude/IS/IMS | ✅ Claude/IS/IMS |
| **iMac zelený .170** | cold 1 | — | — | daily 10 | ✅ (#65) |
| **iMac žlutý** | — | TM | — | — | ❌ |
| **Synology .120** | RAID5 | — | — | — | ✅ vše (#39–65) |
| **Recepční Macy .62/.64/.90** | — | — | — | ✅ Time Machine | ❌ |
| **Domácí Macy OLD/NEW** | — | — | — | Bedřichov TM | ❌ (doma) |

---

# ČÁST 2 — KUCHAŘKA OBNOVY (co dělat + co ztrácím)

## A) VM macOS (hlavní automat) nenaběhne / je poškozená
**Zdroje (nejbližší → nejvzdálenější):**
1. Thunderbolt `KD_Ext4T/VM_packages` (cold 06/13/18, ram noc) — nejrychlejší
2. WD `VM_WD/VM_packages` (cold 3)
3. Synology `.120:/volume1/VM macOS M4/VM_packages` (cold 3)
4. C2 cloud (cold off-site, přes NAS relink)

**Postup (detail `VM_package_zaloha/OBNOVA.md`):** vyber nejnovější **dobrý** balík z data PŘED problémem → zaregistruj v Parallels (`prlctl register …/macOS.macvm`) → `prlctl start`. **Při zámrzu preferuj COLD** (čistý boot), NE ram ze zatuhlé VM.

| Verze zálohy | Jak stará data | Co ztratím |
|---|---|---|
| cold 06/13/18 (dnešní) | ≤ pár hodin | jen běžící paměť (neuložená práce) |
| cold nejstarší (ret 4) | až ~2 dny | běžící paměť + práce od tehdy |
| **ram noc 23:00** (zdravá VM) | ≤ ~16 h | **nic** — resume přesně kde bylo |
| ram ze **zatuhlé** VM | — | **nepoužitelný** (nenabootuje) → jdi na cold |
| C2 cold off-site | dny–týdny | vše od té verze (ransomware/požár pojistka) |

**Předpoklady:** Parallels na cílovém Macu; klíč `~/.ssh/synology_backup` (přístup na NAS); vědět datum/čas PŘED problémem.

## B) Mac Mini HOST (.24) mrtvý
**Zdroje:** Thunderbolt (připojit k jinému Macu) → WD `VM_WD` → NAS SMB. **Postup:** nový Mac + Parallels → zkopíruj nejnovější `macOS.macvm` balík → `prlctl register` → start. Data celá.
**Co navíc ztratím:** host Time Machine (týdně) = poslední stav hostu; SSH klíče na hostu (redeploy z VM/GitHubu); Parallels Tools/VirtioFS mount (přeinstalovat).

## C) Synology .120 mrtvá
**Zdroje:** `.dss` konfig (v `SECRETS…enc`) + **C2 cloud** (všechny úlohy). **Postup (detail `DR_restore_playbook.md`):** nový DS418play+ → DSM → obnov `.dss` → dohrát SSH klíč, Entware rsync, plánované úlohy, **relink HyperBackup na C2** → ověřit noční zálohy.

| Zdroj | Jak stará data | Co ztratím |
|---|---|---|
| `.dss` konfig | poslední ruční export (16.8.) | plánované úlohy (dohrát ručně) |
| C2 (dle úlohy) | Claude 200 verzí ≈ měsíce; RTG/CBCT 256×; Soft21 12× | nejstarší verze nad retencí |
| Btrfs snapshot | — | **NENÍ** (vypnuté) — žádná lokální rollback vrstva |

**Předpoklady:** nový NAS DSM 7+; heslo na `.dss`/C2 (správce hesel); C2 PEM.

## D) Claude_Project data (ztráta/poškození)
**Zdroje:** NAS mirror (`.120:/volume1/Claude_Project`) → C2 (#62, 200 verzí).
**Postup:** aktuální stav `rsync -a admin@.120:/volume1/Claude_Project/ "/Volumes/My Shared Files/Claude_Project/"`; starší verzi přes HyperBackup Explore z C2.

| Zdroj | Jak stará data | Co ztratím |
|---|---|---|
| NAS mirror | poslední sync (08/20 h) | ≤ 12 h; smazané/přepsané soubory (jsou v C2) |
| C2 (200 verzí) | týdny–měsíce | verze starší než +200 (FIFO) |

## E) IS/databáze 2kdent
**Zdroje:** 3 poslední dumpy (iCloud `IS_KittlerDent/databaze`) → `.120:/soft21backup/…/dbbackup` → C2 (#60, 12 verzí).
**Postup:** `~/bin/sync_crm_db.sh` stáhne nejnovější dump → reimport přes `sync_crm_db.sh` do lokální MySQL.
**⚠️ Co ztratím:** dump je snímek, **ne binlog** (binlogy se na VM netvoří) → **žádná point-in-time recovery**; reimportem ztratím transakce mezi dumpem a pádem (produkce dumpuje á 2 h → max ~2 h). *(Pozn.: živá produkční DB je u poskytovatele Soft21; tohle je lokální kopie pro analýzy/implantáty.)*

## F) IMS / No Problem
**Zdroje:** iCloud dump (`Sklad/database`, pull 08/16 h) → `.120:/npgroup_backup/database` → C2 (#57, 59 verzí).
**Co ztratím:** ≤ 8 h (mezi pully); starší jen z C2.

## G) iMac zelený ordinace (VM Soft21)
**Zdroje:** lokální cold (iMac SSD) → NAS `daily` (10 dní) → C2 (#65).
**Postup (detail `Imac_zelený_ordinace/PLAN_OBNOVY.md`):** ověření = otevřít `config.pvs` z backupu (Parallels „Copy"); plná obnova = stop/unregister/nahradit z backupu; z NAS přes rsync když padl SSD.
**Co ztratím:** lokální cold ≤ 1 den; NAS ≤ týden; C2 dle Smart Recycle.

## H) RTG / CBCT / Lightroom (klinické obrazy)
**Zdroje:** `.120` (živé cíle uploadu) → C2 (#48/#59/#49, 256 verzí). **Co ztratím:** ≤ od posledního uploadu; C2 verze starší než +256.

---

## Rychlý index — co spadlo → co otevřít
| Co spadlo | Otevři | Klíč |
|---|---|---|
| VM macOS nejede | scénář **A** + `VM_package_zaloha/OBNOVA.md` | nejbližší dobrý cold |
| Host .24 mrtvý | scénář **B** + `OBNOVA.md` | balík z Thunderbolt/WD/NAS |
| Synology .120 mrtvá | scénář **C** + `DR_restore_playbook.md` | `.dss` + C2 relink |
| Ztráta Claude_Project | scénář **D** | NAS mirror / C2 |
| IS DB / IMS | scénář **E / F** | dump reimport |
| iMac ordinace | scénář **G** + `Imac_zelený_ordinace/PLAN_OBNOVY.md` | lokální cold |

## Rizika a mezery (stav 22.9.2026)
- **E1** Vše on-site ve stejné budově kromě C2 → požár/krádež pokrývá jen C2.
- **E2** C2 = jediná off-site vrstva; závislost na klíči (správce hesel).
- **E3** Btrfs snapshoty na `.120` VYPNUTÉ → žádná lokální ransomware/rollback vrstva.
- **E4** WD Backup 8 (TM) hlásil 100 % inodů → hlídat, ať neodmítne zápis.
- **E5** IS dump = bez binlogu → PITR jen do nejbližšího dumpu.
- **E6** SynoVeeam `.104` nevyužitý; domácí video sync (USB→synoplay) nedokončený.

## Klíče a secrety (jen ukazatele, hodnoty NE)
- `~/.ssh/synology_backup` (NAS), `~/.ssh/id_ed25519_macmini` (VM→host), `~/.ssh/github_implantaty` (push z VM).
- `SECRETS_zalohovaci_schemata.tar.gz.enc` (AES-256, heslo ve správci hesel): `.dss`, C2 credentials/PEM, Synology Drive conf, `.telegram.env`. Rozbalení viz `DR_restore_playbook.md`.

## Doprovodné dokumenty
`PREHLED_ZALOH.md` (schémata po řádcích) · `DR_restore_playbook.md` · `PLANOVACE_WATCHDOGY_NOTIFIKACE.md` ·
`synology_DR_konfigurace.md` · `KUCHARKA_ZALOH_NAS120.md` · `VM_package_zaloha/{PLAN,OBNOVA}.md` ·
`Imac_zelený_ordinace/PLAN_OBNOVY.md`.
