// Shared ours capabilities library (core 1.6).
//
// Makes CAPABILITIES a first-class protocol property. Every node advertises an
// app manifest (app_id + name + description + monitoring_status + a TYPED MAP
// of capabilities), and capability VERBS multiplex over the existing
// a2a_control transport via a {cap, verb, args, req_id} envelope. This library
// owns envelope parsing + dispatch: it routes an inbound envelope to the
// app-injected per-capability handler, so apps stop hand-parsing control JSON.
// Adding a capability = a new $cap id string — no wire-shape change.
//
// Layering: app_id (the cheap "WHO", core 1.5) stays on the a2a_control
// transport; the manifest is the richer pull (name/description live ONLY here,
// no double-sourcing). The per-capability $params and verb $args remain opaque
// JSON strings — that is what a dumb frontend renders (e.g. the config schema +
// value for core.configuration) — while the ROUTING (cap/verb) is typed.
//
// Transport-agnostic by design: dispatch operates on an already-parsed envelope
// RECORD. The consumer (or its daemon) adapts whatever a2a_control delivers
// (opaque JSON string today) into that record before calling dispatch.
library a2a_capabilities loads libraries
    current_transaction_info,
    version
    uses transactions
{
    // ---- well-known capability ids ---------------------------------------
    // Open id space: "core.*" is reserved for protocol capabilities, apps use
    // "app.*". A new capability is just a new id — no wire change. core.monitoring
    // is governance-required and auto-present on every node (see a2a_monitoring).
    cap_configuration = "core.configuration".
    cap_monitoring    = "core.monitoring".
    cap_connect       = "core.connect".
    cap_notifications = "core.notifications". // NaaS node surface (a2a_notifications.mm; NOTIFICATIONS_CONTRACT.md) — reserved id, no control verbs in v1.
    // core.cluster (core 2.3): promotes cluster/subagent management from private
    // a2a_messaging plumbing to a FIRST-CLASS, app-reusable capability. It owns
    // child/subagent lifecycle, per-child monitoring authorization, the host-local
    // contact book, and child<->contact + cross-cluster introductions, so ANY
    // root-managing app (messenger today, telegram proxy later) exposes the same
    // generic surface. Verbs stay convention (opaque $verb/$args, see
    // control_envelope_t) — this id only RESERVES the namespace and the contract
    // below blesses it; no wire/type/dispatch change. See CLUSTER_CONTRACT.md.
    //
    // VERB CONTRACT (verb -> reference handler / composition -> current wire alias).
    // Wire aliases are KEPT as-is (no hard rename); core.cluster is the documented
    // umbrella, "app.agents" remains a recognized alias for back-compat. NOTE:
    // CamelCase handlers (provisionIdentity/delegateRole/deleteIdentityCompletely/
    // setAgentMonitoring/connect_sibling/sign_monitoring_auth) are reference-host
    // (ours-mcp) DAEMON composites, NOT single core trns; snake_case names are
    // core a2a_messaging transactions. core.cluster blesses the VERB surface; the
    // consuming app/daemon owns the composition. (Verified vs real handlers, R7.)
    //   child.create   -> provisionIdentity + set_my_bio + delegateRole + best-effort enroll_delegated_node  (alias: create_agent)
    //   child.list     -> list_contact_roots / list_contacts (cluster filter)                                (alias: list_agents)
    //   child.set_bio  -> set_my_bio (child-scoped role label)                                               (alias: update_role)
    //   child.remove   -> deleteIdentityCompletely — FULL teardown (packet/disk/contact-book/binding)        (alias: remove_agent)
    //   child.set_monitoring -> setAgentMonitoring = connect_sibling + sign_monitoring_auth(root) + set_monitoring(role)  (alias: set_monitoring)
    //   contact.list   -> list_contacts                                                                      (host-local book)
    //   contact.add    -> generate_invite (returns an invite blob the caller redeems)                        (alias: contact_agent)
    //   contact.remove -> remove_contact                                                                     (host-local book)
    //   introduce.child_to_contact -> introduce                                                              (1:1 introduction)
    //   introduce.cross_cluster    -> introduce_to_group                                                     (cluster fan-out)
    //
    // GUARDRAILS (critic R6-3 / R6-5 / R7): core.cluster promotes MECHANISMS, NOT
    // POLICY. Policy knobs are APP PARAMS — stated as honest TARGETs, not as
    // already-current behavior:
    //   - local_auto_accept: RECOMMENDED safe default = false (introductions queue
    //     for operator approval). The reference host ours-mcp currently defaults
    //     TRUE (index.ts:1496,1541); flipping to false is a TRACKED OBLIGATION,
    //     not yet implemented.
    //   - child.set_monitoring child-visible notice: TARGET — authorizing per-child
    //     monitoring SHOULD surface a child-visible notice. Current code stores the
    //     root-signed monitoring_auth with NO notice; surfacing it is an obligation
    //     on the consuming app.
    //   - child.remove: DESTRUCTIVE — MUST be operator-confirmed. The reference
    //     frontend (messenger AgentNode) implements a confirm() dialog.
    // Tiered authz (observe < manage < create < destroy) is ROADMAP, not yet
    // enforced in core; today the app gates verbs. See CLUSTER_CONTRACT.md.
    // DISCOVERY: advertising core.cluster != having a manageable cluster.
    // describe() is static/shared, so EVERY identity (incl. leaf children with no
    // children) advertises it. A generic consumer (e.g. telegram-proxy) MUST
    // confirm an actual cluster via child.list (empty = none) before offering
    // child.create/child.remove. Benign for messenger (only bound roots show the
    // Cluster tab); a false-positive for capability-presence-keyed UIs.
    cap_cluster       = "core.cluster".
    // core 0.7.0 — message receipts (delivery + read), the emit/receive split
    // (COMPATIBILITY.md §receipts). PROTOCOL-surface ids with NO control verbs:
    // they gate receipt traffic (fail-CLOSED on absent caps — emitting to a
    // client that can't parse receipts is the incident class), never authz
    // (REG-6). Delivery-vs-read is the wire $kind, not a capability split.
    cap_receipts_emit    = "core.receipts.emit".    // "I WILL emit receipts (delivered on arrival, read on my get path)"
    cap_receipts_receive = "core.receipts.receive". // "I consume receipts — send me yours"

    // core 0.8.0 — end-to-end encryption (Olm double-ratchet signed-message
    // envelope). PROTOCOL-surface id with NO control verbs (cf. core.notifications):
    // "I speak the e2e_signed_message envelope and publish an AD v2 $e2e_bundle."
    // Gates E2E traffic + drives monotonic anti-downgrade (a2a_messaging::e2e_route);
    // never authz (REG-6). Crypto + session state live in the adapt `e2e` library.
    cap_e2e = "core.e2e".

    // core 0.9.0 — the per-connection E2E migration FSM (offer/ack/commit/confirm
    // + exactly-once bilateral key rotation, a2a_messaging §5). PROTOCOL-surface
    // id with NO control verbs, $advertise-carried: "I run the migration FSM."
    // Gates offer emission (fail-closed + pv self-heal, spec §5.4); never authz
    // (REG-6). SINGLE id, deliberately: migration has NO peer opt-out semantics —
    // a peer that doesn't want it simply never advertises/answers and legacy
    // continues untouched (so the receipts-style id PAIR is not needed here).
    cap_e2e_migrate = "core.e2e.migrate".

    // ---- secret-field sentinels (config dialect, core.configuration) ------
    // A secret field's VALUE is never echoed in plaintext: reads carry one of
    // these sentinels, and writes interpret them. "$needs_reentry" is the
    // load-bearing "no new party" guarantee — secrets auto-clear to it on any
    // control-plane change (evict/rebind) so they must be re-entered for the
    // new authority. The schema/value tree itself is opaque JSON in $params;
    // these are the shared constants the daemon (write/store) and frontend
    // (render redacted) agree on.
    secret_set           = "$set".
    secret_unset         = "$unset".
    secret_needs_reentry = "$needs_reentry".
    // Sentinel for a contact_ref field whose target is not yet a contact:
    // selecting it triggers core.connect for that target (the config <-> connect
    // hinge the telegram connector needs).
    contact_ref_connect  = "$connect".

    // ---- wire shapes ------------------------------------------------------
    // A secret field's redacted state, carried IN PLACE of its value — the value
    // is NEVER present in the manifest. $status is one of the $set / $unset /
    // $needs_reentry sentinels above; $epoch is the control-plane epoch the
    // stored secret was last written under. At manifest build the app derives
    // $status = $needs_reentry whenever $epoch is behind the node's current
    // control-plane epoch (any evict/rebind bumps it), so a secret entered for a
    // prior authority must be re-entered for the new one — the load-bearing
    // "no new party inherits live secrets" guarantee, now in the type system.
    metadef secret_field_t: ($status -> str, $epoch -> int).
    // First-class capability descriptor. $cap is the stable enumerable id (the
    // protocol property a dumb frontend keys off); $version is the per-capability
    // schema version; $params is the opaque per-capability JSON; $secrets is the
    // per-field redacted secret state, keyed by the field's path within $params'
    // schema. $secrets is value-less by construction: $params declares WHICH
    // fields are secret, $secrets carries only their status + epoch, so a secret
    // VALUE can never ride the manifest wire.
    metadef capability_t: ($cap -> str, $version -> int, $params -> str, $secrets -> (str ->> secret_field_t)).
    // The node's self-description. monitoring_status is a first-class manifest
    // field (governance-visible). $version is the manifest envelope version, bumped
    // whenever the manifest content changes so a controller knows to refetch.
    metadef app_manifest_t: (
        $version           -> int,
        $app_id            -> str,
        $name              -> str,
        $description       -> str,
        $monitoring_status -> str,
        $capabilities      -> (str ->> capability_t)
    ).
    // Capability verb envelope, carried as the a2a_control payload. All fields
    // are plain strings so it round-trips as JSON or as a native record; the
    // per-verb $args stays opaque JSON for the handler to interpret.
    // $args is a NATIVE value (R1): the daemon adapts the inbound JSON payload into
    // this record AND parses $args to native before dispatch — MUFL has no JSON
    // DECODER either, so a string $args would be unreadable by a handler. $cap/$verb/
    // $req_id stay plain strings (routing/correlation only).
    metadef control_envelope_t: ($cap -> str, $verb -> str, $args -> any, $req_id -> str).
    // Response envelope, shipped back as the a2a_control payload and correlated by
    // the controller on (sender,$req_id). $result/$err are NATIVE values (records/
    // arrays/strings), not pre-stringified JSON: MUFL has no JSON encoder, so a
    // handler returns this as transaction return_data and the daemon performs the
    // generic JSON marshalling at the transport boundary (no verb logic in TS).
    // $result present iff $ok; $err = ($code,$message) iff not. See CLUSTER_API.md §2.
    metadef response_envelope_t: ($req_id -> str, $ok -> bool, $result -> any, $err -> any).

    hidden
    {
        // App-injected: returns the node's CURRENT manifest (secrets already
        // redacted by the config capability). Fires on get_manifest.
        describe is (any -> app_manifest_t) = fn (_: any) -> app_manifest_t {
            abort "describe hook is unset in a2a_capabilities (call a2a_capabilities::init)." when TRUE.
            return ($version -> 0, $app_id -> "", $name -> "", $description -> "", $monitoring_status -> "off", $capabilities -> (,)).
        }
        // App-injected per-capability verb handlers, keyed by $cap id. Each
        // receives ($sender_id, $sender_name, $app_id, $verb, $args, $req_id,
        // $date) and returns the transaction actions (persist / notify / send a
        // response). A handler decides whether to process in-packet or enqueue.
        handlers is (str ->> (any -> transaction::action::type[])) = (,).
        // Fallback for an unknown / unhandled capability id.
        on_unknown is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { return []. }
        // App-injected STATEFUL authz gate (RR-9): wired to a2a_messaging::authorize_control
        // (which reads the bound monitoring_proxy — hidden there, a2a_capabilities cannot).
        // Receives ($sender_id,$cap,$verb), returns TRUE iff the sender may run it.
        // NIL until init wires it; dispatch FAIL-FASTS (abort) if a controller-class
        // verb is routed with this unset, so an app can never forget the gate.
        authorizer is (any -> bool)+ = NIL.
        // The static capability-id list captured from init's $supported — the
        // source for the 0.5.0 $caps wire piggyback (self_cap_ids below).
        // DELIBERATELY not derived through describe(): that hook aborts when
        // an app never wires capabilities, and the piggyback must degrade to
        // "advertises nothing" there, never abort an invite/restore leg.
        self_caps is str[] = [].
    }

    // FAIL-FAST: $supported is the static list of capability ids this app
    // implements; init aborts if any lacks a wired handler, so "declared" and
    // "implemented" can never drift. (Distinct from the dynamic describe(),
    // which reads live state at get_manifest time.)
    init = fn (_:(
        $describe   -> describe_cb: (any -> app_manifest_t),
        $supported  -> supported_caps: str[],
        $handlers   -> handler_map: (str ->> (any -> transaction::action::type[])),
        $on_unknown -> fallback: (any -> transaction::action::type[]),
        // RR-9: the stateful authz gate. OPTIONAL for back-compat — an app with no
        // controller-class verbs (e.g. the connector: only core.configuration via
        // its own path) may omit it. If omitted, dispatch fail-fasts on the first
        // controller-class verb, so a cluster app MUST wire it.
        $authorizer -> authorizer_cb: (any -> bool)+,
        // core 0.7.0, OPTIONAL (absent from pre-0.7 callers): PROTOCOL-surface
        // capability ids advertised on the wire piggyback WITHOUT control-verb
        // handlers (e.g. core.receipts.*). $supported keeps its declared-implies-
        // implemented handler guard; $advertise is for ids that gate peer
        // traffic shaping only and never route through dispatch.
        $advertise  -> advertise_list: str[]+
    ))
    {
        describe -> describe_cb.
        handlers -> handler_map.
        on_unknown -> fallback.
        if authorizer_cb != NIL { authorizer -> authorizer_cb. }
        merged is str[] = [].
        sc supported_caps -- ( -> cap) { merged (_count merged|) -> cap. }
        if advertise_list != NIL
        {
            sc advertise_list? -- ( -> cap) { merged (_count merged|) -> cap. }
        }
        self_caps -> merged.
        sc supported_caps -- ( -> cap)
        {
            abort "Capability declared without a handler: " + cap when (handler_map cap) == NIL.
        }
    }

    // Does THIS node advertise `cap` on the wire piggyback ($supported ∪
    // $advertise, captured at init)? Empty/uninited apps advertise nothing —
    // degrade, never abort (the self_cap_ids contract).
    fn self_advertises (cap: str) -> bool
    {
        found is bool = FALSE.
        sc self_caps -- ( -> c)
        {
            if c == cap { found -> TRUE. break. }
        }
        return found.
    }

    // The capability ids THIS node advertises on the 0.5.0 wire piggyback
    // ($caps in the invite/restore identity bundles, SPEC §4). Empty for an
    // app that never ran init — degrade, never abort (CAP-1 spirit).
    fn self_cap_ids (_) -> str[]
    {
        return self_caps.
    }

    // Append a PROTOCOL-surface ($advertise-class) capability id to the live self_caps at RUNTIME —
    // e.g. enable migration mid-session (cap_e2e_migrate) WITHOUT a restart, so the existing e2e
    // session is preserved (a restart re-keys the Olm ratchet). Idempotent (no duplicate). The next
    // outbound message's self_cap_ids piggyback carries it, so the peer re-learns and its
    // mig_should_trigger fires. Intended for $advertise-class ids (traffic-shaping, no control verb) —
    // NOT $supported ids (those require a wired handler, still enforced at init).
    fn add_self_cap (cap: str) -> nil
    {
        if (self_advertises cap) != TRUE { self_caps (_count self_caps|) -> cap. }
    }

    // ---- manifest helpers -------------------------------------------------
    fn has_capability (_:($manifest -> m: app_manifest_t, $cap -> cap: str)) -> bool
    {
        return (m $capabilities cap) != NIL.
    }

    fn get_capability (_:($manifest -> m: app_manifest_t, $cap -> cap: str)) -> capability_t+
    {
        return m $capabilities cap.
    }

    // The node's current live manifest (reads the app-injected describe hook).
    // Public fn accessor so a handler library (e.g. a2a_cluster's bind handler,
    // which returns {manifest,members,config}) can read it without the readonly
    // get_manifest trn (handlers run inside a trn and call fns, not trns).
    fn current_manifest (_) -> app_manifest_t
    {
        return describe NIL.
    }

    // Does THIS node's own live manifest advertise `cap`? Reads the app-injected
    // describe() hook (live state at call time) so another library — e.g.
    // a2a_messaging's ingest_connect_descriptor node-side gate — can enforce
    // "I only accept introductions if I actually support core.connect" without
    // reaching into the hidden describe field. describe is wired by init, which
    // every packet runs before serving, so it is set whenever this is reached.
    fn self_supports (cap: str) -> bool
    {
        return has_capability ($manifest -> describe NIL, $cap -> cap).
    }

    // ---- authorization policy (pure) + response builder -------------------
    // PURE policy table for the single pre-dispatch authz chokepoint
    // (CLUSTER_API.md §3). Returns the auth CLASS a (cap,verb) requires; it reads
    // NO state, so it lives here in the lowest layer. The STATEFUL gate
    // a2a_messaging::authorize_control combines this with the bound-proxy identity
    // (monitoring_proxy is hidden in a2a_messaging, which loads THIS library —
    // the dependency runs that way, not the reverse). FAIL-CLOSED: anything not
    // explicitly public/bootstrap returns "controller", so an unknown or typo'd
    // cap/verb is denied to strangers at the chokepoint before dispatch.
    //   "public"     — no auth; the get_manifest readonly trn only (no member data).
    //   "bootstrap"  — core.monitoring.bind only; auth is 6-digit code possession.
    //   "controller" — the bound control proxy; the explicit verbs below.
    //   "deny"       — anything not listed (RR-6 deny-all): a new verb must be
    //                  consciously classified here to become reachable.
    fn control_auth_class (_:($cap -> cap: str, $verb -> verb: str)) -> str
    {
        // NOTE (C6): get_manifest is NOT classified here — it is a standalone
        // `trn readonly` (get_manifest below), never routed through dispatch, so it
        // never reaches this table. The CLUSTER_API.md §3 "public" row documents the
        // get_manifest trn itself, not a (cap,verb) envelope.
        if cap == cap_monitoring && verb == "bind" { return "bootstrap". }
        if cap == cap_cluster && (verb == "list" || verb == "create" || verb == "set_bio"
            || verb == "set_persona"
            || verb == "remove" || verb == "set_monitoring" || verb == "contact"
            || verb == "introduce") { return "controller". }
        if cap == cap_monitoring && verb == "disable" { return "controller". }
        if cap == cap_connect && verb == "introduce" { return "controller". }
        if cap == cap_configuration && (verb == "get_config" || verb == "set_config") { return "controller". }
        return "deny".
    }

    // Build a response envelope (CLUSTER_API.md §2). $result/$err are NATIVE values
    // the handler assembles per verb; it is carried back as transaction return_data
    // and the daemon marshals it to JSON + ships — no in-MUFL JSON, no core send.
    fn build_response (_:(
        $req_id -> req_id: str, $ok -> ok: bool, $result -> result_val: any, $err -> err_val: any
    )) -> response_envelope_t
    {
        return ($req_id -> req_id, $ok -> ok, $result -> result_val, $err -> err_val).
    }

    // Build the return_data action carrying an error response_envelope (the daemon
    // marshals + ships it). Used by the dispatch authz chokepoint and handlers.
    fn deny_action (_:($req_id -> req_id: str, $code -> code: str, $message -> message: str)) -> transaction::action::type
    {
        return transaction::action::return_data (
            $kind -> $data,
            $payload -> build_response (
                $req_id -> req_id, $ok -> FALSE,
                $result -> (,), $err -> ($code -> code, $message -> message)
            )
        ).
    }

    // ---- dispatch ---------------------------------------------------------
    // Route a parsed capability envelope to its handler. The consumer wires this
    // into a2a_control's on_control_received (after adapting the opaque payload
    // into an envelope record). Unknown caps fall through to on_unknown.
    fn dispatch (_:(
        $sender_id   -> sender_id: global_id,
        $sender_name -> sender_name: str,
        $app_id      -> app_id: str,
        $envelope    -> env: any,
        $date        -> date: time
    )) -> transaction::action::type[]
    {
        cap    = (env $cap) safe str.
        verb   = (env $verb) safe str.
        args   = env $args.                                  // NATIVE (R1), handler interprets per verb
        req_id = ((env $req_id) == NIL ?? "" ; (env $req_id) safe str).

        // ---- RR-9 pre-route authz chokepoint (non-bypassable BY CONSTRUCTION) ----
        // The gate lives HERE, inside dispatch, so an app cannot wire routing while
        // forgetting the gate. deny/unauthorized are returned as a response_envelope
        // via return_data (the daemon marshals+ships); no in-MUFL JSON, no core send.
        klass = control_auth_class ($cap -> cap, $verb -> verb).
        if klass == "deny"
        {
            return [ deny_action ($req_id -> req_id, $code -> "unknown_verb", $message -> "verb not permitted: " + cap + "/" + verb) ].
        }
        if klass == "controller"
        {
            // FAIL-FAST (mirrors init's missing-handler abort): a controller verb must
            // never route without the stateful gate wired.
            abort "a2a_capabilities::dispatch routed a controller verb without an authorizer wired (pass $authorizer to init)." when authorizer == NIL.
            if (authorizer? ($sender_id -> sender_id, $cap -> cap, $verb -> verb)) != TRUE
            {
                return [ deny_action ($req_id -> req_id, $code -> "unauthorized", $message -> "sender is not the bound controller") ].
            }
        }
        // "public" + "bootstrap" fall through (bootstrap's own check is in the bind handler).

        ctx = (
            $sender_id   -> sender_id,
            $sender_name -> sender_name,
            $app_id      -> app_id,
            $verb        -> verb,
            $args        -> args,
            $req_id      -> req_id,
            $date        -> date
        ).

        handler = handlers cap.
        if handler == NIL
        {
            return on_unknown (
                $sender_id   -> sender_id,
                $sender_name -> sender_name,
                $app_id      -> app_id,
                $cap         -> cap,
                $verb        -> verb,
                $args        -> args,
                $req_id      -> req_id,
                $date        -> date
            ).
        }
        return handler? ctx.
    }

    // ---- manifest read ----------------------------------------------------
    // Pull the current manifest (for a controller / connecting peer). Readonly:
    // no state change. Secrets are already redacted by the app's describe().
    trn readonly get_manifest _
    {
        return describe NIL.
    }
}
