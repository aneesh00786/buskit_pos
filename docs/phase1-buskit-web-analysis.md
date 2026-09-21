# Phase 1 — buskit-web Analysis for ThriveWoo Retail POS

Read-only analysis of `/Users/aneesh/buskit-web` performed to prepare the isolated POS module in `/Users/aneesh/buskit-pos`. No files in buskit-web were created, edited, deleted, or renamed. No database write/DDL/DML was executed — all schema facts come from reading `busskit_new.sql` (3,131 lines, 85 `CREATE TABLE` statements) and the `database/*.sql` files on disk. Where something could not be confirmed from source, that is stated explicitly rather than assumed.

---

## 1. Executive summary

buskit-web is a single-process Express 4.18 monolith (`server.js`, 1,494 lines) serving both server-rendered EJS admin/web-store pages and ~450+ JSON API routes from one file, `Routes/authroutes.js` (43KB / 448 route registrations), plus several smaller route files for third-party integrations (Xero, QuickBooks, MYOB, Salesforce, Business Central) and one genuinely isolated feature module, **Van Sales** (`Routes/vanSalesRoutes.js` + `Controllers/VanSales/*` + dedicated `van_sales_*` tables). The Van Sales module is the closest existing precedent for "bolt an isolated module onto this monolith without touching the core," and its structure (dedicated route file, dedicated `Controllers/<Module>/` folder, dedicated tables, single `app.use()` mount line in `server.js`) is the recommended template for the new POS module.

Multi-tenancy is implemented entirely through a `company_id` (sometimes `companyId`) column threaded through almost every table and query — there is no schema-level tenant isolation (no row-level security, no per-tenant schema/database). Authorization is a mix of `express-session` (used by the web/admin UI, `req.session.user`) and a custom JWT layer (`jsonwebtoken`, used only for a small set of "TPA" third-party-API and Van Sales endpoints); the vast majority of the 448 routes in `authroutes.js` have **no route-level auth middleware at all** — trust is established (or not) inside each controller by checking whatever `company_id`/`admin_id` the client sent in the request body/query, which is a significant, structural finding for POS to design around rather than copy.

The database has no formal migration framework: `busskit_new.sql` is a hand-exported phpMyAdmin dump (and it contains an unresolved git merge-conflict block inside the `customers` table definition, lines 327–357 — the dump itself is not directly re-importable as-is), and schema changes are applied via one-off scripts (`add_cols.js`, `add_location_permission_cols.js`) or manually-run `.sql` files in `database/` with comments like "already applied to local dev, run manually elsewhere." Testing is a placeholder (`npm test` = `echo "Error: no test specified" && exit 1`); `test_folder/` holds stale duplicate copies of production files, not a test suite. There is no Dockerfile, no PM2 ecosystem file, and no nginx config inside the repo except a reference copy at `utils/webstore.conf` (wildcard-subdomain HTTPS reverse proxy to `127.0.0.1:4000`).

These findings directly shape the POS plan: build POS as a fully separate, sibling-module-style codebase (per the user's own decision to keep it in `/Users/aneesh/buskit-pos`), reuse buskit-web's MySQL database and `company_id` conventions for read access to product/customer/tax data, but do **not** reuse its ambient-trust authorization pattern, and bring POS's own auth derivation, its own migration discipline, and its own test tooling — none of which currently exist to inherit.

---

## 2. Existing backend architecture

- **Runtime**: Node.js + Express `^4.18.2` (`package.json`). No TypeScript anywhere (`server.js`, all `Controllers/*.js`, `Routes/*.js`, `services/*.js` are plain CommonJS `.js`, using `require`/`module.exports`).
- **Entry point**: `/Users/aneesh/buskit-web/server.js`. Boot sequence (verified by reading the file):
  1. `express()` app created; `compression`, file-based `morgan` access/error logs (`/var/log/node-access.log`, `/var/log/node-error.log` — absolute host paths, not repo-relative), `express.urlencoded`/`express.json` (50MB body limit), a custom `setTimezone` middleware.
  2. `app.disable('x-powered-by')`, EJS view engine, static serving of `views/` and `public/`, plus `/uploads`.
  3. `cors()` with default (fully open) config.
  4. `express-session` with a **hardcoded secret literal** in `server.js` (not read from env) and `cookie.maxAge = 86400000` (24h), `resave:false`, `saveUninitialized:true`.
  5. `tenantMiddleware` (`middleware/tenantMiddleware.js`) mounted globally, before all routes.
  6. Route mounting, in this order: `myroutes` (= `Routes/authroutes.js`, no prefix — this is the main app), `/quickbooks`, `/xero`, `/salesforce`, `/api/delivery`, `/myob`, `/businesscentral`, then `vanSalesRoutes` (no prefix; the module namespaces itself internally via `/van-sales/*` and `/api/van-sales/*` paths).
  7. `startEmailScheduler()` (from `Controllers/SuperAdmin/mail.js`) called synchronously at boot.
  8. Swagger/OpenAPI UI mounted at `/docs` from `docs/openapi.yaml` (496 lines — a partial/manually maintained spec, not auto-generated from the routes).
  9. Two background job starters called at module load time: `frequncy.startFrequencyJobs()` (`Controllers/productFrequency.js`) and `thrivewooSync.startThriveWooSyncJobs()` (`services/thrivewooSyncService.js`) — both presumably `node-cron`-based (package.json lists `node-cron: ^3.0.3`); exact schedules were not opened in this pass but the call sites confirm cron-style background jobs run in-process, not via a separate worker.
  10. `socket.io` server (`socketIo(server)`) attached to the same HTTP server for a chat feature (`join_room`, `chat message`, `disconnect` events) — real-time infra already exists in-process if POS ever wants live register/session updates.
  11. Generic error-handling middleware (413 for oversized uploads, else JSON 500) and a catch-all 404 renderer at the very end of the file.
- **Folder responsibilities** (as observed, not as documented — there is no architecture doc in the repo):
  - `Routes/` — thin route-definition files; almost all business logic lives in `Controllers/`, not here. `Routes/authroutes.js` is the one large exception aggregating ~30 controller modules.
  - `Controllers/` — 57 top-level files plus `Delivery/`, `SuperAdmin/`, `VanSales/` subfolders. Naming is inconsistent (`*API.js`, `*Controller.js`, `*Api.js`, `*APIS.js` all appear), and file sizes vary wildly (`orderAPI.js` is 357KB; `MyobSettingsController.js` is 162 bytes). Controllers directly `require('../config/db.js')` and write SQL inline — there is no repository/DAO layer.
  - `services/` — a mixed bag: some are genuine cross-cutting services (`stockService.js`, `creditService.js`, `tenantService.js`), others are third-party sync engines (`syncCustomersSalesforce.js`, `syncStaffXero.js`, `thrivewooSyncService.js`) and per-integration subfolders (`myob/`, `quickbook/`, `xero/`, `businesscentral/`).
  - `middleware/` — only 4 files (see §4).
  - `config/` — `db.js` (mysql2 pool), `config.js` (port/domain/JWT secret literals), `s3Client.js`, plus two `.sql` files that are **not** used by the app at runtime (`tables.sql`, `kanban_tables.sql` — the latter is empty).
  - `database/` — ad-hoc migration/seed `.sql` files for the Van Sales feature only; nothing for the core schema.
  - `utils/` — grab-bag of date helpers, common query builders (`commonUsage.js` is 44KB), mailer, S3 upload helper, and (concerning) several `.pem`/`.key` files sitting directly in `utils/` (`merchant.pem`, `merchant_identity.pem`, `merchant_private.key`, `private_key.pem`) — these are credential material co-located with application code, not read for content per the read-only/no-secret-values rule, but their presence and location is itself a finding (see §12).
- **Conventions**: snake_case DB columns, camelCase/mixed JS variables, response envelope pattern `{ status_code, status: true|false, message, data? }` used consistently across controllers (verified across `categoryAPI.js`, `customerAPI.js`, `vanSalesOrderAPI.js`), raw parameterized `mysql2` queries via a hand-rolled `getQueryPromise()` wrapper (no ORM/query builder).

---

## 3. Existing database structure

Single MySQL 8 database (`busskit_new`, per `config/db.js`), 85 tables in the core dump plus a separate set of `van_sales_*` tables defined only in `database/van_sales_schema.sql` (i.e., **not** present in `busskit_new.sql` — the Van Sales schema is tracked separately from the core dump, reinforcing that it was built as an isolated add-on). No FK constraints exist on tenant columns (`company_id` is never itself a foreign key to a `company`/`web_store` table); the ~20 real `ADD CONSTRAINT ... FOREIGN KEY` statements that do exist (lines 2952–3126 of `busskit_new.sql`) are on business/natural keys such as `cart.customer_id → customers.customer_id`, `cart_detail.cart_id → cart.cart_id`, `cart_detail.product_id → product.product_id`, `varient_stock.varient_id → product_variation.variation_id`, `order.customer_id/cart_id/salesman_id`, `promotion_* → promotions.id (ON DELETE CASCADE)`, `submenu.main_menu_id → main_menu.id`. Most tables (e.g. `customers`, `product`, `product_variation`, `categories`, `salesmans`) have **no** FK constraints at all despite clear logical relationships — referential integrity is enforced in application code, not the schema.

**Note on dump integrity**: `busskit_new.sql` lines 327–357 (inside the `customers` table definition) contain an unresolved git merge conflict (`<<<<<<< HEAD` / `=======` / `>>>>>>> master`), meaning this file as currently checked in cannot be executed as SQL without manual resolution. This should be flagged to the buskit-web maintainers independently of the POS work; it also means the "true" current `customers` schema is ambiguous between the two conflict branches (one includes `latitude`/`longitude`/`country`/delivery-address fields, the other doesn't).

### Tables relevant to POS (from `busskit_new.sql` unless noted)

| Table | PK | Key columns / notable FKs | Tenant column | POS-relevant assessment |
|---|---|---|---|---|
| `company` (line 223) | `id` | name, address, `time_zone`, `order_counter`/`invoice_counter` etc., `active_language` | is itself the tenant | Read-only reference for company profile/currency/timezone. Safe to read. No explicit currency/tax-jurisdiction column beyond `time_zone`. |
| `web_store` (1724) | `id` | `company_id`, `webstore_name`, `status` | `company_id` | This is the **actual tenant/subdomain resolution table** used by `tenantMiddleware`/`tenantService.js` (not `company`). Safe to read for tenant lookup by subdomain or company_id. |
| `admin_info` (30) | `id_admin` | `company_id`, email, `password` (hash) | `company_id` | Admin/owner accounts. Contains password hashes — must not be read/exposed by POS beyond auth delegation. |
| `salesmans` (1267) | `id` | `company_id`, `salesman_id` (string business key used everywhere else as FK target), `usertype`, `app_status`, `password` | `company_id` | This is the **staff/employee table** (despite the name, used for all non-admin logins incl. drivers). POS cashiers/staff would most naturally map here or to a new POS-specific staff-link table. Contains password hashes. |
| `user_roles` (1606) | `id` | `company_id`, `salesman_id`, `submenu_id`, `submenu_level2_id`, `status` | `company_id` | Menu-item-level permission grants (see §5). Purely additive per-menu-item flags, joined against `main_menu`/`submenu`/`submenu_level2` — a custom, non-RBAC-library permission model. |
| `customers` (317) | `id` | `customer_id` (string business key), `company_id`, credit fields (`credit_amt`, `credit_period`), integration IDs (`qb_id`,`xero_id`,`sf_id`,`myob_id`) | `company_id` | Directly reusable for POS "look up existing customer" / loyalty flows. **Contains an unresolved merge conflict** (see above) — column set differs by branch. Read-only reuse is reasonable; do not write. |
| `product` (898) | `id` | `product_id` (string business key), `company_id`, `catId`, `brandname` (string, not a brand table — see gap in §7) | `company_id` | Core catalog table. Safe to read for POS product lookup. |
| `product_variation` (942) | `id` | `company_id`, `product_id`, `variation_id` (string business key, used as FK target elsewhere), `barcode`, `price`, `sell_price`, `tax`, `stock`, `lowstock`, integration sync columns | `company_id` | This is where **barcode, price, and stock actually live** (not on `product`). Critical read table for POS scan-to-sell. `stock` here appears to be a denormalized/cached total; the authoritative live stock ledger is `varient_stock` (see below) — `stockService.js` computes current stock as `SUM(stock)+SUM(return_qty)-SUM(sold_count)-SUM(damage_qty)` per `varient_stock` batch, not by reading `product_variation.stock` directly. POS must use the same computed-stock convention or risk drifting from web-store stock. |
| `varient_stock` (1667, note the table's actual misspelling) | `id` (bigint) | `company_id`, `varient_id` (FK → `product_variation.variation_id`, `ON DELETE CASCADE`), `batch`, `stock`, `sold_count`, `return_qty`, `damage_qty`, `date` | `company_id` | The real inventory ledger, FIFO-batched (see `services/stockService.js::reduceStockAndUpdateSoldCount`, which does `BEGIN`/FIFO-loop/`COMMIT` across batches). **Any POS sale must decrement stock through the same batch-FIFO mechanism (or a POS-side equivalent) to stay consistent with web-store inventory** — this is the single highest-integration-risk table. |
| `order_item_batches` (768) | `id` | `order_item_id`→`cart_detail.id`, `order_pk`→`order.id` (`ON DELETE CASCADE`), `variant_id`→`product_variation.variation_id`, `batch_id`→`varient_stock.id` | `company_id` | Line-level batch attribution for stock decrements; POS sales would need an equivalent linking table if writing into the same stock ledger. |
| `categories` (134) / `sub_catagories` (1545) / `category_tax` (167) | `cid`/`id` | `company_id`, tax rate per category | `company_id` | Category-level tax rates live here, not on a global tax table — `sales_tax` (1377) exists but is scoped to `cart_id`/`product_id`/`variation_id`, i.e., it's a **line-item tax record generated at checkout time**, not a rate table. POS needs to replicate the "look up `category_tax` for the item's category, or use category default" logic (in `utils/commonUsage.js::CalcuteCategoryTax`/`GetSalesTax`, referenced from `orderAPI.js`) rather than inventing its own tax lookup, to keep tax treatment consistent between channels. |
| `discount` (466) | `id` | `company_id`, `customer_id`, `categories_id` | `company_id` | Per-customer/per-category discount table, used by the web ordering flow. Read-usable if POS wants to honor the same customer discounts at the register. |
| `staff_discounts` (1427) / `staff_discounts_category` (1444) | `id` | `company_id`, `item_id`/`category_id` | `company_id` | Staff-level discount config; same reuse logic as above. |
| `promotions` (985) + 9 child tables (`promotion_brands`, `promotion_bundles`, `promotion_bundle_items`, `promotion_categories`, `promotion_discounts`, `promotion_free_items`, `promotion_multi_item_deals`, `promotion_products`, `promotion_time_based`, `promotion_usage`) | `id` | `company_id`, `user_id`→`admin_info.id_admin`, all children FK→`promotions.id ON DELETE CASCADE` | `company_id` | Rich promo engine (percentage/flat/BOGO/bundle/time-based/tiered). Reusing this for POS discounts is possible but would require re-implementing all of this evaluation logic (currently only in `Controllers/b2bPromoAPI.js`, 54KB, not extracted into a shared service) — a real integration cost, not a trivial read. |
| `order` (708) | `id` | `order_id` (string business key), `company_id`, `customer_id`, `cart_id`→`cart.cart_id`, `payment_status`, `payment_type` (tinyint enum: 0=cash,1=cheque,2=bank transfer — **no card/digital-wallet value defined at the DB comment level**), `order_status` (14-value tinyint enum incl. "Quick Sale" = 14) | `company_id` | Core order header. Note `order_status` already has a "Quick Sale" (14) status — suggests the schema anticipated some walk-up/point-of-sale-like flow, but no controller in this pass was found implementing it beyond the enum value existing. |
| `cart` (80) / `cart_detail` (99) | `id` | `company_id`, `cart_id` string key (FK target for several children), `customer_id`→`customers.customer_id` | `company_id` | Pre-order-confirmation staging tables. A POS sale, if it reused this pipeline, would flow cart → cart_detail → order, same as the web store. |
| `sales_return` (1322) / `sales_return_items` (1346) / `customer_return_ledger` (387) | `id` | `order_id`→`order.order_id` (`ON DELETE CASCADE`), `cart_id`→`cart.cart_id` (`ON DELETE SET NULL`) | `company_id` | Returns/credit-note infrastructure already exists and is reasonably rich (damage vs normal vs writeoff return types, a debit/credit ledger). Strong candidate for POS returns to reuse rather than duplicate. |
| `payment_providers` (836) | `id` | `company_id`, `processor`, `credentials_encrypted`+`iv`+`auth_tag` (AES-GCM-style encrypted-at-rest credentials) | `company_id` | Per-tenant payment processor credentials (Stripe etc.), already encrypted at rest — good pattern to reuse for POS terminal/payment credentials rather than reinventing. |
| `pending_payment_links` (854) | `id` | `company_id`, Stripe session id | `company_id` | Existing Stripe Checkout session tracking; Van Sales additionally already integrates **Stripe Terminal** (physical card-reader) per `database/van_sales_migration_stripe_terminal.sql`, which is the most directly reusable precedent for POS card-present payments. |
| `sales_tax` (1377) | `id` | `cart_id`,`product_id`,`variation_id`, `company_id` | `company_id` | See note under `category_tax` above — this is a line-item snapshot table, not a rate table. |
| `invoice` (658) | `id` | `company_id`, `customer_id`, `cart_id`, `order_id` | `company_id` | Invoice records with a JSON blob (`items_data`) — reusable read-model for receipt generation. |
| `store_pick_list` (1477) / `pack_containers` (789) / `pack_container_items` (819) | `pick_id`/`id` | `tenant_id`, `store_id` (note: these two use `tenant_id`/`store_id` naming instead of `company_id`, an inconsistency in the schema) | `tenant_id` | Warehouse pick/pack workflow for order fulfillment. Interesting precedent: this is the *only* place in the core schema with a `store_id` concept, but it is not a real "stores/warehouses" table — it's a free-text/int id with no `stores` table backing it. **Confirms there is currently no warehouses/stores/locations table in buskit-web** (see gap in §7). |
| `van_sales_vans` / `van_sales_routes` / `van_sales_orders` / `van_sales_order_items` / `van_sales_collections` (database/van_sales_schema.sql) | `id` (AUTO_INCREMENT) | `company_id INT NOT NULL DEFAULT 1` | `company_id` | Confirms the precedent of "new isolated module → new `<module>_*` prefixed tables, own file, own migration script," which POS should follow (`pos_*` tables). Also confirms `payment_method` enums get widened additively over time (`Cash,Card,UPI,Cheque,Bank Transfer,QR,WhatsApp,Terminal` — Stripe Terminal added last) rather than normalized into a lookup table — a convention POS can either follow or improve on. |

**Assessment of read-only safety**: `company`/`web_store`, `product`, `product_variation`, `categories`/`category_tax`, `customers`, `discount`/`staff_discounts`, `varient_stock` (for read/stock-check only), and `promotions`* are all safe for POS to **read** without modification, provided POS always filters by `company_id` and never assumes uniqueness of the surrogate `id` column alone (several tables, e.g. `categories`, have composite primary keys like `(cid, category)`). POS must **not** write to any of these tables directly for its own transactions (sales/inventory decrements) without an explicit, reviewed integration decision, because the FIFO batch-stock mechanism in `varient_stock`/`order_item_batches` and the tax/promotion evaluation logic are non-trivial and currently only implemented inside `orderAPI.js`/`b2bPromoAPI.js`/`stockService.js` — duplicating vs. calling them is a decision needing developer sign-off (§17).

---

## 4. Existing API structure

- **Mounting**: `server.js` mounts one un-prefixed router (`Routes/authroutes.js`) that owns the vast majority of the surface area — 448 `router.get/post/put/delete` calls in that one file. Sub-areas are then given path prefixes only for third-party integrations (`/quickbooks`, `/xero`, `/salesforce`, `/myob`, `/businesscentral`, `/api/delivery`) and for the isolated `vanSalesRoutes` module, which self-prefixes its own paths (`/van-sales/*` for HTML pages, `/api/van-sales/*` for JSON — 40+ routes counted in `Routes/vanSalesRoutes.js`).
- **No versioning**: nothing under `/api/v1/` exists today anywhere in the codebase (confirmed by grep) — POS introducing `/api/v1/pos/...` will be the first versioned namespace in this codebase, which is fine (additive) but means there's no existing convention to match beyond "prefix + module name."
- **Path style**: heavily verb-in-path (`/fetch_customer`, `/add_product_b2b`, `/delete_customer_post`, `/update_credit_period`) rather than resource/REST style, almost entirely **POST for everything** including reads (e.g. `/fetch_customer`, `/fetch_order`, `/fetch_product_b2b` are all POST, presumably because body-based filtering was easier than query strings under `multer`'s `upload.none()` body-parsing). A few newer additions (`/promotions_b2b/:id` — GET/PUT/DELETE, in `authroutes.js` lines 576–579) use conventional REST verbs, suggesting a slow, inconsistent drift toward REST in newer code (the b2b promotions and Van Sales modules are the most "modern"-feeling parts of the codebase).
- **Body parsing per route**: nearly every route explicitly attaches `upload.none()` (multer, for `multipart/form-data` without files) or a specific `uploadX.single/fields(...)` for file uploads — this is a deliberate, repeated per-route middleware, not a global body parser for these cases (global `express.json`/`express.urlencoded` handle JSON/`x-www-form-urlencoded` bodies; `upload.none()` handles `multipart/form-data` text fields).
- **Auth middleware on routes — the key structural finding**: of the 448 routes in `authroutes.js`, only ~15 explicitly attach an auth middleware (`authWebOrApi`, used for `*_for_TPA` third-party-API endpoints like `/fetch_customer_for_TPA`, `/add_product_for_TPA` — see lines 629–645). `verifyToken` (`middleware/authMiddleware.js`) is imported into `authroutes.js` but **grep confirms it is never actually attached to any route in that file** — it exists but is dead code from a routing perspective (it may be used ad hoc inside a controller, but was not found wired as route middleware). The overwhelming majority of routes — including all customer, product, order, payment, report, and settings endpoints reachable from the main admin UI — have **no per-route auth middleware**; a code comment at line 75 of `authroutes.js` even says explicitly: *"Main menu routes - frontend handles authorization with page blur."* Authorization for these routes is instead performed ad hoc inside each controller by trusting a `company_id`/`admin_id`/`companyId` value taken from `req.body`, `req.query`, or occasionally `req.session`/`req.company_id` (set by `tenantMiddleware`) — see §5 for the concrete risk this creates.
- **Representative domain samples actually opened and read**:
  - **Category** (`Controllers/categoryAPI.js`, `fetch_categories_get`): trusts `req.query.company_id` directly, no auth check, all three queries (`sub_catagories`, `category_tax`, `categories`) filtered by that client-supplied `company_id`.
  - **Customer** (`Controllers/customerAPI.js`, 117KB): mixed sourcing of `company_id` — some functions read `req.body.company_id`, others `req.company_id` (tenant middleware), others `req.user.company_id` (JWT payload, for the few JWT-protected paths) — three different trust sources coexist in the same file (e.g. lines 2629–2637). Several queries build SQL via string interpolation of `companyId`/`customer_id` directly into the query string rather than parameter binding (e.g. lines 910, 927, 943, 960, 1105, 1116, 1317, 1344) — a SQL-injection-shaped pattern even though most call sites happen to source the value from validated numeric contexts today.
  - **Order** (`Controllers/orderAPI.js`, 357KB — the largest file in the repo): owns cart, checkout, payment recording, credit, returns, and order-processing/pick-list flows; imports `stockService`, `creditService`, `commonUsage`'s tax helpers — this is the single most important file to read further before designing POS's own checkout logic, since it is the only place all of tax + stock + promo + payment-status logic is currently composed together.
  - **Van Sales orders** (`Controllers/VanSales/vanSalesOrderAPI.js`) — cleanest example in the repo: derives `company_id` with a documented fallback chain (`req.session?.company_id || req.session?.user?.company_id || req.body?.company_id || req.body?.companyId`), fully parameterized queries, pagination, and inline comments explaining *why* each filter exists. This file is the best style reference for new POS controllers.
- **Cross-tenant API client auth** (`api_clients` table + `middleware/authWebOrApi.js`): a real client-credentials-style JWT flow exists for external "third-party API" (TPA) consumers — `authWebOrApi` verifies a bearer JWT signed with `API_JWT_SECRET` (env-var-sourced, unlike the hardcoded session/JWT secrets elsewhere) and injects `req.company_id`/`req.client_id` from the token claims. This is the most "correct" auth pattern in the codebase and is a plausible model for how POS terminals/devices could authenticate to buskit-web if POS ever needs to call back into it (though POS is being built as its own project with its own auth, per the task's framing).

---

## 5. Existing authentication and permissions

**Two coexisting auth mechanisms, used for different audiences — confirmed by reading, not assumed:**

1. **Session-based (`express-session`)** — used by the main admin/staff web UI. On successful login (`Controllers/loginAPI.js`), the server sets `req.session.user = { id, email, role: 'admin'|'staff', salesman_id? }` (lines ~1076, ~1960, ~2131). The session secret is a **hardcoded string literal in `server.js`** (not read from `.env`), which is a security weakness (session-signing secret checked into source control) — value withheld per instructions, but its presence and hardcoding is the finding.
2. **JWT (`jsonwebtoken`)** — used narrowly: `middleware/authMiddleware.js::verifyToken` signs/verifies with `JWT_SECRET` from `config/config.js`, which is **also a hardcoded literal** (`'testing_key'`) rather than sourced from environment — same class of weakness, and this constant is clearly a leftover dev value never rotated for "production." Despite being defined, grep confirms `verifyToken` is not attached as middleware anywhere in `authroutes.js`; its only confirmed live usage is via `server.js`'s import (unused in the reviewed portion) and it's unclear from this pass whether any other file actually applies it as route middleware (not found in the files opened). A **separate, better-designed JWT flow** exists specifically for third-party API + Van Sales integration: `middleware/authWebOrApi.js` verifies against `process.env.API_JWT_SECRET` (a real environment variable, confirmed present as a key in both `.env` and `.env_production` — value not read) and injects `company_id`/`client_id` from the token claims onto `req`.
3. **Role model**: coarse role (`'admin'` vs `'staff'`) stored in the session object at login time (not read from a `roles` table at request time — it's a snapshot taken once at login). Fine-grained permissions are separate: `user_roles` table (company_id, salesman_id, submenu_id, submenu_level2_id, status) joined against a static 3-level menu tree (`main_menu` → `submenu` → `submenu_level2`) lets an admin grant/revoke specific staff access to specific UI menu sections (`Controllers/PrivilegeAPI.js::load_menuPOST`, `update_role_actionPOST`). This is a **menu-visibility permission model**, not an API-level authorization model — i.e., it controls what UI sections a staff member's frontend shows, and (per the "frontend handles authorization with page blur" comment) there is no evidence found in this pass that these `user_roles` grants are independently re-checked server-side on every underlying API call. This is a material gap if POS wants to reuse buskit-web's permission concept for register-level access control.
4. **Tenant scoping is NOT authorization** — `middleware/tenantMiddleware.js` resolves a `web_store` row from the request's hostname/subdomain (or, on localhost, from a query param or session fallback) purely to know *which company's web-store page to render*; it explicitly bypasses itself for any path starting with `/api`, `/fetch_`, `/add_`, `/update_`, `/delete_`, `/login`, etc. (i.e., it does not protect the JSON API surface at all — see the `isBypassRoute` list, `middleware/tenantMiddleware.js` lines 24–42). The JSON API's tenant scoping is therefore done entirely by each controller trusting a client-supplied `company_id`, as described in §4 — **there is no server-side derivation-and-enforcement of `company_id` from an authenticated identity for the majority of routes**, which is the single most important structural fact for POS's own auth design to explicitly avoid replicating.
5. **Password storage**: `bcrypt` is a declared dependency and appears intended for use (`server.js` has a `hashmypassword` helper using `bcrypt.genSalt`/`bcrypt.hash`, though `bcrypt`'s `require` is commented out at the top of `server.js` — `// const bcrypt = require("bcrypt");` — meaning that particular helper would currently throw if invoked; whether login/registration paths elsewhere `require('bcrypt')` independently was not exhaustively verified in this pass).
6. **Confirmed SQL-injection-shaped code**: `Controllers/loginAPI.js` line 132 builds a login-lookup query via raw string concatenation of the `email` value: `` 'SELECT `salesman_id`,`usertype` FROM `salesmans` WHERE `email` = "' + email + '"' `` — this is not parameterized and is a genuine injection risk in an authentication code path. This is called out as a concrete, cited finding, not a generic caution.
7. **Rate limiting**: `middleware/authMiddleware.js::blockAfterLimit` implements a basic in-memory (per-process, non-persistent, resets on restart) IP-based login-attempt limiter (5 attempts / 5 minutes); `express-rate-limit` is a declared dependency but this pass did not confirm it's wired up globally.

---

## 6. Reusable read-only resources (what POS can safely read from buskit-web as-is)

Assuming POS is given direct, read-only MySQL credentials to the same `busskit_new` database (a decision requiring developer approval — see §17), these are safe to `SELECT` from, always filtered by `company_id`:

- `web_store` — resolve tenant/company by subdomain or id (mirrors `tenantService.js`'s two lookup functions).
- `company` — company display name/address/timezone for receipts.
- `product`, `product_variation` — catalog, barcode, price, tax rate, and (with the caveat above) a cached stock figure.
- `varient_stock` — for a live, correct stock check, POS should replicate the same aggregate query `stockService.js::ShowVarientStock` uses (`SUM(stock)+SUM(return_qty)-SUM(sold_count)-SUM(damage_qty)`) rather than trusting `product_variation.stock`.
- `categories`, `sub_catagories`, `category_tax` — category names and per-category tax rates.
- `customers` — customer lookup (loyalty/credit at register), being mindful of the merge-conflict ambiguity in that table's column set.
- `discount`, `staff_discounts`, `staff_discounts_category` — existing discount configuration, if POS wants price parity with the web channel.
- `promotions` + children — readable, but *evaluating* a promotion (is it active, does the cart qualify) requires porting non-trivial logic currently only implemented in `Controllers/b2bPromoAPI.js`; reading the rows alone is not sufficient to reuse promotions correctly.
- `sales_tax` — only useful as a historical reference (it's a snapshot per past cart line, not a rate table).

None of buskit-web's existing **write** endpoints (`/add_*`, `/update_*`, `/place_order`, etc.) should be treated as a stable "reusable API" for POS to call, because (a) most have no server-side authorization beyond a client-supplied `company_id`, and (b) they are POST-body-shaped internal endpoints, not a documented/stable contract — calling them from POS would silently couple POS to buskit-web's internal implementation details rather than a real integration boundary.

---

## 7. POS requirements not currently available (gaps)

Confirmed absent from buskit-web by source inspection (not merely "not found in the files sampled" — actively searched for and absent):

- **No stores/warehouses/locations table.** The only location-shaped concept (`store_pick_list.store_id`, `pack_containers.store_id`) is a bare integer/string with no backing `stores` table — there is nothing to join against for a real multi-location model. POS needs its own `pos_stores` concept from scratch.
- **No till/register/session concept.** Nothing resembling a cash-drawer, shift open/close, or register session exists anywhere in the schema or controllers searched.
- **No card-present/POS payment method on the core `order` table.** `order.payment_type` is a 3-value tinyint (`0=cash,1=cheque,2=bank transfer`) per its own column comment — no "card," "tap," or "wallet" value. (Van Sales separately widened its own `van_sales_collections.payment_method` enum to include `Card`/`Terminal`/`QR`/`WhatsApp` — that precedent lives only in the Van Sales module, not the core `order` table.)
- **No brands table.** `product.brandname` is a free-text varchar, not a foreign key to a `brands` table — "brand" is not a normalized entity anywhere in this schema.
- **No formal tax-rate table independent of category.** Tax is category-scoped (`category_tax`) or line-item-snapshot (`sales_tax`); there's no jurisdiction-aware or product-level tax-rate table.
- **No hardware/device registry.** Nothing for registering a barcode scanner, receipt printer, cash drawer, or card-reader device — the closest precedent is Van Sales' recent Stripe Terminal integration, which is payment-processor-specific, not a general hardware device model.
- **No API-level RBAC.** As established in §5, permission checks are UI-menu-visibility flags, not enforced per-API-call authorization — POS cannot "reuse" an authorization service because none exists at the API layer today.
- **No offline/sync framework.** The Van Sales module has *stubs* for this (`/api/van-sales/sync/status` and `/api/van-sales/sync/trigger` in `Routes/vanSalesRoutes.js`, lines ~93–101) that literally return hardcoded zero-counts and a `// TODO: Process pending offline transactions` comment — this is scaffolding, not a working offline-sync engine, and POS cannot treat it as reusable infrastructure.
- **No formal migration/versioning system** (see §8) and **no automated test suite** (see next) to build against with confidence that a shared-schema change won't silently break buskit-web.

---

## 8. Migration system

There is no migration framework (no Knex/Sequelize/Prisma/Flyway/Liquibase, no `migrations/` folder with up/down pairs, no schema-version tracking table found). What exists instead:

- `add_cols.js` and `add_location_permission_cols.js` — one-off Node scripts at the repo root that connect via `config/db.js` and run a single hardcoded `ALTER TABLE`, guarded only by a try/catch that special-cases the "Duplicate column" MySQL error message as a no-op. Run manually (`node add_cols.js`), not invoked from `package.json` scripts, no down-migration.
- `database/*.sql` — for the Van Sales module specifically: `van_sales_schema.sql` (full schema), `van_sales_migration_*.sql` (five incremental, additive-only migrations for credit limit, presale orders, route templates, Stripe collections, Stripe terminal, voice/language packs), and `seed_*.sql` seed-data files. These are well-commented (each states intent and idempotency guard, e.g. `ADD COLUMN IF NOT EXISTS`) but are still applied by hand per environment — one comment literally reads *"Already applied to the local dev database by this session. Run this against any other environment... before deploying."* This is a manual, discipline-dependent process, not an automated one.
- `busskit_new.sql` itself is a full phpMyAdmin structure+data dump, used as the canonical schema reference, not as an executable migration artifact (and, as noted, currently contains an unresolved merge conflict that would block a straight re-import).
- `seed.js` / `seed_van_sales.js` — a `npm run seed` script exists and is Van-Sales-specific (seeds vans, routes, customers, sample orders) — there is no equivalent core-schema seed script.

**Conclusion**: POS should not assume it can piggyback on any shared migration tooling from buskit-web, because none exists to piggyback on. POS needs its own migration approach from day one, and any schema changes POS ever needs *inside* buskit-web's database (e.g., new columns on `product_variation` for POS-specific fields) would have to follow this same ad-hoc, manually-run-`.sql`-file convention or introduce a real migration tool — a decision for the developer (§17).

---

## 9. Testing framework

Not a real test suite. `package.json`'s `"test"` script is the npm default placeholder: `"echo \"Error: no test specified\" && exit 1"`. No `jest`/`mocha`/`supertest`/etc. appears in `dependencies` or `devDependencies` (only `nodemon` is a devDependency). `test_folder/` contains four files (`Register.html`, `authroutes.js`, `loginAPI.js`, `orderAPI.js`) that are **stale duplicate copies** of real application files (e.g. `test_folder/authroutes.js` still imports `Controllers/productAPI` — a controller that no longer exists at that path in the live `Controllers/` directory, which now has `b2bProductAPI.js` instead) — this is a backup/scratch directory, not a test harness, and should not be treated as evidence of any testing convention to follow.

---

## 10. Process/deploy configuration

- **No Dockerfile**, **no PM2 ecosystem file** (`ecosystem.config.js` or similar), **no systemd unit file** found anywhere in the repo.
- **nginx**: one reference config exists at `utils/webstore.conf` (not `/etc/nginx/...` — this is a copy kept in the repo for reference/deployment, not something nginx itself reads from this path). It's a wildcard-subdomain (`*.thrivewoo.com`) HTTPS server block with TLS 1.2/1.3, standard security headers (HSTS, X-Content-Type-Options, X-Frame-Options, X-XSS-Protection), and a `proxy_pass http://127.0.0.1:4000` with WebSocket upgrade headers (`Upgrade`/`Connection: upgrade`) — consistent with the in-process `socket.io` server. Note the proxy target port (**4000**) does not match `config/config.js`'s hardcoded default port (**3000**) — the running production process must override the port via an environment variable or a different startup command not captured in this repo (this discrepancy could not be resolved from source alone and should be confirmed with whoever manages the production deploy).
- `package.json` scripts: `start` → `node server.js`, `server` → `nodemon server.js` (dev), `seed` → `node seed.js`. No `build` step (plain JS, no bundler/transpiler in the server codebase).
- Two TLS files sit in the repo root for local HTTPS dev (`localhost+2.pem`, `localhost+2-key.pem`, presumably `mkcert`-generated) — not used in the production nginx flow above, local-dev only.

---

## 11. Auth & authorization (see §5 for full detail — summary here)

Both session-based (`express-session`, admin/staff web UI) and JWT-based (`jsonwebtoken`, narrowly for TPA/Van-Sales API clients) mechanisms coexist; they are not layered (a request is not both), they serve different client types. The dominant pattern for the main API surface, however, is **neither** — most routes rely on no auth middleware and trust client-supplied `company_id`. Role model is a coarse `admin`/`staff` flag plus a custom menu-visibility permission table (`user_roles`/`main_menu`/`submenu`/`submenu_level2`), not an API-level RBAC/ABAC system.

---

## 12. Security risks

Concrete, cited findings from this pass (none exploited or tested against a live system — static reading only):

1. **Ambient-trust tenant scoping**: the majority of `authroutes.js` endpoints accept a `company_id`/`companyId` value from the request body/query and use it directly in queries with no verification that the calling session/token actually belongs to that company (e.g. `Controllers/categoryAPI.js::fetch_categories_get`, `Controllers/customerAPI.js` throughout). This is a cross-tenant data access risk (IDOR-shaped) affecting a large fraction of the API surface, not an isolated bug.
2. **SQL injection via string concatenation**: `Controllers/loginAPI.js` line 132 (`'... WHERE email = "' + email + '"'`) and multiple sites in `Controllers/customerAPI.js` (lines 910, 927, 943, 960, 1105, 1116, 1317, 1344) interpolate `companyId`/other values directly into SQL strings rather than using the parameterized `queryPromise(sql, params)` pattern used everywhere else in the same files. The login-path instance is the most serious given it's in an authentication flow.
3. **Hardcoded secrets in source**: the `express-session` secret (`server.js`) and `JWT_SECRET` (`config/config.js`, literal value `'testing_key'`) are checked into the repository rather than sourced from environment variables — unlike `API_JWT_SECRET`, `STRIPE_SECRET_KEY`, `ENCRYPTION_KEY`, etc., which correctly come from `.env`/`.env_production` (confirmed by variable-name-only inspection; no values read or reproduced here).
4. **Credential-shaped files in `utils/`**: `merchant.pem`, `merchant_identity.pem`, `merchant_private.key`, `private_key.pem` sit directly under `utils/` alongside application code. Their contents were not opened (out of scope / secret-value rule), but their location suggests they may be committed private-key material rather than environment-injected at deploy time — worth the buskit-web team independently confirming these are not sensitive or are properly gitignored.
5. **Dead/inconsistent auth middleware**: `verifyToken` is imported in `authroutes.js` but not attached to any route there, which risks a false sense of protection for anyone reading the imports without checking actual route wiring.
6. **`cors()` with no options** — reflects/allows all origins by default, appropriate for a single first-party frontend but worth confirming intentional given the API is also meant to serve mobile/Van Sales clients.
7. **In-memory rate limiting** (`blockAfterLimit`) is per-process and resets on every restart/deploy, and does not appear to be applied broadly (only found referenced alongside `authMiddleware.js`, not confirmed wired to the main login route in this pass) — not a robust brute-force defense.

**Implication for POS**: POS must not inherit buskit-web's "trust the client-supplied `company_id`" pattern. Whatever POS's auth mechanism is (device/terminal token, staff PIN, etc.), `company_id`/store scoping must be derived server-side from a verified credential, never accepted as a raw client-supplied field, in every new POS endpoint.

---

## 13. Compatibility risks

1. **Shared database, no formal contract**: if POS reads/writes `busskit_new` directly, any future buskit-web schema change (column rename, type change, the unresolved `customers` merge conflict eventually being resolved one way or the other) can silently break POS with no compiler/test signal, because there is no schema-versioning or contract-testing mechanism in place on the buskit-web side to catch it.
2. **Stock-ledger duplication/desync risk**: if POS decrements inventory independently rather than through the same FIFO `varient_stock`/`order_item_batches` mechanism `stockService.js` uses, web-store and POS stock will drift. This is the single highest-impact compatibility risk identified.
3. **Tax/discount/promotion logic divergence**: category tax, staff/customer discounts, and the promotion engine are all evaluated by bespoke logic embedded in large controller files (`orderAPI.js`, `b2bPromoAPI.js`, `utils/commonUsage.js`) with no shared, importable "pricing engine" module. POS reimplementing this logic independently risks producing different totals/tax amounts than the web store for the same customer/product/promo combination.
4. **Port/proxy mismatch** noted in §10 (nginx proxies to 4000, code defaults to 3000) suggests the actual runtime configuration is not fully captured by the repository alone — POS's deployment assumptions about "reusing buskit-web's deployment environment" should be validated against however the real production process is actually started (not found in this repo).
5. **No automated tests** on buskit-web means there is no regression safety net to detect if a POS-driven change (or even a POS-caused load pattern) affects the shared database/app in an unexpected way.
6. **`order_status` enum already has a "Quick Sale" value (14)** with no controller found implementing it in this pass — if a developer later wires this up independently on the web-store side, it could semantically collide with what POS considers a "sale," so this should be clarified with the team rather than assumed either way.

---

## 14. Files that must remain unchanged

Per this task's constraints, **the entire `/Users/aneesh/buskit-web` repository was not modified in any way**, and none of it should be, for POS Phase 1/2 purposes. Highest-risk areas specifically, if any future phase ever considers touching buskit-web at all (which was explicitly out of scope here):

- `/Users/aneesh/buskit-web/server.js` — single entry point; any change here affects every existing route, the session config, and the socket.io server for the entire monolith.
- `/Users/aneesh/buskit-web/middleware/authMiddleware.js`, `middleware/tenantMiddleware.js`, `middleware/authWebOrApi.js` — the entirety of buskit-web's auth/tenant resolution; POS must treat these as read-only reference material for understanding conventions, never as files to edit.
- `/Users/aneesh/buskit-web/config/db.js`, `config/config.js` — shared DB pool and secret constants; touching these affects every controller in the app.
- `/Users/aneesh/buskit-web/busskit_new.sql` and everything under `/Users/aneesh/buskit-web/database/` — the schema/migration history; POS should never edit these files, and any *new* column/table POS needs inside this database should be proposed as a brand-new, separately-reviewed migration, following the existing `database/van_sales_migration_*.sql` convention, not a hand-edit of the dump.
- `/Users/aneesh/buskit-web/Routes/authroutes.js` and all of `/Users/aneesh/buskit-web/Controllers/` — the existing route/controller surface; POS is a sibling project and should never add routes into this router.

---

## 15. Files that could potentially be created later (proposed paths — none created)

All paths below are proposals for Phase 2+ inside the **new, separate** `/Users/aneesh/buskit-pos` project (none of these exist yet):

- `buskit-pos/src/server.js` or equivalent entry point (own process, own port).
- `buskit-pos/src/routes/posRoutes.js` mounting everything under `/api/v1/pos/`.
- `buskit-pos/src/controllers/{stores,registers,shifts,sales,payments,returns,sync,devices}Controller.js`.
- `buskit-pos/src/services/{pricingEngineClient,stockClient,taxClient}.js` — thin, explicit clients wrapping whatever read access to buskit-web's DB/APIs is approved (see §17), rather than scattering raw SQL against buskit-web's tables throughout POS controllers.
- `buskit-pos/src/repositories/` — a real repository/DAO layer for the new `pos_*` tables, addressing the "SQL inline in controllers" pattern observed in buskit-web rather than repeating it.
- `buskit-pos/src/middleware/{deviceAuth,shiftGuard}.js` — POS's own, independently-derived tenant/store/shift authorization (explicitly not modeled on buskit-web's ambient-trust pattern).
- `buskit-pos/database/migrations/*.sql` (or a real migration tool's migration files) for the `pos_*` tables proposed in §9-of-the-brief (see §9 below in this doc's own numbering — POS's proposed tables).
- `buskit-pos/test/` — an actual test suite (buskit-web has none to inherit).

---

## 16. Proposed isolated POS architecture

Modeled directly on the Van Sales precedent (`Routes/vanSalesRoutes.js` + `Controllers/VanSales/*` + `van_sales_*` tables), but as a fully separate process/repo rather than a module inside buskit-web, per the task's own framing:

- **Process isolation**: POS runs as its own Node/Express process in `/Users/aneesh/buskit-pos`, its own `package.json`, its own port, reverse-proxied separately (or under its own subdomain/path) in whatever shared nginx config the deployment environment uses — it does not `require()` anything from `/Users/aneesh/buskit-web`.
- **Data access**: two layers, to be decided per table with developer approval (§17):
  - **Direct read access** to buskit-web's `busskit_new` MySQL database for the tables listed in §6 (`web_store`, `company`, `product`, `product_variation`, `varient_stock`, `categories`/`category_tax`, `customers`, `discount`/`staff_discounts`), via a dedicated read-only DB user with `SELECT`-only grants, isolated from POS's own tables.
  - **POS-owned tables** (`pos_*`, proposed in §9-of-brief below) — **developer decision (2026-09-18): live inside the same `busskit_new` database as buskit-web**, not a separate database, using the `pos_*` naming prefix (matching the `van_sales_*` precedent) to keep them clearly distinguishable from core tables. This means real FK constraints back to `company`/`web_store`/`product_variation`/`customers`/`salesmans` are now actually possible (unlike the cross-database app-layer-only validation originally proposed below) — POS's own migration scripts must still be applied by hand following the existing `database/van_sales_migration_*.sql` convention, since buskit-web has no automated migration tooling to plug into (§8).
- **Routing convention**: all POS endpoints under `/api/v1/pos/...`, resource-oriented (unlike buskit-web's verb-in-path style) — e.g. `GET /api/v1/pos/products?barcode=...`, `POST /api/v1/pos/sales`, `POST /api/v1/pos/shifts/:id/close` — establishing REST conventions from a clean slate rather than inheriting buskit-web's inconsistency.
- **Controller/service/repository layering**: unlike buskit-web (SQL inline in controllers), POS should have controllers → services (business logic: pricing, tax, stock-decrement orchestration) → repositories (parameterized SQL only) as separate layers, to keep the pricing/tax/stock consistency logic (which must mirror buskit-web's, per §13) in one testable place.
- **Auth**: POS defines its own device/terminal and staff-shift authentication from scratch (JWT or session, developer's choice), always deriving `company_id`/`store_id` server-side from a verified credential — explicitly not the ambient-trust pattern found in buskit-web (§5, §12).

---

## 17. Proposed new POS tables

**Updated 2026-09-18 per developer decision**: all proposed tables below live inside the existing `busskit_new` database (not a separate database), using the `pos_*` naming prefix, following the precedent set by `van_sales_*`. Where the table descriptions below say "cross-database reference, app-layer validated only," that constraint no longer applies — real FK constraints to `company`, `web_store`, `product_variation`, `customers`, and `salesmans` should be used where the relationship is 1:1 with an existing table's primary/business key, consistent with how `van_sales_*` tables reference core tables. The rest of each row's analysis (purpose, essentiality, risk) still holds.

| Table | Purpose | Key fields | Relationships | Tenant isolation | Duplicates existing data? | Essential? | Integration risk |
|---|---|---|---|---|---|---|---|
| `pos_stores` | Physical retail location a register belongs to | `id`, `company_id`, `store_name`, `address`, `timezone`, `status` | `company_id` conceptually maps to buskit-web's `company`/`web_store.company_id`, but no FK across databases is possible — must be validated at the application layer against a cached/looked-up `web_store` row | `company_id` column, always filtered | No — buskit-web has no stores/locations table at all (§7 gap) | Essential — nothing to build POS on without it | Low technical risk; the only risk is `company_id` values must stay valid against buskit-web's `web_store.company_id`, requiring either a periodic sync or a live lookup at store-creation time |
| `pos_registers` | A till/terminal instance at a store | `id`, `store_id`→`pos_stores.id`, `register_name`, `status` | `store_id` FK within POS's own DB | Via `store_id`→`store.company_id` | No | Essential | Low |
| `pos_devices` | Registered hardware (scanner, printer, card reader) bound to a register | `id`, `register_id`→`pos_registers.id`, `device_type`, `device_identifier`, `status`, `last_seen_at` | `register_id` FK | Via register→store | No | Important, not day-1-blocking | Low; mostly a POS-internal concern |
| `pos_hardware_devices` | If distinguished from `pos_devices` (e.g. this holds device *models/capabilities* while `pos_devices` holds *registered instances*) — recommend merging into a single `pos_devices` table with a `capabilities` JSON column rather than two tables, unless the team specifically wants a device-catalog vs. device-instance split | — | — | — | — | Marginal — likely redundant with `pos_devices`; flag for developer decision (§18) rather than building both | Low, but adds unnecessary schema complexity if kept separate |
| `pos_shifts` | Cash-drawer/register session open→close, with opening/closing float | `id`, `register_id`, `staff_id`, `opened_at`, `closed_at`, `opening_float`, `closing_float`, `status` | `register_id` FK; `staff_id` conceptually maps to buskit-web's `salesmans.salesman_id` (cross-database reference, app-layer validated only) | Via register→store→company | No — buskit-web has no shift/till concept (§7 gap) | Essential for cash accountability | Low technical risk; needs a decision on how `staff_id` is validated against buskit-web's `salesmans` table (§18) |
| `pos_sales` | The POS sale/transaction header | `id`, `shift_id`, `store_id`, `customer_id` (nullable, optionally maps to buskit-web `customers.customer_id`), `subtotal`, `tax_total`, `discount_total`, `grand_total`, `status`, `created_at` | `shift_id` FK; `customer_id` cross-database reference (app-validated) | Via shift→register→store→company | Partially — a "sale" here is conceptually similar to buskit-web's `order`+`cart`, but POS needs its own header shaped for register workflows (tender, change due, etc.) that `order` doesn't model | Essential | **Highest integration risk in this list**: whether `pos_sales` should ultimately sync into buskit-web's `order`/`cart` tables (so web-store reporting sees POS sales) is an open, developer-level decision (§18) — building this table is safe, but its *downstream sync* is not a solved problem |
| `pos_sale_items` | Line items per sale | `id`, `sale_id`→`pos_sales.id`, `product_variation_id` (maps to buskit-web `product_variation.id`/`variation_id`, app-validated), `sku`, `quantity`, `unit_price`, `tax_amount`, `discount_amount`, `line_total` | `sale_id` FK | Via sale | Conceptually mirrors `cart_detail` | Essential | Must replicate buskit-web's tax/discount calculation logic (§13) to avoid divergence — this is a logic-porting risk, not a schema risk |
| `pos_payments` | Completed payment records against a sale (supports split tender) | `id`, `sale_id`→`pos_sales.id`, `method` (cash/card/wallet/etc.), `amount`, `status`, `processor_reference`, `created_at` | `sale_id` FK | Via sale | No — buskit-web's `order.payment_type` is a single tinyint, no split-tender support (§7 gap) | Essential | Low, self-contained |
| `pos_payment_attempts` | Pre-settlement attempts (card auth pending, declined, retried) for audit/reconciliation | `id`, `sale_id`, `method`, `amount`, `attempt_status`, `processor_response` (careful: must not store raw card data — PCI scope), `created_at` | `sale_id` FK | Via sale | No | Important for reconciliation/audit, not strictly day-1-blocking | **Security-sensitive**: must ensure no PAN/CVV/track data is ever persisted here — a tokenized reference only, same pattern as buskit-web's `payment_providers.credentials_encrypted` (encrypt-at-rest) should inform this design |
| `pos_returns` | POS-side returns/refunds | `id`, `original_sale_id`→`pos_sales.id`, `staff_id`, `reason`, `refund_total`, `status`, `created_at` | `original_sale_id` FK | Via sale | Conceptually overlaps buskit-web's `sales_return`/`sales_return_items`/`customer_return_ledger` (§3) | Essential for a real POS | Medium — decide whether POS returns should also post into buskit-web's `customer_return_ledger` for a unified credit/ledger view (§18) |
| `pos_sync_events` | Outbox of POS transactions pending/completed sync to buskit-web (inventory decrement, order mirroring, etc.) | `id`, `event_type`, `payload` (JSON), `status` (pending/processing/failed/done), `attempts`, `last_error`, `created_at`, `processed_at` | References `pos_sales.id`/`pos_returns.id` loosely via `payload` | N/A (operational table) | No — buskit-web's own `/api/van-sales/sync/*` endpoints are stubs, not a real pattern to copy (§7) | Essential if POS and buskit-web's stock/order data must ever reconcile | This is where the stock-ledger-consistency risk from §13 must be resolved — recommend this be an explicit, reviewed design (event-driven reconciliation vs. direct dual-write) rather than improvised during implementation |
| `pos_audit_logs` | Append-only log of sensitive POS actions (voids, discounts applied, shift adjustments, manager overrides) | `id`, `store_id`, `staff_id`, `action`, `entity_type`, `entity_id`, `details` (JSON), `created_at` | Loose references via `entity_type`/`entity_id` | `store_id` | No | Important for loss-prevention/compliance, not a hard day-1 blocker but cheap to add early | Low |

**General note on all of the above (updated)**: since `pos_*` tables now live inside `busskit_new` itself (developer decision, 2026-09-18), cross-references (`company_id`, `staff_id`/`salesman_id`, `customer_id`, `product_variation_id`) **can and should** be real foreign keys where a 1:1 relationship to an existing table's key exists — this removes the app-layer-only validation burden described in the original per-table analysis above. Note that most of buskit-web's own core tables (e.g. `customers`, `product`, `product_variation`, `salesmans`) currently have **no FK constraints themselves** (§3) — POS's own tables should still add real constraints where possible (matching the ~20 FKs that *do* exist, e.g. `van_sales_*` → core tables) rather than following the majority no-FK convention, since consistency enforcement is one of the main benefits of sharing a database. `company_id` should still be included as a plain column on every `pos_*` table (no FK target exists for it even in core tables — `company_id` is never itself an FK anywhere in this schema, §3) and always used as the tenant filter in every query, exactly as buskit-web's own tables do.

---

## 18. Proposed new POS APIs (under `/api/v1/pos/`)

Illustrative, not exhaustive — grouped by the tables above:

- `POST /api/v1/pos/auth/device-login`, `POST /api/v1/pos/auth/staff-pin` — POS's own auth (not reusing buskit-web's session/JWT).
- `GET /api/v1/pos/stores`, `POST /api/v1/pos/stores`, `GET /api/v1/pos/stores/:id/registers`
- `POST /api/v1/pos/registers`, `POST /api/v1/pos/registers/:id/devices`
- `POST /api/v1/pos/shifts/open`, `POST /api/v1/pos/shifts/:id/close`, `GET /api/v1/pos/shifts/:id/summary`
- `GET /api/v1/pos/products?barcode=` / `?query=` — reads through to buskit-web's `product`/`product_variation` (+ live `varient_stock` aggregate)
- `GET /api/v1/pos/customers?search=` — reads through to buskit-web's `customers`
- `POST /api/v1/pos/sales` (create/hold a sale), `POST /api/v1/pos/sales/:id/items`, `POST /api/v1/pos/sales/:id/complete`
- `POST /api/v1/pos/sales/:id/payments` (record tender), `POST /api/v1/pos/payments/:id/void`
- `POST /api/v1/pos/returns`, `GET /api/v1/pos/returns/:id`
- `GET /api/v1/pos/sync/status`, `POST /api/v1/pos/sync/retry/:eventId`
- `GET /api/v1/pos/reports/shift/:id`, `GET /api/v1/pos/reports/store/:id/daily`

---

## 19. Data synchronization approach (POS ↔ existing system)

Two viable approaches, neither of which has an existing implementation to reuse (the Van Sales `/sync/*` stubs are placeholders only, §7):

1. **Outbox/event-driven (recommended)**: POS writes its own `pos_sales`/`pos_sale_items`/`pos_payments` transactionally within its own database, and separately appends a row to `pos_sync_events`. A background worker (in POS, or a small dedicated sync service) then calls into buskit-web — either via a to-be-built internal API (mirroring the `authWebOrApi`/`api_clients` JWT pattern already used for TPA integrations, §4) or via a direct, carefully scoped DB write — to decrement `varient_stock` using the same FIFO logic as `services/stockService.js::reduceStockAndUpdateSoldCount`, and optionally to mirror the sale into `order`/`cart`/`cart_detail` if unified reporting is required. Retries/failures are visible in `pos_sync_events.status`.
2. **Direct dual-write (higher risk, not recommended without strong justification)**: POS writes directly into buskit-web's `varient_stock`/`order` tables inline with each sale. This avoids building sync infrastructure but tightly couples POS's write path to buskit-web's internal schema and business logic (which, per §13, is only implemented inside large controller files, not a reusable service function) — any buskit-web schema/logic change silently risks breaking POS.

Either way, **stock decrement is the one piece of synchronization that cannot be deferred or approximated**, because both channels sell from the same physical inventory; everything else (order mirroring for reporting, customer credit updates) can reasonably be eventually-consistent.

---

## 20. Security risks

(Cross-reference to §12 for buskit-web's existing risks; POS-specific risks to design against from day one:)

- Do not replicate buskit-web's ambient-trust `company_id` pattern (§5, §12) — POS must derive tenant/store scope from a verified device/staff credential on every request.
- `pos_payment_attempts`/`pos_payments` must never persist raw card data (PAN/CVV/track2) — follow buskit-web's `payment_providers` precedent of encrypting processor credentials at rest, and prefer processor-tokenized references only.
- The cross-database references described in §17 (no real FKs) mean POS must validate `company_id`/`customer_id`/`product_variation_id` against buskit-web at write time, not just trust client input, or POS reintroduces the exact IDOR-shaped risk found in buskit-web itself.
- If POS is given direct MySQL credentials to `busskit_new`, they must be a dedicated, least-privilege user — read-only (`SELECT`) on the tables in §6, no write grants at all on buskit-web's own tables, enforced at the database-user level, not just by application discipline.
- Rate limiting and audit logging (`pos_audit_logs`) should be considered from the start, given buskit-web's own rate limiting is confirmed weak (§12.7).

---

## 21. Compatibility risks

(See §13 for the full detailed list; summary): shared-database schema drift with no contract testing, inventory-ledger desync if POS doesn't mirror buskit-web's FIFO batch logic, pricing/tax/promotion divergence if POS reimplements rather than ports buskit-web's calculation logic, an unresolved deploy-configuration ambiguity (port 3000 vs. 4000) that should be clarified with whoever manages production before POS assumes anything about "the same deployment environment," and the complete absence of automated tests on buskit-web to catch regressions caused by shared-resource contention or schema assumptions.

---

## 22. Files that must remain unchanged

(Restating §14 for completeness against the requested 17-section structure — see §14 above for the full list and rationale.) In short: all of `/Users/aneesh/buskit-web`, with `server.js`, the `middleware/` auth/tenant files, `config/db.js`/`config.js`, `busskit_new.sql`, everything under `database/`, and `Routes/authroutes.js`/`Controllers/*` called out as the specific highest-risk areas if any future phase ever reconsiders touching this repository.

---

## 23. Files that could potentially be created later

(Restating §15 for completeness — see §15 above for the full proposed path list, all inside the new `/Users/aneesh/buskit-pos` project; nothing has been created.)

---

## 24. Recommended implementation sequence for Phase 2+

1. **Developer decisions first** (§25) — especially the DB-access model (direct read vs. API), the stock-sync approach (§19), and whether POS sales/returns should ever mirror into buskit-web's `order`/`sales_return` tables. Building schema/APIs before these are settled risks rework.
2. **Stand up the POS project skeleton**: own `package.json`, own entry point, own (separate) database for `pos_*` tables, per §16.
3. **Build read-only integration first**: product/category/customer/stock lookups against buskit-web (§6), with a dedicated least-privilege DB user, before any write path exists. This validates the cross-database reference approach cheaply.
4. **Build core transactional tables and APIs**: `pos_stores` → `pos_registers`/`pos_devices` → `pos_shifts` → `pos_sales`/`pos_sale_items`/`pos_payments`, each with its own tests (buskit-web has none to inherit, so POS's test discipline must be built from scratch, §9/§15).
5. **Build `pos_sync_events` + the stock-decrement sync worker**, porting (not guessing at) the FIFO logic from `services/stockService.js::reduceStockAndUpdateSoldCount` — this is the highest-risk integration point (§13, §19) and should be reviewed/tested most heavily, ideally against a copy of buskit-web's schema rather than production.
6. **Add returns (`pos_returns`)** once core sales are stable, deciding then whether to also post into buskit-web's `customer_return_ledger`.
7. **Add `pos_payment_attempts`/hardware device registry/audit logs** as hardening once the core flow works end-to-end.
8. **Only after the above is stable**, consider order-mirroring into buskit-web's `order`/`cart` tables for unified reporting, if the business actually needs POS sales to show up in the existing web-store dashboards — this is an optional, higher-risk step that should not gate the core POS launch.

---

## 25. Questions requiring developer approval

1. **Database access model — partially resolved (2026-09-18)**: developer decided POS's own `pos_*` tables live in the same `busskit_new` database (not a separate one) — see updated §16/§17. Still open: whether POS's *application code* connects with a single shared DB user (read/write on `pos_*`, read-only on core tables) or two separate connection pools/users (one read-only for core tables, one read/write for `pos_*`) — the latter is safer (a bug in POS code can't accidentally write to `product`/`order`/etc.) and is recommended, but needs confirmation before Phase 2 sets up the DB connection layer.
2. **Stock synchronization**: must POS sales decrement the *same* `varient_stock` ledger in real time (strong consistency, higher coupling), or is eventual consistency via the outbox pattern (§19) acceptable for the business?
3. **Order mirroring**: should POS sales ever appear in buskit-web's `order`/reporting dashboards, or is POS's own reporting sufficient? This determines whether `pos_sales` needs a write path into `order`/`cart`/`cart_detail` at all.
4. **Returns unification**: should POS returns write into buskit-web's existing `sales_return`/`customer_return_ledger` tables (for a single customer credit ledger across channels), or stay entirely in `pos_returns`?
5. **Pricing/tax/promotion parity**: should POS port buskit-web's category-tax and promotion-evaluation logic (from `utils/commonUsage.js` and `Controllers/b2bPromoAPI.js`) as a shared, versioned module, or is it acceptable for POS to implement its own simpler tax/discount model initially and accept the price-parity risk noted in §13?
6. **Staff identity**: should POS staff logins be tied to buskit-web's existing `salesmans` records (single identity, cross-database validated), or should POS maintain its own staff/PIN table entirely, decoupled from buskit-web's HR/staff data?
7. **`pos_devices` vs `pos_hardware_devices`**: as flagged in §17, these look redundant as specified in the brief — confirm whether a device-catalog/device-instance split is actually wanted, or whether one `pos_devices` table (with a capabilities/type column) suffices.
8. **buskit-web's unresolved `customers` table merge conflict** (§3): this is a pre-existing defect in buskit-web unrelated to POS, but since POS plans to read from `customers`, the team should resolve which branch's column set is authoritative before POS builds against it.
9. **Deploy topology**: given the port mismatch noted in §10/§13 (nginx → 4000, code default → 3000), how exactly does POS "reuse buskit-web's deployment environment" — same host, same nginx instance with a new server block/location, same PM2-less `node server.js` process-management approach? This repo alone doesn't answer it.

---

*Analysis performed by reading source files, schema dumps, and configuration on disk only. No writes, migrations, or queries were executed against any database, and no files in `/Users/aneesh/buskit-web` were modified.*
