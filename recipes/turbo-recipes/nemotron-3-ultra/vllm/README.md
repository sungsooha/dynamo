<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Nemotron-3-Ultra vLLM Candidate Notes

vLLM Patch06+humming plus the Ultra MTP DS-copy patch is the current phase-0
v2 Ultra candidate. Patch06+humming passed B200 TP4 `1P+1D` endpoint smoke,
strict A7 API semantics, KV-router diagnostics, KV-cache reuse diagnostics,
65K-filtered direct-Docker Mooncake replay, and 128K/256K context admission in
direct Docker. The MTP patch adds the missing DS-layout conv-tail copy path
needed for `VLLM_SSM_CONV_STATE_LAYOUT=DS`, `mamba_cache_mode=align`, prefix
caching, and `nemotron_h_mtp` speculative decoding.

## Image

Build this recipe image from the Dynamo repo root:

```bash
docker build \
  -t nemotron-3-ultra-vllm-turbo:dev \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/Dockerfile \
  recipes/turbo-recipes/nemotron-3-ultra/vllm
```

The B200 run pushed the accepted Patch06+humming base image:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521
sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337
```

The expedited MTP DS-copy diagnostic image is:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-patch06-humming-mtp-ds-copy-diag-20260523T164824Z
sha256:4c2e66ddd2610b9fbd84caffb0ae5663264322cfc29b9f22cf8be141f88d7cca
```

The Dockerfile builds the reproducible recipe image by starting from the
Patch06+humming base and applying `patches/ds_copy_diag_installed_vllm.patch`.
For debugging only, it can wrap the already-pushed diagnostic image by passing
`--build-arg BASE_IMAGE=<diagnostic-image>@sha256:4c2e... --build-arg
APPLY_MTP_DS_COPY_PATCH=0`.

Patch06+humming provenance:

```text
vLLM main: 1c78f76c29a642379ad0ec953a77af9bc44376b6
PR #42554: 68dc38bcbac5004090939bbeb6bdcb9574379bb0
PR #42547: 477556a47a77b85ad1797419c1fa370c0fae83a1
Patch06: patches/06_vllm_patch02_hash_block_event_port_after_pr42547.patch
Patch06 sha256: 9ffec3b72951a305f23d943ea5a1eb5faff5077e665b58200247fef6d00dbd30
dependency: humming-kernels[cu13]==0.1.0
MTP DS-copy patch: patches/ds_copy_diag_installed_vllm.patch
MTP quality gate: full GSM8K MTP EM 0.884003 vs non-MTP 0.881729 on 1319 samples
```

Important: historical patch files are intentionally not carried in this recipe;
use git history if they are needed. The current Patch06 source patch is checked
into `patches/` for audit and future source rebuild work. The Dockerfile still
wraps the accepted pushed Patch06+humming image because that is the validated
runtime reproduction path for this checkpoint.

Recipe handoff provenance:

```text
MTP image build evidence:
  /tmp/nemotron-ultra/artifacts/helix_ultra_mtp_ds_copy_image_build_20260523T164824Z
GSM8K quality evidence:
  /tmp/nemotron-ultra/artifacts/helix_ultra_mtp_ds_copy_full_gsm8k_compare_real_20260523T161619Z
MTP apply helper sha256:
  7f7acdc2ff05287e129cd608972b60899e70e1c30199aea8eccfc2ca1fadd309
MTP self-test sha256:
  83e724f61d47033c626cd2a0a74bb8c31a42bad7a12309f0b70abb826f49686e
Installed-package MTP patch sha256:
  794e04517df6276a4568c6b97883fc57e87d6615ccf6a25728cdec458c7ff9a3
```

## Local Image Smoke

Use `benchmark.sh` for a bounded image-build-to-server check on one B200 host.
It emits `run_config.json`, `status.jsonl`, `run_status.json`,
`generated_commands.json/jsonl`, command scripts under `commands/`,
`failures.jsonl`, empty `metrics.jsonl`, `quality_not_requested.json`, smoke
evidence, logs, cleanup evidence, and `manifest.tsv`. It does not produce a
throughput row; use tracked AIPerf contracts for measured data.

Example AGG1 MTP smoke on 4 GPUs:

```bash
cd /path/to/dynamo
HOST_MODEL_PATH=/path/to/nemotron-ultra-ea-model-view \
BUILD_IMAGE=1 \
IMAGE=nemotron-3-ultra-vllm-turbo:dev \
GPU_SET=0,1,2,3 \
AGG_WORKERS=1 \
MAX_NUM_SEQS=32 \
MAX_BATCHED_TOKENS=32768 \
BLOCK_SIZE=64 \
SPEC_METHOD=nemotron_h_mtp \
SPEC_TOKENS=1 \
ARTIFACT_ROOT=/tmp/nemotron-ultra/recipe-smoke-agg1-mtp \
recipes/turbo-recipes/nemotron-3-ultra/vllm/benchmark.sh
```

Example AGG2 MTP smoke on 8 GPUs:

```bash
HOST_MODEL_PATH=/path/to/nemotron-ultra-ea-model-view \
IMAGE=nemotron-3-ultra-vllm-turbo:dev \
GPU_SET=0,1,2,3,4,5,6,7 \
AGG_WORKERS=2 \
MAX_NUM_SEQS=32 \
MAX_BATCHED_TOKENS=32768 \
BLOCK_SIZE=64 \
SPEC_METHOD=nemotron_h_mtp \
SPEC_TOKENS=1 \
ARTIFACT_ROOT=/tmp/nemotron-ultra/recipe-smoke-agg2-mtp \
recipes/turbo-recipes/nemotron-3-ultra/vllm/benchmark.sh
```

The smoke script runs the DS-copy self-test before server startup when
`SPEC_TOKENS != 0`, then requires `/health`, `/v1/models`, and exact short chat
`recipe smoke ok`.

## 30% Moontrace Tuning Results

The current tuning objective is to maximize `TPS/GPU` while keeping
`Gen TPS/user avg >= 50`, with stable server health, cache/routing evidence,
mostly complete profile export, and cleanup.

### Chat

| Workload | Topology | Image | Shape | 30% Moontrace result | Status |
|---|---|---|---|---|---|
| Chat | AGG1 MTP1 | MTP DS-copy | `mns64`, `mbt32768`, `block64`, `c64` | `198.736 TPS/GPU`, `71.488 TPS/user`, fail0 | robust candidate |
| Chat | AGG1 MTP1 | MTP DS-copy | `mns72`, `mbt32768`, `block64`, `c68` | `202.097 TPS/GPU`, `64.263 TPS/user`, 11 warnings / 3546 | frontier candidate |
| Chat | AGG1 MTP1 | MTP DS-copy | `mns72`, `mbt32768`, `block32`, `c68` | `201.458 TPS/GPU`, `105.699 TPS/user`, 4 warnings / 3546 | warning-reduction variant |
| Chat | AGG1 MTP1 | MTP DS-copy | `mns80`, `mbt32768`, `block64`, `c72` | `205.351 TPS/GPU`, `39.810 TPS/user`, 4 warnings / 3546 | below-floor knee |
| Chat | AGG1 non-MTP | Patch06+humming | `mns40`, `mbt32768`, `block32`, `c40` | `184.512 TPS/GPU`, `21.822 TPS/user`, fail0 | negative control |

Recommended chat recipe for next validation is AGG1 MTP1 `c68` if small
AIPerf/client invalid warnings are acceptable, or AGG1 MTP1 `c64` when a
zero-warning row is required.

### SWE

| Workload | Topology | Image | Shape | 30% Moontrace result | Status |
|---|---|---|---|---|---|
| SWE | AGG1 MTP1 | MTP DS-copy | `mns24`, `mbt32768`, `block64`, `c12` | `88.389 TPS/GPU`, `55.181 TPS/user`, fail0 | AGG1 above-floor point |
| SWE | AGG1 MTP1 | MTP DS-copy | `mns24`, `mbt32768`, `block64`, `c14` | `93.092 TPS/GPU`, `42.319 TPS/user`, fail0 | AGG1 below-floor knee |
| SWE | AGG2 MTP1 | MTP DS-copy | `mns32/worker`, `mbt32768`, `block64`, `c32` | `96.260 TPS/GPU`, `51.875 TPS/user`, fail0 | current constrained optimum |
| SWE | AGG2 MTP1 | MTP DS-copy | `mns32/worker`, `mbt32768`, `block64`, `c38` | `95.039 TPS/GPU`, `77.888 TPS/user`, 2 warnings / 6819 | boundary support |
| SWE | AGG2 MTP1 | MTP DS-copy | `mns32/worker`, `mbt32768`, `block64`, `c40` | `98.303 TPS/GPU`, `42.639 TPS/user`, 4 warnings / 6819 | below-floor knee |
| SWE | AGG2 non-MTP | Patch06+humming | `mns32/worker`, `mbt65536`, `block64`, `c32` | `95.937 TPS/GPU`, `33.185 TPS/user`, fail0 | negative control |

Recommended SWE recipe for next validation is AGG2 MTP1 `c32`. The same-shape
AGG2 MTP climb should not continue to `c44/c48` because `c40` already crossed
below the `50 TPS/user` floor.

## Current DGD Plan

K8s aggregate DGDs should use separate namespaces for concurrent same-model
runs until Dynamo frontend/backend discovery isolation is proven. Within one
namespace, run only one same-model DGD at a time.

Current K8s status:

- AGG1 K8s templates exist under `agg1/`; they include the FlashInfer writable
  cubin path fix and prestart GPU guard. AGG1 chat c40 reached terminal PASS
  on full 256K Moontrace; AGG1 SWE c27 produced a partial profile before its
  deadline and should not be treated as a final recipe row.
- AGG2 K8s chat c64 exists under `agg2/`; it reached readiness and endpoint
  smoke, but AIPerf was intentionally blocked because a live same-model DGD in
  the same namespace made `/health` report a foreign backend. Use a dedicated
  namespace for concurrent same-model AGG2 benchmarking.
- 2P1D + MTP1 SWE 30% c20 has a dry-run/command-proofed DGD contract, but the
  live attempt was blocked before endpoint by dirty allocated decode GPUs. It
  is pending clean 12-GPU B200 capacity or an approved dirty-node exclusion
  policy.
- Full 256K Moontrace should not be the tuning tier. Use 30% Moontrace for
  recipe selection, then run full Moontrace only for finalists.

## Direct-Docker Passing B200 Shape

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

Required vLLM/HMA environment for direct Docker:

```text
VLLM_SSM_CONV_STATE_LAYOUT=DS
VLLM_ALLOW_CHUNKED_LOCAL_ATTN_WITH_HYBRID_KV_CACHE=1
DYN_VLLM_APPEND_PREFILL_OUTPUT_TOKENS=0
VLLM_WORKER_MULTIPROC_METHOD=spawn
VLLM_ALLREDUCE_USE_SYMM_MEM=0
```

For the K8s DGD draft, the worker pods also use nscale B200 UCX/RDMA settings
from the Dynamo examples:

```text
UCX_TLS=rc_x,rc,cuda_copy,cuda_ipc
UCX_NET_DEVICES=mlx5_0:1
UCX_IB_ADDR_TYPE=eth
UCX_RNDV_SCHEME=get_zcopy
UCX_RNDV_THRESH=0
UCX_RC_TIMEOUT=600s
UCX_KEEPALIVE_INTERVAL=300s
NCCL_IB_DISABLE=0
NCCL_SOCKET_IFNAME=eth0
GLOO_SOCKET_IFNAME=eth0
NCCL_STORE_TIMEOUT=7200
NIXL_LOG_LEVEL=INFO
```

`UCX_NET_DEVICES=mlx5_0:1` avoids the bonded `mlx5_bond_0` path, which can be
invalid on nscale B200 nodes.

K8s namespace admission is also required on nscale. Without this label, Grove
creates gated pods but KAI does not inject `pod-group-name`,
`kai.scheduler/subgroup-name`, or a matching `scheduling.run.ai` `PodGroup`:

```bash
NAMESPACE=<your-namespace>
kubectl label namespace "${NAMESPACE}" kai.scheduler/enabled=true --overwrite
```

The reusable DGD manifests omit `metadata.namespace`. Apply them with an
explicit namespace:

```bash
NAMESPACE=<your-namespace>
kubectl -n "${NAMESPACE}" apply --dry-run=server \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/disagg/deploy.yaml \
  -o yaml >/tmp/ultra-vllm-pd2p1d-mtp1-swe30-c20.dryrun.yaml

kubectl -n "${NAMESPACE}" apply \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/disagg/deploy.yaml

kubectl get pod -n "${NAMESPACE}" \
  -l nemotron-ultra.nvidia.com/cohort=vllm-patch06-mtp1-pd2p1d-swe30-c20 \
  -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,SCHEDULER:.spec.schedulerName,PG_LABEL:.metadata.labels.pod-group-name,PG_ANNOTATION:.metadata.annotations.pod-group-name,SUBGROUP:.metadata.labels.kai\\.scheduler/subgroup-name

kubectl get podgroups.scheduling.run.ai -n "${NAMESPACE}"
```

Only continue to endpoint traffic after the KAI metadata and `PodGroup` exist,
all three pods are Ready, and the prestart GPU guard has passed. On the current
nscale cluster, `pod-group-name` has been observed as an annotation while
`kai.scheduler/subgroup-name` is a label.

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

For K8s aggregate workers, use `runAsUser: 0` or mount an `emptyDir` at the
exact path above. The first AGG1 K8s attempt mounted `/opt/dynamo/.flashinfer`
instead and failed before endpoint with a FlashInfer cubin permission error.
The disaggregated DGD avoided that failure because its worker already runs as
root and mounts the exact site-packages cubin path.

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

Raw request/response evidence from the accepted Patch06+humming P/D run is
included below. The response snippets keep `finish_reason`, `message`, and
`usage`; replay artifacts should preserve the full OpenAI response JSON.

<details>
<summary>Basic chat raw evidence</summary>

Request:

```json
{"chat_template_kwargs":{"enable_thinking":false,"force_nonempty_content":true},"max_tokens":16,"messages":[{"content":"Reply with exactly: feature smoke ok","role":"user"}],"model":"nemotron-ultra-ea","temperature":0}
```

Response:

```json
{"finish_reason":"stop","message":{"content":"feature smoke ok","role":"assistant"},"usage":{"completion_tokens":4,"prompt_tokens":23,"total_tokens":27}}
```

</details>

<details>
<summary>Tool-call raw evidence</summary>

Request:

```json
{"chat_template_kwargs":{"enable_thinking":true,"force_nonempty_content":true},"max_tokens":128,"messages":[{"content":"Call the get_current_weather tool for location exactly Santa Clara, CA. Do not answer in natural language.","role":"user"}],"model":"nemotron-ultra-ea","temperature":0,"tool_choice":"required","tools":[{"function":{"description":"Get current weather for a city.","name":"get_current_weather","parameters":{"additionalProperties":false,"properties":{"location":{"type":"string"}},"required":["location"],"type":"object"},"strict":true},"type":"function"}]}
```

Response:

```json
{"finish_reason":"tool_calls","message":{"role":"assistant","tool_calls":[{"function":{"arguments":"{\"location\": \"Santa Clara, CA\"}","name":"get_current_weather"},"id":"call-0dad870c-8494-4b1d-bd33-9b32e57a971c","type":"function"}]},"usage":{"completion_tokens":57,"prompt_tokens":305,"total_tokens":362}}
```

</details>

<details>
<summary>Reasoning disabled raw evidence</summary>

Request:

```json
{"chat_template_kwargs":{"enable_thinking":false,"force_nonempty_content":true},"max_tokens":64,"messages":[{"content":"Answer with only the final integer: If x=7 and y=5, what is 3*x + 2*y?","role":"user"}],"model":"nemotron-ultra-ea","temperature":0}
```

Response:

```json
{"finish_reason":"stop","message":{"content":"31","role":"assistant"},"usage":{"completion_tokens":3,"prompt_tokens":42,"total_tokens":45}}
```

</details>

<details>
<summary>Reasoning enabled raw evidence</summary>

Request:

```json
{"chat_template_kwargs":{"enable_thinking":true,"force_nonempty_content":true},"max_tokens":128,"messages":[{"content":"Think carefully and answer with only the final integer: If x=7 and y=5, what is 3*x + 2*y?","role":"user"}],"model":"nemotron-ultra-ea","temperature":0}
```

Response:

```json
{"finish_reason":"length","message":{"content":"The user asks: \"Think carefully and answer with only the final integer: If x=7 and y=5, what is 3*x + 2*y?\"\n\nWe need to compute 3*7 + 2*5 = 21 + 10 = 31. The answer should be just the integer 31, no extra text.\n\nThe instruction: \"Think carefully and answer with only the final integer\". So we should output \"31\". Probably just \"31\". Ensure no extra spaces or punctuation? It says \"only the final integer\". So just \"31\". We'll output","role":"assistant"},"usage":{"completion_tokens":128,"prompt_tokens":45,"total_tokens":173}}
```

</details>

<details>
<summary>Low-effort reasoning budget raw evidence</summary>

Request:

```json
{"chat_template_kwargs":{"enable_thinking":true,"force_nonempty_content":true,"low_effort":true,"reasoning_effort":"low"},"max_tokens":128,"messages":[{"content":"Use the lowest reasoning effort. Then answer with only the final integer: If x=7 and y=5, what is 3*x + 2*y?","role":"user"}],"model":"nemotron-ultra-ea","reasoning_effort":"low","temperature":0}
```

Response:

```json
{"finish_reason":"stop","message":{"content":"We need to compute 3*x + 2*y with x=7, y=5. 3*7=21, 2*5=10, sum=31. Output only final integer: 31.</think>31","role":"assistant"},"usage":{"completion_tokens":54,"prompt_tokens":49,"total_tokens":103}}
```

</details>

## 65K Direct-Docker Mooncake Benchmark Note

The filtered Mooncake benchmark numbers below are **not** the 256K admission
or active 256K c16/c32 Moontrace replay. They were collected at the 65K
direct-Docker serving shape:

```text
server_shape_id: vllm_upstream_patch06_humming_recipe_tp4_1p1d_65k
max_model_len: 65536
max_num_seqs: 16
max_batched_tokens: 32768
concurrency: 8
fresh_server_per_workload: true
trace_mode: mooncake-trace-filtered-slices
```

Metric definitions:

- `Output TPS`: aggregate generated tokens per second across the whole server.
- `Output TPS/GPU`: `Output TPS / 8`, because this run used one 8x B200 node.
- `p50 TPS/user`: median per-request output-token throughput reported by
  AIPerf.
- `Router prefix-match avg`: Dynamo router's average matched-prefix ratio from
  KV-event metadata over the measured interval. It is computed as
  `delta(dynamo_component_router_kv_hit_rate_sum) /
  delta(dynamo_component_router_kv_hit_rate_count)`. It is routing/cache
  evidence, but it is not a raw backend prefix-cache-hit counter.
- `Cached tokens delta` and `KV events applied delta`: positive metric deltas
  proving that KV events and cached-token accounting moved during the benchmark.

| Benchmark type | Workload type | Concurrency | Requests | Errors | p50 ISL | p50 OSL | p50 TTFT ms | p50 ITL ms | p50 latency ms | p50 TPS/user | Output TPS | Output TPS/GPU | Router prefix-match avg | Cached tokens delta | KV events applied delta |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Mooncake trace, 65K filtered | Chat | 8 | 1817 | 0 | 5810 | 995 | 491.5 | 9.48 | 9828.0 | 105.44 | 759.40 | 94.92 | 56.6% | 5491200 | 2945 |
| Mooncake trace, 65K filtered | SWE | 8 | 1973 | 0 | 18316 | 400 | 581.6 | 9.43 | 4141.4 | 106.08 | 665.07 | 83.13 | 81.3% | 20558720 | 2985 |

Replay should create a fresh artifact root on the target system and preserve
`run_status.json`, `run_config.json`, `metrics.jsonl`, raw endpoint I/O, A7 raw
requests/responses, KV metrics snapshots, and cleanup evidence.

The 256K Moontrace chat contract is separate from the table above. It uses the
official no-schedule chat trace filtered to `11854` rows at `max_model_len=262144`
and should be reported as its own c16/c32 result only after the replay reaches
terminal metrics and cleanup passes. See `aiperf/README.md` and
`aiperf/mooncake-chat-job.yaml` for that reproducible contract.

## K8s Synthetic AIPerf Canary

The current K8s DGD has passed a synthetic AIPerf c16 client canary at the
256K no-hostpin P/D shape. This is not a cache-verified dashboard row because
the canary did not collect server cache metrics or run a KV probe in the same
action.

Client image:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-aiperf-client-0.8.0-tokenizers-20260522T204015Z@sha256:ebbb3bf5e2e2c09f34e742db18ab7ef6cfb01721050aeec7a4a77473f53fb4d4
```

Validated AIPerf command shape:

```bash
aiperf profile \
  -m nemotron-ultra-ea \
  -u http://ultra-vllm-p06h-256k-frontend:8000 \
  --endpoint v1/chat/completions \
  --endpoint-type chat \
  --streaming \
  --concurrency 16 \
  --workers-max 16 \
  --request-count 64 \
  --num-dataset-entries 64 \
  --shared-system-prompt-length 7373 \
  --user-context-prompt-length 1 \
  --synthetic-input-tokens-mean 818 \
  --synthetic-input-tokens-stddev 0 \
  --output-tokens-mean 64 \
  --output-tokens-stddev 0 \
  --tokenizer /opt/models/patched/nemotron-ultra-ea-trtllm-tokenizer-patch-469ed01fa35dbc5e962a7d78bdbd9548872e9844 \
  --tokenizer-trust-remote-code \
  --extra-inputs min_tokens:64 \
  --extra-inputs ignore_eos:true \
  --use-server-token-count \
  --random-seed 42 \
  --export-level records \
  --ui-type none \
  --no-server-metrics
```

Synthetic c16 result:

| Requests | Errors | Request throughput | Output TPS | Output TPS/GPU | TTFT p50/p95 ms | Latency p50/p95 ms | ITL p50/p95 ms |
|---:|---:|---:|---:|---:|---:|---:|---:|
| `64` | `0` | `1.316` rps | `84.24` | `10.53` | `11137.48` / `13707.04` | `11632.44` / `14131.76` | `7.744` / `8.129` |

If running c16 and c32 as comparable points, use a fresh DGD per point unless a
validated cache-reset path is available through the Dynamo frontend.

Reusable K8s AIPerf client Job manifests are checked in under `aiperf/`:

- `aiperf/synthetic-shared-prefix-c16-job.yaml` reproduces the validated
  synthetic c16 client canary.
- `aiperf/mooncake-chat-job.yaml` is the current Mooncake chat c16/c32 template
  using the filtered 256K no-schedule trace contract. Treat it as a template
  until the active c16/c32 replay reports terminal metrics; do not substitute
  the 65K direct-Docker table above as the 256K Moontrace result.
- `aiperf/mooncake-chat-agg1-c40-job.yaml` and
  `aiperf/mooncake-swe-agg1-c27-job.yaml` target the local-sweep-informed AGG1
  K8s candidates in `agg1/`.
- `aiperf/mooncake-chat-agg2-c64-job.yaml` pairs with `agg2/deploy-chat-c64.yaml`
  and requires namespace isolation if any other same-model DGD is live.
- `aiperf/mooncake-swe-mtp1-pd2p1d-c20-job.yaml` pairs with
  `disagg/deploy.yaml`; it is pending clean 12-GPU capacity, not a passed
  recipe row.

## Local Synthetic Champion Recipes

The current local direct-Docker synthetic champions are documented in
`aiperf/local-synthetic-champions.md`. They use the same Patch06+humming image
but a container-level aggregate shape, not the TP4 `1P+1D` P/D topology:

```text
topology: AGG1, frontend/router + one aggregate TP4 vLLM worker
worker GPUs: 0,1,2,3
max_model_len: 262144
max_batched_tokens: 32768 for chat, 49152 for the current SWE frontier
block_size: 32 for chat, 64 for SWE
prefix cache: enabled
P/D transfer: none
```

Current strict PRD-ready local synthetic winners:

| Workload | Config | Concurrency | Requests | TPS/GPU | TPS/user | Cache verification |
|---|---|---:|---:|---:|---:|---|
| Chat 8K/1K cache70 | `AGG1_mns40`, `max_num_seqs=40`, `max_batched_tokens=32768`, `block_size=32` | 40 | 1280 | 432.911 | 52.917 | verified by metrics |
| SWE 64K/400 cache90 | `AGG1_mns32`, `max_num_seqs=32`, `max_batched_tokens=65536`, `block_size=64` | 27 | 432 | 232.812 | 54.046 | verified by metrics |

Use `launch_aggregate.sh` for the AGG1 server and
`aiperf/run_synthetic_shared_prefix.sh` for the client command shape. The
cacheable-prefix split must remain explicit:

```text
Chat: ISL=8192, OSL=1024, cache=70%, system=5734, user_total=2458
SWE:  ISL=65536, OSL=400, cache=90%, system=58982, user_total=6554
```

K8s AGG1 DGD templates are checked in under `agg1/`. They keep the aggregate
serve arguments above, omit P/D transfer/RDMA resources, and include the
FlashInfer cubin writable-path fix.

Speculative/MTP decoding is the current 30% Moontrace tuning lane. K8s DGD
templates that use the expedited MTP DS-copy diagnostic image are marked with
their pending gate status. Promote them to production recipe rows only after
the same DGD shape reaches terminal AIPerf metrics, cache/router evidence, and
cleanup in Kubernetes.

Next local/K8s follow-up should prioritize Moontrace validation of the frozen
AGG1 chat/SWE candidates, then AGG2 total-node throughput once all 8 GPUs are
free, and finally local Moontrace on the champion recipes.
