#!/bin/bash
# =============================================================================
#  DENNÍ kopie cold zálohy Parallels VM (zelený iMac / ordinace) na Synology .120
#  Zdroj: lokální cold záloha ~/Parallels_Backup_ordinace/backup/<jediný .pvm>
#  Žádný další prostoj VM (kopíruje se z hotové cold zálohy).
#
#  Cíl:      /volume1/VM Imac_zelený/  na NAS .120
#  Struktura:
#     daily/Imac_zeleny_cold_VM_<YYYY-MM-DD>.pvm ... denní verze (retence 10 dní)
#     offsite_current/Imac_zeleny_cold_VM.pvm    ... hardlink na nejnovější den
#                                                 = JEDINÝ ZDROJ pro HyperBackup -> C2
#                                                 (C2 drží 2 verze = poslední 2 cold)
#  POZOR: denní verze jsou v podsložce daily/, aby šly z C2 vyloučit jednou stálou
#         cestou /VM Imac_zelený/daily/ (do C2 tak jde jen offsite_current). 5.9.2026.
#  Retence:  10 denních verzí na NASu (hardlink dedup mezi dny -> reálně málo místa).
#  Kdy:      1x denně (LaunchAgent). Ruční běh: --now (bez efektu, běží vždy).
#
#  Přenos:   openrsync (Apple, na iMacu) push přes SSH klíčem synology_backup.
#            Dnešní verze se nejdřív "naseeduje" z nejnovější přes cp -al
#            (hardlinky na NASu, okamžité), pak rsync přenese jen rozdíly.
#            Při selhání zůstanou předchozí denní verze nedotčené.
# =============================================================================
set -uo pipefail

# Název .pvm balíku odvozujeme z lokální cold zálohy (tam je vždy jediný .pvm) — rename-proof.
DROOT="$HOME/Parallels_Backup_ordinace"
BNAME="$(cd "$DROOT/backup" 2>/dev/null && ls -d *.pvm 2>/dev/null | head -1)"
[ -n "$BNAME" ] || BNAME="Imac_zeleny_cold_VM.pvm"
SRC="$DROOT/backup/$BNAME"
LOG="$DROOT/nas_sync.log"
STATUS="$DROOT/NAS_STATUS.txt"
LOCK="$DROOT/.nas.lock"

NAS="admin@192.168.100.120"
NKEY="$HOME/.ssh/synology_backup"
RBASE="/volume1/VM Imac_zelený"
DAILY="daily"                          # podsložka s denními verzemi (C2 ji vylučuje jednou cestou)
RETENTION=10
DATE=$(date +%F)                       # YYYY-MM-DD (lexikální řazení = chronologické)
DEST_NAME="Imac_zeleny_cold_VM_${DATE}.pvm"  # název dnešní denní verze
DEST="$DAILY/$DEST_NAME"               # relativní cesta pod RBASE (daily/…)
CURR_DIR="offsite_current"             # stálý název pro HyperBackup->C2 (jen tohle jde do C2)
CURR_NAME="Imac_zeleny_cold_VM.pvm"
SSH_NAS=(ssh -i "$NKEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=15)
MAX_RETRY=3

log(){ printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
run_nas(){ "${SSH_NAS[@]}" "$NAS" "$@"; }

# --- víkendová pojistka: v So/Ne se na Synology NEzálohuje (přání Martina 5.9.2026) ---
#     Lokální cold na iMacu běží dál každý den; jen push na NAS se o víkendu vynechá.
DOW=$(date +%u)   # 1=Po ... 6=So, 7=Ne
if [ "$DOW" -ge 6 ]; then
  log "víkend (den $DOW) — na Synology se nezálohuje, přeskakuji"
  exit 0
fi

# --- lock ---
if ! mkdir "$LOCK" 2>/dev/null; then log "PŘESKAKUJI: běží už jiná instance"; exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

log "===== START NAS denní kopie ($DATE) ====="
[ -d "$SRC" ] || { log "CHYBA: lokální záloha neexistuje ($SRC)"; echo "FAIL src $(date '+%F %T')" >"$STATUS"; exit 1; }
run_nas "test -d \"$RBASE\" || mkdir -p \"$RBASE\"" 2>>"$LOG" || { log "CHYBA: NAS nedostupný"; echo "FAIL nas-unreachable $(date '+%F %T')" >"$STATUS"; exit 1; }

START=$(date +%s)

# --- 1) seed dnešní verze z nejnovější existující (hardlinky = basis pro rozdíly) ---
#     openrsync neumí vytvořit vnořené adresáře -> cíl vždy zajistíme přes mkdir -p
log "seeduji $DEST z nejnovější denní verze (hardlinky)"
run_nas "
  cd \"$RBASE\" || exit 1
  mkdir -p \"$DAILY\"
  if [ ! -d \"$DEST\" ]; then
    LATEST=\$(ls -d \"$DAILY\"/Imac_zeleny_cold_VM_*.pvm 2>/dev/null | sort | tail -1)
    if [ -n \"\$LATEST\" ] && [ \"\$LATEST\" != \"$DEST\" ]; then cp -al \"\$LATEST\" \"$DEST\"; fi
  fi
  mkdir -p \"$DEST\"
" 2>>"$LOG"

# --- 2) rsync push s retry (BEZ --inplace: chrání hardlinkované předchozí dny) ---
RC=1
for try in $(seq 1 $MAX_RETRY); do
  log "rsync pokus $try/$MAX_RETRY -> NAS:$RBASE/$DEST/"
  /usr/bin/rsync -a --delete \
    -e "ssh -i $NKEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=15" \
    "$SRC/" "$NAS:'$RBASE/$DEST/'" >>"$LOG" 2>&1
  RC=$?
  [ "$RC" = "0" ] && break
  log "rsync selhal (rc=$RC), čekám 30s a zkusím znovu"; sleep 30
done

if [ "$RC" != "0" ]; then
  log "CHYBA: rsync se nepovedl ani na $MAX_RETRY pokusů (rc=$RC) — předchozí dny nedotčené"
  echo "FAIL rsync rc=$RC $(date '+%F %T')" >"$STATUS"; exit 1
fi

# --- 3) offsite_current = hardlink na dnešní verzi (zdroj pro HyperBackup->C2) ---
log "aktualizuji $CURR_DIR/$CURR_NAME (hardlink na $DEST)"
run_nas "
  cd \"$RBASE\" || exit 1
  rm -rf \"$CURR_DIR\"
  mkdir -p \"$CURR_DIR\"
  cp -al \"$DEST\" \"$CURR_DIR/$CURR_NAME\"
" 2>>"$LOG"

# --- 4) retence: nech nejnovějších $RETENTION denních verzí, starší smaž ---
log "retence: nechávám posledních $RETENTION denních verzí"
run_nas "
  cd \"$RBASE/$DAILY\" || exit 1
  ls -d Imac_zeleny_cold_VM_*.pvm 2>/dev/null | sort | head -n -$RETENTION | while read d; do
    [ -n \"\$d\" ] && rm -rf \"\$d\" && echo \"smazáno staré: \$d\"
  done
" 2>>"$LOG"

END=$(date +%s); DUR=$((END-START))
INFO=$(run_nas "
  cd \"$RBASE\" 2>/dev/null || exit 0
  echo verzí=\$(ls -d \"$DAILY\"/Imac_zeleny_cold_VM_*.pvm 2>/dev/null | wc -l | tr -d ' ');
  echo dnes=\$(du -sh \"$DEST\" 2>/dev/null | awk '{print \$1}');
  echo celkem=\$(du -sh . 2>/dev/null | awk '{print \$1}');
  echo free=\$(df -h /volume1 | awk 'NR==2{print \$4}')
" 2>>"$LOG" | tr '\n' ' ')

log "HOTOVO OK — $INFO  čas: ${DUR}s ($((DUR/60)) min)"
printf 'OK  %s  %s duration=%ss\n' "$(date '+%F %T')" "$INFO" "$DUR" >"$STATUS"
log "===== KONEC ====="
exit 0
