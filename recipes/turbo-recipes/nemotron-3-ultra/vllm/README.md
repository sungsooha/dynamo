<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Nemotron-3-Ultra vLLM Candidate Notes

vLLM Patch06+humming is the current phase-0 v2 Ultra candidate. It passed B200
TP4 `1P+1D` endpoint smoke, strict A7 API semantics, KV-router diagnostics,
KV-cache reuse diagnostics, full filtered Mooncake replay, and 128K/256K
context admission in direct Docker.

## Image

Build this recipe image from the Dynamo repo root:

```bash
docker build \
  -t nemotron-3-ultra-vllm-turbo:dev \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/Dockerfile \
  recipes/turbo-recipes/nemotron-3-ultra/vllm
```

The B200 run pushed the accepted Patch06+humming image:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521
sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337
```

Patch06+humming provenance:

```text
vLLM main: 1c78f76c29a642379ad0ec953a77af9bc44376b6
PR #42554: 68dc38bcbac5004090939bbeb6bdcb9574379bb0
PR #42547: 477556a47a77b85ad1797419c1fa370c0fae83a1
Patch06: patches/06_vllm_patch02_hash_block_event_port_after_pr42547.patch
Patch06 sha256: 9ffec3b72951a305f23d943ea5a1eb5faff5077e665b58200247fef6d00dbd30
dependency: humming-kernels[cu13]==0.1.0
```

Important: historical patch files are intentionally not carried in this recipe;
use git history if they are needed. The current Patch06 source patch is checked
into `patches/` for audit and future source rebuild work. The Dockerfile still
wraps the accepted pushed Patch06+humming image because that is the validated
runtime reproduction path for this checkpoint.

## Passing B200 Shape

| Field | Value |
|---|---|
| Topology | TP4 `1P+1D` |
| Prefill GPUs | `0,1,2,3` |
| Decode GPUs | `4,5,6,7` |
| Discovery | standalone etcd |
| Context length | `262144` default; validated at `65536`, `131072`, and `262144` |
| Max sequences | `16` |
| Max batched tokens | `32768` |
| Block size | `64` |
| Transfer | NIXL/HMA |
| Router | Dynamo KV router with KV events |

Required vLLM/HMA environment:

```text
VLLM_SSM_CONV_STATE_LAYOUT=DS
VLLM_ALLOW_CHUNKED_LOCAL_ATTN_WITH_HYBRID_KV_CACHE=1
DYN_VLLM_APPEND_PREFILL_OUTPUT_TOKENS=0
VLLM_WORKER_MULTIPROC_METHOD=spawn
VLLM_ALLREDUCE_USE_SYMM_MEM=0
```

Required parser contract:

```text
--dyn-tool-call-parser qwen3_coder
--dyn-reasoning-parser nemotron3
--reasoning-parser-plugin ${MODEL_PATH}/ultra_v3_reasoning_parser.py
--reasoning-parser nemotron_v3
```

Required vLLM flags include:

```text
--no-disable-hybrid-kv-cache-manager
--enable-prefix-caching
--mamba-cache-mode align
--kv-transfer-config {"kv_connector":"NixlConnector","kv_role":"kv_both"}
```

Prefill publishes KV events:

```text
--kv-events-config {"publisher":"zmq","topic":"kv-events","endpoint":"tcp://*:5571","enable_kv_cache_events":true}
```

Keep the FlashInfer cubin path writable if running with a non-root user. The
Patch06 recipe image uses this path; if a rebuilt base moves site-packages,
override the validation helper with `VLLM_FLASHINFER_TMPFS` and mount that
detected path instead:

```text
/usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer
```

## Readiness And Validation

Do not send chat, A7, AIPerf, or Mooncake traffic after `/v1/models` alone.
Require the frontend to add a non-prefill `dynamo` worker set, then run the
exact-content short chat:

```text
disagg smoke ok
```

Strict A7 must preserve raw requests, raw responses, and usage. KV reuse must
be proved by runtime metrics or request-time logs, not startup-only logs.

## Standalone Validation Summary

These are the public, reproducible acceptance facts for the current vLLM
candidate. The original reserved-node artifact directories are internal and are
not needed to replay the recipe.

| Gate | Standalone result |
|---|---|
| Image identity | `nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521@sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337` |
| Primary functional target | 256K context admission PASS on TP4 `1P+1D`: `/health` PASS, `/v1/models` exposed `context_window=262144`, exact short chat PASS, strict A7 5/5 PASS, long-context probe used `191986` prompt tokens and returned usage `191986/4/191990` |
| 128K control | PASS with `context_window=131072`; long-context probe used `95986` prompt tokens and returned usage `95986/4/95990` |
| KV reuse control | PASS by metrics at the 65K smoke shape: `dynamo_frontend_cached_tokens_sum +66560`, `dynamo_component_router_kv_hit_rate_sum +3.3226837060702876`; warmup `3.640718s`, repeat `0.634655s`, shared-prefix extension `0.607402s` |

## Functional API Smoke

Strict A7 API smoke passed 5/5 on the current Patch06+humming P/D image. The
table below captures the request/response contract without private artifact
paths.

| Check | Input contract | Required output |
|---|---|---|
| Basic chat | Ask for exact string `feature smoke ok` | Content exactly `feature smoke ok`; usage present |
| Tool call | Weather tool request with `get_current_weather` available | `finish_reason=tool_calls`; parsed tool call `get_current_weather({"location":"Santa Clara, CA"})`; usage present |
| Reasoning enabled | Arithmetic prompt: `If x=7 and y=5, what is 3*x + 2*y?` with thinking enabled | HTTP 200, JSON parse OK, usage present, response contains `31` |
| Reasoning disabled | Same arithmetic prompt with thinking disabled | Content exactly `31`; usage present |
| Low-effort budget | Same arithmetic prompt with low reasoning budget | Final answer contains `31`; completion tokens stayed below the full reasoning row |

## Mooncake Trace Benchmark Note

The filtered Mooncake benchmark numbers below are **not** the 256K admission
run. They were collected at the 65K serving shape:

```text
server_shape_id: vllm_upstream_patch06_humming_recipe_tp4_1p1d_65k
max_model_len: 65536
max_num_seqs: 16
max_batched_tokens: 32768
concurrency: 8
fresh_server_per_workload: true
trace_mode: mooncake-trace-filtered-slices
```

`router hit avg` means
`delta(dynamo_component_router_kv_hit_rate_sum) /
delta(dynamo_component_router_kv_hit_rate_count)` over the measured tail
interval. It is Dynamo router KV-hit evidence, not the raw trace target by
itself.

| Benchmark type | Workload type | Requests | Errors | p50 ISL | p50 OSL | p50 TTFT ms | p50 ITL ms | p50 latency ms | p50 TPS/user | Aggregate output TPS | Aggregate TPS/GPU | Router hit avg |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Mooncake trace, filtered | Chat | 1817 | 0 | 5810 | 995 | 491.5 | 9.48 | 9828.0 | 105.44 | 759.40 | 94.92 | 56.6% |
| Mooncake trace, filtered | SWE | 1973 | 0 | 18316 | 400 | 581.6 | 9.43 | 4141.4 | 106.08 | 665.07 | 83.13 | 81.3% |

Replay should create a fresh artifact root on the target system and preserve
`run_status.json`, `run_config.json`, `metrics.jsonl`, raw endpoint I/O, A7 raw
requests/responses, KV metrics snapshots, and cleanup evidence.
