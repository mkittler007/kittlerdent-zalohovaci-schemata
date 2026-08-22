#!/bin/bash
# vm-backup-run.sh — RUČNÍ spuštění zálohy VM s živým logem; po dokončení ZAVŘE okno Terminalu.
# Noční běh jede přes LaunchAgent (com.kittler.vm-backup) bez okna — tenhle wrapper je jen na ruční testy.
# Předpoklad pro tiché zavření: Terminal → Nastavení → Profily → Shell → "Zeptat se před zavřením: Nikdy".

LOG="$HOME/Library/Logs/vm-backup-synology.log"

: > "$LOG"
echo "Spouštím zálohu VM na Synology… (okno se po dokončení samo zavře)"
echo

# živý log na pozadí
tail -f "$LOG" &
TAILPID=$!

# vlastní záloha na popředí — čeká se na dokončení
/usr/local/bin/vm-backup-synology.sh
RC=$?

# ukonči tail a zavři okno
kill "$TAILPID" 2>/dev/null
echo
if [ "$RC" -eq 0 ]; then echo "Hotovo. Zavírám okno…"; else echo "Skončilo s chybou ($RC). Zavírám okno…"; fi
sleep 2
osascript -e 'tell application "Terminal" to close front window' >/dev/null 2>&1
