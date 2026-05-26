#!/usr/bin/env python3
"""Apply the Ultra SSM/NIXL prefix-cache tailfix in-container.

This patches the installed vLLM package in the current container. The patch is
kept separate from the DS-copy patch because it affects only the P/D NIXL
transfer path; aggregate-only AGG1/AGG2 runs do not exercise this branch.
"""

from __future__ import annotations

import argparse
import difflib
import importlib
from pathlib import Path


PATCH_MARKER = "NEMOTRON_ULTRA_SSM_NIXL_TAILFIX"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"tailfix patch anchor missing: {label}")
    return text.replace(old, new, 1)


def patch_worker(path: Path) -> tuple[str, str]:
    before = path.read_text()
    if PATCH_MARKER in before:
        return before, before

    old_installed = '''                if _is_ssm_spec(self._group_spec_types[i]):
                    assert num_local_blocks == 1, "SSM can only have one local block"
                    remote_block_ids[i] = remote_group[-num_local_blocks:]
                else:'''
    new = f'''                if _is_ssm_spec(self._group_spec_types[i]):
                    # {PATCH_MARKER}: SSM state groups may allocate multiple
                    # local blocks after long-context prefix-cache transfer.
                    # Tail-align remote SSM blocks to the local suffix instead
                    # of asserting a single local block.
                    assert num_local_blocks > 0, (
                        "SSM group has no local blocks to receive"
                    )
                    assert num_local_blocks <= num_remote_blocks, (
                        f"SSM group {{i}}: local blocks {{num_local_blocks}} "
                        f"> remote blocks {{num_remote_blocks}}"
                    )
                    remote_block_ids[i] = remote_group[-num_local_blocks:]
                else:'''

    if old_installed in before:
        after = replace_once(before, old_installed, new, "installed SSM local-block assert")
    else:
        old_source = '''                if _is_ssm_spec(self._group_spec_types[i]):
                    assert num_local_blocks == num_remote_blocks
                else:'''
        after = replace_once(before, old_source, new, "source SSM equal-block assert")

    path.write_text(after)
    return before, after


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--diff-out", type=Path, required=True)
    args = parser.parse_args()

    vllm = importlib.import_module("vllm")
    worker = (
        Path(vllm.__file__).resolve().parent
        / "distributed/kv_transfer/kv_connector/v1/nixl/worker.py"
    )
    before, after = patch_worker(worker)

    args.diff_out.parent.mkdir(parents=True, exist_ok=True)
    args.diff_out.write_text(
        "".join(
            difflib.unified_diff(
                before.splitlines(keepends=True),
                after.splitlines(keepends=True),
                fromfile=f"{worker}.before",
                tofile=f"{worker}.after",
            )
        )
    )
    print(worker)


if __name__ == "__main__":
    main()
