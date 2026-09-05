# Time Machine WD — hlídač rotace

`tm_wd_rotation_watch.py` (host .24, LaunchAgent `com.kittler.tm-wd-rotation`, denně 09:30).

Zadání Martina 5.9.2026: TM na WD ("My Book") jede 1x denně, má kvótu. Až se kvóta
naplní a TM začne mazat nejstarší zálohy, hlídač NAPÍŠE Martinovi přes `notify.py`:
- kdy rotace poprvé nastala,
- od kterého data se verze maže (jaká nejstarší verze zmizela),
- kolik verzí drží + rozsah historie + volné místo.

Podle toho se pak zálohování upraví (kvóta / disk WD Backup 8 na 5 TB TM, VM jinam).

Bez root (tmutil listbackups + df + notify.py jako uživatel). Stav: `~/.tm_wd_rotation.state`.
