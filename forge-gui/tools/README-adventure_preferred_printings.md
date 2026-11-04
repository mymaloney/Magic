# Adventure preferred printings

`adventure_preferred_printings.py` re-pins every card in the Adventure deck files
(`forge-gui/res/adventure/**/*.dck`) to a preferred printing, written as `Name|SET|[collector number]`.
It reads Forge's own edition files, so it needs no network access and only picks printings Forge can load.

By default it is a **dry run**: it prints a report and changes nothing.

```bash
python3 forge-gui/tools/adventure_preferred_printings.py --report preferred-printings.md
```

```bash
python3 forge-gui/tools/adventure_preferred_printings.py --apply
```

## How a printing is chosen

1. Printings in an excluded category are dropped (all categories are excluded by default).
2. With `--prefer-old-frame` (default on), old-frame printings come first: sets released before
   Eighth Edition (2003-07-28) and the `[retro frame]` reprints in newer sets.
3. Among the rest, `--order latest` (default) picks the newest printing; `--order oldest` the first one.
   Catch-all sets such as The List and Mystery Booster, and collector/joke sets, are ranked last.
4. Ties go to the set's regular `[cards]` section, then the lowest collector number.

A line already using the chosen set is left alone, so hand-picked art variants survive.

## Exclusion categories

| Category | What it covers | Hard? |
|---|---|---|
| `ub` | Universes Beyond sets | yes |
| `secret-lair` | Secret Lair sets | yes |
| `masterpiece` | Inventions, Invocations, Expeditions, Mystical Archive | yes |
| `promo` | Promo sets, and promo/buy-a-box/bundle/box-topper printings inside normal sets | yes |
| `digital` | Alchemy, Arena and Magic Online sets | yes |
| `borderless` | `[borderless]` printings | no |
| `extended-art` | `[extended art]` printings | no |
| `full-art` | `[full art]` printings | no |
| `showcase` | `[showcase]` and `[etched]` printings | no |
| `white-border` | White-bordered sets (Revised to Ninth Edition, Portal Three Kingdoms...) | no |

Hard exclusions are never relaxed: a card with no other printing keeps its current line.
Soft exclusions are relaxed for a card only when nothing else exists; the report lists those cards.

Allow a category again with `--include`, e.g. `--include white-border digital`,
or give the full list with `--exclude`.

## Which decks are touched

- `--skip-set-named-decks` (default on) leaves decks named after a product, like
  `4ED - Black Starter.dck` or `PIP - Science!.dck`, so preconstructed products keep their printings.
  Use `--no-skip-set-named-decks` to include them.
- `--skip-dir PATH` (repeatable) leaves a folder alone, e.g. `--skip-dir "Shandalar Old Border"`.
- Planes whose `config.json` limits cards with `legalCards.editions` only get printings from those sets
  (Crystal_Kingdoms stays Final Fantasy).

## Limits

- Forge's edition files don't record the inverted frame or thick stock, and there are no gold-bordered sets,
  so those can't be filtered.
- Some sets list treated printings in `[cards]`, or regular ones in a treatment section; the tool can only
  go by the section a printing is listed in.
- Only bundled deck files change. Cards generated during play (rewards, shops, boosters) are not affected.
