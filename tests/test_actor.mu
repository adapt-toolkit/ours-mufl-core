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
        metadef msg_t: ($sender -> global_id, $text -> str, $wire_id -> str, $reply_wire -> str, $message_kind -> str).
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

        // core 0.13 TEST-ONLY probe ephemerals (cross-redeemer leg-1 isolation).
        // Hidden and fixture-local: never exported, never reachable from production.
        qa_leg1_keys is (str ->> secretkey_encrypt) = (,).

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
                mk is str = a2a_protocol::message_kind_text.
                if (arg $message_kind) != NIL { mk -> (arg $message_kind) safe str. }
                inbox (_count inbox|) -> ($sender -> sid, $text -> txt, $wire_id -> wid, $reply_wire -> rw, $message_kind -> mk).
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

    // $cert_v1 (NULLABLE): the SAME chain minted over my v1 (bundle-less) AD, so a
    // down-level to a pre-E2E peer carries a cert whose $role_ad_hash matches the v1
    // AD that peer receives. Verified against _value_id(produce_v1_address_document()).
    trn set_delegation _:($cert -> cert_blob: bin, $root_ad -> root_ad_blob: bin, $root_profile -> rp_blob: bin, $cert_v1 -> cert_v1_blob: bin+)
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
        if cert_v1_blob != NIL
        {
            cert_v1 = (_read_or_abort cert_v1_blob?) safe a2a_protocol::delegation_cert_t.
            v1_ad = address_document::get_my_address_document_versioned(TRUE).
            abort "v1 cert not for me." when (cert_v1 $c $role_cid) != _get_container_id().
            abort "v1 cert AD mismatch." when (cert_v1 $c $role_ad_hash) != (_value_id v1_ad).
            abort "v1 cert root mismatch." when (cert_v1 $c $root_cid) != (cert $c $root_cid).
            abort "v1 cert not root-signed." when key_storage::check_signature_new_container (_value_id (cert_v1 $c)) (cert_v1 $s) (new_root_ad $identity $key_list) != TRUE.
            a2a_messaging::delegation_cert_v1 -> cert_v1.
        }
        return transaction::success [ _return_data ($delegated -> TRUE), _save_state NIL ].
    }

    // Expose my v1 (bundle-less) AD so the root can sign a v1-bound delegation cert
    // (the daemon mints this by calling sign_delegation with this blob).
    trn export_v1_address_document _
    {
        v1_ad = address_document::get_my_address_document_versioned(TRUE).
        return transaction::success [ _return_data ($ad -> (_write v1_ad)) ].
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

    // ---- receive-side E2E dedup window QA ----
    trn qa_dedup_note _:($contact -> cid: global_id, $wire_id -> wid: str)
    {
        a2a_messaging::delivered_note cid wid.
        return transaction::success [ _return_data ($noted -> TRUE), _save_state NIL ].
    }
    trn readonly qa_dedup_state _:($contact -> cid: global_id)
    {
        q = a2a_messaging::delivered_wire cid.
        ids is str[] = [].
        bytes is int = 0.
        if q != NIL
        {
            sc q? -- ( -> e) { ids (_count ids|) -> (e $w). }
            bytes -> _binlen (_write q?).
        }
        return ($count -> (_count ids|), $ids -> ids, $serialized_bytes -> bytes).
    }
    trn readonly qa_dedup_seen _:($contact -> cid: global_id, $wire_id -> wid: str)
    { return ($seen -> (a2a_messaging::wire_seen cid wid)). }
    trn qa_dedup_seed _:($contact -> cid: global_id, $wire_ids -> wids: str[], $expire_first -> expire_first: bool)
    {
        now = (current_transaction_info::get_transaction_time())?.
        ancient = _time_from_seconds_and_nanoseconds_since_epoch 0 0.
        q is a2a_messaging::delivered_entry_t[] = [].
        i is int = 0.
        sc wids -- ( -> w)
        {
            d = now.
            if expire_first && i == 0 { d -> ancient. }
            q (_count q|) -> ($w -> w, $d -> d).
            i -> i + 1.
        }
        a2a_messaging::delivered_wire cid -> q.
        return transaction::success [ _return_data ($seeded -> (_count wids|)), _save_state NIL ].
    }
    trn qa_dedup_import _:($contact -> cid: global_id, $wire_ids -> wids: str[], $legacy -> legacy: bool)
    {
        now = (current_transaction_info::get_transaction_time())?.
        current is a2a_messaging::delivered_entry_t[] = [].
        old is str[] = [].
        sc wids -- ( -> w)
        {
            current (_count current|) -> ($w -> w, $d -> now).
            old (_count old|) -> w.
        }
        if legacy
        {
            dw_old is (global_id ->> str[]) = (,).
            dw_old cid -> old.
            a2a_messaging::import_core_state ($my_name -> "DedupImport", $contacts -> (,), $peer_ads -> (,), $delivered_wire -> dw_old).
        }
        else
        {
            dw_new is (global_id ->> a2a_messaging::delivered_entry_t[]) = (,).
            dw_new cid -> current.
            a2a_messaging::import_core_state ($my_name -> "DedupImport", $contacts -> (,), $peer_ads -> (,), $delivered_wire -> dw_new).
        }
        return transaction::success [ _return_data ($imported -> (_count wids|)), _save_state NIL ].
    }
    trn qa_dedup_restart _
    {
        state = a2a_messaging::export_core_state NIL.
        a2a_messaging::import_core_state state.
        return transaction::success [ _return_data ($restarted -> TRUE), _save_state NIL ].
    }
    trn qa_unacked_fill _:($contact -> cid: global_id, $wire_ids -> wids: str[])
    {
        now = (current_transaction_info::get_transaction_time())?.
        sc wids -- ( -> w)
        {
            a2a_messaging::unacked_note cid "m" w (_write ($wire_id -> w)) now.
        }
        q = a2a_messaging::unacked_e2e cid.
        n is int = 0.
        if q != NIL { n -> _count q?|. }
        return transaction::success [ _return_data ($count -> n), _save_state NIL ].
    }

    trn qa_import_mismatched_public_key _
    {
        data = a2a_messaging::export_core_state NIL.
        bad_keys is (global_id ->> secretkey_encrypt) = (,).
        sc a2a_messaging::pending_invites -- (iid -> rec) ?? (_count bad_keys|) == 0 &&
            (a2a_protocol::normalize_invite_mode (rec $mode)) == a2a_protocol::invite_mode_public
        {
            substitute = _crypto_construct_encryption_keypair (rec $scheme).
            bad_keys iid -> (substitute $secret_key).
        }
        abort "qa_import_mismatched_public_key requires one public invite" when (_count bad_keys|) != 1.
        data $public_invite_keys -> bad_keys.
        a2a_messaging::import_core_state data.
        return transaction::success [ _return_data ($unexpected_success -> TRUE) ].
    }

    trn qa_import_without_public_fields _
    {
        data = a2a_messaging::export_core_state NIL.
        data $public_invites -> NIL.
        data $public_invite_keys -> NIL.
        a2a_messaging::import_core_state data.
        return transaction::success [ _return_data ($imported -> TRUE), _save_state NIL ].
    }

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

    // Force a contact's stored display name, bypassing register_contact —
    // simulates a pre-uniqueness book (or a hypothetical write site that skips
    // the helper) so the resolver's ambiguity abort can be exercised against
    // REAL contacts with live channels, which no public surface can produce
    // once ordinal suffixing is in place.
    trn qa_force_contact_name _:($cid -> cid: global_id, $name -> name: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        a2a_messaging::contacts cid -> ($name -> name, $container_id -> cid).
        return transaction::success [ _return_data ($forced -> name), _save_state NIL ].
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

    trn qa_set_command_catalog _:($catalog -> catalog: str+)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        a2a_messaging::set_self_command_catalog catalog.
        return transaction::success [ _return_data ($set -> TRUE), _save_state NIL ].
    }

    trn qa_set_contact_command_catalog _:($cid -> cid: global_id, $catalog -> catalog: str+)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        a2a_messaging::learn_contact_command_catalog cid catalog.
        return transaction::success [ _return_data ($set -> TRUE), _save_state NIL ].
    }

    trn readonly qa_get_command_catalogs _:($cid -> cid: global_id)
    {
        return ($self -> (a2a_messaging::get_self_command_catalog NIL),
                $contact -> (a2a_messaging::get_contact_command_catalog cid)).
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

    // ---- core 0.13 bilateral-removal QA (security regressions) ----
    // ARRANGE an epoch pin for `cid`, standing in for a completed migration. Same
    // pattern the V7 series already uses to arrange v2-era state (qa_set_contact_pv /
    // qa_set_contact_caps): driving the full migration FSM between two born-DR nodes
    // is not reachable in a fixture (mig_should_trigger refuses born-DR contacts by
    // design), and what the barrier under test keys off is precisely the presence of
    // contact_e2e_epoch. The BYTES are arbitrary — nothing in the barrier reads them.
    trn qa_set_e2e_epoch _:($cid -> cid: global_id, $epoch -> ep: bin, $session_id -> sid: bin)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        a2a_messaging::contact_e2e_epoch cid -> ($epoch -> ep, $session_id -> sid).
        a2a_messaging::contact_e2e_seen cid -> TRUE.
        return transaction::success [ _return_data ($set -> TRUE), _save_state NIL ].
    }

    // THE DOWNGRADE ATTACK: push a contact-removal notice over the LEGACY encrypted
    // channel. Against a peer that is epoch-pinned to me this must be refused —
    // purging nothing and clearing no pin.
    trn qa_send_legacy_crm _:($target -> tgt: global_id, $reason -> reason: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        return encrypted_channel::execute_transaction tgt (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx tgt (
                    $name -> "::a2a_messaging::receive_contact_removal",
                    $targ -> ($reason -> reason, $pv -> 9)
                ),
                _return_data ($sent -> TRUE)
            ].
        }).
    }

    // FORGERY: the same notice as a BARE, UNENCRYPTED send. check_encrypted_or_abort
    // must reject it before any state is touched.
    trn qa_send_bare_crm _:($target -> tgt: global_id, $reason -> reason: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        return transaction::success [
            transaction::action::send tgt (
                $name -> "::a2a_messaging::receive_contact_removal",
                $targ -> ($reason -> reason, $pv -> 9)
            ),
            _return_data ($sent -> TRUE)
        ].
    }

    // Typed test-only mint seam: compilation and transaction argument validation
    // prove that invite mode is the same closed enum all the way into the shared
    // construction helper (rather than an integer/string flag at this boundary).
    trn qa_mint_mode_invite _:($mode -> mode: a2a_protocol::invite_mode_t)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        minted = a2a_messaging::mint_eph_invite "" mode.
        return transaction::success [
            _return_data ($invite -> (minted $blob), $invite_id -> (minted $invite_id)),
            _save_state NIL
        ].
    }

    // Decode the real invite blob through invite_eph_t and surface its enum. This
    // checks that the mode did not become an untyped integer/string on the wire.
    trn readonly qa_read_invite_mode _:($invite -> invite_blob: bin)
    {
        inv = (_read_or_abort invite_blob) safe a2a_protocol::invite_eph_t.
        return ($mode -> (a2a_protocol::normalize_invite_mode (inv $m))).
    }

    // ---- core 0.13 cross-redeemer leg-1 confidentiality QA ----
    // TEST-ONLY, AND DELIBERATELY ONLY HERE. These probes hand back raw leg-1
    // ciphertext and attempt decryption with a CHOSEN ephemeral. They exist to produce
    // NEGATIVE evidence (a wrong-key open must FAIL) and are confined to this QA
    // fixture: actor.mu, the production unit, defines none of them, they are not
    // reachable from any advertised capability or MCP tool, and the driver asserts
    // that invoking them on a production packet fails.
    //
    // WHY THE PROBE KEYS STAND IN FOR pending_redemption_keys: that store is `hidden`
    // in a2a_messaging, so only that library can read it. Exposing a peek would put a
    // secret-reading accessor into the PRODUCTION core purely for a test — a strictly
    // worse trade than this. The property under test is unaffected: each redeemer
    // boxes with an INDEPENDENT ephemeral of its own, so "B's ephemeral cannot open
    // A's box" is a property of the key pairing, not of which store holds the key.
    // The boxes are built against the REAL published invite's ephemeral pubkey.

    // Mint a probe ephemeral under `tag`; returns only its PUBLIC half.
    trn qa_mint_probe_key _:($tag -> tag: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        kp = _crypto_construct_encryption_keypair (_crypto_default_scheme_id()).
        qa_leg1_keys tag -> (kp $secret_key).
        return transaction::success [ _return_data ($pub -> (kp $public_key)), _save_state NIL ].
    }

    // Build a leg-1-shaped box to `to_pub` with a FRESH sender ephemeral, exactly as
    // add_contact boxes its identity bundle to the invite's ephemeral pubkey. Returns
    // what travels on the wire ($epk + $data). Nothing is sent: the isolation property
    // is a property of the box, not of delivery.
    trn qa_leg1_box _:($to_pub -> to_pub: publickey_encrypt, $tag -> tag: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        kp = _crypto_construct_encryption_keypair (_crypto_default_scheme_id()).
        payload = _write ($probe -> tag).
        data = _crypto_encrypt_message (kp $secret_key) to_pub payload.
        return transaction::success [
            _return_data ($epk -> (kp $public_key), $data -> data),
            _save_state NIL
        ].
    }

    // Attempt to open `data` with the ephemeral stored under `key_tag`.
    // _crypto_decrypt_message ABORTS on a wrong key, so a failed open surfaces to the
    // driver as a REJECTED transaction — which is the negative evidence being sought.
    // A successful open resolves and echoes the probe marker, proving it really opened
    // the intended plaintext rather than merely not crashing.
    trn qa_try_open_leg1 _:($epk -> epk: publickey_encrypt, $data -> data: crypto_message, $key_tag -> key_tag: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        sk = qa_leg1_keys key_tag abort "qa_try_open_leg1: no such probe key" WHEN IS NIL.
        pt = _crypto_decrypt_message sk? epk data.
        iv2 = key_storage::read_external pt.
        marker is str = "".
        if (iv2 $probe) != NIL { marker -> (iv2 $probe) safe str. }
        return transaction::success [ _return_data ($opened -> TRUE, $marker -> marker) ].
    }

    // Report what a published invite blob actually carries, so the driver can assert
    // it exposes only the PUBLIC ephemeral half — nothing able to open a leg-1 box.
    trn readonly qa_invite_fields _:($invite -> blob: bin)
    {
        inv = (_read_or_abort blob) safe a2a_protocol::invite_eph_t.
        return ($has_pub -> ((inv $k) != NIL), $eph_pub -> (inv $k), $mode -> (inv $m), $raw -> (_read_or_abort blob)).
    }

    // ---- core 0.13 contact_origin export/import QA ----
    // Import a MINIMAL legacy-shaped core blob that has NO $contact_origin at all —
    // the pre-0.13 case. Everything import_core_state treats as mandatory is present.
    trn qa_import_legacy_core _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        a2a_messaging::import_core_state (
            $my_name -> "LegacyImported",
            $contacts -> (,),
            $peer_ads -> (,)
        ).
        return transaction::success [ _return_data ($imported -> TRUE), _save_state NIL ].
    }

    // Import a core blob whose $contact_origin is HOSTILE: a wrong-typed $via on one
    // entry, an unknown extra field on another, and one well-formed entry. The import
    // must not abort, and the well-formed entry must survive.
    // Every malformed shape the guard must survive, in ONE blob so a single import
    // proves the whole class degrades rather than aborting. Keys are also placed in
    // $contacts, because the rebuild draws its keys from there (trusted) rather than
    // from the untrusted provenance map.
    //   good      — well-formed, PLUS an unknown extra field (must be stripped)
    //   bad_via   — wrong-typed $via (int)                       -> entry dropped
    //   bad_at    — wrong-typed $at (str, not a time)            -> entry dropped
    //   bad_iid   — non-hex $invite_id (would abort `safe global_id`) -> KEPT, label dropped
    //   no_at     — missing $at entirely                          -> entry dropped
    trn qa_import_hostile_origin _:($good_cid -> good: global_id, $bad_cid -> bad: global_id, $at_cid -> atc: global_id, $iid_cid -> iidc: global_id, $noat_cid -> noatc: global_id)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        now = (current_transaction_info::get_transaction_time())?.
        a2a_messaging::import_core_state (
            $my_name -> "HostileImported",
            $contacts -> (
                good  -> ($name -> "Good",   $container_id -> good),
                bad   -> ($name -> "BadVia", $container_id -> bad),
                atc   -> ($name -> "BadAt",  $container_id -> atc),
                iidc  -> ($name -> "BadIid", $container_id -> iidc),
                noatc -> ($name -> "NoAt",   $container_id -> noatc)
            ),
            $peer_ads -> (,),
            $contact_origin -> (
                bad   -> ($via -> 12345, $at -> now),
                atc   -> ($via -> "invite_public", $at -> "not-a-time"),
                iidc  -> ($via -> "invite_one_time", $at -> now, $invite_id -> "zzzz-not-hex-!!"),
                noatc -> ($via -> "invite_public"),
                good  -> ($via -> "invite_public", $at -> now, $unknown_extra -> "ignored-by-the-rebuild")
            )
        ).
        return transaction::success [ _return_data ($imported -> TRUE), _save_state NIL ].
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

    // Contact-naming regression plumbing: advertise core.connect on the receiver,
    // then let its already-bound CP relay a real signed peer AD + display label.
    trn qa_init_connect _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        hs is (str ->> (any -> transaction::action::type[])) = (,).
        hs a2a_capabilities::cap_connect -> fn (_: any) -> transaction::action::type[] { return []. }.
        a2a_capabilities::init (
            $describe -> fn (_: any) -> a2a_capabilities::app_manifest_t
            {
                caps is (str ->> a2a_capabilities::capability_t) = (,).
                caps a2a_capabilities::cap_connect -> (
                    $cap -> a2a_capabilities::cap_connect,
                    $version -> 1,
                    $params -> "",
                    $secrets -> (,)
                ).
                return ($version -> 1, $app_id -> "test.actor", $name -> "actor",
                        $description -> "", $monitoring_status -> "off", $capabilities -> caps).
            },
            $supported -> [a2a_capabilities::cap_connect],
            $handlers -> hs,
            $on_unknown -> fn (_: any) -> transaction::action::type[] { return []. },
            $authorizer -> NIL,
            $advertise -> []
        ).
        return transaction::success [ _return_data ($set -> TRUE) ].
    }

    trn qa_send_ingest_descriptor _:($target -> tgt: global_id, $peer_ad -> ad_blob: bin, $peer_name -> peer_name: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        ad = (_read_or_abort ad_blob) safe address_document_types::t_address_document.
        return encrypted_channel::execute_transaction tgt (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx tgt (
                    $name -> "::a2a_messaging::ingest_connect_descriptor",
                    $targ -> ($peer_ad -> ad, $peer_name -> peer_name, $pv -> a2a_versions::wire_version)
                ),
                _return_data ($sent -> TRUE)
            ].
        }).
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
