# PR #91: item_picker — placeholder sizing, alt text, asset type, show_photo

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/91
**Author**: @timujinne
**Merged**: 2026-09-01 (`c4a98bd`)

Four small, additive changes to `<.item_picker>`, all default-preserving:

- **`:photo_asset_type`** (default `"thumbnail"`) — the Storage variant name
  passed to `URLSigner.signed_url/2`, so a host wanting a larger thumbnail
  isn't stuck on the previously hardcoded variant. Interpolated into a signed
  URL path, so it is documented as a developer-chosen literal, never bound to
  end-user input.
- **`:show_photo`** (default `true`) — forces the real `<img>` off for *every*
  selected item, not just photo-less ones. With `:photo_clickable` on, the
  placeholder stands in as the product-card target; with it off, nothing
  renders in the thumbnail's place. Implemented as
  `effective_photo_uuid/2`, which matches `false` explicitly so an explicit
  `nil` reads as the `true` default.
- **`alt`** on both thumbnail branches now carries the item's translated
  display name instead of `""`.
- **Placeholder box parity** — the `hero-photo` placeholder dropped its
  `p-1.5` so its box matches the image's at every `:photo_size`.

The `<.item_picker>` function-component wrapper in `web/components.ex`
forwards both new attrs.

Branched from `d8e545d`, i.e. *before* #90, and merged after it. The two PRs
both touch `item_picker.ex`; the merge is semantically clean — #90's locale
fallback (`assigns[:locale] || Gettext.get_locale/1`) and #91's
`alt={item_display_name(@selected_item, @locale)}` compose correctly, and the
new `alt` picks up #90's locale fix for free.

## Related PRs

- Concurrent: [#90](../90-selector-popup-sweep)
- Review: [`CLAUDE_REVIEW.md`](CLAUDE_REVIEW.md)
