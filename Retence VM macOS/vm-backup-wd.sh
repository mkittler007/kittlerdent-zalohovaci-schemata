#!/bin/bash
# vm-backup-wd.sh — verzovaná záloha Parallels VM na lokální USB/Thunderbolt disk (Western Digital "My Book").
# BĚŽÍ NA HOSTU (Mac Mini M4 Pro), NE uvnitř VM. LaunchAgent com.kittler.vm-backup-wd, denně 04:00 (gate: OBDEN).
#
# Tok (stejná osvědčená logika jako vm-backup-synology.sh):
#   1) OBDEN gate — spustí se jen každý druhý den (parita epoch-dne)
#   2) ověří, že cílový disk je připojený a ZAPISOVATELNÝ (jinak graceful konec + 1× Telegram)
#   3) suspend VM (jen pár sekund)
#   4) cp -c → instantní APFS copy-on-write klon do lokální staging složky (sdílí bloky, ~0 B navíc)
#   5) resume VM → VM hned zpět pro práci
#   6) rsync klonu na WD s --link-dest na PŘEDCHOZÍ kopii → nezměněné 128GB .hds bandy se HARDLINKUJÍ
#      (verzované kopie, ale místo žerou jen změněné bandy)
#   7) smazat lokální klon
#   8) retence: smazat kopie starší než 7 dní
#
# Telegram JEN při problému (chyba, disk nedostupný/nezapisovatelný, klon se nesmazal). Při úspěchu MLČÍ.
#
# POZN. TCC: zápis na externí svazek vyžaduje, aby proces, který launchd spouští, měl Full Disk Access.
#   Bez FDA macOS vrací "Operation not permitted" (EPERM) — skript to pozná a gracefully skončí (Telegram 1×).
#   FDA se uděluje ručně v Nastavení → Soukromí a zabezpečení → Plný přístup k disku (nelze přes SSH kvůli SIP).
#
# CÍL: přepínatelný jednou proměnnou TARGET_BASE — v pondělí po připojení Thunderbolt disku stačí změnit cestu.
# bash 3 kompatibilní.
set -uo pipefail

# ---------- KONFIGURACE ----------
VM_UUID="{cf7a9c8f-39b4-4691-8c25-40ebae6a0768}"
VM_NAME="macOS"
VM_SRC="/Users/martinkittler/Parallels/macOS.macvm"
STAGE_DIR="/Users/martinkittler/Parallels_backup_tmp"        # lokální staging (MIMO iCloud), sdílí bloky přes cp -c
OWNER="martinkittler"

# >>> JEDINÁ PROMĚNNÁ K PŘEPNUTÍ NA THUNDERBOLT (pondělí) <<<
TARGET_VOL="/Volumes/My Book 1"                              # připojený svazek (mountpoint)
TARGET_BASE="$TARGET_VOL/screenshoty VM MacOS"              # cílová složka pro verzované kopie VM
# <<< ------------------------------------------------------ >>>

RETENTION_DAYS=7                                             # držet kopie z posledních 7 dní
EVERY_N_DAYS=2                                               # OBDEN

RSYNC="/opt/homebrew/bin/rsync"                             # rsync 3.x (kvůli -S sparse + spolehlivosti)
LOG="$HOME/Library/Logs/vm-backup-wd.log"
NOTIFY_STATE="$HOME/Library/Logs/vm-backup-wd-notify.state" # aby se stejný problém neposílal opakovaně
STAMP="$(date +%Y-%m-%d_%H%M)"
CLONE="$STAGE_DIR/macOS_wd_$STAMP.macvm"
DEST="$TARGET_BASE/macOS_$STAMP.macvm"
DEST_PARTIAL="$TARGET_BASE/macOS_$STAMP.macvm.partial"
LOCK="/tmp/vm-backup-wd.lock"
NOW=$(date +%s)
EPOCH_DAY=$(( NOW / 86400 ))
# ---------------------------------

mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() { echo "$(date '+%F %T'): $*" >> "$LOG"; }
hms() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

# --- Telegram: token+chat_id z prvního existujícího .env ---
TG_TOKEN=""; TG_CHAT=""
for tgenv in \
    "$HOME/.vm-backup-telegram.env" \
    "$HOME/.claude/channels/telegram/.env" \
    "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Claude_Project/Retence VM macOS/.telegram.env"; do
    if [ -f "$tgenv" ]; then
        TG_TOKEN=$(awk -F= '/^TELEGRAM_BOT_TOKEN=/{print $2}' "$tgenv" 2>/dev/null | tr -d ' "')
        TG_CHAT=$(awk -F= '/^TELEGRAM_CHAT_ID=/{print $2}' "$tgenv" 2>/dev/null | tr -d ' "')
        [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] && break
    fi
done
notify_telegram() {
    [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] || return 0
    curl -s -m 15 "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$TG_CHAT" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=$1" >/dev/null 2>&1
}
# pošle Telegram jen když se stejný "kód" problému neposlal už dnes (proti spamu obden)
notify_once() {
    local code="$1" text="$2" today
    today=$(date +%Y-%m-%d)
    if [ -f "$NOTIFY_STATE" ] && grep -qxF "$code $today" "$NOTIFY_STATE"; then
        return 0
    fi
    echo "$code $today" > "$NOTIFY_STATE"
    notify_telegram "$text"
}
fail() {
    log "CHYBA: $1"
    notify_telegram "🔴 <b>WD záloha VM selhala</b>
$1

Host: Mac Mini M4 Pro
Čas: $(date '+%d.%m.%Y %H:%M')"
    exit 1
}

# --- lock proti překryvu ---
if ! mkdir "$LOCK" 2>/dev/null; then
    log "Jiný běh už probíhá ($LOCK) — končím."
    exit 0
fi
cleanup() { rmdir "$LOCK" 2>/dev/null; }
trap cleanup EXIT

# ================= 1) OBDEN gate =================
if [ $(( EPOCH_DAY % EVERY_N_DAYS )) -ne 0 ]; then
    log "OBDEN gate: dnes (epoch-den $EPOCH_DAY) se neběží. Konec."
    exit 0
fi

log "==== START WD zálohy VM (obden, retence ${RETENTION_DAYS}d) ===="

# ================= 2) cíl dostupný a zapisovatelný? =================
if ! mount | grep -q " $TARGET_VOL "; then
    log "Cílový disk '$TARGET_VOL' NENÍ připojen — přeskakuji (disk odpojen?)."
    notify_once "unmounted" "🟠 <b>WD záloha VM přeskočena</b>
Disk '$TARGET_VOL' není připojen. Připoj ho, nebo mě v pondělí přesměruj na Thunderbolt.
Čas: $(date '+%d.%m.%Y %H:%M')"
    exit 0
fi
# test zápisu (odhalí TCC / Full Disk Access blok)
if ! mkdir -p "$TARGET_BASE" 2>/dev/null || ! touch "$TARGET_BASE/.wtest" 2>/dev/null; then
    log "Zápis na '$TARGET_BASE' selhal (nejspíš chybí Full Disk Access / TCC) — přeskakuji."
    notify_once "tcc" "🟠 <b>WD záloha VM zablokována (TCC)</b>
Zápis na '$TARGET_VOL' selhal — proces nemá <b>Full Disk Access</b>.
Uděl FDA v Nastavení → Soukromí a zabezpečení → Plný přístup k disku (ideálně v pondělí u stroje).
Čas: $(date '+%d.%m.%Y %H:%M')"
    exit 0
fi
rm -f "$TARGET_BASE/.wtest" 2>/dev/null

# --- volné místo na cíli (jen do logu) ---
DEST_AVAIL="$(df -h "$TARGET_VOL" 2>/dev/null | awk 'NR==2{print $4}')"
log "Cíl OK: '$TARGET_BASE' (volno na svazku: ${DEST_AVAIL:-?})"

# ================= 3) prlctl =================
PRLCTL=""
for p in \
    "/usr/local/bin/prlctl" \
    "/usr/bin/prlctl" \
    "/Applications/Parallels Desktop.app/Contents/MacOS/prlctl" \
    "$(command -v prlctl 2>/dev/null)"; do
    [ -n "$p" ] && [ -x "$p" ] && PRLCTL="$p" && break
done
[ -z "$PRLCTL" ] && fail "prlctl nenalezen"
run_prl() { if [ "$(id -u)" = "0" ]; then sudo -u "$OWNER" "$PRLCTL" "$@"; else "$PRLCTL" "$@"; fi; }
run_as_owner() { if [ "$(id -u)" = "0" ]; then sudo -u "$OWNER" "$@"; else "$@"; fi; }

[ -e "$VM_SRC" ] || fail "zdroj $VM_SRC neexistuje"
[ -x "$RSYNC" ] || fail "rsync 3.x nenalezen na $RSYNC"
mkdir -p "$STAGE_DIR"

# --- úklid osiřelých klonů z minula ---
for old in "$STAGE_DIR"/macOS_wd_*.macvm; do
    [ -e "$old" ] && { log "Mažu osiřelý staging klon: $old"; rm -rf "$old"; }
done

STATE="$(run_prl status "$VM_UUID" 2>/dev/null | awk '{print $NF}')"
log "Stav VM: ${STATE:-neznámý}"

# ================= 3) suspend =================
SUSP_START=$(date +%s)
if [ "$STATE" = "running" ]; then
    log "Suspend VM…"
    run_prl suspend "$VM_UUID" >> "$LOG" 2>&1
    sleep 6
fi

# ================= 4) instantní APFS klon =================
CLONE_START=$(date +%s)
log "Klonuji $VM_SRC → $CLONE (cp -c)…"
if ! run_as_owner cp -c -R "$VM_SRC" "$CLONE"; then
    log "cp -c selhal — zkouším cp -R"
    rm -rf "$CLONE"
    if ! run_as_owner cp -R "$VM_SRC" "$CLONE"; then
        [ "$STATE" = "running" ] && run_prl resume "$VM_UUID" >> "$LOG" 2>&1
        fail "klon VM selhal (cp -c i cp -R). VM obnovena (resume)."
    fi
fi
CLONE_END=$(date +%s)
CLONE_SECS=$(( CLONE_END - CLONE_START ))
DOWNTIME_SECS=$(( CLONE_END - SUSP_START ))

# ================= 5) resume VM hned =================
if [ "$STATE" = "running" ]; then
    log "Resume VM…"
    run_prl resume "$VM_UUID" >> "$LOG" 2>&1 || log "POZOR: resume selhal — zkontroluj VM ručně!"
fi
log "KLON hotov za $(hms $CLONE_SECS). Výpadek VM ~$(hms $DOWNTIME_SECS)."

# ================= 6) rsync na WD s --link-dest (hardlink dedup) =================
# najdi nejnovější existující kopii jako referenci pro hardlinky
PREV="$(ls -1dt "$TARGET_BASE/"macOS_*.macvm 2>/dev/null | grep -v '\.partial$' | head -n 1)"
LINKDEST_OPT=""
if [ -n "$PREV" ] && [ -d "$PREV" ]; then
    LINKDEST_OPT="--link-dest=$PREV"
    log "Reference pro hardlinky: $PREV"
else
    log "Žádná předchozí kopie — první plná záloha."
fi

# úklid zbytkového .partial
rm -rf "$DEST_PARTIAL" 2>/dev/null

RSYNC_START=$(date +%s)
log "rsync klonu → $DEST_PARTIAL …"
run_as_owner "$RSYNC" -rlt -S --delete $LINKDEST_OPT \
    --human-readable --stats \
    "$CLONE/" "$DEST_PARTIAL/" >> "$LOG" 2>&1
RC=$?
if [ $RC -ne 0 ]; then
    log "rsync selhal (rc=$RC). Ponechávám klon $CLONE pro diagnostiku."
    fail "rsync na WD selhal (rc=$RC)."
fi
mv "$DEST_PARTIAL" "$DEST"
RSYNC_END=$(date +%s)
RSYNC_SECS=$(( RSYNC_END - RSYNC_START ))
DEST_SIZE="$(du -sh "$DEST" 2>/dev/null | awk '{print $1}')"
log "WD kopie hotová za $(hms $RSYNC_SECS) (velikost dle du: $DEST_SIZE): $DEST"

# ================= 7) smaž lokální klon =================
rm -rf "$CLONE"
if [ -e "$CLONE" ]; then
    log "VAROVÁNÍ — staging klon $CLONE se NEsmazal!"
    notify_telegram "⚠️ <b>WD záloha VM — klon se nesmazal</b>
Lokální $CLONE zůstal na hostu. Smaž ho ručně."
else
    log "Staging klon smazán: OK"
fi

# ================= 8) retence: smaž kopie starší než RETENTION_DAYS =================
DELETED=0
find "$TARGET_BASE" -maxdepth 1 -type d -name 'macOS_*.macvm' -mtime +"$RETENTION_DAYS" -print 2>/dev/null | while read -r old; do
    log "Retence — mažu (>$RETENTION_DAYS dní): $old"
    rm -rf "$old"
done
# taky ukliď osiřelé .partial
find "$TARGET_BASE" -maxdepth 1 -type d -name 'macOS_*.macvm.partial' -mtime +1 -exec rm -rf {} \; 2>/dev/null

KEPT="$(ls -1d "$TARGET_BASE/"macOS_*.macvm 2>/dev/null | grep -v '\.partial$' | grep -c .)"
TOTAL_SIZE="$(du -sh "$TARGET_BASE" 2>/dev/null | awk '{print $1}')"
log "==== HOTOVO | klon $(hms $CLONE_SECS) / rsync $(hms $RSYNC_SECS) / výpadek VM ~$(hms $DOWNTIME_SECS) | kopií na WD: $KEPT | celkem: ${TOTAL_SIZE:-?} ===="
