# PR 34 follow-up — Move AI translation into the plugin

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

- ~~**BLOCKING:** `main` did not compile against the published
  `phoenix_kit_ai` — 0.3.0 lacked the pipeline the merged code called.~~
  `mix.exs:100` now declares `pk_dep(:phoenix_kit_ai, "~> 0.18")` with the
  lock at 0.19.2.
- ~~**MEDIUM:** the CHANGELOG understated the real `phoenix_kit_ai` floor.~~
  The constraint floor is `~> 0.18`, well past the release that carries the
  pipeline.

## Open

- **MINOR (still live): `pk_dep/3` treats an exported-but-empty `<APP>_PATH`
  as a path override.** `mix.exs:80-84` matches only `nil`, so an exported
  but empty variable — the usual result of `export PHOENIX_KIT_PATH=` or a
  cleared shell var — falls into the `path ->` clause and yields
  `{app, [path: "", override: true]}`, i.e. a dependency pointed at the empty
  path rather than at Hex. Flagged by the review as minor and left; still
  true. The fix is one guard (`path when is_binary(path) and path != ""`),
  but it is shared boilerplate across every module in the ecosystem, so it
  wants doing everywhere at once rather than here alone.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
