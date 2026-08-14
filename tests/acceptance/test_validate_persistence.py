#!/usr/bin/env python3
"""Regression tests for restored browser-state validation."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
VALIDATOR = ROOT / "validate-persistence.py"
MARKER = "synthetic-marker"


class ValidatePersistenceTests(unittest.TestCase):
    def test_restored_tab_reports_prove_cookie_without_full_navigation(self) -> None:
        before = [{"path": "/state-a", "cookie": ""}]
        after = before + [
            {
                "path": "/storage-report",
                "cookie": f"ghostlight_acceptance={MARKER}",
                "query": {"tab": [tab], "value": [MARKER]},
            }
            for tab in ("A", "B")
        ]
        with tempfile.TemporaryDirectory() as directory:
            before_path = Path(directory) / "before.jsonl"
            after_path = Path(directory) / "after.jsonl"
            before_path.write_text("".join(f"{json.dumps(row)}\n" for row in before), encoding="utf-8")
            after_path.write_text("".join(f"{json.dumps(row)}\n" for row in after), encoding="utf-8")
            result = subprocess.run(
                ["python3", str(VALIDATOR), str(before_path), str(after_path), MARKER],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
