# PR #126: ProductCard delegates its render to core PreviewCard

**Author**: @timujinne
**Reviewer**: @claude
**Status**: Merged (reviewed post-merge, fixes applied on `main`)
**Commit**: `e3aa542` (merge `91b3c24`)
**Date**: 2026-09-18

## Goal

Move the product card's markup — the unified photos-then-files swipe carousel,
the jump strip, the fields grid and the compact file list — out of this module
and into core's new `PhoenixKitWeb.Components.Core.PreviewCard`
(phoenix_kit#827), so the catalogue item card and Andi's sub-order
featured-image card share one implementation. `product_card/1` and
`product_card_body/1` keep their names and attrs and become thin delegations;
the DB-backed helpers (`resolve_images/1`, `resolve_files/1`, `resolve_name/2`,
`build_fields/3`) are untouched.

The direction is right and the core component is a faithful generalisation —
I diffed it against the deleted markup and the carousel, strip, arrows, PDF
`sm:` breakpoint handling, fields grid and file list are character-identical.
Two things shipped broken, both found and fixed below.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/web/components/product_card.ex` | -240/+31: render bodies replaced by delegation to `PreviewCard`; `file_slide_tile/1`, `jump_js/1`, `file_ext/1`, `format_size/1` and the `Icon`/`Modal`/`URLSigner`/`Format` imports removed |

## Findings

### BUG - CRITICAL — the merged tree does not compile: `mix.lock` predates the core release that ships `PreviewCard`

`b0c3230 ("libs")` bumped `:phoenix_kit` to **2.29.1**, which has no
`PhoenixKitWeb.Components.Core.PreviewCard` — the component ships in **2.30.0**,
published 2026-09-18T08:29:58Z, forty-one seconds *after* that lock commit was
authored (08:29:17Z). The PR title flags the dependency
("needs the phoenix_kit release that ships it"), but the lock never caught up,
so `main` as merged fails to compile:

```
** (CompileError) PhoenixKitWeb.Components.Core.PreviewCard.preview_card/1 is undefined
```

This is exactly the `[[project_stale_lock_hex_trap]]` shape in reverse — the lock
was stale *behind* a release that already existed, not a phantom break. Verified
against Hex and the `../phoenix_kit` checkout (`35452656` merges #827) before
concluding.

**Fix applied**: `mix deps.update phoenix_kit` → lock now at 2.30.0.

### BUG - HIGH — `product_card_body/1` forwards a `:target` attr core's body does not declare

Core deliberately dropped `:target` from `preview_card_body/1` — the body renders
no event of its own (slides switch client-side, Close lives in the modal's action
row), so an inline embedder has nothing to point at. The delegation forwards it
anyway:

```elixir
<PreviewCard.preview_card_body
  target={@target}     # <- undefined attribute
```

Phoenix raises this as a compile-time warning, which `mix precommit`
(`--warnings-as-errors`) turns into a build failure:

```
warning: undefined attribute "target" for component
         PhoenixKitWeb.Components.Core.PreviewCard.preview_card_body/1
```

So even with the lock corrected, the gate does not pass.

**Fix applied**: stop forwarding it. The attr stays *declared* on
`product_card_body/1` — it was `required: true` before this PR and external
hosts (ecommerce/Andi) pass it — but is now `default: nil` and documented as
accepted-for-compatibility, mirroring how `:current_image` is already handled in
this module. Two tests pin it: one passing a target, one omitting it entirely.

### BUG - MEDIUM — the nameless-item title silently changed from "Item" to core's "Preview"

The PR body states "Attrs/behavior are unchanged". They are not, in one visible
spot. The old code rendered

```elixir
<:title>{@item_name || Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item")}</:title>
```

and used the same fallback for the carousel's `aria-label` and image `alt`.
The delegation passes `title={@item_name}` straight through, so a nil/blank name
now falls back to core's generic `gettext("Preview")` — a different word, from a
*different gettext backend*. Two consequences beyond the wording: the string
stops being translated by this module's hand-maintained `et`/`ru` catalogues (it
now depends on core shipping those translations), and the `"Item"` msgid that
`test/gettext_test.exs` pins loses one of its two call sites in the card path.

`resolve_name/2` can legitimately return `nil` — an item with no name in the
active locale and no fallback — so this is reachable, not theoretical.

**Fix applied**: a private `card_title/1` restores the catalogue's own `"Item"`,
from the catalogue's own backend, and also normalises `""` (which the old
`||` idiom did *not* catch — a blank name previously rendered an empty title;
it now falls back too, which is the intended reading). Applied to both
`product_card/1` and `product_card_body/1` so the aria-label matches the title
again. Three tests pin it, including one asserting core's `"Preview"` does
*not* appear.

### NITPICK — six msgids in the hand-maintained `.pot` are now orphaned

`"Previous"`, `"Next"` and `"Show image %{number}"` have **zero** remaining call
sites in `lib/` (`"Close"`, `"Files"`, `"Open"` and `"Item"` survive elsewhere);
they are now rendered by core's backend instead. They remain in
`priv/gettext/default.pot` and every locale, and `test/gettext_test.exs` still
pins all three with their `et`/`ru` strings.

**Deliberately not fixed.** Per AGENTS.md the `.pot` is hand-maintained and
regenerating it is explicitly forbidden, so removing these means hand-editing
four files plus the test to delete translations that cost nothing to keep and
would have to be re-added by hand if any call site returns. The real exposure is
upstream, not here: these user-facing strings are now only as translated as
core's `et`/`ru` catalogues make them. Recording it so the limitation is on the
record rather than rediscovered.

### IMPROVEMENT - MEDIUM — the `:phoenix_kit` floor no longer describes what the code needs

`mix.exs` pins `>= 2.13.11 and < 3.0.0`, and `test/core_pin_conformance_test.exs`
asserts 2.13.11 is admitted. Since this PR the module *hard-requires* core
≥ 2.30.0 at compile time — `PreviewCard` is referenced unguarded, with no
`Code.ensure_loaded?/1` fallback like the `phoenix_kit_comments` calls use. A
host that resolves core 2.13.11–2.29.1 alongside catalogue 0.38.0 gets an
undefined-function compile error with no degraded mode.

**Deliberately not fixed**, per the standing preference to keep `mix.exs`
constraints loose and record upstream requirements in the CHANGELOG instead
(`[[feedback_dep_constraints]]`) — and because raising the floor means also
rewriting the `@must_admit`/`@must_reject` pins and the long rationale moduledoc
in the conformance test. The requirement is now stated in the CHANGELOG entry
for 0.38.0. **Flagging it for a maintainer decision**: this is the one finding
where the conservative choice leaves a real consumer-facing failure mode open,
and if you'd rather the floor move to `>= 2.30.0 and < 3.0.0`, that's a
mechanical follow-up.

## Implementation Details

- The delegation itself is sound: `on_close` ("card_close") and `max_width`
  ("3xl", core's default) come out identical, `current_image` stays accepted and
  ignored exactly as before, and the always-present `<:extra_actions>` slot maps
  cleanly onto core's.
- No LiveView lifecycle concerns — both functions are pure function components,
  every DB-backed value is resolved by the caller, and the removed code carried
  no server events (slide switching was already client-side scroll-snap).

## Testing

- [x] Unit tests added/updated — 5 new tests in `test/web/product_card_test.exs`
      (2 for the target non-forwarding, 3 for the title fallback)
- [x] Integration tests pass
- [x] Backward compatibility verified — `product_card/1`'s public attrs are
      unchanged; `product_card_body/1`'s `:target` relaxed from required to
      optional, which is widening, not breaking
- [x] Documentation updated — moduledoc/attr docs note what is and isn't
      forwarded

## Migration Notes

Hosts must be on `phoenix_kit >= 2.30.0`. See the IMPROVEMENT above.

## Related

- Core component: `PhoenixKitWeb.Components.Core.PreviewCard` (phoenix_kit#827)
- Previous PR: [#125](/dev_docs/pull_requests/2026/125-picks-in-catalogue-order/)
