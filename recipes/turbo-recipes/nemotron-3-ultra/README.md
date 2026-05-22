<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Nemotron-3-Ultra Turbo NIM

Draft Turbo recipe checkpoint for the Nemotron-3-Ultra EA mixed NVFP4/FP8
checkpoint. This mirrors the lightweight `nemotron-3-super` Turbo recipe format:
a patched vLLM image plus direct launch scripts for one-node Dynamo P/D smoke.

This is not yet a production `recipes/<model>/<framework>/<mode>/deploy.yaml`
recipe. `recipes/CONTRIBUTING.md` describes that final Kubernetes structure.
When we promote this from checkpoint to production recipe, the target path
should be `recipes/nemotron-3-ultra-nvfp4/` with per-framework deployment
folders such as `vllm/disagg-single-node/`.

## Checkpoint

Validated phase-0 checkpoint:

```text
repo: nvidia/Nemotron-Ultra-V3-rl3-050826-mixed_nvfp4-fp8_amax_1024x65k
snapshot: 469ed01fa35dbc5e962a7d78bdbd9548872e9844
served model name: nemotron-ultra-ea
```

Use a tokenizer-patched model view under the local HF cache:

```text
${HF_CACHE_ROOT}/patched/nemotron-ultra-ea-trtllm-tokenizer-patch-469ed01fa35dbc5e962a7d78bdbd9548872e9844
```

Mount the full HF cache, not just the snapshot directory, because snapshot
files are symlinks into `hub/blobs`.

## Available Configurations

The current primary draft is vLLM Patch06+humming TP4 `1P+1D` because it
passed B200 endpoint smoke, strict A7 API checks, KV-cache reuse diagnostics,
full filtered Mooncake replay, and 128K/256K context admission in direct
Docker.

| Configuration | GPUs | Backend | Mode | Description |
|---|---:|---|---|---|
| [**vllm/direct-1p1d**](vllm/) | 8x B200 | vLLM | Direct Docker P/D | Patch06+humming, TP4 prefill + TP4 decode, NIXL/HMA, KV-aware routing, strict A7 + KV reuse + full filtered Mooncake passed |
| [**sglang/direct-1p1d**](sglang/) | 8x B200 | SGLang | Direct Docker P/D | TP4/EP4 prefill + decode, NIXL, KV reuse passed |
| [**trtllm/direct-1p1d**](trtllm/) | 8x B200 | TensorRT-LLM | Direct Docker P/D | Bounded KV reuse diagnostic passed; A10 cache verification TBD |
| `vllm/disagg-single-node` | TBD | vLLM | Kubernetes DGD | TBD production recipe |
| `sglang/disagg-single-node` | TBD | SGLang | Kubernetes DGD | TBD production recipe |
| `trtllm/disagg-single-node` | TBD | TensorRT-LLM | Kubernetes DGD | TBD production recipe |

Framework-specific replay notes are in `sglang/` and `trtllm/`.

## Validation Gates

Direct-Docker validation should not treat `/v1/models` alone as endpoint
readiness. Require all of the following before sending benchmark or AIPerf
traffic:

- `/health` returns HTTP 200.
- `/v1/models` exposes `nemotron-ultra-ea`.
- The decode/backend worker is registered. For TRT-LLM this means the logs or
  discovery tree contain `dynamo.tensorrt_llm.generate`; for vLLM and SGLang it
  means the frontend has added a non-prefill worker set for the `dynamo`
  namespace.
- A short exact-content chat request returns `disagg smoke ok` with numeric
  usage.

Strict A7 validation must preserve raw requests, raw responses, and usage for
all payloads. HTTP 200 without semantic checks is not sufficient. Cache-reuse
validation must use runtime metrics or request-time logs; startup-only
publisher/router logs are not sufficient.

## A11 Mooncake Practice

Filtered Mooncake AIPerf practice canaries are supported by:

```text
scripts/a11_filtered_mooncake_practice_run.sh
```

Use filtered trace JSONL only. Do not run raw/unfiltered traces as AIPerf metric
rows. For clean cache attribution, run one fresh server per backend/workload:
for example vLLM chat, cleanup, vLLM SWE, cleanup, then repeat for SGLang and
TRT-LLM. The helper requires `IMAGE`, `PREP_ARTIFACT`, `HF_CACHE_ROOT`, and
`MODEL_VIEW_HOST` as explicit inputs so clean-checkout users choose either a
locally-built recipe image or an accepted staging image. `EXPECTED_IMAGE_DIGEST`
is optional and enforced when set. The runner records cache evidence from
`/metrics` intervals and computes router hit-rate as:

```text
delta(dynamo_component_router_kv_hit_rate_sum)
/ delta(dynamo_component_router_kv_hit_rate_count)
```

Do not report the `_sum` value alone as a percentage.

## Prerequisites

1. Docker with NVIDIA runtime on an 8x B200 node.
2. HF cache containing the validated checkpoint and tokenizer-patched model view.
3. For vLLM, the current Dockerfile wraps the accepted Patch06+humming image
   and embeds recipe launch scripts. The Patch06 source delta is checked in at
   `vllm/patches/06_vllm_patch02_hash_block_event_port_after_pr42547.patch`
   for audit and future source rebuild work.
4. Kubernetes Dynamo platform, PVCs, and model-cache manifests: TBD for the
   production recipe. Draft DGD config exists for vLLM, SGLang, and TRT-LLM
   under each framework's `disagg/deploy.yaml`, but direct Docker remains the
   validated path.

## Build vLLM Image

Build the current Patch06+humming wrapper image from the Dynamo repo root:

```bash
docker build \
  -t nemotron-3-ultra-vllm-turbo:dev \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/Dockerfile \
  recipes/turbo-recipes/nemotron-3-ultra/vllm
```

Historical patch files are intentionally not carried in this recipe; use git
history if they are needed. The accepted vLLM Patch06+humming image is:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521
sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337
```

`vllm/disagg/deploy.yaml` is a draft DGD capturing the current Patch06+humming
K8s no-hostpin smoke contract. It server-side dry-runs on
`dynamo-nscale-dev-cluster/sungsooh-ultra`; live DGD retries still require
explicit approval and must preserve one-live-object throttling.

## Run vLLM P/D Smoke

Start etcd:

```bash
ETCD_CLIENT_PORT=22879
ETCD_PEER_PORT=22880
ETCD_ENDPOINTS="http://127.0.0.1:${ETCD_CLIENT_PORT}"

docker run -d --name nemotron-ultra-etcd --network host \
  gcr.io/etcd-development/etcd:v3.6.7 \
  /usr/local/bin/etcd \
  --name nemotron-ultra-etcd \
  --data-dir /etcd-data \
  --listen-client-urls "http://0.0.0.0:${ETCD_CLIENT_PORT}" \
  --advertise-client-urls "${ETCD_ENDPOINTS}" \
  --listen-peer-urls "http://0.0.0.0:${ETCD_PEER_PORT}" \
  --initial-advertise-peer-urls "http://127.0.0.1:${ETCD_PEER_PORT}" \
  --initial-cluster "nemotron-ultra-etcd=http://127.0.0.1:${ETCD_PEER_PORT}" \
  --initial-cluster-state new
```

Start the patched image with the full HF cache mounted:

```bash
IMAGE=nemotron-3-ultra-vllm-turbo:dev
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
  -e MAX_MODEL_LEN=262144 \
  --tmpfs /usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer:rw,exec,mode=1777 \
  --entrypoint /bin/bash \
  "${IMAGE}"
```

Inside the container:

```bash
bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/launch_prefill.sh &
bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/launch_decode.sh &
bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/launch_frontend.sh &
```

Default B200 shape:

```text
prefill GPUs: 0,1,2,3
decode GPUs: 4,5,6,7
tensor parallel: 4 per side
max model len: 65536
max num seqs: 16
max batched tokens: 32768
router: Dynamo KV router with KV events
transfer: NIXL/HMA with hybrid KV manager enabled
```

Smoke:

```bash
curl -sS http://127.0.0.1:18740/v1/models

curl -sS http://127.0.0.1:18740/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"nemotron-ultra-ea","messages":[{"role":"user","content":"Reply with exactly: disagg smoke ok"}],"chat_template_kwargs":{"enable_thinking":false,"force_nonempty_content":true},"max_tokens":16,"temperature":0}'
```

For a real pass, also run the strict A7 API checks: basic chat, tool calling,
reasoning enabled, reasoning disabled, and low-effort reasoning budget. Preserve
raw request/response files and usage for each payload; HTTP 200 alone is not
sufficient.

## Build SGLang Image

The SGLang challenger image is reproducible from `sglang/Dockerfile`.

```bash
docker build \
  -t nemotron-3-ultra-sglang-turbo:dev \
  -f recipes/turbo-recipes/nemotron-3-ultra/sglang/Dockerfile \
  recipes/turbo-recipes/nemotron-3-ultra/sglang
```

The Dockerfile overlays Dynamo dev.3 runtime pieces onto
`lmsysorg/sglang:nightly-dev-cu13-20260519-dbac4647`, then embeds:

```text
sglang/launch_frontend.sh
sglang/launch_prefill.sh
sglang/launch_decode.sh
```

The phase-0 B200 run pushed the equivalent derived image:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-dynamo-sglang-1.2.0-dev3-sglang-nightly-cu13-20260519-dbac4647-flashinfer-trtllm
sha256:11d2cc443a92250e9127f489ded01dbb370d9b25f4360a5a7008ded6225a66e9
```

SGLang-specific required deltas:

```text
--moe-runner-backend flashinfer_trtllm
--moe-a2a-backend none
--fp4-gemm-backend auto
--fp8-gemm-backend triton
--mamba-scheduler-strategy no_buffer
```

Keep the FlashInfer cubin path writable with tmpfs when running as a non-root
host user:

```text
/usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer
```

## Build TRT-LLM Image

TRT-LLM requires a two-stage build: first build the TensorRT-LLM PR #14060 wheel,
then build the Dynamo runtime image.

```bash
bash recipes/turbo-recipes/nemotron-3-ultra/trtllm/build_trtllm_wheel.sh

docker build \
  -t nemotron-3-ultra-trtllm-turbo:dev \
  -f recipes/turbo-recipes/nemotron-3-ultra/trtllm/Dockerfile \
  recipes/turbo-recipes/nemotron-3-ultra/trtllm
```

The phase-0 B200 run pushed the equivalent derived image:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-dynamo-trtllm-base501a580-pr14060-9c9cde-sm100-donordeps-20260520
sha256:7652b201b605ffd4a415c8205eebc694df30e19d7b188b2b72eafd6d068a4bf9
```

This TRT path is caveated: it passed endpoint smoke, strict A7, router events,
and bounded-prefix KV reuse with conservative admission settings. It is not yet
a long-context or A10 throughput winner.

## Model Details

- **Model**: `nvidia/Nemotron-Ultra-V3-rl3-050826-mixed_nvfp4-fp8_amax_1024x65k`
- **Architecture**: Nemotron-H hybrid Mamba/Attention/MoE
- **Quantization**: mixed NVFP4/FP8 ModelOpt checkpoint
- **Max context used in this checkpoint**: `65536` for one-node P/D smoke; wider
  context and Mooncake filtering are TBD for production benchmark sweeps.

## Parser Configuration

The vLLM P/D smoke uses:

- `--dyn-tool-call-parser qwen3_coder`
- `--dyn-reasoning-parser nemotron3`
- `--reasoning-parser-plugin ${MODEL_PATH}/ultra_v3_reasoning_parser.py`
- `--reasoning-parser nemotron_v3`

This parser contract passed strict A7 on the patched vLLM TP4 `1P+1D` setup.

## Routing

The vLLM checkpoint uses Dynamo KV-aware routing with KV events:

```text
frontend: --router-mode kv --router-kv-events --kv-cache-block-size 64
prefill:  --kv-events-config {"publisher":"zmq","topic":"kv-events","endpoint":"tcp://*:5571","enable_kv_cache_events":true}
```

KV reuse was observed in the A9 B200 diagnostic. Production-scale routing and
Mooncake trace benchmark settings are TBD.

## File Layout

```text
recipes/turbo-recipes/nemotron-3-ultra/
  README.md
  vllm/
    Dockerfile
    launch_prefill.sh
    launch_decode.sh
    launch_frontend.sh
    disagg/
      deploy.yaml
    patches/
  sglang/
    Dockerfile
    launch_prefill.sh
    launch_decode.sh
    launch_frontend.sh
    disagg/
      deploy.yaml
  trtllm/
    Dockerfile
    build_trtllm_wheel.sh
    launch_prefill.sh
    launch_decode.sh
    launch_frontend.sh
    disagg/
      deploy.yaml
    configs/
  scripts/
    a11_filtered_mooncake_practice_run.sh
```
