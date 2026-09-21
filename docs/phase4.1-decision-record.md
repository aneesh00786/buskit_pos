# Phase 4.1 — Design Decision Record

Consolidates all 10 open questions from Phase 4 into confirmed decisions, deferred research items, and the resulting database/API implications for Phase 5+. This is the reference document Phase 5 (and every phase after it) implements against — supersedes the "recommended answers" (§9a) in `phase4-cart-sales-design.md` wherever the two differ.

**Nothing is created or implemented by this document.** It is the decision record only; Phase 5 begins after this.

---

## Critical decisions

### 1. Transaction numbering — CONFIRMED

**Decision**: simple, ID-derived format: `POS-` + zero-padded `pos_sales.id` (e.g. `POS-00000123`).

**Why this satisfies your conditions**: the `POS-` prefix is structurally distinct from every existing numbering scheme observed in `order.order_id` (`ORDER1170/September`, `DRAFT277/2026`) — no collision is possible, and no shared counter is touched. Uniqueness comes from the auto-increment primary key, not a separately-maintained counter, so there's no race condition to get wrong.

**DB implication**: `pos_sales.sale_number` (nullable until completion — a `draft`/`held` sale has no transaction number yet, only a `completed` one does). Derivable (`CONCAT('POS-', LPAD(id, 8, '0'))`) or stored — recommend **storing it** (set once, at completion) rather than computing on every read, so it never changes even if numbering logic evolves later.

### 2. Cart ownership and scope — CONFIRMED (synthesized from your directive + §9a)

**Decision**: company/store/register scope is always enforced via the existing hardened middleware (Phase 2/3.1) — unchanged. On top of that: a `draft` cart is locked to the shift that created it (only that shift's staff token can mutate it — prevents two cashiers concurrently editing the same in-progress cart). A `held` cart can be resumed by **any authenticated staff at the same store**, which reassigns its `shift_id` to the resuming session. This is "authenticated staff where applicable" made concrete: applicable = actively mutating a draft; not applicable = resuming a parked cart after a handover.

**DB implication**: `pos_sales.shift_id` is mutable (updated on resume), unlike `pos_shifts` itself which is immutable once closed. Ownership checks in the service layer: `draft` mutations require `req.pos.shiftId === sale.shift_id` in addition to the standard company/store check; `held→draft` (resume) requires only company/store match.

### 3. Sale state model — CONFIRMED

**Decision**: 5 states as designed — `draft → held → draft → completed | canceled`, plus a post-completion `voided` reachable only through an explicit void action (never a direct status flip). `canceled` is reachable only from `draft`/`held`, never from `completed`.

**API implication**: no generic "update status" endpoint — each transition is its own explicit action (`hold`, `resume`, `cancel`, `complete`, and later `void`), so each can carry its own authorization/validation rules rather than a single endpoint accepting any status value.

### 4. Order/cart mirroring — CONFIRMED, with your 4 conditions addressed

**Decision**: POS sales are **never** written into `order`/`cart`/`cart_detail`. Separate `pos_sales`/`pos_sale_items` tables only, unified at the **reporting layer**, not the write layer.

Addressing each condition:
- *"POS sales must have their own unique transaction numbers"* → satisfied by decision #1 (`POS-` prefix, structurally non-colliding).
- *"Reporting must clearly distinguish POS and existing sales"* → `pos_sales` rows are inherently distinguishable (different table, different id space, `POS-` prefixed number) — no ambiguity is possible even in a combined view.
- *"No duplicated writes across POS and legacy tables"* → confirmed by design: nothing in Phase 5+ writes to `order`/`cart`/`cart_detail`, ever, in any phase currently planned.
- *"Define how finance, sales reports, and customer history will combine the data"* → **proposed approach (design only, not built)**: a read-only reporting query/view that `UNION ALL`s a normalized projection of `order` and `pos_sales` (e.g. `source, transaction_number, customer_id, total, tax, status, created_at`), tagged with a literal `source = 'web'` or `source = 'pos'` column. Customer purchase history similarly queries both tables and merges by `customer_id`. **This reporting layer is not part of Phase 5-8 and is not scheduled yet** — flagging it as a real, needed piece of future work (likely alongside or after Phase 8/9), not something this decision defers indefinitely.

**DB implication**: no schema change to any existing table. No new "bridge" table needed for this — the union happens at query time.

---

## High-priority decisions

### 5. Returns data model — APPROVED IN PRINCIPLE, table creation BLOCKED pending sub-design

**Decision**: a new `pos_returns` table (not the core `sales_return`/`customer_return_ledger`), for the isolation reasons already agreed. **The table will not be created until the following are explicitly designed and reviewed** (per your instruction) — this is a Phase 8 prerequisite, not a Phase 5 task:

| Item | Status |
|---|---|
| Original POS sale/item references | Not designed — needs `pos_returns.original_sale_id` → `pos_sales.id` and a `pos_return_items` child table referencing `pos_sale_items.id`, analogous to how `sales_return`/`cart_detail.return_quantity` relate. |
| Partial vs. full returns | Not designed — needs per-line `returned_quantity` tracking (mirroring `cart_detail.return_quantity`'s precedent) so partial returns don't require a full-sale reversal. |
| Return quantity limits | Not designed — must prevent returning more than was originally sold minus already-returned, likely enforced via a DB constraint or a transactional check at write time. |
| Refund status/approval | Not designed — needs its own state machine (e.g. `requested → approved → refunded` or `rejected`), and a decision on whether refund and stock-restoration happen atomically or in separate steps. |
| Stock restoration rules | Not designed — this is stock-writing territory, meaning it inherits **all** of §5.3's single-connection + row-locking requirements from the FIFO design (adding stock back to `varient_stock` is just as concurrency-sensitive as deducting it). |
| Audit trail | Not designed in detail — reuses the `pos_audit_logs` shape (§9 below) conceptually, exact `action` values TBD. |
| Manager authorization for returns | **New open question, not previously identified**: POS currently has no role/permission tier beyond `device` vs `staff` (no "cashier" vs "manager" distinction exists anywhere in the auth model built so far). If returns need manager sign-off, POS needs a role concept it doesn't have yet — this is a prerequisite design decision for Phase 8, not something Phase 5-7 needs to solve. |

**This entire item is explicitly out of scope for Phase 5, 6, and 7.**

### 6. Tax and pricing snapshot rules — CONFIRMED, revised from the original Phase 4 proposal

**Decision (your correction, adopted)**: price and tax are snapshotted **at sale completion**, not at add-time. While a sale is `draft`/`held`, line items reflect the product's **live, current** `sell_price`/`tax` (re-read from `product_variation` whenever the cart is viewed or before completion) — there is no earlier snapshot to drift out of sync with, so the "block on price-mismatch-at-completion" mechanism from the original Phase 4 draft (§4.5) is **no longer needed and is superseded by this decision**. The snapshot happens exactly once, at the moment `unit_price`/`tax_amount` are written to `pos_sale_items` as part of the completion transaction — after that point they are immutable history.

**DB implication**: `pos_sale_items.unit_price`/`.tax_amount` are **nullable until completion** (or, more precisely, are only meaningfully populated at completion; a simpler alternative is to not persist them at all pre-completion and compute totals on the fly from a live join to `product_variation` for `draft`/`held` sales). Recommend the latter — cleaner, since it means `pos_sale_items` never holds a value that's known to be provisional. **Flagging this as the one remaining implementation detail to settle in Phase 5's own plan** (persist provisional prices vs. compute live) — both are compatible with this decision, it's an implementation choice, not a new open question.

**Consequence**: a product's price or tax rate changing while a cart sits in `held` state is no longer an error condition to detect — the customer simply gets whichever price is current at the moment the cashier hits "complete." This is simpler and matches many real POS systems' behavior.

### 7. Idempotency and duplicate checkout — CONFIRMED

**Decision**: the client **must** supply a unique checkout request identifier (idempotency key) on every complete-sale call — not optional. `pos_sales.idempotency_key` (`UNIQUE`), scoped per the decision in §9a (server generates a fallback only for simple non-retrying callers, but this is a Phase 6 concern, not Phase 5).

**DB implication**: relevant to Phase 6 (`pos_sale_payments`/completion), not Phase 5 (cart CRUD has no completion step yet).

---

## Medium-priority decisions

### 8. Promotion evaluation location — DEFERRED, formal research task recorded

**Decision**: not answered. Recorded as a **required research task before any future phase implements promotion-aware pricing** (not before Phase 5-7, which stay at base-price-only). Research scope, per your directive:
- Trace exactly where existing promotion eligibility/pricing is calculated (targeted read of `orderAPI.js`'s checkout path — `b2bPromoAPI.js` was checked and appears to be promo-definition CRUD, not a cart-time evaluator).
- Identify customer-, company-, product-, and date-based rule dimensions the existing `promotions` + 9 child tables (Phase 1 §3) actually support.
- Determine whether POS needs its own pricing engine or can share (read-only) the existing evaluation logic once located.
- Document how base price, discounts, tax, and promotions are meant to compose/conflict-resolve in the existing system, before designing POS's version.

**Not scheduled to a specific phase number yet** — correctly sequenced after Phase 7 (stock deduction) at the earliest, likely alongside or after Phase 8 (returns), since pricing correctness and returns/refund correctness are related concerns.

### 9. Audit log structure — CONFIRMED

**Decision**: `pos_audit_logs` as designed in Phase 4 §2, with a **fixed enum** of `action` values (not free text): starting set — `item_removed`, `price_mismatch_override` *(superseded by decision #6 — may be dropped or repurposed once Phase 6 settles the persist-vs-compute-live implementation detail)*, `sale_canceled`, `sale_voided`, `shift_discrepancy`. Explicitly **never logs secrets** — no PINs, no device secrets, no raw payment references, consistent with every prior phase's logging convention.

**DB implication**: not created in Phase 5 — first needed in Phase 6 (cancellation logging) at the earliest, more fully in Phase 8 (returns/voids).

### 10. Offline synchronization strategy — CONFIRMED

**Decision**: design the data-model hooks now (`pos_sales.client_generated_id`, `pos_sales.version`), implement the actual sync protocol later, once the Flutter frontend's real constraints (expected offline duration, background vs. manual sync) are known. No protocol design work happens in Phase 5-9.

**DB implication for Phase 5**: `pos_sales` includes `client_generated_id` (nullable, `UNIQUE(device_id, client_generated_id)` when present) and `version` (integer, default `1`, incremented on every update) from the start, even though nothing consumes them yet — cheaper to include now than to retrofit later.

---

## Summary: what Phase 5 actually needs to build

Given the above, Phase 5 (cart implementation only) needs:

- **Tables**: `pos_sales`, `pos_sale_items` (both new, not yet created).
- **NOT in Phase 5**: `pos_sale_payments`, `pos_audit_logs`, `pos_returns` — all deferred per the decisions above.
- **Endpoints**: create cart, add/update/remove item, hold, resume, cancel, get cart — no completion endpoint yet (Phase 6).
- **No stock read-write beyond Phase 3's existing read-only product/stock lookups** (for showing live price/stock while building a cart) — no deduction, no reservation.

A concrete Phase 5 plan (exact table SQL, file list, API request/response schemas) will follow as its own checkpoint before anything is created, consistent with every prior schema-touching phase in this project.
