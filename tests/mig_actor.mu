// Migration test actor — the E2E per-connection migration FSM scenarios (spec §5).
//
// SPLIT from test_actor.mu deliberately (same reason as corpus_actor.mu): the
// compiler bounds meta-stage type-level reduction PER COMPILED UNIT (1M steps).
// test_actor loads BOTH heavy libraries a2a_messaging (139KB) AND a2a_notifications
// (57KB) and already sits at the fuel ceiling. a2a_messaging has ZERO references to
// a2a_notifications (the dep is one-way: notifications -> messaging), so a
// migration/messaging-focused unit can drop a2a_notifications entirely and reclaim
// its whole reduction budget — leaving ample room for the 0.9.0 migration surface
// (mig_state_t/e2e_epoch_t stores, the FSM handlers in phase C, the §5.8 matrix).
application actor loads libraries
    identity_proof_document,
    attestation_document,
    native_attestation_document,
    transaction_message_decoder,
    address_document,
    address_document_types,
    key_utils,
    key_storage,
    e2e,
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
        fn _return_data (payload: any) = (transaction::action::return_data ($kind -> $data, $payload -> payload)).
        // Host wiring the crypto facade needs at runtime (Phase-B e2e qa trns):
        // _read_or_abort deserializes blobs; key_storage derives the e2e pickle key
        // from the identity signing secret; encrypted_channel is a2a_messaging's dep.
        _read_or_abort = grab( _read_or_abort ).
        key_storage::init ($_read_or_abort -> _read_or_abort).
        encrypted_channel::init ($_read_or_abort -> _read_or_abort).
        // a2a_messaging needs its own _read_or_abort + storage hooks (the migration
        // handlers deserialize snapshots via it). Minimal no-op hooks — mig_actor
        // exercises the FSM, not message delivery.
        a2a_messaging::init (
            $_read_or_abort      -> _read_or_abort,
            $on_message_received -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_message_sent     -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_contact_removed  -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_file_received    -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_file_sent        -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_receipt_received -> fn (_: any) -> transaction::action::type[] { return []. }
        ).
        // Phase-B decode-seam test hook: a togglable "migration pending" flag the installed
        // e2e hook reads, so the driver can exercise decrypt_and_commit's stage-vs-replace
        // decision (in the real inbound path) without wiring the full core FSM.
        qa_mig_pending is bool = FALSE.
    }

    // Phase-A compile/headroom probe + export/import round-trip for the three new
    // migration stores (contact_migration / contact_e2e_epoch / mig_deferred).
    // Seeds a synthetic FSM entry + epoch pin + deferred queue for a cid, exports,
    // and reports what the blob carries; a companion trn re-imports a pre-0.9 blob
    // (the fields absent) and reports the stores stay empty (= legacy, spec §5.1).
    trn qa_mig_export_roundtrip _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        cid = _new_id "qa mig peer".
        nonce = _hex_string_to_binary "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf".
        ep    = _hex_string_to_binary "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf".
        sid   = _hex_string_to_binary "d0d1d2d3d4d5d6d7d8d9dadbdcdddedf".
        now   = (current_transaction_info::get_transaction_time())?.
        // Seed all three stores directly (cross-library store write, as the qa
        // setters in test_actor do for contact_pv/contact_caps).
        a2a_messaging::contact_migration cid -> (
            $phase -> "active", $initiator -> TRUE, $local_nonce -> nonce,
            $peer_nonce -> nonce, $epoch -> ep, $session_id -> sid,
            $local_bundle -> NIL, $local_fp -> NIL, $attempts -> 1, $updated -> now ).
        a2a_messaging::contact_e2e_epoch cid -> ($epoch -> ep, $session_id -> sid).
        a2a_messaging::mig_deferred cid -> [ ($text -> "queued", $wire_id -> "w1", $reply_to -> NIL, $date -> now) ].

        blob = a2a_messaging::export_core_state NIL.
        return transaction::success [ _return_data (
            $has_migration -> ((blob $contact_migration) != NIL),
            $has_epoch     -> ((blob $contact_e2e_epoch) != NIL),
            $has_deferred  -> ((blob $mig_deferred) != NIL),
            $phase         -> (((blob $contact_migration) as any) cid $phase),
            $epoch_sid_present -> (((((blob $contact_e2e_epoch) as any) cid) $session_id) != NIL),
            $deferred_len  -> (_count (((blob $mig_deferred) as any) cid|))
        ) ].
    }

    // Pre-0.9 import: a blob WITHOUT the three fields must leave the stores empty
    // (absence = legacy). We hand import_core_state a minimal blob and confirm.
    trn qa_mig_import_legacy _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        // A faithful pre-0.9 blob: the original-schema required fields (my_name,
        // contacts, peer_ads) present, the three 0.9.0 migration fields ABSENT —
        // exactly what a 0.8-era export looks like. Import must leave the migration
        // stores empty (guarded reads skip absent fields; absence = legacy, §5.1).
        a2a_messaging::import_core_state ( $format_version -> 1, $my_name -> "", $contacts -> (,), $peer_ads -> (,) ).
        exp = a2a_messaging::export_core_state NIL.
        probe = _new_id "qa legacy probe".
        return transaction::success [ _return_data (
            $migration_absent -> (((exp $contact_migration) as any) probe == NIL),
            $epoch_absent     -> (((exp $contact_e2e_epoch) as any) probe == NIL),
            $deferred_absent  -> (((exp $mig_deferred) as any) probe == NIL)
        ) ].
    }

    // ---- Phase-B staged-rotation exercise (adapt e2e §5.5) ----------------
    // Thin qa wrappers over the adapt e2e facade so a two-node driver can drive
    // establish -> stage -> commit and assert the rotate-once property. The driver
    // shuttles the opaque envelope fields + the sender's e2e identity key between
    // two packets (there is no core FSM here — this is the crypto-layer property).
    trn readonly qa_e2e_bundle _ { return ($bundle -> (_write (e2e::my_public_bundle()))). }
    trn readonly qa_e2e_ik _ { return ($ik -> ((e2e::my_public_bundle()) $ik_curve)). }

    // Establish the LIVE session (encrypt_to lazily creates it) and emit the pre-key envelope.
    trn qa_e2e_first_send _:($cid -> cid: global_id, $pt -> pt: bin, $peer -> peer_blob: bin)
    {
        peer = (_read_or_abort peer_blob) safe address_document_types::t_e2e_bundle.
        env = e2e::encrypt_to cid pt peer.
        e = env $e2e_envelope.
        return transaction::success [ _return_data ($session_id -> (e $session_id), $olm_type -> (e $olm_type), $ciphertext -> (e $ciphertext)) ].
    }

    // Receive on the LIVE session (decode-seam: establishes/decrypts + commits m_sessions).
    trn qa_e2e_recv _:($from -> from_cid: global_id, $ik -> ik: bin, $olm_type -> ot: int, $ciphertext -> ct: bin)
    {
        r = e2e::decrypt_and_commit from_cid ik ot ct.
        pt is bin+ = NIL.  if r $ok { pt -> (r $plaintext) as bin. }
        return transaction::success [ _return_data ( $ok -> (r $ok), $plaintext -> pt,
            $code -> ((r $ok) ?? "" ; ((r $error)?) $code) ) ].
    }

    // Stage a FRESH outbound rotation (live session untouched); returns the staged session id.
    trn qa_e2e_stage_out _:($cid -> cid: global_id, $peer -> peer_blob: bin)
    {
        peer = (_read_or_abort peer_blob) safe address_document_types::t_e2e_bundle.
        return transaction::success [ _return_data ($sid -> (e2e::stage_outbound_rotation cid peer)) ].
    }

    // Encrypt on the STAGED session (pre-key on the fresh session).
    trn qa_e2e_enc_staged _:($cid -> cid: global_id, $pt -> pt: bin)
    {
        env = e2e::encrypt_staged cid pt.
        e = env $e2e_envelope.
        return transaction::success [ _return_data ($session_id -> (e $session_id), $olm_type -> (e $olm_type), $ciphertext -> (e $ciphertext)) ].
    }

    // Stage an INBOUND rotation from the peer's pre-key (m_sessions untouched).
    trn qa_e2e_stage_in _:($from -> from_cid: global_id, $ik -> ik: bin, $ciphertext -> ct: bin)
    {
        r = e2e::stage_inbound_rotation from_cid ik ct.
        pt is bin+ = NIL.  if r $ok { pt -> (r $plaintext) as bin. }
        return transaction::success [ _return_data ( $ok -> (r $ok), $plaintext -> pt,
            $code -> ((r $ok) ?? "" ; ((r $error)?) $code) ) ].
    }

    // Promote staged -> active (idempotent; NIL if nothing staged).
    trn qa_e2e_commit _:($cid -> cid: global_id)
    {
        sid = e2e::commit_rotation cid.
        return transaction::success [ _return_data ($sid -> sid, $committed -> (sid != NIL)) ].
    }

    trn readonly qa_e2e_active _:($cid -> cid: global_id) { return ($sid -> (e2e::active_session_id cid)). }
    trn readonly qa_e2e_staged _:($cid -> cid: global_id) { return ($sid -> (e2e::staged_session_id cid)). }

    // Decode-seam test controls: install a mig-pending hook that reads the togglable flag,
    // then flip the flag to steer decrypt_and_commit's stage-vs-replace decision.
    trn qa_e2e_install_mig_hook _
    {
        e2e::set_mig_pending_hook (fn (_: global_id) -> bool { return qa_mig_pending. }).
        return transaction::success [ _return_data ($ok -> TRUE) ].
    }
    trn qa_e2e_set_mig_pending _:($pending -> p: bool)
    {
        qa_mig_pending -> p.
        return transaction::success [ _return_data ($pending -> qa_mig_pending) ].
    }

    // ---- Cross-library atomicity gate (spec §5.5 / plan B gate 5, blocks C/D) ----
    // Within ONE transaction: write ADAPT-library state (e2e m_staged via
    // stage_outbound_rotation), write CORE-library state (a2a_messaging
    // contact_migration), queue an ACTION (a send), then ABORT. If the toolchain
    // gives cross-library atomic rollback, a subsequent read sees NEITHER write
    // (and the action never fired). If it does NOT, §5.5 handlers must switch to
    // explicit prepare/commit records — so this gate's result decides phase C's shape.
    trn qa_atomicity_abort _:($cid -> cid: global_id, $peer -> peer_blob: bin)
    {
        peer = (_read_or_abort peer_blob) safe address_document_types::t_e2e_bundle.
        now = (current_transaction_info::get_transaction_time())?.
        // 1) ADAPT-library state write (e2e packet state):
        sid = e2e::stage_outbound_rotation cid peer.
        // 2) CORE-library state write (a2a_messaging packet state):
        a2a_messaging::contact_migration cid -> (
            $phase -> "offered", $initiator -> TRUE, $local_nonce -> sid,
            $peer_nonce -> NIL, $epoch -> NIL, $session_id -> NIL,
            $local_bundle -> NIL, $local_fp -> NIL, $attempts -> 1, $updated -> now ).
        // 3) ABORT the whole tx AFTER both cross-library writes. Any transaction::action
        //    (send / _save_state) would ride the success return, which is never reached — so
        //    a queued action is inherently discarded on abort (MUFL actions fire ONLY on
        //    success). The load-bearing question is whether the two cross-LIBRARY STATE writes
        //    above roll back together; qa_atomicity_check reads them after.
        abort ("atomicity probe: forced rollback after adapt-write + core-write (staged " + (_str (_value_id sid)) + ")") when TRUE.
        return transaction::success [ _return_data ($unreachable -> TRUE) ].
    }
    // Fault injection (MigrationReview): a self-heal REPLACE on a live session whose inner
    // dispatch then ABORTS. decrypt_and_commit replaces m_sessions[from_cid] (0.8.0 self-heal),
    // then we abort — modelling the inner tx failing. If the decode tx is atomic, the replace
    // rolls back and the live session is UNCHANGED (the immediate-replace design is only safe
    // BECAUSE of this; without it, an aborted dispatch would clobber the live session — the very
    // unilateral-reset the seam closes).
    trn qa_e2e_recv_abort _:($from -> from_cid: global_id, $ik -> ik: bin, $olm_type -> ot: int, $ciphertext -> ct: bin)
    {
        r = e2e::decrypt_and_commit from_cid ik ot ct.
        abort ("fault-injection: inner dispatch aborts after self-heal replace (ok=" + (_str (r $ok)) + ")") when TRUE.
        return transaction::success [ _return_data ($ok -> (r $ok)) ].
    }
    // ---- Phase-C §5.2 helpers (election + epoch determinism) ----
    trn readonly qa_mig_initiator _:($peer -> peer: global_id)
    { return ($initiator -> (a2a_messaging::mig_initiator peer), $mycid -> (_get_container_id())). }
    trn readonly qa_mig_epoch _:($lo -> lo: global_id, $hi -> hi: global_id, $nlo -> nlo: bin, $nhi -> nhi: bin, $flo -> flo: bin, $fhi -> fhi: bin)
    { return ($epoch -> (a2a_messaging::mig_epoch lo hi nlo nhi flo fhi)). }
    trn readonly qa_mig_bundle_fp _
    { return ($fp -> (a2a_messaging::e2e_bundle_fp (address_document::produce_my_address_document()))). }

    // Trigger an OFFER to a contact (invokes mig_offer_actions: persists offered + sends).
    trn qa_mig_trigger_offer _:($peer -> peer: global_id)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        actions is transaction::action::type[] = a2a_messaging::mig_offer_actions peer.
        actions (_count actions|) -> (transaction::action::return_data ($kind -> $data, $payload -> ($triggered -> TRUE))).
        actions (_count actions|) -> (transaction::action::return_data ($kind -> $save_state)).
        return transaction::success actions.
    }
    // Read the FSM entry for a contact (phase / epoch / initiator).
    trn readonly qa_mig_state _:($cid -> cid: global_id)
    {
        st = a2a_messaging::contact_migration cid.
        return (
            $present   -> (st != NIL),
            $phase     -> ((st == NIL ?? "" ; ((st?) $phase))),
            $epoch     -> ((st == NIL ?? NIL ; ((st?) $epoch))),
            $initiator -> ((st == NIL ?? FALSE ; ((st?) $initiator)))
        ).
    }

    // Read both libraries' state for `cid` AFTER the aborted tx: both must be absent.
    trn readonly qa_atomicity_check _:($cid -> cid: global_id)
    {
        return (
            $core_present  -> ((a2a_messaging::contact_migration cid) != NIL),
            $adapt_present -> ((e2e::staged_session_id cid) != NIL)
        ).
    }
}
