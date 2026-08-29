#!/bin/bash
# Přenos nejnovějšího nočního (ram) balíku z LOCAL_BASE na Synology (.120) — off-host.
# BĚŽÍ NA HOSTU (.24), okno ~23:50 (PO WD). OBDEN (parita sudý den), retence 4 na NAS.
# POLITIKA: off-host jde POUZE noční RAM balík (macOS_ram_*); intraday cold zůstává lokálně.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/config.sh"
LOG="$LOG_DIR/prenos_na_synology.log"; ts(){ date +%FT%T%z; }; log(){ echo "$(ts) $*" >> "$LOG"; }

# OBDEN: agent fajruje denně, tady se pustí jen v SUDÝ den (epoch_day % 2 == 0).
epoch_day=$(( $(date +%s) / 86400 ))
if [ $(( epoch_day % 2 )) -ne 0 ]; then log "Obden gate: dnes lichý den — nekopíruje se."; exit 0; fi

PKG=$(ls -1dt "$LOCAL_BASE/macOS_ram_"*.macvm 2>/dev/null | head -1)
[ -n "$PKG" ] || { log "Žádný macOS_ram_* v $LOCAL_BASE — nic k přenosu."; exit 0; }
NAME=$(basename "$PKG")

# vzdálený rsync (Entware 3.4.1 se sparse, jinak DSM bez -S) + cílová složka
REMOTE_RSYNC=$(ssh $SSH_OPTS "$SYNO_USER@$SYNO_HOST" "command -v /opt/bin/rsync >/dev/null && echo /opt/bin/rsync || echo /usr/bin/rsync" 2>/dev/null)
REMOTE_RSYNC=${REMOTE_RSYNC:-/usr/bin/rsync}
SPARSE=""; echo "$REMOTE_RSYNC" | grep -q /opt/bin/rsync && SPARSE="-S"
ssh $SSH_OPTS "$SYNO_USER@$SYNO_HOST" "mkdir -p \"$NAS_BASE\"" 2>>"$LOG"

log "přenos $NAME → $SYNO_HOST:$NAS_BASE/ (rsync $REMOTE_RSYNC $SPARSE)…"
if "$RSYNC" -rlt $SPARSE --partial --inplace --timeout=1800 --rsync-path="$REMOTE_RSYNC" \
     -e "ssh $SSH_OPTS" "$PKG/" "$SYNO_USER@$SYNO_HOST:$NAS_BASE/$NAME/" 2>>"$LOG"; then
  log "OK přeneseno: $NAME"
else
  log "CHYBA přenosu $NAME (rc=$?) — ponecháno k dalšímu pokusu."; notify "VM záloha Synology: přenos $NAME selhal"; exit 1
fi

# retence 4 na NAS (jen macOS_ram_*)
ssh $SSH_OPTS "$SYNO_USER@$SYNO_HOST" "
  ls -1dt \"$NAS_BASE\"/macOS_ram_*.macvm 2>/dev/null | tail -n +\$(( $RETAIN_SYNO + 1 )) | while read -r d; do
    rm -rf \"\$d\" && echo \"rotace: smazan \$d\"
  done
" 2>>"$LOG" | while read -r line; do log "$line"; done
log "OK hotovo (retence $RETAIN_SYNO na NAS)."
