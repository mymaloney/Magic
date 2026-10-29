# Card scripts, from text to runtime

The full reference is `docs/Card-scripting-API/` (one page each for abilities, costs, targeting,
triggers, replacements, statics, restrictions). This page is the condensed version aimed at
writing a converter that turns scripts into GBA data.

## Where the data lives

| Data | Path | Size (Oct 2026 snapshot) |
|---|---|---|
| Cards | `forge-gui/res/cardsfolder/<a-z>/*.txt` (+ `upcoming/`, `rebalanced/`) | ~34,100 files, ~25 MB raw text |
| Tokens | `forge-gui/res/tokenscripts/*.txt` | ~860 files |
| Sets (rarity, collector #, booster layout) | `forge-gui/res/editions/*.txt` | ~690 files |
| Formats / ban lists | `forge-gui/res/formats/` | |
| Puzzles (board states) | `forge-gui/res/puzzle/*.pzl` | |
| Precon / AI decks | `forge-gui/res/quest/`, `res/deckgendecks/`, … | |

Loaded by `forge-core: forge/CardStorageReader` → `CardRules.Reader` → `CardDb` (inside `StaticData`).

## Line types

```
Name:Soul Warden
ManaCost:W
Types:Creature Human Cleric
PT:1/1
T:Mode$ ChangesZone | Origin$ Any | Destination$ Battlefield | ValidCard$ Creature.Other | TriggerZones$ Battlefield | Execute$ TrigGainLife | TriggerDescription$ Whenever another creature enters, you gain 1 life.
SVar:TrigGainLife:DB$ GainLife | Defined$ You | LifeAmount$ 1
Oracle:Whenever another creature enters, you gain 1 life.
```

| Prefix | Meaning | Parsed into |
|---|---|---|
| `Name`, `ManaCost`, `Types`, `PT`, `Loyalty`, `Colors`, `Oracle`, `Text` | Characteristics | `CardFace` |
| `A:` | Spell (`SP$`) or activated ability (`AB$`) | `SpellAbility` via `AbilityFactory` |
| `T:` | Triggered ability (`Mode$`) | `Trigger` via `TriggerHandler.parseTrigger` |
| `S:` | Static ability (`Mode$`) | `StaticAbility` |
| `R:` | Replacement effect (`Event$`) | `ReplacementEffect` |
| `K:` | Keyword (`K:Flying`, `K:Equip:2`, `K:Cycling:1 U`) | `KeywordInterface`, expanded by `CardFactoryUtil` |
| `SVar:Name:value` | Named variable: a sub-ability (`DB$ ...`), a number expression (`Count$...`), or an AI hint | Looked up by name from `Execute$`, `SubAbility$`, `ReplaceWith$`, amounts |
| `AI:`, `DeckHints`, `DeckNeeds`, `DeckHas` | AI / deckbuilding hints | ignore for rules |
| `AlternateMode:` + `ALTERNATE` separator | Second face (DFC, split, adventure, flip, meld) | second `CardFace` |

Parameters are `Key$ Value` pairs separated by ` | `. Chains: an ability's `SubAbility$ DBFoo`
points to `SVar:DBFoo:DB$ ...`, which can have its own `SubAbility$`.

## Mini-languages a converter must handle

1. **Valid filters** (`ValidTgts$`, `ValidCard$`, `ValidCards$`, `Affected$`): `Type.Prop+Prop,Type2`,
   e.g. `Creature.OppCtrl+nonToken`, `Card.Self`, `Creature.Other`, `Any` (= creature/player/planeswalker/battle).
   `.` starts properties, `+` ANDs them, `,` ORs alternatives. Implemented in
   `forge-game: card/CardProperty.cardHasProperty` (large switch on property names) and
   `player/PlayerProperty`.
2. **Defined** (`Defined$`): `You`, `Targeted`, `Self`, `Enchanted`, `TriggeredCard`, `ReplacedCard`,
   `Remembered`… → `AbilityUtils.getDefinedCards/getDefinedPlayers`.
3. **Amounts** (`NumDmg$`, `LifeAmount$`, `NumCards$`): literal int, `X`, or an SVar name holding
   `Count$...` / `Count$Valid Creature.YouCtrl` with math suffixes (`/Plus.1`, `/Twice`) →
   `AbilityUtils.calculateAmount` and `forge-game: forge/util/Expressions`.
4. **Costs** (`Cost$`): `T`, `Q` (untap), mana symbols, `Sac<1/Creature>`, `Discard<1/Card>`,
   `PayLife<2>`, `SubCounter<1/LOYALTY>`… → `cost/Cost`.
5. **Mana costs**: space-separated shards; `W/U` hybrid, `W/P` phyrexian, `2/W`, `X`, `C`, `S` (snow).

## What scripts actually use (frequency in `cardsfolder`)

Good input for picking the first effect set to port. Counts are occurrences, not cards.

**Effect APIs (`SP$`/`AB$`/`DB$`):** ChangeZone 6691, Pump 5053, Draw 3800, Token 3632,
PutCounter 3381, Cleanup 3037 (bookkeeping), DealDamage 2898, Mana 2546, Effect 1940,
GainLife 1816, Destroy 1565, Tap 1505, LoseLife 1224, Discard 1115, PumpAll 1059, Animate 1042,
Dig 994, Sacrifice 899, Charm 819, ChangeZoneAll 671, Mill 598, Counter 538, Untap 492,
DelayedTrigger 480, Scry 455, ChooseCard 435, DamageAll 432, …

**Keywords (`K:`):** Flying 3341, Enchant 1268, Trample 1047, Vigilance 759, Haste 688, Equip 653,
Flash 637, etbCounter 478, Reach 449, ETBReplacement 422, Menace 419, First Strike 394,
Lifelink 390, Deathtouch 356, Defender 311, Cycling 306, Kicker 239, …

**Trigger modes:** ChangesZone 7677 (ETB/dies/LTB), Phase 2403 (upkeep/end step), Attacks 1621,
SpellCast 1423, DamageDone 879, then a long tail under 250 each.

**Static modes:** Continuous 4883 (anthems, granted abilities), ReduceCost 534, CantBlockBy 364,
CantAttack 204, …

**Replacement events:** Moved 983, DamageDone 219, Untap 158, Counter 118, …

Regenerate these with:

```bash
cd forge-gui/res/cardsfolder
grep -rhoE '(SP|AB|DB)\$ ?[A-Za-z]+' . | sed -E 's/.*\$ ?//' | sort | uniq -c | sort -rn | head -40
grep -rhoE '^K:[A-Za-z ]+' . | sort | uniq -c | sort -rn | head -40
grep -rhoE '^T:Mode\$ ?[A-Za-z]+' . | sort | uniq -c | sort -rn
```

## Finding all cards that use a feature

```bash
grep -rl 'SP\$ DealDamage' forge-gui/res/cardsfolder | wc -l
grep -rlE '^K:(Flying|Trample)$' forge-gui/res/cardsfolder
```

For the set of cards in one edition, read the `[cards]` section of `forge-gui/res/editions/<Set>.txt`
(lines are `<collector#> <rarity> <Card Name> @<artist>`), then map names to files
(lowercase, spaces → `_`, punctuation removed).
