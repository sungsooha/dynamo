<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Patch Boundary File Map

This directory contains vLLM installed-package patch files. Some delivery
boundaries also include scripts or launch plumbing outside `patches/`; those
paths are listed here explicitly so reviewers do not have to infer them from
the Dockerfile.

| Boundary | Reviewable files | Dockerfile behavior |
|---|---|---|
| `01_patch06_humming_base` | `06_vllm_patch02_hash_block_event_port_after_pr42547.patch`; provenance in `../BASE_IMAGE_PROVENANCE.md` | Already included in the published base image. The recipe Dockerfile does not reapply it. |
| `02_vllm_mtp_ds_copy` | `ds_copy_diag_installed_vllm.patch`; `../scripts/apply_ds_copy_patch_in_container.py`; `../scripts/ds_copy_selftest.py` | Applied when `APPLY_MTP_DS_COPY_PATCH=1`; writes `ds_copy_diag_applied_at_build.patch` inside the built image for audit. |
| `03_vllm_pd_ssm_nixl_tailfix` | `ssm_nixl_tailfix_installed_vllm.patch`; `../scripts/apply_ssm_nixl_tailfix_in_container.py` | Applied when `APPLY_SSM_NIXL_TAILFIX_PATCH=1`; writes `ssm_nixl_tailfix_applied_at_build.patch` inside the built image for audit. |
| `04_dynamo_reasoning_api_compat_proxy` | `../scripts/reasoning_api_compat_proxy.py`; `../launch_frontend.sh`; `../launch_aggregate.sh`; `../qa_reasoning_api.sh`; K8s frontend wrapper blocks in `../agg1/*.yaml`, `../agg2/*.yaml`, and `../disagg/deploy.yaml` | Installed when `ENABLE_REASONING_API_PROXY=1` to `/opt/nemotron-ultra/reasoning_api_compat_proxy.py`. It is a standalone runtime component, not a diff applied to vLLM or Dynamo source. |

Do not look for a separate `04_*.patch` file: the reasoning API compatibility
fix is intentionally a script/component boundary. It is kept out of the vLLM
patch files because it does not modify the installed vLLM package.

