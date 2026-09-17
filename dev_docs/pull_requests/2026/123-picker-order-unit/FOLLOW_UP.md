# PR #123 follow-up

| Finding | Severity | Resolution |
|---|---|---|
| Dialect locale ("ru-RU") renders English unit labels | BUG - MEDIUM | Fixed: `unit_label_in/2` falls back to the base language; test added |
| `@doc` insertion orphaned the `presented_price_and_fee/1` comment | NITPICK | Fixed: comment moved back |
| Preselected entries ordered by map, not host order | NITPICK | Not fixed: would need an ordered `selected` API |

Shipped in 0.35.0.
