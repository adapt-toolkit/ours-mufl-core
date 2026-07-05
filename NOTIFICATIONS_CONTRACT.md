# NOTIFICATIONS_CONTRACT — the `a2a_notifications` v1 surface (core 0.3)

The frozen protocol contract for Notifications-as-a-Service: a
protocol-defined **notification-service node** (an always-online packet any
operator can run) plus a `send_notification` transaction parallel to
`send_message`, so any ours identity can register for out-of-band wake-ups
(WebPush in v1), hand out a token, and any token-holder can trigger a push to
the recipient's browser(s) — even while the recipient's own packet is offline.

Library: [`a2a_notifications.mm`](./a2a_notifications.mm). Capability id:
`core.notifications` (`a2a_capabilities.mm` — reserved constant only; **no
control verbs in v1**, so `control_auth_class`/`dispatch` are untouched).

---

## ⚠️ Trust model (READ THIS FIRST)

- **The service reads every notification payload. There is NO end-to-end
  privacy from the service.** The payload travels encrypted on each transport
  leg (the wire's signed/encrypted envelopes; WebPush's own `aes128gcm`
  payload encryption), but the service node decrypts and sees the full
  plaintext, and stores it in its app-side log. Do not put secrets in
  notification payloads you would not show the service operator.
- **There is NO anti-spam in v1.** Anyone holding a recipient's handout token
  can notify that recipient without limit. The recovery path is
  `notify_rotate_token`: the old token dies instantly; senders get the new
  handout only when the recipient redistributes it.
- **Sender authorization is token possession alone.** `post_notification` is
  accepted as a **bare signed send** from a packet the service has never met
  (no contact, no encrypted channel — the invite-leg precedent). The envelope
  `$from` is wrapper-verified and *recorded* on the notification
  (`$sender_cid`) but is **informational, never authorization** (E14).
- The recipient↔service surface (register / update_bindings / rotate /
  unregister / mark_read / confirm) rides the **encrypted channel** and
  requires the peers to be contacts — established by the ordinary
  invite/introduction machinery; no new connection flow.
- The **VAPID private key never enters packet state** (and therefore never
  rides `export_notify_state`). It lives only in the host daemon's env/file.
  The packet holds the *public* key (`set_vapid_public_key`) to echo to
  clients.

## Wire shapes (frozen v1 bytes — never rename/retype a `$field`)

```mufl
// The shared sender token, minted and SIGNED by the service.
metadef notify_token_core_t: (
    $version       -> int,        // 1
    $service_cid   -> global_id,  // the issuing service (binds token to one N)
    $recipient_cid -> global_id,  // whom it notifies
    $token_id      -> global_id,  // rotation/revocation handle
    $scope         -> str,        // v1 always "" (shared); reserved for per-sender/group later
    $iat           -> time
).
metadef notify_token_t: ($c -> notify_token_core_t, $s -> crypto_signature).

// One WebPush subscription (browser PushSubscription fields).
metadef webpush_binding_t: (
    $version    -> int,   // 1
    $binding_id -> str,   // app-chosen stable id (e.g. endpoint hash)
    $endpoint   -> str,   // push service URL
    $p256dh     -> str,   // client public key, base64url
    $auth       -> str    // auth secret, base64url
).

// The handout blob R gives to senders ("to notify me: this service, this token").
metadef notify_address_t: (
    $version      -> int,        // 1
    $service_cid  -> global_id,  // bare-send routing target
    $service_name -> str,        // display only
    $token        -> notify_token_t
).

// SERVICE-side registration record (core state on N).
metadef registration_t: (
    $version       -> int,       // 1
    $recipient_cid -> global_id,
    $token         -> notify_token_t,
    $bindings      -> webpush_binding_t[],
    $created_at    -> time
).

// CLIENT-side view of my registration (core state on R).
metadef my_registration_t: (
    $service_cid  -> global_id,
    $service_name -> str,
    $token        -> notify_token_t,
    $vapid_pub    -> str,        // service's VAPID public key (browser subscribe param)
    $bindings     -> webpush_binding_t[],
    $created_at   -> time
).

// One posted notification as handed to the service app hook (LOG is app-side).
metadef notification_t: (
    $version       -> int,       // 1
    $notif_id      -> str,       // service-stamped — the mark_read handle
    $wire_id       -> str,       // sender-stamped, "" tolerated
    $recipient_cid -> global_id,
    $sender_cid    -> global_id, // envelope $from (authenticated; informational)
    $payload       -> str,       // OPAQUE to the protocol; the service reads it
    $date          -> time
).
```

Payload limit: `payload_max_bytes = 4000` (WebPush ceiling is ~4KB). Oversize
aborts on the **sender** side (`send_notification`) AND the **service** side
(`post_notification`) — defense in depth (E6).

Inbound routing: every inbound name is **library-routed**
`::a2a_notifications::<name>` (brand-new surface, no `::actor::` shims).

## Transaction surface

### Client half (compiled into every consumer)

| trn | args | behavior |
|---|---|---|
| `notify_register` | `$service -> str`, `$bindings -> webpush_binding_t[]+` | resolve the service via `a2a_messaging::resolve_contact`; encrypted send `register`; mark pending. `$bindings` NIL is valid (E11 — register first, bind after the browser subscribes). |
| `notify_update_bindings` | `$service -> str`, `$bindings -> webpush_binding_t[]` | must hold a registration; encrypted send `update_bindings` (**replace-all** semantics). |
| `notify_rotate_token` | `$service -> str` | must hold a registration; encrypted send `rotate_token`; mark pending. |
| `notify_unregister` | `$service -> str` | encrypted send `unregister`; clears the local registration + pending. |
| `notify_mark_read` | `$service -> str`, `$notif_ids -> str[]+` | must hold a registration; encrypted send `mark_read`. ids `NIL` ⇒ **mark ALL read** (the on-open default). "Dismiss" == mark_read in v1. |
| `send_notification` | `$address -> bin`, `$payload -> str` | parse the handout (version == 1); abort oversize; stamp a `wire_id` (shared `_new_id` namespace); **ONE bare signed send** of `post_notification` to the blob's `$service_cid`; `_return_data ($sent_to, $wire_id)`. **No monitoring copy** (D-4) — the forced-monitoring contract covers *messages*. Fire-and-forget: no response leg. |
| `export_notify_address` (readonly) | `$service -> str` | the handout blob (`_write` of `notify_address_t`) from the stored registration. Distribution rides ordinary messaging. |
| `confirm_registration` (INBOUND, external + encrypted) | token, vapid_pub, bindings | `$from` must be a **pending or already-registered** service (E9 — an unsolicited confirm cannot plant a registration); stores `my_registration_t`; clears pending; fires `on_notify_registration`. |

### Service half (a notifier packet)

| trn | channel | behavior |
|---|---|---|
| `set_vapid_public_key` | user-origin (host boot) | store the PUBLIC key echoed in every confirm. |
| `register` | encrypted required | recipient = envelope `$from`; mint + store token & registration; reply `confirm_registration`. **Re-register keeps the token** (D-5/E8) and replaces bindings only when provided — a lost confirm never invalidates distributed handouts. |
| `update_bindings` | encrypted required | must be registered; replace bindings wholesale; re-confirm (idempotent). |
| `rotate_token` | encrypted required | must be registered; **delete the old `token_id` index entry** (old handouts die instantly — E4), mint/store/index a fresh token, re-confirm. Rotation replaces revocation (D-3); revoke-without-replace == `unregister`. |
| `unregister` | encrypted required | delete registration + index entry; fire `on_unregistered`. |
| `post_notification` | **bare signed accepted** (no `check_encrypted_or_abort`) | validate the token (order below); build `notification_t`; fire `on_notification_posted` with the recipient's current bindings; **NO reply**. |
| `mark_read` | encrypted required | `$from` must hold a registration; fire `on_notifications_marked_read` with `($recipient_cid, $notif_ids /* NIL = ALL */)` — only ever the caller's own cid, so one recipient cannot mark another's log (E7). |

### Token validation in `post_notification` (order matters; abort on first failure, mutate nothing)

1. Parse: `$token` `safe notify_token_t`; `$c $version == 1`.
2. `$c $service_cid == _get_container_id()` — minted by THIS service.
3. Index lookup: `notify_token_index ($c $token_id)` must exist and equal
   `$c $recipient_cid` — rotation/unregister removed entries, so **revocation
   is a state lookup**, not a signature question.
4. **Byte-equality** against the stored registration's token:
   `_value_id (presented) == _value_id (stored)` — forging any field
   (`$scope` included) requires possessing the exact minted artifact. No
   signature re-verification on the service: it compares against what it
   itself stored. (The signature exists so *clients* can verify a handout
   against the service's pinned keys; client-side verification is not a v1
   requirement.)
5. Payload size ≤ `payload_max_bytes`.

## State & hooks

Client state: `my_notify_registrations (global_id ->> my_registration_t)`,
`pending_notify_registers (global_id ->> bool)` (transient). Service state:
`notify_registrations (global_id ->> registration_t)`, `notify_token_index
(global_id ->> global_id)`, `vapid_public_key str`. Non-hidden (the
contacts/peer_ads posture); only the hooks are hidden.

`init` wires `$_read_or_abort` + four app hooks (unset hooks abort):
`on_notification_posted ($notification, $bindings)` ·
`on_notifications_marked_read ($recipient_cid, $notif_ids /*NIL=all*/)` ·
`on_unregistered ($recipient_cid)` · `on_notify_registration ($service_cid,
$registration)`. Consumers wire no-ops for the half they don't play.

Persistence: `export_notify_state` / `import_notify_state` — compose them into
the app's `export_state`/`import_state` beside `export_core_state`. The
export contains **no secret material by construction**.

## Edge cases (the frozen abort/tolerate matrix)

| # | Case | Behavior |
|---|---|---|
| E1 | recipient-surface trn arriving unencrypted / from a non-contact | abort (`check_encrypted_or_abort`). |
| E2 | `post_notification` with unparseable / version≠1 token | abort, no state change. |
| E3 | token minted by another service | abort. |
| E4 | rotated/revoked token (`token_id` not indexed) | abort — this IS revocation. |
| E5 | token fields differ from the stored artifact (`_value_id` mismatch) | abort (forgery). |
| E6 | payload > 4000 | abort on sender AND service. |
| E7 | `mark_read` with foreign/nonexistent ids | hook only ever gets the caller's own cid; the daemon ignores non-matching ids (idempotent). |
| E8 | re-`register` while registered | keep token, replace bindings when provided, re-confirm. |
| E9 | `confirm_registration` from a non-pending, non-registered sender | abort (cannot plant a registration). |
| E10 | duplicate `post_notification` (same `wire_id`) | v1: delivered twice — **no dedup**, documented. |
| E11 | registration with zero bindings | valid — logged, nothing pushed, bindings added later. |
| E12 | WebPush endpoint 404/410/5xx | daemon logs and continues (binding auto-prune is a non-v1 enhancement). |
| E13 | daemon restart | packet state restores via the export/import helpers; the log is the daemon's own file; in-flight posts lost at most once (fire-and-forget contract). |
| E14 | `$from` spoofing concern | `$sender_cid` is informational; authorization is the token alone. |
| E15 | consumers compiled without this library | unaffected — inbound names are library-routed and never sent to them; no existing shape changed. |

## Versioning

Shipped in core **0.1.0** (MIN — purely additive: one new library, one
capability constant, one config export; no existing wire shape or verification
path touched). See `release-notes/0.1.md`.

---

# v2 additions (core 0.4) — per-contact notification tokens

This section is **frozen** against the `a2a_notifications.mm` surface as of core 0.4.0
(branch `feat/a2a-notifications-v2`, HEAD 7feddf2). Read the v1 sections above first — v2
extends, does not replace, every v1 guarantee.

## ⚠️ Trust model addendum (READ THIS TOO)

- **The payload-visibility and no-rate-limiting guarantees are unchanged in v2.**
  The service still reads every notification payload; there is still no anti-spam.
  These are explicit v2 non-goals — see §Non-goals below.
- **For SCOPED tokens, `$from` is now authorization, not merely informational.**
  The envelope `$from` (wrapper-verified by the send primitive) must match the token's
  `$scope` cid or the post is rejected. This is the principal security upgrade of v2:
  a stolen scoped handout is useless without the named sender's signing key. Legacy
  (shared, scope-`""`) tokens keep pure possession semantics until retired (see E14
  addendum and the retire path below).
- **The service learns per-contact mute flags** (the cardinality of each recipient's
  muted senders). The service could already infer senders from `$sender_cid` on every
  post; the mute flags are the marginal new disclosure.

## The per-sender token model

The `$scope` field in `notify_token_core_t` (always `""` in v1, reserved for later use) is
v2's extension point. A **scoped token** is a standard v1 token whose `$scope` is set to
`_str(sender_cid)`. All other fields are unchanged:

- Token `$version` stays `1` — no wire-shape change.
- `notify_address_t` stays version `1` — un-upgraded senders treat the blob as opaque and
  post the embedded scoped token verbatim. They work as long as they post from the cid
  named in `$scope`.
- Byte-equality validation (step 4) already covers `$scope`: an attacker cannot re-scope a
  token without possessing the exact minted artifact.
- Scoped tokens are indexed in the **same** `notify_token_index` as shared tokens, so
  rotation and revocation-by-index-delete (E4) work identically.

**Shared-token lifecycle in v2:** `handle_register` continues to mint and index a shared
(scope-`""`) token for every new registration, exactly as in v1. The shared token remains
valid at the service until explicitly retired via `retire_shared`. Retirement deletes its
index entry; the registration record and all scoped tokens keep working. This is the
deliberate choice: full v1 back-compat by default, retirement is an opt-in step.

## New service-half inbounds (v2)

All new inbounds require an **encrypted channel** (`check_encrypted_or_abort`) and a
**live registration** for the sender (`notify_registrations [$from]` must exist). Absent
registration → abort `"No notification registration for this sender."` (the shared gate
pattern, same as `update_bindings`).

| trn | args | behavior |
|---|---|---|
| `issue_tokens` | `$senders -> global_id[]+` | For each sender: if a scoped token already exists for (recipient, sender), keep it (idempotent, E8). Otherwise `mint_notify_token_scoped recipient (_str sender)` and index `token_id → recipient`. Batch capped at `issue_max_senders = 256` — oversized batches abort (V12 defense). Re-confirms after all mints. |
| `set_sender_muted` | `$sender -> global_id`, `$muted -> bool` | `$muted TRUE` → write a flag entry into `notify_sender_muted[recipient][sender]` (presence = muted; absent = enabled). `$muted FALSE` → delete the entry (absent = enabled, minimal state). No token change; no redistribution. Re-confirms. |
| `revoke_sender_tokens` | `$senders -> global_id[]` | For each sender: delete its scoped `token_id` from `notify_token_index` (posts abort at step 3 — E4) and delete its slot from `notify_sender_tokens`. No re-mint (revoke-without-replace). Idempotent: unknown senders tolerated. Re-confirms. |
| `retire_shared` | (none) | Delete the shared token's `token_id` from `notify_token_index`. Posts using the old shared handout now abort at step 3. Registration record and scoped tokens unaffected. Idempotent: already-absent entry is a no-op. Re-confirms. |

**`rotate_token` extension (optional `$sender`):**

- `$sender` present → per-sender rotation: delete ONLY that sender's old scoped token from the
  index, mint a fresh scoped token, store and index it. Other senders' tokens untouched.
  Abort `"No scoped token for this sender."` if the sender slot does not exist.
- `$sender` absent/NIL → **rotate-all** (Q9 panic button): (a) shared token — if currently
  indexed, delete and re-mint and re-index; if NOT indexed (already retired), mint and store
  a new inert shared token but do NOT re-index (rotate-all does not un-retire); (b) ALL scoped
  tokens — two-pass (collect sender keys, then rotate each slot atomically). Every old handout
  dies instantly (E4 semantics). Re-confirms with the full updated maps.

## New client-half transactions (v2)

| trn | args | behavior |
|---|---|---|
| `notify_issue_tokens` | `$service -> str`, `$contacts -> global_id[]` | Pages `$contacts` into batches of `issue_max_senders`; sends one `issue_tokens` per batch over the encrypted channel. |
| `notify_set_sender_muted` | `$service -> str`, `$contact -> global_id`, `$muted -> bool` | Encrypted send `set_sender_muted ($sender, $muted)`. |
| `notify_revoke_contact_tokens` | `$service -> str`, `$contacts -> global_id[]` | Encrypted send `revoke_sender_tokens ($senders)`. |
| `notify_retire_shared` | `$service -> str` | Encrypted send `retire_shared`. |
| `notify_rotate_token` | `$service -> str`, `$contact -> str+` | `$contact` present → resolves via `resolve_contact` and sends `rotate_token ($sender)`. `$contact` NIL → sends `rotate_token` with empty targ (rotate-all path). |

## Confirm extension (`$sender_tokens` / `$sender_muted`)

Every `confirm_actions` call now includes two additional fields in the
`confirm_registration` targ sent to the client:

```
$sender_tokens -> (global_id ->> notify_token_t)   // full current per-sender map
$sender_muted  -> (global_id ->> bool)              // full current mute map
```

Old clients read only `$token`, `$vapid_pub`, `$bindings` from the confirm record — unknown
fields are ignored — so this extension is additive-safe. New clients replace
`my_notify_contact_tokens[service]` wholesale from `$sender_tokens` on each confirm; the
confirm is the single source of truth and re-confirms are idempotent replays.

## Token validation in `post_notification` — v2 order (order matters; abort on first failure, mutate nothing)

Steps 1–3 are unchanged from v1. Step 4 now dispatches on `$scope`; steps 5–6 are new
scoped-only checks. The two new abort strings are reproduced exactly from the code.

1. Parse: `safe notify_token_t`; `$c $version == 1`.
2. `$c $service_cid == _get_container_id()` — minted by this service.
3. Index lookup: `notify_token_index ($c $token_id)` must exist and equal `$c $recipient_cid`.
   Additionally: `notify_registrations ($c $recipient_cid)` must exist (the registration may
   have been unregistered after tokens were indexed).
4. **Dispatch on `$scope`:**
   - `""` (legacy/shared path) → byte-equality: `_value_id (presented) == _value_id (registration_t.$token)`.
     Reachable only while the shared token's index entry is live (step 3 kills it after `retire_shared`).
   - non-`""` (scoped path) → two checks in this order:
     1. **Sender binding:** envelope `$from` must satisfy `$scope == _str($from)`. If the outer
        `notify_sender_tokens[recipient]` map is absent, or the sender slot is absent, or
        `$scope != _str($from)` → abort **`"Token is not bound to this sender."`**
     2. **Byte-equality:** `_value_id (presented) == _value_id (notify_sender_tokens[recipient][sender])`
        → abort `"Presented token does not match the stored registration."` on mismatch.
5. **Mute check (scoped only):** `notify_sender_muted[recipient][sender]` — if the entry is
   **present** (any value; present = muted, absent = enabled) →
   abort **`"Notifications from this sender are disabled."`** Nothing is stored or pushed.
   The abort is invisible to the sender: `post_notification` has no reply leg.
6. Payload ≤ `payload_max_bytes`.

**Note on step 4 ordering:** Sender binding is evaluated before byte-equality in the scoped
path. This is intentional (the code cannot reverse `_str(sender_id)` back to a `global_id`
without the bound identity already in hand from the binding check) and is the correct order
to document — it matches what the code at HEAD enforces.

## New state (additive; individually guarded on import)

**Service half:**
```mufl
// recipient -> (sender -> scoped token). Minted by issue_tokens.
notify_sender_tokens is (global_id ->> (global_id ->> notify_token_t)) = (,).
// recipient -> (sender -> present-entry-means-muted). Absent = enabled.
notify_sender_muted  is (global_id ->> (global_id ->> bool)) = (,).
```

**Client half:**
```mufl
// service -> (contact -> scoped token returned in the last confirm).
my_notify_contact_tokens is (global_id ->> (global_id ->> notify_token_t)) = (,).
```

`export_notify_state` / `import_notify_state` gain all three fields. A v1-era export
imports unchanged (fields absent → defaults in place). No `format_version` bump — this
change is mufl-compatible/additive per the upgrade-epic classification.

## Edge cases — v2 extension (V1–V14)

These rows extend the E1–E15 matrix above. The "V" prefix indicates v2-only scenarios;
v1 edge cases are unchanged.

| # | Case | Behavior |
|---|---|---|
| V1 | `issue_tokens` called for a cid that is not the recipient's contact | Token is minted (the service cannot and must not know the recipient's contact set; any cid R names is eligible). Harmless orphan; cleaned by `rotate_token` (rotate-all) or `revoke_sender_tokens`. |
| V2 | Contact removed after their scoped token was issued | Actor deletes the handout ledger entry; host fires `notify_revoke_contact_tokens [cid]` (best-effort). If that call never lands (service unreachable), the orphan token remains valid only for posts from that specific sender cid (sender binding enforces this). Rotate-all clears stragglers. |
| V3 | `post_notification` with a scoped token from a muted sender | Aborts at step 5 (`"Notifications from this sender are disabled."`); nothing stored or pushed; invisible to sender (no reply leg). |
| V4 | Scoped token presented with `$from ≠ $scope` | Aborts at step 4 (`"Token is not bound to this sender."`); logged by the daemon via the existing inbound-rejected path. |
| V5 | Confirm lost after `issue_tokens` | Client re-calls `issue_tokens` — idempotent (existing tokens kept, E8). Re-confirm replays the full per-sender map. |
| V6 | Reconcile pass while a contact is degraded (no peer address document) | Skip that contact; ledger entry stays dirty; retried when the address document returns. Same deferred-channel posture as the v1 `share_notify_address` guard. |
| V7 | Legacy (un-upgraded) peer receives a v2 scoped blob | Stores it (handout shape is identical); never sends an ack. Retry cap stops resends. The contact can still post — the scoped token is valid for posts from its cid. |
| V8 | v2 peer receives a legacy shared blob (from an un-upgraded recipient) | Stores it; posts work as today. No generation field → no ack sent; treated as best-effort (today's deployed semantics, no regression). |
| V9 | Two devices / stale blob overwrite (LWW hazard) | Ledger and token maps ride the same blob; LWW skew can resend handouts (idempotent) or re-issue (idempotent — E8). Converges. Pre-existing accepted hazard. |
| V10 | Service switch mid-flight while a rotation distribution is pending on the old service | `notify_mark_dirty` with the new `$service_cid` supersedes the in-flight generation. Per-contact monotonic generation numbers mean late acks from the old service cannot regress the new service's state (`max()` in the ack handler). |
| V11 | Recipient with zero contacts binds | Backfill (`issue_tokens` over contacts) is a no-op; no `issue_tokens` call is made. The first `contact_added` event triggers the normal per-contact issue + distribute path. |
| V12 | `issue_tokens` with more than 256 senders in one call | Service aborts with `"issue_tokens batch exceeds the 256-sender cap — V12."` (defense in depth). The client wrapper `notify_issue_tokens` pages automatically; callers that bypass the wrapper must page themselves. |
| V13 | Duplicate `post_notification` (same `wire_id`) | Unchanged from v1 (E10) — delivered twice, no dedup. |
| V14 | Recipient unbinds service B before shared-token retirement of service A (overlap window) | Registrations are independent; ledger entries pointing at B go stale. A later `notify_mark_dirty` toward A restores coherent state. The UI surfaces pending contacts. |

## E14 addendum — sender binding upgrade for scoped tokens

The v1 contract (E14) states: `$sender_cid` is informational; authorization is the token alone.
This remains true for **legacy shared tokens** (scope `""`): possession of the token is the
sole grant, as deployed.

For **scoped tokens** (scope = `_str(sender_cid)`) the upgrade is: envelope `$from`
(wrapper-verified by the `send` primitive — not forge-able by payload manipulation) must equal
the token's embedded `$scope`. This makes `$from` authorization-grade for the scoped path.
A stolen scoped handout is useless without the named sender's signing key. The transition is
per-token, per-contact, and gradual: legacy tokens keep possession-only semantics until
`retire_shared` is called.

## Non-goals (v2 — explicit)

The following **do not improve in v2** and are restated as non-goals:

- **Payload privacy from the service.** The service decrypts and reads every notification
  payload. Transport legs (wire envelopes, WebPush `aes128gcm`) are encrypted, but the service
  node sees plaintext. Do not put secrets in payloads you would not show the service operator.
- **Rate limiting / anti-spam.** No rate limit is enforced on `post_notification`. The recovery
  path for abuse remains token rotation: per-contact (`rotate_token ($sender)`) for a known
  abuser, or rotate-all for a leak of unknown origin. Revocation (`revoke_sender_tokens`) is
  the no-replace alternative for contact removal.

## Versioning

`a2a_notifications` v2 surface shipped in core **0.4.0** (MINOR — additive new names, no
format_version bump, no existing wire shape or verification path changed). See
`release-notes/0.4.md`.
