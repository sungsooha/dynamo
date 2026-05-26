# syntax=docker/dockerfile:1.10.0
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Nemotron-3-Ultra turbo NIM vLLM draft recipe.
#
# Current accepted vLLM checkpoint: Patch06+humming plus Ultra MTP/P-D
# installed-package patches.
#
# This Dockerfile starts from the published Patch06+humming image, applies the
# installed-package Ultra patches, and embeds the recipe launch and validation
# scripts. Patch06 and the installed-package patches are checked into patches/
# for audit and future source rebuild work.
#
# Patch06+humming base image provenance:
# - vLLM main 1c78f76 + PR #42554 68dc38b + PR #42547 477556a
# - Patch06: patches/06_vllm_patch02_hash_block_event_port_after_pr42547.patch
# - added CUDA requirement: humming-kernels[cu13]==0.1.0
# - pushed tag:
#   nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521
# - digest:
#   sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337
#
# Ultra installed-package patch provenance:
# - diagnostic patch: patches/ds_copy_diag_installed_vllm.patch
# - P/D SSM/NIXL tailfix: patches/ssm_nixl_tailfix_installed_vllm.patch
# - patch source: work-tracker/helix-vllm
#   projects/nemotron-ultra/mtp-ds-copy-diagnostic
# - validated non-bypass config: VLLM_SSM_CONV_STATE_LAYOUT=DS,
#   mamba_cache_mode=align, prefix caching enabled, nemotron_h_mtp,
#   --spec-tokens 1
# - full GSM8K comparison: MTP EM 0.884003 vs non-MTP EM 0.881729
#   on 1319 samples, within +/-0.01 tolerance
# - pushed diagnostic image:
#   nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-patch06-humming-mtp-ds-copy-diag-20260523T164824Z
# - diagnostic image digest:
#   sha256:4c2e66ddd2610b9fbd84caffb0ae5663264322cfc29b9f22cf8be141f88d7cca
# - SSM/NIXL tailfix image:
#   nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-patch06-humming-mtp-ds-copy-ssm-tailfix-20260526T061806Z
# - SSM/NIXL tailfix digest:
#   sha256:b4a948fd7560ba072a46762bc026f1fefdac7ab276ed02798ffd1fc958a7cc3a
#
# Build this recipe wrapper from the Dynamo repo root:
#
#   docker build \
#     -t nemotron-3-ultra-vllm-turbo:dev \
#     -f recipes/turbo-recipes/nemotron-3-ultra/vllm/Dockerfile \
#     recipes/turbo-recipes/nemotron-3-ultra/vllm

ARG BASE_IMAGE="nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521@sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337"
ARG APPLY_MTP_DS_COPY_PATCH=1
ARG APPLY_SSM_NIXL_TAILFIX_PATCH=1

FROM ${BASE_IMAGE}
USER root

ARG APPLY_MTP_DS_COPY_PATCH
ARG APPLY_SSM_NIXL_TAILFIX_PATCH

COPY --chmod=755 --chown=root:0 \
  scripts/apply_ds_copy_patch_in_container.py \
  scripts/apply_ssm_nixl_tailfix_in_container.py \
  scripts/ds_copy_selftest.py \
  /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/scripts/

COPY --chmod=644 --chown=root:0 \
  patches/ds_copy_diag_installed_vllm.patch \
  patches/ssm_nixl_tailfix_installed_vllm.patch \
  /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/patches/

RUN if [ "${APPLY_MTP_DS_COPY_PATCH}" = "1" ]; then \
      python3 /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/scripts/apply_ds_copy_patch_in_container.py \
        --diff-out /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/patches/ds_copy_diag_applied_at_build.patch; \
    fi && \
    if [ "${APPLY_SSM_NIXL_TAILFIX_PATCH}" = "1" ]; then \
      python3 /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/scripts/apply_ssm_nixl_tailfix_in_container.py \
        --diff-out /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/patches/ssm_nixl_tailfix_applied_at_build.patch; \
    fi && \
    python3 - <<'PY'
import importlib
import pathlib

vllm = importlib.import_module("vllm")
root = pathlib.Path(vllm.__file__).resolve().parent
required = {
    "model_executor/layers/mamba/mamba_utils.py": [
        "HELIX_ULTRA_MTP_DS_COPY_DIAG",
        "ds_conv_tail",
    ],
    "v1/worker/mamba_utils.py": [
        "HELIX_ULTRA_MTP_DS_COPY_DIAG",
        "ds_conv_tail_copy",
    ],
    "distributed/kv_transfer/kv_connector/v1/nixl/worker.py": [
        "NEMOTRON_ULTRA_SSM_NIXL_TAILFIX",
        "SSM group has no local blocks to receive",
    ],
}
missing = []
for rel, markers in required.items():
    text = (root / rel).read_text(errors="ignore")
    for marker in markers:
        if marker not in text:
            missing.append(f"{rel}:{marker}")
if missing:
    raise RuntimeError(f"Ultra MTP DS-copy markers missing: {missing}")
PY

RUN set -eux; \
    mkdir -p /usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer; \
    chown -R dynamo:0 /usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer; \
    chmod -R 0775 /usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins/flashinfer

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
  launch_aggregate.sh \
  benchmark.sh \
  /workspace/recipes/turbo-recipes/nemotron-3-ultra/vllm/

USER dynamo
