# GBA porting plan (proposal)

Status: **proposal, nothing built yet.** Update this file as decisions are made; record them in
the "Decisions log" at the bottom so later sessions don't re-litigate them.

## Target hardware

| Resource | GBA | Implication |
|---|---|---|
| CPU | ARM7TDMI @ 16.78 MHz, no FPU, no cache | Integer-only, avoid deep recursion and dynamic dispatch in hot loops |
| Fast RAM | 32 KB IWRAM | Hot code (ARM mode) + small hot state |
| Work RAM | 256 KB EWRAM | **Entire game state must fit here** (cards in play, stack, effects) |
| ROM | up to 32 MB cartridge | Card data, art, compiled scripts |
| Save | 32–128 KB SRAM/Flash | Collection, decks, progress |
| Screen | 240×160, tiles + sprites | Very little room for card text; needs zoom/detail views |
| Input | D-pad, A, B, L, R, Start, Select | Every PlayerController decision needs a pad-friendly UI |

Forge's Java engine cannot run here (no JVM, ~1 GB heap typical). So the GBA engine is a
**re-implementation** in C (or C++ without exceptions/RTTI), using Forge as the behavioural spec.

## Proposed architecture

```
forge-gui/res/cardsfolder/*.txt ──► [converter, runs on PC] ──► gba/data/*.c / .bin (packed card DB)
                                            │
                                            └── reports cards it can't compile (unsupported API/keyword)

gba/engine/   rules engine in C, mirrors forge-game structure (phases, stack, SBA, triggers…)
gba/ui/       GBA screens: board, hand, card zoom, targeting cursor, stack view
gba/ai/       simple heuristic AI, modelled on forge-ai's per-API canPlayAI logic
gba/tests/    engine unit tests that build and run on the PC (host build), compared against Forge
```

Proposed home: a new top-level `gba/` directory, **not** a Maven module, with its own Makefile.
Keep the Forge Java tree untouched so upstream merges stay clean.

### Toolchain options

- **devkitARM** (devkitPro) + **libtonc** or libgba — plain C, the standard homebrew toolchain.
- **Butano** — modern C++ engine on top of devkitARM; good asset pipeline and UI helpers.
- Emulator for testing: **mGBA** (accurate, scriptable, has a headless/test build).

Make the engine core platform-independent (no GBA headers) so it can be compiled and unit-tested
natively on the PC. Only `gba/ui` and the platform layer touch hardware.

### Converter (PC side)

Options, roughly in order of fidelity:
1. **Java tool inside this repo** reusing `forge-core`'s `CardRules` parser, emitting C tables.
   Most faithful parsing; adds one small Java class (keep it under `gba/tools/`, not in Forge modules).
2. **Python script** re-parsing the `Key$ Value | ...` format directly. Simpler, easy to iterate.

Either way the output should be a compact bytecode or struct-per-ability form:
`{api_id, params…, target_filter_id, amount_expr_id, sub_ability_index}`, with filters and amount
expressions deduplicated into shared tables. The converter must **refuse** (and list) cards using
anything the GBA engine does not implement, rather than emit partially-working cards.

## Scope: what to port first

Use the frequency tables in `card-scripts.md`. A sensible first milestone ("core-set era"):

- Two players only; no multiplayer, Commander, Planechase, Archenemy, Contraptions, Attractions.
- Turn structure, priority, stack, state-based actions, combat incl. first strike / trample.
- Mana: five colors + colorless, generic costs, X; skip hybrid/phyrexian/snow initially.
- Effects: ChangeZone (subset), Pump/PumpAll, Draw, Token, PutCounter (+1/+1, −1/−1), DealDamage,
  DamageAll, Mana, GainLife, LoseLife, Destroy/DestroyAll, Tap/Untap, Discard, Sacrifice,
  Counter, Mill, Scry, Charm.
- Keywords: Flying, Reach, Trample, Vigilance, Haste, Flash, Menace, First/Double Strike,
  Lifelink, Deathtouch, Defender, Indestructible, Hexproof, Enchant (Auras), Equip.
- Triggers: ChangesZone (ETB / dies), Phase (upkeep / end step), Attacks, SpellCast, DamageDone.
- Statics: Continuous (layer 6 abilities + layer 7 P/T only at first), CantBlock/CantAttack.
- Replacements: defer; implement "enters tapped" / "enters with counters" (`etbCounter`) only.

Then pick a concrete card pool (e.g. one or two classic core sets via `res/editions/`) and drive
the converter's "unsupported" list to zero for that pool.

### Things that are deliberately simplified versus Forge

Record each simplification here when made, with the Forge code it diverges from:
- Full layer dependency ordering (`GameAction.checkStaticAbilities`) → timestamp order only.
- Undo, network, game views/events, animations hints → not ported.
- AI simulation (`forge-ai/.../simulation`) → not ported; heuristics only.

## Verifying behaviour against Forge

For a rules scenario, write the same setup twice:
1. Java: a test in `forge-gui-desktop/src/test/java/forge/ai/simulation/` style
   (`initAndCreateGame`, `addCard`, `devModeSet`, resolve, assert) — or a `.pzl` puzzle.
2. GBA host build: the same board in `gba/tests/`, asserting the same outcome.

Forge is the oracle: if they disagree, the GBA side is wrong unless the divergence is listed above.

## Legal notes

- Forge is **GPL-3.0**. A C port derived from its logic, and data generated from its scripts,
  should be GPL-3.0 too; keep `LICENSE` and attribution.
- Magic: The Gathering card names, rules text, art and mana symbols belong to Wizards of the Coast.
  Fan projects generally avoid distributing official art; consider original art or text-only cards.

## Decisions log

| Date | Decision | Why |
|---|---|---|
| 2026-10-29 | Docs created; architecture above is a proposal only | Initial survey |
