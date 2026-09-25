#!/usr/bin/env python3
"""Add a Swift file to Trio.xcodeproj next to an existing sibling file.

Usage: add_to_xcodeproj.py <project.pbxproj> <sibling.swift> <new.swift>

The new file lands in the sibling's group and the sibling's target(s): a
PBXFileReference, a PBXBuildFile, a group child and a Sources-phase entry are
each cloned from the sibling's lines with fresh 24-hex ids.
"""
import re
import secrets
import sys


def new_id(text):
    while True:
        candidate = secrets.token_hex(12).upper()
        if candidate not in text:
            return candidate


def main(pbxproj, sibling, new):
    text = open(pbxproj, encoding="utf-8").read()
    if f"path = {new};" in text:
        sys.exit(f"{new} is already in the project")

    ref_match = re.search(
        rf"^\t\t([0-9A-F]{{24}}) /\* {re.escape(sibling)} \*/ = {{isa = PBXFileReference;[^\n]*\n", text, re.M
    )
    if not ref_match:
        sys.exit(f"no PBXFileReference for {sibling}")
    sib_ref = ref_match.group(1)
    ref_id = new_id(text)
    ref_line = ref_match.group(0).replace(sib_ref, ref_id).replace(sibling, new)
    text = text.replace(ref_match.group(0), ref_match.group(0) + ref_line, 1)

    child = f"\t\t\t\t{sib_ref} /* {sibling} */,\n"
    if text.count(child) != 1:
        sys.exit(f"expected exactly one group child for {sibling}")
    text = text.replace(child, child + f"\t\t\t\t{ref_id} /* {new} */,\n", 1)

    build_matches = list(
        re.finditer(
            rf"^\t\t([0-9A-F]{{24}}) /\* {re.escape(sibling)} in Sources \*/ = {{isa = PBXBuildFile; fileRef = {sib_ref} [^\n]*\n",
            text,
            re.M,
        )
    )
    if not build_matches:
        sys.exit(f"no PBXBuildFile for {sibling}")
    for match in build_matches:
        sib_build = match.group(1)
        build_id = new_id(text)
        line = match.group(0).replace(sib_build, build_id).replace(sib_ref, ref_id).replace(sibling, new)
        text = text.replace(match.group(0), match.group(0) + line, 1)
        phase = f"\t\t\t\t{sib_build} /* {sibling} in Sources */,\n"
        if text.count(phase) != 1:
            sys.exit(f"expected exactly one Sources entry for {sibling}")
        text = text.replace(phase, phase + f"\t\t\t\t{build_id} /* {new} in Sources */,\n", 1)

    open(pbxproj, "w", encoding="utf-8").write(text)
    print(f"added {new} next to {sibling} ({len(build_matches)} target(s))")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
