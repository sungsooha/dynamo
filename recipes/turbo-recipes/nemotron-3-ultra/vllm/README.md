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
| A9 P/D smoke | TP4 `1P+1D`, `/health` PASS, `/v1/models` exposed `nemotron-ultra-ea`, exact short chat PASS |
| Strict A7 | 5/5 PASS, all HTTP 2xx, JSON parse OK, usage present, tool call parsed `Santa Clara, CA`, low-effort reasoning produced final answer |
| KV reuse | PASS by metrics: `dynamo_frontend_cached_tokens_sum +66560`, `dynamo_component_router_kv_hit_rate_sum +3.3226837060702876`; warmup `3.640718s`, repeat `0.634655s`, shared-prefix extension `0.607402s` |
| Full filtered Mooncake chat | `1817` measured requests, `0` errors, `req/s 1.0294`, `avg ISL 14627.9`, `avg OSL 737.7`, `output TPS 759.40`, `TPS/GPU 94.92`, router hit avg `56.6%` |
| Full filtered Mooncake SWE | `1973` measured requests, `0` errors, `req/s 1.9094`, `avg ISL 20476.1`, `avg OSL 348.3`, `output TPS 665.07`, `TPS/GPU 83.13`, router hit avg `81.3%` |
| Context ladder | 128K PASS with `95986` prompt tokens, 256K PASS with `191986` prompt tokens |

Replay should create a fresh artifact root on the target system and preserve
`run_status.json`, `run_config.json`, `metrics.jsonl`, raw endpoint I/O, A7 raw
requests/responses, KV metrics snapshots, and cleanup evidence.
