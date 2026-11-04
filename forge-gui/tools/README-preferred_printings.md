# Preferred Printings

Choose which **printing** of each card Forge uses: its set, art and frame. Swap Secret Lair, Universes
Beyond and borderless printings for regular ones, give your decks the old frame, see cards in your own
language, or pick the exact art you want for a card. Only the version of a card changes. Its name, rules and
how it plays stay the same.

It works on Forge's own Adventure mode decks, on your own decks, and on Adventure rewards and shop cards. It
comes as one file, `preferred_printings.py`, and runs on Windows, Mac and Linux.

## Contents

- [Getting started](#getting-started)
- [Using the picker](#using-the-picker)
- [How a printing is chosen](#how-a-printing-is-chosen)
- [Card details from Scryfall](#card-details-from-scryfall)
- [Adventure rewards and shops](#adventure-rewards-and-shops)
- [Backups, undo and Forge updates](#backups-undo-and-forge-updates)
- [Command line](#command-line)
- [Files the tool creates](#files-the-tool-creates)
- [Troubleshooting](#troubleshooting)
- [Limits](#limits)

## Getting started

**You need:**

- Forge, installed anywhere.
- Python 3.9 or newer, from <https://www.python.org/downloads/>. On Windows, keep the installer's options that
  associate `.py` files with Python.
- `preferred_printings.py`, saved in any folder you like, for example its own folder on your Desktop.

**First run:**

1. **Close Forge.**
2. **Double-click `preferred_printings.py`.** You can also run `python preferred_printings.py` from a terminal
   (`python3` on Mac and Linux). A small window opens and keeps the tool running, and the picker opens in
   your web browser.
3. **Tell it where Forge is.** The first time, the page asks *Where is Forge installed?* Choose one of the Forge
   folders it found, paste the path, or browse to the folder that contains Forge's `res` folder (on a Mac,
   `Forge.app`). It remembers this for next time.
4. **Download the card details (recommended).** Under **Card details**, click **Download from Scryfall**. It
   takes a minute or two and tags full-art, borderless, retro-frame and other printings that Forge's own files
   don't mark. See [Card details from Scryfall](#card-details-from-scryfall).
5. **Set your rules** on the left, and look at a few cards to see what they'll get.
6. **Preview**, then **Apply to decks**. Your decks are backed up first.
7. **Start a new Adventure game** to see the new starter decks. Existing saves keep the deck they started with.

To quit, close the small window the tool opened.

## Using the picker

### Left: what to change and how

- **Forge:** which Forge the tool is changing. Paste another folder's path and click **Use** to switch. If
  it points at a source checkout of Forge, a warning says so: an installed Forge won't see those changes.
- **Decks:**
  - *Adventure decks that come with Forge*: enemies, starter decks, rewards and shops.
  - *My own decks*: the decks you've built in Forge.
  - Any other folders of `.dck` files.
  - *Leave product decks alone* (on by default) skips decks named after a real product, such as
    `4ED - Black Starter`, so they keep their real printings.
- **Exclude:** kinds of printing never to use. See [Exclusions](#exclusions).
- **Prefer:**
  - *Old frame*, *With up-to-date text* and *Printings in my language*: see
    [How a printing is chosen](#how-a-printing-is-chosen).
  - **Spread across decks** or **Use one**: whether a card varies from deck to deck, or every deck gets the same
    printing.
- **Card details:** download or update the details from Scryfall.
- **Images:** where card pictures come from (see below).
- **Rewards and shops:** also apply your choices to Adventure rewards and shop cards. See
  [Adventure rewards and shops](#adventure-rewards-and-shops).
- **Safety:** back up decks before changing them (on by default).

Changes on the left take effect straight away in the card list and card view. Nothing is written until you
click **Apply to decks**.

### Middle: the cards in your decks

Every card in the chosen decks, most-used first. Type to search. Each row shows how many decks use the card,
plus one of these:

- the set it will use;
- "*N* prints" when the rules spread it across several printings;
- "*N* picks" when you've picked printings yourself.

**My picks** lists only the cards you've picked yourself.

### Right: every printing of a card

All the printings Forge has for the selected card, with pictures. Printings that can be used come first, in
order of preference, and excluded ones come after. **Hide excluded** tidies up cards with hundreds of
printings.

- **Highlighted** printings are what your decks will use: the rules' choice, every printing in the spread, or
  your own picks.
- **Tags** explain each printing:
  - *Rules pick* or *In the spread*.
  - *Your pick*.
  - *Old frame*.
  - Your language.
  - Its treatments, such as *Full art* or *Secret Lair*, marked *excluded* where your rules exclude them.
- **Click a printing to pick it** for this card, whatever the rules say. This works even for excluded ones.
  - Click more to pick several; they're then spread across your decks.
  - Click a pick again to unpick it.
  - **Use the rules instead** clears all your picks for the card.

**Pictures** come from Forge's own image cache when Forge has already downloaded them. The rest are fetched
from Scryfall, Forge's own picture source, a few per second as Scryfall asks. A card with hundreds of
printings fills in as you scroll, and each picture is kept on disk, so it's only downloaded once. Untick
*Fetch missing images from Scryfall* to stay offline.

### Buttons

- **Preview** shows how many card lines in how many decks would change. **Full report** lists the details.
- **Apply to decks** makes the changes after a confirmation, backing everything up first.
- **Save settings** stores your rules and picks without applying anything. Apply saves them too.

## How a printing is chosen

For each card in each deck, the tool narrows the card's printings down step by step:

1. **Exclusions** remove the kinds of printing you never want. Everything left is *allowed*.
2. **Language:** if you chose one, and some allowed printings were printed in it, only those are kept.
3. **Old frame:** if you prefer it, and some allowed printings have the old frame, only those are kept. Old
   frame means sets from before Eighth Edition (2003), plus retro-frame reprints in newer sets.
4. **With up-to-date text** (needs old frame; on by default): if a card has old-frame reprints from 2004 on,
   only those are kept. That includes retro frames, 30th Anniversary Edition, Retro Artifacts and Commander
   sets. You get the old look with current card wording. Cards without such a reprint keep the originals.
5. **Catch-all sets** (The List, Mystery Booster) and Un-sets are only used if nothing else is left.
6. Then either:
   - **Spread across decks** (the default): each deck gets one of the printings that are left, so a card
     varies from deck to deck; or
   - **Use one**: every deck gets the same printing, the **Latest** or the **Oldest**.

**Your own picks win over all of these rules.**

A line that already uses the set chosen for its deck is left as it is, so a particular art already in a deck
survives.

### Spreading

When a card has several printings to choose from, through the rules' spread or your own picks, each deck gets
one of them:

- **It isn't random.** The printing is worked out from the card and the deck's file name, so running the tool
  again gives the same result.
- **Changes move as little as possible.** Adding a printing only moves the decks that switch to it. Removing
  one only moves the decks that had it.
- **Order doesn't matter.** The order you picked printings in makes no difference.

### Exclusions

| Exclusion | What it covers | Always? |
|---|---|---|
| Universes Beyond | Universes Beyond sets (Lord of the Rings, Final Fantasy, Marvel, Star Trek...) | yes |
| Secret Lair | Secret Lair | yes |
| Masterpiece | Inventions, Invocations, Expeditions, Mystical Archive | yes |
| Promo | Promo sets, and promo, buy-a-box, bundle and box-topper printings | yes |
| Digital only | Alchemy, Arena and Magic Online | yes |
| Borderless | Borderless printings | no |
| Extended art | Extended-art printings | no |
| Full art | Full-art printings | no |
| Showcase | Showcase and etched printings | no |
| White border | White-bordered sets (Revised to Ninth Edition, Portal Three Kingdoms...) | no |
| Gold border | Gold-bordered printings* | no |
| Inverted | Inverted-frame printings* | no |
| Thick | Thick-stock printings, such as display commanders* | no |

\* Only known with the [card details from Scryfall](#card-details-from-scryfall).

The two kinds of exclusion behave differently when a card has nothing else:

- **"Always" exclusions are never broken.** A card that only exists in them, such as a Universes Beyond-only
  card, keeps the printing its deck already has.
- **The others give way only if a card has no other printing.** The report lists those cards.

**New Universes Beyond sets:** Forge's files don't say which sets are Universes Beyond, so the tool carries its
own list. You can see it under *Sets already counted as UB* in the picker. When a new UB set comes out, add
its set code in *Also count these set codes as Universes Beyond*. The Scryfall card details also catch UB
printings by their security stamp.

### Your language

Forge shows card pictures in the **Card download language** set in Forge's preferences, when the printing was
made in that language, and in English otherwise. Many printings never were; most older sets were never
printed in Japanese or Chinese, for example. So the tool can choose printings that were.

- **Choosing it:** pick the language under **Prefer**. It starts out as Forge's own Card download language.
  Set the same language in Forge, so it shows the cards in it.
- **Where the tool learns which printings exist in a language:**
  - Forge's own records, which grow as Forge downloads pictures.
  - The Scryfall card details, which download the complete list for your language.
- **In the picker:** printings in your language are tagged, and their pictures are shown in it.

## Card details from Scryfall

Forge's set files only mark some treatments:

- Many full-art, borderless and showcase printings are listed as ordinary cards.
- So are most retro-frame reprints, including whole sets such as The Brothers' War Commander and Retro
  Artifacts. They wouldn't count as old frame.
- Inverted frames, thick stock and gold borders aren't recorded at all.

[Scryfall](https://scryfall.com) records all of these. Click **Download from Scryfall** under *Card details*,
or use `--update-scryfall` on the command line, and the tool fetches:

- which printings have each treatment;
- which have the old frame;
- which carry the Universes Beyond stamp;
- which exist in your chosen language.

It takes a minute or two, because Scryfall sends tens of thousands of printings a page at a time. The details
are saved and used automatically from then on. Click **Update from Scryfall** after new sets come out, or
after changing your language.

A printing can carry several tags, for example Secret Lair, borderless and inverted. It's excluded if any of
them is.

## Adventure rewards and shops

Adventure rewards and shop cards are made while you play, not read from deck files. When Forge hands out a
card by name, it uses its own per-card art preference: the setting Forge's deck editor changes with *Change
preferred art*. That covers random card rewards, single-card shop items and anything else that picks "a"
printing of a card.

Tick **Also use these printings for Adventure rewards and shop cards**. **Apply** then also writes your choice
for every card into Forge's `card.preferences` file, in Forge's preferences folder. It keeps your card star
ratings, and it's backed up with your decks.

- **Close Forge first.** Forge saves that file itself and could overwrite the change when it exits.
- In Adventure's settings, keep **Use Card Variants from All Sets** off, which is the default. With it on,
  Forge gives every reward a random printing instead.
- Rewards get one printing per card: the first of your picks, or what **Use one** would choose.
- **Booster packs aren't affected.** A pack always holds its own set's printings, as a real one would.
- The preference applies to the rest of Forge too, wherever Forge picks a printing by name.

## Backups, undo and Forge updates

**Undo:**

- **Every Apply backs up** the decks it changes, and `card.preferences` when that option is on. Backups go in a
  dated folder inside `preferred-printings-backups`.
- **To undo**, run the command shown when the change is made, for example:

  ```bash
  python preferred_printings.py --restore "preferred-printings-backups/20261104-221500"
  ```

  It puts every file back. A `card.preferences` file the tool created is removed again.

**Forge updates** replace Forge's own files, so the Adventure decks go back to their original printings. Your
settings are kept, so open the picker and **Apply** again, or use the command line below. Your own decks and
`card.preferences` aren't touched by updates.

**Existing Adventure saves** keep the starting deck they began with, and shops that were already stocked keep
their cards. New games, new rewards and newly stocked shops use the new printings.

## Command line

Everything the picker does can be done from a terminal. Without `--apply` nothing is changed: it only reports
what would change.

```bash
python preferred_printings.py --forge "C:\Games\Forge" --user-decks
```

```bash
python preferred_printings.py --forge "C:\Games\Forge" --user-decks --apply
```

Use `python3` on Mac and Linux. With no options at all, the tool opens the picker.

**Repeating a setup:** save your options once with `--save-config FILE`, then apply them, for example after
every Forge update:

```bash
python preferred_printings.py --config preferred-printings.json --apply
```

The picker's **Save settings** writes the same file, `preferred-printings.json` next to the script. Options
given on the command line override the file.

### Options

| Option | What it does |
|---|---|
| `--gui` | Open the picker (the same as running with no options) |
| `--forge PATH` | Your Forge folder (the one containing `res`), or `Forge.app` on a Mac |
| `--decks PATH` | A folder of `.dck` files to change; repeatable. Default: Forge's Adventure decks |
| `--user-decks` | Also change your own decks |
| `--skip-dir PATH` | Leave a sub-folder alone; repeatable |
| `--no-skip-set-named-decks` | Also change product decks such as `4ED - Black Starter.dck` |
| `--exclude CATEGORY ...` | Exactly what to exclude (default: everything). On its own: exclude nothing |
| `--include CATEGORY ...` | Allow these categories again |
| `--ub-set CODE` | Also count this set as Universes Beyond; repeatable |
| `--no-prefer-old-frame` | Don't prefer the old frame |
| `--no-modern-text` | With old frame, include the original printings too, not only reprints with current text |
| `--language CODE` | Prefer printings in `es`, `fr`, `de`, `it`, `pt`, `ja`, `ko`, `ru`, `zhs` or `zht`; `en` for none. Default: Forge's own setting |
| `--no-spread` | Give every deck the same printing of a card |
| `--order latest\|oldest` | With `--no-spread`: which printing (default: latest) |
| `--update-scryfall` | Download the card details from Scryfall first |
| `--card-prefs` | Also write Forge's `card.preferences` for rewards and shops |
| `--apply` | Make the changes (otherwise: preview only) |
| `--no-backup` | Don't back up before changing |
| `--backup-dir PATH` | Where backups go |
| `--restore BACKUP` | Put back the files in a backup folder |
| `--report FILE` | Write the full report: every folder, skipped deck, card left unchanged, and sample changes |
| `--quiet` | Only print the one-line result |
| `--config FILE` | Load settings from a file |
| `--save-config FILE` | Save these options to a file, then stop |
| `--scryfall-cache FILE` | Where the Scryfall card details are kept |
| `--image-cache PATH` | Where Forge's card pictures are, if the picker can't find them |
| `--no-online-images` | Keep the picker offline |

The exclusion categories are `ub`, `secret-lair`, `masterpiece`, `promo`, `digital`, `borderless`,
`extended-art`, `full-art`, `showcase`, `white-border`, `gold-border`, `inverted` and `thick`.

### Settings file

`preferred-printings.json` is plain JSON and can be edited by hand. Its keys match the options:

- **What to change:** `forge`, `decks`, `user_decks`, `skip_dir`, `skip_set_named_decks`.
- **Rules:** `exclude`, `extra_ub_sets`, `prefer_old_frame`, `modern_text`, `language`, `spread`, `order`.
- **Rewards and shops:** `card_prefs`.
- **Backups:** `backup`, `backup_dir`.
- **Card details and pictures:** `scryfall_cache`, `image_cache`, `online_images`.
- **Your own picks:** `card_choices`. Each card takes one printing or a list, written as `SET|collector number`:

  ```json
  "card_choices": {"Sol Ring": ["LEB|270", "30A|563"], "Lightning Bolt": "M10|146"}
  ```

## Files the tool creates

All of these are kept next to `preferred_printings.py`. On the command line they go next to the settings
file, or in the current folder if there isn't one.

| File or folder | What it holds |
|---|---|
| `preferred-printings.json` | Your settings and picks |
| `preferred-printings-scryfall.json` | The card details from Scryfall |
| `preferred-printings-images/` | Card pictures downloaded for the picker |
| `preferred-printings-backups/` | Backups made before each Apply |

Outside that folder, the tool only changes the files you choose:

- the deck files you chose;
- `card.preferences`, only with the rewards-and-shops option.

The picker runs only on your computer and nothing is uploaded. It only connects to Scryfall: for pictures
Forge hasn't downloaded, and when you download the card details.

## Troubleshooting

**Nothing changed in the game.**

- **Check the Forge folder.** The top of the picker's sidebar shows which Forge it's changing. If you play an
  installed Forge, it must point there, not at a source checkout.
- **Start a new game.** Existing Adventure saves keep their starting deck.
- **Rewards and shops:** tick the option, close Forge before applying, and keep Adventure's *Use Card
  Variants from All Sets* off.

**A card shows the wrong frame or treatment tags.** Download, or update, the card details from Scryfall.
Forge's own files don't mark many full-art, borderless and retro-frame printings.

**A new Universes Beyond set isn't being excluded.** Add its set code under *Also count these set codes as
Universes Beyond*, and update the card details from Scryfall.

**Some pictures say "No image".** Scryfall has no picture for that printing, or the computer is offline, or
*Fetch missing images from Scryfall* is off.

**A note appears under Card details.** Scryfall rejected one of the tool's searches, and the note says which
one. The other details are still used. Please report the note.

**Double-clicking opens the file in an editor instead of running it.** Run it from a terminal with
`python preferred_printings.py`. Or, on Windows, right-click the file and choose *Open with → Python*.

## Limits

- Only deck files change, plus `card.preferences` for rewards and shops. Booster packs keep their own set's
  printings.
- Without the Scryfall card details, the tool only knows the treatments Forge's files mark. Many full-art,
  borderless and retro-frame printings go untagged, and the inverted, thick and gold-border filters have
  nothing to go on.
- Some sets list ordinary printings under a treatment in Forge's files, such as Commander Masters' precon cards
  under borderless. The Scryfall details add tags, but they can't remove Forge's.
- Adventure planes that limit cards to certain sets keep to those sets.
- Un-set cards aren't included in `card.preferences`, because Forge handles their variants differently.
