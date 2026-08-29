#!/bin/bash
# ============================================================================
# ims_pull.sh — záloha No Problem (IMS) databáze ze Synology .120 na Mac Mini
# + watchdog na IMS i IS sync.
#
# Logika (dle zadání Martina): NEPANIKAŘIT kvůli chvilkovému zpoždění.
#   1) běh: zkus stáhnout (vč. okamžitého retry) → diagnostika → pokus o opravu
#   2) 1. neúspěšný běh = TICHÝ strike (jen log), žádný Telegram
#   3) alarm na Telegram AŽ když selže i DRUHÝ běh za sebou (strike 2)
#   4) po úspěchu se počítadlo resetuje; alarm se pošle jen jednou za výpadek
# U skladu drží jen JEDNU (nejnovější) verzi lokálně.
# Běží 2× denně (~08:00 a 16:00) přes LaunchAgent com.kittler.ims_pull.
# ============================================================================
set -uo pipefail

# --- konfig ---
KEY="$HOME/.ssh/synology_backup"
SYNO="admin@192.168.100.120"
SRC_DIR="/volume1/npgroup_backup/database"
DST="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Claude_Project/Sklad/database"
IS_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Claude_Project/IS_KittlerDent/databaze"
SSH_OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15"
RSYNC="/opt/homebrew/bin/rsync"
LOG="$HOME/Library/Logs/ims_pull.log"
STATE_DIR="$HOME/Library/Logs"
IS_MAX_AGE_H=36        # IS dump starší než tolik hodin = podezřelé

log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

# --- Telegram (stejně jako ostatní watchdogy: .env + curl) ---
TG_TOKEN=""; TG_CHAT=""
for e in "$HOME/.vm-backup-telegram.env" "$HOME/.claude/channels/telegram/.env" \
         "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Claude_Project/Retence VM macOS/.telegram.env"; do
  [ -f "$e" ] || continue
  TG_TOKEN=$(awk -F= '/^TELEGRAM_BOT_TOKEN=/{print $2}' "$e" 2>/dev/null | tr -d ' "')
  TG_CHAT=$(awk  -F= '/^TELEGRAM_CHAT_ID=/{print $2}'   "$e" 2>/dev/null | tr -d ' "')
  [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] && break
done
tg(){ [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] || return 0
  curl -s -m 15 "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TG_CHAT" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$1" >/dev/null; }

# strike counter: return 1 = poslat TEĎ alarm (přesně 2. selhání), jinak 0
strike(){
  local name="$1" ok="$2" f="$STATE_DIR/ims_pull.$1.strike" n
  n=$(cat "$f" 2>/dev/null || echo 0)
  if [ "$ok" = "1" ]; then
    [ "$n" != "0" ] && log "$name: OK, reset (bylo $n selhání)"
    echo 0 > "$f"; return 0
  fi
  n=$((n+1)); echo "$n" > "$f"
  if [ "$n" -ge 2 ]; then log "$name: strike $n → ALARM"; return 1; fi
  log "$name: strike $n (tichý, zkusím znovu příští běh)"; return 0
}

mkdir -p "$DST" "$STATE_DIR"
log "=== běh start ==="
ALARM=""

# ============================================================================
# 1) IMS: stáhni jen NEJNOVĚJŠÍ denní 05:00 snímek, drž jen jednu verzi
# ============================================================================
ims_ok=1
newest_src=""
get_newest(){ newest_src=$(ssh $SSH_OPTS "$SYNO" "ls '$SRC_DIR' 2>/dev/null | grep _05-00-01 | sort | tail -1"); }
get_newest
if [ -z "$newest_src" ]; then
  log "IMS: zdroj nedostupný/prázdný, retry za 20s…"; sleep 20; get_newest
fi

if [ -z "$newest_src" ]; then
  ims_ok=0
  if ssh $SSH_OPTS "$SYNO" true 2>>"$LOG"; then
    ALARM+="• IMS: SSH na .120 OK, ale zdrojová složka je prázdná/nedostupná. "
  else
    ALARM+="• IMS: nejde SSH na Synology .120 (síť/klíč). "
  fi
else
  if [ ! -f "$DST/$newest_src" ]; then
    pull_one(){ "$RSYNC" -t --rsync-path=/usr/bin/rsync -e "ssh $SSH_OPTS" \
        "$SYNO:$SRC_DIR/$newest_src" "$DST/" 2>>"$LOG"; }
    if ! pull_one; then
      log "IMS: rsync selhal, retry za 15s…"; sleep 15
      pull_one || { ims_ok=0; ALARM+="• IMS: rsync přenos ze Synology selhal (2×). "; }
    fi
    [ -f "$DST/$newest_src" ] && log "IMS: staženo $newest_src"
  else
    log "IMS: už mám nejnovější $newest_src"
  fi

  # drž jen jednu verzi — smaž ostatní denní snímky
  if [ -f "$DST/$newest_src" ]; then
    ls "$DST" 2>/dev/null | grep _05-00-01 | grep -v -x "$newest_src" | while IFS= read -r old; do
      rm -f "$DST/$old" && log "IMS: smazána stará verze $old"
    done
  fi

  # info o čerstvosti (bez postihu — když zdroj dnešní 05:00=07:00 SELČ ještě nevyrobil)
  d=$(echo "$newest_src" | sed -E 's/ims_backup_([0-9-]+)_.*/\1/'); today=$(date +%F)
  if [[ "$d" < "$today" ]]; then
    log "IMS: nejnovější na zdroji je $d (dnešní 05:00 zatím není) — bez postihu"
  else
    log "IMS: čerstvé, $newest_src"
  fi
fi

# ============================================================================
# 2) IS: kontrola čerstvosti dumpu (jen hlídání, bez vlastního tahání)
# ============================================================================
is_ok=1
newest_is=$(find "$IS_DIR" -name 'is.2kdent*gz' -type f 2>/dev/null -exec stat -f '%m %N' {} \; | sort -nr | head -1)
if [ -z "$newest_is" ]; then
  is_ok=0; ALARM+="• IS: nenalezen žádný dump v $IS_DIR. "
else
  mt=${newest_is%% *}
  age_h=$(( ( $(date +%s) - mt ) / 3600 ))
  if [ "$age_h" -gt "$IS_MAX_AGE_H" ]; then
    is_ok=0; ALARM+="• IS: nejnovější dump je starý ${age_h} h (limit ${IS_MAX_AGE_H} h). "
  else
    log "IS: OK, nejnovější dump starý ${age_h} h"
  fi
fi

# ============================================================================
# 3) Vyhodnocení strike + případný jediný alarm
# ============================================================================
send=0
strike "ims" "$ims_ok" || send=1
strike "is"  "$is_ok"  || send=1

if [ "$send" = "1" ] && [ -n "$ALARM" ]; then
  tg "🔴 <b>Záloha KittlerDent — 2× po sobě neúspěch</b>
$ALARM
(1. výpadek byl tichý + retry; tohle je druhý neúspěšný běh.)
Host Mac Mini · $(date '+%F %T')"
  log "ALARM odeslán: $ALARM"
elif [ -n "$ALARM" ]; then
  log "problém (1. strike, tichý): $ALARM"
else
  log "vše OK"
fi
log "=== běh konec ==="
