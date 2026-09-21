# Tax alignment with the web store — report (2026-09-21)

Prerequisite to Phase 7. Trace: `tax-arithmetic-trace.md`. Nothing about stock, returns, promotions or gateways was touched.

## What changed
- **One shared implementation**: `services/pos/posTax.js` (pure, integer milli-units). Browse (`posProductRepository`), cart views and completion (`posSaleService`) all call it; no POS code reads `product_variation.tax` any more (grep-verified).
- **Rules (from web-store source)**: percent = SUM of `category_tax` rows, `status = 0`, ÷100; `incl_tax === 'incl_tax'` ⇒ price already contains tax (charged amount unchanged); `'N.A'` ⇒ no tax; NULL / '' / anything else ⇒ tax added on top; no rows ⇒ zero tax, never rejected. Rounding: half-up to 3 dp once per line, after summing percentages.
- **Browse response** `pricing` is now `{sell_price, tax_percent, tax_mode, tax_included, tax_amount, unit_total, discount:0, final_price:null, pricing_status}` (per-unit; the old `tax` key is gone — no frontend consumes it yet).
- **Snapshots**: `pos_sale_items.tax_rate` now stores the percent (12.000 = 12%); new `tax_included` column (migration 005, idempotent, applied to `busskit_new` and both test DBs). Safe to redefine: no real sale had been completed.

## One deliberate deviation — needs your confirmation
For **inclusive** lines the informational tax figure is the *embedded* tax `amount×pct/(100+pct)`. The backend persists `amount×pct/100` for such lines (overstated; it is simply not added), and the storefront itself is inconsistent (cart summary extracts, cart list doesn't). The **charged amount is identical to the web store in every case**; only this reported tax figure differs. It is isolated in `computeLine()` (one branch) if you'd rather mirror the backend's figure.

## Tests
- Full committed suite: **55 pass, 0 fail, 1 skipped (the opt-in smoke test)**, run 3× consecutively; test DB left empty. New `posTax.test.js` (9): mode mapping, exclusive, inclusive, N.A, multiple tax rows summed, inactive row ignored, zero-tax (0/null/NaN/negative), rounding & FLOAT noise, and browse == cart == completion for every mode, plus completed sales unaffected by later rate changes.
- Existing tests were updated to the new expected values (they had asserted the 30% `product_variation.tax` decoy).
- A fixture bug was found and fixed: `varient_stock` fixture inserts weren't idempotent (no unique key ⇒ duplicate batches on each bootstrap run).

## Scrubbed real-schema smoke test
`busskit_new_smoke_test` (user `pos_smoke`, no grants on `busskit_new` — verified `Access denied`): full schema clone (120/120 tables), sampled data for companies 1 and 142 (581 variations, 17 category_tax rows, 595 stock rows), **0 customers, 0 admin rows, staff names/contacts/passwords/tokens scrubbed**, company details scrubbed. Run: `POS_SMOKE=1 NODE_ENV=test POS_TEST_DB_NAME=busskit_new_smoke_test POS_TEST_DB_USER=pos_smoke node --test test/pos/posRealSchemaSmoke.test.js`.
- 112 real products (company 1: 68; company 142: 44) driven through browse → cart → completion; each checked against an independent oracle (own SQL + own arithmetic). Modes exercised: exclusive-taxed 11, zero-tax 29, inclusive 68, `N.A` 4. All pass; completion == cart == oracle; every line snapshotted; payments == grand_total == sum of lines; no catalog/tax/stock/staff row changed. `busskit_new` POS tables remain empty.
- Coverage gap: company 142 data has no exclusive-taxed products and company 1 has no `N.A` ones; exclusive/N.A are covered by the fixture suite and the other company respectively.

## Still open (yours)
- `.env` is still tracked by git (`git ls-files .env`): untrack + ignore + audit history + rotate; generate the production `POS_JWT_SECRET` on the server.
- Confirm the inclusive-tax-figure choice above.
- `server.js` now matches `HEAD` (someone committed the 2-line mount); nothing else in legacy code was modified by POS work.
