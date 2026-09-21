# Phase 3.1 — POS Authentication Hardening: Completion Report

Closes the gap you identified: `posDeviceAuth` verified JWT signatures but never checked that the claimed device/staff record still existed or was still active. Fixed, tested, and regression-checked against all prior phases.

## 1. The gap and the fix

**Before**: a validly-signed device or staff JWT was accepted forever (until expiry), even if the underlying `pos_devices` row was deleted, deactivated, or revoked, or the underlying `pos_staff_pins`/`salesmans` record was deactivated after the token was issued. JWT signature validity was being treated as authorization.

**After**: `middleware/posDeviceAuth.js` now does a live database check on every single authenticated request:
1. Rejects any token missing a `device_id` claim outright (every legitimate token from `deviceLogin`/`staffLogin` always carries one — a token without it can only be forged).
2. Looks up the real `pos_devices` row by that id; rejects if it doesn't exist, isn't `status = 'active'`, or its `company_id` doesn't match the token's claim.
3. **Refreshes `store_id`/`register_id` from the live device row**, not the token's cached copy — so reassigning a device to a different store/register takes effect immediately, without waiting for re-login.
4. For staff-scoped tokens: looks up `pos_staff_pins`, rejects if missing/inactive/cross-company, rejects with `423` if currently locked out, and separately checks the underlying `salesmans.status` (verified `= 0` is active, the same inverted convention as `categories`).

`services/pos/posStaffAuthService.js::staffLogin` also now enforces the same checks at login time (so a revoked/locked account can't even get a fresh token), plus new PIN lockout: 5 failed attempts locks the account for 15 minutes, tracked in two new columns.

## 2. Schema change (POS-owned table only)

```sql
ALTER TABLE pos_staff_pins
  ADD COLUMN failed_attempts INT NOT NULL DEFAULT 0 AFTER pin_hash,
  ADD COLUMN locked_until DATETIME NULL DEFAULT NULL AFTER failed_attempts;
```
Run against `busskit_new`, exit 0. `pos_staff_pins` had 0 rows at the time (verified before running) — zero data risk. No other table touched.

## 3. A real bug found and fixed during testing

While testing the lockout logic, discovered the lockout SQL had an **off-by-one**: MySQL evaluates a multi-column `UPDATE`'s assignments left-to-right, so `locked_until = IF(failed_attempts + 1 >= ?, ...)` was reading `failed_attempts` *after* the preceding `failed_attempts = failed_attempts + 1` assignment had already applied — double-counting the increment and locking the account after only 4 failures instead of 5. Caught via an isolated diagnostic (logged `failed_attempts`/`locked_until` after each of 6 sequential failures), fixed by removing the redundant `+ 1`, and re-verified to lock exactly on the 5th failure.

## 4. Files touched

**New**: `database/pos_migration_002_staff_pin_lockout.sql`.
**Modified** (all POS-owned files created in earlier phases, not pre-existing buskit-web files): `middleware/posDeviceAuth.js` (live device/staff re-validation), `repositories/pos/posStaffAuthRepository.js` (lockout functions + `isSalesmanActive`), `services/pos/posStaffAuthService.js` (lockout enforcement + salesman-status check at login).
**Untouched**: `middleware/posStaffAuth.js` (still just the `authType === 'staff'` gate — the deeper checks now live in `posDeviceAuth`, which runs first on every route). `server.js` unchanged since Phase 2 (still exactly the same 2-line diff).

## 5. Test results

**New Phase 3.1 suite — 13/13 passed**:
```
PASS - token with no device_id claim at all -> 401
PASS - device_id pointing at a nonexistent (deleted) device -> 401
PASS - inactive device is rejected
PASS - revoked device is rejected
PASS - a device that starts active can be revoked mid-session and the SAME already-issued token stops working
PASS - device row belongs to a DIFFERENT company than the token claims -> 401 (forged company_id)
PASS - device reassigned to a different store: live scope is used, not the token's stale cached store_id
PASS - expired token is rejected even with a valid device
PASS - staff-login with an INACTIVE pos_staff_pins row -> 401
PASS - PIN lockout: 5 failed attempts locks the account, 6th attempt (even eventually with the right PIN) is 423
PASS - successful login resets the failed-attempts counter
PASS - an already-issued staff token stops working once its PIN record is locked mid-session
PASS - deactivated salesman (salesmans.status != 0) cannot log in even with a correct, active PIN
```
The "revoked mid-session" and "locked mid-session" tests are the most important ones functionally: they issue a token, confirm it works, mutate the underlying row directly (bypassing the API), and confirm the **exact same already-issued token** stops working on the very next request — proving this isn't just login-time validation.

**Full regression across all prior phases — 65/65 passed** (26 Phase 2 + 7 Phase 2.1 + 19 Phase 3 + 13 Phase 3.1). Two Phase 2 test assertions needed updating: two tests that forged a cross-company token (without a `device_id` claim) originally expected `403` from the ownership-check business logic; they now correctly get `401` from the auth layer instead, since the hardening rejects such tokens before ownership logic ever runs — a strictly earlier and stronger rejection, not a regression. Phase 3's tests needed a real device fixture (store+register+device) per test company instead of a bare token, since that's now required for any request to succeed at all — this is precisely the intended effect of the hardening.

All `pos_*` tables confirmed empty after the full run (fixtures fully cleaned up in every suite).

## 6. What "PIN lockout rules" means concretely

5 failed PIN attempts → account locked for 15 minutes (both hardcoded constants in `posStaffAuthService.js`, easy to tune later). Lockout is enforced both at login (`staffLogin` checks `locked_until` before even attempting the bcrypt compare) and per-request (`posDeviceAuth` re-checks it on every subsequent request using an already-issued staff token, so a token obtained just before lockout stops working immediately, not just future login attempts).

## 7. FIFO transaction technical debt — status unchanged

Per your note, this stays documented-but-untouched (see Phase 3's report/plan) and is not part of this phase. Not modified again here.

## 8. Remaining scope notes

- Device secret rotation / re-issuance endpoint doesn't exist yet (only create + status update) — not requested, noted for a future phase if needed.
- Lockout constants (5 attempts / 15 minutes) are hardcoded, not per-company configurable — flag if that's wanted later.
- `test/pos/` (a real committed suite) is still deferred, consistent with all prior phases.

No existing buskit-web table, column, index, or source file was modified. No route beyond the already-approved `server.js` 2-line mount exists. The only schema change this phase (`pos_staff_pins` + 2 columns) is to a table POS created and owns.
