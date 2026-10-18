#!/usr/bin/env python3
"""Check physical lines in every Git-visible Swift source file.

Without --baseline, every file must be at most 1500 lines. During migration,
--baseline permits only the recorded existing over-limit files, up to their
recorded line counts. Remove an entry as soon as its file reaches the limit.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


LIMIT = 1500


def repository_root():
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return Path(result.stdout.strip())


def swift_files(root):
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.swift"],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    paths = {os.fsdecode(path) for path in result.stdout.split(b"\0") if path}
    return sorted(path for path in paths if (root / path).is_file())


def physical_lines(path):
    content = path.read_bytes()
    return content.count(b"\n") + int(bool(content) and not content.endswith(b"\n"))


def load_baseline(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("version") != 1 or data.get("limit") != LIMIT:
        raise ValueError(f"{path}: expected baseline version 1 and limit {LIMIT}")
    entries = data.get("files")
    if not isinstance(entries, dict):
        raise ValueError(f"{path}: files must be an object")
    for name, entry in entries.items():
        if (
            not isinstance(name, str)
            or not name.endswith(".swift")
            or not isinstance(entry, dict)
            or type(entry.get("max_lines")) is not int
            or entry["max_lines"] <= LIMIT
            or not isinstance(entry.get("owner"), str)
            or not entry["owner"]
        ):
            raise ValueError(f"{path}: invalid baseline entry for {name!r}")
    return entries


def check(root, baseline):
    files = swift_files(root)
    counts = {name: physical_lines(root / name) for name in files}
    problems = []
    if baseline is None:
        problems.extend(
            f"{name}: {count} lines (limit {LIMIT})"
            for name, count in counts.items()
            if count > LIMIT
        )
    else:
        for name, count in counts.items():
            entry = baseline.get(name)
            if count > LIMIT and entry is None:
                problems.append(f"{name}: new over-limit file, {count} lines (limit {LIMIT})")
            elif entry is not None and count > entry["max_lines"]:
                problems.append(f"{name}: grew to {count} lines (baseline {entry['max_lines']})")
            elif entry is not None and count <= LIMIT:
                problems.append(f"{name}: now {count} lines; remove its resolved baseline entry")
        for name in baseline.keys() - counts.keys():
            problems.append(f"{name}: file no longer exists; remove its baseline entry")
    return files, counts, sorted(problems)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--baseline", type=Path, metavar="JSON",
        help="migration mode: allow listed files only up to their recorded line count",
    )
    args = parser.parse_args()
    try:
        root = repository_root()
        baseline = load_baseline(root / args.baseline) if args.baseline else None
        files, counts, problems = check(root, baseline)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Swift file length check: {error}", file=sys.stderr)
        return 2
    for problem in problems:
        print(problem)
    mode = "migration" if baseline is not None else "strict"
    print(f"Swift file length check ({mode}): {len(files)} files, "
          f"{sum(count > LIMIT for count in counts.values())} over {LIMIT}, "
          f"{len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
