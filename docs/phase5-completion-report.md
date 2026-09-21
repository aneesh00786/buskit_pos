# Phase 5 — Cart Implementation: Completion Report

Implemented exactly the approved v2 plan, plus the two final requirements from the last review round. Two real bugs were found and fixed during testing — both documented below, not glossed over.

## 1. Migration executed

`database/pos_migration_003_sales_cart.sql` run against `busskit_new`, exit 0, confirmed idempotent (re-ran cleanly a second time). Created `pos_sales` and `pos_sale_items` exactly per the approved v2 schema — composite FK, `UNIQUE(id, company_id)`, `NOT NULL device_id`, `CHECK (quantity > 0)` all verified present via `SHOW CREATE TABLE`.

## 2. Two real bugs found during testing (not just the planned test scenarios)

**Bug 1 — `req.pos.shiftId` was never populated, anywhere.** Every cart-mutation endpoint depends on knowing the caller's current shift (for draft-cart ownership), but `posDeviceAuth.js` never set `req.pos.shiftId` — shift context was never part of the JWT payload or the auth middleware's output in any prior phase (Phase 2 never needed it). Fixed by adding a live lookup in `posDeviceAuth.js`, for staff-scoped tokens only: `shiftRepo.findOpenByRegister(req.pos.registerId)`, reusing the existing Phase 2 repository function and the same `open_lock`-guaranteed "at most one open shift per register" invariant. This follows the same "live, not cached" pattern already established for device/staff status in Phase 3.1 — a shift closing mid-session is picked up on the very next request, not just at token-issue time.

**Bug 2 — MariaDB's `CHECK` constraint violation errno collides with an unrelated MySQL-named constant in `mysql2`.** Confirmed empirically: the real error is numeric `errno: 4025` (MariaDB's `quantity > 0` constraint failing, message correctly reads `CONSTRAINT 'CONSTRAINT_1' failed`), but `mysql2`'s symbol table names error 4025 `ER_INNODB_AUTOEXTEND_SIZE_OUT_OF_RANGE` (a MySQL constant with no relation to CHECK constraints at all). `posErrorHandler.js` now matches on the numeric `errno === 4025` (documented as unreliable-by-name, reliable-by-number) and maps it to a proper `422` instead of falling through to a generic `500`.

Both fixes are in POS-owned files only; neither required touching any existing buskit-web file or table.

## 3. Files

**New**: `Controllers/POS/PosSaleController.js`, `services/pos/posSaleService.js`, `repositories/pos/posSaleRepository.js`, `validation/pos/posSaleValidation.js`, `database/pos_migration_003_sales_cart.sql`.
**Modified** (all POS-owned, from earlier phases): `Routes/posRoutes.js` (+9 routes), `repositories/pos/posProductRepository.js` (exposed `status` on `findById`'s return — Phase 5's availability check needs to tell active from inactive, which Phase 3's `findById` didn't previously report), `middleware/posDeviceAuth.js` (shift-context lookup, bug 1), `middleware/posErrorHandler.js` (errno 4025 handling, bug 2).
**Unchanged since Phase 2**: `server.js` (still the same approved 2-line diff, reconfirmed via `git diff --stat`).

## 4. The two "final requirements" from the last review, confirmed in the implementation

1. **One transaction per item mutation, no split connections**: every mutation (`addItem`/`updateItem`/`removeItem`/`hold`/`resume`/`cancel`) runs inside a single `posDb.withTransaction()` call — lock sale (`FOR UPDATE`) → validate ownership/state/version → lock+merge the existing active item if present (same transaction) → bump version → commit, all on one connection. Verified structurally (one `withTransaction` call wraps the entire sequence in `posSaleService.js`) and functionally (the resume-race test below proves the locking actually serializes concurrent writers, which wouldn't be possible if reads and writes crossed connections).
2. **`company_id` never trusted from the client**: confirmed by a dedicated test — a request body containing forged `company_id`/`store_id` values was submitted, and the created row was checked directly in the database to confirm it used `req.pos`'s real values, not the forged ones. Product-variation company ownership is validated the same way it was in Phase 3 (`posProductRepository.findById`/`findByBarcode`, already company-scoped — a cross-company product id simply returns "not found," per the existing convention).

## 5. Test results — 19/19 passed (Phase 5), 84/84 across all phases combined

```
PASS - composite FK rejects a direct insert with mismatched company_id
PASS - adding a cross-company product to a sale returns 404, never leaks the product
PASS - adding the same product twice merges into one active line
PASS - remove then re-add the same product creates a new active row (not a constraint violation)
PASS - merging past the 9999 cap is rejected with 422
PASS - stale expected_version returns 409 with current version/state
PASS - resume race: two concurrent resume attempts on the same held cart, exactly one succeeds
PASS - missing expected_version is rejected at validation (422), never reaches the transaction
PASS - viewing a sale with an active product shows availability_status: available
PASS - attempting to ADD an inactive product as a new line is rejected (409), not silently added
PASS - canceling a draft cart from the SAME shift succeeds
PASS - canceling a draft cart from a DIFFERENT shift at the same store is 403
PASS - canceling a HELD cart from a different shift at the SAME store succeeds (store-level permission)
PASS - canceling an already-canceled sale is 409
PASS - a forged company_id/store_id in the request body is ignored — server uses req.pos
PASS - invalid quantities are rejected with 422 at validation
PASS - a direct repository-level insert with quantity=0 is rejected by the DB CHECK constraint
PASS - company isolation: listing sales for company B never shows company A's store's sales
PASS - unauthorized access (no token) is 401

19 passed, 0 failed, 19 total
```

Full regression: Phase 2 (26/26), Phase 2.1 (7/7), Phase 3 (19/19, read-only check passed), Phase 3.1 (13/13) — **84/84 total**, run against real data with two real companies (company 1: 107 active variations, known barcode `1232321321` on item id 2; company 142: 417 variations, used only for cross-company checks). All `pos_*` tables confirmed empty after the run; `product_variation.id=2`'s temporarily-toggled `status` confirmed restored to `1`.

The resume-race test is the most functionally important one: two concurrent HTTP requests (different shifts, same store) both attempt to resume the same held cart with the same `expected_version` — exactly one gets `200`, the other `409`, proving the `FOR UPDATE` lock + version-check combination actually serializes concurrent writers rather than just looking correct on paper.

## 6. What's explicitly not in Phase 5 (unchanged from the plan)

No `complete` action, no `pos_sale_payments`, no stock deduction/reservation (only Phase 3's existing read-only product/price lookup is reused for live pricing), no `pos_audit_logs`, no `pos_returns`. `test/pos/` remains deferred, consistent with every prior phase.

No existing buskit-web table, column, index, constraint, or row was modified. No existing source file was modified beyond the already-approved `server.js` 2-line mount (unchanged since Phase 2).
