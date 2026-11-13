# Dorian Licensing Logic

Status: future specification, v1.0 (Nov 2026). Not implemented — the live model is [LICENSE_LOGIC.md](LICENSE_LOGIC.md) (order-driven licensing).
Supersedes: host-level `license_type` (Trial / L4 / L7 / Unified) and per-machine RSA licenses described in [WORKFLOW.md](WORKFLOW.md).
Based on: `Design/Dorian Licensing Architecture.pdf` (draft, Nov 9 2026), completed with trust model, feature registry, tenancy, lifecycle timers, enforcement matrices, bundle protocol, metric attribution and migration.

---

## Contents

1. Principles
2. Current system and its defects
3. Core model: Package, SKU, Entitlement, Enforcement
4. Objects, nodes and locations
5. Feature registry
6. SKU catalog
7. Packages
8. Tenancy and roles
9. Lifecycle state machine
10. The `Entitled()` decision function
11. Enforcement matrices
12. Trust model and keys
13. Entitlement bundles
14. Bundle delivery protocol
15. Anti-abuse
16. Metric and event attribution
17. Hybrid: ORIGIN-LOCK
18. Data model (DDL)
19. API surface
20. Panel UI rules
21. Scenarios (acceptance list)
22. Migration from legacy licenses
23. Rollout phases
24. Glossary

---

## 1. Principles

1. **License objects, not processes.** Customers buy protection for a site, an IP, an application port or a prefix, or they buy the right to run Dorian software on their own machine. Platform processes (Sparta/Athens on Dorian-operated edges) are never licensed to a customer.
2. **Every setup is a combination of SKUs.** No bespoke license types. Packages are only sales bundles.
3. **L4 and L7 may live in different places and still be linked** (customer L4 on their machine, Dorian L7 on the platform).
4. **Non-payment removes features or control, never traffic.** Only revocation stops service.
5. **Trial is a state, not a type.** Unified is a package name, not a license.
6. **One decision function.** `Entitled()` is the single source of truth for the API, the bundle compiler, the panel UI and analytics.
7. **Customer machines cannot forge, replay, clone or roll back licenses.**

---

## 2. Current system and its defects

How it works today:

- The panel stores `servers.license_type` (Trial/L4/L7/Unified) and `servers.expired`.
- `deploy_license` (`/create_server`) generates an RSA keypair **per machine**, runs `mklicense` with `machine_id`, `duration`, `feature` (1=L4, 2=L7, 3=unified, 7=trial), and ships `license.tar.gz` containing the license and the machine's public key.
- The edge verifies `RSA-SHA256(payload)` with the shipped public key and checks `updated_at + duration` against the local clock.
- Angelos reports `report_license expired|manipulated`; the panel turns that into a security event only.
- The panel gates L4/L7 pages in the front end only (`serverLayerStatus.js`).

| # | Defect | Severity | Fixed in |
|---|--------|----------|----------|
| D1 | Public key ships beside the license, so a box owner can generate a keypair, self-sign `feature=3, duration=9999`, and replace both files. | Critical | §12 |
| D2 | Expiry uses the local clock; rolling it back extends the license. | High | §12.4 |
| D3 | License = process tier for a whole box; cannot express shared platform edges or hybrid customers. | High | §3–§6 |
| D4 | No server-side enforcement of writes (L4 config, WAF, service control). | High | §11.5 |
| D5 | Two sources of truth (`lic.license` vs `servers.*`) drift; license reports do not change node state. | Medium | §14.5 |
| D6 | No tenancy; `Admin` is global. | High | §8 |
| D7 | Server-level metrics are not attributable to a customer on shared edges. | High | §16 |

---

## 3. Core model

```
Package  ──contains──▶  SKU line items  ──compile──▶  Signed entitlements  ──▶  Enforcement
(sales)                 (billing unit)                (per node bundle)          (Sparta / Athens / API)
```

- **Package**: a named bundle of SKUs with a price. Never seen by enforcement.
- **SKU**: a fixed product unit bound to one object type, with a feature JSON (§5).
- **Line item**: one purchased SKU inside a subscription, with quantity and its own lifecycle state.
- **Assignment**: links a line item to the objects or nodes it covers (quantity limits how many).
- **Entitlement**: the compiled result "object X may use feature Y with value V at location Z until T".
- **Enforcement**: Sparta BPF maps, Athens `ent:{site_id}` dictionary, Go control-plane write checks, analytics query clamps.

---

## 4. Objects, nodes and locations

### 4.1 Protected objects

| Type | Identity | Example |
|------|----------|---------|
| `site` | hostname | `shop.example.com` |
| `ip` | single IPv4/IPv6 | `203.0.113.10` |
| `port_app` | dedicated edge IP + port(s) | game server `:27015/udp` |
| `prefix` | CIDR (future L4-NET) | `198.51.100.0/24` |

Every object belongs to exactly one tenant.

### 4.2 Nodes

| Kind | Owner | Who is licensed |
|------|-------|-----------------|
| `platform` | Dorian | Nobody. Runs objects of many tenants. |
| `private` | Customer | The tenant, via a `NODE-*` SKU activation. |

### 4.3 Locations

A **placement** says where an object is served: `(object_id, node_id)`. The location of a placement is `platform` or `private:{node_id}`. Features can be location-restricted (e.g. a `NODE-L7` only serves sites of the node's own tenant).

Hard rule: **a private node never joins the platform L7 pool**, and a platform node never carries another tenant's private config.

---

## 5. Feature registry

Canonical keys. SKUs, add-ons and overrides only speak these keys; enforcement only reads these keys.

| Key | Type | Merge rule | Enforced by |
|-----|------|-----------|-------------|
| `node.sparta` | bool | or | Angelos (run Sparta) |
| `node.athens` | bool | or | Angelos (run Athens) |
| `node.capacity_tier` | enum `10g<40g<100g<200g` | max | Panel warning if Sparta-reported link > tier (soft) |
| `node.sites_included` | int | sum | Control plane (count of private placements) |
| `l4.on_node` | bool | or | Sparta per protected IP |
| `l4.custom_rules_max` | int | sum | Control plane write |
| `l4.geo_block` | bool | or | Sparta |
| `l4.proxy` | bool | or | Platform L4 proxy listener |
| `l4.dedicated_ips` | int | sum | Control plane IP allocation |
| `origin_lock` | bool | or | Bundle compiler → Sparta allowlist |
| `l7.waf.managed` | enum `none<basic<full` | max | Athens |
| `l7.waf.custom_rules_max` | int | sum | Control plane write |
| `l7.rate_limit` | enum `none<basic<full` | max | Athens |
| `l7.bot` | enum `none<basic<full` | max | Athens |
| `l7.certs.custom` | bool | or | Control plane + Athens SSL |
| `l7.ai.mode` | enum `none<suggest<auto` | max | Control plane |
| `analytics.retention_days` | int | max | Query layer clamps range |
| `logs.export` | bool | or | Export/download endpoints |
| `logs.retention_days` | int | max | Log listing + query clamp |
| `support.tier` | enum `community<standard<priority` | max | Panel only |

Resolution of a feature for an object: base SKU value → merge add-ons (merge rule) → apply `feature_overrides` (override replaces) → apply lifecycle degradation (§9.3).

Unknown keys are ignored by enforcement and rejected by the SKU editor.

---

## 6. SKU catalog

### 6.1 Node SKUs (private nodes)

| SKU | Features |
|-----|----------|
| `NODE-L4` | `node.sparta`, `l4.on_node`, `l4.custom_rules_max=50`, `l4.geo_block`, `node.capacity_tier` (per quantity option), `origin_lock` eligible |
| `NODE-L7` | `node.athens`, `node.sites_included=10`; sites on it still need a `SITE-*` for tier features (default `SITE-pro` included ×10) |
| `NODE-FULL` | Union of `NODE-L4` and `NODE-L7`, bundle price |

A node SKU is consumed by an **activation** (line item ↔ node, bound to hardware fingerprint).

### 6.2 Site SKUs

| Feature | `SITE-free` | `SITE-pro` | `SITE-business` | `SITE-ent` |
|---------|-------------|------------|-----------------|------------|
| `l7.waf.managed` | basic | full | full | full |
| `l7.waf.custom_rules_max` | 5 | 25 | 100 | contract |
| `l7.rate_limit` | none | basic | full | full |
| `l7.bot` | none | basic | full | full |
| `l7.certs.custom` | false | true | true | true |
| `l7.ai.mode` | none | suggest | auto | auto |
| `analytics.retention_days` | 1 | 7 | 30 | contract (default 90) |
| `logs.export` | false | true | true | true |
| `logs.retention_days` | 1 | 7 | 30 | contract |
| `support.tier` | community | standard | standard | priority |

### 6.3 L4 object SKUs

| SKU | Object | Features |
|-----|--------|----------|
| `L4-PROXY` | `port_app` | `l4.proxy`, `l4.dedicated_ips=1`, `l4.custom_rules_max=20` |
| `L4-NET` | `prefix` | Future: GRE/BGP scrubbing |
| `ORIGIN-LOCK` | site↔node link | `origin_lock`; price 0 when tenant holds `NODE-L4`+any `SITE-*` |

### 6.4 Add-ons

| Add-on | Adds |
|--------|------|
| `ADD-RULES-25` | `l7.waf.custom_rules_max +25` |
| `ADD-L4-RULES-50` | `l4.custom_rules_max +50` |
| `ADD-AI-AUTO` | `l7.ai.mode = auto` |
| `ADD-RETENTION-90` | `analytics.retention_days = 90`, `logs.retention_days = 90` |
| `ADD-IP` | `l4.dedicated_ips +1` |
| `ADD-BW-COMMIT` | Platform bandwidth commitment (billing only) |

Add-ons attach to one object (or node) via assignment.

---

## 7. Packages

| Package | Contents |
|---------|----------|
| Site Protection | `SITE-pro` ×N |
| Hybrid Shield | `NODE-L4` ×1 + `SITE-business` ×N + `ORIGIN-LOCK` |
| Private CDN | `NODE-L7` ×N (+ included `SITE-pro`) |
| Unified | `NODE-FULL` ×N + `SITE-business` ×N |
| Game / App Shield | `L4-PROXY` ×N |

Buying a package creates one subscription with one line item per SKU. After that, only line items matter.

---

## 8. Tenancy and roles

| Role | Scope | Permissions |
|------|-------|-------------|
| `platform_operator` | global | Platform nodes, SKU/price editor, overrides, payments, revoke, read all tenants |
| `tenant_admin` | one tenant | Subscriptions, private nodes, objects, members, API tokens |
| `tenant_member` | one tenant | Configure objects assigned to them; read analytics |
| `reseller_admin` | parent tenant | Allocate pooled line items to child tenants |

Rules:

- Every request resolves `(user, tenant)` first. `viewer_scope` filters by `tenant_id` before any node/site ACL.
- `server_users` stays as a per-node ACL **inside** a tenant.
- Operators reading tenant data is logged in the audit log.
- Reseller pools: a parent line item with quantity N; child assignments decrement it. Child tenants see only their own objects.

---

## 9. Lifecycle state machine

State lives on each **line item**.

### 9.1 States

| State | Meaning |
|-------|---------|
| `trial` | Free evaluation, time-boxed |
| `active` | Paid and current |
| `past_due` | Period ended unpaid; full service with warnings |
| `suspended` | Unpaid beyond grace; config frozen or degraded |
| `expired` | Long unpaid; base or free behaviour |
| `revoked` | Terminated; service removed |

### 9.2 Transitions

```
            payment                 period_end unpaid         +7d               +14d             +30d (sites/objects)
trial ───────────────▶ active ─────────────────────▶ past_due ─────▶ suspended ─────▶ expired ───────────────▶ revoked
  │ trial_ends                ▲      payment            │               │                │
  └──────────▶ expired        └─────────────────────────┴───────────────┴────────────────┘
active/any ── operator fraud action ──▶ revoked
```

| Timer | Value |
|-------|-------|
| `past_due → suspended` | 7 days |
| `suspended → expired` | 14 days |
| `expired → revoked` | 30 days for `SITE-*`, `L4-PROXY`, `L4-NET`, add-ons. **Never automatic for `NODE-*`** (private nodes stay `expired` on base ruleset until an operator revokes). |
| `SITE-*` trial | 14 days |
| `NODE-*` trial | 7 days |
| Trial limits | max 2 concurrent trials per tenant; one trial per SKU family per tenant, ever |

All transitions go through one function:

```go
func TransitionLineItem(ctx context.Context, lineItemID int64, ev LifecycleEvent, actor string, reason string) error
// LifecycleEvent: PaymentRecorded | PeriodEnded | TimerElapsed | TrialEnded | OperatorRevoke | OperatorReinstate
```

It writes `license_events`, updates `line_items.state`, and enqueues recompile of every node whose bundle includes the affected objects.

An hourly worker `license_lifecycle_tick` applies timer events. Billing is manual in v1: operators record payments and extend periods in the panel; a payment provider later calls the same `PaymentRecorded` event.

### 9.3 Degradation applied by `Entitled()`

| State | Node features | Object features |
|-------|---------------|-----------------|
| trial, active, past_due | full | full tier |
| suspended | `frozen` (enforce last config, no writes) | `SITE-*` → `SITE-free` values; `L4-PROXY` → default thresholds |
| expired | `base` (Sparta default thresholds only; Athens serves existing sites, no changes) | same as suspended; release dedicated IPs after 7-day notice |
| revoked | deny | deny (object removed from bundles) |

### 9.4 Downgrade and over-limit

When a resolved cap drops below current usage (downgrade, suspension, add-on removed):

1. All existing rules stay active for 7 days; the panel shows "over limit: choose rules to disable".
2. After 7 days, the newest rules over the cap are **disabled (not deleted)**, with an in-panel notification and audit entry.
3. New writes are rejected while over the cap.

### 9.5 Hardware replacement

A tenant admin can **transfer** a node activation once per 30 days without an operator: old node `activations.revoked_at = now`, new activation created, old node's bundle stops renewing. More frequent transfers need an operator.

---

## 10. The `Entitled()` decision function

```go
type Location struct {
    Kind   string // "platform" | "private"
    NodeID int64
}

type Decision struct {
    Allow  bool
    Level  string // "full" | "degraded" | "frozen" | "base" | "deny"
    Value  any    // resolved feature value
    State  string // best line-item state
    Reason string // "ok" | "not_assigned" | "wrong_tenant" | "not_placed" | "line_item_suspended" | "line_item_expired" | "revoked" | "cap_reached"
}

func Entitled(ctx context.Context, tenantID, objectID int64, feature string, loc Location) (Decision, error)
func EntitledNode(ctx context.Context, tenantID, nodeID int64, feature string) (Decision, error)
func CheckCap(ctx context.Context, tenantID, objectID int64, feature string, current int) (Decision, error)
```

Algorithm:

1. **Tenant.** `objects.tenant_id == tenantID`, else `deny/wrong_tenant`. Operators pass for reads only.
2. **Coverage.** Collect line items assigned to the object (for node features: activations on the node). None → `SITE-free` defaults for sites on the platform, otherwise `deny/not_assigned`.
3. **Pick.** Drop `revoked`. Choose the best by state priority `active > trial > past_due > suspended > expired`; ties by highest tier.
4. **Resolve.** Base SKU feature → add-ons → overrides (§5).
5. **Degrade.** Apply §9.3 for the chosen state.
6. **Location.** For site/port_app features, require a placement at `loc`; for `NODE-L7`, require the object tenant == node tenant.
7. **Return.** `Decision` with reason. Callers never re-implement this.

Consumers: API write validators, bundle compiler, `GET /api/v1/entitlements/effective`, analytics/log query clamps.

---

## 11. Enforcement matrices

### 11.1 Private node (`NODE-*`)

| State | Sparta | Athens | Control plane |
|-------|--------|--------|---------------|
| trial / active / past_due | Full | Full | Writes within caps; past_due banner |
| suspended | Last config frozen, enforcing | Last config frozen, serving | Config writes → `423 license_suspended` |
| expired | Base ruleset: default SYN/UDP/ICMP flood thresholds; no custom lists, no geo | Existing sites serve; no new sites or changes | As suspended; no new placements |
| revoked | Stopped by Angelos | Stopped by Angelos | Node read-only, removable |

### 11.2 Site on the platform (`SITE-*`)

| State | Athens | Control plane |
|-------|--------|---------------|
| trial / active / past_due | Tier features | Writes within tier caps |
| suspended / expired | Free-tier features | Writes limited to Free caps |
| revoked | Site removed from all bundles | Site detached |

Athens lookup rule: a site with no `ent:{site_id}` entry on a platform node is served with **Free** features and logs `ent_missing` (fail-open for availability). Revocation never relies on this lookup because revoked sites are removed from configuration.

### 11.3 `L4-PROXY`

| State | Behaviour |
|-------|-----------|
| trial / active / past_due | Full proxy, custom rules |
| suspended | Proxy with default thresholds |
| expired | Proxy with default thresholds; dedicated IP released after 7-day notice |
| revoked | Listener and IP released |

### 11.4 Analytics and logs

- Time range clamped to `analytics.retention_days` / `logs.retention_days`.
- Export and hourly log download require `logs.export`.

### 11.5 Panel API gating

Every mutating handler checks `Entitled()` / `CheckCap()` before writing.

| Endpoint group | Feature checked |
|----------------|-----------------|
| L4 config, Sparta rules, geo | `l4.on_node` / `l4.custom_rules_max` / `l4.geo_block` |
| L7 Guard, rate limit | `l7.rate_limit` |
| WAF custom rules | `l7.waf.custom_rules_max` |
| Bot settings | `l7.bot` |
| Custom certificates | `l7.certs.custom` |
| AI auto-apply | `l7.ai.mode == auto` |
| Service control (start Sparta/Athens) | `node.sparta` / `node.athens` |
| Log export / download | `logs.export` |
| New site placement on private node | `node.athens`, `node.sites_included` |

Error responses:

| HTTP | Code | When |
|------|------|------|
| 402 | `entitlement_required` | Feature not in any active line item |
| 409 | `cap_reached` | Count would exceed resolved cap (`{"cap":25,"current":25}`) |
| 423 | `license_suspended` | State is suspended/expired for a write |
| 403 | `license_revoked` | Revoked |

---

## 12. Trust model and keys

### 12.1 Key hierarchy

| Key | Location | Use |
|-----|----------|-----|
| Root Ed25519 private | Offline operator vault | Signs signing-key certificates only |
| Root Ed25519 public | **Compiled into the Angelos binary** | Verifies signing-key certificates |
| Signing Ed25519 private (`kid`) | License signer service only | Signs bundles; rotated every 90 days, 14-day overlap |

Nothing shipped next to a license is ever trusted as a key. This closes D1.

### 12.2 Signing-key certificate

```json
{ "kid": "sk-2026-11", "pub": "<base64 ed25519 pub>", "nbf": 1762700000, "exp": 1770500000,
  "root_sig": "<base64 ed25519 signature by root over canonical JSON of the fields above>" }
```

### 12.3 Roles of services

- **Panel API (Go)** owns the commercial model, `Entitled()`, and compiles bundle JSON. It holds **no private keys**.
- **License signer** (this repository, replacing per-machine RSA generation) exposes `POST /sign_bundle`, reachable only from the panel host (mTLS or allowlisted IP + shared token). It validates structure, sets `kid`, signs, logs `(node_id, serial, sha256)`.
- **Angelos** verifies and projects bundles; it never contacts the signer.

### 12.4 Clock safety (closes D2)

- Every bundle carries server `iat`.
- Angelos persists `max_seen_iat`. Effective time = `max(local_now, max_seen_iat)`. If local time is more than 10 minutes behind `max_seen_iat`, Angelos reports `report_license data=clock_rollback`.
- Commercial expiry is decided by the panel (line-item state), not by local math. The bundle only carries its own short validity.

### 12.5 Key compromise

- Signing key: mark `revoked_at` in `signing_keys`, issue a new `kid`, every new bundle carries `revoked_kids`; Angelos rejects bundles signed by those kids.
- Root key: requires an Angelos release with a new embedded root; avoid by keeping the root offline.

---

## 13. Entitlement bundles

One bundle per node, recompiled whenever any input changes (line item state, assignment, placement, override, allow-set version, key rotation).

### 13.1 Envelope

```json
{
  "v": 1,
  "kid": "sk-2026-11",
  "cert": { "...signing-key certificate (§12.2)..." },
  "payload": "<base64 canonical JSON>",
  "sig": "<base64 ed25519(payload bytes)>"
}
```

### 13.2 Payload

```json
{
  "node_id": 31,
  "node_kind": "private",
  "tenant_id": 42,
  "hw_fp": "sha256:…",
  "serial": 1187,
  "iat": 1762740000,
  "nbf": 1762740000,
  "exp": 1763344800,
  "revoked_kids": [],
  "node": {
    "state": "active",
    "level": "full",
    "components": { "sparta": true, "athens": true },
    "capacity_tier": "40g",
    "commercial_exp": 1794276000
  },
  "l4": {
    "protected_ips": ["203.0.113.10"],
    "custom_rules_max": 50,
    "geo_block": true,
    "origin_lock": {
      "enabled": true,
      "ports": [80, 443],
      "allow_set": "dorian_edges",
      "allow_set_ver": 14,
      "cidrs": ["198.18.0.0/24", "198.18.1.0/24"]
    }
  },
  "sites": [
    { "site_id": 9, "host": "shop.example.com", "state": "active", "level": "full",
      "f": { "waf": "full", "rl": "full", "bot": "basic", "certs": true } }
  ]
}
```

Rules:

- `exp` = `iat + 7 days` for online nodes; `iat + 30..90 days` for offline nodes (§14.4).
- Platform node bundles: `tenant_id = 0`, `node.components` always both, `sites` contains **only sites placed on that node**, from all tenants.
- Private node bundles contain only the owning tenant's objects.
- Canonical JSON: UTF-8, sorted keys, no insignificant whitespace; the signature covers the exact `payload` bytes.

### 13.3 Angelos verification order

1. `cert.root_sig` valid under embedded root; `cert` within `nbf..exp`; `kid` not in stored or incoming `revoked_kids`.
2. `sig` valid over `payload` bytes with `cert.pub`.
3. `node_id` matches local registration; `hw_fp` matches local fingerprint (2-of-3 rule, §15.1).
4. `serial` > stored highest serial.
5. Effective time (§12.4) within `nbf..exp`.
6. Persist bundle, serial and `max_seen_iat` atomically.
7. Project: Sparta maps (protected IPs, rule caps, origin-lock allowlist, base vs full ruleset) and Athens shared dict `ent:{site_id}`; start or stop components per `node.components` and `node.level`.

Any failure: keep the last valid bundle, report via `report_license`.

### 13.4 Grace when no fresh bundle

| Condition | Behaviour |
|-----------|-----------|
| Last bundle within `exp` | Full behaviour from that bundle |
| `exp` passed, ≤ 7 days | Same, `bundle_stale` reported each poll |
| `exp` passed, > 7 days | Private node: `base` level (traffic continues). Platform node: unchanged (Dorian-operated). |

---

## 14. Bundle delivery protocol

### 14.1 Request

`POST /api/v1/edge/bundle` (existing edge token auth + HMAC `X-Dorian-Signature`)

```json
{ "node_id": 31, "hw_fp": { "machine_id": "…", "product_uuid": "…", "mac": "…" },
  "serial_seen": 1186, "max_seen_iat": 1762739700, "nonce": "<128-bit random>",
  "angelos_version": "2.4.0", "link_speed_mbps": 40000 }
```

### 14.2 Response

- `200` with the bundle envelope when `serial_seen` < current serial.
- `304` when up to date.
- `409 fingerprint_mismatch` / `409 clone_suspected` with no bundle.

### 14.3 Cadence

- Poll every 5 minutes (aligned with `report_edge_configure`).
- Immediate wake through the existing edge pub/sub channel when the node's bundle is recompiled.

### 14.4 Offline nodes

- Node flagged `offline=true` by an operator.
- Panel Nodes tab offers **Download bundle** (30–90 day `exp`).
- Angelos `import-bundle <file>` verifies like §13.3.
- Renewal is manual; the panel shows days remaining.

### 14.5 Heartbeat effects in the panel (closes D5)

Each request writes `node_heartbeats`. The panel updates `nodes.license_status` from heartbeats and `report_license` events: `ok | bundle_stale | fingerprint_mismatch | clock_rollback | clone_suspected | legacy`. These are visible in the Nodes tab and as security events.

---

## 15. Anti-abuse

### 15.1 Hardware fingerprint

`hw_fp` factors: `/etc/machine-id`, DMI `product_uuid`, primary NIC MAC. At least 2 of 3 must match the activation. On a 2-of-3 match the panel updates the stored third factor. On a mismatch, renewal is refused and the node shows `fingerprint_mismatch`.

### 15.2 Clone detection

The same activation polled from two different `hw_fp` values or source IPs within one 5-minute window leads to these steps:

- Renewal is frozen for that activation.
- The operator is alerted.
- Both machines keep their last bundle until §13.4 grace runs out.

### 15.3 Replay

The monotonic `serial` and `max_seen_iat` make old bundles useless. Request `nonce` values are kept 10 minutes to reject replayed requests.

### 15.4 Trial abuse

The limits in §9.2 apply per tenant. Trial sign-ups also need a verified email. A new trial that matches an existing tenant's payment fingerprint or `hw_fp` is refused.

### 15.5 Private nodes in the platform pool

A private node is never placed in platform pools. The compiler refuses to put another tenant's site in a private node bundle.

---

## 16. Metric and event attribution

| Data | Private node | Platform node |
|------|--------------|---------------|
| NIC throughput, host CPU/RAM | Tenant, labelled "Node health" | Operator only |
| L4 attack series | Tenant (own protected IPs) | Tenant only for dedicated-IP objects (`L4-PROXY`, `L4-NET`); shared-IP floods operator only |
| L7 requests, WAF hits, access logs | Tenant per site | Tenant per site |
| Security events | Tagged `tenant_id`, `object_id`, `layer` | Same; shared-IP L4 events operator only |
| Attack console "host at peak" | Tenant | Operator only |

Schema additions: add `tenant_id` and `object_id` to `security_events` and `l7_attacks`. L4 stats ingestion maps destination IP to object to tenant.

UI consequences:

- Analytics nav shows L4 Traffic and DDoS only if the viewer has any L4 entitlement. It shows Firewall, WAF and L7 Traffic only if the viewer has any L7 entitlement.
- Overview KPIs only include entitled layers. A tenant with L7 only never sees mixed L4 data.

---

## 17. Hybrid: ORIGIN-LOCK

Scenario: the customer runs Sparta (`NODE-L4`) on their origin and Dorian serves L7 on the platform (`SITE-*`).

1. `objects.origin_node_id` links the site to the customer's private node.
2. The control plane keeps the `allow_sets` row `dorian_edges` (platform edge egress IPs) with a `version`. Any platform fleet change bumps the version and recompiles every bundle that has origin lock.
3. The private node bundle carries `l4.origin_lock` (§13.2). Sparta then accepts only `dorian_edges` on those ports and leaves other ports untouched.
4. `ORIGIN-LOCK` costs nothing when the tenant has `NODE-L4` and any `SITE-*`.
5. The onboarding checklist in the panel covers these steps:
   - DNS has moved to Dorian.
   - The origin IP has rotated. The panel warns if the origin IP appeared in public DNS before onboarding.
   - Uplink notice: on-node XDP cannot absorb a flood larger than the link.
6. The Nodes tab shows a badge: `Origin of: shop.example.com, …`.

---

## 18. Data model (DDL)

MySQL, in the `cdnproxy` database (panel). The signer keeps only its own sign log.

```sql
CREATE TABLE tenants (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  name VARCHAR(190) NOT NULL,
  parent_tenant_id BIGINT NULL,
  status ENUM('active','closed') NOT NULL DEFAULT 'active',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE tenant_members (
  tenant_id BIGINT NOT NULL,
  user_id BIGINT NOT NULL,
  role ENUM('tenant_admin','tenant_member','reseller_admin') NOT NULL,
  PRIMARY KEY (tenant_id, user_id)
);

CREATE TABLE skus (
  code VARCHAR(40) PRIMARY KEY,
  object_type ENUM('node','site','ip','port_app','prefix','link') NOT NULL,
  is_addon TINYINT(1) NOT NULL DEFAULT 0,
  features JSON NOT NULL,
  trial_days INT NOT NULL DEFAULT 0,
  active TINYINT(1) NOT NULL DEFAULT 1
);

CREATE TABLE packages (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  code VARCHAR(40) UNIQUE NOT NULL,
  name VARCHAR(120) NOT NULL,
  price_cents INT NOT NULL,
  period ENUM('month','year') NOT NULL
);

CREATE TABLE package_skus (
  package_id BIGINT NOT NULL,
  sku_code VARCHAR(40) NOT NULL,
  quantity INT NOT NULL,
  PRIMARY KEY (package_id, sku_code)
);

CREATE TABLE subscriptions (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  tenant_id BIGINT NOT NULL,
  package_id BIGINT NULL,
  current_period_start DATETIME NOT NULL,
  current_period_end DATETIME NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX (tenant_id)
);

CREATE TABLE line_items (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  subscription_id BIGINT NOT NULL,
  sku_code VARCHAR(40) NOT NULL,
  quantity INT NOT NULL DEFAULT 1,
  options JSON NULL,                      -- e.g. {"capacity_tier":"40g"}
  state ENUM('trial','active','past_due','suspended','expired','revoked') NOT NULL,
  state_since DATETIME NOT NULL,
  trial_ends_at DATETIME NULL,
  parent_line_item_id BIGINT NULL,        -- reseller pool
  INDEX (subscription_id), INDEX (state)
);

CREATE TABLE nodes (
  id BIGINT PRIMARY KEY,                  -- = servers.id
  kind ENUM('platform','private') NOT NULL,
  tenant_id BIGINT NULL,                  -- NULL for platform
  offline TINYINT(1) NOT NULL DEFAULT 0,
  license_status VARCHAR(32) NOT NULL DEFAULT 'legacy',
  last_link_speed_mbps INT NULL
);

CREATE TABLE activations (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  line_item_id BIGINT NOT NULL,
  node_id BIGINT NOT NULL,
  fp_machine_id VARCHAR(128) NOT NULL,
  fp_product_uuid VARCHAR(64) NULL,
  fp_mac VARCHAR(32) NULL,
  activated_at DATETIME NOT NULL,
  revoked_at DATETIME NULL,
  INDEX (node_id), INDEX (line_item_id)
);

CREATE TABLE objects (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  tenant_id BIGINT NOT NULL,
  type ENUM('site','ip','port_app','prefix') NOT NULL,
  ref VARCHAR(255) NOT NULL,              -- hostname / ip / ip:port / cidr
  site_id BIGINT NULL,                    -- = sites.id when type=site
  origin_node_id BIGINT NULL,
  UNIQUE KEY (type, ref)
);

CREATE TABLE placements (
  object_id BIGINT NOT NULL,
  node_id BIGINT NOT NULL,
  PRIMARY KEY (object_id, node_id)
);

CREATE TABLE assignments (
  line_item_id BIGINT NOT NULL,
  object_id BIGINT NOT NULL,
  PRIMARY KEY (line_item_id, object_id)
);

CREATE TABLE bundle_serials (
  node_id BIGINT PRIMARY KEY,
  serial BIGINT NOT NULL,
  payload_sha256 CHAR(64) NOT NULL,
  compiled_at DATETIME NOT NULL
);

CREATE TABLE license_events (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  line_item_id BIGINT NOT NULL,
  event VARCHAR(32) NOT NULL,
  from_state VARCHAR(16) NOT NULL,
  to_state VARCHAR(16) NOT NULL,
  actor VARCHAR(120) NOT NULL,
  reason VARCHAR(255) NULL,
  at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX (line_item_id)
);

CREATE TABLE feature_overrides (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  tenant_id BIGINT NOT NULL,
  object_id BIGINT NULL,
  node_id BIGINT NULL,
  feature VARCHAR(64) NOT NULL,
  value JSON NOT NULL,
  reason VARCHAR(255) NOT NULL,
  expires_at DATETIME NULL
);

CREATE TABLE usage_records (
  tenant_id BIGINT NOT NULL,
  object_id BIGINT NOT NULL,
  metric ENUM('requests','egress_bytes') NOT NULL,
  period_start DATE NOT NULL,
  quantity BIGINT NOT NULL,
  PRIMARY KEY (tenant_id, object_id, metric, period_start)
);

CREATE TABLE signing_keys (
  kid VARCHAR(40) PRIMARY KEY,
  pub VARCHAR(64) NOT NULL,
  nbf DATETIME NOT NULL,
  exp DATETIME NOT NULL,
  revoked_at DATETIME NULL
);

CREATE TABLE node_heartbeats (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  node_id BIGINT NOT NULL,
  fp_hash CHAR(64) NOT NULL,
  src_ip VARCHAR(45) NOT NULL,
  nonce CHAR(32) NOT NULL,
  serial_seen BIGINT NOT NULL,
  at DATETIME NOT NULL,
  INDEX (node_id, at)
);

CREATE TABLE allow_sets (
  name VARCHAR(40) PRIMARY KEY,
  version INT NOT NULL,
  cidrs JSON NOT NULL,
  updated_at DATETIME NOT NULL
);
```

Mapping from existing tables:

| Existing | New |
|----------|-----|
| `servers` | `nodes` (same id) |
| `servers.license_type`, `expired`, `license_file` | `line_items` + `activations`; read-only until cutover |
| `sites` | `objects(type='site', site_id)` |
| `site_servers` | `placements` |
| `license_plans` | Price seed for `packages` |
| `users.role` | `tenant_members` + `platform_operator` flag |
| `lic.license` (signer DB) | Legacy fingerprints only |

---

## 19. API surface

### Tenant

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/v1/entitlements/effective` | Capabilities for the viewer (drives UI) |
| GET | `/api/v1/licensing/subscriptions` | Subscriptions and line items with state |
| GET | `/api/v1/licensing/nodes` | Private nodes, activation, `license_status`, heartbeat |
| POST | `/api/v1/licensing/nodes/{id}/transfer` | Hardware replacement (§9.5) |
| GET | `/api/v1/licensing/nodes/{id}/offline-bundle` | Offline bundle download |
| GET | `/api/v1/licensing/objects` | Protected objects, coverage, placements, origin link |
| POST | `/api/v1/licensing/assignments` | Assign a line item to an object |
| DELETE | `/api/v1/licensing/assignments` | Unassign |
| POST | `/api/v1/licensing/trials` | Start a trial for a SKU |

`/entitlements/effective` response:

```json
{ "tenantId": 42,
  "layers": { "l4": true, "l7": true },
  "nodes": [ { "id": 31, "kind": "private", "components": ["sparta","athens"],
               "state": "past_due", "level": "full", "licenseStatus": "ok",
               "warnings": ["Payment overdue; suspension on 2026-11-17"] } ],
  "objects": [ { "id": 9, "type": "site", "ref": "shop.example.com", "state": "active",
                 "features": { "l7.waf.managed": "full", "l7.waf.custom_rules_max": 25,
                               "analytics.retention_days": 7, "logs.export": true },
                 "usage": { "l7.waf.custom_rules_max": 12 } } ] }
```

### Operator

| Method | Path | Purpose |
|--------|------|---------|
| GET/PUT | `/api/v1/admin/skus` | SKU catalog and feature JSON |
| GET/PUT | `/api/v1/admin/packages` | Packages and prices |
| POST | `/api/v1/admin/line-items/{id}/payment` | Record payment, extend period |
| POST | `/api/v1/admin/line-items/{id}/revoke` | Revoke |
| POST | `/api/v1/admin/line-items/{id}/reinstate` | Reinstate |
| CRUD | `/api/v1/admin/overrides` | Feature overrides |
| GET | `/api/v1/admin/license-alerts` | Clone, mismatch, rollback, stale |

### Edge

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/v1/edge/bundle` | Bundle poll (§14) |

### Signer (internal, this repository)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/sign_bundle` | `{node_id, serial, payload}` → envelope |
| GET | `/signing_keys` | Current public certs |

---

## 20. Panel UI rules

- Navigation, analytics sections and configure-edge tabs are built **only** from `/entitlements/effective`. No front-end license math.
- Caps are shown inline, for example "12 / 25 custom rules". When a write is blocked, the panel names the required feature and the SKU that grants it.
- The panel shows a banner for each state:
  - past_due shows the date suspension starts.
  - suspended shows "configuration frozen".
  - expired shows "base protection only".
- The Licensing page has three tabs: **Subscriptions**, **Nodes** and **Protected objects**.
- The operator console has these tools:
  - SKU and package editor
  - Payments, revoke and reinstate
  - Overrides
  - License alerts
- Only operators create platform nodes. The "Add edge" flow for tenants always creates a private node and asks for a `NODE-*` line item.

---

## 21. Scenarios (acceptance list)

| ID | Setup | SKUs | Expected |
|----|-------|------|----------|
| A | Website on the Dorian platform | `SITE-pro` | Athens on platform serves site with Pro features; tenant sees L7 analytics only |
| B | Own server, L4 only | `NODE-L4` | Sparta on node protects tenant IPs; no L7 surfaces |
| C | Own L4 + Dorian L7 | `NODE-L4` + `SITE-business` + `ORIGIN-LOCK` | Origin accepts web ports only from `dorian_edges`; both layers visible, attributed |
| D | Private CDN | `NODE-L7` ×N | Athens on tenant nodes, only tenant sites; node health shown |
| E | Platform failover for private CDN | `NODE-L7` + `SITE-*` placed on platform too | Same site entitlement at both locations |
| F | Mixed placement | `SITE-*` placed on private + platform | One object, two placements, one line item |
| G | Game server | `L4-PROXY` | Dedicated edge IP, tenant sees L4 for that IP only |
| H | Game server with own Sparta | `L4-PROXY` + `NODE-L4` | Proxy plus on-node rules; origin lock to proxy IPs |
| I | Prefix scrubbing | `L4-NET` | Future |
| J | Reseller | Pooled `SITE-*` ×100 | Child tenants consume pool; isolation enforced |
| K | Trial | any SKU in `trial` | Full features, timer, trial limits |
| L | Downgrade | Business to Pro | Over-limit flow §9.4 |
| M | Hardware replacement | `NODE-*` transfer | §9.5 |
| N | Air-gapped node | `NODE-*`, offline | File bundle §14.4 |
| O | Customer node in platform pool | n/a | Refused by compiler §15.5 |

---

## 22. Migration from legacy licenses

1. **Schema and tenancy.**
   - Create the tables and one default tenant.
   - Current `Admin` users become `platform_operator` and `tenant_admin` of the default tenant.
   - Current `User` users become `tenant_member`.
   - Every existing server becomes `nodes.kind='private'` under the default tenant. Operators then reclassify Dorian-owned edges as `platform`.
2. **Line items.**

   | Legacy | New |
   |--------|-----|
   | `L4` | `NODE-L4` active |
   | `L7` | `NODE-L7` active, plus `SITE-pro` for each placed site |
   | `Unified` / Professional / Enterprise | `NODE-FULL`, plus `SITE-business` for each placed site |
   | `Trial` | Same as Unified with `state='trial'` and `trial_ends_at = servers.expired` |

   `current_period_end = servers.expired`. Activation fingerprints are seeded from `lic.license.machine_id` and completed on the first heartbeat.
3. **Shim.** Until bundles ship, `Entitled()` reads node features from `servers.license_type`. This lets API gating and `/entitlements/effective` go live first.
4. **Dual-run.** A bundle-capable Angelos prefers a valid bundle. If it has none, it falls back to the legacy license file and the node shows `license_status='legacy'`.
5. **Cutover.** 90 days after the bundle-capable Angelos release, legacy license files are no longer accepted. Nodes without a bundle drop to `expired` behaviour: base ruleset, and serving continues.
6. **Signer change.**
   - `/create_server` stops generating per-machine RSA keypairs and licenses.
   - `deploy_license` keeps install and upgrade, and adds `/sign_bundle`.
   - `mklicense` and `parse_license` stay only for reading legacy licenses.

---

## 23. Rollout phases

| Phase | Delivers | Closes |
|-------|----------|--------|
| 1 | `Entitled()` shim, API write gating, `/entitlements/effective`, layer-scoped nav and analytics | D4, mixed L4/L7 UI |
| 2 | Tenancy, data model, Licensing tabs, operator console, lifecycle tick with manual billing | D5, D6 |
| 3 | Root and signing keys, signer `/sign_bundle`, bundle compiler, `/edge/bundle`, Angelos verify, heartbeats, Sparta/Athens projection, dual-run | D1, D2, D3 |
| 4 | Platform nodes with multi-tenant site bundles, attribution, ORIGIN-LOCK, `L4-PROXY` | D7; scenarios A, C, E, F, G, H |
| 5 | Legacy cutover, reseller pools, offline bundles | Scenarios J, N |

---

## 24. Glossary

| Term | Meaning |
|------|---------|
| Activation | A node SKU line item bound to one machine fingerprint |
| Allow set | Versioned CIDR list (e.g. `dorian_edges`) pushed to Sparta |
| Bundle | Signed, per-node entitlement document |
| Effective time | `max(local clock, max_seen_iat)` on the edge |
| Line item | One purchased SKU with quantity and lifecycle state |
| Object | Protected thing: site, IP, port_app, prefix |
| Placement | Object served at a node |
| Platform node | Dorian-operated, multi-tenant edge |
| Private node | Customer machine running licensed Dorian software |
| Serial | Monotonic per-node bundle counter |
