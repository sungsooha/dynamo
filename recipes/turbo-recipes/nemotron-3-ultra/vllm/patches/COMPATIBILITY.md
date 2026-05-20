# vLLM version compatibility — what changes if you're not on v0.21.0

These patches were authored against **vLLM `v0.21.0`** (commit-pinned in
`ai-dynamo/dynamo` PR #9669 via `container/context.yaml`:
`runtime_image_tag: v0.21.0` for cuda13.0, `v0.21.0-cu129` for cuda12.9). The
text anchors in the patches match v0.21.0 source byte-for-byte. If you ship
against any other vLLM version, the unified-diff context will likely fail
and you have to re-anchor manually.

This doc walks through the version cases I expect, what fails, and what to do.

---

## Version map

| vLLM version | Patch 01 (PR 40984) | Patch 02 (Patch C v21) | Patch 03 (metadata hash block size) | Patch 04 (Mamba HMA async load) | Patch 05 (Mamba single-token row metadata) |
|---|---|---|---|---|---|
| `v0.18.x` | Doesn't apply — needs all three nim-dynamo-llm patches instead | Use nim-dynamo-llm/docker/patches/python/vllm-hma-decouple-attn-mamba-blocksize.sh (v0.18 source layout) | Re-port only after Patch 02 equivalent exists | Re-port only if scheduler has `_mamba_block_aligned_split` with external-token assert | Re-port only if `mamba_attn.py` has the same `split_decodes_and_prefills` metadata path |
| `v0.19.x` – `v0.20.x` | Doesn't apply — PR 37688 (HMA + KV events compat) not yet upstream until v0.19.2rc0; PR 40984 not until v0.21.1rc0 | Anchors will mismatch; re-port using v0.21.0 patch as reference | Re-port after Patch 02 | Re-port only if the assertion exists | Re-port from upstream PR #42430/#43186 after HMA/NIXL support is present |
| **`v0.21.0`** (this distribution's target) | **Apply as-is** | **Apply as-is** | **Apply as-is** | **Apply as-is** | **Apply as-is** |
| `v0.21.1rc0`+ | **Skip Patch 01** — PR 40984 already in source. `patch --dry-run` will say "previously applied" | Apply as-is; anchors should still match (no churn yet) | Apply as-is unless upstream reports `hash_block_size` in metadata | Apply as-is if `_mamba_block_aligned_split` still asserts external tokens | Check if PR #42430 and #43186 are already present; otherwise apply/re-anchor |
| `v0.22.x` (future) | Skip Patch 01 | Re-anchor if `_align_hybrid_block_size` or `_initialize_kv_caches` move | Re-check metadata contract | Re-check scheduler load-async flow | Re-check whether single-token Mamba prefill rows are already treated as decode rows under CUDA graphs |
| `main` (HEAD) | Skip Patch 01 (commit `bcb9c133b`); verify via `git tag --contains bcb9c133b` | Check the four anchors below; they may have moved | Re-check `get_kv_cache_group_metadata()` | Re-check `_mamba_block_aligned_split()` | Usually skip if PR #42430/#43186 are present; verify exact behavior before carrying this patch |

The decision tree:

```
$ docker run --rm <runtime_image> python -c "import vllm; print(vllm.__version__)"
v0.21.0  → apply both
v0.21.1+ → apply Patch 02 only
v0.18-v0.20 → don't use these; use nim-dynamo-llm originals
```

---

## What Patch 01 needs (PR 40984)

Patch 01 is a clean cherry-pick of upstream PR 40984. It adds:

- `vllm/v1/kv_cache_interface.py`: `KVCacheSpecKind` enum, `get_kv_cache_spec_kind()`, `get_kv_cache_spec_sliding_window()`
- `vllm/distributed/kv_events.py`: new `kv_cache_spec_kind` + `kv_cache_spec_sliding_window` fields on `BlockStored` and `BlockRemoved`
- `vllm/v1/core/kv_cache_manager.py`: `kv_cache_event_metadata` tuple in `__init__`; annotation loop in `take_kv_events()`
- `vllm/v1/core/kv_cache_coordinator.py`: small adapter so `KVCacheManager` can find the spec per group
- `vllm/v1/engine/core.py`: new `get_kv_cache_group_metadata()` utility method on `EngineCoreProc`

The patch was generated from `git format-patch -1 bcb9c133b -- vllm/` against
the local checkout of upstream vllm-project/vllm at the merge commit.

**If on `v0.21.1rc0` or later**: the patch will refuse to apply ("already applied"
or "Reversed (or previously applied) patch"). That's correct — skip it.

**If on `v0.20.x` or earlier**: Patch 01 is not enough on its own. You also need
PR 37688 (`[HMA][KVEvent] Enable GPU-side KV events for HMA`) which removes the
`v0.18`-era guard that disables HMA whenever `kv_events_config` is set. That's
already in v0.21.0; before then it requires the nim-dynamo-llm
`vllm-allow-hma-with-kv-events.sh` patch (Patch A) or its upstream equivalent.

**If on `main`**: confirm PR 40984 is in your tree with:
```
git merge-base --is-ancestor bcb9c133b HEAD && echo "have it" || echo "need it"
```
If yes, skip Patch 01.

---

## What Patch 02 needs (Patch C v21)

Patch 02 has three coordinated edits. Each has a specific text anchor that
must match the installed vllm source. The anchors are:

### Part 1 — `vllm/v1/core/single_type_kv_cache_manager.py`

**Anchor A (init field):**
```python
        self.num_cached_block: dict[str, int] = {}

        self.kv_cache_group_id = kv_cache_group_id
```

If the SingleTypeKVCacheManager `__init__` was refactored (e.g., the order
of `num_cached_block` / `kv_cache_group_id` changes), this anchor breaks.
Patch action: re-locate where `self.num_cached_block` and
`self.kv_cache_group_id` are set; inject
`self._last_emitted_hash_block: dict[str, int] = {}` adjacent.

**Anchor B (cache_blocks body):** the full v0.21.0 `cache_blocks()` body is
embedded in the patch. Any change to:
- the docstring wording
- the order of `num_cached_blocks` / `num_full_blocks` reads
- the early-return shape
- the kwargs passed to `block_pool.cache_full_blocks`

...breaks the match. Patch action: re-extract the new `cache_blocks()`,
duplicate its body, and add `self._maybe_emit_sub_block_events(request,
num_tokens)` at the end.

**Anchor C (free body):**
```python
        self.block_pool.free_blocks(ordered_blocks)
        self.num_cached_block.pop(request_id, None)
```
Add `self._last_emitted_hash_block.pop(request_id, None)` after.

**Tail append (Mamba override):** the patch appends a module-level
`MambaManager._maybe_emit_sub_block_events = _mamba_noop_emit`. If
`MambaManager` is renamed or moved to another module, find the new class
and assign the no-op there. (Alternative: drop the override entirely — PR
40984's receive-side filter in Dynamo's Rust router will drop Mamba events
anyway; this is purely a ZMQ-bandwidth optimization.)

### Part 2 — `vllm/platforms/interface.py`

**Anchor:**
```python
        if cache_config.block_size < attn_block_size:
            cache_config.block_size = attn_block_size
            logger.info(
                "Setting attention block size to %d tokens "
                "to ensure that attention page size is >= mamba page size.",
                attn_block_size,
            )
```

The hybrid-model inflation lives inside `_align_hybrid_block_size()` (called
from `update_block_size_for_backend`, called from the executor — multiproc /
uniproc / ray). The anchor matches the inflation site only.

**If `_align_hybrid_block_size` is renamed or relocated** (e.g. moved into a
new `hybrid_kv_planner` module): grep for the `"Setting attention block
size to %d tokens"` log message — wherever it lives, you want to insert the
`if cache_config.hash_block_size is None: cache_config.hash_block_size =
cache_config.block_size` two-line save just before the
`cache_config.block_size = attn_block_size` line.

**If the inflation logic itself changes** (e.g., new conditions on
`mamba_block_size`, or the inflation is gated on `mamba_cache_mode`): re-check
that your "before-inflation" save still actually fires on a hybrid model. The
log line `(hash granularity preserved at 64)` is your runtime canary.

### Part 3 — `vllm/v1/engine/core.py`

**Anchor:**
```python
        kv_cache_groups = scheduler_kv_cache_config.kv_cache_groups
        if kv_cache_groups:
            vllm_config.cache_config.block_size = min(
                g.kv_cache_spec.block_size for g in kv_cache_groups
            )
```

This lives inside `EngineCore._initialize_kv_caches`. **This anchor is the
load-bearing one** — without Part 3, `hash_block_size` is only set in worker
processes, not in EngineCore, and `resolve_kv_cache_block_sizes()` returns
`(2176, 2176)` regardless of what Part 2 set worker-side.

**If `_initialize_kv_caches` is refactored**: the contract you need to preserve
is "save `cache_config.block_size` as `cache_config.hash_block_size` *before*
the worker-reported group min overwrites it". Anywhere along that flow works.

**If vLLM changes how worker `kv_cache_specs` are propagated back** (e.g., a
new IPC contract that already keeps the user's original block_size separate):
that's a sign Part 3 may have been obviated. Verify with the
`PATCH-C-DEBUG group=5 block_size=2176 hash_block_size=64` log we added during
development — if `hash_block_size` is `64` without Part 3, you don't need it.

---

## What if you build vLLM from source instead of pulling a release wheel?

The Dynamo MR's `container/context.yaml` controls which **prebuilt
`vllm/vllm-openai:<tag>` image** is pulled in for the runtime stage. If you
override that to build vLLM from your own checkout (`pip install -e .` against
a local clone), the patches still target the same Python files in your
`site-packages/vllm/` — just point `patch -p1` at the right directory:

```bash
cd $(python -c "import vllm, os; print(os.path.dirname(vllm.__file__))")/..
patch -p1 < .../01_vllm_pr40984.patch
patch -p1 < .../02_patch_c_v21_sub_block_emit.patch
patch -p1 < .../03_vllm_metadata_hash_block_size.patch
patch -p1 < .../04_vllm_mamba_hma_async_load_align_split.patch
patch -p1 < .../05_vllm_mamba_single_token_prefill_as_decode.patch
```

If your local clone is at vLLM `main` ahead of v0.21.1, Patch 01 and Patch 05
may already be present. Patch 02/03/04 still need source inspection because
the Dynamo router block-size contract and the HMA async-load path may or may
not have been upstreamed by the target commit.

---

## How to verify after applying

1. **Patch 01 alive**: worker log no longer prints
   `AttributeError: 'EngineCoreProc' object has no attribute 'get_kv_cache_group_metadata'`,
   and the WARN line `Failed to fetch KV cache group metadata; falling back
   to vLLM cache_config.block_size` is gone.

2. **Patch 02 alive**: worker log shows
   `INFO interface.py:NNN Setting attention block size to 2176 tokens ... (hash granularity preserved at 64)`.
   Subscriber sees `block_sizes_seen` containing `64` (not only `2176`).
   `dynamo_component_kv_cache_events_applied{status="ok"}` climbs past a few
   hundred under prefix-heavy load instead of staying at ~6.

3. **Still broken**: any of the above; check that you ran `patch -p1` from
   the right directory (the parent of `vllm/`), and that idempotency-guard
   markers ("Patch-C-v21:") didn't already block a re-apply.

4. **Patch 05 alive**: marker probe finds `Patch-E-v21` in
   `vllm/v1/attention/backends/mamba_attn.py`. Under P/D with CUDA graphs,
   one-token Mamba prefill rows with prior state should be classified as decode
   rows before `split_decodes_and_prefills()`. Under eager mode, the reroute is
   skipped to avoid the Hybrid SSM NIXL accuracy regression reported in the
   upstream follow-up.

---

## Source references

- vLLM v0.21.0 tag: <https://github.com/vllm-project/vllm/releases/tag/v0.21.0>
- vLLM PR 40984: <https://github.com/vllm-project/vllm/pull/40984>
- nim-dynamo-llm Patch C original (v0.18-era):
  `nim-dynamo-llm/docker/patches/python/vllm-hma-decouple-attn-mamba-blocksize.sh`
- Root-cause doc (v0.18 baseline):
  `nim-dynamo-llm/deploy/nim-d-user-guide/KV-Aware Routing 0% Cache Hit Root Cause and Fix.md`
- Dynamo PR 9669: <https://github.com/ai-dynamo/dynamo/pull/9669>
- vLLM PR 42430: <https://github.com/vllm-project/vllm/pull/42430>
- vLLM PR 43186: <https://github.com/vllm-project/vllm/pull/43186>
