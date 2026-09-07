#!/bin/bash
# Monitor vytíženosti RAM/CPU — GUEST (VM macOS, .82)
# Hlavní zdroj pro dimenzování RAM: skutečný working set guestu.
# Spouští LaunchAgent com.kittler.moncpuram.vm každých 60 s.
set -u
BASE="$HOME/monitoring/cpuram"
mkdir -p "$BASE"
PHASE_FILE="$BASE/phase"
DAY=$(date +%F)
LOG="$BASE/vm_${DAY}.csv"

ts=$(date +%FT%T%z)
phase=$(cat "$PHASE_FILE" 2>/dev/null || echo run)

ps=$(vm_stat | sed -n 's/.*page size of \([0-9][0-9]*\) bytes.*/\1/p'); ps=${ps:-16384}
read F A I S W CO <<EOF
$(vm_stat | awk '
  /Pages free/{gsub(/[.]/,"",$3);f=$3}
  /Pages active/{gsub(/[.]/,"",$3);a=$3}
  /Pages inactive/{gsub(/[.]/,"",$3);i=$3}
  /Pages speculative/{gsub(/[.]/,"",$3);s=$3}
  /Pages wired down/{gsub(/[.]/,"",$4);w=$4}
  /occupied by compressor/{gsub(/[.]/,"",$5);c=$5}
  END{print f+0,a+0,i+0,s+0,w+0,c+0}')
EOF
mb(){ awk -v p="$1" -v ps="$ps" 'BEGIN{printf "%.0f", p*ps/1048576}'; }
total_mb=$(sysctl -n hw.memsize | awk '{printf "%.0f",$1/1048576}')
free_mb=$(mb "$F"); active_mb=$(mb "$A"); inactive_mb=$(mb "$I")
spec_mb=$(mb "$S"); wired_mb=$(mb "$W"); comp_mb=$(mb "$CO")
used_mb=$((active_mb + wired_mb + comp_mb))
swap_used=$(sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p'); swap_used=${swap_used:-0}
pressure=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null); pressure=${pressure:-}
load1=$(sysctl -n vm.loadavg | awk '{print $2}')

[ -f "$LOG" ] || echo "ts,phase,total_mb,free_mb,active_mb,inactive_mb,speculative_mb,wired_mb,compressed_mb,used_mb,swap_used_mb,pressure,load1" > "$LOG"
echo "$ts,$phase,$total_mb,$free_mb,$active_mb,$inactive_mb,$spec_mb,$wired_mb,$comp_mb,$used_mb,$swap_used,$pressure,$load1" >> "$LOG"

# ── zachyt viníky při REÁLNÉM přetížení (pro týdenní report) ──
# Stejně jako u hostu: swap>100M ani pressure "warn" (=2) NENÍ přetížení. Za tíseň bereme
# kriticky plnou RAM (>=90 % přidělené), critical pressure (=4), nebo load1 > počet jader.
ncpu=$(sysctl -n hw.logicalcpu 2>/dev/null); ncpu=${ncpu:-8}
upct=0; [ "$total_mb" -gt 0 ] && upct=$((used_mb * 100 / total_mb))
reasons=""
[ "$upct" -ge 90 ] && reasons="RAM${upct}%"
[ -n "$pressure" ] && [ "$pressure" -ge 4 ] 2>/dev/null && reasons="$reasons pressure$pressure"
awk -v l="${load1:-0}" -v c="$ncpu" 'BEGIN{exit !(l>c)}' && reasons="$reasons load${load1}>${ncpu}c"
reasons=$(echo "$reasons" | sed 's/^ *//')
if [ -n "$reasons" ]; then
  PLOG="$BASE/peaks_vm_${DAY}.log"
  # RSS vč. mapované/sdílené paměti (orientační); procesy nad fyzickou RAM vynecháme.
  tm=$(ps -axo rss,comm -m 2>/dev/null | awk -v tot="$total_mb" 'NR>1{mb=$1/1024; if(mb<=tot){n=$2;sub(/.*\//,"",n);printf "%s(%dMB) ",n,mb; if(++k>=5)exit}}')
  tc=$(ps -axo %cpu,comm -r 2>/dev/null | awk 'NR>1&&NR<=6{n=$2;sub(/.*\//,"",n);printf "%s(%.0f%%) ",n,$1}')
  echo "$ts|$reasons|used=${used_mb}MB free=${free_mb}MB swap=${swap_used}M|MEM: $tm|CPU: $tc" >> "$PLOG"
fi

# retence 90 dní
find "$BASE" -maxdepth 1 \( -name 'vm_*.csv' -o -name 'peaks_vm_*.log' \) -type f -mtime +90 -delete 2>/dev/null
