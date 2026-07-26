# Nemotron Ultra runtime validator provenance

This test-only validator was imported verbatim from
`upstream/release/1.3.0-nemotron-ultra-dev.1@dd735a0c0848`, source path
`container/deps/vllm/validate_nemotron_ultra_runtime.py`.

Source file SHA-256: `f248466be3b4609dcbbaf42a25f25765cb3601c37f9ec7ddda51fa95f3338037`.

It is intentionally stored under `tests/validation/`; no Dockerfile or runtime
build context may copy it into the shipping image. It is a build-validation
input used to reveal upstream/patch-marker coverage before shipping.
