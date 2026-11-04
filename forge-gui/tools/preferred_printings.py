#!/usr/bin/env python3
"""Re-pin the cards in Forge deck files (.dck) to the printings you prefer.

Every card line is rewritten to "Name|SET|[collector number]", using the printing that best matches
your rules: which kinds of printings to exclude (Secret Lair, Universes Beyond, promos, borderless...),
whether to prefer the old frame, whether to take the latest or the oldest printing, and any printings
you picked yourself for particular cards. Only the version of each card changes, never the card itself.

Run with --gui to choose visually in your web browser. It reads Forge's own edition files and image
cache, so it works on a normal Forge install or a source checkout. By default the command line is a dry
run: it prints a summary and changes nothing; pass --apply to rewrite the decks.
See README-preferred_printings.md for details.
"""
import argparse
import collections
import datetime
import glob
import hashlib
import http.server
import json
import mimetypes
import os
import re
import secrets
import shutil
import sys
import threading
import unicodedata
import urllib.parse
import webbrowser

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

# Every category that can be excluded: (description, hard?, short label for the GUI).
# Soft exclusions are relaxed for a card when no printing survives all of them (and reported).
CATEGORIES = {
    'ub': ('Universes Beyond sets', True, 'Universes Beyond'),
    'secret-lair': ('Secret Lair sets', True, 'Secret Lair'),
    'masterpiece': ('Masterpiece sets (Inventions, Invocations, Expeditions, Mystical Archive)', True,
                    'Masterpiece'),
    'promo': ('promo sets, and promo/buy-a-box/bundle printings inside normal sets', True, 'Promo'),
    'digital': ('Alchemy, Arena and Magic Online sets', True, 'Digital only'),
    'borderless': ('borderless printings', False, 'Borderless'),
    'extended-art': ('extended art printings', False, 'Extended art'),
    'full-art': ('full art printings', False, 'Full art'),
    'showcase': ('showcase and etched printings', False, 'Showcase'),
    'white-border': ('white-bordered sets (Revised to Ninth Edition, Portal Three Kingdoms...)', False,
                     'White border'),
}

# Options that a settings file (--config / --save-config) can hold, with their defaults.
DEFAULTS = {'forge': None, 'decks': [], 'user_decks': False, 'skip_dir': [], 'skip_set_named_decks': True,
            'order': 'latest', 'prefer_old_frame': True, 'exclude': sorted(CATEGORIES),
            'backup': True, 'backup_dir': 'preferred-printings-backups', 'card_choices': {},
            'image_cache': None, 'online_images': True}
SAVED_OPTIONS = tuple(DEFAULTS)

Printing = collections.namedtuple('Printing', 'set cn section date type border card art arts')
SetInfo = collections.namedtuple('SetInfo', 'code name date type border code2 scryfall')
DECK_LINE = re.compile(r'^(\d+)\s+(.+?)\s*$')
EDITION_LINE = re.compile(r'^(\S+)\s+\S+\s+(.+?)(\s+@.*)?$')
SET_NAMED_DECK = re.compile(r'^([A-Za-z0-9_]+) - ')
MANIFEST = 'preferred-printings-backup.json'


class ToolError(Exception):
    """A problem the user can fix, reported without a traceback."""


# ---------------------------------------------------------------- locating Forge's files

def find_res(forge_path):
    """The res folder of a Forge install or source checkout (the folder holding editions/)."""
    if not forge_path:
        return None
    forge_path = os.path.expanduser(forge_path)
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


def read_profile(forge_path, res):
    """Folder overrides from forge.profile.properties, which sits next to the Forge program."""
    props = {}
    for folder in filter(None, {forge_path and os.path.expanduser(forge_path), res and os.path.dirname(res)}):
        path = os.path.join(folder, 'forge.profile.properties')
        if os.path.isfile(path):
            with open(path, encoding='utf-8', errors='replace') as f:
                for line in f:
                    key, sep, value = line.strip().partition('=')
                    if sep and not key.startswith('#'):
                        props[key.strip()] = value.strip().replace('\\\\', '\\')
            break
    return props


def default_dirs():
    """Forge's default user and cache folders, matching ForgeProfileProperties."""
    home = os.path.expanduser('~')
    if sys.platform.startswith('win'):
        user_root = os.environ.get('APPDATA') or os.path.join(home, '.forge')
        cache_root = os.environ.get('LOCALAPPDATA') or user_root
        return os.path.join(user_root, 'Forge'), os.path.join(cache_root, 'Forge', 'Cache')
    if sys.platform == 'darwin':
        return (os.path.join(home, 'Library', 'Application Support', 'Forge'),
                os.path.join(home, 'Library', 'Caches', 'Forge'))
    return os.path.join(home, '.forge'), os.path.join(home, '.cache', 'forge')


def user_decks_dir(profile=None):
    profile = profile or {}
    user_dir = profile.get('userDir') or default_dirs()[0]
    return profile.get('decksDir') or os.path.join(user_dir, 'decks')


def card_pics_dir(profile=None):
    profile = profile or {}
    cache_dir = profile.get('cacheDir') or default_dirs()[1]
    return profile.get('cardPicsDir') or os.path.join(cache_dir, 'pics', 'cards')


# ---------------------------------------------------------------- reading editions

class Editions:
    def __init__(self, editions_dir):
        self.by_name = collections.defaultdict(list)
        self.sets = {}
        for path in glob.glob(os.path.join(editions_dir, '*.txt')):
            self._read(path)
        # Forge numbers the arts of one card within a set in collector number order.
        groups = collections.defaultdict(list)
        for name, prints in self.by_name.items():
            for i, p in enumerate(prints):
                groups[(p.set, name)].append(i)
        for (code, name), idxs in groups.items():
            prints = self.by_name[name]
            ordered = sorted(idxs, key=lambda i: collector_key(prints[i].cn))
            for art, i in enumerate(ordered, 1):
                prints[i] = prints[i]._replace(art=art, arts=len(ordered))
        # Decks may name split cards and rooms by a single face.
        for full in list(self.by_name):
            if ' // ' in full:
                for face in full.split(' // '):
                    self.by_name.setdefault(face, self.by_name[full])
        self.codes = set(self.sets)

    def _read(self, path):
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
                    meta[key.strip()] = value.strip()
                elif section:
                    m = EDITION_LINE.match(line)
                    if m and re.match(r'^[0-9A-Za-z★†\-]+$', m.group(1)):
                        entries.append((m.group(1), m.group(2).strip(), section))
        code = meta.get('Code')
        if not code:
            return
        info = SetInfo(code, meta.get('Name', code), meta.get('Date', '9999-99-99'), meta.get('Type', ''),
                       meta.get('Border', 'Black'), meta.get('Code2', code),
                       meta.get('ScryfallCode', code).lower())
        self.sets[code.upper()] = info
        for cn, name, section in entries:
            self.by_name[name.lower()].append(
                Printing(code, cn, section, info.date, info.type, info.border, name, 1, 1))

    def get(self, name):
        return self.by_name.get(name.lower(), [])


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


def choice_key(p):
    return f'{p.set}|{p.cn}'


def normalize_choices(choices):
    """card_choices maps a card to one printing ("SET|CN") or a list of them; return name -> list."""
    out = {}
    for name, value in (choices or {}).items():
        values = [value] if isinstance(value, str) else list(value or [])
        values = list(dict.fromkeys(v.strip().upper() for v in values if isinstance(v, str) and v.strip()))
        if values:
            out[name] = values
    return out


def spread_pick(name, deck, picks):
    """Which of a card's allowed printings a deck gets: stable for the same deck, varied across decks.

    Rendezvous hashing: each printing gets a score per deck and the highest wins, so adding or removing a
    printing only moves the decks that must move, and the order of the picks doesn't matter."""
    def score(p):
        text = f'{name.lower()}\n{deck}\n{choice_key(p).upper()}'
        return hashlib.sha1(text.encode('utf-8')).digest()
    return max(picks, key=score)


class Chooser:
    def __init__(self, editions, opts):
        self.editions = editions
        self.excluded = set(opts.exclude)
        self.order_latest = opts.order == 'latest'
        self.prefer_old_frame = opts.prefer_old_frame
        self.card_choices = {k.lower(): v for k, v in normalize_choices(opts.card_choices).items()}
        self.cache = {}
        self.fallbacks = {}

    def rank(self, p):
        return (0 if (self.prefer_old_frame and is_old_frame(p)) else 1,
                1 if (p.set in CATCH_ALL_SETS or p.type in LOW_PRIORITY_TYPES) else 0,
                date_key(p.date, self.order_latest),
                0 if p.section == 'cards' else 1,
                collector_key(p.cn))

    def ranked(self, name):
        return sorted(self.editions.get(name), key=self.rank)

    def automatic(self, name, allowed_sets=None):
        """The printing the rules pick, ignoring the user's own picks."""
        prints = self.editions.get(name)
        if allowed_sets is not None:
            prints = [p for p in prints if p.set.upper() in allowed_sets]
        ok = [p for p in prints if category_of(p) not in self.excluded]
        if ok:
            return min(ok, key=self.rank), False
        hard = {c for c in self.excluded if CATEGORIES[c][1]}
        ok = [p for p in prints if category_of(p) not in hard]
        return (min(ok, key=self.rank), True) if ok else (None, False)

    def picks(self, name, allowed_sets=None):
        """The printings the user allowed for this card, in the order they were picked."""
        wanted = self.card_choices.get(name.lower())
        if not wanted:
            return []
        by_key = {choice_key(p).upper(): p for p in self.editions.get(name)
                  if allowed_sets is None or p.set.upper() in allowed_sets}
        return [by_key[k] for k in wanted if k in by_key]

    def best(self, name, allowed_sets=None, deck=None):
        """The printing to use. With several allowed by the user, each deck gets one of them."""
        picks = self.picks(name, allowed_sets)
        if len(picks) > 1:  # the user's own picks win over every rule
            return spread_pick(name, deck, picks) if deck is not None else picks[0]
        key = (name.lower(), allowed_sets)
        if key in self.cache:
            return self.cache[key]
        result = picks[0] if picks else None
        if result is None:
            result, fallback = self.automatic(name, allowed_sets)
            if fallback:
                self.fallbacks[name] = f'{result.set} [{result.cn}] ({category_of(result)})'
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


# ---------------------------------------------------------------- deck files

def deck_roots(opts, res, profile):
    roots = [os.path.abspath(os.path.expanduser(d)) for d in opts.decks]
    if opts.user_decks:
        roots.append(user_decks_dir(profile))
    if not roots:
        roots = [os.path.join(res, 'adventure')]
    return list(dict.fromkeys(os.path.normpath(r) for r in roots))  # drop duplicates, keep order


def iter_decks(roots, opts, set_codes, skipped=None):
    """Yield (root index, root, path, relative path) for every deck that should be processed."""
    for index, root in enumerate(roots):
        if not os.path.isdir(root):
            raise ToolError(f'Deck folder not found: {root}')
        for path in sorted(glob.glob(os.path.join(glob.escape(root), '**', '*.dck'), recursive=True)):
            rel = os.path.relpath(path, root).replace(os.sep, '/')
            label = f'{os.path.basename(root)}/{rel}'
            if any(rel.startswith(s.replace(os.sep, '/').rstrip('/') + '/') for s in opts.skip_dir):
                if skipped is not None:
                    skipped.append((label, 'skipped folder'))
                continue
            m = SET_NAMED_DECK.match(os.path.basename(rel))
            if opts.skip_set_named_decks and m and m.group(1).upper() in set_codes:
                if skipped is not None:
                    skipped.append((label, 'set-named deck'))
                continue
            yield index, root, path, rel


def parse_card_line(s):
    m = DECK_LINE.match(s)
    if not m:
        return None
    count, rest = m.groups()
    parts = rest.split('|')
    name = parts[0].strip()
    foil = '+' if name.endswith('+') else ''
    return count, rest, name.rstrip('+').strip(), foil, (parts[1].strip().upper() if len(parts) > 1 else '')



def rewrite(text, chooser, editions, allowed_sets, stats, kept, unknown, samples, label):
    out, changed, section = [], 0, None
    for raw_with_end in text.splitlines(keepends=True):
        raw = raw_with_end.rstrip('\r\n')
        end = raw_with_end[len(raw):]
        s = raw.strip()
        if s.startswith('['):
            section = s.lower()
        parsed = parse_card_line(s) if section != '[metadata]' else None
        if not parsed:
            out.append(raw_with_end)
            continue
        count, rest, name, foil, old_set = parsed
        stats['card lines'] += 1
        if not editions.get(name):
            unknown[name] += 1
            out.append(raw_with_end)
            continue
        choice = chooser.best(name, allowed_sets, deck=label)
        if choice is None:
            kept[name] += 1
            stats['kept: no allowed printing'] += 1
            out.append(raw_with_end)
            continue
        new = f'{count} {name}{foil}|{choice.set}|[{choice.cn}]'
        # Without picks of the user's own, a line already in the preferred set is kept, so an art variant
        # already in the deck survives. With picks, every deck gets exactly the printing chosen for it.
        if s == new or (not chooser.picks(name, allowed_sets) and old_set == choice.set.upper()):
            stats['already preferred'] += 1
            out.append(raw_with_end)
            continue
        stats['pinned (had no set)' if not old_set else 'repinned'] += 1
        changed += 1
        if len(samples) < 50 and old_set:
            samples.append(f'{label}: `{rest}` -> `{choice.set}|[{choice.cn}]`')
        out.append(new + end)
    return ''.join(out), changed


class Tool:
    """Forge's data plus the user's options; shared by the command line and the GUI."""

    def __init__(self, opts):
        self.opts = opts
        self.res = find_res(opts.forge)
        if not self.res:
            raise ToolError('Could not find Forge\'s files. Point --forge at your Forge folder '
                            '(the one containing "res"), or at Forge.app on a Mac.')
        self.profile = read_profile(opts.forge, self.res)
        self.editions = Editions(os.path.join(self.res, 'editions'))

    def roots(self):
        return deck_roots(self.opts, self.res, self.profile)

    def run(self, apply=False, report_path=None):
        opts, editions = self.opts, self.editions
        chooser = Chooser(editions, opts)
        roots = self.roots()
        backup_root = None
        if apply and opts.backup:
            stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
            backup_root = os.path.abspath(os.path.join(os.path.expanduser(opts.backup_dir), stamp))
        manifest = {'roots': {}, 'files': []}
        stats = collections.Counter()
        per_folder = collections.defaultdict(collections.Counter)
        kept, unknown = collections.Counter(), collections.Counter()
        skipped, samples = [], []
        config_cache = {}

        for index, root, path, rel in iter_decks(roots, opts, editions.codes, skipped):
            tag = f'{index}-{os.path.basename(root.rstrip(os.sep)) or "decks"}'
            manifest['roots'][tag] = root
            label = f'{os.path.basename(root)}/{rel}'
            with open(path, encoding='utf-8', errors='replace', newline='') as f:
                original = f.read()
            allowed = legal_sets_for(path, root, config_cache)
            new_text, changed = rewrite(original, chooser, editions, allowed, stats, kept, unknown, samples, label)
            folder = os.path.dirname(label)
            per_folder[folder]['decks'] += 1
            per_folder[folder]['lines changed'] += changed
            if not changed:
                continue
            per_folder[folder]['decks changed'] += 1
            if apply:
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
        else:
            backup_root = None

        report = build_report(opts, apply, self.res, roots, stats, per_folder, chooser, kept, unknown, skipped,
                              samples)
        if report_path:
            with open(report_path, 'w', encoding='utf-8') as f:
                f.write(report)
        return {'lines': stats['repinned'] + stats['pinned (had no set)'],
                'decks': sum(c['decks changed'] for c in per_folder.values()),
                'stats': dict(stats), 'backup': backup_root, 'report': report,
                'summary': report.split('\n## By folder')[0]}


def restore(backup_root):
    manifest_path = os.path.join(backup_root, MANIFEST)
    if not os.path.isfile(manifest_path):
        raise ToolError(f'No {MANIFEST} in {backup_root}; is this a backup folder made by this tool?')
    with open(manifest_path, encoding='utf-8') as f:
        manifest = json.load(f)
    count = 0
    for tag, rel in manifest['files']:
        dest = os.path.join(manifest['roots'][tag], rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(os.path.join(backup_root, tag, rel), dest)
        count += 1
    return count


def build_report(opts, apply, res, roots, stats, per_folder, chooser, kept, unknown, skipped_decks, samples):
    lines = ['# Preferred printings', '',
             f"- mode: {'applied' if apply else 'dry run'}",
             f'- Forge files: {res}',
             f"- deck folders: {', '.join(roots)}",
             f'- order: {opts.order}; prefer old frame: {opts.prefer_old_frame}',
             f"- excluded: {', '.join(sorted(opts.exclude)) or 'nothing'}",
             f'- cards with your own picks: {len(normalize_choices(opts.card_choices))}',
             f"- skipped folders: {', '.join(opts.skip_dir) or 'none'}; "
             f'skip set-named decks: {opts.skip_set_named_decks}', '', '## Totals']
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


# ---------------------------------------------------------------- settings files

def load_settings(path):
    with open(path, encoding='utf-8') as f:
        saved = json.load(f)
    unknown = set(saved) - set(SAVED_OPTIONS)
    if unknown:
        raise ToolError(f"Unknown setting(s) in {path}: {', '.join(sorted(unknown))}")
    base = os.path.dirname(os.path.abspath(path))
    for key in ('forge', 'backup_dir', 'image_cache'):  # relative paths are relative to the settings file
        if saved.get(key):
            saved[key] = os.path.join(base, os.path.expanduser(saved[key]))
    if saved.get('decks'):
        saved['decks'] = [os.path.join(base, os.path.expanduser(d)) for d in saved['decks']]
    return saved


def save_settings(opts, path):
    data = {k: getattr(opts, k) for k in SAVED_OPTIONS}
    for key in ('forge', 'image_cache'):
        if data[key]:
            data[key] = os.path.abspath(os.path.expanduser(data[key]))
    data['decks'] = [os.path.abspath(os.path.expanduser(d)) for d in data['decks']]
    data['card_choices'] = {k: (v[0] if len(v) == 1 else v)
                            for k, v in sorted(normalize_choices(data['card_choices']).items())}
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write('\n')


# ---------------------------------------------------------------- GUI

def strip_accents(s):
    return ''.join(c for c in unicodedata.normalize('NFKD', s) if not unicodedata.combining(c))


def image_file_names(p):
    """File names Forge may have used for this printing in its image cache (see ImageUtil)."""
    names = []
    full = p.card
    bases = [full.replace(' // ', ''), full.split(' // ')[0]] if ' // ' in full else [full]
    for base in bases:
        base = ''.join(c for c in strip_accents(base) if c not in '"/:?')
        variants = [str(p.art)] if p.arts > 1 else ['']
        if p.arts > 1 and p.art == 1:
            variants.append('')
        for v in variants:
            for infix in ('.fullborder', '.full'):
                for ext in ('.jpg', '.png'):
                    names.append(f'{base}{v}{infix}{ext}')
    return names


def find_cached_image(pics_dir, editions, p):
    if not pics_dir or not os.path.isdir(pics_dir):
        return None
    info = editions.sets.get(p.set.upper())
    folders = list(dict.fromkeys(filter(None, [info and info.code2, p.set])))
    for folder in folders:
        for name in image_file_names(p):
            path = os.path.join(pics_dir, folder, name)
            if os.path.isfile(path):
                return path
    return None


def scryfall_image_url(editions, p):
    info = editions.sets.get(p.set.upper())
    code = info.scryfall if info else p.set.lower()
    cn = p.cn[1:] if re.match(r'^F\d+[a-z]?$', p.cn) else p.cn
    face = '&face=front' if ' // ' in p.card else ''
    return (f'https://api.scryfall.com/cards/{urllib.parse.quote(code)}/{urllib.parse.quote(cn)}'
            f'?format=image&version=normal{face}')


class GuiState:
    def __init__(self, tool, settings_path):
        self.tool = tool
        self.settings_path = settings_path
        self.lock = threading.Lock()
        self.deck_cards = None  # name -> number of decks it appears in
        self.deck_cards_key = None

    @property
    def opts(self):
        return self.tool.opts

    def pics_dir(self):
        return self.opts.image_cache or card_pics_dir(self.tool.profile)

    def cards_in_decks(self):
        key = (tuple(self.tool.roots()), tuple(self.opts.skip_dir), self.opts.skip_set_named_decks)
        if self.deck_cards_key != key:
            counts = collections.Counter()
            for _, _, path, _ in iter_decks(self.tool.roots(), self.opts, self.tool.editions.codes):
                names, section = set(), None
                with open(path, encoding='utf-8', errors='replace') as f:
                    for line in f:
                        s = line.strip()
                        if s.startswith('['):
                            section = s.lower()
                        parsed = parse_card_line(s) if section != '[metadata]' else None
                        if parsed and self.tool.editions.get(parsed[2]):
                            names.add(parsed[2])
                counts.update(names)
            self.deck_cards, self.deck_cards_key = counts, key
        return self.deck_cards

    def describe(self):
        o = self.opts
        adventure = os.path.normpath(os.path.join(self.tool.res, 'adventure'))
        extra = [d for d in (os.path.normpath(os.path.abspath(os.path.expanduser(x))) for x in o.decks)
                 if d != adventure]
        return {
            'forge': self.tool.res,
            'adventure': not o.decks and not o.user_decks or adventure in
            [os.path.normpath(os.path.abspath(os.path.expanduser(x))) for x in o.decks],
            'userDecks': bool(o.user_decks), 'userDecksDir': user_decks_dir(self.tool.profile),
            'extraDecks': extra, 'skipSetNamed': o.skip_set_named_decks, 'order': o.order,
            'oldFrame': o.prefer_old_frame, 'exclude': list(o.exclude), 'backup': o.backup,
            'onlineImages': o.online_images, 'picsDir': self.pics_dir(),
            'picsDirFound': os.path.isdir(self.pics_dir()), 'settingsPath': os.path.abspath(self.settings_path),
            'picks': len(normalize_choices(o.card_choices)),
            'categories': [{'id': k, 'label': v[2], 'about': v[0], 'hard': v[1]} for k, v in CATEGORIES.items()],
        }

    def update(self, d):
        o = self.opts
        adventure = os.path.join(self.tool.res, 'adventure')
        if 'adventure' in d or 'extraDecks' in d or 'userDecks' in d:
            decks = [adventure] if d.get('adventure', True) else []
            decks += [x for x in d.get('extraDecks', []) if x.strip()]
            for x in decks:
                if not os.path.isdir(os.path.expanduser(x)):
                    raise ToolError(f'Deck folder not found: {x}')
            o.user_decks = bool(d.get('userDecks', o.user_decks))
            if not decks and not o.user_decks:
                raise ToolError('Choose at least one set of decks.')
            o.decks = decks
        if 'skipSetNamed' in d:
            o.skip_set_named_decks = bool(d['skipSetNamed'])
        if d.get('order') in ('latest', 'oldest'):
            o.order = d['order']
        if 'oldFrame' in d:
            o.prefer_old_frame = bool(d['oldFrame'])
        if 'exclude' in d:
            o.exclude = sorted(c for c in d['exclude'] if c in CATEGORIES)
        if 'backup' in d:
            o.backup = bool(d['backup'])
        if 'onlineImages' in d:
            o.online_images = bool(d['onlineImages'])

    def card_list(self, query, only_picks, limit=400):
        cards = self.cards_in_decks()
        chooser = Chooser(self.tool.editions, self.opts)
        picks = {k.lower(): len(v) for k, v in normalize_choices(self.opts.card_choices).items()}
        q = query.lower().strip()
        names = sorted(cards, key=lambda n: (-cards[n], n.lower())) if not q else sorted(
            (n for n in cards if q in n.lower()), key=lambda n: (not n.lower().startswith(q), n.lower()))
        if only_picks:
            names = [n for n in names if n.lower() in picks]
        out = []
        for n in names[:limit]:
            p = chooser.best(n)
            out.append({'name': n, 'decks': cards[n], 'set': p.set if p else None, 'cn': p.cn if p else None,
                        'picked': picks.get(n.lower(), 0)})
        return {'total': len(names), 'cards': out, 'deckCards': len(cards)}

    def printings(self, name):
        editions = self.tool.editions
        chooser = Chooser(editions, self.opts)
        auto, fallback = chooser.automatic(name)
        best = chooser.best(name)
        mine = {choice_key(p).upper() for p in chooser.picks(name)}
        out = []
        # Usable printings first, in the order the rules rank them; excluded ones after.
        for p in sorted(chooser.ranked(name), key=lambda p: category_of(p) in chooser.excluded):
            info = editions.sets.get(p.set.upper())
            cat = category_of(p)
            out.append({
                'set': p.set, 'cn': p.cn, 'setName': info.name if info else p.set, 'year': p.date[:4],
                'section': p.section, 'category': cat, 'categoryLabel': CATEGORIES[cat][2] if cat else None,
                'excluded': cat in chooser.excluded, 'oldFrame': is_old_frame(p),
                'auto': auto is not None and choice_key(p) == choice_key(auto),
                'mine': choice_key(p).upper() in mine,
                'chosen': choice_key(p).upper() in mine if mine else (
                    best is not None and choice_key(p) == choice_key(best)),
                'img': '/img?' + urllib.parse.urlencode({'name': name, 'set': p.set, 'cn': p.cn}),
            })
        return {'name': name, 'picked': len(mine), 'fallback': fallback, 'printings': out,
                'decks': self.cards_in_decks().get(name, 0)}

    def set_pick(self, name, key, on=True):
        """Allow (on) or stop allowing one printing of a card; key None clears all of the card's picks."""
        choices = normalize_choices(self.opts.card_choices)
        current = []
        for k in [k for k in choices if k.lower() == name.lower()]:
            current = choices.pop(k)
        if key:
            key = key.upper()
            if not any(choice_key(p).upper() == key for p in self.tool.editions.get(name)):
                raise ToolError(f'{name} has no printing {key}')
            current = [k for k in current if k != key] + ([key] if on else [])
            if current:
                choices[name] = current
        self.opts.card_choices = choices

    def image(self, name, code, cn):
        for p in self.tool.editions.get(name):
            if p.set.upper() == code.upper() and p.cn == cn:
                path = find_cached_image(self.pics_dir(), self.tool.editions, p)
                if path:
                    return 'file', path
                if self.opts.online_images:
                    return 'url', scryfall_image_url(self.tool.editions, p)
                return None, None
        return None, None


class GuiHandler(http.server.BaseHTTPRequestHandler):
    state = None
    token = None
    port = None

    def log_message(self, fmt, *args):  # keep the terminal quiet
        pass

    def _host_ok(self):
        host = (self.headers.get('Host') or '').lower()
        return host in (f'127.0.0.1:{self.port}', f'localhost:{self.port}')

    def _send(self, code, body, ctype='application/json; charset=utf-8', extra=None):
        data = body if isinstance(body, bytes) else body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj))

    def do_GET(self):
        if not self._host_ok():
            return self._send(403, 'forbidden', 'text/plain')
        url = urllib.parse.urlparse(self.path)
        q = {k: v[-1] for k, v in urllib.parse.parse_qs(url.query).items()}
        if url.path == '/':
            return self._send(200, GUI_HTML.replace('__TOKEN__', self.token), 'text/html; charset=utf-8')
        if url.path == '/img':
            kind, where = self.state.image(q.get('name', ''), q.get('set', ''), q.get('cn', ''))
            if kind == 'file':
                with open(where, 'rb') as f:
                    data = f.read()
                return self._send(200, data, mimetypes.guess_type(where)[0] or 'image/jpeg',
                                  {'Cache-Control': 'max-age=3600'})
            if kind == 'url':
                self.send_response(302)
                self.send_header('Location', where)
                self.end_headers()
                return None
            return self._send(404, 'no image', 'text/plain')
        if self.headers.get('X-Token') != self.token:
            return self._send(403, 'forbidden', 'text/plain')
        try:
            with self.state.lock:
                if url.path == '/api/state':
                    return self._json(self.state.describe())
                if url.path == '/api/cards':
                    return self._json(self.state.card_list(q.get('q', ''), q.get('picks') == '1'))
                if url.path == '/api/printings':
                    return self._json(self.state.printings(q.get('name', '')))
        except ToolError as e:
            return self._json({'error': str(e)}, 400)
        return self._send(404, 'not found', 'text/plain')

    def do_POST(self):
        if not self._host_ok() or self.headers.get('X-Token') != self.token:
            return self._send(403, 'forbidden', 'text/plain')
        length = int(self.headers.get('Content-Length') or 0)
        try:
            body = json.loads(self.rfile.read(length) or b'{}')
        except ValueError:
            return self._json({'error': 'bad request'}, 400)
        path = urllib.parse.urlparse(self.path).path
        st = self.state
        try:
            with st.lock:
                if path == '/api/settings':
                    st.update(body)
                    return self._json(st.describe())
                if path == '/api/pick':
                    st.set_pick(body.get('name', ''), body.get('key'), body.get('on', True))
                    return self._json(st.printings(body.get('name', '')))
                if path == '/api/run':
                    result = st.tool.run(apply=bool(body.get('apply')))
                    if result['decks']:
                        st.deck_cards_key = None  # deck contents changed
                    return self._json({k: result[k] for k in ('lines', 'decks', 'backup', 'summary')})
                if path == '/api/save':
                    save_settings(st.opts, st.settings_path)
                    return self._json({'path': os.path.abspath(st.settings_path)})
                if path == '/api/report':
                    result = st.tool.run(apply=False)
                    return self._json({'report': result['report']})
        except ToolError as e:
            return self._json({'error': str(e)}, 400)
        except OSError as e:
            return self._json({'error': f'{e.strerror or e}: {getattr(e, "filename", "")}'}, 500)
        return self._send(404, 'not found', 'text/plain')


def run_gui(tool, settings_path, port=0, open_browser=True):
    GuiHandler.state = GuiState(tool, settings_path)
    GuiHandler.token = secrets.token_urlsafe(24)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', port), GuiHandler)
    GuiHandler.port = server.server_address[1]
    url = f'http://127.0.0.1:{GuiHandler.port}/'
    print(f'Preferred printings is open at {url}\nKeep this window open while you use it; press Ctrl+C to quit.')
    if open_browser:
        threading.Timer(0.3, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nClosed.')
    finally:
        server.server_close()


GUI_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Preferred Printings</title>
<style>
:root {
  --bg: #f6f5f2; --panel: #ffffff; --ink: #1d1d1b; --muted: #6b6a66; --line: #e2e0da;
  --accent: #2f5d8a; --accent-ink: #ffffff; --chip: #eeece6; --good: #2e7d4f; --warn: #a15c00; --bad: #b3261e;
  --shadow: 0 1px 2px rgba(0,0,0,.06), 0 2px 8px rgba(0,0,0,.05);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #161615; --panel: #1f1f1d; --ink: #ecebe7; --muted: #a09e98; --line: #34332f;
    --accent: #7fb0e0; --accent-ink: #10202f; --chip: #2b2a27; --good: #6cc495; --warn: #e2a24a; --bad: #f08a80;
    --shadow: 0 1px 2px rgba(0,0,0,.4);
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
header { display: flex; align-items: center; gap: 12px; padding: 12px 16px; border-bottom: 1px solid var(--line); background: var(--panel); position: sticky; top: 0; z-index: 5; flex-wrap: wrap; }
header h1 { font-size: 17px; margin: 0; margin-right: auto; }
button { font: inherit; border: 1px solid var(--line); background: var(--panel); color: var(--ink); border-radius: 8px; padding: 7px 12px; cursor: pointer; }
button:hover { border-color: var(--accent); }
button.primary { background: var(--accent); color: var(--accent-ink); border-color: var(--accent); font-weight: 600; }
button:disabled { opacity: .5; cursor: default; }
.layout { display: grid; grid-template-columns: 290px 320px 1fr; height: calc(100vh - 58px); }
aside, .list, .detail { overflow: auto; }
aside { border-right: 1px solid var(--line); padding: 14px 16px; background: var(--panel); }
aside h2 { font-size: 12px; text-transform: uppercase; letter-spacing: .06em; color: var(--muted); margin: 18px 0 8px; }
aside h2:first-child { margin-top: 0; }
label.opt { display: flex; gap: 8px; align-items: flex-start; padding: 3px 0; cursor: pointer; }
label.opt input { margin-top: 3px; }
.small { font-size: 12px; color: var(--muted); overflow-wrap: anywhere; }
.detail-head { display: flex; gap: 12px; align-items: baseline; flex-wrap: wrap; }
.detail-head label { margin-left: auto; font-size: 13px; display: flex; gap: 6px; align-items: center; cursor: pointer; }
.hard { font-size: 10px; border: 1px solid var(--line); border-radius: 4px; padding: 0 4px; margin-left: 4px; color: var(--muted); }
textarea { width: 100%; font: 12px ui-monospace, monospace; border: 1px solid var(--line); border-radius: 6px; background: var(--bg); color: var(--ink); padding: 6px; resize: vertical; }
.seg { display: flex; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
.seg button { border: 0; border-radius: 0; flex: 1; }
.seg button.on { background: var(--accent); color: var(--accent-ink); }
.list { border-right: 1px solid var(--line); }
.search { position: sticky; top: 0; background: var(--bg); padding: 12px; border-bottom: 1px solid var(--line); z-index: 2; }
.search input { width: 100%; font: inherit; padding: 8px 10px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); color: var(--ink); }
.tabs { display: flex; gap: 6px; margin-top: 8px; }
.tabs button { padding: 4px 10px; font-size: 12px; }
.tabs button.on { background: var(--chip); border-color: var(--muted); }
.card-row { display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--line); cursor: pointer; }
.card-row:hover { background: var(--chip); }
.card-row.sel { background: var(--chip); box-shadow: inset 3px 0 0 var(--accent); }
.card-row .nm { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.badge { font: 11px ui-monospace, monospace; background: var(--chip); border-radius: 4px; padding: 1px 5px; color: var(--muted); white-space: nowrap; }
.badge.pick { background: var(--accent); color: var(--accent-ink); }
.detail { padding: 16px; }
.detail h2 { margin: 0 0 4px; font-size: 20px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 14px; margin-top: 14px; }
.tile { background: var(--panel); border: 2px solid transparent; border-radius: 12px; padding: 8px; cursor: pointer; box-shadow: var(--shadow); position: relative; }
.tile:hover { border-color: var(--line); }
.tile.chosen { border-color: var(--accent); }
.tile.excluded .art { opacity: .38; filter: grayscale(.6); }
.art { width: 100%; aspect-ratio: 488 / 680; border-radius: 4.75% / 3.5%; background: var(--chip); display: flex; align-items: center; justify-content: center; overflow: hidden; color: var(--muted); font-size: 12px; text-align: center; }
.art img { width: 100%; height: 100%; object-fit: cover; display: block; }
.meta { margin-top: 6px; font-size: 12px; }
.meta .set { font-weight: 600; }
.tags { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 4px; }
.tag { font-size: 10.5px; border-radius: 4px; padding: 1px 5px; background: var(--chip); color: var(--muted); }
.tag.ex { color: var(--bad); }
.tag.old { color: var(--good); }
.tag.mine { background: var(--accent); color: var(--accent-ink); }
.tag.auto { color: var(--accent); }
.empty { color: var(--muted); padding: 40px 16px; text-align: center; }
.note { border: 1px solid var(--line); background: var(--panel); border-radius: 10px; padding: 10px 12px; margin-top: 10px; font-size: 13px; }
.status { font-size: 12px; color: var(--muted); }
dialog { border: 1px solid var(--line); border-radius: 12px; background: var(--panel); color: var(--ink); max-width: min(720px, 92vw); padding: 18px; }
dialog::backdrop { background: rgba(0,0,0,.4); }
dialog pre { white-space: pre-wrap; font: 12px ui-monospace, monospace; background: var(--bg); padding: 10px; border-radius: 8px; max-height: 50vh; overflow: auto; }
.row { display: flex; gap: 8px; justify-content: flex-end; margin-top: 14px; flex-wrap: wrap; }
.toast { position: fixed; bottom: 16px; left: 50%; transform: translateX(-50%); background: var(--ink); color: var(--bg); padding: 8px 14px; border-radius: 8px; opacity: 0; transition: opacity .2s; pointer-events: none; z-index: 20; }
.toast.show { opacity: 1; }
@media (max-width: 1000px) {
  .layout { grid-template-columns: 1fr; height: auto; }
  aside, .list { border-right: 0; border-bottom: 1px solid var(--line); max-height: none; }
  .list { max-height: 50vh; }
}
</style>
</head>
<body>
<header>
  <h1>Preferred Printings</h1>
  <span class="status" id="status"></span>
  <button id="btnSave" title="Save your rules and picks to a settings file">Save settings</button>
  <button id="btnPreview">Preview</button>
  <button id="btnApply" class="primary">Apply to decks…</button>
</header>
<div class="layout">
  <aside>
    <h2>Decks</h2>
    <label class="opt"><input type="checkbox" id="optAdventure"> <span>Adventure decks that come with Forge</span></label>
    <label class="opt"><input type="checkbox" id="optUser"> <span>My own decks<br><span class="small" id="userDir"></span></span></label>
    <div class="small" style="margin:6px 0 4px">Other deck folders, one per line:</div>
    <textarea id="optExtra" rows="2" placeholder="/path/to/decks"></textarea>
    <label class="opt"><input type="checkbox" id="optSkipSet"> <span>Leave product decks alone<br><span class="small">e.g. “4ED - Black Starter”</span></span></label>

    <h2>Exclude</h2>
    <div id="cats"></div>
    <div class="small">Marked <span class="hard">always</span>: never used, even if a card has nothing else.</div>

    <h2>Prefer</h2>
    <label class="opt"><input type="checkbox" id="optOld"> <span>Old frame<br><span class="small">Pre-2003 sets and “retro frame” reprints</span></span></label>
    <div class="small" style="margin:6px 0 4px">Then take the</div>
    <div class="seg" id="segOrder"><button data-v="latest">Latest</button><button data-v="oldest">Oldest</button></div>

    <h2>Images</h2>
    <label class="opt"><input type="checkbox" id="optOnline"> <span>Fetch missing images from Scryfall<br><span class="small" id="picsDir"></span></span></label>

    <h2>Safety</h2>
    <label class="opt"><input type="checkbox" id="optBackup"> <span>Back up decks before changing them</span></label>
    <div class="small" id="settingsPath" style="margin-top:10px"></div>
  </aside>

  <section class="list">
    <div class="search">
      <input id="q" type="search" placeholder="Search cards in your decks…" autocomplete="off">
      <div class="tabs"><button id="tabAll" class="on">All cards</button><button id="tabPicks">My picks</button></div>
      <div class="small" id="count" style="margin-top:6px"></div>
    </div>
    <div id="cards"></div>
  </section>

  <section class="detail" id="detail">
    <div class="empty">Pick a card on the left to see every printing Forge knows.<br><br>
      Click a printing to always use it for that card. Cards you don’t pick follow the rules on the left.</div>
  </section>
</div>

<dialog id="dlg"><h3 id="dlgTitle" style="margin-top:0"></h3><div id="dlgBody"></div><div class="row" id="dlgButtons"></div></dialog>
<div class="toast" id="toast"></div>

<script>
const TOKEN = "__TOKEN__";
const $ = id => document.getElementById(id);
let state = null, current = null, onlyPicks = false, searchTimer = null, lastCard = null;
let hideExcluded = false;
try { hideExcluded = localStorage.getItem('pp.hideExcluded') === '1'; } catch (e) {}

async function api(path, body) {
  const opts = { headers: { 'X-Token': TOKEN } };
  if (body !== undefined) { opts.method = 'POST'; opts.body = JSON.stringify(body); opts.headers['Content-Type'] = 'application/json'; }
  const r = await fetch(path, opts);
  const data = await r.json().catch(() => ({ error: 'Unexpected reply (' + r.status + ')' }));
  if (!r.ok || data.error) throw new Error(data.error || ('Error ' + r.status));
  return data;
}
function toast(msg) { const t = $('toast'); t.textContent = msg; t.classList.add('show'); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('show'), 2600); }
function esc(s) { return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
function dialog(title, html, buttons) {
  $('dlgTitle').textContent = title; $('dlgBody').innerHTML = html;
  const row = $('dlgButtons'); row.innerHTML = '';
  return new Promise(resolve => {
    for (const [label, value, primary] of buttons) {
      const b = document.createElement('button'); b.textContent = label; if (primary) b.className = 'primary';
      b.onclick = () => { $('dlg').close(); resolve(value); }; row.appendChild(b);
    }
    $('dlg').onclose = () => resolve(null);
    $('dlg').showModal();
  });
}

function renderSettings() {
  const s = state;
  $('optAdventure').checked = s.adventure; $('optUser').checked = s.userDecks;
  $('userDir').textContent = s.userDecksDir; $('optExtra').value = s.extraDecks.join('\n');
  $('optSkipSet').checked = s.skipSetNamed; $('optOld').checked = s.oldFrame;
  $('optOnline').checked = s.onlineImages; $('optBackup').checked = s.backup;
  $('picsDir').textContent = (s.picsDirFound ? 'Forge image cache: ' : 'No Forge image cache found at ') + s.picsDir;
  $('settingsPath').textContent = 'Settings file: ' + s.settingsPath;
  for (const b of $('segOrder').children) b.classList.toggle('on', b.dataset.v === s.order);
  $('cats').innerHTML = s.categories.map(c =>
    `<label class="opt" title="${esc(c.about)}"><input type="checkbox" data-cat="${c.id}" ${s.exclude.includes(c.id) ? 'checked' : ''}>
     <span>${esc(c.label)}${c.hard ? '<span class="hard">always</span>' : ''}</span></label>`).join('');
  for (const el of $('cats').querySelectorAll('input')) el.onchange = () => saveRules();
  $('status').textContent = s.picks ? `${s.picks} card${s.picks === 1 ? '' : 's'} picked by you` : '';
}

async function saveRules(extra) {
  const body = Object.assign({
    exclude: [...$('cats').querySelectorAll('input:checked')].map(e => e.dataset.cat),
    oldFrame: $('optOld').checked, onlineImages: $('optOnline').checked, backup: $('optBackup').checked,
    skipSetNamed: $('optSkipSet').checked,
  }, extra || {});
  try { state = await api('/api/settings', body); renderSettings(); await loadCards(); if (current) await openCard(current); }
  catch (e) { toast(e.message); state = await api('/api/state'); renderSettings(); }
}
function saveDecks() {
  return saveRules({ adventure: $('optAdventure').checked, userDecks: $('optUser').checked,
                     extraDecks: $('optExtra').value.split('\n').map(s => s.trim()).filter(Boolean) });
}

async function loadCards() {
  const q = $('q').value;
  $('count').textContent = 'Loading…';
  try {
    const data = await api('/api/cards?' + new URLSearchParams({ q, picks: onlyPicks ? '1' : '0' }));
    $('count').textContent = `${data.total.toLocaleString()} of ${data.deckCards.toLocaleString()} cards` +
      (data.total > data.cards.length ? ` (showing ${data.cards.length})` : '');
    $('cards').innerHTML = data.cards.length ? data.cards.map(c =>
      `<div class="card-row ${c.name === current ? 'sel' : ''}" data-name="${esc(c.name)}">
        <span class="nm">${esc(c.name)}</span>
        ${c.picked > 1 ? `<span class="badge pick" title="${c.picked} printings spread across decks">${c.picked} picks</span>`
          : c.set ? `<span class="badge ${c.picked ? 'pick' : ''}">${esc(c.set)}</span>` : '<span class="badge">—</span>'}
        <span class="small" title="decks">${c.decks}</span></div>`).join('')
      : `<div class="empty">${onlyPicks ? 'You haven’t picked any printings yet.' : 'No cards found.'}</div>`;
    for (const row of $('cards').querySelectorAll('.card-row')) row.onclick = () => openCard(row.dataset.name);
  } catch (e) { $('count').textContent = e.message; }
}

async function openCard(name) {
  current = name;
  for (const row of $('cards').querySelectorAll('.card-row')) row.classList.toggle('sel', row.dataset.name === name);
  let data;
  try { data = await api('/api/printings?' + new URLSearchParams({ name })); } catch (e) { toast(e.message); return; }
  renderCard(data);
}

function renderCard(data) {
  lastCard = data;
  const d = $('detail');
  const shown = data.printings.map((p, i) => [p, i]).filter(([p]) => !hideExcluded || !p.excluded || p.chosen);
  const hidden = data.printings.length - shown.length;
  const chosen = data.printings.find(p => p.chosen);
  const mine = data.printings.filter(p => p.mine);
  let note = '';
  if (mine.length === 1) note = `<div class="note">Your decks use <b>${esc(mine[0].setName)} #${esc(mine[0].cn)}</b>. Pick more printings to spread them across your decks. <button id="btnAuto">Use the rules instead</button></div>`;
  else if (mine.length > 1) note = `<div class="note">Your <b>${mine.length}</b> picks are spread across the ${data.decks.toLocaleString()} deck${data.decks === 1 ? '' : 's'} using this card: each deck gets one of them, and the same one every time. <button id="btnAuto">Use the rules instead</button></div>`;
  else if (!chosen) note = '<div class="note">Every printing of this card is excluded by an “always” rule, so its decks keep the printing they already use. You can still pick one here.</div>';
  else if (data.fallback) note = '<div class="note">Only excluded treatments exist for this card, so the rules fall back to the best of them.</div>';
  d.innerHTML = `<div class="detail-head"><h2>${esc(data.name)}</h2>
    <label><input type="checkbox" id="optHide" ${hideExcluded ? 'checked' : ''}> Hide excluded</label></div>
    <div class="small">${data.printings.length} printing${data.printings.length === 1 ? '' : 's'} in Forge${hidden ? ` (${hidden} excluded hidden)` : ''}. ${mine.length ? 'Highlighted: your picks.' : 'Highlighted: the one the rules choose.'} Click printings to pick them; click again to unpick.</div>
    ${note}
    <div class="grid">${shown.map(([p, i]) => `
      <div class="tile ${p.chosen ? 'chosen' : ''} ${p.excluded ? 'excluded' : ''}" data-i="${i}" title="${esc(p.setName)} (${esc(p.set)}) #${esc(p.cn)}">
        <div class="art"><img loading="lazy" alt="" src="${p.img}" onerror="this.parentNode.textContent='No image'"></div>
        <div class="meta"><div class="set">${esc(p.setName)}</div>
          <div class="small">${esc(p.set)} · #${esc(p.cn)} · ${esc(p.year)}</div>
          <div class="tags">
            ${p.mine ? '<span class="tag mine">Your pick</span>' : ''}
            ${p.auto ? '<span class="tag auto">Rules pick</span>' : ''}
            ${p.oldFrame ? '<span class="tag old">Old frame</span>' : ''}
            ${p.category ? `<span class="tag ${p.excluded ? 'ex' : ''}">${esc(p.categoryLabel)}${p.excluded ? ' · excluded' : ''}</span>` : ''}
          </div></div></div>`).join('')}</div>`;
  for (const t of d.querySelectorAll('.tile')) t.onclick = () => pick(data, data.printings[+t.dataset.i]);
  const auto = $('btnAuto'); if (auto) auto.onclick = () => pick(data, null);
  $('optHide').onchange = e => {
    hideExcluded = e.target.checked;
    try { localStorage.setItem('pp.hideExcluded', hideExcluded ? '1' : '0'); } catch (err) {}
    renderCard(lastCard);
  };
}

async function pick(data, p) {
  try {
    const on = p ? !p.mine : false;
    const res = await api('/api/pick', { name: data.name, key: p ? `${p.set}|${p.cn}` : null, on });
    renderCard(res);
    state = await api('/api/state'); renderSettings(); loadCards();
    toast(!p ? `${data.name}: following the rules` : on ? `Picked ${p.setName} #${p.cn}` :
          res.picked ? `Unpicked ${p.setName} #${p.cn}` : `${data.name}: following the rules`);
  } catch (e) { toast(e.message); }
}

async function busy(btn, fn) { const old = btn.textContent; btn.disabled = true; btn.textContent = 'Working…'; try { await fn(); } finally { btn.disabled = false; btn.textContent = old; } }

$('btnPreview').onclick = () => busy($('btnPreview'), async () => {
  try {
    const r = await api('/api/run', { apply: false });
    const choice = await dialog('Preview', `<p><b>${r.lines.toLocaleString()}</b> card lines in <b>${r.decks.toLocaleString()}</b> decks would change. Nothing has been changed yet.</p><pre>${esc(r.summary)}</pre>`,
      [['Full report', 'report'], ['Close', null, true]]);
    if (choice === 'report') { const rep = await api('/api/report', {}); await dialog('Full report', `<pre>${esc(rep.report)}</pre>`, [['Close', null, true]]); }
  } catch (e) { toast(e.message); }
});
$('btnApply').onclick = () => busy($('btnApply'), async () => {
  try {
    const p = await api('/api/run', { apply: false });
    if (!p.lines) { toast('Nothing to change: your decks already match.'); return; }
    const ok = await dialog('Apply to decks?', `<p>This changes <b>${p.lines.toLocaleString()}</b> card lines in <b>${p.decks.toLocaleString()}</b> deck files.</p>` +
      (state.backup ? '<p>The original decks are backed up first, so you can undo it.</p>' : '<p><b>Backups are off</b>, so this can’t be undone.</p>'),
      [['Cancel', false], ['Apply', true, true]]);
    if (!ok) return;
    const r = await api('/api/run', { apply: true });
    await dialog('Done', `<p>Changed ${r.lines.toLocaleString()} card lines in ${r.decks.toLocaleString()} decks.</p>` +
      (r.backup ? `<p class="small">Originals backed up to<br><code>${esc(r.backup)}</code></p><p class="small">To undo, run:<br><code>python3 preferred_printings.py --restore "${esc(r.backup)}"</code></p>` : ''),
      [['Close', null, true]]);
    loadCards(); if (current) openCard(current);
  } catch (e) { toast(e.message); }
});
$('btnSave').onclick = () => busy($('btnSave'), async () => {
  try { const r = await api('/api/save', {}); toast('Saved to ' + r.path); } catch (e) { toast(e.message); }
});

for (const id of ['optOld', 'optOnline', 'optBackup', 'optSkipSet']) $(id).onchange = () => saveRules();
for (const id of ['optAdventure', 'optUser']) $(id).onchange = () => saveDecks();
$('optExtra').onchange = () => saveDecks();
for (const b of $('segOrder').children) b.onclick = () => saveRules({ order: b.dataset.v });
$('q').oninput = () => { clearTimeout(searchTimer); searchTimer = setTimeout(loadCards, 200); };
$('tabAll').onclick = () => { onlyPicks = false; $('tabAll').classList.add('on'); $('tabPicks').classList.remove('on'); loadCards(); };
$('tabPicks').onclick = () => { onlyPicks = true; $('tabPicks').classList.add('on'); $('tabAll').classList.remove('on'); loadCards(); };

(async () => {
  try { state = await api('/api/state'); renderSettings(); await loadCards(); }
  catch (e) { $('count').textContent = e.message; }
})();
</script>
</body>
</html>
"""


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
                       help=f'also process your own decks, in {user_decks_dir()}')
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
    run.add_argument('--gui', action='store_true',
                     help='choose printings visually in your web browser (uses and saves --config, '
                          'default preferred-printings.json)')
    run.add_argument('--port', type=int, default=0, help=argparse.SUPPRESS)
    run.add_argument('--no-browser', action='store_true', help=argparse.SUPPRESS)
    run.add_argument('--image-cache', metavar='PATH', default=None,
                     help="Forge's card image folder, for the GUI (default: found automatically)")
    run.add_argument('--online-images', action=argparse.BooleanOptionalAction, default=None,
                     help='let the GUI fetch images Forge has not downloaded from Scryfall (default: on)')
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


def resolve_options(args):
    """Command line beats settings file beats built-in defaults."""
    if args.gui and not args.config:
        args.config = 'preferred-printings.json'
    saved = load_settings(args.config) if args.config and os.path.isfile(args.config) else {}
    if args.config and not saved and not args.gui:
        raise ToolError(f'Settings file not found: {args.config}')
    args.card_choices = None
    for key in SAVED_OPTIONS:
        if getattr(args, key, None) is None:
            value = saved.get(key, DEFAULTS[key])
            setattr(args, key, list(value) if isinstance(value, list) else
                    dict(value) if isinstance(value, dict) else value)
    args.exclude = sorted(c for c in args.exclude if c not in set(args.include))
    bad = set(args.exclude) - set(CATEGORIES)
    if bad:
        raise ToolError(f"Unknown exclusion categories: {', '.join(sorted(bad))}")
    if not args.forge:
        args.forge = default_forge_path()
    return args


def main():
    try:
        args = resolve_options(build_parser().parse_args())
        if args.restore:
            count = restore(os.path.abspath(os.path.expanduser(args.restore)))
            print(f'Restored {count} decks from {args.restore}')
            return
        if args.save_config:
            save_settings(args, args.save_config)
            print(f'Settings saved to {args.save_config}. Run again with: --config "{args.save_config}" --apply')
            return
        tool = Tool(args)
        if args.gui:
            run_gui(tool, args.config, args.port, not args.no_browser)
            return
        result = tool.run(apply=args.apply, report_path=args.report)
        if args.report:
            print(f'Report written to {args.report}')
        elif not args.quiet:
            print(result['summary'] + '\n\n(Add --report FILE for the full details.)')
        if args.apply:
            print(f"Applied: {result['lines']} card lines in {result['decks']} decks.", file=sys.stderr)
            if result['backup']:
                print(f"Originals backed up to {result['backup']}\n"
                      f'Undo with: --restore "{result["backup"]}"', file=sys.stderr)
        else:
            print(f"Dry run: {result['lines']} card lines in {result['decks']} decks would change. "
                  'Add --apply to write them.', file=sys.stderr)
    except ToolError as e:
        sys.exit(str(e))


if __name__ == '__main__':
    main()
