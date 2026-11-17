#!/usr/bin/env python3
"""Build an offline name trie from the pinned Digital Agency town CSV ZIP."""
import argparse
import csv
import hashlib
import io
import json
import re
import struct
import unicodedata
import zipfile
from pathlib import Path

SOURCE_URL = 'https://data.address-br.digital.go.jp/mt_town/mt_town_all.csv.zip'
SOURCE_SHA256 = 'd4745978092c30e4ed4e1aa8901b29b2f90a7e5bf4c0b2e4301693547cd7c6fa'
SOURCE_UPDATED = '2026-11-06T15:40:49.000Z'
FIELDS = {'pref': 1, 'county': 2, 'city': 2, 'ward': 2, 'oaza_cho': 4, 'koaza': 8}


def normalize(value):
    # Match the OCR normalizer without changing the original glyph offsets.
    value = ''.join(chr(ord(c) - 0xFEE0) if 0xFF01 <= ord(c) <= 0xFF5E else c for c in value)
    return re.sub(r'[ \t\u3000]', '', value)


def aliases(value, field):
    yield value
    if field in ('city', 'ward', 'county') and value[-1:] in '市区町村郡':
        yield value[:-1]
    if field in ('oaza_cho', 'koaza'):
        yield re.sub(r'^(?:大字|小字|字)', '', value)


def is_single_kanji(value):
    if len(value) != 1:
        return False
    return unicodedata.name(value, '').startswith((
        'CJK UNIFIED IDEOGRAPH-', 'CJK COMPATIBILITY IDEOGRAPH-',
    ))


def build(source, output):
    raw = source.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    if digest != SOURCE_SHA256:
        raise ValueError('Source checksum differs: explicitly review and pin a new snapshot before rebuilding.')
    names = {}
    rows = 0
    municipalities = set()
    statuses = {}
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        with archive.open('mt_town_all.csv') as stream:
            reader = csv.DictReader(io.TextIOWrapper(stream, encoding='utf-8-sig'))
            if not set(FIELDS).issubset(reader.fieldnames or []):
                raise ValueError('Missing source columns')
            for row in reader:
                rows += 1
                statuses[row['status_flg']] = statuses.get(row['status_flg'], 0) + 1
                municipalities.add(row['lg_code'])
                for field, flag in FIELDS.items():
                    original = normalize(row[field])
                    if not original or not re.search(r'[A-Za-z぀-ヿ㐀-鿿𠀀-𱍏]', original):
                        continue
                    for name in aliases(original, field):
                        # Count Unicode code points, including supplementary kanji.
                        if len(name) >= 2 or is_single_kanji(name):
                            names[name] = names.get(name, 0) | flag
    # UTF-16 edges match Dart String offsets, including supplementary kanji.
    nodes = [{}]
    flags = [0]
    max_depth = 0
    for name, flag in sorted(names.items()):
        units = struct.unpack('<' + 'H' * (len(name.encode('utf-16-le')) // 2), name.encode('utf-16-le'))
        max_depth = max(max_depth, len(units))
        node = 0
        for unit in units:
            if unit not in nodes[node]:
                nodes[node][unit] = len(nodes)
                nodes.append({})
                flags.append(0)
            node = nodes[node][unit]
        flags[node] |= flag
    edges = []
    records = bytearray()
    for node, children in enumerate(nodes):
        records.extend(struct.pack('<IHH', len(edges), len(children), flags[node]))
        edges.extend(sorted(children.items()))
    binary = bytearray(struct.pack('<4sIII', b'JPN1', len(nodes), len(edges), max_depth))
    binary.extend(records)
    for unit, child in edges:
        binary.extend(struct.pack('<II', unit, child))
    output.mkdir(parents=True, exist_ok=True)
    (output / 'names.bin').write_bytes(binary)
    metadata = {
        'source_url': SOURCE_URL, 'source_sha256': digest,
        'source_updated_utc': SOURCE_UPDATED,
        'source_catalog': 'https://dataset.address-br.digital.go.jp/documents/b80e77a0e2d24e5692be4af885eb3de7',
        'rows': rows, 'municipality_codes': len(municipalities),
        'status_counts': statuses, 'fields': FIELDS, 'names_with_aliases': len(names),
        'single_character_names': sum(len(n) == 1 for n in names),
        'nodes': len(nodes), 'edges': len(edges), 'max_utf16_length': max_depth,
        'binary_bytes': len(binary), 'binary_sha256': hashlib.sha256(binary).hexdigest(),
        'processing': 'camereon: deduplicate names; remove city/ward/town/village/county suffixes for aliases; remove aza/oaza/koaza prefixes for aliases; include all published rows, excluding numeric/punctuation-only field values and non-kanji single-character names/aliases; no invented names.',
    }
    (output / 'manifest.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(metadata, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--output', type=Path, default=Path('assets/address_dictionary'))
    args = parser.parse_args()
    build(args.source, args.output)
