#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Install and validate the DeepSeek-V4 Flash MTP vLLM runtime overlay."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.metadata as metadata
import importlib.util
import json
from pathlib import Path
import py_compile
import shutil


TARGET_RELATIVE = Path("models/deepseek_v4/nvidia/mtp.py")

REQUIRED_MARKERS = {
    "flash_shape_gate": "config.hidden_size == 4096",
    "bf16_projection_switch": "use_bf16_mtp_projection",
    "cached_bf16_weight": "_dsv4_mtp_bf16_weight",
    "checkpoint_projection_cache": "_maybe_cache_flash_mtp_projection",
    "bf16_matmul_path": "torch.matmul(x.to(torch.bfloat16), weight.t())",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--patch-source", required=True)
    parser.add_argument("--expect-vllm-git-sha", default="")
    parser.add_argument("--expect-vllm-version", default="")
    parser.add_argument("--expect-mtp-sha256", required=True)
    parser.add_argument("--require-dynamo", action="store_true")
    return parser.parse_args()


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def vllm_root() -> Path:
    spec = importlib.util.find_spec("vllm")
    if spec is None or not spec.submodule_search_locations:
        raise RuntimeError("Cannot locate installed vllm package")
    return Path(next(iter(spec.submodule_search_locations))).resolve()


def check_vllm_identity(
    vllm_version: str, expected_sha: str, expected_version: str
) -> None:
    expected_version = expected_version.strip()
    if expected_version and vllm_version == expected_version:
        return

    expected_sha = expected_sha.strip().lower()
    if not expected_sha:
        return
    candidates = {expected_sha[:n] for n in (7, 8, 9, 10, 12) if len(expected_sha) >= n}
    if expected_sha in vllm_version.lower():
        return
    if any(candidate and candidate in vllm_version.lower() for candidate in candidates):
        return
    raise RuntimeError(
        "Installed vLLM version does not match expected release version "
        "or contain expected git SHA prefix: "
        f"version={vllm_version!r}, expected_version={expected_version!r}, "
        f"expected_sha={expected_sha!r}"
    )


def main() -> None:
    args = parse_args()
    src = Path(args.patch_source)
    root = vllm_root()
    dst = root / TARGET_RELATIVE

    if not src.is_file():
        raise RuntimeError(f"Patch source does not exist: {src}")
    if not dst.parent.is_dir():
        raise RuntimeError(f"Target vLLM package path does not exist: {dst.parent}")

    src_sha = sha256(src)
    if src_sha != args.expect_mtp_sha256:
        raise RuntimeError(
            "Unexpected DSV4 Flash MTP patch SHA256: "
            f"actual={src_sha}, expected={args.expect_mtp_sha256}"
        )

    shutil.copy2(src, dst)
    py_compile.compile(str(dst), doraise=True)

    text = dst.read_text(errors="ignore")
    missing_markers = {
        name: marker for name, marker in REQUIRED_MARKERS.items() if marker not in text
    }
    if missing_markers:
        raise RuntimeError(f"Missing DSV4 Flash MTP markers: {missing_markers}")

    installed_sha = sha256(dst)
    if installed_sha != args.expect_mtp_sha256:
        raise RuntimeError(
            "Installed DSV4 Flash MTP patch SHA256 mismatch: "
            f"actual={installed_sha}, expected={args.expect_mtp_sha256}"
        )

    vllm_version = metadata.version("vllm")
    check_vllm_identity(
        vllm_version, args.expect_vllm_git_sha, args.expect_vllm_version
    )

    dynamo_origin = None
    if args.require_dynamo:
        dynamo_mod = importlib.import_module("dynamo")
        dynamo_origin = getattr(dynamo_mod, "__file__", None)

    payload = {
        "dsv4_flash_mtp_patch": "installed",
        "dynamo_origin": dynamo_origin,
        "installed_file": str(dst),
        "installed_sha256": installed_sha,
        "required_markers": REQUIRED_MARKERS,
        "vllm_root": str(root),
        "vllm_version": vllm_version,
    }
    print(json.dumps(payload, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
