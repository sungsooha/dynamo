<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Nemotron-3-Ultra vLLM Recipe

This recipe packages the current vLLM Patch06+humming runtime and the Ultra
MTP DS-copy patch. It is intended to be reproducible from this directory for
both direct-Docker B200 checks and Kubernetes DGD runs.

## Image

The recipe image is built by applying local patches on top of the accepted
Patch06+humming base image.

Base image:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521@sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337
```

Patches/features included by the recipe Dockerfile:

- Patch06 hash-block KV event port patch:
  `patches/06_vllm_patch02_hash_block_event_port_after_pr42547.patch`
- Humming kernels: `humming-kernels[cu13]==0.1.0`
- Ultra MTP DS-layout conv-tail copy patch:
  `patches/ds_copy_diag_installed_vllm.patch`
- FlashInfer cubin writable-path setup for non-root container runtime
- Recipe launchers and bounded smoke wrapper

Build from the Dynamo repo root:

```bash
docker build \
  -t nemotron-3-ultra-vllm-turbo:dev \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/Dockerfile \
  recipes/turbo-recipes/nemotron-3-ultra/vllm
```

The expedited diagnostic image used for MTP experiments was:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-patch06-humming-mtp-ds-copy-diag-20260523T164824Z@sha256:4c2e66ddd2610b9fbd84caffb0ae5663264322cfc29b9f22cf8be141f88d7cca
```

Use the Dockerfile as the normal reproduction path. The diagnostic image is
kept here as provenance and as a temporary comparison target while the DS-copy
patch remains an installed-package patch.

## Direct-Docker Smoke

Use `benchmark.sh` for a bounded image/server smoke on one 8x B200 host. It
builds or pulls the image, starts isolated etcd, starts the vLLM server, runs
`/health`, `/v1/models`, and an exact short chat, then writes wrun-style
artifacts and cleanup evidence. It does not run AIPerf throughput.

AGG1 MTP smoke on GPUs 0-3:

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

AGG2 MTP smoke on GPUs 0-7:

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

When `SPEC_TOKENS != 0`, `benchmark.sh` runs the DS-copy self-test before
server startup.

## 30% Moontrace Tuning Results

The tuning objective is to maximize `TPS/GPU` while keeping
`Gen TPS/user avg >= 50`, with server health, cache/router evidence, profile
export, and cleanup all recorded.

Current best recipes from 30% Moontrace:

| Workload | Recommended topology | Server shape | AIPerf point | Result | Cache/router evidence |
|---|---|---|---|---|---|
| Chat | AGG1 MTP1 | `mns72`, `mbt32768`, `block64`, TP4 on 4 GPUs | `c68`, `3546` requests | `202.097 TPS/GPU`, `64.263 TPS/user`, `11/3546` client warnings | router hit avg `0.4924`, cached tokens `14.3M`, KV events `18.8K` |
| SWE | AGG2 MTP1 | `mns32/worker`, `mbt32768`, `block64`, two TP4 workers on 8 GPUs | `c32`, `6819` requests | `96.260 TPS/GPU`, `51.875 TPS/user`, fail0 | router hit avg `0.8398`, cached tokens `234.5M`, KV events `30.0K` |

Chat has a zero-warning AGG1 MTP1 fallback at `mns64/mbt32768/block64/c64`
with `198.736 TPS/GPU`, `71.488 TPS/user`, router hit avg `0.4900`, cached
tokens `13.6M`, and KV events `19.1K`.

The same AGG2 MTP SWE shape should not be climbed past `c40` without changing
configuration: `c40` improved raw throughput but fell below the `50 TPS/user`
floor.

## Local Synthetic Recipes

Synthetic shared-prefix runs are useful for fast shape screening, but 30%
Moontrace is the recipe-selection tier. Use the script below for synthetic
checks and keep the cacheable prefix split explicit in artifacts.

```bash
recipes/turbo-recipes/nemotron-3-ultra/vllm/aiperf/run_synthetic_shared_prefix.sh
```

Synthetic prompt/cache contracts:

```text
Chat: ISL=8192, OSL=1024, cache=70%, system_prompt_tokens=5734, user_prompt_tokens=2458
SWE:  ISL=65536, OSL=400, cache=90%, system_prompt_tokens=58982, user_prompt_tokens=6554
```

Representative local synthetic winners:

| Workload | Topology | Shape | Result | Cache evidence |
|---|---|---|---|---|
| Chat | AGG1 MTP1 | `mns72`, `mbt32768`, `block64`, `c68` | `558.974 TPS/GPU`, `52.581 TPS/user`, fail0 | verified by metrics |
| SWE | AGG1 MTP1 | `mns40`, `mbt32768`, `block64`, `c38` | `303.310 TPS/GPU`, `51.587 TPS/user`, fail0 | verified by metrics |
| SWE | AGG2 MTP1 | `mns32/worker`, `mbt32768`, `block64`, `c32` | `96.260 TPS/GPU`, `51.875 TPS/user`, fail0 on 30% Moontrace | verified by metrics |

More synthetic rows and command shapes are in
`aiperf/local-synthetic-champions.md`.

## Kubernetes DGD Configs

The checked-in manifests are namespace-neutral. Apply them with
`kubectl -n <namespace> ...`.

| Config | Files | Status |
|---|---|---|
| AGG1 chat/SWE non-MTP | `agg1/deploy-chat-c40.yaml`, `agg1/deploy-swe-c27.yaml`, `aiperf/mooncake-chat-agg1-c40-job.yaml`, `aiperf/mooncake-swe-agg1-c27-job.yaml` | Available. Chat reached terminal on Kubernetes; SWE produced partial profile before deadline and is not a final row. |
| AGG2 chat non-MTP | `agg2/deploy-chat-c64.yaml`, `aiperf/mooncake-chat-agg2-c64-job.yaml` | Available. Endpoint passed; benchmark was held because same-model backend discovery needed isolation. |
| P/D 2P1D MTP1 SWE 30% | `disagg/deploy.yaml`, `aiperf/mooncake-swe-mtp1-pd2p1d-c20-job.yaml` | Pending terminal result. Requires three clean 4-GPU B200 worker slots with RDMA. |

Server-side dry-run example:

```bash
NAMESPACE=<namespace>
kubectl -n "${NAMESPACE}" apply --dry-run=server \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/disagg/deploy.yaml \
  -o yaml >/tmp/ultra-vllm-pd2p1d-mtp1-swe30-c20.dryrun.yaml

kubectl -n "${NAMESPACE}" apply --dry-run=server \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/aiperf/mooncake-swe-mtp1-pd2p1d-c20-job.yaml \
  -o yaml >/tmp/ultra-aiperf-pd2p1d-mtp1-swe30-c20.dryrun.yaml
```

Live apply should use the deterministic benchmark routine: verify PVCs,
secrets, trace hash, CRD/operator compatibility, scheduler capacity, and
prestart GPU memory guard before any AIPerf traffic.

## AIPerf Setup

The current AIPerf client image used by K8s jobs is:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-aiperf-client-0.8.0-tokenizers-20260522T204015Z@sha256:ebbb3bf5e2e2c09f34e742db18ab7ef6cfb01721050aeec7a4a77473f53fb4d4
```

Reusable job templates live under `aiperf/`:

- `mooncake-chat-agg1-c40-job.yaml`
- `mooncake-chat-agg2-c64-job.yaml`
- `mooncake-swe-agg1-c27-job.yaml`
- `mooncake-swe-mtp1-pd2p1d-c20-job.yaml`
- `synthetic-shared-prefix-c16-job.yaml`

For Moontrace jobs, cache behavior is trace-native. Record router hit average,
cached-token deltas, and KV-event deltas from server metrics. For synthetic
shared-prefix jobs, record `system_prompt_tokens`, `user_prompt_tokens`,
`cache_hit_rate_pct`, and `cache_hit_strategy=system_prompt_shared_prefix` in
the generated command and metrics row.

## Runtime Arguments

Common aggregate launcher knobs:

```text
MODEL_PATH=/path/to/model-view
SERVED_MODEL_NAME=nemotron-ultra-ea
TP=4
MAX_MODEL_LEN=262144
MAX_NUM_SEQS=<shape-specific>
MAX_BATCHED_TOKENS=<shape-specific>
BLOCK_SIZE=<shape-specific>
MAMBA_CACHE_MODE=align
SPEC_METHOD=nemotron_h_mtp
SPEC_TOKENS=1
AGG_WORKERS=1|2
```

For MTP runs, keep:

```text
VLLM_SSM_CONV_STATE_LAYOUT=DS
VLLM_ALLOW_CHUNKED_LOCAL_ATTN_WITH_HYBRID_KV_CACHE=1
VLLM_WORKER_MULTIPROC_METHOD=spawn
VLLM_ALLREDUCE_USE_SYMM_MEM=0
```

Parser contract:

```text
--dyn-tool-call-parser qwen3_coder
--dyn-reasoning-parser nemotron3
--reasoning-parser-plugin ${MODEL_PATH}/ultra_v3_reasoning_parser.py
--reasoning-parser nemotron_v3
```

P/D runs additionally require:

```text
--kv-transfer-config {"kv_connector":"NixlConnector","kv_role":"kv_both"}
--disaggregation-mode prefill|decode
```

Aggregate runs must not set P/D transfer or RDMA resource requests.
