#!/bin/bash
# TM na WD "My Book" -> kvóta 3 TB, cadence HODINOVĚ (zbytek kontejneru ~3 TB pro VM_WD).
# Rozhodnutí Martina 5.9.2026: 3 TB TM, zbytek VM, vše na připojeném WD, hodinové TM, pak vyhodnotit.
# Spustit NA HOSTU (Mac Mini .24) jako root:  sudo bash ~/bin/setup_tm_wd_quota3.sh
set -e
DEST_ID="CBCBA507-5AD3-4913-BA19-F93B2858E185"   # My Book (z tmutil destinationinfo)

echo "[1/2] Nastavuji kvótu Time Machine na 3 TB (3000 GB)..."
tmutil setquota "$DEST_ID" 3000

echo "[2/2] Kontrola hodinových automatických záloh (výchozí macOS, má být 1)..."
# Pozn.: verb 'enableautobackup' na novějším macOS neexistuje; auto se řídí klíčem
# AutoBackup v /Library/Preferences/com.apple.TimeMachine (1 = hodinově zapnuto).
# Případné vypnutí: 'sudo tmutil disableautobackup'; zapnutí zpět přes GUI Nastavení > TM.

echo "HOTOVO. Kontrola:"
tmutil destinationinfo | grep -iE "Name|Quota"
echo "Hodinové auto (1 = zapnuto):"
defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2>/dev/null || true
