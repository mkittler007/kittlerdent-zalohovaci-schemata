#!/bin/bash
# Nasadí oba zálohovací skripty + LaunchAgenty na zelený iMac a (pře)načte plánovače.
# Spouštět z VM (192.168.100.82) nebo hosta — používá SSH klíč id_ed25519_macmini.
set -euo pipefail

IMAC=192.168.100.170
USER_=martinkittler
KEY="$HOME/.ssh/id_ed25519_macmini"
HERE="$(cd "$(dirname "$0")" && pwd)"
SSH=(ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$USER_@$IMAC")
L_LOCAL=com.kittler.parallels-cold-backup       # denní lokální cold záloha (12:00)
L_NAS=com.kittler.parallels-nas-monthly         # měsíční kopie na NAS (1. neděle 13:00)

echo "== složky na iMacu =="
"${SSH[@]}" 'mkdir -p "$HOME/Parallels_Backup_ordinace/backup" "$HOME/Library/LaunchAgents"'

echo "== nahrávám skripty =="
"${SSH[@]}" 'cat > "$HOME/Parallels_Backup_ordinace/parallels_cold_backup.sh" && chmod +x "$HOME/Parallels_Backup_ordinace/parallels_cold_backup.sh"' < "$HERE/parallels_cold_backup.sh"
"${SSH[@]}" 'cat > "$HOME/Parallels_Backup_ordinace/nas_monthly_sync.sh" && chmod +x "$HOME/Parallels_Backup_ordinace/nas_monthly_sync.sh"' < "$HERE/nas_monthly_sync.sh"

echo "== nahrávám plisty =="
"${SSH[@]}" 'cat > "$HOME/Library/LaunchAgents/'"$L_LOCAL"'.plist" && plutil -lint "$HOME/Library/LaunchAgents/'"$L_LOCAL"'.plist"' < "$HERE/$L_LOCAL.plist"
"${SSH[@]}" 'cat > "$HOME/Library/LaunchAgents/'"$L_NAS"'.plist" && plutil -lint "$HOME/Library/LaunchAgents/'"$L_NAS"'.plist"' < "$HERE/$L_NAS.plist"

echo "== (pře)načítám LaunchAgenty =="
for L in "$L_LOCAL" "$L_NAS"; do
  "${SSH[@]}" '
    U=$(id -u); L="'"$L"'"
    launchctl bootout gui/$U/$L 2>/dev/null || true
    launchctl bootstrap gui/$U "$HOME/Library/LaunchAgents/$L.plist"
    echo "  $L:"; launchctl print gui/$U/$L | grep -iE "state|calendar|weekday|hour" | head -3'
done

echo "== selftest lokální zálohy =="
"${SSH[@]}" '"$HOME/Parallels_Backup_ordinace/parallels_cold_backup.sh" --selftest'

cat <<TXT
HOTOVO.
  Ruční lokální záloha:  ~/Parallels_Backup_ordinace/parallels_cold_backup.sh
  Ruční kopie na NAS:    ~/Parallels_Backup_ordinace/nas_monthly_sync.sh --now
TXT
