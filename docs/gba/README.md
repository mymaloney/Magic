# GBA project docs

Goal: a Game Boy Advance Magic: The Gathering game whose rules behave like Forge's, using this
repository (a fork of Card-Forge/forge) as the reference implementation and data source.

| Doc | Read it when |
|---|---|
| [engine-map.md](engine-map.md) | You need to know how Forge implements a rule (turn loop, stack, SBA, layers, triggers, combat, AI) and which Java file to open |
| [card-scripts.md](card-scripts.md) | You're reading/converting card scripts, or choosing which effects/keywords to support |
| [porting-plan.md](porting-plan.md) | You're making design decisions about the GBA code; also holds the decisions log |

## Current status

- [x] Repository surveyed, navigation docs written (2026-10-29)
- [ ] Toolchain chosen (devkitARM+libtonc vs Butano)
- [ ] `gba/` skeleton with host-buildable engine core
- [ ] Card script converter + "unsupported features" report
- [ ] First playable: two vanilla decks, combat only
- [ ] First card pool fully supported

Keep this checklist up to date — it's the first thing a new session should read.

## Keeping in sync with upstream Forge

Upstream is `https://github.com/Card-Forge/forge` (branch `master`). To pull rules fixes and new
card scripts:

```bash
git remote add upstream https://github.com/Card-Forge/forge.git   # once
git fetch upstream master
git merge upstream/master
```

After merging, re-run the converter: script changes may turn previously-unsupported cards
supported (or vice versa).
