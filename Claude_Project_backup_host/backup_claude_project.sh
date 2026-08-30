#!/bin/bash
# Zálohuje iCloud Claude_Project NATIVNĚ na hostu Mac Mini (.24) na Synology .120.
# Přesunuto z VM 30.8.2026: čtení iCloudu přes VirtioFS z VM bylo pomalé (iCloud
# materializace + VirtioFS overhead → běh 3 h+ místo ~30 min). Na hostu jsou soubory
# nativní = mnohem rychleji. LaunchAgent cz.kittlerdent.backup_claude_project (host), 08:00 a 20:00.
# Autentizace: SSH klíč ~/.ssh/synology_backup. Retry 3x + --partial kvůli případným
# iCloud materializacím / chvilkovým výpadkům. Kód 0 i 23 (částečně) = OK.
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

RSYNC=/opt/homebrew/bin/rsync            # GNU rsync 3.4.4 (NE Apple openrsync 2.6.9)
SYNOLOGY_HOST="192.168.100.120"
SYNOLOGY_USER="admin"
SYNOLOGY_KEY="$HOME/.ssh/synology_backup"
SYNOLOGY_DEST="/volume1/Claude_Project/"
SOURCE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Claude_Project/"
LOG="$HOME/Library/Logs/backup_claude_project.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }
mkdir -p "$(dirname "$LOG")"

if [ ! -d "$SOURCE" ]; then
    log "CHYBA: zdroj '$SOURCE' neexistuje (iCloud nepřipojen?)"
    exit 1
fi

log "=== START backup_claude_project (host) ==="
log "rsync SSH: $SOURCE -> $SYNOLOGY_USER@$SYNOLOGY_HOST:$SYNOLOGY_DEST"

ATTEMPTS=3
RC=1
for i in $(seq 1 $ATTEMPTS); do
    log "rsync pokus $i/$ATTEMPTS"
    "$RSYNC" -rlt --stats --size-only --ignore-errors --partial --timeout=600 \
        -e "ssh -i $SYNOLOGY_KEY -o StrictHostKeyChecking=no -o BatchMode=yes" \
        --exclude='*.icloud' \
        --exclude='.DS_Store' \
        --exclude='Icon?' \
        "$SOURCE" "$SYNOLOGY_USER@$SYNOLOGY_HOST:$SYNOLOGY_DEST" >> "$LOG" 2>&1
    RC=$?
    if [ $RC -eq 0 ] || [ $RC -eq 23 ]; then break; fi
    log "pokus $i selhal (kód $RC), za 30 s zkusím znovu"
    sleep 30
done

if [ $RC -eq 0 ] || [ $RC -eq 23 ]; then
    log "Záloha OK (exit $RC — případné iCloud stuby přeskočeny)."
    RC=0
else
    log "CHYBA: rsync skončil s kódem $RC (po $ATTEMPTS pokusech)"
fi

log "=== END backup_claude_project ==="
exit $RC
