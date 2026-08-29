#!/bin/bash
# Výroba samostatného obnovitelného balíku VM (kopie celého bundlu macOS.macvm).
# BĚŽÍ NA HOSTU (.24). Viz PLAN.md.
#
# Postup (minimální downtime):
#   1) pause (cold) NEBO suspend (ram)  -> konzistentní stav, disk klidný
#   2) cp -cR na INTERNÍ disk = instantní COW klon (staging)   -> downtime jen tohle
#   3) resume  -> VM zase jede
#   4) přesun staging klonu na Thunderbolt (plná kopie, už za běhu VM)
#   5) rotace (retence) na Thunderbolt, úklid staging
#
# Použití:  zaloha_vm_package.sh cold|ram
set -u
TYPE="${1:-cold}"                       # cold = studený (bez RAM) | ram = s RAM stavem (true resume)
UUID="{cf7a9c8f-39b4-4691-8c25-40ebae6a0768}"
PRL="/Applications/Parallels Desktop.app/Contents/MacOS/prlctl"
SRC="/Users/martinkittler/Parallels/macOS.macvm"
STAGE_DIR="/Users/martinkittler/VM_Safety/staging"          # interní, COW klon (dočasně)
DEST_BASE="/Volumes/Thunderbolt/VM_packages"                # Thunderbolt (od pondělí); uprav dle skutečného mountu
PHASE="/Users/martinkittler/monitoring/cpuram/phase"        # korelace zátěže s monitoringem
LOG="/Users/martinkittler/VM_Safety/zaloha_vm_package.log"
# retence dle typu (počet balíků na Thunderbolt)
RETAIN_COLD=6
RETAIN_RAM=3

ts() { date +%FT%T%z; }
log() { echo "$(ts) [$TYPE] $*" >> "$LOG"; }
stamp=$(date +%Y-%m-%d_%H%M)
NAME="macOS_${TYPE}_${stamp}.macvm"
STAGE="$STAGE_DIR/$NAME"
DEST="$DEST_BASE/$NAME"

mkdir -p "$STAGE_DIR" "$(dirname "$LOG")"
[ -x "$PRL" ] || { log "CHYBA: prlctl nenalezen"; exit 1; }
[ -d "$SRC" ] || { log "CHYBA: zdrojový bundle chybí: $SRC"; exit 1; }

# cíl musí být připojený (Thunderbolt). Když ne, radši nic nedělej než plnit interní disk.
if [ ! -d "$DEST_BASE" ]; then
  log "CÍL $DEST_BASE není připojen (Thunderbolt?) — přeskočeno, aby se nezaplnil interní disk."
  exit 2
fi

echo backup > "$PHASE" 2>/dev/null

# ── 1)+2) konzistentní stav → COW klon interně ─────────────────────────────────
if [ "$TYPE" = "ram" ]; then
  log "suspend (s RAM, ~52 GB, delší downtime)…"
  "$PRL" suspend "$UUID"  >>"$LOG" 2>&1 || { log "CHYBA suspend"; echo run > "$PHASE"; exit 1; }
else
  log "pause (studený, disk-konzistentní)…"
  "$PRL" pause "$UUID"    >>"$LOG" 2>&1 || { log "CHYBA pause"; echo run > "$PHASE"; exit 1; }
fi

t0=$(date +%s)
cp -cR "$SRC" "$STAGE"; cprc=$?
t1=$(date +%s)
log "COW klon interně rc=$cprc, ${STAGE}, ${t1}s-${t0}s = $((t1-t0)) s downtime-část"

# ── 3) resume co nejdřív ───────────────────────────────────────────────────────
"$PRL" resume "$UUID" >>"$LOG" 2>&1 || log "POZOR: resume vrátil chybu (ověř VM!)"
echo run > "$PHASE" 2>/dev/null

if [ "$cprc" -ne 0 ]; then
  log "CHYBA: interní klon selhal — balík NEvznikl. Staging uklizen."
  rm -rf "$STAGE" 2>/dev/null
  exit 1
fi

# ── 4) přesun staging → Thunderbolt (už za běhu VM) ───────────────────────────
log "přesun na Thunderbolt: $DEST"
if cp -R "$STAGE" "$DEST" 2>>"$LOG"; then
  rm -rf "$STAGE" 2>/dev/null
  log "OK balík na Thunderboltu: $DEST"
else
  log "CHYBA přenosu na Thunderbolt — staging PONECHÁN v $STAGE k ručnímu přesunu."
  exit 1
fi

# ── 5) rotace (retence) ── (bash 3.2 na macOS: bez mapfile) ────────────────────
if [ "$TYPE" = "ram" ]; then keep=$RETAIN_RAM; else keep=$RETAIN_COLD; fi
i=0
ls -1dt "$DEST_BASE/macOS_${TYPE}_"*.macvm 2>/dev/null | while IFS= read -r p; do
  i=$((i+1))
  if [ "$i" -gt "$keep" ]; then
    rm -rf "$p" 2>/dev/null && log "rotace: smazán starý balík $p"
  fi
done
log "hotovo (retence $keep)."
