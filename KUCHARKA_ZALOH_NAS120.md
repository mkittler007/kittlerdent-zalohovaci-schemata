# Kuchařka záloh — Synology .120 (DS418play)

> Kdy co běží na NASu `192.168.100.120`, jak dlouho to trvá a kam který nový job zaplánovat,
> aby se nepral s ostatními na slabém DS418play (4j Celeron J3355, 6 GB RAM od 30.8.2026).
> **Rozvrhy vytaženy ŽIVĚ 5.9.2026** (root, `synoschedtask --get` — aktuální stav, ne starý dump).
> WhiteStore rozvrh z paměti `project_ws_backup_watch` (server-side, nastaveno 25.8.).
> rsync joby z `reference_nas_zalohy` + `project_vm_package_zaloha`.
> Pozn.: Synology nedrží historii běhů (`task_result` = 0 záznamů) → doby denních C2 uploadů
> jsou inkrementální (delta) = jednotky minut; velké přenosy odhadnuty z reálných měření v paměti.

---

## 1) Tři systémy, které soupeří o NAS

| Systém | Co dělá | Kam | Úzké hrdlo |
|---|---|---|---|
| **WhiteStore (Ahsay OBM)** | balíček na NASu zálohuje složky | cloud WhitestoreCBS | NAS CPU + **upload** internetu |
| **HyperBackup** | `dsmbackup` = upload, `detect_monitor` = kontrola integrity | Synology **C2** cloud | NAS CPU + **upload** internetu |
| **rsync (Mac Mini .24 + iMac .170)** | push záloh na NAS | disk NASu | NAS CPU + **LAN + zápis** na NAS |

WhiteStore i HyperBackup perou o **stejný upload** (NAS→internet); rsync pere o **LAN + zápis na disk NASu**. Na slabém DS418play se dva těžké joby naráz navzájem brzdí.

---

## 2) Denní časová osa (24 h) — ŽIVÝ stav 5.9.2026

| Čas | Job | Systém | Typ | Doba |
|---|---|---|---|---|
| **01:50** (So) | Backup settings — kontrola integrity | HyperBackup | týdně So | minuty |
| **02:30** | Lightroom → C2 | HyperBackup | **denně** upload | minuty (delta) |
| 03:00–05:00 | — 🟢 **KLID** — | | | (nejtišší okno pro C2) |
| **05:30** | Syno settings (á 3 dny) | WhiteStore | upload | sekundy |
| **06:50** (Čt) | DSM Auto Update | systém | týdně Čt | minuty |
| **08:00** | Claude_Project ← Mac Mini | rsync | denně | minuty |
| **09:00** | RTG_OPG | WhiteStore | upload | minuty |
| **10:15** | Lightroom | WhiteStore | upload | minuty |
| **11:00** | Soft21 | WhiteStore | upload | minuty |
| **11:00** (Ne) | RTG_OLD → C2 | HyperBackup | týdně Ne | minuty |
| **12:00** | npgroup (sklad) | WhiteStore | upload | ~1–2 min |
| **12:00** | **iMac cold (lokální)** | iMac .170 | denně | ~0 s (COW) |
| **13:00** ⭐ | **iMac VM → NAS** NOVÉ | rsync | denně | 1. běh ~50 min, pak delta |
| 13:30–15:00 | — 🟢 **KLID (LAN)** — | | | (nejtišší okno pro rsync/LAN) |
| **14:00** ⭐ | **iMac → C2 (doporučeno založit)** | HyperBackup | denně upload | minuty (delta) |
| **15:00** | RTG_OPG | WhiteStore | upload | minuty |
| **17:00** | Soft21 | WhiteStore | upload | minuty |
| **17:00** (Ne) | VM macOS M4 offsite → C2 | HyperBackup | týdně Ne | delta |
| **18:30** | Lightroom | WhiteStore | upload | minuty |
| **19:30** | npgroup (sklad) | WhiteStore | upload | ~1–2 min |
| **19:30** | RTG → C2 | HyperBackup | **denně** upload | minuty |
| **20:02** (Po) | Security advisor | systém | týdně Po | minuty |
| **22:00** | Soft21 → C2 | HyperBackup | **denně** upload | minuty |
| **22:30** | Claude_project → C2 | HyperBackup | **denně** upload | minuty |
| **23:00** (So) | Loxone → C2 | HyperBackup | týdně So | minuty |
| **23:15** | NP_Group → C2 | HyperBackup | **denně** upload | minuty |
| **23:30** (So) | Backup settings → C2 | HyperBackup | týdně So | minuty |
| **23:30** (So) | VM macOS M4 offsite — kontrola integrity | HyperBackup | týdně So | minuty |
| **00:00** (So) | CBCT → C2 + Auto S.M.A.R.T. test | HyperBackup+systém | týdně So | minuty / desítky min |
| **23:50 (obden)** | **VM macOS M4 ram (~1 TB) ← Mac Mini** | rsync | obden | **~8 h (23:59→08:00)** 🔴 |

### Kontroly integrity HyperBackup (`detect_monitor`) — víkendové noci
So: Backup_settings 01:50, Claude_project 21:20, Soft21 21:40, CBCT 22:30, NP_Group 22:40, Lightroom 23:10, VM macOS M4 23:30, Loxone 23:50 · Ne: RTG 21:30, RTG_OLD 22:20, HDD_Backup 23:50. (Čtou vault → zátěž na disk NASu, víkend večer.)

---

## 3) Mapa vytíženosti — kdy je NAS volný a kdy zahlcený

| Okno | Zátěž | Vhodné pro |
|---|---|---|
| **03:00–05:00** | 🟢 klid (jen sudé noci doznívá VM ram) | C2 upload |
| 05:30–12:00 | 🟡 WhiteStore uploady rozprostřené + Claude rsync 08:00 | běžný provoz |
| **13:30–15:00** | 🟢 **nejlepší klid na LAN i C2** | **rsync na NAS + iMac C2** |
| 15:00–19:00 | 🟡 WhiteStore odpolední | běžný provoz |
| **19:30–23:15** | 🔴 **špička** — HyperBackup C2 stack (RTG 19:30, Soft21 22:00, Claude 22:30, NP 23:15) | NIC sem nedávat |
| 23:30–00:30 (So/Ne) | 🔴 víkendové C2 + kontroly integrity + S.M.A.R.T. | NIC těžkého |
| **23:59–08:00 (obden)** | 🔴 VM macOS M4 ram ~1 TB, ~8 h saturuje NAS | NIC těžkého |

**Denní C2 upload (NAS→internet) je teď: 02:30, 19:30, 22:00, 22:30, 23:15.** Přes den (08:00–19:00 v týdnu) je C2 uplink volný — pere o něj jen krátký WhiteStore.

---

## 4) Doporučení pro novou zálohu iMac VM (ordinace)

**a) iMac VM → NAS (rsync, `com.kittler.parallels-nas-daily`)** — nastaveno **13:00 denně**. ✅ Dobře: hned po lokální cold (12:00), padne do poledního klidu, LAN volná. (V Ne 13:00 se lehce potká s „VM macOS M4 cold offsite" — obě jen delta, nevadí; pro jistotu lze posunout na 13:30.)

**b) iMac offsite_current → C2 (HyperBackup, ZALOŽIT V GUI)** — doporučený čas **14:00 denně**. ⭐
- Naváže na rsync (nová cold verze je na NASu ~13:50), C2 upload delty = minuty.
- Je v **denním klidu**, **daleko od večerní C2 špičky (19:30–23:15)**, od noční VM ram (obden) i od noční Lightroom C2 (02:30).
- Přes den o C2 uplink pere jen krátký WhiteStore (RTG 15:00 až za hodinu) → 14:00 čisté.
- Retence **2 verze** (`rotate_earliest`), přesně jako vzor `VM macOS M4 offsite` (task_64).

**Postup založení v DSM (bod b):**
> HyperBackup → **+** → *Složka a soubory* → cíl **Synology C2** (přihlášené) → zdroj **`VM Imac_zelený/offsite_current`** → rozvrh **denně 14:00** → Rotace: **zapnout, „poslední 2 verze"**.

---

## 5) Poznámky / stav

- ✅ **Starý task „HDD_Backup → C2" (dsmbackup 61) je už VYPNUTÝ** (`disabled`) — takže mazání starého VM cíle `HDD IMac ordinace/Parallels_VM_zaloha` nic C2 zálohy nerozbije. (Jeho `detect_monitor` Ne 23:50 zůstal zapnutý, ale je neškodný.)
- Rozvrhy se od dumpu 16.8. **změnily** (Lightroom C2 21:10→**02:30**, CBCT z denní na So 00:00, Soft21 C2 23:40→22:00, Claude 01:20→22:30, NP 20:40→23:15, přibyla VM macOS M4 offsite Ne 17:00) → proto tahle živá verze.
- Nová iMac VM záloha nemá vlastní hlídač stáří (jako VM macOS M4 `hlidac_zaloh.sh`); zatím jen `NAS_STATUS.txt`+`STATUS.txt` na iMacu. Doplnit do supervizoru, kdyby bylo třeba.

---

## 6) Zdroje pravdy
- HyperBackup + systémové rozvrhy: **živě** `synoschedtask --get` (root); config `synology_dump/HyperBackup/synobackup.conf` (⚠️ C2 secrets, mimo git)
- WhiteStore rozvrh: paměť `project_ws_backup_watch` (server-side na server-ng.whitestore.eu)
- rsync joby: `reference_nas_zalohy`, `project_vm_package_zaloha`
- iMac VM záloha: `Imac_zelený_ordinace/` (skripty + plisty) + paměť `project_imac_zeleny_zaloha`
