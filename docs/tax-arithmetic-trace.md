# Web-store tax arithmetic — traced from source (input to POS tax design)

Traced 2026-09-21 in `buskit-web`. Nothing here is assumed from the flag's name; every rule cites where it is enforced.

## 1. What `incl_tax` holds (live data, active products)
`'incl_tax'` = 501, `'N.A'` = 4, `NULL` = 109, `''` (empty) = 41. `cart_detail`: `'incl_tax'` 1726, `'N.A'` 58, NULL/empty 1355.

## 2. Rules, with sources
| Question | Rule | Source |
|---|---|---|
| Tax rate source | Sum **all** `category_tax` rows for `(cat_id, company_id, status = 0)`; `TaxAmount = price × totalPercent / 100` (percentages summed first, one calculation) | `utils/commonUsage.js::CalcuteCategoryTax`; `product_variation.tax` is never read |
| Is `sell_price` tax-inclusive? | **Only when `incl_tax === 'incl_tax'`.** NULL, empty string and `'N.A'` are all treated as tax-**exclusive** by every total | `orderAPI.js` 2610, 4614, 4834, 4859; `web_store.js` 2172; product cards show "(Incl.Tax)" only for the exact value `'incl_tax'` (`web_store.js` 795) |
| `'N.A'` | Tax is **not calculated at all** (zero tax); price is the total | `orderAPI.js` 1438 / 1692 (`if (incl_tax != "N.A") tax = CalcuteCategoryTax(...)`) |
| Line total, exclusive | `amount + tax` | `orderAPI.js` 2613–2616, 4614–4618 |
| Line total, inclusive | `amount` (tax is **not** added) | same |
| Order-level tax added on top | `SUM(cart_detail.tax)` **excluding** `incl_tax` rows | `commonUsage.js::GetSalesTax` |
| Base for tax | amount **after** line discount (`amount = price × qty − discount`) | `orderAPI.js` 1410–1421 |
| No category-tax rows | `TaxAmount = 0`; nothing rejected. Errors in the lookup also return 0 | `CalcuteCategoryTax` |
| Rounding | No explicit rounding in code; values persist into `DECIMAL(10,3)` columns, i.e. rounded to 3 dp by MySQL | column types |

## 3. The one inconsistency (informational tax on inclusive lines)
The amount charged is unambiguous in every path. The *tax figure shown for an inclusive line* is not:
- Backend persisted `cart_detail.tax` (and `sales_tax`): `amount × pct / 100` — computed as if the price were exclusive, even for `incl_tax`, then simply not added.
- Storefront cart summary (`web_store.js` 2277–2280): `amount × rate / (100 + rate)` ("extract embedded tax").
- Storefront cart list (`web_store.js` 2168–2172): `amount × rate / 100`.

## 4. POS decision — FINAL (confirmed by the product owner 2026-09-21)
Charged amount = exactly the web store's. Informational tax on **inclusive** lines = the *embedded* tax `amount × pct / (100 + pct)` (the tax actually contained in the price), because POS `tax_total` will be reported as "tax collected" and the backend's `amount × pct / 100` would overstate it while `subtotal + tax ≠ total`. This is the only line of arithmetic that deviates from what the backend persists, is isolated in `services/pos/posTax.js`, and is flagged for confirmation. Everything else matches.

## 5. POS rounding rules
All money in integer thousandths. Per line: tax rounded **half-up to 3 dp once per line** (after summing category percentages), never per tax row. Percent sums are normalised to 4 dp before use (the `category_tax.tax` column is a `FLOAT`). Totals are sums of already-rounded line values. No discounts/promotions (still deferred, decision #8); piece pricing only (pack pricing is out of POS scope, as before).

## 6. POS accounting semantics vs legacy backend reporting (explicit)
- POS `tax_total` / `tax_amount` on an inclusive line is **the tax contained in the price the customer paid** (`amount × pct / (100 + pct)`). It is **not** a copy of the legacy backend's informational `cart_detail.tax` / `sales_tax.tax` for such lines (`amount × pct / 100`, which is not added to the total and overstates the contained tax).
- Amount charged is identical to the web store in all modes. Only the *reported tax figure on inclusive lines* differs; any future unified report (POS ∪ web store) must not sum the two figures as if they were the same measure for inclusive lines.
- Invariant (tested): tax-exclusive amount + tax = total. Inclusive: `(listed price − tax) + tax = listed price`; exclusive: `listed price + tax = total`.
- `totals.subtotal` = sum of listed prices (gross for inclusive lines). Consequently `subtotal + tax_total = grand_total` only when there are no inclusive lines; use `grand_total` as the amount due.
- Legacy web-store tax logic is untouched.
