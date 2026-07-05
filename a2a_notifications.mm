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
    issue_tokens_tx         = "::a2a_notifications::issue_tokens".
    retire_shared_tx        = "::a2a_notifications::retire_shared".
    // Maximum senders per issue_tokens call (V12 batch cap — the client wrapper
    // pages >256 into multiple calls automatically).
    issue_max_senders       = 256.

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

    // ---- service half v2: per-sender scoped token maps (DoD 1/5/6) -----------
    // notify_sender_tokens[recipient][sender]: scoped token minted by issue_tokens
    // (E8 idempotent — re-issue keeps existing token; scope == _str sender).
    notify_sender_tokens is (global_id ->> (global_id ->> notify_token_t)) = (,).
    // notify_sender_muted[recipient][sender]: mute flag set by future mute_sender
    // inbound (a later task). Declared here so confirm_actions can mirror it.
    notify_sender_muted  is (global_id ->> (global_id ->> bool)) = (,).

    // ---- client half v2: mirror of the per-sender tokens from the last confirm
    // my_notify_contact_tokens[service][sender]: the scoped token the service
    // returned for that sender in the confirm_registration; populated wholesale
    // from $sender_tokens in each confirm (mute-flag consumption is a later task).
    my_notify_contact_tokens is (global_id ->> (global_id ->> notify_token_t)) = (,).

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

    // ---- service-side helpers ----------------------------------------------

    // Mint a token for one recipient with an explicit scope. Scope "" is the
    // v1/shared-token path; scope == _str sender is the v2 per-sender path.
    // Detached signature over _value_id (the delegation_cert_t signing idiom).
    // The CALLER stores the registration + index entry.
    fn mint_notify_token_scoped (recipient: global_id, scope: str) -> notify_token_t
    {
        core is notify_token_core_t = (
            $version       -> 1,
            $service_cid   -> _get_container_id(),
            $recipient_cid -> recipient,
            $token_id      -> _new_id "ours notify token",
            $scope         -> scope,
            $iat           -> (current_transaction_info::get_transaction_time())?
        ).
        return ($c -> core, $s -> key_storage::default_sign (_value_id core)).
    }

    // Backward-compat shim: callers that don't need a scope (register /
    // rotate_token) keep minting with scope "" so nothing changes for v1 consumers.
    fn mint_notify_token (recipient: global_id) -> notify_token_t
    {
        return mint_notify_token_scoped recipient "".
    }

    // The confirm leg every service-side mutator replies with (register /
    // update_bindings / rotate_token — idempotent): the stored token + this
    // service's VAPID public key + the registration's current bindings, over
    // the already-established encrypted channel.
    fn confirm_actions (recipient: global_id) -> transaction::action::type[]
    {
        reg = notify_registrations recipient.
        abort "No registration to confirm." when reg == NIL.
        // v2 DoD 5: carry the per-sender token and mute maps so the client can
        // mirror them. Additive-only — a v1-shaped consumer reading only
        // $token/$vapid_pub/$bindings still parses correctly.
        sender_tokens_map is (global_id ->> notify_token_t) = (,).
        if (notify_sender_tokens recipient) != NIL { sender_tokens_map -> (notify_sender_tokens recipient)?. }
        sender_muted_map is (global_id ->> bool) = (,).
        if (notify_sender_muted recipient) != NIL { sender_muted_map -> (notify_sender_muted recipient)?. }
        return [
            encrypted_channel::send_encrypted_tx recipient (
                $name -> confirm_registration_tx,
                $targ -> (
                    $token         -> (reg? $token),
                    $vapid_pub     -> vapid_public_key,
                    $bindings      -> (reg? $bindings),
                    $sender_tokens -> sender_tokens_map,
                    $sender_muted  -> sender_muted_map
                )
            )
        ].
    }

    // ---- client transactions (user-origin) -----------------------------------

    // Enroll with a notification service (must already be a contact — the
    // normal invite/introduction machinery; no new connection flow). $bindings
    // may be NIL: register first, add bindings once the browser subscribed
    // (E11 — zero bindings is a valid registration).
    trn notify_register _:($service -> service_ref: str, $bindings -> bindings: webpush_binding_t[]+)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        target_id = a2a_messaging::resolve_contact service_ref.
        pending_notify_registers target_id -> TRUE.

        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> register_tx,
                    $targ -> ($bindings -> bindings)
                ),
                _return_data ($sent_to -> target_id),
                _save_state NIL
            ].
        }).
    }

    // Replace-all bindings update (the service re-confirms, which refreshes the
    // client copy too). Requires an existing registration with that service.
    trn notify_update_bindings _:($service -> service_ref: str, $bindings -> bindings: webpush_binding_t[])
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        target_id = a2a_messaging::resolve_contact service_ref.
        abort "No notification registration with that service." when (my_notify_registrations target_id) == NIL.

        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> update_bindings_tx,
                    $targ -> ($bindings -> bindings)
                ),
                _return_data ($sent_to -> target_id)
            ].
        }).
    }

    // Replace the shared token (rotation IS revocation — D-3): the old handout
    // dies the moment the service processes this; senders keep working only
    // after I redistribute the new handout. Recovery path for a leaked token.
    trn notify_rotate_token _:($service -> service_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        target_id = a2a_messaging::resolve_contact service_ref.
        abort "No notification registration with that service." when (my_notify_registrations target_id) == NIL.
        pending_notify_registers target_id -> TRUE.

        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> rotate_token_tx,
                    $targ -> (,)
                ),
                _return_data ($sent_to -> target_id),
                _save_state NIL
            ].
        }).
    }

    // Relay a mark-read to the service's daemon log. $notif_ids NIL means mark
    // ALL my notifications read — the default an app fires on open. "Dismiss"
    // == mark_read in v1 (one verb, no separate dismissed state).
    trn notify_mark_read _:($service -> service_ref: str, $notif_ids -> notif_ids: str[]+)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        target_id = a2a_messaging::resolve_contact service_ref.
        abort "No notification registration with that service." when (my_notify_registrations target_id) == NIL.

        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> mark_read_tx,
                    $targ -> ($notif_ids -> notif_ids)
                ),
                _return_data ($sent_to -> target_id)
            ].
        }).
    }

    // Full teardown with a service: tell it to drop my registration, clear my
    // local copy. (Revoke-without-replace == unregister; rotation is the
    // keep-registered recovery path.)
    trn notify_unregister _:($service -> service_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        target_id = a2a_messaging::resolve_contact service_ref.
        if (my_notify_registrations target_id) != NIL { delete my_notify_registrations target_id. }
        if (pending_notify_registers target_id) != NIL { delete pending_notify_registers target_id. }

        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> unregister_tx,
                    $targ -> (,)
                ),
                _return_data ($sent_to -> target_id),
                _save_state NIL
            ].
        }).
    }

    // Ask the service to mint scoped tokens for each contact in $contacts. The
    // service cap is issue_max_senders (256) per call; this wrapper pages the
    // list into batches automatically so callers never need to handle paging.
    // Re-issuing a contact the service already has a token for is idempotent (E8).
    // Requires an existing registration with the service.
    trn notify_issue_tokens _:($service -> service_ref: str, $contacts -> contacts: global_id[])
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        target_id = a2a_messaging::resolve_contact service_ref.
        abort "No notification registration with that service." when (my_notify_registrations target_id) == NIL.

        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            // Page the contact list into batches of issue_max_senders.
            batch is global_id[] = [].
            actions is transaction::action::type[] = [].
            sc contacts -- ( -> sender)
            {
                batch (_count batch|) -> sender.
                if (_count batch) == issue_max_senders
                {
                    actions (_count actions|) -> encrypted_channel::send_encrypted_tx target_id (
                        $name -> issue_tokens_tx,
                        $targ -> ($senders -> batch)
                    ).
                    batch -> [].
                }
            }
            if (_count batch) > 0
            {
                actions (_count actions|) -> encrypted_channel::send_encrypted_tx target_id (
                    $name -> issue_tokens_tx,
                    $targ -> ($senders -> batch)
                ).
            }
            actions (_count actions|) -> _return_data ($sent_to -> target_id).
            actions (_count actions|) -> _save_state NIL.
            return transaction::success actions.
        }).
    }

    // Retire the shared (legacy scope-"") token for my registration with a
    // service: tells the service to delete the shared token's index entry
    // (revocation by index removal — E4; registration record stays inert so
    // the service still knows me). Idempotent: second call is a no-op (the
    // service-side delete silently skips an already-gone entry — E4 discipline).
    // After retirement the shared handout is permanently dead; scoped tokens
    // for the same registration keep working normally.
    trn notify_retire_shared _:($service -> service_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        target_id = a2a_messaging::resolve_contact service_ref.
        abort "No notification registration with that service." when (my_notify_registrations target_id) == NIL.

        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> retire_shared_tx,
                    $targ -> (,)
                ),
                _return_data ($sent_to -> target_id),
                _save_state NIL
            ].
        }).
    }

    // Export the handout blob for my registration with a service ("to notify
    // me: this service, this token"). Distribution is out of protocol — it
    // rides ordinary send_message/send_file.
    trn readonly export_notify_address _:($service -> service_ref: str)
    {
        target_id = a2a_messaging::resolve_contact service_ref.
        reg = my_notify_registrations target_id.
        abort "No notification registration with that service." when reg == NIL.
        addr is notify_address_t = (
            $version      -> 1,
            $service_cid  -> (reg? $service_cid),
            $service_name -> (reg? $service_name),
            $token        -> (reg? $token)
        ).
        return ($blob -> (_write addr), $service_cid -> (_str (reg? $service_cid))).
    }

    // THE parallel of send_message, against a handout instead of a contact:
    // parse the blob, stamp a wire_id from the shared _new_id namespace, and
    // emit ONE BARE signed send of post_notification to the blob's service —
    // deliberately NOT send_encrypted_tx (the sender never has a channel with
    // the service; the token is the sole authorization) and deliberately NO
    // monitoring copy (D-4: the forced-monitoring contract covers messages;
    // notifications are wake-up signals). Fire-and-forget: no response leg.
    trn send_notification _:($address -> address_blob: bin, $payload -> payload: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        addr = (_read_or_abort address_blob) safe notify_address_t.
        abort "Unsupported notify address version." when (addr $version) != 1.
        abort "Notification payload exceeds " + (_str payload_max_bytes) + " bytes." when (_strlen payload) > payload_max_bytes.

        wire_id = _str (_new_id "ours notification").
        return transaction::success [
            transaction::action::send (addr $service_cid) (
                $name -> post_notification_tx,
                $targ -> (
                    $token   -> (addr $token),
                    $payload -> payload,
                    $wire_id -> wire_id
                )
            ),
            _return_data ($sent_to -> (addr $service_cid), $wire_id -> wire_id)
        ].
    }

    // ---- service transactions -------------------------------------------------

    // Host-fired at daemon boot: the VAPID PUBLIC key echoed in every confirm
    // (the browser needs it as applicationServerKey). The PRIVATE key stays in
    // the daemon's env/file — it must never enter packet state.
    trn set_vapid_public_key _:($key -> key: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        vapid_public_key -> key.
        return transaction::success [
            _return_data ($ok -> TRUE),
            _save_state NIL
        ].
    }

    // SERVICE inbound: enroll the channel-authenticated sender. Re-register is
    // idempotent recovery (E8): the token is KEPT (already-distributed handouts
    // stay valid) and bindings are replaced only when provided; the confirm is
    // re-sent either way.
    fn handle_register (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        recipient = current_transaction_info::get_external_envelope_or_abort() $from.
        bindings is webpush_binding_t[] = [].
        if (args $bindings) != NIL { bindings -> (args $bindings) safe (webpush_binding_t[]). }

        existing = notify_registrations recipient.
        if existing != NIL
        {
            // E8: keep the token; replace bindings only when the caller sent some.
            if (args $bindings) != NIL
            {
                notify_registrations recipient -> (
                    $version       -> (existing? $version),
                    $recipient_cid -> (existing? $recipient_cid),
                    $token         -> (existing? $token),
                    $bindings      -> bindings,
                    $created_at    -> (existing? $created_at)
                ).
            }
        }
        else
        {
            token = mint_notify_token recipient.
            notify_registrations recipient -> (
                $version       -> 1,
                $recipient_cid -> recipient,
                $token         -> token,
                $bindings      -> bindings,
                $created_at    -> (current_transaction_info::get_transaction_time())?
            ).
            notify_token_index (token $c $token_id) -> recipient.
        }

        actions is transaction::action::type[] = confirm_actions recipient.
        actions (_count actions|) -> _save_state NIL.
        return transaction::success actions.
    }

    // SERVICE inbound: replace-all bindings for a registered sender; re-confirm.
    fn handle_update_bindings (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        recipient = current_transaction_info::get_external_envelope_or_abort() $from.
        existing = notify_registrations recipient.
        abort "No notification registration for this sender." when existing == NIL.

        bindings is webpush_binding_t[] = [].
        if (args $bindings) != NIL { bindings -> (args $bindings) safe (webpush_binding_t[]). }
        notify_registrations recipient -> (
            $version       -> (existing? $version),
            $recipient_cid -> (existing? $recipient_cid),
            $token         -> (existing? $token),
            $bindings      -> bindings,
            $created_at    -> (existing? $created_at)
        ).

        actions is transaction::action::type[] = confirm_actions recipient.
        actions (_count actions|) -> _save_state NIL.
        return transaction::success actions.
    }

    // SERVICE inbound: mint (or re-use) a scoped token for each requested sender
    // cid and return the current per-sender map in the confirm (DoD 1/5 V12).
    //
    //   $senders: global_id[]+  — non-empty, max issue_max_senders (V12 batch cap).
    //
    // Edge cases:
    //   E8: re-issue for an already-known sender keeps the existing token bytes
    //       unchanged (idempotent — test proves byte-stability across repeat calls).
    //   V11: empty $senders → abort (the type is non-empty; no partial mints).
    //   V12: >issue_max_senders entries → abort; client wrapper pages for you.
    // The handler does NOT check whether each sender is a contact of either side —
    // that is intentional (V1: service cannot know R's contact set; any cid R
    // names is eligible for a scoped token).
    fn handle_issue_tokens (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        recipient = current_transaction_info::get_external_envelope_or_abort() $from.
        abort "No notification registration for this sender." when (notify_registrations recipient) == NIL.

        senders is global_id[] = (args $senders) safe (global_id[]).
        abort "issue_tokens requires at least one sender ($senders must be non-empty — V11)." when (_count senders) == 0.
        abort "issue_tokens batch exceeds the " + (_str issue_max_senders) + "-sender cap — V12." when (_count senders) > issue_max_senders.

        // E8: load existing per-sender map for this recipient (may be empty on
        // the first call).
        existing_map is (global_id ->> notify_token_t) = (,).
        if (notify_sender_tokens recipient) != NIL { existing_map -> (notify_sender_tokens recipient)?. }

        sc senders -- ( -> sender)
        {
            // Only mint when there is no existing token for this sender.
            if (existing_map sender) == NIL
            {
                token = mint_notify_token_scoped recipient (_str sender).
                existing_map sender -> token.
                notify_token_index (token $c $token_id) -> recipient.
            }
        }
        notify_sender_tokens recipient -> existing_map.

        actions is transaction::action::type[] = confirm_actions recipient.
        actions (_count actions|) -> _save_state NIL.
        return transaction::success actions.
    }

    // SERVICE inbound: retire the shared (scope-"") token for a registered
    // sender — delete its notify_token_index entry so future posts using the
    // old shared handout abort at step 3 (index lookup, "Unknown or revoked").
    // The registration_t.$token field stays inert; the registration record
    // itself is NOT removed (scoped tokens and re-confirm keep working).
    // Idempotent (E4 discipline): if the index entry is already gone (second
    // call, or after a rotation that replaced the shared token), the delete is
    // a no-op — no abort is raised (§12.4 "tolerate/no-op" framing).
    fn handle_retire_shared (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        recipient = current_transaction_info::get_external_envelope_or_abort() $from.
        existing = notify_registrations recipient.
        abort "No notification registration for this sender." when existing == NIL.

        // One index delete — revocation by index removal (E4).
        // delete on an absent key is a no-op, so this is naturally idempotent.
        shared_tid = (existing? $token $c $token_id).
        if (notify_token_index shared_tid) != NIL
        {
            delete notify_token_index shared_tid.
        }

        // Re-confirm so the client mirror stays coherent with the service state
        // (consistent with all other service-side mutators).
        actions is transaction::action::type[] = confirm_actions recipient.
        actions (_count actions|) -> _save_state NIL.
        return transaction::success actions.
    }

    // SERVICE inbound: atomically replace a registered sender's token — delete
    // the old index entry (posts against the old handout die on the lookup from
    // this transaction on — E4), mint + store + index a fresh token, re-confirm.
    fn handle_rotate_token (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        recipient = current_transaction_info::get_external_envelope_or_abort() $from.
        existing = notify_registrations recipient.
        abort "No notification registration for this sender." when existing == NIL.

        delete notify_token_index (existing? $token $c $token_id).
        token = mint_notify_token recipient.
        notify_registrations recipient -> (
            $version       -> (existing? $version),
            $recipient_cid -> (existing? $recipient_cid),
            $token         -> token,
            $bindings      -> (existing? $bindings),
            $created_at    -> (existing? $created_at)
        ).
        notify_token_index (token $c $token_id) -> recipient.

        actions is transaction::action::type[] = confirm_actions recipient.
        actions (_count actions|) -> _save_state NIL.
        return transaction::success actions.
    }

    // SERVICE inbound: full teardown for a registered sender — registration +
    // token index entry removed, then the hook lets the daemon purge its log
    // (hook actions before the save, the remove_contact composition).
    fn handle_unregister (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        recipient = current_transaction_info::get_external_envelope_or_abort() $from.
        existing = notify_registrations recipient.
        abort "No notification registration for this sender." when existing == NIL.

        delete notify_token_index (existing? $token $c $token_id).
        delete notify_registrations recipient.

        actions is transaction::action::type[] = [].
        sc on_unregistered ($recipient_cid -> recipient) -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        actions (_count actions|) -> _save_state NIL.
        return transaction::success actions.
    }

    // SERVICE inbound: a registered sender marks its notifications read. The
    // ids (or NIL = ALL) pass straight through to the daemon hook — the daemon
    // updates its log and ignores non-matching ids (E7, idempotent). The hook
    // only ever receives the CALLER's own recipient_cid, so one recipient can
    // never mark another's notifications.
    fn handle_mark_read (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        recipient = current_transaction_info::get_external_envelope_or_abort() $from.
        abort "No notification registration for this sender." when (notify_registrations recipient) == NIL.

        notif_ids is str[]+ = NIL.
        if (args $notif_ids) != NIL { notif_ids -> (args $notif_ids) safe (str[]). }

        return transaction::success (on_notifications_marked_read (
            $recipient_cid -> recipient,
            $notif_ids     -> notif_ids
        )).
    }

    // CLIENT inbound: a service confirmed (or refreshed) my registration. Only
    // a service I am PENDING with or ALREADY registered with may plant one —
    // an unsolicited confirm from any other contact aborts (E9).
    fn handle_confirm_registration (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        abort "Unsolicited registration confirm." when (pending_notify_registers sender_id) == NIL && (my_notify_registrations sender_id) == NIL.

        token = (args $token) safe notify_token_t.
        abort "Unsupported notify token version." when (token $c $version) != 1.
        vapid_pub = (args $vapid_pub) safe str.
        bindings is webpush_binding_t[] = [].
        if (args $bindings) != NIL { bindings -> (args $bindings) safe (webpush_binding_t[]). }

        service_name is str = "".
        c = a2a_messaging::contacts sender_id.
        if c != NIL { service_name -> c? $name. }

        myreg is my_registration_t = (
            $service_cid  -> sender_id,
            $service_name -> service_name,
            $token        -> token,
            $vapid_pub    -> vapid_pub,
            $bindings     -> bindings,
            $created_at   -> (current_transaction_info::get_transaction_time())?
        ).
        my_notify_registrations sender_id -> myreg.
        if (pending_notify_registers sender_id) != NIL { delete pending_notify_registers sender_id. }

        // v2 DoD 5/6: replace the contact-token mirror from the confirm wholesale.
        // Absent on v1-era confirms → guard keeps existing (empty-default) map.
        if (args $sender_tokens) != NIL
        {
            my_notify_contact_tokens sender_id -> (args $sender_tokens) safe (global_id ->> notify_token_t).
        }

        actions is transaction::action::type[] = [].
        sc on_notify_registration ($service_cid -> sender_id, $registration -> myreg) -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        actions (_count actions|) -> _save_state NIL.
        return transaction::success actions.
    }

    // SERVICE inbound: the notification ingest. The ONE inbound that accepts a
    // BARE signed send (origin external, NO check_encrypted_or_abort — locked
    // §0.2): the sender is typically a packet this service never met, and the
    // token is the sole authorization. Validation order matters (abort on first
    // failure, mutate nothing):
    //   1. parse-safe + version   2. minted by THIS service   3. live index
    //   entry matching $recipient_cid (rotation/unregister deletes entries, so
    //   revocation is a state lookup)   4. byte-equality vs the STORED token
    //   (_value_id) — forging any field, $scope included, requires possessing
    //   the exact minted artifact; no signature re-verification is needed
    //   because we compare against what we ourselves stored   5. payload cap.
    // $sender_cid is the wrapper-verified envelope $from — informational only
    // (E14), never authorization. Fire-and-forget: no reply leg.
    fn handle_post_notification (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).

        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.

        token = (args $token) safe notify_token_t.
        abort "Unsupported notify token version." when (token $c $version) != 1.
        abort "Token was not minted by this service." when (token $c $service_cid) != _get_container_id().
        indexed = notify_token_index (token $c $token_id).
        abort "Unknown or revoked notification token." when indexed == NIL.
        abort "Token recipient does not match its index entry." when indexed? != (token $c $recipient_cid).
        reg = notify_registrations (token $c $recipient_cid).
        abort "No registration for the token's recipient." when reg == NIL.

        // Step 4 — dispatch on $scope: "" = v1/legacy path (shared token);
        // non-empty = v2/scoped path (per-sender token, steps 4-6 extended).
        token_scope = (token $c $scope).
        if token_scope == ""
        {
            // V1/legacy path: byte-equality vs the stored shared token in
            // registration_t.$token. Shared token validates exactly as v1
            // while its index entry is live (step 3 above kills it after retire).
            abort "Presented token does not match the stored registration." when (_value_id token) != (_value_id (reg? $token)).
        }
        else
        {
            // V2/scoped path —
            // Step 5 (evaluated first in code — no reverse _str() to recover a
            // global_id from scope; Q1 strict binding per §16): envelope $from
            // must equal the token's $scope string. This also means a v1 sender
            // posting a scoped token (it treats the blob as opaque) passes as long
            // as it posts from the cid the token was issued to — happy path intact.
            abort "Token is not bound to this sender." when token_scope != _str sender_id.
            // Step 4 (scoped): byte-equality vs notify_sender_tokens[recipient][sender].
            // Absent outer map or absent sender slot both abort (never-issued or revoked).
            scoped_outer = notify_sender_tokens (token $c $recipient_cid).
            abort "Token is not bound to this sender." when scoped_outer == NIL.
            scoped_tok_entry = (scoped_outer?) sender_id.
            abort "Token is not bound to this sender." when scoped_tok_entry == NIL.
            abort "Presented token does not match the stored registration." when (_value_id token) != (_value_id scoped_tok_entry?).
            // Step 6 — mute check (scoped only): FALSE stored = muted per §4.1;
            // absent = enabled. All checks precede hook/store writes — NFR-6.
            muted_outer = notify_sender_muted (token $c $recipient_cid).
            if muted_outer != NIL
            {
                muted_entry = muted_outer? sender_id.
                abort "Notifications from this sender are disabled." when muted_entry != NIL.
            }
        }

        payload = (args $payload) safe str.
        abort "Notification payload exceeds " + (_str payload_max_bytes) + " bytes." when (_strlen payload) > payload_max_bytes.

        wire_id is str = "".
        if (args $wire_id) != NIL { wire_id -> (args $wire_id) safe str. }

        notification is notification_t = (
            $version       -> 1,
            $notif_id      -> _str (_new_id "ours notif"),
            $wire_id       -> wire_id,
            $recipient_cid -> (token $c $recipient_cid),
            $sender_cid    -> sender_id,
            $payload       -> payload,
            $date          -> (current_transaction_info::get_transaction_time())?
        ).
        return transaction::success (on_notification_posted (
            $notification -> notification,
            $bindings     -> (reg? $bindings)
        )).
    }

    // Inbound trn stubs (declared AFTER their handlers — define-before-use).
    trn register args: any { return handle_register args. }
    trn update_bindings args: any { return handle_update_bindings args. }
    trn rotate_token args: any { return handle_rotate_token args. }
    trn unregister args: any { return handle_unregister args. }
    trn mark_read args: any { return handle_mark_read args. }
    trn confirm_registration args: any { return handle_confirm_registration args. }
    trn post_notification args: any { return handle_post_notification args. }
    trn issue_tokens args: any { return handle_issue_tokens args. }
    trn retire_shared args: any { return handle_retire_shared args. }

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
            $vapid_public_key         -> vapid_public_key,
            $notify_sender_tokens     -> notify_sender_tokens,
            $notify_sender_muted      -> notify_sender_muted,
            $my_notify_contact_tokens -> my_notify_contact_tokens
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
        // v2 fields: individually guarded so a v1-era export imports cleanly
        // with the defaults (empty maps) in place — DoD 6 fixture test relies on this.
        if (data $notify_sender_tokens) != NIL
        {
            notify_sender_tokens -> (data $notify_sender_tokens) safe (global_id ->> (global_id ->> notify_token_t)).
        }
        if (data $notify_sender_muted) != NIL
        {
            notify_sender_muted -> (data $notify_sender_muted) safe (global_id ->> (global_id ->> bool)).
        }
        if (data $my_notify_contact_tokens) != NIL
        {
            my_notify_contact_tokens -> (data $my_notify_contact_tokens) safe (global_id ->> (global_id ->> notify_token_t)).
        }
        pending_notify_registers -> (,).
    }
}
