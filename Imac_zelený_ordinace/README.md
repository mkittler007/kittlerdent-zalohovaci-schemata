# Imac_zelený_ordinace — cold záloha Parallels VM (Windows/ordinace)

Denní **cold** záloha Parallels VM „Windows 11 (1)" na zeleném iMacu
(`192.168.100.170`, účet `martinkittler`), s minimálním downtime přes APFS clonefile.

- **Metoda:** suspend → APFS klon → resume (~9 s downtime) → swap, **retence 1**
- **Kdy:** denně 12:00 (LaunchAgent `com.kittler.parallels-cold-backup`)
- **Kam:** `/Users/martinkittler/Parallels_Backup_ordinace/backup/` (na témže SSD)
- **Automatické snapshoty (SmartGuard):** vypnuté

📄 **Detailní popis + postup obnovy → [PLAN_OBNOVY.md](PLAN_OBNOVY.md)**

## Soubory v projektu
| Soubor | Popis |
|---|---|
| `parallels_cold_backup.sh` | zálohovací skript (zdroj pravdy; deployuje se na iMac) |
| `com.kittler.parallels-cold-backup.plist` | definice plánovače (LaunchAgent, 12:00) |
| `deploy.sh` | nahraje skript+plist na zelený iMac a (pře)načte plánovač |
| `PLAN_OBNOVY.md` | plán obnovy, umístění, retence, omezení |

## Nasazení / aktualizace
Z VM (`192.168.100.82`) nebo hosta:
```bash
./deploy.sh
```

## ⚠️ Omezení
Záloha je na **stejném SSD** jako originál → chrání proti rozbití/smazání VM,
**ne** proti selhání disku. Pro plnou ochranu doplnit kopii na NAS/externí disk.
