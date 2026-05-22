# syntax=docker/dockerfile:1.10.0
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Nemotron-3-Ultra turbo NIM vLLM draft recipe.
#
# Current accepted vLLM checkpoint: Patch06+humming.
#
# This Dockerfile wraps the published Patch06+humming image and embeds the
# recipe launch scripts. The current Patch06 source patch is checked into
# patches/ for audit and future source rebuild work; this wrapper remains the
# validated runtime reproduction path.
#
# Accepted image provenance:
# - vLLM main 1c78f76 + PR #42554 68dc38b + PR #42547 477556a
# - Patch06: patches/06_vllm_patch02_hash_block_event_port_after_pr42547.patch
# - added CUDA requirement: humming-kernels[cu13]==0.1.0
# - pushed tag:
#   nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521
# - digest:
#   sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337
#
# Build this recipe wrapper from the Dynamo repo root:
#
#   docker build \
#     -t nemotron-3-ultra-vllm-turbo:dev \
#     -f recipes/turbo-recipes/nemotron-3-ultra/vllm/Dockerfile \
#     recipes/turbo-recipes/nemotron-3-ultra/vllm

ARG BASE_IMAGE="nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521@sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337"

FROM ${BASE_IMAGE}
USER root

RUN python3 - <<'PY'
import pathlib
import vllm

root = pathlib.Path(vllm.__file__).resolve().parent
joined = "\n".join(
    path.read_text(errors="ignore")
    for path in root.rglob("*.py")
    if path.is_file()
)
required = [
    "get_kv_cache_group_metadata",
    "hash_block_size",
    "humming",
    "FullAttentionSpec",
    "TQFullAttentionSpec",
]
missing = [marker for marker in required if marker not in joined]
if missing:
    raise RuntimeError(f"Nemotron Ultra vLLM Patch06+humming markers missing: {missing}")
PY

COPY --chmod=755 --chown=dynamo:0 \
  launch_frontend.sh \
  launch_prefill.sh \
  launch_decode.sh \
  /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/

USER dynamo
