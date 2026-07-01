#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

DOCKER_CMD="${DOCKER_CMD:-docker}"
PLATFORM="${PLATFORM:-linux/amd64}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-vllm/vllm-openai}"
RUNTIME_IMAGE_TAG="${RUNTIME_IMAGE_TAG:-v0.24.0-ubuntu2404@sha256:9c3197280522a02d62f60595a138361a26b1cc01cee13991828d6e6cf2416588}"
VLLM_GIT_SHA="${VLLM_GIT_SHA:-ee0da84ab9e04ac7610e28580af62c365e898389}"
VLLM_VERSION="${VLLM_VERSION:-0.24.0}"
TARGET_IMAGE="${TARGET_IMAGE:-nvcr.io/nvstaging/nim/sungsooh:dsv4-dynamo-vllm-cu130-v0240-ee0da84a-ubuntu2404-flashmtp-20260701}"
PUSH="${PUSH:-0}"
BUILD_TARGET="${BUILD_TARGET:-runtime}"
DSV4_FLASH_MTP_BF16_PATCH="${DSV4_FLASH_MTP_BF16_PATCH:-true}"
DSV4_PER_RANK_NIC_PATCH="${DSV4_PER_RANK_NIC_PATCH:-false}"
DSV4_PACKED_KV_RDMA_PATCH="${DSV4_PACKED_KV_RDMA_PATCH:-false}"
DSV4_DSPARK_PR46995_PATCH="${DSV4_DSPARK_PR46995_PATCH:-false}"
DSV4_EXPECT_FLASH_MTP_SHA256="${DSV4_EXPECT_FLASH_MTP_SHA256:-4fd6a700a77ef920ccf0da42a258edf273fdfd5671e68e6a0adbfbe6d5582e3d}"
DSV4_EXPECT_PER_RANK_NIC_BASE_SHA256="${DSV4_EXPECT_PER_RANK_NIC_BASE_SHA256:-d459c858e5bd4cfcb73be441cfefa6529d1c14def8a64314eb9dce8fde629878}"
DSV4_EXPECT_PER_RANK_NIC_SHA256="${DSV4_EXPECT_PER_RANK_NIC_SHA256:-2a5080698a240db2fc51ac37821eeae7dc18fbd9fcbfec40c4ba779041fa5b5b}"

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
  --build-arg "DSV4_FLASH_MTP_BF16_PATCH=${DSV4_FLASH_MTP_BF16_PATCH}" \
  --build-arg "DSV4_PER_RANK_NIC_PATCH=${DSV4_PER_RANK_NIC_PATCH}" \
  --build-arg "DSV4_EXPECT_VLLM_GIT_SHA=${VLLM_GIT_SHA}" \
  --build-arg "DSV4_EXPECT_VLLM_VERSION=${VLLM_VERSION}" \
  --build-arg "DSV4_EXPECT_FLASH_MTP_SHA256=${DSV4_EXPECT_FLASH_MTP_SHA256}" \
  --build-arg "DSV4_EXPECT_PER_RANK_NIC_BASE_SHA256=${DSV4_EXPECT_PER_RANK_NIC_BASE_SHA256}" \
  --build-arg "DSV4_EXPECT_PER_RANK_NIC_SHA256=${DSV4_EXPECT_PER_RANK_NIC_SHA256}" \
  --build-arg "DYNAMO_COMMIT_SHA=$(git rev-parse HEAD)" \
  -t "${TARGET_IMAGE}" \
  .

${DOCKER_CMD} run --rm -i \
  --entrypoint=python3 \
  -e PYTHONPYCACHEPREFIX=/tmp/pycache \
  -e DSV4_FLASH_MTP_BF16_PATCH="${DSV4_FLASH_MTP_BF16_PATCH}" \
  -e DSV4_PER_RANK_NIC_PATCH="${DSV4_PER_RANK_NIC_PATCH}" \
  -e DSV4_EXPECT_VLLM_VERSION="${VLLM_VERSION}" \
  -e DSV4_EXPECT_FLASH_MTP_SHA256="${DSV4_EXPECT_FLASH_MTP_SHA256}" \
  -e DSV4_EXPECT_PER_RANK_NIC_SHA256="${DSV4_EXPECT_PER_RANK_NIC_SHA256}" \
  "${TARGET_IMAGE}" - <<'PY'
import os
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
if os.environ["DSV4_FLASH_MTP_BF16_PATCH"] == "true":
    mtp_sha = hashlib.sha256(path.read_bytes()).hexdigest()
    expected_mtp_sha = os.environ["DSV4_EXPECT_FLASH_MTP_SHA256"]
    if mtp_sha != expected_mtp_sha:
        raise SystemExit(
            f"unexpected Flash MTP patch sha: actual={mtp_sha} expected={expected_mtp_sha}"
        )

base_worker = (
    Path(next(iter(spec.submodule_search_locations)))
    / "distributed"
    / "kv_transfer"
    / "kv_connector"
    / "v1"
    / "nixl"
    / "base_worker.py"
)
py_compile.compile(str(base_worker), doraise=True)
if os.environ["DSV4_PER_RANK_NIC_PATCH"] == "true":
    base_worker_sha = hashlib.sha256(base_worker.read_bytes()).hexdigest()
    expected_base_worker_sha = os.environ["DSV4_EXPECT_PER_RANK_NIC_SHA256"]
    if base_worker_sha != expected_base_worker_sha:
        raise SystemExit(
            "unexpected per-rank NIC base_worker.py sha: "
            f"actual={base_worker_sha} expected={expected_base_worker_sha}"
        )
print(f"vllm_version={metadata.version('vllm')}")
expected_vllm_version = os.environ["DSV4_EXPECT_VLLM_VERSION"]
if expected_vllm_version and metadata.version("vllm") != expected_vllm_version:
    raise SystemExit(
        "unexpected vLLM version: "
        f"actual={metadata.version('vllm')} expected={expected_vllm_version}"
    )
print(f"mtp_file={path}")
print(f"mtp_sha256={hashlib.sha256(path.read_bytes()).hexdigest()}")
print(f"base_worker_file={base_worker}")
print(f"base_worker_sha256={hashlib.sha256(base_worker.read_bytes()).hexdigest()}")
print("dynamo_import=ok")
print("dynamo_vllm_import=ok")
PY

if [[ "${PUSH}" == "1" ]]; then
  ${DOCKER_CMD} push "${TARGET_IMAGE}"
fi

echo "TARGET_IMAGE=${TARGET_IMAGE}"
echo "BUILD_TARGET=${BUILD_TARGET}"
echo "VLLM_VERSION=${VLLM_VERSION}"
echo "DSV4_FLASH_MTP_BF16_PATCH=${DSV4_FLASH_MTP_BF16_PATCH}"
echo "DSV4_PER_RANK_NIC_PATCH=${DSV4_PER_RANK_NIC_PATCH}"
echo "DSV4_PACKED_KV_RDMA_PATCH=${DSV4_PACKED_KV_RDMA_PATCH}"
echo "DSV4_DSPARK_PR46995_PATCH=${DSV4_DSPARK_PR46995_PATCH}"
