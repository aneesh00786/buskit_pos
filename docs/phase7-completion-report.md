# Phase 7 — Stock Deduction: Completion Report

Status: **implemented and tested on the isolated fixture DB and the scrubbed real-schema clone. NOT enabled anywhere.** `POS_STOCK_DEDUCTION_ENABLED` defaults off. Production enablement is blocked on the read-only production preflight (user-supplied credentials) and migration 006 being applied to `busskit_new` (not done).

## What was built (all POS-owned; no legacy file, table, column, index or row changed)
| Area | File |
|---|---|
| Fixture fidelity (real `varient_stock` columns/indexes/FK) | `database/pos_test_db_bootstrap.sql` (idempotent, run twice) |
| Migration 006 (attribution table, `stock_deducted`, composite-FK target key) | `database/pos_migration_006_stock_deduction.sql` (idempotent; applied to test DB and smoke clone, **not** `busskit_new`) |
| Single-connection tx + per-transaction isolation + deadlock retry | `repositories/pos/posDb.js` (`withTransaction(work,{isolationLevel})`, `withDeadlockRetry`) |
| Ledger access (`FOR UPDATE`, conditional `sold_count` UPDATE, attribution) | `repositories/pos/posStockRepository.js` |
| FIFO allocation / shortages / partial-deduction guard | `services/pos/posStockService.js` |
| Weight-unit policy (extensible `getSellingMode`) | `services/pos/posSellability.js` |
| Wiring into completion + add-to-cart + completed view | `services/pos/posSaleService.js` |
| Error code + details rendering | `middleware/posErrorHandler.js` |
| Reconciliation (D9) + read-only production preflight (D6/D7) | `services/pos/posStockReconciliation.js`, `posStockPreflight.js`, CLIs `database/pos_stock_reconciliation.js`, `pos_stock_preflight.js`, `posReadOnlyConnection.js` |

## Behaviour
- Completion (flag on): lock sale → validate → recompute → weight-unit check → snapshot → **lock batches `FOR UPDATE` in deterministic order (variation id, then item id; batches by date,id), FIFO-allocate, conditional `UPDATE sold_count … WHERE remaining >= qty`, attribution rows** → payments → final version-checked update (`stock_deducted=1`). One connection, `SET TRANSACTION ISOLATION LEVEL READ COMMITTED` immediately before `START TRANSACTION` (one-shot form: applies to that transaction only, then reverts; never `SESSION`/`GLOBAL`). Deadlock/lock-timeout → whole transaction re-run once.
- Insufficient stock → `409`, `error_code: POS_INSUFFICIENT_STOCK`, `data.shortages[]` (all short lines), nothing changed, sale stays draft.
- KG/GR variations → `422`, `error_code: POS_WEIGHT_UNIT_NOT_SUPPORTED`, at completion (authoritative) and at add-to-cart; never converted to pieces. Only when the flag is on.
- Completed/replayed sale view adds `stock_deducted` and `stock_allocations`; replay never recomputes from live stock and never deducts twice.
- Flag off = exact Phase 6 behaviour (proved by an SQL-spy test: no isolation statement, no ledger lock/write, no attribution access).

## Test results (actual)
`NODE_ENV=test POS_TEST_DB_NAME=busskit_new_pos_test node --test --test-concurrency=1 test/pos/` ×3 consecutive runs: **98 tests, 96 pass, 0 fail, 2 skipped** (the two opt-in smoke files) each time. The 58-test pre-Phase-7 baseline is preserved (57 passing + 1 skipped); Phase 7 added 40 tests (39 run + 1 skipped smoke file). DB left empty after runs; no triggers left behind.
Opt-in `POS_SMOKE=1` on `busskit_new_smoke_test` (user `pos_smoke`): both smoke files **9/9 pass, twice**; the stock smoke test restores every `sold_count` it changes and asserts the whole ledger is byte-identical afterwards.

Coverage by required group:
- **Concurrency**: 20 concurrent on one variant (exactly ⌊S/q⌋ succeed, none negative, sold_count == attribution); **60 concurrent vs a 10-connection pool** (45 succeed / 15 blocked, no leak, pool usable after); READ COMMITTED vs REPEATABLE READ give identical outcomes; opposite-order carts (10 pairs, no deadlock); two registers contending for one batch; completion racing hold/cancel of other sales; same-sale double tap (same key → both 200, deducted once; different keys → 200 + 409); real-schema smoke: 25 concurrent on a real variation in both companies.
- **Rollback (trigger injection)**: failure at stock UPDATE, at the *second batch* UPDATE (first batch update rolled back), attribution insert, line snapshot, payment insert (after stock already deducted in-transaction), final sale update → stock, attribution, payments, snapshots unchanged, clean retry succeeds with exactly one deduction.
- **Idempotency**: replay returns stored allocations, no second deduction, unaffected by later live-stock changes; same key + different payload 409 with stock untouched; failed (blocked) attempt stores nothing so the same key succeeds after restock; stale offline completion is re-validated against current stock.
- **Reconciliation**: clean state passes; detects attribution/line mismatch, stock_deducted with no rows, attribution for an undeducted sale, `sold_count` below attribution; reports negative batches informationally (with `has_pos_attribution`); counts completed-without-deduction; CLIs refuse to run without `POS_RO_DB_*` and refuse `root`.
- **Isolation containment**: behavioural probe proves READ COMMITTED inside the transaction and default behaviour on every pooled connection afterwards; SQL spy proves `SET TRANSACTION ISOLATION LEVEL READ COMMITTED` immediately precedes `START TRANSACTION`, all ledger statements use one connection, never SESSION/GLOBAL; level string is whitelisted.
- **Correctness**: FIFO by date then id, exact remaining, one-over, `status=1` ignored, return/damage/sold honoured, multi-line all-or-nothing, all shortages reported, company isolation with a shared `varient_id`, composite/batch FKs, conditional-guard direct test, only `varient_stock.sold_count` changes in legacy tables.

## Findings and deviations to know about (honest disclosure)
1. **Order of work**: I drafted the stock modules before writing the tests, then wired them in only after the tests existed. The first test run against the un-wired code hung rather than failing cleanly, so I cannot claim a clean red→green cycle.
2. **Latent pool-starvation bug fixed (also affects flag-off)**: `completeSale` read products through a *second* pool connection while holding a transaction connection, so ≥ pool-size concurrent completions could deadlock the pool. Product lookup inside completion now uses the transaction connection (`findById(companyId, id, exec)`). Behaviour unchanged otherwise.
3. **`posErrorHandler` now renders `error_code` and `data` for non-500 errors.** Previously `err.extra` (e.g. `current_version`, `unavailable_item_ids`) was silently dropped; those fields now appear in `data`. Additive.
4. **`@@tx_isolation` does not show the one-shot level** and the test user lacks PROCESS, so isolation is proven by behaviour + SQL spy, not by reading a variable.
5. **Hazard caught before it hurt**: the shared reset helper would have wiped the smoke clone's stock/products; now guarded to the fixture DB only (clone verified intact: 595 batches, 581 products).
6. **Fixture changes**: the fixture `varient_stock` now mirrors the real table; the KG test product is created inside its test so Phase 3 product counts are unchanged.
7. **Real-data finding — weight units dominate the catalog**: on the clone, 476 of 581 variations (~82%; 404 of company 142's) are weight units by the block list (441 with stock). With the flag on, POS cannot sell them. Unit spellings **not** blocked: `ML` (20), `L` (5), `1KG` (4), `25KG` (1), `2KG` (1), and `mg` (7) appear in the data — a decision for you (block, or classify as pieces). Also 9 per-piece price anomalies (company 142, listed in the design doc) and the same 6 pre-existing negative batches; POS did not create any new negative batch in any run.
8. **Not verified on production**: the D6/D7 checks above ran on the test DB and the scrubbed clone only. `busskit_new` was not touched (no migration 006, no queries).
9. **Residual risk unchanged (D4)**: legacy `stockService.js` remains lock-free and unconditional; a concurrent legacy order can still oversell a batch POS also sells from. Separate phase, not started.
10. Test-DB timing-dependent tests use fixed contention sizes, not sleeps; 3 consecutive full runs were stable, but a heavier host could still expose timing sensitivity.

## Before enabling `POS_STOCK_DEDUCTION_ENABLED` anywhere real (checklist)
1. You create a least-privilege **read-only** DB account and supply `POS_RO_DB_*` yourself (not shared in chat; the scripts refuse `root` and never use `config/db.js`).
2. Run `node database/pos_stock_preflight.js` and `node database/pos_stock_reconciliation.js` against production; review warnings (weight-like unit spellings, price anomalies, negative-batch baseline); record output here.
3. Back up `busskit_new`; apply migration 006 (idempotent); re-run preflight (`pos_objects` all true).
4. Enable in dev first; run reconciliation after real sales; only then production. Rollback = flag off; reversal script from `pos_sale_item_batches` is documented in the design (not automatic, not yet written).
