// Self-contained test actor for the core-3.0 ephemeral-invite suite.
//
// DERIVED locally for the core repo — it does NOT vendor any consumer/daemon
// source. It loads only the shared core libraries this suite exercises
// (a2a_protocol + a2a_messaging + their stdlib deps) and provides the MINIMUM
// host wiring a packet needs: the storage hooks a2a_messaging::init requires, a
// tiny inbox, the identity-hierarchy helper trns (so the role scenario can mint
// a delegation chain), export/import wrappers (migration scenario), and the
// `qa_*` probe trns the driver uses to inject adversarial inputs and read state.
//
// It does NOT load a2a_control / a2a_cluster / a2a_monitoring / a2a_capabilities-
// init: the invite redeem flow, send_message, the hierarchy chain, and
// export/import do not depend on them. The redeem transactions themselves
// (generate_invite / add_contact / submit_invite_response / complete_invite) live
// in a2a_messaging and are library-routed, so no ::actor:: shim is needed.

application actor loads libraries
    identity_proof_document,
    attestation_document,
    native_attestation_document,
    transaction_message_decoder,
    address_document,
    address_document_types,
    key_utils,
    key_storage,
    continuation,
    encrypted_channel,
    a2a_versions,
    a2a_capabilities,
    a2a_protocol,
    a2a_messaging,
    a2a_group,
    a2a_notifications,
    current_transaction_info,
    protocol_container,
    version
    uses transactions
{
    hidden
    {
        // Minimal inbox (the app owns message storage; the core calls the hook).
        metadef msg_t: ($sender -> global_id, $text -> str, $wire_id -> str, $reply_wire -> str).
        inbox is msg_t[] = [].

        // Minimal file store (the app owns file storage; the core calls the hook).
        metadef file_t: ($sender -> global_id, $filename -> str, $mime -> str, $wire_id -> str, $reply_wire -> str).
        files is file_t[] = [].

        // Wire the deserialization primitive into the libraries that need it.
        _read_or_abort = grab( _read_or_abort ).
        key_storage::init ($_read_or_abort -> _read_or_abort).
        encrypted_channel::init ($_read_or_abort -> _read_or_abort).

        // Host-protocol action helpers (the driver resolves on kind "data").
        fn _save_state (_) = (transaction::action::return_data ($kind -> $save_state)).
        fn _return_data (payload: any) = (transaction::action::return_data ($kind -> $data, $payload -> payload)).
        fn _notify_agent (payload: any) = (transaction::action::return_data ($kind -> $notify_agent, $payload -> payload)).

        // Receipt consumer log (core 0.7.0) — the driver's RC-series probe.
        receipts_log is any[] = [].
        // Group message log (core 0.8.0) — the G-series probe.
        group_log is any[] = [].
        a2a_group::init (
            $_read_or_abort -> _read_or_abort,
            $on_group_message_received -> fn (arg: any) -> transaction::action::type[]
            {
                group_log (_count group_log|) -> arg.
                return [ _notify_agent ($event -> $group_message_received), _save_state NIL ].
            },
            $on_group_message_sent -> fn (_: any) -> transaction::action::type[] { return []. }
        ).

        // Storage hooks: deposit inbound messages; send/remove are no-ops.
        a2a_messaging::init (
            $_read_or_abort -> _read_or_abort,
            $on_message_received -> fn (arg: any) -> transaction::action::type[]
            {
                sid = (arg $sender_id) safe global_id.
                txt = (arg $text) safe str.
                wid is str = "".
                if (arg $wire_id) != NIL { wid -> (arg $wire_id) safe str. }
                rw is str = "".
                if (arg $reply_to) != NIL { rw -> ((arg $reply_to) $wire_id) safe str. }
                inbox (_count inbox|) -> ($sender -> sid, $text -> txt, $wire_id -> wid, $reply_wire -> rw).
                return [ _notify_agent ($event -> $message_received), _save_state NIL ].
            },
            $on_message_sent -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_contact_removed -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_file_received -> fn (arg: any) -> transaction::action::type[]
            {
                sid = (arg $sender_id) safe global_id.
                fname = (arg $filename) safe str.
                mt = (arg $mime) safe str.
                wid is str = "".
                if (arg $wire_id) != NIL { wid -> (arg $wire_id) safe str. }
                rw is str = "".
                if (arg $reply_to) != NIL { rw -> ((arg $reply_to) $wire_id) safe str. }
                files (_count files|) -> ($sender -> sid, $filename -> fname, $mime -> mt, $wire_id -> wid, $reply_wire -> rw).
                return [ _notify_agent ($event -> $file_received), _save_state NIL ].
            },
            $on_file_sent -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_receipt_received -> fn (arg: any) -> transaction::action::type[]
            {
                receipts_log (_count receipts_log|) -> arg.
                return [ _notify_agent ($event -> $receipt_received), _save_state NIL ].
            }
        ).

        // Notification hook logs (the app owns notification storage; the core
        // calls the hooks). Plain observable lists the qa probes expose.
        notif_log is any[] = [].
        marks_log is any[] = [].
        unregs_log is any[] = [].
        regconfirm_log is any[] = [].

        // Deployed-messenger emulation (LEGACY receive_notify_address): stores
        // the blob, counts receipts, sends NO ack — exactly the pre-engine peer
        // shape. Feeds the control-plane engine rig's byte-compat + retry-cap
        // tests.
        notify_addr_store is (global_id ->> bin) = (,).
        notify_addr_recv_count is int = 0.

        a2a_notifications::init (
            $_read_or_abort -> _read_or_abort,
            $on_notification_posted -> fn (arg: any) -> transaction::action::type[]
            {
                notif_log (_count notif_log|) -> arg.
                return [ _notify_agent ($event -> $notification_posted), _save_state NIL ].
            },
            $on_notifications_marked_read -> fn (arg: any) -> transaction::action::type[]
            {
                marks_log (_count marks_log|) -> arg.
                return [ _save_state NIL ].
            },
            $on_unregistered -> fn (arg: any) -> transaction::action::type[]
            {
                unregs_log (_count unregs_log|) -> arg.
                return [ _save_state NIL ].
            },
            $on_notify_registration -> fn (arg: any) -> transaction::action::type[]
            {
                regconfirm_log (_count regconfirm_log|) -> arg.
                return [ _save_state NIL ].
            }
        ).
    }

    // ---- minimal host surface used by the driver ----
    // The core's send_message delivers to the legacy ::actor::receive_message name;
    // this shim routes it into the core receive handler (→ on_message_received hook).
    trn receive_message args: any { return a2a_messaging::handle_receive_message args. }
    trn readonly list_incoming_messages _ { return ($inbox -> inbox). }
    trn readonly list_incoming_files _ { return ($files -> files). }

    // LEGACY notify-address receiver — byte-for-byte the DEPLOYED messenger
    // targ shape ($address only, required bin). Stores + counts, never acks.
    // An engine sender's additive $gen field must route here unchanged
    // (byte-compat obligation).
    trn receive_notify_address _:($address -> blob: bin)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort ().

        from = current_transaction_info::get_external_envelope_or_abort() $from.
        notify_addr_store from -> blob.
        notify_addr_recv_count -> notify_addr_recv_count + 1.
        return transaction::success [ _save_state NIL ].
    }
    trn readonly qa_notify_addr_store _
    {
        return ($store -> notify_addr_store, $count -> notify_addr_recv_count).
    }
    // LEGACY notify-address SENDER — byte-for-byte the deployed fan-out targ
    // shape ($address only, no $gen). Lets the engine rig prove a pre-engine
    // peer's handout still lands at a v2 messenger (which must store it and
    // send no ack).
    trn qa_send_legacy_notify_address _:($target -> tgt: global_id, $address -> blob: bin)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        return encrypted_channel::execute_transaction tgt (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx tgt (
                    $name -> "::actor::receive_notify_address",
                    $targ -> ($address -> blob)
                ),
                _return_data ($sent_to -> tgt)
            ].
        }).
    }
    // Exercises the metadata-only file monitoring summary directly (the loopback has
    // no bound control plane, so the format + byte-secrecy are asserted on the helper).
    trn qa_file_summary _:($filename -> f: str, $mime -> m: str, $data -> d: bin)
    {
        return transaction::success [ _return_data ($summary -> (a2a_messaging::file_monitor_summary f m d)) ].
    }
    trn readonly export_address_document _ { return (_write address_document::get_my_address_document()). }

    // Identity-hierarchy helpers (derived equivalents of the host's; used only by
    // the role scenario). sign_delegation/export_root_profile are root-side;
    // set_delegation is role-side.
    trn sign_delegation _:($role_ad -> role_ad_blob: bin, $role_id -> role_id: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        abort "Only a root can sign delegation certs." when a2a_messaging::delegation_cert != NIL.
        role_ad = (_read_or_abort role_ad_blob) safe address_document_types::t_address_document.
        role_cid = role_ad $identity $container_id.
        abort "Cannot delegate to myself." when role_cid == _get_container_id().
        core is a2a_protocol::delegation_core_t = (
            $version -> 1, $role_cid -> role_cid, $role_ad_hash -> (_value_id role_ad),
            $role_id -> role_id, $root_cid -> _get_container_id(),
            $issued_at -> (current_transaction_info::get_transaction_time())?
        ).
        cert is a2a_protocol::delegation_cert_t = ($c -> core, $s -> key_storage::default_sign (_value_id core)).
        return transaction::success [ _return_data ($cert -> (_write cert)) ].
    }

    trn export_root_profile _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        abort "Only a root can export a root profile." when a2a_messaging::delegation_cert != NIL.
        my_ad = address_document::get_my_address_document().
        core is a2a_protocol::root_profile_core_t = (
            $version -> 1, $root_cid -> _get_container_id(),
            $name -> a2a_messaging::my_name, $bio -> a2a_messaging::my_bio,
            $keys -> my_ad $identity $key_list
        ).
        profile is a2a_protocol::root_profile_t = ($p -> core, $s -> key_storage::default_sign (_value_id core)).
        return transaction::success [ _return_data ($profile -> (_write profile)) ].
    }

    trn set_delegation _:($cert -> cert_blob: bin, $root_ad -> root_ad_blob: bin, $root_profile -> rp_blob: bin)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        cert = (_read_or_abort cert_blob) safe a2a_protocol::delegation_cert_t.
        new_root_ad = (_read_or_abort root_ad_blob) safe address_document_types::t_address_document.
        rp = (_read_or_abort rp_blob) safe a2a_protocol::root_profile_t.
        abort "cert not for me." when (cert $c $role_cid) != _get_container_id().
        my_ad = address_document::get_my_address_document().
        abort "cert AD mismatch." when (cert $c $role_ad_hash) != (_value_id my_ad).
        abort "root AD mismatch." when (new_root_ad $identity $container_id) != (cert $c $root_cid).
        abort "cert not root-signed." when key_storage::check_signature_new_container (_value_id (cert $c)) (cert $s) (new_root_ad $identity $key_list) != TRUE.
        abort "profile not root-signed." when key_storage::check_signature_new_container (_value_id (rp $p)) (rp $s) (new_root_ad $identity $key_list) != TRUE.
        a2a_messaging::delegation_cert -> cert.
        a2a_messaging::root_ad -> new_root_ad.
        a2a_messaging::root_profile -> rp.
        return transaction::success [ _return_data ($delegated -> TRUE), _save_state NIL ].
    }

    // export/import wrappers (migration scenario): the core state under $core, as a
    // host would compose it. (The app inbox is not part of this suite's migration
    // assertions, so it is omitted to keep the fixture minimal.)
    trn readonly export_state _ { return ($core -> (a2a_messaging::export_core_state NIL), $notify -> (a2a_notifications::export_notify_state NIL)). }
    trn import_state data: any
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        a2a_messaging::import_core_state (data $core).
        if (data $notify) != NIL { a2a_notifications::import_notify_state (data $notify). }
        return transaction::success [ _return_data ($imported -> TRUE), _save_state NIL ].
    }

    // ================= TEST PROBES =================
    trn readonly qa_my_cid _ { return ($cid -> _get_container_id()). }
    trn readonly qa_export_ad _ { return ($ad -> (_write address_document::get_my_address_document())). }

    // Counts over the (non-hidden) core state — for receiver-side assertions.
    trn readonly qa_state _
    {
        return (
            $n_contacts -> (_count a2a_messaging::contacts),
            $n_peer_ads -> (_count a2a_messaging::peer_ads),
            $n_pending_invites -> (_count a2a_messaging::pending_invites),
            $n_pending_redemptions -> (_count a2a_messaging::pending_redemptions),
            $n_contact_roots -> (_count a2a_messaging::contact_roots),
            $n_pending_restores -> (_count a2a_messaging::pending_restores),
            $n_restore_replies -> (_count a2a_messaging::pending_restore_replies),
            $n_deferred -> (_count a2a_messaging::deferred_msgs)
        ).
    }

    // export-secrecy: hand back export_core_state so the driver confirms neither
    // ephemeral secret store appears in the portable export.
    trn readonly qa_export_core _ { return ($core -> (a2a_messaging::export_core_state NIL)). }

    // Simulate a breaking-change migration that carried contacts but dropped the
    // address documents (the spec's "degraded contact" state).
    trn qa_strip_peer_ads _
    {
        a2a_messaging::peer_ads -> (,).
        return transaction::success [ _return_data ($stripped -> TRUE) ].
    }

    // Notification state + hook logs — for receiver-side assertions (N-series).
    trn readonly qa_notify_state _
    {
        return (
            $registrations -> a2a_notifications::notify_registrations,
            $token_index   -> a2a_notifications::notify_token_index,
            $my_regs       -> a2a_notifications::my_notify_registrations,
            $pending       -> a2a_notifications::pending_notify_registers,
            $vapid_pub     -> a2a_notifications::vapid_public_key,
            $notif_log     -> notif_log,
            $marks_log     -> marks_log,
            $unregs_log    -> unregs_log,
            $regconfirm_log -> regconfirm_log
        ).
    }

    // v2: per-sender token maps + contact-token mirror (N9-series probes).
    trn readonly qa_notify_state_v2 _
    {
        return (
            $sender_tokens  -> a2a_notifications::notify_sender_tokens,
            $sender_muted   -> a2a_notifications::notify_sender_muted,
            $contact_tokens -> a2a_notifications::my_notify_contact_tokens
        ).
    }

    // Extract the scoped token_id for a specific (recipient, sender) pair from
    // notify_sender_tokens. Used in N10 to prove handle_issue_tokens indexes scoped
    // tokens into notify_token_index (revocation mechanism): the returned token_id
    // must appear as a key in notify_token_index; if the indexing line were removed
    // from handle_issue_tokens the token would exist in sender_tokens but be absent
    // from the index and the N10 assertion would fail.
    trn readonly qa_scoped_token_id _:($recipient -> r: global_id, $sender -> s: global_id)
    {
        outer = a2a_notifications::notify_sender_tokens r.
        abort "No sender tokens for recipient." when outer == NIL.
        inner_map = outer?.
        tok = inner_map s.
        abort "No token for this sender." when tok == NIL.
        return ($token_id -> (tok? $c $token_id)).
    }

    // Send a raw issue_tokens directly to a service (bypasses client-side paging —
    // used to probe the batch-cap gate and the registered-recipient gate).
    trn qa_issue_tokens_direct _:($service -> svc: global_id, $senders -> senders: any)
    {
        return encrypted_channel::execute_transaction svc (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx svc (
                    $name -> "::a2a_notifications::issue_tokens",
                    $targ -> ($senders -> senders)
                ),
                _return_data ($sent_to -> svc)
            ].
        }).
    }

    // Import a v1-era notify record (fields $notify_sender_tokens/$notify_sender_muted/
    // $my_notify_contact_tokens absent) and return the post-import map state.
    // Used for the v1-era import fixture: verifies import_notify_state handles missing v2 fields
    // by leaving the defaults (empty maps) in place.
    trn qa_import_v1_notify_state _:($vapid -> vapid: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        a2a_notifications::import_notify_state (
            $my_notify_registrations -> (,),
            $notify_registrations    -> (,),
            $notify_token_index      -> (,),
            $vapid_public_key        -> vapid
            // $notify_sender_tokens, $notify_sender_muted, $my_notify_contact_tokens
            // intentionally absent — simulates a v1-era export record shape.
        ).
        return transaction::success [
            _return_data (
                $sender_tokens  -> a2a_notifications::notify_sender_tokens,
                $sender_muted   -> a2a_notifications::notify_sender_muted,
                $contact_tokens -> a2a_notifications::my_notify_contact_tokens
            ),
            _save_state NIL
        ].
    }

    // ---- adversarial leg-1 senders (bare-send a crafted submit_invite_response) ----
    trn qa_leg1_badbox _:($invite -> blob: bin)
    {
        inv = (_read_or_abort blob) safe a2a_protocol::invite_eph_t.
        kpr = _crypto_construct_encryption_keypair (inv $v).
        wrong = _crypto_construct_encryption_keypair (inv $v).
        payload = _write ($ad -> (address_document::get_my_address_document()), $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> (inv $d)).
        data = _crypto_encrypt_message (kpr $secret_key) (wrong $public_key) payload.
        return transaction::success [
            transaction::action::send (inv $c) ($name -> "::a2a_messaging::submit_invite_response", $targ -> ($invite_id -> (inv $d), $epk -> (kpr $public_key), $v -> (inv $v), $data -> data)),
            _return_data ($sent -> TRUE)
        ].
    }
    trn qa_leg1_foreign_ad _:($invite -> blob: bin, $foreign_ad -> fad: bin)
    {
        inv = (_read_or_abort blob) safe a2a_protocol::invite_eph_t.
        kpr = _crypto_construct_encryption_keypair (inv $v).
        foreign = (_read_or_abort fad) safe address_document_types::t_address_document.
        payload = _write ($ad -> foreign, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> (inv $d)).
        data = _crypto_encrypt_message (kpr $secret_key) (inv $k) payload.
        return transaction::success [
            transaction::action::send (inv $c) ($name -> "::a2a_messaging::submit_invite_response", $targ -> ($invite_id -> (inv $d), $epk -> (kpr $public_key), $v -> (inv $v), $data -> data)),
            _return_data ($sent -> TRUE)
        ].
    }
    trn qa_leg1_forged_ad _:($invite -> blob: bin)
    {
        inv = (_read_or_abort blob) safe a2a_protocol::invite_eph_t.
        kpr = _crypto_construct_encryption_keypair (inv $v).
        my_ad = address_document::get_my_address_document().
        forged is address_document_types::t_address_document = ($version -> (my_ad $version), $identity -> (my_ad $identity), $authorizations -> (,)).
        payload = _write ($ad -> forged, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> (inv $d)).
        data = _crypto_encrypt_message (kpr $secret_key) (inv $k) payload.
        return transaction::success [
            transaction::action::send (inv $c) ($name -> "::a2a_messaging::submit_invite_response", $targ -> ($invite_id -> (inv $d), $epk -> (kpr $public_key), $v -> (inv $v), $data -> data)),
            _return_data ($sent -> TRUE)
        ].
    }

    // Fire a leg-0 restore request at an arbitrary target (bypassing the
    // degraded-contact trigger) — used to prove the responder's contacts gate.
    trn qa_send_restore_request _:($target -> tgt: global_id)
    {
        actions is transaction::action::type[] = a2a_messaging::begin_contact_restore tgt.
        actions (_count actions|) -> _return_data ($ok -> TRUE).
        return transaction::success actions.
    }

    // Craft an unsolicited leg-1 (no matching pending_restores at the target).
    trn qa_send_fake_restore_response _:($target -> tgt: global_id)
    {
        scheme = _crypto_default_scheme_id().
        kp = _crypto_construct_encryption_keypair scheme.
        payload = _write ($junk -> "x").
        data = _crypto_encrypt_message (kp $secret_key) (kp $public_key) payload.
        return transaction::success [
            transaction::action::send tgt (
                $name -> "::a2a_messaging::submit_restore_response",
                $targ -> ($rid -> (_new_id "fake restore"), $epk -> (kp $public_key), $v -> scheme, $data -> data)
            ),
            _return_data ($ok -> TRUE)
        ].
    }

    // ---- adversarial notification senders (N3/N8) ----
    // Emit the SAME bare send send_notification emits, with a corrupted artifact.
    // modes: flip_recipient (different $recipient_cid, old $s — dies on the index
    // match), fake_token_id (dies on the index lookup), foreign_service (dies on
    // the minted-by-me check), flip_scope ($scope flipped, id/recipient intact —
    // dies ONLY on the _value_id byte-equality), oversize (valid token, 4096-char
    // payload — dies on the service-side cap).
    trn qa_post_tampered _:($address -> blob: bin, $mode -> mode: str)
    {
        addr = (_read_or_abort blob) safe a2a_notifications::notify_address_t.
        token is a2a_notifications::notify_token_t = addr $token.
        old = token $c.
        payload is str = "tampered".
        if mode == "flip_recipient"
        {
            core is a2a_notifications::notify_token_core_t = (
                $version -> (old $version), $service_cid -> (old $service_cid),
                $recipient_cid -> _get_container_id(),
                $token_id -> (old $token_id), $scope -> (old $scope), $iat -> (old $iat)
            ).
            token -> ($c -> core, $s -> (token $s)).
        }
        if mode == "fake_token_id"
        {
            core is a2a_notifications::notify_token_core_t = (
                $version -> (old $version), $service_cid -> (old $service_cid),
                $recipient_cid -> (old $recipient_cid),
                $token_id -> _new_id "qa fake token id", $scope -> (old $scope), $iat -> (old $iat)
            ).
            token -> ($c -> core, $s -> (token $s)).
        }
        if mode == "foreign_service"
        {
            core is a2a_notifications::notify_token_core_t = (
                $version -> (old $version), $service_cid -> _get_container_id(),
                $recipient_cid -> (old $recipient_cid),
                $token_id -> (old $token_id), $scope -> (old $scope), $iat -> (old $iat)
            ).
            token -> ($c -> core, $s -> (token $s)).
        }
        if mode == "flip_scope"
        {
            core is a2a_notifications::notify_token_core_t = (
                $version -> (old $version), $service_cid -> (old $service_cid),
                $recipient_cid -> (old $recipient_cid),
                $token_id -> (old $token_id), $scope -> "evil", $iat -> (old $iat)
            ).
            token -> ($c -> core, $s -> (token $s)).
        }
        if mode == "oversize"
        {
            big is str = "x".
            big -> big + big. big -> big + big. big -> big + big. big -> big + big.
            big -> big + big. big -> big + big. big -> big + big. big -> big + big.
            big -> big + big. big -> big + big. big -> big + big. big -> big + big.
            payload -> big.   // 4096 chars > payload_max_bytes
        }
        return transaction::success [
            transaction::action::send (addr $service_cid) (
                $name -> "::a2a_notifications::post_notification",
                $targ -> ($token -> token, $payload -> payload, $wire_id -> "qa-tamper")
            ),
            _return_data ($sent -> TRUE)
        ].
    }

    // ---- N17+ probes (per-contact validation) ----

    // Export a notify_address_t blob using a scoped (per-sender) token from
    // my_notify_contact_tokens[service][sender]. Lets a sender post via the
    // UNCHANGED send_notification trn using a scoped-token handout (N17).
    trn readonly qa_export_contact_notify_address _:($service -> svc: global_id, $sender -> s: global_id)
    {
        outer = a2a_notifications::my_notify_contact_tokens svc.
        abort "No contact tokens for this service." when outer == NIL.
        inner_map = outer?.
        tok = inner_map s.
        abort "No token for this sender." when tok == NIL.
        addr is a2a_notifications::notify_address_t = (
            $version      -> 1,
            $service_cid  -> svc,
            $service_name -> "",
            $token        -> tok?
        ).
        return ($blob -> (_write addr)).
    }

    // Set mute: write FALSE (= muted per §4.1) into notify_sender_muted[recipient][sender].
    // Stand-in for set_sender_muted until that service inbound lands (a later task).
    trn qa_notify_set_muted _:($recipient -> r: global_id, $sender -> s: global_id)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        inner is (global_id ->> bool) = (,).
        if (a2a_notifications::notify_sender_muted r) != NIL { inner -> (a2a_notifications::notify_sender_muted r)?. }
        inner s -> FALSE.
        a2a_notifications::notify_sender_muted r -> inner.
        return transaction::success [ _return_data ($muted -> TRUE), _save_state NIL ].
    }

    // Clear mute: delete the entry — absent = enabled per §7.
    trn qa_notify_clear_muted _:($recipient -> r: global_id, $sender -> s: global_id)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        if (a2a_notifications::notify_sender_muted r) != NIL
        {
            inner is (global_id ->> bool) = (a2a_notifications::notify_sender_muted r)?.
            if (inner s) != NIL { delete inner s. a2a_notifications::notify_sender_muted r -> inner. }
        }
        return transaction::success [ _return_data ($cleared -> TRUE), _save_state NIL ].
    }

    // Clear sender slot: delete notify_sender_tokens[recipient][sender].
    // Used in N21 to create the absent-slot abort condition.
    trn qa_notify_clear_sender_slot _:($recipient -> r: global_id, $sender -> s: global_id)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        if (a2a_notifications::notify_sender_tokens r) != NIL
        {
            inner is (global_id ->> a2a_notifications::notify_token_t) = (a2a_notifications::notify_sender_tokens r)?.
            if (inner s) != NIL { delete inner s. a2a_notifications::notify_sender_tokens r -> inner. }
        }
        return transaction::success [ _return_data ($cleared -> TRUE), _save_state NIL ].
    }

    // Return exactly the $sender_muted map the LAST on_notify_registration hook
    // call carried (the engine-mirror feed). Precise probe — avoids grepping
    // the whole regconfirm_log dump.
    trn readonly qa_last_confirm_muted _
    {
        found is any = NIL.
        sc regconfirm_log -- ( -> entry) { found -> entry. }
        abort "No confirms logged." when found == NIL.
        return ($sender_muted -> (found $sender_muted)).
    }

    // Send set_sender_muted directly to the service without going through the
    // client-side wrapper (bypasses the client's registration check). Used in N26
    // to probe the service-side registered-recipient gate.
    trn qa_set_sender_muted_direct _:($service -> svc: global_id, $sender -> s: global_id, $muted -> m: bool)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        return encrypted_channel::execute_transaction svc (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx svc (
                    $name -> "::a2a_notifications::set_sender_muted",
                    $targ -> ($sender -> s, $muted -> m)
                ),
                _return_data ($sent_to -> svc)
            ].
        }).
    }

    // E9: a well-formed confirm_registration over a REAL channel, from a contact
    // that is neither a pending nor a registered service of the target.
    trn qa_send_fake_confirm _:($target -> target: global_id)
    {
        return encrypted_channel::execute_transaction target (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx target (
                    $name -> "::a2a_notifications::confirm_registration",
                    $targ -> ($vapid_pub -> "EVIL_VAPID", $bindings -> NIL, $sender_tokens -> (,), $sender_muted -> (,))
                ),
                _return_data ($sent -> TRUE)
            ].
        }).
    }
    // ---- cross-version leg-1 senders (PLAN Step 4.1) ----
    // Emit a submit_invite_response whose BOXED payload is the EXACT wire shape
    // of a given core version's sender — the 0.2.0 ($shape "v2": no $name, no
    // $pv), 0.3.0 ("v3": +$name), 0.5.0 ("v5": +$pv/$caps), or a BELOW-FLOOR
    // dialect ("too_old": v2 fields + $pv -> 1, the Addition A/B injection).
    // Sender-side emulation only: the responder-side completion stores are
    // hidden (INV-4), so the inviter-side outcome + the leg-3 ARRIVAL at this
    // packet (visible as its gate abort) are what the driver asserts.
    trn qa_send_versioned_leg1 _:($invite -> blob: bin, $shape -> shape: str, $name -> name: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        inv = (_read_or_abort blob) safe a2a_protocol::invite_eph_t.
        kpr = _crypto_construct_encryption_keypair (inv $v).
        my_ad = address_document::get_my_address_document().

        payload is bin+ = NIL.
        if shape == "v2"
        {
            payload -> (_write ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> (inv $d))).
        }
        if shape == "v3"
        {
            payload -> (_write ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> (inv $d), $name -> name)).
        }
        if shape == "v5"
        {
            // literal 5: this shape emulates a 0.5.0 sender (wire_version moved on).
            payload -> (_write ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> (inv $d), $name -> name, $pv -> 5, $caps -> ["core.notifications"])).
        }
        if shape == "too_old"
        {
            payload -> (_write ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> (inv $d), $pv -> 1)).
        }
        abort "qa_send_versioned_leg1: unknown shape " + shape when payload == NIL.

        data = _crypto_encrypt_message (kpr $secret_key) (inv $k) payload?.
        return transaction::success [
            transaction::action::send (inv $c) (
                $name -> "::a2a_messaging::submit_invite_response",
                $targ -> ($invite_id -> (inv $d), $epk -> (kpr $public_key), $v -> (inv $v), $data -> data)
            ),
            _return_data ($sent -> TRUE, $shape -> shape)
        ].
    }

    // Passive version learning probe: the contact_pv map (cid -> learned wire
    // dialect; absent = nothing learned yet, 0 = pre-0.5 peer).
    trn readonly qa_contact_pv _
    {
        return ($contact_pv -> a2a_messaging::contact_pv, $contact_caps -> a2a_messaging::contact_caps).
    }

    // Per-cid probes (precise driver assertions, no map-dump parsing):
    // learned dialect (-1 = nothing learned), advertised caps, contact name.
    trn readonly qa_contact_pv_of _:($cid -> cid: global_id)
    {
        p = a2a_messaging::contact_pv cid.
        caps = a2a_messaging::contact_caps cid.
        empty is str[] = [].
        return (
            $pv   -> (p == NIL ?? 0 - 1 ; p?),
            $caps -> (caps == NIL ?? empty ; caps?)
        ).
    }
    trn readonly qa_contact_name _:($cid -> cid: global_id)
    {
        c = a2a_messaging::contacts cid.
        return ($name -> (c == NIL ?? "" ; (c? $name))).
    }

    // Inject a learned capability set for a contact — drives the CAP-1 gate
    // tests (positive-evidence denial vs unknown/empty pass-through).
    trn qa_set_contact_caps _:($cid -> cid: global_id, $caps -> caps: str[])
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        a2a_messaging::contact_caps cid -> caps.
        return transaction::success [ _return_data ($set -> TRUE), _save_state NIL ].
    }

    // Inject a learned dialect for a contact — arranges the "peer was v2 at
    // invite time" precondition of the upgrade scenario (V7) on a pair that
    // has a live encrypted channel (V1 proves the real v2 leg-1 learns 2).
    trn qa_set_contact_pv _:($cid -> cid: global_id, $pv -> pv: int)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        a2a_messaging::contact_pv cid -> pv.
        return transaction::success [ _return_data ($set -> TRUE), _save_state NIL ].
    }

    // Emit the EXACT pre-0.5 legacy receive_message $targ — only $text, no
    // $wire_id / $reply_to / $pv — over the established encrypted channel
    // (byte-shape of the deployed 0.2-line sender). Drives the V7 monotonicity
    // assertion: unstamped legacy traffic must never downgrade learned state.
    trn qa_send_legacy_message _:($target -> tgt: global_id, $text -> text: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        return encrypted_channel::execute_transaction tgt (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx tgt (
                    $name -> "::actor::receive_message",
                    $targ -> ($text -> text)
                ),
                _return_data ($sent -> TRUE)
            ].
        }).
    }

    // ---- core 0.8.0 group-chat QA (G-series) ----
    trn readonly qa_group_log _ { return ($log -> group_log). }
    // NOTE: group state is read via the a2a_group::list_groups / get_group
    // TRNs directly from the driver — NOT a forwarder fn here. A fn that
    // touches the nested groups map is INLINED across the library boundary and
    // blows the meta step budget; a trn returns an already-flattened value.

    // ---- core 0.7.0 receipts QA (RC-series) ----
    trn readonly qa_receipts_log _ { return ($log -> receipts_log). }
    trn readonly qa_receipt_expectation _:($cid -> cid: global_id)
    {
        return ($state -> (a2a_messaging::receipt_expectation cid)).
    }
    // (Re)declare this node's advertised protocol caps — drives the emit gate's
    // self side (a2a_capabilities::init is re-callable; empty handlers, stub
    // describe: receipts ids are $advertise-class, no control verbs).
    trn qa_init_caps _:($advertise -> adv: str[])
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        a2a_capabilities::init (
            $describe -> fn (_: any) -> a2a_capabilities::app_manifest_t
            {
                return ($version -> 1, $app_id -> "test.actor", $name -> "actor",
                        $description -> "", $monitoring_status -> "off", $capabilities -> (,)).
            },
            $supported -> [],
            $handlers -> (,),
            $on_unknown -> fn (_: any) -> transaction::action::type[] { return []. },
            $authorizer -> NIL,
            $advertise -> adv
        ).
        return transaction::success [ _return_data ($set -> TRUE) ].
    }
    // Consumer read-path emission (the get/mark-read moment): appends the core
    // read_receipt_actions for ids just transitioned unread->read.
    trn qa_mark_read _:($contact -> cid: global_id, $wire_ids -> wids: str[])
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        actions is transaction::action::type[] = [].
        sc a2a_messaging::read_receipt_actions cid wids -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        actions (_count actions|) -> _return_data ($sent -> ((_count actions) > 0)).
        return transaction::success actions.
    }
    // Raw receipt injector (forward-compat / shape-tolerance cells).
    trn qa_send_raw_receipt _:($target -> tgt: global_id, $kind -> kind: any, $wire_ids -> wids: any)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        return encrypted_channel::execute_transaction tgt (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx tgt (
                    $name -> "::a2a_messaging::receive_receipt",
                    $targ -> ($kind -> kind, $wire_ids -> wids, $pv -> a2a_versions::wire_version)
                ),
                _return_data ($sent -> TRUE)
            ].
        }).
    }

    // Emulate an OLD-dialect sender: a stamped message with an arbitrary $pv
    // (+ wire_id so the receiver's delivered-emission path is actually
    // evaluated, not short-circuited). Drives the RC10 old-peer-silence cell:
    // the receiver LEARNS the stamped pv from this very message (learning
    // precedes the gate — the self-heal mechanism), so presetting maps isn't
    // enough; the message itself must carry the old dialect.
    trn qa_send_stamped_message _:($target -> tgt: global_id, $text -> text: str, $pv -> pv: int, $wire_id -> wid: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        return encrypted_channel::execute_transaction tgt (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx tgt (
                    $name -> "::actor::receive_message",
                    $targ -> ($text -> text, $wire_id -> wid, $pv -> pv)
                ),
                _return_data ($sent -> TRUE)
            ].
        }).
    }

    // ---- golden-wire corpus probes (COMPATIBILITY.md release gate) ----
    // One fixture per REGISTERED version per registry, built as the EXACT wire
    // shape that version's sender emits (fixtures-as-code: the payloads carry
    // real global_ids + a real AD, which JSON fixtures cannot encode), replayed
    // through the registry try_narrow_* dispatch. The driver asserts the branch
    // taken for every registered version — a release is green only if all pass.
    trn qa_corpus_narrow _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        my_ad = address_document::get_my_address_document().
        iid = _new_id "qa corpus invite".
        rid = _new_id "qa corpus rid".

        // registry "sir" — leg-1 boxed bundle: v2 (no $name), v3 (+$name),
        // v5 (+$pv/$caps), a below-floor dialect ($pv -> 1), an unrecognized
        // shape, and a FUTURE dialect ($pv -> 7, v5 shape + unknown field).
        sir_v2  = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> iid).
        sir_v3  = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> iid, $name -> "Bob").
        sir_v5  = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> iid, $name -> "Carol", $pv -> 5, $caps -> ["core.notifications"]).
        sir_old = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> iid, $pv -> 1).
        sir_bad = ($nope -> 1).
        sir_fut = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> iid, $name -> "Dee", $pv -> 7, $caps -> ["core.notifications"], $future_field -> "F").
        // M1 wrong-domain fixtures: present-but-mistyped NON-nullable fields
        // must classify as shape errors (error-as-data), never abort the cast.
        sir_wid = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> 42).
        sir_wnm = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> iid, $name -> 42).
        // Mistyped $pv: tolerated as UNSTAMPED (shape inference applies) — this
        // one carries $name so it dispatches v3.
        sir_wpv = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> iid, $name -> "Eve", $pv -> "five").
        // Synthetic $pv=4 (dead 0.4 line, wire-identical to 0.3): narrows as v3.
        sir_pv4 = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> iid, $name -> "Fay", $pv -> 4).

        r2 = a2a_versions::try_narrow_sir (sir_v2 as any).
        r3 = a2a_versions::try_narrow_sir (sir_v3 as any).
        r5 = a2a_versions::try_narrow_sir (sir_v5 as any).
        ro = a2a_versions::try_narrow_sir (sir_old as any).
        rb = a2a_versions::try_narrow_sir (sir_bad as any).
        rf = a2a_versions::try_narrow_sir (sir_fut as any).
        rwid = a2a_versions::try_narrow_sir (sir_wid as any).
        rwnm = a2a_versions::try_narrow_sir (sir_wnm as any).
        rwpv = a2a_versions::try_narrow_sir (sir_wpv as any).
        rpv4 = a2a_versions::try_narrow_sir (sir_pv4 as any).

        // registry "cin" — leg-3 boxed bundle: v2 / v5.
        c2 = a2a_versions::try_narrow_cin ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> iid).
        c5 = a2a_versions::try_narrow_cin ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> iid, $pv -> 5, $caps -> []).
        co = a2a_versions::try_narrow_cin ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> iid, $pv -> 1).

        // registry "rst" — restore boxed bundle: v2 / v5.
        s2 = a2a_versions::try_narrow_rst ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $rid -> rid).
        s5 = a2a_versions::try_narrow_rst ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $rid -> rid, $pv -> 5, $caps -> []).
        so = a2a_versions::try_narrow_rst ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $rid -> rid, $pv -> 1).

        // registry "acc" — legacy accept_contact args: v2 (no $joiner_name) / v3.
        a2 = a2a_versions::try_narrow_acc ($invite_id -> iid, $joiner_ad -> my_ad).
        a3 = a2a_versions::try_narrow_acc ($invite_id -> iid, $joiner_ad -> my_ad, $joiner_name -> "Joi").
        ao = a2a_versions::try_narrow_acc ($invite_id -> iid, $joiner_ad -> my_ad, $pv -> 1).

        return transaction::success [ _return_data (
            $sir -> (
                $v2  -> ($ok -> (r2 $ok), $v -> (a2a_versions::sir_version_of (sir_v2 as any)), $name -> (a2a_versions::sir_joiner_name ((r2 $payload)?))),
                $v3  -> ($ok -> (r3 $ok), $v -> (a2a_versions::sir_version_of (sir_v3 as any)), $name -> (a2a_versions::sir_joiner_name ((r3 $payload)?))),
                $v5  -> ($ok -> (r5 $ok), $v -> (a2a_versions::sir_version_of (sir_v5 as any)), $name -> (a2a_versions::sir_joiner_name ((r5 $payload)?))),
                $old -> ($ok -> (ro $ok), $code -> (((ro $err)?) $code), $msg -> (((ro $err)?) $message), $peer_v -> (((ro $err)?) $peer_version), $min -> (((ro $err)?) $min_supported)),
                $bad -> ($ok -> (rb $ok), $code -> (((rb $err)?) $code), $msg -> (((rb $err)?) $message)),
                $fut -> ($ok -> (rf $ok), $name -> (a2a_versions::sir_joiner_name ((rf $payload)?)), $stripped_future -> ((((rf $payload)?) as any) $future_field == NIL)),
                $wid -> ($ok -> (rwid $ok), $code -> (((rwid $err)?) $code)),
                $wnm -> ($ok -> (rwnm $ok), $code -> (((rwnm $err)?) $code)),
                $wpv -> ($ok -> (rwpv $ok), $name -> (a2a_versions::sir_joiner_name ((rwpv $payload)?)), $v -> (a2a_versions::sir_version_of (sir_wpv as any))),
                $pv4 -> ($ok -> (rpv4 $ok), $name -> (a2a_versions::sir_joiner_name ((rpv4 $payload)?)))
            ),
            $cin -> (
                $v2  -> ($ok -> (c2 $ok)),
                $v5  -> ($ok -> (c5 $ok)),
                $old -> ($ok -> (co $ok), $code -> (((co $err)?) $code))
            ),
            $rst -> (
                $v2  -> ($ok -> (s2 $ok)),
                $v5  -> ($ok -> (s5 $ok)),
                $old -> ($ok -> (so $ok), $code -> (((so $err)?) $code))
            ),
            $acc -> (
                $v2  -> ($ok -> (a2 $ok), $name -> (a2a_versions::acc_joiner_name ((a2 $payload)?))),
                $v3  -> ($ok -> (a3 $ok), $name -> (a2a_versions::acc_joiner_name ((a3 $payload)?))),
                $old -> ($ok -> (ao $ok), $code -> (((ao $err)?) $code))
            )
        ) ].
    }

    // The STRICT narrow on a below-floor payload must abort with the stable
    // error message (never a raw NIL-cast EVAL_ERROR) — driver asserts the text.
    trn qa_corpus_narrow_strict_old _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        my_ad = address_document::get_my_address_document().
        iid = _new_id "qa strict".
        p = a2a_versions::narrow_sir ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> iid, $pv -> 1).
        return transaction::success [ _return_data ($unreachable -> ((p as any) $invite_id)) ].
    }

    // ---- leg-3 isolation helpers ----
    // A fake invite carrying a chosen inviter cid; the named cid never minted it, so
    // its leg-2 aborts (unknown invite) and sends no real leg-3 — leaving the
    // responder with a LIVE redemption + kept eph priv to target.
    trn qa_mint_fake_invite _:($inviter_cid -> icid: global_id)
    {
        scheme = _crypto_default_scheme_id().
        kp = _crypto_construct_encryption_keypair scheme.
        iid = _new_id "fake invite".
        inv is a2a_protocol::invite_eph_t = ($d -> iid, $c -> icid, $n -> "Fake", $k -> (kp $public_key), $v -> scheme).
        return transaction::success [ _return_data ($blob -> (_write inv), $invite_id -> iid) ].
    }
    // Crafted leg-3 as a BARE BOXED send to the responder's kept eph pubkey.
    // mode: "real" (sender-pin) | "foreign" (cid-bind leg-3) | "forged" (PoP leg-3).
    trn qa_send_complete _:($target -> tgt: global_id, $invite_id -> iid: global_id, $resp_eph_pub -> rpk: publickey_encrypt, $mode -> mode: str, $foreign_ad -> fad: bin)
    {
        scheme = _crypto_default_scheme_id().
        kpi = _crypto_construct_encryption_keypair scheme.
        my_ad = address_document::get_my_address_document().
        ad is address_document_types::t_address_document = my_ad.
        if mode == "foreign" { ad -> (_read_or_abort fad) safe address_document_types::t_address_document. }
        if mode == "forged"  { ad -> ($version -> (my_ad $version), $identity -> (my_ad $identity), $authorizations -> (,)). }
        payload = _write ($ad -> ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> iid).
        data = _crypto_encrypt_message (kpi $secret_key) rpk payload.
        return transaction::success [
            transaction::action::send tgt ($name -> "::a2a_messaging::complete_invite", $targ -> ($invite_id -> iid, $epk -> (kpi $public_key), $v -> scheme, $data -> data)),
            _return_data ($sent -> TRUE)
        ].
    }
}
