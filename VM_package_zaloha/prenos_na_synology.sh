#!/bin/bash
# Přenos posledního nočního balíku (s RAM) z Thunderboltu na Synology (.120) — off-host.
# BĚŽÍ NA HOSTU (.24), okno ~04:00. Retence 2 na NAS. Viz PLAN.md.
#
# POLITIKA (MK 29.8.2026): off-host na NAS jde POUZE noční RAM balík (macOS_ram_*).
#   Intraday cold balíky (macOS_cold_*) zůstávají JEN lokálně na Thunderboltu — na NAS se NEposílají
#   (plný noční přenos je kvůli kontenci SSD hosta pomalý, viz PLAN/paměť). Proto glob níže = jen _ram_.
set -u
SRC_BASE="/Volumes/Thunderbolt/VM_packages"          # uprav dle skutečného mountu Thunderboltu
SYNO_USER="admin"
SYNO_HOST="192.168.100.120"
SYNO_KEY="$HOME/.ssh/synology_backup"
NAS_BASE="/volume1/VM_packages"                      # dedikovaná složka (NE monitoring logy)
RSYNC="/opt/homebrew/bin/rsync"; [ -x "$RSYNC" ] || RSYNC="rsync"
SSH_OPTS="-i $SYNO_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=15"
KEEP=2
LOG="/Users/martinkittler/VM_Safety/prenos_na_synology.log"
ts() { date +%FT%T%z; }
log() { echo "$(ts) $*" >> "$LOG"; }

[ -d "$SRC_BASE" ] || { log "Thunderbolt $SRC_BASE není připojen — přeskočeno."; exit 2; }

# nejnovější noční (ram) balík
PKG=$(ls -1dt "$SRC_BASE/macOS_ram_"*.macvm 2>/dev/null | head -1)
[ -n "$PKG" ] || { log "Žádný macOS_ram_*.macvm na Thunderboltu — nic k přenosu."; exit 0; }
NAME=$(basename "$PKG")

# vzdálený rsync (Entware, když je) + cílová složka
REMOTE_RSYNC=$(ssh $SSH_OPTS "$SYNO_USER@$SYNO_HOST" 'command -v /opt/bin/rsync >/dev/null && echo /opt/bin/rsync || echo /usr/bin/rsync' 2>/dev/null)
REMOTE_RSYNC=${REMOTE_RSYNC:-/usr/bin/rsync}
ssh $SSH_OPTS "$SYNO_USER@$SYNO_HOST" "mkdir -p '$NAS_BASE'" 2>>"$LOG"

log "přenos $NAME → $SYNO_HOST:$NAS_BASE/ (rsync $REMOTE_RSYNC)…"
if "$RSYNC" -a --partial --inplace --timeout=1200 --rsync-path="$REMOTE_RSYNC" \
     -e "ssh $SSH_OPTS" "$PKG/" "$SYNO_USER@$SYNO_HOST:$NAS_BASE/$NAME/" 2>>"$LOG"; then
  log "OK přeneseno: $NAME"
else
  log "CHYBA přenosu $NAME (rc=$?) — ponecháno k dalšímu pokusu."
  exit 1
fi

# retence: nech KEEP nejnovějších macOS_ram_* na NAS, starší smaž
ssh $SSH_OPTS "$SYNO_USER@$SYNO_HOST" "
  ls -1dt '$NAS_BASE'/macOS_ram_*.macvm 2>/dev/null | tail -n +\$(( $KEEP + 1 )) | while read -r d; do
    rm -rf \"\$d\" && echo \"rotace: smazan \$d\"
  done
" 2>>"$LOG" | while read -r line; do log "$line"; done
log "hotovo (retence $KEEP na NAS)."
