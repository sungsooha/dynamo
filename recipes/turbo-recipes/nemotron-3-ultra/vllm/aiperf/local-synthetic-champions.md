<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Local Synthetic Champion Recipes

This note captures the phase-0 v2 direct-Docker local synthetic winners for
Nemotron Ultra vLLM Patch06+humming. These rows are synthetic
shared-system-prompt tuning evidence, not Moontrace rows and not K8s topology
decisions.

## Runtime Image

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521
sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337
```

The AIPerf client image used for these rows was:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-aiperf-client-0.8.0-tokenizers-20260522T204015Z
sha256:ebbb3bf5e2e2c09f34e742db18ab7ef6cfb01721050aeec7a4a77473f53fb4d4
```

Mount the full Hugging Face cache root read-only into the server at `/hf-cache`
and into the client at `/opt/models`. The model view must resolve to:

```text
/hf-cache/patched/nemotron-ultra-ea-trtllm-tokenizer-patch-469ed01fa35dbc5e962a7d78bdbd9548872e9844
```

The node-local evidence used `/tmp/nemotron-ultra/hf-cache/huggingface` as the
host cache root. That path is not a durable requirement; any host cache root is
valid if it contains the same patched model view.

## Server Shape

The current local winners use an aggregate single-worker shape:

```text
server_shape_family: AGG1
topology: frontend/router + one aggregate vLLM TP4 worker
worker GPUs: 0,1,2,3
max_model_len: 262144
max_batched_tokens: 32768 for chat, 65536 for current SWE frontier
gpu_memory_utilization: 0.9
block_size: 32 for chat, 64 for SWE
prefix_cache: enabled
mamba_cache_mode: align
P/D transfer: none
```

Use `../launch_aggregate.sh` inside the server container. The script starts the
Dynamo frontend/router and a single aggregate `dynamo.vllm` worker. It preserves
the same Patch06/HMA/Mamba environment as the P/D launcher while omitting
`--disaggregation-mode` and NIXL P/D transfer.

Minimal direct-Docker server sketch:

```bash
IMAGE=nemotron-3-ultra-vllm-turbo:dev
sudo docker run -d --network host --ipc host --ulimit memlock=-1 \
  --ulimit stack=67108864 --gpus all \
  --user "$(id -u):$(id -g)" \
  --tmpfs /usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer:rw,exec,mode=1777 \
  -e HOME=/tmp \
  -e HF_HOME=/hf-cache \
  -e MODEL_PATH=/hf-cache/patched/nemotron-ultra-ea-trtllm-tokenizer-patch-469ed01fa35dbc5e962a7d78bdbd9548872e9844 \
  -e SERVED_MODEL_NAME=nemotron-ultra-ea \
  -e FRONTEND_PORT=18740 \
  -e ETCD_ENDPOINTS=http://127.0.0.1:2379 \
  -e DYN_DISCOVERY_BACKEND=etcd \
  -e DYN_REQUEST_PLANE=tcp \
  -e DYN_EVENT_PLANE=zmq \
  -e TP=4 \
  -e MAX_MODEL_LEN=262144 \
  -e MAX_NUM_SEQS=40 \
  -e MAX_BATCHED_TOKENS=32768 \
  -e VLLM_BLOCK_SIZE=32 \
  -e WORKER_CVD=0,1,2,3 \
  -e WORKER_SYSTEM_PORT=19901 \
  -v "${ARTIFACT_ROOT}:/artifacts" \
  -v "${HF_CACHE_ROOT}:/hf-cache:ro" \
  "${IMAGE}" \
  bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/launch_aggregate.sh
```

For the current SWE champion, keep the same shape but set
`MAX_NUM_SEQS=32`, `MAX_BATCHED_TOKENS=65536`, and `VLLM_BLOCK_SIZE=64`.

The wrapper image built from this recipe embeds `launch_aggregate.sh`. If using
the accepted Patch06+humming image directly, mount or copy the script explicitly
and record that runtime mode.

Run `/health`, `/v1/models`, exact short chat, strict A7, and a bounded KV probe
before AIPerf traffic. Preserve raw endpoint/A7 I/O, metrics snapshots, logs,
and cleanup evidence in the artifact root.

## Cache-Hit Construction

Use the shared-system-prompt split. Record these fields in `run_config.json`,
point inputs, generated commands, and `metrics.jsonl`.

| Workload | ISL | OSL | Cache target | System prompt tokens | User prompt tokens total | AIPerf split |
|---|---:|---:|---:|---:|---:|---|
| Chat | 8192 | 1024 | 70% | 5734 | 2458 | `--shared-system-prompt-length 5734 --user-context-prompt-length 2432 --synthetic-input-tokens-mean 26` |
| SWE | 65536 | 400 | 90% | 58982 | 6554 | `--shared-system-prompt-length 58982 --user-context-prompt-length 6528 --synthetic-input-tokens-mean 26` |

Stage `run_synthetic_shared_prefix.sh` from this directory into the AIPerf
artifact root or mount the recipe tree into the tokenizer-capable AIPerf client
container. The examples below assume the script is staged at
`/artifacts/commands/run_synthetic_shared_prefix.sh`.

Chat champion command shape:

```bash
BASE_URL=http://127.0.0.1:18740 \
CONCURRENCY=40 \
WORKERS_MAX=40 \
REQUEST_COUNT=1280 \
SYSTEM_PROMPT_TOKENS=5734 \
USER_CONTEXT_PROMPT_LENGTH=2432 \
SYNTHETIC_INPUT_TOKENS_MEAN=26 \
OSL=1024 \
ARTIFACT_DIR=/artifacts/points/agg1_mns40_mbt32768_block32_chat_8k1k_cache70_c40_confirm \
bash /artifacts/commands/run_synthetic_shared_prefix.sh
```

SWE champion command shape:

```bash
BASE_URL=http://127.0.0.1:18740 \
CONCURRENCY=27 \
WORKERS_MAX=27 \
REQUEST_COUNT=432 \
SYSTEM_PROMPT_TOKENS=58982 \
USER_CONTEXT_PROMPT_LENGTH=6528 \
SYNTHETIC_INPUT_TOKENS_MEAN=26 \
OSL=400 \
ARTIFACT_DIR=/artifacts/points/agg1_mns32_mbt65536_swe_64k400_cache90_c27 \
bash /artifacts/commands/run_synthetic_shared_prefix.sh
```

## Current Champion Rows

TPS/GPU is normalized over the 4 GPUs used by AGG1. Both rows had zero request
failures and cache verification by server metrics.

| Workload | Server config | Concurrency | Requests | TPS/GPU | TPS/user | TTFT p50 ms | ITL p50 ms | Latency p50 ms | Cache evidence | Source artifact |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| Chat | `AGG1_mns40`, `max_num_seqs=40`, `max_batched_tokens=32768`, `block_size=32` | 40 | 1280 | 432.911 | 52.917 | 4448.4 | 18.72 | 23568.8 | router hit avg `0.675`, KV events `3537` | `/tmp/nemotron-ultra/artifacts/v2_1_vllm_patch06_humming_local_synthetic_packet19_agg1_chat_block32_confirm_20260523T155918Z` |
| SWE | `AGG1_mns32`, `max_num_seqs=32`, `max_batched_tokens=65536`, `block_size=64` | 27 | 432 | 232.812 | 54.046 | 4103.972 | 18.801 | 11575.989 | cache verified | `/tmp/nemotron-ultra/artifacts/v2_1_vllm_patch06_humming_local_synthetic_packet22_agg1_swe_mbt65536_canary_20260523T172500Z` |

Dashboard promotion remains controller-owned. The rows above are recipe
champions for reproducibility and follow-up tuning, not automatically promoted
dashboard rows.

## MTP Lane

MTP/speculative decoding is tracked as a separate recipe lane from the non-MTP
synthetic rows above. The diagnostic MTP DS-copy image passed MTP canaries and
full GSM8K against this stack. Current 30% Moontrace selection is AGG1 MTP1
chat c64/c68 and AGG2 MTP1 SWE c32; same-shape AGG2 c40 fell below the
50 Gen TPS/user floor. K8s P/D 2P1D+MTP1 is command-proofed but pending clean
12-GPU B200 capacity.

## Forward Plan

Suggested follow-up packets:

1. K8s Moontrace: AGG1 chat c40 has a full-run PASS packet; AGG1 SWE c27 is
   partial-only and should not be promoted as the current SWE recipe.
2. AGG2 K8s must use namespace isolation when another same-model DGD is live;
   same-namespace `/health` can list foreign generate backends.
3. P/D 2P1D+MTP1 SWE c20 should retry only when a clean 12-GPU B200 capacity
   gate passes or a dirty-node exclusion policy is approved.
4. Local Moontrace only after champion recipes are frozen and controller
   approves product-like replay on the reserved node.
