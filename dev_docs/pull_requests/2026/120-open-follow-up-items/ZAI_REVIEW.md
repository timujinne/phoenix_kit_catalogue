# PR #120: Fix the open items from the #108, #109, #113 and #118 follow-ups — Zai review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/120
**Reviewer**: Zai (GLM-5.3), from the diffs of catalogue `c651dcc` and ecommerce `b5abf0b` plus a written brief, no test runs
**Date**: 2026-09-15

Both commits verified against the working trees in this workspace (catalogue `c651dcc`, ecommerce `b5abf0b`). Areas checked and sound:

- **Item category-facts reuse** (`catalogue.ex:5128,5351`) — tuple plumbed at both call sites; uuid mismatch falls back to a fresh FOR SHARE read; same-transaction lock means no check lost and no stale facts.
- **Refusal error keys** (`catalogue.ex:5264,5267`) — both the trashed and the foreign-category refusals are keyed `:category_uuid`, so the ecommerce matcher covers exactly the two claimed cases.
- **`ancestors_first`** (`catalogue.ex:6048`) — one parent-links read taken under the catalogue locks; depth sort ≡ old ancestor-count sort; cycle-guarded; unknown uuids sort at 0 and are skipped by the step.
- **`value_slug`** (`attribute_sets.ex:518`) — taken = live + archived + trashed (`list_hidden_values_for/1` verified); a new value can't share a selection key with a hidden one.
- **`filter_options`** (`attribute_sets.ex:1387`) — archived sets dropped (index `:all` too, matching intent); a stale URL selection degrades safely in `attribute_filter` (no crash, "Clear filters" still offered).
- **Delete attribute** (`attributes.ex:354`, form LV else-order) — `:not_found` reloads, other refusals flash; both msgids in the catalogue.
- **Root Deleted tab** — the skipped listing was already replaced by `root_trash_categories`; `{%{}, %{}}` is fully overwritten by `trash_unit_counts` for every card key, so `sort_categories` and the card badges see identical values; `children_with_subs` still read.
- **Drilled counts** — `level_children_counts` runs exactly the two queries `level_tab_counts` used to; `cat_mode` is an atom (`view_mode_to_atom`), so the `%^cat_mode` pin reuses the right map; root Active still queries its own subcat map.
- **Root Active tree from root_tree** — Category status is only `active|deleted` (schema `@statuses`), so `reject(deleted)` ≡ `mode: :active`; root_tree's global `(position, name)` order preserves the old per-group order; orphan-promotion rule identical; `%{category | parent_uuid: nil}` copies don't alias the rows `trash_unit_counts` already consumed.
- **"(archived)" markers** (modal, product card) — display-only consumers of `label`; `values`/`hidden_values` disjoint; no nil-input crashes (`hidden_values` default, empty selection lists guarded).
- **Ecommerce skip** (`collection_sync.ex:437`) — changeset clause ordered before `{:error, reason}`; non-category changeset errors and client errors still halt; position-only repositions never reach the check; the mid-run-trash test exists (`collection_sync_test.exs:437`).
- **Gettext plumbing** — all three msgids present in `default.pot` + all five locales; ru/et translated and pinned (`gettext_test.exs:879`).

**Findings:**

1. `phoenix_kit_catalogue/priv/gettext/{de,fr}/LC_MESSAGES/default.po:1363,3462,3465` — any admin using de/fr after this commit: the renamed tooltip, the delete flash and the "(archived)" suffix render in English (empty msgstrs) while ru/et/en are translated. Commit message says "every locale" for the rename; expected translated, actual fallback-to-msgid. Possibly accepted (the pin test covers ru/et only) — if so, ignore.
