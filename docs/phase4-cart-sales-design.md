# Phase 4 — POS Cart & Sales Transaction Design (design only — nothing implemented)

**Status: DESIGN DOCUMENT ONLY.** No table created or modified, no source file created or modified, no route/controller/service written, no stock deducted, no payment processed. Per your restrictions, this stops here for review before any implementation.

---

## 1. Existing workflow analysis (grounded in this session's own reads — cited, not assumed)

### 1.1 Cart → Order pipeline (the web-store's own sales flow)

`cart` (id, company_id, cart_id [string business key], customer_id, salesman_id, total, discount, `status`: `1=draft, 2=canceled, 3=pending, 4=Create Order, 5=Estimate`) → `cart_detail` (one row per line item) → `order` (the finalized header, keyed by `order_id` [string]).

`cart_detail`'s columns are the single best reference for what a POS line item needs to capture — confirmed live schema: `unit_price`, `price`, `quantity`, `pieces`, `packType`, `discount`, `discount_amount`, `total_price`, `tax`, `incl_tax`, `promo_discount`, `is_promo`, `is_bundle`, `is_bulk`, `promo_code`, `return_quantity`, `status` (soft-delete flag, `1=active,0=delete`). Every price-related field is **snapshotted per line at add-time**, not re-derived live — this is the pattern POS should follow (§3.2).

`order`'s `order_status` has 9 named states (`0=Pre Order,1=Out Of Delivery,2=Delivered,3=Canceled,4=Draft,5=Processing,6=Pending,7=Estimate,11=new order,12=Waiting for approval,13=Rejected,14=Quick Sale`) and `payment_status` has 3 (`0=not paid,1=paid,3=partial` — note there is no `2`, a pre-existing numbering gap, not a POS concern). `payment_type` is `0=cash,1=cheque,2=bank transfer` — **no card value exists on the core `order` table**, confirming Phase 1's finding.

### 1.2 Transaction numbering (confirmed from live data, not assumed)

Real `order_id` values observed: `ORDER1170/September`, `DRAFT277/2026` — a human-readable `<TYPE><sequence>/<period>` format. The exact counter logic wasn't fully traced (grep for `order_counter` inside `orderAPI.js` found no direct hits — the increment logic likely lives in a helper not opened this pass), but the **format itself** is a clear, confirmed precedent: retail/order documents in this system get short, human-legible numbers, not raw database ids. POS's own transaction numbering (§4.4) should follow a similarly readable convention, generated independently (not by sharing buskit-web's `company.order_counter`, which POS must never write to).

### 1.3 Payments, tax, promotions, returns (building on Phase 1 + this session's checks)

- **Pricing inputs**: `product_variation.sell_price`/`.tax` (already used for POS browsing, Phase 3) and `category_tax` (category-level rate). No dedicated "evaluate this cart" pricing function was found in a targeted read of `Controllers/b2bPromoAPI.js` — its exported functions (`getPromoTypeData`, `insertPromoTypeData`, `deletePromoTypeData`, `getRelatedPromoData`, `enrichVariant`, …) look like **admin CRUD for defining promotions**, not a runtime "does this cart qualify" evaluator. **This is an open question, not a finding** — the actual cart-time promotion evaluation logic may live inline inside `orderAPI.js` (357KB, not exhaustively read this pass) or elsewhere. Flagging this explicitly rather than guessing: **before any future phase implements promotion-aware POS pricing, that evaluation code path needs its own dedicated, targeted read** — separate from this design phase, which stays at `base_price_only` per your standing instruction (Phase 3).
- **Payments**: `payment_providers` holds per-tenant encrypted processor credentials (Stripe etc.) — already a good pattern to reuse *conceptually* later, not touched now. Van Sales separately integrated Stripe Terminal (`database/van_sales_migration_stripe_terminal.sql`) — the only real "card-present" precedent in this codebase, and it's Van-Sales-specific, not something POS reuses directly.
- **Returns**: `sales_return` (return_id, order_id → `order.order_id` FK `ON DELETE CASCADE`, cart_id, invoice_id, customer_id, return_reason, total_refund_amount, status, pickup_salesman/pickup_status) + `customer_return_ledger` (Phase 1 finding, a credit/debit ledger). This is a reasonably rich, reusable *pattern* — whether POS returns should write into these actual tables or a separate `pos_returns` table is an **open question** (§7).

### 1.4 FIFO stock logic — reference only, not re-analyzed here

Already fully reviewed and empirically verified in Phase 3 (`docs/phase3-plan.md` §2, `docs/phase3-completion-report.md` §1): `reduceStockAndUpdateSoldCount`'s `BEGIN`/`COMMIT`/`ROLLBACK` do not reliably stay on one MySQL connection under real concurrent load (proven: 60/60 concurrent logical transactions had statements split across different connections), so a reported failure's rollback can be a no-op. **Not re-touched this phase.** Restated here because it directly shapes §5's transaction design: POS must not reuse this function or its pattern.

One **additional** gap worth naming now, found by re-reading the function's logic (not previously called out): `reduceStockAndUpdateSoldCount`'s batch-selection query (`SELECT ... FROM varient_stock WHERE varient_id = ? AND company_id = ? AND (stock + return_qty - sold_count - damage_qty) > 0 ... ORDER BY date ASC, id ASC`) has **no `SELECT ... FOR UPDATE` row lock**. Even if the connection-pinning bug were fixed, two concurrent transactions could both read the same batch's "remaining stock" before either commits, both believe there's enough stock, and both deduct — a classic lost-update overselling race, independent of the connection issue. **POS's own future stock-deduction design (§5.3) must lock the batch rows it reads within the same transaction it writes to them.**

---

## 2. Proposed POS data model (design only — no table created)

All in the same `busskit_new` database (continuing the established decision), `pos_`-prefixed, real FKs where a stable target exists (continuing the Phase 2 decision), `company_id` kept as a plain redundant column on every table (continuing the established defense-in-depth convention).

| Table | Purpose | Key columns (illustrative) |
|---|---|---|
| `pos_sales` | Sale/cart header — a single row for the entire lifecycle from draft to completed | `id`, `sale_number` (nullable until completed, §4.4), `client_generated_id` (nullable, for offline — §8), `company_id`, `store_id`, `register_id`, `shift_id`, `device_id`, `salesman_id` (cashier), `customer_id` (nullable — walk-in), `status` (`draft/held/completed/canceled/voided`), `subtotal`, `discount_total`, `tax_total`, `grand_total`, `currency`, `version` (optimistic concurrency, §8), `idempotency_key` (nullable, unique — §6), `notes`, `created_at`, `updated_at`, `completed_at` |
| `pos_sale_items` | Line items — snapshotted at add-time, mirroring `cart_detail`'s approach | `id`, `sale_id` FK, `product_variation_id` FK → `product_variation.id`, `variation_id` (string business key, snapshot), `barcode`/`product_name`/`brandname` (snapshot, so a later catalog edit never rewrites history), `quantity`, `unit_price`, `tax_rate`, `tax_amount`, `discount_amount` (always `0` until pricing is analyzed — §1.3), `line_total`, `status` (`active/removed`), `created_at`, `updated_at` |
| `pos_sale_payments` | One row per tender (supports split payment) | `id`, `sale_id` FK, `method` (`cash/card/other`), `amount`, `tendered_amount`/`change_due` (cash only), `reference` (tokenized/manual reference only — never raw card data), `status` (`pending/completed/voided`), `created_at` |
| `pos_audit_logs` | Append-only log of sensitive actions (already proposed in Phase 1, still not built) | `id`, `company_id`, `store_id`, `sale_id` (nullable), `salesman_id`, `device_id`, `action`, `details` (JSON), `created_at` |
| `pos_returns` *(tentative — see open question §7)* | POS-side returns, if not unified with core `sales_return` | `id`, `original_sale_id` FK → `pos_sales.id`, `salesman_id`, `reason`, `refund_total`, `status`, `created_at` |

Not proposed as new tables: an idempotency-key table (folded into `pos_sales.idempotency_key` directly, simpler for this single-resource case) and a `pos_sync_events` outbox (still relevant conceptually for the future stock-sync problem, but out of scope until §5/§7's open questions are resolved).

---

## 3. Cart lifecycle

### 3.1 States and transitions

```
        create
  (none) ────────► draft ◄──────────┐
                     │  \           │ resume
                hold │   \ cancel   │
                     ▼    ▼         │
                   held  canceled   │
                     └──────────────┘
                     complete
        draft ──────────────────► completed ──► voided (§7, later phase)
```

- **draft**: mutable — items can be added/updated/removed, customer can be attached/changed, totals recompute on every mutation.
- **held**: parked — a cashier can start a *new* draft on the same register while a held cart waits (e.g., customer steps away). Multiple held carts per register/store are normal and expected (unlike shifts, there is no "only one" constraint).
- **canceled**: terminal, from `draft` or `held` only. Not from `completed` — a completed sale needs a return/void flow (§7), never a plain cancel.
- **completed**: terminal (for editing) — immutable line items; only new records (returns/voids) reference it afterward, mirroring `cart_detail`'s convention where a placed order's lines aren't mutated in place either.
- **expiration**: a `held` cart older than a configurable window (e.g. 24–48h, business decision) should auto-expire to `canceled` — proposed as a scheduled job (mirroring buskit-web's own `node-cron` usage, e.g. `frequncy.startFrequencyJobs()`), **not built in this phase**.

### 3.2 Add / update / remove items

- **Add**: validate the product exists, is active, and belongs to the caller's `company_id` (reuse Phase 3's `posProductRepository` exactly — no new product-lookup logic). **Snapshot** `unit_price`/`tax_rate`/`product_name`/`barcode` onto the line item at this moment — mirrors `cart_detail`'s design and protects sale history from later catalog price changes. Server always derives price from `product_variation.sell_price`; a client-supplied price is never trusted or accepted (closes a common POS vulnerability class).
- **Update quantity**: recompute that line's `line_total` and the sale's aggregate totals.
- **Remove**: soft-delete (`status = 'removed'`), never a hard `DELETE` — preserves an audit trail of what was added-then-removed (relevant for loss-prevention review), mirroring `cart_detail.status`'s soft-delete convention.
- Every mutation recomputes `pos_sales.subtotal/tax_total/discount_total/grand_total` from the live set of `active` line items in the same transaction as the item change — never trusts a client-supplied total.

### 3.3 Ownership

Recommended: **store-level ownership**, not strictly the exact shift that created the cart. A `draft`/`held` cart belongs to `company_id` + `store_id`; any staff token currently authenticated at that store can view/resume a held cart (matches real-world register handover — a customer who steps away might return after a shift change or at a different register in the same store). A `draft` cart *in active use* is naturally tied to whichever staff session is currently editing it, but that's a UX/business-logic convention, not a hard authorization boundary — the hard boundary is the store. **Flagging this as a decision to confirm**, not asserting it's the only right answer — the alternative (register-only or shift-only ownership) is simpler but would make "customer stepped away past a shift change" awkward.

---

## 4. Sales

### 4.1 Draft vs. completed

A `pos_sales` row *is* the cart — there is no separate "cart" object promoted into a "sale" object at completion (unlike buskit-web's `cart` → `order` two-table pipeline). This is simpler and avoids a class of bugs where cart and order data can drift; the tradeoff is that `pos_sales` needs to carry both "in-progress" and "finalized" concerns in one table, distinguished by `status`. Flagging this as a deliberate proposed simplification versus mirroring buskit-web's two-table pattern — open to reconsidering if there's a reason to keep them separate.

### 4.2 Customer selection

`customer_id` is **nullable** — walk-in/anonymous sales are a first-class case for POS (unlike the b2b order flow, which appears to always require a real customer). When provided, it's validated read-only against the existing `customers` table (reusing the same company-scoped lookup pattern already built for Phase 3's product browsing), never written to.

### 4.3 Tax and discount handling

Tax: same snapshot-at-add-time approach as `cart_detail` — `product_variation.tax` captured onto the line item, summed into `pos_sales.tax_total`. Discount: the column exists on `pos_sale_items` (`discount_amount`) but **stays `0` in every phase until pricing/promotions are properly analyzed** — continuing the exact `base_price_only` decision from Phase 3, not reopening it here.

### 4.4 Transaction numbering — two options, needs your call

1. **Simple, ID-derived** (recommended): `sale_number = 'POS-' || LPAD(pos_sales.id, 8, '0')`, computed from the real auto-increment primary key. Trivially unique, no separate counter table, no reset-boundary race conditions.
2. **Human-readable, period-reset** (matches buskit-web's own `ORDER1170/September` convention): e.g. `POS-<store_code>-<YYYYMMDD>-<sequence>`, resetting daily per store. Matches receipt conventions many retail businesses expect, but needs its own atomic counter (a small `pos_sale_counters` table keyed by `store_id + date`, incremented inside the same transaction as sale completion) — more moving parts, more ways to get concurrency wrong if not built carefully.

This is a **business decision**, not a technical one — flagging rather than picking for you.

### 4.5 Price validation at completion

Because line items snapshot price at add-time, a cart held open for a while could complete at a stale price if the catalog changed in between. Proposed: at completion time, **re-check each line's snapshotted `unit_price` against the current live `product_variation.sell_price`**; if unchanged, proceed; if changed, either (a) block completion and require staff to review/accept the new price, or (b) auto-refresh silently. Recommend (a) for a POS context (silent price changes at the register are a bad look) — **flagging as a decision**, not deciding unilaterally.

### 4.6 Returns and cancellations

`canceled` (pre-completion) is covered in §3.1. Post-completion returns/voids are **out of scope for implementation** in this phase and the next — see the open question in §7 (reuse core `sales_return`/`customer_return_ledger` vs. a new `pos_returns` table) and the recommended phase sequencing in §9 (returns come after stock deduction is working, not before).

---

## 5. Inventory (analysis + strategy — nothing executed)

### 5.1 Stock tables (recap, already fully mapped in Phase 1/3)

`varient_stock` (the real ledger, FIFO-batched, `status = 0` = counted), `order_item_batches` (line-level batch attribution), `product_variation.stock` (cached, not authoritative). No new stock table is proposed — POS should write into the **existing** `varient_stock`/`order_item_batches` tables when deduction is eventually built (a decision already flagged in Phase 1 §17/§25 as needing developer sign-off: does POS decrement the *same* ledger, or maintain its own?). This design assumes "same ledger" as the working assumption, since a `pos_sales`-only stock ledger would let POS and the web-store double-sell the same physical inventory — but this is **still an open question**, not settled here.

### 5.2 Concurrent checkout behavior — the core risk

Two cashiers (POS and/or web-store) selling the last unit of the same variant at the same moment must not both succeed. This requires **both**: (a) a real single-connection transaction (not `reduceStockAndUpdateSoldCount`'s broken pattern), **and** (b) row-level locking on the specific `varient_stock` batch rows being read-then-written, so a second concurrent transaction blocks until the first commits or rolls back, rather than both reading the same "remaining stock" snapshot.

### 5.3 Proposed single-connection transaction strategy (design only — not implemented)

Extend `repositories/pos/posDb.js::withTransaction()` (already built and tested in Phase 2.1/3.1) with a POS-specific stock function, sketched here as pseudocode — **not written this phase**:

```
withTransaction(async (txQuery) => {
  const batches = await txQuery(
    `SELECT id, stock, return_qty, sold_count, damage_qty
     FROM varient_stock
     WHERE varient_id = ? AND company_id = ? AND status = 0
     ORDER BY date ASC, id ASC
     FOR UPDATE`,                      // <-- the row lock reduceStockAndUpdateSoldCount lacks
    [variantId, companyId]
  );
  // FIFO-distribute saleQuantity across batches, same math as the existing
  // function, but every UPDATE/INSERT runs via txQuery (same connection),
  // and the SELECT above holds row locks for the transaction's duration —
  // a concurrent request for the same variant blocks here until this
  // transaction commits or rolls back.
  ...
});
```

`FOR UPDATE` inside an explicit transaction on one pinned connection is what makes this safe where the existing function is not — both the connection-pinning fix (already proven correct via `withTransaction`) and the row lock (missing from the existing function entirely) are required together.

### 5.4 What this phase does NOT do

No stock is read for deduction purposes, no `varient_stock` row is written, no `withTransaction`-based deduction function is written. §5.3 is a sketch for a **future** phase (§9) to implement and concurrency-test (using the same "N concurrent transactions against a saturated pool" technique already used in Phase 3 to prove the original bug) before it ever touches real data.

---

## 6. Payments (design only)

- `pos_sale_payments` (§2) supports **split tender**: multiple rows per `sale_id`; a sale is considered fully paid once `SUM(payments.amount) >= grand_total`.
- `method` is conceptual for now: `cash` (fully supported — tendered amount, computed change), `card`/`other` (recorded as a **manual reference entry** — e.g. a terminal's printed auth code typed in by the cashier — not a live gateway integration). This mirrors treating Van Sales' Stripe Terminal work as a later, optional reference point, not something POS pulls in now.
- **No real payment gateway/processor is integrated in this phase or the next** — per your explicit restriction. `payment_providers` (existing, encrypted-at-rest credentials) remains the right *pattern* to reuse whenever real integration happens.
- Partial payment / layaway is naturally supported by the same split-tender model (a sale can sit at `grand_total > SUM(payments)` indefinitely while still `completed`... or should partial payment keep a sale in a `held`-like state instead of `completed`? **Flagging as a question**: recommend a sale only reaches `completed` once fully paid, with a `draft`/`held` sale that has partial payments recorded but not yet full staying in `held` — needs confirmation.

---

## 7. Reliability and security

- **Idempotency**: client generates a UUID for the "complete sale" action (or reuses `client_generated_id`, §8) and sends it once; `pos_sales.idempotency_key` is `UNIQUE`. A retry with the same key returns the **original** completion result (same `sale_number`, same status) rather than erroring or double-completing — critical for a POS terminal or Flutter client that retries on a network timeout without knowing whether the first attempt actually landed.
- **Duplicate checkout prevention**: covered by the above, plus a plain status check — calling "complete" on an already-`completed` sale is idempotent (returns the existing result), not an error.
- **Company/store/register/shift scope**: continues exactly the Phase 2/3.1 pattern — `req.pos.companyId/storeId/registerId` (from the hardened, live-re-checked middleware) is the only source of truth; a sale's `shift_id` ties it to the session that owns it.
- **Authorization**: completing/voiding a sale requires a staff token (not device-only), consistent with how shift-open/close already work. Whether it must be the *same* salesman who started the draft, or any staff on the *current* open shift for that register, mirrors the cart-ownership question in §3.3 — recommend the same store/shift-level answer for consistency, pending your confirmation.
- **Audit logging**: `pos_audit_logs` (§2) — every void, post-completion price mismatch (§4.5), and cancellation gets a row: `salesman_id`, `device_id`, `action`, JSON `details`, timestamp. Not built this phase, proposed for whichever phase first needs it (likely alongside completion, §9).
- **Transaction rollback and recovery**: every multi-step write (add-item + recompute totals; complete-sale + payment recording + [later] stock deduction) is one `withTransaction()` call — all-or-nothing, using the *correct*, already-proven pattern from Phase 2.1/3.1, never the pattern documented as broken in §1.4.

---

## 8. Future offline support (for the eventual Flutter frontend — forward-looking, not built now)

- **Client-generated IDs**: every cart/sale gets a client-generated UUID (`pos_sales.client_generated_id`) at creation time, *before* any network call — the app can create/edit a cart entirely offline. A `UNIQUE(device_id, client_generated_id)` constraint means a resync after connectivity returns can never create a duplicate sale from the same client-side id.
- **Sync conflict handling**: proposed `pos_sales.version` integer, incremented on every server-side update. A client submitting an update must echo the version it last saw; a mismatch returns `409 Conflict` with the current server state, so the client reconciles explicitly rather than silently overwriting (blind "last write wins" is not acceptable for money/inventory data).
- **Duplicate request prevention**: the same idempotency-key mechanism (§7) doubly matters for an offline queue, where a "complete sale" request might sit queued and get resent multiple times once the device regains connectivity.
- **Scope check**: everything built through Phase 3.1 is a synchronous request/response JSON API — there is no batch/queue endpoint for "replay N offline-queued operations" yet. A real offline-first architecture needs a dedicated sync protocol (a batch-upload endpoint, per-operation idempotency, conflict responses the client can act on) that is **substantially its own design effort**, not something this phase fully solves — §8 sketches the *data-model* hooks (`client_generated_id`, `version`) that any future sync design will need, without designing the full protocol now.

---

## 9. Risks and unresolved questions (compiled)

1. **Transaction numbering format** — simple ID-derived vs. human-readable period-reset (§4.4). Business decision.
2. **Cart/held-cart and sale-completion ownership scope** — store-level vs. shift-level (§3.3, §7). Recommend store-level; needs confirmation.
3. **Whether POS sales should mirror into buskit-web's `order`/`cart` tables** for unified reporting — carried over from Phase 1 §25, still unresolved.
4. **Whether POS returns write into the core `sales_return`/`customer_return_ledger`** or a new `pos_returns` table (§1.3, §6) — carried over, still unresolved.
5. **Exact promotion evaluation entry point is unconfirmed** (§1.3) — `b2bPromoAPI.js`'s exports look like promo-definition CRUD, not cart-time evaluation; needs its own targeted read before any promotion-aware pricing work, independent of this design.
6. **Whether POS decrements the same `varient_stock` ledger as the web-store, or something else** (§5.1) — carried over from Phase 1, this design assumes "same ledger" but that's not a settled decision.
7. **Price-change-at-completion behavior** — block-and-require-staff-review vs. silent refresh (§4.5).
8. **Partial-payment sale status** — does a partially-paid sale stay `held`, or can `completed` mean "finalized but not fully paid" (§6)?
9. **The FIFO transaction bug (§1.4) is a hard blocker** for any real stock deduction, per your explicit restriction — must be fixed (single connection + row locks, §5.3) and concurrency-tested before Phase 9 (below) touches real inventory.
10. **Full offline sync protocol is out of scope for this design** (§8) — only the underlying data hooks are proposed; the protocol itself needs its own future design pass.

---

## 9a. Recommended answers (2026-09-18 — proposed for review, not yet confirmed)

Organized by your priority table. These are recommendations to approve/override before Phase 5, not decisions made unilaterally.

### Critical

1. **Transaction number format** → **simple, ID-derived** (`POS-` + zero-padded `pos_sales.id`). Trivially unique, zero extra moving parts, no counter-table race to get wrong. If there's a specific business/compliance reason to want daily-reset receipt numbers later, that's addable as a separate `display_number` column without touching the underlying id-based one — not a blocker either way.
2. **Cart ownership/scope** → two-tier: a `draft` cart can only be mutated by the **shift** that owns it (prevents two cashiers editing the same in-progress cart concurrently); a `held` cart can be **resumed by any staff at the same store**, which re-assigns its `shift_id` to the resuming session. Company/store/register scope continues exactly the existing hardened-middleware pattern (Phase 2/3.1) — no change to how that works.
3. **Sale state transitions** → confirm the 5-state model as designed in §3.1/§4.1 (`draft → held → draft → completed/canceled`, plus a post-completion `voided`). `voided` is reachable only via an explicit void action that creates its own audit trail and reversing records — never a direct status flip.
4. **Order/cart mirroring strategy** → **recommend not mirroring**, at least initially. Writing POS sales into buskit-web's `order`/`cart` tables would double the write surface exactly where correctness matters most (money + inventory), and `order`'s schema carries a lot of order-management baggage (delivery status, approval workflow, credit terms) that doesn't fit a walk-up register sale. Unified reporting can be achieved later as a **read-side** concern (a query/view that unions `pos_sales` and `order` for dashboards) without POS ever writing into core tables — keeping the isolation this whole project has maintained. Flagging this as reversible once real usage patterns are known, not a permanent architectural wall.

### High

5. **Tax/pricing snapshot rules** → confirm §4.3/§4.5 as designed: snapshot `sell_price`+`tax` at add-time; discount stays `0` until promotions are analyzed (open question #8 below); at completion, **block and require staff review** on a live-price mismatch rather than silently refreshing — a POS register silently changing a shown price is a receipt-accuracy and trust problem.
6. **Returns data model** → **recommend a new `pos_returns` table**, not writing into core `sales_return`/`customer_return_ledger`, for the same isolation rationale as #4 — `sales_return`'s `pickup_salesman`/`pickup_status` columns are clearly shaped for a delivery-return workflow, not an in-store walk-up return. Same escape hatch: unify at the reporting layer later if needed, not the write layer now.
7. **Idempotency/duplicate checkout** → require the client to **always send** an idempotency key on the complete-sale call (not optional) — a missing key on a retry-prone client (mobile, and especially the future offline Flutter app) is a bug waiting to happen. Server generates one as a fallback only for simple, non-retrying callers (e.g. a basic web cashier UI), but the client-supplied path is the one to build and test first.

### Medium

8. **Promotion evaluation location** → **explicitly deferred**, not answered here. §1.3 already flagged that a targeted read of `b2bPromoAPI.js` didn't find a cart-time evaluator — recommend this be the **first research task** of whichever future phase reopens pricing, rather than guessing now or during Phase 5-7's build-out.
9. **Audit log structure** → confirm the `pos_audit_logs` shape from §2 as final, plus recommend a **fixed enum** of `action` values from the start (e.g. `item_removed`, `price_mismatch_override`, `sale_canceled`, `sale_voided`) rather than a free-text field, so the log stays queryable as it grows.
10. **Offline sync strategy** → **recommend treating as its own future design phase**, not decided now. §8 already scoped Phase 4 correctly to just the data hooks (`client_generated_id`, `version`); recommend the actual sync *protocol* work wait until the Flutter frontend's real constraints are known (expected offline duration, background vs. manual sync) — designing the protocol before those constraints exist risks over-engineering something that doesn't match real usage.

---

## 10. Recommended implementation phase sequence (proposed, not started)

- **Phase 5 — Cart CRUD**: `pos_sales`/`pos_sale_items` tables, create/add/update/remove/hold/resume/cancel, ownership + validation, reusing Phase 3's product lookup exactly. No payment, no stock deduction, no completion — carts only ever reach `held`/`canceled` in this phase.
- **Phase 6 — Sale completion without stock deduction**: `pos_sale_payments`, transaction numbering (once §4.4 is decided), idempotency keys, split-tender payment recording, price-revalidation-at-completion (§4.5) — sale reaches `completed`, but inventory is untouched. This deliberately decouples checkout/payment UX from the highest-risk inventory piece.
- **Phase 7 — Stock deduction**: implement §5.3's fixed FIFO function (single connection + `FOR UPDATE` locks), wire it into completion behind its own transaction boundary, concurrency-test it the same way Phase 3 proved the original bug (N concurrent transactions against a saturated pool) before it ever runs against real data.
- **Phase 8 — Returns/voids**: resolves open question #4, builds on a stable completion+deduction flow.
- **Phase 9 — Real payment integration and/or the full offline sync protocol**: only after 5–8 are stable; each is a substantial effort in its own right and should likely be its own dedicated phase rather than combined.

**Stopping here per your instructions — waiting for review and approval before any implementation begins.**
