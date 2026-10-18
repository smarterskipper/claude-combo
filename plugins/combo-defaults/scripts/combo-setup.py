#!/usr/bin/env python3
"""Merge the claude-combo defaults into Claude Code's user settings.

Sets model, Opus 5.5 effort, output style and ultracode. Every other key stays
where it is. Plugins can't set these keys themselves, so this runs once per machine.

  python3 combo-setup.py            # merge, back up the old file, print what changed
  python3 combo-setup.py --dry-run  # print what would change, write nothing
"""
import argparse
import copy
import json
import os
import shutil
import sys
import tempfile
import time

MODEL = "claude-opus-5-5"


def default_path():
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(base, "settings.json")


def show(value):
    return json.dumps(value, ensure_ascii=False)


def merge(data):
    """Return (merged copy, list of change lines)."""
    out = copy.deepcopy(data)
    changes = []

    def put(container, key, value, label):
        if key in container:
            if container[key] != value:
                changes.append(f"~ {label}: {show(container[key])} -> {show(value)}")
                container[key] = value
        else:
            changes.append(f"+ {label}: {show(value)}")
            container[key] = value

    put(out, "model", MODEL, "model")
    ms = out.setdefault("modelSettings", {})
    if not isinstance(ms, dict):
        raise ValueError("modelSettings is not an object; fix it by hand first")
    per_model = ms.setdefault(MODEL, {})
    if not isinstance(per_model, dict):
        raise ValueError(f"modelSettings.{MODEL} is not an object; fix it by hand first")
    put(per_model, "effortLevel", "high", f"modelSettings.{MODEL}.effortLevel")
    put(out, "outputStyle", "Proactive", "outputStyle")
    put(out, "ultracode", True, "ultracode")
    return out, changes


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="print the changes, write nothing")
    ap.add_argument("--settings", default=default_path(), help="settings file (default: %(default)s)")
    args = ap.parse_args(argv)
    path = args.settings

    exists = os.path.exists(path)
    if exists:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        try:
            data = json.loads(text) if text.strip() else {}
        except json.JSONDecodeError as e:
            print(f"error: {path} is not valid JSON ({e}); nothing changed", file=sys.stderr)
            return 1
        if not isinstance(data, dict):
            print(f"error: {path} is not a JSON object; nothing changed", file=sys.stderr)
            return 1
    else:
        data = {}

    try:
        merged, changes = merge(data)
    except ValueError as e:
        print(f"error: {e}; nothing changed", file=sys.stderr)
        return 1

    print(path + ("" if exists else " (new file)"))
    if not changes:
        print("already set, nothing to change")
        return 0
    for line in changes:
        print("  " + line)
    if args.dry_run:
        print("dry run: nothing written")
        return 0

    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    mode = 0o600
    if exists:
        mode = os.stat(path).st_mode & 0o777
        backup = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(path, backup)
        print(f"backup: {backup}")

    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".settings.json.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(merged, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    print("written; start a new session (or /config) to pick it up")
    return 0


if __name__ == "__main__":
    sys.exit(main())
