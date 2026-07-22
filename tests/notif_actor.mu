// Notifications test actor for the a2a_notifications N-series (tests/notif.mjs).
//
// SPLIT from test_actor.mu deliberately: the compiler bounds meta-stage
// type-level reduction PER COMPILED UNIT (adapt src/eval/meta_reduction_fuel.h,
// 1M steps — a consensus-deterministic compile-time DoS guard). test_actor loads
// BOTH heavy libraries a2a_messaging (139KB) AND a2a_notifications (57KB) and,
// after the 0.9.0 migration surface landed in a2a_messaging, tips OVER the
// per-unit ceiling. a2a_messaging has ZERO references to a2a_notifications (the
// dep is one-way: notifications -> messaging), so the fix is to move the
// notifications tests into THEIR OWN unit and drop a2a_notifications from
// test_actor. This unit loads BOTH libraries (a2a_notifications needs
// a2a_messaging's contact machinery) but exercises ONLY the N-series
// notification transactions, so it too fits under the per-unit budget.
//
// It carries the SHARED host wiring the notify flows need (a2a_messaging::init
// storage hooks for the invite/contact machinery the N-series set-up uses; a
// tiny inbox; the identity helpers) PLUS everything notification-specific: the
// a2a_notifications::init block, the notify hook logs, and the notify qa probes.
// The COMBINED core+notify export_state/import_state round-trip lives HERE (this
// is the only unit that loads both libraries) — see qa export_state/import_state.

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
    a2a_notifications,
    a2a_notification_integration,
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

        // Receipt consumer log (core 0.7.0) — unused by the N-series but the
        // a2a_messaging::init hook requires it.
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

        // Notification hook logs (the app owns notification storage; the core
        // calls the hooks). Plain observable lists the qa probes expose.
        notif_log is any[] = [].
        marks_log is any[] = [].
        unregs_log is any[] = [].
        regconfirm_log is any[] = [].

        // The integration supplies ordinary client defaults; this dual-role
        // test actor then overrides them with observable service/client hooks.
        a2a_notification_integration::init ($_read_or_abort -> _read_or_abort).
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

    // export/import wrappers: this UNIT loads BOTH libraries, so the COMBINED
    // core+notify round-trip lives here (test_actor keeps only the core half).
    // The "both halves coexist in one blob and both restore" coverage (N7/N16)
    // is asserted against these.
    trn readonly export_state _ {
        return (
            $core -> (a2a_messaging::export_core_state NIL),
            $notify -> (a2a_notifications::export_notify_state NIL),
            $notify_integration -> (a2a_notification_integration::export_state NIL)
        ).
    }
    trn import_state data: any
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        a2a_messaging::import_core_state (data $core).
        if (data $notify) != NIL { a2a_notifications::import_notify_state (data $notify). }
        if (data $notify_integration) != NIL { a2a_notification_integration::import_state (data $notify_integration). }
        return transaction::success [ _return_data ($imported -> TRUE), _save_state NIL ].
    }

    // Inject a learned capability set for a contact — drives the V5 CAP-1 gate
    // test (positive-evidence denial vs unknown/empty pass-through).
    trn qa_set_contact_caps _:($cid -> cid: global_id, $caps -> caps: str[])
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        a2a_messaging::contact_caps cid -> caps.
        return transaction::success [ _return_data ($set -> TRUE), _save_state NIL ].
    }

    // ================= NOTIFICATION TEST PROBES =================

    // Deployed-peer compatibility shim: old senders still address ::actor::*;
    // state and validation are owned by the integration library.
    trn receive_notify_address args: any { return a2a_notification_integration::handle_receive_notify_address args. }
    trn readonly qa_notify_addr_store _
    {
        return ($store -> a2a_notification_integration::received_notify_addresses).
    }
    // Send either the new library-routed handout or the deployed ::actor::*
    // shape. Nullable address deletes the receiver's stored handout.
    trn qa_send_notify_address _:($target -> tgt: global_id, $address -> blob: bin+, $legacy -> legacy: bool)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        return encrypted_channel::execute_transaction tgt (fn (_) -> transaction::results::type {
            tx_name is str = "::a2a_notification_integration::receive_notify_address".
            if legacy { tx_name -> "::actor::receive_notify_address". }
            return transaction::success [
                encrypted_channel::send_encrypted_tx tgt (
                    $name -> tx_name,
                    $targ -> ($address -> blob)
                ),
                _return_data ($sent_to -> tgt)
            ].
        }).
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
}
