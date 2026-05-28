<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# vLLM P/D Examples

These examples are reproducibility templates. Treat measured throughput as a
separate benchmark result, not as a property of the template itself.

## Local Direct-Docker 1P1D

Run one prefill TP4 worker and one decode TP4 worker on a single 8x B200 host.
The script starts etcd, the Dynamo frontend, one prefill container on GPUs 0-3,
and one decode container on GPUs 4-7. It waits for `/health`, verifies
`/v1/models`, and runs one short chat.

```bash
cd /path/to/dynamo

HOST_MODEL_PATH=/path/to/nemotron-ultra-ea-model-view \
IMAGE=nemotron-3-ultra-vllm-turbo:dev \
PREFILL_GPU_SET=0,1,2,3 \
DECODE_GPU_SET=4,5,6,7 \
MAX_MODEL_LEN=262144 \
MAX_NUM_SEQS=32 \
MAX_BATCHED_TOKENS=32768 \
BLOCK_SIZE=64 \
SPEC_METHOD=nemotron_h_mtp \
SPEC_TOKENS=1 \
ARTIFACT_ROOT=/tmp/nemotron-ultra/local-pd-1p1d-smoke \
KEEP_RUNNING=0 \
recipes/turbo-recipes/nemotron-3-ultra/vllm/disagg/local-pd-1p1d.sh
```

Set `KEEP_RUNNING=1` to leave the server up for a follow-up AIPerf command.
The script prints the cleanup command and writes exact Docker commands under
`$ARTIFACT_ROOT/commands/`.

## Kubernetes DGD 2P1D

Run two prefill TP4 replicas plus one decode TP4 replica through the DGD
template. This requires three clean 4-GPU B200 worker slots with RDMA.

```bash
cd /path/to/dynamo

NAMESPACE=<namespace>
DGD=recipes/turbo-recipes/nemotron-3-ultra/vllm/disagg/deploy.yaml
JOB=recipes/turbo-recipes/nemotron-3-ultra/vllm/aiperf/mooncake-swe-mtp1-pd2p1d-c20-job.yaml
DGD_NAME=ultra-vllm-p06h-mtp1-pd2p1d-swe30-c20
JOB_NAME=ultra-aiperf-mtp1-pd2p1d-swe30-c20

kubectl -n "${NAMESPACE}" apply --dry-run=server -f "${DGD}" -f "${JOB}" -o yaml \
  >/tmp/nemotron-ultra-pd2p1d.dryrun.yaml
kubectl -n "${NAMESPACE}" apply -f "${DGD}"
kubectl -n "${NAMESPACE}" wait --for=condition=Ready "dgd/${DGD_NAME}" --timeout=60m

# Run /health, /v1/models, and one short-chat smoke before submitting AIPerf.
kubectl -n "${NAMESPACE}" apply -f "${JOB}"
kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${JOB_NAME}" --timeout=8h
kubectl -n "${NAMESPACE}" logs "job/${JOB_NAME}"
kubectl -n "${NAMESPACE}" delete -f "${JOB}" -f "${DGD}" --ignore-not-found
```

The checked-in DGD uses the proxy-enabled tailfix image and MTP1 flags:

```bash
rg 'bfa2d02|reasoning-api-proxy|spec-method|spec-tokens|kv-transfer-config|disaggregation-mode' \
  recipes/turbo-recipes/nemotron-3-ultra/vllm/disagg/deploy.yaml
```

The public service remains on port `8000`; the reasoning API compatibility
proxy listens there and forwards to the inner Dynamo frontend on `8001`.
Prefill/decode worker commands, NIXL/UCX transfer args, and RDMA resources are
the P/D recipe contract and should not change for API compatibility.

Run only bounded probes first. The tailfix image has passed tiny long-context
1P1D and K8s 2P1D traffic, but the local 1P1D 30% SWE c20 run exposed very
high decode-side NIXL transfer latency. Treat full 30% P/D SWE as pending until
c1/r8 and c4/r64 transfer metrics are clean on the target topology.
