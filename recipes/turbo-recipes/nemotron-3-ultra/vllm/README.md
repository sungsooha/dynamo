<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Nemotron-3-Ultra vLLM Candidate Notes

vLLM Patch05 is the primary phase-0 Ultra candidate. It passed B200 TP4
`1P+1D` endpoint smoke, strict A7 API semantics, KV-router diagnostics,
KV-cache reuse diagnostics, A10 mini AIPerf, and filtered Mooncake A11 practice
canaries.

## Image

Build this recipe image from the Dynamo repo root:

```bash
docker build \
  -t nemotron-3-ultra-vllm-turbo:dev \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/Dockerfile \
  recipes/turbo-recipes/nemotron-3-ultra/vllm
```

The B200 run pushed the accepted Patch05 image:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-dynamo-vllm-pr9669-vllm0.21.0-kvpatch-20260520-mamba-hma-pr42430
sha256:017360cce7950f1b0ab4d8a8bd698945f0b3e88c51d1226d5940a3dcb00926a6
```

The Dockerfile applies patches `01` through `05` and verifies these markers:

```text
get_kv_cache_group_metadata
hash_block_size
kv_cache_spec_kind
_maybe_emit_sub_block_events
Patch-D-v21
Patch-E-v21
```

## Passing B200 Shape

| Field | Value |
|---|---|
| Topology | TP4 `1P+1D` |
| Prefill GPUs | `0,1,2,3` |
| Decode GPUs | `4,5,6,7` |
| Discovery | standalone etcd |
| Context length | `65536` |
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
Patch05 recipe image uses this path; if a rebuilt base moves site-packages,
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

## Internal Evidence

| Evidence | Artifact |
|---|---|
| A9 Patch05 P/D + strict A7 + KV reuse | `/home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_a9_vllm_pr42430_patch05_tp4_1p1d_strict_a7_20260520T071359Z` |
| Recipe layout reproduction | `/home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_recipe_vllm_e2e_build_launchscripts_20260520T223641Z` |
| A10 mini AIPerf | `/home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_a10_vllm_mini_aiperf_20260520T181501Z` |
| A11 filtered Mooncake chat practice | `/home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_a11_mooncake_vllm_chat_filtered_20260521T163949Z` |
| A11 filtered Mooncake SWE practice | `/home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_a11_mooncake_vllm_swe_filtered_20260521T164649Z` |

A11 practice used filtered traces only and one fresh server per workload. Both
chat and SWE had `request_errors=0` and `verified_by_metrics` cache evidence.
