# PR #127: Keep the popup's dropdowns on screen, and let the item picker search without a form — Grok review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/127
**Reviewer**: Grok 4.3, no tools; answered from a brief (no repository access)
**Date**: 2026-09-17
**Scope**: two rounds: the popover change at `d0a6b0d` (markup, hook, and the `ItemSelectorModal` render); the follow-up fixes at `917beba`

## Round 1: the popover change (`d0a6b0d`)

Questions: popover state across LiveView patches; whether the half-viewport cap plus `flip-block` is a guarantee; popovers inside a `showModal()` dialog; the hook's `stopPropagation` and debounce; anything else that can stick out, be clipped or be unreachable.

**1. Open state vs morphdom, and `showPopover()` in `updated()`**

Same node, same attributes, only children change: **the open state usually survives.** `:popover-open` is element state + top layer, not an attribute morphdom diffs. morphdom only `setAttribute`s when the value changes, so a stable `popover` / `popover="manual"` and a stable `id` should not close it. Column toggles that only swap `<li>`s are the happy path.

It does **not** survive if the `<ul>` is replaced (id change, parent move, `:if` destroy/recreate) or if the patch rewrites `popover` / moves the node. Auto popovers can also light-dismiss if a patch makes the click look “outside.”

**B:** destroying via `:if={@open}` drops a new node that is **not** open (UA `display:none` until shown). `showPopover()` from the **wrapper** hook’s `updated()` (and `mounted()`) is the right place: it runs after the patch, in the same frame, so you should not paint the hidden state. Guard with `matches(':popover-open')` — `showPopover()` throws `InvalidStateError` if already open. Do not call it if the node is missing or disconnected.

Footguns: `updated()` will **re-open** a manual popover that was only `hidePopover()`’d locally while `@open` is still true (Escape must set `@open false`, not just hide). If the JS fallback writes `style.top/left/width`, morphdom will reset `style` to the server string on every `query_change` patch; re-place in `updated()` or you get a jump. `showPopover()` does not steal focus unless something inside is `autofocus`.

**2. Is `50dvh - 2.5rem` + `flip-block` a guarantee?**

**In a full layout viewport, `position: fixed` top-layer, ~2rem anchor, no keyboard: yes, for the block axis.** `max(space_above, space_below) ≥ (100dvh - anchor)/2`. For a 2rem anchor that is `≥ 50dvh - 1rem`. Cap at `50dvh - 2.5rem` leaves ~1.5rem for `my-1` / `margin-block: 0.25rem` (0.5rem), borders, and half-anchor. `flip-block` then picks that larger side. `overflow-y-auto` handles content taller than the cap. `min(16rem, …)` only makes the picker smaller.

**Not a guarantee** when:

- the virtual keyboard shrinks the **visual** viewport but not `dvh` (common on iOS)
- `safe-area-inset-*` eat the slack
- the anchor is taller than ~3rem (daisyUI `input-md` is 3rem; `input-lg` is 4rem — budget goes to ~0)
- extra gap/border/UA chrome
- all try options fail: `flip-block` does **not** shrink; the spec leaves the overflowing try in place, and the off-screen part is not scrollable from outside

Picker has **no `flip-inline`**, so this math does not cover horizontal overflow at all.

**3. Popover inside `showModal()`**

**If the popover node is a DOM descendant of the `<dialog>` (yours is): it paints above the dialog and is not inert.** Modal inertness is everything *outside* the dialog; top-layer promotion does not take it out of that tree. Clicks, `phx-click`, focus trap all still see it as inside the dialog. That is why this escapes `.modal-box { overflow-y: auto }` clipping.

If it were portaled **outside** the `<dialog>` in the DOM, it could paint on top and still be inert. Don’t do that.

Escape/light-dismiss: the topmost popover should go first, then the dialog.

**daisyUI `@supports not (position-area: bottom)`:** `margin: auto` + `::backdrop` turns the menu into a **viewport-centered sheet** with a backdrop in the popover’s top-layer entry — **above** the item-selector dialog. It will dim/intercept clicks on the modal. Columns has **no JS fallback**, so that is the no-anchor path. The picker fallback (fixed top/left, no daisy backdrop) is safer. A transparent popover `::backdrop` on auto popovers can still eat clicks meant for the dialog.

Nested product-card `<dialog showModal()>`: that stack is the next inert/focus-trap layer; the outer modal becomes inert until it closes. Nested dialogs remain flaky in Safari.

**4. `stopPropagation` + debounce/IME**

**Breaks (by design if you want it, bugs if you don’t):**

- Host `<form phx-change>` never sees this field’s `input`/`change`. The host that wrapped with `name="value"` will no longer get keystrokes in the form payload. Dirty-tracking / autosave on that form ignore the picker.
- Any ancestor/other hook listening on bubble `input`/`change`. Capture listeners still run.
- Same-element listeners: order is registration order; you removed `phx-change` on the input, so LV is not on that node anymore.

**Does not break:** LiveView form recovery (it reads DOM values, not those events); other fields in the same form; `phx-focus="open"`.

**IME/debounce:** skip `isComposing`, push on `compositionend`, 300ms trailing debounce is the right shape. Gaps: Safari sometimes lies about `isComposing` (old `keyCode === 229` guard still helps on Android); `compositionend` + the following `input` can double-queue (debounce usually collapses it); **flush the debounce on Enter / ArrowDown / blur**, or the first keystroke+Enter races a stale list; cancelled composition still fires `compositionend` (pushing the reverted value is correct).

**5. Remaining clip / overflow / unreachable (by likelihood)**

1. **Picker: only `flip-block`, no `flip-inline`** — row picker near the right edge of a table/panel runs off sideways. Columns already tries `flip-inline`.
2. **Tab between row pickers** — `popover="manual"` does not auto-close when another opens; `phx-click-away` does not fire on Tab. Previous listbox stays open, possibly over the next row.
3. **iOS `100vh` modal-box + visual viewport / keyboard** — `.modal-box` at `max-height: 100vh` (not `dvh`) and `50dvh` lists ignore the keyboard; bottom of modal + flipped list sit under chrome/keyboard.
4. **No-anchor Columns path** — daisyUI centered sheet + `::backdrop` over the already-modal selector (Firefox/older Safari).
5. **JS fallback `position:fixed` + transformed ancestor** — `getBoundingClientRect` + `top/left` is wrong if a host modal has `transform`/`filter` (fixed containing block). Top-layer popover path is fine; fallback is not. Also listen to `visualViewport` resize/scroll, not just `scroll`/`resize`.
6. **Columns open while `.modal-box` scrolls** — no `position-visibility: anchors-visible`; menu can float on a clipped/off-screen button. Picker already sets this.
7. **Enter/Arrow before 300ms debounce flush** — list doesn’t match what was typed.
8. **Toolbar `<button>` inside the search `<form>` without `type="button"`** — column toggles submit the form, remount/close the stack. Unsure of DOM nesting; high if they are inside the form.
9. **Nested product-card dialog** clipped if it is a daisyUI absolute overlay in `.modal-box` rather than a real top-layer `<dialog>`; inert/focus bugs if it is `showModal()`.
10. **48vh list + 26vh tray + toolbar > short window** — modal-box scrolls; toolbar (and Columns anchor) can leave the visible box (see 6).
11. **Active option not `scrollIntoView`** inside the capped listbox — keyboard-reachable, visually off the pane.
12. **`width: anchor-size(width)` before layout** in `updated()` → 0-width frame.
13. **RTL + `span-right`** — menu prefers the wrong inline side.
14. **`flex-nowrap` Columns items** — vertical cap is solved; long labels can overflow horizontally.

`phx-click-away` vs top-layer list is **fine** as long as the `<ul>` stays a DOM child of the wrapper (`contains(target)`). A portal would break it. Unsure of product-card’s exact dialog vs overlay implementation.

## Round 2: the follow-up fixes (`917beba`)

Questions: the reopen-on-scroll workaround; the pending-search rules; the `focusout` close; anything still missed.

**1. Reopen-on-leave-viewport — mostly sound, not a loop.**

Manual popover + focused input: `hidePopover`/`showPopover` should not move focus (input is not inside the popover; manual does not light-dismiss or auto-focus). Unsure of a 1-frame paint flash in Chrome 152; same-turn hide+show usually does not paint closed.

No self-loop: refit runs once per rAF, and only on scroll/resize, not on toggle. After reopen, if it still fails `fitsViewport`, it sits there until the next scroll/resize.

Real costs of the workaround:

- **While the open list is *partially* off-screen, every scroll frame hide+shows.** That can flicker, re-announce `toggle` to AT, and **reset `list.scrollTop`** (internal option scroll is lost on page scroll; you only skip when the *list* is the scroll target).
- **Flip-flop at the midpoint:** reopen always retries `position-area: bottom` first. Scrolling through the band where below/above both barely fail can alternate sides every frame.
- `fitsViewport` is a full-rect test vs `window.innerHeight` (not visualViewport). Subpixel overflow → refit every frame; mobile keyboard → “fits” while covered.

Zero-rect while `position-visibility: anchors-visible` strongly hides: `top=0, bottom=0` **passes** `fitsViewport`, so you will not refit until the anchor is visible again. Probably fine.

**2. Pending-search rules — close/in-flight is the hole; cancel-on-pointerdown is the lost search.**

Sound: tab-away before debounce (`close` → `cancelQuery`); blur with `relatedTarget === null` then `pushQuery` sets `_skipped` and focus re-queues; Enter-pick cancels before `.click()`.

Loses a search the user expects: **pointerdown on an option then release off it** (no click) still `cancelQuery`s. Input can be `"abcd"` with `"abc"` results and nothing will search until the next `input`/`focus`.

Reopens a list they closed: **`query_change` already in flight, then Escape / focusout `close` / pick.** The hook cannot cancel that. If the server opens on query results without a generation/open-guard, the list comes back under the next field. Same for Enter-pick vs a just-sent query.

`change` after tab-away is OK: `close` cancels, then `change` would re-queue, then `pushQuery` sees the other field and only sets `_skipped`.

**3. focusout — correct for Tab; `relatedTarget` is the whole game.**

Closes only on a **focusable** target outside `this.el`. Popover top-layer does not reparent, so `contains` still works for the list.

Wrongly closes: **product-card dialog** (focus moves into the dialog → `close`). Usually what you want. Photo control **outside** the hook root (or a hidden `input[type=file]` it labels) — closes. Photo/clear **inside** `this.el` — does not.

Wrongly stays open: `relatedTarget === null` (non-focusable click, OS file dialog, window switch, some Safari button clicks). You rely on `phx-click-away` there; you already verified outside click. Clear button inside: list stays open (fine unless clear is supposed to dismiss). Clicking the list scrollbar: input may blur with `relatedTarget` null → list stays, which is OK.

Unsure: Safari `relatedTarget` on button/file-input clicks.

**4. Still missed, ranked**

1. **In-flight `query_change` vs `close`** — will reopen under the next field unless the server drops stale queries / ignores results when closed. Highest functional risk.
2. **Empty `updated()` vs “each render is a new element.”** If LiveView recreates the listbox after results, nothing calls `showPopover`. If the node is reused and stays `:popover-open`, OK — then the comment is wrong. One of the two is a bug.
3. **Refit during scroll** — per-frame hide+show, flip oscillation, list `scrollTop` reset (see Q1).
4. **`placeListbox` as pasted** — `height` is unbound (`ReferenceError`); no `left`/`width`/`position: fixed`. Dead for the non-anchor path if that is the real code.
5. **Layout change without window scroll/resize does not refit** (Columns toggle that grows the list past the viewport — you verified it *stays open*, not that it still *fits*).
6. **Visual viewport / keyboard** vs `innerHeight` + `50dvh` cap: after flip, a 50dvh list can still overflow the shorter side (`fitsViewport` then hide+show every scroll).
7. Pointerdown-cancel without a successful pick → stale query (Q2).
8. `position-area: bottom` + `width: anchor-size(width)` — with equal widths, start vs center is a wash; good drop of `span-right`. No `flip-inline` is consistent with that.

Not missed given your measurements: outside click, synthetic `focusin`, flip-block when 209px below, refit after scroll-to-top, Columns unclipped past the modal.
