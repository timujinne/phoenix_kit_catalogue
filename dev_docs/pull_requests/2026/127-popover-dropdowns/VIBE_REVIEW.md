# PR #127: Keep the popup's dropdowns on screen, and let the item picker search without a form — Vibe review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/127
**Reviewer**: Vibe (Mistral Devstral 2), no tools; answered from a brief with the `lib/` diff
**Date**: 2026-09-17
**Scope**: the popover change at `d0a6b0d`: browser behaviour, visuals and what else commonly gets clipped

1. **Firefox, Safari**: Columns dropdown centered (daisyUI fallback), ItemPicker JS-positioned; both stay on-screen but Columns not anchored to button. **Chrome/Edge**: perfect.

2. Stacking in top layer prevents clipping. `text-base-content` fixes dark theme. Widths match anchors. 0.25rem gap adequate. Keyboard nav works. Touch targets small (btn-sm). dvh + JS handle on-screen keyboard.

3. Tooltips, long text in fixed-width menus, custom date pickers, nested modals, sticky headers.

4.
   1. Columns dropdown positioning in Firefox/Safari (centered, not anchored)
   2. Missing ARIA roles and focus management
   3. Small touch targets
   4. Horizontal text overflow in Columns dropdown
