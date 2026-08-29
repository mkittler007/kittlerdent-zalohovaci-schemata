#!/bin/bash
# Nasadí zálohovací skript + LaunchAgent na zelený iMac a (pře)načte plánovač.
# Spouštět z VM (192.168.100.82) nebo hosta — používá SSH klíč id_ed25519_macmini.
set -euo pipefail

IMAC=192.168.100.170
USER_=martinkittler
KEY="$HOME/.ssh/id_ed25519_macmini"
HERE="$(cd "$(dirname "$0")" && pwd)"
SSH=(ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$USER_@$IMAC")
LABEL=com.kittler.parallels-cold-backup

echo "== vytvářím složky na iMacu =="
"${SSH[@]}" 'mkdir -p "$HOME/Parallels_Backup_ordinace/backup" "$HOME/Library/LaunchAgents"'

echo "== nahrávám skript =="
"${SSH[@]}" 'cat > "$HOME/Parallels_Backup_ordinace/parallels_cold_backup.sh" && chmod +x "$HOME/Parallels_Backup_ordinace/parallels_cold_backup.sh"' < "$HERE/parallels_cold_backup.sh"

echo "== nahrávám plist =="
"${SSH[@]}" 'cat > "$HOME/Library/LaunchAgents/'"$LABEL"'.plist" && plutil -lint "$HOME/Library/LaunchAgents/'"$LABEL"'.plist"' < "$HERE/$LABEL.plist"

echo "== (pře)načítám LaunchAgent =="
"${SSH[@]}" '
  U=$(id -u)
  launchctl bootout gui/$U/'"$LABEL"' 2>/dev/null || true
  launchctl bootstrap gui/$U "$HOME/Library/LaunchAgents/'"$LABEL"'.plist"
  launchctl print gui/$U/'"$LABEL"' | grep -iE "state|calendar" | head'

echo "== selftest =="
"${SSH[@]}" '"$HOME/Parallels_Backup_ordinace/parallels_cold_backup.sh" --selftest'

echo "HOTOVO. Ruční ostrá záloha:  ssh … '$USER_@$IMAC'  →  ~/Parallels_Backup_ordinace/parallels_cold_backup.sh"
