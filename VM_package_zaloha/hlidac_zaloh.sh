#!/bin/bash
# Hlídač VM package záloh (BĚŽÍ NA HOSTU .24, KAŽDOU HODINU přes launchd StartInterval).
# LOGIKA (přání MK): žádný okamžitý poplach. Když vrstva neproběhne (je stará nad práh):
#   1) 1. detekce → jen zapíš „výpadek", NIC víc (bez retry, bez notifikace).
#   2) 2 h po výpadku → RETRY (kickstart agenta).
#   3) 1 h po retry, když je pořád vadné → TEPRVE Telegram (1×/24h) a dál to každé kolo zkouší znovu.
# Když vrstva zase OK → stav se vyčistí. Chybějícího agenta znovu nahraje.
# POZOR: WD (VM_WD) čte jen launchd proces (FDA) — testuj přes `launchctl kickstart`, ne přes SSH.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/config.sh"
LOG="$LOG_DIR/hlidac.log"; STATE="$LOG_DIR/hlidac.state"
ts(){ date +%FT%T%z; }; log(){ echo "$(ts) $*" >> "$LOG"; }
U=$(id -u); now=$(date +%s); touch "$STATE"
RETRY_AFTER=7200     # 2 h po výpadku zkus znovu
ALERT_AFTER=3600     # 1 h po retry (ať má čas doběhnout) → teprve alert

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
    clr "${n}_fail"; clr "${n}_retry"; clr "${n}_alert"; log "OK $n (${age}h <= ${thr}h)"; return
  fi
  local fs rt al
  fs=$(get "${n}_fail")
  if [ -z "$fs" ]; then
    set_ "${n}_fail" "$now"; log "VÝPADEK $n (${age}h > ${thr}h) — retry za 2 h, zatím BEZ poplachu"; return
  fi
  rt=$(get "${n}_retry")
  if [ -z "$rt" ]; then
    if [ $(( now - fs )) -ge "$RETRY_AFTER" ]; then
      log "RETRY $n (2 h po výpadku) → kickstart $ag"; launchctl kickstart -k gui/$U/com.kittler.vmpkg.$ag 2>>"$LOG"; set_ "${n}_retry" "$now"
    else
      log "$n vadné, čekám na 2h okno pro retry (uplynulo $(( (now-fs)/60 )) min)"
    fi
    return
  fi
  if [ $(( now - rt )) -ge "$ALERT_AFTER" ]; then
    al=$(get "${n}_alert")
    if [ -z "$al" ] || [ $(( now - al )) -gt 86400 ]; then
      notify "VM záloha: vrstva '$n' selhala i po opakovaném pokusu (2 h po výpadku, stáří ${age}h). Zkontroluj host/NAS."
      set_ "${n}_alert" "$now"; log "ALERT $n (selhalo i po retry)"
    else
      log "$n stále vadné → další retry (alert už dřív poslán)"; launchctl kickstart -k gui/$U/com.kittler.vmpkg.$ag 2>>"$LOG"; set_ "${n}_retry" "$now"
    fi
  else
    log "$n: retry běží/čeká na dokončení ($(( (now-rt)/60 )) min)"
  fi
}

check cold "$(age_local "$LOCAL_BASE" 'macOS_cold_*.macvm')" 15 cold
check ram  "$(age_local "$LOCAL_BASE" 'macOS_ram_*.macvm')"  27 ram
check syno "$(age_nas 'macOS_cold_*.macvm')" 27 nas

# WD (VM_WD): když disk odpojen → nelze zálohovat, přeskoč bez poplachu; jinak normální fail→retry→alert
WDVOL="$(dirname "$WD_BASE")"
if [ ! -d "$WDVOL" ]; then
  log "WD ($WDVOL) nepřipojen — přeskočeno (bez poplachu)"; clr wd_fail; clr wd_retry; clr wd_alert
else
  check wd "$(age_local "$WD_BASE" 'macOS_ram_*.macvm')" 27 wd
fi
log "hlídač hotov."
