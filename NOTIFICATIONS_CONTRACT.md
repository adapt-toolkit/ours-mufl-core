# NOTIFICATIONS_CONTRACT — the `a2a_notifications` surface (core 0.4)

The frozen protocol contract for Notifications-as-a-Service: a
protocol-defined **notification-service node** (an always-online packet any
operator can run) plus a `send_notification` transaction parallel to
`send_message`, so any ours identity can register for out-of-band wake-ups
(WebPush), hand out **per-contact tokens**, and each token-holder can trigger
a push to the recipient's browser(s) — even while the recipient's own packet
is offline.

Tokens are **per-contact only**: every token is scoped to exactly one
(recipient, sender) pair via `$scope == _str(sender_cid)`. There is no shared
token, no unscoped fallback, and registration itself mints nothing — tokens
come exclusively from `issue_tokens`.

Library: [`a2a_notifications.mm`](./a2a_notifications.mm). Capability id:
`core.notifications` (`a2a_capabilities.mm` — reserved constant only; **no
control verbs**, so `control_auth_class`/`dispatch` are untouched).

---

## ⚠️ Trust model (READ THIS FIRST)

- **The service reads every notification payload. There is NO end-to-end
  privacy from the service.** The payload travels encrypted on each transport
  leg (the wire's signed/encrypted envelopes; WebPush's own `aes128gcm`
  payload encryption), but the service node decrypts and sees the full
  plaintext, and stores it in its app-side log. Do not put secrets in
  notification payloads you would not show the service operator.
- **There is NO rate limiting / anti-spam.** A contact holding their handout
  can notify the recipient without limit. The recovery paths are per-contact:
  `rotate_token ($sender)` for a known abuser (their old handout dies
  instantly), `revoke_sender_tokens` for contact removal (no re-mint), and
  rotate-all as the panic button for a leak of unknown origin. A leak only
  ever exposes ONE relationship's channel.
- **Sender authorization is scoped-token possession PLUS sender binding.**
  `post_notification` is accepted as a **bare signed send** from a packet the
  service has never met (no contact, no encrypted channel — the invite-leg
  precedent). The envelope `$from` is wrapper-verified by the send primitive
  and MUST equal the token's `$scope` — a stolen handout is useless without
  the named sender's signing key. `$from` is also recorded on the notification
  (`$sender_cid`), giving per-relationship attribution.
- **The service learns per-contact mute flags** (which of a recipient's
  contacts are muted). The service already sees `$sender_cid` on every post,
  so the mute flags are the marginal disclosure.
- The recipient↔service surface (register / update_bindings / issue_tokens /
  rotate / set_sender_muted / revoke / unregister / mark_read / confirm) rides
  the **encrypted channel** and requires the peers to be contacts —
  established by the ordinary invite/introduction machinery; no new
  connection flow.
- The **VAPID private key never enters packet state** (and therefore never
  rides `export_notify_state`). It lives only in the host daemon's env/file.
  The packet holds the *public* key (`set_vapid_public_key`) to echo to
  clients.

## Wire shapes (frozen bytes — never rename/retype a `$field`)

```mufl
// The per-contact sender token, minted and SIGNED by the service.
metadef notify_token_core_t: (
    $version       -> int,        // 1
    $service_cid   -> global_id,  // the issuing service (binds token to one N)
    $recipient_cid -> global_id,  // whom it notifies
    $token_id      -> global_id,  // rotation/revocation handle
    $scope         -> str,        // _str of the SENDER cid this token is issued to
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

// The handout blob R gives to ONE sender ("to notify me: this service, YOUR token").
metadef notify_address_t: (
    $version      -> int,        // 1
    $service_cid  -> global_id,  // bare-send routing target
    $service_name -> str,        // display only
    $token        -> notify_token_t
).

// SERVICE-side registration record (core state on N). Carries NO token —
// per-contact tokens live in notify_sender_tokens, minted only by issue_tokens.
metadef registration_t: (
    $version       -> int,       // 1
    $recipient_cid -> global_id,
    $bindings      -> webpush_binding_t[],
    $created_at    -> time
).

// CLIENT-side view of my registration (core state on R).
metadef my_registration_t: (
    $service_cid  -> global_id,
    $service_name -> str,
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
    $sender_cid    -> global_id, // envelope $from (authenticated; == token $scope by validation)
    $payload       -> str,       // OPAQUE to the protocol; the service reads it
    $date          -> time
).
```

Payload limit: `payload_max_bytes = 4000` (WebPush ceiling is ~4KB). Oversize
aborts on the **sender** side (`send_notification`) AND the **service** side
(`post_notification`) — defense in depth (E6).

Issuance batch limit: `issue_max_senders = 256` per `issue_tokens` call;
oversized batches abort (V12). The client wrapper pages automatically.

Inbound routing: every inbound name is **library-routed**
`::a2a_notifications::<name>` (no `::actor::` shims).

## Transaction surface

### Client half (compiled into every consumer)

| trn | args | behavior |
|---|---|---|
| `notify_register` | `$service -> str`, `$bindings -> webpush_binding_t[]+` | resolve the service via `a2a_messaging::resolve_contact`; encrypted send `register`; mark pending. `$bindings` NIL is valid (E11 — register first, bind after the browser subscribes). Registration mints NO token. |
| `notify_update_bindings` | `$service -> str`, `$bindings -> webpush_binding_t[]` | must hold a registration; encrypted send `update_bindings` (**replace-all** semantics). |
| `notify_issue_tokens` | `$service -> str`, `$contacts -> global_id[]` | must hold a registration; pages `$contacts` into batches of `issue_max_senders`; one encrypted `issue_tokens` send per batch. |
| `notify_rotate_token` | `$service -> str`, `$contact -> str+` | must hold a registration. `$contact` present → resolve via `resolve_contact`, encrypted send `rotate_token ($sender)` (rotate ONE contact's token). `$contact` NIL → `rotate_token` with empty targ (rotate-ALL panic button). Marks pending. |
| `notify_set_sender_muted` | `$service -> str`, `$contact -> global_id`, `$muted -> bool` | must hold a registration; encrypted send `set_sender_muted ($sender, $muted)`. Runtime-only toggle — no token change, no redistribution. |
| `notify_revoke_contact_tokens` | `$service -> str`, `$contacts -> global_id[]` | must hold a registration; encrypted send `revoke_sender_tokens ($senders)` (delete-without-remint — the contact-removal path). |
| `notify_unregister` | `$service -> str` | encrypted send `unregister`; clears the local registration + pending. |
| `notify_mark_read` | `$service -> str`, `$notif_ids -> str[]+` | must hold a registration; encrypted send `mark_read`. ids `NIL` ⇒ **mark ALL read** (the on-open default). "Dismiss" == mark_read. |
| `send_notification` | `$address -> bin`, `$payload -> str` | parse the handout (version == 1); abort oversize; stamp a `wire_id` (shared `_new_id` namespace); **ONE bare signed send** of `post_notification` to the blob's `$service_cid`; `_return_data ($sent_to, $wire_id)`. **No monitoring copy** (D-4) — the forced-monitoring contract covers *messages*. Fire-and-forget: no response leg. |
| `export_notify_address` (readonly) | `$service -> str`, `$contact -> str` | the per-contact handout blob (`_write` of `notify_address_t` wrapping `my_notify_contact_tokens[service][contact]`). Aborts if no scoped token exists yet (`issue_tokens` first). Distribution rides ordinary messaging or the messenger's distribution engine. |
| `confirm_registration` (INBOUND, external + encrypted) | vapid_pub, bindings, sender_tokens, sender_muted | `$from` must be a **pending or already-registered** service (E9 — an unsolicited confirm cannot plant a registration); stores `my_registration_t`; replaces `my_notify_contact_tokens[service]` **wholesale** from `$sender_tokens`; clears pending; fires `on_notify_registration` with the token AND mute maps. |

### Service half (a notifier packet)

All recipient-surface inbounds require an **encrypted channel**
(`check_encrypted_or_abort`) and — except `register` — a **live registration**
for the sender (abort `"No notification registration for this sender."`, the
shared gate pattern).

| trn | channel | behavior |
|---|---|---|
| `set_vapid_public_key` | user-origin (host boot) | store the PUBLIC key echoed in every confirm. |
| `register` | encrypted required | recipient = envelope `$from`; store a registration record (**mints NOTHING** — tokens come only from `issue_tokens`); reply `confirm_registration`. **Re-register is idempotent** (E8): existing scoped tokens untouched, bindings replaced only when provided, re-confirm either way. |
| `update_bindings` | encrypted required | must be registered; replace bindings wholesale; re-confirm (idempotent). |
| `issue_tokens` | encrypted required | `$senders -> global_id[]+` (non-empty, ≤ 256 — V11/V12). For each sender: existing scoped token → **kept** (idempotent, E8); else `mint_notify_token_scoped recipient (_str sender)`, store in `notify_sender_tokens[recipient][sender]`, index `token_id → recipient`. Re-confirms with the full maps. |
| `rotate_token` | encrypted required | `$sender` present → delete ONLY that sender's old `token_id` index entry, mint/store/index a fresh scoped token (abort `"No scoped token for this sender."` when the slot is absent). `$sender` absent → **rotate-all**: every scoped slot, two-pass (collect keys, then rotate). Old handouts die instantly (E4). Re-confirms. |
| `set_sender_muted` | encrypted required | `$muted TRUE` → write a flag entry into `notify_sender_muted[recipient][sender]` (**present = muted**); `$muted FALSE` → delete the entry (**absent = enabled**, minimal state). No token change. Re-confirms. |
| `revoke_sender_tokens` | encrypted required | for each sender: delete its scoped `token_id` from the index (posts abort at step 3 — E4) AND its `notify_sender_tokens` slot. **No re-mint.** Idempotent: unknown senders tolerated. Re-confirms. |
| `unregister` | encrypted required | full teardown: registration, EVERY scoped token (slot + index entry) and the mute map removed; fire `on_unregistered`. Re-register + issue_tokens starts from a clean slate. |
| `post_notification` | **bare signed accepted** (no `check_encrypted_or_abort`) | validate the token (order below); build `notification_t`; fire `on_notification_posted` with the recipient's current bindings; **NO reply**. |
| `mark_read` | encrypted required | `$from` must hold a registration; fire `on_notifications_marked_read` with `($recipient_cid, $notif_ids /* NIL = ALL */)` — only ever the caller's own cid, so one recipient cannot mark another's log (E7). |

### Token validation in `post_notification` (order matters; abort on first failure, mutate nothing)

1. Parse: `$token` `safe notify_token_t`; `$c $version == 1`.
2. `$c $service_cid == _get_container_id()` — minted by THIS service.
3. Index lookup: `notify_token_index ($c $token_id)` must exist and equal
   `$c $recipient_cid` — rotation/revocation/unregister removed entries, so
   **revocation is a state lookup**, not a signature question. Additionally
   `notify_registrations ($c $recipient_cid)` must exist.
4. **Sender binding:** envelope `$from` must satisfy
   `$scope == _str($from)` — abort **`"Token is not bound to this sender."`**
   A token with any other scope (including the empty string) dies here.
   (Binding is evaluated before byte-equality: mufl cannot reverse
   `_str(sender_id)` back to a `global_id`, so the bound identity comes from
   the envelope; observably equivalent to checking equality first.)
5. **Byte-equality** against the stored scoped token:
   `_value_id (presented) == _value_id (notify_sender_tokens[recipient][sender])`
   — absent outer map / absent sender slot abort
   `"Token is not bound to this sender."` (never-issued or revoked); a
   mismatch aborts `"Presented token does not match the stored registration."`
   Forging any field (`$scope` included) requires possessing the exact minted
   artifact. No signature re-verification on the service: it compares against
   what it itself stored. (The signature exists so *clients* can verify a
   handout against the service's pinned keys.)
6. **Mute check:** `notify_sender_muted[recipient][sender]` — if the entry is
   **present** (present = muted, absent = enabled) → abort
   **`"Notifications from this sender are disabled."`** Nothing stored,
   nothing pushed. The abort is invisible to the sender:
   `post_notification` has no reply leg, so mute state cannot be probed.
7. Payload size ≤ `payload_max_bytes`.

## Confirm shape (`confirm_registration` targ)

Every service-side mutator (register / update_bindings / issue_tokens /
rotate_token / set_sender_muted / revoke_sender_tokens) replies with the same
idempotent confirm:

```
$vapid_pub     -> str
$bindings      -> webpush_binding_t[]
$sender_tokens -> (global_id ->> notify_token_t)   // full current per-sender map
$sender_muted  -> (global_id ->> bool)              // full current mute map
```

The client replaces `my_notify_contact_tokens[service]` **wholesale** from
`$sender_tokens` on each confirm — the confirm is the single source of truth
and re-confirms are idempotent replays (E8 recovery: a lost confirm is healed
by any later confirm).

## State & hooks

Client state: `my_notify_registrations (global_id ->> my_registration_t)`,
`pending_notify_registers (global_id ->> bool)` (transient),
`my_notify_contact_tokens (global_id ->> (global_id ->> notify_token_t))`.
Service state: `notify_registrations (global_id ->> registration_t)`,
`notify_token_index (global_id ->> global_id)`,
`notify_sender_tokens (global_id ->> (global_id ->> notify_token_t))`,
`notify_sender_muted (global_id ->> (global_id ->> bool))`,
`vapid_public_key str`. Non-hidden (the contacts/peer_ads posture); only the
hooks are hidden.

`init` wires `$_read_or_abort` + four app hooks (unset hooks abort):
`on_notification_posted ($notification, $bindings)` ·
`on_notifications_marked_read ($recipient_cid, $notif_ids /*NIL=all*/)` ·
`on_unregistered ($recipient_cid)` · `on_notify_registration ($service_cid,
$registration, $sender_tokens, $sender_muted)` — the token and mute maps let
a consumer (e.g. the messenger's distribution engine) diff/mirror per-contact
state on every confirm. Consumers wire no-ops for the half they don't play.

Persistence: `export_notify_state` / `import_notify_state` — compose them into
the app's `export_state`/`import_state` beside `export_core_state`. Every
field is individually guarded on import (absent → default stays). The export
contains **no secret material by construction**.

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
| E8 | re-`register` while registered | keep scoped tokens, replace bindings when provided, re-confirm. Re-`issue_tokens` keeps existing tokens (byte-stable). |
| E9 | `confirm_registration` from a non-pending, non-registered sender | abort (cannot plant a registration). |
| E10 | duplicate `post_notification` (same `wire_id`) | delivered twice — **no dedup**, documented. |
| E11 | registration with zero bindings | valid — logged, nothing pushed, bindings added later. |
| E12 | WebPush endpoint 404/410/5xx | daemon logs and continues (binding auto-prune is a later enhancement). |
| E13 | daemon restart | packet state restores via the export/import helpers; the log is the daemon's own file; in-flight posts lost at most once (fire-and-forget contract). |
| E14 | `$from` spoofing concern | `$from` is wrapper-verified by the send primitive (not forge-able by payload manipulation) and is **authorization-grade**: it must equal the token's `$scope` (validation step 4). |
| E15 | consumers compiled without this library | unaffected — inbound names are library-routed and never sent to them. |
| V1 | `issue_tokens` for a cid that is not the recipient's contact | Token is minted (the service cannot and must not know the recipient's contact set; any cid R names is eligible). Harmless orphan; cleaned by rotate-all or `revoke_sender_tokens`. |
| V2 | Contact removed after their scoped token was issued | Host fires `notify_revoke_contact_tokens [cid]` (best-effort). If that call never lands (service unreachable), the orphan token remains valid only for posts from that specific sender cid (sender binding). Rotate-all clears stragglers. |
| V3 | `post_notification` from a muted sender | Aborts at step 6; nothing stored or pushed; invisible to the sender (no reply leg). |
| V4 | Token presented with `$from ≠ $scope` | Aborts at step 4 (`"Token is not bound to this sender."`); logged by the daemon via the existing inbound-rejected path. |
| V5 | Confirm lost after `issue_tokens` | Client re-calls `issue_tokens` — idempotent (existing tokens kept, E8). Re-confirm replays the full per-sender map. |
| V6 | Distribution while a contact is degraded (no peer address document) | The messenger engine skips that contact; its ledger entry stays dirty; retried when the address document returns. |
| V7 | A peer that ignores the handout's `$gen` field | Stores the blob (shape-identical), never acks; the engine's retry cap stops resends. Posting still works — the scoped token is valid for posts from its cid. |
| V9 | Two devices / stale blob overwrite (LWW hazard) | Ledger and token maps ride the same blob; LWW skew can resend handouts (idempotent) or re-issue (idempotent — E8). Converges. Pre-existing accepted hazard. |
| V10 | Service switch mid-flight while a rotation distribution is pending on the old service | `notify_mark_dirty` with the new `$service_cid` supersedes the in-flight generation. Per-contact monotonic generation numbers mean late acks from the old service cannot regress the new service's state (`max()` in the ack handler). |
| V11 | Recipient with zero contacts binds | Backfill (`issue_tokens` over contacts) is a no-op; no `issue_tokens` call is made. The first `contact_added` event triggers the normal per-contact issue + distribute path. |
| V12 | `issue_tokens` with more than 256 senders in one call | Service aborts with `"issue_tokens batch exceeds the 256-sender cap — V12."` (defense in depth). The client wrapper pages automatically; callers that bypass the wrapper must page themselves. |
| V13 | Duplicate `post_notification` (same `wire_id`) | == E10 — delivered twice, no dedup. |
| V14 | Recipient unbinds a newly-switched-to service B during the A→B overlap window | Registrations are independent; ledger entries pointing at B go stale. A later `notify_mark_dirty` toward A restores coherent state. The UI surfaces pending contacts. |

## Non-goals (explicit)

- **Payload privacy from the service.** The service decrypts and reads every
  notification payload. Do not put secrets in payloads you would not show the
  service operator.
- **Rate limiting / anti-spam.** No rate limit is enforced on
  `post_notification`. The recovery path for abuse is per-contact rotation or
  revocation; rotate-all for a leak of unknown origin.
- Notification dedup (E10), WebPush binding auto-prune (E12), non-contact
  ("guest") senders, multi-device real sync.

## Versioning

The per-contact `a2a_notifications` surface ships in core **0.4.0**. Relative
to core 0.3 this is a **breaking rewrite of the notifications library**: the
shared (unscoped) token model was removed entirely — `registration_t` /
`my_registration_t` / the confirm no longer carry a `$token`, `register` mints
nothing, `export_notify_address` is per-contact, and `retire_shared` (which
never shipped) does not exist. There are no deployed v1-notifications clients;
consumers are (re)built against 0.4. See `release-notes/0.4.md`.
