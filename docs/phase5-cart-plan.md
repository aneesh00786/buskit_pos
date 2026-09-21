# Phase 5 — Cart Implementation Plan v2 (proposal — nothing created yet)

Revision of the original plan, incorporating all 8 required clarifications from review. Builds on `phase4.1-decision-record.md`. Scope unchanged: cart CRUD only — create, add/update/remove item, hold, resume, cancel, view. No completion, payment, stock deduction, audit logs, or returns.

---

## 1. Tables (2 new, both in `busskit_new`) — final schema

### `pos_sales`

```sql
CREATE TABLE IF NOT EXISTS `pos_sales` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `company_id` INT NOT NULL,
  `store_id` INT NOT NULL,
  `register_id` INT NOT NULL,
  `shift_id` INT NOT NULL,
  `device_id` INT NOT NULL,
  `salesman_id` VARCHAR(70) NOT NULL,
  `customer_id` VARCHAR(255) DEFAULT NULL,
  `sale_number` VARCHAR(20) DEFAULT NULL,
  `status` ENUM('draft','held','completed','canceled','voided') NOT NULL DEFAULT 'draft',
  `client_generated_id` VARCHAR(64) DEFAULT NULL,
  `idempotency_key` VARCHAR(64) DEFAULT NULL,
  `version` INT NOT NULL DEFAULT 1,
  `notes` VARCHAR(255) DEFAULT NULL,
  `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `held_at` DATETIME DEFAULT NULL,
  `canceled_at` DATETIME DEFAULT NULL,
  `completed_at` DATETIME DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pos_sales_id_company` (`id`,`company_id`),
  UNIQUE KEY `uq_pos_sales_sale_number` (`sale_number`),
  UNIQUE KEY `uq_pos_sales_device_client_id` (`device_id`,`client_generated_id`),
  UNIQUE KEY `uq_pos_sales_idempotency_key` (`idempotency_key`),
  KEY `idx_pos_sales_company_status` (`company_id`,`status`),
  KEY `idx_pos_sales_store_status` (`store_id`,`status`),
  KEY `idx_pos_sales_shift` (`shift_id`),
  KEY `idx_pos_sales_salesman` (`salesman_id`),
  CONSTRAINT `fk_pos_sales_company` FOREIGN KEY (`company_id`) REFERENCES `company` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_sales_store` FOREIGN KEY (`store_id`) REFERENCES `pos_stores` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_sales_register` FOREIGN KEY (`register_id`) REFERENCES `pos_registers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_sales_shift` FOREIGN KEY (`shift_id`) REFERENCES `pos_shifts` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_sales_device` FOREIGN KEY (`device_id`) REFERENCES `pos_devices` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_sales_salesman` FOREIGN KEY (`salesman_id`) REFERENCES `salesmans` (`salesman_id`) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_sales_customer` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`customer_id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
```

**Changed from v1**:
- Added `UNIQUE KEY uq_pos_sales_id_company (id, company_id)` — a redundant-but-valid composite unique index (MySQL/MariaDB allow this alongside the plain PK) whose only purpose is to serve as a composite foreign-key target for `pos_sale_items` (§1's item #1 below).
- `device_id` changed from `DEFAULT NULL` to `NOT NULL`, and its FK from `ON DELETE SET NULL` to `ON DELETE RESTRICT`. Reasoning (point 6 of the review): every authenticated request already has a real `req.pos.deviceId` (guaranteed non-null by `posDeviceAuth`, which rejects any token missing a device binding — Phase 3.1). Since `device_id` is never client-supplied and never legitimately absent, making it `NOT NULL` closes the "null-device client IDs" question entirely — there is no null-device case to handle, by construction. `RESTRICT` (not `SET NULL`) because a sale must always be traceable to the device that created it; a device can't be deleted while sales reference it (matches how `pos_sales.salesman_id` already uses `RESTRICT` for the same reason).

### `pos_sale_items` — final schema

```sql
CREATE TABLE IF NOT EXISTS `pos_sale_items` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `sale_id` INT NOT NULL,
  `company_id` INT NOT NULL,
  `product_variation_id` INT UNSIGNED NOT NULL,
  `quantity` INT NOT NULL,
  `status` ENUM('active','removed') NOT NULL DEFAULT 'active',
  `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pos_sale_items_sale_variation_active` (`sale_id`,`product_variation_id`,`status`),
  KEY `idx_pos_sale_items_company` (`company_id`),
  KEY `idx_pos_sale_items_variation` (`product_variation_id`),
  CONSTRAINT `fk_pos_sale_items_sale_company` FOREIGN KEY (`sale_id`,`company_id`) REFERENCES `pos_sales` (`id`,`company_id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_sale_items_variation` FOREIGN KEY (`product_variation_id`) REFERENCES `product_variation` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE,
  CHECK (`quantity` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
```

**Changed from v1** (addressing points 1, 2, 8):
- **Point 1 — cross-company integrity, now DB-enforced, not just app-validated.** Replaced the two separate FKs (`sale_id`→`pos_sales.id`, `company_id`→`company.id`) with **one composite FK**: `(sale_id, company_id) REFERENCES pos_sales (id, company_id)`. This makes it a foreign-key error (not just a service-layer bug) to insert a `pos_sale_items` row whose `company_id` doesn't match its parent `pos_sales.company_id` — **verified empirically this session** with disposable scratch tables: an insert with a mismatched `company_id` was rejected with `ERROR 1452` before any application code even ran. `posErrorHandler.js` already maps this MySQL error class (`ER_NO_REFERENCED_ROW_2`) to a `422` — no new error-handling code needed. **Limitation, stated plainly**: this only protects the `pos_sales` ↔ `pos_sale_items` relationship. The equivalent check between `pos_sale_items.product_variation_id` and its `company_id` (i.e., "is this product actually owned by this sale's company?") **cannot** be enforced the same way without adding a matching composite unique index to the *existing* `product_variation` table, which would mean modifying an existing table — out of scope. That check remains **application-layer only** (the service validates `productVariation.company_id === sale.company_id` before every insert, reusing Phase 3's already-company-scoped `posProductRepository.findById`, which returns `null` for a cross-company id rather than leaking the row) and is covered by a dedicated regression test (§5).
- **Point 2 — duplicate-item behavior.** `UNIQUE KEY (sale_id, product_variation_id, status)` makes "one active line per variation per sale" a real DB constraint, not just an application convention — the service's merge logic (§3) is naturally enforced even if a bug ever tried to insert a second active row for the same variation.
- **Point 8 — quantity enforcement.** Added `CHECK (quantity > 0)` (supported on this MariaDB 10.4 server) as a DB-level backstop in addition to the validation-layer check (defense in depth, matching the general "validate at the boundary, enforce in the schema" approach used elsewhere in POS).
- No pricing/product-identity-snapshot columns — unchanged from v1, still deferred to Phase 6 per decision #6.

**Foreign keys**: 9 total (7 on `pos_sales`, 2 on `pos_sale_items` — one composite, one single-column), zero changes to any existing table.

**Column-type verification (point 7)** — checked live `information_schema.columns` this session, not assumed:

| FK column | Target | Target type | `pos_*` column type | Match |
|---|---|---|---|---|
| `company_id` | `company.id` | `int(11)` | `INT` | ✅ |
| `store_id` | `pos_stores.id` | `int(11)` | `INT` | ✅ |
| `register_id` | `pos_registers.id` | `int(11)` | `INT` | ✅ |
| `shift_id` | `pos_shifts.id` | `int(11)` | `INT` | ✅ |
| `device_id` | `pos_devices.id` | `int(11)` | `INT` | ✅ |
| `salesman_id` | `salesmans.salesman_id` | `varchar(70)`, NOT NULL | `VARCHAR(70)` | ✅ |
| `customer_id` | `customers.customer_id` | `varchar(255)`, nullable | `VARCHAR(255)`, nullable | ✅ |
| `product_variation_id` | `product_variation.id` | `int(10) unsigned` | `INT UNSIGNED` | ✅ |

`customers.customer_id` also reconfirmed nullable and indexed on the **live** table — the merge-conflict Phase 1 flagged is in the checked-in dump file only.

---

## 2. Files to be created (unchanged from v1)

```
Controllers/POS/PosSaleController.js
services/pos/posSaleService.js
repositories/pos/posSaleRepository.js
validation/pos/posSaleValidation.js
database/pos_migration_003_sales_cart.sql
```
Plus new routes appended to `Routes/posRoutes.js`.

---

## 3. Endpoint behavior (detailed — addressing points 2, 3, 4, 5, 6)

### Scope derivation (point 6) — stated once, applies to every endpoint below

`company_id`, `store_id`, `register_id`, `shift_id`, `device_id`, `salesman_id` are **always** taken from `req.pos` (the live-rechecked auth context from Phase 2/3.1's hardened middleware) — **never** from the request body or query string, even if a client supplies them. If a client sends any of these fields anyway, they are silently ignored (not validated-then-rejected — simply never read from the request at all, so there is no code path where they could take effect).

### Concurrency pattern (point 3) — the mechanism, used identically by every mutating endpoint below

Every mutation (add/update/remove item, hold, resume, cancel) runs inside one `posDb.withTransaction()` call and follows this exact sequence:
1. `SELECT * FROM pos_sales WHERE id = ? AND company_id = ? FOR UPDATE` on the transaction's connection — locks the row for the transaction's duration (blocks a second concurrent mutation on the *same* sale until this one commits or rolls back) and fetches current `status`/`shift_id`/`version` in one read.
2. Not found → `404`.
3. Ownership/state check (varies per endpoint, detailed below) → `403`/`409` as appropriate.
4. **Version check**: request must include `expected_version`; if it doesn't match the row just fetched → `409 Conflict`, response body includes the current `version` and current sale state so the client can reconcile (re-fetch and retry) rather than guess.
5. Apply the mutation (item insert/update/soft-delete, or status/timestamp change) via the same transaction connection.
6. `UPDATE pos_sales SET version = version + 1, updated_at = NOW() WHERE id = ? AND company_id = ? AND version = ?` (the exact conditional-update form suggested in review) — using the *same* `expected_version` value confirmed in step 4. Because step 1's `FOR UPDATE` lock has been held continuously since before step 4's check, this can only ever affect the expected 1 row; it is not a second, independent race window — it's the mechanism that actually persists the version bump, with the row lock (not a second guess) providing the safety.
7. Return the updated sale.

This combines pessimistic locking (for safety *during* the transaction) with an explicit, client-facing optimistic-versioning contract (for detecting staleness *across* requests/devices) — which is what makes it "particularly important for held-cart resumption and multiple devices" (point 3's stated concern): two devices racing to resume or mutate the same held cart will have their requests serialize on the `FOR UPDATE` lock, and whichever one is holding a stale `version` gets a clean `409` instead of silently clobbering the other's change.

### `POST /api/v1/pos/sales` — create

No `expected_version` (nothing exists yet). Requires an **open** shift (`req.pos.shiftId` must resolve to a `pos_shifts` row with `status = 'open'`). Optional body: `customer_id` (validated read-only against `customers`, company-scoped), `client_generated_id`. Returns the new sale, `status: 'draft'`, `version: 1`.

### `GET /api/v1/pos/sales/:id` — view (point 4: live-price/availability handling)

For each active line item, joins live to `product_variation` (reusing Phase 3's `posProductRepository`) and computes:
- If the variation is found **and** `status = 1` (active): `availability_status: "available"`, `unit_price`/`tax_rate`/`line_total` computed normally, included in the sale's totals.
- If the variation is **not found** (shouldn't happen given the `RESTRICT` FK, but a defensive case) **or** `status != 1` (deactivated since being added): `availability_status: "unavailable"`, `unit_price`/`tax_rate`/`line_total` are `null` — **excluded from the totals sum**, not computed as zero or stale.
- The sale response includes a top-level `has_unavailable_items: boolean` so a UI can surface a clear warning rather than the cashier silently ringing up an incomplete total.
- **Phase 6 commitment, stated now**: sale completion will **reject** (`409`, listing the affected item ids) any sale with `has_unavailable_items: true` — the cashier must remove or resolve those lines first. This is a design commitment for Phase 6, not something Phase 5 implements, but it's decided now so Phase 5's `availability_status` field is built with that consumer in mind.

### `GET /api/v1/pos/sales?status=held` — list

Store-scoped (`req.pos.storeId`), filterable by `status`.

### `POST /api/v1/pos/sales/:id/items` — add item (point 2: merge behavior)

Body: `{ product_variation_id | barcode, quantity, expected_version }`. Within the transaction (after the version check, step 4 above):
1. Resolve the product (by id or barcode) via Phase 3's repository, company-scoped; `404` if not found, `409` if `has_unavailable_items`-shaped (inactive) — an inactive product cannot be newly *added*, only already-added lines can become retroactively unavailable (§ view endpoint above).
2. `SELECT id, quantity FROM pos_sale_items WHERE sale_id = ? AND product_variation_id = ? AND status = 'active' FOR UPDATE` (same transaction/connection — no separate lock needed beyond the sale-row lock already held, but this read is still explicit for clarity).
3. If an active line exists: `UPDATE pos_sale_items SET quantity = quantity + ? WHERE id = ?` (merge). If the resulting quantity would exceed the cap (9999), reject with `422` *before* writing.
4. If none exists: `INSERT` a new `active` line.
5. Requires `req.pos.shiftId === sale.shift_id` (draft-mutation ownership, point 5) and `sale.status = 'draft'` (`409` otherwise — including a clear message if the sale is `held`, telling the client to resume it first).

### `PATCH /api/v1/pos/sales/:id/items/:itemId` — update quantity

Same transaction pattern; sets `quantity` directly (not additive) to the requested value; same ownership/state rules as add.

### `DELETE /api/v1/pos/sales/:id/items/:itemId` — remove

Soft-delete (`status = 'removed'`); same ownership/state rules. Removing an item never violates the `UNIQUE(sale_id, product_variation_id, status)` constraint, since `'removed'` is a different `status` value than `'active'` — re-adding the same variation afterward correctly inserts a *new* active row rather than colliding with the removed one's unique-key slot.

### `POST /api/v1/pos/sales/:id/hold` — `draft → held`

Requires `req.pos.shiftId === sale.shift_id` (only the shift currently working the draft can park it) and `sale.status = 'draft'`.

### `POST /api/v1/pos/sales/:id/resume` — `held → draft`

Requires only company/store match (any staff at the store, per decision #2) and `sale.status = 'held'`. On success, also sets `shift_id = req.pos.shiftId` (reassigns ownership to the resuming session) as part of the same version-checked update.

### `POST /api/v1/pos/sales/:id/cancel` — point 5, cancellation permissions, now explicit

**Decision**: cancellation permission mirrors the cart's **current** ownership tier, not a separate rule — `draft` cancellation requires `req.pos.shiftId === sale.shift_id` (same as hold/mutate); `held` cancellation requires only store-level match (same as resume), since a held cart already has no single "owning" shift once parked. **No manager-role requirement in Phase 5** — POS has no role tier beyond `device`/`staff` yet (a gap already surfaced in the Phase 4.1 decision record for returns); if a future phase introduces a manager tier, revisiting whether canceling a *held* cart should require it is a reasonable follow-up, but not built now. Rejected from `completed`/`voided`/`canceled` (`409`).

---

## 4. Validation (point 8)

`validation/pos/posSaleValidation.js`: `quantity` must be a positive integer (`> 0`, matching the new DB `CHECK` constraint), capped at 9999; `expected_version` required and must be a positive integer on every mutating endpoint; `customer_id`/`client_generated_id` length-bounded strings; `product_variation_id` integer or `barcode` string, exactly one of the two required.

---

## 5. Test plan (to be implemented alongside the code, ad-hoc scratchpad suite matching the established pattern — `test/pos/` still deferred)

**Cross-company integrity (point 1)**:
- Attempt to insert a `pos_sale_items` row with a `company_id` that doesn't match its `pos_sales.company_id` directly at the repository layer (bypassing the service) → confirm the DB rejects it (`ER_NO_REFERENCED_ROW_2` via the composite FK), not just that the service happens to prevent it.
- Attempt to add an item whose `product_variation_id` belongs to a *different* company than the sale (via the service, using two real companies as in prior phases) → `404` (product not found in scope, per Phase 3's existing company-scoped lookup — never leaks the cross-company product's existence).

**Duplicate-item merge (point 2)**:
- Add the same `product_variation_id` twice with quantities 2 and 3 → exactly one `active` line exists afterward with `quantity = 5`.
- Add, remove, then add the same variation again → two rows exist (one `removed`, one `active`), not a constraint violation.
- Merge that would exceed the 9999 cap → `422`, quantity unchanged.

**Optimistic concurrency (point 3)**:
- Two sequential requests with the same `expected_version` (simulating two devices that both read the cart before either wrote) — first succeeds and bumps the version; second (still holding the stale version) → `409`, with the current version in the response.
- Resume race: two "devices" attempt to resume the same held cart concurrently with the same expected version — exactly one succeeds, the other gets `409`.
- Missing `expected_version` in the request → `422` (validation layer), never reaches the transaction.

**Live-price/availability (point 4)**:
- View a sale whose line item's `product_variation` is still active → `availability_status: "available"`, normal totals.
- Deactivate that `product_variation` (`status = 0`) directly, then view the same sale again (no sale mutation in between) → that line flips to `availability_status: "unavailable"`, `unit_price`/`line_total` are `null`, `has_unavailable_items: true`, and the excluded line is *not* included in `totals`.
- Attempt to *add* an inactive product as a new line → `409`, not silently added.

**Cancellation permissions (point 5)**:
- Cancel a `draft` cart from the *same* shift → succeeds.
- Cancel a `draft` cart from a *different* shift at the same store → `403`.
- Cancel a `held` cart from any staff at the same store (different shift than the one that created it) → succeeds.
- Cancel an already-`completed`/`canceled` sale → `409`.

**Scope derivation (point 6)**:
- Send a request body that includes a forged `company_id`/`store_id`/`shift_id` alongside otherwise-valid data → confirm the created/mutated row uses `req.pos`'s real values, not the forged body values (the classic "does the server actually ignore this, or just silently accept it" test).

**Quantity enforcement (point 8)**:
- `quantity: 0`, `quantity: -1`, `quantity: 1.5`, `quantity: "abc"` → all `422` at the validation layer.
- A direct repository-level insert attempt with `quantity = 0` (bypassing validation) → confirm the DB `CHECK` constraint itself rejects it, not just the app layer.

**Cross-cutting**: company isolation (existing pattern, re-verified for the new endpoints), unauthorized access (`401` with no token, as in every prior phase), read-only impact on all *existing* tables (before/after row-count check on `product`, `product_variation`, `company`, `customers`, `salesmans` — Phase 5 never writes to any of them).

---

Waiting for approval on this revised schema, endpoint behavior, and test plan before creating anything.
