# Phase 2 — POS Backend Foundation: Inspection Findings + Implementation Plan (Proposal, awaiting approval)

**Status: PROPOSAL ONLY.** Per the Phase 2 STOP CONDITION, nothing in this document has been created or executed yet — no files, no migrations, no code. This is the analysis + schema + implementation plan for review. Zero files were modified inside `/Users/aneesh/buskit-web` while producing this document; all commands run were read-only (`cat`, `grep`, `sed -n`, `ls`, `awk`, `node -v`).

---

## 1. Re-inspection findings (Step 4 of the brief)

Confirmed directly from source, this session:

1. **DB name confirmed**: `busskit_new` (`config/db.js` — `mysql.createPool({ database: 'busskit_new', ... })`). Note: `config/db.js` connects with hardcoded `host: 'localhost', user: 'root', password: ''` — it does *not* actually read DB credentials from `.env` despite `require("dotenv").config()` being called (a pre-existing buskit-web inconsistency, not something this phase touches).
2. **Engine/charset confirmed**: every table in `busskit_new.sql` is `ENGINE=InnoDB DEFAULT CHARSET=utf8mb4` (mostly `COLLATE=utf8mb4_general_ci`, `web_store` is the one exception at `utf8mb4_0900_ai_ci`). **InnoDB supports real foreign keys** — confirmed technically possible, consistent with your Phase 1 decision to keep POS tables in this same database.
3. **No `pos_*` naming collisions anywhere** — confirmed via repo-wide grep (`pos_stores`, `pos_registers`, `pos_devices`, `pos_shifts`, `posRoutes`, `Controllers/POS` all return zero matches outside `node_modules`). Safe to use these names.
4. **Reference table keys/types** (needed for FK compatibility), confirmed from `busskit_new.sql`:
   - `company.id` — `int NOT NULL AUTO_INCREMENT`, PRIMARY KEY. Safe FK target.
   - `web_store.id` — `int NOT NULL AUTO_INCREMENT`, PRIMARY KEY. `web_store.company_id` — plain `int`, **not** itself a FK (confirmed, matches Phase 1 finding that `company_id` is never an FK anywhere in this schema).
   - `salesmans.id` — `int AUTO_INCREMENT` PK; `salesmans.salesman_id` — `varchar(70)`, has a plain `KEY smid_idx`, already used as an FK target by 6 existing constraints (e.g. `customer_return_ledger.salesman_id_foreign`) — confirmed safe, precedented FK target.
   - `product_variation.id` — `int UNSIGNED AUTO_INCREMENT` PK; `product_variation.variation_id` — `varchar(255)`, has a plain `KEY variation_id`, already an FK target (`varient_stock.varient_id → product_variation.variation_id`) — confirmed safe (not needed until a later phase's `pos_sale_items`, noted here for continuity).
   - `customers` — **still contains the unresolved git merge conflict** at the same lines flagged in Phase 1 (confirmed still present). Not needed for this phase's tables, but flagged again since it will block any future `pos_sales.customer_id` FK until resolved.
5. **Van Sales does *not* use real FK constraints** — checked `database/van_sales_schema.sql` and all `database/van_sales_migration_*.sql`: zero `FOREIGN KEY`/`REFERENCES` statements. Van Sales relies entirely on application-layer `company_id`/`salesman_id` filtering, consistent with the rest of the schema's convention. **This means adding real FKs on `pos_*` tables (per your Phase 1 decision) is a deliberate improvement over the Van Sales precedent, not a continuation of it** — flagging this explicitly as something to confirm you still want (see §7, decision D1).
6. **Van Sales schema style** (the style to mirror): `CREATE TABLE IF NOT EXISTS`, `id INT AUTO_INCREMENT PRIMARY KEY`, `company_id INT NOT NULL` (Van Sales defaults this to `1`, which I'm **not** carrying over — a default tenant value is a footgun; POS tables will make `company_id` required with no default), `ENUM` for status columns, `created_at`/`updated_at` `DATETIME DEFAULT CURRENT_TIMESTAMP` (+ `ON UPDATE CURRENT_TIMESTAMP` on `updated_at`), composite `UNIQUE KEY (company_id, <code>)`, `ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci`.
7. **Route mount precedent confirmed** — `server.js` line 22: `const vanSalesRoutes = require("./Routes/vanSalesRoutes"); // VAN SALES MODULE (isolated)`, line 110: `app.use(vanSalesRoutes); // VAN SALES MODULE (isolated — /van-sales/* and /api/van-sales/*)`. This is the **entire** integration footprint Van Sales has in `server.js` — 2 lines, both comment-tagged. See §6 for why POS needs the identical treatment and why that requires your explicit approval per the brief's own rules.
8. **Middleware directory is flat** — only 4 files (`authMiddleware.js`, `authWebOrApi.js`, `setTimezone.js`, `tenantMiddleware.js`), no subfolders. No `middleware/VanSales/` exists. This changes the proposed structure in §2 (flat files, not a `middleware/POS/` subfolder) to match actual convention.
9. **Best existing auth pattern**: `middleware/authWebOrApi.js` — verifies a Bearer JWT against `process.env.API_JWT_SECRET`, attaches `req.company_id`/`req.client_id` from verified token claims (never from client input). Paired with an `api_clients` table (`id, company_id, client_id, client_secret_hash, is_enabled, created_at, updated_at`). **This is the pattern POS's own device auth will mirror** — client_id/secret-hash issuance, server-derived scope — using POS's own secret and POS's own device table, not reusing `API_JWT_SECRET` or `api_clients` itself.
10. **Important new finding — credential storage is plaintext, not hashed**: read `Controllers/loginAPI.js` lines 30–70. `bcrypt.compare` is commented out; the actual check is `if (password === result[i].password)` — a **plaintext password comparison** against `admin_info`/`salesmans` records. This is a pre-existing buskit-web security defect (not introduced or fixed by this work, and out of scope to fix per your rules), but it directly affects POS's design: **POS must not authenticate cashiers by reading and comparing against `salesmans.password`**, because that field is plaintext and reusing it would inherit the same weakness into POS. See §5 for the alternative (a new, POS-owned, properly-hashed credential table).
11. **Node version confirmed**: `v26.8.2` (via `node -v`). This is well past Node's built-in test runner (`node:test`, stable since Node 18/20) — meaning **POS tests can be written using Node's built-in `assert` + `node:test` modules with zero new dependencies**, avoiding any need to touch `package.json` at all (no `jest`/`mocha`/`supertest` addition required). This removes what would otherwise be a second required touch to an existing file.
12. **Response envelope convention confirmed**: every controller sampled uses `{ status_code, status: true|false, message, data? }` with no shared helper function — it's repeated inline everywhere. POS will use the same envelope shape for consistency with the rest of the API surface, via a small POS-local helper (new file, doesn't touch existing code).

---

## 2. Proposed directory structure (adapted to actual conventions)

The brief's suggested structure (§5) used `Services/`, `Repositories/`, `Validation/`, `Middleware/POS/`, `Database/POS/migrations/` — capitalized folders that **don't match** buskit-web's real, observed conventions. Adapted structure below, with reasoning per deviation:

```text
Routes/
  posRoutes.js                        # matches: single file per module (vanSalesRoutes.js precedent)

Controllers/
  POS/
    PosStoreController.js             # matches: Controllers/VanSales/ (capitalized parent + PascalCase module folder)
    PosRegisterController.js
    PosDeviceController.js
    PosShiftController.js
    PosStaffAuthController.js         # new: staff PIN login (see §5)

services/
  pos/
    posStoreService.js                # lowercase "services/pos/": services/ subfolders are all lowercase
    posRegisterService.js             # third-party names (myob/, xero/, businesscentral/) — no capitalized
    posDeviceService.js               # precedent exists for services/, so "pos" here matches sibling case
    posShiftService.js
    posStaffAuthService.js

repositories/
  pos/
    posStoreRepository.js             # NEW CONCEPT — buskit-web has no repository layer anywhere;
    posRegisterRepository.js          # introduced here specifically to avoid the inline-SQL-in-controllers
    posDeviceRepository.js            # anti-pattern this codebase otherwise has everywhere (Phase 1 §16
    posShiftRepository.js             # recommendation). Confirm you want this extra layer (see §7, D2) —
    posStaffAuthRepository.js         # the alternative is to fold parameterized queries into services/pos/
                                       # directly, matching buskit-web's existing (flatter) convention.

validation/
  pos/
    posStoreValidation.js             # NEW CONCEPT — no dedicated validation layer exists in buskit-web
    posRegisterValidation.js          # (the `validator` package is a dependency but used ad hoc inline).
    posDeviceValidation.js            # Uses the already-installed `validator` package — no new dependency.
    posShiftValidation.js

middleware/
  posDeviceAuth.js                    # FLAT, not middleware/POS/ — matches the real middleware/ convention
  posStaffAuth.js                     # (4 existing files, no subfolders observed anywhere in this dir)
  posErrorHandler.js

database/
  pos_schema.sql                      # FLAT, not database/POS/migrations/ — matches the real convention:
  pos_migration_001_staff_pins.sql    # van_sales_schema.sql + van_sales_migration_*.sql both sit directly
                                       # in database/, numbered/named incrementally, no subfolder.

test/
  pos/
    posStore.test.js                  # NEW — no real test convention exists to match (test_folder/ is
    posRegister.test.js               # stale scratch, not a suite, per Phase 1 §9). Uses Node's built-in
    posDevice.test.js                 # node:test + assert — zero new dependencies, so package.json is
    posShift.test.js                  # never touched (see §1.11).
    posAuth.test.js
```

**Files/dirs that do NOT yet exist and would be newly created** (nothing created yet — this is the full list for approval): every path above. Confirmed via grep (§1.3) that none collide with anything existing.

---

## 3. The two things that touch an existing file — flagged per the brief's own STOP rule

The brief says: *"If route registration requires modifying an existing file, STOP and report the issue... request approval."* Two such points were found. Both are the **minimum possible touch**, both are additive-only (no existing line changed or removed), and both mirror an existing, already-accepted precedent exactly:

### 3a. Mounting `posRoutes.js` requires 2 new lines in `server.js`

There is no mechanism in Express to register a new route file without the entry point executing a `require` + `app.use()` for it. The Van Sales module required exactly the same thing. Proposed change (additive only, placed adjacent to the existing Van Sales lines for consistency):

```js
// after line 22:
const posRoutes = require("./Routes/posRoutes"); // POS MODULE (isolated)

// after line 110:
app.use(posRoutes); // POS MODULE (isolated — /api/v1/pos/*)
```

No existing line is edited, removed, or reordered. **Requesting explicit approval to make this 2-line addition** — nothing else in `server.js` would be touched.

### 3b. Nothing else touches an existing file

Testing avoids touching `package.json` (§1.11). No existing `.env` key is read or required to change — POS's own JWT secret (`POS_JWT_SECRET`) would be a **new** environment variable your deploy process adds when ready; it is not required to exist for this document to be approved, only before the auth middleware is first run. (Flagging this as a pre-deployment action item, not a code change request.)

---

## 4. Proposed database migration (complete SQL, not yet executed)

All tables: `ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci`, `CREATE TABLE IF NOT EXISTS` (matching Van Sales' idempotency guard), real FK constraints to `company`/`salesmans` (per your Phase 1 decision — see §7 D1 to reconsider), `company_id` kept as a plain redundant column on every table with no default (defense-in-depth tenant filtering, matching the rest of the schema's convention, minus Van Sales' risky `DEFAULT 1`).

```sql
-- =====================================================================
-- POS MODULE — Phase 2 Foundation Schema
-- Lives inside the existing `busskit_new` database (developer decision).
-- =====================================================================

CREATE TABLE IF NOT EXISTS `pos_stores` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `company_id` INT NOT NULL,
  `store_code` VARCHAR(50) NOT NULL,
  `store_name` VARCHAR(150) NOT NULL,
  `address` VARCHAR(255) DEFAULT NULL,
  `town` VARCHAR(99) DEFAULT NULL,
  `state` VARCHAR(99) DEFAULT NULL,
  `zip` VARCHAR(10) DEFAULT NULL,
  `country` VARCHAR(99) DEFAULT NULL,
  `timezone` VARCHAR(50) NOT NULL DEFAULT 'UTC',
  `currency` VARCHAR(10) NOT NULL DEFAULT 'AUD',
  `status` ENUM('active','inactive') NOT NULL DEFAULT 'active',
  `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pos_stores_company_code` (`company_id`,`store_code`),
  KEY `idx_pos_stores_company` (`company_id`),
  CONSTRAINT `fk_pos_stores_company` FOREIGN KEY (`company_id`) REFERENCES `company` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS `pos_registers` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `company_id` INT NOT NULL,
  `store_id` INT NOT NULL,
  `register_code` VARCHAR(50) NOT NULL,
  `register_name` VARCHAR(150) NOT NULL,
  `status` ENUM('active','inactive') NOT NULL DEFAULT 'active',
  `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pos_registers_store_code` (`store_id`,`register_code`),
  KEY `idx_pos_registers_company` (`company_id`),
  CONSTRAINT `fk_pos_registers_store` FOREIGN KEY (`store_id`) REFERENCES `pos_stores` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_registers_company` FOREIGN KEY (`company_id`) REFERENCES `company` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS `pos_devices` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `company_id` INT NOT NULL,
  `store_id` INT NOT NULL,
  `register_id` INT DEFAULT NULL,
  `device_identifier` VARCHAR(100) NOT NULL,
  `device_name` VARCHAR(150) DEFAULT NULL,
  `platform` VARCHAR(50) DEFAULT NULL,
  `device_secret_hash` VARCHAR(255) NOT NULL,
  `status` ENUM('active','inactive','revoked') NOT NULL DEFAULT 'active',
  `last_seen_at` DATETIME DEFAULT NULL,
  `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pos_devices_identifier` (`device_identifier`),
  KEY `idx_pos_devices_store` (`store_id`),
  KEY `idx_pos_devices_register` (`register_id`),
  CONSTRAINT `fk_pos_devices_store` FOREIGN KEY (`store_id`) REFERENCES `pos_stores` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_devices_register` FOREIGN KEY (`register_id`) REFERENCES `pos_registers` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_devices_company` FOREIGN KEY (`company_id`) REFERENCES `company` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- NEW, beyond the brief's original list — see §5 for why this is needed.
CREATE TABLE IF NOT EXISTS `pos_staff_pins` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `company_id` INT NOT NULL,
  `salesman_id` VARCHAR(70) NOT NULL,
  `pin_hash` VARCHAR(255) NOT NULL,
  `status` ENUM('active','inactive') NOT NULL DEFAULT 'active',
  `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pos_staff_pins_salesman` (`salesman_id`),
  KEY `idx_pos_staff_pins_company` (`company_id`),
  CONSTRAINT `fk_pos_staff_pins_salesman` FOREIGN KEY (`salesman_id`) REFERENCES `salesmans` (`salesman_id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_staff_pins_company` FOREIGN KEY (`company_id`) REFERENCES `company` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS `pos_shifts` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `company_id` INT NOT NULL,
  `store_id` INT NOT NULL,
  `register_id` INT NOT NULL,
  `device_id` INT DEFAULT NULL,
  `salesman_id` VARCHAR(70) NOT NULL,
  `opening_amount` DECIMAL(12,2) NOT NULL DEFAULT 0.00,
  `closing_amount` DECIMAL(12,2) DEFAULT NULL,
  `status` ENUM('open','closed') NOT NULL DEFAULT 'open',
  -- generated column trick: MySQL has no partial/filtered unique index, so a plain
  -- UNIQUE(register_id, status) would also block multiple *closed* shift rows on the
  -- same register (wrong — history must accumulate). This virtual column is NULL for
  -- every closed row (NULLs never collide in a MySQL unique index) and equals
  -- register_id only while a shift is open, so at most one OPEN row per register is
  -- enforced at the database level, while closed history accumulates freely.
  `open_lock` INT GENERATED ALWAYS AS (IF(`status` = 'open', `register_id`, NULL)) VIRTUAL,
  `opened_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `closed_at` DATETIME DEFAULT NULL,
  `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_pos_shifts_one_open_per_register` (`open_lock`),
  KEY `idx_pos_shifts_company` (`company_id`),
  KEY `idx_pos_shifts_salesman` (`salesman_id`),
  CONSTRAINT `fk_pos_shifts_store` FOREIGN KEY (`store_id`) REFERENCES `pos_stores` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_shifts_register` FOREIGN KEY (`register_id`) REFERENCES `pos_registers` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_shifts_device` FOREIGN KEY (`device_id`) REFERENCES `pos_devices` (`id`) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_shifts_salesman` FOREIGN KEY (`salesman_id`) REFERENCES `salesmans` (`salesman_id`) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT `fk_pos_shifts_company` FOREIGN KEY (`company_id`) REFERENCES `company` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
```

**Tables to be created**: `pos_stores`, `pos_registers`, `pos_devices`, `pos_staff_pins`, `pos_shifts` (5 tables — 1 more than the brief's original 4, see §5).
**Foreign keys**: 11 total, all POS-table-to-POS-table or POS-table-to-(`company`/`salesmans`), none modify or add to any existing table's definition.
**Indexes**: 1 unique key per table for natural-key dedup (store code per company, register code per store, device identifier globally, one staff PIN per salesman, one open shift per register via the generated-column trick) + plain indexes on every FK column and `company_id`.
**No existing table's DDL is touched.**

---

## 5. Why a 5th table (`pos_staff_pins`) beyond the brief's list

The brief's §14 shift requirements say *"Only authorized cashiers can open shifts"* and §9 says *"Verify credentials before granting access... Never rely only on a request-body company_id."* Satisfying that requires *some* credential to check. The two options:

- **(Rejected) Read and compare against `salesmans.password`**: confirmed plaintext (§1.10) — reusing it would mean POS inherits a live, known-bad practice into brand-new code, and would require the POS layer to see raw plaintext passwords for existing accounts (a bigger exposure surface than necessary).
- **(Proposed) `pos_staff_pins`**: a new, POS-owned table storing a bcrypt-hashed PIN per `salesman_id` (bcrypt is already a `buskit-web` dependency — `package.json` — just not currently wired up correctly for login, per §1.10; POS will use it correctly). An admin/manager enrolls a cashier once (sets a PIN via a POS admin endpoint, not built in this phase — see §9 "not implemented"); at shift-open, the cashier enters `salesman_id` (or scans a badge) + PIN, POS verifies the hash, and issues a short-lived POS-scoped JWT with `company_id`/`salesman_id`/`store_id`/`register_id` embedded server-side.

This keeps identity tied to the real `salesmans` record (so reporting/audit can say "cashier X, who is salesman Y in the core system, opened this shift") without touching or trusting the insecure existing password field. **Flagging for your approval** — the alternative is to accept the plaintext-comparison risk and reuse `salesmans.password` directly, which is not recommended.

---

## 6. Proposed API surface (`/api/v1/pos/...`)

| Method | Path | Auth required | Notes |
|---|---|---|---|
| `POST` | `/api/v1/pos/auth/device-login` | device `device_identifier` + secret | Issues a device-scoped POS JWT (`company_id`, `store_id`, `register_id` embedded) |
| `POST` | `/api/v1/pos/auth/staff-login` | `salesman_id` + PIN | Issues a staff-scoped POS JWT (`company_id`, `salesman_id`) — requires device JWT already present |
| `GET` | `/api/v1/pos/stores` | device or staff JWT | Lists stores for the authenticated `company_id` only (never a query param) |
| `POST` | `/api/v1/pos/stores` | staff JWT (admin-level — see §9 limitation) | Create store |
| `GET` | `/api/v1/pos/stores/:id` | JWT + store-ownership check | View store; 403 if store's `company_id` ≠ token's `company_id` |
| `PATCH` | `/api/v1/pos/stores/:id` | staff JWT, admin-level | Update POS-specific store fields only |
| `GET` | `/api/v1/pos/stores/:id/registers` | JWT + store-ownership check | List registers for a store |
| `POST` | `/api/v1/pos/registers` | staff JWT, admin-level | Create register (`store_id` must belong to token's `company_id`) |
| `GET` | `/api/v1/pos/registers/:id` | JWT + register-ownership check | View register |
| `PATCH` | `/api/v1/pos/registers/:id/status` | staff JWT, admin-level | Enable/disable |
| `POST` | `/api/v1/pos/devices` | staff JWT, admin-level | Register a device, returns the one-time plaintext secret (never stored/logged) |
| `GET` | `/api/v1/pos/devices` | JWT + store-ownership check | List devices for a store |
| `PATCH` | `/api/v1/pos/devices/:id/status` | staff JWT, admin-level | Enable/disable/revoke |
| `POST` | `/api/v1/pos/shifts/open` | device JWT + staff PIN in body | Opens a shift; rejects if register already has an open shift (§4 `open_lock`) |
| `POST` | `/api/v1/pos/shifts/:id/close` | staff JWT (must be the same salesman who opened it, or admin override) | Closes a shift, records `closing_amount` |
| `GET` | `/api/v1/pos/shifts/:id` | JWT + shift-ownership check | View shift summary |

Every read endpoint filters by `req.pos.company_id` (from the verified JWT — see §7 middleware), **never** by a client-supplied `company_id`/`store_id` in the query/body, per the brief's §9 requirement.

---

## 7. Auth/authorization design

- **`middleware/posDeviceAuth.js`**: verifies `Authorization: Bearer <deviceToken>` against a **new**, POS-specific secret (`process.env.POS_JWT_SECRET` — new env var, see §3b), modeled directly on `authWebOrApi.js` (§1.9). On success, attaches `req.pos = { company_id, store_id, register_id, authType: 'device' }`.
- **`middleware/posStaffAuth.js`**: same pattern for the staff-scoped token issued after PIN verification; attaches `salesman_id`/`shift_id` in addition to the above.
- **Ownership checks**: a small shared helper (inside `services/pos/`) that, for any `:id` path param, loads the row and compares its `company_id`/`store_id` chain against `req.pos` before allowing the request to proceed — returns 403 on mismatch, never a raw 404 that would leak existence across tenants vs. genuinely-not-found (both return 404, per standard practice, to avoid enumeration — worth confirming you're OK with this choice).
- **"Admin-level" actions** (create store/register/device): Phase 2 will check `req.pos.authType === 'staff'` and (for now) any authenticated staff member — a proper role/permission check (mirroring or replacing buskit-web's `user_roles` menu-permission model) is **out of scope for Phase 2** per the brief ("do not implement... offline sync... inventory deduction" — role management wasn't listed as in-scope either) and is flagged as a known limitation (§9).
- **What is explicitly not built in Phase 2**: the PIN-enrollment endpoint (how a `pos_staff_pins` row first gets created) is deliberately left out — bootstrapping the very first staff PIN needs a decision (does an existing `admin_info` session do it via a thin bridge endpoint, or is there a separate one-time CLI/seed script?). Flagging as an open question (§8, Q3).

---

## 8. Validation, error handling, logging

- Validation files in `validation/pos/` export plain functions (e.g. `validatePosStoreCreate(body)`) using the existing `validator` package (already a dependency — no new package). Each returns `{ valid: boolean, errors: string[] }`; controllers call it first and short-circuit with `422` on failure.
- Response envelope matches the existing convention exactly: `{ status_code, status: true|false, message, data? }` (§1.12) — via one small shared helper local to POS (`services/pos/posResponse.js`), not a change to any existing file.
- Error handling: `middleware/posErrorHandler.js`, mounted only on the POS router (`Routes/posRoutes.js` uses `router.use(posErrorHandler)` as its last middleware) — catches thrown errors, logs the real error server-side (`console.error`, matching existing style), returns a generic `{ status_code: 500, status: false, message: "Internal server error" }` to the client with no stack trace, no SQL text, no secrets. This is scoped to the POS router only — the existing app's global error handler in `server.js` is untouched.
- All SQL in `repositories/pos/*.js` (or `services/pos/*.js` if you choose the flatter option per §7 D2) uses parameterized queries exclusively (`mysql2`'s `?` placeholders via the same `getQueryPromise()` helper already exported from `config/db.js` — read-only reuse of an existing utility function, not a modification to it).

---

## 9. Test plan (descriptions — code not yet written, per STOP condition)

Using Node's built-in `node:test` + `assert` (§1.11 — zero new dependencies):

**Security**
- Request with no `Authorization` header → 401.
- Request with an expired/invalid/malformed JWT → 401.
- Valid staff JWT for company A used against a store belonging to company B → 403.
- Valid JWT for store A used against a register belonging to store B (same company) → 403.
- Attempted `company_id`/`store_id` override via request body/query while a valid JWT is present → body/query value is ignored; the JWT's value is what's used (test asserts the DB row created belongs to the JWT's company, not the body's).

**Stores**: create with valid data → 201 + row persisted; missing `store_name` → 422; duplicate `store_code` within same company → 409; same `store_code` across two different companies → both succeed (proves the unique key is correctly scoped to `company_id`).

**Registers**: create under an owned store → 201; create under a store belonging to a different company → 403; duplicate `register_code` within same store → 409.

**Devices**: register with valid data → 201, response includes the one-time plaintext secret exactly once; duplicate `device_identifier` → 409; disable a device → subsequent device-login with that identifier → 401.

**Shifts**: open on a register with no active shift → 201; open a second shift on the same register while one is already open → 409 (proves the `open_lock` generated-column constraint, §4); close by a different salesman than who opened it (non-admin) → 403; close an already-closed shift → 409 (invalid status transition); closing records `closing_amount` and `closed_at`.

Each test file spins up against a disposable test schema (or a transaction rolled back after each test) — **exact test-DB strategy needs your input**, since buskit-web has no existing test-database convention to follow (Phase 1 §9) — see §10, open question.

---

## 10. Decisions needed before implementation begins

1. **D1 — Real FKs vs. Van Sales' no-FK precedent (§1.5)**: proceed with real FK constraints on `pos_*` tables as designed in §4 (recommended — matches your Phase 1 decision and is safer), or drop them to match Van Sales' looser, app-layer-only convention?
2. **D2 — Repository layer (§2)**: keep the extra `repositories/pos/` layer (cleaner, but a new concept for this codebase), or fold parameterized queries directly into `services/pos/*.js` (matches buskit-web's flatter existing style more closely)?
3. **D3 — `pos_staff_pins` (§5)**: approve adding this table beyond the original 4, given the plaintext-password finding — or do you want POS to reuse `salesmans.password` directly despite that risk?
4. **Q1 — server.js 2-line mount (§3a)**: approved to add, exactly as shown?
5. **Q2 — `POS_JWT_SECRET`**: confirm this will be added to `.env`/`.env_production` as a new key before the auth middleware is first exercised (not required for this document's approval, just a pre-req to note).
6. **Q3 — PIN enrollment bootstrap (§7)**: how does the very first `pos_staff_pins` row get created — a thin bridge endpoint gated by an existing `admin_info` session check (touches nothing existing, just reads the session), or a one-time seed script (mirroring `seed_van_sales.js`)?
7. **Q4 — Test database strategy (§9)**: run POS tests against a disposable schema/dump, or wrap each test in a transaction that's rolled back on a copy of `busskit_new`? Either way, tests must **never** run against a production database — need your input on what test DB actually exists/can be created in this environment.
8. **Q5 — Ownership-check 404-vs-403 behavior (§7)**: confirmed OK to return `404` (not `403`) for cross-tenant access attempts on `:id` routes, to avoid confirming a resource's existence to an unauthorized caller? (Standard practice; flagging since the brief's own test list (§9, brief) explicitly expects `403` for cross-company/cross-store access — worth reconciling before writing tests.)

---

## 11. Mandatory final verification (per brief §17)

- No existing source file in `/Users/aneesh/buskit-web` was edited, deleted, or renamed this session — confirmed (only `Read`/read-only `Bash` commands were run: `cat`, `grep`, `sed -n`, `awk`, `ls`, `node -v`).
- No existing database table was modified, no existing record changed, no destructive or write SQL was executed — confirmed (no `mysql`/DB-client command was run at all; all schema facts came from reading `busskit_new.sql` on disk).
- No existing API, authentication code, or migration file was changed — confirmed.
- No file was created inside `/Users/aneesh/buskit-web` — confirmed; the only file written this session is this document, inside `/Users/aneesh/buskit-pos/docs/`.
- No migration was executed — confirmed, §4's SQL is proposed text only.
- No billing, payment, or inventory-deduction functionality was designed or implemented — confirmed, out of scope per the brief.

**STOP CONDITION met.** Waiting for your decisions on §10 before any file is created inside `buskit-web` or any migration is run.
