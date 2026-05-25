#!/usr/bin/env python3
"""Apply the Ultra MTP DS-layout conv-copy diagnostic patch in-container.

This script intentionally patches the installed vLLM package in the current
container. It writes a unified diff to the requested artifact path so the
diagnostic remains reproducible without promoting the patch to a source branch.
"""

from __future__ import annotations

import argparse
import difflib
import importlib
import re
from pathlib import Path


PATCH_MARKER = "HELIX_ULTRA_MTP_DS_COPY_DIAG"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"patch anchor missing: {label}")
    return text.replace(old, new, 1)


def patch_model_mamba_utils(path: Path) -> tuple[str, str]:
    before = path.read_text()
    text = before
    if PATCH_MARKER in text:
        return before, before

    class_re = re.compile(
        r"@dataclass\nclass MambaCopySpec:\n(?P<body>.*?)\n\nMambaStateCopyFunc",
        re.DOTALL,
    )
    match = class_re.search(text)
    if not match:
        raise RuntimeError("MambaCopySpec class anchor missing")

    new_class = f'''@dataclass
class MambaCopySpec:
    """
    Data class specifying memory-copy parameters for Mamba state copies.

    {PATCH_MARKER}: DS-layout conv-state speculative copies with offset > 0
    cannot be represented as one contiguous span. For that diagnostic case,
    ``ds_conv_tail`` carries the source block and accepted-token offset; the
    worker-side copy path launches a strided copy kernel.
    """

    start_addr: int
    num_elements: int
    ds_conv_tail: bool = False
    src_block_id: int = -1
    offset: int = 0


MambaStateCopyFunc'''
    text = text[: match.start()] + new_class + text[match.end() :]

    old = '''        if offset > 0:
            # Slicing along the last dim yields a non-contiguous view
            # because features (dim) are strided by state_len.
            raise NotImplementedError(
                "DS conv state layout does not yet support speculative "
                "decoding with mamba_cache_mode='align' "
                "(num_accepted_tokens > 1)."
            )
        src_state = state[src_block_id]'''
    new = f'''        if offset > 0:
            # {PATCH_MARKER}: DS layout stores rows as (dim, state_len), so
            # the accepted-token tail is strided across rows. Return a marker
            # spec and let the worker-side copy path use a strided kernel.
            return MambaCopySpec(
                start_addr=0,
                num_elements=0,
                ds_conv_tail=True,
                src_block_id=src_block_id,
                offset=offset,
            )
        src_state = state[src_block_id]'''
    text = replace_once(text, old, new, "DS get_conv_copy_spec guard")

    path.write_text(text)
    return before, text


def patch_worker_mamba_utils(path: Path) -> tuple[str, str]:
    before = path.read_text()
    text = before
    if PATCH_MARKER in text:
        return before, before

    insert_after = '''def batch_memcpy(src_ptrs, dst_ptrs, sizes):
    batch = src_ptrs.shape[0]
    assert dst_ptrs.shape[0] == batch
    assert sizes.shape[0] == batch

    grid = (batch,)
    BLOCK_SIZE = 1024
    batch_memcpy_kernel[grid](src_ptrs, dst_ptrs, sizes, BLOCK_SIZE=BLOCK_SIZE)
'''
    kernel = f'''

# {PATCH_MARKER}: diagnostic DS-layout conv-state tail copy for MTP align mode.
@triton.jit
def ds_conv_tail_copy_kernel(
    state,
    src_block_id,
    dst_block_id,
    dim: tl.constexpr,
    state_len: tl.constexpr,
    offset,
    stride_block: tl.constexpr,
    stride_dim: tl.constexpr,
    stride_state: tl.constexpr,
    BLOCK_D: tl.constexpr,
    BLOCK_T: tl.constexpr,
):
    pid_d = tl.program_id(0)
    pid_t = tl.program_id(1)
    rows = pid_d * BLOCK_D + tl.arange(0, BLOCK_D)
    cols = pid_t * BLOCK_T + tl.arange(0, BLOCK_T)
    tail_len = state_len - offset
    mask = (rows[:, None] < dim) & (cols[None, :] < tail_len)
    src = (
        state
        + src_block_id * stride_block
        + rows[:, None] * stride_dim
        + (cols[None, :] + offset) * stride_state
    )
    dst = (
        state
        + dst_block_id * stride_block
        + rows[:, None] * stride_dim
        + cols[None, :] * stride_state
    )
    values = tl.load(src, mask=mask, other=0)
    tl.store(dst, values, mask=mask)


def ds_conv_tail_copy(state: torch.Tensor, src_block_id: int, dst_block_id: int,
                      offset: int) -> None:
    """Copy DS-layout conv tail from source block into destination prefix."""
    if offset <= 0:
        raise ValueError("ds_conv_tail_copy expects offset > 0")
    if state.dim() != 3:
        raise ValueError(f"expected 3D Mamba conv state, got {{tuple(state.shape)}}")
    _, dim, state_len = state.shape
    if offset >= state_len:
        return
    stride_block, stride_dim, stride_state = state.stride()
    block_d = 16
    block_t = 8
    grid = (triton.cdiv(dim, block_d), triton.cdiv(state_len - offset, block_t))
    ds_conv_tail_copy_kernel[grid](
        state,
        int(src_block_id),
        int(dst_block_id),
        int(dim),
        int(state_len),
        int(offset),
        int(stride_block),
        int(stride_dim),
        int(stride_state),
        BLOCK_D=block_d,
        BLOCK_T=block_t,
    )
'''
    text = replace_once(
        text,
        insert_after,
        insert_after + kernel,
        "insert ds_conv_tail_copy kernel",
    )

    old = '''                copy_spec = state_copy_func(
                    state, block_ids, src_block_idx, accept_token_bias + 1
                )

                src_ptrs_np[offset] = copy_spec.start_addr
                dst_ptrs_np[offset] = state[dest_block_id].data_ptr()
                sizes_np[offset] = copy_spec.num_elements * state.element_size()
                offset += 1'''
    new = f'''                copy_spec = state_copy_func(
                    state, block_ids, src_block_idx, accept_token_bias + 1
                )

                if getattr(copy_spec, "ds_conv_tail", False):
                    # {PATCH_MARKER}: DS conv tail is not one contiguous
                    # memcpy span. Launch a diagnostic strided copy kernel.
                    ds_conv_tail_copy(
                        state,
                        copy_spec.src_block_id,
                        dest_block_id,
                        copy_spec.offset,
                    )
                    continue

                src_ptrs_np[offset] = copy_spec.start_addr
                dst_ptrs_np[offset] = state[dest_block_id].data_ptr()
                sizes_np[offset] = copy_spec.num_elements * state.element_size()
                offset += 1'''
    text = replace_once(text, old, new, "collect_mamba_copy_meta branch")

    path.write_text(text)
    return before, text


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--diff-out", type=Path, required=True)
    args = parser.parse_args()

    vllm = importlib.import_module("vllm")
    root = Path(vllm.__file__).resolve().parent
    files = [
        root / "model_executor/layers/mamba/mamba_utils.py",
        root / "v1/worker/mamba_utils.py",
    ]

    before_after: list[tuple[Path, str, str]] = []
    before_after.append((files[0], *patch_model_mamba_utils(files[0])))
    before_after.append((files[1], *patch_worker_mamba_utils(files[1])))

    args.diff_out.parent.mkdir(parents=True, exist_ok=True)
    chunks: list[str] = []
    for path, before, after in before_after:
        chunks.extend(
            difflib.unified_diff(
                before.splitlines(keepends=True),
                after.splitlines(keepends=True),
                fromfile=f"{path}.before",
                tofile=f"{path}.after",
            )
        )
    args.diff_out.write_text("".join(chunks))
    for path, _, _ in before_after:
        print(path)


if __name__ == "__main__":
    main()
