#!/bin/bash
# Přenos nejnovějšího nočního (ram) balíku z LOCAL_BASE na Synology (.120) — off-host.
# BĚŽÍ NA HOSTU (.24), okno ~23:50 (PO WD). OBDEN (parita sudý den), retence 4 na NAS.
# POLITIKA: off-host jde POUZE noční RAM balík (macOS_ram_*); intraday cold zůstává lokálně.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/config.sh"
LOG="$LOG_DIR/prenos_na_synology.log"; ts(){ date +%FT%T%z; }; log(){ echo "$(ts) $*" >> "$LOG"; }

# OBDEN: agent fajruje denně, tady se normálně pustí jen v SUDÝ den (epoch_day % 2 == 0).
# Výjimka (fix 2026-09-03): v LICHÝ den přesto DOŽENE přenos, pokud je nejnovější offsite
# kopie na NASu starší než 48 h (nebo chybí) = předchozí sudý přenos selhal. Bez toho by
# kickstart-retry hlídače spadlý do lichého dne jen no-opnul a stáří by přeteklo do alertu.
epoch_day=$(( $(date +%s) / 86400 ))
if [ $(( epoch_day % 2 )) -ne 0 ]; then
  nas_m=$(ssh $SSH_OPTS "$SYNO_USER@$SYNO_HOST" "p=\$(ls -1dt \"$NAS_BASE\"/macOS_ram_*.macvm 2>/dev/null | head -1); [ -n \"\$p\" ] && stat -c %Y \"\$p\"" 2>/dev/null)
  nas_age=$([ -n "$nas_m" ] && echo $(( ( $(date +%s) - nas_m ) / 3600 )) || echo 9999)
  if [ "$nas_age" -lt 48 ]; then
    log "Obden gate: lichý den, offsite kopie svěží (${nas_age}h) — nekopíruje se."; exit 0
  fi
  log "Obden gate: lichý den, ale offsite kopie stará/chybí (${nas_age}h) — DOŽENU (předchozí sudý přenos zřejmě selhal)."
fi

PKG=$(ls -1dt "$LOCAL_BASE/macOS_ram_"*.macvm 2>/dev/null | head -1)
[ -n "$PKG" ] || { log "Žádný macOS_ram_* v $LOCAL_BASE — nic k přenosu."; exit 0; }
NAME=$(basename "$PKG")

# macOS 26 Local Network Privacy blokuje Homebrew rsync (config.sh $RSYNC) přístup na LAN pod launchd
# → connect() EHOSTUNREACH ("No route to host"). OBEJITÍ (4.9.2026): Apple /usr/bin/ssh (LNP-povolený)
# drží SSH tunel 127.0.0.1:$LPORT → NAS:22; Homebrew rsync pak jede na 127.0.0.1 (loopback = z Local
# Network Privacy VYŇATÝ) → zachová GNU rsync -S sparse + --inplace pro velké .hds (openrsync to neumí:
# rc=11 na velkých souborech + -S neslučuje s --inplace). Bez zásahu do konfigurace NASu (stávající sshd).
LPORT=2873
/usr/bin/ssh $SSH_OPTS -o ExitOnForwardFailure=yes -N -L 127.0.0.1:$LPORT:127.0.0.1:22 "$SYNO_USER@$SYNO_HOST" 2>>"$LOG" & TUN_PID=$!
trap '[ -n "${TUN_PID:-}" ] && kill "$TUN_PID" 2>/dev/null' EXIT
for i in $(seq 1 20); do /usr/bin/nc -z 127.0.0.1 "$LPORT" 2>/dev/null && break; sleep 0.5; done
if ! /usr/bin/nc -z 127.0.0.1 "$LPORT" 2>/dev/null; then
  log "CHYBA: SSH tunel na NAS se nezvedl (port $LPORT) — přenos přeskočen."; notify "VM záloha Synology: SSH tunel na NAS selhal"; exit 1
fi
TSSH="/usr/bin/ssh -p $LPORT $SSH_OPTS -o NoHostAuthenticationForLocalhost=yes"

# vzdálený rsync (Entware 3.4.1 se sparse, jinak DSM bez -S) + cílová složka — vše přes loopback tunel
REMOTE_RSYNC=$($TSSH "$SYNO_USER@127.0.0.1" "command -v /opt/bin/rsync >/dev/null && echo /opt/bin/rsync || echo /usr/bin/rsync" 2>/dev/null)
REMOTE_RSYNC=${REMOTE_RSYNC:-/usr/bin/rsync}
SPARSE=""; echo "$REMOTE_RSYNC" | grep -q /opt/bin/rsync && SPARSE="-S"
$TSSH "$SYNO_USER@127.0.0.1" "mkdir -p \"$NAS_BASE\"" 2>>"$LOG"

log "přenos $NAME → $SYNO_HOST:$NAS_BASE/ (loopback tunel :$LPORT, rsync $REMOTE_RSYNC $SPARSE)…"
if "$RSYNC" -rlt $SPARSE --partial --inplace --timeout=1800 --rsync-path="$REMOTE_RSYNC" \
     -e "$TSSH" "$PKG/" "$SYNO_USER@127.0.0.1:$NAS_BASE/$NAME/" 2>>"$LOG"; then
  log "OK přeneseno: $NAME"
else
  log "CHYBA přenosu $NAME (rc=$?) — ponecháno k dalšímu pokusu."; notify "VM záloha Synology: přenos $NAME selhal"; exit 1
fi

# retence 4 na NAS (jen macOS_ram_*) — přes loopback tunel
$TSSH "$SYNO_USER@127.0.0.1" "
  ls -1dt \"$NAS_BASE\"/macOS_ram_*.macvm 2>/dev/null | tail -n +\$(( $RETAIN_SYNO + 1 )) | while read -r d; do
    rm -rf \"\$d\" && echo \"rotace: smazan \$d\"
  done
" 2>>"$LOG" | while read -r line; do log "$line"; done
log "OK hotovo (retence $RETAIN_SYNO na NAS)."
