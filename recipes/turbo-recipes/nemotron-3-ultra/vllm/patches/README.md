# Patches for Dynamo KV-aware Routing on Nemotron-3-Super (hybrid Mamba+Attention)

These patches make Dynamo's KV-aware router actually receive useful
prefix signal from vLLM when serving NVIDIA Nemotron-3-Super-120B-A12B-FP8 (or
any hybrid Mamba/Attention model) under
[ai-dynamo/dynamo PR #9669](https://github.com/ai-dynamo/dynamo/pull/9669).

Without them, the router silently falls back to non-KV-aware routing —
`host_pinned blocks: 0, disk blocks: 0, effective cached blocks: 0.00` for every
request, even with `--router-mode kv` enabled.

## Files

| # | Patch | Source | Targets |
|---|---|---|---|
| 01 | `01_vllm_pr40984.patch` | vllm-project/vllm [PR #40984](https://github.com/vllm-project/vllm/pull/40984) `feat(kv-events): emit KV cache metadata` (commit `bcb9c133b`) | `vllm/distributed/kv_events.py`, `vllm/v1/core/{kv_cache_coordinator,kv_cache_manager}.py`, `vllm/v1/engine/core.py`, `vllm/v1/kv_cache_interface.py` |
| 02 | `02_patch_c_v21_sub_block_emit.patch` | v0.21-targeted port of nim-dynamo-llm `vllm-hma-decouple-attn-mamba-blocksize.sh` (Patch C) | `vllm/v1/core/single_type_kv_cache_manager.py`, `vllm/platforms/interface.py`, `vllm/v1/engine/core.py` |
| 03 | `03_vllm_metadata_hash_block_size.patch` | New (vLLM-only): expose `hash_block_size` through `get_kv_cache_group_metadata` so Dynamo router uses the correct request-hashing granularity. | `vllm/v1/engine/core.py` (depends on 01 + 02) |
| 04 | `04_vllm_mamba_hma_async_load_align_split.patch` | New (vLLM-only): allow HMA/NIXL async external-KV load to bypass the Mamba block-aligned splitter while `num_new_tokens=0`. | `vllm/v1/core/sched/scheduler.py` |
| 05 | `05_vllm_mamba_single_token_prefill_as_decode.patch` | v0.21-targeted runtime port of vLLM PR #42430 plus the #43186 CUDA-graph-mode gate: treat one-token Mamba prefills with prior state as decode/update rows only when CUDA graphs are active. | `vllm/v1/attention/backends/mamba_attn.py` |

## What each patch does

### Patch 01 — vLLM PR 40984

- Adds `EngineCoreProc.get_kv_cache_group_metadata()` so Dynamo's
  `dynamo.vllm.cache_info.configure_kv_event_block_size` can fetch per-group
  `{kind, block_size, sliding_window, ...}` instead of falling back to
  `cache_config.block_size`.
- Adds `kv_cache_spec_kind` + `kv_cache_spec_sliding_window` fields on every
  `BlockStored` / `BlockRemoved` event. Dynamo's Rust router uses these in
  `lib/kv-router/src/zmq_wire/filter.rs::is_main_attention()` to drop
  non-FullAttention groups at receive time. This replaces nim-dynamo-llm's
  `vllm-hma-skip-non-attn-kv-events.sh` (Patch B), which did the same job by
  filtering at *emit* time — Patch B is no longer needed with PR 40984 applied.
- Adds the `KVCacheSpecKind` enum + `get_kv_cache_spec_kind()` helper in
  `kv_cache_interface.py`.

After applying, the router can correctly distinguish Mamba SSM-state events
from attention KV events and only ingest the latter into its prefix tree.

### Patch 02 — Patch C v21 (sub-block emission)

Hybrid models inflate `cache_config.block_size` from the user's
`--block-size 64` to e.g. `2176` (to satisfy `attention_page_size >=
mamba_page_size`). vLLM's `BlockPool.cache_full_blocks()` only fires
`BlockStored` when a full *physical* block is captured — so for any prompt
< 2176 tokens, zero events ever flow.

vLLM v0.21.0 ships the `hash_block_size` plumbing
(`resolve_kv_cache_block_sizes`, `BlockPool.hash_block_size`) needed to
compute block hashes at a finer granularity than the physical block size,
but it does **not** wire up sub-block event emission. This patch closes
that gap in three coordinated edits:

| Part | File | Edit |
|---|---|---|
| 1 | `vllm/v1/core/single_type_kv_cache_manager.py` | Add `_maybe_emit_sub_block_events()` on the base class; call it from `cache_blocks()` after the upstream full-block path; clear cursor on `free()`; append `MambaManager._maybe_emit_sub_block_events = _mamba_noop_emit` to suppress Mamba state event flooding |
| 2 | `vllm/platforms/interface.py` | Before the `attn_block_size` inflation, save `cache_config.hash_block_size = cache_config.block_size`. Worker-side. |
| 3 | `vllm/v1/engine/core.py` | Mirror the save in EngineCore's `_initialize_kv_caches`, right before the worker-reported `min(group.block_size)` overwrites `cache_config.block_size`. Without this part, only worker-side cache_config has `hash_block_size` set; EngineCore (where the scheduler/BlockPool actually live) does not, and `resolve_kv_cache_block_sizes` returns `(2176, 2176)` instead of `(2176, 64)`. |

After applying, `block_pool.hash_block_size = 64` and
`SingleTypeKVCacheManager.cache_blocks()` emits a `BlockStored` event for
every newly-completed 64-token chunk, with `group_idx` set so PR 40984's
metadata annotation tags the event as `full_attention`.

## How to apply

Inside the running container (or in a Dockerfile build stage), against
`/usr/local/lib/python3.12/dist-packages` (or wherever your vllm install lives):

```bash
cd /usr/local/lib/python3.12/dist-packages
patch -p1 < /path/to/01_vllm_pr40984.patch
patch -p1 < /path/to/02_patch_c_v21_sub_block_emit.patch
patch -p1 < /path/to/03_vllm_metadata_hash_block_size.patch
patch -p1 < /path/to/04_vllm_mamba_hma_async_load_align_split.patch
patch -p1 < /path/to/05_vllm_mamba_single_token_prefill_as_decode.patch
```

(`patch -p1` strips one leading directory; the patches use `a/vllm/...` and
`b/vllm/...` prefixes, so applying from the dist-packages root puts each
edit in `dist-packages/vllm/...`.)

Both patches are idempotent on the v0.21.0 release tag — re-running them
fails noisily rather than corrupting the source.

## Verification

After restart, you should see (worker startup):

```
INFO interface.py:650 Setting attention block size to 2176 tokens to ensure
that attention page size is >= mamba page size (hash granularity preserved at 64).
```

Subscribe to the ZMQ KV-events publisher (`tcp://localhost:20080`, topic
`kv-events`) and send a prefix-heavy traffic pattern (>500 tokens). You
should see events at `block_size=64` from the full_attention group:

```
batches=39 stored_by_group={5: 446, 0:1, 1:1, 2:1, 3:1, 4:1}
block_sizes_seen={64: 39, 2176: 6}
kinds={5:'full_attention', 0:'mamba', 1:'mamba', 2:'mamba', 3:'mamba', 4:'mamba'}
```

Frontend `/metrics`:

```
dynamo_component_kv_cache_events_applied{event_type="stored", status="ok"}  > 0
dynamo_component_kv_cache_event_warnings{warning_kind="duplicate_store"}     0
dynamo_router_overhead_indexer_find_matches_ms_count                          > 0
```

### Patch 03 — vLLM-only fix for router read-side granularity

After Patches 01 + 02, vLLM writes events at `hash_block_size=64` but
Dynamo's router reads incoming-request keys at `block_size=2176`. DEBUG logs
show `[ROUTING_INPUT] isl_tokens=1227 block_size=2176 num_blocks=0
local_hashes=[]` — short prompts produce zero query blocks and never match
the index. `effective cached blocks` stays at `0.00`.

Patch 03 fixes this **without changing Dynamo**: in
`EngineCoreProc.get_kv_cache_group_metadata()`, report `cache_config.hash_block_size`
as the `block_size` field (instead of `spec.block_size`) whenever sub-block
emission is active. Dynamo's `select_main_attention_block_size` reads this
verbatim and plumbs the value through:

```
get_kv_cache_group_metadata → DYNAMO_KV_EVENT_BLOCK_SIZE_KEY (64)
  → KvEventPublisher.kv_block_size
  → ModelDeploymentCard.kv_cache_block_size
  → KvRouter.block_size
  → compute_block_hash_for_seq (request-side hashing at 64)
  → log_routing_input_hashes (`[ROUTING_INPUT] block_size=64 num_blocks=31`)
```

Verified empirically: 20-request prefix-shared burst on a single TP=8 worker:

| Metric | After Patches 01+02 | + Patch 03 |
|---|---|---|
| `dynamo_frontend_model_kv_cache_block_size` | 2176 | **64** |
| Router formula `effective cached blocks` per request | `0.00` | **`31.00`** |
| Router formula `raw_prefill_blocks` per request | `0.932` (=2026/2176) | **`31.688`** (=2026/64) |
| `router_kv_hit_rate_sum` over 20 requests | `0.0` | **`18.4`** |
| → avg hit rate | 0% | **~92%** |
| `event_warnings{duplicate_store}` | 0 | 38 (benign — re-emit of same hashes by requests 2-20) |

With Patch 03 in place, single-worker routing still doesn't reduce per-request
TTFT (vLLM's local APC operates at physical block size and benefit shows up at
the next full 2176-token boundary), but **multi-worker setups now have real
per-prefix worker affinity** for prompts of any length ≥ `hash_block_size` —
the router's selector formula picks the worker holding the cached prefix
because `overlap_credit_blocks` reflects real shared blocks.

### Patch 04 — Mamba-align scheduler fix for external KV load

In vLLM `0.21.0`, the scheduler's Mamba block-aligned splitter asserts that
`num_external_computed_tokens == 0`. HMA/NIXL remote prefill for hybrid Mamba
models intentionally violates that during the async external-KV load step: the
connector returns external prompt tokens and asks the scheduler to allocate
slots with `num_new_tokens=0`.

`KVCacheManager.allocate_slots()` already supports that path when external
tokens are present. Patch 04 therefore skips `_mamba_block_aligned_split()` only
for the async load step. The normal Mamba-align split still runs on the next
scheduler step, after the external KV load completes, when the decoder computes
the remaining local token(s).

### Patch 05 — D-side one-token Mamba recompute metadata

vLLM's NIXL/HMA P/D path for Mamba-style models prefills `0..N-1` on the
prefill side and recomputes token `N` on the decode side from prior state
`h(N-1)`. In vLLM `0.21.0`, that decode-side one-token row can still be marked
as prefill by metadata because `num_computed_tokens < num_prompt_tokens`.
When CUDA graph dispatch chooses a decode graph for a uniform one-token batch,
Mamba metadata can then disagree with the graph path.

Patch 05 applies the runtime part of upstream vLLM PR #42430: one-token Mamba
prefills that already have prior state are reclassified as decode/update rows.
It also folds in the follow-up PR #43186 gate so this reroute runs only when
CUDA graphs are active; eager mode keeps the original prefill path to avoid the
known Hybrid SSM NIXL accuracy regression from changing the SSM reduce order.

This patch is a candidate fix for the Nemotron Ultra A9 vLLM P/D semantic gap
where the D side emitted immediate `<|im_end|>` after external-KV handoff for
unguided reasoning rows, while the same image passed TP8 single-worker A7.
