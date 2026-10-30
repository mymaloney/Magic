# Solarus project docs

Goal: a Magic: The Gathering adventure game built on the [Solarus](https://www.solarus-games.org)
engine. Solarus handles the overworld/RPG side; duels use a pure-Lua port of Forge's rules, with
this repository (a fork of Card-Forge/forge) as the reference implementation and card data source.

| Doc | Read it when |
|---|---|
| [engine-map.md](engine-map.md) | You need to know how Forge implements a rule (turn loop, stack, SBA, layers, triggers, combat, AI) and which Java file to open |
| [card-scripts.md](card-scripts.md) | You're reading card scripts or extending the Lua parser, or choosing which effects/keywords to support |
| [porting-plan.md](porting-plan.md) | You're making design decisions about the Lua engine or the quest; also holds the decisions log |
| `solarus/README.md` | Setting up Solarus, running the quest and tests, adding content |

## Current status

- [x] Repository surveyed, navigation docs written (2026-10-29)
- [x] Minimum card pool defined: `solarus/cardpool/maloney_foundations.txt` + feature report
- [x] Target switched from GBA/Butano to Solarus (2026-10-30)
- [x] Card sync (`tools/sync_cards.py`) + Lua script parser, with all 330 pool cards parsing in tests
- [x] Quest built on the Solarus 2.1 starter quest (owner, 2026-10-30); placeholder duel board /
      card browser added to the startup menus
- [ ] Card browser confirmed working on a real Solarus install
- [ ] `scripts/mtg` game state, zones, turn structure, mana, combat (vanilla creatures)
- [ ] Stack, targeting, first effects; controller interface + coroutine-driven duel menu
- [ ] Triggers, statics/layers, replacements
- [ ] Maloney Foundations pool fully supported (no "unsupported feature" reports)
- [ ] Overworld: first map, NPC that starts a duel

Keep this checklist up to date. It's the first thing a new session should read.

## Keeping in sync with upstream Forge

Upstream is `https://github.com/Card-Forge/forge` (branch `master`). To pull rules fixes and new
card scripts:

```bash
git remote add upstream https://github.com/Card-Forge/forge.git   # once
git fetch upstream master
git merge upstream/master
python3 solarus/tools/sync_cards.py solarus/cardpool/maloney_foundations.txt
luajit solarus/tests/run.lua
```
