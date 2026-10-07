# POS Retail Production Gap Audit

Scope: the retail POS only (scan or search, cart, verify, pay, complete, receipt, stock). B2B orders, restaurant ordering, tables, kitchen and online ordering are out of scope and were not audited.

Method: the code and the local database structure were inspected directly (`DESCRIBE`, index and count queries only). No source, database, configuration or migration was changed, and no test suites were run.

Repos: buskit-pos (Flutter) and buskit-web (`services/pos`, `repositories/pos`, `Controllers/POS`, `Routes/posRoutes.js`, `Routes/adminRoutes.js`).

Statuses: **READY** · **NEEDS HARDENING** · **MISSING - BLOCKER** · **MISSING - RECOMMENDED** · **OPTIONAL**

---

## 1. Core retail checkout

| Area | Current implementation | Evidence | Status | Exact gap | Next phase |
|---|---|---|---|---|---|
| Search, cart, quantity, customer, held/draft | Debounced search, add/update/remove line, PIECE/WEIGHT quantity dialog, guest or customer, hold/resume/cancel/discard | `lib/features/products`, `cart/state/cart_controller.dart`, `held_sales/*`; `POST/PATCH/DELETE /sales*`, `/hold`, `/resume`, `/cancel` | READY | — | — |
| Payment and completion | Cash (tendered and change), card, other, split tender; provider attempts; idempotent completion with live repricing and a lock | `checkout/ui/pay_modal.dart`; `posSaleService.completeDraftInTransaction` | READY | — | — |
| Receipt | PDF / system print / ESC/POS; email or SMS hand-off | `receipt/*`, `ReceiptActions` | NEEDS HARDENING | Printing is manual: the cashier taps "Print Receipt" after every sale, and there is no auto-print setting | 14B (auto-print setting) |
| History, reprint, void, refund | History list and detail, reprint via `ReceiptActions`, void, full and partial refund (PIECE and WEIGHT) | `history/*`, `/sales/:id/void`, `/refund`, `/refunds` | READY | — | — |
| Keyboard operation | Only the scanner's Enter key is handled | No `Shortcuts`/`SingleActivator` usage in `lib` | MISSING - RECOMMENDED | No keys for pay, new sale, quantity or search focus on keyboard tills | 14E |

## 2. Barcode scanner

| Area | Current implementation | Evidence | Status | Exact gap | Next phase |
|---|---|---|---|---|---|
| USB/Bluetooth scanners that act as a keyboard | Global `HardwareKeyboard` listener; a burst (gap ≤ 80 ms, ≥ 4 chars, ending in Enter) counts as a scan; works while the search box has focus and clears the code from it | `barcode/barcode_key_buffer.dart`, `barcode_key_listener.dart`, `products_page.dart:241-247` | READY (software) | Not yet tried with physical scanners (timing differs between models) | Hardware UAT |
| Rapid / duplicate scans | Scans are queued and processed in order; each scan adds one unit (repeat scan = +1, intended) | `barcode_scan_handler.dart` (`_tail` chain) | NEEDS HARDENING | A scan that arrives while another cart change is running returns `busy` ("scan again") and the item is **not added**; the cashier can miss it during a fast run | 14E: queue the scan instead of dropping it |
| Unknown or invalid code | `notFound` / `invalid` message | `ScanOutcome` | READY | — | — |
| WEIGHT products | Scanning a WEIGHT product is refused ("select it and enter the weight") | `barcode_scan_handler.dart:62-67` | READY | — | — |
| Price- or weight-embedded supermarket barcodes (e.g. EAN-13 prefix 2x) | Not supported | No prefix/PLU parsing | MISSING - RECOMMENDED (a BLOCKER only for stores using scale labels) | — | Later phase (needs business rules: prefix, PLU length, price vs weight) |
| Scanner configuration | Gap and minimum length are hard-coded defaults | `BarcodeKeyBuffer(maxGap: 80ms, minLength: 4)` | OPTIONAL | No setting for slow scanners | Later |
| Duplicate barcodes in the catalogue | Lookup uses `LIMIT 1`; 0 duplicate active barcodes in the data today; no unique constraint | `posProductRepository.js:132` | NEEDS HARDENING | A future duplicate barcode would silently pick an arbitrary product | 14B: return a conflict when more than one active row matches |

## 3. Receipt and printer

| Area | Current implementation | Evidence | Status | Exact gap | Next phase |
|---|---|---|---|---|---|
| ESC/POS network printer (port 9100) | `NetworkPrinterAdapter`, 5 s timeout, 58 mm (32 columns) and 80 mm (42 columns), cut, setup dialog | `receipt/printing/*`, `receipt/data/printer_driver.dart` | READY (software) | Physical printer validation pending | Hardware UAT |
| USB / Bluetooth printers | Enum values only; no adapter | `printer_adapter.dart:9` (`usb`, `bluetooth`), only network and mock adapters exist | MISSING - RECOMMENDED | Tills without network printers can only use the system print dialog | 14D (platform-specific) |
| Failure / unavailable | Thermal failure falls back to the system print dialog with a message; errors are returned, never thrown | `print_service.dart` (`fellBack`, `thermalError`) | READY | — | — |
| Reprint / receipt recovery | Reprint from history | `history/ui/sales_history_view.dart:588` | READY | — | — |

## 4. Cash drawer

| Area | Current implementation | Evidence | Status | Exact gap | Next phase |
|---|---|---|---|---|---|
| Drawer kick through the printer | `ESC p` pulse is built and sent only if `openDrawer` is requested and the printer declares a drawer port | `escpos_commands.dart:124-137`, `escpos_receipt_service.dart:46-65` | MISSING - BLOCKER (for tills with printer-driven drawers) | **Nothing ever requests `openDrawer`**: a cash sale never opens the drawer. There's also no permission-controlled, audited "open drawer / no sale" action | 14A |

## 5. Payments (no real provider was called)

| Method | Current implementation | Evidence | Status | Exact gap | Next phase |
|---|---|---|---|---|---|
| CASH | Tendered, change, quick-cash buttons, cash permissions | `pay_modal.dart`, `payment_plan.dart`, `posPaymentPermissions.js` | READY | — | — |
| Manual CARD / OTHER (provider NONE) | Recorded with a reference from a standalone terminal | `posPaymentModel.js` | READY | — | — |
| Razorpay UPI QR | Create, poll, close, signed webhook (HMAC over the raw body), provider refunds with a request reference | `providers/razorpayQrProvider.js`, `Routes/posPaymentWebhookRoutes.js` | Implemented, needs provider configuration | Live keys, webhook secret, webhook URL, UAT | Provider UAT |
| Pine Labs Cloud (EDC) | Create, status, cancel; card captured on approval; register-to-terminal mapping (`pos_payment_terminals`) | `providers/pineLabsCloudProvider.js` | Implemented, needs provider configuration and certification | Credentials, terminal mapping, Pine Labs certification. Refunds are manual (Phase 8 close-out) | Provider UAT |
| Duplicate / timeout / captured-but-failed / recovery | Idempotent attempts; a timeout leaves the attempt PENDING; restart recovery; captured-payment exceptions; four-eyes manual refund close-out; store-wide manager view; reconciliation CSV | `posPaymentAttemptService.js`, `posPaymentRecoveryService.js`, `posPaymentExceptionService.js`, `/payment-exceptions*`, `/reconciliation/refunds*` | READY | — | — |

## 6. Inventory

| Area | Current implementation | Evidence | Status | Exact gap | Next phase |
|---|---|---|---|---|---|
| First-in-first-out deduction, insufficient stock, concurrent registers | Inside the completion transaction: batches locked with `FOR UPDATE` in a fixed order; 409 `POS_INSUFFICIENT_STOCK` lists all shortages; never negative | `services/pos/posStockService.js` | READY | — | — |
| Feature flag | `POS_STOCK_DEDUCTION_ENABLED`, **off by default** (set in local `.env`) | `posStockService.js:6,17` | NEEDS HARDENING (configuration) | Production must set it, or no stock is ever deducted | Production configuration checklist |
| WEIGHT stock / restoration | Exact thousandths; void (`reverseForSale`), full and partial refunds restock only what that sale deducted; damaged units recorded, not restocked | `posStockService.reverseForSale`, `posSalePartialRefundService.js` (D4/D5) | READY | — | — |
| Adjustments | `POST/GET /inventory/adjustments` (`inventory.adjust`) | `posInventoryAdjustmentService.js` | READY | — | — |

## 7. Offline

| Area | Current implementation | Evidence | Status | Exact gap | Next phase |
|---|---|---|---|---|---|
| Offline sales and payments | Cash always allowed; manual card or other only when enabled in offline settings; provider payments (Pine Labs, Razorpay) never; promotions, loyalty and discounts blocked | `offline/offline_payment_policy.dart`, `offline_checkout_service.dart` | READY | — | — |
| Sync, duplicates, conflicts | Idempotent sync (`pos_offline_sale_syncs` unique key); stock, price, tax or shift conflicts become SYNC_FAILED; manager resolution (`sales.resolve_offline`) | `/offline-sales/sync`, `/offline-sales/:id/resolve`, `offline_sale_views.dart` | READY | — | — |
| Stale catalogue and prices | Cached stock is labelled stale; there is no maximum age; a price change after the sale fails the sync | `offline/models/offline_catalogue.dart:234-249` | NEEDS HARDENING | No limit on how old the offline catalogue can be; a sale made at an old price needs manager resolution | 14C |

## 8. Shift and cash management

| Area | Current implementation | Evidence | Status | Exact gap | Next phase |
|---|---|---|---|---|---|
| Open, float, cash movements, expected cash, close, variance, force close, one shift per register | Expected cash is computed in integer thousandths; variance is shown at close | `posShiftService.js`, `posShiftSummaryService.js:49,107`, `pos_cash_movements`, `pos_shift_force_closes` | READY | — | — |
| Stored close record | `pos_shifts` stores `closing_amount` only | `DESCRIBE pos_shifts` | NEEDS HARDENING | Expected cash and variance at close are not stored; they're recomputed later, so later data changes can alter the history | 14C |
| Denominations / X and Z reports | Not present (denominations only as quick-cash buttons) | `payment_plan.dart:150` | MISSING - RECOMMENDED | No note-and-coin count and no printable shift report | 14C |

## 9. Returns, refunds and voids

| Area | Current implementation | Evidence | Status | Exact gap | Next phase |
|---|---|---|---|---|---|
| Full, partial, PIECE, WEIGHT, damaged, payment refunds, stock, permissions, audit | Each has its own tables (`pos_sale_refunds`, `pos_sale_partial_refund*`, `pos_sale_voids`, `pos_payment_refunds`); `payments.refund`, `sales.void` | `posSalePartialRefundService.js`, `PosSaleController.js` | READY | Pine Labs card refunds are manual | Provider UAT |

## 10. Devices and registers

| Area | Current implementation | Evidence | Status | Exact gap | Next phase |
|---|---|---|---|---|---|
| Registration / revocation | Admin portal and POS settings create registers and devices; the device secret is shown once and stored as a bcrypt hash; status checked live on every request, so revocation is immediate | `adminRoutes.js:96-103`, `posDeviceService.js`, `middleware/posDeviceAuth.js` | READY | — | — |
| Pairing / replacement | Secrets are typed in; replacing a device means creating a new one and deactivating the old | — | MISSING - RECOMMENDED | No QR or short-code enrolment | Later |
| Register scoping on device create | The store is checked against the caller's company; `register_id` from the body is stored **without checking it belongs to that store or company** | `posDeviceService.js` (create, around lines 14-36) | NEEDS HARDENING | Opening a shift does check the register's company (`posShiftService.js:48-50`), so another company's register can't be used. A register from **another store of the same company** can be attached, giving sales a mismatched store and register | 14B |

## 11. Multi-store / multi-register scoping

- Sales, shifts, analytics and offline sync all take their scope from the signed-in session (`req.pos`). Any IDs in a request body are only compared against it, never used (`posOfflineSyncValidation`, analytics comments).
- The client-supplied IDs I found are `store_id` and `register_id` on register and device creation. `store_id` is checked; the `register_id` gap is the one in section 10.
- **NEEDS HARDENING:** that single item.

## 12. Customer display

- None exists: no second-screen or customer-facing code in `lib`.
- **OPTIONAL.** Recommended only where regulation or the store's practice expects a customer-facing total; the receipt and the cashier screen cover the minimum.

## 13. Retail product management

| Area | Current implementation | Evidence | Status | Exact gap | Next phase |
|---|---|---|---|---|---|
| Catalogue, barcode, tax, active/inactive | Read from the shared catalogue (`product_variation`); category tax | `posProductRepository.js`, `posTax.js` | READY | — | — |
| POS price override | `products.price_change`, version and history | `pos_product_prices`, `pos_product_price_changes` | READY | — | — |
| Selling modes | PIECE / WEIGHT (feature flag) / REVIEW blocked | `pos_product_selling_modes`, `posSellability.js` | READY | WEIGHT stays behind `POS_WEIGHT_SALES_ENABLED` | Production configuration |
| Duplicate barcode / SKU | See section 2. Duplicate `product_code` groups (31) are variations of the same product, which is expected | DB counts | NEEDS HARDENING | Ambiguous barcode lookup | 14B |

## 14. Retail reporting

| Area | Current implementation | Evidence | Status | Exact gap | Next phase |
|---|---|---|---|---|---|
| Sales summary | `GET /analytics/summary?from=&to=`: gross, refunds, net, payment and refund breakdown by method, cash movements; scoped to the store | `posAnalyticsService.js` | READY (basic) | — | — |
| By cashier / register / product / tax, shift report | Not found in the analytics service; the admin portal lists shifts only (`/stores/:storeId/shifts`) | `posAnalyticsService.js`, `adminRoutes.js:113` | MISSING - RECOMMENDED (**tax report may be a BLOCKER** if GST filing depends on POS) | No tax-collected report, no product-sales report, no per-cashier or per-register report, no exports | 14C / 14F |

## 15. Security / audit

| Area | Current implementation | Evidence | Status | Exact gap | Next phase |
|---|---|---|---|---|---|
| Role-based permissions | Dynamic per-staff permissions: sales.*, payments.accept_*, payments.refund, sales.void, discounts.override, products.price_change, inventory.adjust, shifts.*, sales.resolve_offline | `posAuthorizationService.js`, `pos_roles` / `pos_permissions` | READY | — | — |
| Authentication | Device JWT plus staff PIN (rate-limited, lockout); revocation checked live; admin portal login rate-limited | `posRoutes.js:59-60`, `pos_staff_pins`, `adminRoutes.js:58` | READY | Device secrets are shortened when not in production (`posDeviceSecret.js`), so `NODE_ENV=production` must be set | Production configuration |
| Audit / four-eyes | Admin audit log; per-action tables with staff and time; four-eyes on manual refund close-out | `pos_admin_audit_log`, `pos_payment_exception_events` | READY | — | — |

## 16. Platform readiness

| Platform | Status | Notes |
|---|---|---|
| Android | READY (software) | Primary target: camera scanning, keyboard-wedge scanners, network printing, speech and TTS. Needs device UAT |
| iOS | NEEDS HARDENING | Project present (camera, microphone, speech and local-network permissions declared); the CocoaPods include was added by Phase 13F; untested on a device |
| Windows / macOS | MISSING - RECOMMENDED only if desktop tills are planned | No platform folders. USB printing, scanners as keyboards and secure storage would need desktop validation; `speech_to_text` and `mobile_scanner` are limited on desktop |

## 17. Retail usability (significant issues only)

- **No keyboard shortcuts** (section 1): slow on keyboard tills. MISSING - RECOMMENDED.
- **Receipts must be printed manually** after every sale (section 1). NEEDS HARDENING.
- **Cash drawer doesn't open** on cash sales (section 4). BLOCKER where drawers are used.
- **Scans can be lost** while the cart is busy (section 2). NEEDS HARDENING.
- **Shift close has no denomination count** (section 8). MISSING - RECOMMENDED.
- **Payment state and failure recovery are clear:** "Retry payment" uses the same request key, and there's a recovery view and an exception view. READY.

---

## 1. TOP PRODUCTION BLOCKERS (most severe first)

1. **Stock deduction off by default.** `POS_STOCK_DEDUCTION_ENABLED` must be on in production, or sales never reduce stock. This is configuration, not code.
2. **Cash drawer never opens** on a cash sale, and there's no audited "no sale" action (for tills using printer-driven drawers).
3. **Hardware not yet validated:** thermal printer, scanner and drawer on real devices.
4. **Card/QR providers not yet live:** Razorpay and Pine Labs need credentials, configuration and UAT/certification before they can be enabled. Until then: cash plus manual card only.
5. **Tax report** (business to confirm): no tax-collected reporting if GST filing relies on the POS.
6. **Device register scoping** (security hardening): validate that `register_id` belongs to the device's store.

## 2. RECOMMENDED NEXT PHASES (smallest, highest value first)

- **14A:** cash drawer. Open on a successful cash sale (when the printer declares a drawer), plus a permission-controlled, audited "open drawer" action.
- **14B:** small hardening.
  - Check `register_id` on device create.
  - Ambiguous-barcode conflict.
  - Auto-print setting.
- **14C:** shift close completeness.
  - Store expected cash and variance.
  - Denomination count.
  - X/Z shift report.
  - Maximum age for the offline catalogue.
- **14D:** USB/Bluetooth printer adapters (Android first).
- **14E:** cashier speed: keyboard shortcuts, and queue scans instead of dropping them when busy.
- **14F:** retail reports: tax collected, product sales, by cashier and by register, exports.

## 3. HARDWARE / PROVIDER DEPENDENCIES

- **Physical hardware:**
  - ESC/POS network printer (58/80 mm, cutter, drawer port);
  - USB or Bluetooth printers if chosen;
  - keyboard-wedge scanners;
  - cash drawer;
  - Android tablets or phones (and iOS if used);
  - microphone and speaker quality for voice.
- **Provider credentials:** Razorpay key ID/secret and webhook secret; Pine Labs Cloud credentials and terminal mapping.
- **Provider certification / UAT:** Pine Labs integration certification; Razorpay live-mode UAT, including webhook delivery and refunds.
- **Production configuration:**
  - `POS_STOCK_DEDUCTION_ENABLED`;
  - `POS_WEIGHT_SALES_ENABLED` (if selling by weight);
  - `NODE_ENV=production` (full-strength device secrets);
  - `ENABLE_BACKGROUND_JOBS`;
  - provider environment variables;
  - webhook URL reachability.
- **Device engines:** Malayalam speech recognition and TTS voices (if voice is used).

## 4. POSTPONED ITEMS (deliberately later)

- Customer-facing display (OPTIONAL).
- Price- or weight-embedded scale barcodes (only for scale-label stores).
- Windows/macOS tills.
- QR or short-code device pairing.
- Pine Labs automated refunds (manual close-out works).
- Scanner timing settings.
- Hands-free voice and further languages.
- Out of scope entirely: B2B orders, restaurant ordering, tables, kitchen.
