# Phase 7 stock deduction — production preflight report

Date: 2026-09-22. Scope: sections 3A–3E of the Phase 3 task brief (Stock
Preflight Preparation). **No production database was queried or connected to
in the course of writing this report** — see §0. This is a review of the
existing Phase 7 implementation and its own prior findings, not a fresh data
pull.

## 0. Why no live production check was run

`database/pos_stock_preflight.js` and `database/pos_stock_reconciliation.js`
(in `buskit-web`, read-only, not modified) both refuse to run unless
`POS_RO_DB_USER`, `POS_RO_DB_NAME` (and `POS_RO_DB_PASSWORD`,
`POS_RO_DB_HOST`) are set to a least-privilege account, and they refuse the
`root` user (`database/posReadOnlyConnection.js`). I checked — without
printing any value — and **none of the `POS_RO_DB_*` variables are set**, not
in `buskit-web/.env`, not in `buskit-web/.env_production`, not in this shell's
environment. Per the task brief ("use only the existing least-privilege
read-only production credentials... never use root credentials") and the
project's own standing rule not to ask for secrets in chat, I did not create
an ad hoc account, did not fall back to the application's full-privilege DB
config, and did not touch `busskit_new`.

**To complete sections A–C and E against live data**, you need to set those
four variables (yourself, not pasted into chat) to a `SELECT`-only MySQL
account on the production host, then run:
```
POS_RO_DB_USER=... POS_RO_DB_PASSWORD=... POS_RO_DB_HOST=... POS_RO_DB_NAME=busskit_new \
  node database/pos_stock_preflight.js --json > preflight.json
POS_RO_DB_USER=... POS_RO_DB_PASSWORD=... POS_RO_DB_HOST=... POS_RO_DB_NAME=busskit_new \
  node database/pos_stock_reconciliation.js --json > reconciliation.json
```
from `buskit-web`. Both are already written, already tested (see the Phase 7
completion report), and cover exactly what sections A–C ask for. What follows
is what code review and the last run (on a scrubbed clone, not production;
`docs/phase7-stock-deduction-design.md` §0.1, `docs/phase7-completion-report.md`
finding 7) can support today, clearly marked as such.

## A. Database prerequisites

| Check | Status |
|---|---|
| Migration 006 applied to `busskit_new` | **Not applied.** `database/pos_migration_006_stock_deduction.sql` exists in the `buskit-web` working tree as an **untracked, uncommitted file** (`git status` in `buskit-web` shows it under `??`). It has not been run anywhere near production. `docs/phase7-completion-report.md` states it was applied only to the isolated test DB and a scrubbed clone. I did not apply it and did not query `busskit_new` to double-check, per §0. |
| `pos_sale_item_batches` table / `pos_sales.stock_deducted` column / `fk_psib_batch` FK exist in `busskit_new` | Unverified live (needs `POS_RO_DB_*`; `pos_stock_preflight.js` reports this as `pos_objects`). Expected **false** given migration 006 is unapplied. |
| `varient_stock` compatible (InnoDB, `id` bigint PK, indexed `varient_id`, required columns) | Verified once, read-only, against the real schema per the design doc §0.1 (2026-09-21): InnoDB, `id bigint(20) AUTO_INCREMENT PRIMARY KEY`, index `fk_varient_id(varient_id)`, all required columns present. This was a one-time schema check, not re-run today. |
| Outbound FK `pos_sale_item_batches.batch_id → varient_stock(id)` | Design-verified as buildable without altering `varient_stock` (PK target). Not yet created (depends on migration 006 being applied). |

**Migration 006 is idempotent (`IF NOT EXISTS` throughout) and creates
POS-owned objects only** — it does not alter `varient_stock` or any other
legacy table. It is safe to review but I did not apply it (out of scope for
this task, and it should go through a backup first per the design doc's own
checklist).

## B. Product/unit compatibility

The backend's actual sellability gate (`services/pos/posSellability.js`) blocks
**only** an exact (trimmed, case-insensitive) match against:
`kg, kgs, kilogram, kilograms, gr, g, gm, gms, grm, gram, grams`.

The preflight script additionally flags anything that *looks* weight/volume-
based by a looser pattern (leading-quantity forms like `1KG`, and units the
exact block list misses) as `unclassified_weight_like_unit_types` — those are
not blocked by the running code today, which is exactly the gap the task asks
about.

| Unit (as given) | Classification | Why |
|---|---|---|
| `KG` | **BLOCKED** | Exact match in the sellability block list; POS already refuses these (`POS_WEIGHT_UNIT_NOT_SUPPORTED`, 422) at add-to-cart and at completion, independent of the stock-deduction flag. |
| `GR` | **BLOCKED** | Same — exact match. |
| `ML` | **REQUIRES BUSINESS DECISION** | Not in the block list, so POS currently treats it as a normal piece-sold unit. On the scrubbed clone (2026-09-21, not live), 20 variations used it. |
| `L` | **REQUIRES BUSINESS DECISION** | Same gap. 5 variations on the clone. |
| `1KG`, `25KG`, `2KG` | **REQUIRES BUSINESS DECISION** — and the sharpest gap of the set | These do **not** exact-match `kg` (leading digit), so today's code sells them as ordinary pieces even though they are weight quantities. On the clone: `1KG` × 4, `25KG` × 1, `2KG` × 1 variations. If deduction is enabled before this is decided, these would deduct one "piece" per unit sold regardless of the stated weight — silently wrong, not blocked. |
| `mg` | **REQUIRES BUSINESS DECISION** | Not blocked; 7 variations on the clone. |
| Other weight/volume-like spellings (`ltr`, `litre`, `liter`, `ton`, `tonne`, `lb`, `lbs`, `oz`) | **REQUIRES BUSINESS DECISION if present** | Covered by the same detection pattern in the preflight script; none were reported on the clone, but this has not been checked against current production data. |
| Everything else (e.g. `unit`, `pack`, `box`, `piece`, `pcs`, `each`) | **SUPPORTED** | Piece-based; the ledger unit is verified to be the piece for the POS path (design doc §0.1/D7: legacy deduction = `qty × pieces` for packs, `qty` for pieces; `sell_price` is per piece for 376/385 sampled multi-piece rows). |

**Important caveat**: the counts above (`ML` 20, `L` 5, `1KG` 4, `25KG` 1,
`2KG` 1, `mg` 7) are from a **scrubbed clone examined on 2026-09-21**, not from
current production data, and I did not re-run the check today (§0). Treat them
as "known to exist as of yesterday's clone," not as today's production truth —
re-run `pos_stock_preflight.js` against production once credentials are
available and use its `weight_units.unit_type_distribution` and
`unclassified_weight_like_unit_types` output as the authoritative list.

**No code change was made to how these units are handled.** Per the task
brief, I did not decide behavior for the unresolved units — they are reported,
not silently fixed.

## C. Stock data quality

`services/pos/posStockPreflight.js` and `posStockReconciliation.js` already
check every item the brief lists:

| Check | Covered by | Last known result (clone, 2026-09-21) |
|---|---|---|
| Missing/no stock batches for a variation | `weight_units.stocked_variations` vs `variations` (weight units only; the same query pattern applies to all) | 441 of 476 weight-unit variations had stock batches on the clone; not separately reported for non-weight variations in that run |
| Invalid/negative stock | `negative_batches` (preflight) / `negative_batches` (reconciliation, with `has_pos_attribution`) | 6 pre-existing negative batches, unrelated to POS (baseline before any POS activity) |
| Unusual quantity precision (fractional stock) | `units.fractional_quantity_batches` | 0 fractional batches in 595 sampled — integers only |
| Per-piece pricing inconsistency (proxy for ambiguous/duplicate stock semantics) | `units.per_piece_pricing_anomalies` | 9 rows, all company 142, all `packtype='1'`, all weight-unit (KG/GR) products — listed in `docs/phase7-stock-deduction-design.md` §0.1; no consistent rule found (`pack_sale_price` is sometimes above, sometimes below `sell_price × pieces`) |
| Duplicate/ambiguous stock rows, inactive batches | `pos_objects` / schema checks (indexes, keys) | Schema-level checks passed on the real-schema clone; row-level duplicate detection was not part of the reported findings and would need a fresh run |
| Reconciliation (attribution vs ledger consistency) | `posStockReconciliation.js`, 4 issue types + negative-batch report | N/A yet — reconciliation only has meaning once sales exist with `stock_deducted=1`; since the flag has never been on anywhere real, there is nothing to reconcile in production |

None of this was re-verified against live data today; it is what the existing,
tested tooling last reported on a non-production clone, restated here so it's
in one place with today's date on it.

## D. Production database safety

- I did not use, print, or ask for `POS_RO_DB_*` values, `POS_JWT_SECRET`,
  device secrets, or PINs anywhere in this session.
- I did not open a connection to `busskit_new` (production or otherwise) at
  any point.
- I did not modify `posReadOnlyConnection.js`, `pos_stock_preflight.js`,
  `pos_stock_reconciliation.js`, `posStockService.js`, or any other
  `buskit-web` file (that repo remains read-only for this project; `git
  status` in `buskit-web` shows no changes from this session — see the final
  report's git-status section).
- I did not apply migration 006 anywhere, and did not enable
  `POS_STOCK_DEDUCTION_ENABLED` (verified unset in both `.env` files and in
  this shell's environment; `posStockService.isEnabled()` defaults to `false`
  when unset).

## E. Reconciliation

Not run today (no `POS_RO_DB_*`, see §0). The tooling exists, is tested
(`docs/phase7-completion-report.md`: reconciliation test group — clean state
passes, detects all four issue types, reports negative batches with
`has_pos_attribution`), and is safe to run read-only once credentials are
supplied. Since `stock_deducted` has never been set to 1 anywhere outside the
isolated test DB, a production reconciliation run today would be expected to
report `ok: true` with zero POS-attribution rows — but that is an expectation
based on the flag being off, not something I confirmed by running the script.

## Summary

| Question | Answer |
|---|---|
| Is migration 006 applied to production (`busskit_new`)? | **No** — file is uncommitted in `buskit-web`, not run anywhere near production. |
| Is `POS_STOCK_DEDUCTION_ENABLED` on anywhere? | **No** — unset in both `.env` files and this shell; code defaults to off. |
| Did preflight run against production today? | **No** — blocked on missing `POS_RO_DB_*` credentials; this is expected and by design (the scripts refuse to run without them, and refuse `root`). |
| Blocking issues | Missing `POS_RO_DB_*` credentials (blocks A/C/E against live data); migration 006 not applied (blocks enabling the flag even after credentials exist). |
| Warnings | Weight-like unit spellings not covered by the exact block list (`ML`, `L`, `1KG`, `25KG`, `2KG`, `mg`, and possibly others in current data); 9 per-piece pricing anomalies (company 142) with no clear resolution rule; baseline of 6 pre-existing negative batches (not POS-caused, but worth knowing before enabling); all figures are a day old (scrubbed clone) and need re-confirmation on live data. |
| Unresolved business decisions | Whether `ML`/`L`/`1KG`/`25KG`/`2KG`/`mg` (and any other weight/volume-like spelling found in production) should be blocked like `KG`/`GR`, sold as whole pieces, or handled some other way; how to treat the 9 per-piece pricing anomaly rows. |
| Did stock deduction get enabled? | **No.** Not touched in this session. |
