# Muse Glimmer nospec AGG delivery overlays

Ordered overlays for the B200 SGLang delivery image based on
`lmsysorg/sglang@sha256:f95b4ba28b5c4f6f01fa3c3510c33fd35fe32a360fae7231460c4f2248185561`.

1. `0002-dynamo-sglang-fpm-late-resolution.patch`
   (`sha256:da684c2d983ba35512c31d678549d2fda5868b1d5c8909998feb56e31402bb37`)
   is a pending-upstream Dynamo overlay for FPM-on worker initialization.
2. `0005-dynamo-sglang-response-format-skip-muse-reasoning.patch`
   (`sha256:01ec98a7e047291b866f800fa8d19eca5780895ea6cc4145c299986c45eae342`)
   is a pending-upstream Dynamo overlay for Muse structured-output correctness.

`0004` is omitted: its `seq_lens_cpu` fallback is present on current SGLang
main, but the pinned preview does not have it and nospec AGG does not exercise
the FPM + DP-Attention + Mixed-Chunk failure path. `0006` is omitted because it
is DFLASH draft-alias logic and nospec AGG does not configure a draft.
