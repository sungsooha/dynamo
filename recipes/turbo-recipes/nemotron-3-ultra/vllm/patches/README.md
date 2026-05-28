<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Current vLLM Patch Status

The current Nemotron Ultra vLLM candidate is **Patch06+humming plus the MTP
DS-layout conv-tail copy diagnostic patch and the P/D SSM/NIXL tailfix**.

```text
vLLM main: 1c78f76c29a642379ad0ec953a77af9bc44376b6
PR #42554: 68dc38bcbac5004090939bbeb6bdcb9574379bb0
PR #42547: 477556a47a77b85ad1797419c1fa370c0fae83a1
Patch06: 06_vllm_patch02_hash_block_event_port_after_pr42547.patch
Patch06 sha256: 9ffec3b72951a305f23d943ea5a1eb5faff5077e665b58200247fef6d00dbd30
dependency: humming-kernels[cu13]==0.1.0
```

The accepted image is:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521
sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337
```

The accepted MTP diagnostic image is:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-patch06-humming-mtp-ds-copy-diag-20260523T164824Z
sha256:4c2e66ddd2610b9fbd84caffb0ae5663264322cfc29b9f22cf8be141f88d7cca
```

The accepted P/D SSM/NIXL tailfix image is:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-patch06-humming-mtp-ds-copy-ssm-tailfix-20260526T061806Z
sha256:b4a948fd7560ba072a46762bc026f1fefdac7ab276ed02798ffd1fc958a7cc3a
```

The accepted QA recipe image layers only the reasoning API compatibility proxy
on top of that validated tailfix image:

```text
nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-reasoning-api-validated-tailfix-20260528T070932Z
sha256:bfa2d02fd0dd1daab3fd41e4f2acfd8b131c44b49f0a4282937b5716e04fc265
```

`06_vllm_patch02_hash_block_event_port_after_pr42547.patch` is the current
Patch06 source delta. It was validated against the combined source stack above
with `git apply --check`, Python compile checks for the touched modules, and
marker checks for hash-block preservation, EngineCore metadata effective block
size, and FullAttention/TQFullAttention-only sub-block event emission.

`ds_copy_diag_installed_vllm.patch` is the installed-package MTP DS-copy patch
captured from the passing Helix diagnostic. It adds a DS-layout conv-tail copy
path for `mamba_cache_mode=align` plus prefix caching and
`--spec-method nemotron_h_mtp --spec-tokens 1`. This patch is directly
applicable to the Patch06+humming container package layout under
`/usr/local/lib/python3.12/dist-packages/vllm`; it is not yet a polished
source-tree patch.

`ssm_nixl_tailfix_installed_vllm.patch` is the installed-package P/D NIXL
tailfix captured from the passing local 1P1D+MTP1 tiny probe. It changes the
SSM branch in NIXL prefix-cache block alignment from a single-local-block
assertion to a tail-aligned remote SSM suffix. This branch is exercised by P/D
NIXL transfer, not by aggregate-only AGG1/AGG2 runs.

`scripts/reasoning_api_compat_proxy.py` is the explicit API compatibility
component for QA bugs 6230473, 6230496, and 6230578. It is deliberately kept
separate from vLLM Patch06, MTP DS-copy, and P/D SSM/NIXL tailfix work. The
proxy accepts only the owned top-level reasoning fields, maps them to already
validated backend controls, and adds reasoning-token accounting to responses.
It is enabled by `ENABLE_REASONING_API_PROXY=1`. In K8s, public port `8000`
terminates at the proxy and forwards to the inner Dynamo frontend on `8001`;
worker serve args and resources remain unchanged. Validate it with
`qa_reasoning_api.sh`.

The Dockerfile currently wraps the accepted pushed Patch06+humming image and
applies `ds_copy_diag_installed_vllm.patch` plus
`ssm_nixl_tailfix_installed_vllm.patch`, then installs the reasoning API proxy,
through feature-scoped installer steps instead of rebuilding the full vLLM or
Dynamo source stack. Use these patch files as source deltas if/when the recipe
gains a from-source rebuild path.

Recipe helper hashes captured for the handoff:

```text
scripts/apply_ds_copy_patch_in_container.py sha256:
  7f7acdc2ff05287e129cd608972b60899e70e1c30199aea8eccfc2ca1fadd309
scripts/apply_ssm_nixl_tailfix_in_container.py sha256:
  3ffd62b9ed809f3a213d78576fb6ce0826fa5a714714e25d5b2e4e75477b2f3f
scripts/ds_copy_selftest.py sha256:
  83e724f61d47033c626cd2a0a74bb8c31a42bad7a12309f0b70abb826f49686e
ds_copy_diag_installed_vllm.patch sha256:
  794e04517df6276a4568c6b97883fc57e87d6615ccf6a25728cdec458c7ff9a3
ssm_nixl_tailfix_installed_vllm.patch sha256:
  063492d3f89afc9669e6c38ba5e55677403470a54f843373900463e5a3d9d1d5
```

## Delivery Patch Boundaries

Keep final patches/components independently reviewable:

The exact file map is in `PATCH_BOUNDARIES.md`.

- `01_patch06_humming_base`: provenance only; already included in the base
  image documented by `../BASE_IMAGE_PROVENANCE.md`; source delta is
  `06_vllm_patch02_hash_block_event_port_after_pr42547.patch`.
- `02_vllm_mtp_ds_copy`: `ds_copy_diag_installed_vllm.patch` plus
  `scripts/apply_ds_copy_patch_in_container.py`.
- `03_vllm_pd_ssm_nixl_tailfix`: `ssm_nixl_tailfix_installed_vllm.patch` plus
  `scripts/apply_ssm_nixl_tailfix_in_container.py`.
- `04_dynamo_reasoning_api_compat_proxy`:
  `scripts/reasoning_api_compat_proxy.py` plus launch/QA wrapper plumbing.
  This is a standalone runtime component installed by the Dockerfile, not a
  patch applied to the vLLM package, so there is no separate `04_*.patch` file.

Do not combine rc8 porting changes with the old-base QA delivery image. rc8
startup, Patch06 re-adaptation, metakind, and router/admission parity remain a
separate porting project until they have their own clean gate evidence.
