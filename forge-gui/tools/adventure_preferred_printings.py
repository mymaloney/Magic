#!/usr/bin/env python3
"""Re-pin the card printings used by Adventure mode deck files (.dck) to preferred printings.

Every card line in a deck is rewritten to "Name|SET|[collector number]", using the printing that best
matches the chosen rules. Rules come from Forge's own edition files (forge-gui/res/editions), so no
network access is needed.

By default this is a dry run: it writes a report and changes nothing. Pass --apply to rewrite the decks.
See README-adventure_preferred_printings.md for details.
"""
import argparse
import collections
import glob
import json
import os
import re
import sys

# Universes Beyond sets (and their promo/companion sets) as named in Forge's edition files.
UB_SETS = {'40K', 'ACR', 'BOT', 'FCA', 'FIC', 'FIN', 'HOB', 'HOC', 'LMAR', 'LTC', 'LTR', 'MAR', 'MDC', 'MDD',
           'MSC', 'MSH', 'PIP', 'PLTC', 'PZA', 'REX', 'RFIN', 'SPE', 'SPM', 'TLA', 'TLE', 'TMC', 'TMT', 'WHO'}
SECRET_LAIR_SETS = {'SLD', 'SLU', 'SLC', 'SLP', 'PSSC'}
MASTERPIECE_SETS = {'MP2', 'MPS_KLD', 'EXP', 'ZNE', 'STA', 'SOA'}
# Sets dated before many of the cards they contain; ranked last so their date doesn't win "oldest".
CATCH_ALL_SETS = {'PLST', 'MB1', 'MB2', 'PLIST', 'ULST'}
LOW_PRIORITY_TYPES = {'Collector_Edition', 'Funny'}
OLD_FRAME_CUTOFF = '2003-07-28'  # Eighth Edition introduced the modern frame

# Edition sections (lowercase headers in the edition files) mapped to a filter category.
SECTION_CATEGORY = {
    'borderless': 'borderless',
    'extended art': 'extended-art',
    'showcase': 'showcase',
    'etched': 'showcase',
    'full art': 'full-art',
    'promo': 'promo',
    'prerelease promo': 'promo',
    'buy a box': 'promo',
    'bundle': 'promo',
    'box topper': 'promo',
    'rebalanced': 'digital',
    'conjured': 'digital',
}
# Sections Forge loads as card printings: keep in sync with CardEdition.EditionSectionWithCollectorNumbers.
# Printings listed in any other section (e.g. [special guests], [fullart]) can't be resolved by deck files.
LOADED_SECTIONS = {'cards', 'special slot', 'precon product', 'borderless', 'etched', 'showcase', 'full art',
                   'extended art', 'alternate art', 'retro frame', 'buy a box', 'promo', 'prerelease promo',
                   'bundle', 'box topper', 'jumpstart', 'rebalanced', 'eternal', 'conjured', 'scheme'}

# Every category that can be excluded, and whether it is a "hard" exclusion.
# Soft exclusions are relaxed for a card when no printing survives all of them (and reported).
CATEGORIES = {
    'ub': ('Universes Beyond sets', True),
    'secret-lair': ('Secret Lair sets', True),
    'masterpiece': ('Masterpiece sets (Inventions, Invocations, Expeditions, Mystical Archive)', True),
    'promo': ('promo sets, and promo/buy-a-box/bundle printings inside normal sets', True),
    'digital': ('Alchemy, Arena and Magic Online sets', True),
    'borderless': ('borderless printings', False),
    'extended-art': ('extended art printings', False),
    'full-art': ('full art printings', False),
    'showcase': ('showcase and etched printings', False),
    'white-border': ('white-bordered sets (Revised to Ninth Edition, Portal Three Kingdoms...)', False),
}

Printing = collections.namedtuple('Printing', 'set cn section date type border')
DECK_LINE = re.compile(r'^(\d+)\s+(.+?)\s*$')
EDITION_LINE = re.compile(r'^(\S+)\s+\S+\s+(.+?)(\s+@.*)?$')
SET_NAMED_DECK = re.compile(r'^([A-Za-z0-9_]+) - ')


def parse_editions(editions_dir):
    by_name = collections.defaultdict(list)
    codes = set()
    for path in glob.glob(os.path.join(editions_dir, '*.txt')):
        meta, section, entries = {}, None, []
        with open(path, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                if line.startswith('[') and line.endswith(']'):
                    header = line[1:-1]
                    section = header if header in LOADED_SECTIONS or header == 'metadata' else None
                    continue
                if section == 'metadata':
                    key, _, value = line.partition('=')
                    meta[key] = value
                elif section:
                    m = EDITION_LINE.match(line)
                    if m and re.match(r'^[0-9A-Za-z★†\-]+$', m.group(1)):
                        entries.append((m.group(1), m.group(2).strip(), section))
        code = meta.get('Code')
        if not code:
            continue
        codes.add(code.upper())
        for cn, name, section in entries:
            by_name[name.lower()].append(Printing(code, cn, section, meta.get('Date', '9999-99-99'),
                                                  meta.get('Type', ''), meta.get('Border', 'Black')))
    # Decks may name split cards and rooms by a single face.
    for full in list(by_name):
        if ' // ' in full:
            for face in full.split(' // '):
                by_name.setdefault(face, by_name[full])
    return by_name, codes


def category_of(p):
    """The filter category a printing falls into, or None for a regular printing."""
    if p.set in UB_SETS:
        return 'ub'
    if p.set in SECRET_LAIR_SETS:
        return 'secret-lair'
    if p.set in MASTERPIECE_SETS:
        return 'masterpiece'
    if p.type == 'Promo':
        return 'promo'
    if p.type in ('Online', 'Other'):
        return 'digital'
    if p.section in SECTION_CATEGORY:
        return SECTION_CATEGORY[p.section]
    if p.border == 'White':
        return 'white-border'
    return None


def is_old_frame(p):
    return p.section == 'retro frame' or p.date < OLD_FRAME_CUTOFF


def collector_key(cn):
    m = re.match(r'(\d+)', cn)
    return (int(m.group(1)) if m else 10 ** 9, cn)


def date_key(date, newest_first):
    if not newest_first:
        return date
    # Invert the date so that sorting ascending puts the newest first.
    return ''.join(chr(0x10FFFF - ord(c)) for c in date)


class Chooser:
    def __init__(self, by_name, args):
        self.by_name = by_name
        self.excluded = set(args.exclude)
        self.order_latest = args.order == 'latest'
        self.prefer_old_frame = args.prefer_old_frame
        self.cache = {}
        self.fallbacks = {}

    def rank(self, p):
        return (0 if (self.prefer_old_frame and is_old_frame(p)) else 1,
                1 if (p.set in CATCH_ALL_SETS or p.type in LOW_PRIORITY_TYPES) else 0,
                date_key(p.date, self.order_latest),
                0 if p.section == 'cards' else 1,
                collector_key(p.cn))

    def best(self, name, allowed_sets=None):
        key = (name.lower(), allowed_sets)
        if key in self.cache:
            return self.cache[key]
        prints = self.by_name.get(name.lower(), [])
        if allowed_sets is not None:
            prints = [p for p in prints if p.set.upper() in allowed_sets]
        ok = [p for p in prints if category_of(p) not in self.excluded]
        if not ok:
            hard = {c for c in self.excluded if CATEGORIES[c][1]}
            ok = [p for p in prints if category_of(p) not in hard]
            if ok:
                choice = min(ok, key=self.rank)
                self.fallbacks[name] = f'{choice.set} [{choice.cn}] ({category_of(choice)})'
        result = min(ok, key=self.rank) if ok else None
        self.cache[key] = result
        return result


def plane_legal_sets(adventure_dir):
    """Planes whose config limits cards to specific editions (e.g. a single-set plane)."""
    limits = {}
    for cfg in glob.glob(os.path.join(adventure_dir, '*', 'config.json')):
        try:
            with open(cfg, encoding='utf-8') as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        editions = (data.get('legalCards') or {}).get('editions')
        if editions:
            limits[os.path.basename(os.path.dirname(cfg))] = frozenset(e.upper() for e in editions)
    return limits


def process(args):
    res = os.path.abspath(args.res)
    adventure_dir = os.path.join(res, 'adventure')
    by_name, set_codes = parse_editions(os.path.join(res, 'editions'))
    chooser = Chooser(by_name, args)
    legal_limits = plane_legal_sets(adventure_dir)

    stats = collections.Counter()
    per_folder = collections.defaultdict(collections.Counter)
    kept = collections.Counter()
    unknown = collections.Counter()
    skipped_decks = []
    samples = []

    for path in sorted(glob.glob(os.path.join(adventure_dir, '**', '*.dck'), recursive=True)):
        rel = os.path.relpath(path, adventure_dir).replace(os.sep, '/')
        if any(rel.startswith(s.rstrip('/') + '/') for s in args.skip_dir):
            skipped_decks.append((rel, 'skipped folder'))
            continue
        m = SET_NAMED_DECK.match(os.path.basename(rel))
        if args.skip_set_named_decks and m and m.group(1).upper() in set_codes:
            skipped_decks.append((rel, 'set-named deck'))
            continue
        allowed_sets = legal_limits.get(rel.split('/', 1)[0])

        with open(path, encoding='utf-8', errors='replace') as f:
            original = f.read()
        out_lines, changed, section = [], 0, None
        for raw_with_end in original.splitlines(keepends=True):
            raw = raw_with_end.rstrip('\r\n')
            end = raw_with_end[len(raw):]
            s = raw.strip()
            if s.startswith('['):
                section = s.lower()
            m = DECK_LINE.match(s) if section != '[metadata]' else None
            if not m:
                out_lines.append(raw_with_end)
                continue
            count, rest = m.groups()
            parts = rest.split('|')
            name = parts[0].strip()
            foil = '+' if name.endswith('+') else ''
            name = name.rstrip('+').strip()
            old_set = parts[1].strip().upper() if len(parts) > 1 else ''
            stats['card lines'] += 1
            if name.lower() not in by_name:
                unknown[name] += 1
                out_lines.append(raw_with_end)
                continue
            choice = chooser.best(name, allowed_sets)
            if choice is None:
                kept[name] += 1
                stats['kept: no allowed printing'] += 1
                out_lines.append(raw_with_end)
                continue
            new = f'{count} {name}{foil}|{choice.set}|[{choice.cn}]'
            # Already in the preferred set: keep the line, so a hand-picked art variant survives.
            if s == new or old_set == choice.set.upper():
                stats['already preferred'] += 1
                out_lines.append(raw_with_end)
                continue
            stats['pinned (had no set)' if not old_set else 'repinned'] += 1
            changed += 1
            if len(samples) < 50 and old_set and old_set != choice.set.upper():
                samples.append(f'{rel}: `{rest}` -> `{choice.set}|[{choice.cn}]`')
            out_lines.append(new + end)

        folder = os.path.dirname(rel)
        per_folder[folder]['decks'] += 1
        per_folder[folder]['lines changed'] += changed
        if changed:
            per_folder[folder]['decks changed'] += 1
            if args.apply:
                with open(path, 'w', encoding='utf-8', newline='') as f:
                    f.write(''.join(out_lines))

    report = build_report(args, stats, per_folder, chooser, kept, unknown, skipped_decks, samples)
    if args.report:
        with open(args.report, 'w', encoding='utf-8') as f:
            f.write(report)
        print(f'Report written to {args.report}')
    else:
        print(report)
    print(('Applied' if args.apply else 'Dry run (use --apply to write)') +
          f": {stats['repinned'] + stats['pinned (had no set)']} card lines in "
          f"{sum(c['decks changed'] for c in per_folder.values())} decks", file=sys.stderr)


def build_report(args, stats, per_folder, chooser, kept, unknown, skipped_decks, samples):
    lines = ['# Adventure preferred printings', '',
             f"- mode: {'applied' if args.apply else 'dry run'}",
             f'- order: {args.order}; prefer old frame: {args.prefer_old_frame}',
             f"- excluded: {', '.join(sorted(args.exclude)) or 'nothing'}",
             f"- skipped folders: {', '.join(args.skip_dir) or 'none'}; "
             f'skip set-named decks: {args.skip_set_named_decks}', '', '## Totals']
    lines += [f'- {k}: {v}' for k, v in stats.most_common()]
    resolved = [p for p in chooser.cache.values() if p]
    lines.append(f'- distinct cards resolved: {len(resolved)} '
                 f'({sum(1 for p in resolved if is_old_frame(p))} on an old-frame printing)')
    lines += ['', '## By folder (decks / decks changed / lines changed)']
    lines += [f"- {f}: {c['decks']} / {c['decks changed']} / {c['lines changed']}"
              for f, c in sorted(per_folder.items())]
    chosen = collections.Counter(p.set for p in resolved)
    lines += ['', '## Sets most often chosen (distinct cards)']
    lines += [f'- {s}: {n}' for s, n in chosen.most_common(25)]
    lines += ['', f'## Skipped decks ({len(skipped_decks)})']
    lines += [f'- {d} ({why})' for d, why in skipped_decks]
    lines += ['', f'## Left unchanged: every printing excluded ({len(kept)})']
    lines += [f'- {n} ({k})' for n, k in kept.most_common()]
    lines += ['', f'## Soft-exclusion fallbacks: only an excluded treatment exists ({len(chooser.fallbacks)})']
    lines += [f'- {n}: {v}' for n, v in sorted(chooser.fallbacks.items())]
    lines += ['', f'## Names not found in edition files ({len(unknown)})']
    lines += [f'- {n} ({k})' for n, k in unknown.most_common()]
    lines += ['', '## Sample changes'] + [f'- {s}' for s in samples]
    return '\n'.join(lines) + '\n'


def main():
    default_res = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'res'))
    cats = '\n'.join(f'  {k:13} {v[0]}{" (hard)" if v[1] else ""}' for k, v in CATEGORIES.items())
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f'Exclusion categories:\n{cats}\n\nHard exclusions are never relaxed. Soft ones are relaxed '
               'for a card only when no other printing exists.')
    parser.add_argument('--res', default=default_res, help='Forge res folder (default: %(default)s)')
    parser.add_argument('--apply', action='store_true', help='rewrite the deck files (default: dry run)')
    parser.add_argument('--report', help='write the report to this file instead of stdout')
    parser.add_argument('--order', choices=('latest', 'oldest'), default='latest',
                        help='which printing wins among equally preferred ones (default: %(default)s)')
    parser.add_argument('--prefer-old-frame', action=argparse.BooleanOptionalAction, default=True,
                        help='prefer pre-Eighth Edition frames and retro-frame reprints (default: on)')
    parser.add_argument('--exclude', nargs='*', choices=sorted(CATEGORIES), default=sorted(CATEGORIES),
                        metavar='CATEGORY', help='categories to exclude (default: all of them)')
    parser.add_argument('--include', nargs='*', choices=sorted(CATEGORIES), default=[], metavar='CATEGORY',
                        help='categories to allow again, removed from --exclude')
    parser.add_argument('--skip-dir', action='append', default=[], metavar='PATH',
                        help='deck folder (relative to res/adventure) to leave alone; repeatable')
    parser.add_argument('--skip-set-named-decks', action=argparse.BooleanOptionalAction, default=True,
                        help='leave decks named after a product, like "4ED - Black Starter.dck" (default: on)')
    args = parser.parse_args()
    args.exclude = [c for c in args.exclude if c not in set(args.include)]
    process(args)


if __name__ == '__main__':
    main()
