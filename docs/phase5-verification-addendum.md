# Phase 5 — Verification Addendum

Checked all 5 points against the actual code and live database, not just re-asserted the completion report. One real gap found and fixed; one policy now explicitly documented; one honest disclosure about test isolation that wasn't caught by the original test plan.

## 1. Shift lookup scope — real gap found and fixed

Read `posShiftRepository.js::findOpenByRegister` directly: it had **no `company_id` filter at all** — `WHERE register_id = ? AND status = 'open'`. Checked whether this was currently exploitable: `posShiftService.js::openShift` (Phase 2) already validates `register.company_id === reqPos.companyId` before ever inserting a shift, so through the app's only write path, a `pos_shifts` row's `company_id` and its `register_id`'s real company are always consistent today. But `pos_shifts` has **no database-level constraint** tying those two together (no composite FK, unlike `pos_sale_items` → `pos_sales`), so this was correctness-by-code-discipline, not structural — exactly the distinction your question was getting at.

**Fixed**: `findOpenByRegister(registerId, companyId)` now filters on both, and its one call site (`posDeviceAuth.js`) passes `req.pos.companyId` (the live-verified value from the same request). Defense-in-depth, not currently load-bearing given today's call graph, but closes the gap structurally rather than relying on every future caller getting it right. Full regression re-run after this change — 84/84 still passing.

## 2. Held-cart cancellation permission — now explicitly documented as current policy

Confirmed the code does exactly what the plan describes: `cancelSale` in `posSaleService.js` requires shift-match for `draft`, store-match for `held` — no manager-role check exists anywhere, because POS has no role tier beyond `device`/`staff`. This was already stated in `phase5-cart-plan.md` §3, but per your request it's now also called out explicitly here as **the current, standing policy** (not an oversight): any authenticated staff member at the same store can cancel a held cart. Revisiting this once a manager role exists (already flagged as a prerequisite gap for Phase 8's returns work in the Phase 4.1 decision record) is a reasonable future hardening, not a Phase 5 defect.

## 3. Product/company validation — confirmed correct by direct inspection

```
grep -n "productRepo\.\(findById\|findByBarcode\)" services/pos/posSaleService.js
  61:    const product = await productRepo.findById(companyId, item.product_variation_id);
  228:    product = await productRepo.findById(reqPos.companyId, body.product_variation_id);
  230:    product = await productRepo.findByBarcode(reqPos.companyId, body.barcode);
```
All three call sites pass `companyId`/`reqPos.companyId` (server-derived) as the scope; `body.product_variation_id`/`body.barcode` are the only client-controllable inputs, and neither can affect *which company's* catalog is searched. Confirmed, not just claimed.

## 4. Migration rollback — now documented

`database/pos_migration_003_sales_cart.sql` didn't have a rollback section. Added one (documented only, not executed): `DROP TABLE pos_sale_items` then `pos_sales` (child before parent, per the composite FK), plus a note that reverting also means reverting the application code from this phase, not just the schema — since both tables were newly created by this migration, rollback has no data-migration complexity.

## 5. Test isolation — one honest disclosure, not just a clean bill of health

The fixture-creation pattern (random `Date.now()` + random-suffix identifiers for every `store_code`/`register_code`/`device_identifier`) makes collisions with pre-existing `pos_*` data effectively impossible, and every test cleans up exactly the rows it created by id. That part holds up.

**However**, one test ("viewing a sale with an active product...") directly toggled `product_variation.id = 2`'s `status` from `1` to `0` and back, via raw SQL, to exercise the availability-check behavior — and then restored it. This *is* a temporary write to an **existing** table's real data (confirmed restored afterward, and the original read-only check only verified row *counts*, which wouldn't have caught a transient content change like this). No POS application code path does this — it was the test script itself, deliberately, to exercise a scenario Phase 5's design required covering. In this dev environment (a single local MySQL instance, confirmed via `config/db.js`'s hardcoded `localhost`/`root` connection) this is low-risk, but it's not something that should run against a shared or production-like database, and it's exactly the kind of thing a proper isolated test database (still deferred, per every prior phase's `test/pos/` status) would eliminate entirely rather than relying on "toggle and restore quickly." Flagging this plainly rather than letting the original report's "all tests passed" framing imply cleaner isolation than what actually happened.

## Outcome

One real fix shipped (`findOpenByRegister` company-scoping), two things now explicitly documented rather than just implied (cancellation policy, rollback procedure), one thing confirmed correct by direct code reading rather than by trusting the earlier summary, and one honest gap disclosed about test isolation that the original test plan didn't anticipate. 84/84 tests still pass after the fix.
