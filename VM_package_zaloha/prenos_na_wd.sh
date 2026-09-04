#!/bin/bash
# Denní kopie nejnovějšího nočního (ram) balíku z LOCAL_BASE na USB "My Book" (WD). Retence 5.
# BĚŽÍ NA HOSTU (.24), okno ~23:10 (po nočním ram v 23:00, PŘED Synology v 23:50).
# POZOR: zápis na externí svazek přes launchd chce Full Disk Access (TCC). Bez něj se GRACEFULLY přeskočí + 1× Telegram.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/config.sh"
LOG="$LOG_DIR/prenos_na_wd.log"; ts(){ date +%FT%T%z; }; log(){ echo "$(ts) $*" >> "$LOG"; }
WDVOL="$(dirname "$WD_BASE")"          # "/Volumes/My Book"

[ -d "$WDVOL" ] || { log "WD nepřipojen ($WDVOL) — přeskočeno."; exit 2; }

# TCC write-test: když zápis nejde, je to Full Disk Access, ne unixová práva.
if ! touch "$WDVOL/.vmpkg_wt" 2>/dev/null; then
  log "WD: zápis ZAKÁZÁN (TCC/FDA chybí) — přeskočeno bez dotčení dat."
  notify "VM záloha WD: chybí Full Disk Access. Uděl v System Settings → Soukromí a zabezpečení → Plný přístup k disku (runner /bin/bash). Kopie na WD zatím NEBĚŽÍ."
  exit 3
fi
rm -f "$WDVOL/.vmpkg_wt" 2>/dev/null
mkdir -p "$WD_BASE" 2>/dev/null

PKG=$(ls -1dt "$LOCAL_BASE/macOS_ram_"*.macvm 2>/dev/null | head -1)
[ -n "$PKG" ] || { log "Žádný macOS_ram_* v $LOCAL_BASE — nic k přenosu."; exit 0; }
NAME=$(basename "$PKG")

# PREV = nejnovější existující WD balík (kromě cíle) → --link-dest = hardlink dedup nezměněných 128GB .hds bandů.
# Bez dedup byl každý ram balík plná ~900G kopie → 5× ≈ 4,5T přeplnilo WD (sdílí kontejner s TM). Viz legacy vm-backup-wd.sh.
# POZOR: --link-dest je NEslučitelné s --inplace (to by přepsalo hardlinkovaný předchozí balík) → --inplace pryč.
PREV=$(ls -1dt "$WD_BASE/macOS_ram_"*.macvm 2>/dev/null | grep -vF "$WD_BASE/$NAME" | head -1)
LINKDEST=""; [ -n "$PREV" ] && LINKDEST="--link-dest=$PREV"

log "kopie $NAME → WD ($WD_BASE)${PREV:+ [dedup vs $(basename "$PREV")]}…"
if "$RSYNC" -rlt -S --delete $LINKDEST "$PKG/" "$WD_BASE/$NAME/" 2>>"$LOG"; then
  log "OK na WD: $NAME"
else
  log "CHYBA kopie na WD (rc=$?)"; notify "VM záloha WD: kopie $NAME selhala"; exit 1
fi

# retence 5
i=0
ls -1dt "$WD_BASE/macOS_ram_"*.macvm 2>/dev/null | while IFS= read -r p; do
  i=$((i+1)); [ "$i" -gt "$RETAIN_WD" ] && rm -rf "$p" 2>/dev/null && log "rotace WD: smazán $p"
done
log "OK hotovo (retence $RETAIN_WD na WD)."
