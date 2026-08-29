# VM záloha — intraday package schéma (spec + resume point)

> Durable zápis plánu, ať přežije i restart/pád session. Až budeme stavět, jede se odtud.
> Souvisí: [[project_vm_snapshots_parallels]], [[reference_nas_zalohy]], [[project_zaloha_wd_thunderbolt]].
> VM: „macOS", UUID `{cf7a9c8f-39b4-4691-8c25-40ebae6a0768}`, host Mac Mini M4 Pro (.24, 64 GB).

## ✅ NASAZENO 29.8.2026 v noci (AKTUÁLNÍ SCHÉMA — nahrazuje starší návrh níže)

Schéma finalizované s Martinem a **nasazené na host** (agenty načtené). Skripty v `~/VM_Safety/bin/`
(source `VM_package_zaloha/`), společná konfigurace `config.sh` (jediné místo pro režim/retenci).

| Vrstva | Co | Kam | Frekvence | Retence | Agent |
|---|---|---|---|---|---|
| Intraday | cold (bez RAM) | vnitřní (COW) → Thunderbolt po po | **06:00 + 18:00** (do po 2×; od po 3× +13:00) | **1** (do po; od po 4) | `com.kittler.vmpkg.cold` |
| Noční | cold+RAM (ram) | vnitřní → Thunderbolt | **23:00** | **1** (stará se smaže před novou) | `com.kittler.vmpkg.ram` |
| WD | ram | USB „My Book" | **23:10 denně** | **5** | `com.kittler.vmpkg.wd` |
| Synology | ram | `.120:/volume1/VM macOS M4/VM_packages` | **23:50 obden** (parita v skriptu) | **4 = 6 dní** | `com.kittler.vmpkg.nas` |

Zdroj pro WD i Synology = hotový noční ram balík z `LOCAL_BASE`. Pořadí ve dnech obojího: **WD (23:10) → Synology (23:50)**.
Off-host jde jen ram balík (cold zůstává lokálně).

**Velikosti (dnes ~300 GB/balík; po konsolidaci cold ~180 / ram ~200 GB):** WD 5×ram ≈ **~1,0 T**;
Synology 4×ram ≈ **~0,8 T**; Thunderbolt (od po) 4 cold+1 ram ≈ **~0,9 T**. Vnitřní (do po) = COW ≈ ~0 + churn (proto retence 1 + pojistka místa `MIN_FREE_GB=40`).

**Časy:** freeze VM jen 1×/den = ~40s suspend ve 23:00 (cold pause = ~pár s). Kopie na WD ~25–35 min, na Synology ~30–90 min (z Thunderboltu; z interního déle) — vše na pozadí, VM běží.

### ⚠️ BLOKERY (nutná Martinova ruční akce)
1. **WD zápis přes launchd/SSH = „Operation not permitted" (TCC).** Kopie na WD NEPOBĚŽÍ, dokud se u stroje neudělí
   **Full Disk Access** runneru (`/bin/bash`) v System Settings → Soukromí a zabezpečení → Plný přístup k disku.
   Tentýž grant odblokuje i **Thunderbolt v pondělí** (TCC platí na všechny externí svazky). Skript `prenos_na_wd.sh`
   to detekuje write-testem a gracefully přeskočí + 1× Telegram (žádná data se nedotknou).
2. **notify.py na hostu NEEXISTUJE** → alerty jdou přes funkční `~/.vm-backup-telegram.env` (přímý Telegram, jen při chybě).

### PONDĚLÍ (po „mám Thunderbolt") — přepnout na plný režim
1. Zjistit mount Thunderboltu (`df -h`), v `config.sh`: přepnout `LOCAL_BASE` na Thunderbolt, `RETAIN_COLD=4`.
2. V `com.kittler.vmpkg.cold.plist` přidat zpět `13:00` (→ 3× denně). Redeploy skriptů+plistů na host, reload agentů.
3. Udělit **Full Disk Access** (odblokuje WD i Thunderbolt zápis).
4. Ostrý test `zaloha_vm_package.sh cold`; ověřit kopie na WD i Synology.
5. Aktualizovat OBNOVA.md (víc lokálních verzí) + PLAN + commit + vault.
6. Zvážit vypnutí starých `com.kittler.vm-backup` / `vm-snapshot` / `vm-backup-wd` (po pár úspěšných bězích nového).

## STAV k 29.8.2026 (co UŽ je hotové)
- **První bezpečnostní kopie HOTOVÁ**: `/Users/martinkittler/VM_Safety/macOS_SAFETY_2026-08-29.macvm`
  (pause→`cp -cR`→resume; 0 s, COW klon, zabral ~0 místa). Nezávislý balík, restorovatelný.
  Chrání proti pádu/špatnému stavu VM, omylem smazanému, špatnému Tools-restartu.
  NEchrání proti pádu interního disku (leží na něm) — to doplní Thunderbolt/Synology.
- **Parallels Tools auto-update VYPNUTÝ** (`prlctl set --tools-autoupdate off`). Tools jsou `outdated` ale funkční.
  Restart k dokončení Tools se má udělat VĚDOMĚ (mimo zálohovací okno), ne automaticky. NEkillovat Tools —
  share `/Volumes/My Shared Files` na nich visí (Host Shared Folders: +).
- Monitoring vytíženosti běží (viz `../vytizenost_CPU_RAM`), doporučí snížení RAM 52→~36 GB po ~2 týdnech.

## CÍL
3× denně + 1× v noci vyrobit **samostatný obnovitelný package** (kopie celého bundlu `macOS.macvm`),
aby při pádu VM / omylem smazaném / pádu disku hosta šlo drag-drop obnovit „přesně tam, kde to bylo".

## MECHANISMUS (ověřený)
`prlctl pause` → `cp -cR bundle dest` → `prlctl resume`.
- **pause** (ne suspend): RAM zůstane v host paměti, NEzapisuje se 52 GB → disk je klidný → klon konzistentní.
- **cp -cR**: APFS clonefile, instantní bez ohledu na velikost, COW (v rámci jednoho disku ~0 místa).
- Downtime VM = jen doba klonu (sekundy). Session ve VM na moment zamrzne a naběhne.
- Suspend (s RAM, 52 GB, ~30–60 s zmrazení) NEpoužívat pro intraday — jen kdyby chtěl true-resume noční.

## TYPY BALÍKŮ A ROZVRH
- **Intraday 3× studený** — 06:00 / 13:00 / 21:00. pause→cp-cR→resume. Bez RAM = lehčí, studený start.
- **Noční 1× s RAM** — true resume „přesně kde to bylo". Buď `suspend`→cp-cR→resume (52 GB RAM ve balíku),
  nebo live `prlctl snapshot` s pamětí → cp-cR. Rozhodnout při stavbě.
- **Noční přenos na Synology** — poslední noční balík na NAS `/volume1/...` (off-host, pád disku hosta).
  Okno: **04:00–05:00** (po stávající vm-backup 00:00, NAS v klidu). Před aktivací ověřit volné místo + kolize.

## VELIKOSTI + PŘEDPOKLAD
- Dnešní bundle 284 GB. Skutečně jsou **jen 3 snapshoty** (ne 12 — to byl počet souborů):
  - `start-up bezclaude instalace` (12.5.) — **CHRÁNĚNÝ, NEmazat**.
  - `auto-2026-08-28_0300` + `auto-2026-08-29_0300` — **suspend snapshoty ~52 GB RAM každý** = ten bloat.
- **KONSOLIDACE (smazat ty 2 auto-*) = PŘEDPOKLAD** → bundle ~130 GB. Studený balík ~130 GB,
  noční s RAM ~180 GB (po snížení RAM na 36 → ~164 GB).
- **DUPLICITA — ROZHODNUTO 29.8.: nové schéma NAHRAZUJE starý `vm-backup-synology.sh`.**
  Sekvence (v pondělí): 1) aktivovat nové schéma, 2) ověřit první úspěšný běh (cold i ram balík vznikl,
  přenos na NAS OK), 3) TEPRVE PAK vypnout LaunchAgent starého vm-backup (`launchctl unload`), 4) spustit
  `konsolidace_snapshotu.sh --apply` (smaže 2 auto-* → bundle ~130 GB). Starý vm-backup skript ani jeho
  data na NAS zatím NEmazat (nech jako pojistku, než nové poběží spolehlivě pár dní).

## ÚLOŽIŠTĚ
- **Interní disk hosta** (150 GB volných): COW klony jsou zdarma, ALE jen zde (clonefile = stejný svazek)
  a NEchrání proti pádu disku. Vhodné jen pro okamžitou pojistku (dnešní safety kopie).
- **Thunderbolt 4 TB (od pondělí)**: intraday i noční plné kopie (COW mezi disky nefunguje = plná velikost,
  4 TB má místo). Hlavní úložiště balíků.
- **Synology .120** `/volume1/VM_packages`: off-host kopie **POUZE nočního RAM balíku** (rsync přes klíč
  `synology_backup`, admin@, Entware rsync). Plná velikost každá. Retence 2.

**POLITIKA off-host (MK 29.8.2026):** intraday cold balíky (06/13/21) = **JEN lokálně na Thunderboltu**,
na NAS se NEposílají. Off-host jde **jen noční RAM balík**. Důvod: plný noční přenos je kvůli kontenci
SSD hosta pomalý (historicky ~24 h/1,2 T) — 3× denně na NAS by NAS i disk zahltilo. Chytřejší bloková
delta-replikace do stálého zrcadla = samostatný úkol na později.

## RETENCE (návrh, upravit dle Martina)
- Intraday studené (Thunderbolt): **poslední 2 dny = 6 balíků** (rolling).
- Noční s RAM (Thunderbolt): **poslední 3 noci**.
- Synology: **poslední 2 noční**.

## RESTORE (jak obnovit)
1. Vezmi vybraný balík (`macOS_SAFETY_*.macvm` / intraday / noční).
2. Přetáhni do `~/Parallels/` (nahraď rozbitý), nebo nech na místě.
3. `prlctl register "<cesta>/…​.macvm"` (nebo dvojklik v Parallels).
4. Boot. Studený balík → čistý start do stavu zálohy. Noční s RAM → resume přesně kde bylo.
   (Stejný host = 1:1, žádné řešení aktivace.)

## POSTAVENÉ SOUBORY (HOTOVO 29.8., bash -n OK) — v `VM_package_zaloha/`
- `zaloha_vm_package.sh cold|ram` — pause(cold)/suspend(ram)→cp-cR interní COW klon→resume→přesun na Thunderbolt→rotace. Nastaví monitoring `phase=backup`. Když Thunderbolt nepřipojen → exit 2 (nezaplní interní disk).
- `konsolidace_snapshotu.sh [--apply]` — dry-run default; chrání `start-up bezclaude instalace`; maže leaf-first.
- `prenos_na_synology.sh` — poslední `macOS_ram_*` z Thunderboltu → NAS `/volume1/VM_packages`, retence 2, Entware rsync.
- LaunchAgenty `launchd/`: `com.kittler.vmpkg.cold` (06/13/21), `.ram` (02:00), `.nas` (04:00).
- Deploy (v pondělí): skripty → `/Users/martinkittler/VM_Safety/bin/`, plisty → `~/Library/LaunchAgents` na hostu, `launchctl load -w`.
- **NEaktivováno** — čeká na Thunderbolt (pondělí) + rozhodnutí o vm-backup duplicitě + konsolidaci.

## OTEVŘENÉ / TODO (pořadí)
1. [x] První bezpečnostní kopie (interní) — HOTOVO 29.8.
2. [x] Postavit skripty + plisty — HOTOVO 29.8. (bash -n OK), NEaktivováno.
3. [x] ROZHODNUTO 29.8.: nové schéma NAHRAZUJE starý vm-backup (sekvence viz DUPLICITA výše).
4. [ ] **Pondělí**: připojit Thunderbolt 4 TB → ověřit mount path (`DEST_BASE`/`SRC_BASE` v skriptech) → deploy skriptů na host → `launchctl load -w` → ostrý test (`zaloha_vm_package.sh cold`).
5. [ ] Po 1. úspěšném běhu: `launchctl unload` starého vm-backup → `konsolidace_snapshotu.sh --apply` (VM v klidu).
6. [ ] Ověřit NAS volné místo (`/volume1/VM_packages`) + klidné okno 04:00.
7. [ ] Po ~2 týdnech měření: snížit VM RAM 52→~36 GB (`prlctl set macOS --memsize`, VM vypnutá).
8. [ ] Vědomý Tools restart (mimo okno, po hotové kopii) — dokončí Tools update.
9. [ ] Commit `VM_package_zaloha/` do gitu (po doběhnutí subagenta, aby nekolidoval).
