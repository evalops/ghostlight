#!/usr/bin/env python3
"""Validate post-recreation cookie and local-storage observations."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def load(path: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def main() -> int:
    if len(sys.argv) != 4:
        print(f"usage: {Path(sys.argv[0]).name} <before-log> <after-log> <marker>", file=sys.stderr)
        return 2

    before_path, after_path, marker = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    before = load(before_path)
    after = load(after_path)
    if after[: len(before)] != before:
        raise SystemExit("request log did not persist unchanged across recreation")
    restored = after[len(before) :]
    if not restored:
        raise SystemExit("no post-recreation browser requests were recorded")

    expected_cookie = f"ghostlight_acceptance={marker}"
    for tab in ("A", "B"):
        reports = [
            row
            for row in restored
            if row.get("path") == "/storage-report"
            and row.get("query", {}).get("tab") == [tab]
        ]
        if not any(expected_cookie in str(row.get("cookie", "")) for row in reports):
            raise SystemExit(f"restored cookie marker missing from tab {tab}")
        if not any(row.get("query", {}).get("value") == [marker] for row in reports):
            raise SystemExit(f"restored local-storage marker missing from tab {tab}")

    print("post-recreation cookie and local-storage markers passed for both restored tabs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
