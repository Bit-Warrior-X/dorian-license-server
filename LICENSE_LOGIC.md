# Dorian Licensing Logic — Order-driven model

Status: implemented, v2.0 (Nov 2026)
Code: `dorian-back-end/internal/store/orders.go`, `internal/api/orders.go`, `order_pricing.go`, `order_provision.go`, `license_lifecycle.go`; UI under **Billing → Orders** and **Billing → Licensing**.
Longer-term design (packages, SKUs, signed entitlement bundles): [LICENSE_LOGIC_FUTURE.md](LICENSE_LOGIC_FUTURE.md).  
Edge follow-up (Angelos / Sparta / Athens): [EDGE_LICENSE_WORK.md](EDGE_LICENSE_WORK.md).

---

## 1. Idea in one paragraph

A customer first says **what they want to protect** by placing an order. The order is priced from a small catalog, paid manually (bank transfer, confirmed by an operator), and then an operator approves the setup. Setup creates the edges and sites and issues one **license per protected object** (one per edge, one per site). Licenses run on a monthly or annual subscription and are renewed through renewal orders. Anything added later (more sites, another edge, L4 on an existing edge) is an **add-on order**, paid separately and prorated so it ends together with the customer's existing licenses.

A customer with several kinds of protection (hybrid) simply has several orders; each order pays for its own licenses.

---

## 2. Order purposes

| Purpose | Customer provides | We set up | Licenses issued | Priced as |
|---|---|---|---|---|
| `site_own` — sites on own edge | 1+ edges (SSH access), N sites | Athens (L7) on each edge, optional Sparta (L4) per edge, the sites | Edge: `L7` or `Unified` (if L4 ticked). Site: `SITE_OWN` ×N | `EDGE_L7` per edge + `L4_ADDON` per edge with L4 + `SITE_OWN` ×N + `SETUP_FEE` per edge |
| `site_platform` — sites on platform edge | N sites | Sites on Dorian platform edges | Site: `SITE_PLATFORM` ×N | `SITE_PLATFORM` ×N |
| `edge` — edge protection | N edges (SSH access) | Sparta (L4) on each edge | Edge: `L4` ×N | `EDGE_L4` ×N + `SETUP_FEE` per edge |
| `edge_site` — edge + sites | 1+ edges, N sites | L4 + L7 on each edge, the sites | Edge: `Unified`. Site: `SITE_OWN` ×N | `EDGE_L7` + `L4_ADDON` per edge + `SITE_OWN` ×N + `SETUP_FEE` per edge |
| `addon` | any mix of new edges (choose L4/L7), new sites (own L7 edge or platform), L4 upgrades of own L7 edges | the additions | as above; an upgraded edge becomes `Unified` | same items, **prorated** |
| `renewal` | licenses to renew | nothing | extends the selected licenses | full price per license for one period |

Defaults are enforced server-side (`normalizeOrderDetails`): `edge` is always L4-only, `edge_site` always L4+L7, `site_own` always L7 with L4 optional, `site_platform` has no edges.

---

## 3. Catalog (editable by Admin: Orders → Prices)

| Code | Meaning | Monthly | Annual |
|---|---|---|---|
| `EDGE_L4` | Edge L4 protection (Sparta) | 25 | 240 |
| `EDGE_L7` | Edge setup (L7, Athens) for own sites | 250 | 2400 |
| `L4_ADDON` | L4 added to an L7 edge | 99 | 948 |
| `SITE_OWN` | Site on own edge | 10 | 96 |
| `SITE_PLATFORM` | Site on platform edge | 20 | 192 |
| `SETUP_FEE` | One-time per new edge | 0 | — |

Prices live in `license_plans` rows with `category = 'catalog'` (the old per-edge tiers keep `category = 'tier'`). A submitted order keeps the price it was invoiced at; price changes affect only new quotes.

---

## 4. Order lifecycle

```
draft ──submit──▶ awaiting_payment ──payment(s) ≥ total──▶ awaiting_setup ──approve──▶ provisioning ──▶ active
  │                    │                                        │                        │ (error: "Setup failed",
  └──cancel────────────┴──cancel / reject───────────────────────┴──reject────────────────┘  approve again = retry)
                                                                                    ▶ cancelled
renewal orders: awaiting_payment ──paid──▶ active (licenses extended immediately, no setup)
```

- **Draft**: free to edit; SSH secrets are stored encrypted (secretbox) and kept when the edge IP is unchanged. Customers can keep several drafts.
- **Submit**: validates everything (`validateOrderForSubmit`), locks the quote, assigns invoice `INV-YYYY-#####`. A zero-total order is treated as paid at once.
- **Payment**: Admin records one or more payments (amount, bank reference, date). When paid total ≥ order total the order moves on.
- **Approve** (Admin): picks a Dorian version per new edge and, for platform sites, the platform edges. Setup then runs in the background:
  1. Create each new edge (`performServerCreate`, owner = customer), clear its SSH secrets, issue the edge license.
  2. Apply L4 upgrades (license-only reissue to `Unified`).
  3. Create each site on the customer's L7 edge(s) or on platform edges; issue the site license. Edge sync problems are recorded as warnings, not failures.
  4. Mark the order active and notify the customer.
  Each step records its result on the order (`serverId`, `siteId`, `upgradesDone`), so **retrying skips work already done**.
- **Cancel**: customer can cancel draft or unpaid orders (not once a payment is recorded). **Reject**: Admin, with a reason, any time before setup succeeds.

Every transition sends a panel notification (kind `order`) to the customer and, for new submissions, to all Admins.

---

## 5. Licenses

One row per protected object in `licenses` (unique on scope + target):

| Field | Values |
|---|---|
| scope | `server`, `site` |
| kind | `L4`, `L7`, `Unified` (edges); `SITE_OWN`, `SITE_PLATFORM` (sites) |
| period | `month`, `year` |
| status | `active`, `past_due`, `expired`, `cancelled` |
| current_period_end | end of the paid period |
| renewal_order_id | open renewal order, if any |
| cancel_at_period_end | customer asked not to renew (JSON `cancelAtPeriodEnd`) |

The edge's own license file (deployed by Angelos) keeps working as before: its `license_type` and expiry are synced from the license row on creation, upgrade and renewal.

### 5.1 Status timeline (hourly worker)

| When | Status | Effect |
|---|---|---|
| until period end | `active` | everything allowed |
| period end − 7 days | `active` | renewal order auto-created (grouped per customer and period), customer notified |
| after period end | `past_due` | still allowed; warning notifications |
| period end + 14 days | `expired` | protection keeps running; **configuration changes are locked** (HTTP 423) until renewed |
| after period end, with `cancel_at_period_end` | `cancelled` | locked like expired; no renewal orders |
| admin "end now" | `cancelled` | locked like expired, immediately |

Paying a renewal order extends each license by one period from max(now, current end), sets it back to `active`, syncs the edge expiry and reissues the edge license file.

Customers can also renew manually from **Licensing** (single license or a multi-select of one customer's licenses, monthly or annual).

### 5.2 Cancelling a license

- **Cancel** (Licensing → row → Cancel) sets `cancel_at_period_end`. The license stays active until its period end, then becomes `cancelled`. No refunds.
- If the license sits in an **unpaid** renewal order, that order is cancelled and re-issued for the remaining licenses. If a payment was already recorded on it, cancelling is refused (409) — ask an operator.
- **Keep** (resume) clears the flag any time before the period end. Paying a renewal also clears it.
- Admins can tick **End it now** to cancel immediately.
- Customers cannot renew a `cancelled` license; they place a new order. Admins can still renew it.
- A cancelled license only **locks configuration**. The edge keeps running with its last configuration and services are not stopped; an operator deletes the edge/site when the customer is gone.

---

## 6. Enforcement (non-admin users)

| Request | Rule |
|---|---|
| `POST /servers`, `POST /sites` | 402 — edges and sites come only from orders |
| writes to `/servers/{id}/l4*`, Sparta via `/servers/{id}/service-control` | 402 unless the edge license is `L4` or `Unified` |
| writes to `/servers/{id}/l7-guard`, Athens via `/servers/{id}/service-control` | 402 unless the edge license is `L7` or `Unified` |
| `PUT/PATCH /sites/{id}` changing the domain | 402 — a new domain is a new site (order it) |
| `PUT/PATCH /sites/{id}` adding edges to a `SITE_PLATFORM` site | 402 — placement is done by the operator |
| `PUT/PATCH /sites/{id}` adding edges to a `SITE_OWN` site | 402 unless each added edge holds the same customer's active `L7`/`Unified` license |
| any write to a server/site whose license is `expired` or `cancelled` | 423 `license_expired` |
| `DELETE` of the object itself | always allowed |
| changing an edge tier directly | Admin only (operator override, not billed) |

Visibility: customers see edges they are assigned to and sites they own through a license. Platform edges (`servers.kind = 'platform'`, set under Orders → Platform edges) are never assigned to customers, so they never appear in a customer's edge list; customers reach their platform sites through the site license only.

Analytics for a customer's site (cache, L7 events, performance) are filtered by the site itself, so platform sites show data even though the platform edges are hidden. Edge-level data (NIC, L4, per-edge breakdowns) stays limited to the customer's own edges.

Admins (operators) bypass the guard. Edges and sites an Admin creates directly, outside orders, get no license row and are not billed.

---

## 7. API summary

Customer and Admin:
- `GET /api/v1/orders/catalog`, `POST /api/v1/orders/quote`
- `GET /api/v1/orders[?status=a,b]`, `POST /api/v1/orders` (`submit: true` to submit at once), `GET|PUT /api/v1/orders/{id}`
- `POST /api/v1/orders/{id}/submit`, `POST /api/v1/orders/{id}/cancel`
- `GET /api/v1/licenses`, `POST /api/v1/licenses/renew {licenseIds, period}`
- `POST /api/v1/licenses/{id}/cancel {immediate}` (`immediate` is Admin only), `POST /api/v1/licenses/{id}/resume`

Admin only:
- `POST /api/v1/orders/{id}/payment {amount, reference, paidOn}`
- `POST /api/v1/orders/{id}/approve {edges:[{index, versionUuid}], platformServerIds}`
- `POST /api/v1/orders/{id}/reject {note}`
- `PUT /api/v1/admin/order-catalog/{code} {monthlyPrice, annualPrice}`
- `GET /api/v1/admin/server-kinds`, `PUT /api/v1/admin/server-kinds/{id} {kind}`

Admins may place orders on behalf of a customer (`userId` in the create body).

Each order site carries `origins: [{address, protocol}]` (1–16, host or IP with optional `:port`); on setup every origin becomes an upstream of the site. Drafts saved with the older single `origin` field are read as a one-origin list.

---

## 8. Migration from the tier model

On first start with empty `orders` and `licenses` tables, existing edges get a server license from their `license_type` (`Trial` becomes `Unified`) and existing sites get a `SITE_OWN` license; the owner is the edge's lowest-id assigned user and the period end is the edge's current expiry. No orders are created for migrated licenses ("Migrated" in the Licensing table).

---

## 9. Not covered yet

- Payment gateway / automatic payment confirmation (manual only).
- Signed entitlement bundles verified by Angelos (see the future spec); edges still trust their deployed license file. Switching to one embedded platform key needs an Angelos change first — the license server still ships a per-machine `server_public_key.pem`.
- Stopping services or disabling sites on the edge when a license is cancelled or expired (today only configuration is locked).
- Refunds and credit notes; mid-period downgrades.
- Per-site analytics quotas.
