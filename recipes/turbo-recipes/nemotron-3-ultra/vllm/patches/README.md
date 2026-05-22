<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Current vLLM Patch Status

The current Nemotron Ultra vLLM candidate is **Patch06+humming**.

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

This directory intentionally does not carry historical patch files. Those are
available from git history if needed.

`06_vllm_patch02_hash_block_event_port_after_pr42547.patch` is the current
Patch06 source delta. It was validated against the combined source stack above
with `git apply --check`, Python compile checks for the touched modules, and
marker checks for hash-block preservation, EngineCore metadata effective block
size, and FullAttention/TQFullAttention-only sub-block event emission.

The Dockerfile currently wraps the accepted pushed Patch06+humming image instead
of rebuilding the full vLLM source stack. Use this patch file as the source
delta if/when the recipe gains a from-source vLLM rebuild path.
