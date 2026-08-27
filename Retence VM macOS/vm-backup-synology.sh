#!/bin/bash
# vm-backup-synology.sh — noční 1:1 záloha Parallels VM na Synology přes lokální APFS klon
# BĚŽÍ NA HOSTU (Mac Mini M4 Pro), NE uvnitř VM. LaunchAgent com.kittler.vm-backup, 00:00.
#
# Tok:
#   1) suspend VM (jen pár sekund)
#   2) cp -c  → instantní copy-on-write klon do lokální staging složky (MIMO iCloud)
#   3) resume VM  → VM hned zpět pro práci
#   4) rsync klonu na Synology PŘES SSH (na pozadí, VM už zase běží) — s resumem a max 5 pokusy
#   5) po úspěchu smazat klon + ověřit smazání
#   6) retence: 3 nejnovějších + 1 kotevní kopie (~10 dní), zbytek smazat
#
# Telegram JEN při problému: chyba běhu, klon se nesmazal, nebo přebytek kopií na NASu.
# Při normálním úspěchu MLČÍ. „Noční záloha neproběhla" hlídá zvlášť vm-backup-watchdog.sh (08:00).
# Do logu se měří: doba klonu, doba přenosu na Synology, výpadek VM, velikosti, kontrola smazání klonu.
# Pojistky: kopíruje se konsistentní suspend-stav; kořenový snapshot se NIKDY nemaže (snapshoty neřešíme).
#
# PŘENOS: rsync 3.x přes SSH (NE SMB/ditto). SMB se během 5–7 h přenosu rozpadal (I/O error).
#         rsync --partial --inplace umí navázat (resume) po výpadku; opakuje se až MAX_RETRY×.
# bash 3 kompatibilní.
set -uo pipefail

# ---------- KONFIGURACE ----------
VM_UUID="{cf7a9c8f-39b4-4691-8c25-40ebae6a0768}"
VM_NAME="macOS"
VM_SRC="/Users/martinkittler/Parallels/macOS.macvm"
STAGE_DIR="/Users/martinkittler/Parallels_backup_tmp"   # lokální staging, MIMO iCloud!
OWNER="martinkittler"

SYNO_HOST="192.168.100.120"
SYNO_SSH_USER="admin"
SYNO_KEY="$HOME/.ssh/synology_backup"                    # bezheslový klíč na admin@Synology
SYNO_PATH="/volume1/VM macOS M4"                         # cílová složka na Synology (filesystémová cesta)
RSYNC="/opt/homebrew/bin/rsync"                          # rsync 3.x (Apple openrsync neumí --partial/--inplace)
REMOTE_RSYNC="/usr/bin/rsync"                            # rsync na Synology (výchozí DSM 3.1.2; přepíše se níže na Entware /opt/bin/rsync když je)
SPARSE_FLAG=""                                           # -S (sparse) jen s Entware rsync ≥3.2.4 (DSM 3.1.2 neumí -S+--inplace); nastaví se po ověření SSH
SSH_OPTS="-i $SYNO_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=15"
MAX_RETRY=5                                              # počet pokusů rsync (mezi pokusy resume)
RETRY_WAIT=30                                            # s mezi pokusy

KEEP_RECENT=2                 # kolik nejnovějších kopií vždy držet
LONG_INTERVAL_DAYS=10         # kotevní kopie se obměňuje po tolika dnech

LOG="$HOME/Library/Logs/vm-backup-synology.log"
LT_STATE="$HOME/Library/Logs/vm-backup-longterm.txt"
STAMP="$(date +%Y-%m-%d_%H%M)"
CLONE="$STAGE_DIR/macOS_$STAMP.macvm"
REMOTE_FINAL="$SYNO_PATH/macOS_$STAMP.macvm"
REMOTE_PARTIAL="$SYNO_PATH/macOS_$STAMP.macvm.partial"
LOCK="/tmp/vm-backup-synology.lock"
NOW=$(date +%s)
LONG_INTERVAL=$(( LONG_INTERVAL_DAYS * 86400 ))
# ---------------------------------

mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() { echo "$(date '+%F %T'): $*" >> "$LOG"; }
hms() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

# --- Telegram: token+chat_id z prvního existujícího .env (host-lokální, VM, nebo sdílený iCloud) ---
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
fail() {   # log + Telegram + konec
    log "CHYBA: $1"
    notify_telegram "🔴 <b>Záloha VM selhala</b>
$1

Host: Mac Mini M4 Pro
Čas: $(date '+%d.%m.%Y %H:%M')"
    exit 1
}

# --- lock proti překryvu běhů ---
if ! mkdir "$LOCK" 2>/dev/null; then
    log "Jiný běh už probíhá ($LOCK) — končím."
    exit 0
fi
cleanup() { rmdir "$LOCK" 2>/dev/null; }
trap cleanup EXIT

log "==== START zálohy VM → Synology (rsync/SSH) ===="

# --- prlctl (hledá i v Parallels.app) ---
PRLCTL=""
for p in \
    "/usr/local/bin/prlctl" \
    "/usr/bin/prlctl" \
    "/Applications/Parallels Desktop.app/Contents/MacOS/prlctl" \
    "$(command -v prlctl 2>/dev/null)"; do
    [ -n "$p" ] && [ -x "$p" ] && PRLCTL="$p" && break
done
[ -z "$PRLCTL" ] && fail "prlctl nenalezen (Parallels nainstalován? běžíš na hostu?)"
log "prlctl: $PRLCTL"

run_prl() {
    if [ "$(id -u)" = "0" ]; then sudo -u "$OWNER" "$PRLCTL" "$@"; else "$PRLCTL" "$@"; fi
}
run_as_owner() {
    if [ "$(id -u)" = "0" ]; then sudo -u "$OWNER" "$@"; else "$@"; fi
}
run_ssh() {   # spustí příkaz na Synology přes SSH (jako owner kvůli klíči)
    run_as_owner ssh $SSH_OPTS "$SYNO_SSH_USER@$SYNO_HOST" "$@"
}

[ -e "$VM_SRC" ] || fail "zdroj $VM_SRC neexistuje"
[ -x "$RSYNC" ] || fail "rsync 3.x nenalezen na $RSYNC (brew install rsync)"
mkdir -p "$STAGE_DIR"

# --- úklid případných osiřelých klonů z minula ---
for old in "$STAGE_DIR"/macOS_*.macvm; do
    [ -e "$old" ] && { log "Mažu osiřelý staging klon: $old"; rm -rf "$old"; }
done

# --- zjisti stav VM ---
STATE="$(run_prl status "$VM_UUID" 2>/dev/null | awk '{print $NF}')"
log "Stav VM: ${STATE:-neznámý}"

# ================= 1) suspend =================
SUSP_START=$NOW
if [ "$STATE" = "running" ]; then
    log "Suspend VM…"
    run_prl suspend "$VM_UUID" >> "$LOG" 2>&1
    sleep 6
fi

# ================= 2) instantní APFS klon =================
CLONE_START=$(date +%s)
log "Klonuji $VM_SRC → $CLONE (cp -c)…"
if ! run_as_owner cp -c -R "$VM_SRC" "$CLONE"; then
    log "cp -c selhal — zkouším normální cp -R (pomalejší)"
    rm -rf "$CLONE"
    if ! run_as_owner cp -R "$VM_SRC" "$CLONE"; then
        [ "$STATE" = "running" ] && run_prl resume "$VM_UUID" >> "$LOG" 2>&1
        fail "klon VM selhal (cp -c i cp -R). VM byla obnovena (resume)."
    fi
fi
CLONE_END=$(date +%s)
CLONE_SECS=$(( CLONE_END - CLONE_START ))
DOWNTIME_SECS=$(( CLONE_END - SUSP_START ))

# ================= 3) resume VM hned =================
if [ "$STATE" = "running" ]; then
    log "Resume VM…"
    run_prl resume "$VM_UUID" >> "$LOG" 2>&1 || log "POZOR: resume selhal — zkontroluj VM ručně!"
fi
CLONE_SIZE="$(du -sh "$CLONE" 2>/dev/null | awk '{print $1}')"
log "KLON hotov za $(hms $CLONE_SECS) (velikost $CLONE_SIZE). Výpadek VM (suspend→resume) ~$(hms $DOWNTIME_SECS)."

# ================= 4) ověř SSH dostupnost Synology =================
ensure_ssh() {
    run_ssh "test -d \"$SYNO_PATH\"" >/dev/null 2>&1 && return 0
    return 1
}
if ! ensure_ssh; then
    fail "Synology ($SYNO_HOST) přes SSH nedostupný nebo chybí složka '$SYNO_PATH' — zkontroluj NAS/klíč. Lokální klon ponechán v $CLONE pro pozdější přenos."
fi

# Volba rsync na NASu: Entware /opt/bin/rsync (≥3.2.4) umí sparse (-S) + --inplace →
# poloviční objem kopie. Když chybí (např. po rebootu než boot-task připojí /opt), fallback
# na DSM rsync 3.1.2 BEZ -S, ať se záloha NIKDY nerozbije. Viz [[reference_nas_zalohy]].
if run_ssh "/opt/bin/rsync --version >/dev/null 2>&1" >/dev/null 2>&1; then
    REMOTE_RSYNC="/opt/bin/rsync"; SPARSE_FLAG="-S"
    log "NAS rsync: Entware /opt/bin/rsync — sparse -S ZAP (poloviční objem)"
else
    REMOTE_RSYNC="/usr/bin/rsync"; SPARSE_FLAG=""
    log "NAS rsync: DSM /usr/bin/rsync — sparse VYP (fallback, /opt/bin/rsync na NASu chybí)"
fi

# ================= 5) rsync klonu na Synology přes SSH (resume + retry) =================
log "Úklid zbytkových .partial na NASu…"
run_ssh "rm -rf \"$SYNO_PATH/\"macOS_*.macvm.partial" 2>/dev/null

copy_to_nas() {
    local attempt rc
    for attempt in $(seq 1 "$MAX_RETRY"); do
        log "rsync pokus $attempt/$MAX_RETRY → $REMOTE_PARTIAL (resume)…"
        run_as_owner "$RSYNC" -rlt -s $SPARSE_FLAG --partial --inplace --delete \
            --rsync-path="$REMOTE_RSYNC" \
            --human-readable --stats \
            -e "ssh $SSH_OPTS" \
            "$CLONE/" "$SYNO_SSH_USER@$SYNO_HOST:$REMOTE_PARTIAL/" >> "$LOG" 2>&1
        rc=$?
        [ $rc -eq 0 ] && { log "rsync pokus $attempt OK."; return 0; }
        log "rsync pokus $attempt selhal (rc=$rc) — čekám ${RETRY_WAIT}s, pak resume…"
        sleep "$RETRY_WAIT"
    done
    return 1
}

RSYNC_START=$(date +%s)
log "Kopíruji klon → $REMOTE_FINAL (rsync/SSH)…"
if copy_to_nas; then
    run_ssh "rm -rf \"$REMOTE_FINAL\" && mv \"$REMOTE_PARTIAL\" \"$REMOTE_FINAL\""
    RSYNC_END=$(date +%s)
    RSYNC_SECS=$(( RSYNC_END - RSYNC_START ))
    DEST_SIZE="$(run_ssh "du -sh \"$REMOTE_FINAL\"" 2>/dev/null | awk '{print $1}')"
    log "SYNOLOGY kopie hotová za $(hms $RSYNC_SECS) (velikost $DEST_SIZE): $REMOTE_FINAL"

    rm -rf "$CLONE"
    if [ -e "$CLONE" ]; then
        log "VAROVÁNÍ — staging klon $CLONE se NEsmazal, smaž ručně!"
        notify_telegram "⚠️ <b>Záloha VM — klon se nesmazal</b>
Lokální $CLONE zůstal na hostu (žere místo). Smaž ho ručně."
    else
        log "Staging klon smazán: OK ($CLONE)"
    fi
else
    fail "rsync na Synology selhal po $MAX_RETRY pokusech. Lokální klon ponechán v $CLONE, částečná kopie v $REMOTE_PARTIAL (příště naváže)."
fi

# ================= 6) retence: 3 nejnovějších + 1 kotevní (přes SSH) =================
ALL=$(run_ssh "ls -1dt \"$SYNO_PATH/\"macOS_*.macvm 2>/dev/null" | sed 's#.*/##')
N=$(printf '%s\n' "$ALL" | grep -c .)
RECENT=$(printf '%s\n' "$ALL" | head -n "$KEEP_RECENT")

LT_NAME=""; LT_EPOCH=0
if [ -f "$LT_STATE" ]; then
    LT_NAME=$(awk '{print $1}' "$LT_STATE")
    LT_EPOCH=$(awk '{print $2}' "$LT_STATE"); [ -z "$LT_EPOCH" ] && LT_EPOCH=0
fi
if [ -n "$LT_NAME" ] && ! printf '%s\n' "$ALL" | grep -qxF "$LT_NAME"; then
    LT_NAME=""; LT_EPOCH=0
fi

AGE=$(( NOW - LT_EPOCH ))
if [ "$N" -ge 2 ] && { [ -z "$LT_NAME" ] || [ "$AGE" -ge "$LONG_INTERVAL" ]; }; then
    NEW_LT=$(printf '%s\n' "$RECENT" | tail -n 1)
    if [ -n "$NEW_LT" ]; then
        echo "$NEW_LT $NOW" > "$LT_STATE"
        log "Rotace kotevní kopie: '${LT_NAME:-žádná}' -> '$NEW_LT'"
        LT_NAME="$NEW_LT"
    fi
fi

KEEP_SET=$(printf '%s\n%s\n' "$RECENT" "$LT_NAME" | grep . | sort -u)
log "Držím ($(printf '%s' "$KEEP_SET" | grep -c .)): $(printf '%s ' $KEEP_SET) | kotva: ${LT_NAME:-—}"

printf '%s\n' "$ALL" | grep . | while read -r name; do
    if ! printf '%s\n' "$KEEP_SET" | grep -qxF "$name"; then
        log "Retence — mažu: $name"
        run_ssh "rm -rf \"$SYNO_PATH/$name\""
    fi
done

# kontrola: počet kopií na NASu nesmí přesáhnout limit (3 nejnovějších + 1 kotva)
MAXKEEP=$(( KEEP_RECENT + 1 ))
FINAL_N=$(run_ssh "ls -1d \"$SYNO_PATH/\"macOS_*.macvm 2>/dev/null" | grep -c .)
if [ "$FINAL_N" -gt "$MAXKEEP" ]; then
    log "VAROVÁNÍ — na NASu je $FINAL_N kopií (limit $MAXKEEP) — retence možná selhala."
    notify_telegram "⚠️ <b>Záloha VM — retence</b>
Na Synology je $FINAL_N kopií (limit $MAXKEEP). Mazání starých možná selhalo — zkontroluj NAS."
fi

log "==== HOTOVO | klon $(hms $CLONE_SECS) / syno $(hms ${RSYNC_SECS:-0}) / výpadek VM ~$(hms $DOWNTIME_SECS) | kopií na NAS: $FINAL_N ===="
