# Phase 9 — Customer & Promotion Management: API capability report

Date: 2026-09-22. Scope: API discovery in `buskit-web` (read-only; nothing
there was modified — confirmed by `git status` at the end of this phase
matching its state before it started), then Flutter UI built strictly within
what that discovery found. The `customers` table itself is reused exactly as
it already exists — no schema change anywhere, per your instruction.

## 1. Customer capability table

| Feature | Endpoint | Method | Auth model | Available to POS? |
|---|---|---|---|---|
| Attach a customer at sale creation | `POST /api/v1/pos/sales` (`customer_id` field) | POST | POS device+staff bearer token, company scoped from the verified token | **YES — already implemented** (Phase 1). Validated against the `customers` table (`customer_id` + `company_id`); 404 if unknown. |
| Change customer on an existing sale | — | — | — | **NO.** `posSaleService.js` only accepts `customer_id` in the sale-creation body; there is no `PATCH` for it afterward, by design (already documented in Phase 1). |
| List / search customers | `POST /api/van-sales/customers` (`VanSalesCustomerAPI.getCustomers`) | POST | **Session-cookie** (`req.session.company_id`), with a fallback to trusting `req.body.company_id`/`companyId` directly if no session is present | **NO** — see §1a |
| Customer detail | `POST /fetch_one_customer` (`Controllers/customerAPI.js`) | POST | Mounted with no auth middleware on the route itself; controller reads `company_id` from the request body | **NO** — see §1a |
| Create customer | `POST /add_customer` (legacy) / `POST /api/van-sales/customers/create` | POST | Same as above — body-trusted `company_id` | **NO** — see §1a |
| Update customer | `PATCH /update_customer` | PATCH | Same pattern | **NO** — see §1a |
| Activate/deactivate | Implied by `status_type` field in `add_customer`/`update_customer`; no dedicated toggle endpoint found | — | — | **NO** |
| Customer groups | No `customer_group`/`customer_groups` table or field found anywhere in the schema or controllers searched | — | — | **NOT FOUND** |
| Customer-specific pricing/discount | `POST /customer_discount`, `POST /fetch_customer_discount_list`, `POST /fetch_customer_discount` (legacy, `authroutes.js`) | POST | Same body-trusted pattern | **NO** — and even if reachable, `posSaleService.js` never reads it (see §2) |
| Customer purchase history | No dedicated endpoint; the closest is the Sales History feature (Phase 8), which filters by cashier/date, not customer | — | — | **NOT FOUND** for "sales by this customer" specifically |

### 1a. Why the existing customer endpoints are not POS-appropriate (not just "different")

This is the distinction you asked me to make explicit, so I checked the actual
controller code rather than assuming:

- `VanSalesCustomerAPI.getCustomers`: `const rawCompanyIdInput = req.session?.company_id || req.session?.user?.company_id || req.body?.company_id || req.body?.companyId;` — if there's no session, it falls back to **whatever `company_id` the caller puts in the request body**. A POS device has no session cookie at all (it authenticates with a bearer JWT), so every call from the POS app would hit that fallback — meaning the POS app, or anyone who captured its traffic, could read any company's customer list just by changing a body field.
- `Controllers/customerAPI.js` (`add_customer_post`, `fetch_customer_get`, `search_customer_POST`, etc.): every one of these reads `company_id`/`companyId` straight from `req.body`, with **no auth middleware on the route declarations in `Routes/authroutes.js`** visible in this codebase. Same problem, and it's mounted unconditionally (`app.use(myroutes)` in `server.js`, `verifyToken` is commented out globally).
- Every other POS endpoint (`/api/v1/pos/*`) is built the opposite way on purpose — `company_id`/`store_id` come **only** from the verified JWT payload, never from client input (this is stated directly in `posDeviceAuth.js`'s own comments and enforced by `posSaleService.js` throughout). Wiring the Flutter app to the legacy endpoints would mean either building a second, incompatible auth flow (cookie/session login) inside the POS app, or sending a `company_id` the server would trust blindly — reintroducing exactly the cross-tenant risk the POS module was built to avoid. I did neither.

This is a pre-existing condition in `buskit-web`, not something introduced or made worse by this phase — I'm reporting it because it's directly relevant to why I didn't integrate these endpoints, not asking you to fix it here.

## 2. Promotion capability table

| Feature | Endpoint | Method | Auth model | Available to POS? |
|---|---|---|---|---|
| Promotion list | `GET /promotions_b2b` (`Controllers/b2bPromoAPI.js`) | GET | **None found** — `company_id` read straight from `req.query`, no auth middleware on the route | Exists, but **not safely usable** (see below) |
| Promotion detail | `GET /promotions_b2b/:id` | GET | Same | Same |
| Create/update/delete promotion | `POST`/`PUT`/`DELETE /promotions_b2b[/:id]` | — | Same | Admin/management tooling, not a POS concern either way |
| Eligible products/categories/customers for a promotion | `GET /promo-products_b2b`, `/promo-categories_b2b`, `/promo-customers/...` | GET | Same | Same |
| **Eligibility check for a specific customer/cart** | — | — | — | **NOT FOUND** |
| **Apply a promotion to a sale** | — | — | — | **NOT FOUND** |
| Discount in sale completion | `services/pos/posSaleService.js:169` | — | — | **Explicitly hardcoded to zero**: `const discountTotal = 0; // no promotion/discount evaluation yet (decision #8)`. The completion pipeline has no field or code path for a discount at all today. |

**This settles it decisively, independent of the auth issue above**: even if
`b2bPromoAPI` were safe to call from POS, there is nowhere in the sale
lifecycle for a discount to go — completion always computes `discountTotal =
0`. Building an "Apply" button anywhere in the POS app would be pure fiction
right now. Per your own framework (§8 Case C), the honest answer is:
**"Promotions are not available from POS yet."**

`b2bPromoAPI.getPromotions` also has the same unauthenticated,
query-string-trusted `company_id` pattern as the customer endpoints — worth
knowing regardless of the POS question, but not something I touched or need
to fix for this phase.

## 3. Missing-capability write-ups (per your template)

### Customer search/list/detail, POS-scoped

- **Missing capability**: a way for the POS app to search or list customers by name/phone/email, or fetch one customer's contact details, scoped safely to the requesting device's company.
- **Required endpoint(s)**: e.g. `GET /api/v1/pos/customers?q=` and `GET /api/v1/pos/customers/:customer_id`, under `posDeviceAuth` (+ `requirePosStaff` if writes are ever added).
- **Why it's required**: today the cashier can only type a customer ID they already know by heart (Phase 1's `customer_dialog.dart`) — there's no way to find a customer from the register.
- **Suggested request**: `GET /api/v1/pos/customers?q=<name/phone/email>&limit=20` — `company_id` taken from the verified token, exactly like `/api/v1/pos/products`.
- **Suggested response**: a small, POS-relevant subset of the existing `customers` table — `customer_id`, `fullname`, `mobileno`, `email`, `status` — **no schema change**, just a new read-only query against the table that already exists.
- **Security considerations**: must derive `company_id` from `req.pos.companyId` (the verified token), never from the request; should probably cap fields returned (no need to expose every legacy column, e.g. addresses, to a register).
- **Impact on existing POS flow**: purely additive — the existing guest/customer-ID dialog keeps working unchanged if this is never built; if it is, that dialog is the natural place to add a search field.

### Customer creation, POS-scoped

- **Missing capability**: creating a new customer from the register.
- **Required endpoint**: e.g. `POST /api/v1/pos/customers`, same auth pattern.
- **Why required**: section 5 of your brief asks for "New Customer" at the register; today that would have to either duplicate the legacy unsafe endpoint or not exist.
- **Suggested request/response**: mirror `add_customer`'s useful fields (name, phone, email at minimum) but validate/scope exactly like every other `/api/v1/pos/*` write.
- **Security considerations**: same company-scoping requirement; also decide whether POS-created customers need any different status/approval than web-created ones.
- **Impact**: none on existing flow if not built.

### Change customer on an in-progress sale

- **Missing capability**: attaching or changing a customer after the sale already exists (today: creation-time only).
- **Required endpoint**: e.g. `PATCH /api/v1/pos/sales/:id` (or a dedicated `/sales/:id/customer`) accepting `customer_id` + `expected_version`, following the same lock→validate→bump-version pattern every other sale mutation uses.
- **Why required**: your brief's flow (`Current Sale → Select Customer → ... → Attach customer to sale`) assumes this exists for an already-started sale; it doesn't. Today the only way to change the customer is to void the sale and start over — which the cart UI already tells the cashier plainly ("The customer is set when the sale starts. Void the sale to change it.").
- **Security/impact**: needs the same version-conflict (409) and shift/store ownership checks `updateItem`/`cancelSale` already have.

### Customer-specific promotion eligibility + application

- **Missing capability**: both "what promotions can this customer use" and "apply this promotion to this sale" are entirely absent.
- **Required endpoints**: e.g. `GET /api/v1/pos/customers/:id/promotions` (eligibility) and something like `POST /api/v1/pos/sales/:id/promotions` (application) that recomputes and returns server totals.
- **Why required**: this is the core of sections 7–9 of your brief.
- **The bigger blocker**: `posSaleService.js` has no discount field in its completion math at all (`decision #8`). Adding promotion application isn't just a new route — it changes the completion calculation, which is exactly the kind of backend change this phase was told not to make.
- **Security considerations**: the backend must remain the sole source of truth for eligibility/discount/tax/total, per your own §7 — this needs real design work (rounding, tax interaction, idempotency-key implications), not a quick addition.
- **Impact on existing POS flow**: significant — it touches the same completion path Phase 6/7 tested exhaustively (concurrency, rollback, idempotency). Recommend this be its own dedicated backend design phase, the same way stock deduction (Phase 7 of the backend's own numbering) got one, rather than folded into a POS-side phase.

## 4. What this means for scope

Given the above, almost everything sections 2–9 of the brief describe has
**no safe backend capability today**. Building search/list/create/detail
screens, a customer-to-sale mid-sale flow, or any promotion UI with real data
would mean either inventing endpoints (explicitly forbidden) or wiring the
Flutter app to endpoints that trust client-supplied tenant scoping (a real
security regression, not just an inconsistency). I did neither.
