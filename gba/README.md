# gba/ — the Game Boy Advance game

Built with [Butano](https://github.com/GValiente/butano) (C++ on devkitARM). Design docs are in
`docs/gba/`; this file covers setup and day-to-day workflow.

```
gba/
  game/            Butano project (the ROM)
    Makefile       copy of Butano's template Makefile; LIBBUTANO points at ../butano/butano
    src/ include/  game code
    graphics/      art: one .bmp + one .json per asset  →  bn::sprite_items::<name>, bn::regular_bg_items::<name>
    audio/         .mod/.xm/.s3m/.it music, .wav sound effects  →  bn::music_items / bn::sound_items
    dmg_audio/     Game Boy-style music (optional)
  cardpool/        card lists for the game + generated feature reports
  tools/           PC-side scripts (card pool report; later the script converter)
  butano/          your local Butano checkout (git-ignored)
```

Status: the `game/` skeleton (board background + animated cursor) has **not been compiled yet**:
the cloud session that wrote it had no access to devkitPro or GitHub. The first local build
may need small fixes — note any here.

## One-time setup

1. **devkitPro / devkitARM** — install with devkitPro's installer (Windows) or `dkp-pacman`
   (macOS/Linux): `sudo dkp-pacman -S gba-dev`. Follow the "Getting Started" page on devkitpro.org.
2. **Python 3** on your PATH (Butano's asset tools use it).
3. **Butano** — clone it into `gba/butano`:
   ```bash
   cd gba
   git clone https://github.com/GValiente/butano.git butano
   ```
   (Or clone it anywhere and build with `make LIBBUTANO=/path/to/butano/butano`.)
   It's best to check out a release tag and note the version in `docs/gba/porting-plan.md`.
4. **mGBA** emulator for running and debugging the ROM.

Build and run:

```bash
cd gba/game
make -j8            # produces game.gba
mgba game.gba       # or open it in the mGBA app
```

Butano's own `examples/` folder has a small project for almost every feature (sprites, backgrounds,
text, audio, affine effects) — copy patterns from there.

## Adding art

1. Draw it in Aseprite / LibreSprite / GIMP using **indexed color**.
   - Sprites: ≤16 colors (4bpp). **Palette index 0 is transparent** — make it an unused color
     like magenta. Sprite frame sizes must be GBA shapes: 8, 16, 32 or 64 px per side
     (8×8 … 64×64, plus wide/tall combos like 32×16).
   - Regular backgrounds: total size 256×256, 256×512, 512×256 or 512×512; the visible
     screen is 240×160.
2. Export as BMP (4bpp, or 8bpp with a ≤16-color palette) into `game/graphics/<name>.bmp`.
3. Add `game/graphics/<name>.json`:
   - Sprite (`height` = one frame's height; frames stacked vertically): `{ "type": "sprite", "height": 16 }`
   - Full-screen tiled background: `{ "type": "regular_bg" }`

   Other types include `sprite_tiles`, `sprite_palette`, `regular_bg_tiles`, `affine_bg`.
4. In code: `#include "bn_sprite_items_<name>.h"` and
   `bn::sprite_items::<name>.create_sprite(x, y)` (sprite coordinates are relative to the
   screen centre).

**Animation:** draw frames stacked top to bottom in one BMP, set `"height"` to one frame's
height, then:

```cpp
auto anim = bn::create_sprite_animate_action_forever(
        sprite, 8 /* refreshes per frame */, bn::sprite_items::hero.tile_item(), 0, 1, 2, 3);
// every frame: anim.update(); bn::core::update();
```

`bn_sprite_actions.h` / `bn_bg_actions.h` provide move/scale/rotate/fade-over-time actions.

**Maps:** a small, fixed board can be a single `regular_bg` BMP. For larger tile maps drawn in
Tiled, we'll add a converter in `tools/` that turns the map into a BMP/tiles + map array (not
written yet).

The placeholder `cursor.bmp` / `board.bmp` were generated programmatically; replace them freely.

## Card pool

`cardpool/maloney_foundations.txt` is the minimum card list. Regenerate the feature report
after editing it:

```bash
python3 gba/tools/cardpool_report.py gba/cardpool/maloney_foundations.txt \
        -o gba/cardpool/maloney_foundations_report.md
```

The report maps each card to its Forge script and lists every effect API, keyword, trigger,
static and replacement the pool uses — that list is the engine's feature to-do list.
