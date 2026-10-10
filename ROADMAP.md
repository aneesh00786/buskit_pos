# ThriveWoo POS — Roadmap

Advanced Point-of-Sale system for retail, built phase by phase.

**Status legend:** `[ ]` not started · `[~]` in progress · `[x]` done

## Pending decisions (to be filled in as explained)
- [ ] Tech stack (frontend / backend / mobile / desktop)
- [ ] Architecture model (cloud SaaS / offline-first with sync / on-premise)
- [ ] Database choice
- [ ] Hosting/deployment target
- [ ] Hardware integrations needed (receipt printer, barcode scanner, cash drawer, card reader)

---

## Phase 1 — Foundation & Core Sales (Checkout)
Goal: a working till that can ring up a sale.
- [ ] Project scaffolding & tooling (repo structure, linting, CI)
- [ ] Product catalog (name, price, SKU/barcode, tax rate)
- [ ] Cart / checkout flow (add item, quantity, discount, void line)
- [ ] Payment capture (cash, card placeholder)
- [ ] Receipt generation (print/email/PDF)
- [ ] Basic sale record persistence

## Phase 2 — Inventory Management
Goal: stock is tracked accurately as sales happen.
- [ ] Stock levels per product (and per variant if applicable)
- [ ] Stock deduction on sale, restock/adjustment flow
- [ ] Low-stock alerts / reorder thresholds
- [ ] Supplier & purchase order tracking
- [ ] Barcode scanning support

## Phase 3 — Users, Roles & Store Operations
Goal: more than one person can use the system safely.
- [ ] Authentication & user accounts
- [ ] Role-based access (cashier, manager, admin)
- [ ] Shift management (clock in/out, cash drawer reconciliation)
- [ ] Audit log of sensitive actions (voids, refunds, discounts, price overrides)

## Phase 4 — Customers & Transactions
Goal: richer transaction handling beyond a single walk-in sale.
- [ ] Customer profiles & purchase history
- [ ] Returns & refunds
- [ ] Store credit / gift cards
- [ ] Loyalty points / discounts & promotions engine
- [ ] Split/partial payments, multiple tender types

## Phase 5 — Reporting & Analytics
Goal: owners/managers can see how the business is doing.
- [ ] Daily/weekly/monthly sales reports
- [ ] Top-selling products, category performance
- [ ] Profit margin & tax reports
- [ ] Staff performance (sales per cashier)
- [ ] Exportable reports (CSV/PDF)

## Phase 6 — Multi-Store & Scaling
Goal: support growth beyond a single register/location.
- [ ] Multi-register support within a store
- [ ] Multi-store/multi-branch management
- [ ] Centralized inventory sync across locations
- [ ] Offline mode & conflict-resolution sync (if applicable)

## Phase 7 — Integrations & Advanced Features
Goal: connect to the outside world and add differentiators.
- [ ] Payment gateway integration (real card/mobile payments)
- [ ] Accounting software integration (e.g. QuickBooks/Xero)
- [ ] E-commerce/online store sync
- [ ] Hardware integration (receipt printers, cash drawers, scanners, scales)
- [ ] Notifications (SMS/email for receipts, low stock, etc.)
- [ ] Multi-language / multi-currency support

---

## Notes
- This roadmap is a living document — phases and scope will be refined as details are provided for each stage.
- Each phase should be independently shippable/testable before moving to the next.
