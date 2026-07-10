# HANDOFF — feat/versioned-type-registry (Developer-6)

**Purpose:** in-branch handoff note so FleetCoordinator can resume a fresh agent from the last
commit if this one cuts out. REMOVE this file in the final commit before opening the PR.

**Mission:** MUFL backward-compat (versioned type registry) for core 0.5.0, per
`/home/fleet/.ours-fleet/state/protocol-compat/PLAN.md` (Steps 0-6) + SPEC.md, plus owner
Additions A (too-old ⇒ error-as-data, never a hard fail) and B (invite 2nd-phase from too-old
peer ⇒ clear inviter-facing error). Full running notes:
`/home/fleet/.ours-fleet/tmp/Developer-6/WORKLOG.md` (incl. settled A/B design, checkpoint 1 sent).

**Test command** (baseline green on main@635014a):
```
ADAPT_TOOLKIT=/home/fleet/.ours-fleet/tmp/Developer-6/toolkit \
OURS_SDK_NODE_MODULES=/home/fleet/ours.network/ours-mcp/node_modules \
DEV_BROKER=/home/fleet/ours.network/ours-mcp/scripts/dev-broker.mjs \
PORT=9811 tests/run.sh
```
(toolkit dir = symlinks into /home/fleet/.ours-fleet/tmp/Developer-1/adapt-shim)

**Status:** Steps done: 0 (review, baseline green), A/B design settled + reported.
Next: Step 1 — a2a_versions.mm (registry module) with semantics pins first (TDD).

**Plan of record (condensed):**
1. `a2a_versions.mm`: wire_version=5, min_wire_version=2, opt_* helpers, version_error_t,
   registries sir (v2/v3/v5) / cin (v2/v5) / rst (v2/v5) / acc (v2/v3) + single-version rcv
   entries; per-registry version_of / try_narrow (error-as-data) / narrow (aborting).
2. Handler rework: handle_submit_invite_response (registry gate + Additions A/B via
   _notify_agent $protocol_error), handle_accept_contact (acc), restore legs (rst),
   handle_complete_invite (cin); contact_pv passive learning.
3. Send side: $pv (+$caps on bundles) at every core-originated send; contact_pv/contact_caps
   state, additive export/import; a2a_capabilities::self_cap_ids (from init $supported — NOT
   describe, which aborts uninited); CAP-1 gate at notify client sends (deny only on positive
   evidence: non-empty caps lacking core.notifications; deny = error-as-data).
4. Tests: qa_send_legacy_invite_response (v2/v3/v5 + below-floor pv=1), golden-wire corpus
   fixtures + replay, mufl_semantics pins (t2/t7/t9/t11), A/B assertions (notify events,
   invite NOT consumed, no abort).
5. Docs: COMPATIBILITY.md, docs/how-it-works/versioning.md, version.mm -> 0.5.0.
6. PR (no merge — owner gate). No deploy.
