#!/bin/bash
# Denní kopie z LOCAL_BASE (Thunderbolt) na USB volume VM_WD (WD, kontejner sdílí s TM „My Book").
# CÍLOVÉ SCHÉMA MK 5.9.2026: kopíruje POSLEDNÍ COLD (retence RETAIN_WD_COLD=3) + POSLEDNÍ RAM
# (retence RETAIN_WD_RAM=1). Dřív jen ram (retence 5). link-dest = hardlink dedup proti stejnému typu.
# BĚŽÍ NA HOSTU (.24), okno ~23:10 (po nočním ram 23:00, PŘED Synology 23:50).
# POZOR: zápis na externí svazek přes launchd chce Full Disk Access (TCC). Bez něj GRACEFULLY skip + 1× notify.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/config.sh"
LOG="$LOG_DIR/prenos_na_wd.log"; ts(){ date +%FT%T%z; }; log(){ echo "$(ts) $*" >> "$LOG"; }
WDVOL="$(dirname "$WD_BASE")"          # "/Volumes/VM_WD"

[ -d "$WDVOL" ] || { log "WD nepřipojen ($WDVOL) — přeskočeno."; exit 2; }

# TCC write-test: když zápis nejde, je to Full Disk Access, ne unixová práva.
if ! touch "$WDVOL/.vmpkg_wt" 2>/dev/null; then
  log "WD: zápis ZAKÁZÁN (TCC/FDA chybí) — přeskočeno bez dotčení dat."
  notify "VM záloha WD: chybí Full Disk Access (runner /bin/bash). Kopie na WD zatím NEBĚŽÍ."
  exit 3
fi
rm -f "$WDVOL/.vmpkg_wt" 2>/dev/null
mkdir -p "$WD_BASE" 2>/dev/null

# copy_type <typ> <retence>: zkopíruje NEJNOVĚJŠÍ balík daného typu z LOCAL_BASE + rotace na WD.
# link-dest = hardlink nezměněných 128GB .hds bandů proti předchozímu balíku téhož typu
# (bez dedup byl každý balík plná ~stovky G kopie). --link-dest NEslučitelné s --inplace (to je proto pryč).
copy_type() {
  TYPE="$1"; KEEP="$2"
  PKG=$(ls -1dt "$LOCAL_BASE/macOS_${TYPE}_"*.macvm 2>/dev/null | head -1)
  [ -n "$PKG" ] || { log "Žádný macOS_${TYPE}_* v $LOCAL_BASE — přeskočeno."; return 0; }
  NAME=$(basename "$PKG")
  PREV=$(ls -1dt "$WD_BASE/macOS_${TYPE}_"*.macvm 2>/dev/null | grep -vF "$WD_BASE/$NAME" | head -1)
  LINKDEST=""; [ -n "$PREV" ] && LINKDEST="--link-dest=$PREV"
  log "kopie $NAME → WD${PREV:+ [dedup vs $(basename "$PREV")]}…"
  if "$RSYNC" -rlt -S --delete $LINKDEST "$PKG/" "$WD_BASE/$NAME/" 2>>"$LOG"; then
    log "OK na WD: $NAME"
  else
    log "CHYBA kopie na WD: $NAME (rc=$?)"; notify "VM záloha WD: kopie $NAME selhala"; return 1
  fi
  # retence daného typu
  i=0
  ls -1dt "$WD_BASE/macOS_${TYPE}_"*.macvm 2>/dev/null | while IFS= read -r p; do
    i=$((i+1)); [ "$i" -gt "$KEEP" ] && rm -rf "$p" 2>/dev/null && log "rotace WD: smazán $p"
  done
}

rc=0
copy_type cold "$RETAIN_WD_COLD" || rc=1
copy_type ram  "$RETAIN_WD_RAM"  || rc=1
[ "$rc" -eq 0 ] && log "OK hotovo (WD cold=$RETAIN_WD_COLD, ram=$RETAIN_WD_RAM)."
exit $rc
