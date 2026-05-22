<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Nemotron-3-Ultra Recipe Validation Helpers

These helpers are for recipe reproducibility and practice canaries. They are
not production deployment entrypoints.

## Filtered Mooncake Practice

`a11_filtered_mooncake_practice_run.sh` runs one filtered Mooncake AIPerf c1/r8
practice point against one fresh recipe P/D server.

Rules encoded by the helper:

- filtered trace JSONL only; raw/unfiltered trace rows are never benchmark
  metric rows
- one fresh server per backend/workload for clean cache-hit intervals
- `/health`, `/v1/models`, decode/backend worker readiness, and exact short
  chat before AIPerf traffic
- cache verification from concrete metric deltas or request-time logs
- router hit-rate computed as `_sum` delta divided by `_count` delta
- wrun-style artifacts: `run_status.json`, `status.jsonl`, `run_config.json`,
  `generated_commands.json`, `failures.jsonl`, `metrics.jsonl`,
  `manifest.tsv`, raw smoke I/O, AIPerf output, cache diagnostics, and cleanup

The helper expects a prepared artifact root containing:

```text
filtered_traces/*.jsonl
commands/run_a11_*_mooncake_*.sh
source_recipe/vllm/launch_*.sh        # for vLLM recipe-script replay
source_recipe/sglang/launch_*.sh      # for SGLang recipe-script replay
```

TRT-LLM uses image-embedded launch scripts from
`/workspace/recipes/turbo-recipes/nemotron-3-ultra/trtllm/`.

Required environment:

```text
ARTIFACT_ROOT              fresh run artifact root
BACKEND                    vllm, sglang, or trtllm
WORKLOAD                   chat or swe
IMAGE                      locally-built recipe image or accepted staging image
PREP_ARTIFACT              filtered Mooncake prep artifact used as the seed
HF_CACHE_ROOT              full Hugging Face cache root mounted as /hf-cache
MODEL_VIEW_HOST            tokenizer-patched model view on the host
```

`EXPECTED_IMAGE_DIGEST` is optional. If it is set, the helper enforces an exact
Docker image ID/digest match during preflight. If it is unset, the helper still
records `docker image inspect` and the actual image ID.

Useful image choices:

```text
# Locally-built recipe images
nemotron-3-ultra-vllm-turbo:dev
nemotron-3-ultra-sglang-turbo:dev
nemotron-3-ultra-trtllm-turbo:dev

# Phase-0 accepted staging images
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-dynamo-sglang-1.2.0-dev3-sglang-nightly-cu13-20260519-dbac4647-flashinfer-trtllm
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-dynamo-trtllm-base501a580-pr14060-9c9cde-sm100-donordeps-20260520
```

`VLLM_FLASHINFER_TMPFS` and `SGLANG_FLASHINFER_TMPFS` expose the image-specific
FlashInfer cubin tmpfs mount paths. The vLLM Patch06+humming and SGLang recipe images
use `/usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer`
by default.

Example:

```bash
ARTIFACT_ROOT=/path/to/writable/artifacts/ultra_a11_mooncake_vllm_chat_filtered_<UTC>
PREP_ARTIFACT=/path/to/filtered-mooncake-prep-artifact
HF_CACHE_ROOT=/path/to/huggingface-cache
MODEL_VIEW_HOST="${HF_CACHE_ROOT}/patched/nemotron-ultra-ea-trtllm-tokenizer-patch-469ed01fa35dbc5e962a7d78bdbd9548872e9844"
IMAGE=nemotron-3-ultra-vllm-turbo:dev

rsync -a "$PREP_ARTIFACT"/ "$ARTIFACT_ROOT"/
mkdir -p "$ARTIFACT_ROOT/source_recipe"
rsync -a recipes/turbo-recipes/nemotron-3-ultra/vllm "$ARTIFACT_ROOT/source_recipe/"

BACKEND=vllm WORKLOAD=chat ARTIFACT_ROOT="$ARTIFACT_ROOT" IMAGE="$IMAGE" \
  PREP_ARTIFACT="$PREP_ARTIFACT" HF_CACHE_ROOT="$HF_CACHE_ROOT" \
  MODEL_VIEW_HOST="$MODEL_VIEW_HOST" \
  bash recipes/turbo-recipes/nemotron-3-ultra/scripts/a11_filtered_mooncake_practice_run.sh
```
