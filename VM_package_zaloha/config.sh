# Sdílená konfigurace VM package zálohy (BĚŽÍ NA HOSTU .24). Source všechny skripty.
# Přepínač režimu interní↔Thunderbolt = JEDINÁ proměnná LOCAL_BASE + retence níže.
# VARIANTA 2 (MK 22.9.2026): RAM balík žije JEN na Thunderboltu (rychlý rollback zdravé VM);
#   WD i Synology dostávají POUZE COLD (spolehlivá obnova čistým bootem). Důvod: ram (suspend)
#   ze zatuhlé VM je nespolehlivý resume-zdroj (viz zámrz 22.9.) → off-disk pojistka jen cold.
UUID="{7c4a8e80-613c-4fa3-86a3-516b32b15508}"   # cutover 22.9.
PRL="/Applications/Parallels Desktop.app/Contents/MacOS/prlctl"
SRC="/Volumes/KD_Ext4T/macOS.macvm"   # cutover 22.9.: zpět na kanonickou cestu

# ── REŽIM ÚLOŽIŠTĚ LOKÁLNÍCH BALÍKŮ ─────────────────────────────────────────
#LOCAL_BASE="/Users/martinkittler/VM_Safety/packages"    # interní (legacy)
LOCAL_BASE="/Volumes/KD_Ext4T/VM_packages"          # Thunderbolt SSD (aktivni od 31.8.)

# ── RETENCE (počet balíků) — cílové schéma MK 5.9.2026 ──────────────────────
# Thunderbolt: cold 06/13/18 (drž 4), ram JEN NOČNÍ 23:00 (drž 1) — MK 22.9.2026 (dřív 2× denně).
RETAIN_COLD=4      # Thunderbolt cold (06/13/18)
RETAIN_RAM=1       # Thunderbolt ram: jen poslední noční (23:00)

# ── Pojistka volného místa na interním disku (platí jen když LOCAL_BASE = interní) ─
MIN_FREE_GB=40     # když volno < tohle, ořízne nejstarší cold balík dřív, než udělá nový

# ── WD (USB) — 1× denně v noci (~23:10). Runner (bash) má Full Disk Access. ──
# VARIANTA 2: kopíruje POUZE POSLEDNÍ COLD (drž 3 dny). RAM se na WD už NEkopíruje (jen Thunderbolt).
# POZOR: „My Book" je disk Time Machine → zápis zakázán i s FDA. Proto SAMOSTATNÁ APFS volume „VM_WD"
# ve stejném kontejneru (NENÍ TM, sdílí místo s TM, zápis OK).
WD_BASE="/Volumes/VM_WD/VM_packages"
RETAIN_WD_COLD=3   # WD: poslední cold z Thunderu, drž 3 dny
RETAIN_WD_RAM=0    # VARIANTA 2: WD ram vypnut (ram jen na Thunderboltu)

# ── Synology (.120) — off-host. VARIANTA 2: POUZE COLD KAŽDOU NOC (~23:50, drž 3). Ram vypnut. ──
SYNO_USER="admin"; SYNO_HOST="192.168.100.120"; SYNO_KEY="$HOME/.ssh/synology_backup"
NAS_BASE="/volume1/VM macOS M4/VM_packages"
RETAIN_SYNO_COLD=3 # Synology: intradenní cold nočně, drž 3 dny
RETAIN_SYNO_RAM=0  # VARIANTA 2: Synology ram vypnut (ram jen na Thunderboltu)

LOG_DIR="/Users/martinkittler/VM_Safety"
TG_ENV="$HOME/.vm-backup-telegram.env"
RSYNC="/opt/homebrew/bin/rsync"; [ -x "$RSYNC" ] || RSYNC="rsync"
SSH_OPTS="-i $SYNO_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=15"

# Alert JEN při chybě. POJISTKA: primárně notify.py (cross-kanál Telegram→e-mail→iMessage
# + trvalá outbox fronta, retry navždy; nasazen na hostu 31.8.2026, viz ../notify_pojistka/).
# Fallback = přímý Telegram, když notify.py chybí (zachová funkčnost i bez pojistky).
notify() {
  if [ -x "$HOME/bin/notify.py" ]; then
    /usr/bin/python3 "$HOME/bin/notify.py" --to martin \
      --subject "VM záloha" --body "$1" --key vm_backup >/dev/null 2>&1 && return 0
  fi
  [ -f "$TG_ENV" ] || return 0
  . "$TG_ENV" 2>/dev/null
  curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" -d text="$1" >/dev/null 2>&1
}
