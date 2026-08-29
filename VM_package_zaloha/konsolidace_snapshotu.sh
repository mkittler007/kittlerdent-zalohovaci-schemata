#!/bin/bash
# Konsolidace snapshotů VM — sloučí delty do base, zmenší bundle (284 -> ~130 GB).
# BĚŽÍ NA HOSTU (.24). Viz PLAN.md.
#
# BEZPEČNOST:
#   - VŽDY chrání snapshot "start-up bezclaude instalace" (NEmazat).
#   - Default DRY-RUN (jen vypíše). Provedení jen s argumentem  --apply .
#   - Maže leaf-first (od nejnovějšího), po jednom, při chybě končí.
#
# POZOR — provázanost: snapshoty "auto-*" patří stávajícímu vm-backup-synology.sh
#   (denní snapshot + rsync na NAS, keep 2). Konsoliduj až po rozhodnutí, zda nové
#   package schéma NAHRAZUJE starý vm-backup. Ideálně když VM neběží / je v klidu,
#   a když už existuje čerstvý package (pojistka).
#
# Použití:  konsolidace_snapshotu.sh          (dry-run, jen ukáže)
#           konsolidace_snapshotu.sh --apply  (opravdu sloučí)
set -u
UUID="{cf7a9c8f-39b4-4691-8c25-40ebae6a0768}"   # VM "macOS"
PRL="/Applications/Parallels Desktop.app/Contents/MacOS/prlctl"
PROTECT_NAME="start-up bezclaude instalace"
LOG="/Users/martinkittler/VM_Safety/konsolidace.log"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
ts() { date +%FT%T%z; }
log() { echo "$(ts) $*" | tee -a "$LOG"; }

[ -x "$PRL" ] || { echo "prlctl nenalezen"; exit 1; }
json=$("$PRL" snapshot-list "$UUID" -j 2>/dev/null)
[ -n "$json" ] || { echo "snapshot-list prázdný"; exit 1; }

# python vypíše  "date<TAB>id<TAB>name"  jen pro NEchráněné, seřazené od nejnovějšího
rows=$(/usr/bin/python3 - "$json" "$PROTECT_NAME" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); protect = sys.argv[2]
items = [(v.get("date",""), sid, v.get("name","")) for sid, v in d.items()]
items.sort(reverse=True)  # nejnovější první (leaf-first)
for date, sid, name in items:
    if name == protect:
        continue
    print(f"{date}\t{sid}\t{name}")
PY
)

if [ -z "$rows" ]; then
  log "Není co konsolidovat (kromě chráněného '$PROTECT_NAME')."
  exit 0
fi

log "=== Ke sloučení (chráněný '$PROTECT_NAME' zůstává): ==="
echo "$rows" | while IFS=$'\t' read -r date sid name; do
  log "  $date  $name  $sid"
done

if [ "$APPLY" -ne 1 ]; then
  log "DRY-RUN. Pro skutečné sloučení spusť:  $0 --apply"
  exit 0
fi

log "=== APPLY: mažu leaf-first ==="
echo "$rows" | while IFS=$'\t' read -r date sid name; do
  log "snapshot-delete $name ($sid)…"
  if "$PRL" snapshot-delete "$UUID" --id "$sid" >>"$LOG" 2>&1; then
    log "  OK sloučeno."
  else
    log "  CHYBA při mazání $sid — KONČÍM (zbytek nech ručně)."
    exit 1
  fi
done
log "Konsolidace hotová. Zkontroluj velikost: du -sh /Users/martinkittler/Parallels/macOS.macvm"
