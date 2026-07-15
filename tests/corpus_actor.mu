// Corpus actor for the golden-wire registry gate (tests/corpus.mjs).
//
// SPLIT from test_actor.mu deliberately: the compiler bounds meta-stage
// type-level reduction PER COMPILED UNIT (adapt src/eval/meta_reduction_fuel.h,
// 1M steps — a consensus-deterministic compile-time DoS guard). AD-v2 embeds
// t_e2e_bundle inside t_container_identity, which deepens every type reduction
// that touches t_address_document; test_actor plus the corpus fixtures no
// longer fits a single unit's budget (and Phase-A adds mgb/mgc fixtures here).
// Two units = two budgets; the corpus unit stays small and cheap by loading
// only what try_narrow_* dispatch needs (no a2a_messaging/a2a_protocol).
application actor loads libraries
    address_document,
    address_document_types,
    key_utils,
    key_storage,
    a2a_versions,
    current_transaction_info,
    protocol_container,
    version
    uses transactions
{
    hidden
    {
        fn _return_data (payload: any) = (transaction::action::return_data ($kind -> $data, $payload -> payload)).
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
        // Upcast once: AD-v2 embeds t_e2e_bundle, making the full t_address_document
        // type deep enough that ~40 fixture record literals carrying it exhaust the
        // compiler's meta-stage type-reduction budget. Fixtures only ever feed
        // try_narrow_* as `any`; binding my_ad as any keeps every literal's type flat.
        my_ad = (address_document::get_my_address_document()) as any.
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

        // registry "e2e" — e2e_signed_message VARIANT ($e2e_envelope -> t_e2e_envelope,
        // $emsignature): single version, LOAD-BEARING (sir-style payload cast). The $pv
        // discriminator rides inside $e2e_envelope. Cases mirror sir's abort-free (M1) matrix.
        ct = _hex_string_to_binary "00112233445566778899aabbccddeeff".
        sid = _new_id "qa e2e session".
        sig = key_storage::default_sign (_value_id sid).
        e_pre = ($e2e_envelope -> ($session_id -> sid, $olm_type -> 0, $ciphertext -> ct, $pv -> 8), $emsignature -> sig).  // PRE_KEY
        e_nrm = ($e2e_envelope -> ($session_id -> sid, $olm_type -> 1, $ciphertext -> ct, $pv -> 8), $emsignature -> sig).  // normal ratchet
        e_old = ($e2e_envelope -> ($session_id -> sid, $olm_type -> 1, $ciphertext -> ct, $pv -> 1), $emsignature -> sig).  // inner $pv below floor
        e_bad = ($nope -> 1).                                                                                              // no $e2e_envelope marker
        e_nos = ($e2e_envelope -> ($session_id -> sid, $olm_type -> 0, $ciphertext -> ct, $pv -> 8)).                      // missing $emsignature
        // M1 wrong-domain: present-but-mistyped NON-nullable inner fields -> shape error, never a cast abort.
        e_wsid = ($e2e_envelope -> ($session_id -> 42,  $olm_type -> 1, $ciphertext -> ct, $pv -> 8), $emsignature -> sig).  // $session_id int
        e_wot  = ($e2e_envelope -> ($session_id -> sid, $olm_type -> "one", $ciphertext -> ct, $pv -> 8), $emsignature -> sig). // $olm_type str
        e_wct  = ($e2e_envelope -> ($session_id -> sid, $olm_type -> 1, $ciphertext -> "notbin", $pv -> 8), $emsignature -> sig). // $ciphertext str
        // Mistyped inner $pv (str): every e2e sender stamps an int $pv, so a present-non-int is
        // malformed -> shape_error (error-as-data, abort-free), NOT tolerated as unstamped.
        e_wpv  = ($e2e_envelope -> ($session_id -> sid, $olm_type -> 0, $ciphertext -> ct, $pv -> "eight"), $emsignature -> sig).
        // Unstamped inner (no $pv): the tolerated absent-discriminator path -> defaults to v8, ok.
        e_uns  = ($e2e_envelope -> ($session_id -> sid, $olm_type -> 0, $ciphertext -> ct), $emsignature -> sig).
        // Future dialect (inner $pv=99): single registered version -> narrows as v1 (class-A forward compat).
        e_fut  = ($e2e_envelope -> ($session_id -> sid, $olm_type -> 1, $ciphertext -> ct, $pv -> 99), $emsignature -> sig).

        ep = a2a_versions::try_narrow_e2e (e_pre as any).
        en = a2a_versions::try_narrow_e2e (e_nrm as any).
        eo = a2a_versions::try_narrow_e2e (e_old as any).
        eb = a2a_versions::try_narrow_e2e (e_bad as any).
        ens = a2a_versions::try_narrow_e2e (e_nos as any).
        ews = a2a_versions::try_narrow_e2e (e_wsid as any).
        ewo = a2a_versions::try_narrow_e2e (e_wot as any).
        ewc = a2a_versions::try_narrow_e2e (e_wct as any).
        ewp = a2a_versions::try_narrow_e2e (e_wpv as any).
        eu = a2a_versions::try_narrow_e2e (e_uns as any).
        ef = a2a_versions::try_narrow_e2e (e_fut as any).

        // registry "mgb" — e2e-migration offer/ack bundle (wire 9, single version).
        // sir-shape identity bundle ($ad any) + agreement fields: the offer omits
        // $peer_nonce, the ack echoes the offer nonce. Introduction dialect 9, so
        // an unstamped body (no $pv) is malformed on this surface -> shape error.
        mna = _hex_string_to_binary "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf".   // offer nonce (bin)
        mnb = _hex_string_to_binary "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf".   // ack nonce (bin)
        mgb_off = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $nonce -> mna, $peer_nonce -> NIL, $pv -> 9, $caps -> ["core.e2e.migrate"]).  // offer form
        mgb_ack = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $nonce -> mnb, $peer_nonce -> mna, $pv -> 9, $caps -> ["core.e2e.migrate"]).  // ack form (echoes offer nonce)
        mgb_old = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $nonce -> mna, $peer_nonce -> NIL, $pv -> 1, $caps -> []).       // below floor
        mgb_wn  = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $nonce -> "notbin", $peer_nonce -> NIL, $pv -> 9, $caps -> []).  // mistyped $nonce (str)
        mgb_uns = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $nonce -> mna, $peer_nonce -> NIL, $caps -> []).                 // unstamped (no $pv)
        mgb_fut = ($ad -> my_ad, $cert -> NIL, $root_profile -> NIL, $cp_binding -> NIL, $nonce -> mna, $peer_nonce -> NIL, $pv -> 10, $caps -> []).      // future dialect

        gmo   = a2a_versions::try_narrow_mgb (mgb_off as any).
        gma   = a2a_versions::try_narrow_mgb (mgb_ack as any).
        gmold = a2a_versions::try_narrow_mgb (mgb_old as any).
        gmwn  = a2a_versions::try_narrow_mgb (mgb_wn as any).
        gmuns = a2a_versions::try_narrow_mgb (mgb_uns as any).
        gmfut = a2a_versions::try_narrow_mgb (mgb_fut as any).

        // registry "mgc" — e2e-migration commit/confirm inner $targ (wire 9). The
        // commit carries $session_id; the confirm omits it. $epoch is the required
        // domain-checked field; $pv is nullable (the E2E session authenticates).
        mep = _hex_string_to_binary "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf".   // epoch (bin)
        msd = _hex_string_to_binary "d0d1d2d3d4d5d6d7d8d9dadbdcdddedf".   // session_id (bin)
        mgc_com = ($epoch -> mep, $session_id -> msd, $pv -> 9).          // COMMIT form
        mgc_con = ($epoch -> mep, $pv -> 9).                             // CONFIRM form (no $session_id)
        mgc_old = ($epoch -> mep, $session_id -> msd, $pv -> 1).          // below floor
        mgc_ne  = ($session_id -> msd, $pv -> 9).                        // no $epoch -> shape err (epoch-domain)
        mgc_we  = ($epoch -> "notbin", $session_id -> msd, $pv -> 9).     // mistyped $epoch (str) -> shape err
        mgc_ws  = ($epoch -> mep, $session_id -> 42, $pv -> 9).           // mistyped $session_id (int) -> shape err (M1)
        mgc_uns = ($epoch -> mep, $session_id -> msd).                   // unstamped (no $pv) -> tolerated, ok

        cco   = a2a_versions::try_narrow_mgc (mgc_com as any).
        ccn   = a2a_versions::try_narrow_mgc (mgc_con as any).
        ccold = a2a_versions::try_narrow_mgc (mgc_old as any).
        ccne  = a2a_versions::try_narrow_mgc (mgc_ne as any).
        ccwe  = a2a_versions::try_narrow_mgc (mgc_we as any).
        ccws  = a2a_versions::try_narrow_mgc (mgc_ws as any).
        ccuns = a2a_versions::try_narrow_mgc (mgc_uns as any).

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
            ),
            $e2e -> (
                $pre -> ($ok -> (ep $ok), $v -> (a2a_versions::e2e_version_of (e_pre as any)), $ot -> (((ep $payload)?) $e2e_envelope $olm_type)),
                $nrm -> ($ok -> (en $ok), $ot -> (((en $payload)?) $e2e_envelope $olm_type)),
                $old -> ($ok -> (eo $ok), $code -> (((eo $err)?) $code), $peer_v -> (((eo $err)?) $peer_version), $min -> (((eo $err)?) $min_supported), $msg -> (((eo $err)?) $message)),
                $bad -> ($ok -> (eb $ok), $code -> (((eb $err)?) $code), $msg -> (((eb $err)?) $message)),
                $nos -> ($ok -> (ens $ok), $code -> (((ens $err)?) $code)),
                $wsid -> ($ok -> (ews $ok), $code -> (((ews $err)?) $code)),
                $wot -> ($ok -> (ewo $ok), $code -> (((ewo $err)?) $code)),
                $wct -> ($ok -> (ewc $ok), $code -> (((ewc $err)?) $code)),
                $wpv -> ($ok -> (ewp $ok), $code -> (((ewp $err)?) $code)),
                $uns -> ($ok -> (eu $ok), $v -> (a2a_versions::e2e_version_of (e_uns as any)), $ot -> (((eu $payload)?) $e2e_envelope $olm_type)),
                $fut -> ($ok -> (ef $ok), $ot -> (((ef $payload)?) $e2e_envelope $olm_type))
            ),
            $mgb -> (
                $off -> ($ok -> (gmo $ok), $v -> (a2a_versions::mgb_version_of (mgb_off as any)), $pn_absent -> ((((gmo $payload)?) as any) $peer_nonce == NIL)),
                $ack -> ($ok -> (gma $ok), $pn_present -> ((((gma $payload)?) as any) $peer_nonce != NIL)),
                $old -> ($ok -> (gmold $ok), $code -> (((gmold $err)?) $code), $peer_v -> (((gmold $err)?) $peer_version), $min -> (((gmold $err)?) $min_supported)),
                $wn  -> ($ok -> (gmwn $ok), $code -> (((gmwn $err)?) $code)),
                $uns -> ($ok -> (gmuns $ok), $code -> (((gmuns $err)?) $code)),
                $fut -> ($ok -> (gmfut $ok), $v -> (a2a_versions::mgb_version_of (mgb_fut as any)))
            ),
            $mgc -> (
                $com -> ($ok -> (cco $ok), $has_sid -> ((((cco $payload)?) as any) $session_id != NIL)),
                $con -> ($ok -> (ccn $ok), $no_sid -> ((((ccn $payload)?) as any) $session_id == NIL)),
                $old -> ($ok -> (ccold $ok), $code -> (((ccold $err)?) $code)),
                $ne  -> ($ok -> (ccne $ok), $code -> (((ccne $err)?) $code)),
                $we  -> ($ok -> (ccwe $ok), $code -> (((ccwe $err)?) $code)),
                $ws  -> ($ok -> (ccws $ok), $code -> (((ccws $err)?) $code)),
                $uns -> ($ok -> (ccuns $ok))
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
}
