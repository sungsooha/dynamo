<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Nemotron-3-Ultra SGLang Candidate Notes

SGLang is a viable challenger for the Ultra recipe. The passing B200 path used
a derived Dynamo image based on SGLang nightly plus the FlashInfer TRTLLM MoE
path. This directory now contains the image build recipe and direct-Docker
launch scripts used to reproduce that shape.

## Image

Build the image from the Dynamo repo root:

```bash
docker build \
  -t nemotron-3-ultra-sglang-turbo:dev \
  -f recipes/turbo-recipes/nemotron-3-ultra/sglang/Dockerfile \
  recipes/turbo-recipes/nemotron-3-ultra/sglang
```

The Dockerfile reproduces the phase-0 derived image by combining:

| Layer | Source |
|---|---|
| Dynamo donor | `nvcr.io/nvidia/ai-dynamo/sglang-runtime:1.2.0-deepseek-v4-cuda12-dev.3` |
| SGLang runtime base | `lmsysorg/sglang:nightly-dev-cu13-20260519-dbac4647` |
| Dynamo overlay | NATS, etcd, UCX, NIXL, Dynamo wheels, and Dynamo Python source copied from the donor image |
| Launch scripts | `launch_frontend.sh`, `launch_prefill.sh`, `launch_decode.sh` copied into `/workspace/recipes/turbo-recipes/nemotron-3-ultra/sglang/` |

The B200 run pushed this already-built image:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-dynamo-sglang-1.2.0-dev3-sglang-nightly-cu13-20260519-dbac4647-flashinfer-trtllm
sha256:11d2cc443a92250e9127f489ded01dbb370d9b25f4360a5a7008ded6225a66e9
```

The stock Dynamo SGLang dev.3 image was blocked by missing Nemotron-H runtime
dependency support. Direct SGLang Triton/Cutlass ModelOpt paths hit scale/shape
issues. The successful path switched to FlashInfer TRTLLM MoE:

```bash
--moe-runner-backend flashinfer_trtllm
--moe-a2a-backend none
--fp4-gemm-backend auto
--fp8-gemm-backend triton
```

Keep a writable FlashInfer cubin tmpfs when running as a non-root host user:

```bash
--tmpfs /usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer:rw,exec,mode=1777
```

## Passing B200 Shape

| Field | Value |
|---|---|
| Topology | TP4/EP4 `1P+1D` |
| Prefill GPUs | `0,1,2,3` |
| Decode GPUs | `4,5,6,7` |
| Discovery | standalone etcd |
| Context length | `65536` |
| Chunked prefill | `32768` |
| Mamba scheduler | `no_buffer` |
| Transfer | NIXL |

SGLang model registration can spend a long interval in FlashInfer TRTLLM
autotune after health is available. Validation harnesses should use an extended
model-registration timeout and should not classify the run as an etcd/keepalive
failure unless registration happened and then disappeared. The phase-0 retry
used a 2400s model-registration window.

Direct-Docker launch scripts:

```text
/workspace/recipes/turbo-recipes/nemotron-3-ultra/sglang/launch_frontend.sh
/workspace/recipes/turbo-recipes/nemotron-3-ultra/sglang/launch_prefill.sh
/workspace/recipes/turbo-recipes/nemotron-3-ultra/sglang/launch_decode.sh
```

Start etcd:

```bash
ETCD_CLIENT_PORT=22679
ETCD_PEER_PORT=22680
ETCD_ENDPOINTS="http://127.0.0.1:${ETCD_CLIENT_PORT}"

docker run -d --name nemotron-ultra-sglang-etcd --network host \
  gcr.io/etcd-development/etcd:v3.6.7 \
  /usr/local/bin/etcd \
  --name nemotron-ultra-sglang-etcd \
  --data-dir /etcd-data \
  --listen-client-urls "http://0.0.0.0:${ETCD_CLIENT_PORT}" \
  --advertise-client-urls "${ETCD_ENDPOINTS}" \
  --listen-peer-urls "http://0.0.0.0:${ETCD_PEER_PORT}" \
  --initial-advertise-peer-urls "http://127.0.0.1:${ETCD_PEER_PORT}" \
  --initial-cluster "nemotron-ultra-sglang-etcd=http://127.0.0.1:${ETCD_PEER_PORT}" \
  --initial-cluster-state new
```

Start the image:

```bash
IMAGE=nemotron-3-ultra-sglang-turbo:dev
HF_CACHE_ROOT=/path/to/huggingface-cache

docker run -it --runtime nvidia --gpus all --network host --ipc=host \
  --shm-size 64g \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  -v "${HF_CACHE_ROOT}:/hf-cache:ro" \
  -e HF_HOME=/hf-cache \
  -e HF_HUB_CACHE=/hf-cache/hub \
  -e HF_HUB_OFFLINE=1 \
  -e TRANSFORMERS_OFFLINE=1 \
  -e MODEL_PATH=/hf-cache/patched/nemotron-ultra-ea-trtllm-tokenizer-patch-469ed01fa35dbc5e962a7d78bdbd9548872e9844 \
  -e SERVED_MODEL_NAME=nemotron-ultra-ea \
  -e ETCD_ENDPOINTS="${ETCD_ENDPOINTS}" \
  -e LOG_DIR=/tmp/nemotron-ultra \
  -e SGLANG_FLASHINFER_TMPFS=/usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer \
  --tmpfs /usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer:rw,exec,mode=1777 \
  --entrypoint /bin/bash \
  "${IMAGE}"
```

Inside the container:

```bash
bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/sglang/launch_prefill.sh &
bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/sglang/launch_decode.sh &
bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/sglang/launch_frontend.sh &
```

Before sending chat, A7, AIPerf, or Mooncake traffic, require more than
`/v1/models`: the frontend logs must show a non-prefill `dynamo` worker set, or
equivalent worker/decode readiness evidence. Then run exact short chat and
strict A7 with raw request/response plus usage.

The worker scripts expand to:

```bash
python3 -m dynamo.sglang \
  --discovery-backend etcd \
  --request-plane tcp \
  --event-plane zmq \
  --model-path "${MODEL_PATH}" \
  --served-model-name nemotron-ultra-ea \
  --tp-size 4 \
  --ep-size 4 \
  --trust-remote-code \
  --context-length 65536 \
  --mem-fraction-static 0.85 \
  --chunked-prefill-size 32768 \
  --mamba-scheduler-strategy no_buffer \
  --fp8-gemm-backend triton \
  --fp4-gemm-backend auto \
  --moe-a2a-backend none \
  --moe-runner-backend flashinfer_trtllm \
  --enable-metrics \
  --dyn-tool-call-parser qwen3_coder \
  --dyn-reasoning-parser nemotron3
```

## DynamoGraphDeployment Draft

`disagg/deploy.yaml` captures the same Dynamo/SGLang settings as a draft
Kubernetes DGD. It has not yet replaced the direct-Docker evidence path.
Before treating it as production-ready, validate:

- model-cache PVC layout for the tokenizer-patched model view
- image pull secret access to the private staging image
- FlashInfer cubin writeability in the target pod security context
- Dynamo operator schema compatibility for the explicit `--kv-events-config`
  and emptyDir mount

## Standalone Validation Summary

The original reserved-node artifact directories are internal. Use the results
below as the portable acceptance summary and regenerate local artifacts on the
target system.

| Gate | Standalone result |
|---|---|
| Image identity | `nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-dynamo-sglang-1.2.0-dev3-sglang-nightly-cu13-20260519-dbac4647-flashinfer-trtllm@sha256:11d2cc443a92250e9127f489ded01dbb370d9b25f4360a5a7008ded6225a66e9` |
| A9 P/D smoke | TP4/EP4 `1P+1D`, `/health` PASS, `/v1/models` exposed `nemotron-ultra-ea`, exact short chat PASS |
| Strict A7 | 5/5 PASS, all HTTP 2xx, JSON parse OK, usage present |
| KV-aware routing / reuse | PASS by metrics: `dynamo_frontend_cached_tokens_sum +65536`, `dynamo_component_router_kv_hit_rate_sum +3.99970017240087`, `dynamo_component_kv_cache_events_applied +40029`; warmup/repeat ratio `6.69x` |
| A10 mini shared-prefix | `c1/r8` output TPS `59.419`, `c2/r16` output TPS `111.664`, `0` request errors |
| A11 filtered Mooncake practice | chat `req/s 0.1198`, output TPS `97.68`, router hit avg `34.6%`, KV events applied `+164143`; SWE `req/s 0.2428`, output TPS `88.58`, router hit avg `65.2%`, KV events applied `+57234`; both had `0` request errors |

Full official c32 filtered Mooncake replay is not yet a PASS for this SGLang
image. A larger-load diagnostic reproduced a P/D bootstrap failure under trace
load; continue from a newer SGLang image or an explicit backport plan before
claiming full-trace readiness.
