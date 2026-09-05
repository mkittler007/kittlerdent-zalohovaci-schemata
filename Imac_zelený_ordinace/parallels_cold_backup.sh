#!/bin/bash
# =============================================================================
#  Parallels COLD backup — Imac zelený (ordinace)
#  VM: "Windows 11 (1)"  UUID {5ed2e4d7-210a-4f9c-b955-274bad61ee9f}
#
#  Princip (minimální downtime díky APFS clonefile):
#     1) suspend VM
#     2) cp -c (APFS copy-on-write klon) celého .pvm balíku  -> .staging.pvm
#        (klon je metadatový, trvá vteřiny, nekopíruje reálná data)
#     3) resume VM   <-- downtime KONČÍ zde (jen pár vteřin)
#     4) swap: nová záloha nahradí starou (retence 1)
#
#  Cíl na TÉMŽE SSD (rychlé, ale NECHRÁNÍ proti selhání disku — viz PLAN_OBNOVY.md).
#  Běží lokálně na zeleném iMacu jako LaunchAgent (denně ~12:00).
#  Ruční spuštění:   ./parallels_cold_backup.sh
#  Jen kontrola:     ./parallels_cold_backup.sh --selftest
# =============================================================================
set -uo pipefail

PRL=/usr/local/bin/prlctl
UUID="{5ed2e4d7-210a-4f9c-b955-274bad61ee9f}"
# Cestu k .pvm odvozujeme dynamicky z prlctl podle UUID (rename-proof).
# Fallback na starý pevný název, kdyby prlctl selhal.
SRC="$("$PRL" list -i "$UUID" 2>/dev/null | awk -F': ' '/^Home:/{print $2}' | sed 's:/*$::')"
[ -n "$SRC" ] || SRC="$HOME/Parallels/Windows 11.pvm"
DROOT="$HOME/Parallels_Backup_ordinace"
DEST="$DROOT/backup"
# Cíl zálohy má PEVNÝ, srozumitelný název (odlišit od živé VM, ať se v tom vyznáme).
BUNDLE="Imac_zeleny_cold_VM.pvm"
STAGE="$DEST/.staging.pvm"
OLD="$DEST/.old.pvm"
LOG="$DROOT/backup.log"
STATUS="$DROOT/STATUS.txt"
LOCK="$DROOT/.lock"
MIN_FREE_GB="${MIN_FREE_GB:-20}"   # bezpečnostní rezerva volného místa (přepíš env proměnnou pro jednorázový běh)

mkdir -p "$DEST"
log(){ printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
free_gb(){ df -g /System/Volumes/Data | awk 'NR==2{print $4}'; }
vm_state(){ $PRL status "$UUID" 2>/dev/null | awk '{print $NF}'; }   # running|suspended|stopped

SELFTEST=0; [ "${1:-}" = "--selftest" ] && SELFTEST=1

# --- lock (atomický přes mkdir) ---
if ! mkdir "$LOCK" 2>/dev/null; then
  log "PŘESKAKUJI: běží už jiná instance (lock $LOCK)"; exit 0
fi
RESUME_AFTER=0
cleanup(){
  [ "$RESUME_AFTER" = "1" ] && { log "cleanup: resume VM"; $PRL resume "$UUID" >>"$LOG" 2>&1; }
  rmdir "$LOCK" 2>/dev/null
}
trap cleanup EXIT INT TERM

log "===== START cold backup (selftest=$SELFTEST) ====="

# --- kontroly ---
[ -x "$PRL" ] || { log "CHYBA: prlctl nenalezen ($PRL)"; echo "FAIL prlctl $(date '+%F %T')" >"$STATUS"; exit 1; }
[ -d "$SRC" ] || { log "CHYBA: zdrojová VM neexistuje ($SRC)"; echo "FAIL src $(date '+%F %T')" >"$STATUS"; exit 1; }
FG=$(free_gb); log "volné místo: ${FG} GB (min ${MIN_FREE_GB} GB)"
[ "$FG" -ge "$MIN_FREE_GB" ] || { log "CHYBA: málo místa"; echo "FAIL space ${FG}GB $(date '+%F %T')" >"$STATUS"; exit 1; }

if [ "$SELFTEST" = "1" ]; then
  log "SELFTEST OK — prlctl, zdroj i místo v pořádku. VM se nepozastavuje."
  echo "SELFTEST OK $(date '+%F %T') free=${FG}GB state=$(vm_state)" >"$STATUS"
  exit 0
fi

START=$(date +%s)
STATE=$(vm_state); log "stav VM: $STATE"

# --- suspend (jen pokud běží) ---
SUSP_START=$(date +%s)
if [ "$STATE" = "running" ]; then
  log "suspend VM..."
  if $PRL suspend "$UUID" >>"$LOG" 2>&1; then
    RESUME_AFTER=1
    for i in $(seq 1 60); do [ "$(vm_state)" = "suspended" ] && break; sleep 1; done
    log "VM stav po suspend: $(vm_state)"
  else
    log "CHYBA: suspend selhal — končím."; echo "FAIL suspend $(date '+%F %T')" >"$STATUS"; exit 1
  fi
else
  log "VM neběží ($STATE) — klonuji bez suspend/resume"
fi

# --- APFS clonefile do stagingu (rychlé, COW) ---
log "APFS klon -> $STAGE"
rm -rf "$STAGE"
cp -Rpc "$SRC" "$STAGE"; CRC=$?

# --- resume HNED (konec downtime) ---
if [ "$RESUME_AFTER" = "1" ]; then
  log "resume VM..."; $PRL resume "$UUID" >>"$LOG" 2>&1; RESUME_AFTER=0
  log "VM stav po resume: $(vm_state)"
fi
DOWNTIME=$(( $(date +%s) - SUSP_START ))
log "downtime VM: ${DOWNTIME}s"

if [ "$CRC" != "0" ]; then
  log "CHYBA: klon selhal (rc=$CRC)"; rm -rf "$STAGE"
  echo "FAIL clone rc=$CRC $(date '+%F %T') downtime=${DOWNTIME}s" >"$STATUS"; exit 1
fi

# --- swap: retence 1 (bezpečně, aby vždy existovala jedna platná záloha) ---
rm -rf "$OLD"
[ -d "$DEST/$BUNDLE" ] && mv "$DEST/$BUNDLE" "$OLD"
mv "$STAGE" "$DEST/$BUNDLE"
rm -rf "$OLD"

END=$(date +%s); DUR=$((END-START))
SIZE=$(du -sh "$DEST/$BUNDLE" 2>/dev/null | awk '{print $1}')
log "HOTOVO OK — velikost zálohy: $SIZE, downtime: ${DOWNTIME}s, celkem: ${DUR}s, volno: $(free_gb)GB"
printf 'OK  %s  size=%s  downtime=%ss  total=%ss  free_after=%sGB\n' \
  "$(date '+%F %T')" "$SIZE" "$DOWNTIME" "$DUR" "$(free_gb)" >"$STATUS"
log "===== KONEC (rc=0) ====="
exit 0
