# Phase 7 — Stock Deduction: Design v2 (APPROVED; implemented — see phase7-completion-report.md)

## 0. Confirmed decisions and pre-implementation checks (2026-09-21)
| ID | Decision | Status | How this design honours it |
|---|---|---|---|
| D1 | Atomically update `varient_stock.sold_count` | **Approved** | §3 step 4: conditional `UPDATE … sold_count = sold_count + ? WHERE … remaining >= ?`, `affectedRows` checked; the only legacy-table write, data only |
| D2 | Block sale on insufficient stock | **Approved** | §6: strict 409 + shortages, no override |
| D3 | `status = 0` batches only | **Approved** | §3 queries and UPDATE both filter `status = 0` |
| D4 | Fix legacy `stockService.js` separately | **Approved (separate phase)** | Out of Phase 7 scope; POS never calls or edits it; §11 residual risk stays until that phase |
| D5 | READ COMMITTED + single connection + `FOR UPDATE` | **Approved with conditions** | §4. Conditions as I understand them (please correct if different): (a) `SET TRANSACTION ISOLATION LEVEL READ COMMITTED` scoped to the one POS connection only, before `START TRANSACTION`, never global/session-leaking into the pool (reset in `finally`); (b) every stock read inside the transaction is `FOR UPDATE` on the pinned connection; (c) the conditional UPDATE guard is kept even with locks; (d) concurrency suite passes identically at READ COMMITTED (and is re-run at REPEATABLE READ for comparison); (e) no change to global isolation or to legacy connections |
| D6 | FK to `varient_stock(id)` | **Conditional — only if no legacy schema change** | **Verified compatible** (§0.1): `varient_stock.id` is `bigint(20)` PK, InnoDB; an FK to a primary key needs no new index or alteration on the legacy table. Kept as an outbound FK only; if the migration ever required altering `varient_stock`, the FK is dropped and integrity is enforced by the transaction + reconciliation report instead |
| D7 | Piece-based ledger | **Conditional — verify** | **Verified for the POS path** (§0.1), with 9 anomalous rows to review and a pre-enable production check listed |
| D8 | Feature flag default off | **Approved** | §9 `POS_STOCK_DEDUCTION_ENABLED` |
| D9 | Reconciliation report | **Required in Phase 7** | §6 / §10: shipped script + tests are a completion criterion |

### 0.1 Verification results (read-only; no legacy change)
1. **`tax_rate` stores percent, not fraction.** Column `pos_sale_items.tax_rate DECIMAL(10,3)`; migration 005 documents it as percent; the completion path writes `p.t.percent` (12, not 0.12). Now proven by a committed test (`persisted tax_rate is a PERCENT …`) reading the raw column: `12` (not `0.12`), `tax_included` 0/1, `tax_amount` 600 for 5000 × 12%. Suite: 58 tests, 57 pass, 0 fail, 1 skipped (the 57-test baseline all still passes; +1 new).
2. **D6 compatibility.** Real-schema `varient_stock`: `id bigint(20) NOT NULL AUTO_INCREMENT PRIMARY KEY`, InnoDB, utf8mb4_general_ci; indexes `fk_varient_id(varient_id)`, `company_id`, `status`; an existing FK from `varient_id` to `product_variation.variation_id ON DELETE CASCADE`. `pos_sale_item_batches.batch_id BIGINT` matches exactly. No legacy alteration needed. Note: the cascade means deleting a product variation cascades to its batches; our RESTRICT FK would then block that delete when POS attribution exists — intended, but flagged for the legacy admin UX.
3. **D7 units.** (a) Legacy deduction quantity = `qty × pieces` for packs, `qty` for pieces (`orderAPI.js` 58–60, 553–556) ⇒ ledger unit is the piece. (b) `sell_price` is per piece: on the real-schema clone, 376 of 385 multi-piece variations with a pack price satisfy `pack_sale_price ≈ sell_price × pieces` (0 satisfy `pack_sale_price ≈ sell_price`). POS sells `sell_price × quantity` ⇒ POS quantity = pieces ⇒ deduct exactly `quantity` from the ledger. (c) No fractional `stock/sold_count/return_qty/damage_qty` in the 595 sampled batches (integers only) — the deduction still guards `DOUBLE` noise. (d) **Open items**: 9 multi-piece rows do not satisfy (b) (list them before enabling); many products have `unitType` KG/GR (weight units) — POS quantities are integers, so **weighed/fractional sales are out of scope** and must be blocked or left to a later phase; run the same checks read-only against production as a pre-enable gate.
4. **Fixture fidelity gap.** The committed test fixture's `varient_stock` lacks the real table's `created_at/updated_at` columns, its three separate indexes and its FK to `product_variation`. Lock/gap behaviour depends on indexes, so **the concurrency and rollback tests run in both the fixture DB and the real-schema smoke clone**; the fixture's `varient_stock` is upgraded to mirror the real definition (columns, indexes) as part of implementation, before any deduction code is written.
5. Existing negative batches: 6 of 579 active batches in the clone (6 of 722 live) — recorded as the pre-existing baseline for reconciliation.

#### The 9 D7 anomalies (all company 142, `packtype = '1'`, weight units KG/GR)
| id | variation | unit | pieces | sell_price | pack_sale_price | sell × pieces |
|---|---|---|---|---|---|---|
| 1264 | VARIATION1264 | KG | 10 | 5.500 | 82.500 | 55.000 |
| 1268 | VARIATION1268 | KG | 6 | 5.500 | 68.000 | 33.000 |
| 1354 | VARIATION1354 | GR | 25 | 5.700 | 79.800 | 142.500 |
| 1355 | VARIATION1355 | GR | 20 | 5.700 | 79.800 | 114.000 |
| 1412 | VARIATION1412 | GR | 30 | 12.300 | 135.300 | 369.000 |
| 1413 | VARIATION1413 | GR | 14 | 12.300 | 135.300 | 172.200 |
| 1447 | VARIATION1447 | KG | 16 | 5.300 | 47.700 | 84.800 |
| 1558 | VARIATION1558 | GR | 30 | 8.600 | 68.800 | 258.000 |
| 1579 | VARIATION1579 | GR | 30 | 0.900 | 22.500 | 27.000 |
No consistent relation between the two prices (some higher, some lower), so I cannot tell from data which is authoritative for these rows. They are weight-based products, already out of scope for integer-quantity POS sales. Proposed handling: **POS refuses to add/complete lines whose variation is in a "not piece-based" class** (unit KG/GR-type, or pricing-relationship anomaly) until the business confirms — or the rows are reviewed by you. Decision needed: block weight-unit variations from POS entirely in Phase 7 (recommended), or sell them as whole units.

### Implementation gate
Implementation starts only when: this v2 is confirmed (D5 conditions wording, the 9 D7 anomalies acknowledged, weighed items out of scope); then order of work: (1) mirror real `varient_stock` in the fixture, (2) migration 006 on test/smoke DBs, (3) failing tests first (concurrency, rollback, idempotency, reconciliation), (4) deduction code behind the flag, (5) full suite + smoke run, (6) completion report. Completion is not claimed until all four test groups pass.

Status: approved 2026-09-21 (D5 conditions, weight-unit block, production read-only gate confirmed by the product owner). Implemented behind `POS_STOCK_DEDUCTION_ENABLED` (default off); legacy `stockService.js` untouched and **not reused**. Tax is final (`tax-arithmetic-trace.md` §6).

## 1. Current inventory schema analysis
| Fact | Evidence |
|---|---|
| Ledger = `varient_stock` batches (`varient_id varchar(20)`, `company_id`, `stock`, `return_qty`, `sold_count`, `damage_qty`, `date`, `batch`, `status`). Remaining = `stock + return_qty − sold_count − damage_qty`. The app's displayed stock counts `status = 0` batches only. | `stockService.js::ShowVarientStock`; Phase 3 |
| `product_variation.stock` is a stale cache: equals the ledger for only 552 of 655 active variations; legacy deduction never updates it. POS must never read or write it. | live read-only query |
| `order_item_batches` (per-order batch attribution) has FKs to legacy `cart_detail(id)` and `order(id)` ⇒ POS cannot reuse it. | `SHOW CREATE TABLE` |
| `varient_stock.varient_id` is `varchar(20)` vs `product_variation.variation_id` `varchar(255)` (FK exists). Type/collation must be matched in any new FK/join. | schema |
| Returns/damage in legacy add to `return_qty`/`damage_qty` on a **specific batch id** ⇒ POS needs per-sale batch attribution to support returns later. | `stockService.js` 4–58 |
| Ledger unit assumed = piece (legacy passes `quantity × pieces` for packs). **Must be confirmed on real data before enabling.** | `orderAPI.js` 558 |
| Sale lines are unique per variation per sale (`UNIQUE(sale_id, product_variation_id, status)`), so one deduction per variation per completion. | POS schema |

## 2. Existing FIFO behavior and risks
Legacy `reduceStockAndUpdateSoldCount` (does the FIFO the business expects: oldest `date` first, spilling across batches):
1. Reads batches with remaining > 0 **without a status filter and without a row lock**, then `UPDATE sold_count = sold_count + ?` unconditionally ⇒ two concurrent orders read the same remaining and both deduct (lost-guard oversell).
2. Its transaction spans **different pooled connections** (empirically: 60 concurrent vs. a 20-connection pool deadlocked/leaked in Phase 3) ⇒ begin/commit/rollback do not cover the updates.
3. Real damage already present: **6 of 722** `status = 0` batches have negative remaining.
4. Counter-risk of copying it: including `status = 1` batches would sell from batches the app hides.
Conclusion: POS reimplements FIFO (same ordering semantics) safely, in its own code; legacy is not modified or called.

## 3. Proposed POS stock-deduction flow
Inside the existing completion transaction (`completeSale`), after cheap validation and before the final version-checked sale UPDATE. One `withTransaction` connection for everything:

`lock sale → idempotency/state/ownership/version checks → recompute prices+tax → payment-sum check → snapshot lines → deduct stock → insert attribution → insert payments → final sale UPDATE (+ stock_deducted=1) → commit`

Per completion:
1. Sort sale lines by `variation_id` ascending (global lock order).
2. Per variation, same connection:
   ```sql
   SELECT id, stock, return_qty, sold_count, damage_qty FROM varient_stock
    WHERE varient_id = ? AND company_id = ? AND status = 0
      AND (stock + return_qty - sold_count - damage_qty) > 0
    ORDER BY date ASC, id ASC FOR UPDATE
   ```
   `company_id` always comes from the authenticated context (`req.pos`), never the client.
3. Allocate FIFO in JS (integers; remaining < 1e-9 is empty because columns are `DOUBLE`). Collect **all** shortages across lines first, then fail once.
4. Per allocation, a conditional atomic update as a second guard beside the lock:
   ```sql
   UPDATE varient_stock SET sold_count = sold_count + ?
    WHERE id = ? AND company_id = ? AND status = 0
      AND (stock + return_qty - sold_count - damage_qty) >= ?
   ```
   `affectedRows` must be 1 or the transaction aborts — the DB itself refuses to push a batch negative.
5. Insert one `pos_sale_item_batches` row per allocation.
6. **No reservation**: draft/held carts hold no stock; a held cart can fail at completion for lack of stock (documented UX consequence). Nothing to release on hold/cancel.

## 4. Transaction and locking strategy
- **Order**: sale row → batches by ascending `(variation_id, date, id)`. Carts with the same items in any order lock identically ⇒ no lock cycles among POS transactions.
- **Single connection**: only `posDb.withTransaction`'s connection is used; no call into `stockService`/`config/db` pool helpers (the legacy bug class).
- **Deadlock/timeout** (`1213`/`1205`): whole-transaction automatic retry once (nothing was committed; idempotency key protects the client), then a "retry" error — never a partial result.
- **Isolation**: proposal to run this transaction at READ COMMITTED to avoid gap locks blocking legacy batch inserts; to be measured, not assumed (decision D5).
- **Timeouts**: bounded `innodb_lock_wait_timeout` behaviour verified in tests; no user-visible hang beyond it.

## 5. Concurrency scenarios (each becomes a test, §10)
| Scenario | Expected |
|---|---|
| N concurrent completions of one variant, S units, qty q each | exactly ⌊S/q⌋ succeed, rest 409; no batch negative; Σ`sold_count` = Σ succeeded qty |
| Same, 60 concurrent vs. a 20-connection pool | identical outcome, no hung/leaked connection |
| Two carts, same items, opposite insertion order | no deadlock (or one auto-retry); both correct |
| Same sale completed concurrently twice (double-tap) | one completes; the other replays (same key) or 409; stock deducted once |
| Completion vs. hold/cancel/resume of *other* sales | no interference |
| Different companies, same `varient_id` string | isolated by `company_id`; neither affects the other |
| POS completion racing an **unlocked legacy-style writer** | POS's own guard holds (POS never itself drives a batch negative); legacy may still overshoot — documents §11 residual risk |
| Batch turns `status=1` / stock added mid-flight | locked read decides; result consistent with committed state |

## 6. Error and rollback behavior
- **Insufficient stock** (strict): `409` with `shortages: [{item_id, product_variation_id, requested, available}]`; zero rows changed; sale stays `draft`, cashier can edit and retry. (No manager override: POS has no manager role yet — D2.)
- **Any failure** at stock UPDATE, attribution insert, payment insert, or final sale UPDATE ⇒ full rollback of stock, `sold_count`, attribution, payments, line snapshots; sale unchanged. Verified by trigger injection at every step.
- **Partial deduction prevention**: all-or-nothing by construction (one transaction) + conditional UPDATE guard + `affectedRows` check + post-deduction assertion `Σ allocations == Σ line quantities` before commit.
- **Failure recovery**: crash/connection loss mid-transaction ⇒ MySQL rolls back; client retries with the same idempotency key. Commit-acknowledgement lost ⇒ retry hits the replay path (sale already `completed`) and returns the stored result, no re-deduction.
- **Audit**: `pos_sale_item_batches` (who/what/which batch/qty/when) + `stock_deducted` + existing completed-sale snapshot. Attribution rows are immutable (no UPDATE path except the returns phase's `return_qty` columns). A reconciliation query/script (attribution vs. `sold_count`, and negative-batch report) ships with the phase.

## 7. Idempotency interaction
Idempotent replay (same key + same fingerprint) short-circuits **before** the deduction step and returns the persisted snapshot + `stock_allocations` from `pos_sale_item_batches` — never recomputed from live stock. Same key, different payload ⇒ 409 with stock untouched. A failed (rolled-back) attempt leaves no key stored, so the retry is a fresh, fully-checked attempt. The unique idempotency key + sale row lock guarantee at most one deduction per sale across retries and races.
**Offline / client-generated IDs**: the client's idempotency key (string 8–64) is the dedupe identity for a queued offline completion; a sale replayed hours later is re-validated against *current* stock and may legitimately 409 (stock was sold elsewhere while offline) — the client must surface it as a conflict for a human decision, not auto-retry forever. Client-generated sale ids are not introduced here (server ids remain authoritative); a full offline sync protocol stays out of scope.
**Multi-company isolation**: company from the token; stock queries and updates filter `company_id`; attribution rows use composite FKs `(id, company_id)` so cross-company rows are impossible at the DB level; tested with two companies sharing a `varient_id`.

## 8. Schema changes required (proposed, not created)
```sql
CREATE TABLE IF NOT EXISTS pos_sale_item_batches (
  id BIGINT NOT NULL AUTO_INCREMENT,
  company_id INT NOT NULL,
  sale_id INT NOT NULL,
  sale_item_id INT NOT NULL,
  varient_id VARCHAR(20) NOT NULL,
  batch_id BIGINT NOT NULL,            -- varient_stock.id (exact column type verified before migration)
  qty INT NOT NULL,
  return_qty INT NOT NULL DEFAULT 0,   -- reserved for the returns phase
  damage_return_qty INT NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_psib_sale (sale_id), KEY idx_psib_batch (batch_id),
  CONSTRAINT fk_psib_item  FOREIGN KEY (sale_item_id, company_id) REFERENCES pos_sale_items (id, company_id) ON DELETE RESTRICT,
  CONSTRAINT fk_psib_sale  FOREIGN KEY (sale_id, company_id)      REFERENCES pos_sales (id, company_id)      ON DELETE RESTRICT,
  CONSTRAINT fk_psib_batch FOREIGN KEY (batch_id) REFERENCES varient_stock (id),
  CHECK (qty > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
ALTER TABLE pos_sale_items ADD UNIQUE KEY IF NOT EXISTS uq_pos_sale_items_id_company (id, company_id);
ALTER TABLE pos_sales ADD COLUMN IF NOT EXISTS stock_deducted TINYINT(1) NOT NULL DEFAULT 0;
```
Only POS-owned tables are altered/created. `fk_psib_batch` is an outbound FK to a legacy table (no change to that table); it also stops legacy code deleting a batch POS has sold from (D6 — confirm acceptable). Migration is idempotent (`IF NOT EXISTS`), numbered `pos_migration_006_*`, applied to test DB and smoke DB first; `busskit_new` only after approval and a backup.
**The only legacy-table write** is `UPDATE varient_stock SET sold_count` (data, not schema) — needs explicit approval (D1).

## 9. API changes required
`POST /api/v1/pos/sales/:id/complete`: same request; **new failure** `409` `{message, shortages[]}`; successful and replayed responses add `stock_allocations: [{item_id, batch_id, qty}]` and `stock_deducted: true`. No new endpoints. Browse/cart unchanged (they may later show live available quantity — out of scope). Void/return of completed sales remains unsupported until the returns phase (uses the attribution table, mirrors `UpdateReturnStock` on the specific batch). `POS_STOCK_DEDUCTION_ENABLED` (default off): off = exact Phase 6 behaviour and `stock_deducted = 0`.

## 10. Test plan (isolated DB `busskit_new_pos_test`; real-schema smoke on scrubbed clone; never `busskit_new`)
- **Correctness**: single batch; multi-batch FIFO by `date, id`; exact-remaining; one-over ⇒ 409 + shortage list + zero changes; `status=1` batch ignored; multi-line with one short line (all-or-nothing); attribution sums to line qty; `stock_deducted` set; flag off ⇒ no stock change; different company same `varient_id` untouched.
- **Idempotency**: replay does not deduct twice; different-payload replay 409 leaves stock untouched; retry after rolled-back failure succeeds once; replay returns stored allocations.
- **Concurrency**: all scenarios in §5, including 60-vs-20 pool and opposite-order carts.
- **Rollback (trigger injection)**: fail at stock UPDATE, attribution insert, payment insert, final sale UPDATE ⇒ everything unchanged; clean retry succeeds.
- **Regression/isolation**: full existing suite (57 tests) still green; migration idempotency ×2 on each DB; before/after checksums of every legacy table except intended `varient_stock.sold_count` deltas; smoke DB run over sampled real products asserting ledger delta == completed qty and no batch newly negative; unit assumption check on real data.
- Smoke remains opt-in (`POS_SMOKE=1`), restricted `pos_smoke` user, no customer data.

## 11. Migration rollback plan (and residual risk)
- **Rollback of schema**: `DROP TABLE pos_sale_item_batches; ALTER TABLE pos_sales DROP COLUMN stock_deducted; ALTER TABLE pos_sale_items DROP KEY uq_pos_sale_items_id_company;` (POS-owned only; safe if table empty or after stock reversal).
- **Rollback of data**: set the flag off (new sales stop deducting). Deducted stock is reversible from the attribution rows via a reviewed script (`UPDATE varient_stock SET sold_count = sold_count − qty` per row, inside a transaction, dry-run first) — never automatic. Pre-enable: `busskit_new` backup + snapshot of the 6 already-negative batches so they are not blamed on POS.
- **Residual risk POS cannot remove**: the legacy deduction path stays lock-free/unconditional; a concurrent legacy order can still oversell a batch POS also sells from. Only a separately designed, tested and approved hardening of `stockService.js` fixes it. Not part of Phase 7.

## 12. Decision register (see §0 for confirmed status; only D5 wording, D6/D7 conditions remain to confirm)
| # | Decision | Recommendation |
|---|---|---|
| D1 | Allow POS to `UPDATE varient_stock.sold_count` (first data write to a legacy table, no schema change)? Alternative = separate POS ledger (rejected: allows double-selling the same physical stock). | Approve |
| D2 | Insufficient stock: strict block vs. allow-negative with override | Strict block |
| D3 | Batch eligibility: `status = 0` only vs. legacy unfiltered | `status = 0` only |
| D4 | Authorise (separately, later) a hardened legacy `stockService.js`? | Separate phase, own design |
| D5 | READ COMMITTED for the completion transaction, subject to measurement | Approve |
| D6 | Outbound FK `pos_sale_item_batches → varient_stock(id)` acceptable? | Approve |
| D7 | Confirm ledger unit is the piece for products sold at the register | Confirm on real data |
| D8 | Feature flag default off + staged rollout (test DB → smoke DB → dev `busskit_new` → prod) | Approve |
| D9 | Ship the reconciliation/negative-batch report with this phase | Approve |

Out of scope: returns/voids/restock, reservations, adjustments, transfers, promotions, gateway, offline sync protocol, legacy code changes.
