#!/bin/bash
# =============================================================================
#  Měsíční kopie zálohy Parallels VM (ordinace) na Synology NAS .120
#  Zdroj: lokální cold záloha (SE STAVEM RAM/.mem) — žádný další prostoj VM.
#
#  Cíl:      /volume1/HDD IMac ordinace/Parallels_VM_zaloha/  na NAS .120
#  Retence:  2 verze (vm_current + vm_prev), rotace přes hardlinky (cp -al)
#  Kdy:      1× měsíčně, PRVNÍ NEDĚLI (LaunchAgent běží každou neděli, skript
#            se provede jen když je den v měsíci <= 7). Ruční běh: --now
#
#  Přenos:   openrsync (na iMacu) push přes SSH klíčem synology_backup.
#            Nová verze se na NASu nejdřív "naseeduje" z předchozí přes cp -al
#            (hardlinky, okamžité), pak rsync přenese jen rozdíly a atomicky
#            se prohodí sloty. Při selhání zůstanou current+prev nedotčené.
# =============================================================================
set -uo pipefail

# Název .pvm balíku odvozujeme z lokální cold zálohy (tam je vždy jediný .pvm) — rename-proof.
DROOT_TMP="$HOME/Parallels_Backup_ordinace"
BNAME="$(cd "$DROOT_TMP/backup" 2>/dev/null && ls -d *.pvm 2>/dev/null | head -1)"
[ -n "$BNAME" ] || BNAME="Imac_zeleny_cold_VM.pvm"
SRC="$HOME/Parallels_Backup_ordinace/backup/$BNAME"
DROOT="$HOME/Parallels_Backup_ordinace"
LOG="$DROOT/nas_sync.log"
STATUS="$DROOT/NAS_STATUS.txt"
LOCK="$DROOT/.nas.lock"

NAS="admin@192.168.100.120"
NKEY="$HOME/.ssh/synology_backup"
RBASE="/volume1/HDD IMac ordinace/Parallels_VM_zaloha"
SSH_NAS=(ssh -i "$NKEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=15)
MAX_RETRY=3

log(){ printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
run_nas(){ "${SSH_NAS[@]}" "$NAS" "$@"; }

NOW=0; [ "${1:-}" = "--now" ] && NOW=1

# --- guard: jen první neděli v měsíci (pokud ne --now) ---
if [ "$NOW" = "0" ]; then
  DOM=$(date +%d)
  if [ "$((10#$DOM))" -gt 7 ]; then
    log "není první neděle (den v měsíci $DOM) — přeskakuji"; exit 0
  fi
fi

# --- lock ---
if ! mkdir "$LOCK" 2>/dev/null; then log "PŘESKAKUJI: běží už jiná instance"; exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

log "===== START NAS měsíční kopie (now=$NOW) ====="
[ -d "$SRC" ] || { log "CHYBA: lokální záloha neexistuje ($SRC)"; echo "FAIL src $(date '+%F %T')" >"$STATUS"; exit 1; }
run_nas "test -d \"$RBASE\" || mkdir -p \"$RBASE\"" 2>>"$LOG" || { log "CHYBA: NAS nedostupný"; echo "FAIL nas-unreachable $(date '+%F %T')" >"$STATUS"; exit 1; }

START=$(date +%s)

# --- 1) seed incoming z current (hardlinky = okamžité, basis pro rozdíly) ---
#     openrsync neumí vytvořit vnořené adresáře → cíl vždy zajistíme přes mkdir -p
log "seeduji vm_incoming z vm_current (hardlinky)"
run_nas "rm -rf \"$RBASE/vm_incoming\"; if [ -d \"$RBASE/vm_current\" ]; then cp -al \"$RBASE/vm_current\" \"$RBASE/vm_incoming\"; fi; mkdir -p \"$RBASE/vm_incoming/$BNAME\"" 2>>"$LOG"

# --- 2) rsync push s retry ---
RC=1
for try in $(seq 1 $MAX_RETRY); do
  log "rsync pokus $try/$MAX_RETRY -> NAS:$RBASE/vm_incoming/"
  /usr/bin/rsync -a --delete \
    -e "ssh -i $NKEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=15" \
    "$SRC/" "$NAS:'$RBASE/vm_incoming/$BNAME/'" >>"$LOG" 2>&1
  RC=$?
  [ "$RC" = "0" ] && break
  log "rsync selhal (rc=$RC), čekám 30s a zkusím znovu"; sleep 30
done

if [ "$RC" != "0" ]; then
  log "CHYBA: rsync se nepovedl ani na $MAX_RETRY pokusů (rc=$RC) — current+prev nedotčené"
  echo "FAIL rsync rc=$RC $(date '+%F %T')" >"$STATUS"; exit 1
fi

# --- 3) atomický swap slotů (retence 2) ---
log "swap: prev<-current, current<-incoming"
run_nas "
  rm -rf \"$RBASE/vm_prev\";
  [ -d \"$RBASE/vm_current\" ] && mv \"$RBASE/vm_current\" \"$RBASE/vm_prev\";
  mv \"$RBASE/vm_incoming\" \"$RBASE/vm_current\"
" 2>>"$LOG"

END=$(date +%s); DUR=$((END-START))
INFO=$(run_nas "
  echo current=\$(du -sh \"$RBASE/vm_current\" 2>/dev/null | awk '{print \$1}');
  echo prev=\$(du -sh \"$RBASE/vm_prev\" 2>/dev/null | awk '{print \$1}');
  echo free=\$(df -h /volume1 | awk 'NR==2{print \$4}')
" 2>>"$LOG" | tr '\n' ' ')

log "HOTOVO OK — $INFO  čas: ${DUR}s ($((DUR/60)) min)"
printf 'OK  %s  %s duration=%ss\n' "$(date '+%F %T')" "$INFO" "$DUR" >"$STATUS"
log "===== KONEC ====="
exit 0
