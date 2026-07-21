#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Validate installed Nemotron Ultra vLLM runtime markers."""

from __future__ import annotations

import importlib.metadata as metadata
import json
from pathlib import Path

import vllm


MARKER_GROUPS = {
    "prB_mtp_convalign_precopy": [
        "preprocess_mamba_align_gpu",
        "run_fused_precopy",
        "precopy_src_col_buf",
        "HAS_IDX_MAPPING",
    ],
}


def find_marker(files: list[Path], root: Path, marker: str) -> str | None:
    for path in files:
        if marker in path.read_text(errors="ignore"):
            return str(path.relative_to(root))
    return None


def main() -> None:
    root = Path(vllm.__file__).resolve().parent
    files = sorted(path for path in root.rglob("*.py") if path.is_file())
    missing: dict[str, list[str]] = {}
    evidence: dict[str, dict[str, str | None]] = {}

    for group, markers in MARKER_GROUPS.items():
        group_evidence = {}
        for marker in markers:
            hit = find_marker(files, root, marker)
            group_evidence[marker] = hit
            if hit is None:
                missing.setdefault(group, []).append(marker)
        evidence[group] = group_evidence

    payload = {
        "vllm_root": str(root),
        "vllm_version": metadata.version("vllm"),
        "marker_evidence": evidence,
        "missing": missing,
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    if missing:
        raise SystemExit(f"missing Nemotron Ultra runtime markers: {missing}")


if __name__ == "__main__":
    main()
