# CLAUDE.md

Guidance for Claude Code (and other agents) working in this repository.

## What this repo is

A fork (`mymaloney/Magic`) of **Forge** (upstream: `Card-Forge/forge`), the open-source
Magic: The Gathering rules engine written in Java 17 / Maven. ~59k files, of which ~34k are
card scripts.

**Owner's goal:** build a **Game Boy Advance game** that uses Forge's rules engine as the
reference implementation. The GBA cannot run Java, so the plan is to *port a subset* of the
engine (C/C++) and *compile a subset* of the card scripts into compact data — using the Java
code here as the source of truth for rules behaviour. Read these before doing GBA work:

- `docs/gba/README.md` — index and current status of the GBA effort
- `docs/gba/engine-map.md` — how Forge's engine works, file by file (start here for any rules question)
- `docs/gba/card-scripts.md` — the card script format and how a script becomes runtime objects
- `docs/gba/porting-plan.md` — GBA constraints, proposed architecture, card-subset priorities

Unless a task says otherwise, **do not refactor or reformat the Forge Java code**. Keep the
upstream code close to upstream so it stays easy to merge `Card-Forge/forge` master. New GBA
work goes in its own top-level directory (proposed: `gba/`, see porting plan), outside the Maven
reactor.

## Module map (Maven reactor, root `pom.xml`)

| Module | What it holds | Relevance to GBA |
|---|---|---|
| `forge-core` | Static card data: `CardRules`/`CardFace` (parsed scripts), `CardDb`, mana cost parsing, decks, editions, `StaticData` | Card data model, mana cost format |
| `forge-game` | **The rules engine.** `Game`, phases, stack, zones, combat, mana, costs, abilities, triggers, replacements, statics, keywords | **Primary reference** |
| `forge-ai` | Computer opponent (`PlayerControllerAi`, per-effect AI in `forge/ai/ability/*Ai.java`, simulation) | Reference for a simple GBA AI |
| `forge-gui` | Shared, toolkit-neutral GUI logic **and `forge-gui/res/`** (all game data: `cardsfolder/`, `tokenscripts/`, `editions/`, `puzzle/`, …) | Card data source |
| `forge-gui-desktop` | Swing desktop app; **also holds almost all tests** (169 test classes, incl. game simulation tests) | Test harness |
| `forge-gui-mobile`, `-mobile-dev`, `-android`, `-ios` | libGDX mobile front end; Adventure mode lives in `forge-gui-mobile/src/forge/adventure` | Adventure mode is a design reference for an RPG-style GBA game |
| `forge-lda`, `adventure-editor`, `forge-installer` | Tools | Ignore |

Note: `CONTRIBUTING.md` describes forge-core/forge-game roles slightly loosely; the table
above reflects the actual code (the rules engine is `forge-game`).

## Build & test

Toolchain in the cloud container: `/opt/maven/bin/mvn`, Java 17+.

```bash
mvn -U -B clean -P windows-linux install -DskipTests   # full build (slow, downloads deps)
mvn -B -pl forge-game -am compile                       # just the engine + its deps
mvn -B -pl forge-gui-desktop -am test -Dtest=GameSimulationTest   # one engine test class
```

Tests need a display (CI runs them under `Xvfb :1`, see `.github/workflows/test-build.yaml`).
Engine behaviour tests live under `forge-gui-desktop/src/test/java/forge/ai/simulation/` and
`forge-gui-desktop/src/test/java/forge/gamesimulationtests/`. `SimulationTest.initAndCreateGame()`
plus `addCard(...)` and `PhaseHandler.devModeSet(...)` is the quickest way to set up a board state
and check how Forge resolves something — useful for generating expected results for GBA-side tests.

## Fast navigation

- Card script for a card: `forge-gui/res/cardsfolder/<first letter>/<name_lowercase_underscored>.txt`
  (e.g. `l/lightning_bolt.txt`). Tokens: `forge-gui/res/tokenscripts/`.
- Set lists / rarities: `forge-gui/res/editions/<Set Name>.txt`.
- Script effect name → Java class: `forge-game/src/main/java/forge/game/ability/ApiType.java`
  (e.g. `DealDamage` → `effects/DamageDealEffect.java`). Effect AI: `forge-ai/src/main/java/forge/ai/SpellApiToAi.java`.
- Trigger `Mode$` → `forge-game/.../trigger/TriggerType.java`; replacement `Event$` →
  `replacement/ReplacementType.java`; static `Mode$` → `staticability/StaticAbilityMode.java`.
- Keywords (`K:` lines) → `keyword/Keyword.java`, expanded into real abilities in
  `card/CardFactoryUtil.java` (`addTriggerAbility`, `addReplacementEffect`, `addSpellAbility`, `addStaticAbility`).
- Scripting reference docs: `docs/Card-scripting-API/`.

The codebase is large; prefer `Grep` with a path filter over broad reads. `Card.java` (~8k lines),
`CardFactoryUtil.java`, `Player.java`, `GameAction.java` are big — read by method, not whole.

## Conventions

- Follow upstream style; card script conventions are in `docs/Card-scripting-API/Card-scripting-API.md`
  (lowercase filenames, LF endings, minimal default params).
- Upstream `CONTRIBUTING.md` asks AI agents not to add unnecessary tests and to disclose AI authorship in PRs.
- Licensing: Forge is GPL-3.0. Code ported from it (including a C port for GBA) is a derivative
  work and must stay GPL-3.0. Card names/text/art are Wizards of the Coast IP — keep that in mind
  before distributing a ROM.
