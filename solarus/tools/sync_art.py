#!/usr/bin/env python3
"""Copies the owner's card art from ART/ into the quest: PNGs to solarus/quest/data/sprites/cards/,
fonts (.ttf) to solarus/quest/data/fonts/.

ART/ is the source of truth; the quest copy is generated, so edit the files in ART/ and re-run:

    python3 solarus/tools/sync_art.py

The full frames come from the sheet backs.png when it exists (160x224 cells, row by row: white,
blue, black, red / green, colorless, gold); it replaces the single <color>back.png files.

Missing "snub" frames (the art-less 160x120 version) are derived from the full frame of the same
color: the title bar, then everything from the type bar down, with one extra text-box row. That
recipe reproduces every snub in ART/ exactly. A derived file is reported so it can be replaced by
hand-made art.
"""

import os
import shutil
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = os.path.join(ROOT, "ART")
DEST = os.path.join(ROOT, "solarus", "quest", "data", "sprites", "cards")
FONTS = os.path.join(ROOT, "solarus", "quest", "data", "fonts")
COLORS = ["white", "blue", "black", "red", "green", "colorless", "gold"]
SHEET = "backs.png"   # all full frames in one sheet, in COLORS order, 4 per row


def snub_from_back(path):
    back = Image.open(path).convert("RGBA")
    snub = Image.new("RGBA", (160, 120))
    snub.paste(back.crop((0, 0, 160, 22)), (0, 0))        # title bar
    snub.paste(back.crop((0, 127, 160, 147)), (0, 22))    # type bar and top of the text box
    snub.paste(back.crop((0, 146, 160, 147)), (0, 42))    # one more text-box row
    snub.paste(back.crop((0, 147, 160, 224)), (0, 43))    # rest of the text box and bottom edge
    return snub


def main():
    os.makedirs(DEST, exist_ok=True)
    for name in sorted(os.listdir(SOURCE)):
        if name == SHEET:
            continue
        if name.lower().endswith(".png"):
            shutil.copyfile(os.path.join(SOURCE, name), os.path.join(DEST, name))
        elif name.lower().endswith(".ttf"):
            shutil.copyfile(os.path.join(SOURCE, name), os.path.join(FONTS, name))
    sheet_path = os.path.join(SOURCE, SHEET)
    if os.path.exists(sheet_path):
        sheet = Image.open(sheet_path).convert("RGBA")
        for i, color in enumerate(COLORS):
            x, y = (i % 4) * 160, (i // 4) * 224
            sheet.crop((x, y, x + 160, y + 224)).save(os.path.join(DEST, color + "back.png"))
        stale = os.path.join(DEST, SHEET)
        if os.path.exists(stale):
            os.remove(stale)
    for color in COLORS:
        back = os.path.join(SOURCE, color + "back.png")
        snub = os.path.join(SOURCE, color + "snub.png")
        if not os.path.exists(back):
            print("missing " + color + "back.png", file=sys.stderr)
        elif not os.path.exists(snub):
            snub_from_back(back).save(os.path.join(DEST, color + "snub.png"))
            print("derived " + color + "snub.png from " + color + "back.png")


if __name__ == "__main__":
    main()
