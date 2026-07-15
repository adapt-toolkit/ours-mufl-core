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
        // Increment-B app-e2e delivery observability: the storage hooks RECORD the last delivered
        // message/file into these mutables so the driver can prove handle_receive_e2e_message
        // actually decrypted + delivered the plaintext to the app hook (not just decoded it). The
        // togglable qa_recv_abort makes the message hook ABORT — used to prove must-fix-C rollback
        // (the do_ic promotion + pins + flush roll back with the tx when delivery aborts).
        qa_recv_text is str = "".
        qa_recv_wire is str = "".
        qa_recv_file is str = "".
        qa_recv_flen is int = 0.
        qa_recv_count is int = 0.
        qa_recv_abort is bool = FALSE.
        // a2a_messaging needs its own _read_or_abort + storage hooks (the migration
        // handlers deserialize snapshots via it). The message/file hooks RECORD delivery.
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

    // Phase D §5.6 — the app-data route verdict for a cid (5-state).
    trn readonly qa_e2e_route _:($cid -> cid: global_id) { return ($route -> (a2a_messaging::e2e_route cid)). }

    // ── Increment-B app-e2e delivery observability. qa_recv_last surfaces the last plaintext the
    // on_message_received hook stored (proof handle_receive_e2e_message decrypted + delivered it);
    // qa_recv_reset clears it between assertions; qa_recv_set_abort toggles the must-fix-C rollback
    // probe (the app hook aborts → the do_ic promotion rolls back with the tx).
    trn readonly qa_recv_last _ { return ($text -> qa_recv_text, $wire -> qa_recv_wire, $count -> qa_recv_count, $filename -> qa_recv_file, $flen -> qa_recv_flen). }
    trn qa_recv_reset _ { qa_recv_text -> "".  qa_recv_wire -> "".  qa_recv_file -> "".  qa_recv_flen -> 0.  return transaction::success [ _return_data ($ok -> TRUE) ]. }
    trn qa_recv_set_abort _:($abort -> ab: bool) { qa_recv_abort -> ab.  return transaction::success [ _return_data ($abort -> qa_recv_abort) ]. }

    // Force a LEGACY plaintext box (receive_message_tx) to a contact, BYPASSING e2e_route — lets the
    // driver deliver a legacy inbound at a receiver regardless of the sender's route, to prove the
    // §5.7 receive-side downgrade gate: refused at an EPOCH-pinned receiver, delivered at a
    // seen-not-epoch one. Mirrors send_message's legacy box branch.
    trn qa_send_legacy _:($contact -> cref: str, $text -> text: str)
    {
        target_id = a2a_messaging::resolve_contact cref.
        wid = _str (_new_id "qa legacy").
        // Direct send_encrypted_tx (no execute_transaction wrapper — the migration commit/confirm
        // handlers relay this way too; the wrapper's generic would blow the unit's meta fuel).
        return transaction::success [
            encrypted_channel::send_encrypted_tx target_id (
                $name -> "::a2a_messaging::receive_message",
                $targ -> ($text -> text, $wire_id -> wid, $pv -> a2a_versions::wire_version) ),
            _return_data ($sent_to -> target_id, $wire_id -> wid) ].
    }

    // §5.4 trigger-GATE test helpers (criterion-1 boundary). ISOLATED: advertising cap_e2e_migrate
    // here does NOT touch the full suite's test_actor. qa_mig_should_trigger reads the PURE gate
    // (no send) so we exercise fail-closed WITHOUT needing a registered peer.
    trn qa_init_caps _:($advertise -> adv: str[])
    {
        a2a_capabilities::init (
            $describe -> fn (_: any) -> a2a_capabilities::app_manifest_t
            { return ($version -> 1, $app_id -> "mig.actor", $name -> "actor", $description -> "", $monitoring_status -> "off", $capabilities -> (,)). },
            $supported -> [], $handlers -> (,),
            $on_unknown -> fn (_: any) -> transaction::action::type[] { return []. },
            $authorizer -> NIL, $advertise -> adv ).
        return transaction::success [ _return_data ($set -> TRUE) ].
    }
    trn qa_learn_peer _:($cid -> cid: global_id, $pv -> pv: int, $caps -> caps: str[])
    {
        a2a_messaging::learn_contact_version cid pv caps.
        return transaction::success [ _return_data ($ok -> TRUE) ].
    }
    trn readonly qa_mig_should_trigger _:($cid -> cid: global_id) { return ($fire -> (a2a_messaging::mig_should_trigger cid)). }

    // §5.6 sweep test helpers. Force an `offered` FSM entry (real snapshot, via mig_offer_actions —
    // discard the send) so the sweep has something to re-drive; and set $attempts to exercise the cap.
    trn qa_mig_force_offered _:($cid -> cid: global_id)
    {
        sc a2a_messaging::mig_offer_actions cid -- ( -> a) { }   // side-effect: writes contact_migration=offered
        return transaction::success [ _return_data ($ok -> TRUE) ].
    }
    trn qa_mig_set_attempts _:($cid -> cid: global_id, $n -> n: int)
    {
        st = a2a_messaging::contact_migration cid.
        a2a_messaging::contact_migration cid -> ( $phase -> ((st?) $phase), $initiator -> ((st?) $initiator),
            $local_nonce -> ((st?) $local_nonce), $peer_nonce -> ((st?) $peer_nonce), $epoch -> ((st?) $epoch),
            $session_id -> ((st?) $session_id), $local_bundle -> ((st?) $local_bundle), $local_fp -> ((st?) $local_fp),
            $attempts -> n, $updated -> ((st?) $updated) ).
        return transaction::success [ _return_data ($ok -> TRUE) ].
    }
    // Simulate my published bundle rotating since the snapshot: corrupt $local_fp so it no longer
    // matches the live produce-fp (drives the sweep's §5.4-5 supersession path).
    trn qa_mig_corrupt_fp _:($cid -> cid: global_id)
    {
        st = a2a_messaging::contact_migration cid.
        bogus is bin = _hash_code_to_binary (_value_id ($x -> "bogus-rotated-fp")).
        a2a_messaging::contact_migration cid -> ( $phase -> ((st?) $phase), $initiator -> ((st?) $initiator),
            $local_nonce -> ((st?) $local_nonce), $peer_nonce -> ((st?) $peer_nonce), $epoch -> ((st?) $epoch),
            $session_id -> ((st?) $session_id), $local_bundle -> ((st?) $local_bundle), $local_fp -> bogus,
            $attempts -> ((st?) $attempts), $updated -> ((st?) $updated) ).
        return transaction::success [ _return_data ($ok -> TRUE) ].
    }

    // Phase D §5.6 flush test helpers. Inject a 3-message mig_deferred queue for `cid` (via the
    // import path — REPLACE-if-present, leaves the active pin untouched), read the queued wire_ids
    // in order, and invoke the real flush (drain FIFO + clear via a2a_messaging::flush_mig_deferred_actions).
    trn qa_mig_inject_deferred _:($cid -> cid: global_id)
    {
        now = (current_transaction_info::get_transaction_time())?.
        q is a2a_messaging::deferred_msg_t[] = [
            ($text -> "m0", $wire_id -> "w0", $reply_to -> NIL, $date -> now),
            ($text -> "m1", $wire_id -> "w1", $reply_to -> NIL, $date -> now),
            ($text -> "m2", $wire_id -> "w2", $reply_to -> NIL, $date -> now) ].
        a2a_messaging::mig_deferred cid -> q.
        return transaction::success [ _return_data ($injected -> 3) ].
    }
    trn readonly qa_mig_deferred_ids _:($cid -> cid: global_id)
    {
        ids is str[] = [].
        q = a2a_messaging::mig_deferred cid.
        if q != NIL { sc q? -- ( -> m) { ids (_count ids|) -> (m $wire_id). } }
        return ($ids -> ids, $count -> (_count ids|)).
    }
    trn qa_mig_flush _:($cid -> cid: global_id)
    {
        order is str = "".
        q = a2a_messaging::mig_deferred cid.
        if q != NIL { sc q? -- ( -> m) { order -> order + (m $wire_id) + ",". } }
        acts is transaction::action::type[] = a2a_messaging::flush_mig_deferred_actions cid.
        return transaction::success [ _return_data ($flushed -> (_count acts|), $order -> order) ].
    }

    // ---- decode_migration_envelope GUARD matrix (point-1 divergence + binding + forgery/replay) ----
    // This packet's OWN address document (e2e bundle + sign keys), so a receiver can authenticate a
    // migration envelope as coming from this cid (the sender AD decode_migration_envelope binds to).
    trn readonly qa_produce_ad _ { return ($ad -> (_write (address_document::produce_my_address_document()))). }
    // Encrypt on the STAGED session and return the FULL e2e envelope + emsig (blobs), so the driver
    // can feed them (and tampered variants) to qa_mig_decode.
    trn qa_mig_enc_full _:($cid -> cid: global_id, $pt -> pt: bin)
    {
        env = e2e::encrypt_staged cid pt.
        return transaction::success [ _return_data ($env -> (_write (env $e2e_envelope)), $emsig -> (_write (env $emsignature))) ].
    }
    // Drive e2e::decode_migration_envelope with driver-supplied (tamperable) from/to/AD/env/emsig.
    // Forgery — bad wire_pv (S2), tampered/foreign emsig or wrong $to (S1), AD.cid≠from_cid (binding)
    // — ABORTS the tx (§1.1); an Olm-level failure / replayed pre-key returns $ok=FALSE. Proves the
    // shared S1/S2 path is REAL (not a no-op → the recv_authenticated divergence guard) and that the
    // forgery-abort vs replay-reject split + decode_migration_envelope's own binding gates hold.
    // pv_override >= 0 rebuilds the envelope with that $pv (to exercise the S2 dialect check).
    trn qa_mig_decode _:($from -> from_cid: global_id, $to -> to_cid: global_id, $ad -> ad_blob: bin, $env -> env_blob: bin, $emsig -> emsig_blob: bin, $pv_override -> pvo: int)
    {
        ad = (_read_or_abort ad_blob) safe address_document_types::t_address_document.
        e0 = (_read_or_abort env_blob) safe e2e::t_e2e_envelope.
        emsig = (_read_or_abort emsig_blob) safe crypto_signature.
        env is e2e::t_e2e_envelope+ = e0.
        if pvo >= 0 { env -> ( $session_id -> ((e0?) $session_id), $olm_type -> ((e0?) $olm_type), $ciphertext -> ((e0?) $ciphertext), $pv -> pvo ) safe e2e::t_e2e_envelope. }
        r = e2e::decode_migration_envelope from_cid to_cid (ad?) (env?) (emsig?).
        pt is bin+ = NIL.  if r $ok { pt -> (r $plaintext) as bin. }
        return transaction::success [ _return_data ( $ok -> (r $ok), $plaintext -> pt, $code -> ((r $ok) ?? "" ; ((r $error)?) $code) ) ].
    }

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
    // Re-send the STORED offer byte-identically from the initiator's FSM snapshot
    // (simulates the sweep retransmit / a broker duplicate — same nonce, same bundle).
    trn qa_mig_resend_offer _:($peer -> peer: global_id)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        st = a2a_messaging::contact_migration peer.
        s = _read_or_abort (((st?) $local_bundle)?).
        return transaction::success [
            encrypted_channel::send_encrypted_tx peer (
                $name -> a2a_messaging::e2e_migrate_offer_tx,
                $targ -> ( $ad -> (s $ad), $cert -> (s $cert), $root_profile -> (s $root_profile),
                           $cp_binding -> (s $cp_binding), $nonce -> ((st?) $local_nonce), $peer_nonce -> NIL,
                           $pv -> a2a_versions::wire_version, $caps -> (a2a_capabilities::self_cap_ids NIL) ) ),
            (transaction::action::return_data ($kind -> $data, $payload -> ($resent -> TRUE))) ].
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
    // Read the committed-epoch pin (contact_e2e_epoch) + the advertisement pin (contact_e2e_seen).
    trn readonly qa_mig_pin _:($cid -> cid: global_id)
    {
        ep = a2a_messaging::contact_e2e_epoch cid.
        epb is bin+ = NIL.
        esid is bin+ = NIL.
        if ep != NIL { epb -> (ep?) $epoch.  esid -> (ep?) $session_id. }
        return (
            $pinned     -> (ep != NIL),
            $epoch      -> epb,
            $session_id -> esid,
            $seen       -> ((a2a_messaging::contact_e2e_seen cid) == TRUE)
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
