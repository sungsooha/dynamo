# syntax=docker/dockerfile:1.10.0
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Nemotron-3-Ultra TRT-LLM derived Dynamo image.
#
# This reproduces the phase-0 B200 bounded-reuse candidate. It expects a
# TensorRT-LLM wheel built by build_trtllm_wheel.sh and placed under:
#
#   trtllm/wheels/app_tensorrt_llm/tensorrt_llm-1.3.0rc15-cp312-cp312-linux_x86_64.whl
#
# Build from the Dynamo repo root after the wheel exists:
#
#   docker build \
#     -t nemotron-3-ultra-trtllm-turbo:dev \
#     -f recipes/turbo-recipes/nemotron-3-ultra/trtllm/Dockerfile \
#     recipes/turbo-recipes/nemotron-3-ultra/trtllm

ARG BASE_IMAGE=nvcr.io/nvidia/ai-dynamo/tensorrtllm-runtime:1.1.1
ARG DONOR_IMAGE=nemotron-ultra/trtllm-base501a580-pr14060-9c9cde-sm100:20260520
ARG TRTLLM_WHEEL=app_tensorrt_llm/tensorrt_llm-1.3.0rc15-cp312-cp312-linux_x86_64.whl

FROM ${DONOR_IMAGE} AS donor
FROM ${BASE_IMAGE}

ARG TRTLLM_WHEEL=app_tensorrt_llm/tensorrt_llm-1.3.0rc15-cp312-cp312-linux_x86_64.whl

USER root

# The PR #14060 TensorRT-LLM wheel imports newer dependency surfaces than the
# official Dynamo TRT runtime. Copy the exact dependency set from the TRT-LLM
# release image instead of pip-installing broad upgrades that churn torch/CUDA.
RUN rm -rf \
    /opt/dynamo/venv/lib/python3.12/site-packages/flashinfer \
    /opt/dynamo/venv/lib/python3.12/site-packages/flashinfer_python-*.dist-info \
    /opt/dynamo/venv/lib/python3.12/site-packages/transformers \
    /opt/dynamo/venv/lib/python3.12/site-packages/transformers-*.dist-info \
    /opt/dynamo/venv/lib/python3.12/site-packages/huggingface_hub \
    /opt/dynamo/venv/lib/python3.12/site-packages/huggingface_hub-*.dist-info \
    /opt/dynamo/venv/lib/python3.12/site-packages/mistral_common \
    /opt/dynamo/venv/lib/python3.12/site-packages/mistral_common-*.dist-info

COPY --from=donor /usr/local/lib/python3.12/dist-packages/flashinfer /opt/dynamo/venv/lib/python3.12/site-packages/flashinfer
COPY --from=donor /usr/local/lib/python3.12/dist-packages/flashinfer_python-0.6.11.post1.dist-info /opt/dynamo/venv/lib/python3.12/site-packages/flashinfer_python-0.6.11.post1.dist-info
COPY --from=donor /usr/local/bin/flashinfer /opt/dynamo/venv/bin/flashinfer
COPY --from=donor /usr/local/lib/python3.12/dist-packages/transformers /opt/dynamo/venv/lib/python3.12/site-packages/transformers
COPY --from=donor /usr/local/lib/python3.12/dist-packages/transformers-5.5.3.dist-info /opt/dynamo/venv/lib/python3.12/site-packages/transformers-5.5.3.dist-info
COPY --from=donor /usr/local/lib/python3.12/dist-packages/huggingface_hub /opt/dynamo/venv/lib/python3.12/site-packages/huggingface_hub
COPY --from=donor /usr/local/lib/python3.12/dist-packages/huggingface_hub-1.15.0.dist-info /opt/dynamo/venv/lib/python3.12/site-packages/huggingface_hub-1.15.0.dist-info
COPY --from=donor /usr/local/lib/python3.12/dist-packages/mistral_common /opt/dynamo/venv/lib/python3.12/site-packages/mistral_common
COPY --from=donor /usr/local/lib/python3.12/dist-packages/mistral_common-1.11.2.dist-info /opt/dynamo/venv/lib/python3.12/site-packages/mistral_common-1.11.2.dist-info

COPY wheels/${TRTLLM_WHEEL} /tmp/tensorrt_llm-1.3.0rc15-cp312-cp312-linux_x86_64.whl
RUN python3 -m pip install --force-reinstall --no-deps /tmp/tensorrt_llm-1.3.0rc15-cp312-cp312-linux_x86_64.whl \
 && python3 -m pip show tensorrt-llm flashinfer-python transformers \
 && python3 - <<'PY'
import importlib.metadata as metadata
import importlib.util
import transformers

if not hasattr(transformers, "ExaoneMoeConfig"):
    raise RuntimeError("transformers.ExaoneMoeConfig missing")

print("tensorrt-llm", metadata.version("tensorrt-llm"))
print("flashinfer-python", metadata.version("flashinfer-python"))
print("transformers", metadata.version("transformers"))
if importlib.util.find_spec("dynamo") is None:
    raise RuntimeError("dynamo module missing")
print("dynamo module present")
PY

COPY --chmod=755 \
  launch_frontend.sh \
  launch_prefill.sh \
  launch_decode.sh \
  /workspace/recipes/turbo-recipes/nemotron-3-ultra/trtllm/
COPY configs/ /workspace/recipes/turbo-recipes/nemotron-3-ultra/trtllm/configs/

USER dynamo
WORKDIR /workspace
ENTRYPOINT []
CMD ["bash"]
