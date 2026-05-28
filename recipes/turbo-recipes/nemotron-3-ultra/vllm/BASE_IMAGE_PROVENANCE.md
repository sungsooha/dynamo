<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Base Image Provenance

This file records how the old validated Nemotron Ultra vLLM base image was
created. The QA delivery Dockerfile in this directory starts from this base and
does not use the Dynamo `1.2.0` rc8 runtime image by default.

## Final Base

```text
tag: nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521
digest: sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337
```

The recipe Dockerfile consumes it as:

```dockerfile
ARG BASE_IMAGE="nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521@sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337"
```

## Ancestry

The image was produced in stages:

1. Build a local Dynamo vLLM 0.21.0 runtime base from the Dynamo container
   renderer.
2. Overlay the upstream-reduced vLLM source stack plus Patch06 onto that
   installed runtime.
3. Install the missing CUDA dependency `humming-kernels[cu13]==0.1.0`.
4. Tag and push the resulting image to NVCR staging.
5. Layer recipe-local installed-package patches on top in this directory.

The earlier local runtime base was generated from Dynamo source with:

```text
ai-dynamo/dynamo commit: df6649150dcec1fe3d17a49bd3007b2a96c18ee8
render command: python3 container/render.py --framework vllm --target runtime --cuda-version 13.0 --platform linux/amd64 --output-short-filename
runtime stage base: vllm/vllm-openai:v0.21.0
local tag: nemotron-ultra/dynamo-vllm-pr9669-base:20260519-vllm0.21.0
```

Docker history for that rendered base showed installation of:

```text
/opt/dynamo/wheelhouse/ai_dynamo_runtime*.whl
/opt/dynamo/wheelhouse/ai_dynamo*any.whl
```

and copied Dynamo source directories into `/workspace`. Patch06+humming did not
rebuild Dynamo again; it overlaid vLLM Python sources on top of this runtime.

## Patch06 Source Stack

Patch06 was based on:

```text
vLLM main: 1c78f76c29a642379ad0ec953a77af9bc44376b6
PR #42554: 68dc38bcbac5004090939bbeb6bdcb9574379bb0
PR #42547: 477556a47a77b85ad1797419c1fa370c0fae83a1
combined source sha: 2cf6db15afa4d2fa2f2016f4d1970b77360139c1
Patch06 file: patches/06_vllm_patch02_hash_block_event_port_after_pr42547.patch
Patch06 sha256: 9ffec3b72951a305f23d943ea5a1eb5faff5077e665b58200247fef6d00dbd30
```

Artifact roots from the original staging:

```text
upstream patch dry run:
  /home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_v2_1_vllm_upstream_patch_dryrun_20260521T181341Z
Patch06 implementation:
  /home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_v2_1_vllm_patch02_port_impl_20260521T183338Z
```

Patch06 preserved the request hash-block size before Ultra hybrid physical block
inflation, reported effective hash block size through EngineCore metadata, and
emitted FullAttention/TQFullAttention KV events at hash-block granularity.

## Python Overlay Build

The non-humming Patch06 image was:

```text
artifact: /home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_v2_1_vllm_gate4_image_probe_20260521T183954Z
image: nemotron-ultra/vllm-upstream-pd-mamba-patch06:20260521
image id: sha256:dc0e017d2543f088a6aa5c18202d82e28b4e0499e588516c668aa1118ebdb5b2
base image: nemotron-ultra/dynamo-vllm-pr9669-base:20260519-vllm0.21.0
build mode: capability_only_python_overlay_on_unpatched_dynamo_vllm_base
```

The build copied the patched `vllm/` Python package into the installed package
location:

```dockerfile
COPY vllm/ /tmp/vllm-upstream-overlay/vllm/
RUN python3 - <<'PY'
import pathlib
import shutil
import vllm

site_parent = pathlib.Path(vllm.__file__).resolve().parent.parent
target = site_parent / "vllm"
overlay = pathlib.Path("/tmp/vllm-upstream-overlay/vllm")
shutil.copytree(overlay, target, dirs_exist_ok=True)
PY
```

This was an installed-package Python overlay, not a full vLLM wheel rebuild.

## Humming Dependency Layer

The final local humming image added exactly one dependency layer:

```text
artifact: /home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_v2_1_vllm_gate5_1_humming_dependency_20260521T190029Z
base image: nemotron-ultra/vllm-upstream-pd-mamba-patch06:20260521
base image id: sha256:dc0e017d2543f088a6aa5c18202d82e28b4e0499e588516c668aa1118ebdb5b2
candidate image: nemotron-ultra/vllm-upstream-pd-mamba-patch06-humming:20260521
candidate image id: sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337
dependency: humming-kernels[cu13]==0.1.0
wheel sha256: 9a9f00d357e8e8ef25b5568b80389339db62ef201e6e3700b2717a7747a20563
```

Layer Dockerfile:

```dockerfile
FROM nemotron-ultra/vllm-upstream-pd-mamba-patch06:20260521
RUN python3 -m pip install --no-cache-dir 'humming-kernels[cu13]==0.1.0'
```

## NVCR Push

The local humming image was pushed by:

```text
script: /Users/sungsooh/Workspace/work-tracker/nim/nemotron-ultra/tmp/gate62/push_patch06_humming.sh
artifact: /home/scratch.sungsooh_coreai/nemotron-ultra/artifacts/ultra_v2_1_vllm_patch06_humming_image_push_nvcr_20260522T000254Z
source image: nemotron-ultra/vllm-upstream-pd-mamba-patch06-humming:20260521
expected source image id: sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337
pushed tag: nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-upstream-pd-mamba-patch06-humming-20260521
pushed digest: sha256:23aca0f5c5a332e5ddd69899ed2026cdf7abee5c28a4f2b96d54915e2211a337
```

The push script verified the exact local image ID before tagging and pushing.

## Recipe Wrapper Layers

This directory then adds the recipe-local layers:

```text
APPLY_MTP_DS_COPY_PATCH=1
APPLY_SSM_NIXL_TAILFIX_PATCH=1
ENABLE_REASONING_API_PROXY=1
```

Related pushed images:

```text
MTP DS-copy diagnostic:
  nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-patch06-humming-mtp-ds-copy-diag-20260523T164824Z
  sha256:4c2e66ddd2610b9fbd84caffb0ae5663264322cfc29b9f22cf8be141f88d7cca

P/D SSM/NIXL tailfix:
  nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-patch06-humming-mtp-ds-copy-ssm-tailfix-20260526T061806Z
  sha256:b4a948fd7560ba072a46762bc026f1fefdac7ab276ed02798ffd1fc958a7cc3a

Reasoning API QA image:
  nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-vllm-reasoning-api-validated-tailfix-20260528T070932Z
  sha256:bfa2d02fd0dd1daab3fd41e4f2acfd8b131c44b49f0a4282937b5716e04fc265
```

The reasoning API image did not rebuild Dynamo or vLLM. It starts from the
validated P/D SSM/NIXL tailfix image, installs
`scripts/reasoning_api_compat_proxy.py`, and labels the image with
`nemotron-ultra.recipe.reasoning_api_proxy=1`.
