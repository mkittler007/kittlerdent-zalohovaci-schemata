# Kuchařka záloh — Synology .120 (DS418play)

> Kdy co běží na NASu `192.168.100.120`, jak dlouho to trvá a kam který nový job zaplánovat,
> aby se nepral s ostatními na slabém DS418play (4j Celeron J3355, 6 GB RAM od 30.8.2026).
> Sestaveno 5.9.2026 z: `synology_dump/tasks.txt` (HyperBackup rozvrhy, root, vytaženo 16.8.),
> paměti `project_ws_backup_watch` (WhiteStore rozvrh, nastaveno Martinem 25.8.),
> `reference_nas_zalohy` + `project_vm_package_zaloha` (rsync z Mac Mini + iMac).
> **HyperBackup časy jsou z 16.8.** — nová úloha `VM macOS M4 offsite` (task_64) přibyla 5.9., v dumpu není.

---

## 1) Tři systémy, které soupeří o NAS

| Systém | Co dělá | Kam | Úzké hrdlo |
|---|---|---|---|
| **WhiteStore (Ahsay OBM)** | balíček na NASu zálohuje složky | cloud WhitestoreCBS | NAS CPU + **upload** internetu |
| **HyperBackup** | `dsmbackup` = upload, `detect_monitor` = kontrola integrity | Synology **C2** cloud | NAS CPU + **upload** internetu |
| **rsync (Mac Mini .24 + iMac .170)** | push záloh na NAS | disk NASu | NAS CPU + **LAN + zápis** na NAS |

Klíč: WhiteStore i HyperBackup perou o **stejný upload** (NAS→internet); rsync pere o **LAN + zápis na disk NASu**. Na slabém DS418play se dva těžké joby naráz navzájem brzdí.

---

## 2) Denní časová osa (24 h) — co běží kdy

| Čas | Job | Systém | Typ | Doba (odhad) |
|---|---|---|---|---|
| **01:20** | Claude_project → C2 | HyperBackup | denně upload | minuty (delta) |
| 02:00–05:00 | — **KLID** — | | | (nejtišší okno pro C2) |
| **05:30** | Syno settings (á 3 dny) | WhiteStore | upload | sekundy |
| **08:00** | Claude_Project ← Mac Mini | rsync | denně | minuty |
| **09:00** | RTG_OPG | WhiteStore | upload | minuty |
| **10:15** | Lightroom | WhiteStore | upload | minuty |
| **11:00** | Soft21 | WhiteStore | upload | minuty |
| **12:00** | npgroup (sklad) | WhiteStore | upload | ~1–2 min (delta) |
| **12:00** | **iMac cold (lokální)** | iMac .170 | denně | ~0 s (COW, VM paused) |
| **13:00** | **iMac VM → NAS** ⭐NOVÉ | rsync | denně | 1. běh ~50 min, pak delta pár min |
| **13:00** (Ne) | VM macOS M4 cold offsite ← Mac Mini | rsync | týdně Ne | delta |
| 13:30–15:00 | — **KLID (LAN)** — | | | (nejtišší okno pro LAN/rsync) |
| **15:00** | RTG_OPG | WhiteStore | upload | minuty |
| **17:00** | Soft21 | WhiteStore | upload | minuty |
| **17:00** (Ne) | VM macOS M4 offsite → C2 | HyperBackup | týdně Ne | delta |
| **18:30** | Lightroom | WhiteStore | upload | minuty |
| **19:30** | npgroup (sklad) | WhiteStore | upload | ~1–2 min |
| **19:30** | RTG → C2 | HyperBackup | denně upload | minuty |
| **20:02** (Po) | Security advisor | systém | týdně Po | minuty |
| **20:20** (Ne) | RTG_OLD → C2 | HyperBackup | týdně Ne | minuty |
| **20:40** | NP_Group → C2 | HyperBackup | denně upload | minuty |
| **21:10** | Lightroom → C2 | HyperBackup | denně upload | minuty–desítky min |
| **21:50** | CBCT → C2 | HyperBackup | denně upload | minuty |
| **21:50** (Fri) | Loxone → C2 | HyperBackup | týdně Pá | minuty |
| **21:50** (Ne) | HDD IMac ordinace → C2 | HyperBackup | týdně Ne | minuty ⚠️(viz §5) |
| **23:40** | Soft21 → C2 | HyperBackup | denně upload | minuty |
| **23:50** (So) | Backup settings → C2 | HyperBackup | týdně So | minuty |
| **23:50 (obden)** | **VM macOS M4 ram (~1 TB) ← Mac Mini** | rsync | obden | **~8 h (23:59→08:00)** 🔴 |
| **00:00** (So) | Auto S.M.A.R.T. test | systém | týdně So | desítky min |

### Kontroly integrity HyperBackup (`detect_monitor`) — víkendové noci
So: Backup_settings **01:50**, Claude_project 21:20, Soft21 21:40, CBCT 22:30, NP_Group 22:40, Lightroom 23:10, Loxone 23:50 · Ne: RTG 21:30, RTG_OLD 22:20, HDD IMac 23:50. (Čtou vault, zatěžují disk NASu.)

---

## 3) Mapa vytíženosti — kdy je NAS volný a kdy zahlcený

| Okno | Zátěž | Vhodné pro |
|---|---|---|
| **02:00–05:00** | 🟢 klid (jen sudé noci doznívá VM ram do 08:00) | **C2 upload** (internet volný) |
| 05:30–12:00 | 🟡 WhiteStore uploady rozprostřené | běžný provoz |
| **13:30–15:00** | 🟢 klid na LAN | **rsync na NAS** (LAN volná) |
| 15:00–19:00 | 🟡 WhiteStore odpolední | běžný provoz |
| **19:30–00:00** | 🔴 **špička** — HyperBackup C2 stack + víkendové kontroly | NIC sem nedávat |
| **23:59–08:00 (obden)** | 🔴 VM macOS M4 ram ~1 TB, ~8 h saturuje NAS | NIC těžkého sem |

---

## 4) Doporučení pro novou zálohu iMac VM (ordinace)

**a) iMac VM → NAS (rsync, `com.kittler.parallels-nas-daily`)** — teď **13:00 denně**.
- ✅ Dobře: hned po lokální cold (12:00), padne do klidného poledne, LAN volná.
- ⚠️ V neděli 13:00 se potká s „VM macOS M4 cold offsite" (taky Ne 13:00) — obě jsou ale jen delta, kolize nevýznamná. Když bys chtěl jistotu, posuň iMac na **13:30**.

**b) iMac offsite_current → C2 (HyperBackup, ZALOŽIT V GUI)** — doporučený čas **14:00 denně**.
- Naváže na rsync (nová cold verze je na NASu ~13:50), C2 upload delty = minuty.
- Je v denním klidu, **daleko od večerní C2 špičky (19:30–00:00)** i od noční VM ram (obden).
- Retence **2 verze** (`rotate_earliest`), přesně jako vzor `VM macOS M4 offsite`.
- Alternativa, když bys chtěl C2 radši v noci: **03:00** (po Claude_project 01:20, před WhiteStore 05:30) — ale sudé noci tam ještě doznívá VM ram → 14:00 je čistší.

**Postup založení v DSM (bod b):**
> HyperBackup → **+** → *Složka a soubory* → cíl **Synology C2** (přihlášené) → zdroj **`VM Imac_zelený/offsite_current`** → rozvrh **denně 14:00** → Rotace: **zapnout, „poslední 2 verze"**.

---

## 5) Co ještě prověřit / uklidit

- ⚠️ **HyperBackup task „HDD IMac ordinace → C2" (61, Ne 21:50)** zálohuje celou složku `HDD IMac ordinace`. Rušíme z ní podsložku `Parallels_VM_zaloha` (starý cíl VM, 71 G) → C2 ji při další rotaci zahodí. Zbytek složky (pokud tam něco je) se zálohuje dál. Zvážit, jestli task 61 ještě něco smysluplného kryje, nebo ho vypnout.
- Nová VM iMac záloha nemá zvlastní hlídač stáří jako VM macOS M4 (`hlidac_zaloh.sh`). Zatím stav hlídá jen `NAS_STATUS.txt` + `STATUS.txt` na iMacu. Kdyby bylo potřeba, doplnit do supervizoru.
- HyperBackup přesné časy jsou z 16.8. — až budeš mít root heslo NASu, jde znovu vytáhnout `esynoscheduler.db` a tabulku obnovit (teď root nemám).

---

## 6) Zdroje pravdy
- HyperBackup rozvrhy: `synology_dump/tasks.txt` · config: `synology_dump/HyperBackup/synobackup.conf` (⚠️ C2 secrets, mimo git)
- WhiteStore rozvrh: paměť `project_ws_backup_watch` (server-side na server-ng.whitestore.eu)
- rsync joby: `reference_nas_zalohy`, `project_vm_package_zaloha`
- iMac VM záloha: `Imac_zelený_ordinace/` (skripty + plisty) + paměť `project_imac_zeleny_zaloha`
