#!/usr/bin/env python3
"""Byte-exact DS-layout Mamba conv-copy diagnostic self-test.

Run inside the patched Ultra container before server startup. The test exercises
the new worker-side strided copy kernel directly. It intentionally does not
start vLLM.
"""

from __future__ import annotations

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--num-spec-tokens", type=int, default=1)
    args = parser.parse_args()

    os.environ.setdefault("VLLM_SSM_CONV_STATE_LAYOUT", "DS")

    import torch
    from vllm.v1.worker.mamba_utils import ds_conv_tail_copy

    if not torch.cuda.is_available():
        raise SystemExit("CUDA is required for DS-copy self-test")

    device = "cuda"
    num_blocks = 4
    dim = 37
    state_len = max(4, args.num_spec_tokens + 2)
    src_block = 1
    dst_block = 2
    results = []

    for offset in range(1, args.num_spec_tokens + 1):
        state = torch.empty(
            (num_blocks, dim, state_len),
            device=device,
            dtype=torch.int32,
        )
        state.fill_(-777)
        src = (
            torch.arange(dim * state_len, device=device, dtype=torch.int32)
            .reshape(dim, state_len)
            .contiguous()
        )
        state[src_block].copy_(src)
        state[dst_block].fill_(-12345)

        ds_conv_tail_copy(state, src_block, dst_block, offset)
        torch.cuda.synchronize()

        expected = torch.full((dim, state_len), -12345, device=device, dtype=torch.int32)
        expected[:, : state_len - offset] = src[:, offset:]
        ok = torch.equal(state[dst_block], expected)
        max_diff = int((state[dst_block] - expected).abs().max().item())
        results.append(
            {
                "offset": offset,
                "ok": bool(ok),
                "max_abs_diff": max_diff,
                "shape": [num_blocks, dim, state_len],
            }
        )
        if not ok:
            break

    payload = {
        "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "status": "PASS" if all(r["ok"] for r in results) else "FAIL",
        "layout": os.environ.get("VLLM_SSM_CONV_STATE_LAYOUT"),
        "num_spec_tokens": args.num_spec_tokens,
        "results": results,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    if payload["status"] != "PASS":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
