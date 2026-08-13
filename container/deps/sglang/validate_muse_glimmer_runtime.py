#!/usr/bin/env python3
"""Validate the minimal Muse Glimmer SGLang delivery overlays."""

from __future__ import annotations

import importlib.metadata as metadata
import json
from pathlib import Path

import dynamo
import sglang


EXPECTED_DYNAMO = "1.4.0.dev20260810"
EXPECTED_SGLANG = "0.0.0.dev1+g7c90840ba"
EXPECTED_NIXL = "1.3.1"
MARKERS = {
    "fpm_late_resolution": ("sglang/publisher.py", "dynamo.fpm_endpoint_identity"),
    "response_format_reasoning_guard": (
        "frontend/sglang_prepost.py",
        "response_format_active = isinstance(request.get(\"response_format\"), dict)",
    ),
}


def main() -> None:
    root = Path(dynamo.__file__).resolve().parent
    missing: dict[str, str] = {}
    evidence: dict[str, str | None] = {}
    for name, (relative, marker) in MARKERS.items():
        path = root / relative
        hit = path.is_file() and marker in path.read_text(errors="ignore")
        evidence[name] = str(path) if hit else None
        if not hit:
            missing[name] = marker
    versions = {
        "ai-dynamo": metadata.version("ai-dynamo"),
        "ai-dynamo-runtime": metadata.version("ai-dynamo-runtime"),
        "nixl": metadata.version("nixl"),
        "sglang": metadata.version("sglang"),
        "sglang_module": getattr(sglang, "__version__", None),
    }
    expected = {
        "ai-dynamo": EXPECTED_DYNAMO,
        "ai-dynamo-runtime": EXPECTED_DYNAMO,
        "nixl": EXPECTED_NIXL,
    }
    for package, value in expected.items():
        if versions[package] != value:
            missing[f"{package}_version"] = str(versions[package])
    if versions["sglang"] != EXPECTED_SGLANG and versions["sglang_module"] != EXPECTED_SGLANG:
        missing["sglang_engine_version"] = str(versions)
    payload = {"versions": versions, "marker_evidence": evidence, "missing": missing}
    print(json.dumps(payload, indent=2, sort_keys=True))
    if missing:
        raise SystemExit(f"invalid Muse SGLang runtime: {missing}")


if __name__ == "__main__":
    main()
