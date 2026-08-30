#!/bin/bash
# Watchdog zálohy Claude_Project na Synology .120.
# Záloha (backup_claude_project.sh, LaunchAgent cz.kittlerdent.backup_claude_project)
# běží 08:00 a 20:00. Když poslední ÚSPĚŠNÁ záloha chybí déle než práh:
# PRAVIDLO 2 ZÁSAHY (feedback_notifikace_2_strikes): 1. selhání = ŽÁDNÁ notifikace,
# jen retry zálohy (kickstart agenta) + diagnóza; teprve 2. selhání za sebou → Telegram
# (s diagnózou v textu). Počítadlo se nuluje při každé úspěšné záloze.
# Telegram jde přes telegram_send.sh = respektuje časové okno (mimo okno se alert odloží).
# Throttle: max 1 alert / 6 h. Stampy se mažou při OK.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

LOG_BACKUP="$HOME/Library/Logs/backup_claude_project.log"
LOG="/tmp/watchdog_backup_claude.log"
STAMP="/tmp/watchdog_backup_claude_alert.stamp"
STRIKES_F="/tmp/watchdog_backup_claude_strikes"   # počítadlo selhání za sebou
SEND="$HOME/bin/telegram_send.sh"
BACKUP_AGENT="cz.kittlerdent.backup_claude_project"
MAX_AGE_H=13     # max mezera mezi zálohami (12 h) + 1 h buffer

log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

# Diagnóza NAS .120 + retry zálohy (spouští se při 1. zásahu). Vrací text diagnózy na stdout.
diagnose_and_retry(){
  local diag="NAS .120: "
  if ping -c1 -t3 192.168.100.120 >/dev/null 2>&1; then
    diag+="ping OK"
    if ssh -o ConnectTimeout=6 -o BatchMode=yes -i "$HOME/.ssh/synology_backup" admin@192.168.100.120 'test -w /volume1/Claude_Project' >/dev/null 2>&1; then
      diag+=", SSH+zápis OK"
    else
      diag+=", SSH/zápis SELHAL"
    fi
  else
    diag+="ping SELHAL (NAS nedostupný)"
  fi
  # retry: znovu spustit zálohovací agent
  if launchctl kickstart -k "gui/$(id -u)/$BACKUP_AGENT" >/dev/null 2>&1; then
    diag+="; retry zálohy spuštěn"
  else
    diag+="; retry zálohy SELHAL (kickstart)"
  fi
  echo "$diag"
}

# poslední řádek "Záloha OK" → timestamp (formát logu: 2026-08-11 08:37:30 ...)
LAST_OK=$(grep "Záloha OK" "$LOG_BACKUP" 2>/dev/null | tail -1 | awk '{print $1" "$2}')
if [ -z "$LAST_OK" ]; then
  AGE_H=999; LAST_TXT="nikdy (žádný záznam)"
else
  LAST_TS=$(date -j -f "%Y-%m-%d %H:%M:%S" "$LAST_OK" +%s 2>/dev/null)
  if [ -z "$LAST_TS" ]; then AGE_H=999; else AGE_H=$(( ( $(date +%s) - LAST_TS ) / 3600 )); fi
  LAST_TXT="$LAST_OK"
fi

if [ "$AGE_H" -gt "$MAX_AGE_H" ]; then
  # zvýšit počítadlo selhání za sebou
  STRIKES=$(cat "$STRIKES_F" 2>/dev/null || echo 0)
  case "$STRIKES" in ''|*[!0-9]*) STRIKES=0;; esac
  STRIKES=$((STRIKES+1))
  echo "$STRIKES" > "$STRIKES_F"

  if [ "$STRIKES" -lt 2 ]; then
    # 1. ZÁSAH: bez notifikace — jen retry zálohy + diagnóza, uložit diagnózu pro případný 2. zásah
    DIAG=$(diagnose_and_retry)
    echo "$DIAG" > "${STRIKES_F}.diag"
    log "1. zásah (age ${AGE_H}h, poslední OK: $LAST_TXT) — BEZ notifikace; $DIAG"
    exit 0
  fi

  # 2.+ ZÁSAH: notifikace (s throttle 6 h)
  if [ -f "$STAMP" ]; then
    A=$(( $(date +%s) - $(stat -f %m "$STAMP" 2>/dev/null || echo 0) ))
    [ "$A" -lt 21600 ] && { log "ALERT throttled (${A}s < 21600s, strike=$STRIKES)"; exit 0; }
  fi
  DIAG=$(cat "${STRIKES_F}.diag" 2>/dev/null); [ -z "$DIAG" ] && DIAG=$(diagnose_and_retry)
  log "ALERT (2. zásah, strike=$STRIKES): poslední úspěšná záloha před ${AGE_H} h (poslední OK: $LAST_TXT); $DIAG"
  "$SEND" "⚠️ <b>Záloha Claude_Project na Synology neproběhla ${AGE_H} h (2. selhání za sebou).</b>
Poslední úspěšná: ${LAST_TXT}.
Diagnóza: ${DIAG}.
Zkontroluj LaunchAgent <code>cz.kittlerdent.backup_claude_project</code> a NAS .120."
  RC=$?
  if [ "$RC" -eq 0 ]; then
    touch "$STAMP"; log "alert odeslán"
  else
    log "alert neodeslán (rc=$RC — mimo okno nebo chyba); zopakuje se v okně"
  fi
else
  log "OK: poslední záloha před ${AGE_H} h ($LAST_TXT)"
  rm -f "$STAMP" "$STRIKES_F" "${STRIKES_F}.diag" 2>/dev/null
fi
