# Phase 6 — Completion Report (with Phase 2–5 test port)

Scope held: sale completion, immutable price/tax snapshots, split payments, exact payment validation, idempotency, transaction numbers. **Not touched**: stock deduction/reservation, returns, gateways, legacy tables, legacy source (beyond the already-approved 2-line `server.js` mount, unchanged).

## 1. Implementation summary

| Piece | File |
|---|---|
| Migration (idempotent, rollback documented) | `database/pos_migration_004_sale_completion.sql` |
| Validation (`validateCompleteSale`, integer-milli money) | `validation/pos/posSaleValidation.js` |
| Repository (`snapshotItem`, `insertPayment`, `listPayments`, `buildCompletionSetClause`) | `repositories/pos/posSaleRepository.js` |
| Service (`completeSale`, `buildCompletedSaleView`, request fingerprint) | `services/pos/posSaleService.js` |
| Controller + route `POST /api/v1/pos/sales/:id/complete` | `Controllers/POS/PosSaleController.js`, `Routes/posRoutes.js` |
| Test-mode DB binding | `repositories/pos/posDb.js` |

**Migration.** Every `ALTER` uses `ADD COLUMN IF NOT EXISTS` (MariaDB 10.4), plus `CREATE TABLE IF NOT EXISTS pos_sale_payments`. Adds sale totals + `idempotency_request_hash` to `pos_sales`, the snapshot columns to `pos_sale_items`, and the payments table (composite FK to `pos_sales(id, company_id)`, `CHECK amount > 0`). Run twice on each of `busskit_new` and `busskit_new_pos_test`; all four runs exit 0.

## 2. API behavior and payment rules

Body: `{ expected_version, idempotency_key, payments: [{ method, amount, tendered_amount?, reference? }] }`. Inside **one** `withTransaction`: lock sale `FOR UPDATE` → idempotency check → draft-only (held must resume first) → shift ownership → version check → items must exist and all be available → server-side recompute (`tax = line_subtotal * rate`) → `SUM(payments) == grand_total` exactly (integer thousandths) → snapshot items → insert payments → version-checked final update setting `status='completed'`, `sale_number='POS-'+8-digit id`, key, hash, totals.

- No client price/tax/total/status field is read. Payment `status` is always server-set `completed` (a test sends `status: "pending"`; stored value is `completed`).
- Cash needs `tendered_amount >= amount`; `change_due` is server-computed; non-cash may not carry `tendered_amount`.
- **Fingerprint**: SHA-256 of `{sale_id, expected_version, payments}` with payments sorted first → **payment order is not significant** (documented + tested). Same key + same fingerprint → original result, no writes. Same key + different payload → 409. Different key on a completed sale → 409. Key reused on another sale → 409 via the `UNIQUE` index, that sale left untouched.
- Completed sales are read from persisted columns only (no `product_variation` lookup); all cart mutations on them return 409.

## 3. Test results

Run: `NODE_ENV=test POS_TEST_DB_NAME=busskit_new_pos_test node --test --test-concurrency=1 test/pos/`

**46 tests, 46 pass, 0 fail — run three times consecutively** (repeatability), database left empty each time.

| File | Tests | Covers |
|---|---|---|
| `posAuth.test.js` | 9 | device/staff login, bcrypt PIN, unified 401, lockout + reset, live device re-validation (missing/deleted/inactive/revoked/forged/expired, mid-session revocation), scope refresh, missing secret → 500, rate limit |
| `posAdmin.test.js` | 4 | stores/registers/devices (secret shown once, hashed at rest), shifts (DB open-lock, only opener closes), company isolation, duplicate-key 409s |
| `posProducts.test.js` | 8 | search/pagination math, barcode/id scoping, categories/brands, invalid filters, `status=0`-only stock formula, SQL-injection literal, no-write check |
| `posCart.test.js` | 9 | scope from token, exact tax math, merge/remove/re-add/cap, quantity API + DB CHECK (errno 4025), composite FK, cross-company, version conflicts + concurrent-resume race, live availability, ownership tiers, no core-table writes |
| `posBootstrap.test.js` | 4 | rejection before any write, successful bootstrap w/ hashed PIN + device secret, once-only, transaction rollback keeps real error code |
| `posSaleCompletion.test.js` | 12 | all Phase 6 behavior above |

**Rollback evidence.** Real DB triggers (test DB only) inject a failure at (a) the item-snapshot update, (b) the payment insert, (c) the final sale update. Each returns 500; afterwards there are **no payment rows, no snapshot values, no `sale_number`, no idempotency key, version unchanged, status still `draft`**, and a retry then completes successfully. Key-uniqueness failure is covered by the key-reuse test (409, sale fully untouched). (c) uses trigger injection because the `FOR UPDATE` lock held for the whole transaction makes a version-mismatch at that step unreachable through real concurrent requests; the test proves the rollback mechanism, not that path's reachability.

**Isolation.** All tests use `busskit_new_pos_test` via user `pos_test` (no grants on `busskit_new`). In test mode `posDb.js` loads the guarded pool and never loads `config/db.js`. After the runs: every `pos_*` table in the test DB has 0 rows; `busskit_new`'s `pos_sales`/`pos_sale_payments`/`pos_stores` have 0 rows; test-DB fixture rows (products, salesmen) are unchanged.

## 4. Two defects found in the test infrastructure while porting (fixed)

1. `resetTransactionalTables()` did not include `pos_sale_payments`; with FK checks off, payment rows from earlier runs survived resets and attached to new sales reusing the same ids → false failures. Added; the Phase 6 file also now resets on exit.
2. Fixture barcode `TESTBARCODE01` (13 chars) was silently truncated by `INSERT IGNORE` into `varchar(10)` — the same real column limit noted in Phase 3. Fixture changed to `TESTBC0001`.

Also: `database/pos_bootstrap_company.js` now loads `config/db.js` lazily (CLI only), so importing it in tests cannot open a connection to `busskit_new`.

## 5. Legacy-module check

`server.js` diff is still exactly the approved 2 lines. No legacy controller/service/util/route file shows POS-related changes; no legacy table was altered. `git status` still lists unrelated pre-existing uncommitted work (Van Sales etc.) — not touched.

## 6. Known limitations / honest caveats

- **The Phase 2–5 tests were rewritten, not copied**: the original scratchpad files were lost when the session scratchpad was cleared, so the ported suite is a fresh re-implementation from the documented scenarios (46 tests total including Phase 6, vs. 85 counted before). It covers every scenario area in the reports but is against a 3-product fixture, not real data (107/417-product companies). Nothing verifies the ported tests would have caught every regression the originals could; treat "84/84 → 46/46" as different suites, not a like-for-like count.
- Regression on `busskit_new` itself is no longer exercised (deliberately): real-data behavior is only covered by the earlier phases' historical results.
- Tax uses `product_variation.tax` as a rate on `sell_price`; the real web-store checkout derives tax from `category_tax`. Pricing/promotion research (decision #8) is still open and must precede any real-money use.
- `posRateLimit` is in-memory/per-process. `sale_number` is ID-derived (`POS-` + id), not daily-reset. Completed sales expose no void/refund path yet (returns phase).
- `test/pos/` files must run sequentially (`--test-concurrency=1`) because they share one database and each resets it.
- Not yet done: `.env` remains tracked by git (pre-existing, flagged earlier); production `.env_production` still needs its own `POS_JWT_SECRET`.
- Phase 7 (stock deduction) is not started, per instruction; the single-connection + `FOR UPDATE` design requirements stand.
