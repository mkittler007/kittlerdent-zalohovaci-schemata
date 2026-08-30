# Plán obnovy — Parallels VM „Windows 11 (ordinace)" na zeleném iMacu

> Poslední ostrá záloha ověřena: **30. 8. 2026 00:32**, downtime 9 s, velikost 71 GB.

---

## 1. Co se zálohuje

| Položka | Hodnota |
|---|---|
| **Stroj** | „Imac zelený" (iMac21,1, Apple M1, macOS 26.6.2) |
| **IP** | `192.168.100.170` (WiFi, DHCP — může se změnit, ověřit `arp -a`) |
| **Účet** | `martinkittler` |
| **VM** | Parallels „Windows 11 (1)", UUID `{5ed2e4d7-210a-4f9c-b955-274bad61ee9f}` |
| **Zdroj VM** | `~/Parallels/Windows 11_Imac_zelený 2.pvm` |

## 2. Kam se zálohuje (umístění)

Vše na **témže interním SSD** zeleného iMacu, ve složce:

```
/Users/martinkittler/Parallels_Backup_ordinace/
├── backup/
│   └── Windows 11_Imac_zelený 2.pvm   ← ZÁLOHA (jediná, retence 1)
├── parallels_cold_backup.sh           ← zálohovací skript
├── backup.log                          ← průběžný log všech běhů
├── STATUS.txt                          ← výsledek posledního běhu (OK/FAIL)
├── launchd.out.log / launchd.err.log   ← výstup plánovače
└── .lock                               ← zámek proti souběhu (dočasný)
```

## 3. Jak to funguje (cold, minimální downtime)

Denně **ve 12:00** (LaunchAgent `com.kittler.parallels-cold-backup`):

1. **suspend** běžící VM (konzistentní stav)
2. **APFS clonefile** (`cp -c`) celého `.pvm` balíku → `.staging.pvm`
   — copy-on-write, metadatový klon, trvá vteřiny, nekopíruje reálná data
3. **resume** VM — **downtime končí (~9 s)**
4. **swap** — nová záloha nahradí starou (retence 1), stará se bezpečně zahodí

Pokud iMac ve 12:00 spí, launchd úlohu dožene po probuzení.

## 4. Retence

**1** (zrcadlo). Vždy existuje právě **jedna** záloha = poslední polední stav.
Novým během se přepíše. Historie starších verzí se nedrží (dle zadání).

## 5. Dvě vrstvy ochrany

| Vrstva | Kde | Kdy | Retence | Chrání proti |
|---|---|---|---|---|
| **1) Lokální cold** | interní SSD iMacu `~/Parallels_Backup_ordinace/backup/` | denně 12:00 | 1 | rozbití/smazání VM |
| **2) NAS .120** | `/volume1/HDD IMac ordinace/Parallels_VM_zaloha/` | 1× měsíčně (1. neděle 13:00) | 2 (`vm_current`+`vm_prev`) | + selhání disku / krádež / požár |

Obě vrstvy nesou i **stav RAM** (`.mem`), takže obnova = **probuzení běžícího systému**, ne studený start.

⚠️ Lokální vrstva sama je na **stejném SSD** jako originál (rychlost) → proti selhání disku ji kryje až **NAS vrstva**. Viz [[reference_nas_zalohy]], [[project_imac_zeleny_zaloha]].

## 6. POSTUP OBNOVY

### A) Rychlé ověření zálohy (bez zásahu do ostré VM)
Na zeleném iMacu ve Finderu otevři:
`~/Parallels_Backup_ordinace/backup/Windows 11_Imac_zelený 2.pvm/config.pvs`
→ Parallels nabídne otevřít jako **kopii** („Copy"), spustí se izolovaně. Po ověření zavřít a v Parallels odregistrovat, ať neběží dvě VM naráz.

### B) Plná obnova (originál je rozbitý/smazaný)
```bash
# 1) na zeleném iMacu, přihlášen jako martinkittler
PRL=/usr/local/bin/prlctl

# 2) zastav a odregistruj rozbitou VM (pokud existuje)
$PRL stop   "{5ed2e4d7-210a-4f9c-b955-274bad61ee9f}" --kill 2>/dev/null
$PRL unregister "{5ed2e4d7-210a-4f9c-b955-274bad61ee9f}" 2>/dev/null

# 3) vrať zálohu na místo originálu
SRC="$HOME/Parallels_Backup_ordinace/backup/Windows 11_Imac_zelený 2.pvm"
DST="$HOME/Parallels/Windows 11_Imac_zelený 2.pvm"
rm -rf "$DST"
cp -Rp "$SRC" "$DST"        # nebo cp -Rpc pro rychlý APFS klon

# 4) zaregistruj a spusť
$PRL register "$DST"
$PRL start "Windows 11 (1)"
```
Alternativa: v kroku 3 nechat zálohu na místě a spustit ji rovnou z `~/Parallels_Backup_ordinace/backup/...` (`prlctl register` na tu cestu).

### C) Obnova na dálku (z VM .82 / hosta .24)
```bash
ssh -i ~/.ssh/id_ed25519_macmini martinkittler@192.168.100.170
# dál dle bodu B
```

### D) Obnova z NAS (když padl SSD iMacu)
Na NASu `.120` je poslední + předposlední verze:
`/volume1/HDD IMac ordinace/Parallels_VM_zaloha/vm_current` (nejnovější) a `…/vm_prev`.
```bash
# z libovolného Macu s klíčem k NASu, na cílový (opravený) iMac:
rsync -a -e ssh \
  admin@192.168.100.120:"/volume1/HDD IMac ordinace/Parallels_VM_zaloha/vm_current/Windows 11_Imac_zelený 2.pvm/" \
  ~/Parallels/"Windows 11_Imac_zelený 2.pvm/"
prlctl register ~/Parallels/"Windows 11_Imac_zelený 2.pvm"
prlctl start "Windows 11 (1)"
```

## 7. Provoz a údržba

| Akce | Příkaz (na zeleném iMacu) |
|---|---|
| Ruční záloha teď | `~/Parallels_Backup_ordinace/parallels_cold_backup.sh` |
| Jen kontrola (bez suspendu) | `… parallels_cold_backup.sh --selftest` |
| Výsledek posledního běhu | `cat ~/Parallels_Backup_ordinace/STATUS.txt` |
| Log | `tail -f ~/Parallels_Backup_ordinace/backup.log` |
| Stav plánovače | `launchctl print gui/$(id -u)/com.kittler.parallels-cold-backup` |
| Přenačíst plánovač | viz `deploy.sh` |

## 8. Provedená příprava (30. 8. 2026)

- Vypnut **SmartGuard** (automatické snapshoty) — `prlctl set … --smart-guard off`.
- Smazány **všechny snapshoty** (Snapshot 1 z 30.4. + SmartGuard z 28.8.) → VM 133 GB → 66 GB.
- Smazána **stará neregistrovaná kopie** `Windows 11_Imac_zelený.pvm` (173 GB, z r. 2022).
- Volné místo: 135 GB → **375 GB**.
- Nasazen skript + LaunchAgent, ověřena první ostrá záloha.

Souvisí: [[reference_imac_zeleny]], [[reference_nas_zalohy]].
