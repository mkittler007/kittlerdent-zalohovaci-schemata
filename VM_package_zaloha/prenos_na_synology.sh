#!/bin/bash
# Přenos balíků z LOCAL_BASE (Thunderbolt) na Synology (.120) — off-host.
# CÍLOVÉ SCHÉMA MK 5.9.2026: každou NOC poslední intradenní COLD (retence RETAIN_SYNO_COLD=3);
# ve ČTVRTEK navíc poslední RAM (retence RETAIN_SYNO_RAM=1). Dřív: obden ram ret4.
# BĚŽÍ NA HOSTU (.24), okno ~23:50 (PO WD). macOS 26 LNP → Homebrew rsync přes loopback SSH tunel.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/config.sh"
LOG="$LOG_DIR/prenos_na_synology.log"; ts(){ date +%FT%T%z; }; log(){ echo "$(ts) $*" >> "$LOG"; }

# --- loopback SSH tunel (Apple /usr/bin/ssh = LNP-povolený) → Homebrew rsync na 127.0.0.1 ---
# macOS 26 Local Network Privacy blokuje Homebrew rsync na LAN pod launchd (EHOSTUNREACH). Loopback je z LNP vyňatý.
# Zachovává GNU rsync -S sparse + --inplace pro velké .hds (openrsync to neumí). Bez zásahu do NASu (stávající sshd).
LPORT=2873
/usr/bin/ssh $SSH_OPTS -o ExitOnForwardFailure=yes -N -L 127.0.0.1:$LPORT:127.0.0.1:22 "$SYNO_USER@$SYNO_HOST" 2>>"$LOG" & TUN_PID=$!
trap '[ -n "${TUN_PID:-}" ] && kill "$TUN_PID" 2>/dev/null' EXIT
for i in $(seq 1 20); do /usr/bin/nc -z 127.0.0.1 "$LPORT" 2>/dev/null && break; sleep 0.5; done
if ! /usr/bin/nc -z 127.0.0.1 "$LPORT" 2>/dev/null; then
  log "CHYBA: SSH tunel na NAS se nezvedl (port $LPORT) — přenos přeskočen."; notify "VM záloha Synology: SSH tunel na NAS selhal"; exit 1
fi
TSSH="/usr/bin/ssh -p $LPORT $SSH_OPTS -o NoHostAuthenticationForLocalhost=yes"

# vzdálený rsync (Entware 3.4.1 se sparse, jinak DSM bez -S) — vše přes loopback tunel
REMOTE_RSYNC=$($TSSH "$SYNO_USER@127.0.0.1" "command -v /opt/bin/rsync >/dev/null && echo /opt/bin/rsync || echo /usr/bin/rsync" 2>/dev/null)
REMOTE_RSYNC=${REMOTE_RSYNC:-/usr/bin/rsync}
SPARSE=""; echo "$REMOTE_RSYNC" | grep -q /opt/bin/rsync && SPARSE="-S"
$TSSH "$SYNO_USER@127.0.0.1" "mkdir -p \"$NAS_BASE\"" 2>>"$LOG"

# send_type <typ> <retence>: přenese NEJNOVĚJŠÍ balík daného typu + rotace na NAS.
send_type() {
  TYPE="$1"; KEEP="$2"
  PKG=$(ls -1dt "$LOCAL_BASE/macOS_${TYPE}_"*.macvm 2>/dev/null | head -1)
  [ -n "$PKG" ] || { log "Žádný macOS_${TYPE}_* v $LOCAL_BASE — přeskočeno."; return 0; }
  NAME=$(basename "$PKG")
  log "přenos $NAME → $SYNO_HOST:$NAS_BASE/ (tunel :$LPORT, rsync $REMOTE_RSYNC $SPARSE)…"
  if "$RSYNC" -rlt $SPARSE --partial --inplace --timeout=1800 --rsync-path="$REMOTE_RSYNC" \
       -e "$TSSH" "$PKG/" "$SYNO_USER@127.0.0.1:$NAS_BASE/$NAME/" 2>>"$LOG"; then
    log "OK přeneseno: $NAME"
  else
    log "CHYBA přenosu $NAME (rc=$?) — ponecháno k dalšímu pokusu."; notify "VM záloha Synology: přenos $NAME selhal"; return 1
  fi
  # retence daného typu na NAS
  $TSSH "$SYNO_USER@127.0.0.1" "
    ls -1dt \"$NAS_BASE\"/macOS_${TYPE}_*.macvm 2>/dev/null | tail -n +\$(( $KEEP + 1 )) | while read -r d; do
      rm -rf \"\$d\" && echo \"rotace: smazan \$d\"
    done
  " 2>>"$LOG" | while read -r line; do log "$line"; done
}

rc=0
send_type cold "$RETAIN_SYNO_COLD" || rc=1            # cold KAŽDOU NOC
if [ "$(date +%u)" -eq 4 ]; then                      # 4 = čtvrtek → i ram
  send_type ram "$RETAIN_SYNO_RAM" || rc=1
  log "Čtvrtek → přenesen i ram."
fi
[ "$rc" -eq 0 ] && log "OK hotovo (Synology cold=$RETAIN_SYNO_COLD, ram čtvrtek=$RETAIN_SYNO_RAM)."
exit $rc
