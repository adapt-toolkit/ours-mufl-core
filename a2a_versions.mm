// Shared ours versioned-type-registry library (core 0.5.0).
//
// THE backward-compatibility mechanism (SPEC v2 §1, COMPATIBILITY.md): for every
// wire input surface whose shape ever changed, this library declares — in one
// place, in MUFL types — one metadef PER SHIPPED WIRE VERSION of its payload,
// the accepted UNION (the handler's visible contract), the ordered version
// vector, the DISCRIMINATOR (the $pv wire-version tag, with a per-registry
// shape-inference rule for pre-$pv peers), and the dispatch fns:
//
//   try_narrow_<r> (raw) — dispatch on the discriminator, exact-cast to the
//       matched version's type; a below-floor or unrecognized payload returns
//       an ERROR VALUE AS DATA (version_error_t), never an abort. Handlers on
//       async inbound surfaces use THIS and surface the error to the local
//       client via _notify_agent — the "old peers never crash" invariant plus
//       the owner's "too-old versions return error-as-data" rule (Addition A).
//   narrow_<r> (raw) — the strict form: same dispatch, aborts with the error
//       message on failure. For corpus tests and callers where abort is right.
//
// Rules (REG-1…6, COMPATIBILITY.md): shipped v*_t metadefs are FROZEN — a wire
// shape change registers a NEW versioned type beside them and adds one branch;
// dispatch reads the discriminator off the RAW value and exact-casts (never
// cast-to-union as the selector — disjunction casts pick alternatives in
// canonical order and strip, see tests/mufl_semantics); a $pv NEWER than the
// newest registered version narrows as the newest (class-A changes are
// additive by taxonomy, extra fields strip safely); $pv is peer-asserted
// metadata — it gates parsing branches and diagnostics, NEVER authz.
//
// Self-contained: no library deps (base types only), loadable from anywhere.
library a2a_versions
{
    // ---- this build's wire dialect id -------------------------------------
    // Stamped as $pv on every 0.5.0+ core-originated send (cleartext $targ
    // envelopes AND inside the boxed identity-bundle payloads). Minor-version
    // ints: core 0.5.0 -> 5, 0.7.0 -> 7. Monotone; bump ONLY when a wire
    // surface registers a new versioned type (SPEC Q2), not on every release.
    // 7: the rcp surface (receive_receipt) registered in 0.7 — a peer whose
    // learned dialect is >= 7 is KNOWN to parse receipts-era transactions,
    // which the receipts gate uses to self-heal stale-caps contacts (see
    // a2a_messaging::receipt_gate). Correcting an under-bump: 0.7.0 initially
    // shipped still stamping 5, which left pre-receipts contacts permanently
    // gated (caps only re-learn on invite/restore legs — the owner-reported
    // single-tick bug).
    wire_version = 7.
    // The version floor: OSP (oldest supported peer) = core 0.2.0 -> 2.
    // Raising this = an owner decision recorded in COMPATIBILITY.md (drop the
    // v2 types from the unions + prune the corpus — a visible, reviewed act).
    min_wire_version = 2.

    // ---- safety-net reads (COMPAT-1, the layer UNDER the registry, REG-5) --
    // For display/UX-class optional fields ONLY: defense in depth so a bare
    // NIL is never again the only thing between an old peer and an EVAL_ERROR.
    // The registry dispatch above is the documented mechanism; any new `safe`
    // on wire data belongs inside a registry narrow/branch or one of these.
    fn opt_str  (v: any, dflt: str)  -> str  { return (v == NIL ?? dflt ; v safe str). }
    fn opt_int  (v: any, dflt: int)  -> int  { return (v == NIL ?? dflt ; v safe int). }
    fn opt_bool (v: any, dflt: bool) -> bool { return (v == NIL ?? dflt ; v safe bool). }

    // ---- runtime type-domain guards (M1) -----------------------------------
    // `x safe T` ABORTS on a present-but-wrong-DOMAIN field (mufl has no
    // try/catch), so presence checks alone cannot make try_narrow abort-free.
    // Every NON-nullable field a registry cast reads is pre-checked against its
    // _typeof runtime domain (probed on the vendored toolchain, mufl 0.8.0):
    //   str -> "STRING", int -> "INTEGER", bin -> "BINARY",
    //   global_id -> "STRING" (ids are hex strings at runtime).
    // Residual (documented, accepted): `safe global_id` additionally
    // hex-validates, so a STRING that is not valid hex still aborts inside the
    // exact cast. No shipped version's sender can produce that (senders stamp
    // real ids); reaching it requires a hostile hand-crafted box, which is the
    // malformed/tamper class where a hard abort is the correct outcome.
    td_str = "STRING".
    td_int = "INTEGER".

    fn is_str (v: any) -> bool { return v != NIL && (_typeof v) == td_str. }
    fn is_int (v: any) -> bool { return v != NIL && (_typeof v) == td_int. }

    // $pv as sent by the peer; 0 = pre-0.5 peer (never stamped it). Tolerant
    // of a mistyped $pv (non-int => treated as unstamped, shape inference
    // applies) so reading the discriminator itself can never abort (M1).
    fn peer_pv (raw: any) -> int
    {
        p = raw $pv.
        if is_int p != TRUE { return 0. }
        return p safe int.
    }

    // ---- error-as-data (owner Addition A) ----------------------------------
    // The first-class protocol return type for a version-incompatible input:
    // when a peer's wire version is below the floor, or its payload matches no
    // registered version, the handler RETURNS this value as data (via a
    // _notify_agent $protocol_error event on async inbound surfaces) instead
    // of aborting — the MCP server and every client resolve this type and
    // render $message cleanly. Codes are STABLE wire contract:
    //   "peer_version_unsupported"   — peer dialect below min_wire_version
    //   "payload_shape_unrecognized" — matches no registered version >= floor
    metadef version_error_t: (
        $code          -> str,
        $surface       -> str,   // registry id: "sir" | "cin" | "rst" | "acc" | ...
        $message       -> str,   // human-readable, render-ready
        $peer_version  -> int,   // as read/inferred by the discriminator
        $min_supported -> int,
        $max_supported -> int
    ).

    fn mk_version_error (surface: str, code: str, message: str, peer_version: int, max_supported: int) -> version_error_t
    {
        return (
            $code -> code, $surface -> surface, $message -> message,
            $peer_version -> peer_version,
            $min_supported -> min_wire_version, $max_supported -> max_supported
        ).
    }

    fn too_old_error (surface: str, peer_version: int, max_supported: int) -> version_error_t
    {
        return mk_version_error surface "peer_version_unsupported"
            ("Peer speaks unsupported (too old) protocol version v" + (_str peer_version)
             + "; minimum supported is v" + (_str min_wire_version) + ". Ask the peer to update.")
            peer_version max_supported.
    }

    fn shape_error (surface: str, peer_version: int, max_supported: int) -> version_error_t
    {
        return mk_version_error surface "payload_shape_unrecognized"
            ("Payload matches no supported wire shape of surface '" + surface
             + "' (peer dialect v" + (_str peer_version) + ", supported v"
             + (_str min_wire_version) + "..v" + (_str max_supported) + ").")
            peer_version max_supported.
    }

    // ---- reusable registry scaffold (type-level, via type reductions) ------
    // Generic union/vector pair; a registry may write these out directly (as
    // the concrete registries below do — 2 lines each, SPEC Q10) or
    // instantiate: `module sir instantiates versioned_input_3 with v5, v3, v2.`
    generic module versioned_input_2 takes Vnewest, Voldest
    {
        metadef union_t:    Vnewest || Voldest.
        metadef versions_t: [Voldest, Vnewest].
    }
    generic module versioned_input_3 takes Vnewest, Vmid, Voldest
    {
        metadef union_t:    Vnewest || Vmid || Voldest.
        metadef versions_t: [Voldest, Vmid, Vnewest].
    }

    // ========================================================================
    // REGISTRY "sir" — submit_invite_response, leg-1 boxed identity bundle.
    // The incident surface: 0.3.0 added $name; 0.2.0 peers omit it.
    // ========================================================================

    // v0.2.0 — the deployed OSP shape (ours-mcp). NO $name. $ad stays `any`:
    // the AD is verified downstream by verify_identity_bundle on the RAW
    // payload, never by this cast. bin+ = nullable: absent reads NIL, passes.
    metadef sir_payload_v2_t: (
        $ad           -> any,
        $cert         -> bin+,
        $root_profile -> bin+,
        $cp_binding   -> bin+,
        $invite_id    -> global_id
    ).
    // v0.3.0 — added $name (the field whose strict read caused the incident).
    metadef sir_payload_v3_t: (
        $ad           -> any,
        $cert         -> bin+,
        $root_profile -> bin+,
        $cp_binding   -> bin+,
        $invite_id    -> global_id,
        $name         -> str
    ).
    // v0.5.0 — adds the wire-version tag + capability piggyback (SPEC §4).
    metadef sir_payload_v5_t: (
        $ad           -> any,
        $cert         -> bin+,
        $root_profile -> bin+,
        $cp_binding   -> bin+,
        $invite_id    -> global_id,
        $name         -> str,
        $pv           -> int,
        $caps         -> str[]+
    ).

    // The handler-visible contract: union of every version >= OSP (REG-3).
    metadef sir_payload_t: sir_payload_v5_t || sir_payload_v3_t || sir_payload_v2_t.
    // Ordered registry listing — the reviewable "what do we accept" artifact.
    metadef sir_versions_t: [sir_payload_v2_t, sir_payload_v3_t, sir_payload_v5_t].
    sir_max_version = 5.

    // Discriminator: $pv when stamped (0.5.0+); pre-$pv shapes are inferred:
    // $name present => v3, else v2. Registry-local rule, documented here only.
    fn sir_version_of (raw: any) -> int
    {
        pv = peer_pv raw.
        if pv != 0 { return pv. }
        return ((raw $name) != NIL ?? 3 ; 2).
    }

    // Field presence + runtime-domain check for the REGISTERED version `reg`
    // (2|3|5): the abort-free "does this payload actually carry its version's
    // required fields, with the right domains" probe (M1) try_narrow uses to
    // make no-match an ERROR VALUE instead of a cast abort. Nullable fields
    // ($cert/$root_profile/$cp_binding bin+, $caps str[]+) are excluded: absent
    // reads NIL and passes; present-but-mistyped is the malformed/hostile class
    // (aborts in the cast, correctly). $ad is `any` — verified downstream.
    fn sir_shape_ok (raw: any, reg: int) -> bool
    {
        if (raw $ad) == NIL || is_str (raw $invite_id) != TRUE { return FALSE. }
        if reg >= 3 && is_str (raw $name) != TRUE { return FALSE. }
        if reg >= 5 && is_int (raw $pv) != TRUE { return FALSE. }
        return TRUE.
    }

    // try-narrow result: error-as-data union ($ok TRUE => $payload, else $err).
    metadef sir_narrowed_t: ($ok -> bool, $payload -> sir_payload_t+, $err -> version_error_t+).

    // REG-4 dispatch-then-narrow, error-as-data form (Addition A). $pv NEWER
    // than we know narrows as our newest (class-A forward compat).
    fn try_narrow_sir (raw: any) -> sir_narrowed_t
    {
        v = sir_version_of raw.
        if v < min_wire_version
        {
            return ($ok -> FALSE, $payload -> NIL, $err -> too_old_error "sir" v sir_max_version).
        }
        // Registered-version mapping: 5+ -> v5, 3..4 -> v3 (0.4.x never shipped
        // and its wire on this surface is byte-identical to 0.3's; a synthetic
        // $pv=4 therefore narrows as v3 — requires $name, else shape error),
        // else v2.
        reg = (v >= 5 ?? 5 ; (v >= 3 ?? 3 ; 2)).
        if sir_shape_ok raw reg != TRUE
        {
            return ($ok -> FALSE, $payload -> NIL, $err -> shape_error "sir" v sir_max_version).
        }
        if reg == 5 { return ($ok -> TRUE, $payload -> raw safe sir_payload_v5_t, $err -> NIL). }
        if reg == 3 { return ($ok -> TRUE, $payload -> raw safe sir_payload_v3_t, $err -> NIL). }
        return ($ok -> TRUE, $payload -> raw safe sir_payload_v2_t, $err -> NIL).
    }

    // Strict form: same dispatch, aborts with the stable message naming the
    // surface — never an EVAL_ERROR from a NIL cast deeper in.
    fn narrow_sir (raw: any) -> sir_payload_t
    {
        r = try_narrow_sir raw.
        if (r $ok) != TRUE { abort ((r $err)? $message) when TRUE. }
        return (r $payload)?.
    }

    // Versioned accessor — the per-branch "old way / new way" for the $name
    // gap: v0.3/v0.5 carry $name in their registered type; v0.2 has no such
    // field, so the v2 branch RETURNS the empty sentinel (caller falls back
    // to the sender cid — explicit, typed degradation).
    fn sir_joiner_name (input: sir_payload_t) -> str
    {
        raw = input as any.
        v = sir_version_of raw.
        if v >= 3 { return ((raw safe sir_payload_v3_t) $name). }
        return "".
    }

    // Versioned $caps accessor (M2 pattern: re-cast from raw per version —
    // never read version fields off the union binding): v5 carries $caps
    // (nullable); every earlier version has no such field — empty list.
    fn sir_caps (input: sir_payload_t) -> str[]
    {
        raw = input as any.
        if (sir_version_of raw) >= 5
        {
            c = (raw safe sir_payload_v5_t) $caps.
            if c != NIL { return c?. }
        }
        return [].
    }

    // ========================================================================
    // REGISTRY "cin" — complete_invite, leg-3 boxed identity bundle.
    // Never gained $name; v5 adds $pv/$caps only.
    // ========================================================================
    metadef cin_payload_v2_t: (
        $ad           -> any,
        $cert         -> bin+,
        $root_profile -> bin+,
        $cp_binding   -> bin+,
        $invite_id    -> global_id
    ).
    metadef cin_payload_v5_t: (
        $ad           -> any,
        $cert         -> bin+,
        $root_profile -> bin+,
        $cp_binding   -> bin+,
        $invite_id    -> global_id,
        $pv           -> int,
        $caps         -> str[]+
    ).
    metadef cin_payload_t: cin_payload_v5_t || cin_payload_v2_t.
    metadef cin_versions_t: [cin_payload_v2_t, cin_payload_v5_t].
    cin_max_version = 5.

    // Pre-$pv cin shapes are all v2 (no inferable v3 delta on this surface).
    fn cin_version_of (raw: any) -> int
    {
        pv = peer_pv raw.
        return (pv != 0 ?? pv ; 2).
    }

    fn cin_shape_ok (raw: any, reg: int) -> bool
    {
        if (raw $ad) == NIL || is_str (raw $invite_id) != TRUE { return FALSE. }
        if reg >= 5 && is_int (raw $pv) != TRUE { return FALSE. }
        return TRUE.
    }

    metadef cin_narrowed_t: ($ok -> bool, $payload -> cin_payload_t+, $err -> version_error_t+).

    fn try_narrow_cin (raw: any) -> cin_narrowed_t
    {
        v = cin_version_of raw.
        if v < min_wire_version
        {
            return ($ok -> FALSE, $payload -> NIL, $err -> too_old_error "cin" v cin_max_version).
        }
        reg = (v >= 5 ?? 5 ; 2).
        if cin_shape_ok raw reg != TRUE
        {
            return ($ok -> FALSE, $payload -> NIL, $err -> shape_error "cin" v cin_max_version).
        }
        if reg >= 5 { return ($ok -> TRUE, $payload -> raw safe cin_payload_v5_t, $err -> NIL). }
        return ($ok -> TRUE, $payload -> raw safe cin_payload_v2_t, $err -> NIL).
    }

    fn narrow_cin (raw: any) -> cin_payload_t
    {
        r = try_narrow_cin raw.
        if (r $ok) != TRUE { abort ((r $err)? $message) when TRUE. }
        return (r $payload)?.
    }

    fn cin_caps (input: cin_payload_t) -> str[]
    {
        raw = input as any.
        if (cin_version_of raw) >= 5
        {
            c = (raw safe cin_payload_v5_t) $caps.
            if c != NIL { return c?. }
        }
        return [].
    }

    // ========================================================================
    // REGISTRY "rst" — contact-restore boxed identity bundles (legs 1 and 2,
    // submit_restore_response / complete_restore). Same bundle as cin with
    // $rid instead of $invite_id; v5 adds $pv/$caps.
    // ========================================================================
    metadef rst_payload_v2_t: (
        $ad           -> any,
        $cert         -> bin+,
        $root_profile -> bin+,
        $cp_binding   -> bin+,
        $rid          -> global_id
    ).
    metadef rst_payload_v5_t: (
        $ad           -> any,
        $cert         -> bin+,
        $root_profile -> bin+,
        $cp_binding   -> bin+,
        $rid          -> global_id,
        $pv           -> int,
        $caps         -> str[]+
    ).
    metadef rst_payload_t: rst_payload_v5_t || rst_payload_v2_t.
    metadef rst_versions_t: [rst_payload_v2_t, rst_payload_v5_t].
    rst_max_version = 5.

    fn rst_version_of (raw: any) -> int
    {
        pv = peer_pv raw.
        return (pv != 0 ?? pv ; 2).
    }

    fn rst_shape_ok (raw: any, reg: int) -> bool
    {
        if (raw $ad) == NIL || is_str (raw $rid) != TRUE { return FALSE. }
        if reg >= 5 && is_int (raw $pv) != TRUE { return FALSE. }
        return TRUE.
    }

    metadef rst_narrowed_t: ($ok -> bool, $payload -> rst_payload_t+, $err -> version_error_t+).

    fn try_narrow_rst (raw: any) -> rst_narrowed_t
    {
        v = rst_version_of raw.
        if v < min_wire_version
        {
            return ($ok -> FALSE, $payload -> NIL, $err -> too_old_error "rst" v rst_max_version).
        }
        reg = (v >= 5 ?? 5 ; 2).
        if rst_shape_ok raw reg != TRUE
        {
            return ($ok -> FALSE, $payload -> NIL, $err -> shape_error "rst" v rst_max_version).
        }
        if reg >= 5 { return ($ok -> TRUE, $payload -> raw safe rst_payload_v5_t, $err -> NIL). }
        return ($ok -> TRUE, $payload -> raw safe rst_payload_v2_t, $err -> NIL).
    }

    fn narrow_rst (raw: any) -> rst_payload_t
    {
        r = try_narrow_rst raw.
        if (r $ok) != TRUE { abort ((r $err)? $message) when TRUE. }
        return (r $payload)?.
    }

    fn rst_caps (input: rst_payload_t) -> str[]
    {
        raw = input as any.
        if (rst_version_of raw) >= 5
        {
            c = (raw safe rst_payload_v5_t) $caps.
            if c != NIL { return c?. }
        }
        return [].
    }

    // ========================================================================
    // REGISTRY "acc" — legacy accept_contact $targ args (encrypted channel).
    // Hygiene sibling of sir: 0.3.0 added $joiner_name; 0.2.0 omits it. The
    // path itself is slated for class-C removal at the next OSP raise. Never
    // gained $pv (0.5.0 does not send it), so v3 is the newest registered.
    // ========================================================================
    metadef acc_args_v2_t: (
        $invite_id           -> global_id,
        $joiner_ad           -> any,
        $joiner_cert         -> bin+,
        $joiner_root_profile -> bin+,
        $joiner_cp_binding   -> bin+
    ).
    metadef acc_args_v3_t: (
        $invite_id           -> global_id,
        $joiner_ad           -> any,
        $joiner_cert         -> bin+,
        $joiner_root_profile -> bin+,
        $joiner_cp_binding   -> bin+,
        $joiner_name         -> str
    ).
    metadef acc_args_t: acc_args_v3_t || acc_args_v2_t.
    metadef acc_versions_t: [acc_args_v2_t, acc_args_v3_t].
    acc_max_version = 3.

    fn acc_version_of (raw: any) -> int
    {
        pv = peer_pv raw.
        if pv != 0 { return pv. }
        return ((raw $joiner_name) != NIL ?? 3 ; 2).
    }

    fn acc_shape_ok (raw: any, reg: int) -> bool
    {
        if is_str (raw $invite_id) != TRUE || (raw $joiner_ad) == NIL { return FALSE. }
        if reg >= 3 && is_str (raw $joiner_name) != TRUE { return FALSE. }
        return TRUE.
    }

    metadef acc_narrowed_t: ($ok -> bool, $payload -> acc_args_t+, $err -> version_error_t+).

    fn try_narrow_acc (raw: any) -> acc_narrowed_t
    {
        v = acc_version_of raw.
        if v < min_wire_version
        {
            return ($ok -> FALSE, $payload -> NIL, $err -> too_old_error "acc" v acc_max_version).
        }
        reg = (v >= 3 ?? 3 ; 2).
        if acc_shape_ok raw reg != TRUE
        {
            return ($ok -> FALSE, $payload -> NIL, $err -> shape_error "acc" v acc_max_version).
        }
        if reg >= 3 { return ($ok -> TRUE, $payload -> raw safe acc_args_v3_t, $err -> NIL). }
        return ($ok -> TRUE, $payload -> raw safe acc_args_v2_t, $err -> NIL).
    }

    fn narrow_acc (raw: any) -> acc_args_t
    {
        r = try_narrow_acc raw.
        if (r $ok) != TRUE { abort ((r $err)? $message) when TRUE. }
        return (r $payload)?.
    }

    // acc analogue of sir_joiner_name: v3 carries $joiner_name; v2 has no such
    // field — return the empty sentinel (caller falls back to the sender cid).
    fn acc_joiner_name (input: acc_args_t) -> str
    {
        raw = input as any.
        v = acc_version_of raw.
        if v >= 3 { return ((raw safe acc_args_v3_t) $joiner_name). }
        return "".
    }

    // ========================================================================
    // Single-version registrations (REG-1) — surfaces whose shape never
    // changed since OSP. Registering them pre-wires the change procedure: a
    // future shape change adds a v<next>_t + one union branch here instead of
    // an ad-hoc read. Their handlers keep field-by-field tolerant reads (the
    // shapes are all-optional beyond the required core); the entries below are
    // the registry index + the $pv learning hook. Remaining envelope surfaces
    // (invite/restore cleartext envelopes, enroll/ingest/control/monitoring,
    // notify_*) are catalogued in COMPATIBILITY.md.
    // ========================================================================

    // receive_message $targ (v5 adds only the $pv stamp — same shape).
    metadef rmsg_targ_v2_t: (
        $text     -> str,
        $wire_id  -> str+,
        $reply_to -> any,
        $pv       -> int+
    ).
    metadef rmsg_targ_t: rmsg_targ_v2_t.
    fn rmsg_version_of (raw: any) -> int
    {
        pv = peer_pv raw.
        return (pv != 0 ?? pv ; 2).
    }

    // receive_receipt $targ (core 0.7.0, class-B new surface — single version;
    // reachable only behind positive core.receipts.* caps, so no $pv bump).
    metadef rcp_targ_v1_t: (
        $kind     -> str,      // "delivered" | "read" (frozen id strings)
        $wire_ids -> any,      // str[] — 1..N stable wire ids (shared msg+file namespace)
        $date     -> time+,
        $pv       -> int+
    ).
    metadef rcp_targ_t: rcp_targ_v1_t.
    fn rcp_version_of (raw: any) -> int
    {
        pv = peer_pv raw.
        return (pv != 0 ?? pv ; 7).
    }
    // Abort-free classification (M1): the handler IGNORES (success, no-op) any
    // payload failing this — receipts are best-effort UX, never load-bearing.
    // $wire_ids must be a real list (lists ride IMMUTABLE_DICTIONARY at
    // runtime): iterating a scalar would char-walk strings / abort on ints.
    fn rcp_shape_ok (raw: any) -> bool
    {
        ids = raw $wire_ids.
        return is_str (raw $kind) && ids != NIL && (_typeof ids) == "IMMUTABLE_DICTIONARY".
    }

    // receive_file $targ (v5 adds only the $pv stamp — same shape).
    metadef rfil_targ_v2_t: (
        $filename -> str,
        $data     -> bin,
        $mime     -> str+,
        $wire_id  -> str+,
        $reply_to -> any,
        $pv       -> int+
    ).
    metadef rfil_targ_t: rfil_targ_v2_t.
    fn rfil_version_of (raw: any) -> int
    {
        pv = peer_pv raw.
        return (pv != 0 ?? pv ; 2).
    }
}
