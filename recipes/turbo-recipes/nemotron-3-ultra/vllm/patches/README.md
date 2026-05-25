<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Current vLLM Patch Status

The current Nemotron Ultra vLLM candidate is **Patch06+humming plus the MTP
DS-layout conv-tail copy diagnostic patch**.

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

The Dockerfile currently wraps the accepted pushed Patch06+humming image and
applies `ds_copy_diag_installed_vllm.patch` through
`scripts/apply_ds_copy_patch_in_container.py` instead of rebuilding the full
vLLM source stack. Use these patch files as source deltas if/when the recipe
gains a from-source vLLM rebuild path.

Recipe helper hashes captured for the handoff:

```text
scripts/apply_ds_copy_patch_in_container.py sha256:
  7f7acdc2ff05287e129cd608972b60899e70e1c30199aea8eccfc2ca1fadd309
scripts/ds_copy_selftest.py sha256:
  83e724f61d47033c626cd2a0a74bb8c31a42bad7a12309f0b70abb826f49686e
ds_copy_diag_installed_vllm.patch sha256:
  794e04517df6276a4568c6b97883fc57e87d6615ccf6a25728cdec458c7ff9a3
```
