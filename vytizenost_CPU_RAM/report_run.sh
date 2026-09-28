#!/bin/bash
# Běží ve VM (.82) DENNĚ ráno. Report se ale odešle jen 1× týdně a jen v pracovní den:
#   - už odeslán tento ISO týden  → skip (weekstamp)
#   - Martin dnes neordinuje (IS) → tydenni_report.py vrátí exit 10, weekstamp se nezapíše,
#     zkusí se zas zítra (report tak počká na první pracovní den v týdnu).
# Přitáhne host logy přes SSH (VM->host funguje), pak spustí report → e-mail přes notify.py.
set -u
BASE="$HOME/monitoring/cpuram"
HOSTDIR="$HOME/monitoring/cpuram_host"
KEY="$HOME/.ssh/id_ed25519_macmini"
WEEKSTAMP="$BASE/.last_report_week"
mkdir -p "$HOSTDIR"

CURWEEK="$(date +%G-W%V)"
if [ "$(cat "$WEEKSTAMP" 2>/dev/null)" = "$CURWEEK" ]; then
  exit 0   # report za tenhle týden už odešel
fi

# stáhni host logy (host_*.csv + peaks_host_*.log)
rsync -a --timeout=120 \
  -e "ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15" \
  --include='host_*.csv' --include='peaks_host_*.log' --exclude='*' \
  martinkittler@192.168.100.24:/Users/martinkittler/monitoring/cpuram/ "$HOSTDIR/" 2>>"$BASE/report.log" || \
  echo "$(date +%FT%T%z) report: stažení host logů selhalo (report poběží jen s VM daty)" >>"$BASE/report.log"

/usr/bin/python3 "$BASE/tydenni_report.py" --gate-workday --vm-dir "$BASE" --host-dir "$HOSTDIR" --dny 7 >>"$BASE/report.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "$CURWEEK" > "$WEEKSTAMP"   # odesláno → tenhle týden už znovu ne
fi
# rc=10 = Martin dnes neordinuje → weekstamp nezapsán, zkusí se zítra
