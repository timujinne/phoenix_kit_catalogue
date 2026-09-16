# PR #121 follow-up

| Finding | Severity | Resolution |
|---|---|---|
| QtySignal highlight sticks on refused input ("2.5.1", "1e9") | BUG - MEDIUM | Fixed: the hook matches the server's number shape before flipping |
| Invalid `qty_precision` fails late or silently | IMPROVEMENT - MEDIUM | Fixed: `resolve_limits!/2` raises at init; test added |
| `round_limit/3` splits an unrelated comment block | NITPICK | Fixed: moved under `resolve_limits!/2` |

Shipped in 0.34.0.
