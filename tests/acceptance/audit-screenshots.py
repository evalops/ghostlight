#!/usr/bin/env python3
"""Reject screenshot metadata and credential or address markers, including OCR text."""

from __future__ import annotations

import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
BLOCKED_CHUNKS = {b"tEXt", b"zTXt", b"iTXt", b"eXIf"}
JPEG_SIGNATURE = b"\xff\xd8"
IPV4_PATTERN = re.compile(rb"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])")
SECRET_PATTERN = re.compile(
    rb"(?:__GENERATE_AT_INSTALL__|NEKO_[A-Z0-9_]+|GHOSTLIGHT_(?:VIEWER|CONTROL|USER|ADMIN)[A-Z0-9_]*|"
    rb"(?:password|passwd|secret|api[ _-]?key|authorization))",
    re.IGNORECASE,
)


def visible_marker_failures(data: bytes, source: str = "encoded image bytes") -> list[str]:
    failures: list[str] = []
    visible_markers = b"\n".join(part for part in re.findall(rb"[ -~]{4,}", data) if part)
    if SECRET_PATTERN.search(visible_markers):
        failures.append(f"credential marker in {source}")
    for match in IPV4_PATTERN.finditer(visible_markers):
        if match.group(0) != b"127.0.0.1":
            failures.append(f"address marker {match.group(0).decode('ascii')} in {source}")
            break
    return failures


def rendered_pixel_failures(path: Path) -> list[str]:
    tesseract = shutil.which("tesseract")
    if not tesseract:
        return ["required Tesseract OCR executable is unavailable"]
    try:
        result = subprocess.run(
            [tesseract, str(path), "stdout", "--psm", "11"],
            capture_output=True,
            check=False,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        return ["Tesseract OCR timed out"]
    if result.returncode != 0:
        return [f"Tesseract OCR failed with exit code {result.returncode}"]
    return visible_marker_failures(result.stdout, "rendered pixels")


def audit_png(data: bytes) -> list[str]:
    failures: list[str] = []
    if data[:8] != PNG_SIGNATURE:
        return ["not a PNG"]

    offset = 8
    saw_iend = False
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        end = offset + 12 + length
        if end > len(data):
            failures.append("truncated chunk")
            break
        if chunk_type in BLOCKED_CHUNKS:
            failures.append(f"metadata chunk {chunk_type.decode('ascii')}")
        offset = end
        if chunk_type == b"IEND":
            saw_iend = True
            break

    if not saw_iend:
        failures.append("missing IEND chunk")
    return failures + visible_marker_failures(data)


def audit_jpeg(data: bytes) -> list[str]:
    failures: list[str] = []
    offset = 2
    while offset < len(data):
        if data[offset] != 0xFF:
            failures.append("invalid JPEG marker")
            break
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        if offset >= len(data):
            break
        marker = data[offset]
        offset += 1
        if marker in {0xD9, 0xDA}:
            break
        if marker == 0x01 or 0xD0 <= marker <= 0xD7:
            continue
        if offset + 2 > len(data):
            failures.append("truncated JPEG segment")
            break
        length = struct.unpack(">H", data[offset : offset + 2])[0]
        if length < 2 or offset + length > len(data):
            failures.append("truncated JPEG segment")
            break
        if marker == 0xFE or 0xE1 <= marker <= 0xEF:
            failures.append(f"metadata marker 0x{marker:02x}")
        offset += length
    return failures + visible_marker_failures(data)


def audit_image(path: Path) -> list[str]:
    data = path.read_bytes()
    if data.startswith(PNG_SIGNATURE):
        return audit_png(data) + rendered_pixel_failures(path)
    if data.startswith(JPEG_SIGNATURE):
        return audit_jpeg(data) + rendered_pixel_failures(path)
    return ["unsupported image format"]


def main() -> int:
    paths = [Path(value) for value in sys.argv[1:]]
    if not paths:
        print(f"usage: {Path(sys.argv[0]).name} <image> [<image> ...]", file=sys.stderr)
        return 2

    failures = 0
    for path in paths:
        if not path.is_file():
            print(f"{path}: file does not exist", file=sys.stderr)
            failures += 1
            continue
        errors = audit_image(path)
        if errors:
            print(f"{path}: {', '.join(errors)}", file=sys.stderr)
            failures += 1

    if failures:
        print(f"screenshot privacy audit failed for {failures} file(s)", file=sys.stderr)
        return 1
    print(f"screenshot privacy audit passed for {len(paths)} image file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
