# Nemotron Ultra vLLM v0.26.0 overlay provenance

This directory is the build-context location for the Nemotron Ultra runtime
overlays. It is not copied into the final runtime image except for the four
explicit Python files selected by the runtime Dockerfile.

## Base image

- Source tag: `vllm/vllm-openai:v0.26.0`
- vLLM source: `v0.26.0@f2654939e69b4069b13977e9aef3e31d4dcaf051`
- OCI manifest-list/index digest:
  `sha256:ffb2d59b1c059a5bd8d781320c9f5189de8293693b7d95da54befddaa54abf52`
- Linux amd64 child digest (the x86_64 Docker build input):
  `sha256:770fe65b2c73ee74a5c42165cf3433de4048cc2cd9c57a937ca4e35aba5aa87b`

The index and child digest have distinct roles and must never be conflated.
The Docker `FROM` reference for the reserved x86_64 build pins the amd64 child.

## Overlay stack

The only runtime overlays are the re-anchored, Python-only patch stack
`{0001-align, 0003-L4, 0005-B4}` from
`runs/nemotron-3-ultra/donly-delivery/v0260-reanchored/`.

The exact base and post-overlay file SHA-256 values are recorded in
`HANDOFF-v0.26.0-reanchor.md`. The build must verify all four installed file
hashes before any G0 serve smoke.

## Status

Framework compatibility is an empirical G0 decision and is currently held
pending explicit authorization. This provenance document does not authorize a
container build, registry push, or release.
