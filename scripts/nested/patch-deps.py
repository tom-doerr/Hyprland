#!/usr/bin/env python3
"""Port hyprwire's range appends to the GCC 14 standard library."""
import re
import sys
from pathlib import Path

pattern = re.compile(r"^(\s*)([\w.]+)\.append_range\((.+)\);$", re.MULTILINE)


def replace(match):
    indent, target, value = match.groups()
    return (
        f"{indent}{{\n"
        f"{indent}    auto&& appended = {value};\n"
        f"{indent}    {target}.insert({target}.end(), appended.begin(), appended.end());\n"
        f"{indent}}}"
    )


for path in Path(sys.argv[1]).rglob("*.cpp"):
    if "build" in path.parts:
        continue
    original = path.read_text()
    patched, count = pattern.subn(replace, original)
    if count:
        path.write_text(patched)
        print(f"Patched {count} range appends in {path.name}")
