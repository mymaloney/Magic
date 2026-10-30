# Forge engine map

How Forge's rules engine is put together, with the files to read for each part. Paths are
relative to `forge-game/src/main/java/forge/game/` unless stated otherwise. Line numbers drift
upstream — search for the method name rather than trusting them.

## 1. The object model

| Concept | Class | Notes |
|---|---|---|
| A game in progress | `Game` | Owns players, zones, stack, phase handler, trigger/replacement handlers, `GameAction`, event bus |
| A match (best-of-N) | `Match` | `Match.startGame(game)` → `GameAction.startGame(...)` (mulligans, first turn) → `PhaseHandler.mainGameLoop()` |
| Game setup | `GameRules`, `GameType`, `player/RegisteredPlayer` | Deck + lobby player per seat |
| Player | `player/Player` | Life, counters, mana pool, zones, controller |
| Decision maker | `player/PlayerController` (abstract) | **Every choice the rules need from a player goes through here.** Impls: `PlayerControllerAi` (forge-ai), `PlayerControllerHuman` (forge-gui), `PlayerControllerForTests` (tests) |
| Card instance | `card/Card` (+ `CardState` per face) | Huge (8k lines). Characteristics are recomputed from base state + "changed" tables (layers) |
| Static card data | `forge-core: forge/card/CardRules`, `CardFace`, `CardDb` | Parsed script text, shared across games |
| Building a game card | `card/CardFactory` (`readCard`, `readCardFace`) + `card/CardFactoryUtil` | Turns `CardRules` into a `Card` with SpellAbilities/Triggers/Statics/Replacements |
| Zones | `zone/Zone`, `PlayerZone`, `PlayerZoneBattlefield`, `ZoneType` | Moves go through `GameAction.moveTo(...)` / `changeZone(...)` |
| Stack | `zone/MagicStack`, `spellability/SpellAbilityStackInstance` | |
| Spells/abilities | `spellability/SpellAbility` (`Spell`, `AbilityActivated`, `AbilitySub`, `AbilityStatic`, `LandAbility`) | Sub-abilities chain via `SubAbility$` |
| Costs | `cost/Cost` → list of `CostPart` (`CostPartMana`, `CostTap`, `CostSacrifice`, …); `cost/CostPayment` | |
| Mana | `mana/ManaPool`, `mana/ManaCostBeingPaid`, `mana/Mana`; cost syntax in `forge-core: forge/card/mana/` | |
| Combat | `combat/Combat`, `combat/CombatUtil`, `AttackConstraints` | |
| UI-facing snapshots | `*View` classes + `forge/trackable/` | Read-only mirrors for GUIs/network; the Lua port doesn't need these |
| Events | `event/GameEvent*` (65 types) | Fired for UI/sound/log; not rules-relevant |
| Undo/snapshots | `undo/`, `GameSnapshot`, `GameState` | `GameState` can serialize a board — handy for test fixtures |

## 2. The turn loop and priority

`phase/PhaseHandler`:
- `mainGameLoop()` → repeats `mainLoopStep()` until game over.
- `mainLoopStep()`: run state-based actions (`checkStateBasedEffects()` → `GameAction.checkStateEffects`),
  then ask the priority player's controller `chooseSpellAbilityToPlay()`. `null` = pass. Each play goes
  through `PlayerController.playChosenSpellAbility` → `player/PlaySpellAbility.playSpellAbility(...)`
  (choose modes/targets/X, pay costs, put on stack).
- When priority goes all the way around: empty stack → `onPhaseEnd()`, `advanceToNextPhase()`,
  `onPhaseBegin()`; otherwise `MagicStack.resolveStack()`.
- `onPhaseBegin()` has a `switch` per `PhaseType` (untap, upkeep, draw, declare attackers/blockers,
  combat damage, cleanup…). This switch is the best summary of turn-structure rules (CR 500–514).
- `devModeSet(phase, player)` jumps straight to a phase — used heavily by tests.

## 3. Casting and resolving

1. Script line `A:SP$ DealDamage | ...` is parsed by `ability/AbilityFactory.getAbility(...)`
   into a `SpellAbility`. The `SP$`/`AB$`/`DB$` value is looked up in `ability/ApiType` (enum mapping
   name → `SpellAbilityEffect` subclass in `ability/effects/`).
2. Casting: `player/PlaySpellAbility` handles announcements, targeting (`spellability/TargetRestrictions`,
   `TargetChoices`), cost payment (`cost/CostPayment`), then `MagicStack.add(...)`.
3. Resolution: `MagicStack.resolveStack()` checks targets are still legal (`hasLegalTargeting`), then
   `AbilityUtils.resolve(sa)` → `sa.getApi()`'s effect `.resolve(sa)`, then each `SubAbility` in turn.
4. Expression helpers used by nearly every effect (`ability/AbilityUtils`):
   - `calculateAmount(card, "X", sa)` — numbers, `SVar` math (`Count$...`), X costs
   - `getDefinedCards/Players(card, "Targeted"|"Self"|"You"|..., sa)` — `Defined$` resolution
   - `Card.isValid("Creature.OppCtrl+nonToken", ...)` → `card/CardProperty.cardHasProperty` — the
     `Valid*$` filter mini-language. `player/PlayerProperty` is the player equivalent.

## 4. State-based actions

`GameAction.checkStateEffects(...)` (CR 704): checks game over, applies statics
(`checkStaticAbilities`), lethal damage / 0 toughness, legend rule, auras/equipment legality,
planeswalker loyalty, counters annihilation, etc. Loops until nothing changes. The Lua engine needs
essentially this function, minus variants it doesn't support.

## 5. Continuous effects / layers

- `GameAction.checkStaticAbilities()` wipes previous static effects and reapplies every
  `S:Mode$ Continuous` ability layer by layer.
- Layers: `staticability/StaticAbilityLayer` (1 copy, 2 control, 3 text, 4 type, 5 color,
  6 abilities, 7a/b/c P/T, plus rules). Application: `StaticAbilityContinuous.applyContinuousAbility`.
- Other `S:` modes are *queries*, not layer effects: e.g. `StaticAbilityCantAttackBlock`,
  `StaticAbilityCantTarget`, cost changes in `cost/CostAdjustment`. Each `StaticAbility*` class
  exposes a static check that the relevant rules code calls (grep the class name to find callers).
- Timestamps/dependency order are handled in `checkStaticAbilities`; "until end of turn" pumps are
  stored on the card (`Card.addPTBoost`, `addChangedCardKeywords`, … with a timestamp) and removed at cleanup.

## 6. Triggers

- Script: `T:Mode$ ChangesZone | ... | Execute$ TrigFoo` with `SVar:TrigFoo:DB$ ...`.
- Types: `trigger/TriggerType` (enum → `Trigger*` class with `performTest` that matches run params).
- Engine code calls `game.getTriggerHandler().runTrigger(TriggerType.X, runParams, holdTrigger)`
  at the moment the event happens; `runParams` keys are `ability/AbilityKey`.
- Triggered abilities wait in a "simultaneous stack" and are put on the stack the next time a
  player would get priority: `MagicStack.addAllTriggeredAbilitiesToStack()` (APNAP order, controller
  picks order). `TriggerHandler.resetActiveTriggers` handles "look-back" for leaves-the-battlefield triggers.

## 7. Replacement effects

- Script: `R:Event$ Moved | ... | ReplaceWith$ Foo`.
- `replacement/ReplacementHandler.run(ReplacementType.X, runParams)` is called *before* an event
  happens (damage, zone move, draw, counters, …) and returns a `ReplacementResult` (NotReplaced,
  Replaced, Prevented, Updated…). Affected player chooses order when several apply (CR 616).
- Damage prevention also runs through here (`ReplaceDamage`).

## 8. Keywords

- `K:` lines → `keyword/Keyword` enum (with parameter parsing classes like `KeywordWithCost`).
- Many keywords are *not* special-cased in rules code; instead `card/CardFactoryUtil` expands them
  into ordinary scripted abilities: `addTriggerAbility` (e.g. Prowess), `addReplacementEffect`,
  `addSpellAbility` (Flashback, Cycling, Equip…), `addStaticAbility`. Reading the expansion for a
  keyword is the fastest way to see its exact rules.
- Evergreen combat keywords (Flying, First Strike, Trample, Deathtouch, Lifelink…) are checked
  directly via `card.hasKeyword(Keyword.X)` in `combat/CombatUtil`, `Combat`, and damage code.

## 9. Combat

- Declare attackers/blockers: `PlayerController.declareAttackers/declareBlockers`, validated by
  `combat/CombatUtil` (`canAttack`, `canBlock`, `canBeBlocked`, `validateAttackers`, `validateBlocks`) and `AttackConstraints`
  (requirements/restrictions, "must attack").
- Damage: `Combat.assignCombatDamage(firstStrike)` then `dealAssignedDamage()`; first-strike step is
  inserted only if needed. Damage events go through `card/CardDamageTable`
  so lifelink/deathtouch/replacements see the whole batch.

## 10. Mana and costs

- Mana cost text (`2 W W`, hybrid `W/U`, phyrexian `W/P`, `X`) parsed in
  `forge-core: forge/card/mana/ManaCostParser`, `ManaCost`, `ManaCostShard`.
- Payment: `mana/ManaCostBeingPaid`; AI auto-payment `forge-ai: ComputerUtilMana` (a good reference
  for an "auto-tap" feature). Mana abilities are `AB$ Mana` with `AbilityManaPart`.
- Cost strings (`Cost$ T Sac<1/Creature> 2 R`) parsed by `cost/Cost`.

## 11. AI

`forge-ai/src/main/java/forge/ai/`:
- `AiController` — top-level decisions (what to play, when).
- `SpellApiToAi` — maps each `ApiType` to a `SpellAbilityAi` subclass in `ai/ability/` with
  `canPlayAI`/`chkAIDrawback` heuristics. Per-card hints come from script `SVar`s / `AI:` lines.
- `AiAttackController`, `AiBlockController` — combat.
- `ComputerUtil*` — shared helpers (card evaluation in `ComputerUtilCard.evaluateCreature`).
- `simulation/` — search-based AI (out of scope at first; heuristics are enough).

## 12. Testing a rules question in Java

```java
Game game = initAndCreateGame();          // SimulationTest
Player p = game.getPlayers().get(1);
addCard("Grizzly Bears", p);              // straight onto battlefield
addCardToZone("Lightning Bolt", p, ZoneType.Hand);
game.getPhaseHandler().devModeSet(PhaseType.MAIN1, p);
game.getAction().checkStateEffects(true);
```

See `forge-gui-desktop/src/test/java/forge/ai/simulation/GameSimulationTest.java` for many
examples. Puzzle files (`forge-gui/res/puzzle/*.pzl`) are another compact board-state format
(`[state]` section with `humanhand=`, `aibattlefield=`, life, phase).
