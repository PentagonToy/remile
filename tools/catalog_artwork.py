#!/usr/bin/env python3
"""Export the source artwork catalogue and system-symbol names; no symbol extraction."""
import argparse
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true', help='Verify the maintained catalogues without writing')
args = parser.parse_args()
art = root / 'others'
assets = []
for path in sorted(art.rglob('*.svg')):
    relative = path.relative_to(art).as_posix()
    if relative.startswith(('templates/', 'symbols/guide/')):
        continue
    assets.append({'source': relative, 'bundle': 'Brand/' + path.name})
assert len({x['bundle'] for x in assets}) == len(assets), 'Duplicate runtime asset name'
uses = {}
for source in sorted((root / 'Sources/Remile').rglob('*.swift')):
    # Literal native system symbols actually referenced by UI code, including Label.
    content = source.read_text()
    names = set(re.findall(r'(?:systemName|systemImage):\s*"([^"\\]+)"', content))
    # Include literal alternatives in conditional systemName expressions as well.
    for expression in re.findall(r'(?:systemName|systemImage):[^\n)]*', content):
        choices = expression.split("?", 1)[-1]
        names.update(re.findall(r'"([a-z][a-z0-9.-]*)"', choices))
    if source.name in {"ReferenceKind.swift", "PDFDrawing.swift"}:
        symbol_body = content.split("var symbol: String {", 1)[1].split("\n    }", 1)[0]
        names.update(re.findall(r'return "([a-z][a-z0-9.-]*)"', symbol_body))
    for name in names:
        uses.setdefault(name, []).append(source.relative_to(root).as_posix())
catalogues = {
    art / 'catalogue.json': {'schemaVersion': 1, 'assets': assets, 'templates': ['templates/help/bubble.json'], 'licences': ['licences/CHATGPT-LICENSE.txt', 'licences/SEARCH-WORDS.txt']},
    art / 'symbols/system-symbols.json': {'schemaVersion': 1, 'format': 'Native SF Symbols names; resolve on the target macOS, do not redistribute Apple artwork.', 'symbols': [{'name': n, 'sources': sorted(p)} for n, p in sorted(uses.items())]},
}
for path, value in catalogues.items():
    text = json.dumps(value, indent=2) + '\n'
    if args.check:
        assert path.read_text() == text, f'Regenerate {path.relative_to(root)} with tools/catalog_artwork.py'
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
print(f'{len(assets)} runtime SVG assets; {len(uses)} native symbol names; catalogues verified' if args.check else f'Catalogued {len(assets)} runtime SVG assets and {len(uses)} native symbol names')
