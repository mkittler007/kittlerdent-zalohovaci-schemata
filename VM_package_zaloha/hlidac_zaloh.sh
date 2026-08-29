#!/bin/bash
# Hlídač VM package záloh (BĚŽÍ NA HOSTU .24, 2×/den 07:15 + 19:15).
# Logika: pro každou vrstvu zjisti stáří nejnovějšího balíku. Když je STARŠÍ než práh:
#   1) poprvé → 1× retry (kickstart agenta),  2) když je i po retry stále staré → Telegram (1×/24h).
# WD zvlášť: bez Full Disk Access je to známý bloker → jen info 1×/24h, ne retry-smyčka.
# Navíc: chybějící agent (vypadlý z launchd) znovu nahraje.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/config.sh"
LOG="$LOG_DIR/hlidac.log"; STATE="$LOG_DIR/hlidac.state"
ts(){ date +%FT%T%z; }; log(){ echo "$(ts) $*" >> "$LOG"; }
U=$(id -u); now=$(date +%s); touch "$STATE"

get(){ grep "^$1 " "$STATE" 2>/dev/null | tail -1 | awk '{print $2}'; }
set_(){ grep -v "^$1 " "$STATE" > "$STATE.t" 2>/dev/null; echo "$1 $2" >> "$STATE.t"; mv "$STATE.t" "$STATE"; }
clr(){ grep -v "^$1 " "$STATE" > "$STATE.t" 2>/dev/null; mv "$STATE.t" "$STATE" 2>/dev/null; }

age_local(){ local p; p=$(ls -1dt "$1"/$2 2>/dev/null | head -1); [ -n "$p" ] || { echo 9999; return; }
  echo $(( (now - $(stat -f %m "$p")) / 3600 )); }
age_nas(){ local m; m=$(ssh $SSH_OPTS "$SYNO_USER@$SYNO_HOST" "p=\$(ls -1dt \"$NAS_BASE\"/$1 2>/dev/null | head -1); [ -n \"\$p\" ] && stat -c %Y \"\$p\"" 2>/dev/null)
  [ -n "$m" ] || { echo 9999; return; }; echo $(( (now - m) / 3600 )); }

# chybějící agent znovu nahraj
for a in cold ram wd nas hlidac; do
  launchctl list 2>/dev/null | grep -q "com.kittler.vmpkg.$a" || \
    { launchctl bootstrap gui/$U ~/Library/LaunchAgents/com.kittler.vmpkg.$a.plist 2>/dev/null && log "agent $a znovu nahrán"; }
done

# $1=jmeno $2=stáří_h $3=práh_h $4=retry_agent
check(){ local n="$1" age="$2" thr="$3" ag="$4"
  if [ "$age" -le "$thr" ]; then
    [ -n "$(get ${n}_retry)" ] && clr "${n}_retry"; [ -n "$(get ${n}_alert)" ] && clr "${n}_alert"
    log "OK $n (${age}h <= ${thr}h)"; return
  fi
  local rt; rt=$(get "${n}_retry")
  if [ -z "$rt" ] || [ $(( now - rt )) -gt 43200 ]; then
    log "POZOR $n staré ${age}h > ${thr}h -> retry ($ag)"
    launchctl kickstart -k gui/$U/com.kittler.vmpkg.$ag 2>>"$LOG"
    set_ "${n}_retry" "$now"
  else
    local al; al=$(get "${n}_alert")
    if [ -z "$al" ] || [ $(( now - al )) -gt 86400 ]; then
      notify "VM záloha: vrstva '$n' NEPROBĚHLA ani po retry (stáří ${age}h). Zkontroluj host/NAS."
      set_ "${n}_alert" "$now"; log "ALERT $n (${age}h, retry nepomohl)"
    else log "$n stále staré ${age}h (alert už poslán)"; fi
  fi
}

check cold "$(age_local "$LOCAL_BASE" 'macOS_cold_*.macvm')" 15 cold
check ram  "$(age_local "$LOCAL_BASE" 'macOS_ram_*.macvm')"  27 ram
check syno "$(age_nas 'macOS_ram_*.macvm')" 51 nas

# WD: bez FDA je to známý bloker (info 1×/24h), jinak normální check+retry
WDVOL="$(dirname "$WD_BASE")"
if [ -d "$WDVOL" ] && touch "$WDVOL/.vmpkg_wt" 2>/dev/null; then
  rm -f "$WDVOL/.vmpkg_wt"; [ -n "$(get wd_fda)" ] && clr wd_fda
  check wd "$(age_local "$WD_BASE" 'macOS_ram_*.macvm')" 27 wd
else
  al=$(get wd_fda)
  if [ -z "$al" ] || [ $(( now - al )) -gt 86400 ]; then
    notify "VM záloha WD: chybí Full Disk Access → kopie na WD neběží. Uděl v System Settings → Soukromí a zabezpečení → Plný přístup k disku (/bin/bash)."
    set_ wd_fda "$now"; log "WD: FDA chybí (info 1x/24h)"
  else log "WD: FDA chybí (už hlášeno)"; fi
fi
log "hlídač hotov."
