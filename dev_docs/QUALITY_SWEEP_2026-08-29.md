# Quality sweep — phoenix_kit_catalogue (2026-08-29)

Playbook: `~/Desktop/Elixir/dev_docs/quality_sweep.md`. Phase 1 is complete —
all 47 PR folders now carry a `FOLLOW_UP.md`, and the 20 that lacked one were
verified finding-by-finding against current code with **no regressions**: every
fix a review claimed is still present, present in an equivalent
reimplementation, or moot because the code was deleted.

Phase 2 ran four triage agents over `lib/` + `test/` plus the hand checks.
**Every finding was verified before being acted on**; the rejected ones are
listed at the end.

## The correction worth reading first

I claimed in `65231b3` that `mix gettext.extract` was safe here and rewrote the
`AGENTS.md` warning that said otherwise. **That was wrong.** `extract` MERGES
into an existing `.pot` rather than replacing it, so running it with the
committed file in place reported "959 of 960 msgids extracted" — because it
kept them. Delete the `.pot` first and the same command yields **47**; only 46
committed entries carry `#, elixir-autogen`. The warning is restored with that
trap documented, because the misleading measurement is exactly how I talked
myself out of it. Nothing was lost — the merge reported `0 removed` and the
catalogues are intact.

## Fixed

### Correctness

- **Inline validation errors never rendered on the catalogue form.** The
  `validate` handler forwarded the previous changeset's `action`, which starts
  `nil` from mount, and `to_form/1` drops errors entirely on a nil action — so
  the form was invalid and silent until the first failed *save*. Every sibling
  form hardcodes `:validate`. Pinned by a test that fails without the fix.
- **`reorder_attachments/3` was a check-then-act on a non-primary key** with no
  transaction and no lock: two saves of the same item interleaved their
  per-row `update_all`s into a mixed order, and a mid-loop failure left half
  the attachments renumbered with nothing to roll back. Now one transaction
  under a per-item advisory lock — the mechanism `lock_set/1` already used for
  sets.
- **Two reorders could not report a failure at all.** `reorder_attributes/2`
  and `reorder_attribute_values/2` discarded the transaction result and
  returned `:ok` unconditionally. My first fix only matched on that result,
  which the external panel correctly called a misdiagnosis: nothing in either
  transaction calls `rollback/1`, so a database failure RAISES out of
  `Repo.transaction/1` and an `{:error, _}` branch under it is unreachable —
  the page still crashed and the spec still advertised an error nothing
  produced. `run_reorder/1` now turns the DB families a reorder can genuinely
  hit into that error and leaves programmer errors to crash.
- **Infinite scroll on the events page loaded one page and stopped.** Core's
  hook re-fires only when `data-cursor` *changes* (that is also what clears its
  in-flight guard) and the sentinel passed `data-page`. An IntersectionObserver
  fires on transitions only, and the sentinel stays in view, so it never fired
  again. Core's own `load_more` component passes `data-cursor`.
- **A double-click on Apply duplicated every created row.** `apply_pro100`
  had no guard; the one I first added — an "am I running?" flag — could never
  fire, as all three reviewing models pointed out: LiveView runs events one at
  a time and the handler is synchronous, so the flag is false again by the
  time the second event is dispatched. (`execute_import`'s version works
  because that path is asynchronous.) The guard now keys on the plan being
  consumed. Pinned by a test that creates one row and clicks Apply again:
  against the flag it created two.

### Security and data protection

- **An import failure logged the entire changeset.** `Exception.message/1` on
  an `Ecto.InvalidChangesetError` renders `changes` and `params` — raw rows
  from the operator's uploaded spreadsheet — into the log *and* onto the
  screen. Field names only now, the convention `web/helpers.ex` documents and
  `import/executor.ex` already followed.
- **`client_name` reached Storage as a filename with no `Path.basename`.**
  LiveView validates it against the `:accept` extension list and nothing else.
  Fixed at both upload boundaries.
- **Four sites used `Map.put_new` for `catalogue_uuid`**, so a client-supplied
  value in the form payload beat the server's scope from the URL — and
  `:catalogue_uuid` is in the cast allowlist.

### Performance

- **The Attributes tab ran one query per row** for its value previews, paged 25
  at a time, on a tab that reloads on every attribute-set and item broadcast.
  The batched counts were already two lines above; values now use
  `list_attribute_set_values_for/2` (verified taking the batched path on the
  dev box, not the per-uuid fallback).
- **Saving an item with K attribute sets** ran ~K redundant
  `SELECT catalogue_uuid` and sent K `:item` broadcasts, each making every open
  detail LiveView re-run `refresh_in_place`. One roll-up broadcast now, via the
  same `broadcast: false` convention the importer uses.
- **The items table scanned the whole item list once per row.**
  `any_media_thumb?/2` ran 101 times per render on a full page — hoisted,
  exactly as the categories table 600 lines earlier already does.
- **`ItemFormLive` subscribed after its initial read**, so a write landing in
  between was dropped and the form showed stale supplier rows until the next
  unrelated event.

### i18n and documentation

- **Nine strings rendered by the UI reached no catalogue at all.** The sharpest
  is `"Attribute set not found."`: `errors_test.exs` pinned
  `Errors.message(:set_not_found)` against it and passed *because* it was
  untranslated — a green test guarding the bug. Added by hand (the workflow
  this repo actually uses) and covered by the runtime-locale test.
- **`:file_too_large` and `:too_many_rows`** were the only atoms in the type
  union with no pin.
- **A dead inline JS hook** in the events page: it defined `InfiniteScroll`
  behind a `|| {…}` guard that core's bundle always won, and could not have
  taken effect on a LiveView navigation anyway.
- **`AGENTS.md` claimed the module ships no external hooks.** It ships two, via
  `js_sources/0` — a host believing that line would skip the compiler entry and
  both would die with `unknown hook found`.
- **A test named for a flash asserted only `is_binary`.** It now asserts the
  flash.

## Rejected after verification

- **"The `.pot` is hand-maintained, so extraction is broken"** — half right,
  and the half I got wrong is recorded above. The `g/1` and shim indirections
  the agent flagged are real but are a *consequence* of the hand-maintained
  workflow, not an independent defect.
- Several "missing gettext" flags on numeric placeholders (`"5"`, `"15"`,
  `"EUR"`, `"200MB"`) and on user-defined field labels.
- LIKE-injection and authorization both came back clean, which is worth
  recording: every `ilike` routes through `sanitize_like/1` or
  `escape_like/1` with no bypass, and every route is declared
  `level: :admin, permission: module_key()` with the one controller carrying
  its own plug.

## What an external panel found in the fixes

Four models reviewed the PR. Everything below was verified against the code
before being acted on; the two misdiagnoses above are theirs, and both were
right.

- **The catalogue-scope pin was on the create path only**, and bypassable on
  both. `save_item(:edit, …)` never pinned `catalogue_uuid`, and
  `derive_catalogue_uuid/2` only overrides the field when the item has a
  category — so for every smart item and every uncategorized standard one,
  nothing contradicted a forged value, and the move was logged as a plain
  `item.updated` rather than going through `move_item_to_catalogue/3`. A
  forged `category_uuid` naming a category in ANOTHER catalogue also beats
  the pin, by design: deriving the catalogue from the category is what makes
  a category move carry its items. Both closed, both pinned by tests driven
  as raw events — `form/3` refuses to send what the markup does not offer,
  which is precisely the assumption the bug lived inside.
- **`safe_exception_message/1` scrubbed one exception family of five.** The
  rescue feeding it lists `ArgumentError`, `RuntimeError`,
  `Ecto.InvalidChangesetError`, `Ecto.QueryError` and `Postgrex.Error`;
  everything but the changeset fell through to `Exception.message/1`. A
  unique violation reports `Key (sku)=(ACME-1) already exists` — a row from
  the operator's spreadsheet, in the log and on the screen. Each family now
  reports its structure instead: constraint and code for Postgres, field
  errors for a changeset, and the type name for the parser exceptions whose
  message often IS the offending cell.
- **`list_values_for/2` went public without the feature gate its twin has.**
  `list_values/2` returns `[]` with entities disabled; the batched form
  answered with live data, and its fallback called into an unloaded module.
- **The roll-up broadcast fired even when nothing changed.** Each individual
  write already declined to broadcast a no-op; rolling them into one
  unconditional `:item` event meant a name-only save delivered two — the
  second on top of `update_item/3`'s — so every open detail page ran
  `refresh_in_place/1` twice. That is the load the roll-up exists to remove.

## Open — recorded, not done

- **Activity logging gaps.** `catalogue/attributes.ex` has **7 unlogged
  mutations** (`update_attribute/2`, `reorder_attributes/2`,
  `create/update/delete_attribute_value`, `set_default_value/1`,
  `reorder_attribute_values/2`) — five of which have no `opts` argument at all,
  so they *cannot* accept an actor. `attribute_sets.ex:1470`
  `migrate_groups_to_sets/1` creates sets, values and attachments with zero
  logging while accepting an `actor_uuid`. `attachments.ex:265` `trash_file/2`
  is a destructive write with no audit. CRM link/unlink failures are unaudited
  end to end, because the compensating LiveView layer the convention relies on
  does not exist for CRM.
- **35 action strings written by `lib/` appear in no test**, and only 3 of 54
  files in `test/web/` use `assert_activity_logged` — so most destructive
  LiveView paths would still pass if they dropped `actor_uuid`.
- **135 orphaned msgids** in the catalogues with no call site (attribute-set
  editor, manufacturer/supplier forms and CRM UI that no longer exist). Two of
  them are *pinned as translated* by `gettext_test.exs`, i.e. green tests
  guarding strings nothing renders.
- **Position races on create.** `create_item/2` computes its position outside
  the transaction that inserts, and `create_category/2` has no transaction at
  all — two concurrent creates in the same bucket both read max and both write
  max+1. `create_catalogue/2` does this correctly, inside the lock.
  `CategoryFormLive` additionally seeds `position` in `mount`, holding the
  check-then-act window open for as long as the form is on screen.
- **12 guards `rescue` without `catch :exit`** (`counts.ex`,
  `supplier_comments.ex`, `attachments.ex` ×3, both browse components,
  `item_picker.ex` ×2, `events_live.ex` ×2, `supplier_fields.ex`,
  `translations.ex`). `manufacturers.ex` and `suppliers.ex` are the reference —
  they pair both.
- **Upload gating is `:accept`-only** — no content sniffing, and attachments
  use `accept: :any` with a 2 GB per-submit ceiling and a storage bucket chosen
  from the browser-supplied MIME.
- **Dead code:** `next_catalogue_position/0` (documented, specced, never
  called — and wrong for this schema's interleaved positions),
  `move_item_and_reorder_destination/4` (80 lines, no callers, no tests),
  `Tree.descendant_uuids/1` + `walk_subtree/3` + `build_children_index/1`,
  `party_items_columns/0`, `escape_html/1`. `item_pricing/1` returns 10 keys of
  which 8 have no reader outside tests, and it runs per card per render.
- **138 public functions have no `@spec`**, concentrated in `paths.ex` (all
  16), `web/components.ex` (29), `attachments.ex` (15) and the module
  registration API in `phoenix_kit_catalogue.ex` (14).
- **`handle_info` clauses with no test:** `{:catalogue_view_sort_changed, …}`
  (4 clauses, zero tests, and the producer sends a string where one consumer
  expects an atom), `{:catalogue_category_reorder, …}` (2),
  `{:pdf_search_modal_closed}` (3, and the three consumers clear *different*
  assigns), plus the AI-translation and supplier clauses.
- **Duplication:** `safe_return_to/1` byte-identical in 3 files, the
  `:self_wrapped_layout` `on_mount` in 8, the two-pass reorder writer in 4, and
  four `format_price` implementations with four different empty-value
  contracts (`"—"` vs `nil` vs `"0.00"`), so two admin tables render the same
  missing price differently.
- **Four return shapes for the same bulk-operation concept** in `Catalogue`,
  including `{count, nil}` — the raw `Repo.update_all` tuple — leaked as public
  API and matched literally in tests.
- **Test smells:** `assert is_binary(html)` standing in for a content
  assertion in six places, `function_exported?` as a behaviour stand-in, five
  "catch-all swallows stray messages" tests that pass against a LiveView with
  no catch-all at all, and six bare `assert true`.
