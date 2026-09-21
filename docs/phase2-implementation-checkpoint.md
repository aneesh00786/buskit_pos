# Phase 2 — Implementation Checkpoint (approval gate)

Approved decisions from the previous round are recorded and applied below. Two items had no explicit decision yet — I picked the recommended default for each and flagged it; say the word if you want the other option before I proceed:

- **Repository layer** (kept `repositories/pos/` as its own layer, per Phase 1's recommendation to avoid inline SQL in controllers) — the alternative was folding queries directly into `services/pos/`.
- **PIN enrollment bootstrap** (a one-time seed script, `database/pos_seed_staff_pin.js`, mirroring `seed_van_sales.js` — run manually per environment to set a cashier's first PIN) — an admin API endpoint for this is deferred to a later phase once POS role/permission checks exist.
- **Cross-tenant ownership-check status code**: using `403` (not `404`) for cross-company/store/register access, matching the brief's own test list.

Nothing has been created or executed yet. This document is the last thing before the approval checkpoint (Implementation Order step 7).

---

## 1. Final new-file structure

```text
Routes/
  posRoutes.js

Controllers/POS/
  PosStoreController.js
  PosRegisterController.js
  PosDeviceController.js
  PosShiftController.js
  PosStaffAuthController.js

services/pos/
  posStoreService.js
  posRegisterService.js
  posDeviceService.js
  posShiftService.js
  posStaffAuthService.js
  posResponse.js          # shared { status_code, status, message, data } envelope helper
  posOwnership.js         # shared company/store/register ownership-check helper

repositories/pos/
  posStoreRepository.js
  posRegisterRepository.js
  posDeviceRepository.js
  posShiftRepository.js
  posStaffAuthRepository.js

validation/pos/
  posStoreValidation.js
  posRegisterValidation.js
  posDeviceValidation.js
  posShiftValidation.js

middleware/
  posDeviceAuth.js
  posStaffAuth.js
  posErrorHandler.js

database/
  pos_schema.sql                      # all 5 CREATE TABLE statements, idempotent (IF NOT EXISTS)
  pos_seed_staff_pin.js                # one-time manual PIN-bootstrap script (Node, uses bcrypt)

```

`test/pos/` is deferred (§6) — not created in this pass. 18 new files, 0 modified files inside `buskit-web`, except the one approved `server.js` addition (§5). Re-confirmed via grep immediately before writing this document: none of these paths exist yet.

---

## 2. Proposed SQL migration (final — real FKs, as approved)

Identical to the SQL in `phase2-pos-foundation-plan.md` §4 — reproduced here as the exact, final version to be run once approved. Saved to `database/pos_schema.sql` when approved.

```sql
-- =====================================================================
-- POS MODULE — Phase 2 Foundation Schema
-- Lives inside the existing `busskit_new` database (developer decision).
-- All statements are idempotent (CREATE TABLE IF NOT EXISTS).
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

**Concurrency note on `open_lock` (Implementation Order item 6 / approved decision 17)**: the generated-column unique index enforces "one open shift per register" atomically at the storage-engine level — a second `INSERT ... status='open'` for the same `register_id` will raise a duplicate-key error (`ER_DUP_ENTRY`) even under concurrent requests, because InnoDB's unique-index check-and-insert is atomic per row, unlike an application-level `SELECT` then `INSERT` (which has a race window). The service layer must catch `ER_DUP_ENTRY` on shift-open and translate it to a `409 Conflict` response rather than a raw `500` — this is called out explicitly so it isn't missed during implementation. Verified this MySQL feature (generated columns + functional uniqueness via `VIRTUAL`) requires **MySQL 5.7.8+ / MariaDB 10.2+**; confirmed compatible since the dump targets MySQL 8 (`utf8mb4_0900_ai_ci` collation appears elsewhere in the schema, e.g. `web_store`, which only exists in MySQL 8/MariaDB 10.3+).

---

## 3. Foreign keys and indexes (complete list)

| Table | Constraint | Column → Reference | On delete |
|---|---|---|---|
| `pos_stores` | `fk_pos_stores_company` | `company_id` → `company.id` | CASCADE |
| `pos_registers` | `fk_pos_registers_store` | `store_id` → `pos_stores.id` | CASCADE |
| `pos_registers` | `fk_pos_registers_company` | `company_id` → `company.id` | CASCADE |
| `pos_devices` | `fk_pos_devices_store` | `store_id` → `pos_stores.id` | CASCADE |
| `pos_devices` | `fk_pos_devices_register` | `register_id` → `pos_registers.id` | SET NULL |
| `pos_devices` | `fk_pos_devices_company` | `company_id` → `company.id` | CASCADE |
| `pos_staff_pins` | `fk_pos_staff_pins_salesman` | `salesman_id` → `salesmans.salesman_id` | CASCADE |
| `pos_staff_pins` | `fk_pos_staff_pins_company` | `company_id` → `company.id` | CASCADE |
| `pos_shifts` | `fk_pos_shifts_store` | `store_id` → `pos_stores.id` | CASCADE |
| `pos_shifts` | `fk_pos_shifts_register` | `register_id` → `pos_registers.id` | CASCADE |
| `pos_shifts` | `fk_pos_shifts_device` | `device_id` → `pos_devices.id` | SET NULL |
| `pos_shifts` | `fk_pos_shifts_salesman` | `salesman_id` → `salesmans.salesman_id` | RESTRICT (can't delete a salesman with shift history) |
| `pos_shifts` | `fk_pos_shifts_company` | `company_id` → `company.id` | CASCADE |

**13 foreign keys total, all outbound from new `pos_*` tables — zero constraints added to any existing table** (confirming approved decisions 3 and 11).

Indexes: 1 `PRIMARY KEY` + 1 natural-key `UNIQUE KEY` per table (`company_id+store_code`, `store_id+register_code`, `device_identifier`, `salesman_id`, `open_lock`) + a plain `KEY` on every foreign-key column and on `company_id` (for tenant-filtered queries that don't join) — 21 indexes total across the 5 tables.

---

## 4. Authentication design (final)

Two token types, both HMAC-signed JWTs using a **new** `POS_JWT_SECRET` env var (not `API_JWT_SECRET` — kept separate so rotating one never affects the other):

1. **Device token** (`POST /api/v1/pos/auth/device-login` — body: `device_identifier` + `device_secret`): `posDeviceAuth` middleware/service looks up `pos_devices` by `device_identifier`, `bcrypt.compare`s the secret against `device_secret_hash`, and on success signs a token with `{ company_id, store_id, register_id, device_id, authType: 'device' }` pulled from the **database row**, never from the request. Rejects if `status != 'active'`.
2. **Staff token** (`POST /api/v1/pos/auth/staff-login` — body: `salesman_id` + `pin`, requires a valid device token already present): looks up `pos_staff_pins` by `salesman_id`, `bcrypt.compare`s the PIN against `pin_hash`, joins to `salesmans` to confirm the row's `company_id` matches the device token's `company_id` (rejects cross-company staff/device pairing), and signs a token with `{ company_id, salesman_id, store_id, register_id, authType: 'staff' }`.

Every subsequent POS request requires the staff token (device token alone is enough only for `/auth/*` and read-only `/stores`, `/registers` listing). `req.pos.company_id`/`store_id`/`register_id`/`salesman_id` are the **only** source of tenant/scope truth in every controller — `posOwnership.js` (in `services/pos/`) re-validates that any `:id` in the URL actually belongs to `req.pos.company_id` (and, where applicable, `store_id`) before the controller's main logic runs, returning `403` on mismatch (approved default, §top of doc).

No part of this reads, verifies, or stores `salesmans.password` or `admin_info.password` (approved decisions 8–9). No part of this modifies `authMiddleware.js`, `authWebOrApi.js`, or `tenantMiddleware.js`.

---

## 5. Exact `server.js` diff

```diff
--- a/server.js
+++ b/server.js
@@ -20,6 +20,7 @@
 const businessCentralRoutes = require("./Routes/businessCentralRoutes");
 const vanSalesRoutes = require("./Routes/vanSalesRoutes"); // VAN SALES MODULE (isolated)
+const posRoutes = require("./Routes/posRoutes"); // POS MODULE (isolated)
 const socketIo = require('socket.io');
 const SocketIOFile = require('socket.io-file');
 const fs = require('fs');
@@ -107,6 +108,7 @@
 app.use("/businesscentral", businessCentralRoutes);
 app.use(vanSalesRoutes); // VAN SALES MODULE (isolated — /van-sales/* and /api/van-sales/*)
+app.use(posRoutes); // POS MODULE (isolated — /api/v1/pos/*)
 startEmailScheduler();
```

Two lines added, zero lines removed or reordered, placed immediately adjacent to the Van Sales lines for readability. This is the only change to any file outside `docs/` this phase will make, and it will not be applied until you approve it at the final checkpoint.

---

## 6. Test-database setup — DEFERRED

**Superseded by the 2026-09-18 final database decision**: no separate test database (`busskit_new_pos_test` or otherwise) will be created automatically. Per that decision (rules 9–10): all 5 `pos_*` tables are created directly inside `busskit_new`, and a separate test database is used only if and when explicitly approved later. `test/pos/` test files are therefore **not part of this implementation pass** — they're deferred to a follow-up step once a test-DB approach is explicitly approved, so they don't block getting the tables and API foundation in place now.

---

## Waiting for approval

Per Implementation Order step 7: **no migration file, no source file, no SQL execution, and no route registration will happen until you explicitly approve** what's shown above (including picking option (a) or (b) in §6, and confirming the two defaulted items at the top of this document).
