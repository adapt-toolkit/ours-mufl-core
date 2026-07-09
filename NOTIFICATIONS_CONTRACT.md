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
