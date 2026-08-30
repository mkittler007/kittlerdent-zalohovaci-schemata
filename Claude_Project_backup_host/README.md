# Claude_Project záloha na Synology .120 (z HOSTA .24)

Záloha iCloud složky `Claude_Project` na Synology NAS `/volume1/Claude_Project/`.

## Kde běží
Na **hostu Mac Mini (.24)**, ne ve VM. Přesunuto z VM **30.8.2026**, protože čtení iCloudu
přes VirtioFS z VM bylo neúnosně pomalé (sken 51k souborů 3 h+ místo 1 s) a rsync padal na
měnících se souborech (`file truncated while reading` → Broken pipe, exit 255). Na hostu jsou
soubory nativní.

## Soubory
- `backup_claude_project.sh` — rsync GNU 3.4.4 (`/opt/homebrew/bin/rsync`, NE Apple openrsync)
  ze zdroje `~/Library/Mobile Documents/com~apple~CloudDocs/Claude_Project/` na
  `admin@192.168.100.120:/volume1/Claude_Project/`, klíč `~/.ssh/synology_backup`.
  **Retry 3× + `--partial` + `--timeout=600`**, kód 0 i 23 = OK.
- `watchdog_backup_claude_project.sh` — **pravidlo 2 zásahy**: 1. selhání = ticho + retry
  (`launchctl kickstart` backup agenta) + diagnóza NASu; teprve 2. za sebou → Telegram
  přes `~/bin/telegram_send.sh`. Počítadlo `/tmp/watchdog_backup_claude_strikes`, reset při OK.
- `cz.kittlerdent.backup_claude_project.plist` — LaunchAgent, 08:00 a 20:00.
- `cz.kittlerdent.backup_claude_project.watchdog.plist` — LaunchAgent, 09:30 / 13:30 / 19:30.

## Pozn.
- Ostrý přenos při velkém delta trvá ~2,5 h kvůli iCloud materializaci dataless souborů
  (čtení obsahu je stahuje). Po materializaci jsou lokální → příští delta běhy = minuty.
- VM strana vypnuta (plisty `…plist.disabled_moved_to_host_2026-08-30` + bootout).
- Zdroj pravdy = host `~/bin`; tenhle mirror se synchronizuje ručně.
