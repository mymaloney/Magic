# Porting plan: Forge rules → Lua on Solarus

Status: **engine target is Solarus 2.1 (Lua). The quest is based on the Solarus starter quest.
The rules engine plays complete games with creatures, evergreen keywords, enters/dies triggers,
and targeted instants/sorceries (110 of 335 cards); see `solarus/cardpool/support_report.md`.** Update this file as decisions are made and record them in the
"Decisions log" at the bottom so later sessions don't re-litigate them.

## Target: Solarus

[Solarus](https://www.solarus-games.org) is a GPL-3.0 C++ engine for 2D action-RPGs (the
Zelda: A Link to the Past style). Games ("quests") are Lua scripts plus data files; the engine
supplies maps, tilesets, sprites/animations, entities, dialogs, savegames, audio, menus and input.
That covers the non-Magic parts of the design (overworld, towns, NPCs, progression), so this
project only writes:

1. a **Magic rules engine in pure Lua**, ported from `forge-game`, and
2. a **duel screen** (a Solarus menu) plus glue between the overworld and duels.

Lua runtime: Solarus runs quests on **LuaJIT (Lua 5.1 semantics)**. Write Lua 5.1: no `//`
integer division, no 5.3 bitwise operators, no `utf8` library. LuaJIT is available in the
cloud container (`apt-get install -y luajit`), so pure-Lua code can be tested there.

There are no memory or ROM limits worth designing around, which means the engine can mirror
Forge's structure closely and the cards can be read straight from Forge's scripts.

## Architecture

```
solarus/
  quest/data/                    the Solarus quest (open this folder in Solarus Quest Editor)
    quest.dat, project_db.dat    quest properties and resource list (edited by the Quest Editor)
    main.lua                     entry point (Solarus starter quest; menus from scripts/menus/initial_menus_config.lua)
    cards/                       Forge scripts for the pool, copied verbatim + pool.lua index  [generated]
    scripts/mtg/                 rules engine, PURE LUA: no sol.* calls
    scripts/menus/               duel screen and other menus (uses sol.*)
    maps/ sprites/ tilesets/ …   overworld content, created with the Quest Editor
  cardpool/                      card lists + generated feature reports
  tools/                         PC-side Python: pool report, card sync
  tests/run.lua                  headless tests: luajit solarus/tests/run.lua
```

### Rules that keep this workable

- **`scripts/mtg/` never calls `sol.*`.** All engine input/output goes through tables and
  callbacks. This keeps the rules engine testable under plain LuaJIT and lets the UI change
  freely.
- **Decisions go through a controller interface**, the Lua equivalent of Forge's
  `PlayerController`: `choose_spell_to_play`, `choose_targets`, `declare_attackers`,
  `declare_blockers`, `choose_cards`, `confirm`, … One implementation drives the duel menu for
  the human, another is the AI, and tests use a scripted one. Because the duel menu is
  event-driven and the engine loop is not, run the engine loop in a **Lua coroutine** that
  yields whenever it needs a human decision. The menu resumes it with the answer.
- **Engine events for the UI** (card moved, damage dealt, life changed, …) are emitted as
  plain tables, like Forge's `GameEvent*`. The duel menu animates them; the engine doesn't wait for the animations.

### Card data

Cards are read at runtime from Forge's own script text:
`tools/sync_cards.py <pool>` copies the pool's scripts into `quest/data/cards/` and writes
`cards/pool.lua`. `scripts/mtg/script_parser.lua` turns a script into tables (faces, abilities,
triggers, statics, replacements, keywords, SVars), following Forge's parsing rules
(`FileSection.parseToMap`). Re-run the sync after editing the pool or merging upstream Forge.

The engine then interprets those tables: an `SP$`/`AB$`/`DB$` value selects an effect function
(the Lua counterpart of `ApiType` → `*Effect.java`), `Mode$` selects trigger/static handlers,
`Event$` selects replacement handlers, and `K:` keywords expand into abilities the way
`CardFactoryUtil` does. Unsupported features must fail loudly: report "card X uses
unsupported Y" at load time rather than half-working in a duel.

## The engine so far (`quest/data/scripts/mtg/`)

| Module | Does | Forge reference |
|---|---|---|
| `script_parser.lua` | Forge script text → tables | `CardRules.Reader`, `FileSection.parseToMap` |
| `card_db.lua` | Definitions (types, P/T, keywords, mana abilities) + **support check**; `make_deck` refuses unsupported cards | `CardFactory`, `CardFactoryUtil` |
| `card.lua` | Card instance state, characteristic getters (where layers will hook in) | `Card` |
| `mana.lua` | Cost parsing, mana value, auto-pay (backtracking colored shards, then generic) | `ManaCostParser`, `ComputerUtilMana` |
| `game.lua` | Zones, moves, draw, life, damage batches, SBA (life, decking, lethal/0 toughness, deathtouch, legend rule), legal actions, casting, stack, priority loop, turn structure | `Game`, `GameAction`, `PhaseHandler`, `MagicStack`, `PlaySpellAbility` |
| `keywords.lua` | The set of keywords the engine implements | `keyword/Keyword` |
| `filter.lua` | `Valid*$` filter language (types, `.YouCtrl`, `+nonLand`, `cmcLE2`, `powerGE4`, ...) | `CardProperty`, `PlayerProperty` |
| `abilities.lua` | Ability chains from `SP$`/`DB$` params (+ `SubAbility$`), targeting (candidates, legality, hexproof), `Defined$`, resolution with fizzling | `AbilityFactory`, `AbilityUtils`, `TargetRestrictions` |
| `effects.lua` | Effects by API with a parameter whitelist each: Draw, GainLife, LoseLife, DealDamage, Discard, Destroy, DestroyAll, ChangeZone, Pump, PumpAll, Tap, Untap, Mill, Counter | `ability/effects/*Effect` |
| `expr.lua` | SVar amounts and conditions: numbers, `X`, `Count$Valid…`, `Count$Morbid.a.b`, `Count$AttackersDeclared`, `ThisTurnCast_…`, `PlayerCountPlayers$…`, `TriggerCount$…`, math suffixes (`/Twice`, `/Plus.N`); `CheckSVar`/`IsPresent`-style compares | `AbilityUtils.calculateAmount`, `xCount`, `doXMath` |
| `triggers.lua` | Trigger modes ChangesZone, Attacks, AttackersDeclared, Blocks, AttackerBlocked, Phase, SpellCast, Drawn, LifeGained, LifeLost, Taps, ManaExpend; intervening-if conditions rechecked on resolution; queueing | `TriggerHandler`, `Trigger<Mode>` |
| `cost.lua` | Activated-ability costs: mana, {T}, `Sac<n/...>`, `Discard<n/...>`, `PayLife<n>`; can-pay checks and payment (choices via `choose_cards`) | `Cost`, `CostPart*`, `CostPayment` |
| `replacements.lua` | Enters-the-battlefield replacements: "enters tapped" (with conditions) and `K:ETBReplacement` (choose a color); applied inside `game:move` before anything sees the card enter | `ReplaceMoved`, `ReplacementHandler` |
| `combat.lua` | Attack/block legality (flying, reach, menace, defender, haste), damage assignment (current rules, trample), first/double strike steps | `CombatUtil`, `Combat` |
| `controllers/ai.lua` | Heuristic AI | `AiController`, `AiAttackController`, `AiBlockController` |
| `controllers/prompt.lua` | Human controller: yields requests to the duel menu; `prompt.run(game)` runner | `PlayerControllerHuman` |

Duel screen, outside the engine:

| File | Does |
|---|---|
| `scripts/duel/duel_ui.lua` | Pure Lua (no `sol.*`, tested headlessly): drives the prompt runner, auto-answers requests with no real choice, keeps cursor/selection state, turns inputs (`left/right/up/down/select/confirm/cancel`) into answers, formats prompts, log and card details |
| `scripts/duel/decks.lua` | Preconstructed 40-card decks of supported cards |
| `scripts/menus/duel.lua` | Solarus menu: `duel.start(game, { player_deck, opponent_deck, opponent_name, on_finished })` suspends the game and runs a duel; draws `duel_ui` state with fill rectangles and the `8_bit` font, maps keys to inputs, reports "won"/"lost"/"draw" |

Controller interface (all called as `controller:method(game, player, ...)`): `choose_action`,
`declare_attackers`, `declare_blockers`, `assign_combat_damage`, `choose_discard`,
`choose_legend_to_keep`, `choose_targets`, `confirm_optional`, `choose_color`, `choose_cards`.

Activated abilities (`def.activated`) appear as `{ kind = "activate", card, index }` actions and go
on the stack as `kind = "ability"` items. Mana abilities with costs (`{1}, {T}: any color`,
sacrifice-for-mana, once-per-turn) are used by auto-pay as sources with `extra`/`sacrifice`.

`game.history` records this turn's attacks, life lost/gained, creature deaths, permanents
entering, spells cast and mana spent (for raid, morbid, "second spell" and similar).

Stack items are `{ kind = "spell" | "trigger", card, controller, ability, ctx }`; spells move the
card to the stack zone, triggers don't. Triggers wait in `game.pending_triggers` and go on the
stack (APNAP) each time state-based actions are done and before anyone gets priority. The engine raises an error on illegal answers, so UIs offer only legal
options and use `combat.validate_blocks` / `combat.validate_assignment` before answering.

Adding a feature: implement it, then let `card_db.lua` accept it (keyword in `keywords.lua`, a
new effect in `effects.lua` with its allowed parameters, a trigger mode in `triggers.lua`, a
filter property in `filter.lua`, ...), add a scenario to `solarus/tests/test_rules.lua` or
`test_abilities.lua`, and regenerate `cardpool/support_report.md`. Unknown parameters always make
a card unsupported, so a new feature can't silently half-work. The report's
"only blocker" column shows which feature unlocks the most cards next.

## Scope: the card pool

The minimum card pool is **`solarus/cardpool/maloney_foundations.txt`** (330 distinct cards,
360 entries; repeated lines are extra copies). All 330 have Forge scripts.
`solarus/cardpool/maloney_foundations_report.md` lists every feature the pool uses and which cards
use it. **That report is the engine's feature checklist.** The pool has no basic lands; the
game will need them added.

Highlights from the report:
- **Not needed at all:** tokens, +1/+1 or other counters, planeswalkers, double-faced/split cards,
  hybrid/phyrexian mana.
- **Core effects (most cards):** Draw, Mana, Pump/PumpAll, ChangeZone, Tap, DealDamage, GainLife,
  Destroy, Discard, Scry, LoseLife, Surveil, Fight, Counter, Mill, Sacrifice, Charm.
- **Keywords:** Flying, Haste, Enchant (Auras), Flash, Trample, Deathtouch, Vigilance, Defender,
  First/Double Strike, Lifelink, Reach, Flashback, Menace, Prowess, Kicker, Equip, Changeling;
  one card each for Hexproof, Ward, Crew, Cascade.
- **Triggers:** ChangesZone (79 cards: ETB/dies/LTB) dominates; then Attacks, Phase, SpellCast,
  AttackersDeclared, LifeGained, and singletons.
- **Statics:** Continuous (anthems, aura/equipment boosts, Control Magic/Confiscate = layer 2
  control change), ReduceCost, CantBlock/CantAttack, MustAttack.
- **Replacements:** Moved = "enters tapped" lands (33 cards); DamageDone doubling on two cards.
- **Hard singletons to schedule late:** Teach by Example (copy spell), Aurelia (extra combat),
  Maelstrom Colossus (cascade), Cultivator's Caravan (crew/vehicles), Herald of Eternal Dawn
  (can't lose), Roughshod Duo (expend), Angrath's Marauders / Twinflame Tyrant (damage doubling),
  Firdoch Core (animate artifact), Mine Collapse (alternative cost), Thriving lands (choose a color
  as it enters).

Two players only (no multiplayer, Commander, Planechase, etc.).

Suggested order: game state + zones + turn structure + mana + vanilla creatures + combat →
stack and simple spells (DealDamage, Draw, Destroy, Pump) → ETB/dies triggers →
auras/equipment/anthems (statics, layers) → the hard singletons.

### Things that are deliberately simplified versus Forge

Record each simplification here when made, with the Forge code it diverges from:
- Undo, network play, `*View`/trackable classes → not ported.
- No mulligans yet; opening hand is the top 7 cards.
- Mana is paid automatically by tapping sources at cast time; there is no mana pool, so no
  floating mana and no manual tapping yet (needed later for UI choice and for mana-spending
  triggers like Roughshod Duo's expend).
- Cards keep the same Lua object across zones (state is reset per CR 400.7). Last-known
  information is limited to the controller (for "dies" triggers); P/T and keywords are read from
  the card as it is now.
- A player's simultaneous triggers go on the stack in the order they triggered; the player
  doesn't choose the order yet.
- All targets for a spell or trigger are chosen up front; the duel screen can't back out of a
  cast once targeting starts.
- Amounts must be plain numbers (no X or SVar arithmetic yet).
- Players get no priority in cleanup (correct until something can trigger there).
- Duel screen: combat damage among several blockers is divided automatically (lethal to each
  in turn, rest tramples over); the AI's actions happen instantly and are reported in the log.
- AI simulation (`forge-ai/.../simulation`) → not ported; heuristics only.

## Verifying behaviour against Forge

For a rules scenario, write the same setup twice:
1. Java: a test in `forge-gui-desktop/src/test/java/forge/ai/simulation/` style
   (`initAndCreateGame`, `addCard`, `devModeSet`, resolve, assert), or a `.pzl` puzzle.
2. Lua: the same board in `solarus/tests/`, asserting the same outcome.

Forge is the oracle: if they disagree, the Lua side is wrong unless the divergence is listed above.

## Legal notes

- Forge and Solarus are both **GPL-3.0**, so the quest's Lua code (a port of Forge logic) and the
  copied card scripts should be GPL-3.0 too; keep `LICENSE` and attribution. Solarus quest
  *assets* (art, music) can have their own licenses; track them per file. The starter quest's
  assets come from the Solarus project; check their licenses (on solarus-games.org and in the
  Solarus Quest Editor's initial-quest resources) before distributing.
- Magic: The Gathering card names, rules text, art and mana symbols belong to Wizards of the Coast.
  Fan projects generally avoid distributing official art; consider original art.

## Decisions log

| Date | Decision | Why |
|---|---|---|
| 2026-10-29 | Docs created | Initial survey |
| 2026-10-29 | ~~Toolchain: Butano for GBA~~ (superseded 2026-10-30) | Easiest GBA art pipeline |
| 2026-10-29 | Minimum card pool: `cardpool/maloney_foundations.txt` | Chosen by owner |
| 2026-10-30 | **Target Solarus (Lua) instead of GBA.** Butano skeleton removed (still in git history at commit `22b21951`) | Owner's call: Solarus handles all the non-Magic parts of the design, and Lua is easier to work in |
| 2026-10-30 | Cards are loaded at runtime from verbatim Forge scripts, not converted to a custom format | No memory limits; stays identical to Forge and is easy to re-sync |
| 2026-10-30 | Quest based on the **Solarus 2.1 starter quest** (title "Arpeggio"); the duel board runs as a pre-game menu until duels can start from the overworld | Owner created it so the Quest Editor recognizes the project; hand-written `quest.dat`/empty `project_db.dat` didn't load |
| 2026-10-30 | Basic lands come from `cardpool/basic_lands.txt`, synced alongside the pool | The pool lists none; decks need them |
| 2026-10-30 | Duel screen split into pure-Lua `scripts/duel/duel_ui.lua` (tested) and a thin drawing menu | Solarus can't run in the cloud container, so the logic must be testable without it |
| 2026-10-30 | Duel stops only for real choices (auto-pass when no legal action) | Avoids pressing Return through every step; Forge's auto-yield is the model |
| 2026-10-30 | With only instant-speed options, priority stops only in your main phases, with something on the stack, after blockers, and at the opponent's end step | Like Forge's default phase stops; otherwise a Shock in hand stops every step |
| 2026-10-30 | Duel: human plays the Rakdos deck (spells + triggers) vs the Green AI | Exercises targeting and may-prompts in the UI |
| 2026-10-30 | Duels start from overworld NPCs through `duel.start`; the game is suspended meanwhile, and the duel menu swallows keys so the hero can't act | First step towards the adventure structure; the startup duel menu was removed |
| 2026-10-30 | Engine raises errors on illegal controller answers instead of re-asking | Keeps the engine simple; UI and AI only offer legal options |
| 2026-10-30 | Rules engine is pure Lua 5.1 under `scripts/mtg/`, no `sol.*`; decisions go through a controller interface, and the engine loop runs in a coroutine | Headless tests under LuaJIT; UI stays swappable |
