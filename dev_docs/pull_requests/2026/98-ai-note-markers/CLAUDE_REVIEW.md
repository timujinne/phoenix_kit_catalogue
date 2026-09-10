# PR #98: Catch two more leaked AI-note forms in strip_ai_note/1 — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/98
**Author**: @timujinne
**Reviewer**: Claude (Sonnet 5) — post-merge pass
**Date**: 2026-09-07
**Status**: reviewed; one correctness bug fixed (tests added), no other issues found

## Scope

Reworks `PhoenixKitCatalogue.AITranslatable.strip_ai_note/1`, the
defensive backstop that cuts a leaked model "note" aside off a translated
field before it reaches `generate_slug/5`. Replaces the old fixed-marker
list (`@note_markers`) with a two-stage regex: an anchor
(`@note_anchor_regex`, matching where a candidate "Note:" aside can start)
gated by a content check (`@note_content_regex`, requiring plain-word
evidence the aside actually talks about the translation process — "field",
"placeholder", "was skipped", etc.) before anything is cut. The PR branch
already carried three rounds of its own review fixes before merge
(`99d275b`..`1aa8e00`) narrowing false positives (French/German "note"
asides, care-instruction "Note:" paragraphs, backtick/`{{...}}`/quoted-word
copy) — this pass checked whether those fixes held, not just that they
existed.

## BUG - MEDIUM: content check scanned to the end of the string, not just the anchored aside — a trigger word in a *later, unrelated* paragraph could truncate legitimate trailing content

`lib/phoenix_kit_catalogue/ai_translatable.ex:263-278` (pre-fix)

```elixir
tail = binary_part(value, start, byte_size(value) - start)

if Regex.match?(@note_content_regex, tail) do
  binary_part(value, 0, start)
else
  value
end
```

`tail` ran from the anchor's start to the **end of the string**, not just
the anchored paragraph. Every test fixture placed the leaked note as the
*last* paragraph, so this was never exercised, but nothing in the
implementation guarantees that shape. A legitimate "Note:" aside (already
proven safe by this PR's own tests — e.g. `"Note: hand wash only."`)
followed by an unrelated later paragraph that happens to contain one of
the bare trigger words ("field", "placeholder", …) would cut the
legitimate note **and everything after it**, silently dropping real
content. Confirmed live:

```elixir
iex> AITranslatable.strip_ai_note(
...>   "Nice scarf.\n\nNote: hand wash only.\n\n" <>
...>   "Comes with a reusable gift box; the box's engraving field allows personalization."
...> )
"Nice scarf."
```

Two legitimate paragraphs vanish because "field" appears in a sentence
that has nothing to do with the note two paragraphs earlier.

**Fixed** — the content check now only inspects the anchored aside's own
paragraph: the substring from the anchor's start to the next `"\n\n"` (or
the end of the value if there is none), computed from the position right
after the anchor match itself (not from its start — the anchor match
begins with the leading `\n\n`/`(`, so searching from the match start
found that same leading blank line as a false paragraph boundary on the
first attempt; fixed by searching from `start + len` instead). Added a
regression test
(`test/phoenix_kit_catalogue/ai_translatable_test.exs`, "does not let a
trigger word in a later unrelated paragraph cut a legitimate Note: aside")
reproducing the scenario above. All 12 existing `strip_ai_note/1` tests
plus `ai_translatable_sets_test.exs`'s two end-to-end cases still pass
(82 tests, 0 failures in the module's test files; full suite 2422 tests, 0
failures).

## Other findings

None. The anchor/content regex split, the documented residual
field/placeholder false-positive risk (accepted trade-off, named in the
moduledoc by `1aa8e00`), and the French/German negative-match test
coverage all check out on inspection and under test.
