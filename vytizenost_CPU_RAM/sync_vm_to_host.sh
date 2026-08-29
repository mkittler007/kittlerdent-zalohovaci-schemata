#!/bin/bash
# Běží ve VM (.82). Odešle lokální logy vytíženosti na host (.24) do staging složky,
# odkud je host nočně přepošle na NAS. Používá existující VM->host klíč.
set -u
SRC="$HOME/monitoring/cpuram/"
HOST_USER="martinkittler"
HOST="192.168.100.24"
DST="$HOST_USER@$HOST:/Users/martinkittler/monitoring/cpuram_from_vm/"
KEY="$HOME/.ssh/id_ed25519_macmini"
LOG="$HOME/monitoring/cpuram/sync.log"
ts=$(date +%FT%T%z)

ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
    "$HOST_USER@$HOST" 'mkdir -p /Users/martinkittler/monitoring/cpuram_from_vm' 2>>"$LOG"

if rsync -a --timeout=120 \
    -e "ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15" \
    --include='vm_*.csv' --include='peaks_vm_*.log' --exclude='*' \
    "$SRC" "$DST" 2>>"$LOG"; then
  echo "$ts VM->host OK" >> "$LOG"
else
  echo "$ts VM->host CHYBA (rc=$?)" >> "$LOG"
fi
