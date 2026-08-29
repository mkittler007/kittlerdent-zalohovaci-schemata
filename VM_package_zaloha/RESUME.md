# RESUME — kde jsme skončili (29.8.2026, před vědomým Parallels Tools restartem)

> **STAV 29.8.2026 po restartu — úkoly 1 a 2 HOTOVÉ:**
> 1. ✅ Git commit+push: commit 7688dda (VM_package_zaloha + vytizenost_CPU_RAM + notify_pojistka)
>    pushnut na origin/main. VirtioFS deadlockoval (mmap/COW při git+cp) → obešel jsem přes git plumbing
>    (write-tree/commit-tree/update-ref bez reflogu) pro commit a **push z hosta .24** nativně (github_implantaty klíč).
>    Modifikace „Retence VM macOS" byly falešné (VirtioFS stat artefakt) — strom je čistý.
> 2. ✅ Vault build: dokončen **nativně na hostu** (VM paměť → /tmp, přepsané cesty, zápis do iCloud vaultu).
>    Ověřeno: project_vytizenost_cpu_ram, feedback_notifikace_pojistka, Retence VM snapshoty & záloha — vše ve vaultu.
> **Zbývá: úkol 3 (Thunderbolt = pondělí), úkol 4 (VM RAM 52→36 GB po ~2 týdnech měření).**


> Tenhle restart dokončí Parallels Tools. **Zabije běžící Claude session ve VM i subagenta git+vault.**
> Po bootu se monitoring LaunchAgenty spustí samy (RunAtLoad), notify outbox taky. Odtud navázat.

## HOTOVO a BĚŽÍ (přežije restart)
- **Monitoring vytíženosti** host+VM á 60 s (`~/monitoring/cpuram/`), LaunchAgenty na obou strojích,
  sync VM→host→NAS `/volume1/Mac_mini_Pro_Logy`, týdenní report Po 07:30 → martin@kittler.cz. Viz `../vytizenost_CPU_RAM`.
- **notify.py pojistka**: trvalá fronta + retry navždy (`--drain`, agent `com.kittler.notify.outbox` á 5 min), `--email-to`. Viz `../notify_pojistka`.
- **První bezpečnostní kopie VM**: `/Users/martinkittler/VM_Safety/macOS_SAFETY_2026-08-29.macvm` (COW klon). Scénář A obnovy (viz OBNOVA.md) platí.
- **Parallels Tools auto-update VYPNUTÝ** (`prlctl set --tools-autoupdate off`). Tento restart je poslední „doháněcí".

## ✅ NASAZENO 29.8.2026 v noci (viz PLAN.md „NASAZENO" — autoritativní)
- Skripty na hostu `~/VM_Safety/bin/` (`config.sh` + `zaloha_vm_package.sh` + `prenos_na_wd.sh` + `prenos_na_synology.sh` + `konsolidace_snapshotu.sh`).
- **4 agenty načtené:** `com.kittler.vmpkg.cold` (06/18), `.ram` (23:00), `.wd` (23:10 denně), `.nas` (23:50 obden).
- **Interní ochrana + off-host hned:** ruční COW klon `~/VM_Safety/packages/macOS_cold_2026-08-29_2248.macvm` + jeho přenos na Synology `/volume1/VM macOS M4/VM_packages`.
- **Režim „do pondělí":** LOCAL_BASE = interní (COW), cold 2×/den retence 1, ram retence 1. Přepnutí na Thunderbolt = `config.sh` (LOCAL_BASE + RETAIN_COLD=4) + cold plist +13:00.
- **BLOKER WD:** zápis na „My Book" přes launchd = TCC „Operation not permitted" → čeká na ruční **Full Disk Access** (odblokuje i Thunderbolt). Skript gracefully skipuje + Telegram.
- **notify.py na hostu není** → alerty přes `~/.vm-backup-telegram.env` (přímý Telegram, jen chyba).
- **Staré agenty ponechány** (`vm-backup`, `vm-snapshot`, `vm-backup-wd`) jako pojistka — vypnout až po pár úspěšných bězích nového (pondělí).
- **Off-host politika:** na NAS jen noční RAM balík; intraday cold jen lokálně.

## NEDOKONČENO — udělat po restartu
1. **Git commit+push** nových složek (`vytizenost_CPU_RAM`, `notify_pojistka`, `VM_package_zaloha`) do repa
   „Zalohovací schemata" — NEPROBĚHLO (VirtioFS deadlockoval git; subagent to zkoušel, restart ho zabil).
   Až iCloud/VirtioFS povolí: `GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git -C "<repo>" add -A … && commit && push`.
2. **Vault build** (`Claude_nastavení/obsidian/build_vault.py`) — ověřit, že nové paměti zrcadlí.
3. **Pondělí (Thunderbolt 4 TB):** ověřit mount path → upravit `DEST_BASE`/`SRC_BASE` ve skriptech →
   deploy skriptů na host `/Users/martinkittler/VM_Safety/bin/` → plisty do `~/Library/LaunchAgents` → `launchctl load -w`
   → ostrý test `zaloha_vm_package.sh cold` → po 1. úspěchu vypnout stará agenty + `konsolidace_snapshotu.sh --apply`.
4. **Po ~2 týdnech měření:** snížit VM RAM 52→~36 GB (`prlctl set macOS --memsize`, VM vypnutá).

## Kontext (paměť)
[[project_vytizenost_cpu_ram]], [[feedback_notifikace_pojistka]], [[project_vm_snapshots_parallels]]. Plán+recept: `PLAN.md`, `OBNOVA.md`.
