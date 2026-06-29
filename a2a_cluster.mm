// Shared ours cluster library (core.cluster capability handler).
//
// Implements CLUSTER_API.md (FROZEN v1 + refinement R1): the core.cluster verb
// handler dispatched via a2a_capabilities, the root-packet cluster_members
// registry, the async create/remove workflow (host-primitive notify-actions +
// host callbacks), and reconcile (host-truth ⨝ registry). The control plane and
// every root-managing app speak ONE envelope; this library owns the cluster
// verb logic so no app hand-codes it.
//
// Layering: loads a2a_messaging (composes its trns' helper fns: resolve_contact,
// emit_pair, introduce_name) + a2a_capabilities (build_response, the cap id).
// The authz chokepoint is in a2a_capabilities::dispatch (RR-9); handlers here
// run AFTER it, so they may assume the sender is the authorized controller.
//
// Response model (R1): a handler RETURNS the response_envelope as transaction
// return_data (a NATIVE record); the daemon marshals it to JSON + ships via the
// generic sendControl. Core emits NO send action for responses. MUFL has no JSON
// codec, so $args (request) and $result/$err (response) are native both ways —
// the daemon adapts JSON<->native at the boundary, generically.
library a2a_cluster loads libraries
    current_transaction_info,
    address_document_types,
    a2a_protocol,
    a2a_capabilities,
    a2a_messaging,
    version
    uses transactions
{
    // ---- host-primitive notify-action event tags (CLUSTER_API.md §7) ----------
    // Emitted to the local daemon (host executor) as $notify_agent actions; never
    // cross the network. The daemon maps each to a runtime op + a host callback.
    ev_provision  = "host_provision_child".
    ev_destroy    = "host_destroy_child".
    ev_enumerate  = "host_enumerate_children".
    // R2: minting a child's invite is irreducibly CROSS-PACKET (only the child's
    // packet can sign its own AD) — so it is the 4th host primitive. The daemon
    // runs generate_invite IN the child's packet and calls back register_child_invite.
    ev_mint_invite = "host_mint_child_invite".
    // Per-child monitoring (single-gate, host-mediated): the daemon binds the CHILD's
    // monitoring_proxy to the root's ceremony-pinned cluster CP (enable: host-run
    // set_proxy_pending+verify_proxy_code on the child; disable: host_clear_child_monitoring).
    ev_set_monitoring = "host_set_child_monitoring".

    // core 3.2: CP-side inbound name for a pushed roster snapshot (literal — this lib
    // keeps no code dep on a2a_monitoring, which loads us).
    roster_update_tx = "::a2a_monitoring::receive_roster_update".

    // ---- registry (RR-3: host-truth-backed projection) ------------------------
    // member = the control-plane row for one hosted child. $monitoring in
    // "off"|"pending"|"on"; $caps is the child's advertised capability ids.
    metadef member_t: ($cid -> global_id, $role_id -> str, $name -> str,
                       $bio -> str, $persona -> str, $monitoring -> str, $caps -> str[]).
    cluster_members is (global_id ->> member_t) = (,).

    // A child as enumerated from host truth (RR-4: carries caps + bio so a
    // backfilled member is introduce-capable, not hard-blocked). $child_ad is the
    // child's native address document (the daemon passes it parsed — no in-MUFL
    // deserialization, consistent with R1).
    metadef child_rec_t: ($cid -> global_id, $role_id -> str, $name -> str,
                          $bio -> str, $persona -> str, $caps -> str[],
                          $child_ad -> address_document_types::t_address_document).

    // ---- async pending / dedup state (CLUSTER_API.md §8) ----------------------
    // pending_reqs: keyed by the host-unique $pending_handle, holds the full
    // (sender,$req_id) so a callback resolves the right sender (RR-2).
    metadef pending_req_t: ($handle -> str, $sender_id -> global_id, $req_id -> str,
                           $verb -> str, $op_key -> str, $bio -> str, $date -> time).
    pending_reqs is (str ->> pending_req_t) = (,).
    // GLOBAL (not per-sender) pending-create op-keys by name (RR-3): blocks a
    // proxy-handoff re-create of a name already mid-provision.
    pending_create_names is (str ->> bool) = (,).
    // Monotonic handle counter (MUFL has no RNG): handle = my_cid + "-" + seq.
    next_handle_seq is int = 0.
    // §8 pending-req TTL: a pending-req older than this is swept (settled) by
    // sweep_and_settle, which WS-B calls AFTER a fresh reconcile (so an adopted
    // orphan is already in the registry before we decide success vs timeout).
    pending_req_ttl_seconds = 120.

    // ---- local action helpers -------------------------------------------------
    fn _save (_) = (transaction::action::return_data ($kind -> $save_state)).
    fn _ret (payload: any) = (transaction::action::return_data ($kind -> $data, $payload -> payload)).
    fn _notify (payload: any) = (transaction::action::return_data ($kind -> $notify_agent, $payload -> payload)).

    fn _ok_action (req_id: str, result_val: any) -> transaction::action::type
    {
        return _ret (a2a_capabilities::build_response ($req_id -> req_id, $ok -> TRUE, $result -> result_val, $err -> (,))).
    }
    fn _err_action (req_id: str, code: str, message: str) -> transaction::action::type
    {
        return a2a_capabilities::deny_action ($req_id -> req_id, $code -> code, $message -> message).
    }

    // ASYNC reply (CLUSTER_API.md §2 R1 routing): a host-fired callback runs at
    // origin::user, so its ctx sender is the DAEMON/self — the async response must
    // route to the ORIGINAL controller stored in the pending-req, never to the
    // callback's own sender. So the callback's return_data is a routing wrapper
    // ($target -> the stored sender cid, $response -> the response_envelope); the
    // daemon ships $response to $target. Routing is always by sender, never by verb.
    fn _async_reply (target: global_id, response: a2a_capabilities::response_envelope_t) -> transaction::action::type
    {
        return _ret ($target -> (_str target), $response -> response).
    }

    fn _mint_handle (_) -> str
    {
        next_handle_seq -> next_handle_seq + 1.
        return (_str (_get_container_id())) + "-" + (_str next_handle_seq).
    }

    // member -> the native $result record the daemon marshals to JSON.
    fn _member_view (m: member_t) -> any
    {
        return (
            $cid        -> (_str (m $cid)),
            $role_id    -> (m $role_id),
            $name       -> (m $name),
            $bio        -> (m $bio),
            $persona    -> (m $persona),
            $monitoring -> (m $monitoring),
            $caps       -> (m $caps)
        ).
    }

    fn _member_views (_) -> any[]
    {
        views is any[] = [].
        sc cluster_members -- ( -> m) { views (_count views|) -> (_member_view m). }
        return views.
    }

    // core 3.2: build the roster-push actions IFF a control plane is bound. Bumps the
    // seq so each push is ordered; carries the full member view (rosters are small,
    // push-on-change). Returns [] when unbound (push_to_cp_actions also self-gates).
    fn _push_roster_actions (_) -> transaction::action::type[]
    {
        if (a2a_messaging::bound_cp_cid NIL) == NIL { return []. }
        seq = a2a_messaging::next_roster_seq NIL.
        return a2a_messaging::push_to_cp_actions roster_update_tx ($version -> seq, $members -> (_member_views NIL)).
    }

    // registry lookups for the sweep (the registry is keyed by global_id; create's
    // op-key is the name, remove's is the stringified cid).
    fn _find_by_name (name: str) -> member_t+
    {
        found is member_t+ = NIL.
        sc cluster_members -- ( -> m) ?? found == NIL { if (m $name) == name { found -> m. } }
        return found.
    }
    fn _present_cid_str (cidstr: str) -> bool
    {
        present is bool = FALSE.
        sc cluster_members -- (cid -> _) ?? present == FALSE { if (_str cid) == cidstr { present -> TRUE. } }
        return present.
    }
    fn _timeout_resp (req_id: str, message: str) -> a2a_capabilities::response_envelope_t
    {
        return a2a_capabilities::build_response ($req_id -> req_id, $ok -> FALSE, $result -> (,), $err -> ($code -> "timeout", $message -> message)).
    }

    // ---- verb handlers (each returns transaction::action::type[]) --------------
    // list: read the registry (post-reconcile). Controller-gated upstream.
    fn _h_list (ctx: any) -> transaction::action::type[]
    {
        return [ _ok_action ((ctx $req_id) safe str) ($members -> (_member_views NIL), $version -> (a2a_messaging::current_roster_seq NIL)) ].
    }

    // set_bio: registry-only in v1 (§13-Q3). Updates the member's bio.
    fn _h_set_bio (ctx: any) -> transaction::action::type[]
    {
        req_id = (ctx $req_id) safe str.
        args = ctx $args.
        cid = (args $cid) safe global_id.
        m = cluster_members cid.
        if m == NIL { return [ _err_action req_id "not_found" "no such child" ]. }
        bio = (args $bio) safe str.
        cluster_members cid -> ($cid -> (m $cid), $role_id -> (m $role_id), $name -> (m $name),
                                $bio -> bio, $persona -> (m $persona), $monitoring -> (m $monitoring), $caps -> (m $caps)).
        out is transaction::action::type[] = [ _ok_action req_id ($cid -> (_str cid), $bio -> bio) ].
        sc (_push_roster_actions NIL) -- ( -> a) { out (_count out|) -> a. }
        out (_count out|) -> _save NIL.
        return out.
    }

    // set_persona: registry-only, host-authoritative (mirrors set_bio, §13-Q3).
    fn _h_set_persona (ctx: any) -> transaction::action::type[]
    {
        req_id = (ctx $req_id) safe str.
        args = ctx $args.
        cid = (args $cid) safe global_id.
        m = cluster_members cid.
        if m == NIL { return [ _err_action req_id "not_found" "no such child" ]. }
        persona = (args $persona) safe str.
        cluster_members cid -> ($cid -> (m $cid), $role_id -> (m $role_id), $name -> (m $name),
                                $bio -> (m $bio), $persona -> persona, $monitoring -> (m $monitoring), $caps -> (m $caps)).
        out is transaction::action::type[] = [ _ok_action req_id ($cid -> (_str cid), $persona -> persona) ].
        sc (_push_roster_actions NIL) -- ( -> a) { out (_count out|) -> a. }
        out (_count out|) -> _save NIL.
        return out.
    }

    // set_monitoring (ASYNC, single-gate host-mediated, C5): real per-child monitoring.
    // The CP a child is bound to is DERIVED from the root's OWN ceremony-pinned
    // monitoring_proxy (bound_cp_cid) — NEVER from $args (critic load-bearing condition:
    // a child can only ever be bound to the root's ceremonied CP, so no bypass). Emits
    // host_set_child_monitoring; the daemon host-binds (enable) or host-clears (disable)
    // the CHILD's monitoring_proxy, then calls back confirm_child_monitoring. Enable
    // requires the root to be bound to a cluster CP. (e) disable genuinely clears the
    // child's proxy → forwarding stops. (i) child-visible notice = conscious deferred
    // carry (mcp host children are non-human-facing) — see CLUSTER_API.md §9.
    fn _h_set_monitoring (ctx: any) -> transaction::action::type[]
    {
        req_id = (ctx $req_id) safe str.
        cid = ((ctx $args) $cid) safe global_id.
        if (cluster_members cid) == NIL { return [ _err_action req_id "not_found" "no such child" ]. }
        enabled = ((ctx $args) $enabled) safe bool.
        sender_id = (ctx $sender_id) safe global_id.
        date = (ctx $date) safe time.
        handle = _mint_handle NIL.
        pr = ($handle -> handle, $sender_id -> sender_id, $req_id -> req_id,
              $verb -> "set_monitoring", $op_key -> (_str cid), $bio -> "", $date -> date).
        ack = _ret (a2a_capabilities::build_response ($req_id -> req_id, $ok -> TRUE, $result -> ($pending -> TRUE), $err -> (,))).

        if enabled == TRUE
        {
            // ENABLE: derive the CP from the root's OWN ceremony-pinned proxy, and carry
            // the CP's verified AD so the daemon can HOST-INJECT it into the child as a
            // contact (host_register_monitoring_cp) BEFORE host-running the ceremony — a
            // network introduce is rejected by the child's CP-only acceptance gate and
            // would race the ceremony anyway (§9).
            cp = a2a_messaging::bound_cp_cid NIL.
            if cp == NIL { return [ _err_action req_id "not_bound" "no bound cluster CP to monitor under" ]. }
            cp_ad = a2a_messaging::peer_ads cp?.
            if cp_ad == NIL { return [ _err_action req_id "internal" "bound CP has no stored address document" ]. }
            pending_reqs handle -> pr.
            return [
                _notify ($event -> ev_set_monitoring, $cid -> cid, $cp_cid -> cp?, $cp_ad -> cp_ad?, $enabled -> TRUE, $pending_handle -> handle),
                ack, _save NIL
            ].
        }
        // DISABLE: no CP needed — the daemon host-clears the child's monitoring_proxy.
        pending_reqs handle -> pr.
        return [
            _notify ($event -> ev_set_monitoring, $cid -> cid, $enabled -> FALSE, $pending_handle -> handle),
            ack, _save NIL
        ].
    }

    // create (async): op-key = name (global). Short-circuit if the name already
    // exists as a member or a pending create (RR-3 registry+pending check; the
    // host-packet (d) check is enforced by the daemon enumerable-before-ack +
    // reconcile). Emits host_provision_child + persists the pending-req.
    fn _h_create (ctx: any) -> transaction::action::type[]
    {
        req_id = (ctx $req_id) safe str.
        args = ctx $args.
        name = (args $name) safe str.
        bio = ((args $bio) == NIL ?? "" ; (args $bio) safe str).

        dup is bool = FALSE.
        sc cluster_members -- ( -> m) ?? dup == FALSE { if (m $name) == name { dup -> TRUE. } }
        if dup == TRUE || (pending_create_names name) != NIL
        {
            return [ _err_action req_id "duplicate" "a child with that name already exists or is being created" ].
        }

        handle = _mint_handle NIL.
        pending_reqs handle -> ($handle -> handle, $sender_id -> ((ctx $sender_id) safe global_id), $req_id -> req_id,
                                $verb -> "create", $op_key -> name, $bio -> bio, $date -> ((ctx $date) safe time)).
        pending_create_names name -> TRUE.
        return [
            _notify ($event -> ev_provision, $name -> name, $bio -> bio, $pending_handle -> handle),
            _ret (a2a_capabilities::build_response ($req_id -> req_id, $ok -> TRUE, $result -> ($pending -> TRUE), $err -> (,))),
            _save NIL
        ].
    }

    // remove (async): op-key = cid. Idempotent if already absent. Emits
    // host_destroy_child + pending-req.
    fn _h_remove (ctx: any) -> transaction::action::type[]
    {
        req_id = (ctx $req_id) safe str.
        args = ctx $args.
        cid = (args $cid) safe global_id.
        if (cluster_members cid) == NIL
        {
            return [ _ok_action req_id ($cid -> (_str cid), $removed -> TRUE) ].
        }
        handle = _mint_handle NIL.
        pending_reqs handle -> ($handle -> handle, $sender_id -> ((ctx $sender_id) safe global_id), $req_id -> req_id,
                                $verb -> "remove", $op_key -> (_str cid), $bio -> "", $date -> ((ctx $date) safe time)).
        return [
            _notify ($event -> ev_destroy, $cid -> cid, $pending_handle -> handle),
            _ret (a2a_capabilities::build_response ($req_id -> req_id, $ok -> TRUE, $result -> ($pending -> TRUE), $err -> (,))),
            _save NIL
        ].
    }

    // contact (ASYNC, R2): the controller must become a DIRECT contact of the CHILD
    // (chatWithAgent keys on childCid), so the invite must carry the CHILD's identity
    // — and only the child's packet can sign its own AD. The root handler therefore
    // CANNOT mint it (a root-minted invite = confused deputy → contacts the root).
    // So: validate the cid is a real hosted child (criterion 5), persist a pending-
    // req, and emit host_mint_child_invite; the daemon runs generate_invite IN the
    // child packet and calls back register_child_invite with the child's invite blob.
    // $result.invite shape is UNCHANGED (base64url of an invite bin) — WS-C unaffected.
    fn _h_contact (ctx: any) -> transaction::action::type[]
    {
        req_id = (ctx $req_id) safe str.
        cid = ((ctx $args) $cid) safe global_id.
        if (cluster_members cid) == NIL { return [ _err_action req_id "not_found" "no such child" ]. }
        handle = _mint_handle NIL.
        pending_reqs handle -> ($handle -> handle, $sender_id -> ((ctx $sender_id) safe global_id), $req_id -> req_id,
                                $verb -> "contact", $op_key -> (_str cid), $bio -> "", $date -> ((ctx $date) safe time)).
        return [
            _notify ($event -> ev_mint_invite, $cid -> cid, $pending_handle -> handle),
            _ret (a2a_capabilities::build_response ($req_id -> req_id, $ok -> TRUE, $result -> ($pending -> TRUE), $err -> (,))),
            _save NIL
        ].
    }

    // introduce: compose a2a_messaging::emit_pair (1:1 $peer_a/$peer_b) — both
    // parties must be established contacts (peer_ads). Cluster-scoped child<->contact.
    // resolve_contact aborts on an unknown ref (matches the existing introduce trn);
    // a missing stored AD returns a clean not_found.
    fn _h_introduce (ctx: any) -> transaction::action::type[]
    {
        req_id = (ctx $req_id) safe str.
        args = ctx $args.
        a_id = a2a_messaging::resolve_contact ((args $peer_a) safe str).
        b_id = a2a_messaging::resolve_contact ((args $peer_b) safe str).
        if a_id == b_id { return [ _err_action req_id "bad_args" "cannot introduce a node to itself" ]. }
        ad_a = a2a_messaging::peer_ads a_id.
        ad_b = a2a_messaging::peer_ads b_id.
        if ad_a == NIL || ad_b == NIL { return [ _err_action req_id "not_found" "a peer is not an established contact" ]. }
        actions is transaction::action::type[] =
            a2a_messaging::emit_pair a_id ad_a? (a2a_messaging::introduce_name a_id)
                                     b_id ad_b? (a2a_messaging::introduce_name b_id).
        actions (_count actions|) -> _ok_action req_id ($ok -> TRUE).
        return actions.
    }

    // ---- core.monitoring + core.connect handlers (cutover: ALL caps via dispatch) --
    // core.monitoring: bind (auth-class BOOTSTRAP — runs pre-bind; THE envelope-path
    // bootstrap) wraps the shared 6-digit ceremony and on success returns
    // {manifest, members, config} one-shot (WS-C Q3); disable clears the binding.
    fn monitoring_handler (ctx: any) -> transaction::action::type[]
    {
        verb = (ctx $verb) safe str.
        req_id = (ctx $req_id) safe str.
        sender_id = (ctx $sender_id) safe global_id.
        if verb == "bind"
        {
            code = ((ctx $args) $code) safe str.
            r = a2a_messaging::do_verify_proxy_code code sender_id.
            if (r $verified) != TRUE
            {
                return [ _err_action req_id "bind_failed" (r $reason), _save NIL ].
            }
            mf = a2a_capabilities::current_manifest NIL.
            cfg_cap = (mf $capabilities) a2a_capabilities::cap_configuration.
            config_params = ((cfg_cap == NIL) ?? "" ; cfg_cap? $params).
            return [
                _ok_action req_id ($manifest -> mf, $members -> (_member_views NIL), $config -> config_params, $version -> (a2a_messaging::current_roster_seq NIL)),
                _save NIL
            ].
        }
        if verb == "disable"
        {
            if (a2a_messaging::do_disable_monitoring sender_id) != TRUE
            {
                return [ _err_action req_id "not_bound" "sender is not the bound control plane" ].
            }
            return [ _ok_action req_id ($ok -> TRUE), _save NIL ].
        }
        return [ _err_action req_id "unknown_verb" ("core.monitoring has no verb: " + verb) ].
    }

    // core.connect: introduce (generic peer<->peer; reuses the emit_pair composition).
    fn connect_handler (ctx: any) -> transaction::action::type[]
    {
        verb = (ctx $verb) safe str.
        if verb == "introduce" { return _h_introduce ctx. }
        return [ _err_action ((ctx $req_id) safe str) "unknown_verb" ("core.connect has no verb: " + verb) ].
    }

    // ---- the capability handler (wired into a2a_capabilities::init $handlers) --
    // Switches on ctx.$verb. Unknown verb -> unknown_verb error (no permissive
    // fall-through, §3). contact/introduce compose a2a_messaging and land next.
    fn cluster_handler (ctx: any) -> transaction::action::type[]
    {
        verb = (ctx $verb) safe str.
        if verb == "list"           { return _h_list ctx. }
        if verb == "set_bio"        { return _h_set_bio ctx. }
        if verb == "set_persona"    { return _h_set_persona ctx. }
        if verb == "set_monitoring" { return _h_set_monitoring ctx. }
        if verb == "create"         { return _h_create ctx. }
        if verb == "remove"         { return _h_remove ctx. }
        if verb == "contact"        { return _h_contact ctx. }
        if verb == "introduce"      { return _h_introduce ctx. }
        return [ _err_action ((ctx $req_id) safe str) "unknown_verb" ("core.cluster has no verb: " + verb) ].
    }

    // ---- host callbacks (CLUSTER_API.md §7) ------------------------------------
    // HOST-ONLY: origin::user (a remote peer is origin::external and cannot claim
    // it) + MUST match an outstanding pending-req by $pending_handle (else abort);
    // the pending-req is consumed atomically on first callback (RR-1 correctness /
    // RR-3 idempotency). Not in any $handlers map, so dispatch cannot reach them.
    trn register_provisioned_child _:($pending_handle -> handle: str,
                                      $role_id -> role_id: str,
                                      $child_ad -> child_ad: address_document_types::t_address_document)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        pr = pending_reqs handle.
        abort "register_provisioned_child: no matching pending-req (unsolicited callback rejected)." when pr == NIL || (pr $verb) != "create".

        name = pr $op_key.
        cid = child_ad $identity $container_id.
        // C2 (RR-4 on the create path): populate caps so the new child is NOT
        // introduce-hard-blocked (caps=[] reads connectKnown=true,connect=false)
        // for the ≤300s until the next reconcile. Every child of this app
        // advertises the SAME describe() capability set, so seed from my own live
        // manifest; bio from the create's pending-req; role_id from the daemon
        // (it delegated the role). reconcile later refreshes from host truth.
        mf = a2a_capabilities::current_manifest NIL.
        caps_list is str[] = [].
        sc (mf $capabilities) -- (cap_id -> _) { caps_list (_count caps_list|) -> cap_id. }
        cluster_members cid -> ($cid -> cid, $role_id -> role_id, $name -> name, $bio -> (pr $bio), $persona -> "",
                                $monitoring -> "off", $caps -> caps_list).
        // consume the pending-req + its global op-key atomically.
        pending_reqs handle -> NIL.
        pending_create_names name -> NIL.
        out is transaction::action::type[] = [
            _async_reply (pr $sender_id) (a2a_capabilities::build_response (
                $req_id -> (pr $req_id), $ok -> TRUE,
                $result -> ($cid -> (_str cid), $name -> name, $monitoring -> "off"),
                $err -> (,)
            ))
        ].
        sc (_push_roster_actions NIL) -- ( -> a) { out (_count out|) -> a. }
        out (_count out|) -> _save NIL.
        return transaction::success out.
    }

    trn confirm_child_destroyed _:($pending_handle -> handle: str, $cid -> cid: global_id)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        pr = pending_reqs handle.
        abort "confirm_child_destroyed: no matching pending-req (unsolicited callback rejected)." when pr == NIL || (pr $verb) != "remove".

        cluster_members cid -> NIL.
        pending_reqs handle -> NIL.
        out is transaction::action::type[] = [
            _async_reply (pr $sender_id) (a2a_capabilities::build_response (
                $req_id -> (pr $req_id), $ok -> TRUE,
                $result -> ($cid -> (_str cid), $removed -> TRUE), $err -> (,)
            ))
        ].
        sc (_push_roster_actions NIL) -- ( -> a) { out (_count out|) -> a. }
        out (_count out|) -> _save NIL.
        return transaction::success out.
    }

    // register_child_invite (R2 contact callback): the daemon ran generate_invite IN
    // the CHILD's packet (so $invite carries the child's identity/keys/cert — the
    // redeemer reaches the CHILD, not the root) and hands the blob back here. SAME
    // RR-1 guards as the other callbacks: origin::user FIRST + pending-handle match
    // (verb=="contact") + atomic consume — no forged child-invite injection. Routes
    // the invite to the STORED controller via $target (not the daemon/self).
    trn register_child_invite _:($pending_handle -> handle: str, $invite -> invite_blob: bin)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        pr = pending_reqs handle.
        abort "register_child_invite: no matching pending-req (unsolicited callback rejected)." when pr == NIL || (pr $verb) != "contact".
        pending_reqs handle -> NIL.
        return transaction::success [
            _async_reply (pr $sender_id) (a2a_capabilities::build_response (
                $req_id -> (pr $req_id), $ok -> TRUE,
                $result -> ($invite -> invite_blob), $err -> (,)
            )),
            _save NIL
        ].
    }

    // confirm_child_monitoring (C5 set_monitoring callback): the daemon host-bound (or
    // host-cleared) the CHILD's monitoring_proxy and reports the resulting state. SAME
    // RR-1 guards (origin::user FIRST + pending-handle match verb==set_monitoring +
    // atomic consume). Updates the registry $monitoring to host truth, routes the reply
    // to the STORED controller via $target.
    trn confirm_child_monitoring _:($pending_handle -> handle: str, $cid -> cid: global_id, $enabled -> enabled: bool)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        pr = pending_reqs handle.
        abort "confirm_child_monitoring: no matching pending-req (unsolicited callback rejected)." when pr == NIL || (pr $verb) != "set_monitoring".
        pending_reqs handle -> NIL.
        mon = (enabled == TRUE ?? "on" ; "off").
        m = cluster_members cid.
        if m != NIL { cluster_members cid -> ($cid -> (m $cid), $role_id -> (m $role_id), $name -> (m $name), $bio -> (m $bio), $persona -> (m $persona), $monitoring -> mon, $caps -> (m $caps)). }
        out is transaction::action::type[] = [
            _async_reply (pr $sender_id) (a2a_capabilities::build_response (
                $req_id -> (pr $req_id), $ok -> TRUE,
                $result -> ($cid -> (_str cid), $monitoring -> mon), $err -> (,)
            ))
        ].
        sc (_push_roster_actions NIL) -- ( -> a) { out (_count out|) -> a. }
        out (_count out|) -> _save NIL.
        return transaction::success out.
    }

    // reconcile: host truth ⨝ registry (RR-3). Adds host children missing from the
    // registry (backfills out-of-band/CLI creates + the upgrade migration, RR-5),
    // drops members absent from host truth. $pending_handle="" for timer/boot runs.
    trn reconcile _:($pending_handle -> handle: str, $children -> children: child_rec_t[])
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        // host cids present this round (for the drop pass).
        seen is (global_id ->> bool) = (,).
        added is int = 0.
        changed is int = 0.
        sc children -- ( -> c)
        {
            cid = c $cid.
            seen cid -> TRUE.
            existing = cluster_members cid.
            if existing == NIL { added -> added + 1. }
            // Preserve CP-authoritative registry fields for an EXISTING member:
            // $monitoring AND $bio (set_bio is registry-only v1, §13-Q3 — host
            // truth must not revert it, C1). For a NEW (backfilled) child, seed
            // both from host truth.
            mon = ((existing == NIL) ?? "off" ; existing? $monitoring).
            bio = ((existing == NIL) ?? (c $bio) ; existing? $bio).
            persona = ((existing == NIL) ?? (c $persona) ; existing? $persona).
            if existing != NIL && ((existing? $name) != (c $name) || (existing? $role_id) != (c $role_id) || (_count (existing? $caps)|) != (_count (c $caps)|)) { changed -> changed + 1. }
            cluster_members cid -> ($cid -> cid, $role_id -> (c $role_id), $name -> (c $name),
                                    $bio -> bio, $persona -> persona, $monitoring -> mon, $caps -> (c $caps)).
        }
        // drop registry members no longer hosted.
        stale is global_id[] = [].
        sc cluster_members -- (cid -> _) { if (seen cid) == NIL { stale (_count stale|) -> cid. } }
        sc stale -- ( -> cid) { cluster_members cid -> NIL. }

        // Return a status record (count) so the daemon's mutatingTx await RESOLVES
        // immediately — a save-only trn emits no $data, so the await would block to
        // timeout while holding the root lock (serializing against inbound control,
        // WS-B E2E). $added/$dropped also give the daemon reconcile observability.
        out is transaction::action::type[] = [
            _ret ($ok -> TRUE, $added -> added, $dropped -> (_count stale|), $total -> (_count cluster_members|))
        ].
        if (added > 0 || (_count stale|) > 0 || changed > 0) { sc (_push_roster_actions NIL) -- ( -> a) { out (_count out|) -> a. } }
        out (_count out|) -> _save NIL.
        return transaction::success out.
    }

    // sweep_and_settle (§8 RR-3/R8-4): WS-B calls this AFTER a fresh reconcile (Option
    // 2), so the registry already reflects host truth. Settles every pending-req aged
    // past pending_req_ttl_seconds: create → adopt if the name now exists (a spawned-
    // but-register-lost child, just adopted by reconcile) else timeout; remove → success
    // if the cid is gone else timeout; contact → timeout (no invite arrived). Returns
    // [($target,$response)…] for the daemon to ship to each STORED controller. C7: an
    // expired create clears BOTH pending_reqs[handle] AND pending_create_names[name], so
    // a lost register can never leave the name permanently un-creatable.
    trn sweep_and_settle _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        now = (current_transaction_info::get_transaction_time())?.

        replies is any[] = [].
        expired is str[] = [].
        sc pending_reqs -- (handle -> pr)
        {
            if (_substract_seconds now (pr $date)) > pending_req_ttl_seconds
            {
                expired (_count expired|) -> handle.
                req_id = pr $req_id.
                verb = pr $verb.
                resp is a2a_capabilities::response_envelope_t = (_timeout_resp req_id "request timed out").
                if verb == "create"
                {
                    m = _find_by_name (pr $op_key).
                    if m != NIL { resp -> a2a_capabilities::build_response ($req_id -> req_id, $ok -> TRUE, $result -> (_member_view m?), $err -> (,)). }
                    else { resp -> (_timeout_resp req_id "provision timed out"). }
                }
                if verb == "remove"
                {
                    if (_present_cid_str (pr $op_key)) != TRUE { resp -> a2a_capabilities::build_response ($req_id -> req_id, $ok -> TRUE, $result -> ($removed -> TRUE), $err -> (,)). }
                    else { resp -> (_timeout_resp req_id "destroy timed out"). }
                }
                if verb == "contact" { resp -> (_timeout_resp req_id "invite mint timed out"). }
                replies (_count replies|) -> ($target -> (_str (pr $sender_id)), $response -> resp).
            }
        }
        // C7: clear expired pending-reqs AND, for creates, their global name op-key.
        sc expired -- ( -> h)
        {
            ph = pending_reqs h.
            if ph != NIL && (ph $verb) == "create" { pending_create_names (ph $op_key) -> NIL. }
            pending_reqs h -> NIL.
        }
        return transaction::success [ _ret ($settled -> replies), _save NIL ].
    }
}
