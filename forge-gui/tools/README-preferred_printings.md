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

Point `--forge` at the Forge you actually play, the folder that contains its `res` folder. If you leave it
out, the tool uses the Forge it's sitting in; run from a source checkout's `forge-gui/tools`, that's the
checkout, not an installed copy. The page shows which Forge it's changing at the top, and lets you switch.

Changes to Adventure decks show up in **new** games: an existing save keeps the starting deck it began with,
and shops that were already stocked keep their cards.

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
Scryfall, the same place Forge gets them, a few per second as Scryfall asks, so a card with hundreds of
printings fills in as you scroll. They are kept in a `preferred-printings-images` folder next to your settings
file, so each picture is only downloaded once. Untick "Fetch missing images from Scryfall" to stay offline.

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

1. It drops the kinds of printing you excluded (by default, all of the categories below). **Everything left is
   allowed.**
2. If you chose a **language**, and some of those were printed in it, it keeps only those.
3. If you prefer the **old frame** (sets from before Eighth Edition, 2003, and "retro frame" reprints in newer
   sets), and some are old-frame, it keeps only those. Turn this off with `--no-prefer-old-frame`.
4. Collector and catch-all sets (The List, Mystery Booster, 30th Anniversary Edition, From the Vault...) are
   kept only if nothing else is left.
5. Then, by default, it **spreads** your decks across all of those printings: each deck gets one of them, so a
   card varies from deck to deck, and the same deck gets the same one every time (see "Picking several
   printings" below for how decks are shared out). With **Use one** in the picker, or `--no-spread`, every deck
   gets the same single printing instead: the **latest**, or the first with `--order oldest`.

Printings you picked yourself for a card (in the visual picker, or `card_choices` in a settings file) beat all
of these rules. A card already in the set chosen for its deck keeps its line, so art variants already in a
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
| `gold-border` | Gold-bordered printings (World Championship decks, ...)* | no |
| `inverted` | Inverted-frame printings* | no |
| `thick` | Thick-stock printings, such as display commanders* | no |

\* Needs the card details from Scryfall (below).

Allow a category again with `--include`, e.g. `--include white-border promo`. Or list exactly what to exclude
with `--exclude`, e.g. `--exclude secret-lair ub`. Use `--exclude` on its own to exclude nothing.

Forge's files don't say which sets are Universes Beyond, so the tool carries its own list (shown in the visual
picker under "Sets already counted as UB"). When a new UB set comes out before the tool is updated, add its set
code yourself: in the visual picker's "Also count these set codes as Universes Beyond" box, with
`--ub-set CODE` on the command line, or as `extra_ub_sets` in a settings file.

Hard exclusions are never broken: a card that only exists in those (like a Universes Beyond-only card) is left
as it is. Soft ones are relaxed for a card only when it has no other printing; the report lists those cards.

### Printings in your language

Forge shows each card's picture in the language set as **Card download language** in Forge's preferences,
when that printing was printed in it, and in English otherwise. Many printings never were (most older sets
weren't printed in Japanese or Chinese, for example), so the tool can put the ones that were first.

Choose the language in the visual picker under **Prefer**, or with `--language CODE` (`es`, `fr`, `de`, `it`,
`pt`, `ja`, `ko`, `ru`, `zhs`, `zht`; `en` for no preference). It starts out as Forge's own Card download
language. Which printings exist in which language comes from Forge's own records (it learns them as it
downloads pictures) and, more completely, from the Scryfall card details below, which then also fetch your
language. The picker shows pictures in your language, tagged with it.

### Card details from Scryfall

Forge's own files only mark some treatments: many full-art lands, borderless and showcase cards are listed as
ordinary printings; so are most retro-frame reprints (whole Commander sets such as The Brothers' War Commander,
and the Retro Artifacts set), which then don't count as old frame; and inverted frames, thick stock and gold
borders aren't recorded at all. Download the
missing details from Scryfall once (it takes a minute or two: Scryfall sends tens of thousands of printings,
a page at a time) and the tool tags them all:

- in the visual picker, **Card details → Download from Scryfall** (and **Update** after new sets come out);
- on the command line, add `--update-scryfall`.

They are saved to `preferred-printings-scryfall.json` next to your settings file (or in the current folder;
`--scryfall-cache FILE` puts them elsewhere) and used automatically from then on. A printing can carry several
tags, e.g. Secret Lair, borderless and inverted; it's excluded if any of them is. The details also catch
Universes Beyond printings by their security stamp, on top of the tool's list of UB sets.

## Rewards and shops

Adventure rewards and shop cards are made while you play, not read from deck files. When Forge hands out a
card by name (random card rewards, single-card shop items, and anything else that picks "a" printing of a
card), it uses its own per-card art preference, the same one Forge's deck editor sets with
"Change preferred art".

Tick **Also use these printings for Adventure rewards and shop cards** in the visual picker (or add
`--card-prefs`) and **Apply** also writes that preference for every card, following your rules and picks,
into Forge's `card.preferences` file in your Forge preferences folder. Your star ratings there are kept. It is
backed up with your decks, and `--restore` puts it back (or removes it if there was none).

- **Close Forge first:** Forge saves this file itself and could overwrite the change when it exits.
- In Adventure's settings, keep **Use Card Variants from All Sets** off (the default); with it on, Forge picks
  a random printing for every reward instead.
- Rewards use one printing per card: with several picks, the first one you picked; when spreading, the one
  "Use one" would choose.
- **Booster packs** aren't affected: a pack always holds its own set's printings, as a real one would.
- It applies to the rest of Forge as well, wherever Forge picks a printing by name.

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
`{"Sol Ring": ["LEB|270", "30A|563"], "Lightning Bolt": "M10|146"}`), `image_cache`, `online_images` and
`extra_ub_sets` (set codes to count as Universes Beyond, e.g. `["ABC"]`), `scryfall_cache`, `language`,
`card_prefs` and `spread`.

## Other options

- `--report FILE` writes the full report: every folder, skipped deck, card left unchanged, and samples of changes.
- `--backup-dir PATH` puts backups somewhere else; `--no-backup` skips them.
- `--quiet` prints only the one-line result.
- `--image-cache PATH` tells the visual picker where Forge's card pictures are, if it can't find them
  (normally `pics/cards` in Forge's cache folder).
- `--no-online-images` keeps the visual picker offline.

## Limits

- Without the Scryfall card details, the tool only knows the treatments Forge's files mark, so many full-art,
  borderless and showcase printings go untagged, and inverted, thick and gold-border can't be filtered.
- Some sets list regular printings under a treatment section in Forge's files (e.g. Commander Masters'
  precon cards under borderless); the Scryfall details add tags but can't remove Forge's.
- Cards created during play only follow your choices with the rewards-and-shops option above, and booster
  packs never do.
- Adventure planes that limit cards to certain sets in their `config.json` (`legalCards.editions`) only get
  printings from those sets.
