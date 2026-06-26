#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

DOCKER_CMD="${DOCKER_CMD:-docker}"
PLATFORM="${PLATFORM:-linux/amd64}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-vllm/vllm-openai}"
RUNTIME_IMAGE_TAG="${RUNTIME_IMAGE_TAG:-nightly@sha256:284f3b942010553d2db3386ff6a0b1cc981cd1d3f653ca094fcfd8c4e3436e97}"
VLLM_GIT_SHA="${VLLM_GIT_SHA:-3f5a1e1733200760169ff31ebe60a271072b199e}"
TARGET_IMAGE="${TARGET_IMAGE:-dynamo-vllm-runtime:dsv4-cu130-nightly}"
PUSH="${PUSH:-0}"
BUILD_TARGET="${BUILD_TARGET:-pre_runtime}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

cd "${REPO_ROOT}"

python3 container/render.py \
  --framework vllm \
  --device cuda \
  --cuda-version 13.0 \
  --target runtime \
  --platform "${PLATFORM}" \
  --output-short-filename

${DOCKER_CMD} build \
  --pull=false \
  --target "${BUILD_TARGET}" \
  --platform "${PLATFORM}" \
  -f container/rendered.Dockerfile \
  --build-arg "RUNTIME_IMAGE=${RUNTIME_IMAGE}" \
  --build-arg "RUNTIME_IMAGE_TAG=${RUNTIME_IMAGE_TAG}" \
  --build-arg "DSV4_FLASH_MTP_BF16_PATCH=true" \
  --build-arg "DSV4_EXPECT_VLLM_GIT_SHA=${VLLM_GIT_SHA}" \
  --build-arg "DYNAMO_COMMIT_SHA=$(git rev-parse HEAD)" \
  -t "${TARGET_IMAGE}" \
  .

${DOCKER_CMD} run --rm -i \
  --entrypoint=python3 \
  -e PYTHONPYCACHEPREFIX=/tmp/pycache \
  "${TARGET_IMAGE}" - <<'PY'
import hashlib
import importlib
import importlib.metadata as metadata
import importlib.util
from pathlib import Path
import py_compile

importlib.import_module("dynamo")
importlib.import_module("dynamo.vllm")

spec = importlib.util.find_spec("vllm")
if spec is None or not spec.submodule_search_locations:
    raise SystemExit("vllm package not found")

path = (
    Path(next(iter(spec.submodule_search_locations)))
    / "models"
    / "deepseek_v4"
    / "nvidia"
    / "mtp.py"
)
py_compile.compile(str(path), doraise=True)
print(f"vllm_version={metadata.version('vllm')}")
print(f"patch_file={path}")
print(f"patch_sha256={hashlib.sha256(path.read_bytes()).hexdigest()}")
print("dynamo_import=ok")
print("dynamo_vllm_import=ok")
PY

if [[ "${PUSH}" == "1" ]]; then
  ${DOCKER_CMD} push "${TARGET_IMAGE}"
fi

echo "TARGET_IMAGE=${TARGET_IMAGE}"
echo "BUILD_TARGET=${BUILD_TARGET}"
