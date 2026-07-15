// Self-contained test actor for the core-3.0 ephemeral-invite suite
// (T/V/RC-series; the a2a_notifications N-series moved to notif_actor.mu).
//
// DERIVED locally for the core repo — it does NOT vendor any consumer/daemon
// source. It loads only the shared core libraries this suite exercises
// (a2a_protocol + a2a_messaging + their stdlib deps) and provides the MINIMUM
// host wiring a packet needs: the storage hooks a2a_messaging::init requires, a
// tiny inbox, the identity-hierarchy helper trns (so the role scenario can mint
// a delegation chain), export/import wrappers (migration scenario), and the
// `qa_*` probe trns the driver uses to inject adversarial inputs and read state.
//
// It does NOT load a2a_notifications: the compiler bounds meta-stage type-level
// reduction PER COMPILED UNIT (adapt src/eval/meta_reduction_fuel.h, 1M steps).
// Loading BOTH a2a_messaging AND a2a_notifications, after the 0.9.0 migration
// surface landed in a2a_messaging, tips this unit OVER the ceiling. a2a_messaging
// has ZERO references to a2a_notifications (the dep is one-way), so the
// notification tests split cleanly into notif_actor.mu (which loads both libs and
// keeps the COMBINED core+notify export/import round-trip). This unit keeps only
// the core-half export/import round-trip.
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

    }

    // ---- minimal host surface used by the driver ----
    // The core's send_message delivers to the legacy ::actor::receive_message name;
    // this shim routes it into the core receive handler (→ on_message_received hook).
    trn receive_message args: any { return a2a_messaging::handle_receive_message args. }
    trn readonly list_incoming_messages _ { return ($inbox -> inbox). }
    trn readonly list_incoming_files _ { return ($files -> files). }

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
    // CORE-ONLY (this unit no longer loads a2a_notifications): the COMBINED
    // core+notify round-trip moved to notif_actor.mu/notif.mjs (the unit that
    // loads both libraries). test_actor keeps only the core-half round-trip.
    trn readonly export_state _ { return ($core -> (a2a_messaging::export_core_state NIL)). }
    trn import_state data: any
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        a2a_messaging::import_core_state (data $core).
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
        // Bound `any`, not `safe t_address_document`: the AD is embedded as the
        // `$ad -> any` payload field and re-verified downstream; casting to the
        // full AD type here needlessly deepens meta-stage type reduction (AD-v2
        // embeds t_e2e_bundle) — the per-unit fuel budget is scarce (corpus split).
        foreign = _read_or_abort fad.
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
        forged = ($version -> (my_ad $version), $identity -> (my_ad $identity), $authorizations -> (,)).   // untyped: embedded as $ad -> any, verified downstream (fuel budget)
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
        ad = my_ad as any.   // any, not typed AD: embedded as $ad -> any downstream (meta-stage fuel budget)
        if mode == "foreign" { ad -> (_read_or_abort fad). }
        if mode == "forged"  { ad -> ($version -> (my_ad $version), $identity -> (my_ad $identity), $authorizations -> (,)). }
        payload = _write ($ad -> ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $invite_id -> iid).
        data = _crypto_encrypt_message (kpi $secret_key) rpk payload.
        return transaction::success [
            transaction::action::send tgt ($name -> "::a2a_messaging::complete_invite", $targ -> ($invite_id -> iid, $epk -> (kpi $public_key), $v -> scheme, $data -> data)),
            _return_data ($sent -> TRUE)
        ].
    }

}
