# PR #124: Duplicate a catalogue, move anything to any catalogue, and fix the picker's missing photos — Zai review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/124
**Reviewer**: Zai (GLM-5.3), no tools; answered from a brief carrying the full `lib/` diff
**Date**: 2026-09-17
**Scope**: two rounds: the design draft before `da871e4`; a code review of the `lib/` diff at `c2116b6`

## Round 1: design of Duplicate catalogue

Overall: the draft's shape is right — it mirrors `duplicate_item` semantics, respects the lock protocol, collapses activity to one row, and runs off-request. The three weak spots are item-level decisions inherited unexamined at catalogue scale (slugs, query count), the untouched `ecommerce` namespace, and undefined behaviour at the trash boundary.

**1. Status: always archived.** The copy is born incomplete — empty slugs, "(copy)" names, no history — and duplication is inherently a staging operation (copy → edit → activate). Mirroring "active" publishes an unfinished object into every active-scoped picker the moment the flash renders; "X (copy)" already breaks any illusion that it's the same thing. Archived is also your safety net for the shop-by-name trap in Q6. Make it a *deliberate* deviation from "same fields" — as written, "same fields/data" mirrors status by accident.

**2. SKUs verbatim; slugs generate now.** SKU is not unique by schema and `duplicate_item` already keeps them — blanking destroys data nobody will re-enter at 3k scale. The one hazard (copy + source sharing SKUs in ecommerce-land) vanishes once you strip the ecommerce namespace (Q5). Slugs: verbatim is impossible anyway (table-wide per-language unique projection), and "the edit form fills it on next save" is fine for one item but means a 3k-item copy is born structurally incomplete and stays that way — nobody opens 3000 edit forms. Bulk-run the existing slug generator during the copy with deterministic disambiguation. If you keep them empty, that's one more reason the copy must start archived.

**3. One transaction + source lock — but attack the query count, and mind the snapshot.** All-or-nothing is the right semantics for Duplicate; chunking buys nothing at this scale and costs a cleanup path (classic bug farm) plus a half-visible copy. Three fixes: (a) 6–10 queries/item × thousands is where the minute comes from — batch the inserts (multi-row inserts for items, supplier rows, attribute joins, rules, FolderLinks) and the window drops to seconds; (b) one transaction at READ COMMITTED is *not* one snapshot — later statements see rows created mid-copy, and creates don't take the advisory lock (only trash/restore/reorder/move do). Read the whole source in one up-front pass, or run at REPEATABLE READ while still holding the lock (all writes are inserts, so serialization failure risk is ~nil); (c) set an explicit txn timeout, and note the copier *and* everyone blocked on the advisory lock each pin a pool connection. What breaks with the others: RR-without-lock gives a consistent *read* but not a consistent *outcome* — you faithfully copy rows being trashed or moved that instant (resurrecting trash, stale positions), and you break the protocol every other path respects. Chunked commits expose a partial catalogue mid-run, need failure cleanup that can itself fail, and either hold the lock across commits on one dedicated connection (awkward in Ecto) or let trash/move interleave with a half-built copy.

**4. Link-level ops are safe; file-level ops are shared fate.** Reordering is fine — FolderLinks are per-folder rows with their own positions, so the two folders order independently. What bites: hard-deleting or byte-replacing a file in Media hits source and copy simultaneously, and "removing a link never touches the original" trains users to expect independence that file ops don't have. Featured image is worse: it lives in `data` as `featured_image_uuid`, not as a link — the copy's hero references a file that isn't even linked from the copy's folder, invisible to folder cleanups and usage counts. Copying bytes: not worth it by default — it balloons both storage and the lock window (Q3). Later, offer it as an explicit opt-in for "this copy must fully diverge"; the honest mitigation now is the modal stating plainly that files are *shared* and deletions propagate.

**5. Two kinds of foreign content; treat them differently without learning the namespace.** (i) References to rows you copied — the ecommerce `featured_item_uuid`: you already hold the old→new uuid map for every copied row, so a generic pass rewriting any uuid in the data jsonb that matches a source row's uuid is namespace-agnostic and mechanically safe (a value equal to a copied row's uuid *is* a reference to that row, near-certainty). (ii) External identity — `shopify product_id`/`handle`: unremappable (the copy is a different product) and must be dropped, and only the shop knows that. So: catalogue does the generic remap and emits the duplication event + uuid map; the sibling registers a hook and strips its own ids — the ecosystem already has this shape (delete-guard registration). Never grep for "ecommerce" keys inside catalogue code; the next module breaks that rule.

**6. Shop-by-name traps.** (a) Rename-swap is the killer: source "Main" → "Main old", copy → "Main", and the shop silently rebinds to the copy — which, if Shopify ids survived (Q5), claims the *same* products: two catalogues writing one Shopify inventory with different markup/discount. (b) Second duplicate collides with "X (copy)" — either a dead insert (if names are unique) or "(copy) (copy)" stacking; disambiguate the suffix, and decide whether catalogue names are unique at all. (c) Non-unique names + exact-name resolution = ordering-dependent binding, and duplication systematically manufactures near-twin names. Catalogue-side you can only warn in the confirm modal when the source's name matches a shop binding; the real fix is shop-side — bind by catalogue uuid — and it's one setting.

**7. Misses, ranked (short):**
1. Ecommerce namespace copied verbatim — the draft's minus-list stops at `files_folder_uuid`/`_trash`; cross-linked featured items + Shopify double-claim is the worst latent bug here.
2. Items under trashed categories: the subtree pass skips the category, the uncategorized pass skips anything with a `category_uuid` — those items are silently *lost* unless trash cascades at trash-time. Define it and count them in the activity row.
3. Slugs at scale (see 2) and 4. the per-item query count / lock-pool window (see 3).
5. Smart-kind catalogues: the draft never says whether Duplicate is offered for them — it should be, but it's a different (cheap, config/rules-only) code path.
6. Double-click or LV remount during "Duplicating…" — the in-flight marker lives only in the LiveView; a remount loses it and a second click runs a second full copy.
7. Failure UX and an explicit transaction timeout — the draft only describes the happy path.

## Round 2: code review (`c2116b6`)

### 1. Lock ordering / deadlocks

**New paths vs trash/restore: sound.** Every new move path (`do_move_category_to_catalogue`, `do_move_category_under`, `run_bulk_move_items`, `locked_move_item_to_catalogue`) takes the catalogue advisory locks *first* (`lock_catalogues!` sorted), then row locks — the same order as trash/restore. Since row-only transactions (`create_item`/`update_item`) never wait on advisory locks, an advisory-first transaction can only be waited on by another advisory transaction that arrived first, so no mixed cycle forms there. `locked_move_item_to_catalogue` re-reads `from` inside the retried fn, so the stale-catalogue retry works. `duplicate_catalogue` never blocks on foreign row locks (inserts + unlocked selects + updates only to its own uncommitted rows), so it cannot be in a row-lock cycle at all.

**One real cycle exists, but it is pre-existing, not introduced** — flagging since `move_item_to_category` was touched:

- Tx A = `do_move_category_to_catalogue(R, T)`: advisory [S,T] → `FOR UPDATE` R → `update_all` on subtree **items** → `update_all` on subtree **categories**.
- Tx B = `do_move_item_to_category(X, cat_b)` (or `update_item`): `resolve_move_attrs` takes `FOR SHARE` on **cat_b** → `FOR UPDATE` on **item X**.
- Failing interleaving: X and cat_b both inside R's subtree (item dragged between two categories of the subtree while the subtree is moved). B takes FOR SHARE on cat_b; A locks X in its items `update_all`; B blocks on X; A blocks on cat_b's row (its categories `update_all` needs exclusive, B holds FOR SHARE). Postgres kills one with `deadlock_detected` — a DBError, not `:catalogue_moved`, so `locked_transaction` does not retry it. A locks items-before-categories, B categories-before-items. The `lock_live_item` addition doesn't change B's order, so no regression, but the new `FOR SHARE` in `check_move_parent!`/`lock_destination_category` is always taken before item writes, which is consistent — fine.

**Not a deadlock but a serialization defect:** `free_copy_number` takes the **global** `pg_advisory_xact_lock(hashtext("catalogue:copy-names"))` and holds it to commit, i.e. across the *entire* copy (`timeout: :infinity`). Every catalogue duplication system-wide queues behind the slowest in-flight one, with no lock timeout. Listed under 5.

### 2. `duplicate_catalogue` without a source lock

Assumption stated: `copy_category` re-queries children (and items) per node, as its single-struct API implies. Under READ COMMITTED with no source lock, each statement sees a different tree, while the roots list and the loose-item set come from the *first* statement. That mix is where the defects are.

**2a. Lost subtree — the fallback is NOT enough (main finding).**
`copy_loose_items(fresh.uuid, live_uuids, nested)` receives `live_uuids`, the *snapshot* set, as "copied". Interleaving: initial select reads live categories; trash commits on mid-tree category M (trash holds only the source's catalogue advisory — the duplicate holds nothing on the source); when the recursion reaches M's parent, the children query filters `status != "deleted"` and skips M, so M and its whole subtree are never copied; M's items have `category_uuid ∈ live_uuids`, so `not in ^copied` is false and loose-copy skips them too. Result: rows that were live at the read — exactly what "the copy is the source as the copy read it" promises — are silently absent from the copy, and the item count falls short of `catalogue_copy_counts`. Fix: derive "covered" from what the recursion actually copied (the log-derived mapping already holds exactly that set) instead of the snapshot.

**2b. Duplicated rows on an intra-subtree move.**
Category D lives under A; both under a selected root. The recursion enumerates A's children (sees D, copies D under copy(A)); a concurrent `move_category_under(D, B)` commits (B also in the copied tree, not yet enumerated); the recursion later enumerates B's children with a fresh query and copies D **again** under copy(B). Same shape for items moved between two copied categories after the first visit. The copy then contains a duplicated subtree, and `copy_mapping`'s `Map.put` keeps only the last copy per source uuid, so `remap_references!` points all references at one twin and the other is an unreferenced orphan. No invariant of the copy breaks (both placements are acyclic, parents exist) — but it is duplicated data.

**2c. Ghost root (minor, arguable).** A root trashed after the snapshot is copied from its stale struct with `status: source.status` = live. Snapshot semantics defend this, but combined with 2a the copy is neither snapshot- nor commit-consistent.

The fallback *is* adequate for the static cases it was written for (trashed parent at read → category becomes root; item under trashed category at read → uncategorized). Copy-internal invariants hold in all cases: parents are assigned by the recursion so no dangling parent or loop is possible.

### 3. `remap_references!`

- **Cannot miss inside `data`:** it re-reads every copy row (catalogue, categories, items) after all copies exist and walks maps/lists/binaries exhaustively; keys are preserved, only values are rewritten.
- **Overreach — yes, one class:** any binary exactly equal to a copied row's uuid is rewritten, with no namespace or field-shape check. A uuid-equality collision with a non-reference string is cryptographically implausible, so the practical case is *semantic*: a field that deliberately names the source (provenance like `duplicated_from`) is silently repointed at the copy. Whether that's wrong depends on what extensions store — **unsure**, but worth a convention ("source-provenance keys are exempt") before someone relies on it.
- References outside `data` (other tables — rules, comment threads) are neither remapped nor copied; if any exist they keep naming source rows. Probably intended, but nothing in the diff says so — **unsure**.

### 4. `bulk_move_categories_to_catalogue` selection

- **No double-move.** Overlapping subtrees in a tree imply an ancestor–descendant pair, which `nested_in_selection` drops, and uuids are `uniq`'d, so each row is written by at most one `move_category_to_catalogue`, each under its own locks with a fresh subtree computation. ✔
- **Two ways to lose one:**
  1. **Ancestor's move fails.** Selection {A, B}, B under A → B dropped as nested; A is trashed (or `parent_uuid` invalid) → A's move returns `{:error, :not_found}`; B is neither moved nor present in `errors`. Two rows selected, one error, one silent no-op. B (or an error for B) should be emitted whenever its ancestor's move failed.
  2. **Race on the drop decision.** `nested_in_selection` runs outside any transaction. B under A at that moment → dropped; a concurrent `move_category_under` lifts B out from under A; A's move (subtree computed fresh under lock) leaves B behind; B never moves, no error. Narrow window, real interleaving.
  - Variant worth checking (**unsure**, depends on whether `Tree.subtree_uuids` includes trashed rows): live D under trashed selected A — if the traversal includes trashed rows, D is dropped and A refuses, so D is stuck silently; if live-only, D moves itself correctly.

### 5. Anything else, ranked

1. **Extensions hook skipped for the catalogue row** — `copy_data(data, :catalogue, opts)` short-circuits past `Extensions.duplicate_data/2`. An extension storing an external id at catalogue level gets it duplicated verbatim — precisely the harm the hook exists to prevent. **Unsure** only because it matters iff some extension namespaces catalogue-level `data`.
2. **New untracked gettext msgid** — `"%{name} (copy %{number})"` is used via the runtime `Gettext.gettext` form, invisible to `mix gettext.extract`; it will ship untranslated until hand-added to the pot (this project's known trap).
3. **Copy-name uniqueness vs non-duplicators** — the `copy-names` lock only serializes copies; a concurrent rename/create committing the same "Name (copy)" doesn't take it. Without a DB unique index on live names, two live catalogues can share a name the shop resolves by. **Unsure** (depends on the index).
4. **Global serialization + unbounded waits** — the `copy-names` xact advisory held for the whole copy (`timeout: :infinity`) blocks every other duplication indefinitely; one big copy stalls the pool connection too.
5. **Performance nits** — `root_logs ++ logs` / `item_logs ++ logs` is O(n²) on large copies; `nested_in_selection` calls `load_uuid/1` per subtree member (N×M single-row loads).

### Checked and sound

- `locked_transaction` retry semantics on every `:catalogue_moved` rollback, including the stale-`from` re-read in `locked_move_item_to_catalogue` and the stale destination read in `run_bulk_move_items` (re-read under `FOR SHARE`, retried).
- `lock_live_item` re-read under `FOR UPDATE` refusing trashed items — also fixes the old stale-struct update in `move_item_to_category`.
- `check_move_destination!` (trashed/missing target → `:catalogue_not_found`, kind compare, same-catalogue `{kind, kind}` path) and `check_move_parent!` (FOR SHARE + raw-uuid subtree membership, foreign/trashed parent refusals).
- `move_category_under`'s new advisory + `FOR UPDATE` + status/cycle/catalogue_moved guards; `run_locked_reparent`'s target-before-item order (consistent with trash's category-then-items order, per its own comment).
- `bulk_move_items`: empty-list short-circuit, uuid validation, scope enforcement before writes, live-only `update_all` filter (safe under the advisory), both-catalogue locking, per-side broadcasts.
- `duplicate_catalogue`: `pg_try_advisory_xact_lock` per source (double-click safe, auto-released), fresh source re-read refusing trashed, remap confined to the copy's own rows, `duplicate_data` failure containment (raise/bad-return → drop namespace, logged; disabled extensions still consulted).
- `remap_value` key preservation and non-binary pass-through; file uuids and foreign uuids correctly untouched.
- `copy_category`'s new `:catalogue_uuid` plumbing keeping copied subtrees inside the copy catalogue (`ensure_same_catalogue!` against the copy, not the source).
