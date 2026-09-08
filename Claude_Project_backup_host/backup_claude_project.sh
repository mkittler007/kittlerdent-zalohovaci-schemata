#!/bin/bash
# Zálohuje iCloud Claude_Project NATIVNĚ na hostu Mac Mini (.24) na Synology .120.
# Přesunuto z VM 30.8.2026: čtení iCloudu přes VirtioFS z VM bylo pomalé (iCloud
# materializace + VirtioFS overhead → běh 3 h+ místo ~30 min). Na hostu jsou soubory
# nativní = mnohem rychleji. LaunchAgent cz.kittlerdent.backup_claude_project (host), 08:00 a 20:00.
# Autentizace: SSH klíč ~/.ssh/synology_backup. Retry 3x + --partial kvůli případným
# iCloud materializacím / chvilkovým výpadkům. Kód 0 i 23 (částečně) = OK.
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

# POZOR: macOS 26 Local Network Privacy blokuje Homebrew rsync (third-party binárka) přístup
# na LAN, když běží z launchd (headless, bez GUI promptu) → connect() vrací EHOSTUNREACH
# ("No route to host"). Apple podepsaný /usr/bin/rsync (openrsync protocol 29 na macOS 26 =
# plná podpora -rlt/--stats/--size-only/--partial/--timeout/--exclude, ověřeno real-run) je
# LNP-povolený. Proto ZDE (launchd) NE Homebrew rsync. Historie 4.9.2026.
RSYNC=/usr/bin/rsync                      # Apple openrsync (LNP-safe pod launchd); Homebrew rsync padá EHOSTUNREACH
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

# --- Materializace iCloud "dataless" souborů (fix 8.9.2026) ---
# iCloud "Optimalizace úložiště" evictuje soubory na dataless (moderní macOS BEZ .icloud
# přípony, proto je exclude nezachytí). Apple openrsync na dataless souboru přes mmap
# deadlockne ("mmap: Resource deadlock avoided", EDEADLK) a shodí CELÝ běh (kód 10).
# Před rsyncem je proto stáhneme čtením (cat = blokující, spolehlivé). Detekce find -flags
# +dataless. Historie: 2 selhání za sebou kvůli 95 dataless dokladům v Účetnictví/07_2026.
log "Kontrola dataless iCloud souborů..."
DATALESS_N=$(find "$SOURCE" -flags +dataless -type f 2>/dev/null | wc -l | tr -d " ")
if [ "$DATALESS_N" -gt 0 ]; then
    log "  nalezeno $DATALESS_N dataless souborů, materializuji ctenim..."
    find "$SOURCE" -flags +dataless -type f -print0 2>/dev/null | while IFS= read -r -d "" f; do cat "$f" >/dev/null 2>&1; done
    REMAIN=$(find "$SOURCE" -flags +dataless -type f 2>/dev/null | wc -l | tr -d " ")
    log "  materializace hotová (zbývá dataless: $REMAIN)"
fi
# --- konec materializace ---

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
