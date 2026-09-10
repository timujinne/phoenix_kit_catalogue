# PR #105: Read the primary-language column before the translation bucket — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/105
**Author**: @timujinne
**Reviewer**: Claude (Sonnet 5) — post-merge pass
**Date**: 2026-09-10
**Status**: reviewed; no issues found

## Scope

Three same-day commits, each fixing what the previous one missed:

1. `translated_name/2` / `translated_description/2` unconditionally
   preferred `data[locale]["_name"/"_description"]` over the record's own
   column, even at the record's own primary language — so a writer that
   legitimately updates only the column (the Shopify sync) got shadowed
   forever by a stale primary-language bucket entry. Fixed by reading the
   column first at the record's own primary locale (falling back to the
   bucket only when the column is blank/nil), everything else unchanged.
2. That fix compared locales by exact string equality
   (`locale == record_primary_language(record)`), while
   `Multilang.get_language_data/2` beneath it resolves a bare base code or
   sibling dialect through to the primary bucket — so `"en"` against a
   record whose primary is `"en-US"` fell through to the stale-bucket-first
   branch, the exact bug this module exists to stop. Fixed by mirroring
   `Multilang`'s private `language_entry/3` step for step
   (`resolved_bucket_key/3`, via the same `DialectMapper.extract_base/1`),
   so the two layers can't drift apart.
3. `primary_locale?/2` matched any map `data` and attempted bucket
   resolution on it, including flat pre-multilang data — for which
   `resolved_bucket_key/3` can never find a match, always returns `nil`,
   never equals the primary, so the record fell into the secondary branch
   regardless of locale. Fixed by gating on `Multilang.multilang_data?/1`
   first, exactly as `Multilang.get_language_data/2` itself does.

## Review notes (no fix needed)

- Fetched the actual dependency source
  (`deps/phoenix_kit/lib/phoenix_kit/utils/multilang.ex`) and diffed it
  line-by-line against `resolved_bucket_key/3` /
  `base_resolved_key/3` / `same_base_key/3`: the mirrored logic is exact —
  same three-step fallback (literal locale bucket → literal base-code
  bucket → same-base sibling set with primary-wins tiebreak), same
  `_primary_language` key exclusion, same `Enum.sort/1` for deterministic
  sibling choice. `record_primary_language/1`'s
  `data["_primary_language"] || Multilang.primary_language()` idiom is
  also identical to `Multilang`'s own private
  `primary_language_from_data/1`. There is no daylight between the two
  layers for this PR to have missed.
- Verified the one documented asymmetry (inherited from
  `language_entry/3`, not introduced here) is real and intentional: among
  several dialects sharing a requested base code, the *primary* bucket
  always wins the fallback even when a more specific but unrelated sibling
  exists — e.g. primary `"en-US"`, siblings `"en-US"`/`"en-GB"` present,
  requesting `"en-CA"` (no bucket of its own) resolves to `"en-US"`, not
  `"en-GB"`. The moduledoc calls this out as deliberately left alone rather
  than "fixed" here, since inventing a different tiebreak would just be a
  second, competing source of truth for what a locale resolves to.
- The three pre-existing tests this PR had to touch
  (`test/catalogue_test.exs`, `test/web/catalogue_detail_live_test.exs`,
  `test/web/item_form_live_test.exs`) all used a "translation" locale that,
  in this env's default primary (`"en-US"`), shares a base with the
  primary and so silently exercised the *fixed* column-preferred path
  rather than the secondary-locale path the test claims to cover.
  Confirmed each rewritten fixture (`"de"` instead of `"en"`, or an
  explicit non-English `_primary_language`) now actually exercises what
  its test name says, with no assertion changed.
- No `mount/3` queries, no unscoped PubSub, no N+1 introduced — pure
  read-path logic in `PhoenixKitCatalogue.Catalogue.Translations`.

## Gate

`mix precommit` (format, credo --strict, dialyzer) clean. Full suite: 2535
tests, 0 failures.
