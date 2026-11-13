# Edge-side work for order-driven licensing

Status: guidance for Angelos / Sparta / Athens teams  
Panel status: order model is live (see [LICENSE_LOGIC.md](LICENSE_LOGIC.md))  
Longer design: [LICENSE_LOGIC_FUTURE.md](LICENSE_LOGIC_FUTURE.md)

---

## 0. What already works without edge changes

Today the **panel + API** enforce licensing:

| Layer | Behaviour today |
|---|---|
| Control plane | Customers cannot create edges/sites outside orders (402). L4/L7 config and Sparta/Athens start-stop are gated by edge license kind. Expired / cancelled → config locked (423). |
| Deploy | On order approve / renew / L4 upgrade, the panel still asks the license server for a classic `license.lic` (`license_type` = `l4` / `l7` / `unified`, expiry = period end) and Angelos deploys it as today. |
| Edge runtime | Angelos, Sparta and Athens **do not yet know** about order licenses, cancel-at-period-end, or site licenses. They keep running with the last deployed license file and last config. |

So: **billing and panel gating are done**. Edge-side work is about making the host enforce the same rules when the panel is offline, and about the single-platform signing key.

---

## 1. Angelos (edge agent) — required / recommended

### 1.1 Near term (recommended for order model)

| # | Work | Why |
|---|---|---|
| A1 | **Honour `license_type` + expiry already on the license file** when deciding which components may run. | Panel already issues `l4` / `l7` / `unified` and updates expiry on renew. Angelos should refuse to start Sparta without L4/Unified, refuse Athens without L7/Unified, and refuse both when expired (or only allow “last config, no edits” if you want soft fail). |
| A2 | **On license expiry / cancel sync**, stop or freeze components instead of only reporting status. | Panel locks config but leaves services running. For real offboarding you need Angelos to: stop Sparta and/or Athens, or keep serving but reject config pushes that change rules/sites. Agree the policy with product (hard stop vs freeze). |
| A3 | **Report clearer license state** to the panel (`report_license` / deployment heartbeat): `active`, `past_due`, `expired`, `manipulated`, `clock_rollback` if not already complete. | Lets Licensing / alarms show edge truth, not only DB status. |
| A4 | **Single Dorian signing public key embedded in Angelos** (plan item `license-key`). | Today each deploy ships a per-machine `server_public_key.pem` from `generate_license.sh`. One platform key means: Angelos embeds the public key; license server signs with one private key; stop shipping per-machine public keys. **Must ship Angelos first**, then change the license server — otherwise old edges break. |
| A5 | **Dual-run / rollout** for A4. | New Angelos accepts both old per-machine key files and the embedded key for a grace period; after cutover, only embedded key. |

Out of scope for Angelos alone: site-level `SITE_OWN` / `SITE_PLATFORM` rows — those are panel concepts unless you adopt entitlement bundles (§2 future).

### 1.2 Later (entitlement bundles — future spec)

Only after the panel can compile and deliver signed bundles:

| # | Work |
|---|---|
| A6 | Verify Ed25519 signing-key certificate under an **embedded root**. |
| A7 | Verify bundle payload (`node_id`, `hw_fp`, serial, nbf/exp, revoked_kids). |
| A8 | Persist bundle + `max_seen_iat`; clock-rollback detection. |
| A9 | Project capabilities into Sparta maps and Athens `ent:{site_id}`; start/stop Sparta/Athens from `node.sparta` / `node.athens`. |
| A10 | `import-bundle` CLI + heartbeat that requests refresh; fall back to legacy `license.lic` during dual-run. |

Details: LICENSE_LOGIC_FUTURE.md §§12–14.

---

## 2. Sparta (L4 data plane) — required / recommended

Sparta should stay a **dumb enforcer**: it reads maps / config Angelos installs. Prefer putting policy in Angelos; Sparta only needs hooks.

### 2.1 Near term

| # | Work | Why |
|---|---|---|
| S1 | **Respect Angelos “base vs full” (or enabled/disabled) mode.** | When edge license is expired / cancelled / L7-only, Angelos should either unload Sparta or switch it to a base ruleset (default flood thresholds only, no custom lists/geo). Sparta needs a clear mode switch if you choose freeze-not-stop. |
| S2 | **Do not accept L4 config updates** when Angelos marks L4 as locked (optional if Angelos simply stops applying pushes). | Defence in depth if something bypasses the panel. |
| S3 | Keep reporting traffic / block metrics as today (`allows_l4` already gates what Angelos uploads). | No change required for order billing; only ensure Sparta is not running when the edge has no L4 license. |

### 2.2 Later (bundles)

| # | Work |
|---|---|
| S4 | Consume projected maps from Angelos: protected IPs, rule caps, geo on/off, **origin-lock allowlist** (`dorian_edges` CIDRs). |
| S5 | Soft capacity warning if link speed &gt; entitled `node.capacity_tier` (panel warning; Sparta may only report link speed). |

---

## 3. Athens (L7 data plane) — required / recommended

Same pattern: Angelos owns policy; Athens enforces local dict / config.

### 3.1 Near term

| # | Work | Why |
|---|---|---|
| T1 | **Only run when the edge license allows L7** (`l7` / `unified` / trial). | Aligns with panel: L7-only and Unified edges host sites; L4-only edges must not run Athens. |
| T2 | **On expired / cancelled edge license**: keep serving existing sites **or** go read-only — product choice. Do **not** accept new site pushes / WAF changes if frozen. | Matches panel “config locked, traffic may continue”. |
| T3 | **Multi-origin sites** are already a panel/order concern (each origin → upstream). Athens only needs to keep accepting the upstream list Angelos pushes (already supported). | No Athens change for multi-origin orders unless origin APIs are incomplete on older builds. |
| T4 | Platform edges: no customer-visible license file change; they keep serving all placed sites. Site entitlement (Free vs paid features) is **not** enforced on Athens until bundles. | OK for v2. |

### 3.2 Later (bundles)

| # | Work |
|---|---|
| T5 | Shared dict `ent:{site_id}` with tier features (WAF / rate limit / bot / custom certs). Missing key on platform → Free features + `ent_missing` log (fail-open). |
| T6 | Revoked site → Angelos removes site from config (do not rely on dict alone). |

---

## 4. Suggested implementation order

```
1. Agree freeze vs hard-stop on expiry/cancel          (product)
2. Angelos A1–A3  (component gate + report + freeze)   ← biggest gap vs panel
3. Sparta S1 (+ S2 if needed)
4. Athens T1–T2
5. Angelos A4–A5 + license-server single key           ← blocked plan item
6. Bundle pipeline (panel) then Angelos A6–A10,
   Sparta S4, Athens T5–T6                             ← future
```

---

## 5. Explicit non-goals for the edge right now

- Reading the panel `licenses` table or order APIs from the edge.
- Per-site billing enforcement on Athens without entitlement bundles.
- Refunds, payment gateway, or catalog changes (panel only).
- Changing how customers place orders (already shipped).

---

## 6. Contract reminders (unchanged)

- Panel → Angelos: existing deploy / L4 / L7 push APIs (`ANGELOS_API.md`).
- Angelos → Panel: `report_license`, `report_edge_metrics`, configure snapshot, attack reports.
- License server → deploy tarball still includes `license.lic` (+ today `server_public_key.pem` until A4).

When A4 lands, document the cutover in WORKFLOW.md and bump Angelos + license-server together.
