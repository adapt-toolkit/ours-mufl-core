# ours Generic Configuration / Control-Plane — Consolidated Plan

Author: ours-developer-1 · Reviewer: critic-1 · Relay: Coordinator-1 → human
Baseline: **core v1.10** (a2a_protocol, a2a_messaging, a2a_control, a2a_capabilities, version)
Status: PLANNING ONLY — no implementation. Converged with critic-1.

> Read-the-tree note: an earlier draft was written against a stale v1.2 snapshot.
> This plan is re-baselined against the **current** tree pulled by the human:
> most of the brief is **already built**. The valuable output is the **delta**.

---

## A. What the brief asks for that is ALREADY BUILT (do NOT redesign)

| Brief requirement | Status | Where (current core) |
|---|---|---|
| **1. App manifest** (name, description, optional config schema) | **DONE — richer than asked** | `a2a_capabilities::app_manifest_t` = `($version,$app_id,$name,$description,$monitoring_status,$capabilities)`; `get_manifest` readonly; `app_id` also auto-stamped on the `a2a_control` transport (1.5). The "config schema" is the `core.configuration` capability's opaque-JSON `$params`. |
| **3. Optional JSON config schema, rendered by frontend** | **MOSTLY DONE** | `core.configuration` capability: `$params` is opaque JSON (schema + value) a dumb frontend renders. Full **secret-field redaction**: `secret_field_t`, `$set/$unset/$needs_reentry` sentinels, **epoch auto-clear on CP evict/rebind** ("no new party inherits live secrets"). `contact_ref_connect` (`$connect`) sentinel = the **config↔connect hinge** the telegram connector needs. |
| Config "expose all to wrapper" path | **DONE** | Opaque `$params` + the verb-envelope dispatch (`control_envelope_t` = `$cap,$verb,$args,$req_id` → `dispatch` → app handler) IS "wrapper pushes app-specific config via transaction." |
| **2. Monitoring** — first-class, governance-visible | **PARTIAL** | `monitoring_status` is a first-class manifest field. Architecture decided (1.7): the cert layer was **scrapped**; monitoring is secured by the **proxy-bind ceremony + open-source + eviction**, node **self-asserts** `monitoring_status` (accepted limitation, README §8) — NOT crypto certs. |
| **4. Introduction** — supporting shapes | **DONE (core 2.0)** | Shipped as CP-relayed **peer-signed address documents** (`introduce`/`introduce_to_group` + node-side `ingest_connect_descriptor`); `cap_connect = "core.connect"` is the node-side accept gate; `$connect` config hinge. The earlier `connect_descriptor_t` + `verify_connect_descriptor` + `safety_number` (SAS) shapes were **removed in 2.0**. Plus governance (separate): `cp_attestation_t` (§3c, 1.8), `root_cp_binding_t` (1.9), threaded through invites + `accept_contact` (1.10) so peers **TOFU-pin** "root R is managed by CP X" (NON-enforcing visibility). |
| Identity hierarchy / delegation / TOFU governance edge | **DONE** | `delegation_cert_t`, `root_profile_t`, `verify_peer_delegation`, intra-root sibling auto-connect, `intro_t`/`signed_intro_t` registrar credential (out-of-repo local-book). |

## B. What is GENUINELY NET-NEW (the real work)

| # | Net-new item | Brief pt | Lives in |
|---|---|---|---|
| **B1** | **`a2a_monitoring` library** — referenced by `a2a_capabilities` but **does not exist**. The 6-digit proxy-bind ceremony, `monitoring_proxy` state, and the **FORCED fire-and-forget re-encrypted copy path**. | 2 | new `a2a_monitoring.mm` + a chokepoint in `a2a_messaging` |
| **B2** | **`core.connect` brokering FLOW** (shipped core 2.0, simplified): CP-side `introduce`/`introduce_to_group` relay each node the other's **peer-signed address document**; node-side `ingest_connect_descriptor` gates on bound-CP + own `core.connect` manifest, verifies the AD self-sig, registers. **This is the introduction problem** — solved without SAS / connect-descriptor / CP-signed intro. | 4 | `a2a_messaging` (CP + node txns) + `a2a_capabilities::self_supports` |
| **B3** | **`set_app_config` + typed protocol-policy txns** — store opaque config blob (CP-gated) + fire `$config_updated`; typed security-bearing policy enforced in the core send path. | 3 | `a2a_messaging` (or `a2a_config`) |
| **B4** | **Frontend per-app-name rendering** — registry map, generic fallback panel. | 5 | messenger (NOT this repo) |
| **B5** | **Docs** — README is stale (no `a2a_capabilities`, connect, governance, §8). | — | README.md |

---

## C. The introduction problem — explicit verdict

> **Superseded by core 2.0 (radical simplification).** The original plan below
> proposed a CP-as-registrar *signed* introduction with `connect_descriptor_t`,
> `signed_intro_t`, and a SAS. The human ruled for a far simpler design and that
> machinery was **removed**. This section now describes the shipped 2.0 model; the
> rejected-alternative rationale is retained for history.

**Does 1.10 "root-binding-through-introductions" solve it? NO — only adjacent.**
1.10 threads the root's `root_cp_binding_t` along **existing** connect paths (invites,
`accept_contact`) so a connecting peer learns *who manages* the other side. That is
**governance visibility**, not a mechanism to connect two parties who are not yet
contacts.

**The shipped mechanism (core 2.0): the CP relays peer-signed address documents.**
The CP already holds each managed node's signed address document in `peer_ads`
(captured when the node bound the CP at the 6-digit ceremony). To introduce A and B
the CP simply sends each node the **other's signed AD**; the receiving node verifies
the AD's own self-signature, that the relay came from its bound CP, and that its own
manifest advertises `core.connect`, then registers the contact immediately. **No
SAS, no confirmation step, no per-introduction CP signature** — the bound-CP channel
*is* the authorization, and the node-side capability gate is the authoritative
"do I accept introductions".

Why not the naive invite-relay (still rejected): relaying raw invites would let the
CP register itself as a channel endpoint. Relaying the node's **own self-signed
address document** does not — the AD authorizes only the node's own keys, the
receiver re-checks the self-signature (proof-of-possession), and the contact's
channel is fresh DH between A and B (the CP never holds A↔B keys).

**Design — `introduce(A, B)` (shipped):**
1. **Daemon pre-check (CP side):** pull `get_manifest` for A and B and **refuse if
   either lacks `core.connect`** (prevents a half-open pairing). Daemon logic, not core.
2. CP calls **`introduce(A, B)`** (host-fired). The core reads `peer_ads[A]`/`peer_ads[B]`
   and emits, in one transaction, two encrypted relays: A gets B's signed AD, B gets A's.
3. Each node runs **`ingest_connect_descriptor`**: `require_bound_cp_or_abort` (relay is
   from my bound CP) → node-side capability gate (`self_supports("core.connect")`) →
   `process_address_document` (peer AD self-sig / PoP, aborts on forgery) → register the
   contact + `_notify_agent($introduced)`. An already-known contact is a no-op refresh
   (`$reintroduced`, no downgrade/rename).

`introduce_to_group(joiner, members)` fans the same pair of relays out across a group
(cluster-root onboarding). Properties: keys bound by the AD self-signature (no swap);
the contact channel is independent of the CP; both endpoints notified. The net-new is a
thin *flow* over existing crypto (`process_address_document`, `send_encrypted_tx`) — no
new wire shapes, no SAS, no introduction signature.

---

## D. Net-new code — B1: forced monitoring (the chokepoint owns its gate)

### D.1 Library split — load-order corrected (per critic-1)

Current load chain: `a2a_capabilities ← a2a_protocol ← a2a_messaging ← a2a_control`.
If a new `a2a_monitoring` **loaded** `a2a_messaging`, it would sit **above** it, so
`a2a_messaging::send_message` could **not** call up into it to emit the copy — a circular
load. **Therefore:**

- **The emit helper (`monitor_copy_actions`) AND the `monitoring_proxy` state +
  `monitoring_copy_t` shape live INSIDE `a2a_messaging`** — the chokepoint owns its own
  gate. This is the load-bearing change.
- **`a2a_monitoring` is management-ONLY**: the 6-digit ceremony
  (`set_proxy_pending`/`verify_proxy_code`) + CP-authenticated `disable` + the CP-side
  `receive_monitoring_copy` handler. It **writes `a2a_messaging`'s shared non-hidden
  state** (`monitoring_proxy`) — exactly how `a2a_hierarchy` writes `a2a_messaging`'s
  delegation state without owning the send path.

### D.2 Enforcement principle (the "app can't override" guarantee)

The copy **generation** is **unconditional core code** in the shared `a2a_messaging`
send/receive path that every app routes through — **not** an app-injected hook (the
existing `on_message_*` hooks abort-if-unset and are app-supplied; an app could inject a
no-op and silently kill monitoring, breaking the brief). `monitoring_proxy` is settable
**only** by `verify_proxy_code` (6-digit, sender-bound) and clearable **only** by a
CP-authenticated `disable` — there is **no app-callable clear**. So it is structurally
impossible to send/receive a message without the copy being generated.

Invariants:
- **No recursion**: the copy is emitted as a *distinct* path (`receive_monitoring_copy`),
  **never via `send_message`** — else the copy is itself monitored → infinite fan-out. The
  copy traffic to the proxy is likewise **not** monitored.
- **Ciphertext on the wire**: the copy is sent with `encrypted_channel::send_encrypted_tx`
  to the proxy's container id, so it is re-encrypted under the proxy channel key — never
  plaintext.

### D.3 Fire-and-forget through the broker; uniform gate (HUMAN corrections #1 + #2)

Two corrections from the human collapse the earlier (queue + sink-split) design into the
simplest faithful form:

- **#1 — Fire-and-forget through the broker.** No local `monitoring_inbox`, no
  `get_monitoring_copies` daemon, **no proxy-liveness handling**. The copy is emitted
  *inline* as a distinct fire-and-forget encrypted send. If the proxy is offline the
  **ADAPT broker holds the pending message** — persistence/liveness is the framework's
  job, not the mufl app's. (`send_encrypted_tx` just produces a `send` action; it does not
  block on or wait for the receiver.)
- **#2 — Uniform gate, no sink split.** No role→root-vs-root→CP branching. One rule: **if
  `monitoring_proxy` is bound, emit the copy to it**; otherwise emit nothing. Binding *is*
  the enabled state, so no separate `monitoring_enabled` flag is needed.

```mufl
// ---- a2a_messaging.mm: state + emit (the chokepoint owns these) ----
metadef proxy_binding_t:  ($proxy_cid -> global_id, $bound_at -> time, $epoch -> int).
metadef monitoring_copy_t: (
    $version -> int, $direction -> str /* "out"|"in" */,
    $peer_cid -> global_id, $peer_name -> str, $date -> time, $body -> str
).
// Distinct inbound tx name on the proxy — held as a literal string so a2a_messaging
// needs NO code dependency on a2a_monitoring (which sits above it in the load order).
receive_monitoring_copy_tx = "::a2a_monitoring::receive_monitoring_copy".

monitoring_proxy is proxy_binding_t+ = NIL.   // set ONLY by verify_proxy_code; cleared ONLY by CP-auth disable

// Core, recursion-safe (never calls send_message). Uniform gate: proxy bound ⇒ emit one
// fire-and-forget encrypted copy to it. No queue, no liveness — the broker holds it if the
// proxy is offline. Returns [] (no churn) when no proxy is bound.
fn monitor_copy_actions (direction: str, peer_cid: global_id, peer_name: str, date: time, body: str)
    -> transaction::action::type[]
{
    if monitoring_proxy == NIL { return []. }
    copy is monitoring_copy_t = (
        $version -> 1, $direction -> direction, $peer_cid -> peer_cid,
        $peer_name -> peer_name, $date -> date, $body -> body
    ).
    // The proxy is a registered contact (the 6-digit bind established the channel), so this
    // is a plain encrypted send action — re-encrypted to the proxy key, never plaintext.
    return [ encrypted_channel::send_encrypted_tx (monitoring_proxy? $proxy_cid) (
        $name -> receive_monitoring_copy_tx, $targ -> ($copy -> copy)
    ) ].
}
// send_message: after the user-message send action, UNCONDITIONALLY append
//   monitor_copy_actions "out" target_id <name> sent_date text   (the function self-gates).
// handle_receive_message: UNCONDITIONALLY append
//   monitor_copy_actions "in" sender_id <name> msg_date text.
```

```mufl
// ---- a2a_monitoring.mm (NEW) — management ONLY; writes a2a_messaging state ----
library a2a_monitoring loads libraries
    current_transaction_info, encrypted_channel, a2a_messaging
    uses transactions
{
    // Pending bind state stays local to this lib (only the ceremony reads it).
    metadef proxy_pending_t: ($code -> str, $proxy_cid -> global_id, $expires_at -> time, $attempts -> int).
    proxy_pending is proxy_pending_t+ = NIL.

    // App-injected: where the CP stores a received monitoring copy (storage stays app-side,
    // like a2a_messaging::on_message_received). Fires only for the bound, known proxy path.
    hidden { on_monitoring_copy_received is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_monitoring_copy_received hook is unset (call a2a_monitoring::init)." when TRUE. return []. } }
    init = fn (_:($on_monitoring_copy_received -> cb: (any -> transaction::action::type[]))) { on_monitoring_copy_received -> cb. }

    // TS passes the generated code (MUFL has no random source); stored as pending.
    trn set_proxy_pending _:($code -> code: str, $proxy_cid -> cid: global_id, $expires_at -> exp: time)
    { /* validate user origin; write proxy_pending */ ... }

    // The human's verification message redeems the code; binds the proxy atomically.
    trn verify_proxy_code _:($code -> code: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender = current_transaction_info::get_external_envelope_or_abort() $from.
        abort "No pending proxy bind." when proxy_pending == NIL.
        abort "Bind is for a different identity." when (proxy_pending? $proxy_cid) != sender.
        // expiry + attempts<3 (omitted); on wrong code increment attempts, cancel at 3.
        abort "Wrong code." when (proxy_pending? $code) != code.
        a2a_messaging::monitoring_proxy -> ($proxy_cid -> sender, $bound_at -> /*now*/ ..., $epoch -> /*++epoch*/ ...).
        proxy_pending -> NIL.
        return transaction::success [ a2a_messaging::_notify_agent ($event -> $proxy_bound, $cid -> sender), a2a_messaging::_save_state NIL ].
    }

    // CP-authenticated disable: only the bound proxy may clear monitoring (app can't).
    trn disable_monitoring args: any { /* require sender == a2a_messaging::monitoring_proxy?.proxy_cid; clear it */ ... }

    // CP side: receive a forwarded copy from a node it monitors; storage is the app's.
    fn handle_receive_monitoring_copy (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender = current_transaction_info::get_external_envelope_or_abort() $from.
        copy = (args $copy) safe a2a_messaging::monitoring_copy_t.
        return transaction::success (on_monitoring_copy_received ($source -> sender, $copy -> copy)).
    }
    trn receive_monitoring_copy args: any { return handle_receive_monitoring_copy args. }
}
```

Note: with the uniform rule, the `ours.mcp` cluster (root + N roles) is monitored by
binding the CP **per node**. Roles are full packets; a TS daemon that already manages the
cluster can drive the bind for each. Aggregation/grouping for display is a frontend concern
(B4), not a protocol one — keeping the protocol path single-rule and simple per the human.

Scope (v1, stated honestly): copies cover **chat send/receive only**. Contact
establishment + control traffic are **out of v1 "all traffic" scope**.

---

## E. Net-new code — B2: `core.connect` introduction flow (core 2.0, shipped)

```mufl
// CP-side: introduce two managed nodes. Both must be established contacts of the CP
// (peer_ads holds their signed ADs). Emits both relays in one transaction. The
// manifest "supports introductions" pre-check is the DAEMON's job (get_manifest);
// the node-side gate in ingest_connect_descriptor is the authoritative enforcement.
trn introduce _:($peer_a -> ref_a: str, $peer_b -> ref_b: str)
{
    // validate_origin(user); a = resolve_contact ref_a; b = resolve_contact ref_b.
    // abort if a == b; abort if peer_ads[a] == NIL or peer_ads[b] == NIL.
    // return success( emit_pair(a, ad_a, name_a, b, ad_b, name_b) ++ [ _return_data($introduced) ] ).
}

// emit_pair: two BARE encrypted sends (channels already established at bind, so no
// execute_transaction handshake). A gets B's signed AD, B gets A's.
fn emit_pair (a, ad_a, name_a, b, ad_b, name_b) -> transaction::action::type[]
{
    return [
        encrypted_channel::send_encrypted_tx a ($name -> ingest_connect_descriptor_tx, $targ -> ($peer_ad -> ad_b, $peer_name -> name_b)),
        encrypted_channel::send_encrypted_tx b ($name -> ingest_connect_descriptor_tx, $targ -> ($peer_ad -> ad_a, $peer_name -> name_a))
    ].
}

// Node-side: ingest the peer's signed address document the CP relayed. No SAS, no
// CP signature — the bound-CP channel + the node capability gate are the authorization.
fn handle_ingest_connect_descriptor (args: any) -> transaction::results::type
{
    // validate_origin(external); check_encrypted_or_abort; sender = envelope.$from.
    // require_bound_cp_or_abort(sender).                          // relay is from my bound CP
    // abort unless a2a_capabilities::self_supports(a2a_capabilities::cap_connect).  // node gate (authoritative)
    peer_ad = (args $peer_ad) safe address_document_types::t_address_document.
    peer_cid = peer_ad $identity $container_id.
    // abort if peer_cid == _get_container_id().
    address_document::process_address_document peer_ad TRUE.        // peer AD self-sig / PoP, aborts on forgery
    // if already a contact: refresh peer_ads only, keep name, notify $reintroduced.
    // else: register contact ($peer_name || cid) + peer_ads, notify $introduced.
}
```

CP-side orchestration (daemon): `get_manifest(A)` + `get_manifest(B)`, **refuse if
either lacks `core.connect`**, then call `introduce(A, B)`. The core emits both
signed-AD relays; each node's `ingest_connect_descriptor` gates and registers. The CP
never holds the A↔B channel keys (fresh DH between A and B on first message).

**`ingest_connect_descriptor` authorization (critic-verified, core 2.0):**
1. **CP-sender gate** — `require_bound_cp_or_abort`: the relay must come from the CP
   pinned at the 6-digit bind.
2. **Node capability gate (authoritative)** — abort unless the node's own live manifest
   advertises `core.connect`. Without this the manifest boolean would be pure CP-side
   courtesy.
3. **Peer AD self-signature** — `process_address_document(peer_ad, TRUE)` re-checks the
   peer's own self-signatures and aborts on a forged/inconsistent document *before* any
   write (`TRUE` only relaxes external-authorizing-container trust, not the self-sig).

**Notes (core 2.0):**
1. **`core.connect` means "I ACCEPT introductions", not "I am undiscoverable".** A node's
   AD is public (invite-equivalent); the boolean does not hide it. The half-open
   preventer is the daemon pre-check, which must refuse if **either** party lacks support.
2. **No SAS / no confirm step.** Introductions are established immediately; the node trusts
   its bound CP to introduce honestly (same governance/honesty class as the monitoring bind
   and the README §8 self-assertion limit). `$peer_name` is an unauthenticated display
   label — never gate on it.

---

## F. Net-new code — B3: opaque config storage ONLY

> **SCOPE CORRECTION (human ruling, 2026-06-17):** the core stores and transports an
> **opaque, app-custom JSON blob** and bakes in **no policy semantics whatsoever**.
> The earlier typed `contact_policy` / `outgoing_only` core enforcement was **removed** —
> per-application policy (including "outgoing-only") is **application logic in the
> wrapper**, driven by the app's own custom config schema, not a protocol feature. This
> also reverses the earlier "security-bearing policy core-enforced" decision.

```mufl
app_config is str = "".   // hidden; opaque app-custom JSON, CP-sourced, persisted

fn handle_set_app_config (args: any) -> transaction::results::type
{
    current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
    encrypted_channel::check_encrypted_or_abort().
    sender = current_transaction_info::get_external_envelope_or_abort() $from.
    // GATE: only the bound CP may write config (same gate as monitoring).
    require_bound_cp_or_abort sender.
    app_config -> (args $config) safe str.
    return transaction::success [ _notify_agent ($event -> $config_updated), _save_state NIL ].
}
// get_app_config (readonly) returns the blob. That is the ENTIRE B3 surface.
```

- The wrapper, on `$config_updated`, pulls `get_app_config` and applies **all** of it —
  operational config (bot tokens → start bots, chat→contact routing) AND any
  app-specific policy (e.g. "outgoing-only"). The core never parses it.
- The core's only job: transport + store the opaque blob (hidden, CP-gated, persisted)
  and notify. No JSON↔mufl mapping, no app-specific enforcement.

---

## G. Frontend (B4) + invariants

```ts
const APP_RENDERERS: Record<string, AppRenderer> = { "ours.mcp": McpControlPanel };
const rendererFor = (m: AppManifest) => APP_RENDERERS[m.name] ?? GenericAppPanel;
```
`GenericAppPanel` renders `core.configuration` `$params` (schema + redacted values) + the
monitoring feed. **Invariant (P1/P5):** `manifest.name`/`app_id` is a **RENDERING HINT
ONLY, never an authority grant** — the frontend enables NO capability from the name; the
privileged `ours.mcp` panel degrades gracefully on unsupported control commands and
surfaces the bound node's real `cid`.

---

## H. Versioning

B1/B3 were additive (no existing wire bytes change; the no-proxy/no-config paths stay
byte-identical) ⇒ **MIN bumps** (1.11–1.15). New `a2a_monitoring.mm` added to `config.mufl`.
The **B2 simplification is a MAJ bump → core 2.0**: it removes wire shapes
(`connect_descriptor_t`, the `signed_intro_t` CP path) and changes the
`ingest_connect_descriptor` payload, so it is not backward-compatible for consumers of the
old `core.connect` surface. Update `version.mm` and the docs (README / RELEASE_NOTES) in
the same commit.

---

## I. Scope — governance-attestation layer (HUMAN DECISION: out of scope, off critical path)

The **governance-attestation layer** — `cp_attestation_t` (1.8), `root_cp_binding_t`
(1.9), and the threading of `$rpb`/`$joiner_cp_binding` through `invite_role_t` +
`accept_contact` (1.10) — is **beyond this brief** (manifest / forced monitoring / config /
introduction / frontend). It is **non-enforcing** metadata (TOFU-pinned "which CP manages
which root") threaded through the most compatibility- and security-sensitive existing
paths, changing **no protocol decision**.

**Human decision (2026-06-16, relayed via Coordinator-1):** *keep the governance-
attestation layer OFF the critical path.* It is acknowledged to exist but is **excluded
from this configuration deliverable** and treated as **out-of-scope-pending-founder-
review**. The net-new pieces (B1 `a2a_monitoring` forced-copy, B2 `core.connect`
introduction flow) **must not build on it, block on it, or entangle it**. No further
non-enforcing additions to invite/`accept_contact` without a concrete enforcement purpose.

## J. critic-1 sign-off checklist (all captured above)

1. **Load-order** — `monitor_copy_actions` + `monitoring_proxy` state + `monitoring_copy_t`
   in `a2a_messaging`; `a2a_monitoring` is management-only. → §D.1, §D code.
2. **Fire-and-forget through the broker** (HUMAN #1) — no local queue/drain, no
   proxy-liveness handling; distinct `receive_monitoring_copy` tx, **no recursion** (never
   via `send_message`; copy traffic not monitored). → §D.2/§D.3, §D code.
3. **Uniform gate** (HUMAN #2) — `monitoring_proxy` bound ⇒ emit copy to it; no
   role-vs-root sink split, no separate `monitoring_enabled`. → §D.3, §D code.
4. **core.connect** (core 2.0, simplified): three-gate authorization on ingest —
   bound-CP sender, node-side `core.connect` capability gate, peer-AD self-sig (PoP).
   No SAS, no CP-signed intro; daemon `get_manifest` pre-check refuses if either party
   lacks support. → §C, §E.
5. **`set_app_config` CP-gated**; security-bearing policy **core-enforced**, not
   wrapper-only. → §F.
6. **`name`/`app_id` = rendering-hint-only**, never an authority grant. → §G.
7. **Governance-attestation layer kept off the critical path / not bundled** — HUMAN
   DECISION: out-of-scope-pending-founder-review; B1/B2 must not entangle it. → §I.

**Status:** critic-1 FINAL SIGN-OFF (msg #6); HUMAN approved implementation with three
corrections (#1 fire-and-forget, #2 uniform gate, #3 attestation deferred), all captured
above. Implementation underway on branch `feat/core-config-control-plane`.
