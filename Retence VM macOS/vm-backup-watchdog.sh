#!/bin/bash
# vm-backup-watchdog.sh — ranní kontrola, že v noci proběhla úspěšná záloha VM.
# BĚŽÍ NA HOSTU, LaunchAgent com.kittler.vm-backup-watchdog v 08:00.
# Když poslední úspěšná záloha (řádek HOTOVO v logu) je starší než MAX_AGE_HOURS,
# pošle Telegram. Jinak mlčí. Řeší případ "noční záloha vůbec neproběhla"
# (Mac byl vypnutý, launchd nespustil, skript umřel před logováním atd.).
set -uo pipefail

LOG="$HOME/Library/Logs/vm-backup-synology.log"
WLOG="$HOME/Library/Logs/vm-backup-watchdog.log"
MAX_AGE_HOURS=190   # TYDENNI rezim (VM zaloha so 20:30, beh ~20h): normalni spicka stari ~160h tesne pred dokoncenim sobotniho behu; 190h = normal projde, vynechana sobota alertuje do ~dne

mkdir -p "$(dirname "$WLOG")" 2>/dev/null
wlog() { echo "$(date '+%F %T'): $*" >> "$WLOG"; }

# --- Telegram (stejný zdroj tokenu jako hlavní skript) ---
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

NOW=$(date +%s)

# poslední úspěšná záloha = poslední řádek HOTOVO; timestamp "YYYY-MM-DD HH:MM:SS"
LAST=$(grep 'HOTOVO' "$LOG" 2>/dev/null | tail -1 | cut -d: -f1-3)
if [ -z "$LAST" ]; then
    wlog "V logu není žádná úspěšná záloha → alert"
    notify_telegram "🔴 <b>Záloha VM neproběhla</b>
V logu není žádná úspěšná noční záloha. Zkontroluj skript/NAS."
    exit 0
fi

LAST_EPOCH=$(date -j -f '%Y-%m-%d %H:%M:%S' "$LAST" +%s 2>/dev/null)
if [ -z "$LAST_EPOCH" ]; then
    wlog "Nepodařilo se naparsovat čas '$LAST' — přeskakuji."
    exit 0
fi

AGE_H=$(( (NOW - LAST_EPOCH) / 3600 ))
if [ "$AGE_H" -ge "$MAX_AGE_HOURS" ]; then
    wlog "Poslední úspěšná záloha před ${AGE_H} h ($LAST) → alert"
    notify_telegram "🔴 <b>Záloha VM neproběhla</b>
Poslední úspěšná byla před ${AGE_H} h ($LAST).
Noční záloha na Synology zřejmě neběžela — zkontroluj."
else
    wlog "OK — poslední úspěšná záloha před ${AGE_H} h ($LAST)"
fi

# --- Drift-check: ostrý skript na hostu vs poslední commitnutá verze (git) ---
# Režim B: host = zdroj pravdy. Hash naposledy synchronizované verze je v
# ~/bin/.vm-backup-synced.md5 (aktualizuje ho Claude při každém sync→commit→push).
# iCloud se ZÁMĚRNĚ neporovnává (lag/eviction dělal falešné poplachy).
# Když se aktuální skript liší od zaznamenaného hashe → změna nebyla commitnutá.
HASHFILE="$HOME/bin/.vm-backup-synced.md5"
if [ -f "$HASHFILE" ]; then
    DRIFT=""
    for f in vm-backup-synology.sh vm-backup-watchdog.sh vm-backup-run.sh; do
        live="$HOME/bin/$f"; [ -f "$live" ] || continue
        rec=$(awk -v n="$f" '$2==n{print $1}' "$HASHFILE")
        [ -n "$rec" ] || continue
        [ "$(md5 -q "$live" 2>/dev/null)" != "$rec" ] && DRIFT="$DRIFT $f"
    done
    if [ -n "$DRIFT" ]; then
        wlog "DRIFT: skripty se liší od commitnuté verze:$DRIFT"
        notify_telegram "🟠 <b>VM backup skript nesynchronizovaný s gitem</b>
Na hostu se liší od commitnuté verze:$DRIFT
Změna nebyla pushnutá do repa kittlerdent-zalohovaci-schemata — řekni Claude „sync zálohovací skripty\"."
    else
        wlog "Drift-check OK — skripty == commitnutá verze"
    fi
else
    wlog "Drift-check: chybí baseline $HASHFILE — přeskočeno"
fi
