# OBNOVA VM — recept „když to lehne"

> **Pokud tohle čteš v Claude appce/webu:** VM je pravděpodobně dole, Martin nemá terminálového
> Clauda. Projdi ho podle scénáře (A/B/C) níže, krok po kroku. Hesla/klíče zná Martin, nejsou tu.
>
> **Důležité:** Když je VM dole, pracuje se **přímo na hostu Mac Mini** (jeho obrazovka/klávesnice
> nebo Obrazovka na dálku), NE uvnitř VM. Vše dole se dělá na hostu.

## Co je čím (kde leží zálohy)
| Kde | Cesta | Chrání proti | Kdy vzniká |
|---|---|---|---|
| Interní disk hosta | `/Users/martinkittler/VM_Safety/macOS_SAFETY_*.macvm` | pád/špatný stav VM, omylem smazané | ruční pojistka (první: 29.8.2026) |
| Thunderbolt 4 TB | `/Volumes/Thunderbolt/VM_packages/macOS_cold_*.macvm` a `…_ram_*.macvm` | i pád interního disku | 3× denně (cold) + 1× noc (ram) — od pondělí |
| Synology (.120) | `/volume1/VM_packages` (**JEN noční `macOS_ram_*`**) | pád celého hosta | 1× noc přenos |

Balík = složka `…​.macvm` = **jeden celek** (v Finderu jedna položka). Název nese **datum a čas** —
vybírej **nejnovější PŘED tím, než nastal problém**. `cold` = studený start; `ram` = pokračuje přesně kde bylo.

## Cesty a příkazy (host)
- Parallels CLI: `/Applications/Parallels Desktop.app/Contents/MacOS/prlctl`
- Živá (rozbitá) VM je v: `/Users/martinkittler/Parallels/macOS.macvm`
- VM „macOS" má UUID `{cf7a9c8f-39b4-4691-8c25-40ebae6a0768}`

---

## SCÉNÁŘ A — VM nenaběhne / je rozbitá / omylem smazané soubory (disk hosta OK)
Nejčastější případ. Máš pojistku, klid.

1. Na hostu otevři **Terminal** (nebo Parallels Desktop appku).
2. **Neber hned pryč rozbitou VM** — jen ji odsuň stranou (kdyby byla přece jen potřeba):
   přejmenuj složku `/Users/martinkittler/Parallels/macOS.macvm` na `…​macOS_ROZBITA.macvm`.
   (V Parallels ji můžeš i jen zastavit.)
3. Vyber **nejnovější dobrý balík** (nejdřív zkus Thunderbolt `macOS_ram_*` pro „přesně kde bylo“,
   nebo `macOS_cold_*`; když Thunderbolt není, vezmi interní `VM_SAFETY_*`).
4. **Zaregistruj a spusť** ho — dvě cesty:
   - **GUI:** Parallels Desktop → *File → Open…* → vyber tu `…​.macvm` → *Otevřít* → **Start**.
   - **Terminál:** `"/Applications/Parallels Desktop.app/Contents/MacOS/prlctl" register "<cesta k balíku>.macvm"` → pak *Start* v Parallels (nebo `… start <UUID/název>`).
5. `cold` balík nabootuje čistě do stavu zálohy; `ram` balík pokračuje přesně kde byl.
6. Zkontroluj, že data jsou zpět. **Teprve pak** smaž `macOS_ROZBITA.macvm`.

## SCÉNÁŘ B — spadl interní disk hosta (host jede, ale VM bundle je pryč)
Interní pojistka je taky pryč (byla na tom disku). Sáhni pro **Thunderbolt** nebo **Synology**.

1. Připoj **Thunderbolt 4 TB** k Mac Mini.
2. Zkopíruj nejnovější balík z `/Volumes/Thunderbolt/VM_packages/…​.macvm` do `/Users/martinkittler/Parallels/`.
3. Dál jako Scénář A od kroku 4 (register → start).
4. Když není Thunderbolt: připoj se na **Synology** (login znáš) přes Finder (*Připojit k serveru*,
   `smb://192.168.100.120`) → z `/volume1/VM_packages` zkopíruj balík na Mac → register → start.

## SCÉNÁŘ C — celý Mac Mini mrtvý (jiný Mac / nový stroj)
Data jsou v balíku na Thunderboltu / Synology, jen je rozjedeš jinde.

1. Na náhradním Macu nainstaluj **Parallels Desktop**.
2. Získej balík: z **Thunderboltu** (přepoj) nebo ze **Synology** (login znáš → Finder `smb://…` →
   z `/volume1/VM_packages` stáhni `…​.macvm`).
3. Parallels → *File → Open…* → vyber balík → **Start**.
4. Pozn.: na **jiném** Macu může macOS host chtít drobné doztvrzení (jiný hardware/`macid.bin`),
   ale **data jsou celá**. Na stejném Mac Mini je to 1:1 bez řešení.

---

## Jak poznat nejnovější balík
Řadí se podle **data a času v názvu** (`macOS_cold_2026-08-29_2100.macvm`). Ber ten s nejvyšším
datem/časem, který je **před** okamžikem poruchy. Když si nejsi jistý stavem, `ram` balík tě vrátí
„přesně tam", `cold` nabootuje čistě.

## Rychlé kontakty systému (Martin zná přihlášení)
- Host Mac Mini: `192.168.100.24` · Synology NAS: `192.168.100.120` (`smb://…`, `/volume1/VM_packages`)
- Full plán a mechanismus: `PLAN.md` ve stejné složce.

## STAV k 29.8.2026
Zatím existuje **jen interní pojistka** `VM_SAFETY_2026-08-29.macvm` (Scénář A funguje).
Thunderbolt (Scénář B) + Synology přenos (Scénář C) se aktivují **v pondělí** s Thunderbolt diskem —
do té doby platí jen Scénář A.
