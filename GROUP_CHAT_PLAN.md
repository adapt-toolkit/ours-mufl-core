# GROUP_CHAT_PLAN — implementation plan, core 0.8.0

**Author:** Developer-6 · **Date:** 2026-07-12 · **Status:** PLAN — awaiting FleetCoordinator review + main-suite green before ANY implementation.
**Ports:** `GROUP_CHAT_DESIGN.md` (user-approved 2026-06-21, written against the old `core 3.0→3.1` ours-mcp-vendored lineage) onto **current `ours-mufl-core` main @ `a2c99c4`, version 0.7.1**, under the registry / COMPATIBILITY.md / mixed-unit-gate discipline the core has adopted since. **This is a PORT, not a redesign** — the design's model, decisions, wire shapes, security invariants, and test plan are carried verbatim; only the version numbering, the versioning-discipline wrapping, and the test-harness idioms change.

---

## 0. Scope (unchanged from the approved design — v1 rudimentary, no gold-plating)

ONE group, ONE creator/admin, no multi-admin, no succession. A group = a shared
`chat_id` + a creator-authoritative roster + the full mesh of mutual contacts it
induces; a message is a bare N-way `send_encrypted_tx` fan-out over the existing 1:1
encrypted channels — **no group key, no relay, no server SPOF**. Invite + explicit
accept, owner-only disclosure, one-by-one mesh wiring, admin remove + self-leave,
creator `delete_group` (cannot leave), epoch-based lost-message repair. Locked
decisions 1–8 (design §0) hold as-is. Deferred (design §15) stay deferred: admin
succession/co-admins, group key/forward secrecy, signed tombstones, role-delegated
members, anti-amplification hardening beyond the per-pair bounce note.

**Core-only.** This plan covers the shared mufl core change (`a2a_group.mm` + wire
shapes + monitoring + version + tests). Daemon/messenger/panel integration is a
SEPARATE later phase (Dev-2/Dev-3), not in this plan.

---

## 1. What changed since the design was written (the port deltas)

The design's mechanism is untouched — every primitive it builds on is present on
current main. The deltas are purely the numbering + the discipline wrapper:

1. **Version.** Design says `3.0 → 3.1 (MIN)`. On the renumbered 0.x line the
   equivalent MINOR bump is **`0.7.1 → 0.8.0`** (`version.mm`
   `create_version 0 8 0`). Additive feature = MINOR, exactly the design's intent.
2. **Versioned-type-registry discipline (NEW since the design).** Every wire-visible
   INBOUND surface now must have a registry entry in `a2a_versions.mm` (REG-1) +
   a row in COMPATIBILITY.md. The 11 group inbound surfaces are all **class-B NEW
   transactions** (design taxonomy = new inbound names), so each gets a
   **single-version registry entry** (`grp_*_v1_t` metadef + `$pv` discriminator +
   M1 `_typeof` domain guards + `try_narrow`/narrow), catalogued in COMPATIBILITY.md.
   This is the ONE structural addition the design predates — it makes the group
   payloads first-class in the registry instead of raw `safe`-casts, and gives them
   the abort-free / error-as-data safety net the incident work established.
3. **`wire_version` stays 7.** Group surfaces are NEW names reachable only by peers
   that speak them; they do NOT change any existing surface's shape, and (unlike
   receipts) they are not capability-gated on an existing path, so no dialect bump is
   warranted (bump rule: shape change on an existing surface). `$pv -> 7` is stamped
   on the new group `$targ`s like every other core-originated send. A pre-group peer
   simply never receives a group transaction (it was never invited); if one somehow
   arrives, the registry's error-as-data path applies.
4. **Compat gates (NEW since the design).** In addition to the design's 15-point
   loopback plan, the port must pass the standing `tests/mixed-unit.mjs` (old-unit ↔
   new-unit pairing zero-reject — the group unit is a new unit hash) and
   `tests/blob-import.mjs` (old-unit state imports on the group unit) discipline, and
   the golden-wire corpus gains the grp registry fixtures. This is the fix-3-lesson
   guardrail applied to the group unit-hash change.
5. **Line-number references.** The design cites `core 3.0` line numbers; the port
   targets current main. Verified anchors on `a2c99c4`: `resolve_contact`
   (a2a_messaging.mm:492), `monitor_copy_actions` (:321), `monitoring_copy_t` (:185),
   `receive_monitoring_copy_tx` (:51), `reply_ref_t` (a2a_protocol.mm:101), `contact_t`
   (:14), `send_encrypted_tx` / `is_container_registered` (encrypted_channel /
   key_storage). All present — no missing primitive.

Nothing else moves. The security §10, the flows §3–5, the state §7, the tx spec §8
port line-for-line.

---

## 2. Files touched (port of design §12, updated for current tree)

| # | File | Change | Size |
|---|------|--------|------|
| 1 | `a2a_protocol.mm` | Add `group_invite_t` metadef; document the `any` payload shapes (design §6) as comments beside it. | S |
| 2 | `a2a_versions.mm` | **NEW (port addition):** 11 single-version `grp_*` registry entries (metadef + `$pv` discriminator + M1 `_typeof` guard + `try_narrow`/`narrow`) for the group inbound surfaces. | M |
| 3 | `a2a_messaging.mm` | Add `monitor_group_copy_actions` (sibling of `monitor_copy_actions`:321, reads hidden `monitoring_proxy`); add optional `$chat_id` to `monitoring_copy_t` (:185, additive). | S |
| 4 | `a2a_group.mm` (NEW) | State (design §7: `group_t`, `groups`, `pending_group_invites`, `group_member_t`) + `init` (2 storage hooks) + tx-name consts + `_read_or_abort` wiring. | S |
| 5 | `a2a_group.mm` | User trns: `create_group` / `invite_to_group` / `respond_to_group_invite` / `send_group_message` / `remove_from_group` / `leave_group` / `delete_group` / `request_group_roster` + readonly `list_groups` / `get_group`. | L |
| 6 | `a2a_group.mm` | Inbound trns (11): invite / invite_response / member_add / roster_sync / member_remove / member_leave / delete / message / not_member / stale / roster_request — each narrowing through its registry entry. | L |
| 7 | `a2a_group.mm` | `export_group_state` / `import_group_state` (no secrets; peer_ads re-registered by the existing `import_core_state`). | S |
| 8 | `a2a_monitoring.mm` | Pass the optional `$chat_id` through `receive_monitoring_copy` to its hook (design §7 item 7). | XS |
| 9 | `config.mufl` | Export `a2a_group` (after `a2a_versions`/`a2a_capabilities`, before consumers that load it). | XS |
| 10 | `version.mm` | `create_version 0 7 1` → `create_version 0 8 0`. | XS |
| 11 | `COMPATIBILITY.md` | Registry-index rows for the 11 grp surfaces; a "Group chat (0.8.0)" section (model, admin authority, epoch-advisory, the never-crash/error-as-data note); PR-checklist tick. | S |
| 12 | `docs/how-it-works/` | Short `group-chat.md` (or a section) — the mesh model + `$pv`/registry note. | S |
| 13 | `tests/test_actor.mu` + `tests/test.mjs` | Load `a2a_group`, wire the 2 group hooks + `qa_*` probes; the 15-point G-series (design §13). | L |
| 14 | `tests/` corpus + mixed-unit + blob-import | grp corpus fixtures; group unit through the mixed-unit + blob-import gates. | M |

---

## 3. Registry treatment of the group surfaces (the port's one real design addition)

Each of the 11 group inbound `$targ`s gets a single-version registry entry in
`a2a_versions.mm`, following the rmsg/rfil/rcp precedent exactly:

```mufl
// e.g. group_message:
metadef grp_msg_v1_t: (
    $chat_id  -> global_id,
    $epoch    -> int,
    $text     -> str,
    $wire_id  -> str+,
    $reply_to -> any,          // reply_ref_t+, tolerant
    $pv       -> int+
).
metadef grp_msg_t: grp_msg_v1_t.
fn grp_msg_version_of (raw: any) -> int { pv = peer_pv raw. return (pv != 0 ?? pv ; 7). }
fn grp_msg_shape_ok (raw: any) -> bool
{
    // M1 abort-free domain guards on the non-nullable fields:
    return is_str (raw $chat_id) && is_int (raw $epoch) && is_str (raw $text).
}
// try_narrow_grp_msg → ($ok, $payload, $err) error-as-data on shape/floor miss;
// narrow_grp_msg → strict form.
```

The `group_invite_t` fixed metadef (design §6) lives in `a2a_protocol.mm` as designed;
its registry entry (`grp_invite`) references it. The `$member_ad`/`$members[].ad`
fields stay `any` in the registry type and are verified downstream by
`process_address_document` (exactly as `sir_payload`'s `$ad` is) — the registry never
casts an AD. This keeps the design's "ADs travel whole, PoP-verified" property while
giving every group surface the abort-free classification + error-as-data the core now
requires. Handlers narrow first, then apply the design §4/§5 authority + repair gates.

---

## 4. Milestones (port of design §14, gated)

- **M0 — Shapes + registry + state + skeleton:** files #1, #2 (entries only), #4,
  #9, #10. Compile clean; `get_version` → 0.8.0; registry compiles. Gate: compile +
  corpus grp fixtures narrow correctly.
- **M1 — Membership formation:** create / invite / respond / admin-accept handler /
  member_add / roster_sync, through the registry narrows + the admin-pin authority
  (design §4) + PoP. Tests G2–G4, G6, G10.
- **M2 — Broadcast + storage + monitoring:** send/receive_group_message, the 2 hooks,
  `monitor_group_copy_actions` + `$chat_id` passthrough (#3, #8). Tests G5, G15.
- **M3 — Roster ops + repair:** remove / leave / delete + the repair inbounds
  (not_member / stale / roster_request) with the §5 gates. Tests G7–G9, G11–G13.
- **M4 — Export/import + docs + gates + critic:** #7, #11, #12, corpus + mixed-unit +
  blob-import green, full suite green. Test G14. Then the Critic adversarial pass
  against design §10 invariants.

Commit-often per milestone (Fable discipline); each milestone re-runs the growing
G-series + the standing suite so a break is caught at its milestone, not at the end.

---

## 5. Back-compat proof (the merge gate, port of the fix-3 discipline)

1. Full core suite green (T/R/N/V/RC + the new **G-series**, design §13's 15 points).
2. Golden-wire corpus green incl. the new grp fixtures (each registered group version
   narrows to its branch; below-floor/malformed → error-as-data).
3. **Mixed-unit matrix**: the group unit hash is new, so old-unit ↔ group-unit pairing
   / messaging / files must stay zero-reject (a pre-group peer never speaks group
   txns; the point is that adding the library + unit change does not break 1:1
   interop — the fix-3 guardrail).
4. **Old-unit blob import**: a pre-group state blob imports on the group unit intact
   (groups default empty; `import_group_state` guarded-absent).
5. Semantics pins unaffected.

**Invariants enforced (design §10, non-negotiable):** no `contacts`/`peer_ads` write
before `process_address_document(ad,TRUE)`; no roster mutation from `sender !=
admin_cid` (except sender-only self-assertions); a group op never deletes a contact;
`receive_group_message` mutates no group state before its §5 gate; group state carries
no secrets and round-trips losslessly.

---

## 6. Effort + sequencing

One focused core phase. Calibration off the receipts build (comparable shape: new
library + ~10 inbound txns + registry entries + a full loopback series + gates):
**~2–4 working sessions to green core**, MUFL-core TDD being legitimately slow (broker
boot + 100+ assertions/run). Low risk: additive class-B, zero existing-surface change,
zero cross-version exposure, every primitive already present. Panel integration is a
separate, larger phase owned by Dev-2/Dev-3 (group create/invite/accept UI, group
conversation view, the 2 storage hooks host-side, roster display) — explicitly out of
this plan.

**Branch:** `feat/group-chat` off main `a2c99c4`. **PR HELD** — no merge without the
owner's ours-relayed go, same gate as every core feature. PR #8 (sealed backup) is NOT
touched.

---

## 7. Open items to confirm during implementation (design §15 + port)

- **Role-delegated members** (design §15 last bullet): confirm at M1 whether to pin
  `contact_roots` opportunistically for a member that carries a delegation chain (the
  AD+chain ride like `accept_contact`); v1 default = treat members as flat identities.
- **Monitoring-copy `$chat_id` additivity**: verify `monitoring_copy_t` consumers
  (a2a_monitoring receiver + CP hook) tolerate the added nullable field (they read
  field-by-field — expected fine; confirm at M2).
- **config.mufl load order**: `a2a_group` loads `a2a_messaging`/`a2a_capabilities`/
  `a2a_protocol`/`a2a_versions`/`encrypted_channel`/`address_document(_types)`/
  `version`; place its export accordingly.
