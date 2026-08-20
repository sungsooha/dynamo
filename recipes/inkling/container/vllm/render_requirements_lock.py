#!/usr/bin/env python3
"""Turn pip's resolver report into the hash-locked Mode-2 install closure."""

import json
import os
import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit("usage: render_requirements_lock.py REPORT_JSON OUT_REQUIREMENTS")

report = json.loads(Path(sys.argv[1]).read_text())
excluded = {
    name.strip().lower().replace("_", "-")
    for name in os.environ.get("MODE2_EXCLUDE_PACKAGES", "").split(",")
    if name.strip()
}
rows = []
for entry in report.get("install", []):
    metadata = entry.get("metadata", {})
    name = metadata.get("name")
    version = metadata.get("version")
    hashes = entry.get("download_info", {}).get("archive_info", {}).get("hashes", {})
    digest = hashes.get("sha256")
    if not (name and version and digest):
        raise SystemExit(f"resolver report lacks a sha256-pinned artifact: {name!r} {version!r}")
    normalized = name.lower().replace("_", "-")
    if normalized in excluded:
        continue
    rows.append((normalized, f"{name}=={version} --hash=sha256:{digest}"))

if not rows:
    raise SystemExit("resolver report contains no install closure")

Path(sys.argv[2]).write_text("\n".join(value for _, value in sorted(set(rows))) + "\n")
