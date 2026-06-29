# Cluster CP-Introduction — Implementation Plan (core 2.1)

> **One root↔CP bind enrolls a whole cluster; the CP then introduces child
> components across clusters with zero per-child ceremony and zero application
> logic.** This plan covers ONLY the shared mufl core change plus a release-notes
> directory architecture. Integration (MCP daemon, control-plane/messenger),
> release-note prose, and architecture docs are explicitly LATER phases.

---

## 0. Scope of THIS task

**IN**
1. Core mufl protocol code changes in `ours-mufl-core` (this repo): `a2a_messaging.mm`, `a2a_protocol.mm` (only if a struct/verifier gap is found), `version.mm` bump.
2. A **release-notes directory architecture** — one note file per core version (version defined in `version.mm`), plus the 2.1 entry stub.

**OUT (do NOT touch in this task — later phases, in order)**
- MCP daemon integration (`ours-mcp/packages/core` — orchestration: relay subagent ADs at root-bind, push `root_cp_binding` to roles, `get_manifest` pre-check, call `introduce`).
- Control-plane / messenger integration & UX.
- Release-note **prose** write-up (the architecture sets up the structure; the full narrative is the next round).
- Architecture documentation.
- Recursive delegation (N-level tree). **Parked by decision.**

**Branch & merge discipline:** implement on `feat/cluster-introduction` (do NOT push to `main`). This change **promotes the deferred governance-attestation layer to an *enforcing* role** — merging to main is gated on **founder approval** (see §9).

---

## 1. Context — what already exists (core 2.0, `62afceb` on main)

- **`core.connect` introductions** (`a2a_messaging.mm`): `introduce(peer_a,peer_b)` (L719), `introduce_to_group(joiner,members)` (L741), node-side `ingest_connect_descriptor` (L821→`handle_ingest_connect_descriptor` L776). These are **root-agnostic** — they only need `peer_ads` for both parties.
- **Two gates an introduction must pass today:**
  - CP-side: CP holds `peer_ads[child]` — written ONLY at contact establishment (`add_contact` L319, `accept_contact` L908, `ingest_connect_descriptor`, `import_core_state`). No other writer.
  - Receiver-side: `ingest` calls `require_bound_cp_or_abort(sender)` (def L213, call L782) → **demands the child's OWN `monitoring_proxy == sender`**. Only the 6-digit `verify_proxy_code` (L541) sets `monitoring_proxy` (L590). **This is what forces a per-child bind today.**
- **Identity hierarchy (flat, 2-level):** `delegation_cert_t` (a2a_protocol L43) binds `role_cid → root_cid`, root-signed; `verify_peer_delegation` (L121) checks one link. Node-local hierarchy state in `a2a_messaging`: `delegation_cert` (L74), `root_ad` (L77), `root_profile` (L79), `root_cp_binding` (L83), `contact_cp_bindings` (L89), `contact_roots` (L85).
- **Governance-attestation substrate (built, currently NON-enforcing / off critical path):**
  - `root_cp_binding_t` + `verify_root_cp_binding` (a2a_protocol L~205/212): root self-signs `{context_tag, root_cid, cid_cp}` = "root Y designated CP X". Domain-separated, root-key-verified. **The linchpin.**
  - `cp_attestation_t` + `verify_cp_attestation` (L~175/187): reciprocal CP→root half ("CP X manages root Y").
  - `root_cp_binding` is already **threaded into `accept_contact`'s reply** (L988) and **restored on import** (L1026) — but there is **no `set_root_cp_binding` transaction** to write it (only referenced in the comment at L81). **This gap must be filled.**

---

## 2. Goal / end-state (user-confirmed model)

1. Protocol lets any node define child components and register itself as a **root** (already true).
2. The **root delegates its CP binding to its children** — root binds the CP once, producing a root-signed `root_cp_binding`, and that binding (+ the root's keys) is pushed down to each child. The child binds nothing itself; it **inherits** and can locally verify "a relay is from the CP my root designated".
3. Children get a CP **contact relationship**, established by the single root bind, both directions:
   - CP→child: root relays each child's signed AD to the CP (`enroll_delegated_node`); CP verifies the delegation chain and stores `peer_ads`.
   - child→CP: child accepts the CP's introduction relays via the inherited `root_cp_binding` gate, verified locally, no round-trip.
4. The CP **introduces child components of different roots** to each other (`introduce` / `introduce_to_group` — already root-agnostic). They then do fresh end-to-end DH; the CP never holds their channel keys.

**App logic required: still just the `core.connect` boolean.** Everything else is identity-hierarchy + control-plane material the daemon/host manages.

---

## 3. Architecture of the change

Two pieces, both reusing existing verifiers.

### Piece A — Enrollment (CP-side `peer_ads` population)
New inbound transaction on the CP: **`enroll_delegated_node`**. Payload: the child's signed AD + its `delegation_cert` + the root's `root_profile`.
- Run `verify_peer_delegation(role_cid, role_ad_hash, cert, root_profile)` → confirms the child chains to a root **this CP manages** (check against a new `managed_roots` set, populated when the root binds / via `cp_attestation`).
- On success: store `peer_ads[role]`, `contacts[role]`, `contact_roots[role]`.
- Idempotent; rejects a child whose root the CP does not manage.
- The root/daemon calls this once per child at root-bind time (public material it already holds via the delegation chain). **One bind conveys the cluster.**

### Piece B — Receiver gate (drop the per-child monitoring requirement)
Replace the gate in `ingest_connect_descriptor` (L782/786) with a new **additive** helper:

```
fn require_cluster_cp_or_abort(sender_id):
    # accept EITHER the legacy direct bind …
    if monitoring_proxy != NIL && sender_id == monitoring_proxy.proxy_cid: return
    # … OR a CP my ROOT designated (inherited, verified locally)
    abort unless root_cp_binding != NIL
              && sender_id == root_cp_binding.cid_cp
              && verify_root_cp_binding(root_cp_binding, root_cid, root_ad.key_list)
```

The role already holds `root_cp_binding` (→ `cid_cp`) and `root_ad` (→ root keys to verify it). **No network round-trip, no per-child ceremony.** Additive ⇒ the existing direct-bind path still works ⇒ non-breaking ⇒ MIN bump.

### Piece C — `set_root_cp_binding` transaction (fill the gap)
Add the host-fired transaction that writes node-local `root_cp_binding` (referenced at L81, not implemented). This is what the daemon calls on the root after it binds a CP; the binding then propagates to roles through the existing invite/state-push paths (L988, L1026). Confirm the role-spawn state push carries it (core side) — the actual daemon push is a later phase, but the **core transaction + state plumbing must exist now**.

### Out of core scope here (consumed later by the daemon)
`get_manifest` pre-check (refuse if either party lacks `core.connect`) and the actual call to `introduce` stay daemon-side (already core-ready).

### Open design decision — monitoring inheritance (DEFER unless approved)
The same root-CP edge could make **monitoring inherit** (root-bind ⇒ all roles' traffic copied to the CP) by pointing the forced-copy sink (`monitor_copy_actions`, self-gates on `monitoring_proxy` L187) at `root_cp_binding.cid_cp` when `monitoring_proxy` is NIL. **This changes the monitoring guarantee's semantics — a governance decision, not a default.** Keep it OUT of this task's code unless explicitly approved; note it in the 2.1 release note as a deliberate non-change.

---

## 4. Work breakdown (core mufl only)

| # | File | Change | Size |
|---|------|--------|------|
| 1 | `a2a_protocol.mm` | **Verify only** that `root_cp_binding_t`/`verify_root_cp_binding`, `delegation_cert_t`/`verify_peer_delegation`, `cp_attestation_t`/`verify_cp_attestation` are sufficient as-is. Extend ONLY if a field is missing (e.g. role_ad_hash availability for enroll). | XS (likely none) |
| 2 | `a2a_messaging.mm` | Add `managed_roots` CP-side set (roots this CP manages, populated from the root-bind / `cp_attestation`). | S |
| 3 | `a2a_messaging.mm` | Add **`set_root_cp_binding`** trn (host-fired) → writes node-local `root_cp_binding`; ensure it propagates to roles via existing invite/state-push (L988/L1026). | S |
| 4 | `a2a_messaging.mm` | Add **`enroll_delegated_node`** inbound (CP-side): `verify_peer_delegation` against `managed_roots`, store `peer_ads`/`contacts`/`contact_roots`. Idempotent. | M |
| 5 | `a2a_messaging.mm` | Add **`require_cluster_cp_or_abort`** helper (additive: direct bind OR inherited root-CP binding). | S |
| 6 | `a2a_messaging.mm` | Swap the gate in `handle_ingest_connect_descriptor` (L782/786) to call `require_cluster_cp_or_abort`. Keep the `self_supports(core.connect)` capability gate unchanged. | XS |
| 7 | `version.mm` | Bump `create_version 2 0` → `create_version 2 1` (additive MIN bump). | XS |
| 8 | (compile) | Compile clean against the ADAPT toolkit (`scripts/` per repo convention); no consumer wiring. | — |

**Security invariants to preserve (critic will enforce):**
- The capability gate (`self_supports(core.connect)`) stays — "I accept introductions" remains node-authoritative.
- `enroll_delegated_node` MUST reject a child whose root is not in `managed_roots` (no unsolicited enrollment).
- `require_cluster_cp_or_abort` MUST re-verify `root_cp_binding` against `root_ad` keys every call (never trust the stored `cid_cp` unverified).
- `process_address_document(peer_ad, TRUE)` self-signature re-check stays in `ingest` (proof-of-possession).
- Additive only — the legacy direct-bind introduction path must still pass.

---

## 5. Release-notes directory architecture

**Problem:** today a single `RELEASE_NOTES_core_config.md` at repo root covers a whole range (1.10→2.0). It doesn't scale per-version.

**Design:** a `release-notes/` directory, **one file per core version**, where the version is the `MAJ.MIN` from `version.mm`.

```
release-notes/
  README.md          # index + convention (see below)
  2.0.md             # core 2.0 — migrated from RELEASE_NOTES_core_config.md
                     #   (config/control-plane + B2 core.connect simplification)
  2.1.md             # core 2.1 — THIS change (cluster CP-introduction) — stub now,
                     #   prose filled in the next round
```

**Convention (documented in `release-notes/README.md`):**
- Filename = the core version string `MAJ.MIN.md`, matching `version::get_core_version`.
- Every MIN/MAJ bump in `version.mm` REQUIRES a matching `release-notes/<version>.md` in the same change (a reviewer checklist item).
- Each note starts with a header line stating the version, the bump type (MAJ breaking / MIN additive), and a one-line summary; then sections: *What shipped* · *New/changed transactions* · *Breaking changes* (if MAJ) · *Integration TODO for consumers* · *Security notes*.
- `README.md` carries a table of versions newest-first with one-line summaries.

**Migration (this task):**
- Create `release-notes/` + `README.md` (index + convention).
- Move `RELEASE_NOTES_core_config.md` content into `release-notes/2.0.md` (it is the 2.0 lineage record). Leave a one-line pointer or delete the old file (recorded in the 2.0 note). Do not lose content.
- Add `release-notes/2.1.md` as a **stub** with the header + transaction list from §4 and a "prose pending" marker (the full write-up is the next round, per the user).

> The release-notes architecture is part of THIS task; the full 2.1 prose is NOT (next round).

---

## 6. Work-done metrics (acceptance criteria)

**Code (core 2.1)**
- [ ] `version.mm` reports `2.1`; `get_version` round-trips it.
- [ ] `set_root_cp_binding`, `enroll_delegated_node`, `require_cluster_cp_or_abort` exist with the §3 signatures; `ingest` calls the new gate.
- [ ] `managed_roots` populated on root-bind; `enroll_delegated_node` rejects a child of an unmanaged root (negative test).
- [ ] Packet **compiles clean** against the toolkit, no consumer integration.
- [ ] **Additive proof:** the legacy path — a node that did its own 6-digit bind — still accepts an introduction (the OR-branch in `require_cluster_cp_or_abort`). Regression-covered.
- [ ] **New path proof (unit/runtime):** a role with an inherited `root_cp_binding` (and NO `monitoring_proxy`) accepts an introduction relayed by `root_cp_binding.cid_cp`, and **rejects** one relayed by any other sender. Forged/mismatched `root_cp_binding` (verify against wrong root keys) aborts.
- [ ] Capability gate intact: a role lacking `core.connect` in its live manifest still rejects ingest.

**Release-notes architecture**
- [ ] `release-notes/` exists with `README.md` (convention + version table), `2.0.md` (migrated, no content lost), `2.1.md` (stub).
- [ ] Convention documented: version bump ⇒ matching note file.

**Process**
- [ ] All on `feat/cluster-introduction`; **not** merged to main (founder gate).
- [ ] critic review GREEN against the §4 security invariants.

---

## 7. Test plan (core-level, no consumer)

1. **Compile** — clean build of the modified core packet.
2. **Version** — `get_version` returns 2.1.
3. **Enrollment** — CP with `managed_roots = {rootY}` accepts `enroll_delegated_node(childAd, cert→rootY, rootProfile)` → `peer_ads[child]` set; same with `cert→rootZ` (unmanaged) → abort. Tampered cert → abort.
4. **Inherited gate (positive)** — role with `root_cp_binding{cid_cp=CP}` + matching `root_ad`, `monitoring_proxy=NIL`: `ingest_connect_descriptor` from `CP` succeeds.
5. **Inherited gate (negative)** — same role, relay from a non-CP sender → abort; `root_cp_binding` verifying against wrong root keys → abort.
6. **Legacy gate (regression)** — role with `monitoring_proxy=CP`, no `root_cp_binding`: ingest from `CP` still succeeds.
7. **Capability gate** — role without `core.connect` in `describe()` → ingest aborts regardless of gate.

---

## 8. Milestones / sequencing

- **M1 — Protocol primitives:** items #1–#3, #5, #7 (structs check, `managed_roots`, `set_root_cp_binding`, gate helper, version bump). Compile.
- **M2 — Enrollment + gate swap:** items #4, #6. Compile + the §7 unit/runtime tests.
- **M3 — Release-notes architecture:** §5 (directory, migration, 2.1 stub).
- **M4 — critic review** against §4 invariants → GREEN.
- **Gate:** founder approval to promote the governance layer to enforcing → only then merge to main + (next rounds) release-note prose, architecture docs, MCP integration, control-plane.

---

## 9. Risks & open decisions

- **Founder approval (blocking for main):** this promotes the deferred governance-attestation layer (`cp_attestation`/`root_cp_binding`/invite-threading) from non-enforcing visibility to an **enforcing** authorization role gating introductions. Security is sound (root-signed, domain-separated, locally pinned via `root_ad`); residual trust (host honestly distributes `root_ad`/`root_cp_binding` to its roles) is the same honesty class as the existing monitoring self-assertion limit (README §8). The **promotion decision is the founder's** — implement on a branch, do not merge until signed off.
- **Monitoring inheritance (open):** in scope or not? Default OUT of this task's code; it is a governance-semantics change (root-bind ⇒ all roles monitored). Decide before M2 if it is to be bundled.
- **Recursion (parked):** flat 2-level only. The structs here (`role_cid→root_cid`) are not chain-walking; a future recursive-delegation change is separate and more invasive. Keep `enroll_delegated_node`/the gate written so a later chain-walk could slot in, but do not build it.
- **`role_ad_hash` availability:** confirm the enroll payload can supply the hash `verify_peer_delegation` needs (item #1) — extend `a2a_protocol` only if missing.

---

## 10. Handoff note for the fresh implementation sessions

- Bind identities per the existing team pattern (Coordinator + Developer + critic). Developer implements §4 on `feat/cluster-introduction`; critic reviews against §4 invariants + §6 metrics.
- The authoritative design rationale (verifier reuse, additive compat, sizing) came from the mufl-core dev; this plan encodes it. When in doubt on a verifier signature, read `a2a_protocol.mm` at the line anchors in §1 rather than guessing.
- Do **not** start MCP/control-plane work — those are later phases by explicit user instruction.
