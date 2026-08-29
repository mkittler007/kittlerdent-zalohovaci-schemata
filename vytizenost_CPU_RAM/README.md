# Vytíženost CPU / RAM — host + VM

Monitoring skutečné vytíženosti paměti a CPU na **hostu (Mac Mini M4 Pro, 64 GB)** a ve
**VM macOS (Parallels)**. Cíl: podklad pro **správné dimenzování RAM VM** (teď přiděleno 52 GB,
hostu zbývá jen 12 GB — předimenzované) a přehled o špičkách včetně **procesů, které je způsobily**.

## Proč z VM, ne z hosta
Na Apple Silicon Parallels je guest RAM mapovaná mimo RSS procesu `prl_macvm_app`, takže z hosta
se skutečná vytíženost VM nezměří. Hlavní zdroj pro dimenzování je proto **monitor uvnitř VM**
(`used = active + wired + compressed`). Host se monitoruje kvůli vlastnímu zdraví
(free %, memory pressure, swap).

## Komponenty
| Skript | Kde běží | Kdy | Co dělá |
|---|---|---|---|
| `monitor_vm.sh` | VM (.82) | á 60 s | guest RAM/CPU → `vm_YYYY-MM-DD.csv`; při špičce viníci → `peaks_vm_*.log` |
| `monitor_host.sh` | host (.24) | á 60 s | host RAM/CPU/pressure → `host_*.csv`; špičky → `peaks_host_*.log` |
| `sync_vm_to_host.sh` | VM | 04:20 | rsync VM logů na host do `~/monitoring/cpuram_from_vm/` |
| `sync_host_to_nas.sh` | host | 04:40 | rsync host+VM logů na Synology `/volume1/Mac_mini_Pro_Logy/{host,vm}` |
| `tydenni_report.py` | host | Po 07:30 | týdenní souhrn + viníci → e-mail `martin@kittler.cz` přes `notify.py --email-to` |
| `vyhodnot.py` | ručně | — | percentily working setu → doporučení RAM |

## LaunchAgenty (`launchd/`)
`com.kittler.moncpuram.vm` · `.host` · `.vmsync` · `.nas` · `.report`

## Prahy špičky (zachytí se procesy)
- **VM:** used ≥ 75 % přidělené RAM, nebo pressure > 1, nebo swap > 100 MB.
- **Host:** volná paměť < 25 %, nebo pressure > 1, nebo swap > 100 MB.
Při špičce se do `peaks_*.log` zapíše top 6 procesů podle RAM a podle CPU.

## Data a retence
- Logy lokálně na každém stroji v `~/monitoring/cpuram/`, **retence 90 dní** (mažou monitory).
- Noční kopie na NAS `/volume1/Mac_mini_Pro_Logy/` (odolnost proti pádu hosta).

## Vyhodnocení / snížení RAM
Po ~2 týdnech: `python3 vyhodnot.py --dny 14` (na hostu; VM logy ve `cpuram_from_vm`).
Doporučí RAM = p99 working setu + 25 %. Změna RAM vyžaduje **vypnutou VM**
(`prlctl set macOS --memsize <MB>`). RAM neřezat, dokud guest prokazatelně swapuje.

## Fáze (korelace se zálohou)
Soubor `~/monitoring/cpuram/phase` (default `run`). Zálohovací skript může před/po zápisu
nastavit `backup` → v datech i reportu se odliší zátěž během zálohy.
