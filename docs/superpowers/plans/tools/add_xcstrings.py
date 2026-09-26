#!/usr/bin/env python3
"""Add source strings with Turkish translations to Localizable.xcstrings.

Usage: add_xcstrings.py <Localizable.xcstrings> <entries.json>

entries.json: [{"key": "...", "comment": "...", "tr": "..."}, ...]

Keeps Xcode's on-disk format (2-space indent, " : " separators, existing key order). An existing key only gains the missing "tr"
localization; nothing else of it changes.
"""
import json
import sys


def insert_in_order(strings, key):
    """Insert key before the first existing key that sorts after it, keeping every other key where it is.

    Xcode re-sorts the catalog with its own collation on the next build, so an approximate spot is enough and
    the diff stays limited to the new entries.
    """
    result = {}
    placed = False
    for existing, value in strings.items():
        if not placed and existing.lower() > key.lower():
            result[key] = {}
            placed = True
        result[existing] = value
    if not placed:
        result[key] = {}
    return result


def main(path, entries_path):
    catalog = json.load(open(path, encoding="utf-8"))
    entries = json.load(open(entries_path, encoding="utf-8"))
    strings = catalog["strings"]
    for entry in entries:
        if entry["key"] not in strings:
            strings = insert_in_order(strings, entry["key"])
        item = strings[entry["key"]]
        if entry.get("comment") and "comment" not in item:
            item["comment"] = entry["comment"]
        localizations = item.setdefault("localizations", {})
        localizations.setdefault("tr", {"stringUnit": {"state": "translated", "value": entry["tr"]}})
    catalog["strings"] = strings
    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))
    open(path, "w", encoding="utf-8").write(text)
    print(f"{len(entries)} entries merged")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
