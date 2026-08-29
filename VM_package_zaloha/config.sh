# Sdílená konfigurace VM package zálohy (BĚŽÍ NA HOSTU .24). Source všechny skripty.
# Přepínač režimu interní↔Thunderbolt = JEDINÁ proměnná LOCAL_BASE + retence níže.
UUID="{cf7a9c8f-39b4-4691-8c25-40ebae6a0768}"      # VM "macOS"
PRL="/Applications/Parallels Desktop.app/Contents/MacOS/prlctl"
SRC="/Users/martinkittler/Parallels/macOS.macvm"

# ── REŽIM ÚLOŽIŠTĚ LOKÁLNÍCH BALÍKŮ ─────────────────────────────────────────
# DO PONDĚLÍ: interní disk (COW klon = instantní, ~0 místa; NEchrání proti pádu disku).
# OD PONDĚLÍ (Thunderbolt): zakomentuj interní řádek, odkomentuj Thunderbolt + zvedni RETAIN_COLD na 4.
LOCAL_BASE="/Users/martinkittler/VM_Safety/packages"    # interní (do pondělí)
#LOCAL_BASE="/Volumes/Thunderbolt/VM_packages"          # Thunderbolt (od pondělí)

# ── RETENCE (počet balíků) ──────────────────────────────────────────────────
# DO PONDĚLÍ (malý interní disk, cold 2×/den): cold=1, ram=1.
# OD PONDĚLÍ (Thunderbolt, cold 3×/den):        cold=4, ram=1.
RETAIN_COLD=1      # pondělí → 4
RETAIN_RAM=1

# ── Pojistka volného místa na interním disku (platí jen když LOCAL_BASE = interní) ─
MIN_FREE_GB=40     # když volno < tohle, ořízne nejstarší cold balík dřív, než udělá nový

# ── WD (USB) — denně, retence 5. Runner (bash) má Full Disk Access.
# POZOR: „My Book" je disk Time Machine → macOS tam ZAKAZUJE zápis (i s FDA). Proto se použije
# SAMOSTATNÁ APFS volume „VM_WD" ve stejném kontejneru (NENÍ TM, sdílí místo s TM, zápis OK).
# Vytvořeno 29.8.: diskutil apfs addVolume disk7 APFS VM_WD (spouštět přes launchd-bash s FDA). ─
WD_BASE="/Volumes/VM_WD/VM_packages"
RETAIN_WD=5

# ── Synology (.120) — OBDEN, retence 4. Cíl v existujícím zapisovatelném share. ─
SYNO_USER="admin"; SYNO_HOST="192.168.100.120"; SYNO_KEY="$HOME/.ssh/synology_backup"
NAS_BASE="/volume1/VM macOS M4/VM_packages"
RETAIN_SYNO=4

LOG_DIR="/Users/martinkittler/VM_Safety"
TG_ENV="$HOME/.vm-backup-telegram.env"
RSYNC="/opt/homebrew/bin/rsync"; [ -x "$RSYNC" ] || RSYNC="rsync"
SSH_OPTS="-i $SYNO_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=15"

# Telegram alert JEN při chybě (tvůj funkční env; notify.py na hostu není).
notify() {
  [ -f "$TG_ENV" ] || return 0
  . "$TG_ENV" 2>/dev/null
  curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" -d text="$1" >/dev/null 2>&1
}
