#!/usr/bin/env python3
"""
Repair Neo9labs OrcaSlicer bundles so they survive upstream profile-ID
changes (issue #431) and ship clean (no hardcoded hosts, no macOS junk).

OrcaSlicer 2.4.0-beta renamed/reorganised several bundled vendor profile IDs.
A Neo9labs profile that inherits a vendor parent profile will fail to load if
that parent ID no longer exists, so the user's printer appears "missing" or
resets.

This script:
  * validates every `inherits` reference against the profiles present in the
    bundle,
  * remaps known renamed parents to their current IDs (table below),
  * removes `print_host` / `print_host_webui` (a hardcoded LAN IP must never be
    shipped in a public profile),
  * strips macOS metadata (`__MACOSX`, `.DS_Store`, `._*`),
  * bumps the bundle version and rewrites the archive in place.

Usage:
    python repair_orca_bundles.py [path ...]

With no paths, it repairs every *.orca_printer under ./orca-profiles.
"""

import json
import os
import shutil
import sys
import tempfile
import zipfile

# Known upstream renames. Keys are old IDs, values are the current ID (or a
# list of candidates to try). Extend as Orca changes IDs again.
INHERIT_REMAP = {
    # Orca 2.4.0-beta standardised the vendor prefix.
    "Elegoo Neptune 4 (0.4 nozzle)": [
        "Elegoo Neptune 4 (0.4 nozzle)",
        "Elegoo Neptune 4 0.4 nozzle",
    ],
    "Elegoo Neptune 4 Pro (0.4 nozzle)": [
        "Elegoo Neptune 4 Pro (0.4 nozzle)",
        "Elegoo Neptune 4 Pro 0.4 nozzle",
    ],
    "Elegoo Neptune 4 Plus (0.4 nozzle)": [
        "Elegoo Neptune 4 Plus (0.4 nozzle)",
        "Elegoo Neptune 4 Plus 0.4 nozzle",
    ],
    "Elegoo Neptune 4 Max (0.4 nozzle)": [
        "Elegoo Neptune 4 Max (0.4 nozzle)",
        "Elegoo Neptune 4 Max 0.4 nozzle",
    ],
    "0.20mm Standard @Elegoo Neptune4Pro (0.4 nozzle)": [
        "0.20mm Standard @Elegoo Neptune 4 Pro (0.4 nozzle)",
        "0.20mm Standard @Elegoo Neptune4Pro (0.4 nozzle)",
    ],
    "0.20mm Standard @Elegoo Neptune4 Plus (0.4 nozzle)": [
        "0.20mm Standard @Elegoo Neptune 4 Plus (0.4 nozzle)",
        "0.20mm Standard @Elegoo Neptune4 Plus (0.4 nozzle)",
    ],
    "0.20mm Standard @Elegoo Neptune4Max (0.4 nozzle)": [
        "0.20mm Standard @Elegoo Neptune 4 Max (0.4 nozzle)",
        "0.20mm Standard @Elegoo Neptune4Max (0.4 nozzle)",
    ],
    "Generic PETG @Elegoo": ["Generic PETG @Elegoo", "Generic PETG @Elegoo"],
    "Generic PLA @Elegoo": ["Generic PLA @Elegoo", "Generic PLA @Elegoo"],
}

# Keys that must never be baked into a shared profile.
STRIP_KEYS = ("print_host", "print_host_webui", "printhost_apikey")

BUNDLE_VERSION = "2.0.0"


def _is_junk(name):
    parts = name.replace("\\", "/").split("/")
    if "__MACOSX" in parts:
        return True
    base = parts[-1]
    return base == ".DS_Store" or base.startswith("._")


def _candidate_ids(pid, known_ids):
    """Return the parent ID to use: the first candidate that actually exists."""
    candidates = INHERIT_REMAP.get(pid, [pid])
    for cand in candidates:
        if cand in known_ids:
            return cand
    # Fall back to the first candidate so the profile at least references a
    # valid-looking ID; the user can re-select a parent in Orca if needed.
    return candidates[0]


def repair_bundle(path):
    if not zipfile.is_zipfile(path):
        print(f"  ! skipping (not a zip): {path}")
        return False

    tmpdir = tempfile.mkdtemp(prefix="orca_repair_")
    try:
        with zipfile.ZipFile(path) as zf:
            members = [m for m in zf.namelist() if not _is_junk(m)]
            zf.extractall(tmpdir, members=members)

        # First pass: collect all profile IDs present in the bundle.
        known_ids = set()
        json_files = []
        for root, _dirs, files in os.walk(tmpdir):
            for fn in files:
                if fn.endswith(".json"):
                    fp = os.path.join(root, fn)
                    json_files.append(fp)
                    try:
                        with open(fp, encoding="utf-8") as f:
                            data = json.load(f)
                        for key in ("name", "printer_settings_id",
                                    "filament_settings_id", "print_settings_id"):
                            if isinstance(data.get(key), str):
                                known_ids.add(data[key])
                    except (OSError, json.JSONDecodeError):
                        pass

        # Second pass: fix inherits and strip host keys.
        changed = 0
        for fp in json_files:
            try:
                with open(fp, encoding="utf-8") as f:
                    data = json.load(f)
            except (OSError, json.JSONDecodeError) as e:
                print(f"  ! unreadable JSON {os.path.basename(fp)}: {e}")
                continue

            dirty = False
            inherits = data.get("inherits")
            if isinstance(inherits, str) and inherits and inherits not in known_ids:
                new_parent = _candidate_ids(inherits, known_ids)
                if new_parent != inherits:
                    print(f"  ~ remap inherits: '{inherits}' -> '{new_parent}'")
                    data["inherits"] = new_parent
                    dirty = True

            for k in STRIP_KEYS:
                if k in data:
                    del data[k]
                    dirty = True

            # Keep the profile's own version current.
            if data.get("version") != BUNDLE_VERSION:
                data["version"] = BUNDLE_VERSION
                dirty = True

            if dirty:
                with open(fp, "w", encoding="utf-8") as f:
                    json.dump(data, f, indent=4, ensure_ascii=False)
                    f.write("\n")
                changed += 1

        # Fix bundle_structure.json version if present.
        for root, _dirs, files in os.walk(tmpdir):
            for fn in files:
                if fn == "bundle_structure.json":
                    fp = os.path.join(root, fn)
                    try:
                        with open(fp, encoding="utf-8") as f:
                            bs = json.load(f)
                        bs["version"] = BUNDLE_VERSION
                        with open(fp, "w", encoding="utf-8") as f:
                            json.dump(bs, f, indent=4, ensure_ascii=False)
                            f.write("\n")
                        changed += 1
                    except (OSError, json.JSONDecodeError):
                        pass

        # Rewrite the archive atomically.
        new_zip = path + ".new"
        with zipfile.ZipFile(new_zip, "w", zipfile.ZIP_DEFLATED) as zf:
            for root, _dirs, files in os.walk(tmpdir):
                for fn in files:
                    fp = os.path.join(root, fn)
                    arc = os.path.relpath(fp, tmpdir).replace(os.sep, "/")
                    zf.write(fp, arc)
        shutil.move(new_zip, path)

        print(f"  = repaired {os.path.basename(path)} ({changed} file(s) updated)")
        return True
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def main(argv):
    targets = argv[1:]
    if not targets:
        # The script lives inside orca-profiles/, so walk its own directory.
        base = os.path.dirname(os.path.abspath(__file__))
        for root, _dirs, files in os.walk(base):
            for fn in files:
                if fn.endswith(".orca_printer"):
                    targets.append(os.path.join(root, fn))

    if not targets:
        print("No .orca_printer bundles found.")
        return 1

    ok = 0
    for path in targets:
        print(f"* {path}")
        if repair_bundle(path):
            ok += 1
    print(f"\nRepaired {ok}/{len(targets)} bundle(s).")
    return 0 if ok == len(targets) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
