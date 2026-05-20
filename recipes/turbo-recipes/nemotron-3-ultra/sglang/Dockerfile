# syntax=docker/dockerfile:1.10.0
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Nemotron-3-Ultra SGLang Dynamo image.
#
# This reproduces the B200 SGLang image that passed TP4/EP4 1P+1D smoke.
#
# Important: this Dockerfile does not apply a source-code patch to SGLang.
# It is an image-composition patch:
#
#   1. Use the SGLang nightly image that can run Nemotron Ultra with the
#      FlashInfer TRTLLM MoE path.
#   2. Copy Dynamo runtime pieces from the Dynamo SGLang dev.3 image so the
#      same SGLang runtime can be launched through `python3 -m dynamo.sglang`.
#
# The stock Dynamo SGLang dev.3 image had the Dynamo integration but did not
# have the working Ultra SGLang runtime path. The standalone SGLang nightly had
# the working Ultra runtime path but not the needed Dynamo runtime/discovery/
# transfer overlay. This image combines those two pieces.
#
# Build from the Dynamo repo root:
#
#   docker build \
#     -t nemotron-3-ultra-sglang-turbo:dev \
#     -f recipes/turbo-recipes/nemotron-3-ultra/sglang/Dockerfile \
#     recipes/turbo-recipes/nemotron-3-ultra/sglang
#
# Passing image pushed during phase-0:
#
#   nvcr.io/nvstaging/nim/sungsooh:nemotron-ultra-dynamo-sglang-1.2.0-dev3-sglang-nightly-cu13-20260519-dbac4647-flashinfer-trtllm
#   sha256:11d2cc443a92250e9127f489ded01dbb370d9b25f4360a5a7008ded6225a66e9

ARG DYNAMO_SRC_IMAGE=nvcr.io/nvidia/ai-dynamo/sglang-runtime:1.2.0-deepseek-v4-cuda12-dev.3
ARG SGLANG_BASE_IMAGE=lmsysorg/sglang:nightly-dev-cu13-20260519-dbac4647

FROM ${DYNAMO_SRC_IMAGE} AS dynamo_src
FROM ${SGLANG_BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# The SGLang nightly already carries the working Nemotron-H / FlashInfer TRTLLM
# path. Bring in Dynamo runtime, discovery, and transfer dependencies from the
# Dynamo dev.3 runtime image. These COPY/RUN steps are the "patch" for this
# image: they add Dynamo integration to the working SGLang runtime without
# modifying SGLang source files.
RUN pip uninstall -y black termplotlib || true

COPY --from=dynamo_src /usr/bin/nats-server /usr/bin/nats-server
COPY --from=dynamo_src /usr/local/bin/etcd /usr/local/bin/etcd
ENV PATH=/usr/local/bin/etcd:${PATH}

COPY --from=dynamo_src /usr/lib/x86_64-linux-gnu/ucx /usr/lib/x86_64-linux-gnu/ucx
COPY --from=dynamo_src /usr/lib/x86_64-linux-gnu/libuc*.so* /usr/lib/x86_64-linux-gnu/
COPY --from=dynamo_src /usr/local/lib/python3.12/dist-packages/nixl* /usr/local/lib/python3.12/dist-packages/

COPY --from=dynamo_src /opt/dynamo/wheelhouse /opt/dynamo/wheelhouse
RUN pip install --no-cache-dir --force-reinstall --no-deps \
    /opt/dynamo/wheelhouse/ai_dynamo_runtime*.whl \
    /opt/dynamo/wheelhouse/ai_dynamo-*.whl

COPY --from=dynamo_src /workspace/components/src/dynamo /workspace/components/src/dynamo
COPY --from=dynamo_src /workspace/ATTRIBUTIONS-Python.md /workspace/ATTRIBUTIONS-Rust.md /workspace/ATTRIBUTIONS.md /workspace/

# Avoid /workspace/sglang shadowing the Dynamo Python package while keeping
# source-tree SGLang imports available when the base image carries them.
ENV PYTHONPATH=/workspace/sglang/python:/workspace/components/src

ENV SGLANG_JIT_DEEPGEMM_PRECOMPILE=0 \
    SGLANG_JIT_DEEPGEMM_FAST_WARMUP=1

RUN python3 - <<'PY'
import importlib
import importlib.util
import json

rows = []
for module in ("dynamo", "sglang"):
    mod = importlib.import_module(module)
    rows.append({"module": module, "file": getattr(mod, "__file__", None)})
rows.append({
    "module": "mamba_ssm",
    "required_for_build_probe": False,
    "present": importlib.util.find_spec("mamba_ssm") is not None,
})
try:
    from dynamo._core import get_tool_parser_names

    rows.append({"dynamo_tool_parsers": sorted(get_tool_parser_names())})
except Exception as exc:
    rows.append({"dynamo_tool_parser_probe_error": f"{type(exc).__name__}: {exc}"})
try:
    from dynamo._core import get_reasoning_parser_names

    rows.append({"dynamo_reasoning_parsers": sorted(get_reasoning_parser_names())})
except Exception as exc:
    rows.append({"dynamo_reasoning_parser_probe_error": f"{type(exc).__name__}: {exc}"})
for row in rows:
    print(json.dumps(row, sort_keys=True))
PY

COPY --chmod=755 \
  launch_frontend.sh \
  launch_prefill.sh \
  launch_decode.sh \
  /workspace/recipes/turbo-recipes/nemotron-3-ultra/sglang/

WORKDIR /workspace
ENTRYPOINT []
CMD ["bash"]
