# Phase 3.1 Migration Review (pre-Phase 4)

All 5 checklist items verified — 2 were fine as-is, 2 needed real fixes, 1 was a judgment call flagged rather than changed. Full regression after fixes: **65/65 passed** (unchanged suite counts from Phase 3.1) plus a new dedicated rate-limit check.

## 1. Migration repeatable and safely documented — fixed

Was **not** idempotent: plain `ALTER TABLE ... ADD COLUMN` fails with "Duplicate column name" on a second run. Confirmed MariaDB 10.4 (this server) supports `ADD COLUMN IF NOT EXISTS` empirically (ran it twice against `pos_staff_pins`, both exits clean) and updated `database/pos_migration_002_staff_pin_lockout.sql` to use it, matching the `van_sales_migration_*.sql` idempotency convention. Documentation header expanded to explain both the idempotency and the timezone decision below.

## 2. Lockout timestamps use the correct server timezone — real bug found and fixed

They did **not**, though it happened to work by coincidence in this dev environment. `locked_until` was set via `DATE_ADD(NOW(), ...)` (MySQL server's session timezone — confirmed `SYSTEM`/IST here) and compared in JavaScript via `new Date(pinRecord.locked_until) > new Date()`. Since `config/db.js` sets `dateStrings: true`, MySQL DATETIME values come back as plain strings with no timezone marker; `new Date("2026-09-18 17:31:08")` is parsed by Node as **local time of the Node process** — which only matches here because this dev machine and the DB server both default to the same system timezone (IST). In a real deployment where the app server and DB server have different system timezones, this comparison would silently be wrong.

**Fixed** by moving the entire comparison into SQL: `registerFailedAttempt` now stores `DATE_ADD(UTC_TIMESTAMP(), INTERVAL ? MINUTE)` instead of `NOW()`, and `findPinBySalesmanId` returns a computed `is_locked` boolean (`locked_until IS NOT NULL AND locked_until > UTC_TIMESTAMP()`) that both `posStaffAuthService.js` and `posDeviceAuth.js` now use directly — no JS-side date parsing or comparison remains anywhere in the lockout path.

## 3. Failed-attempt counters reset after successful authentication — confirmed, already correct

Already verified by the existing Phase 3.1 test ("successful login resets the failed-attempts counter") and re-confirmed after this round's changes — `resetFailedAttempts()` is called on every successful `bcrypt.compare` match, setting `failed_attempts = 0, locked_until = NULL`.

## 4. Lockout responses do not reveal unnecessary account information — reviewed, flagged as a judgment call (not changed)

Current responses (`423 "Staff account is temporarily locked..."`) reveal no name, no exact unlock time, no attempt count, and no salesman identity beyond what the caller already supplied. The one real tradeoff: returning a distinct `423` for "locked" versus a generic `401` for "wrong PIN"/"doesn't exist" lets an attacker infer that a given `salesman_id` **exists** (locked implies a real, actively-tried account), a minor enumeration signal. For an internal, device-authenticated POS system (not a public consumer login), I judged this an acceptable, arguably desirable tradeoff — a legitimate cashier locked out needs to know *why* they can't log in, rather than getting the same opaque "wrong PIN" message. **Flagging rather than changing** — say the word if you'd rather lockout be indistinguishable from a wrong PIN (same 401, same message) for stronger enumeration resistance.

## 5. PIN attempts are rate-limited appropriately — gap found and closed

The per-salesman lockout (5 attempts/15 min, on `pos_staff_pins`) only throttles guesses against **one** `salesman_id`. It does nothing to slow an attacker who has a valid device token and cycles through many different `salesman_id`s rapidly — each one gets its own fresh 5-attempt budget. Added `middleware/posRateLimit.js`, a small in-memory sliding-window limiter (same known limitation as buskit-web's own existing `authMiddleware.js::blockAfterLimit` — per-process, resets on restart, not shared across multiple app instances; flag if a shared store like Redis is wanted later), applied to both auth endpoints:
- `/auth/device-login`: 20 attempts / 5 minutes, keyed by IP.
- `/auth/staff-login`: 20 attempts / 5 minutes, keyed by the **authenticated device_id** (available since `posDeviceAuth` runs first) — independent of which `salesman_id` is being tried.

Verified with a live test: 25 rapid staff-login attempts against a real device → the first 20 return `401` (wrong PIN), the remaining 5 return `429`.

## Files touched this round

All POS-owned, none pre-existing buskit-web files: `database/pos_migration_002_staff_pin_lockout.sql` (rewritten, idempotent), `repositories/pos/posStaffAuthRepository.js` (UTC timestamps + `is_locked` computed field), `services/pos/posStaffAuthService.js` (uses `is_locked`), `middleware/posDeviceAuth.js` (uses `is_locked`), `middleware/posRateLimit.js` (new), `Routes/posRoutes.js` (2 new limiter registrations). No existing buskit-web table, column, or source file touched. `server.js` unchanged.

## Regression

All four existing suites re-run after every change in this pass: Phase 2 (26/26), Phase 2.1 (7/7), Phase 3 (19/19, read-only check passed), Phase 3.1 (13/13) — **65/65**, plus the new rate-limit verification above.
