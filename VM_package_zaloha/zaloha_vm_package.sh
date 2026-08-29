#!/bin/bash
# Výroba samostatného obnovitelného balíku VM (kopie celého bundlu macOS.macvm).
# BĚŽÍ NA HOSTU (.24). Viz PLAN.md. Použití: zaloha_vm_package.sh cold|ram
#
# Postup (minimální downtime):
#   1) pause (cold) / suspend (ram)  -> konzistentní stav
#   2) klon:
#        - LOCAL_BASE na STEJNÉM svazku jako SRC (interní) -> cp -cR = instantní COW klon PŘÍMO tam
#        - LOCAL_BASE na jiném svazku (Thunderbolt)        -> cp -cR staging interně (instant) -> resume -> cp -R na Thunderbolt
#   3) resume co nejdřív  4) rotace (retence)
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/config.sh"
TYPE="${1:-cold}"
stamp=$(date +%Y-%m-%d_%H%M)
NAME="macOS_${TYPE}_${stamp}.macvm"
LOG="$LOG_DIR/zaloha_vm_package.log"
PHASE="/Users/martinkittler/monitoring/cpuram/phase"
ts() { date +%FT%T%z; }
log() { echo "$(ts) [$TYPE] $*" >> "$LOG"; }
mkdir -p "$LOCAL_BASE" "$LOG_DIR" 2>/dev/null

[ -x "$PRL" ] || { log "CHYBA: prlctl chybí"; notify "VM záloha: prlctl chybí"; exit 1; }
[ -d "$SRC" ] || { log "CHYBA: zdroj chybí $SRC"; notify "VM záloha: zdroj chybí"; exit 1; }
[ -d "$LOCAL_BASE" ] || { log "CHYBA: LOCAL_BASE nedostupný $LOCAL_BASE (Thunderbolt nepřipojen?)"; notify "VM záloha: cíl $LOCAL_BASE nedostupný (Thunderbolt?)"; exit 2; }

# stejný svazek jako zdroj? (device id) → přímý COW klon, jinak staging+move
SAME=0
[ "$(stat -f %d "$SRC" 2>/dev/null)" = "$(stat -f %d "$LOCAL_BASE" 2>/dev/null)" ] && SAME=1

# pojistka volného místa (jen interní/stejný svazek)
if [ "$SAME" = 1 ]; then
  free_gb=$(df -g "$LOCAL_BASE" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "${free_gb:-}" ] && [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
    old=$(ls -1dt "$LOCAL_BASE/macOS_cold_"*.macvm 2>/dev/null | tail -1)
    [ -n "$old" ] && rm -rf "$old" && log "pojistka místa: smazán nejstarší $old (volno ${free_gb}G < ${MIN_FREE_GB}G)"
  fi
fi

echo backup > "$PHASE" 2>/dev/null

# ── 1) konzistentní stav ──────────────────────────────────────────────────────
if [ "$TYPE" = "ram" ]; then
  "$PRL" suspend "$UUID" >>"$LOG" 2>&1 || { log "CHYBA suspend"; echo run > "$PHASE" 2>/dev/null; notify "VM záloha: suspend selhal"; exit 1; }
else
  "$PRL" pause "$UUID" >>"$LOG" 2>&1 || { log "CHYBA pause"; echo run > "$PHASE" 2>/dev/null; notify "VM záloha: pause selhal"; exit 1; }
fi

# ── 2) klon ───────────────────────────────────────────────────────────────────
t0=$(date +%s)
if [ "$SAME" = 1 ]; then
  DEST="$LOCAL_BASE/$NAME"; cp -cR "$SRC" "$DEST"; rc=$?
else
  STAGE="$LOG_DIR/staging/$NAME"; mkdir -p "$(dirname "$STAGE")"
  cp -cR "$SRC" "$STAGE"; rc=$?
fi
t1=$(date +%s)

# ── 3) resume co nejdřív ──────────────────────────────────────────────────────
"$PRL" resume "$UUID" >>"$LOG" 2>&1 || { log "POZOR: resume vrátil chybu"; notify "VM záloha: resume vrátil chybu — ověř VM!"; }
echo run > "$PHASE" 2>/dev/null
log "klon rc=$rc downtime=$((t1-t0))s same_vol=$SAME"

[ "$rc" -eq 0 ] || { log "CHYBA klonu — balík NEvznikl"; notify "VM záloha: klon selhal ($NAME)"; [ "$SAME" = 0 ] && rm -rf "$STAGE" 2>/dev/null; exit 1; }

# ── 4) staging → Thunderbolt (plná kopie za běhu VM) ─────────────────────────
if [ "$SAME" = 0 ]; then
  DEST="$LOCAL_BASE/$NAME"
  if cp -R "$STAGE" "$DEST" 2>>"$LOG"; then rm -rf "$STAGE" 2>/dev/null; log "OK balík: $DEST"
  else log "CHYBA přenosu na $LOCAL_BASE — staging ponechán"; notify "VM záloha: přenos na Thunderbolt selhal"; exit 1; fi
fi

# ── 5) rotace (retence) ───────────────────────────────────────────────────────
if [ "$TYPE" = "ram" ]; then keep=$RETAIN_RAM; else keep=$RETAIN_COLD; fi
i=0
ls -1dt "$LOCAL_BASE/macOS_${TYPE}_"*.macvm 2>/dev/null | while IFS= read -r p; do
  i=$((i+1)); [ "$i" -gt "$keep" ] && rm -rf "$p" 2>/dev/null && log "rotace: smazán starý $p"
done
log "OK hotovo (retence $keep)."
