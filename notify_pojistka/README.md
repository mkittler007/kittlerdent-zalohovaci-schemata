# notify.py — pojistka: trvalá fronta + retry navždy

Rozšíření `~/bin/notify.py` tak, aby **žádná notifikace nezmizela**, i když v okamžiku
odeslání selžou VŠECHNY kanály (Telegram i e-mail i iMessage) — typicky **výpadek internetu,
vypnutá/uspaná VM, nedostupný SMTP**.

## Jak to funguje
1. `notify()` (i `--email-to`) zkusí doručit jako dřív (cross-kanálový fallback).
2. Když **nic neprojde**, zpráva se uloží do trvalé fronty `~/.claude/notify/outbox/`
   (JSON, přežije reboot i vypnutí). Keyované zprávy se deduplikují (stejný `--key` přepíše starší).
3. LaunchAgent **`com.kittler.notify.outbox`** volá `notify.py --drain`:
   - **při startu** (RunAtLoad → dožene backlog po zapnutí VM/hosta),
   - **každých 5 min** (StartInterval 300) → jakmile se vrátí internet, zpráva odejde.
4. Úspěch → zpráva se z fronty smaže a zaloguje se „DORUČENO po N pokusech".
   Zaseknutá > 24 h → hlasitý zápis do logu (kanály stále mrtvé).

## Platí GLOBÁLNĚ
Protože všechno chodí přes `notify.py`, retry se vztahuje **na každou existující i budoucí
notifikaci** (připomínače koncem roku, reporty, watchdogy…) — není třeba nic dopisovat zvlášť.

## Nasazení (host i VM)
- `~/bin/notify.py` — s frontou (volby `--drain`, `--email-to`).
- `~/Library/LaunchAgents/com.kittler.notify.outbox.plist` — načtený agent.
- Retry běží **na obou strojích** (host .24 i VM .82); každý drénuje svou frontu,
  host je vždy zapnutý, VM dožene backlog při dalším startu.

## Hranice (co řeší jiná vrstva)
Pokud odesílatel **vůbec neběžel** (Mac Mini i VM vypnuté v čase plánu), zajišťuje dohnání
**catch-up dispečer** + **externí hlídač ticha (dead-man's switch)**. Tahle fronta řeší případ,
kdy odesílatel běžel, ale doručení selhalo.
