// App-e2e RECEIVE-path guard-matrix test actor (spec §5.5/§5.6/§4, increment C).
//
// SPLIT from mig_actor.mu for the SAME reason mig_actor split from test_actor: the
// compiler bounds meta-stage type-level reduction PER COMPILED UNIT (~1M steps), and
// mig_actor (which loads a2a_messaging + the full migration FSM surface) is already AT
// that ceiling — it cannot take the extra state-synthesis helper this matrix needs. This
// leaner unit loads a2a_messaging (NOT a2a_notifications) + only the qa surface the
// app-e2e guard matrix drives, reclaiming budget for qa_mig_set_committed.
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
        _read_or_abort = grab( _read_or_abort ).
        key_storage::init ($_read_or_abort -> _read_or_abort).
        encrypted_channel::init ($_read_or_abort -> _read_or_abort).
        // RECORDING storage hooks — surface the last delivered message/file so the driver can prove
        // handle_receive_e2e_message/_file decrypted + DELIVERED the plaintext to the app hook.
        // qa_recv_abort makes the message hook ABORT (must-fix-C rollback probe).
        qa_recv_text is str = "".
        qa_recv_wire is str = "".
        qa_recv_file is str = "".
        qa_recv_flen is int = 0.
        qa_recv_count is int = 0.
        qa_recv_abort is bool = FALSE.
        a2a_messaging::init (
            $_read_or_abort      -> _read_or_abort,
            $on_message_received -> fn (a: any) -> transaction::action::type[] {
                abort "qa_recv_abort: app hook rejected the message (must-fix-C rollback probe)" WHEN qa_recv_abort.
                qa_recv_text -> ((a $text) safe str).
                if (a $wire_id) != NIL { qa_recv_wire -> ((a $wire_id) safe str). }
                qa_recv_count -> (qa_recv_count + 1).
                return []. },
            $on_message_sent     -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_contact_removed  -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_file_received    -> fn (a: any) -> transaction::action::type[] {
                qa_recv_file -> ((a $filename) safe str).
                qa_recv_flen -> (_binlen ((a $data) safe bin)).
                qa_recv_count -> (qa_recv_count + 1).
                return []. },
            $on_file_sent        -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_receipt_received -> fn (_: any) -> transaction::action::type[] { return []. }
        ).
    }

    // ── e2e crypto-layer wrappers (shuttle opaque envelope fields + the peer ik between packets).
    trn readonly qa_e2e_bundle _ { return ($bundle -> (_write (e2e::my_public_bundle()))). }
    trn readonly qa_e2e_ik _ { return ($ik -> ((e2e::my_public_bundle()) $ik_curve)). }

    trn qa_e2e_first_send _:($cid -> cid: global_id, $pt -> pt: bin, $peer -> peer_blob: bin)
    {
        peer = (_read_or_abort peer_blob) safe address_document_types::t_e2e_bundle.
        env = e2e::encrypt_to cid pt peer.
        e = env $e2e_envelope.
        return transaction::success [ _return_data ($session_id -> (e $session_id), $olm_type -> (e $olm_type), $ciphertext -> (e $ciphertext)) ].
    }

    trn qa_e2e_recv _:($from -> from_cid: global_id, $ik -> ik: bin, $olm_type -> ot: int, $ciphertext -> ct: bin)
    {
        r = e2e::decrypt_and_commit from_cid ik ot ct.
        pt is bin+ = NIL.  if r $ok { pt -> (r $plaintext) as bin. }
        return transaction::success [ _return_data ( $ok -> (r $ok), $plaintext -> pt ) ].
    }

    trn qa_e2e_stage_out _:($cid -> cid: global_id, $peer -> peer_blob: bin)
    {
        peer = (_read_or_abort peer_blob) safe address_document_types::t_e2e_bundle.
        return transaction::success [ _return_data ($sid -> (e2e::stage_outbound_rotation cid peer)) ].
    }

    trn qa_e2e_enc_staged _:($cid -> cid: global_id, $pt -> pt: bin)
    {
        env = e2e::encrypt_staged cid pt.
        e = env $e2e_envelope.
        return transaction::success [ _return_data ($session_id -> (e $session_id), $olm_type -> (e $olm_type), $ciphertext -> (e $ciphertext)) ].
    }

    trn qa_e2e_stage_in _:($from -> from_cid: global_id, $ik -> ik: bin, $ciphertext -> ct: bin)
    {
        r = e2e::stage_inbound_rotation from_cid ik ct.
        pt is bin+ = NIL.  if r $ok { pt -> (r $plaintext) as bin. }
        return transaction::success [ _return_data ( $ok -> (r $ok), $plaintext -> pt ) ].
    }

    trn qa_e2e_commit _:($cid -> cid: global_id)
    {
        sid = e2e::commit_rotation cid.
        return transaction::success [ _return_data ($sid -> sid, $committed -> (sid != NIL)) ].
    }

    trn readonly qa_e2e_active _:($cid -> cid: global_id) { return ($sid -> (e2e::active_session_id cid)). }
    trn readonly qa_e2e_staged _:($cid -> cid: global_id) { return ($sid -> (e2e::staged_session_id cid)). }

    // ── delivery observability + the must-fix-C rollback probe.
    trn readonly qa_recv_last _ { return ($text -> qa_recv_text, $wire -> qa_recv_wire, $count -> qa_recv_count, $filename -> qa_recv_file, $flen -> qa_recv_flen). }
    trn qa_recv_reset _ { qa_recv_text -> "".  qa_recv_wire -> "".  qa_recv_file -> "".  qa_recv_flen -> 0.  return transaction::success [ _return_data ($ok -> TRUE) ]. }
    trn qa_recv_set_abort _:($abort -> ab: bool) { qa_recv_abort -> ab.  return transaction::success [ _return_data ($abort -> qa_recv_abort) ]. }

    // Learn a peer's version/caps (caps incl. "core.e2e" → note_e2e_seen sets contact_e2e_seen).
    trn qa_learn_peer _:($cid -> cid: global_id, $pv -> pv: int, $caps -> caps: str[])
    {
        a2a_messaging::learn_contact_version cid pv caps.
        return transaction::success [ _return_data ($ok -> TRUE) ].
    }

    // Synthesize a box-only COMMITTED-INITIATOR FSM entry over an already-staged rotation (the
    // implicit-confirm setup — no live broker handshake). $session_id must equal the staged slot's
    // id so committed_match holds. $seen=TRUE makes it PRODUCTION-LIKE (a real migrating pair
    // advertises cap_e2e ⇒ contact_e2e_seen set by `committed`) — the exact state where do_ic must
    // STILL fire (MigrationReview #3). Fresh-budget unit ⇒ the inline mig_state_t literal fits.
    trn qa_mig_set_committed _:($cid -> cid: global_id, $session_id -> sid: bin, $seen -> seen: bool)
    {
        now = (current_transaction_info::get_transaction_time())?.
        a2a_messaging::contact_migration cid -> ( $phase -> "committed", $initiator -> TRUE,
            $local_nonce -> sid, $peer_nonce -> sid, $epoch -> sid, $session_id -> sid,
            $local_bundle -> sid, $local_fp -> sid, $attempts -> 0, $updated -> now ).
        if seen { a2a_messaging::contact_e2e_seen cid -> TRUE. }
        return transaction::success [ _return_data ($ok -> TRUE) ].
    }

    trn readonly qa_e2e_route _:($cid -> cid: global_id) { return ($route -> (a2a_messaging::e2e_route cid)). }

    // Synthesize an epoch PIN for a cid (imported-migration state). With NO peer bundle in peer_ads,
    // e2e_route returns "downgrade_refused" (§5.6: pinned but no v2 bundle → fail closed).
    trn qa_set_epoch_pin _:($cid -> cid: global_id, $session_id -> sid: bin)
    {
        a2a_messaging::contact_e2e_epoch cid -> ( $epoch -> sid, $session_id -> sid ).
        a2a_messaging::contact_e2e_seen cid -> TRUE.
        return transaction::success [ _return_data ($ok -> TRUE) ].
    }

    // Send a REAL explicit migration CONFIRM (responder → initiator) — encrypt the confirm body on
    // my active (rotation) session and box it as e2e_migrate_confirm, exactly as handle_e2e_migrate_
    // commit does. Lets the interleave test drive {confirm-then-app} / {app-then-confirm} and assert
    // exactly ONE promotion. $epoch must equal the initiator's committed epoch.
    trn qa_send_confirm _:($contact -> cref: str, $peer -> peer_blob: bin, $epoch -> ep: bin)
    {
        target_id = a2a_messaging::resolve_contact cref.
        peer = (_read_or_abort peer_blob) safe address_document_types::t_e2e_bundle.
        confirm_body = _write ( $name -> "::a2a_messaging::e2e_migrate_confirm", $targ -> ( $epoch -> ep, $pv -> a2a_versions::wire_version ) ).
        cenv = e2e::encrypt_to target_id confirm_body peer.
        return transaction::success [
            encrypted_channel::send_encrypted_tx target_id (
                $name -> "::a2a_messaging::e2e_migrate_confirm",
                $targ -> ( $e2e_envelope -> (cenv $e2e_envelope), $emsignature -> (cenv $emsignature) ) ),
            _return_data ($sent_to -> target_id) ].
    }

    trn readonly qa_mig_state _:($cid -> cid: global_id)
    {
        st = a2a_messaging::contact_migration cid.
        return (
            $present   -> (st != NIL),
            $phase     -> ((st == NIL ?? "" ; ((st?) $phase))),
            $initiator -> ((st == NIL ?? FALSE ; ((st?) $initiator)))
        ).
    }
    trn readonly qa_mig_pin _:($cid -> cid: global_id)
    {
        ep = a2a_messaging::contact_e2e_epoch cid.
        esid is bin+ = NIL.
        if ep != NIL { esid -> (ep?) $session_id. }
        return (
            $pinned     -> (ep != NIL),
            $session_id -> esid,
            $seen       -> ((a2a_messaging::contact_e2e_seen cid) == TRUE)
        ).
    }
}
