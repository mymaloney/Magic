#!/usr/bin/env python3
"""Copies the owner's card art from ART/ into the quest (solarus/quest/data/sprites/cards/).

ART/ is the source of truth; the quest copy is generated, so edit the files in ART/ and re-run:

    python3 solarus/tools/sync_art.py

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
COLORS = ["white", "blue", "black", "red", "green", "colorless"]


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
        if name.lower().endswith(".png"):
            shutil.copyfile(os.path.join(SOURCE, name), os.path.join(DEST, name))
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
