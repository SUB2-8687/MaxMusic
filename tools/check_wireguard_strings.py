#!/usr/bin/env python3
"""Checks the WireGuard language pack: <lang>.lproj/WireGuard.strings beside Localizable.strings.

 - every WG_* key used by the sources exists in en.lproj and ko.lproj WireGuard.strings, and nothing else is in them
 - ko has the same keys and the same format specifiers (%@, %lld ...) as en
 - no WG_* key is left in a Localizable.strings
Run from the repository root: python3 tools/check_wireguard_strings.py
"""
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUNDLE = os.path.join(ROOT, 'layout', 'Library', 'Application Support', 'YTMusicUltimate.bundle')
SOURCES = [os.path.join(ROOT, 'Source', 'WireGuard', 'YTMUWGSettingsController.m'),
           os.path.join(ROOT, 'Source', 'Prefs', 'YTMUltimateSettingsController.m')]
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.M)
FMT = re.compile(r'%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:lld|ld|lu|llu|[@dsfiuxXcC%])')
problems = []

def bad(msg): problems.append(msg)

def read(path):
    with open(path, encoding='utf-8') as f: text = f.read()
    entries = ENTRY.findall(text)
    keys = [k for k, _ in entries]
    for k in {k for k in keys if keys.count(k) > 1}: bad(f'{os.path.relpath(path, ROOT)}: {k} appears twice')
    return dict(entries)

used = set()
for src in SOURCES:
    with open(src, encoding='utf-8') as f: used |= set(re.findall(r'@"(WG_[A-Z0-9_]+)"', f.read()))

tables = {}
for lang in ('en', 'ko'):
    path = os.path.join(BUNDLE, f'{lang}.lproj', 'WireGuard.strings')
    if not os.path.exists(path): bad(f'{lang}.lproj/WireGuard.strings is missing'); continue
    tables[lang] = read(path)
    for k in sorted(used - set(tables[lang])): bad(f'{lang}: {k} is used by the sources but not translated')
    for k in sorted(set(tables[lang]) - used): bad(f'{lang}: {k} is not used by the sources')
    for k in tables[lang]:
        if not k.startswith('WG_'): bad(f'{lang}: {k} does not belong in WireGuard.strings')

if len(tables) == 2:
    en, ko = tables['en'], tables['ko']
    for k in sorted(set(en) ^ set(ko)): bad(f'ko/en differ on {k}')
    for k in sorted(set(en) & set(ko)):
        if sorted(FMT.findall(en[k])) != sorted(FMT.findall(ko[k])): bad(f'format specifiers differ in {k}')
        if not ko[k].strip(): bad(f'ko: {k} is empty')

for path in glob.glob(os.path.join(BUNDLE, '*.lproj', 'Localizable.strings')):
    for k in read(path):
        if k.startswith('WG_'): bad(f'{os.path.relpath(path, ROOT)} still holds {k}; it belongs in WireGuard.strings')

for p in problems: print('check_wireguard_strings:', p)
print(f'check_wireguard_strings: {len(used)} keys, {len(problems)} problem(s)')
sys.exit(1 if problems else 0)
