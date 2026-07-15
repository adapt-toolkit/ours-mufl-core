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
}
