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

The current primary draft is vLLM Patch05 TP4 `1P+1D` because it passed B200
endpoint smoke, strict A7 API checks, and KV-cache reuse diagnostics.

| Configuration | GPUs | Backend | Mode | Description |
|---|---:|---|---|---|
| [**vllm/direct-1p1d**](vllm/) | 8x B200 | vLLM | Direct Docker P/D | TP4 prefill + TP4 decode, NIXL/HMA, KV-aware routing, strict A7 + KV reuse passed |
| [**sglang/direct-1p1d**](sglang/) | 8x B200 | SGLang | Direct Docker P/D | TP4/EP4 prefill + decode, NIXL, KV reuse passed |
| [**trtllm/direct-1p1d**](trtllm/) | 8x B200 | TensorRT-LLM | Direct Docker P/D | Bounded KV reuse diagnostic passed; A10 cache verification TBD |
| `vllm/disagg-single-node` | TBD | vLLM | Kubernetes DGD | TBD production recipe |
| `sglang/disagg-single-node` | TBD | SGLang | Kubernetes DGD | TBD production recipe |
| `trtllm/disagg-single-node` | TBD | TensorRT-LLM | Kubernetes DGD | TBD production recipe |

Framework-specific replay notes are in `sglang/` and `trtllm/`.

## Prerequisites

1. Docker with NVIDIA runtime on an 8x B200 node.
2. HF cache containing the validated checkpoint and tokenizer-patched model view.
3. For rebuilding the vLLM image, a local Dynamo vLLM `0.21.0` base image built
   from the command sequence in [vllm/Dockerfile](vllm/Dockerfile).
4. Kubernetes Dynamo platform, PVCs, and model-cache manifests: TBD for the
   production recipe. Draft DGD config exists for vLLM, SGLang, and TRT-LLM
   under each framework's `disagg/deploy.yaml`, but direct Docker remains the
   validated path.

## Build vLLM Image

First build the local Dynamo vLLM `0.21.0` base image. The exact base creation
commands are documented in the Dockerfile header.

Then build the patched Ultra image from the Dynamo repo root:

```bash
docker build \
  -t nemotron-3-ultra-vllm-turbo:dev \
  -f recipes/turbo-recipes/nemotron-3-ultra/vllm/Dockerfile \
  recipes/turbo-recipes/nemotron-3-ultra/vllm
```

The Dockerfile applies five vLLM patches in order:

```text
01_vllm_pr40984.patch
02_patch_c_v21_sub_block_emit.patch
03_vllm_metadata_hash_block_size.patch
04_vllm_mamba_hma_async_load_align_split.patch
05_vllm_mamba_single_token_prefill_as_decode.patch
```

The B200 run pushed this already-built image for replay:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-dynamo-vllm-pr9669-vllm0.21.0-kvpatch-20260520-mamba-hma-pr42430
sha256:017360cce7950f1b0ab4d8a8bd698945f0b3e88c51d1226d5940a3dcb00926a6
```

That pushed image was built before this checkpoint moved launch scripts under
`vllm/`. To test the current script layout, rebuild `nemotron-3-ultra-vllm-turbo:dev`
from this recipe or mount/copy the updated `vllm/launch_*.sh` files into the
container.

The updated `vllm/` script layout was reproduced by mounting the current
`vllm/launch_*.sh` scripts into the pushed Patch05 image and rerunning A9:

```text
/home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_recipe_vllm_repro_primary_20260520T213711Z
```

That run passed endpoint smoke, strict A7, and KV reuse with positive
`dynamo_frontend_cached_tokens_sum` and router hit-rate metrics.

`vllm/disagg/deploy.yaml` is a draft DGD capturing the same Patch05 CLI/env
contract. It has not yet replaced the direct-Docker evidence path; validate
operator schema, PVC model path, image pull, pod networking for NIXL/HMA, and
FlashInfer cubin writeability before treating it as production.

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
```
