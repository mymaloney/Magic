# Preferred printings

`preferred_printings.py` changes which **printing** (set, art and frame) Forge uses for each card in your
decks, by rules you choose or by picking the exact printing you want for a card, visually. The cards
themselves never change, only the version shown. For example, it can swap every Secret Lair or borderless
printing for a regular one, or put cards in the old frame where one exists.

It works on a normal Forge install (Windows, Mac or Linux) or a source checkout. Only the visual picker uses
the internet, to show pictures Forge hasn't downloaded yet.

## What you need

- Forge.
- Python 3.9 or newer (<https://www.python.org/downloads/>). On Windows, type `python` instead of `python3`
  in the commands below.
- This file, `preferred_printings.py`, saved anywhere.

## The easy way: the visual picker

```bash
python3 preferred_printings.py --gui --forge "/path/to/Forge"
```

This opens a page in your web browser. It runs only on your computer; nothing is uploaded. Keep the terminal
window open while you use it, and press Ctrl+C there to quit.

- **Left:** which decks to change (Forge's Adventure decks, your own decks, or other folders), what to exclude,
  and what to prefer. Changes take effect straight away.
- **Middle:** every card in those decks. Search, or switch to **My picks** to see the cards you've chosen yourself.
- **Right:** every printing of the selected card, with its picture. The highlighted one is what your decks will
  use. **Click printings to pick them for that card**, whatever the rules say; click again to unpick, or
  "Use the rules instead" to clear them all. Pick several and they are spread across your decks (see below).
  "Hide excluded" tidies cards with many printings.
- **Preview** shows how many cards would change. **Apply to decks** makes the changes (backing the decks up
  first), and **Save settings** stores your rules and picks in `preferred-printings.json`, which the GUI loads
  next time. You can also use that file from the command line: `--config preferred-printings.json --apply`.

Pictures come from Forge's own image cache when Forge has already downloaded them. Others are fetched from
Scryfall, the same place Forge gets them; untick "Fetch missing images from Scryfall" to stay offline.

## Quick start (command line)

1. **Preview.** Nothing is changed. Point `--forge` at your Forge folder (the one with `res` in it;
   on a Mac, at `Forge.app`). This looks at your own decks:

   ```bash
   python3 preferred_printings.py --forge "/path/to/Forge" --user-decks
   ```

   It prints how many cards would change. Add `--report report.md` to see every change in detail.

2. **Apply.** Same command plus `--apply`:

   ```bash
   python3 preferred_printings.py --forge "/path/to/Forge" --user-decks --apply
   ```

   Every deck is copied to a `preferred-printings-backups` folder before it is changed, and the tool prints
   the command to undo it.

3. **Undo,** if you change your mind:

   ```bash
   python3 preferred_printings.py --restore "preferred-printings-backups/20261104-221500"
   ```

## Which decks it changes

| Option | Decks |
|---|---|
| *(nothing)* | The Adventure mode decks that ship with Forge (enemies, starters, rewards...) |
| `--user-decks` | Your own decks, in `%APPDATA%\Forge\decks` (Windows), `~/Library/Application Support/Forge/decks` (Mac) or `~/.forge/decks` (Linux) |
| `--decks PATH` | Any folder of `.dck` files (searched recursively); repeatable |
| `--skip-dir PATH` | Leave a sub-folder alone; repeatable |
| `--no-skip-set-named-decks` | Also change decks named after a product, like `4ED - Black Starter.dck` (left alone by default, so preconstructed products keep their printings) |

Forge's own files (the Adventure decks) are put back by every Forge update, so run the tool again after
updating. Your own decks are not touched by updates.

## How it picks a printing

1. It drops the kinds of printing you excluded (by default, all of the categories below).
2. It prefers the **old frame**: sets from before Eighth Edition (2003), and "retro frame" reprints in newer
   sets. Turn this off with `--no-prefer-old-frame`.
3. Of what's left, it takes the **latest** printing, or the first one with `--order oldest`.

Printings you picked yourself for a card (in the visual picker, or `card_choices` in a settings file) beat all
of these rules. Without picks, a card already in the chosen set keeps its line, so art variants already in a
deck survive.

### Picking several printings of a card

Pick more than one printing and **each deck gets one of them**, so the same card shows different art from deck
to deck (handy for the many Adventure enemy decks). Which deck gets which is worked out from the deck's file
name, not at random, so running the tool again gives the same result. Adding a printing later only moves the
decks that switch to it, removing one only moves the decks that had it, and the order you picked them in
doesn't matter.

### Exclusion categories

| Category | What it covers | Hard? |
|---|---|---|
| `ub` | Universes Beyond sets | yes |
| `secret-lair` | Secret Lair | yes |
| `masterpiece` | Inventions, Invocations, Expeditions, Mystical Archive | yes |
| `promo` | Promo sets, and promo, buy-a-box, bundle and box-topper printings | yes |
| `digital` | Alchemy, Arena and Magic Online sets | yes |
| `borderless` | Borderless printings | no |
| `extended-art` | Extended art printings | no |
| `full-art` | Full art printings | no |
| `showcase` | Showcase and etched printings | no |
| `white-border` | White-bordered sets (Revised to Ninth Edition, Portal Three Kingdoms...) | no |

Allow a category again with `--include`, e.g. `--include white-border promo`. Or list exactly what to exclude
with `--exclude`, e.g. `--exclude secret-lair ub`. Use `--exclude` on its own to exclude nothing.

Hard exclusions are never broken: a card that only exists in those (like a Universes Beyond-only card) is left
as it is. Soft ones are relaxed for a card only when it has no other printing; the report lists those cards.

## Saving your choices

Save your options once:

```bash
python3 preferred_printings.py --forge "/path/to/Forge" --user-decks --include white-border --save-config my-printings.json
```

Then, for example after each Forge update:

```bash
python3 preferred_printings.py --config my-printings.json --apply
```

Options given on the command line override the file. The file is plain JSON and can be edited by hand; its
keys are `forge`, `decks`, `user_decks`, `order`, `prefer_old_frame`, `exclude`, `skip_dir`,
`skip_set_named_decks`, `backup`, `backup_dir`, `card_choices` (your own picks: one printing or a list, e.g.
`{"Sol Ring": ["LEB|270", "30A|563"], "Lightning Bolt": "M10|146"}`), `image_cache` and `online_images`.

## Other options

- `--report FILE` writes the full report: every folder, skipped deck, card left unchanged, and samples of changes.
- `--backup-dir PATH` puts backups somewhere else; `--no-backup` skips them.
- `--quiet` prints only the one-line result.
- `--image-cache PATH` tells the visual picker where Forge's card pictures are, if it can't find them
  (normally `pics/cards` in Forge's cache folder).
- `--no-online-images` keeps the visual picker offline.

## Limits

- Forge's edition files don't record the inverted frame or thick stock, and Forge has no gold-bordered sets,
  so those can't be filtered.
- Some sets list treated printings in their regular section, or regular printings under a treatment; the tool
  can only go by where a printing is listed.
- Only deck files change. Cards created during play (Adventure rewards, shops, boosters) are not affected.
- Adventure planes that limit cards to certain sets in their `config.json` (`legalCards.editions`) only get
  printings from those sets.
