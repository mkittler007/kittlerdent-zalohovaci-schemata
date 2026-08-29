#!/bin/bash
# Běží na HOSTU (.24). Nočně přepošle logy vytíženosti na Synology .120.
#   host logy       -> /volume1/Mac_mini_Pro_Logy/host/
#   VM logy (staging)-> /volume1/Mac_mini_Pro_Logy/vm/
# Používá stejný NAS klíč jako vm-backup-synology.sh (admin@Synology).
set -u
RSYNC="/opt/homebrew/bin/rsync"; [ -x "$RSYNC" ] || RSYNC="rsync"
SYNO_USER="admin"
SYNO_HOST="192.168.100.120"
SYNO_KEY="$HOME/.ssh/synology_backup"
BASE="/volume1/Mac_mini_Pro_Logy"
SSH_OPTS="-i $SYNO_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15"
LOG="$HOME/monitoring/cpuram/sync.log"
ts=$(date +%FT%T%z)

# vzdálený rsync: Entware když je, jinak DSM
REMOTE_RSYNC=$(ssh $SSH_OPTS "$SYNO_USER@$SYNO_HOST" 'command -v /opt/bin/rsync >/dev/null && echo /opt/bin/rsync || echo /usr/bin/rsync' 2>/dev/null)
REMOTE_RSYNC=${REMOTE_RSYNC:-/usr/bin/rsync}

ssh $SSH_OPTS "$SYNO_USER@$SYNO_HOST" "mkdir -p '$BASE/host' '$BASE/vm'" 2>>"$LOG"

push() {  # $1 = lokální dir, $2 = vzdálený podadresář, $3 = include vzor
  local src="$1" sub="$2" inc="$3"
  [ -d "$src" ] || return 0
  "$RSYNC" -a --timeout=300 --rsync-path="$REMOTE_RSYNC" \
    -e "ssh $SSH_OPTS" \
    --include="$inc" --exclude='*' \
    "$src/" "$SYNO_USER@$SYNO_HOST:$BASE/$sub/" 2>>"$LOG"
}

ok=1
push "$HOME/monitoring/cpuram"        host 'host_*.csv'      || ok=0
push "$HOME/monitoring/cpuram"        host 'peaks_host_*.log'|| ok=0
push "$HOME/monitoring/cpuram_from_vm" vm  'vm_*.csv'         || ok=0
push "$HOME/monitoring/cpuram_from_vm" vm  'peaks_vm_*.log'   || ok=0

[ "$ok" = 1 ] && echo "$ts host+vm -> NAS OK" >> "$LOG" || echo "$ts host+vm -> NAS CHYBA" >> "$LOG"
