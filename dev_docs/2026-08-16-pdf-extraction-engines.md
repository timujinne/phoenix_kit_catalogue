# PDF text extraction engines (2026-08-16)

## Why

Extraction used to require poppler (`pdfinfo`/`pdftotext`) on the server.
A host ran for months with every extraction failing "pdfinfo not on PATH"
because the container never had poppler installed — and the failure only
lived in a DB column. Decision: extraction must work with **zero system
packages**, so the primary engine now ships with the app.

## The chain (`Catalogue.PdfEngines`)

1. **pdfium** via `ex_pdfium` — Chrome's PDF engine as a precompiled NIF
   (`rustler_precompiled` fetches the platform binary during `mix deps.get`).
2. **poppler** — used only when `pdftotext`/`pdfinfo` are on PATH; kept as
   the fallback for files pdfium cannot open and as the safety net on hosts
   that already have it.

`open_best/1` commits to the first engine that opens the document; per-page
failures after that keep the existing partial-result behavior. When every
engine refuses, the stored `error_message` lists each engine's reason. The
winning engine is recorded in the `pdf.extracted` activity metadata
(`"engine"` key).

## Benchmark (a host's corpus, 6 real PDFs)

Word recall vs `pdftotext -layout` (words = downcased alnum runs ≥ 3 chars —
the "would a part-number search hit" proxy). Harness + corpus lived in the
session scratchpad; rebuild it from this table's method if needed.

| PDF | pdfium | pdf_elixide | NEPU 0.8.0 (pure Elixir) |
|---|---|---|---|
| Dealroom 76p/32MB | 98.4% | 99.4% | refused (content stream) |
| Invoice 1p | 100% | 100% | 100% |
| PdfContainer_aspx 12p | 100% | 98.3% | refused (startxref) |
| REVEGO (Estonian) 84p | **99.8%** (2 words missed) | 91.2% (105 missed, incl. part-number-like digits) | refused (startxref) |
| State of AI 133p/116MB | scan — no text layer exists | same | refused (>25MB cap) |
| VauxLeVicomte 2p | 100% | 100% | 100% (more chars than poppler) |

pdfium won on the file that matters (missed digit-bearing tokens on REVEGO
would break part-number search under pdf_elixide). It was also fastest
(76-page report in 0.26s vs poppler's 4.3s).

Known trade-off: pdfium's core is C++ — a segfault would take the BEAM down
(pdf_elixide is memory-safe pure Rust but loses real content). Accepted
because uploads come from admins, and pdfium is Chrome-hardened. Revisit if
uploads ever become public.

## Future idea: `native_elixir_pdf_utilities` (pure Elixir)

Benchmarked at 100% recall on the 2/6 files it accepted — it even out-
extracted poppler on one — but it refused the rest: strict xref validation
(no salvage-by-scan for sloppy real-world files), a 25MB byte cap, and a
documented document-atomic font rule (one undecodable text string fails the
whole document, never partial output).

Parked because current releases require **Elixir ~> 1.19** (0.8.0 is the
last ~> 1.18 version) and the ecosystem is on 1.18. When the ecosystem
upgrades to 1.19+:

- consider adding it to the chain as a **verifier / third engine**, and
- consider contributing upstream (MIT, single maintainer, high test
  hygiene): a `lenient: true` extraction mode that skips undecodable spans
  and returns partial text + warnings, and/or xref-salvage for files with a
  broken final startxref. That would make it a genuine recall engine.

Scanned PDFs (the 133-page "State of AI" case) are beyond ANY engine —
that's the future OCR/vision-model story, tracked separately.
