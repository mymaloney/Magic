#!/usr/bin/env python3
"""Re-pin the cards in Forge deck files (.dck) to the printings you prefer.

Every card line is rewritten to "Name|SET|[collector number]", using the printing that best matches
your rules: which kinds of printings to exclude (Secret Lair, Universes Beyond, promos, borderless...),
whether to prefer the old frame, and whether to take the latest or the oldest printing.
Only the version of each card changes, never the card itself.

It reads Forge's own edition files, so it works on a normal Forge install or a source checkout,
with no network access. By default it is a dry run: it prints a report and changes nothing.
Pass --apply to rewrite the decks. See README-preferred_printings.md for details.
"""
import argparse
import collections
import datetime
import glob
import json
import os
import re
import shutil
import sys

# Universes Beyond sets (and their promo/companion sets) as named in Forge's edition files.
UB_SETS = {'40K', 'ACR', 'BOT', 'FCA', 'FIC', 'FIN', 'HOB', 'HOC', 'LMAR', 'LTC', 'LTR', 'MAR', 'MDC', 'MDD',
           'MSC', 'MSH', 'PIP', 'PLTC', 'PZA', 'REX', 'RFIN', 'SPE', 'SPM', 'TLA', 'TLE', 'TMC', 'TMT', 'WHO'}
SECRET_LAIR_SETS = {'SLD', 'SLU', 'SLC', 'SLP', 'PSSC'}
MASTERPIECE_SETS = {'MP2', 'MPS_KLD', 'EXP', 'ZNE', 'STA', 'SOA'}
# Sets dated before many of the cards they contain; ranked last so their date doesn't decide the order.
CATCH_ALL_SETS = {'PLST', 'MB1', 'MB2', 'PLIST', 'ULST'}
LOW_PRIORITY_TYPES = {'Collector_Edition', 'Funny'}
OLD_FRAME_CUTOFF = '2003-07-28'  # Eighth Edition introduced the modern frame

# Sections Forge loads as card printings: keep in sync with CardEdition.EditionSectionWithCollectorNumbers.
# Printings listed in any other section (e.g. [special guests], [fullart]) can't be resolved by deck files.
LOADED_SECTIONS = {'cards', 'special slot', 'precon product', 'borderless', 'etched', 'showcase', 'full art',
                   'extended art', 'alternate art', 'retro frame', 'buy a box', 'promo', 'prerelease promo',
                   'bundle', 'box topper', 'jumpstart', 'rebalanced', 'eternal', 'conjured', 'scheme'}
# Edition sections mapped to a filter category.
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

# Options that a settings file (--config / --save-config) can hold.
SAVED_OPTIONS = ('forge', 'decks', 'user_decks', 'order', 'prefer_old_frame', 'exclude', 'skip_dir',
                 'skip_set_named_decks', 'backup', 'backup_dir')

Printing = collections.namedtuple('Printing', 'set cn section date type border')
DECK_LINE = re.compile(r'^(\d+)\s+(.+?)\s*$')
EDITION_LINE = re.compile(r'^(\S+)\s+\S+\s+(.+?)(\s+@.*)?$')
SET_NAMED_DECK = re.compile(r'^([A-Za-z0-9_]+) - ')
MANIFEST = 'preferred-printings-backup.json'


# ---------------------------------------------------------------- locating Forge's files

def find_res(forge_path):
    """The res folder of a Forge install or source checkout (the folder holding editions/)."""
    candidates = [forge_path,
                  os.path.join(forge_path, 'res'),
                  os.path.join(forge_path, 'forge-gui', 'res'),
                  os.path.join(forge_path, 'Contents', 'Resources', 'res'),
                  os.path.join(forge_path, 'Forge.app', 'Contents', 'Resources', 'res')]
    for c in candidates:
        if os.path.isdir(os.path.join(c, 'editions')):
            return os.path.abspath(c)
    return None


def default_forge_path():
    here = os.path.dirname(os.path.abspath(__file__))
    for c in (os.path.join(here, '..'), here, os.getcwd()):
        if find_res(c):
            return c
    return None


def default_user_decks_dir():
    """Where Forge keeps a player's own decks, matching ForgeProfileProperties' defaults."""
    home = os.path.expanduser('~')
    if sys.platform.startswith('win'):
        root = os.environ.get('APPDATA') or os.path.join(home, '.forge')
        return os.path.join(root, 'Forge', 'decks')
    if sys.platform == 'darwin':
        return os.path.join(home, 'Library', 'Application Support', 'Forge', 'decks')
    return os.path.join(home, '.forge', 'decks')


# ---------------------------------------------------------------- reading editions

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


def legal_sets_for(path, root, cache):
    """Edition limit from the nearest Adventure plane config.json (legalCards.editions), if any."""
    folder = os.path.dirname(path)
    while True:
        if folder not in cache:
            limit = None
            cfg = os.path.join(folder, 'config.json')
            if os.path.isfile(cfg):
                try:
                    with open(cfg, encoding='utf-8') as f:
                        editions = (json.load(f).get('legalCards') or {}).get('editions')
                    if editions:
                        limit = frozenset(e.upper() for e in editions)
                except (OSError, ValueError, AttributeError):
                    pass
            cache[folder] = limit
        if cache[folder] is not None or os.path.normcase(folder) == os.path.normcase(root):
            return cache[folder]
        parent = os.path.dirname(folder)
        if parent == folder:
            return None
        folder = parent


# ---------------------------------------------------------------- rewriting decks

def rewrite(text, chooser, by_name, allowed_sets, stats, kept, unknown, samples, label):
    out, changed, section = [], 0, None
    for raw_with_end in text.splitlines(keepends=True):
        raw = raw_with_end.rstrip('\r\n')
        end = raw_with_end[len(raw):]
        s = raw.strip()
        if s.startswith('['):
            section = s.lower()
        m = DECK_LINE.match(s) if section != '[metadata]' else None
        if not m:
            out.append(raw_with_end)
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
            out.append(raw_with_end)
            continue
        choice = chooser.best(name, allowed_sets)
        if choice is None:
            kept[name] += 1
            stats['kept: no allowed printing'] += 1
            out.append(raw_with_end)
            continue
        new = f'{count} {name}{foil}|{choice.set}|[{choice.cn}]'
        # Already in the preferred set: keep the line, so a hand-picked art variant survives.
        if s == new or old_set == choice.set.upper():
            stats['already preferred'] += 1
            out.append(raw_with_end)
            continue
        stats['pinned (had no set)' if not old_set else 'repinned'] += 1
        changed += 1
        if len(samples) < 50 and old_set:
            samples.append(f'{label}: `{rest}` -> `{choice.set}|[{choice.cn}]`')
        out.append(new + end)
    return ''.join(out), changed


def process(args):
    res = find_res(args.forge) if args.forge else None
    if not res:
        sys.exit('Could not find Forge\'s files. Point --forge at your Forge folder '
                 '(the one containing "res"), or at Forge.app on a Mac.')
    by_name, set_codes = parse_editions(os.path.join(res, 'editions'))
    chooser = Chooser(by_name, args)

    roots = [os.path.abspath(os.path.expanduser(d)) for d in args.decks]
    if args.user_decks:
        roots.append(default_user_decks_dir())
    if not roots:
        roots = [os.path.join(res, 'adventure')]
    roots = list(dict.fromkeys(os.path.normpath(r) for r in roots))  # drop duplicates, keep order
    for r in roots:
        if not os.path.isdir(r):
            sys.exit(f'Deck folder not found: {r}')

    backup_root = None
    if args.apply and args.backup:
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
        backup_root = os.path.abspath(os.path.join(os.path.expanduser(args.backup_dir), stamp))
    manifest = {'roots': {}, 'files': []}

    stats = collections.Counter()
    per_folder = collections.defaultdict(collections.Counter)
    kept, unknown = collections.Counter(), collections.Counter()
    skipped_decks, samples = [], []
    config_cache = {}

    for index, root in enumerate(roots):
        tag = f'{index}-{os.path.basename(root.rstrip(os.sep)) or "decks"}'
        manifest['roots'][tag] = root
        for path in sorted(glob.glob(os.path.join(glob.escape(root), '**', '*.dck'), recursive=True)):
            rel = os.path.relpath(path, root).replace(os.sep, '/')
            label = f'{os.path.basename(root)}/{rel}'
            if any(rel.startswith(s.replace(os.sep, '/').rstrip('/') + '/') for s in args.skip_dir):
                skipped_decks.append((label, 'skipped folder'))
                continue
            m = SET_NAMED_DECK.match(os.path.basename(rel))
            if args.skip_set_named_decks and m and m.group(1).upper() in set_codes:
                skipped_decks.append((label, 'set-named deck'))
                continue
            with open(path, encoding='utf-8', errors='replace', newline='') as f:
                original = f.read()
            allowed = legal_sets_for(path, root, config_cache)
            new_text, changed = rewrite(original, chooser, by_name, allowed, stats, kept, unknown, samples, label)

            folder = os.path.dirname(label)
            per_folder[folder]['decks'] += 1
            per_folder[folder]['lines changed'] += changed
            if not changed:
                continue
            per_folder[folder]['decks changed'] += 1
            if args.apply:
                if backup_root:
                    dest = os.path.join(backup_root, tag, rel)
                    os.makedirs(os.path.dirname(dest), exist_ok=True)
                    shutil.copy2(path, dest)
                    manifest['files'].append([tag, rel])
                with open(path, 'w', encoding='utf-8', newline='') as f:
                    f.write(new_text)

    if backup_root and manifest['files']:
        with open(os.path.join(backup_root, MANIFEST), 'w', encoding='utf-8') as f:
            json.dump(manifest, f, indent=1)

    report = build_report(args, res, roots, stats, per_folder, chooser, kept, unknown, skipped_decks, samples)
    if args.report:
        with open(args.report, 'w', encoding='utf-8') as f:
            f.write(report)
        print(f'Report written to {args.report}')
    elif not args.quiet:
        print(report.split('\n## By folder')[0] + '\n\n(Add --report FILE for the full details.)')
    lines = stats['repinned'] + stats['pinned (had no set)']
    decks = sum(c['decks changed'] for c in per_folder.values())
    if args.apply:
        print(f'Applied: {lines} card lines in {decks} decks.', file=sys.stderr)
        if backup_root and manifest['files']:
            print(f'Originals backed up to {backup_root}\n'
                  f'Undo with: --restore "{backup_root}"', file=sys.stderr)
    else:
        print(f'Dry run: {lines} card lines in {decks} decks would change. Add --apply to write them.',
              file=sys.stderr)


def restore(backup_root):
    manifest_path = os.path.join(backup_root, MANIFEST)
    if not os.path.isfile(manifest_path):
        sys.exit(f'No {MANIFEST} in {backup_root}; is this a backup folder made by this tool?')
    with open(manifest_path, encoding='utf-8') as f:
        manifest = json.load(f)
    count = 0
    for tag, rel in manifest['files']:
        dest = os.path.join(manifest['roots'][tag], rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(os.path.join(backup_root, tag, rel), dest)
        count += 1
    print(f'Restored {count} decks from {backup_root}')


def build_report(args, res, roots, stats, per_folder, chooser, kept, unknown, skipped_decks, samples):
    lines = ['# Preferred printings', '',
             f"- mode: {'applied' if args.apply else 'dry run'}",
             f'- Forge files: {res}',
             f"- deck folders: {', '.join(roots)}",
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


# ---------------------------------------------------------------- command line

def build_parser():
    cats = '\n'.join(f'  {k:13} {v[0]}{" (hard)" if v[1] else ""}' for k, v in CATEGORIES.items())
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f'Exclusion categories:\n{cats}\n\nHard exclusions are never relaxed. Soft ones are relaxed '
               'for a card only when no other printing exists.')
    where = p.add_argument_group('what to process')
    where.add_argument('--forge', metavar='PATH',
                       help='your Forge folder (the one containing "res"), Forge.app on a Mac, '
                            'or a source checkout; found automatically when run from inside one')
    where.add_argument('--decks', action='append', metavar='PATH',
                       help='a folder of .dck files to process (searched recursively); repeatable. '
                            'Default: the Adventure decks that ship with Forge')
    where.add_argument('--user-decks', action=argparse.BooleanOptionalAction, default=None,
                       help=f'also process your own decks, in {default_user_decks_dir()}')
    where.add_argument('--skip-dir', action='append', metavar='PATH',
                       help='folder (relative to a deck folder) to leave alone; repeatable')
    where.add_argument('--skip-set-named-decks', action=argparse.BooleanOptionalAction, default=None,
                       help='leave decks named after a product, like "4ED - Black Starter.dck" (default: on)')

    rules = p.add_argument_group('which printing to pick')
    rules.add_argument('--order', choices=('latest', 'oldest'),
                       help='which printing wins among equally preferred ones (default: latest)')
    rules.add_argument('--prefer-old-frame', action=argparse.BooleanOptionalAction, default=None,
                       help='prefer pre-Eighth Edition frames and retro-frame reprints (default: on)')
    rules.add_argument('--exclude', nargs='*', choices=sorted(CATEGORIES), metavar='CATEGORY',
                       help='categories to exclude (default: all of them)')
    rules.add_argument('--include', nargs='*', choices=sorted(CATEGORIES), default=[], metavar='CATEGORY',
                       help='categories to allow again, removed from the excluded ones')

    run = p.add_argument_group('running')
    run.add_argument('--apply', action='store_true', help='rewrite the deck files (default: dry run)')
    run.add_argument('--backup', action=argparse.BooleanOptionalAction, default=None,
                     help='copy each deck before changing it (default: on)')
    run.add_argument('--backup-dir', metavar='PATH',
                     help='where backups go; a dated folder is made inside (default: preferred-printings-backups)')
    run.add_argument('--restore', metavar='BACKUP',
                     help='put back the decks saved in this backup folder, then stop')
    run.add_argument('--report', metavar='FILE', help='write the full report to this file')
    run.add_argument('--quiet', action='store_true', help="don't print the summary")
    run.add_argument('--config', metavar='FILE',
                     help='load your choices from a settings file (options given on the command line win)')
    run.add_argument('--save-config', metavar='FILE',
                     help='save the choices from this command to a settings file, then stop')
    return p


DEFAULTS = {'forge': None, 'decks': [], 'user_decks': False, 'skip_dir': [], 'skip_set_named_decks': True,
            'order': 'latest', 'prefer_old_frame': True, 'exclude': sorted(CATEGORIES),
            'backup': True, 'backup_dir': 'preferred-printings-backups'}


def resolve_options(args):
    """Command line beats settings file beats built-in defaults."""
    saved = {}
    if args.config:
        with open(args.config, encoding='utf-8') as f:
            saved = json.load(f)
        unknown = set(saved) - set(SAVED_OPTIONS)
        if unknown:
            sys.exit(f"Unknown setting(s) in {args.config}: {', '.join(sorted(unknown))}")
        base = os.path.dirname(os.path.abspath(args.config))
        for key in ('forge', 'backup_dir'):  # relative paths in a settings file are relative to that file
            if saved.get(key):
                saved[key] = os.path.join(base, os.path.expanduser(saved[key]))
        if saved.get('decks'):
            saved['decks'] = [os.path.join(base, os.path.expanduser(d)) for d in saved['decks']]
    for key in SAVED_OPTIONS:
        if getattr(args, key) is None:
            setattr(args, key, saved.get(key, DEFAULTS[key]))
    bad = set(args.exclude) - set(CATEGORIES)
    if bad:
        sys.exit(f"Unknown exclusion categories: {', '.join(sorted(bad))}")
    args.exclude = sorted(c for c in args.exclude if c not in set(args.include))
    if not args.forge:
        args.forge = default_forge_path()
    return args


def main():
    args = resolve_options(build_parser().parse_args())
    if args.restore:
        restore(os.path.abspath(os.path.expanduser(args.restore)))
        return
    if args.save_config:
        data = {k: getattr(args, k) for k in SAVED_OPTIONS}
        if data['forge']:
            data['forge'] = os.path.abspath(data['forge'])
        data['decks'] = [os.path.abspath(os.path.expanduser(d)) for d in data['decks']]
        with open(args.save_config, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2)
            f.write('\n')
        print(f'Settings saved to {args.save_config}. Run again with: --config "{args.save_config}" --apply')
        return
    process(args)


if __name__ == '__main__':
    main()
