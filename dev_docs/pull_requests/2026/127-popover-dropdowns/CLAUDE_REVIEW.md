# PR #127: Keep the popup's dropdowns on screen, and let the item picker search without a form — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/127
**Merge**: `3e80ab0` (branch `mdon/main`, author Max Don)
**Reviewer**: Claude (Opus 5), full repo access — ran the suite, the gate, and
rendered the changed components to inspect the real markup
**Date**: 2026-09-18
**Scope**: the whole merged diff, read after `GROK_REVIEW.md`, `ZAI_REVIEW.md`,
`VIBE_REVIEW.md` and `FOLLOW_UP.md`, so this is a *post-fix* pass: what the three
earlier reviews and the follow-up left standing.

## Verdict

The popover work is sound. I re-derived the four things that carry the design —
top-layer escape from the modal box, `flip-block` + the half-viewport cap
guaranteeing one side always fits, the reopen-on-refit trick for the fact that a
browser picks a position option at *open* time, and the hook-pushed
`query_change` replacing a `phx-change` that LiveView refuses outside a form —
and all four hold. I found no functional defect in the JS or the HEEx that the
earlier reviews had not already caught and the follow-up had not already fixed.

I did find one **regression that ships in the merge and breaks the project gate**,
plus a weak test assertion and two documentation gaps. All are fixed here.

`mix test`: 2 doctests, 3094 tests, 0 failures.
`mix precommit`: clean after the fix below (it was failing on the merge commit).

## Findings

### BUG - MEDIUM — the merged tree fails `mix precommit`

`lib/phoenix_kit_catalogue/catalogue.ex:5653`, commit `1141a05` ("Format
`category_facts/2` the way this Elixir formats it").

The PR reindented the `, do:` continuation of `category_facts/2` from 7 spaces to
4. Under this repo's Elixir (1.19.5) `mix format` puts it back to 7, so
`mix quality.ci` — which `precommit` ends with — aborts at
`format --check-formatted` and **credo and dialyzer never run at all**. Verified
on the merge commit:

```
** (Mix) mix format failed due to --check-formatted.
The following files are not formatted:
  lib/phoenix_kit_catalogue/catalogue.ex
5654 -|    do: {status, catalogue_uuid}
     +|       do: {status, catalogue_uuid}
```

This is not a one-off typo: `mix.exs` declares `elixir: "~> 1.18"`, and 1.18 and
1.19 genuinely disagree about how deep a wrapped `, do:` continuation sits. The
commit title is accurate — that *is* how the author's Elixir formats it — which
means simply reformatting it back only hands the flip-flop to the next
contributor on 1.18.

**Fixed** by removing the ambiguity rather than picking a side: the clause is now
a `do` block, which both versions format identically, with a comment saying why.
Recorded in AGENTS.md under the repo-local aliases so the next `, do:` one-liner
does not reintroduce it.

### IMPROVEMENT - MEDIUM — a test assertion with a dead half

`test/web/browse_components_test.exs:403` (as merged):

```elixir
assert html =~ ~s(phx-hook=".ColumnToggle") or html =~ "Browse.ColumnToggle"
```

A colocated hook's name is expanded to `<Module>.<name>` at compile time, so the
leading-dot form never reaches the HTML. I rendered the component to confirm:

```
phx-hook="PhoenixKitCatalogue.Web.Components.Browse.ColumnToggle"
```

The first disjunct is therefore always false, and an `or` between a
never-true check and the real one is a standing invitation to "fix" a future
failure by leaning on the wrong half. **Fixed**: the assertion now pins the
expanded name, with a comment on why the dot form is not also asserted.

(The hook is registered correctly — `_build/test/phoenix-colocated/
phoenix_kit_catalogue/index.js` carries
`PhoenixKitCatalogue.Web.Components.Browse.ColumnToggle`. `_build/dev` is stale
and does not; that is a stale build, not a defect.)

### IMPROVEMENT - MEDIUM — the new contracts were nowhere in AGENTS.md

Two things this PR establishes are exactly the kind of non-obvious contract
AGENTS.md exists to hold, and neither was recorded:

1. **The picker searches without a form.** The Landmines section said only "a
   `<select phx-change=…>` outside a `<form>` never reaches the server — wrap it
   in a form, and drive it in tests via `render_change`". That advice is now
   actively wrong for the picker: there is no form, `phx-change` is gone, and
   `render_change` on the input no longer reaches anything. The next agent
   following the old landmine would either wrap the picker in a form (firing the
   host form's `phx-change`, the thing this PR removed) or write a test that
   silently exercises nothing.
2. **Popovers as the anti-clipping pattern.** `Browse.popover_anchor/1` is now
   the module's way to keep a dropdown out of a clipping ancestor, and the
   reopen-on-refit rule (a browser picks a position option at open time, not
   when the anchor scrolls) is the single least guessable thing in the diff.

**Fixed**: both added to Landmines, with the testing consequence
(`render_hook("query_change", …)`, never `render_change`) spelled out, and the
Item picker feature note updated to say it needs neither a form nor overflow
rules.

### NITPICK — `column_toggle/1` has no fallback where the Popover API is absent

The picker's listbox is `:if={@open}` and the hook positions it by hand when
`showPopover` is missing, so it degrades to a plain positioned list. The Columns
`<ul>` is rendered unconditionally and relies entirely on `[popover]` being
honoured; a browser that ignores the attribute has no UA
`[popover]:not(:popover-open) { display: none }` rule either, so the column list
would sit permanently expanded in the toolbar rather than merely mispositioned.

Not fixed, and I would not fix it: that means Firefox < 114 / Safari < 17, well
below the floor the follow-up already argued for anchor positioning, and adding a
second fallback path to a component that has one code path is a worse trade than
the bug it averts.

### NITPICK — `refit()` reopens an auto popover, which drops focus inside it

`hidePopover()` on a popover holding the focused element returns focus to the
invoker, and the following `showPopover()` does not put it back. A keyboard user
partway down the Columns list who scrolls the page loses their place.

Not fixed: it needs the page to scroll while focus sits inside an open menu that
has stopped fitting, and preserving focus and `scrollTop` across the reopen is
more moving parts than the case earns. The scroll handlers already guard against
the common version of this (`this.menu.contains(e.target)` / `list.contains`), so
scrolling *inside* either list never triggers it.

### NITPICK — `popover_anchor/1` is public but unlisted

`Web.Components`' moduledoc enumerates what `Browse` offers hosts composing their
own surface (`item_card/1`, `view_toggle/1`, `column_toggle/1`, …).
`popover_anchor/1` is now public, `@spec`'d, and exactly what such a host needs
to anchor its own popover. Left alone — the list is prose, not a contract, and
the function's own `@doc` is thorough.

## Checked and confirmed sound (no action)

Re-derived independently rather than taken from the earlier reviews:

- **`updated()` fires for the listbox's arrival.** morphdom calls `onElUpdated`
  on every element it morphs, ancestors included, so a diff that only adds the
  `<ul>` deep inside still reaches the root hook's `updated()` — which is what
  `syncListbox()` depends on to call `showPopover()` on each newly rendered list.
- **The focused input is not clobbered.** Dropping `phx-change` does not expose
  the input to having `value={@query}` patched over what the user is typing:
  LiveView's `mergeFocusedInput` excludes `value` for *any* focused form input,
  bindings or not.
- **`stopPropagation` reaches the right listeners and no others.** `phx-change`
  on a host form is bound to the form element and sees `input`/`change` by
  bubbling, so stopping them at the input is sufficient and exact. `phx-focus` is
  bound on the input itself and is unaffected.
- **No pending search can outlive the interaction that made it stale.** I walked
  click-away (relatedTarget `null` → no `focusout` close, but `_skipped` blocks
  the push and `phx-click-away` closes), Tab (`focusout` → `close`), clicking an
  option (`pointerdown` → `cancelQuery`), Enter (`cancelQuery` before `.click()`),
  and the clear button (button is inside `this.el`, so no close; the timer then
  skips because focus left the input). Every path either sends or drops the query
  deliberately.
- **Clicks on options do not trip `phx-click-away`.** The top layer changes
  paint order, not DOM ancestry; the listbox is still a descendant of the
  `phx-click-away` root.
- **Zai 5's clamp is genuinely fixed.** `placeListbox` now clamps to
  `Math.max(0, Math.min(top, innerHeight - height))`, and because the list is
  capped at `min(16rem, 50dvh - 2.5rem)` the clamp can never produce a negative
  window. The "neither side fits" case Zai constructed is unreachable *and*
  handled.
- **`gettext`** — `aria-label={gettext("Columns")}` reuses an existing msgid,
  present in `default.pot` and all five locales. Macro form inside a HEEx
  attribute, as AGENTS.md requires. No `.pot` work needed.
- **Stale docs** — I grepped `lib/` and `dev_docs/` for the old "parent must
  allow overflow" / `z-50` guidance the PR removed from `ItemPicker`'s moduledoc.
  Nothing else repeats it; the `Web.Components` wrapper doc never did.

## Open

None.
