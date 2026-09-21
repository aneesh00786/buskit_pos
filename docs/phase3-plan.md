# Phase 3 — POS Product & Inventory Visibility: Pre-Implementation Plan

**Status: PLAN ONLY — nothing created or executed.** Per your instructions, this covers existing-table analysis, actual queries, proposed endpoints, security design, files, and assumptions. Waiting for approval before writing any code or touching any index.

---

## 1. Existing table analysis (live `busskit_new`, actual `SHOW CREATE TABLE` output)

### `product_variation` — the real browsing/pricing/barcode source
```sql
CREATE TABLE `product_variation` (
  `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `company_id` int(11) NOT NULL,
  `product_id` varchar(255) NOT NULL,
  `product_code` varchar(255) NOT NULL,
  `brandname` varchar(100) DEFAULT NULL,
  `product_name` varchar(1000) DEFAULT NULL,
  `variation_id` varchar(255) NOT NULL DEFAULT '0',
  `variation_name` varchar(255) NOT NULL,
  `in_no` varchar(20) NOT NULL,
  `barcode` varchar(10) DEFAULT NULL,
  `group_handle` varchar(255) DEFAULT NULL,
  `scid` varchar(200) DEFAULT NULL,
  `description` varchar(700) DEFAULT NULL,
  `unitType` varchar(255) NOT NULL,
  `price` decimal(10,3) NOT NULL,
  `pack_cost_price` decimal(10,3) NOT NULL DEFAULT 0.000,
  `sell_price` decimal(10,3) NOT NULL,
  `pack_sale_price` decimal(10,3) NOT NULL DEFAULT 0.000,
  `tax` decimal(10,3) NOT NULL,
  `incl_tax` varchar(10) DEFAULT NULL,
  `catId` int(11) NOT NULL,
  `packtype` varchar(200) NOT NULL,
  `pieces` int(11) NOT NULL,
  `stock` int(11) NOT NULL,           -- cached/denormalized, NOT authoritative (see §2)
  `lowstock` int(11) NOT NULL,
  `fullstock` int(11) NOT NULL,
  `image_url` varchar(255) DEFAULT NULL,
  `status` tinyint(1) NOT NULL DEFAULT 1 COMMENT '1 = Active, 0 = Deactive',
  `v_status` int(11) NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp(),
  `myob_id`/`salesforce_id`/`quickbooks_id`/`sync_hash`/`last_synced_at`  -- integration sync columns, irrelevant to POS
  PRIMARY KEY (`id`),
  KEY `product_id` (`product_id`),
  KEY `variation_id` (`variation_id`),
  KEY `company_id` (`company_id`),
  KEY `idx_product_company` (`product_id`,`company_id`)
  -- NOTE: no index on `barcode` at all, no index on `product_name` — see §3
) ENGINE=InnoDB AUTO_INCREMENT=2011 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
```
`product_name`, `brandname`, and `catId` are **denormalized directly onto `product_variation`** (duplicated from `product`) — meaning POS product search can query `product_variation` alone, without joining `product`, for everything the browsing scope needs. Confirmed by comparing both tables' live schemas — `product` adds nothing not already present on `product_variation`, except `product.status`/`product.description` which are separately duplicated per-variation anyway.

**Data reality check** (live counts, read-only): 226 rows in `product`, 712 in `product_variation`, 738 in `varient_stock`. This is a small dataset — table scans are sub-millisecond at this size, which changes the indexing recommendation in §3.

**Barcode column is `varchar(10)`** — too short for a full EAN-13 (13 digits) if one were ever scanned; current data's longest barcode is 10 characters (matches the column max, no truncation observed yet). This is a pre-existing schema constraint, not something POS changes — flagging it as a real-world limitation to be aware of, not a POS bug.

### `categories` / `category_tax`
```sql
CREATE TABLE `categories` (
  `cid` int(11) NOT NULL AUTO_INCREMENT,
  `category` varchar(70) NOT NULL,
  `company_id` int(11) NOT NULL,
  `updated_at` timestamp ...,
  `status` int(11) NOT NULL,
  PRIMARY KEY (`cid`,`category`),      -- composite PK, note this
  KEY `idx_category` (`category`),
  KEY `company_id` (`company_id`)
) ...
-- 102 rows live

CREATE TABLE `category_tax` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `tax_name` varchar(99) NOT NULL,
  `cat_id` int(11) NOT NULL,          -- not a declared FK to categories.cid
  `tax` float NOT NULL,
  `company_id` int(11) NOT NULL,
  `status` int(11) NOT NULL,
  PRIMARY KEY (`id`), KEY (`company_id`), KEY (`cat_id`)
) ...
-- 30 rows live
```
`categories.cid` has a composite PK `(cid, category)` — because `cid` is `AUTO_INCREMENT` it's effectively unique in practice, but I'll avoid a plain `JOIN ON c.cid = pv.catId` and use a scalar subquery instead (§2), so a hypothetical duplicate `cid` can never fan out a product row into duplicates.

There is **no formal `brands` table** (confirmed again live, matching Phase 1) — `brandname` is a free-text column on `product_variation`; "brand filtering" means filtering on that string, and a brand *list* means `SELECT DISTINCT brandname`.

### `varient_stock` — the authoritative stock ledger
```sql
CREATE TABLE `varient_stock` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `company_id` int(11) NOT NULL,
  `varient_id` varchar(20) NOT NULL,   -- FK to product_variation.variation_id
  `batch` varchar(20) NOT NULL,
  `stock` double NOT NULL,
  `sold_count` double NOT NULL DEFAULT 0,
  `return_qty` double NOT NULL,
  `damage_qty` double NOT NULL,
  `date` datetime NOT NULL,
  `status` int(11) NOT NULL,           -- 0 = counted as active stock (see §2)
  PRIMARY KEY (`id`),
  KEY `fk_varient_id` (`varient_id`), KEY (`company_id`), KEY (`status`),
  CONSTRAINT `fk_varient_id` FOREIGN KEY (`varient_id`) REFERENCES `product_variation` (`variation_id`) ON DELETE CASCADE
) ...
-- 738 rows live
```

---

## 1a. Active-status convention verified per table (not assumed — checked live)

**Correction from the original plan**: the "active" convention is **not consistent** across these tables — verified against both live data distribution and actual production query code, not assumed:

- **`product_variation.status = 1`** is active (`0` = deactivated). Confirmed by: the column's own comment (`1 = Active, 0 = Deactive`), live data (655 rows at `status=1` vs. 57 at `0`), and real production code consistently filtering `WHERE pv.status = 1` (`Controllers/b2bProductAPI.js` lines 93/100/108/115/226/795, `Controllers/productFrequency.js` line 480) with deletion setting `status = 0` (line 689/691).
- **`categories.status = 0`** is active — the **opposite** convention. There is no column comment to go by, so I checked the actual production query instead: `Controllers/categoryAPI.js::fetch_categories_get` (the real, live category-fetch endpoint used by the web store today) queries `categories`/`sub_catagories`/`category_tax` with **`WHERE status = 0`** (lines 35/45/49). Live data confirms this reading makes sense (81 rows at `status=0`, 21 at `status=1` — the majority-active number is the one the real endpoint actually selects).

Phase 3's category query has been corrected to `WHERE status = 0` (§4), matching what the existing app actually does — not the `product_variation` convention. This is exactly the kind of check your "verify before implementing filters" instruction was meant to catch; treating this as verified now, not assumed.

## 2. `services/stockService.js` review (the "review carefully" instruction) — FIFO transaction issue now empirically confirmed, not just suspected

Read the full file (229 lines). Two functions matter for Phase 3, and one finding matters a lot for **whichever future phase does deduction**:

**`ShowVarientStock(companyId, varient_id)`** — the exact, authoritative "current stock" query already used elsewhere in the app:
```sql
SELECT
    COALESCE(SUM(stock), 0)
  + COALESCE(SUM(return_qty), 0)
  - COALESCE(SUM(sold_count), 0)
  - COALESCE(SUM(damage_qty), 0) AS current_stock
FROM varient_stock
WHERE varient_id = ?
  AND company_id = ?
  AND status = 0
```
Note the `AND status = 0` filter — this was **not** captured precisely in the Phase 1 analysis and matters: only batches with `status = 0` count toward displayed stock. POS's own stock-visibility query (§4) replicates this exactly, so POS never shows a number that disagrees with what the rest of the app already shows for the same variation.

**`reduceStockAndUpdateSoldCount(...)` — the FIFO deduction function — has a likely transaction-atomicity bug**, found while reviewing it per your instruction (not something Phase 3 touches or fixes, but important to record for whoever builds checkout later):

It calls `queryPromise("BEGIN")`, then several more `await queryPromise(...)` calls (a `SELECT`, then per-batch `UPDATE`+`INSERT` in a loop), then `queryPromise("COMMIT")` — all via the shared `getQueryPromise()` helper, which wraps `pool.query()` (confirmed in `config/db.js`). `pool.query()` auto-acquires and auto-releases a connection on every single call, so it does not inherently pin all these statements to one connection/session.

**This was empirically verified, not left as a structural suspicion**, per the instruction to confirm before concluding the rollback is definitely ineffective. Method (entirely read-only — `SELECT CONNECTION_ID()`, `SELECT SLEEP()`, `BEGIN`, `ROLLBACK` only; no table was written to; `stockService.js` was never modified, imported, or executed):
1. **Sequential calls, no concurrency**: `getQueryPromise()`, then `BEGIN`, then two more queries — all three returned the *same* `CONNECTION_ID()`. At zero contention, the pool happens to hand the same idle connection straight back.
2. **15 concurrent logical "transactions" against the pool's `connectionLimit: 20`**: each of the 15 got its own dedicated connection and stayed pinned to it for its own `BEGIN → sleep → query → ROLLBACK` sequence — 0/15 showed a change. Below saturation, there's enough spare capacity that pinning holds by chance.
3. **60 concurrent logical "transactions" against the same `connectionLimit: 20`** — i.e., real contention, which is the actual production scenario since the pool is shared by the entire app, not just checkout: **60/60 sessions had their own statements land on multiple *different* connection IDs mid-sequence** (e.g. one session's own three checks returned connection ids `87, 87, 79` — the third statement landed on a different connection than the first two).

**Conclusion: confirmed, not just suspected.** Under realistic concurrent load, `getQueryPromise()`'s `pool.query()`-per-call behavior does not keep a logical transaction on one MySQL session. This means `reduceStockAndUpdateSoldCount`'s `BEGIN`/`COMMIT`/`ROLLBACK` calls are very likely operating on different connections than the `UPDATE`/`INSERT` calls in between, so those statements run in implicit per-statement autocommit, and the `catch` block's `ROLLBACK` has nothing real to undo — **partial FIFO deductions can persist on disk even after the function reports a rolled-back failure, under real concurrent traffic.**

**Recorded as technical debt, not fixed** — `stockService.js` was not modified, per your instruction to keep Phase 3 strictly read-only and not touch it. This is documented for whichever future phase implements POS stock deduction: it must use a genuine single-connection transaction (the `withTransaction()` helper already built in `repositories/pos/posDb.js` for Phase 2.1 does this correctly — `pool.getConnection()` once, run every statement on that same connection object, commit/rollback, then release) rather than `reduceStockAndUpdateSoldCount`'s pattern. That future phase should also add concurrency tests specifically targeting this failure mode (the same "N concurrent logical transactions against a saturated pool" technique used here) before any deduction logic is integrated or replaced.

**Phase 3 does not call, modify, or depend on `reduceStockAndUpdateSoldCount` at all** — it only reads via a query shaped like `ShowVarientStock`, a single `SELECT` with nothing to make atomic, so this issue does not affect Phase 3's own correctness.

---

## 3. Indexing plan

Given the live data volume (712 variations, 738 stock rows), every query below runs as a full or near-full table scan today regardless of indexing, and at that size this is sub-millisecond — **there is no performance problem to solve right now.**

One index is still worth flagging as a candidate, since barcode scan-to-sell is POS's single hottest lookup path and `product_variation` has **no index on `barcode` at all**:
```sql
ALTER TABLE product_variation ADD INDEX idx_pos_barcode_lookup (company_id, barcode);
```
This is a new, additive, non-unique secondary index on an **existing table** — I'm not creating it without your explicit sign-off, and my recommendation is to **defer it for now** given the current table size makes it unnecessary, and revisit once real data volume or measured latency justifies it. No new index will be added in this phase unless you say otherwise.

No other indexing changes are proposed. No existing index is touched.

---

## 4. Proposed queries (exact SQL, using `posQuery` from the existing `posDb.js`)

All company-scoped via `req.pos.companyId` only — never from a client-supplied value.

**Product search / list** (`GET /api/v1/pos/products`):
```sql
SELECT
  pv.id, pv.product_id, pv.product_code, pv.brandname, pv.product_name,
  pv.variation_id, pv.variation_name, pv.barcode, pv.unitType,
  pv.price, pv.sell_price, pv.tax, pv.incl_tax, pv.catId, pv.image_url,
  (SELECT category FROM categories WHERE cid = pv.catId AND company_id = pv.company_id LIMIT 1) AS category_name,
  (
    SELECT COALESCE(SUM(vs.stock),0) + COALESCE(SUM(vs.return_qty),0)
         - COALESCE(SUM(vs.sold_count),0) - COALESCE(SUM(vs.damage_qty),0)
    FROM varient_stock vs
    WHERE vs.varient_id = pv.variation_id AND vs.company_id = pv.company_id AND vs.status = 0
  ) AS current_stock
FROM product_variation pv
WHERE pv.company_id = ?
  AND pv.status = 1
  [AND (pv.product_name LIKE ? OR pv.variation_name LIKE ? OR pv.product_code LIKE ? OR pv.barcode LIKE ?)]
  [AND pv.catId = ?]
  [AND pv.brandname = ?]
ORDER BY pv.product_name ASC, pv.variation_name ASC
LIMIT ? OFFSET ?
```
Plus a matching `SELECT COUNT(*) FROM product_variation pv WHERE ... (same filters, no subqueries)` for pagination totals. Bracketed clauses are appended only when that filter is supplied; always via `?` placeholders, never string-built from raw input values (only the *presence* of a filter changes which literal SQL fragments are concatenated, matching the same "conditionally append parameterized clauses" pattern already used throughout buskit-web, e.g. `categoryAPI.js`).

**Barcode lookup** (`GET /api/v1/pos/products/barcode/:barcode`) — same SELECT list, `WHERE pv.company_id = ? AND pv.barcode = ? AND pv.status = 1 LIMIT 1`.

**Single variation detail** (`GET /api/v1/pos/products/:id`) — same SELECT list, `WHERE pv.id = ? AND pv.company_id = ? LIMIT 1`.

**Categories** (`GET /api/v1/pos/categories`) — note `status = 0`, verified per §1a, not `= 1`:
```sql
SELECT cid, category FROM categories WHERE company_id = ? AND status = 0 ORDER BY category ASC
```

**Brands** (`GET /api/v1/pos/brands`) — `product_variation` uses the opposite convention (`status = 1` active, verified per §1a):
```sql
SELECT DISTINCT brandname FROM product_variation
WHERE company_id = ? AND status = 1 AND brandname IS NOT NULL AND brandname <> ''
ORDER BY brandname ASC
```

---

## 4a. API response schemas (base-price-only, per your instruction — no `final_price` computed)

Every response uses the existing envelope (`{ status_code, status, message, data }`, from `posResponse.js`). A single product/variation item is always shaped like this — for the list endpoint it appears inside `data.items[]`; for barcode/id lookup it *is* `data` directly:

```json
{
  "id": 1234,
  "product_id": "P-001",
  "product_code": "CODE-1",
  "variation_id": "V-001",
  "variation_name": "500g",
  "product_name": "Example Product",
  "brandname": "Example Brand",
  "barcode": "1234567890",
  "unit_type": "kg",
  "image_url": "https://.../image.jpg",
  "category": { "id": 12, "name": "Groceries" },
  "stock": {
    "current_stock": 42
  },
  "pricing": {
    "sell_price": 100,
    "tax": 5,
    "discount": 0,
    "final_price": null,
    "pricing_status": "base_price_only"
  }
}
```
`pricing` is exactly the shape you specified: `discount` is hardcoded `0` and `final_price` is hardcoded `null` in this phase — no promotion/discount/customer-pricing evaluation happens anywhere in the code, `pricing_status: "base_price_only"` is a fixed literal on every response so a future phase can safely distinguish "no pricing engine ran yet" from a real computed price later without an API version bump.

**List endpoint** (`GET /products`):
```json
{
  "status_code": 200,
  "status": true,
  "message": "Products retrieved",
  "data": {
    "items": [ /* array of the item shape above */ ],
    "pagination": { "page": 1, "limit": 20, "total": 143, "total_pages": 8 }
  }
}
```

**Barcode / single-id endpoints** — `data` is the item object directly (not wrapped in `items`), or a `404` envelope if not found.

**Categories** (`GET /categories`):
```json
{ "status_code": 200, "status": true, "message": "Categories retrieved",
  "data": [ { "id": 12, "name": "Groceries" }, { "id": 13, "name": "Beverages" } ] }
```

**Brands** (`GET /brands`):
```json
{ "status_code": 200, "status": true, "message": "Brands retrieved",
  "data": ["Example Brand", "Another Brand"] }
```

## 5. Proposed API endpoints

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/api/v1/pos/products` | device or staff token | query: `q`, `category_id`, `brand`, `page`, `limit` |
| GET | `/api/v1/pos/products/barcode/:barcode` | device or staff token | exact match, single result or 404 |
| GET | `/api/v1/pos/products/:id` | device or staff token | `id` = `product_variation.id` |
| GET | `/api/v1/pos/categories` | device or staff token | flat list, no pagination needed (102 rows) |
| GET | `/api/v1/pos/brands` | device or staff token | flat distinct list |

All added to the **existing `Routes/posRoutes.js`** — that file is POS's own, created in Phase 2, not a pre-existing buskit-web file, so extending it isn't a restricted "existing file" edit. No change to `server.js` beyond what's already approved.

---

## 6. Security design

- `req.pos.companyId` (from the verified JWT, same middleware as Phase 2) is the only source of tenant scope — `q`/`category_id`/`brand`/`page`/`limit` are the only client-controllable inputs, and none of them can affect which company's data is queried.
- All values bound via `?` placeholders through the existing `posQuery()` helper — no string-built SQL anywhere, including the conditionally-appended filter clauses (§4).
- Validation (`validation/pos/posProductValidation.js`): `page` integer ≥1 (default 1), `limit` integer 1–100 (default 20, hard cap to prevent a client requesting an unbounded result set), `q` string ≤100 chars, `category_id` integer if present, `barcode`/`brand` string ≤100 chars. Invalid input → `422`, same pattern as Phase 2.
- No write capability anywhere in this phase — every new repository function is a `SELECT`, confirmed by design (no `INSERT`/`UPDATE`/`DELETE` in any planned query).
- Reuses `posDeviceAuth` only (not `requirePosStaff`) — browsing doesn't need staff-level access, consistent with how Phase 2's read endpoints (e.g. `GET /stores`) are already scoped.

---

## 7. Files to be created (all new; nothing existing touched except the addition to `Routes/posRoutes.js`, which is POS's own file)

```
Controllers/POS/PosProductController.js
services/pos/posProductService.js
repositories/pos/posProductRepository.js
validation/pos/posProductValidation.js
```
Plus new route registrations appended inside the existing `Routes/posRoutes.js`.

---

## 8. Assumptions (flagging rather than guessing silently)

1. "Applicable selling price" = `product_variation.sell_price` + `tax` column, as already stored per-variation — **not** re-deriving price from `category_tax` or evaluating `promotions`/`discount`/`staff_discounts`, since those are customer/staff-specific pricing adjustments that belong to a sales/checkout context, not browsing. Flag if you want promotional/discount-aware pricing surfaced during browsing already.
2. "Product categories" scope = top-level `categories` only, not `sub_catagories` — `product_variation.scid` (subcategory id) exists and could be added as a filter later; leaving it out of this pass to match the explicit scope items ("categories and brands," no mention of subcategories).
3. ~~Only `status = 1` (active) variations and `status = 1` categories are ever shown~~ — **corrected per §1a**: `product_variation.status = 1` is active, `categories.status = 0` is active (opposite conventions, verified against live production query code, not assumed).
4. `page`/`limit` default to `1`/`20`, capped at `limit ≤ 100` — no explicit values were given, chose numbers consistent with typical POS scan/browse UI needs.

---

## 9. Planned tests (once implementation is approved)

Product search + pagination correctness (including exact result-count math); barcode exact lookup (found + not-found cases); company isolation (a token for company A never sees company B's products, tested against two real companies as in Phase 2); unauthorized access (no token → 401); invalid filters (non-numeric `category_id`, oversized `limit` → 422); stock/variation accuracy (compare returned `current_stock` against an independent direct calculation for the same variation); a SQL-injection-shaped search string (e.g. `' OR '1'='1`) confirmed to be treated as a literal, not as SQL; and a before/after row-count check on `product`, `product_variation`, `varient_stock`, `categories` proving zero writes occurred.

---

**Stopping here per your instructions.** No file created, no index added, no route registered yet. Let me know if the plan (especially §3's deferred index and §8's assumptions) looks right, and I'll implement exactly this.
