#!/bin/bash
# Monitor vytíženosti RAM/CPU — HOST (Mac Mini M4 Pro, .24, 64 GB)
# Hlídá zdraví hosta při běhu VM (free %, memory pressure, swap) + RSS VM procesu.
# Spouští LaunchAgent com.kittler.moncpuram.host každých 60 s.
set -u
BASE="$HOME/monitoring/cpuram"
mkdir -p "$BASE"
PHASE_FILE="$BASE/phase"
DAY=$(date +%F)
LOG="$BASE/host_${DAY}.csv"

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
free_mb=$(mb "$F"); wired_mb=$(mb "$W"); comp_mb=$(mb "$CO"); active_mb=$(mb "$A")
used_mb=$((active_mb + wired_mb + comp_mb))
free_pct=$(memory_pressure 2>/dev/null | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p'); free_pct=${free_pct:-}
swap_used=$(sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p'); swap_used=${swap_used:-0}
pressure=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null); pressure=${pressure:-}
load1=$(sysctl -n vm.loadavg | awk '{print $2}')
# RSS VM procesu (na Apple Silicon jen orientační — guest RAM je mapovaná mimo RSS)
vm_rss_mb=$(ps -axo rss,comm | awk '/prl_macvm_app/{s+=$1} END{printf "%.0f", s/1024}')

[ -f "$LOG" ] || echo "ts,phase,total_mb,free_mb,active_mb,used_mb,wired_mb,compressed_mb,free_pct,swap_used_mb,pressure,load1,vm_proc_rss_mb" > "$LOG"
echo "$ts,$phase,$total_mb,$free_mb,$active_mb,$used_mb,$wired_mb,$comp_mb,$free_pct,$swap_used,$pressure,$load1,$vm_rss_mb" >> "$LOG"

# ── zachyt viníky při REÁLNÉM přetížení (pro týdenní report) ──
# Pozor: na Apple Siliconu je swap oportunistický (medián ~4.5 GB i při volné RAM) a
# memory_pressure "warn" (pressure=2) je běžný provozní stav běžící VM — ANI JEDNO není
# přetížení (dříve swap>100M falešně označoval ~92 % vzorků). Za přetížení bereme jen
# skutečnou tíseň: kriticky málo volné paměti, critical pressure, nebo load1 > počet jader.
ncpu=$(sysctl -n hw.logicalcpu 2>/dev/null); ncpu=${ncpu:-10}
reasons=""
[ -n "$free_pct" ] && [ "$free_pct" -lt 20 ] 2>/dev/null && reasons="free${free_pct}%"
[ -n "$pressure" ] && [ "$pressure" -ge 4 ] 2>/dev/null && reasons="$reasons pressure$pressure"
awk -v l="${load1:-0}" -v c="$ncpu" 'BEGIN{exit !(l>c)}' && reasons="$reasons load${load1}>${ncpu}c"
reasons=$(echo "$reasons" | sed 's/^ *//')
if [ -n "$reasons" ]; then
  PLOG="$BASE/peaks_host_${DAY}.log"
  # RSS vč. mapované/sdílené paměti (orientační). Procesy s RSS > fyzické RAM jsou
  # mmap-artefakt (VM framework mapuje guest RAM jako RSS) → vynecháme, jinak zkreslí žebříček.
  tm=$(ps -axo rss,comm -m 2>/dev/null | awk -v tot="$total_mb" 'NR>1{mb=$1/1024; if(mb<=tot){n=$2;sub(/.*\//,"",n);printf "%s(%dMB) ",n,mb; if(++k>=5)exit}}')
  tc=$(ps -axo %cpu,comm -r 2>/dev/null | awk 'NR>1&&NR<=6{n=$2;sub(/.*\//,"",n);printf "%s(%.0f%%) ",n,$1}')
  echo "$ts|$reasons|free=${free_pct}% used=${used_mb}MB swap=${swap_used}M|MEM: $tm|CPU: $tc" >> "$PLOG"
fi

# retence 90 dní
find "$BASE" -maxdepth 1 \( -name 'host_*.csv' -o -name 'peaks_host_*.log' \) -type f -mtime +90 -delete 2>/dev/null
