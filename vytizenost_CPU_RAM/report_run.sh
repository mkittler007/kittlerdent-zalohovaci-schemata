#!/bin/bash
# Běží ve VM (.82), pondělí ráno. Přitáhne host logy přes SSH (VM->host funguje),
# pak spustí týdenní report, který e-mailem přes notify.py pošle výsledek na martin@kittler.cz.
set -u
BASE="$HOME/monitoring/cpuram"
HOSTDIR="$HOME/monitoring/cpuram_host"
KEY="$HOME/.ssh/id_ed25519_macmini"
mkdir -p "$HOSTDIR"

# stáhni host logy (host_*.csv + peaks_host_*.log)
rsync -a --timeout=120 \
  -e "ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15" \
  --include='host_*.csv' --include='peaks_host_*.log' --exclude='*' \
  martinkittler@192.168.100.24:/Users/martinkittler/monitoring/cpuram/ "$HOSTDIR/" 2>>"$BASE/report.log" || \
  echo "$(date +%FT%T%z) report: stažení host logů selhalo (report poběží jen s VM daty)" >>"$BASE/report.log"

/usr/bin/python3 "$BASE/tydenni_report.py" --vm-dir "$BASE" --host-dir "$HOSTDIR" --dny 7 >>"$BASE/report.log" 2>&1
