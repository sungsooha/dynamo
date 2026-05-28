<!--
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Promotion Gate

This gate applies to the old validated Patch06+humming recipe image with the
reasoning API compatibility proxy. Passing the API matrix alone is not enough
to hand the recipe to QA as final.

## Required Evidence

All evidence must be produced through recipe entry points, with generated
commands and cleanup artifacts retained.

1. Reasoning API QA:
   - Run `qa_reasoning_api.sh all`.
   - Prefer the validated tailfix image as `BASE_IMAGE`, with
     `APPLY_MTP_DS_COPY_PATCH=0`, `APPLY_SSM_NIXL_TAILFIX_PATCH=0`, and
     `ENABLE_REASONING_API_PROXY=1`, when the goal is testing only the API
     compatibility fix.
   - Bugs 6230473, 6230496, and 6230578 must pass.
   - Preserve raw request/response bodies, `reasoning_api_matrix.json`,
     `qa_ticket_summary.json`, `run_status.json`, `run_config.json`,
     `generated_commands.json`, `manifest.tsv`, and cleanup evidence.

2. Recipe-driven end-to-end test:
   - Build or pull the recipe image from this directory.
   - Launch through `launch_aggregate.sh` via the recipe wrapper.
   - Pass `/health`, `/v1/models`, exact short chat, workload execution,
     artifact collection, and cleanup.

3. Full GSM8K:
   - vLLM framework baseline.
   - Dynamo aggregate without MTP.
   - Dynamo aggregate with MTP.
   - KV-aware routing disabled.
   - KV-aware routing enabled.
   - Keep MTP accuracy within the previously accepted tolerance unless the
     controller explicitly changes the threshold.

4. Comparable benchmark reproduction:
   - Reproduce a comparable 30% Moontrace row for the accepted recipe shape.
   - Preserve cache/router evidence, AIPerf profile export, normalized metrics,
     server logs, generated commands, and cleanup proof.
   - Benchmark traffic should use the inner Dynamo endpoint when the reasoning
     proxy is enabled, so the row measures the model/router path rather than
     proxy overhead. API compatibility is validated separately by the QA matrix.

## Parallel Execution

When an 8-GPU reserved node is available, independent lanes should run in
parallel on disjoint GPU sets, ports, container names, and artifact roots. A
typical split is GPUs `0,1,2,3` for one TP4 lane and GPUs `4,5,6,7` for another.

Do not run concurrent lanes that share:

- the same server port,
- the same etcd ports,
- the same artifact root,
- the same container names,
- the same GPU set,
- or mutable model/cache directories.

## Non-Promotion Evidence

`ENFORCE_EAGER=1` evidence is diagnostic-only. It cannot satisfy QA, GSM8K, or
benchmark promotion gates unless it is explicitly marked and requested as a
debug isolation run.

Dynamo `1.2.0` rc8 porting evidence is also separate. Do not combine rc8
Patch06 re-adaptation, metakind, or router/admission parity diagnostics with
this old-base delivery gate.
