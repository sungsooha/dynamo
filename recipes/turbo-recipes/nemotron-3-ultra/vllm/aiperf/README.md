<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Ultra vLLM AIPerf Jobs

This directory contains the AIPerf client-side Kubernetes jobs used with the
Nemotron-3-Ultra vLLM Patch06+humming DGD.

These manifests are client jobs only. Start and validate the DGD first:

```bash
NAMESPACE=<your-namespace>
kubectl label namespace "${NAMESPACE}" kai.scheduler/enabled=true --overwrite
kubectl -n "${NAMESPACE}" apply --dry-run=server \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/disagg/deploy.yaml \
  -o yaml >/tmp/ultra-vllm-p06h-256k.dryrun.yaml
kubectl -n "${NAMESPACE}" apply \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/disagg/deploy.yaml
```

Continue only after:

- KAI metadata and a matching `scheduling.run.ai` `PodGroup` exist.
- All DGD pods are Ready with zero restarts.
- `/health` returns HTTP 200.
- `/v1/models` exposes `nemotron-ultra-ea` with `context_window=262144`.
- The exact short chat smoke passes.

Client image:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-aiperf-client-0.8.0-tokenizers-20260522T204015Z@sha256:ebbb3bf5e2e2c09f34e742db18ab7ef6cfb01721050aeec7a4a77473f53fb4d4
```

The full `shared-model-cache` PVC must be mounted at `/opt/models`; mounting
only the patched model-view directory is not enough for the tokenizer smoke.
Before copying a manifest for a new run, update the Kubernetes Job name and
`ARTIFACT_DIR` so the run does not overwrite a prior PVC artifact directory.

Full Moontrace runs need a larger artifact PVC than the 10 GiB smoke PVC used
for early K8s bringup. Use a namespace-local RWX PVC named
`nemotron-ultra-aiperf-artifacts` mounted at `/artifacts` for Moontrace traces,
`inputs.json`, and profile exports. Keep small diagnostics on a separate smoke
PVC if the namespace has one.

## Jobs

| Manifest | Status | Purpose |
|---|---|---|
| `synthetic-shared-prefix-c16-job.yaml` | Validated PASS | Synthetic 8K/64 shared-prefix c16 client canary against the 256K DGD |
| `mooncake-chat-job.yaml` | Template while c16/c32 run is in progress | Official no-schedule Mooncake chat trace replay, fresh DGD per measured point |
| `mooncake-chat-agg1-c40-job.yaml` | Template | AGG1 chat champion candidate, c40, 256K filtered no-schedule Mooncake chat |
| `mooncake-swe-agg1-c27-job.yaml` | Template | AGG1 SWE champion candidate, c27, 256K filtered no-schedule Mooncake SWE |
| `mooncake-chat-agg2-c64-job.yaml` | Blocked before AIPerf pending namespace isolation | AGG2 chat c64, two aggregate TP4 workers, 256K filtered no-schedule Mooncake chat |
| `mooncake-swe-mtp1-pd2p1d-c20-job.yaml` | Pending clean capacity | 2P1D+MTP1 SWE 30% c20, command-proofed and dry-run validated |
| `run_synthetic_shared_prefix.sh` | Direct-Docker helper | Reusable AIPerf command wrapper for local synthetic shared-system-prompt rows |

## Validated Synthetic c16 Point

Shape:

```text
benchmark_type: synthetic shared-prefix
concurrency: 16
workers_max: 16
request_count: 64
ISL: 8192
OSL: 64
cache_hit_strategy: system_prompt_shared_prefix
system_prompt_tokens: 7373
user_context_prompt_length: 1
synthetic_input_tokens_mean: 818
streaming: true
use_server_token_count: true
ignore_eos: true
export_level: records
```

Result:

```text
requests=64
errors=0
request_throughput=1.316 rps
output_tps=84.24
output_tps_per_gpu=10.53
ttft_p50/p95_ms=11137.48/13707.04
latency_p50/p95_ms=11632.44/14131.76
itl_p50/p95_ms=7.744/8.129
cache_verification=shared_prefix_unverified_cache_metrics
dashboard_row_ready=no
```

This point is a client/server plumbing canary. It did not collect server cache
metrics in the same action, so do not use it as a cache-verified dashboard row.

## Local Direct-Docker Synthetic Champions

The local synthetic champion rows are documented in
`local-synthetic-champions.md`. They use a direct-Docker AGG1 server launched by
`../launch_aggregate.sh` and this directory's
`run_synthetic_shared_prefix.sh` client wrapper. The wrapper is not part of the
published AIPerf client image; stage it into the run artifact or mount this
recipe directory before invoking it.

Current champion rows:

| Workload | Config | Concurrency | Requests | TPS/GPU | TPS/user | Cache verification |
|---|---|---:|---:|---:|---:|---|
| Chat 8K/1K cache70 | `AGG1_mns40_mbt32768_block32` | 40 | 1280 | 432.911 | 52.917 | verified by metrics |
| SWE 64K/400 cache90 | `AGG1_mns32_mbt49152_block64` | 27 | 864 | 232.555 | 52.228 | verified by metrics |

These rows are local container/runtime tuning evidence. They do not replace the
K8s DGD or Moontrace validation lanes.

## 30% Moontrace Tuning Selection

The active tuning tier is 30% Moontrace, not full 256K Moontrace. The objective
is highest `TPS/GPU` while keeping `Gen TPS/user avg >= 50`, with cache/router
metrics verified and stable server health.

Current vLLM 30% selections:

| Workload | Candidate | Concurrency | Trace rows | TPS/GPU | Gen TPS/user avg | Notes |
|---|---|---:|---:|---:|---:|---|
| Chat 30% Moontrace | AGG1 MTP1 `mns72/mbt32768/block64` | 68 | 3546 | 202.097 | 64.263 | Frontier candidate, 11 small AIPerf/client warnings |
| Chat 30% Moontrace | AGG1 MTP1 `mns64/mbt32768/block64` | 64 | 3546 | 198.736 | 71.488 | Robust zero-warning candidate |
| SWE 30% Moontrace | AGG2 MTP1 `mns32/worker/mbt32768/block64` | 32 | 6819 | 96.260 | 51.875 | Current constrained optimum |
| SWE 30% Moontrace | AGG1 MTP1 `mns24/mbt32768/block64` | 12 | 6819 | 88.389 | 55.181 | AGG1 fallback point |
| SWE 30% Moontrace | 2P1D+MTP1 `2x prefill TP4 + 1x decode TP4` | 20 | 6819 | TBD | TBD | Pending clean 12-GPU B200 capacity; DGD schema and command proof passed |

Do not continue the same AGG2 MTP SWE shape above c40: c40 reached
`98.303 TPS/GPU` but dropped to `42.639 TPS/user`. For SWE, the next
experiments should change topology or serving shape rather than extending
c44/c48.

## Mooncake Chat Contract

Use the official no-schedule chat trace, filtered for the 256K serving shape:

```text
source_trace=nim_turbo_8k_1k_70kv_chat_new_noschedule.jsonl
filtered_count=11854
max_model_len=262144
osl_cap=1024
margin=512
sha256=1efbdba25d51e8e325fdc3b48cca75c044547a134ab3c888e06f68b10207fc14
prompt_input_tokens_block_size=512
synthesis_max_isl=260608
synthesis_max_osl=1024
dataset_sampling_strategy=sequential
cache_salt_mode=omit_fresh_dgd
```

Stage the filtered trace under the AIPerf artifact PVC before running the Job:

```text
/artifacts/trace_preflight/prep_chat_256k/filtered_traces/chat_maxlen262144_oslcap1024_margin512.jsonl
```

Run c16 first. Run c32 only after c16 passes and cleanup verifies no remaining
DGD, pod, job, or service in the namespace. Use a fresh DGD per measured point
unless a validated cache reset path is available.

To run c32 from `mooncake-chat-job.yaml`, change the Job name, `ARTIFACT_DIR`,
`CONCURRENCY`, and `WORKERS_MAX` together. Keep `REQUEST_COUNT` equal to the
filtered trace line count; the Job derives it with `wc -l`.

The Moontrace client request is intentionally modest (`cpu=4`, `memory=16Gi`)
because a larger no-GPU request (`cpu=16`, `memory=32Gi`) stayed Pending on the
shared dev cluster without sending traffic.

Keep `--export-level records` for full runs. Do not enable
`--export-http-trace` by default; it increases per-record artifact size and is
reserved for bounded diagnostics of invalid/empty-content responses.

## Mooncake SWE Contract

Use the official no-schedule SWE trace, filtered for the 256K serving shape:

```text
source_trace=official no-schedule SWE trace
filtered_count=22917
max_model_len=262144
osl_cap=400
margin=512
sha256=72d5c0333e70a639e58e6fc009936f611fd4ccbc1306f52864e05105cb12c123
prompt_input_tokens_block_size=512
synthesis_max_isl=261232
synthesis_max_osl=400
dataset_sampling_strategy=sequential
cache_salt_mode=omit_fresh_dgd
```

Stage the filtered trace under the AIPerf artifact PVC before running the Job:

```text
/artifacts/trace_preflight/prep_swe_256k/filtered_traces/swe_maxlen262144_oslcap400_margin512.jsonl
```

For the local-sweep-informed aggregate candidate, run
`mooncake-swe-agg1-c27-job.yaml` against
`../agg1/deploy-swe-c27.yaml`. Keep `CONCURRENCY`, `WORKERS_MAX`, and the DGD
`--max-num-seqs` contract aligned: c27 client against `max_num_seqs=32`.

## SWE 30% P/D MTP1 Contract

`mooncake-swe-mtp1-pd2p1d-c20-job.yaml` pairs with
`../disagg/deploy.yaml`. It is not a passed benchmark row. The DGD and AIPerf
Job server-side dry-ran successfully and the live DGD reached KAI/Grove
metadata, but decode landed on dirty B200 GPUs and the prestart guard stopped
before model load. Retry only when a capacity scan proves three clean 4-GPU
B200 slots with matching `rdma/ib` availability, or an explicit dirty-node
exclusion policy is approved.

## AGG1 K8s Pairing

The AGG1 Moontrace jobs pair with these DGD manifests:

| DGD | Job | Workload | Required serve args |
|---|---|---|---|
| `../agg1/deploy-chat-c40.yaml` | `mooncake-chat-agg1-c40-job.yaml` | Chat | `max_num_seqs=40`, `max_num_batched_tokens=32768`, `block_size=32` |
| `../agg1/deploy-swe-c27.yaml` | `mooncake-swe-agg1-c27-job.yaml` | SWE | `max_num_seqs=32`, `max_num_batched_tokens=49152`, `block_size=64` |

Both AGG1 DGDs intentionally omit P/D transfer, UCX/NIXL transfer args, and
`rdma/ib` resources. They also include the FlashInfer cubin writable-path fix
required by the Patch06+humming image on K8s. The public service endpoint is
the reasoning API proxy on port `8000`; benchmark jobs should keep using the
service endpoint unless a run contract explicitly targets the inner frontend
for proxy-overhead isolation.

## AGG2 K8s Pairing

| DGD | Job | Workload | Required serve args |
|---|---|---|---|
| `../agg2/deploy-chat-c64.yaml` | `mooncake-chat-agg2-c64-job.yaml` | Chat | two `VllmWorker` replicas, per-worker `max_num_seqs=32`, `max_num_batched_tokens=32768`, `block_size=64` |

AGG2 is aggregate routing evidence, not P/D or NIXL evidence. Run it in a
separate namespace when another same-model DGD is live; same-namespace
`/health` can list foreign generate backends.
The public service endpoint is the reasoning API proxy on port `8000`; the
inner Dynamo frontend is container-local port `8001`.
