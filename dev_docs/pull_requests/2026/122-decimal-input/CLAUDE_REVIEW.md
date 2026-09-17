# PR #122: Migrate free-decimal inputs to core's decimal_input — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/122
**Author**: timujinne
**Reviewer**: Claude (Opus 5), release review
**Date**: 2026-09-16
**Scope**: merge `b825394` (`5f5dc3a..4fe914f`): `Web.CatalogueFormLive`,
`Web.ItemFormLive`, `Web.Components` (smart-rule row), `Web.Helpers`
(`normalize_decimal_params/2`), `Web.Components.ItemSelectorModal`
(`zero_qty?/1`, `parse_qty/2`, `to_decimal/1`) and the two form test files.

## Summary

Every free-decimal form control (base price, markup, discount, smart default
value, supplier min. order qty, smart-rule value) moves from a browser
`type="number"` input to core's `<.decimal_input>`, and the ad-hoc
`Decimal.parse` + comma-swap code moves to `PhoenixKit.Utils.Number`.

Checked:

- **Ambiguous separators.** `Number.parse_decimal/2` treats a lone dot or
  comma as the decimal point ("1.234" → 1.234, "1,234" → 1.234) and accepts
  grouping only with both separators or spaces. A price typed "1.250" does
  not turn into 1250. The quantity pattern `^\d{1,12}([.,]\d{1,N})?$` never
  lets a grouped form through to the parser.
- **Garbage params.** `parse_decimal/2` returns `{:error, _}` for `nil`,
  maps and lists (verified), so `normalize_decimal_params/2` and
  `parse_decimal_or_nil/1` can't crash on a tampered payload. Dropping the
  `nil`/`""` clauses from `parse_decimal_or_nil/1` is safe.
- **Removed `min`/`max` HTML attributes.** Server-side bounds still hold:
  `Item.changeset/2` validates `base_price`, `markup_percentage`,
  `default_value` ≥ 0 and `discount_percentage` 0–100;
  `ItemSupplierInfo` validates `min_order_qty` ≥ 0.
- **Behaviour change in `parse_decimal_or_nil/1`.** It used to take a
  numeric prefix ("5abc" → 5); it now returns `nil` (inherit). That is
  better, since the old version silently kept half of a typo.
- **`zero_qty?/1` / `parse_qty/2`.** The NaN/Infinity guard is now
  implicit in the parser, and the regex still rejects the "2." typing state.
  No change in what the modal accepts.

## Findings

### BUG - HIGH — the `:phoenix_kit` floor still admits cores without `DecimalInput` / `Number.parse_decimal` (not fixed in mix.exs, see below)

`PhoenixKitWeb.Components.Core.DecimalInput` and
`PhoenixKit.Utils.Number.parse_decimal/2` first ship in **phoenix_kit
2.26.0** (core CHANGELOG, #818). The requirement is still
`>= 2.13.11 and < 3.0.0`. A host locked to any core 2.13.11–2.25.x resolves
this release fine and then fails to compile it (undefined function component
and remote call). The mix.exs floor comment itself says the floor exists to
prevent exactly that kind of failure.

**Not changed:** the maintainer's standing rule is not to tighten dep
constraints during a release and to state the upstream requirement in the
CHANGELOG instead. The 0.35.0 entry says **requires phoenix_kit 2.26.0+**
at the top. If the floor should move, update `pk_dep(:phoenix_kit, …)`, the
mix.exs comment, and `@must_admit`/`@must_reject` in
`test/core_pin_conformance_test.exs` together.

### NITPICK — golden item-form fixture not refreshed (fixed)

`ExtensionSlotTest` compares the item form, with no extension registered,
against `test/fixtures/item_form_no_ext.html`. The PR changed three inputs
in that form, so the full suite failed on this test. The only other
difference was the `[dev]` environment badge that the phoenix_kit 2.26.0
lock bump adds to the layout. Nothing changed around the extension slot.
Fixture regenerated.

### NITPICK — rule-value input keeps negative values (not fixed)

`set_catalogue_rule_value` parses without `min: 0`, so "-5" is stored. The
old `Decimal.parse` path did the same, and rule validation belongs to
`Rules`, not the input. This is unchanged behaviour and out of this PR's
scope.
