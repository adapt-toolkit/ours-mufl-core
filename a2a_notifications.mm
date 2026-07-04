// Shared ours notifications library — protocol-level Notifications-as-a-Service.
//
// ONE library, TWO halves (the a2a_messaging/a2a_monitoring split-by-state
// pattern):
//
//   - CLIENT half (compiled into every consumer): register with a notification
//     service, hold the returned shared token, export the handout blob
//     (notify_address_t), send_notification to any handout, relay mark_read.
//   - SERVICE half (exercised only by a notifier packet): registration + token
//     state, post_notification ingest, and the app hooks a host daemon consumes
//     for storage + WebPush egress. A packet "is" a notification service by
//     USING this half and advertising cap_notifications — no node-type enum.
//
// Trust model (v1, owner-locked): the payload is NOT end-to-end private — the
// service reads every payload and delivers plaintext to the device (transport
// legs are encrypted by the wire and by WebPush itself). Sender authorization
// is possession of the service-minted shared token alone: post_notification
// arrives as a BARE signed send from a packet the service never met (the
// invite-leg precedent), NOT over an encrypted channel. There is no anti-spam;
// rotating the token is the recovery path for a leaked/spammed handout.
//
// Delivery/storage stay APP-SIDE (the core's architectural rule): this library
// validates + resolves and hands (notification, bindings) to injected hooks;
// the host daemon does WebPush HTTP and owns the notification log. mark_read
// therefore validates the caller and delegates ids (NIL = all) to a hook.
//
// Routing: brand-new surface, no legacy clients — every inbound name is
// LIBRARY-routed ::a2a_notifications::<name> (the receive_file_tx precedent).
library a2a_notifications loads libraries
    key_storage,
    current_transaction_info,
    encrypted_channel,
    a2a_protocol,
    a2a_messaging
    uses transactions
{
    // Network-visible inbound transaction names (embedded in what peers send).
    register_tx             = "::a2a_notifications::register".
    confirm_registration_tx = "::a2a_notifications::confirm_registration".
    update_bindings_tx      = "::a2a_notifications::update_bindings".
    rotate_token_tx         = "::a2a_notifications::rotate_token".
    unregister_tx           = "::a2a_notifications::unregister".
    post_notification_tx    = "::a2a_notifications::post_notification".
    mark_read_tx            = "::a2a_notifications::mark_read".

    // WebPush payload ceiling is ~4KB; oversize posts abort on BOTH sides
    // (sender-side in send_notification, service-side in post_notification).
    payload_max_bytes = 4000.

    // ---- wire shapes (all versioned; $c/$s signed-artifact idiom) ----------

    // The shared sender token, minted and signed by the SERVICE. One token per
    // recipient in v1 ($scope always ""); $token_id is the rotation/revocation
    // handle (revocation is a service-side index lookup, not a signature
    // question). The signature lets a CLIENT verify a handout against the
    // service's pinned keys (check_signature_new_container idiom) — the service
    // itself validates presented tokens by byte-equality against what it stored.
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
        $binding_id -> str,   // app-chosen stable id (e.g. endpoint hash) for replace/remove UX
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

    // One posted notification as handed to the service app hook (LOG storage is
    // app-side; the daemon owns read/unread status).
    metadef notification_t: (
        $version       -> int,       // 1
        $notif_id      -> str,       // service-stamped (_str of _new_id) — mark_read handle
        $wire_id       -> str,       // sender-stamped, "" tolerated
        $recipient_cid -> global_id,
        $sender_cid    -> global_id, // envelope $from (signature-authenticated; informational)
        $payload       -> str,       // OPAQUE to the protocol (any payload; service reads it)
        $date          -> time
    ).

    // ---- shared packet state (non-hidden, like contacts/peer_ads) ----------

    // ---- client half (every consumer) ----
    // My registrations, keyed by service cid.
    my_notify_registrations is (global_id ->> my_registration_t) = (,).
    // Service cids with an in-flight register/rotate awaiting confirm (cleared
    // on confirm; gates which senders may plant a confirm_registration — E9).
    pending_notify_registers is (global_id ->> bool) = (,).

    // ---- service half (notifier packet) ----
    // Registrations, keyed by recipient cid.
    notify_registrations is (global_id ->> registration_t) = (,).
    // token_id -> recipient cid. Rotation/unregister DELETES entries, so a
    // revoked token dies on the index lookup — this IS revocation.
    notify_token_index is (global_id ->> global_id) = (,).
    // Set by the host at boot (set_vapid_public_key); echoed in every confirm
    // so the client's browser can pushManager.subscribe against it. PUBLIC key
    // only — the VAPID PRIVATE key never enters packet state.
    vapid_public_key is str = "".

    hidden
    {
        _read_or_abort is (bin->any) = fn (_: bin) { abort "_read_or_abort is unset in a2a_notifications (call a2a_notifications::init)." when TRUE. }

        // App-injected hooks, unset-aborting defaults (the a2a_messaging::init
        // pattern). Each receives one record and returns the actions to append.
        //
        // on_notification_posted ($notification -> notification_t,
        //   $bindings -> webpush_binding_t[]): SERVICE side — a validated post.
        //   The daemon appends to its log (status unread) and sends one WebPush
        //   per binding. Zero bindings is valid (logged, nothing pushed).
        on_notification_posted is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_notification_posted hook is unset in a2a_notifications (call a2a_notifications::init)." when TRUE. return []. }
        // on_notifications_marked_read ($recipient_cid, $notif_ids -> str[]+):
        //   SERVICE side — $notif_ids NIL means ALL. The daemon updates its log
        //   (unknown/foreign ids are ignored there — idempotent).
        on_notifications_marked_read is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_notifications_marked_read hook is unset in a2a_notifications (call a2a_notifications::init)." when TRUE. return []. }
        // on_unregistered ($recipient_cid): SERVICE side — registration torn
        //   down; the daemon may purge that recipient's log.
        on_unregistered is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_unregistered hook is unset in a2a_notifications (call a2a_notifications::init)." when TRUE. return []. }
        // on_notify_registration ($service_cid, $registration -> my_registration_t):
        //   CLIENT side — a confirm landed; the host surfaces $vapid_pub so the
        //   browser can create/refresh its WebPush subscription.
        on_notify_registration is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_notify_registration hook is unset in a2a_notifications (call a2a_notifications::init)." when TRUE. return []. }
    }

    init = fn (_:(
        $_read_or_abort -> read: (bin->any),
        $on_notification_posted -> posted_cb: (any -> transaction::action::type[]),
        $on_notifications_marked_read -> marked_cb: (any -> transaction::action::type[]),
        $on_unregistered -> unregistered_cb: (any -> transaction::action::type[]),
        $on_notify_registration -> registration_cb: (any -> transaction::action::type[])
    ))
    {
        _read_or_abort -> read.
        on_notification_posted -> posted_cb.
        on_notifications_marked_read -> marked_cb.
        on_unregistered -> unregistered_cb.
        on_notify_registration -> registration_cb.
    }

    // ---- shared action builders (the a2a_messaging builders) ---------------
    fn _save_state (_) = (transaction::action::return_data ($kind -> $save_state)).
    fn _return_data (payload: any) = (transaction::action::return_data ($kind -> $data, $payload -> payload)).

    // ---- upgrade: state export / import helpers ------------------------------
    // NOT transactions: each app's export_state/import_state composes these with
    // its other state (the export_core_state contract). No secret material lives
    // in either half by construction — the VAPID private key never enters packet
    // state, and tokens are bearer artifacts the state must keep anyway.

    fn export_notify_state (_) -> any
    {
        return (
            $my_notify_registrations  -> my_notify_registrations,
            $notify_registrations     -> notify_registrations,
            $notify_token_index       -> notify_token_index,
            $vapid_public_key         -> vapid_public_key
        ).
    }

    fn import_notify_state (data: any) -> nil
    {
        // Every field is optional (an export that predates this library imports
        // unchanged — defaults stay in place when absent). pending_notify_registers
        // is transient by design: an in-flight register/rotate does not survive an
        // export/import (re-register is idempotent and keeps the token — E8).
        if (data $my_notify_registrations) != NIL
        {
            my_notify_registrations -> (data $my_notify_registrations) safe (global_id ->> my_registration_t).
        }
        if (data $notify_registrations) != NIL
        {
            notify_registrations -> (data $notify_registrations) safe (global_id ->> registration_t).
        }
        if (data $notify_token_index) != NIL
        {
            notify_token_index -> (data $notify_token_index) safe (global_id ->> global_id).
        }
        if (data $vapid_public_key) != NIL
        {
            vapid_public_key -> (data $vapid_public_key) safe str.
        }
        pending_notify_registers -> (,).
    }
}
