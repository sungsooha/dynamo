<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# DeepSeek-V4 Reference Containers

Shared reference Dockerfiles for the DeepSeek-V4 family — used by both [`deepseek-v4-flash`](../deepseek-v4-flash/) and [`deepseek-v4-pro`](../deepseek-v4-pro/). Nothing in either image is recipe-specific; the model is selected at runtime via `--model-path` (SGLang).

| Backend | Dockerfile / script | Base image | Build flow |
|---------|-----------|-----------|------------|
| vLLM (CUDA 13 / DSV4) | [`vllm/build_dsv4_vllm_runtime.sh`](vllm/build_dsv4_vllm_runtime.sh) | `vllm/vllm-openai:nightly@sha256:284f3b942010553d2db3386ff6a0b1cc981cd1d3f653ca094fcfd8c4e3436e97` | Standard Dynamo vLLM runtime render plus opt-in DSV4 Flash MTP overlay |
| SGLang (B200)  | [`sglang/Dockerfile.dsv4.sglang.b200`](sglang/Dockerfile.dsv4.sglang.b200)   | `lmsysorg/sglang:deepseek-v4-blackwell` (digest-pinned, amd64)       | Two-stage; Dynamo runtime image as donor |
| SGLang (GB200) | [`sglang/Dockerfile.dsv4.sglang.gb200`](sglang/Dockerfile.dsv4.sglang.gb200) | `lmsysorg/sglang:deepseek-v4-grace-blackwell` (digest-pinned, arm64) | Two-stage; Dynamo runtime image as donor |

NVIDIA also publishes the prebuilt images for vLLM and SGLang which manifests pull directly:
- `nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.2.0-deepseek-v4-cuda13-dev.3` (multi-arch)
- `nvcr.io/nvidia/ai-dynamo/sglang-runtime:1.2.0-deepseek-v4-cuda13-dev.3` (arm64 only)
- `nvcr.io/nvidia/ai-dynamo/sglang-runtime:1.2.0-deepseek-v4-cuda12-dev.3` (amd64 only)

The `cudaXY` suffix encodes the CUDA major version baked into the image, not the hardware target.

## vLLM (`vllm/build_dsv4_vllm_runtime.sh`)

Use this path when a Dynamo runtime image must include the current vLLM CUDA 13
nightly NVFP4/Hopper support. The plain upstream image imports vLLM but does not
contain the Dynamo runtime package, so it cannot back a Dynamo DGD by itself.
This build starts from the same upstream vLLM nightly image, layers the standard
Dynamo runtime wheels/NIXL/NATS/ETCD through `container/render.py`, and applies
the DeepSeek-V4 Flash MTP BF16 projection overlay.

The current pinned upstream image is:

```text
image=vllm/vllm-openai:nightly@sha256:284f3b942010553d2db3386ff6a0b1cc981cd1d3f653ca094fcfd8c4e3436e97
tag_label=vllm/vllm-openai:nightly-3f5a1e1733200760169ff31ebe60a271072b199e
cuda=13.0
required_vllm_commit=3f5a1e1733200760169ff31ebe60a271072b199e
```

That image family contains the NVFP4 support needed for H100/H200/Hopper
preflights. Do not use the `cu129` variant for official Dynamo runtime builds.
The script default is `PLATFORM=linux/amd64`; if building arm64, use the
matching arm64 digest instead of the amd64 digest above.

### Build

From the **repo root**:

```bash
DOCKER_CMD="docker" \
TARGET_IMAGE="<your-registry>/dynamo-vllm-runtime:dsv4-cu130-nightly-3f5a1e173" \
PUSH=0 \
recipes/deepseek-v4/container/vllm/build_dsv4_vllm_runtime.sh
```

The script renders `container/rendered.Dockerfile` and builds the `runtime`
target with these DSV4-specific build args:

```text
RUNTIME_IMAGE=vllm/vllm-openai
RUNTIME_IMAGE_TAG=nightly@sha256:284f3b942010553d2db3386ff6a0b1cc981cd1d3f653ca094fcfd8c4e3436e97
DSV4_FLASH_MTP_BF16_PATCH=true
DSV4_EXPECT_VLLM_GIT_SHA=3f5a1e1733200760169ff31ebe60a271072b199e
```

The patch asset is copied from:

```text
container/deps/vllm/patches/deepseek-v4/flash_mtp_bf16_projection/mtp.py
```

and installed over:

```text
vllm/models/deepseek_v4/nvidia/mtp.py
```

Build-time validation checks:

- `import vllm` works.
- `import dynamo` works, proving this is a Dynamo runtime image rather than a
  plain vLLM image.
- the vLLM version string contains the expected nightly git SHA prefix.
- the installed `mtp.py` SHA256 is
  `1b599ddfe6f578c1e98551ceceead599e3cae24534427a84462143c6eac86f30`.
- the Flash-only BF16 projection markers are present.

The Flash MTP overlay is gated by `config.hidden_size == 4096`; Pro's 7168-wide
MTP path is intentionally untouched.

## SGLang (`sglang/Dockerfile.dsv4.sglang.b200`)

Two-stage build: a Dynamo SGLang runtime image as the donor (for nats / etcd / UCX / NIXL and the Dynamo wheels + Python source), layered onto the upstream SGLang dsv4 base.

### Step 1 — Build the Dynamo SGLang runtime

From the **repo root**:

```bash
container/render.py --framework sglang --target runtime --output-short-filename
docker build -t dynamo:latest-sglang-runtime -f container/rendered.Dockerfile .
```

This produces the local tag `dynamo:latest-sglang-runtime`, which Step 2 expects as `DYNAMO_SRC_IMAGE`. The donor must contain the V4 tool/reasoning parsers and the SGLang routed_experts fix; the build asserts on this with a post-install `assert 'deepseek_v4' in get_tool_parser_names()`.

See [`<repo_root>/container/README.md`](../../../container/README.md) for runtime-image build details and alternative tags.

### Step 2 — Build the dsv4 overlay

Still from the **repo root**:

```bash
docker build \
  -f recipes/deepseek-v4/container/sglang/Dockerfile.dsv4.sglang.b200 \
  -t <your-registry>/sglang-dsv4:<tag> \
  .
```

The Dockerfile takes nothing from the build context (everything comes from `FROM` / `COPY --from=`), so any context directory works.

### Build args

| Arg | Default | Purpose |
|-----|---------|---------|
| `DYNAMO_SRC_IMAGE` | `dynamo:latest-sglang-runtime` | Source for nats / etcd / UCX / NIXL and the V4-aware Dynamo wheels. Default matches Step 1; override with a published Dynamo SGLang runtime tag for reproducible builds without rebuilding locally. |
| `DSV4_BASE_IMAGE`  | `lmsysorg/sglang:deepseek-v4-blackwell@sha256:da2acdc8...` | The DeepSeek-V4 SGLang base. Digest-pinned for byte-stable rebuilds. |

### Wire into a recipe

Push:

```bash
docker push <your-registry>/sglang-dsv4:<tag>
```

Set the `image:` field (Frontend + decode worker) in the recipe's SGLang manifest, then follow the recipe's Quick Start:

- Flash → [`../deepseek-v4-flash/sglang/agg/deploy.yaml`](../deepseek-v4-flash/sglang/agg/deploy.yaml) — see [Quick Start](../deepseek-v4-flash/README.md#quick-start).
- Pro → [`../deepseek-v4-pro/sglang/agg/deploy.yaml`](../deepseek-v4-pro/sglang/agg/deploy.yaml) — see [Quick Start](../deepseek-v4-pro/README.md#quick-start).
