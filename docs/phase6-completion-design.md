# Phase 6 — Completion, Pricing, Payments & Idempotency: Design + Decision Record

**Status: DESIGN ONLY, with three prerequisite corrections/actions completed per your review.** No `pos_sales`/`pos_sale_items`/`pos_sale_payments` completion columns/tables exist yet, no completion route/controller/service written — that part is still design only, awaiting your final go-ahead. What **has** been done, per your explicit instructions to complete before implementation:

1. **Tax formula corrected — and the bug it caught was already live, not just theoretical.** You caught that this design's prose formula (`line_tax = tax_rate * quantity`) was dimensionally wrong, and that the design's own example already used the correct math. Checking the actual Phase 5 code that this design explicitly reuses (`posSaleService.js::buildSaleView`) found **the exact same bug already shipped** — `lineTax = taxRate * item.quantity`. Fixed there directly (not just in this document): `lineTax = lineSubtotal * taxRate`. Added a regression test using a real company-1 product with a non-zero tax rate (id 9, 30% tax) asserting the exact subtotal/tax/grand totals — the old formula would have failed it. Full regression re-run: **85/85 passing** (84 prior + this new test).
2. **Isolated POS test database built** (§7) — a real, separate MySQL database (`busskit_new_pos_test`) with its own MySQL user (`pos_test`) that has **zero grants on `busskit_new`**, verified by directly attempting to connect (`Access denied`). Minimal fixture schema + data, all three existing POS migrations run against it successfully, and a committed Node helper (`test/pos/helpers/testDb.js`) with hard guards. Details in §7.
3. **Cash tender validation and idempotency-replay fingerprinting** — both specified below (§2, §4).

This document still stops short of writing the completion controller/service/routes — that remains gated on your final approval of the corrected design.

---

## 1. Existing workflow reference (brief — full analysis already done in Phases 1/4)

`order`'s payment fields, confirmed live in Phase 4: `payment_status` (`0=not paid,1=paid,3=partial`), `payment_type` (`0=cash,1=cheque,2=bank transfer`), `payment_detail` (a single free-text varchar), `received_amount`/`received_amount_date`. **There is no split-tender/multi-payment table anywhere in the core system** — one order has at most one payment record's worth of fields. POS's own `pos_sale_payments` (§3) is therefore a genuine capability the core system doesn't have, not a mirror of an existing pattern — worth stating plainly rather than implying continuity that doesn't exist.

---

## 2. Completion flow (matches your recommended sequence, expanded with the specific checks)

`POST /api/v1/pos/sales/:id/complete` — staff-authenticated. Body: `{ expected_version, idempotency_key, payments: [{ method, amount, tendered_amount? }] }`.

**Cash tender validation rules** (new, per review):
- `tendered_amount` **must be `NULL`/omitted** for `method: 'card'` or `method: 'other'` — a value there is a validation error (`422`), not silently ignored.
- For `method: 'cash'`: `tendered_amount` is **required** and must be `>= amount` (fixed-point comparison, 3 decimals) — you cannot tender less than the amount being applied.
- `change_due = tendered_amount - amount`, computed server-side and stored — never accepted from the client. **Never negative** (guaranteed by the `tendered_amount >= amount` check above, not a separate clamp).
- `amount` (the value that must sum to `grand_total` across all payments) is always the amount **applied to the sale** — change is a cash-handling detail on top of that, never a reason `amount` itself differs from what's actually owed.
- All monetary comparisons throughout completion use fixed-point arithmetic at 3 decimal places (matching the `DECIMAL(*,3)` columns) — never a raw floating-point `===`.

Entirely inside one `posDb.withTransaction()` call (continuing Phase 5's established pattern — never split across connections):

1. `SELECT * FROM pos_sales WHERE id = ? AND company_id = ? FOR UPDATE` — lock, same as every Phase 5 mutation.
2. **Idempotency check, before anything else**: if `sale.status === 'completed'`:
   - `sale.idempotency_key === request.idempotency_key`:
     - **and** the replayed request's fingerprint matches the stored one (§4) → return the **existing** completed sale (200), no reprocessing, no new payment rows. This is the actual "network dropped the first response, client retried" case idempotency exists for.
     - **but** the fingerprint differs (same key, different `payments[]` or different sale id somehow reaching this row) → `409` ("Idempotency key reused with a different request") — the key alone is not treated as sufficient proof it's a genuine replay.
   - Key doesn't match at all → `409` ("Sale already completed") — a different key against an already-completed sale is treated as a new, illegitimate attempt, not silently accepted.
3. `sale.status !== 'draft'` (for any other status: `held`, `canceled`, `voided`) → `409`. **A `held` sale must be resumed first** — completion is only a `draft → completed` transition, matching Phase 5's state diagram exactly; there is no direct `held → completed` path.
4. Ownership: `req.pos.shiftId === sale.shift_id` (same rule as every other `draft`-state mutation in Phase 5).
5. `expected_version` mismatch → `409` (identical mechanism to Phase 5's other mutations).
6. **Item validation**: fetch active line items; for each, live-check the product exactly as Phase 5's `buildSaleView` already does. If **any** item is `unavailable` → `409`, listing the affected item ids — this is the exact commitment Phase 5's plan already made ("Phase 6 will reject completing a sale with any unavailable items"), now being kept.
7. Reject if there are **zero** active line items (`422` — can't complete an empty cart).
8. **Server-side price/tax recompute** — re-derive `unit_price`/`tax_rate` from the *current* `product_variation` row for every line (same source Phase 5's live view already uses), compute `line_subtotal = unit_price * quantity`, **`line_tax = line_subtotal * tax_rate`** (tax_rate is a percentage, e.g. `0.180` = 18% — corrected per review; the original prose here had the same `tax_rate * quantity` bug already found and fixed in Phase 5's live code, per the status note above), `line_total = line_subtotal + line_tax`. **Never reads a client-submitted price, tax, or total from the request body — there is no such field in the request shape at all**, closing that class of tampering by construction, not by validation.
9. **Write the immutable snapshot** onto each `pos_sale_items` row (the columns Phase 5's migration comment explicitly reserved for this: `unit_price`, `tax_rate`, `tax_amount`, `discount_amount` (`0`), `line_total`).
10. Sum into sale-level `subtotal`/`tax_total`/`discount_total` (`0`)/`grand_total`.
11. **Payment validation**: `payments` must be non-empty; each `amount > 0`; each `method` in `('cash','card','other')`. **`SUM(payments[].amount)` must equal `grand_total` exactly** (fixed-point comparison at 3 decimal places, matching the `DECIMAL(*, 3)` columns — never a floating-point `===`). Mismatch in either direction → `422` (both "not enough" and "too much" are rejected — change is handled *within* a single cash payment's `tendered_amount`/`change_due`, not by overpaying the `amount` field).
12. Insert one `pos_sale_payments` row per tender, in the same transaction.
13. Generate `sale_number = 'POS-' || LPAD(id, 8, '0')` (decision #1, confirmed).
14. `UPDATE pos_sales SET status='completed', sale_number=?, idempotency_key=?, idempotency_request_hash=?, subtotal=?, tax_total=?, discount_total=0, grand_total=?, completed_at=NOW(), version=version+1 WHERE id=? AND company_id=? AND version=?` — the same version-checked update pattern as every Phase 5 mutation, just with more columns.
15. Commit. Return the completed sale (items now carrying immutable snapshots, plus `payments[]` and `sale_number`).

Any failure at any step → the whole transaction rolls back — no partial state (a payment row without a completed sale, or vice versa, is structurally impossible since both writes are in the same transaction, satisfying "payment and completion must commit or roll back together" directly).

---

## 3. Schema changes (design only — not created)

### `ALTER TABLE pos_sales` — add immutable sale-level totals

```sql
ALTER TABLE pos_sales
  ADD COLUMN subtotal DECIMAL(12,3) NULL AFTER version,
  ADD COLUMN tax_total DECIMAL(12,3) NULL AFTER subtotal,
  ADD COLUMN discount_total DECIMAL(12,3) NULL DEFAULT 0 AFTER tax_total,
  ADD COLUMN grand_total DECIMAL(12,3) NULL AFTER discount_total;
```
Nullable because `draft`/`held` sales never populate these (Phase 5's decision: totals are computed live for in-progress carts, never stored) — they're written exactly once, at completion, and never change afterward. `sale_number` and `idempotency_key` already exist as columns from Phase 5's original migration (always `NULL` until now) — no new column needed for either.

### `ALTER TABLE pos_sale_items` — add the immutable per-line snapshot

```sql
ALTER TABLE pos_sale_items
  ADD COLUMN unit_price DECIMAL(10,3) NULL AFTER quantity,
  ADD COLUMN tax_rate DECIMAL(10,3) NULL AFTER unit_price,
  ADD COLUMN tax_amount DECIMAL(10,3) NULL AFTER tax_rate,
  ADD COLUMN discount_amount DECIMAL(10,3) NULL DEFAULT 0 AFTER tax_amount,
  ADD COLUMN line_total DECIMAL(12,3) NULL AFTER discount_amount;
```
This is precisely the migration Phase 5's own file comment already promised: *"Phase 6 will `ALTER TABLE` this table to add the pricing-snapshot columns when completion is built — an expected future migration, not an oversight."*

### New table `pos_sale_payments`

```sql
CREATE TABLE IF NOT EXISTS `pos_sale_payments` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `sale_id` INT NOT NULL,
  `company_id` INT NOT NULL,
  `method` ENUM('cash','card','other') NOT NULL,
  `amount` DECIMAL(12,3) NOT NULL,
  `tendered_amount` DECIMAL(12,3) NULL,
  `change_due` DECIMAL(12,3) NULL,
  `reference` VARCHAR(255) NULL,
  `status` ENUM('completed') NOT NULL DEFAULT 'completed',
  `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_pos_sale_payments_sale` (`sale_id`),
  CONSTRAINT `fk_pos_sale_payments_sale_company` FOREIGN KEY (`sale_id`,`company_id`) REFERENCES `pos_sales` (`id`,`company_id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CHECK (`amount` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
```
Continues the same composite-FK pattern proven in Phase 5 (cross-company integrity enforced at the DB level, verified empirically there — not re-proposed as new, just reused). `status` is a single-value enum (`'completed'`) deliberately — Phase 6 never records a `pending`/`authorized` payment state, since there's no real gateway integration (that's Phase 9). `reference` is for a manually-entered card auth code or similar — **never a raw card number, CVV, or track data**, continuing the same rule stated for `pos_devices`/`pos_staff_pins` secrets in every prior phase.

---

## 4. Idempotency — the exact mechanism, tied to the existing schema, now with replay fingerprinting

`pos_sales.idempotency_key` already exists (Phase 5, `UNIQUE`, currently always `NULL`). Phase 6 activates it at completion time only (not at cart-creation — that's `client_generated_id`'s job, a separate concept for offline cart identity, decision #10). The `UNIQUE` constraint is a second, structural safety net beyond the request-level check in step 2 above: if a client somehow reused the same `idempotency_key` across two genuinely different sales, the second `UPDATE`'s attempt to set that key would hit the unique index and fail with `ER_DUP_ENTRY` — already mapped to `409` by the existing `posErrorHandler.js`, no new error-handling code needed.

**Replay fingerprinting (new, per review)**: a bare key match isn't proof the replayed request is actually the *same* request — a client bug (or something adversarial) could send the same key with a different `payments[]` payload and, without a fingerprint check, would silently get back whatever the *original* request produced, masking the mismatch. Fix: store a SHA-256 hex digest of a canonical JSON representation of `{ sale_id, expected_version, payments }` (**`idempotency_request_hash`**, new column, `CHAR(64)`, nullable) alongside `idempotency_key` at completion time. On a replay with the same key, recompute the hash of the *new* request and compare — mismatch → `409`, not a silent "successful" response for a materially different request.

```sql
ALTER TABLE pos_sales
  ADD COLUMN idempotency_request_hash CHAR(64) NULL AFTER idempotency_key;
```

---

## 5. Response schema

```json
{
  "status_code": 200, "status": true, "message": "Sale completed",
  "data": {
    "id": 42, "status": "completed", "sale_number": "POS-00000042",
    "items": [
      { "id": 101, "product_variation_id": 2, "quantity": 3,
        "unit_price": 1250.000, "tax_rate": 0.180, "tax_amount": 675.000, "discount_amount": 0, "line_total": 4425.000 }
    ],
    "totals": { "subtotal": 3750.000, "tax_total": 675.000, "discount_total": 0, "grand_total": 4425.000 },
    "payments": [
      { "method": "cash", "amount": 4425.000, "tendered_amount": 4500.000, "change_due": 75.000 }
    ],
    "completed_at": "2026-09-18T..."
  }
}
```
Note the shape change from Phase 5's live view: `items[].unit_price`/`tax_rate`/`line_total` are now the **persisted, immutable** values (read directly from `pos_sale_items`), not live-recomputed on every read — a completed sale never needs to re-join `product_variation` again, by design.

---

## 6. Critical safeguards — mapped to the exact mechanism enforcing each one

| Safeguard | Mechanism |
|---|---|
| Never trust client-submitted totals/tax/discount/price | The request body has no such fields at all — the completion endpoint's validation schema only accepts `expected_version`, `idempotency_key`, `payments[]`. Prices/tax are always re-derived server-side from live `product_variation` data (step 8). |
| Payment total = payable total | Exact `SUM(payments[].amount) === grand_total` check at 3-decimal fixed-point precision (step 11) — both under- and over-payment rejected. |
| Duplicate completion prevented | Idempotency-key replay check (step 2) + the `UNIQUE` constraint as a structural backstop (§4). |
| Payment + completion commit/rollback together | Single `posDb.withTransaction()` call wraps every write in the flow (§2) — the exact pattern already proven correct in Phase 5's resume-race test. |
| No stock deduction | Not present anywhere in this design — confirmed by omission, not by a guard that could be bypassed. |

---

## 7. The three formal decisions from this review round

### Decision 1 — Partial payment: REJECTED for Phase 6 (approved)

Exact-match payment validation stands as designed: `SUM(payments[].amount)` must equal `grand_total` exactly, both under- and over-payment rejected with `422`. Cash change is handled entirely through `tendered_amount`/`change_due` (§2), never by letting `amount` itself drift from the owed total. Pay-later, store credit, and installment payments are explicitly deferred — not designed, not stubbed, not partially supported. This was Phase 4.1 decision-record question #8, left open at the time; now resolved.

### Decision 2 — Payment status enum: stays `ENUM('completed')` (approved)

No `pending`/`authorized`/`failed`/`refunded` values added now — those belong to real gateway integration (Phase 9), designed when its actual requirements are known, not speculatively now. **Explicit rule, now stated**: the API request shape for `POST .../complete` has no `status` field on any payment object at all — `status` is set to `'completed'` by the server unconditionally, after all validation in §2 succeeds. A client cannot submit, override, or influence this value in any way, by construction (the field isn't read from the request), not merely by being ignored if present.

### Decision 3 — Isolated POS test database: BUILT (mandatory prerequisite, now complete)

Real infrastructure exists, not just a plan:

- **Database**: `busskit_new_pos_test`, separate from `busskit_new`, same MySQL instance (matching the "same server, different database" pattern already used for the main `busskit_new`/dev setup — no new server needed).
- **Dedicated credentials**: MySQL user `pos_test`@`localhost`/`127.0.0.1`, granted `ALL PRIVILEGES` on `busskit_new_pos_test.*` **only**. Verified directly: `mysql -u pos_test ... busskit_new` → `ERROR 1044: Access denied for user 'pos_test'@'localhost' to database 'busskit_new'`. This is a real, structural, MySQL-privilege-level guard — not an application convention that could be bypassed by a config mistake.
- **Minimum fixture data**: `database/pos_test_db_bootstrap.sql` — minimal (not full-schema-replica) copies of `company`/`salesmans`/`customers`/`categories`/`product_variation`/`varient_stock`, just the columns POS code actually reads, plus small fixture rows (2 companies, 3 salesmen, 3 products — one with a non-zero 30% tax rate specifically for exact tax-math tests, matching the regression test added per the status note above). Run once; safe to re-run (`INSERT IGNORE`).
- **Full POS schema**: the existing `database/pos_schema.sql`, `pos_migration_002_staff_pin_lockout.sql`, and `pos_migration_003_sales_cart.sql` run against this database completely unmodified — confirmed all three `EXIT 0`, all `pos_*` tables present.
- **Product status changes allowed**: since this database has no connection to real product data, tests may freely toggle `product_variation.status` (or anything else) without the Phase 5 disclosure concern — there is no "real" data here to protect.
- **Concurrency-safe**: the connection pool (`test/pos/helpers/testDb.js`) supports concurrent connections the same way `posDb.js` does against `busskit_new` — the resume-race-style concurrent test pattern from Phase 5 works identically here.
- **Reset between runs**: `testDb.resetTransactionalTables()` clears every POS transactional table (`pos_sales` down through `pos_stores`) and resets their `AUTO_INCREMENT`, while leaving the bootstrap fixture rows (companies/salesmen/products) intact and reusable — verified working (ran it, confirmed `pos_stores` back to 0 rows).
- **Guard against pointing at production/shared dev**: `test/pos/helpers/testDb.js` throws immediately if the resolved database name doesn't end in `_test`, or equals `busskit_new` by name, or if `NODE_ENV=production` — verified by deliberately pointing it at `busskit_new` and confirming the immediate, correct error. This is the **second** layer of defense on top of the MySQL-privilege-level one above, not the only one.

**Not yet done**: Phase 5's (and every prior phase's) tests still live in the session scratchpad, not ported to this new infrastructure — that's a separate, optional retroactive cleanup, not something this prerequisite required. Phase 6's own tests (once implemented) will be written as real, committed files under `test/pos/`, using this database, from the start — finally ending the "test/pos/ deferred" status carried since Phase 2.

### Cancellation policy — unchanged, reconfirmed

Phase 6 adds a `complete` transition only; it does not touch `cancel`/`hold`/`resume` or their documented ownership rules from Phase 5.

---

## 8. Test plan (to be run against `busskit_new_pos_test`, once implementation is approved)

Completion happy path (single cash payment, exact amount); completion with change (cash `tendered_amount` > `grand_total`, `change_due` computed correctly, `amount` still equals `grand_total`); non-cash payment with a `tendered_amount` present → `422`; split-tender (cash + card summing exactly to `grand_total`); payment total too low/too high → `422`; completing a `held` sale directly → `409` (must resume first); completing an empty cart → `422`; completing with an unavailable item → `409` listing the item; idempotent replay with a matching fingerprint (same `idempotency_key`, same `payments[]`, same result, no duplicate payment rows — verified via a row count on `pos_sale_payments`, not just the HTTP response); idempotency key replayed with a **different** `payments[]` payload → `409` (fingerprint mismatch, not a silently-returned stale result); a different `idempotency_key` against an already-completed sale → `409`; reused `idempotency_key` across two different sales → `409` via the `UNIQUE` constraint; stale `expected_version` → `409`; wrong-shift completion attempt → `403`; cross-company payment insert attempted directly at the repository layer → rejected by the composite FK (mirroring Phase 5's proof pattern); the tax-formula regression already added in Phase 5 (per the status note above), ported into this suite as a real committed test rather than a scratchpad one; before/after row-count check on the fixture core tables (`product`, `product_variation`, `company`, `customers`, `salesmans` — in `busskit_new_pos_test`, so free to also assert exact *content*, not just counts, given decision 3's "product status changes allowed" ruling).

**Stopping here — no completion controller/service/route implementation until this corrected design is reviewed and approved.**
