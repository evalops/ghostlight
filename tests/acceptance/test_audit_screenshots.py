#!/usr/bin/env python3
"""Regression tests for screenshot privacy auditing."""

from __future__ import annotations

import base64
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

AUDIT_SCRIPT = Path(__file__).with_name("audit-screenshots.py")
AUDIT_SPEC = importlib.util.spec_from_file_location("audit_screenshots", AUDIT_SCRIPT)
assert AUDIT_SPEC and AUDIT_SPEC.loader
AUDIT_MODULE = importlib.util.module_from_spec(AUDIT_SPEC)
AUDIT_SPEC.loader.exec_module(AUDIT_MODULE)
RENDERED_SECRET_PNG = base64.b64decode(
    "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"
)


class ScreenshotPrivacyAuditTests(unittest.TestCase):
    def test_rejects_chromium_extension_error_rendered_in_pixels(self) -> None:
        ocr_result = subprocess.CompletedProcess(
            args=["tesseract"],
            returncode=0,
            stdout=(
                b"Error Loading Extension\n"
                b"Failed to load extension from: /usr/share/chromium/extensions/agent.json\n"
                b"Loading of unpacked extensions is disabled by the administrator.\n"
            ),
            stderr=b"",
        )
        with mock.patch.object(AUDIT_MODULE.subprocess, "run", return_value=ocr_result):
            failures = AUDIT_MODULE.rendered_pixel_failures(Path("unused.jpg"))

        self.assertIn("browser startup error in rendered pixels", failures)

    def test_rejects_secret_rendered_only_in_pixels(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            screenshot = Path(temporary_directory) / "rendered-secret.png"
            screenshot.write_bytes(RENDERED_SECRET_PNG)

            result = subprocess.run(
                [sys.executable, str(AUDIT_SCRIPT), str(screenshot)],
                capture_output=True,
                check=False,
                text=True,
            )

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("credential marker in rendered pixels", result.stderr)


if __name__ == "__main__":
    unittest.main()
