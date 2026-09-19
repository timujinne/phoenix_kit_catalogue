# PR #127 follow-up

How each finding in `GROK_REVIEW.md`, `ZAI_REVIEW.md` and `VIBE_REVIEW.md`
was resolved. Each was checked against the code, and several in the browser,
before acting. Codex was out of quota for both rounds.

## Fixed

- ~~Grok 1.5.2: tabbing to the next field leaves the list open, now over the
  next row — `phx-click-away` never fires on Tab.~~ `917beba`: the hook
  closes on `focusout` to a focusable target outside the component. Pinned in
  `item_picker_test.exs`.
- ~~Grok 1.5.6 / Zai 2: the Columns list keeps tracking a button that scrolled
  out of the modal box.~~ `917beba` adds `position-visibility: anchors-visible`,
  which the picker list already had.
- ~~Grok 1.5.13: `position-area: bottom span-right` is a physical side, wrong
  in right-to-left text.~~ `917beba`: the picker list sits in the input's own
  column (`position-area: bottom`) at `width: anchor-size(width)`.
- ~~Zai 3: the modal's toolbar row has no `flex-wrap`; with the opt-in root
  switcher a narrow screen pushes Columns and View past the modal's edge.~~
  `ccd7a40`: the row wraps and the search form keeps 12rem. Measured at 320px
  and 360px with the switcher's two buttons added: nothing past the edge.
- ~~Zai 5: the no-anchor fallback places the list below even when it doesn't
  fit there.~~ `917beba` clamps the bottom to the viewport. (The half-viewport
  cap already made this unreachable; the clamp is one line.)
- ~~Grok 2.4.5: a list that opened below with room can grow past the edge when
  new results arrive, and nothing scrolled to trigger a re-check.~~ `6ba665b`
  re-checks after every server update, with a pixel of slack so sub-pixel
  sizes never reopen it on every frame. Verified: one match sat below the
  input, all 11 results moved it above.
- ~~Found while verifying, not by a reviewer: an OPEN anchored popover follows
  its anchor on scroll but keeps the position option it opened with, so it
  scrolls off screen.~~ Both hooks reopen a list that no longer fits
  (`hidePopover()` + `showPopover()` makes the browser choose again).
  Measured both ways in Chrome 152.

## Refuted, with the check

- **Zai 1: a manual popover's `::backdrop` swallows outside clicks, leaving
  the picker stuck open and the page unclickable.** Marked "unsure, test this
  one" and tested: with the list open, `elementFromPoint` on empty page area
  returns `BODY`, and a real click there closed the list through
  `phx-click-away`.
- **Grok 2.4.1: a `query_change` already in flight reopens a list the user
  closed.** Both events go to the same LiveView process in order, so the close
  is applied last.
- **Grok 2.3: the product-card dialog's focus closes the list.** The card
  renders inside the component root, so `this.el.contains(relatedTarget)` is
  true.
- **Grok 2.4.2 / 2.4.4: `updated()` never shows a re-rendered list;
  `placeListbox` has an unbound `height`.** Both readings came from a diff
  hunk; the file's `updated()` calls `syncListbox/1` and `placeListbox/1` is
  complete.
- **Grok 1.5.1: the picker needs `flip-inline`.** The list is the input's own
  width in the input's own column, so it cannot overflow sideways further than
  the input does.
- **Grok 1.5.5: fixed coordinates are wrong inside a transformed ancestor.**
  Only reachable without the Popover API; a shown popover is in the top layer,
  whose containing block is the viewport.
- **Grok 1.5.8: a toolbar button inside the search form submits it.** The
  Columns button is `type="button"` and sits outside that form.
- **Grok 1.5.11: the active option is not scrolled into view.** The hook's
  `syncActiveDescendant` already calls `scrollIntoView({block: "nearest"})`.
- **Zai's aside: a duplicated line in the `.ScrollTop` hook.** It is a
  conditional assignment inside an `if`, not a duplicate.
- **Vibe 1: Firefox and Safari centre the Columns list.** Only before Firefox
  147 and Safari 26; both support anchor positioning now (MDN).

## Declined, with reasons

- **Zai 4: flush a pending search when the picker is destroyed.** A removed
  component has nowhere to send it.
- **Grok 2.2: pressing an option and releasing elsewhere drops the pending
  search.** Cancelling on `pointerdown` is what keeps a pick from being
  overwritten by a search that lands between press and release. The next
  keystroke or focus searches again.
- **Grok 1.5.3 / 2.4.6: the mobile on-screen keyboard shrinks the visual
  viewport but not `dvh`.** Measuring the visual viewport would reopen the
  list on every scroll without the browser placing it any better. The modal's
  own `100vh` is core's.
- **Zai 6: two DOM ids differing only in punctuation share an anchor name.**
  Ids are unique per document and the pattern is `<component-id>-…`.
- **Vibe 2/3: touch target size, ARIA roles on the Columns menu, long labels
  wrapping.** Unchanged behaviour, older than this PR.

## Open

None.
