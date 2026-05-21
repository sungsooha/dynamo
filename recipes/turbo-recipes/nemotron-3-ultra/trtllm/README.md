<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Nemotron-3-Ultra TRT-LLM Candidate Notes

TRT-LLM is a caveated candidate for Ultra. The official Dynamo TRT image proved
P/D endpoint and A7 liveness, but did not prove actual KV reuse because block
reuse was disabled. The current reuse candidate is a derived B200/SM100 image
with TensorRT-LLM PR #14060 lineage and donor-copied dependencies.

## Images

| Purpose | Image | Digest |
|---|---|---|
| Official control | `nvcr.io/nvidia/ai-dynamo/tensorrtllm-runtime:1.1.1` | `sha256:15adf35d35bcba505264645c6662af27636b36b1b8134e542ce0bce830c1f951` |
| Derived B200 reuse candidate | `nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-dynamo-trtllm-base501a580-pr14060-9c9cde-sm100-donordeps-20260520` | `sha256:7652b201b605ffd4a415c8205eebc694df30e19d7b188b2b72eafd6d068a4bf9` |

Derived-image lineage:

```text
TensorRT-LLM base: 501a58034eef4ff1ae144891963f790390875863
TensorRT-LLM PR #14060 head: 9c9cde29249b0e9103d129aca9094217b466b922
Wheel sha256: 17334fae8bb02b706096fb303572ec33b8f37a7406de2bad4a799741b53cfabc
```

## Build Derived Image

The derived image is a two-step build.

First build the TensorRT-LLM wheel from the pinned source lineage:

```bash
cd <dynamo-repo-root>
bash recipes/turbo-recipes/nemotron-3-ultra/trtllm/build_trtllm_wheel.sh
```

Expected B200 wheel:

```text
recipes/turbo-recipes/nemotron-3-ultra/trtllm/wheels/app_tensorrt_llm/tensorrt_llm-1.3.0rc15-cp312-cp312-linux_x86_64.whl
sha256: 17334fae8bb02b706096fb303572ec33b8f37a7406de2bad4a799741b53cfabc
```

Then build the Dynamo TRT runtime image:

```bash
docker build \
  -t nemotron-3-ultra-trtllm-turbo:dev \
  -f recipes/turbo-recipes/nemotron-3-ultra/trtllm/Dockerfile \
  recipes/turbo-recipes/nemotron-3-ultra/trtllm
```

The Dockerfile starts from the official Dynamo TRT runtime, installs the PR
#14060 TensorRT-LLM wheel, and donor-copies these dependency packages from the
TensorRT-LLM release image to avoid broad pip dependency churn:

```text
flashinfer-python 0.6.11.post1
transformers 5.5.3
huggingface_hub 1.15.0
mistral-common 1.11.2
```

For H200, do not reuse the B200/SM100 wheel. Rebuild with the appropriate
`CUDA_ARCHS` before building the final image.

## Passing Bounded Reuse Shape

The passing T5.4 reuse diagnostic used a conservative memory/admission shape.
The checked-in config copies are:

```text
configs/prefill-reuseprobe.yaml
configs/decode-reuseprobe.yaml
```

Key values:

| Field | Value |
|---|---|
| Topology | TP4 `1P+1D` |
| Prefill GPUs | `0,1,2,3` |
| Decode GPUs | `4,5,6,7` |
| Discovery | file discovery |
| `max_batch_size` | `1` |
| `max_num_tokens` | `4096` |
| `free_gpu_memory_fraction` | `0.35` |
| `enable_block_reuse` | `true` |
| `event_buffer_max_size` | `8192` |
| `tokens_per_block` | `32` |
| `transceiver_runtime` | `CPP` |
| `max_tokens_in_buffer` | `8192` |

Frontend flags:

```bash
python3 -m dynamo.frontend \
  --discovery-backend file \
  --router-mode kv \
  --router-kv-events \
  --kv-cache-block-size 32 \
  --router-kv-overlap-score-weight 1.0 \
  --router-temperature 0.0 \
  --http-port "${FRONTEND_PORT}"
```

Worker flags:

```bash
python3 -m dynamo.trtllm \
  --discovery-backend file \
  --model-path "${MODEL_PATH}" \
  --served-model-name nemotron-ultra-ea \
  --extra-engine-args /artifacts/commands/a9_trtllm_prefill_config.yaml \
  --modality text \
  --disaggregation-mode prefill \
  --dyn-tool-call-parser nemotron_nano \
  --dyn-reasoning-parser nemotron_nano \
  --publish-events-and-metrics \
  --kv-block-size 32
```

Use the same shape for decode with `--disaggregation-mode decode` and the decode
YAML.

Direct-Docker launch scripts in this directory encode the same contract:

```text
/workspace/recipes/turbo-recipes/nemotron-3-ultra/trtllm/launch_frontend.sh
/workspace/recipes/turbo-recipes/nemotron-3-ultra/trtllm/launch_prefill.sh
/workspace/recipes/turbo-recipes/nemotron-3-ultra/trtllm/launch_decode.sh
```

Start the derived image:

```bash
IMAGE=nemotron-3-ultra-trtllm-turbo:dev
HF_CACHE_ROOT=/path/to/huggingface-cache
FRONTEND_PORT=18000
DYN_FILE_KV=/tmp/dynamo_store_kv_trtllm_a9_${FRONTEND_PORT}

docker run -it --runtime nvidia --gpus all --network host --ipc=host \
  --shm-size 64g \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  --user "$(id -u):$(id -g)" \
  -v "${HF_CACHE_ROOT}:/hf-cache:ro" \
  -e HOME=/tmp \
  -e USER="$(id -un)" \
  -e LOGNAME="$(id -un)" \
  -e HF_HOME=/hf-cache \
  -e HF_HUB_CACHE=/hf-cache/hub \
  -e HF_MODULES_CACHE=/tmp/hf_modules \
  -e HF_HUB_OFFLINE=1 \
  -e TRANSFORMERS_OFFLINE=1 \
  -e XDG_CACHE_HOME=/tmp/cache \
  -e TORCH_EXTENSIONS_DIR=/tmp/torch_extensions \
  -e MODEL_PATH=/hf-cache/patched/nemotron-ultra-ea-trtllm-tokenizer-patch-469ed01fa35dbc5e962a7d78bdbd9548872e9844 \
  -e SERVED_MODEL_NAME=nemotron-ultra-ea \
  -e FRONTEND_PORT="${FRONTEND_PORT}" \
  -e DYN_FILE_KV="${DYN_FILE_KV}" \
  -e LOG_DIR=/tmp/nemotron-ultra \
  --entrypoint /bin/bash \
  "${IMAGE}"
```

Inside the container:

```bash
bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/trtllm/launch_frontend.sh &
bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/trtllm/launch_prefill.sh &
bash /workspace/recipes/turbo-recipes/nemotron-3-ultra/trtllm/launch_decode.sh &
```

`disagg/deploy.yaml` is a draft DGD with the same T5.4 bounded-reuse config
embedded as ConfigMaps. It is not a substitute for the direct-Docker evidence
until validated through the target Dynamo operator and PVC layout.

## Internal Evidence

These paths are from the original B200 reserved-node run and are not required
for replay on another cluster.

| Evidence | Artifact |
|---|---|
| Official image TP4 single-worker | `/home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_a8_trtllm_tp4_single_worker_20260518T235518Z` |
| Official image raw A7 | `/home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_a7_trtllm_tp4_rawio_token_freegpu_20260519T150338Z` |
| Derived image build/probe/push | `/home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_a9_trtllm_derived_dynamo_image_t2_4_donor_deps_20260520T091917Z` |
| Derived T5.4 A9 bounded KV reuse | `/home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_a9_trtllm_derived_t5_tool256_reuseprobe_20260520T104249Z` |
| A10 mini AIPerf | `/home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_a10_trtllm_derived_mini_aiperf_decode_ready_20260520T193311Z` |

T5.4 reuse evidence: `dynamo_frontend_cached_tokens_sum=12846.0`,
`dynamo_component_router_kv_hit_rate_sum=3.980099502487562`, warmup
`4.068899s`, identical repeat `0.602096s`, and shared-prefix extension
`0.542034s`.

A10 passed as a client/tooling canary but cache verification remained
`routing_only_not_cache_verified`. Treat TRT as viable but caveated until a
larger-prefix/admission sweep gives stronger evidence.

## H200 Note

The derived TRT image was built for B200/SM100. For H200, rebuild the same
source lineage with an H200-compatible architecture target before replaying the
recipe.
