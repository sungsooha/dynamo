# syntax=docker/dockerfile:1.10.0
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Nemotron-3-Ultra turbo NIM vLLM draft recipe.
#
# This Dockerfile rebuilds the vLLM Patch05 image from a locally-built Dynamo
# vLLM 0.21.0 runtime base.
#
# Build the base first from a Dynamo checkout. The passing B200 image used
# ai-dynamo/dynamo commit df6649150dcec1fe3d17a49bd3007b2a96c18ee8.
#
#   git clone https://github.com/ai-dynamo/dynamo.git dynamo-pr9669
#   cd dynamo-pr9669
#   git checkout --detach df6649150dcec1fe3d17a49bd3007b2a96c18ee8
#   python3 -m pip install pyyaml jinja2
#   python3 container/render.py \
#     --framework vllm \
#     --target runtime \
#     --cuda-version 13.0 \
#     --platform linux/amd64 \
#     --output-short-filename
#   docker build \
#     --pull \
#     -t nemotron-ultra/dynamo-vllm-pr9669-base:20260519-vllm0.21.0 \
#     -f container/rendered.Dockerfile \
#     .
#
# The rendered runtime stage resolves to `FROM vllm/vllm-openai:v0.21.0`.
# Builder stages use nvcr.io/nvidia/cuda-dl-base:25.11-cuda13.0-devel-ubuntu24.04
# and quay.io/pypa/manylinux_2_28_x86_64.
#
# Build this patched image from the Dynamo repo root:
#
#   docker build \
#     -t nemotron-3-ultra-vllm-turbo:dev \
#     -f recipes/turbo-recipes/nemotron-3-ultra/vllm/Dockerfile \
#     recipes/turbo-recipes/nemotron-3-ultra/vllm

ARG BASE_IMAGE="nemotron-ultra/dynamo-vllm-pr9669-base:20260519-vllm0.21.0"

FROM ${BASE_IMAGE}
USER root

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends patch \
 && rm -rf /var/lib/apt/lists/*

COPY patches/ /tmp/nemotron-ultra-vllm-kvpatches/

RUN set -eux; \
    VLLM_PARENT="$(python3 -c 'import vllm, os; print(os.path.dirname(os.path.dirname(vllm.__file__)))')"; \
    cd "${VLLM_PARENT}"; \
    patch -p1 < /tmp/nemotron-ultra-vllm-kvpatches/01_vllm_pr40984.patch; \
    patch -p1 < /tmp/nemotron-ultra-vllm-kvpatches/02_patch_c_v21_sub_block_emit.patch; \
    patch -p1 < /tmp/nemotron-ultra-vllm-kvpatches/03_vllm_metadata_hash_block_size.patch; \
    patch -p1 < /tmp/nemotron-ultra-vllm-kvpatches/04_vllm_mamba_hma_async_load_align_split.patch; \
    patch -p1 < /tmp/nemotron-ultra-vllm-kvpatches/05_vllm_mamba_single_token_prefill_as_decode.patch; \
    python3 -m compileall -q "${VLLM_PARENT}/vllm"; \
    python3 - <<'PY'
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
    "kv_cache_spec_kind",
    "_maybe_emit_sub_block_events",
    "Patch-D-v21",
    "Patch-E-v21",
]
missing = [marker for marker in required if marker not in joined]
if missing:
    raise RuntimeError(f"Nemotron Ultra vLLM patch markers missing: {missing}")
PY

RUN rm -rf /tmp/nemotron-ultra-vllm-kvpatches

COPY --chmod=755 --chown=dynamo:0 \
  launch_frontend.sh \
  launch_prefill.sh \
  launch_decode.sh \
  /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/

USER dynamo
