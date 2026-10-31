#!/usr/bin/env python3
"""Compares the extension API of the pinned Godot with the JSON that godot-cpp ships for api_version.

    compare_extension_api.py DUMPED.json BUNDLED.json

DUMPED.json comes from `godot --headless --dump-extension-api` (the Godot we build and test with),
BUNDLED.json is godot-cpp's gdextension/extension_api-<api_version>.json. godot-cpp generates its
bindings from the second one, so every class, method (with its hash), builtin size and offset in it
must be what the first one says. The header may differ in exactly two fields: a patch release has
another version_patch and version_full_name. Anything else is a difference.

Exit code 0 and "RESULT: identical" when equal, 1 and "RESULT: DIFFERENT" otherwise.
"""
import json
import sys

HEADER_MAY_DIFFER = {"version_patch", "version_full_name"}
MAX_REPORTED = 25


def diff(a, b, path):
    """Yields a description of every place where a and b differ."""
    if type(a) is not type(b):
        yield f"{path}: type {type(a).__name__} vs {type(b).__name__}"
    elif isinstance(a, dict):
        for key in sorted(a.keys() | b.keys(), key=str):
            if key not in a:
                yield f"{path}/{key}: only in bundled"
            elif key not in b:
                yield f"{path}/{key}: only in dumped"
            else:
                yield from diff(a[key], b[key], f"{path}/{key}")
    elif isinstance(a, list):
        if len(a) != len(b):
            yield f"{path}: list length {len(a)} vs {len(b)}"
        for index, (x, y) in enumerate(zip(a, b)):
            label = x.get("name", index) if isinstance(x, dict) else index
            yield from diff(x, y, f"{path}[{label}]")
    elif a != b:
        yield f"{path}: {a!r} vs {b!r}"


def count_methods(api):
    classes = api["classes"]
    builtins = api["builtin_classes"]
    return (sum(len(c.get("methods", [])) for c in classes), sum(len(c.get("methods", [])) for c in builtins))


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as f:
        dumped = json.load(f)
    with open(sys.argv[2], encoding="utf-8") as f:
        bundled = json.load(f)

    d_head, b_head = dumped["header"], bundled["header"]
    print(f"dumped header : {d_head['version_full_name']} (precision {d_head['precision']})")
    print(f"bundled header: {b_head['version_full_name']} (precision {b_head['precision']})")
    for section in ("builtin_class_sizes", "builtin_class_member_offsets", "global_constants", "global_enums",
                    "utility_functions", "builtin_classes", "classes", "singletons", "native_structures"):
        print(f"  {section:30s} dumped {len(dumped[section]):5d}  bundled {len(bundled[section]):5d}")
    print("  class methods (engine, builtin) dumped %d, %d  bundled %d, %d" % (*count_methods(dumped), *count_methods(bundled)))

    problems = []
    for key in sorted(d_head.keys() | b_head.keys()):
        if key not in HEADER_MAY_DIFFER and d_head.get(key) != b_head.get(key):
            problems.append(f"header/{key}: {d_head.get(key)!r} vs {b_head.get(key)!r}")
    for key in sorted(dumped.keys() | bundled.keys()):
        if key != "header":
            problems.extend(diff(dumped.get(key), bundled.get(key), key))

    if not problems:
        print("RESULT: identical (only version_patch and version_full_name of the header differ)")
        return 0
    print(f"RESULT: DIFFERENT ({len(problems)} difference(s); first {min(len(problems), MAX_REPORTED)}):")
    for line in problems[:MAX_REPORTED]:
        print(f"  {line}")
    print("Use custom_api_file=<dumped json> instead of api_version if the differences matter.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
