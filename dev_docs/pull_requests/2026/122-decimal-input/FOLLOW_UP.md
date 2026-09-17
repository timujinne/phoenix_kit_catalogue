# PR #122 follow-up

| Finding | Severity | Resolution |
|---|---|---|
| Core floor `>= 2.13.11` admits cores lacking `DecimalInput` / `Number.parse_decimal` (2.26.0+) | BUG - HIGH | Documented only, per the no-tightening policy: CHANGELOG 0.35.0 states "requires phoenix_kit 2.26.0+" |
| Golden item-form fixture stale after the input swap | NITPICK | Fixed: fixture regenerated (decimal inputs + core 2.26 `[dev]` badge) |
| Rule value accepts negatives | NITPICK | Not fixed: pre-existing, belongs to rule validation |

Shipped in 0.35.0.
