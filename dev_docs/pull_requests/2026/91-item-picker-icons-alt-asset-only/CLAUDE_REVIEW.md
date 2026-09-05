# PR #91: item_picker attrs — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/91
**Author**: @timujinne
**Reviewer**: Claude (Opus 5) — post-merge pass
**Date**: 2026-08-31
**Status**: reviewed; no changes required

## Verdict

Clean. No bugs found, nothing fixed. Four additive attrs, each with a
default that reproduces the previous render byte-for-byte, each pinned by a
test that asserts exactly that. Recording the checks rather than a finding
list, since the interesting question here was the merge, not the diff.

## What I checked

**The merge with #90.** #91 branched from `d8e545d` — before #90 — and was
merged after it, and both PRs edit `item_picker.ex`. Git auto-merged; the risk
was a semantic conflict, not a textual one. #90 replaced the component's
hardcoded `"en"` locale default with
`assigns[:locale] || Gettext.get_locale(PhoenixKitCatalogue.Gettext)`
(deliberately `||`, not `put_new`, so an explicit `locale={nil}` still falls
back). #91 introduced `alt={item_display_name(@selected_item, @locale) || ""}`.
Read together on `main` (`item_picker.ex:704-722` against `:226-241`), they
compose: the new `alt` is translated through #90's resolved locale, not the
stale `"en"`. Neither change is shadowed.

**`show_photo`'s falsy handling.** `effective_photo_uuid(_item, false)` matches
the literal `false` rather than testing falsiness, and the placeholder gate is
`@photo_placeholder || @show_photo == false`. That is the correct pairing: a
host passing `show_photo={@maybe_nil}` gets the documented `true` default, not
"hide". The PR pins exactly this case ("show_photo: nil (explicit) behaves like
the true default"), which is the clause most likely to be broken by a later
"simplification" to `!@show_photo`.

**`photo_asset_type` as an injection surface.** It is interpolated unescaped
into the signed URL path. The moduledoc says so explicitly and tells hosts
never to bind it to end-user input — the same contract `:photo_size` already
carries. Given the component is admin-only and the attr is a developer literal,
that is the right call over a runtime allow-list this module has no source of
truth for.

**The `p-1.5` removal.** The test's stated rationale — that the padding
"shrinks its visible box by 12px relative to the image" — is not quite how
`border-box` sizing works; `w-8 h-8 p-1.5` yields the same 32×32 outer box as
`w-8 h-8`. What the padding *did* change is the inset of the masked
`hero-photo` glyph inside that box, so removing it makes the placeholder read
as a filled tile rather than a small icon in a frame. The change is right and
the class-string assertions pin it precisely; only the comment's reasoning is
off, which changes nothing about the code.

**Test quality.** The two placeholder-parity tests assert the *full* class
string rather than "contains the size class" — the author's comment explains
why, and they are correct that the weaker assertion passes on the buggy code
too. That is the right instinct.

## Gate

Covered by the combined run on `main` alongside #90: `mix format` →
`mix precommit` clean, full suite green.

## Related PRs

- Concurrent: [#90](../90-selector-popup-sweep)
