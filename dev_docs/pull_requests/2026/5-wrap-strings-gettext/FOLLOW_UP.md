# Follow-up Items for PR #5

Triaged against `main` on 2026-04-26. Three reviews on file (CLAUDE,
MISTRAL, PINCER); MISTRAL and PINCER both verdict "Approve / Ready to
merge" with no actionable findings. Actionable findings come from
CLAUDE_REVIEW only.

## Fixed (pre-existing)

- ~~**#2a** "Description" field label not wrapped (manufacturer +
  supplier forms)~~ — wrapped in PRs #11/#12. Verified at
  `manufacturer_form_live.ex:195`, `supplier_form_live.ex:195`,
  `catalogue_form_live.ex:396`, `category_form_live.ex:419`,
  `item_form_live.ex:725`.
- ~~**#2b** Association toggle hint text~~ — wrapped. Verified at
  `manufacturer_form_live.ex:264` and `supplier_form_live.ex:257`.
- ~~**#2c** "No manufacturers/suppliers yet." empty-state messages~~ —
  wrapped. Verified at `catalogues_live.ex:868` and `:923`.
- ~~**#4** "0.00" placeholder wrapped (locale-sensitive concern)~~ —
  wrapped (`item_form_live.ex:777`). Reviewer flagged the
  browser-locale interaction; not a code defect.
- ~~**#6** "Name *" required-marker split~~ — verified across the
  forms; the consistent pattern is now `<.input ... required>` with
  the `*` indicator coming from the wrapped component, not bare
  template text. Reviewer's concern was cosmetic.

## Fixed (Batch 1 — 2026-04-26, deferred to Phase 2)

- **#5** `search_input` `attr(:placeholder, default: "Search...")` —
  the literal default is unwrapped. Bundled with the C5/C6 component
  pass on this branch so the fix lands alongside the other Gettext
  audit work. Pattern: change default to `nil` and resolve to
  `gettext("Search...")` inside the component body.

## Skipped (with rationale)

- **#1** `Gettext.gettext/3` runtime function bypasses
  `mix gettext.extract` — this is the workspace convention. Per
  [feedback_gettext_translation.md]the agent memory note `feedback_gettext_translation.md`:
  feature modules wrap call sites in `gettext(...)` but never own
  `.po`/`.pot` files; translation files live in core `phoenix_kit`.
  The runtime form `Gettext.gettext(PhoenixKitWeb.Gettext, "...")` is
  the correct shape for a library that delegates to the host's Gettext
  backend. No change.
- **#3** `"https://"` URL placeholder wrapped unnecessarily — translator
  noise concern. Removing the wrap from a string already in the catalog
  would create a no-op extraction churn; leaving it wrapped is the
  cheaper non-decision. No change.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/web/components.ex` | #5 `search_input` placeholder default → `nil`, resolved in body via `gettext("Search...")` |

(Touched in the Phase 2 component sweep, not as a standalone
PR-followup commit. Anchored here for the audit trail.)

## Verification

- Stale-string greps (`"Description"`, `"No manufacturers"`,
  `"No suppliers"`, `"Click to toggle"`, `"https://"`, `"0.00"`) all
  return only Gettext-wrapped occurrences in current `lib/`.

## Open

None.
