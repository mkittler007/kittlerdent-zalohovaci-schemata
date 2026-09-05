#!/bin/bash
# TM na WD ("My Book") -> 1x denně ve 02:00.
# Vypne hodinové automatické zálohy a naplánuje jeden běh denně (klinika zavřená, LAN volná).
# Spustit NA HOSTU (Mac Mini .24) jako root:  sudo bash ~/bin/setup_tm_1x_denne.sh
set -e

echo "[1/3] Vypínám hodinové automatické Time Machine zálohy..."
tmutil disableautobackup

echo "[2/3] Instaluji denní spouštěč (02:00)..."
cat > /Library/LaunchDaemons/com.kittler.tm-wd-daily.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.kittler.tm-wd-daily</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/tmutil</string><string>startbackup</string><string>--auto</string><string>--block</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>2</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>/private/tmp/tm_wd_daily.out</string>
  <key>StandardErrorPath</key><string>/private/tmp/tm_wd_daily.err</string>
</dict></plist>
PLIST
chown root:wheel /Library/LaunchDaemons/com.kittler.tm-wd-daily.plist
chmod 644 /Library/LaunchDaemons/com.kittler.tm-wd-daily.plist

echo "[3/3] Nahrávám LaunchDaemon..."
launchctl bootout system/com.kittler.tm-wd-daily 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.kittler.tm-wd-daily.plist

echo "HOTOVO: Time Machine na WD nyní jede 1x denně ve 02:00 (hodinové auto vypnuto)."
echo "Kontrola: tmutil status ; sudo defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup"
