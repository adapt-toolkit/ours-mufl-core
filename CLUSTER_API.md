# CLUSTER_API.md — control-protocol-over-MUFL contract

**Status: `FROZEN v1`** (critic PASS on dd44ae6, Coordinator-frozen 2026-06-19) ·
core `a2a_*` libraries · base core version **2.6** · branch
`feat/control-protocol-mufl` (off `feat/core-cluster-capability`).

> **FROZEN — single source of truth.** WS-B/C/D/E build against THIS. Changes
> require a Coordinator-routed re-freeze. Implementation tracks this contract;
> any impl-discovered necessity that contradicts it is raised to the Coordinator,
> not silently diverged.

> **v0.3 closes critic re-review RR-1…RR-9** (built on cb01be2). RR-1 callback
> forgery (origin::user, critic-verified); RR-2 `$pending_handle` threads
> `(sender,$req_id)`; RR-3 host-truth create dedup + complete/atomic enumerate +
> sync-reconcile-on-timeout + honest drift bound; RR-4 enumerate carries
> `$caps`+`$bio`; RR-5 legacy responder + `absent⇒1`; RR-6 deny-all/explicit-allow
> + god-mode caveat; RR-7 invite brotli dropped (raw-bin + generic base64); RR-8
> monitoring delivery already in-packet (WS-B deletes the drain); RR-9 authz gate
> moved INTO dispatch (non-bypassable, fail-fast). Pre-critic v0.2.1 hardening
> (host-callback unforgeable, fail-closed, layering split) retained.

Single source of truth (TEAM-PROTOCOL §37) for the control-protocol-to-MUFL
initiative. WS-B/C/D/E build against the **FROZEN** version — not against
TypeScript.

> **DRAFT — not frozen.** v0.2 closes critic R8 (R8-1…R8-7) and answers WS-C's 5
> wire questions. WS-B/C/D do **not** implement until the Coordinator broadcasts
> `CONTRACT FROZEN v<n>` after critic clears it. Remaining opens: §13.

**Changelog v0.1→v0.2:** added the single pre-dispatch **authz chokepoint** (§3,
R8-1) + normative per-verb auth class; carved `get_manifest` as the sole pre-auth
no-leak path (§6.1, R8-2); added `host_enumerate_children` + **reconcile** (§9,
R8-3) and the upgrade **backfill** (§10, R8-5); rewrote **idempotency** on
`(sender_id,$req_id)` + operation-keys + retention + timeout-rollback (§8, R8-4);
added manifest **`$protocol_version`** + negotiated cutover (§11, R8-6); honest
**host-primitive enumeration** — it is 3 packet hooks + 1 OOB step, not "two"
(§9, R8-7); added WS-C **wire answers** (§12).

---

## 1. Model

One opaque transport already exists — `a2a_control::send_control($contact,$payload)`
outbound, inbound `a2a_control::control_message` (the `on_control_received` seam).
We stop hand-parsing `$payload` per app. Every command becomes a **capability
envelope** that the seam **authorizes once** (§3) then routes via
`a2a_capabilities::dispatch` to a core handler keyed by capability id. Control
plane and peer app speak the **same** envelope; TypeScript only moves bytes.

```
control plane ──send_control(payload=request_envelope)──▶ node packet
  node: control_message
      → adapt payload → control_envelope_t
      → [AUTHZ CHOKEPOINT §3]  ── deny ──▶ response($ok=false, err=unauthorized)   (NO dispatch)
                               └─ allow ─▶ a2a_capabilities::dispatch → handlers[$cap](ctx) → [actions…]
                                          (+ async host hooks for create/remove, §7/§9)
  node ──send_control(payload=response_envelope)──▶ control plane     (correlated by (sender,$req_id))
```

## 2. Envelopes

**Request — `control_envelope_t`** (EXISTS, a2a_capabilities.mm:131):
```
metadef control_envelope_t: ($cap -> str, $verb -> str, $args -> str, $req_id -> str).
```
| field | type | meaning |
|---|---|---|
| `$cap` | str | `core.cluster` \| `core.monitoring` \| `core.connect` \| `core.configuration` |
| `$verb` | str | verb within the cap (§5–§6) |
| `$args` | str | **opaque JSON object**, schema per verb. `"{}"` when none. |
| `$req_id` | str | caller-chosen correlation id. Uniqueness scoped per sender (§8). `""` = fire-and-forget (no response shipped, no dedup marker). |

**Response — `response_envelope_t`** (NEW, in a2a_capabilities.mm):
```
metadef response_envelope_t: ($req_id -> str, $ok -> bool, $result -> any, $err -> any).
```
| field | type | meaning |
|---|---|---|
| `$req_id` | str | echoes the request `$req_id` |
| `$ok` | bool | TRUE on success |
| `$result` | any | **native** value per verb (record/array/string); present iff `$ok` |
| `$err` | any | **native** `($code,$message)`; present iff not `$ok` |

> **Refinement R1 of FROZEN v1 — impl-discovered 2026-06-19, blessed by Coordinator.**
> `$result`/`$err` are **native MUFL values, NOT pre-stringified JSON**, because
> **MUFL has no JSON encoder** — the frozen "build a JSON-string `$result` in-MUFL"
> was literally impossible. **Delivery:** a handler (sync) or async callback trn
> **returns the `response_envelope` as transaction `return_data`**; the **daemon
> marshals it** (AdaptValue→`JSON.stringify`) and ships via the existing generic
> `sendControl`. **Core emits NO send action for responses.** This marshalling is
> generic envelope transport — identical for every verb, never verb logic — so DoD
> §10 holds and the browser wire shape is unchanged (still a JSON response with the
> same fields). **Response target routing (must need no verb knowledge):** SYNC →
> `ctx.$sender_id` (the seam trn's return_data goes back to the caller); ASYNC →
> the sender resolved from the pending-req by `$pending_handle` (RR-2), to which the
> daemon ships the callback trn's return_data. The daemon never inspects the verb to
> route or marshal — the proof it stays generic.

Control plane resolves the pending promise by `(sender,$req_id)`. Handlers are
**idempotent by `(sender,$req_id)`** (§8).

**Binary-in-JSON encoding — ONE uniform rule [NORMATIVE] (preempts RR-7 concern).**
`$args` and `$result` are always JSON **strings**; this invariant never bends. A
binary value that must appear *inside* one of those JSON objects is carried as a
**base64url string**, applied **identically to every binary field of every verb** —
a single, verb-agnostic transport encoding, never per-verb logic. `core.cluster.contact`'s
`$result.invite` (the raw uncompressed invite `bin`, §9 RR-7) is simply *the one
current instance* of this rule, not a special case — so it does not break the
"`$result` is opaque JSON str" invariant and introduces no verb-specific TS (DoD
§10). Any future binary-bearing result uses the same rule. (Because MUFL itself has
no base64 — grep-clean — the encode/decode sits at the generic transport boundary,
but it is the same code path for all bins, so it is provably generic, not
verb-specific.)

**Dispatch ctx** (EXISTS, a2a_capabilities.mm:196) handed to each handler:
```
ctx = ($sender_id: global_id, $sender_name: str, $app_id: str,
       $verb: str, $args: str, $req_id: str, $date: time)
```

## 3. Authorization — ONE pre-dispatch chokepoint (R8-1, R8-2) [NORMATIVE]

`dispatch()` performs **no** authorization. A "switch+compose" handler would
therefore expose every mutator to any contact. So authorization is decided
**once, before dispatch, in the `control_message`/`on_control_received` seam** —
mirroring today's single TS chokepoint (`proxyCid === senderCid`,
index.ts:798-802). This is a **core-provided** gate, not per-app code.

**New core fns — split by the library layering** (this is load-bearing, see note):
```
// PURE policy table — no state. Home: a2a_capabilities (the lowest layer).
fn a2a_capabilities::control_auth_class (_:($cap -> str, $verb -> str)) -> str   // "public" | "controller" | "bootstrap"

// STATEFUL gate — reads the bound control proxy. Home: a2a_messaging.
fn a2a_messaging::authorize_control (_:($sender_id -> global_id, $cap -> str, $verb -> str)) -> bool
```
**Layering note (corrects v0.2 first draft):** `a2a_capabilities` is loaded *by*
`a2a_messaging`, not vice-versa, and the bound-proxy identity (`monitoring_proxy`,
a `proxy_binding_t`) is `hidden` inside `a2a_messaging` — readable only there. So
the stateful `authorize_control` **must** live in `a2a_messaging` (which already
owns the identical check at index-side parity, a2a_messaging.mm:228 config gate
and :249 CP gate); `a2a_capabilities` holds only the pure `control_auth_class`
policy table. The seam calls `a2a_messaging::authorize_control` once; on FALSE it
emits an `unauthorized` response and **does not** dispatch. Handlers MAY add finer
checks (e.g. introduce consent, §6.3) but **cannot widen** access.

**Auth classes**
- **`public`** — no auth. Read-only, side-effect-free, **no member data**. The
  ONLY public surface is `get_manifest` (§6.1) — needed *before* bind, or
  bootstrap deadlocks (R8-2).
- **`controller`** — `$sender_id` is the node's **bound control proxy**
  (`$sender_id == a2a_messaging` bound `monitoring_proxy.$proxy_cid`). All cluster
  mutators + `list`/`contact`/`introduce` + `monitoring.disable`.
- **`bootstrap`** — `core.monitoring.bind` ONLY. The sender is **not yet** the
  controller; authorization is **possession of the 6-digit code** (verified by
  `verify_proxy_code`). On success the sender *becomes* the controller.

**Fail-closed — deny-all / explicit-allow [NORMATIVE] (RR-6).** Authorization is an
**explicit allow-list**, not a permissive default:
- `control_auth_class` returns one of `public`/`bootstrap`/`controller` ONLY for
  the `(cap,verb)` pairs explicitly enumerated in the table above; for **anything
  else it returns `"deny"`**, and the chokepoint rejects `"deny"` with
  `unauthorized` **before** dispatch. A new verb must be *consciously classified*
  in the table to become reachable — it can never silently inherit access. (This
  is stricter than v0.2's `unknown→controller`.)
- `on_unknown` (an authorized controller hitting an unimplemented *cap*) **MUST be
  side-effect-free** and emit `$ok=false`/`unknown_verb` — no state change, no
  action but the error reply. Never fail-open.
- A known cap's handler **MUST** default its verb switch to `$ok=false`/`unknown_verb`
  — an unrecognized verb never falls through to a permissive branch.

**Scope caveat [NORMATIVE-VISIBLE] (RR-6).** This single chokepoint faithfully
reinstates the **single-credential `controller` = god-mode** model: one bound-proxy
credential authorizes every mutator incl. destructive `remove`. Tiered authz
(observe < manage < create < destroy) remains **roadmap**, not enforced here. Kept
visible so it is a conscious, documented limitation, not an accident.

**Non-bypassable BY CONSTRUCTION — the gate lives INSIDE dispatch (RR-9)
[NORMATIVE].** A per-app seam gate is a footgun: a new app could wire `dispatch`
and *forget* the gate → silent bypass, nothing fails-fast. So the gate is moved
**into `dispatch` itself**, fail-fast like `init`'s declared-vs-implemented check:
- `init` gains an injected **`$authorizer -> (any -> bool)`** hook — the app wires
  it to `a2a_messaging::authorize_control` (the stateful gate; lives there per the
  layering note). `a2a_capabilities` calls it through the hook, so no reverse
  dependency.
- **`dispatch`, before routing**, computes `class = control_auth_class($cap,$verb)`:
  - `"deny"` → return `unauthorized` (never routes);
  - `"controller"` → **`abort` if `authorizer` is unset** (fail-fast: an app that
    forgot to wire it cannot serve a single mutator) then call it; on FALSE →
    `unauthorized`;
  - `"public"`/`"bootstrap"` → route (bootstrap's own check — `verify_proxy_code` —
    runs inside the `bind` handler).
This makes "every mutator passes the chokepoint" true **by construction**, not by
convention — a missing gate is a hard abort, exactly like a missing handler. (WS-E
still adds a conformance test as defense-in-depth, but it is no longer the only
backstop.)

**MUFL wiring note for `init` (saves WS-B/C/D compile time).**
- `$authorizer -> a2a_messaging::authorize_control` works DIRECTLY — `authorize_control`
  takes `any` (not a typed arg record) so it is assignable to the `(any -> bool)`
  field. (A typed-arg fn is NOT assignable there under function-arg contravariance;
  no wrapper needed because the fn already takes `any`.)
- `$handlers` and `$supported` literals infer **closed/fixed** types
  (`<"core.cluster",…> ->> …`, `[0->,1->,2->]`) that don't match `init`'s OPEN
  `(str ->> …)` / `(int ->> str)`. Build them as explicitly-typed locals first:
  ```
  h is (str ->> (any -> transaction::action::type[])) = (,).
  h (a2a_capabilities::cap_cluster)    -> a2a_cluster::cluster_handler.
  h (a2a_capabilities::cap_monitoring) -> a2a_cluster::monitoring_handler.
  h (a2a_capabilities::cap_connect)    -> a2a_cluster::connect_handler.
  s is str[] = [a2a_capabilities::cap_cluster, a2a_capabilities::cap_monitoring, a2a_capabilities::cap_connect].
  ```
  then pass `h`/`s` to `init`.

**Normative per-verb auth class** (the authoritative table; §5/§6 repeat it per row):

| cap.verb | class |
|---|---|
| `get_manifest` (trn, §6.1) | **public** |
| `core.monitoring.bind` | **bootstrap** |
| `core.cluster.*` (list/create/set_bio/remove/set_monitoring/contact/introduce) | **controller** |
| `core.monitoring.disable` | **controller** |
| `core.connect.introduce` | **controller** (+ handler-side verified-connect gate, §6.3) |
| `core.configuration.*` | **controller** |

## 4. `member_t` registry

Root-packet registry, the control-plane projection of the hosted child set
(kept honest by §9 reconcile — it is NOT an unbacked source of truth):
```
metadef member_t: ($cid -> global_id, $role_id -> str, $name -> str,
                   $bio -> str, $monitoring -> str, $caps -> str[]).
cluster_members is (global_id ->> member_t).      // keyed by child cid
```
`$monitoring` ∈ `"off" | "pending" | "on"`. JSON member:
`{"cid":str,"role_id":str,"name":str,"bio":str,"monitoring":"off|pending|on","caps":[str]}`.

## 5. `core.cluster` verbs

| verb | class | sync? | `$args` JSON | `$result` JSON | composes / notes |
|---|---|---|---|---|---|
| `list` | controller | sync | `{}` | `{"members":[member,…]}` | reads `cluster_members` (post-reconcile, §9). Empty ⇒ caller is not a managing root. |
| `create` | controller | **async** | `{"name":str,"bio":str}` | `{"cid":str,"role_id":str,"name":str,"bio":str,"monitoring":"off","caps":[…]}` | **op-key = name** (§8). Emits `host_provision_child` + persists pending-req; completed by `register_provisioned_child` (§7). |
| `set_bio` | controller | sync | `{"cid":str,"bio":str}` | `{"cid":str,"bio":str}` | registry-only in v1 (§13-Q3): updates `cluster_members[cid].bio`. |
| `remove` | controller | **async** | `{"cid":str}` | `{"cid":str,"removed":true}` | **op-key = cid** (§8). Emits `host_destroy_child` + pending-req; completed by `confirm_child_destroyed` (§7). Destructive (full teardown). |
| `set_monitoring` | controller | **async** (C5) | `{"cid":str,"enabled":bool}` | `{"cid":str,"monitoring":"on\|off"}` | REAL per-child monitoring (§9): host-binds/clears the child's `monitoring_proxy` to the root's ceremony-pinned CP via `host_set_child_monitoring` → `confirm_child_monitoring`. CP derived from `bound_cp_cid`, never `$args`. |
| `contact` | controller | **async** (R2) | `{"cid":str}` | `{"invite":str}` | the controller must become a **direct contact of the CHILD**, so the invite must carry the CHILD's identity — only the child's packet can sign it. The root handler validates the cid is a real hosted child, persists a pending-req, and emits **`host_mint_child_invite`** (4th host primitive, §9); the daemon runs `generate_invite` IN the child packet and calls back `register_child_invite`. `$invite` = base64url of the raw child invite bin (shape unchanged → WS-C unaffected). |
| `introduce` | controller | sync | `{"peer_a":str,"peer_b":str}` \| `{"joiner":str,"members":[str,…]}` | `{"ok":true}` | composes `a2a_messaging::introduce` / `introduce_to_group`. Cluster-scoped child↔contact. |

## 6. `core.monitoring` / `core.connect` / `get_manifest`

### 6.1 `get_manifest` — the ONLY pre-auth discovery path (R8-2) [NORMATIVE]
Stays the existing `a2a_capabilities::get_manifest` **`trn readonly`**, auth class
**public**. Returns the `app_manifest_t` ONLY — caps, verbs, name,
`$monitoring_status`, and **`$protocol_version`** (§11). It **MUST NOT** return
`cluster_members` or any member data (member enumeration requires
`core.cluster.list`, which is `controller`). This is what lets a not-yet-bound
client discover envelope support without deadlock, without leaking the roster.

### 6.2 `core.monitoring`
| verb | class | `$args` | `$result` | notes |
|---|---|---|---|---|
| `bind` | bootstrap | `{"code":str}` | `{"manifest":{…},"members":[member,…],"config":{…}}` | the 6-digit ceremony verify step → `verify_proxy_code($code, sender=ctx.$sender_id)`. Code generated host-side OOB (§9). **One-shot** manifest+members+config (WS-C Q3, §12). On success sender becomes controller. |
| `disable` | controller | `{}` | `{"ok":true}` | `disable_monitoring`. |

### 6.3 `core.connect`
| verb | class | `$args` | `$result` | notes |
|---|---|---|---|---|
| `introduce` | controller + verified-gate | `{"peer_a":str,"peer_b":str,"force":bool}` | `{"ok":true}` | generic peer↔peer. The **verified-connect gate** is preserved (R7 #3 / WS-C §3): block with `$err.code="unverified_connect"` unless `force=true` (§12 Q2). No second ungated introduce path. |

## 7. Host-primitive hooks (async create/remove)

**Pending-handle threads the sender dimension (RR-2) [NORMATIVE].** The host
round-trip would otherwise drop `$sender_id` (host actions carried `$req_id` only,
contradicting §8's `(sender,$req_id)` key). Fix: the handler mints a **host-unique
`$pending_handle`** per async op and threads it through; the pending-req is keyed
by `$pending_handle` and stores the full `(sender_id, $req_id, verb, op_key, args,
date)`. The handle — not the client-chosen `$req_id` — is what the callback echoes,
so the correct sender's pending-req is recovered unambiguously across proxy handoffs
or `$req_id` reuse.

**Notify-actions emitted by core handlers** (daemon host executor consumes):
```
host_provision_child : ($event -> $host_provision_child, $name -> str, $bio -> str, $pending_handle -> str)
host_destroy_child   : ($event -> $host_destroy_child,   $cid  -> global_id,         $pending_handle -> str)
host_enumerate_children : ($event -> $host_enumerate_children, $pending_handle -> str)   // §9
```
**Callback trns (daemon → core, after the host op):**
```
register_provisioned_child _:($pending_handle -> str, $child_ad -> bin)
    // MUST match an outstanding host_provision_child pending-req by $pending_handle
    // (else ABORT). Delegate + register the new AD into cluster_members, resolve the
    // pending-req's (sender,$req_id), emit the `create` response to that sender.
confirm_child_destroyed _:($pending_handle -> str, $cid -> global_id)
    // MUST match an outstanding host_destroy_child pending-req (else ABORT). Drop
    // cluster_members[cid], resolve the pending-req, emit the `remove` response.
reconcile _:($pending_handle -> str, $children -> child_rec[])   // §9; $pending_handle="" for timer/boot runs
```
Daemon maps `host_provision_child`→`provisionIdentity`→`register_provisioned_child`,
`host_destroy_child`→`deleteIdentityCompletely`→`confirm_child_destroyed`,
`host_enumerate_children`→enumerate→`reconcile`. **`$child_ad` is passed NATIVE**
(a parsed `t_address_document` record, not a `bin` blob) — consistent with R1, no
in-MUFL deserialization.

**Async response routing [NORMATIVE] (R1 routing).** A host callback runs at
`origin::user`, so its `ctx.$sender_id` is the **daemon/self** — replying there
would misroute. The callback therefore returns a routing wrapper as its
`return_data`: **`($target -> <stored controller cid>, $response -> response_envelope)`**,
where `$target` is the sender stored in the pending-req (resolved by
`$pending_handle`, RR-2). The daemon ships `$response` to `$target`. **Routing is
always by stored sender, never by `ctx.$sender_id` and never by verb.** (Sync
verbs differ: the seam trn's `return_data` is the bare `response_envelope`, shipped
to its own `ctx.$sender_id`.)

**HOST-ONLY, MATCH-REQUIRED gate (UNFORGEABLE) [NORMATIVE] (RR-1).**
`register_provisioned_child`, `confirm_child_destroyed`, and `reconcile` are **host
callbacks, never control verbs**. THREE independent guarantees stop a forged
"child registered/destroyed" from poisoning `cluster_members`:
1. **Not in any `$handlers` map** — `dispatch` cannot reach them. A remote contact
   can only deliver a control envelope (→ `control_message` → `origin::external` →
   dispatch → handlers); these trns are not on that path.
2. **Origin gate** — each MUST open with
   `current_transaction_info::validate_origin_or_abort(transaction::envelope::origin::user,)`.
   *Origin determination (RR-1, corrected):* `origin::self` **does not exist** in
   ours-mufl-core or adapt-toolkit/transactions (grep-clean); every host-fired
   daemon-invoked trn — `manage_root` (a2a_messaging.mm:790), `set_proxy_pending`,
   `generate_invite`, `introduce`, … — gates on **`origin::user`**, which is the
   origin the daemon's callback invocation actually carries. `origin::external`
   (remote peers) **cannot** claim `user`. *(The R8-RR1 `origin::self`/`:830`
   citation was a misread — `:830` is inside `handle_enroll_delegated_node`, which
   is `origin::external`. Confirmed with critic.)*
3. **Pending-match (correctness/idempotency guard — NOT the forgery fix)** — the
   callback MUST correspond to an **outstanding pending-req** (looked up by
   `$pending_handle`) that actually emitted the matching `host_*` action; **no
   match ⇒ ABORT**, and the pending-req is **consumed atomically on first
   callback**. *Threat-model attribution (critic-confirmed):* guarantees #1+#2
   (`origin::user`) **alone** close the remote-forgery threat — every inbound peer
   message, **including the browser control-proxy's control envelopes**, is
   `origin::external` (a2a_control.mm:64), so no remote party can ever invoke a
   user-origin callback; the only entity that can is the local daemon (a
   compromised daemon is total-loss regardless). The pending-match instead
   guarantees **correctness against the legit daemon**: a duplicate/stale/re-fired
   callback with no live pending-req must no-op, else a second `register`
   double-inserts and a second `confirm` mis-drops (ties to RR-3 idempotency). It
   is also belt-and-suspenders if origin were ever mis-stamped, but `origin::user`
   is THE forgery fix.

## 8. Async correlation & idempotency (R8-4) [NORMATIVE]

- **Two indices, by purpose (RR-2/RR-3):**
  - **Correlation** — pending-reqs are keyed by the **host-unique `$pending_handle`**
    (§7) and store the full `(sender_id, $req_id, verb, op_key, args, date)`. The
    handle threads `(sender,$req_id)` through the host round-trip that the raw
    actions would otherwise drop, so the right sender's response is shipped
    unambiguously across proxy handoffs / `$req_id` reuse.
  - **Operation dedup** — a SEPARATE **GLOBAL (not per-sender)** index keyed by the
    op-key (`create`→`$name`, `remove`→`$cid`). Global is required: across a proxy
    handoff a *new* controller must not re-create a `$name` the *old* controller is
    mid-provisioning (the member doesn't exist yet, so a per-sender check would
    miss it — RR-3).
- **Operation-level idempotency consults HOST TRUTH, not just the registry (RR-3):**
  - `create` **op-key = `$name`** (global). Before emitting `host_provision_child`,
    short-circuit if the name exists as **(a)** a member, **(b)** a global pending
    create, **(c)** a completed-create marker, **OR (d) a HOST packet** (per the
    last reconcile / a read-through `host_enumerate_children`). (d) is the RR-3
    fix: between spawn and registry-add the name exists as a *packet* but not a
    *member*; checking only (a)-(c) lets a retry spawn a **duplicate packet**.
  - `remove` **op-key = `$cid`** (global). If `cid` is already absent from both the
    registry and host truth (or a remove is pending/completed), return idempotent
    `{"cid":…,"removed":true}`; do NOT re-emit `host_destroy_child`. (Requires
    `host_destroy_child`/`deleteIdentityCompletely` to be **idempotent on an
    already-absent packet** — RR-6 — so a retry after a lost `confirm` is safe.)
- **Completed-req retention** — keep a `completed_reqs` marker
  (`(global_id,str) ->> response_envelope_t`, keyed `(sender,$req_id)`) for
  **`completed_req_retention` (600 s)**, distinct from the pending TTL. A duplicate
  `(sender,$req_id)` within the window re-ships the stored response, no new work.
- **Pending TTL = `pending_req_ttl` (120 s) ⇒ SYNCHRONOUS reconcile then settle
  (RR-3).** When a pending-req ages out, the sweep **reconciles first**
  (`host_enumerate_children` ⨝ registry) and only then settles: if the orphan
  packet is found it is **adopted** and the op reported success; if genuinely
  absent the op is **rolled back** and an `$ok=false`/`timeout` response shipped.
  Reconciling synchronously *before* emitting the failure closes the
  "timeout-then-retry-duplicates" window — the client never sees a failure for a
  child that actually exists, so it won't retry-and-duplicate.

## 9. Host truth & reconciliation (R8-3, R8-7) [NORMATIVE]

The registry is a **projection that MUST be provably non-divergent** from the
hosted packet set. Two mechanisms:

**(a) The `create` VERB funnel.** A `core.cluster.create` lands in `cluster_members`
via `register_provisioned_child` — which **requires a matching `create` pending-req**
(by `$pending_handle`, §7) and **aborts otherwise**. So funnel (a) covers ONLY the
create verb (the only path that has a pending-req). **Out-of-band / CLI `create_identity`
has NO pending-req**, so it MUST NOT go through `register_provisioned_child` (it would
abort) — it is caught by funnel (b)/reconcile instead. (This is why non-divergence
rests on (b), not (a): any provisioning that isn't a `create` verb — CLI, crash mid-
workflow — is reconciled from host truth.)

**(b) `host_enumerate_children` + `reconcile`.** Third packet host-primitive
(payload corrected per RR-4 to carry `$caps` + `$bio`):
```
host_enumerate_children : ($event -> $host_enumerate_children, $pending_handle -> str)
    // daemon replies via:
reconcile _:($pending_handle -> str, $children -> child_rec[])     // $pending_handle="" for timer/boot
    // child_rec = ($cid -> global_id, $role_id -> str, $name -> str,
    //              $bio -> str, $caps -> str[], $child_ad -> bin)
```
`reconcile` joins host truth ⨝ `cluster_members`:
- host child **not** in registry → **add** (backfills out-of-band/CLI children;
  the R6-2 ghost-child fix — the registry can no longer permanently under-count).
- registry member **not** in host set → **drop** (clears dead members from a lost
  `confirm_child_destroyed`).

**`$caps` (and `$bio`) are MANDATORY in `child_rec` (RR-4).** A backfilled member
with `caps=[]` reads `connectKnown=true, connect=false` at the introduce
verified-gate (§6.3) → every introduce **HARD-BLOCKS** until a later re-sync. So
the enumerate payload MUST carry the child's real caps + bio, not just identity.

**Completeness + atomicity (RR-3) [NORMATIVE].** `host_enumerate_children` MUST
return the **complete, authoritative** packet set **including half-provisioned**
packets, and `provisionIdentity` MUST make a packet **enumerable BEFORE**
`host_provision_child` is acknowledged. Without this an orphan that is
un-enumerable at reconcile time is adopted by *no* future reconcile → a permanent
ghost. With it, every orphan is eventually adopted.

**Drift is BOUNDED, not eliminated — stated honestly (RR-3).** Non-divergence is
*not* "by construction"; it is bounded by `reconcile_interval` (300 s) + every
`bind`, with two strong-read exceptions that close the dangerous gaps: (i)
`create` idempotency reads host truth before provisioning (§8(d)); (ii) the 120 s
timeout sweep reconciles synchronously before settling (§8). An out-of-band create
that slips funnel (a) is invisible to `list` for ≤300 s — a *bounded* under-count,
not a permanent one.

**Host-primitive surface — the honest count (R8-7 / RR-7 / R2 / C5).** It is **5
cross-packet host primitives + 1 OOB operator step**:
1. `host_provision_child` — spawn a packet, enumerable-before-ack (TS).
2. `host_destroy_child` — tear down a packet; **idempotent on an absent packet** (TS, RR-6).
3. `host_enumerate_children` — complete packet set incl half-provisioned (TS).
4. `host_mint_child_invite` — run `generate_invite` **IN the child's packet** (R2):
   minting a child's invite is irreducibly cross-packet (only the child can sign
   its own AD), so a root-handler compose could only ever mint the ROOT's invite
   (confused deputy). The daemon calls back `register_child_invite`. MUST reject an
   unknown/nonexistent cid cleanly.
5. `host_set_child_monitoring` — bind/clear the CHILD's `monitoring_proxy` (C5,
   §below). The daemon calls back `confirm_child_monitoring`.
6. **bind code** — the 6-digit code is **generated host-side** (MUFL has no RNG)
   and entered **out-of-band by the operator**; *verification* is in-packet
   (`verify_proxy_code`).

> **Count stays 5** (not 6): `host_set_child_monitoring`'s executor invokes the
> CORE child-side trns `host_register_monitoring_cp` + `set_proxy_pending` +
> `verify_proxy_code` (enable) / `host_clear_child_monitoring` (disable) — these are
> **core transactions the daemon merely sequences**, NOT things the app implements,
> so they are not additional host primitives. The host-implemented surface a new app
> writes is exactly the 5 above + the OOB code.

**Per-child monitoring — single-gate, host-mediated (C5) [NORMATIVE].** SECURITY-MODEL.md
**CUT** the root-signed grant / CP-signed MA; monitoring authority is the node's own
6-digit ceremony binding (the single trust anchor). So per-child monitoring is NOT a
signed grant — it host-propagates the root's ceremony:
- **ENABLE (two host steps, ordered):** a child connects to its ROOT, not the CP, so
  it can't resolve/forward to the CP yet. **(1) CP-contact injection** — the handler
  carries the CP's **verified** AD (`peer_ads[cp]`) in the notify; the daemon host-runs
  `host_register_monitoring_cp(cp_ad)` IN the child's packet, which **re-verifies** the
  AD (`process_address_document` — self-sig + proof-of-possession, rejects a forgery)
  and stores it as a contact. **The injected AD IS the ceremony-pinned CP, not an
  arbitrary root peer:** the handler computes `cp_cid = bound_cp_cid` and injects
  `cp_ad = peer_ads[cp_cid]` (keyed by that exact cid), and step 2 binds the child to
  the SAME `cp_cid` — injected contact, verified AD, and ceremony target are one CP by
  construction; never from `$args` or any other peer. This is **host-mediated, not a
  network introduce**: the
  child's introduction-acceptance gate (`require_cluster_cp_or_abort`) only accepts a
  relay from the child's OWN CP, so a ROOT-relayed introduce is **rejected** (the root
  isn't the child's CP) and a network introduce would race step 2. **(2) ceremony** —
  the daemon host-runs the REAL ceremony (`set_proxy_pending` + `verify_proxy_code`)
  IN the child's packet, binding the child's `monitoring_proxy` to that CP. The CP is
  **derived from the root's OWN ceremony-pinned `monitoring_proxy`** (`bound_cp_cid`) —
  **NEVER** a `set_monitoring` `$args` parameter (load-bearing: a child can only ever
  be bound to the root's ceremonied CP). The child's `idpk_CP` is pinned by genuine
  ceremony machinery, so "pinned-at-ceremony" stays literally true for children.
  **Consent:** the child is given ONLY the cluster CP as a contact (the minimum
  monitoring requires), controller-gated via `set_monitoring(on)`, CP AD verified.
- **DISABLE:** `host_clear_child_monitoring` clears the child's `monitoring_proxy`
  → `monitor_copy_actions` returns `[]` → forwarding genuinely stops (criterion **e**:
  real revocation, NOT a registry-flag-only no-op). It is **CP-authorized** (only via
  the controller-gated `set_monitoring(off)`) and merely **host-mediated** to the
  child; the child's app packet has **no user-origin path**, so it can **never
  self-clear** — the model's no-self-escape property holds. This is the cluster analog
  of the standalone CP-authenticated `disable_monitoring`. **Full teardown (RR9-C12):**
  disable ALSO drops the injected CP contact (`peer_ads[cp]` + `contacts[cp]`), so the
  child↔CP relationship does not outlive the monitoring it was established for; re-enable
  cheaply re-injects it.
- **NO FREE HOST PATH [load-bearing invariant]:** `host_set_child_monitoring` (enable
  AND disable) is emitted ONLY from the controller-gated `_h_set_monitoring` — never
  any other core path; and the daemon executor runs ONLY in response to that notify
  (no standalone daemon/CLI set/clear-child-monitoring command). So a local host can
  neither bind nor clear a child's monitoring without the ceremony-pinned CP
  authorizing it via `set_monitoring`.
- **(f) CP-REBIND [daemon obligation]:** on a cluster-CP rebind, the daemon MUST
  re-point (re-run enable) or clear the currently-monitored children, so no child
  keeps forwarding to a stale/old CP.
- **(i) child-visible NOTICE:** a CONSCIOUS DEFERRED CARRY — mcp-host children are
  non-human-facing, so surfacing a per-child monitoring notice is a consuming-app/UI
  obligation, not implemented here. Stated, not silently dropped (R6-3 / CLUSTER_CONTRACT.md).

**`contact` invite packing — DECISION (RR-7) [NORMATIVE].** Today
`packInvite = generate_invite (in-packet) → brotli → base64url`; **brotli is not
in MUFL**, so v0.2's "packed in-packet, no TS" was false. Resolution: **drop
brotli.** `generate_invite` already returns the raw `_write` blob (`bin`); the
`contact` `$result` carries that **raw invite `bin`**, and any base64/base64url
string-ification is a **generic, verb-agnostic transport encoding** (identical for
any `bin` payload), NOT verb-specific logic — so DoD §10 holds with **no 4th host
primitive**. *(MUFL base64 is also absent — grep-clean in mufl_stdlib+meta — so the
string encoding sits at the transport boundary, but it is generic, not per-verb.)*
**Wire-format change:** invites become **uncompressed** (larger, but ephemeral —
acceptable) and the **redeemer** drops its brotli-decompress step (core
`add_contact` is unchanged — it already `_read_or_abort`s the raw `bin`). WS-B/WS-C
must update the pack/redeem path accordingly.

**Monitoring forced-forward — fully in-packet (RR-8) [NORMATIVE].** Generation
*and delivery* are in-packet: `monitor_copy_actions` already **emits a
`send_encrypted_tx` action** to the bound proxy directly (a2a_messaging.mm:214,
same mechanism as the response envelope), so the TS `forwardMonitoring` drain
(idx:683) is **redundant** — **WS-B deletes it** (this also removes that drain's
`AdaptValue` churn). No host primitive.

**RR-8b — unbound = no copy, by DESIGN (ruled, not accidental).** When unbound,
copy-generation is **skipped** (`monitor_copy_actions` returns `[]`), so there is
no pre-bind backlog — and that is the **intended** semantics, NOT a regression to
fix with a buffer. Monitoring is a **consented** act that begins at `bind`; a
capped pre-bind buffer would deliver activity generated *before any control plane
bound* — pre-consent history — to whoever binds next, which is a **privacy
regression**. Capturing strictly **from bind forward** is the correct model. (If a
future requirement ever needs pre-bind capture it must be an explicit, consented
opt-in, not a silent buffer.)

## 10. Upgrade backfill (R8-5) [NORMATIVE]

`cluster_members` is **new** state (absent today). On the core-version bump an
existing root carries children as delegated roles + enrolled `peer_ads`, with an
**empty** registry → every child would vanish from the control plane. Fix: a
**one-time backfill** = the §9 `reconcile` run once at first boot on the new
version (seeded from `host_enumerate_children` ⨝ existing `peer_ads`/delegated
roles). Build once (§9), use for both reconcile and migration. Because the §9
`child_rec` now carries `$caps` + `$bio` (RR-4), backfilled members are introduce-
capable and bio-populated immediately — no hard-block window. `§7.4`'s "unchanged
shapes" is corrected: this registry needs an explicit backfill.

## 11. Cutover & version negotiation (R8-6) [NORMATIVE]

The control plane is a **browser packet** (cached, independently deployed) — a
hard wire-incompatible cutover is fragile. Mitigation:
- **`app_manifest_t` gains `$protocol_version: int`** (`1` = legacy JSON path,
  `2` = envelope path). It MUST be readable by **both** paths during the
  transition: the legacy TS `get_manifest` relay also surfaces `$protocol_version`,
  and the new `get_manifest` trn returns it. So a stale browser learns the daemon
  speaks envelopes **without already speaking them** (resolves the chicken-and-egg).
- Client negotiates: read `$protocol_version`; `>=2` ⇒ envelope path, else JSON.
  This negotiation is **mandatory**, replacing the v0.1 "optional feature-flag."
- Cutover ships the daemon packet + control-plane packet together per environment;
  `$protocol_version` makes a version-skew a **clean, diagnosable** mismatch
  instead of silent total failure.
- **Old-browser → new-daemon (the silent-failure direction R8-6/RR-5 actually
  cares about) [NORMATIVE].** `$protocol_version` only helps a *new* client detect
  an *old* daemon. A **cached old browser** (predating the version check, still
  sending v1 JSON) hitting a **new daemon** that has *deleted* `handleControlRequest`
  (WS-B.2) would fail **silently**. Fix: the new daemon MUST keep a **minimal
  legacy responder** that answers any v1/JSON control request with a structured
  **`{"v":1,"t":"res","error":{"code":"protocol_upgraded","message":…}}`** the old
  UI surfaces as a refresh/cache-bust prompt (or a forced cache-bust on deploy).
  This is a WS-B obligation; the contract fixes the error shape so WS-C's legacy
  build can recognize it.
- **`absent $protocol_version ⇒ assume 1 (JSON)` [NORMATIVE].** A truly
  pre-transition daemon cannot surface the field, so its absence MUST be read as
  protocol 1, never as "unknown/fail."

## 12. WS-C wire answers (messenger/PREP-WS-C.md §4)

1. **On-wire envelope shape + the `$`-key convention [NORMATIVE].** MUFL record
   fields are `$`-prefixed (`$cap`/`$verb`/`$args`/`$req_id`), but the **JS/JSON wire
   keys carry NO `$`** — the SDK bridges: `object_to_adapt_value({cap})` → MUFL
   `$cap` (adds `$`), and `GetKeys`/`Reduce("cap")` strips it. So **both directions
   use NO-`$` keys** on the wire:
   - **REQUEST** (browser → daemon): `{ "cap":…, "verb":…, "args":{…}, "req_id":… }`.
     Per **R1**, `args` is a **native nested object** (NOT a stringified JSON) — the
     daemon `object_to_adapt_value`s the whole envelope (incl. nested `args`) into the
     MUFL `control_envelope_t` so `dispatch` reads `env $cap` / `env $args` natively.
   - **RESPONSE** (daemon → browser): the marshaller walks the response via `GetKeys`
     (which returns stripped keys), emitting `{ "req_id":…, "ok":…, "result":…, "err":… }`
     and nested no-`$` keys (`cid`, `name`, `members`, `monitoring`, `invite`, `code`,
     `message`, …). WS-C parses exactly those.
   (Earlier drafts showed `$`-prefixed wire keys and a stringified `$args` — both
   superseded: no-`$` keys, native `args`, per R1 + the SDK bridge.)
2. **Error channel.** `$ok=false`, `$err={"code":…,"message":…}`. Typed errors
   the UI keys off come back in `$err.code` — specifically **`unverified_connect`**
   for the introduce gate. Force-retry: resend the same verb with
   `$args.force=true` (§6.3). The UI's existing force path maps 1:1.
3. **`bind` one-shot.** YES — `core.monitoring.bind` `$result` =
   `{"manifest":{…},"members":[…],"config":{…}}` in one response (preserves
   ControlClient 262-277 behavior).
4. **`introduce` / `disableMonitoring`.** Both **move into the envelope**
   (`core.connect.introduce`, `core.monitoring.disable`). introduce stays behind
   the SAME client-side verified-connect gate (§6.3) before `sendEnvelope` — no
   second ungated path. (The browser may still use `host.introduce` as the
   transport beneath `sendEnvelope`; semantically it is the envelope verb.)
5. **`managed_roots` / `manageRoot`.** Confirmed **out of WS-C envelope scope** —
   cluster-enrollment / `manage_root` is host-level (`::actor::list_managed_roots`),
   not a control-envelope verb. WS-C does not wrap it.

## 13. OPEN QUESTIONS

**ACCEPTED by Coordinator** (folded in): Q1 response helper → a2a_capabilities; Q2
list controller-gated; Q3 set_bio registry-only v1; Q4 set_monitoring frozen,
composition later; Q5 ttl=120s; Q6 keep both introduce verbs; **Q7** retention
600 s; **Q8** reconcile_interval 300 s; **Q9 RESOLVED (RR-4): `child_rec` carries
`$cid,$role_id,$name,$bio,$caps,$child_ad`** — caps are mandatory (else backfilled
members hard-block at introduce).

**Critic R8/RR closure status** (all folded into v0.3):
- RR-1 (callback forgery) — `origin::user` + not-a-control-verb; critic-verified
  CLOSED (§7).
- RR-2 (sender dimension) — host-unique `$pending_handle` threads `(sender,$req_id)`
  (§7/§8).
- RR-3 (drift/dup) — host-truth create dedup (§8(d)) + global pending-by-name +
  complete/atomic enumerate + sync-reconcile-on-timeout (§8/§9); drift bound stated
  honestly.
- RR-4 (caps) — Q9 resolved above.
- RR-5 (old-browser→new-daemon) — legacy responder + `protocol_upgraded` +
  `absent⇒1` (§11).
- RR-6 (deny-all) — explicit allow-list + god-mode caveat + remove-idempotency (§3/§8).
- RR-7 (invite packing) — brotli dropped; raw-bin + generic transport base64;
  **DECISION needs critic sign-off** + WS-B/C pack/redeem update (§9).
- RR-8 (monitoring delivery) — already in-packet (a2a_messaging.mm:214); WS-B
  deletes the drain (§9).
- RR-9 (non-bypassable gate) — moved INTO dispatch via injected `$authorizer` +
  fail-fast; **feasibility confirmed** (no reverse dep; mirrors init's check) (§3).

All of §3–§12 is **stable for freeze** pending critic's RR-7 sign-off. WS-B/C/D
can map against it now (passive).
