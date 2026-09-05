#!/bin/bash
# Feeder: nejnovější cold balík → Synology (.120) do stálého adresáře pro HyperBackup → C2 (offsite).
# BĚŽÍ NA HOSTU (.24). Delta režim: rsync --inplace --delete do FIXNÍHO jména → týdně jen změněné bloky.
# HyperBackup pak verzuje (retence 2 v C2). Reuse tunel logiky (macOS 26 LNP → loopback SSH + GNU rsync -S).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/config.sh"
NAS_COLD_BASE="/volume1/VM macOS M4/VM_cold_offsite"
DEST_NAME="macOS_cold_current.macvm"   # stálé jméno → delta přenos + čistý zdroj pro HyperBackup
LOG="$LOG_DIR/prenos_cold_na_synology.log"; ts(){ date +%FT%T%z; }; log(){ echo "$(ts) $*" >> "$LOG"; }

PKG=$(ls -1dt "$LOCAL_BASE/macOS_cold_"*.macvm 2>/dev/null | head -1)
[ -n "$PKG" ] || { log "Žádný macOS_cold_* v $LOCAL_BASE — nic k přenosu."; exit 0; }
SRCNAME=$(basename "$PKG")

LPORT=2874
/usr/bin/ssh $SSH_OPTS -o ExitOnForwardFailure=yes -N -L 127.0.0.1:$LPORT:127.0.0.1:22 "$SYNO_USER@$SYNO_HOST" 2>>"$LOG" & TUN_PID=$!
trap "[ -n \"\${TUN_PID:-}\" ] && kill \"\$TUN_PID\" 2>/dev/null" EXIT
for i in $(seq 1 20); do /usr/bin/nc -z 127.0.0.1 "$LPORT" 2>/dev/null && break; sleep 0.5; done
if ! /usr/bin/nc -z 127.0.0.1 "$LPORT" 2>/dev/null; then
  log "CHYBA: SSH tunel na NAS se nezvedl (port $LPORT) — přenos přeskočen."; notify "VM cold→Synology: SSH tunel selhal"; exit 1
fi
TSSH="/usr/bin/ssh -p $LPORT $SSH_OPTS -o NoHostAuthenticationForLocalhost=yes"

REMOTE_RSYNC=$($TSSH "$SYNO_USER@127.0.0.1" "command -v /opt/bin/rsync >/dev/null && echo /opt/bin/rsync || echo /usr/bin/rsync" 2>/dev/null)
REMOTE_RSYNC=${REMOTE_RSYNC:-/usr/bin/rsync}
SPARSE=""; echo "$REMOTE_RSYNC" | grep -q /opt/bin/rsync && SPARSE="-S"
$TSSH "$SYNO_USER@127.0.0.1" "mkdir -p \"$NAS_COLD_BASE\"" 2>>"$LOG"

log "delta přenos $SRCNAME → $SYNO_HOST:$NAS_COLD_BASE/$DEST_NAME (loopback :$LPORT, rsync $REMOTE_RSYNC $SPARSE --inplace --delete)…"
if "$RSYNC" -rlt $SPARSE --partial --inplace --delete --timeout=1800 --rsync-path="$REMOTE_RSYNC" \
     -e "$TSSH" "$PKG/" "$SYNO_USER@127.0.0.1:$NAS_COLD_BASE/$DEST_NAME/" 2>>"$LOG"; then
  log "OK přeneseno (zdroj $SRCNAME → $DEST_NAME)."
else
  log "CHYBA přenosu (rc=$?) — ponecháno k dalšímu pokusu."; notify "VM cold→Synology: přenos selhal"; exit 1
fi
