# UI conventions

The catalogue's pages should read and look like one product. These rules came
out of a sweep after the owner asked why two labels in one dialog had different
fonts, and why "Add supplier" sat next to "Unit Cost". The mechanical ones are
enforced by `test/web/ui_conventions_test.exs`.

## Words

- **Sentence case** for every label, button, heading, tab, column header and
  dialog title: "Add supplier", "Unit cost", "Save & exit". Capitals stay only
  on acronyms (SKU, PDF, SEO, URL, CRM, AI), words with digits (Pro100) and
  names of things (the "Deleted" tab, Shopify, the Entities module). This is
  also what core, CRM and projects use.
- **Unset value** in a select: "— X not set —" ("— Manufacturer not set —").
  Never "No X", which reads as if the list were empty.
- **Action prompt** in a select: "— Select a format —", "— Add supplier —".
  One dash style: the em dash, spaced, on both sides. A filter's default is
  "All …" ("All statuses").
- **Empty state**: what is true, with a full stop. "Suppliers not set.",
  "No catalogues yet.", "This company has no contacts yet." Avoid jargon like
  "linked" or "attached" where the page's own verb is different.
- **Ellipsis** is one character, `…`, and only where something continues:
  a placeholder that invites typing ("Search items…"), a working state
  ("Saving…"). Not on select prompts.
- **e.g.,** with a comma. **Quotes** are curly: “Reorder all”.

## Form fields

- Every field label is core's: `<.input label=…>`, `<.select label=…>`, or
  `<.label>` for a field built from parts. They all render
  `<label class="label mb-2"><span class="font-semibold">` (14px).
- **Never wrap a field in daisyUI's `.fieldset`.** It sets `font-size: .75rem`,
  so a label inside it renders 12px beside 14px labels elsewhere. daisyUI means
  `.fieldset` for a group of controls (radios, a from/to pair), not a single
  field.
- **Help text** under a field: `<span class="block text-xs text-base-content/50 mt-1">`.
- **Section heading** inside a card:
  `<h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">`
  with a `w-4 h-4` icon.
