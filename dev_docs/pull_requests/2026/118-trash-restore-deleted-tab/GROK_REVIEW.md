# PR #118 — Grok review — trash card counts

**Reviewer**: Grok, no tools (answered from a written description of the trash and restore rules and the two count formulas)
**Date**: 2026-09-15
**Questions**: Q1 — does the trashed catalogue count equal what `restore_catalogue/2` brings back? Q2 — does the trashed category card count equal what `restore_category/2` brings back?

**Q1. Yes.**

(a) is the same set as “already live, or restored by `restore_catalogue(K)`”. Item-side `P` (`unstamped ∨ root=K`) matches the restore filter. Category-side `B` on the current row is the same as “NULL or not deleted after the category pass”, because that pass revives exactly the deleted cats of `K` that are unstamped or `root=K`. Already-live legacy items (uncascaded) stay live and pass `B` under the given operations: new trash of `K` would have deleted them, and a later trash of their category would stamp/delete them too. No shorter trash/restore/legacy sequence splits the two numbers.

**Q2. No.**

(b) walks only deleted children; `restore_category(C)` revives every descendant with `root=C`, then every `root=C` item whose category is live after that — **not** only items in the walked set.

Sequence: `C → A`, item `I` in `A`. Trash `C` (C, A, I all `root=C`). Restore category `A` (A live; C and I stay deleted).

- **(b):** Subcategories = 0 (A is live, walk stops), Items = 0 (`I` sits in A, not in `{C} ∪` walked descendants).
- **`restore_category(C)`:** 0 subcategories revived, **1 item** (`I`, category A already live).

(Whether A stays parented under C or is promoted out does not matter: restore still revives `I`, the walk still misses it.)
