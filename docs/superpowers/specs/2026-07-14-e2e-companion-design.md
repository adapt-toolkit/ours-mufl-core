# E2E ours-mufl-core companion — design

**Author:** Developer-6 · **Date:** 2026-07-14 · **Branch:** `feat/e2e-companion` (off `main` @ core 0.7.1)
**Authoritative input:** `/tmp/e2e-envelope-contract.md` (LOCKED adapt↔ours seam) + Dev-10 design set
(`e2e-ergonomic-api.md`, `e2e-mufl-sketch.md`, `e2e-otk-options.md`).

## 1. Scope & non-goals

This companion is **ADDITIVE**. It adds a new end-to-end-encrypted message envelope alongside the
existing envelope types, which stay **byte-for-byte unchanged** for dual-support with v1 peers. All
cryptography, ratchet state, and the receive-side decrypt+commit live in the **adapt** `e2e` library
(Dev-10, PR #117). This repo owns only three things:

1. **Wire-type registration** — `e2e_signed_message` / `t_e2e_envelope` in `a2a_versions.mm` as a
   class-B versioned type with `try_narrow_e2e` (error-as-data), so an old-unit peer degrades cleanly.
2. **Capability + anti-downgrade** — `core.e2e` in `a2a_capabilities.mm`, learned per-contact, with a
   monotonic pin so a peer once seen at E2E is never silently boxed again.
3. **Send-side wiring** — build the `e2e_signed_message` envelope (adapt encrypt → sign → send) and the
   E2E-vs-legacy routing decision.

**Non-goals (explicitly out of this repo):** Olm/ratchet crypto, `m_e2e_account`/`m_e2e_sessions` state,
the receive-side decode hook + decrypt+commit, AD v2 `t_e2e_bundle` *type definition* and AD generation,
`pickle_key` derivation. The `min_wire_version` deprecation is **DEFERRED** per owner — do NOT touch it.

## 2. Grounding (real code, this repo, `file:line`)

- `version.mm:20` — `core_version = create_version 0 7 1` (main). This work → **0.8.0**.
- `a2a_versions.mm:43` — `wire_version = 7`; `:47` — `min_wire_version = 2`.
- `a2a_versions.mm:82-87` — `peer_pv` (non-int → 0). `:98-131` — `version_error_t`, `too_old_error`,
  `shape_error`. `:206-212` — `sir_shape_ok` (abort-free `is_str`/`is_int` guards). `:215` —
  `sir_narrowed_t = ($ok, $payload+, $err+)`. `:219-238` — **`try_narrow_sir`** (the load-bearing
  template: floor-check → shape_ok → `raw safe TYPE`). `:242-247` — `narrow_sir` strict form.
- `a2a_versions.mm:519-538` — **`rcp` registration** (shipped single-surface class-B template:
  `rcp_targ_v1_t` + alias + `rcp_version_of` unstamped→7 + abort-free `rcp_shape_ok`), gated behind caps.
- `a2a_capabilities.mm:29-32,82,88-89` — cap ids; `core.notifications` (`:32`) is precedent for a
  **reserved protocol-surface cap with no control verbs**. `:185-218` — `init` merges `$supported` +
  optional `$advertise` (protocol-surface ids) into `self_caps`. `:233-239` — `self_cap_ids`.
- `a2a_messaging.mm:110-111` — `contact_pv` / `contact_caps` per-contact maps. `:622-627` —
  `learn_contact_version` (guarded/monotone write). `:676-686` — **`receipt_gate`** (hybrid:
  explicit-caps-win → else infer `pv >= 7`) — the anti-downgrade/gate template.
- `a2a_messaging.mm:923,950-955` — `send_message` trn; body build with `$pv` stamp via
  `encrypted_channel::send_encrypted_tx` (the **v1 static box**, kept unchanged as the fallback).
- `#77` outer sender-auth: `encrypted_channel::check_encrypted_or_abort()` +
  `current_transaction_info::get_external_envelope_or_abort()$from` (e.g. `a2a_messaging.mm:1174-1177`).
- `key_storage::default_sign(_value_id x)` — e.g. `a2a_messaging.mm:555`; `key_storage` is EXTERNAL.

## 3. Wire-type registration (`a2a_versions.mm`)

New registry surface `"e2e"`, single version, **load-bearing** ⇒ follows the `sir` shape (returns
`$payload`), not the best-effort `rcp` ignore shape.

```mufl
// t_e2e_envelope — the opaque-ciphertext body the core never parses.
metadef e2e_env_v1_t: (
    $session_id -> global_id,   // adapt-derived session id (hex string at runtime)
    $olm_type   -> int,         // 0 = PRE_KEY (establishment inside $ciphertext), 1 = normal ratchet
    $ciphertext -> bin,         // opaque Olm blob
    $pv         -> int+         // wire dialect stamp; NULLABLE in the cast (see $pv note below)
).
metadef e2e_env_t: e2e_env_v1_t.
e2e_max_version = 8.

fn e2e_version_of (raw: any) -> int { pv = peer_pv raw.  return (pv != 0 ?? pv ; 8). }

// Abort-free shape probe (M1): every non-nullable field checked against its runtime domain.
// $pv: absent tolerated (defaults to 8); present MUST be int — every 0.8.0+ e2e sender stamps a real
// int $pv, so a present-non-int is malformed -> shape_error (not the sir-style "tolerate as unstamped").
// This is what keeps the `$pv -> int+` cast abort-free: single-version e2e cannot fall back to an older
// type that omits $pv (as sir does), so a non-int $pv must be rejected at shape_ok, never reach the cast.
fn e2e_env_shape_ok (raw: any) -> bool
{
    ct = raw $ciphertext.  pv = raw $pv.
    return is_str (raw $session_id) && is_int (raw $olm_type)
        && ct != NIL && (_typeof ct) == "BINARY"
        && (pv == NIL || is_int pv).
}

metadef e2e_narrowed_t: ($ok -> bool, $payload -> e2e_env_t+, $err -> version_error_t+).

fn try_narrow_e2e (raw: any) -> e2e_narrowed_t
{
    v = e2e_version_of raw.
    if v < min_wire_version { return ($ok -> FALSE, $payload -> NIL, $err -> too_old_error "e2e" v e2e_max_version). }
    if e2e_env_shape_ok raw != TRUE { return ($ok -> FALSE, $payload -> NIL, $err -> shape_error "e2e" v e2e_max_version). }
    return ($ok -> TRUE, $payload -> raw safe e2e_env_v1_t, $err -> NIL).
}
```

**Accepted residual (inherited from `sir`, critic B3):** `$session_id -> global_id` and `safe global_id`
additionally hex-validates (`a2a_versions.mm:64-69`), while `e2e_env_shape_ok` only checks
`is_str` (STRING domain). A value that is a valid STRING but **not valid hex** passes shape-ok and then
aborts inside `raw safe e2e_env_v1_t`. This is the **identical documented residual `sir` carries**
(`sir_shape_ok` checks `is_str($invite_id)` while the cast is to `global_id`) — the malformed/hostile
class where a hard abort is the correct outcome (`a2a_versions.mm:67-69`). Consequence for §7 tests:
the no-abort guarantee is scoped to **well-typed bodies** (old/short/unstamped, well-typed fields); a
non-hex `$session_id` is the tamper class and MAY abort by design. Do NOT assert *unconditional* no-abort.

Note: `try_narrow_e2e` operates on the **inner `$e2e_envelope`** (after the outer `e2e_signed_message`
`$emsignature` is verified). Whether the outer `e2e_signed_message` wrapper also gets a registry entry or
is a fixed 2-field shape read directly in the handler is a **receive-side** concern (adapt's decode hook);
this repo only needs the inner-envelope narrow available to the send builder and to any ours-side handler
stub. Old-unit peer that receives an `e2e_signed_message` it can't parse: its decode path never matches
the E2E marker (no such tx registered) and it declines — the registry narrow is defense-in-depth for the
hostile/downgraded case, returning error-as-data instead of a `safe`-cast abort (the fix-3 class).

## 4. Capability + monotonic anti-downgrade

```mufl
// a2a_capabilities.mm — reserved protocol-surface id, no control verbs (cf. core.notifications).
cap_e2e = "core.e2e".              // "I speak the E2E signed-message envelope + publish an AD v2 bundle"
```

Advertise it via the existing `$advertise` list in `init` (app passes `["core.e2e", ...]`). Learned
per-contact through the existing `learn_contact_version` → `contact_caps` path — **no new learning code**.

Anti-downgrade lives in `a2a_messaging.mm`, mirroring `receipt_gate`'s hybrid, plus a monotonic pin.
Three-state routing (not a bare bool) so a real downgrade is **error-as-data**, not a channel `abort`
(critic N2 — align with Addition A discipline, which the rest of this repo uses in the send/negotiation
path: `receipt_gate` returns `bool` and never aborts):

```mufl
m_contact_e2e is (global_id ->> bool) = (,).     // highest-seen E2E state per contact (positive-evidence, monotone)

fn note_e2e_seen (cid: global_id, caps: str[]) -> nil
{
    if caps_contains caps a2a_capabilities::cap_e2e { m_contact_e2e cid -> TRUE. }
}

// "e2e" -> send E2E ; "box" -> unchanged static-box fallback ; "downgrade_refused" -> fail-closed, typed refusal
fn e2e_route (cid: global_id) -> str
{
    seen = (m_contact_e2e cid) == TRUE.                          // ever advertised core.e2e
    v2   = peer_has_e2e_bundle cid.                              // AD v2 with a $e2e_bundle present
    if seen && v2 != TRUE { return "downgrade_refused". }        // known-E2E peer with no current bundle: fail closed
    return ((seen || v2) ?? "e2e" ; "box").                     // first-contact v1-only peer => "box" (correct floor)
}
```

`note_e2e_seen` is called from the same inbound legs that already call `learn_contact_version` (so the
pin is set from the same positive evidence). `peer_has_e2e_bundle` reads `peer_ads[cid]` (populated by
adapt's `process_address_document`). On `"downgrade_refused"` the send trn returns a typed
`_notify_agent ($protocol_error, ...)` (an `e2e_downgrade_refused` refusal) and emits **no send** — the
app surfaces "this contact was E2E and can't currently be reached securely; re-verify" rather than
silently boxing a peer the user believes is E2E (fail-closed) **and** without a hard `abort` that would
crash the transaction on a legitimate bundle-loss/migration (avoids the DoS the critic flagged). A
brand-new genuinely-v1-only peer yields `"box"` and takes the unchanged static-box path.

## 5. Send-side wiring (`a2a_messaging.mm`)

Routing at the existing send seam, keyed on `e2e_route cid` (§4). E2E replaces the static box (you do
**not** static-box an already-E2E-encrypted payload).

`$from` authentication note (critic B2): a **bare** send is already sender-authenticated — `#77` signs
every envelope's `$ptsignature` and rejects unsigned/forged origin, so `get_external_envelope_or_abort()
$from` **is** the authenticated sender regardless of any box (`a2a_messaging.mm:1844-1847`). The E2E
`$emsignature` therefore does **not** provide `$from` binding; per contract line 31 it binds the
**envelope contents** to that already-authenticated `$from` (prevents a MITM re-wrapping ciphertext under
a different envelope). Verification of `$emsignature` is **receive-side (adapt)**; this repo only builds it.

Real send primitive is `transaction::action::send` returned inside `transaction::success [...]` with
`_save_state` (critic B1; template `a2a_messaging.mm:1742-1754`) — `send_bare`/`send_a2a` do not exist:

```mufl
// route == "e2e" branch. tx name is a bound constant (cf. complete_invite_tx); MUST equal adapt's decode-branch name.
receive_e2e_message_tx = "::a2a_messaging::receive_e2e_message".   // module-const, see N4

enc = e2e::encrypt_to cid (_to_bin tx_body).       // adapt-STATEFUL: reads+commits adapt-held session[cid] (§Q1)
env = ($session_id -> enc $session_id, $olm_type -> enc $olm_type,
       $ciphertext -> enc $ciphertext, $pv -> a2a_versions::wire_version).
sig = key_storage::default_sign (_value_id env).   // binds envelope contents to the #77-authenticated $from
return transaction::success [
    transaction::action::send cid ($name -> receive_e2e_message_tx,
                                   $targ -> ($e2e_envelope -> env, $emsignature -> sig)),
    _save_state NIL
].
```

First send to a new peer establishes the session first (§Q2). `route == "box"` → exactly today's
`encrypted_channel::send_encrypted_tx` path, untouched. `route == "downgrade_refused"` → the typed
`_notify_agent ($protocol_error, ...)` refusal from §4, no send.

## 6. Version + wire bump

- `version.mm` → **0.8.0**. `a2a_versions.mm:wire_version` → **8** (a peer at dialect ≥ 8 is *known* to
  parse E2E-era transactions — the belt to the `core.e2e` suspenders, exactly the `receipts`→7 precedent).
  `min_wire_version` unchanged (2). COMPATIBILITY.md / release-notes updated.
- **Collision flag:** group-chat is parked at a parallel `0.8.0` on `feat/group-chat` (unmerged). Both
  can't ship as 0.8.0. Merge sequencing is FleetCoordinator's call — flagged, not resolved here.

## 7. Testing

- **MUFL unit tests** (`tests/`, `test.mjs` harness over `@adapt-toolkit/sdk`): (a) `try_narrow_e2e`
  returns `too_old_error` for a sub-floor `$pv` and `shape_error` for a malformed body — **never aborts**
  (the fix-3 regression guard); (b) `use_e2e` routing truth table incl. the downgrade-abort; (c)
  `note_e2e_seen` monotonic pin survives a later caps-absent inbound.
- **Mixed-unit acceptance** (old-unit ↔ new-unit pairing + messaging, **zero reject**) — the fix-3-class
  gate. In-repo `test.mjs` is single-unit; a two-unit-hash harness is needed. **See Q4** — confirm whether
  this runs in an outer ours-mcp harness or is added here.

## 8. OPEN integration questions — routed to Dev-10 THROUGH FleetCoordinator

These are the adapt↔ours seam questions the design depends on. Recommendations given; confirmation needed
before the corresponding code is final.

- **Q1 — Single session-state owner (blocks the §5 call shape).** The real invariant is **one owner per
  peer's Olm session** (a session pickle is a *single bidirectional* blob; a send-side ratchet advance
  mutates the same chain state the receive side reads, so two independently-persisted copies desync).
  The contract is internally inconsistent about *who* owns it: the SEND block (`:19-25`) shows app-held
  `e2e::encrypt(session,...)` + `persist $session'`, while State-ownership (`:50-54`) says **adapt** holds
  `m_e2e_sessions[cid]` for the decode-seam decrypt. Two coherent single-owner models exist: **(a)** adapt
  owns both directions — ours send calls a stateful `e2e::encrypt_to(cid, plaintext) -> ($ciphertext,
  $olm_type, $session_id)` (recommended, matches the LOCKED contract's adapt-held receive); **(b)** ours
  owns both directions and decrypts in a **mutating handler** (not the decode seam), per
  `e2e-mufl-sketch.md:112-152` / `e2e-ergonomic-api.md:33-45` — also desync-free. **Ask Dev-10 (via FC):
  confirm which single owner, and the exact send-side surface signature.** Design assumes (a).
- **Q2 — Session establishment.** Does ours call `e2e::create_session(cid, bundle)` (reading
  `peer_ads[cid].$e2e_bundle`) before first encrypt, or does adapt establish lazily inside `encrypt_to`
  given `cid`? **Recommend** adapt-lazy (ours only ensures the v2 bundle is present); confirm.
- **Q3 — Account + `my_bundle` publication.** Who creates the local account and embeds `my_bundle` into
  our outgoing AD v2 `$e2e_bundle`? **Recommend** adapt owns account state + AD generation (not ours);
  confirm ours has no call here.
- **Q4 — Versioning + acceptance harness.** (a) OK to ship as core **0.8.0 / wire_version 8** off main,
  with the group-chat 0.8.0 collision flagged for merge sequencing? (b) How is the mixed-unit
  (old-unit↔new-unit, unit-hash-change) zero-reject gate run — outer ours-mcp harness, or add to `tests/`?
- **Q5 — Wire tx name (critic N4).** The contract marker is *presence of `$e2e_envelope`* (`:16`), not the
  tx name, but the send tx name must still match adapt's decode branch. Design uses
  `receive_e2e_message`; the sketch used `e2e_message`. **Confirm the exact tx name with Dev-10** before
  the send side is finalized.

## 9. Build order (feeds the implementation plan)

1. `try_narrow_e2e` + metadefs in `a2a_versions.mm` + unit tests (error-as-data). *(No seam dependency.)*
2. `cap_e2e` + `advertise` wiring + `note_e2e_seen`/`use_e2e` + routing truth-table tests. *(No seam dep.)*
3. Version/wire bump + COMPATIBILITY/release-notes.
4. Send-side envelope build (§5) — **gated on Q1/Q2 confirmation**; integrate against Dev-10's compiled
   `e2e` lib through FleetCoordinator.
5. Mixed-unit acceptance gate — **gated on Q4**.
```
