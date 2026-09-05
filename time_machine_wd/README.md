# Time Machine WD — hlídač rotace

`tm_wd_rotation_watch.py` (host .24, LaunchAgent `com.kittler.tm-wd-rotation`, denně 09:30).

Zadání Martina 5.9.2026: TM na WD ("My Book") jede 1x denně, má kvótu. Až se kvóta
naplní a TM začne mazat nejstarší zálohy, hlídač NAPÍŠE Martinovi přes `notify.py`:
- kdy rotace poprvé nastala,
- od kterého data se verze maže (jaká nejstarší verze zmizela),
- kolik verzí drží + rozsah historie + volné místo.

Podle toho se pak zálohování upraví (kvóta / disk WD Backup 8 na 5 TB TM, VM jinam).

Bez root (tmutil listbackups + df + notify.py jako uživatel). Stav: `~/.tm_wd_rotation.state`.

## 5.9.2026 — host TM přepnut na TÝDENNÍ na 2 cíle (WD + Synology)
Rozhodnutí MK: host Time Machine 1× týdně na WD **a** 1× týdně na Synology (share `VM macOS M4`).
- **Hodinové auto VYPNUTO** (`sudo tmutil disable` + `AutoBackup=0`; verb `disableautobackup` na macOS 26 neexistuje).
- Cíle: WD `My Book` (ID CBCBA507, kvóta 3 TB) + Synology `smb://admin@192.168.100.120/VM macOS M4` (ID 4BC1116C, síťový; nativní TM funguje pod LNP, `backupd` je Apple-signed → žádný tunel).
- Spouštěče (LaunchDaemony, root): `com.kittler.tm-wd-weekly` (neděle 03:00) + `com.kittler.tm-syno-weekly` (neděle 14:00) → `tmutil startbackup --destination <ID> --block`.
- **NAS kvóta (1500 GB) nastavit až PO první nedělní záloze** (setquota vyžaduje existující sparsebundle).
- WD manuální plná záloha 5.9. 15:32 OK (baseline po resetu). Rotaci WD hlídá `com.kittler.tm-wd-rotation`.
- TODO: rozšířit hlídač rotace i na NAS cíl; nastavit NAS kvótu po 1. záloze.
