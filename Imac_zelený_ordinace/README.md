# Imac_zelený_ordinace — záloha Parallels VM (Windows/ordinace)

Záloha Parallels VM „Windows 11 (1)" na zeleném iMacu (`192.168.100.170`, účet `martinkittler`),
ve **dvou vrstvách** — obě se stavem RAM (obnova = probuzení běžícího systému).

| Vrstva | Metoda | Kdy | Kam | Retence |
|---|---|---|---|---|
| **1) Lokální cold** | suspend → APFS klon → resume (~9 s downtime) → swap | denně **12:00** | `~/Parallels_Backup_ordinace/backup/` (interní SSD) | 1 |
| **2) NAS .120** | push (openrsync) + rotace hardlinky | **1× měsíčně** (1. neděle 13:00) | `/volume1/HDD IMac ordinace/Parallels_VM_zaloha/` | 2 |

- Automatické snapshoty (SmartGuard) **vypnuté**.
- NAS kopie jde z hotové lokální zálohy → **žádný další prostoj VM**.
- 1 verze ≈ 71 GB (vč. 2,3 GB RAM); 2 verze na NASu ≈ ~142 GB.

📄 **Detailní popis + postup obnovy → [PLAN_OBNOVY.md](PLAN_OBNOVY.md)**

## Soubory v projektu
| Soubor | Popis |
|---|---|
| `parallels_cold_backup.sh` | denní lokální cold záloha (zdroj pravdy) |
| `com.kittler.parallels-cold-backup.plist` | LaunchAgent lokální zálohy (12:00) |
| `nas_monthly_sync.sh` | měsíční kopie na NAS (retence 2); `--now` = ruční běh |
| `com.kittler.parallels-nas-monthly.plist` | LaunchAgent NAS (neděle 13:00, guard 1. neděle) |
| `deploy.sh` | nahraje oba skripty+plisty na iMac a (pře)načte plánovače |
| `PLAN_OBNOVY.md` | plán obnovy, umístění, retence, obě vrstvy |

## Nasazení / aktualizace
Z VM (`192.168.100.82`) nebo hosta:
```bash
./deploy.sh
```

## Přístupy
- iMac: `ssh -i ~/.ssh/id_ed25519_macmini martinkittler@192.168.100.170` (klíč jen ve VM).
- iMac → NAS: klíč `~/.ssh/synology_backup` na iMacu, `admin@192.168.100.120`.
