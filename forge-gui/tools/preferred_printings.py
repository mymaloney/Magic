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
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

# Universes Beyond sets (and their promo/companion sets) as named in Forge's edition files. Forge doesn't mark
# UB sets, so this list is kept by hand: add new UB releases here, or list them in a settings file
# (extra_ub_sets) / with --ub-set. Universes Within (SLX) is deliberately absent: it holds the non-UB versions.
BUILT_IN_UB_SETS = frozenset({
    '40K',                                  # Warhammer 40,000
    'ACR',                                  # Assassin's Creed
    'BOT',                                  # Transformers
    'FIN', 'FIC', 'FCA', 'RFIN', 'PSS5',    # Final Fantasy
    'HOB', 'HOC',                           # The Hobbit
    'LTR', 'LTC', 'PLTC',                   # The Lord of the Rings
    'MSH', 'MSC', 'MDD', 'MDC', 'MAR', 'LMAR', 'SPM', 'SPE',  # Marvel
    'PCBB',                                 # Cowboy Bebop
    'PIP',                                  # Fallout
    'REX',                                  # Jurassic World
    'TLA', 'TLE',                           # Avatar: The Last Airbender
    'TMT', 'TMC', 'PZA',                    # Teenage Mutant Ninja Turtles
    'TRK', 'TRC',                           # Star Trek
    'WHO',                                  # Doctor Who
})
UB_SETS = set(BUILT_IN_UB_SETS)  # plus the user's extra_ub_sets; see set_extra_ub_sets()


def set_extra_ub_sets(codes):
    UB_SETS.clear()
    UB_SETS.update(BUILT_IN_UB_SETS)
    UB_SETS.update(c.strip().upper() for c in codes or [] if c and c.strip())
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
    'gold-border': ('gold-bordered printings (needs Scryfall card details)', False, 'Gold border'),
    'inverted': ('inverted-frame printings (needs Scryfall card details)', False, 'Inverted'),
    'thick': ('thick-stock printings, e.g. display commanders (needs Scryfall card details)', False, 'Thick'),
}

# Card details from Scryfall fill the gaps in Forge's edition files (which only mark some treatments).
# White borders aren't asked for: Forge's edition files already mark the white-bordered sets.
# category: (search keywords to try in turn, test on each returned card). The test guards against a keyword
# matching more than intended; if it rejects every result, the keyword's results are used as they are.
SCRYFALL_API = 'https://api.scryfall.com'
SCRYFALL_TAGS = {
    'full-art': (('is:full', 'is:fullart'), lambda c: bool(c.get('full_art'))),
    'borderless': (('border:borderless',), lambda c: c.get('border_color') == 'borderless'),
    'gold-border': (('border:gold',), lambda c: c.get('border_color') == 'gold'),
    'extended-art': (('frame:extendedart', 'is:extendedart'), lambda c: 'extendedart' in (c.get('frame_effects') or [])),
    'showcase': (('frame:showcase', 'is:showcase'), lambda c: 'showcase' in (c.get('frame_effects') or [])),
    'inverted': (('frame:inverted', 'is:inverted'), lambda c: 'inverted' in (c.get('frame_effects') or [])),
    'thick': (('is:thick',), lambda c: 'thick' in (c.get('promo_types') or [])),
    'ub': (('stamp:triangle',), lambda c: c.get('security_stamp') == 'triangle'),
}
SCRYFALL_CACHE_NAME = 'preferred-printings-scryfall.json'
PRINTING_TAGS = {}  # "SET|CN" -> set of categories, from the Scryfall card details file
LANGUAGE_PRINTINGS = {}  # language code -> {"SET|CN"} printed in that language (Scryfall details + Forge's cache)
CARD_LANG_BY_SET = {}  # Forge set code -> language of the whole set (CardLang in its edition file)
# The languages Forge can show card pictures in (ForgeConstants.getScryfallCardLanguageMapping).
LANGUAGES = {'English': 'en', 'Spanish': 'es', 'French': 'fr', 'German': 'de', 'Italian': 'it', 'Portuguese': 'pt',
             'Japanese': 'ja', 'Korean': 'ko', 'Russian': 'ru', 'Chinese Simplified': 'zhs',
             'Chinese Traditional': 'zht'}

# Options that a settings file (--config / --save-config) can hold, with their defaults.
DEFAULTS = {'forge': None, 'decks': [], 'user_decks': False, 'skip_dir': [], 'skip_set_named_decks': True,
            'order': 'latest', 'prefer_old_frame': True, 'exclude': sorted(CATEGORIES),
            'backup': True, 'backup_dir': 'preferred-printings-backups', 'card_choices': {},
            'image_cache': None, 'online_images': True, 'extra_ub_sets': [], 'scryfall_cache': None,
            'language': None, 'card_prefs': False, 'spread': True}
SAVED_OPTIONS = tuple(DEFAULTS)

Printing = collections.namedtuple('Printing', 'set cn section date type border card art arts')
SetInfo = collections.namedtuple('SetInfo', 'code name date type border code2 scryfall')
DECK_LINE = re.compile(r'^(\d+)\s+(.+?)\s*$')
# CardEdition.Reader.CARD_PATTERN: [collector number] [rarity] name [@artist] [${extra params}]
EDITION_LINE = re.compile(r'^(?:(.?[0-9A-Z-]+\S*[A-Z]*)\s)?(?:([SCURML])\s)?([^@$]+)(?: @([^$]*))?(?: \$\{(.+)\})?$')
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
        # Forge numbers the arts of one card within a set in its own collector number order.
        groups = collections.defaultdict(list)
        for name, prints in self.by_name.items():
            for i, p in enumerate(prints):
                groups[(p.set, name)].append(i)
        for (code, name), idxs in groups.items():
            prints = self.by_name[name]
            ordered = sorted(idxs, key=lambda i: forge_sortable_cn(prints[i].cn))
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
                    if m and m.group(3).strip():
                        entries.append((m.group(1) or '', m.group(3).strip(), section))
        code = meta.get('Code')
        if not code:
            return
        info = SetInfo(code, meta.get('Name', code), meta.get('Date', '9999-99-99'), meta.get('Type', ''),
                       meta.get('Border', 'Black'), meta.get('Code2', code),
                       meta.get('ScryfallCode', code).lower())
        self.sets[code.upper()] = info
        if meta.get('CardLang', 'en') != 'en':
            CARD_LANG_BY_SET[code.upper()] = meta['CardLang']
        for cn, name, section in entries:
            self.by_name[name.lower()].append(
                Printing(code, cn, section, info.date, info.type, info.border, name, 1, 1))

    def get(self, name):
        return self.by_name.get(name.lower(), [])


def categories_of(p):
    """Every filter category a printing falls into (empty for a regular printing)."""
    cats = set(PRINTING_TAGS.get(f'{p.set}|{p.cn}'.upper(), ()))
    own = category_of(p)
    if own:
        cats.add(own)
    return cats


def is_excluded(p, excluded):
    return bool(categories_of(p) & excluded)


def category_of(p):
    """The category Forge's own edition files put a printing in, or None."""
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


def forge_sortable_cn(cn):
    """CardEdition.getSortableCollectorNumber: Forge orders a set's printings by this string."""
    if not cn:
        cn = '50000'
    if cn.isdigit():
        return f'{int(cn):05d}'
    non_num = re.sub(r'[0-9]', '', cn)
    only_num = re.sub(r'[^0-9]', '', cn)
    num = int(only_num) if only_num else 0
    if num > 0 and cn.startswith(only_num):  # e.g. 12a, 37+
        return f'{num:05d}{non_num}'
    return f'{non_num}{num:05d}'  # e.g. WS6, S1


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
        self.language = getattr(opts, 'language', None) or 'en'
        self.card_choices = {k.lower(): v for k, v in normalize_choices(opts.card_choices).items()}
        self.spread = getattr(opts, 'spread', True)
        self.cache = {}
        self.pools = {}
        self.fallbacks = {}

    def rank(self, p):
        return (0 if in_language(p, self.language) else 1,
                0 if (self.prefer_old_frame and is_old_frame(p)) else 1,
                1 if (p.set in CATCH_ALL_SETS or p.type in LOW_PRIORITY_TYPES) else 0,
                date_key(p.date, self.order_latest),
                0 if p.section == 'cards' else 1,
                collector_key(p.cn))

    def ranked(self, name):
        return sorted(self.editions.get(name), key=self.rank)

    def pool(self, name, allowed_sets=None):
        """The printings the rules allow for a card, narrowed by the preferences: only those in the chosen
        language if there are any, then only old-frame ones if preferred and there are any, then leaving out
        catch-all and collector sets if anything else is left. Returns (printings, fell back on a soft rule)."""
        key = (name.lower(), allowed_sets)
        if key in self.pools:
            return self.pools[key]
        prints = self.editions.get(name)
        if allowed_sets is not None:
            prints = [p for p in prints if p.set.upper() in allowed_sets]
        ok = [p for p in prints if not is_excluded(p, self.excluded)]
        fallback = False
        if not ok:
            hard = {c for c in self.excluded if CATEGORIES[c][1]}
            ok = [p for p in prints if not is_excluded(p, hard)]
            fallback = bool(ok)
        tiers = [lambda p: in_language(p, self.language)]
        if self.prefer_old_frame:
            tiers.append(is_old_frame)
        tiers.append(lambda p: not (p.set in CATCH_ALL_SETS or p.type in LOW_PRIORITY_TYPES))
        for keep in tiers:
            narrowed = [p for p in ok if keep(p)]
            if narrowed:
                ok = narrowed
        self.pools[key] = (sorted(ok, key=self.rank), fallback)
        return self.pools[key]

    def automatic(self, name, allowed_sets=None):
        """The single best printing by the rules (ignoring the user's own picks), and whether it fell back."""
        pool, fallback = self.pool(name, allowed_sets)
        return (pool[0], fallback) if pool else (None, False)

    def picks(self, name, allowed_sets=None):
        """The printings the user allowed for this card, in the order they were picked."""
        wanted = self.card_choices.get(name.lower())
        if not wanted:
            return []
        by_key = {choice_key(p).upper(): p for p in self.editions.get(name)
                  if allowed_sets is None or p.set.upper() in allowed_sets}
        return [by_key[k] for k in wanted if k in by_key]

    def best(self, name, allowed_sets=None, deck=None):
        """The printing to use. Given a deck, with several printings allowed (the user's own picks, or the
        rules' pool in spread mode), each deck gets one of them; otherwise the single best one."""
        picks = self.picks(name, allowed_sets)
        if len(picks) > 1:  # the user's own picks win over every rule
            return spread_pick(name, deck, picks) if deck is not None else picks[0]
        if not picks and self.spread and deck is not None:
            pool, _ = self.pool(name, allowed_sets)
            if len(pool) > 1:
                self.best(name, allowed_sets)  # records fallbacks for the report
                return spread_pick(name, deck, pool)
        key = (name.lower(), allowed_sets)
        if key in self.cache:
            return self.cache[key]
        result = picks[0] if picks else None
        if result is None:
            result, fallback = self.automatic(name, allowed_sets)
            if fallback:
                cats = ', '.join(sorted(categories_of(result) & self.excluded))
                self.fallbacks[name] = f'{result.set} [{result.cn}] ({cats})'
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


def scryfall_cache_path(opts):
    if opts.scryfall_cache:
        return os.path.abspath(os.path.expanduser(opts.scryfall_cache))
    base = os.path.dirname(os.path.abspath(opts.config)) if getattr(opts, 'config', None) else os.getcwd()
    return os.path.join(base, SCRYFALL_CACHE_NAME)


def load_scryfall_tags(path):
    """Load card details saved by fetch_scryfall_tags; returns the file's info, or None if there is none."""
    PRINTING_TAGS.clear()
    LANGUAGE_PRINTINGS.clear()
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
        for cat, keys in data.get('tags', {}).items():
            if cat in CATEGORIES:
                for key in keys:
                    PRINTING_TAGS.setdefault(key.upper(), set()).add(cat)
        for lang, keys in data.get('languages', {}).items():
            LANGUAGE_PRINTINGS.setdefault(lang, set()).update(k.upper() for k in keys)
    except (OSError, ValueError, AttributeError) as e:
        raise ToolError(f'Could not read Scryfall card details from {path}: {e}')
    return {'fetched': data.get('fetched'), 'printings': len(PRINTING_TAGS), 'notes': data.get('notes', []),
            'languages': sorted(data.get('languages', {}))}


def load_forge_language_cache(editions, profile):
    """Add what Forge itself learned about card languages ({cacheDir}/cdn_uuid/{set}.json.gz) to
    LANGUAGE_PRINTINGS. Forge fills it in as it downloads pictures, so it covers the sets a player has seen."""
    cache_dir = profile.get('cacheDir') or default_dirs()[1]
    folder = os.path.join(cache_dir, 'cdn_uuid')
    if not os.path.isdir(folder):
        return 0
    import gzip
    forge_codes = collections.defaultdict(set)
    for code, info in editions.sets.items():
        forge_codes[info.scryfall.lower()].add(info.code)
    added = 0
    for path in glob.glob(os.path.join(glob.escape(folder), '*.json.gz')):
        codes = forge_codes.get(os.path.basename(path)[:-len('.json.gz')].lower())
        if not codes:
            continue
        try:
            with gzip.open(path, 'rt', encoding='utf-8') as f:
                data = json.load(f)
        except (OSError, ValueError, EOFError):
            continue
        for cn, langs in (data.items() if isinstance(data, dict) else ()):
            for lang, value in (langs.items() if isinstance(langs, dict) else ()):
                if isinstance(value, dict):  # {"miss": timestamp}: Forge looked and found nothing
                    continue
                for code in codes:
                    LANGUAGE_PRINTINGS.setdefault(lang, set()).add(f'{code}|{cn}'.upper())
                    added += 1
    return added


def in_language(p, lang):
    if not lang or lang == 'en':
        return False
    info_lang = CARD_LANG_BY_SET.get(p.set.upper())
    return info_lang == lang or f'{p.set}|{p.cn}'.upper() in LANGUAGE_PRINTINGS.get(lang, ())


def _scryfall_get(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'ForgePreferredPrintings/1.0',
                                               'Accept': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return 200, json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.load(e)
        except ValueError:
            return e.code, {}


def _scryfall_search(api, query, label, progress, **params):
    """Every card a Scryfall search returns, page by page; (cards, None) or (None, error message)."""
    url = f'{api}/cards/search?' + urllib.parse.urlencode(dict({'q': query, 'unique': 'prints'}, **params))
    cards = []
    while url:
        if progress:
            progress(f'{label}: {len(cards)} printings so far')
        time.sleep(0.12)  # Scryfall asks for 50-100 ms between requests
        try:
            status, page = _scryfall_get(url)
        except (urllib.error.URLError, OSError) as e:
            raise ToolError(f'Could not reach Scryfall ({getattr(e, "reason", e)}). '
                            'Check your internet connection and try again.')
        if status == 404 and page.get('object') == 'error':  # no cards match
            break
        if status != 200:
            return None, page.get('details', f'HTTP {status}')
        cards.extend(page.get('data', []))
        url = page.get('next_page') if page.get('has_more') else None
    return cards, None


def fetch_scryfall_tags(editions, path, api=SCRYFALL_API, progress=None, language=None):
    """Ask Scryfall which printings are full art, borderless, showcase..., and which exist in the player's
    language, and save them to path. One search per treatment, plus one for the language."""
    forge_codes = collections.defaultdict(set)  # Scryfall set code -> Forge set codes
    for code, info in editions.sets.items():
        forge_codes[info.scryfall.lower()].add(info.code)

    def keys_for(cards):
        keys = set()
        for c in cards:
            cn = str(c.get('collector_number', ''))
            for code in forge_codes.get(str(c.get('set', '')).lower(), ()):
                keys.add(f'{code}|{cn}'.upper())
        return sorted(keys)

    tags, notes = {}, []
    for cat, (queries, test) in SCRYFALL_TAGS.items():
        found = None
        for query in queries:
            cards, error = _scryfall_search(api, query, CATEGORIES[cat][2], progress, include_variations='true')
            if error:
                notes.append(f'{cat}: Scryfall did not accept "{query}" ({error})')
                continue
            found = [c for c in cards if test(c)]
            if cards and not found:
                notes.append(f'{cat}: none of the {len(cards)} results for "{query}" passed the check; used them all')
                found = cards
            break
        if found is None:
            notes.append(f'{cat}: no Scryfall search worked; this category is left to Forge\'s own data')
            continue
        tags[cat] = keys_for(found)

    languages = {}
    if os.path.isfile(path):  # keep languages fetched before
        try:
            with open(path, encoding='utf-8') as f:
                languages = json.load(f).get('languages', {}) or {}
        except (OSError, ValueError, AttributeError):
            languages = {}
    if language and language != 'en':
        label = next((k for k, v in LANGUAGES.items() if v == language), language)
        cards, error = _scryfall_search(api, f'lang:{language}', label, progress, include_multilingual='true')
        if error:
            notes.append(f'{language}: Scryfall did not accept "lang:{language}" ({error})')
        else:
            languages[language] = keys_for(c for c in cards if c.get('lang', language) == language)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump({'fetched': datetime.datetime.now().isoformat(timespec='seconds'), 'source': api,
                   'notes': notes, 'tags': tags, 'languages': languages}, f, indent=0)
    return load_scryfall_tags(path)


def read_forge_language(profile):
    """The player's 'Card download language' from Forge's own preferences, if set."""
    user_dir = profile.get('userDir') or default_dirs()[0]
    path = os.path.join(user_dir, 'preferences', 'forge.preferences')
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            for line in f:
                key, sep, value = line.strip().partition('=')
                if sep and key.strip() == 'UI_CARD_DOWNLOAD_LANG' and value.strip() in LANGUAGES.values():
                    return value.strip()
    except OSError:
        pass
    return None


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
        unknown = sorted(c.upper() for c in opts.extra_ub_sets if c.strip().upper() not in self.editions.sets)
        if unknown:
            raise ToolError(f"Unknown set code(s) in extra UB sets: {', '.join(unknown)}")
        set_extra_ub_sets(opts.extra_ub_sets)
        self.scryfall_api = SCRYFALL_API
        self.scryfall_path = scryfall_cache_path(opts)
        if opts.language is None:  # follow Forge's own "Card download language"
            opts.language = read_forge_language(self.profile) or 'en'
        if opts.language not in LANGUAGES.values():
            raise ToolError(f"Unknown language {opts.language}; use one of {', '.join(LANGUAGES.values())}")
        self.load_card_details()

    def load_card_details(self):
        self.scryfall_info = load_scryfall_tags(self.scryfall_path)
        self.forge_language_entries = load_forge_language_cache(self.editions, self.profile)

    def language_known(self):
        """How many printings are known to exist in the chosen language."""
        lang = self.opts.language
        return 0 if lang == 'en' else len(LANGUAGE_PRINTINGS.get(lang, ()))

    def update_scryfall(self, api=SCRYFALL_API, progress=None):
        fetch_scryfall_tags(self.editions, self.scryfall_path, api, progress, self.opts.language)
        self.load_card_details()
        return self.scryfall_info

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

        prefs_path = card_prefs_path(self.profile)
        if opts.card_prefs:
            choices = card_preference_choices(chooser, editions)
            stats['card preferences for rewards and shops'] = len(choices)
            if apply:
                if backup_root:
                    if os.path.isfile(prefs_path):
                        tag = 'card-preferences'
                        manifest['roots'][tag] = os.path.dirname(prefs_path)
                        dest = os.path.join(backup_root, tag, os.path.basename(prefs_path))
                        os.makedirs(os.path.dirname(dest), exist_ok=True)
                        shutil.copy2(prefs_path, dest)
                        manifest['files'].append([tag, os.path.basename(prefs_path)])
                    else:
                        manifest.setdefault('created', []).append(prefs_path)
                write_card_preferences(prefs_path, choices)

        if backup_root and (manifest['files'] or manifest.get('created')):
            os.makedirs(backup_root, exist_ok=True)
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
                'cardPrefs': stats['card preferences for rewards and shops'], 'cardPrefsPath': prefs_path,
                'decks': sum(c['decks changed'] for c in per_folder.values()),
                'stats': dict(stats), 'backup': backup_root, 'report': report,
                'summary': report.split('\n## By folder')[0]}


def card_prefs_path(profile):
    """Forge's per-card preferences (preferred art and star ratings), in the user's preferences folder."""
    user_dir = profile.get('userDir') or default_dirs()[0]
    return os.path.join(user_dir, 'preferences', 'card.preferences')


def card_preference_choices(chooser, editions):
    """Card name -> the printing Forge should use when it picks a card by name (rewards, shops...)."""
    names = {p.card for prints in editions.by_name.values() for p in prints}
    out = {}
    for name in sorted(names):
        p = chooser.best(name)  # with several picks of the player's own, the first one
        # Un-set cards (with their lettered variants) don't resolve by art index in Forge; leave them alone.
        if p is not None and p.type != 'Funny':
            out[name] = p
    return out


def write_card_preferences(path, choices):
    """Write Forge's card.preferences with an art preference per card, keeping the player's star ratings."""
    import xml.etree.ElementTree as ET
    stars = {}
    if os.path.isfile(path):
        try:
            for el in ET.parse(path).getroot().iter('card'):
                if el.get('stars'):
                    stars[el.get('name')] = el.get('stars')
        except ET.ParseError:
            pass
    root = ET.Element('preferences', {'type': 'cards'})
    for name in sorted(set(stars) | set(choices)):
        attrs = {'name': name}
        if name in stars:
            attrs['stars'] = stars[name]
        if name in choices:
            p = choices[name]
            attrs['art'] = f'{name}|{p.set}|{p.art}'
        ET.SubElement(root, 'card', attrs)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.part'
    ET.ElementTree(root).write(tmp, encoding='utf-8', xml_declaration=True)
    os.replace(tmp, path)


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
    for path in manifest.get('created', []):  # files the tool made that didn't exist before
        if os.path.isfile(path):
            os.remove(path)
            count += 1
    return count


def build_report(opts, apply, res, roots, stats, per_folder, chooser, kept, unknown, skipped_decks, samples):
    lines = ['# Preferred printings', '',
             f"- mode: {'applied' if apply else 'dry run'}",
             f'- Forge files: {res}',
             f"- deck folders: {', '.join(roots)}",
             f"- {'spread across every allowed printing' if opts.spread else 'single best printing'}; "
             f'order: {opts.order}; prefer old frame: {opts.prefer_old_frame}',
             f"- excluded: {', '.join(sorted(opts.exclude)) or 'nothing'}",
             f"- extra UB sets: {', '.join(sorted(opts.extra_ub_sets)) or 'none'}",
             f'- language first: {opts.language}' if opts.language != 'en' else '- language first: no preference',
             f"- Scryfall card details: {len(PRINTING_TAGS)} printings tagged" if PRINTING_TAGS else
             '- Scryfall card details: not downloaded (only Forge\'s own treatment data is used)',
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
    for key in ('forge', 'backup_dir', 'image_cache', 'scryfall_cache'):  # relative to the settings file
        if saved.get(key):
            saved[key] = os.path.join(base, os.path.expanduser(saved[key]))
    if saved.get('decks'):
        saved['decks'] = [os.path.join(base, os.path.expanduser(d)) for d in saved['decks']]
    return saved


def save_settings(opts, path):
    data = {k: getattr(opts, k) for k in SAVED_OPTIONS}
    for key in ('forge', 'image_cache', 'scryfall_cache'):
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


def scryfall_image_url(editions, p, api=SCRYFALL_API, lang='en'):
    info = editions.sets.get(p.set.upper())
    code = info.scryfall if info else p.set.lower()
    cn = p.cn[1:] if re.match(r'^F\d+[a-z]?$', p.cn) else p.cn
    face = '&face=front' if ' // ' in p.card else ''
    lang_part = '' if lang == 'en' else '/' + urllib.parse.quote(lang)
    return (f'{api}/cards/{urllib.parse.quote(code)}/{urllib.parse.quote(cn)}{lang_part}'
            f'?format=image&version=normal{face}')


class ImageDownloader:
    """Fetches card pictures from Scryfall one at a time, paced as Scryfall asks, and keeps them on disk.

    A card can have hundreds of printings; asking Scryfall for all of their pictures at once gets most of the
    requests throttled, so the picker goes through here instead of linking to Scryfall directly."""

    def __init__(self, folder):
        self.folder = folder
        self.lock = threading.Lock()
        self.last = 0.0

    def path_for(self, p, lang='en'):
        safe = lambda t: re.sub(r'[^0-9A-Za-z._-]', '_', t)
        suffix = '' if lang == 'en' else '.' + safe(lang)
        return os.path.join(self.folder, safe(p.set.upper()), safe(p.cn) + suffix + '.jpg')

    def get(self, url, dest):
        if os.path.isfile(dest):
            return dest
        with self.lock:
            if os.path.isfile(dest):  # another request fetched it while this one waited
                return dest
            for attempt in range(4):
                wait = 0.11 - (time.monotonic() - self.last)
                if wait > 0:
                    time.sleep(wait)
                self.last = time.monotonic()
                req = urllib.request.Request(url, headers={'User-Agent': 'ForgePreferredPrintings/1.0',
                                                           'Accept': 'image/*'})
                try:
                    with urllib.request.urlopen(req, timeout=30) as r:
                        data = r.read()
                except urllib.error.HTTPError as e:
                    if e.code == 429:  # throttled: back off and try again
                        time.sleep(float(e.headers.get('Retry-After') or 1) * (attempt + 1))
                        continue
                    return None
                except (urllib.error.URLError, OSError):
                    return None
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                tmp = dest + '.part'
                with open(tmp, 'wb') as f:
                    f.write(data)
                os.replace(tmp, dest)
                return dest
        return None


class GuiState:
    def __init__(self, tool, settings_path):
        self.tool = tool
        self.settings_path = settings_path
        self.lock = threading.Lock()
        self.deck_cards = None  # name -> number of decks it appears in
        self.downloader = ImageDownloader(os.path.join(os.path.dirname(tool.scryfall_path),
                                                       'preferred-printings-images'))
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
                        prints = self.tool.editions.get(parsed[2]) if parsed else None
                        if prints:  # Forge's spelling, so "snow-covered Forest" and "Snow-Covered Forest" match
                            names.add(prints[0].card if ' // ' not in prints[0].card else parsed[2])
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
            'oldFrame': o.prefer_old_frame, 'exclude': list(o.exclude), 'backup': o.backup, 'spread': o.spread,
            'cardPrefs': o.card_prefs, 'cardPrefsPath': card_prefs_path(self.tool.profile),
            'onlineImages': o.online_images, 'picsDir': self.pics_dir(),
            'picsDirFound': os.path.isdir(self.pics_dir()), 'settingsPath': os.path.abspath(self.settings_path),
            'scryfall': self.tool.scryfall_info, 'scryfallPath': self.tool.scryfall_path,
            'picks': len(normalize_choices(o.card_choices)),
            'extraUb': list(o.extra_ub_sets), 'builtInUb': sorted(BUILT_IN_UB_SETS),
            'language': o.language, 'languages': LANGUAGES, 'languageKnown': self.tool.language_known(),
            'languageFetched': o.language in ((self.tool.scryfall_info or {}).get('languages') or []),
            'forgeLanguage': read_forge_language(self.tool.profile),
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
        if 'spread' in d:
            o.spread = bool(d['spread'])
        if d.get('order') in ('latest', 'oldest'):
            o.order = d['order']
        if 'oldFrame' in d:
            o.prefer_old_frame = bool(d['oldFrame'])
        if 'exclude' in d:
            o.exclude = sorted(c for c in d['exclude'] if c in CATEGORIES)
        if 'backup' in d:
            o.backup = bool(d['backup'])
        if 'cardPrefs' in d:
            o.card_prefs = bool(d['cardPrefs'])
        if 'onlineImages' in d:
            o.online_images = bool(d['onlineImages'])
        if d.get('language') in LANGUAGES.values() and d['language'] != o.language:
            o.language = d['language']
        if 'extraUb' in d:
            codes = list(dict.fromkeys(c.strip().upper() for c in d['extraUb'] if c.strip()))
            unknown = [c for c in codes if c not in self.tool.editions.sets]
            if unknown:
                raise ToolError(f"Forge has no set with code {', '.join(unknown)}")
            o.extra_ub_sets = codes
            set_extra_ub_sets(codes)

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
            spread = len(chooser.pool(n)[0]) if chooser.spread and not picks.get(n.lower()) else 0
            out.append({'name': n, 'decks': cards[n], 'set': p.set if p else None, 'cn': p.cn if p else None,
                        'picked': picks.get(n.lower(), 0), 'spread': spread if spread > 1 else 0})
        return {'total': len(names), 'cards': out, 'deckCards': len(cards)}

    def printings(self, name):
        editions = self.tool.editions
        chooser = Chooser(editions, self.opts)
        auto, fallback = chooser.automatic(name)
        best = chooser.best(name)
        mine = {choice_key(p).upper() for p in chooser.picks(name)}
        pool = {choice_key(p).upper() for p in chooser.pool(name)[0]} if chooser.spread else set()
        out = []
        # Usable printings first, in the order the rules rank them; excluded ones after.
        for p in sorted(chooser.ranked(name), key=lambda p: is_excluded(p, chooser.excluded)):
            info = editions.sets.get(p.set.upper())
            cats = sorted(categories_of(p), key=list(CATEGORIES).index)
            out.append({
                'set': p.set, 'cn': p.cn, 'setName': info.name if info else p.set, 'year': p.date[:4],
                'section': p.section,
                'cats': [{'label': CATEGORIES[c][2], 'excluded': c in chooser.excluded} for c in cats],
                'inLanguage': in_language(p, chooser.language),
                'excluded': is_excluded(p, chooser.excluded), 'oldFrame': is_old_frame(p),
                'auto': auto is not None and choice_key(p) == choice_key(auto) and not chooser.spread,
                'inSpread': choice_key(p).upper() in pool and len(pool) > 1,
                'mine': choice_key(p).upper() in mine,
                'chosen': choice_key(p).upper() in mine if mine else (
                    choice_key(p).upper() in pool if pool else
                    best is not None and choice_key(p) == choice_key(best)),
                'img': '/img?' + urllib.parse.urlencode({'name': name, 'set': p.set, 'cn': p.cn,
                                                         'lang': chooser.language}),
            })
        return {'name': name, 'picked': len(mine), 'fallback': fallback, 'printings': out,
                'spread': len(pool) if len(pool) > 1 else 0,
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
                api, lang = self.tool.scryfall_api, self.opts.language
                # The picture in the player's language when that printing exists in it, else English.
                tries = ([(self.downloader.path_for(p, lang), scryfall_image_url(self.tool.editions, p, api, lang))]
                         if in_language(p, lang) else [])
                tries.append((self.downloader.path_for(p), scryfall_image_url(self.tool.editions, p, api)))
                for path, _ in tries:
                    if os.path.isfile(path):
                        return 'file', path
                if self.opts.online_images:
                    for path, url in tries:
                        if self.downloader.get(url, path):
                            return 'file', path
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
                    return self._json({k: result[k] for k in ('lines', 'decks', 'backup', 'summary', 'cardPrefs',
                                                              'cardPrefsPath')})
                if path == '/api/save':
                    save_settings(st.opts, st.settings_path)
                    return self._json({'path': os.path.abspath(st.settings_path)})
                if path == '/api/scryfall':
                    st.tool.update_scryfall(st.tool.scryfall_api)
                    return self._json(st.describe())
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
.art { position: relative; }
.art img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; display: block; }
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
    <div class="small" style="margin:10px 0 4px">Also count these set codes as Universes Beyond (for newer UB sets):</div>
    <input id="optExtraUb" type="text" placeholder="e.g. ABC, XYZ" autocomplete="off"
      style="width:100%;font:12px ui-monospace,monospace;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--ink);padding:6px">
    <details class="small" style="margin-top:4px"><summary>Sets already counted as UB</summary><span id="builtInUb"></span></details>

    <h2>Prefer</h2>
    <label class="opt"><input type="checkbox" id="optOld"> <span>Old frame<br><span class="small">Pre-2003 sets and “retro frame” reprints</span></span></label>
    <div class="small" style="margin:8px 0 4px">Printings in my language:</div>
    <select id="optLang" style="width:100%;font:inherit;padding:5px;border:1px solid var(--line);border-radius:6px;background:var(--panel);color:var(--ink)"></select>
    <div class="small" id="langInfo" style="margin-top:4px"></div>
    <div class="small" style="margin:10px 0 4px">From the printings that are left:</div>
    <div class="seg" id="segSpread"><button data-v="1" title="Each deck gets one of them, so a card varies from deck to deck">Spread across decks</button><button data-v="0" title="Every deck gets the same one">Use one</button></div>
    <div id="orderBox"><div class="small" style="margin:6px 0 4px">Use the</div>
    <div class="seg" id="segOrder"><button data-v="latest">Latest</button><button data-v="oldest">Oldest</button></div></div>

    <h2>Card details</h2>
    <div class="small" id="scryInfo"></div>
    <button id="btnScry" style="margin-top:6px">Download from Scryfall</button>
    <div class="small" id="scryNotes" style="margin-top:4px"></div>

    <h2>Images</h2>
    <label class="opt"><input type="checkbox" id="optOnline"> <span>Fetch missing images from Scryfall<br><span class="small" id="picsDir"></span></span></label>

    <h2>Rewards and shops</h2>
    <label class="opt"><input type="checkbox" id="optCardPrefs"> <span>Also use these printings for Adventure rewards and shop cards<br>
      <span class="small">Writes Forge’s card preferences (Forge uses them whenever it picks a card by name). Close Forge first, and keep Adventure’s “Use Card Variants from All Sets” off. Booster packs always contain their own set’s printings.</span></span></label>

    <h2>Safety</h2>
    <label class="opt"><input type="checkbox" id="optBackup"> <span>Back up decks and card preferences before changing them</span></label>
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
function langName(code) { return Object.keys(state.languages).find(k => state.languages[k] === code) || code; }
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
  $('optLang').innerHTML = Object.entries(s.languages).map(([name, code]) =>
    `<option value="${code}" ${code === s.language ? 'selected' : ''}>${code === 'en' ? 'English (no preference)' : esc(name)}${code === s.forgeLanguage ? ' – Forge’s setting' : ''}</option>`).join('');
  const n = s.languageKnown, lname = langName(s.language), pr = `${n.toLocaleString()} printing${n === 1 ? '' : 's'}`;
  $('langInfo').textContent = s.language === 'en' ? '' :
    (s.languageFetched ? `${pr} known in ${lname}.`
      : `Forge knows ${pr} in ${lname} so far. Click “${s.scryfall ? 'Update' : 'Download'} from Scryfall” below to learn about all of them.`) +
    (s.forgeLanguage === s.language ? '' : ` Also set Forge’s “Card download language” to ${lname}, so Forge shows the cards in it.`);
  $('optOnline').checked = s.onlineImages; $('optBackup').checked = s.backup; $('optCardPrefs').checked = s.cardPrefs;
  $('optExtraUb').value = s.extraUb.join(', '); $('builtInUb').textContent = s.builtInUb.join(', ');
  $('scryInfo').textContent = s.scryfall
    ? `${s.scryfall.printings.toLocaleString()} printings tagged (full art, borderless, inverted…), downloaded ${s.scryfall.fetched.replace('T', ' ')}.`
    : 'Forge’s files miss many full-art, borderless and other treatments. Download the details from Scryfall to tag them (takes about a minute).';
  $('btnScry').textContent = s.scryfall ? 'Update from Scryfall' : 'Download from Scryfall';
  $('scryNotes').textContent = s.scryfall && s.scryfall.notes.length ? 'Notes: ' + s.scryfall.notes.join('; ') : '';
  $('picsDir').textContent = (s.picsDirFound ? 'Forge image cache: ' : 'No Forge image cache found at ') + s.picsDir;
  $('settingsPath').textContent = 'Settings file: ' + s.settingsPath;
  for (const b of $('segOrder').children) b.classList.toggle('on', b.dataset.v === s.order);
  for (const b of $('segSpread').children) b.classList.toggle('on', (b.dataset.v === '1') === s.spread);
  $('orderBox').style.display = s.spread ? 'none' : '';
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
    cardPrefs: $('optCardPrefs').checked,
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
          : c.spread ? `<span class="badge" title="The rules spread ${c.spread} printings across decks">${c.spread} prints</span>`
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
  else if (data.spread) note = `<div class="note">The rules allow <b>${data.spread}</b> printings, highlighted, and spread them across the ${data.decks.toLocaleString()} deck${data.decks === 1 ? '' : 's'} using this card: each deck gets one of them, and the same one every time.${data.fallback ? ' (Only excluded treatments exist for this card, so these are the best of them.)' : ''}</div>`;
  else if (!chosen) note = '<div class="note">Every printing of this card is excluded by an “always” rule, so its decks keep the printing they already use. You can still pick one here.</div>';
  else if (data.fallback) note = '<div class="note">Only excluded treatments exist for this card, so the rules fall back to the best of them.</div>';
  d.innerHTML = `<div class="detail-head"><h2>${esc(data.name)}</h2>
    <label><input type="checkbox" id="optHide" ${hideExcluded ? 'checked' : ''}> Hide excluded</label></div>
    <div class="small">${data.printings.length} printing${data.printings.length === 1 ? '' : 's'} in Forge${hidden ? ` (${hidden} excluded hidden)` : ''}. ${mine.length ? 'Highlighted: your picks.' : data.spread ? 'Highlighted: the printings the rules spread across decks.' : 'Highlighted: the one the rules choose.'} Click printings to pick them; click again to unpick.</div>
    ${note}
    <div class="grid">${shown.map(([p, i]) => `
      <div class="tile ${p.chosen ? 'chosen' : ''} ${p.excluded ? 'excluded' : ''}" data-i="${i}" title="${esc(p.setName)} (${esc(p.set)}) #${esc(p.cn)}">
        <div class="art"><span>Loading…</span><img loading="lazy" alt="" src="${p.img}" onerror="this.parentNode.textContent='No image'"></div>
        <div class="meta"><div class="set">${esc(p.setName)}</div>
          <div class="small">${esc(p.set)} · #${esc(p.cn)} · ${esc(p.year)}</div>
          <div class="tags">
            ${p.mine ? '<span class="tag mine">Your pick</span>' : ''}
            ${p.auto ? '<span class="tag auto">Rules pick</span>' : ''}
            ${p.inSpread && !mine.length ? '<span class="tag auto">In the spread</span>' : ''}
            ${p.inLanguage ? `<span class="tag old">${esc(langName(state.language))}</span>` : ''}
            ${p.oldFrame ? '<span class="tag old">Old frame</span>' : ''}
            ${p.cats.map(c => `<span class="tag ${c.excluded ? 'ex' : ''}">${esc(c.label)}${c.excluded ? ' · excluded' : ''}</span>`).join('')}
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

async function busy(btn, fn) {
  const old = btn.textContent; btn.disabled = true; btn.textContent = 'Working…';
  try { await fn(); } finally { btn.disabled = false; if (btn.textContent === 'Working…') btn.textContent = old; }
}

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
    if (!p.lines && !p.cardPrefs) { toast('Nothing to change: your decks already match.'); return; }
    const ok = await dialog('Apply to decks?', `<p>This changes <b>${p.lines.toLocaleString()}</b> card lines in <b>${p.decks.toLocaleString()}</b> deck files.</p>` +
      (p.cardPrefs ? `<p>It also sets the printing of <b>${p.cardPrefs.toLocaleString()}</b> cards for Adventure rewards and shops, in<br><code>${esc(p.cardPrefsPath)}</code>.<br><b>Close Forge before you continue</b>, or it may overwrite this when it exits.</p>` : '') +
      (state.backup ? '<p>The originals are backed up first, so you can undo it.</p>' : '<p><b>Backups are off</b>, so this can’t be undone.</p>'),
      [['Cancel', false], ['Apply', true, true]]);
    if (!ok) return;
    const r = await api('/api/run', { apply: true });
    await dialog('Done', `<p>Changed ${r.lines.toLocaleString()} card lines in ${r.decks.toLocaleString()} decks.</p>` +
      (r.cardPrefs ? `<p>Set the printing of ${r.cardPrefs.toLocaleString()} cards for rewards and shops.</p>` : '') +
      (r.backup ? `<p class="small">Originals backed up to<br><code>${esc(r.backup)}</code></p><p class="small">To undo, run:<br><code>python3 preferred_printings.py --restore "${esc(r.backup)}"</code></p>` : ''),
      [['Close', null, true]]);
    loadCards(); if (current) openCard(current);
  } catch (e) { toast(e.message); }
});
$('btnScry').onclick = () => busy($('btnScry'), async () => {
  try {
    state = await api('/api/scryfall', {}); renderSettings(); await loadCards(); if (current) await openCard(current);
    toast(`Tagged ${state.scryfall.printings.toLocaleString()} printings from Scryfall`);
  } catch (e) { toast(e.message); }
});
$('btnSave').onclick = () => busy($('btnSave'), async () => {
  try { const r = await api('/api/save', {}); toast('Saved to ' + r.path); } catch (e) { toast(e.message); }
});

for (const id of ['optOld', 'optOnline', 'optBackup', 'optSkipSet', 'optCardPrefs']) $(id).onchange = () => saveRules();
for (const id of ['optAdventure', 'optUser']) $(id).onchange = () => saveDecks();
$('optExtra').onchange = () => saveDecks();
 $('optLang').onchange = () => saveRules({ language: $('optLang').value });
$('optExtraUb').onchange = () => saveRules({ extraUb: $('optExtraUb').value.split(/[\s,]+/).filter(Boolean) });
for (const b of $('segOrder').children) b.onclick = () => saveRules({ order: b.dataset.v });
for (const b of $('segSpread').children) b.onclick = () => saveRules({ spread: b.dataset.v === '1' });
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
    rules.add_argument('--spread', action=argparse.BooleanOptionalAction, default=None,
                       help='spread decks across all the printings the rules allow, so the same card varies from '
                            'deck to deck; --no-spread gives every deck the single best one (default: spread)')
    rules.add_argument('--order', choices=('latest', 'oldest'),
                       help='with --no-spread, which printing wins among equally preferred ones (default: latest)')
    rules.add_argument('--prefer-old-frame', action=argparse.BooleanOptionalAction, default=None,
                       help='prefer pre-Eighth Edition frames and retro-frame reprints (default: on)')
    rules.add_argument('--exclude', nargs='*', choices=sorted(CATEGORIES), metavar='CATEGORY',
                       help='categories to exclude (default: all of them)')
    rules.add_argument('--include', nargs='*', choices=sorted(CATEGORIES), default=[], metavar='CATEGORY',
                       help='categories to allow again, removed from the excluded ones')
    rules.add_argument('--language', choices=sorted(LANGUAGES.values()), default=None, metavar='CODE',
                       help='put printings that exist in this language first: ' + ', '.join(
                           f'{v} ({k})' for k, v in LANGUAGES.items()) + ". Default: Forge's own Card download "
                       'language; en means no preference')
    rules.add_argument('--ub-set', dest='extra_ub_sets', action='append', metavar='CODE',
                       help='also treat this set code as Universes Beyond (for UB sets newer than this tool); '
                            'repeatable')

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
    run.add_argument('--update-scryfall', action='store_true',
                     help='download card details (full art, borderless, showcase, inverted, thick, gold border, '
                          'UB stamp...) from Scryfall before running; they are saved and reused afterwards')
    run.add_argument('--scryfall-cache', metavar='FILE', default=None,
                     help=f'where those card details are saved (default: {SCRYFALL_CACHE_NAME} next to the '
                          'settings file, or in the current folder)')
    run.add_argument('--scryfall-api', default=SCRYFALL_API, help=argparse.SUPPRESS)
    run.add_argument('--apply', action='store_true', help='rewrite the deck files (default: dry run)')
    run.add_argument('--card-prefs', action=argparse.BooleanOptionalAction, default=None,
                     help="also write Forge's card preferences, so Adventure rewards and shops (and anything else "
                          'that picks a card by name) use the same printings. Close Forge first (default: off)')
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
            print(f'Restored {count} file{"" if count == 1 else "s"} from {args.restore}')
            return
        if args.save_config:
            save_settings(args, args.save_config)
            print(f'Settings saved to {args.save_config}. Run again with: --config "{args.save_config}" --apply')
            return
        tool = Tool(args)
        tool.scryfall_api = args.scryfall_api
        if args.update_scryfall:
            info = tool.update_scryfall(args.scryfall_api,
                                        progress=lambda m: print(f'\r{m:<60}', end='', file=sys.stderr))
            print(f"\rScryfall card details saved to {tool.scryfall_path}: {info['printings']} printings tagged.",
                  file=sys.stderr)
            for note in info['notes']:
                print(f'  note: {note}', file=sys.stderr)
        elif not tool.scryfall_info:
            print('Tip: add --update-scryfall once to tag full art, inverted, thick and other printings that '
                  "Forge's files don't mark.", file=sys.stderr)
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
            if result['cardPrefs']:
                print(f"Wrote printings for {result['cardPrefs']} cards to {result['cardPrefsPath']}, for "
                      'rewards and shops (Adventure setting "Use Card Variants from All Sets" must be off).',
                      file=sys.stderr)
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
