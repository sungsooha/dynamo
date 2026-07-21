#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Emit only runtime package hunks from a vendored upstream vLLM patch."""

from __future__ import annotations

import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: filter_runtime_patch.py <patch>")

    patch_path = Path(sys.argv[1])
    text = patch_path.read_text()

    selected: list[str] = []
    current: list[str] = []
    include_current = False

    for line in text.splitlines(keepends=True):
        if line.startswith("diff --git "):
            if current and include_current:
                selected.extend(current)
            current = [line]
            parts = line.split()
            include_current = len(parts) >= 4 and parts[2].startswith("a/vllm/")
            continue
        if current:
            current.append(line)

    if current and include_current:
        selected.extend(current)

    if not selected:
        raise SystemExit(f"no vllm/ runtime hunks found in {patch_path}")

    sys.stdout.write("".join(selected))


if __name__ == "__main__":
    main()
