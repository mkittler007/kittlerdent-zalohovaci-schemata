#!/bin/bash
# Běží ve VM (.82) DENNĚ ráno. Politika (Martin 12.10.2026): TICHÝ monitoring.
#   - Když NENÍ potřeba zásah → neodešle se nic (rc=20), weekstamp se nezapíše,
#     běží se dál každý den a hlídá, jestli se neobjeví důvod k zásahu.
#   - Když JE vhodný zásah (tíseň hosta / navýšení či snížení RAM VM) → e-mail
#     přes notify.py, a to I MIMO pracovní okno. Pak weekstamp = 1× týdně max
#     (ať stejný alert nechodí každý den).
# Přitáhne host logy přes SSH (VM->host funguje), pak spustí report.
set -u
BASE="$HOME/monitoring/cpuram"
HOSTDIR="$HOME/monitoring/cpuram_host"
KEY="$HOME/.ssh/id_ed25519_macmini"
WEEKSTAMP="$BASE/.last_report_week"
mkdir -p "$HOSTDIR"

CURWEEK="$(date +%G-W%V)"
if [ "$(cat "$WEEKSTAMP" 2>/dev/null)" = "$CURWEEK" ]; then
  exit 0   # actionable alert už tento ISO týden odešel
fi

# stáhni host logy (host_*.csv + peaks_host_*.log)
rsync -a --timeout=120 \
  -e "ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15" \
  --include='host_*.csv' --include='peaks_host_*.log' --exclude='*' \
  martinkittler@192.168.100.24:/Users/martinkittler/monitoring/cpuram/ "$HOSTDIR/" 2>>"$BASE/report.log" || \
  echo "$(date +%FT%T%z) report: stažení host logů selhalo (report poběží jen s VM daty)" >>"$BASE/report.log"

/usr/bin/python3 "$BASE/tydenni_report.py" --only-if-action --vm-dir "$BASE" --host-dir "$HOSTDIR" --dny 7 >>"$BASE/report.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "$CURWEEK" > "$WEEKSTAMP"   # actionable e-mail odešel → tenhle týden už ne
fi
# rc=20 = bez zásahu → nic neodesláno, weekstamp nezapsán, zkusí se zas zítra
