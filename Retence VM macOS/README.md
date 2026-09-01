# Retence VM macOS

Projekt správy zálohování a diskového místa virtuálního stroje **Parallels macOS** (`~/Parallels/macOS.macvm`), ve kterém běží Claude Code na hostu Mac Mini M4 Pro.

Paměť: [[project_vm_snapshots_parallels]], [[project_vm_disk_binlogy]], [[reference_sitove_zarizeni]].

---

> ## ⚠️ LEGACY / nahrazeno (ověřeno 1.9.2026)
> Zálohovací mechanismus popsaný v tomto dokumentu (`vm-backup-synology.sh` = týdenní přímý APFS klon → NAS, retence 7+1, agent `com.kittler.vm-backup`; a `vm-backup-wd.sh` obden → WD) **už NEBĚŽÍ** — ani jeden z agentů `com.kittler.vm-backup` / `com.kittler.vm-backup-wd` není nahraný v `launchctl`. `vm-backup-wd.sh` navíc cílil na `/Volumes/My Book 1`, který na hostu neexistuje.
>
> **Živá VM záloha dnes = `VM_package_zaloha/`** (agenti `vmpkg.cold/ram/wd/nas`: cold 06/18, ram 23:00, WD 23:10 ret5, Synology obden 23:50 ret4). Sekce 1 (kontext snapshotů, „start-up bezclaude" baseline NEmazat) a poznatky o kompakci **platí dál**; retenční/plánovací část ber jako historickou. Aktuální stav a plán obnovy viz `../PREHLED_ZALOH.md` a `../VM_package_zaloha/OBNOVA.md`.

---

## 1. Kontext

- VM = `~/Parallels/macOS.macvm`, UUID `{cf7a9c8f-39b4-4691-8c25-40ebae6a0768}`, řízeno `prlctl` **na hostu** (ne uvnitř VM).
- Kořenový snapshot **„start-up bezclaude installed" (12.5.2026) = čistý baseline. NIKDY nemazat.** Jeho smazání nevrátí prakticky žádné místo (~0 GB), jen ztratíš baseline.
- Disk hosta se plnil `auto-` suspend snapshoty (bundle až 429 GB). Úklid 2.8.2026: **94 % → 41 %** konsolidací snapshotů + `tmutil deletelocalsnapshots`. Bundle 101 GB.
- Kompakce (`prl_disk_tool`) NEFUNGUJE — disk je „plain".

## 2. Noční záloha na Synology (aktuální řešení)

Přechod ze snapshotů na **noční 1:1 kopii bundlu na Synology** přes lokální APFS klon:

1. `prlctl suspend` VM (pár sekund).
2. `cp -c` **instantní copy-on-write klon** do lokálního `/Users/martinkittler/Parallels_backup_tmp` (MIMO iCloud — jinak by iCloud 100 GB nahrával do cloudu).
3. `prlctl resume` VM → VM hned zpět pro práci.
4. Na pozadí `rsync` klonu na `smb://192.168.100.120/VM macOS M4` jako `macOS_<stamp>.macvm`.
5. Smazat lokální klon (+ ověřit smazání).
6. Retence: **7 nejnovějších + 1 kotevní kopie** (rotace po 10 dnech, fallback ~1–2 týdny).

Do logu se měří: doba klonu, doba přenosu na Synology, výpadek VM, velikosti. NAS má 6 TB volných.

### Soubory
- `vm-backup-synology.sh` — hlavní skript (běží NA HOSTU).
- `com.kittler.vm-backup.plist` — LaunchAgent, spouští v 00:00.
- `vm-backup-watchdog.sh` — ranní hlídač, že noční záloha proběhla.
- `com.kittler.vm-backup-watchdog.plist` — LaunchAgent, 08:00.
- `vm-backup-run.sh` — RUČNÍ spuštění s živým logem, po dokončení samo zavře okno Terminalu (jen pro testy; vyžaduje Terminal → Profily → Shell → „Zeptat se před zavřením: Nikdy").

### Telegram alerty (jen při problému, ne při úspěchu)
Posílá se JEN když: chyba běhu/mountu (🔴), lokální klon se nesmazal (⚠️), na NASu je víc kopií než limit 8 (⚠️), nebo noční záloha vůbec neproběhla (🔴 z watchdogu — poslední `HOTOVO` v logu starší než 28 h). Token+chat_id z `.telegram.env` (stejný bot jako disk_alert.py).

### Instalace (na hostu Mac Mini)
```bash
SRC="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Claude_Project/Retence VM macOS"
sudo cp "$SRC/vm-backup-synology.sh" /usr/local/bin/vm-backup-synology.sh
sudo chmod +x /usr/local/bin/vm-backup-synology.sh
cp "$SRC/com.kittler.vm-backup.plist" ~/Library/LaunchAgents/
# jednou připojit Synology ve Finderu (Cmd+K → smb://192.168.100.120/VM macOS M4 → uložit heslo do Keychain)
```

### Test / aktivace
```bash
# jednorázový test (živě uvidíš časy):
/usr/local/bin/vm-backup-synology.sh & tail -f ~/Library/Logs/vm-backup-synology.log
# noční běh v 00:00:
launchctl load ~/Library/LaunchAgents/com.kittler.vm-backup.plist
```

### Logy
- `~/Library/Logs/vm-backup-synology.log` — hlavní log (časy, velikosti, retence).
- `~/Library/Logs/vm-backup-longterm.txt` — stav kotevní kopie.

## 3. Stav / TODO
- [x] **Ostrý test 2.8.2026:** klon 125 GB / 0 s, výpadek VM 25 s, ditto přenos 59m46s, klon smazán OK. ✅
- [x] Aktivovat LaunchAgent (noční 00:00) + watchdog (08:00). **PLNĚ NASAZENO — oba agenti v `launchctl list`.**
- [ ] Volitelně vypnout starý snapshotovací `com.kittler.vm-snapshot` (přechod ze snapshotů na NAS kopie).
- [ ] Zvážit sparse-aware přenos: na NASu kopie zabrala **279 GB** (ne 125 GB), protože `.hds` je APFS sparse a SMB řídkost neumí. `rsync --no-times --no-perms --no-owner --no-group -S` nebo `tar -S` by přeneslo jen ~125 GB (2× rychleji, ~1,2 TB místo 2,2 TB pro 8 kopií). Na SMB vrtkavé — zatím necháno na `ditto`, funguje.

## 4. Poznatky z ladění (2.8.2026)
- `prlctl` je v `/usr/local/bin/prlctl`.
- `rsync -a` na SMB padá (`aux.bin: utimensat No such file or directory`) → přepnuto na `ditto` (+ fallback `cp -R`).
- Musí existovat `~/Library/Logs` (skript dělá `mkdir -p`), jinak žádný log.
- Synology heslo musí být v Keychain (jednou Finder Cmd+K), jinak mount selže → 🔴 Telegram.
- Stale lock `/tmp/vm-backup-synology.lock` po přerušeném běhu → smazat ručně.
