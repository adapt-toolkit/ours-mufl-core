// Shared ours messaging library.
//
// The contact + message wire path common to every ours client: identity
// profile (name/bio), invite generation/redemption, contact registry, the
// encrypted send/receive pair, and the export/import helpers for the shared
// state. Message STORAGE stays app-side — each consumer injects storage hooks
// via init (the agent keeps its inbox lifecycle, the messenger its per-contact
// history); this library handles wire + validation + contact resolution only.
//
// Routing: this library's transactions are addressed ::a2a_messaging::<name>.
// The four NETWORK-VISIBLE inbound names stay ::actor::* for compatibility
// with pre-migration clients (Option A): consumers keep one-line ::actor::
// delegating shims, and this library keeps SENDING to the ::actor:: names
// (the *_tx constants below). Drop both only when no old clients remain.
//
// Identity-hierarchy state (delegation_cert, root_ad, root_profile,
// contact_roots) lives HERE because generate_invite/add_contact read it; the
// hierarchy transactions themselves arrive in a2a_hierarchy.mm, which loads
// this library and shares this state.
//
// The contact/identity state is deliberately non-hidden: consumers (and
// a2a_hierarchy) read and assign it directly during the migration's transition
// steps. The EXCEPTION is the monitoring + config gate state (monitoring_proxy,
// proxy_pending, app_config), which is `hidden` so neither the app nor any other
// library can switch monitoring off or rewrite the stored config by assigning it
// directly — the "app can't override" guarantee. Its mutators (the bind ceremony,
// disable, set_app_config) therefore live in THIS library.
library a2a_messaging loads libraries
    address_document,
    address_document_types,
    key_utils,
    key_storage,
    current_transaction_info,
    encrypted_channel,
    a2a_versions,
    a2a_protocol,
    a2a_capabilities,
    version
    uses transactions
{
    // Network-visible inbound transaction names (embedded in what peers send).
    // Pre-migration clients listen on these, so the core keeps sending to them.
    accept_contact_tx = "::actor::accept_contact".
    receive_message_tx = "::actor::receive_message".
    // File transfer inbound (core 3.1). NEW surface, no legacy clients, so
    // LIBRARY-routed like submit_invite_response/complete_invite — no ::actor:: shim.
    receive_file_tx = "::a2a_messaging::receive_file".
    // Distinct inbound name on the control plane for a forced monitoring copy.
    // The CP-side receiver lives in a2a_monitoring; held as a literal so this
    // library keeps no code dependency on it (a2a_monitoring loads THIS library).
    receive_monitoring_copy_tx = "::a2a_monitoring::receive_monitoring_copy".
    // Node-side inbound for a control-plane introduction (core.connect): the CP
    // relays a peer's signed address document here. Library-routed (new surface,
    // no legacy clients), so introduce/introduce_to_group send to this literal.
    ingest_connect_descriptor_tx = "::a2a_messaging::ingest_connect_descriptor".
    // CP-side inbound for cluster enrollment (core 2.2): a root relays one of its
    // children's signed AD + delegation chain here so the CP can hold peer_ads for
    // the whole cluster off a single root bind. handle_enroll_delegated_node is the
    // receiver; relay_enroll_delegated_node (root side) sends to this literal.
    enroll_delegated_node_tx = "::a2a_messaging::enroll_delegated_node".
    // core 3.0 ephemeral-invite redeem legs. NEW surfaces (no legacy clients), so
    // both are LIBRARY-routed — no ::actor:: shim needed, unlike the pre-migration
    // names above. leg 1 (responder->inviter) is a BARE send carrying a box; leg 3
    // (inviter->responder) is ALSO a bare boxed send (NOT encrypted_channel — the
    // box to the responder's kept ephemeral key is the confidentiality/integrity).
    // See submit_invite_response / complete_invite below.
    submit_invite_response_tx = "::a2a_messaging::submit_invite_response".
    complete_invite_tx        = "::a2a_messaging::complete_invite".
    // contact-restore wire names (LIBRARY-routed, new surface — no ::actor:: shims).
    request_contact_restore_tx = "::a2a_messaging::request_contact_restore".
    submit_restore_response_tx = "::a2a_messaging::submit_restore_response".
    complete_restore_tx        = "::a2a_messaging::complete_restore".
    // core 0.7.0 receipts inbound (LIBRARY-routed, new surface, no legacy
    // listeners; reachable only behind positive core.receipts.* caps).
    receive_receipt_tx         = "::a2a_messaging::receive_receipt".

    // Version stamp of the portable export blob (see import_core_state for the
    // migration contract). Bump ONLY on a breaking blob-shape change, together
    // with a migration from the previous stamp.
    core_format_version = 1.
    // Give up re-requesting a restore after this many attempts per contact (the
    // host sweep re-fires on its GC cadence; a peer that upgraded and came back
    // online answers on the first post-upgrade attempt).
    restore_max_attempts = 30.
    // Per-contact cap on messages queued while its keys are being restored.
    deferred_msgs_cap = 50.

    // 6-digit bind ceremony limits (code is generated host-side — MUFL has no
    // random source — and handed to set_proxy_pending).
    proxy_code_max_age_seconds = 300.
    proxy_max_attempts = 3.

    // ---- shared packet state ---------------------------------------------
    // The display name peers see for me (set via set_my_name).
    my_name is str = "".
    // My profile bio (free-text, self-asserted; carried in role invites).
    my_bio is str = "".
    // My LOCAL operating contract. Adopted as the bound agent's persona ONLY with
    // the user's explicit consent (never silently). NEVER carried in invites; shared
    // only via the control-plane cluster registry (a2a_cluster set_persona).
    my_persona is str = "".
    // Known contacts, keyed by their container id.
    contacts is (global_id ->> a2a_protocol::contact_t) = (,).
    // core 0.5.0: passively learned peer wire dialects + capability ids
    // (SPEC §3/§4). Written on every inbound that carries version evidence
    // (last-seen wins); absent = nothing learned, 0 = pre-0.5 peer. $pv is
    // peer-asserted — these gate send-side feature selection and diagnostics,
    // NEVER authz (REG-6). Both maps are additive in the export blob and
    // guarded on import (pre-0.5 exports import unchanged).
    contact_pv is (global_id ->> int) = (,).
    contact_caps is (global_id ->> str[]) = (,).
    // core 3.0: invites I generated, keyed by invite id. Holds the NON-secret
    // per-invite material — the assigned contact name ("" = none), the ephemeral
    // encryption PUBLIC key shipped in the slim invite, and the crypto scheme id.
    // The matching ephemeral PRIVATE key lives in the hidden, non-exported
    // pending_invite_keys store (INV-4) and is consumed together on first redeem.
    metadef pending_invite_t: ($assigned -> str, $eph_pub -> publickey_encrypt, $scheme -> int).
    pending_invites is (global_id ->> pending_invite_t) = (,).
    // core 3.0: responder-side pending redemptions, keyed by invite id — who I am
    // redeeming, so leg 3 (complete_invite) can name the contact and pin the
    // expected inviter cid. No secrets; transient (not exported — outstanding
    // invites do not survive a restart; see the 3.0 release note).
    metadef pending_redemption_t: ($inviter_cid -> global_id, $inviter_name -> str, $custom_name -> str).
    pending_redemptions is (global_id ->> pending_redemption_t) = (,).
    // contact-restore (spec 2026-07-01): a DEGRADED contact is derivable state —
    // cid present in `contacts`, absent from `peer_ads` (e.g. a breaking-change
    // migration carried the contact but dropped its address document). These
    // stores drive the self-heal handshake; see request_contact_restore below.
    // Requester side, keyed by the TARGET cid. Non-secret half (the eph PRIVATE
    // key lives in the hidden pending_restore_keys, INV-4).
    metadef pending_restore_t: ($rid -> global_id, $eph_pub -> publickey_encrypt, $scheme -> int, $attempts -> int, $created -> time).
    pending_restores is (global_id ->> pending_restore_t) = (,).
    // Responder side, keyed by the REQUESTER cid — at most ONE outstanding reply
    // per requester (bounded by the contacts set; a newer request replaces it).
    metadef restore_reply_t: ($rid -> global_id, $scheme -> int, $created -> time).
    pending_restore_replies is (global_id ->> restore_reply_t) = (,).
    // Messages queued toward a degraded contact, flushed (host-driven,
    // flush_deferred) once its AD is re-established. Plain data — EXPORTED.
    metadef deferred_msg_t: ($text -> str, $wire_id -> str, $reply_to -> a2a_protocol::reply_ref_t+, $date -> time).
    deferred_msgs is (global_id ->> deferred_msg_t[]) = (,).
    // Peer address documents, captured when a contact is established. Self-
    // signed, code-independent, and seed-stable: import_core_state replays
    // them through address_document::process_address_document so encrypted
    // channels survive a code upgrade with no re-handshake. Only peer PUBLIC
    // keys travel here, never secrets.
    peer_ads is (global_id ->> address_document_types::t_address_document) = (,).
    // My delegation cert. NIL == I am a root or a legacy flat identity.
    delegation_cert is a2a_protocol::delegation_cert_t+ = NIL.
    // My root's address document (set with the cert; its key list is what
    // sibling introductions and my own cert are verified against).
    root_ad is address_document_types::t_address_document+ = NIL.
    // My root's self-signed profile, embedded in the invites I generate.
    root_profile is a2a_protocol::root_profile_t+ = NIL.
    // My root's §3c CP binding (root half), distributed to me by the host
    // (set_root_cp_binding) and carried beside root_profile in my invites so
    // peers can TOFU-pin my governance edge. NIL until a CP is bound.
    root_cp_binding is a2a_protocol::root_cp_binding_t+ = NIL.
    // Verified root linkage per contact, keyed by the contact's container id.
    contact_roots is (global_id ->> a2a_protocol::contact_root_t) = (,).
    // Peers' verified §3c root bindings, keyed by the ROOT's container id (one
    // edge per root, shared across its roles). Populated when a peer's invite or
    // introduction carries a binding that verifies against its root key list.
    contact_cp_bindings is (global_id ->> a2a_protocol::root_cp_binding_t) = (,).
    // CP SIDE: the set of ROOTS this control plane manages, keyed by the root's
    // container id (value is a presence marker). A child may be enrolled
    // (enroll_delegated_node) ONLY when the delegation chain it presents resolves
    // to a root in this set — the host asserts membership via manage_root when it
    // binds a root, so the cryptographic chain + this set together authorize a
    // cluster enrollment and forbid unsolicited ones. Empty on a non-CP node.
    managed_roots is (global_id ->> bool) = (,).
    // ---- forced monitoring + config types --------------------------------
    // FORCED monitoring lives HERE, in the chokepoint, because send_message /
    // handle_receive_message are the single path every app routes through —
    // monitoring copies are generated as UNCONDITIONAL core code (see
    // monitor_copy_actions). CRITICAL: the gate STATE (monitoring_proxy etc.) is
    // declared `hidden` below, so ONLY this library can mutate it — an app or any
    // other loading library cannot write `a2a_messaging::monitoring_proxy -> NIL`
    // to switch monitoring off. That is why the bind ceremony + disable + the
    // config writers all live IN THIS library (hidden state is mutable only by its
    // declaring library); a2a_monitoring keeps only the CP-side copy RECEIVER.
    //
    // One monitored message copy, re-encrypted to the bound control plane. The
    // source is the channel-authenticated envelope $from on the receiver, so it
    // is not carried in the body. (Types are public; only the STATE is hidden.)
    metadef monitoring_copy_t: (
        $version   -> int,
        $direction -> str,        // "out" (I sent) | "in" (I received)
        $peer_cid  -> global_id,
        $peer_name -> str,
        $date      -> time,
        $body      -> str
    ).
    metadef proxy_pending_t: ($code -> str, $proxy_cid -> global_id, $created_at -> time, $attempts -> int).
    metadef proxy_binding_t: ($proxy_cid -> global_id, $bound_at -> time).

    hidden
    {
        // ---- monitoring + config gate state (NON-app-writable) -----------
        // Hidden so only this library mutates it (the "app can't override"
        // guarantee). A pending 6-digit bind, and the verified control plane that
        // replaces it on success.
        proxy_pending    is proxy_pending_t+ = NIL.
        // The verified control plane: set ONLY by verify_proxy_code, cleared ONLY
        // by the CP-authenticated disable_monitoring (both in this library). It is
        // also the configuration authority for set_app_config.
        monitoring_proxy is proxy_binding_t+ = NIL.
        // Opaque, app-custom JSON config the TS wrapper owns; the core NEVER parses
        // it and bakes in NO policy semantics — per-application policy (e.g. anything
        // like "outgoing-only") is the application's job, implemented in the wrapper
        // from this blob. Written ONLY by the bound CP via set_app_config.
        app_config is str = "".

        // core 3.2 cluster roster push: monotonic sequence bumped on every real
        // roster change. Carried in each push and in the list/bind result so the CP
        // can order/dedup. No opt-in flag — push is gated only on monitoring_proxy.
        roster_push_seq is int = 0.

        // core 3.0: per-outstanding-invite ephemeral PRIVATE keys, keyed by invite id.
        // hidden ⇒ only this library mutates it AND it is structurally invisible to the
        // export record builder, but `hidden` governs VISIBILITY, not persistence — it
        // is deliberately NEVER added to export_core_state (INV-4: secrets must not ride
        // the portable export blob; empirically the SDK export serializer also corrupts
        // raw secret keys). Consumed (deleted) together with pending_invites[id] on the
        // first valid redemption. Outstanding entries do not survive a daemon restart.
        pending_invite_keys is (global_id ->> secretkey_encrypt) = (,).

        // core 3.0: RESPONDER-side per-redemption ephemeral PRIVATE keys, keyed by
        // invite id. The responder keeps its leg-1 ephemeral private key here so it
        // can OPEN the inviter's leg-3 reply (which is a bare send boxed to the
        // responder's ephemeral PUBLIC key — leg 3 cannot ride encrypted_channel
        // because the responder has not registered the inviter yet, and the stdlib
        // never exposes a raw long-term encryption privkey to box against instead).
        // Same INV-4 treatment as pending_invite_keys: hidden AND never exported;
        // consumed with pending_redemptions[id] on the leg-3 completion.
        pending_redemption_keys is (global_id ->> secretkey_encrypt) = (,).

        // contact-restore ephemeral PRIVATE keys — same INV-4 treatment as the
        // invite stores: hidden AND never exported; consumed with their public-half
        // records on the first valid completion. Requester side keyed by target cid,
        // responder side keyed by requester cid.
        pending_restore_keys is (global_id ->> secretkey_encrypt) = (,).
        pending_restore_reply_keys is (global_id ->> secretkey_encrypt) = (,).

        _read_or_abort is (bin->any) = fn (_: bin) { abort "_read_or_abort is unset in a2a_messaging (call a2a_messaging::init)." when TRUE. }

        // App-injected storage hooks. Each receives one record and returns the
        // transaction actions to append (storage writes + notify/save actions).
        //
        // on_message_received ($sender_id, $sender_name, $text, $date,
        //   $wire_id, $reply_to):
        //   $sender_name is NIL when the sender is NOT a known contact — the
        //   app decides what an unknown sender means (the agent checks its
        //   pending-introduction queue; a plain client aborts). $wire_id is the
        //   message's stable cross-side id ("" from pre-1.4 senders) and
        //   $reply_to is its optional reply pointer (NIL when not a reply).
        on_message_received is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_message_received hook is unset in a2a_messaging (call a2a_messaging::init)." when TRUE. return []. }
        // on_message_sent ($target_id, $text, $date, $wire_id, $reply_to):
        //   fired after the wire send is queued (agent: no-op; messenger:
        //   append "out" history, keyed by $wire_id so a peer's reply pointer
        //   resolves back to it). $reply_to is NIL unless this send is a reply.
        on_message_sent is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_message_sent hook is unset in a2a_messaging (call a2a_messaging::init)." when TRUE. return []. }
        // on_contact_removed ($container_id): fired after a contact is dropped
        //   (agent: no-op; messenger: delete that contact's history).
        on_contact_removed is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_contact_removed hook is unset in a2a_messaging (call a2a_messaging::init)." when TRUE. return []. }
        // on_file_received ($sender_id, $sender_name, $filename, $mime, $data,
        //   $date, $wire_id, $reply_to): the file analogue of on_message_received.
        //   $sender_name is NIL for an unknown sender; $mime is "" when omitted;
        //   $wire_id shares the message namespace; $reply_to is NIL unless a reply.
        on_file_received is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_file_received hook is unset in a2a_messaging (call a2a_messaging::init)." when TRUE. return []. }
        // on_file_sent ($target_id, $filename, $mime, $data, $date, $wire_id,
        //   $reply_to): fired after the wire send is queued (agent: no-op;
        //   messenger: append an outgoing file history entry keyed by $wire_id).
        on_file_sent is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_file_sent hook is unset in a2a_messaging (call a2a_messaging::init)." when TRUE. return []. }
        // on_receipt_received ($sender_id, $kind "delivered"|"read", $wire_ids
        //   str[], $date time+): a peer confirmed delivery/read of messages we
        //   sent (core 0.7.0 receipts). DEFAULT NO-OP — receipts are best-effort
        //   UX, never load-bearing; an app that doesn't wire the hook silently
        //   drops them. Hook contract (normative): application is MONOTONIC per
        //   (peer, wire_id) on unknown < sent < delivered < read — duplicates
        //   and out-of-order arrivals collapse to no-ops.
        on_receipt_received is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { return []. }
    }

    init = fn (_:(
        $_read_or_abort -> read: (bin->any),
        $on_message_received -> received_cb: (any -> transaction::action::type[]),
        $on_message_sent -> sent_cb: (any -> transaction::action::type[]),
        $on_contact_removed -> removed_cb: (any -> transaction::action::type[]),
        $on_file_received -> file_received_cb: (any -> transaction::action::type[]),
        $on_file_sent -> file_sent_cb: (any -> transaction::action::type[]),
        // core 0.7.0, OPTIONAL (absent from pre-0.7 callers): receipt consumer.
        $on_receipt_received -> receipt_cb: (any -> transaction::action::type[])+
    ))
    {
        _read_or_abort -> read.
        on_message_received -> received_cb.
        on_message_sent -> sent_cb.
        on_contact_removed -> removed_cb.
        on_file_received -> file_received_cb.
        on_file_sent -> file_sent_cb.
        if receipt_cb != NIL { on_receipt_received -> receipt_cb?. }
    }

    // ---- shared action builders -------------------------------------------
    // Signal the host to persist the packet. Only emitted at the end of a
    // complete procedure — intermediate states (e.g. channel handshake) are
    // never saved, so a crash mid-handshake restores to the last stable point.
    fn _save_state (_) = (transaction::action::return_data ($kind -> $save_state)).
    fn _return_data (payload: any) = (transaction::action::return_data ($kind -> $data, $payload -> payload)).
    fn _notify_agent (payload: any) = (transaction::action::return_data ($kind -> $notify_agent, $payload -> payload)).

    // ---- forced monitoring copy (UNCONDITIONAL core; see a2a_monitoring) ----
    // Uniform rule: if a control plane is bound, fire-and-forget ONE re-encrypted
    // copy of this message to it; otherwise nothing. No local queue and no
    // liveness wait — if the control plane is offline the ADAPT broker holds the
    // pending message (delivery is the framework's job, not the app's). The copy
    // rides a DISTINCT transaction name (receive_monitoring_copy), never
    // send_message, so the copy traffic is not itself monitored (no recursion).
    // Called unconditionally by send_message + handle_receive_message; it
    // self-gates on monitoring_proxy, which only the bind ceremony can set.
    fn monitor_copy_actions (direction: str, peer_cid: global_id, date: time, body: str) -> transaction::action::type[]
    {
        if monitoring_proxy == NIL { return []. }
        peer_name is str = "".
        p = contacts peer_cid.
        if p != NIL { peer_name -> p? $name. }
        copy is monitoring_copy_t = (
            $version   -> 1,
            $direction -> direction,
            $peer_cid  -> peer_cid,
            $peer_name -> peer_name,
            $date      -> date,
            $body      -> body
        ).
        // The control plane is a registered contact (the bind established its
        // channel), so this is a plain encrypted send action — ciphertext on the
        // wire under the control-plane key, never plaintext.
        return [
            encrypted_channel::send_encrypted_tx (monitoring_proxy? $proxy_cid) (
                $name -> receive_monitoring_copy_tx,
                $targ -> ($copy -> copy, $pv -> a2a_versions::wire_version)
            )
        ].
    }

    // core 3.2: generic fire-and-forget push to the bound control plane. Same rule
    // as monitor_copy_actions: self-gates on monitoring_proxy, rides a DISTINCT trn
    // name (so the push is not itself monitored), native record (no JSON).
    fn push_to_cp_actions (tx_name: str, targ: any) -> transaction::action::type[]
    {
        if monitoring_proxy == NIL { return []. }
        return [
            encrypted_channel::send_encrypted_tx (monitoring_proxy? $proxy_cid) (
                $name -> tx_name,
                $targ -> targ
            )
        ].
    }

    // Authorize a control-plane configuration write: the sender must BE the bound
    // control plane (monitoring_proxy). Config authority == the same CP that
    // monitoring is bound to. Aborts otherwise.
    fn require_bound_cp_or_abort (sender_id: global_id) -> nil
    {
        abort "No control plane is bound." when monitoring_proxy == NIL.
        abort "Only the bound control plane may configure this node." when sender_id != (monitoring_proxy? $proxy_cid).
    }

    // RR-9 single pre-dispatch authz gate (CLUSTER_API.md §3). The STATEFUL half:
    // a2a_capabilities holds the pure control_auth_class policy (it cannot read
    // monitoring_proxy — hidden HERE, and a2a_capabilities is the lower layer);
    // this fn combines that class with the bound-proxy identity. Wired into
    // a2a_capabilities::init as $authorizer, called by dispatch BEFORE routing any
    // controller-class verb. Returns TRUE iff the sender may run (cap,verb):
    //   public/bootstrap -> TRUE (bind's own 6-digit check is in its handler);
    //   deny             -> FALSE;
    //   controller       -> the sender must BE the bound control proxy.
    // Takes `any` (not a typed arg record) so it is DIRECTLY assignable to
    // a2a_capabilities::init's $authorizer field, which is (any -> bool): a typed
    // arg signature is not assignable there under function-arg contravariance, so
    // an app would otherwise need a wrapper. Extract the fields here instead.
    fn authorize_control (args: any) -> bool
    {
        cap = (args $cap) safe str.
        verb = (args $verb) safe str.
        klass = a2a_capabilities::control_auth_class ($cap -> cap, $verb -> verb).
        if klass == "public" || klass == "bootstrap" { return TRUE. }
        if klass == "deny" { return FALSE. }
        return monitoring_proxy != NIL && ((args $sender_id) safe global_id) == (monitoring_proxy? $proxy_cid).
    }

    // This node's ceremony-pinned cluster CP (its monitoring_proxy $proxy_cid), or
    // NIL if unbound. The cluster set_monitoring handler DERIVES the CP a child is
    // host-bound to from THIS — never a caller parameter (critic's load-bearing
    // condition): a child's monitoring_proxy is only ever set to the root's OWN
    // ceremony-pinned CP, so host-mediation cannot bind a child to an un-ceremonied
    // CP (which would be a developer-held-credential equivalent / ceremony bypass).
    fn bound_cp_cid (_) -> global_id+
    {
        if monitoring_proxy == NIL { return NIL. }
        return monitoring_proxy? $proxy_cid.
    }

    fn next_roster_seq (_) -> int { roster_push_seq -> roster_push_seq + 1. return roster_push_seq. }
    fn current_roster_seq (_) -> int { return roster_push_seq. }

    // Host-mediated REVOCATION of a CHILD's monitoring (origin::user, host-fired on
    // the child packet). CHILD-ONLY: aborts on a root/standalone (delegation_cert==NIL)
    // so the standalone "only the bound CP may disable" property is preserved —
    // cluster children's monitoring is host-propagated-from-the-root-ceremony, so the
    // root-operator (host-control posture, SECURITY-MODEL.md) revokes it. REAL
    // revocation (criterion e): clears monitoring_proxy so monitor_copy_actions stops
    // forwarding immediately. (Enable reuses set_proxy_pending+verify_proxy_code,
    // host-run on the child — no new bind path, ceremony pin preserved.)
    trn host_clear_child_monitoring _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        abort "host_clear_child_monitoring is cluster-children-only (a root/standalone node's monitoring is CP-cleared, not host-cleared)." when delegation_cert == NIL.
        // RR9-C12 full teardown (minimal-exposure): also DROP the CP contact that
        // host_register_monitoring_cp injected, so the child↔CP relationship does not
        // outlive the monitoring it was established for. Read the cp from monitoring_proxy
        // BEFORE clearing it. Re-enable cheaply re-injects via host_register_monitoring_cp.
        if monitoring_proxy != NIL
        {
            cp_cid = monitoring_proxy? $proxy_cid.
            peer_ads cp_cid -> NIL.
            contacts cp_cid -> NIL.
        }
        monitoring_proxy -> NIL.
        proxy_pending -> NIL.
        // Trivial ack so the daemon's mutatingTx await resolves immediately (a
        // save-only trn emits no $data → await blocks to timeout under the root lock).
        return transaction::success [ _return_data ($ok -> TRUE), _save_state NIL ].
    }

    // Host-mediated delivery of the cluster CP as a CONTACT to a CHILD packet
    // (origin::user, host-fired), so per-child monitoring can RESOLVE and FORWARD to
    // the CP. Why host-mediated, not a network introduce: the child's introduction
    // acceptance gate (ingest_connect_descriptor / require_cluster_cp_or_abort) only
    // accepts a relay FROM the child's own CP, so a ROOT-relayed introduce is rejected
    // (the root isn't the child's CP) AND a network introduce would race the ceremony.
    // The daemon, which hosts the child, injects the CP contact directly. SECURITY: the
    // CP AD is still VERIFIED here (process_address_document = self-sig + proof-of-
    // possession, aborts on a forged/inconsistent document), so a forged CP cannot be
    // injected. Stores peer_ads + a contacts entry so resolve_contact(cp) resolves and
    // monitor_copy_actions' encrypted send can establish the child->CP channel. Only the
    // host (origin::user) can call it; ordered by the daemon BEFORE the bind ceremony.
    trn host_register_monitoring_cp _:($cp_ad -> cp_ad: address_document_types::t_address_document)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        address_document::process_address_document cp_ad TRUE.
        cp_cid = cp_ad $identity $container_id.
        peer_ads cp_cid -> cp_ad.
        if (contacts cp_cid) == NIL { contacts cp_cid -> ($name -> "control-plane", $container_id -> cp_cid). }
        // Trivial ack so the daemon's mutatingTx await resolves immediately (save-only
        // → no $data → await blocks to timeout under the root lock).
        return transaction::success [ _return_data ($ok -> TRUE), _save_state NIL ].
    }

    // Authorize an introduction relay (core.connect) — ADDITIVE successor to
    // require_bound_cp_or_abort. A relay is accepted on EITHER of two grounds:
    //   (a) Legacy direct bind — this node ran the 6-digit ceremony itself, so the
    //       sender IS its own monitoring_proxy. Unchanged behaviour, non-breaking.
    //   (b) Inherited cluster CP — the sender is the CP my ROOT designated. The role
    //       binds nothing itself: it inherits root_cp_binding (the root-signed edge)
    //       and root_ad (the root's pinned keys), and verifies the edge LOCALLY, with
    //       no round-trip and no per-child ceremony.
    // Security (critic invariant #3): the inherited branch re-derives trust from the
    // pinned root_ad on EVERY call — verify_root_cp_binding does NOT check cid_cp, so
    // we (1) assert sender_id == root_cp_binding.cid_cp AND (2) verify the binding's
    // signature/context/root_cid against root_ad's OWN container id + key list (never
    // the cid_cp stored in the binding, never keys carried by the binding). A
    // signature-valid binding whose cid_cp is unpinned, or that verifies against the
    // wrong root keys, is rejected.
    fn require_cluster_cp_or_abort (sender_id: global_id) -> nil
    {
        // (a) legacy direct bind: short-circuit, leave the inherited path unevaluated.
        legacy_ok = monitoring_proxy != NIL && sender_id == (monitoring_proxy? $proxy_cid).
        if legacy_ok != TRUE
        {
            // (b) inherited cluster CP — require both the binding and the pinned root.
            abort "Unauthorized introduction relay: no bound control plane and no inherited root CP binding." when root_cp_binding == NIL || root_ad == NIL.
            // (1) the relay must come from the exact CP my root designated.
            abort "Unauthorized introduction relay: sender is not the CP my root designated." when sender_id != (root_cp_binding? $c $cid_cp).
            // (2) re-verify the root-signed edge against my pinned root identity every call.
            abort "Unauthorized introduction relay: root CP binding does not verify against my pinned root identity." when a2a_protocol::verify_root_cp_binding (root_cp_binding?) (root_ad? $identity $container_id) (root_ad? $identity $key_list) != TRUE.
        }
    }

    // Resolve a contact reference (a display name or stringified container id)
    // to a container id; aborts if no contact matches.
    fn resolve_contact (ref: str) -> global_id
    {
        found is global_id+ = NIL.
        sc contacts -- (cid -> c) ?? found == NIL && ((c $name) == ref || (_str cid) == ref)
        {
            found -> cid.
        }
        abort "Unknown contact: " + ref when found == NIL.
        return found?.
    }

    // ---- user transactions --------------------------------------------------

    trn set_my_name _:($name -> name: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        my_name -> name.
        return transaction::success [
            _return_data ($name -> name),
            _save_state NIL
        ].
    }

    trn set_my_bio _:($bio -> bio: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        my_bio -> bio.
        return transaction::success [
            _return_data ($bio -> bio),
            _save_state NIL
        ].
    }

    trn set_my_persona _:($persona -> persona: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        my_persona -> persona.
        return transaction::success [
            _return_data ($persona -> persona),
            _save_state NIL
        ].
    }

    // Host-fired (ROOT only, core 2.2): mint this root's §3c CP binding. The root
    // self-signs {context_tag, root_cid=me, cid_cp} so its roles can TOFU-pin "my
    // root designated CP X" and accept that CP's introductions locally. STATELESS and
    // root-only, mirroring sign_delegation: it returns the signed blob; the daemon
    // stores it on the root via set_root_cp_binding (own-identity verify) and pushes
    // the SAME blob to each role via set_root_cp_binding (root_ad verify). This is the
    // root-side PRODUCER core 2.1 deferred (it shipped only the verifier + store + the
    // accept gate); without it nothing could create the binding the cluster needs.
    trn sign_root_cp_binding _:($proxy -> proxy_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        abort "Only a root identity can mint a CP binding." when delegation_cert != NIL.

        cid_cp = resolve_contact proxy_ref.
        core is a2a_protocol::root_cp_binding_core_t = (
            $version     -> 1,
            $context_tag -> a2a_protocol::cp_attestation_context_tag,
            $root_cid    -> _get_container_id(),
            $cid_cp      -> cid_cp
        ).
        binding is a2a_protocol::root_cp_binding_t = ($c -> core, $s -> key_storage::default_sign (_value_id core)).
        return transaction::success [
            _return_data ($binding -> (_write binding), $cid_cp -> (_str cid_cp))
        ].
    }

    // Host-fired: store a root-signed CP binding for THIS node's root edge. DUAL-MODE
    // (core 2.2 widened the verify path — additive, rejects strictly more):
    //   • ROOT (delegation_cert == NIL): the binding is the root's OWN self-signed edge
    //     (sign_root_cp_binding above); verified against this node's own identity —
    //     unchanged from 2.1.
    //   • ROLE (delegation_cert != NIL): the binding is the root's edge INHERITED by the
    //     role; verified against the role's PINNED root_ad — the SAME keys and verifier
    //     the require_cluster_cp_or_abort accept gate uses, so a role can store only an
    //     edge its OWN root actually signed. This fills root_cp_binding (which the gate
    //     reads), letting a child accept CP introductions with zero per-child ceremony.
    // verify_root_cp_binding enforces, on the role path: (a) binding.root_cid == the
    // pinned root_ad's container id — an edge signed by ANY other root is rejected;
    // (b) the signature against root_ad's key list under the domain-separated context_tag,
    // which also covers (c) cid_cp integrity (cid_cp is inside the signed core record).
    // Fails CLOSED on any mismatch. The binding also rides the existing invite/state-push
    // paths (generate_invite $rpb, export/import_core_state).
    trn set_root_cp_binding _:($binding -> binding_blob: bin)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        binding = (_read_or_abort binding_blob) safe a2a_protocol::root_cp_binding_t.
        if delegation_cert != NIL
        {
            abort "Cannot inherit a root CP binding without pinned root material." when root_ad == NIL.
            abort "Inherited root CP binding does not verify against my pinned root identity." when a2a_protocol::verify_root_cp_binding binding (root_ad? $identity $container_id) (root_ad? $identity $key_list) != TRUE.
        }
        else
        {
            my_ad = address_document::get_my_address_document().
            abort "Root CP binding does not verify against this node's own root identity." when a2a_protocol::verify_root_cp_binding binding (my_ad $identity $container_id) (my_ad $identity $key_list) != TRUE.
        }
        root_cp_binding -> binding.
        return transaction::success [
            _return_data ($cid_cp -> _str (binding $c $cid_cp)),
            _save_state NIL
        ].
    }

    // ---- shared identity-bundle helpers (invite legs + contact-restore legs) ----
    // My identity bundle payload fields: my AD plus, when I am a delegated role,
    // my chain blobs (cert / root profile / optional §3c cp binding). The caller
    // appends its own correlation id ($invite_id or $rid) and _write's the record.
    fn my_identity_bundle_fields (_) -> ($ad -> address_document_types::t_address_document, $cert -> bin+, $root_profile -> bin+, $cp_binding -> bin+)
    {
        my_cert_blob is bin+ = NIL.
        my_rp_blob is bin+ = NIL.
        my_rpb_blob is bin+ = NIL.
        if delegation_cert != NIL && root_profile != NIL
        {
            my_cert_blob -> (_write delegation_cert?).
            my_rp_blob -> (_write root_profile?).
            if root_cp_binding != NIL { my_rpb_blob -> (_write root_cp_binding?). }
        }
        return ($ad -> address_document::get_my_address_document(), $cert -> my_cert_blob, $root_profile -> my_rp_blob, $cp_binding -> my_rpb_blob).
    }

    // ---- core 0.5.0 versioning helpers ---------------------------------------
    // Passive version learning (SPEC §3): record the peer's wire dialect (and
    // its advertised capability ids, when it piggybacked any) off an inbound
    // that carried version evidence. Guarded writes — state only mutates when
    // the learned value actually changes, so handlers that do not _save_state
    // are not left with silently divergent persistence.
    fn learn_contact_version (cid: global_id, pv: int, caps: str[]) -> nil
    {
        prev = contact_pv cid.
        if prev == NIL || prev? != pv { contact_pv cid -> pv. }
        if (_count caps|) != 0 { contact_caps cid -> caps. }
    }

    // Owner Addition B: the inviter-facing, render-ready message for a version-
    // incompatible invite second phase. Context-specific wording layered over
    // the registry's generic version_error_t (which rides beside it verbatim).
    fn invite_version_error_message (err: a2a_versions::version_error_t) -> str
    {
        if (err $code) == "peer_version_unsupported"
        {
            return "An invite you created was accepted by a peer running an unsupported (too old) protocol version (v" + (_str (err $peer_version)) + "; minimum supported is v" + (_str (err $min_supported)) + "). The contact was not added — ask them to update their client, then they can redeem the same invite again.".
        }
        return "An invite you created was accepted by a peer whose payload matches no supported protocol shape. The contact was not added — ask them to update their client, then they can redeem the same invite again.".
    }

    // ---- core 0.7.0 receipts (delivery + read confirmations) -----------------
    // Gate (BOTH kinds, one capability pair; polarity is deliberately the
    // OPPOSITE of CAP-1): emit iff THIS node advertises core.receipts.emit
    // (user policy, manifest-captured) AND the peer POSITIVELY advertises
    // core.receipts.receive in learned contact_caps. Absent/unknown caps =>
    // nothing is sent — emitting to a client that cannot parse receipts is the
    // incident class (undeliverable inbound). REG-6: never authz.
    // Does this caps list mention ANY receipts id (i.e. the peer's build is
    // receipts-aware and its advertisement is an EXPLICIT opinion)?
    fn caps_receipts_opinion (caps: str[]) -> bool
    {
        sc caps -- ( -> c)
        {
            if c == a2a_capabilities::cap_receipts_receive { return TRUE. }
            if c == a2a_capabilities::cap_receipts_emit { return TRUE. }
        }
        return FALSE.
    }
    fn caps_contains (caps: str[], cap: str) -> bool
    {
        sc caps -- ( -> c) { if c == cap { return TRUE. } }
        return FALSE.
    }

    // HYBRID GATE (stale-caps self-heal): capability ids are exchanged only on
    // invite/restore bundle legs, so a contact paired PRE-receipts keeps its
    // old caps forever unless re-paired — which froze receipts off for every
    // existing contact after the 0.7 update (owner-reported single-tick bug).
    // Rule: if the peer's learned caps express ANY receipts opinion, follow
    // them STRICTLY (preserves explicit emit/receive toggles); if they are
    // silent on receipts, imply `receive` from the peer's learned dialect
    // pv >= 7 — pv IS re-learned from every stamped ordinary message (ongoing
    // learning), and a pv>=7 peer is KNOWN to parse receive_receipt (the rcp
    // surface registered in 0.7). Old peers (pv < 7 / unknown) stay silent.
    // REG-6 holds: this shapes traffic, never authz.
    fn receipt_gate (peer: global_id) -> bool
    {
        if a2a_capabilities::self_advertises a2a_capabilities::cap_receipts_emit != TRUE { return FALSE. }
        caps = contact_caps peer.
        if caps != NIL && caps_receipts_opinion (caps?)
        {
            return caps_contains (caps?) a2a_capabilities::cap_receipts_receive.
        }
        pv = contact_pv peer.
        return pv != NIL && pv? >= 7.
    }

    // Build the receipt send (fire-and-forget over the established encrypted
    // channel; receipts always FOLLOW message traffic, so the channel exists).
    // Returns [] when gated off or nothing to confirm — callers append blindly.
    fn receipt_actions (peer: global_id, kind: str, wire_ids: str[]) -> transaction::action::type[]
    {
        if (_count wire_ids|) == 0 { return []. }
        if receipt_gate peer != TRUE { return []. }
        return [
            encrypted_channel::send_encrypted_tx peer (
                $name -> receive_receipt_tx,
                $targ -> (
                    $kind     -> kind,
                    $wire_ids -> wire_ids,
                    $date     -> (current_transaction_info::get_transaction_time())?,
                    $pv       -> a2a_versions::wire_version
                )
            )
        ].
    }

    // READ receipts ride the consumer's get/mark-read path: mufl readonly trns
    // cannot emit sends, so the consumer's (mutating) unread->read MARK is the
    // read event — it appends these actions for the ids it JUST transitioned,
    // which makes emission exact-once for free (no transition, no receipt).
    fn read_receipt_actions (sender_id: global_id, wire_ids: str[]) -> transaction::action::type[]
    {
        return receipt_actions sender_id "read" wire_ids.
    }

    // Sender-side expectation, DERIVED from learned caps (no wire traffic):
    // "expected" iff the peer positively advertises the emit capability, else
    // "unknown" — absence of a receipt is NEVER a failure state.
    // Same hybrid as the gate: explicit caps opinion wins; otherwise a
    // pv>=7 peer is expected to emit (its build does by default).
    fn receipt_expectation (cid: global_id) -> str
    {
        caps = contact_caps cid.
        if caps != NIL && caps_receipts_opinion (caps?)
        {
            return (caps_contains (caps?) a2a_capabilities::cap_receipts_emit ?? "expected" ; "unknown").
        }
        pv = contact_pv cid.
        if pv != NIL && pv? >= 7 { return "expected". }
        return "unknown".
    }

    // Verify a received identity bundle against the authenticated sender: D8
    // cid-bind + PoP self-sig (process_address_document aborts on a forged or
    // inconsistent document), then the OPTIONAL delegation chain (an invalid
    // chain aborts; a verifying §3c cp binding is STAGED in the returned record,
    // never written here — INV-5: the CALLER performs all registration writes
    // together after every gate has passed).
    metadef verified_bundle_t: ($ad -> address_document_types::t_address_document, $root -> a2a_protocol::contact_root_t+, $pin_binding -> a2a_protocol::root_cp_binding_t+, $pin_binding_root -> global_id+).
    fn verify_identity_bundle (payload: any, sender_id: global_id) -> verified_bundle_t
    {
        ad = (payload $ad) safe address_document_types::t_address_document.
        abort "Address document does not belong to the sender." when (ad $identity $container_id) != sender_id.
        address_document::process_address_document ad TRUE.
        peer_root is a2a_protocol::contact_root_t+ = NIL.
        pin_binding is a2a_protocol::root_cp_binding_t+ = NIL.
        pin_binding_root is global_id+ = NIL.
        if (payload $cert) != NIL
        {
            cert = (_read_or_abort ((payload $cert) safe bin)) safe a2a_protocol::delegation_cert_t.
            rp = (_read_or_abort ((payload $root_profile) safe bin)) safe a2a_protocol::root_profile_t.
            peer_root -> a2a_protocol::verify_peer_delegation sender_id (_value_id ad) cert rp.
            if (payload $cp_binding) != NIL
            {
                binding = (_read_or_abort ((payload $cp_binding) safe bin)) safe a2a_protocol::root_cp_binding_t.
                if a2a_protocol::verify_root_cp_binding binding (rp $p $root_cid) (rp $p $keys) == TRUE
                {
                    pin_binding -> binding.
                    pin_binding_root -> (rp $p $root_cid).
                }
            }
        }
        return ($ad -> ad, $root -> peer_root, $pin_binding -> pin_binding, $pin_binding_root -> pin_binding_root).
    }

    // core 3.0: mint a SLIM ephemeral-key invite assigned to `assigned` (empty
    // string = no assigned name). Reusable fn so BOTH generate_invite (user trn)
    // and the core.cluster `contact` verb (a2a_cluster, which relays the blob
    // OPAQUELY) share ONE construction path. Generates a fresh ephemeral encryption
    // keypair, registers its PUBLIC half (+ assigned name + scheme) in pending_invites
    // and its PRIVATE half in the hidden, non-exported pending_invite_keys store, and
    // emits ONLY {invite_id, inviter_cid, name, eph_pub, scheme} — no keys, no cert,
    // no root profile (those move to the encrypted two-message redeem hop). No role
    // branch: roles emit the same slim shape. Side effect: registers both stores; the
    // CALLER must emit _save_state. Returns the _write'd blob + its invite_id.
    fn mint_eph_invite (assigned: str) -> ($blob -> bin, $invite_id -> global_id)
    {
        scheme = _crypto_default_scheme_id().
        kp = _crypto_construct_encryption_keypair scheme.
        invite_id = _new_id "ours invite".

        pending_invites invite_id -> ($assigned -> assigned, $eph_pub -> (kp $public_key), $scheme -> scheme).
        pending_invite_keys invite_id -> (kp $secret_key).

        my_ad = address_document::get_my_address_document().
        invite is a2a_protocol::invite_eph_t = (
            $d -> invite_id,
            $c -> (my_ad $identity $container_id),
            $n -> my_name,
            $k -> (kp $public_key),
            $v -> scheme
        ).
        return ($blob -> (_write invite), $invite_id -> invite_id).
    }

    trn generate_invite _:($name -> name: str+)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        // Empty string is the "no assigned name" sentinel: accept_contact then
        // registers the joiner under its self-announced name instead.
        assigned = (name == NIL ?? "" ; name?).
        minted = mint_eph_invite assigned.
        return transaction::success [
            _return_data (
                $invite     -> (minted $blob),
                $invite_id  -> (minted $invite_id),
                $peer_name  -> assigned
            ),
            _save_state NIL
        ].
    }

    // core 3.0 LEG 1 (responder): redeem a slim ephemeral invite. Generate a
    // one-shot responder ephemeral keypair, BOX my identity bundle (AD + optional
    // role chain) to the invite's ephemeral pubkey, and BARE-send it to the inviter
    // — the inviter is not registered yet, so confidentiality/integrity come from
    // the box and authenticity from the cid-bind + PoP the inviter enforces at leg 2.
    // The contact is NOT final here: it is registered when the inviter's leg-3
    // complete_invite arrives (pending_redemptions remembers the chosen name +
    // expected inviter cid; pending_redemption_keys keeps my ephemeral PRIVATE key
    // so I can open the inviter's leg-3, which is boxed to my ephemeral pubkey — see
    // the leg-3 handler for why encrypted_channel cannot carry it). Disclosure order
    // flips vs the old fat invite — the responder discloses first — see
    // EPHEMERAL_INVITE_PLAN.md §2/§6.
    trn add_contact _:($invite -> invite_blob: bin, $name -> custom_name: str+)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        inv = (_read_or_abort invite_blob) safe a2a_protocol::invite_eph_t.
        inviter_cid = inv $c.
        abort "This invite is your own — you cannot add yourself." when inviter_cid == _get_container_id().
        invite_id = inv $d.
        inviter_name = inv $n.
        eph_pub_inviter = inv $k.
        scheme = inv $v.

        // Responder ephemeral keypair. The PUBLIC half travels (cleartext, beside
        // the box); the PRIVATE half is KEPT in pending_redemption_keys so I can open
        // the inviter's leg-3 reply (boxed to this pubkey). Forward secrecy for the
        // leg-1 "who is connecting" metadata; both halves are dropped at leg 3.
        kpr = _crypto_construct_encryption_keypair scheme.

        // My identity bundle: my AD plus, if I am a delegated role, my chain so the
        // inviter learns my root linkage symmetrically. All inside the box.
        b = my_identity_bundle_fields NIL.
        // The literal sir_payload_v5_t shape: 0.5.0 stamps its wire dialect +
        // capability ids (SPEC §3/§4). Pre-0.5 inviters ignore both (unknown
        // fields — shipped, proven behavior).
        payload = _write (
            $ad -> (b $ad),
            $cert -> (b $cert),
            $root_profile -> (b $root_profile),
            $cp_binding -> (b $cp_binding),
            $invite_id -> invite_id,
            $name -> my_name,
            $pv   -> a2a_versions::wire_version,
            $caps -> (a2a_capabilities::self_cap_ids NIL)
        ).
        data = _crypto_encrypt_message (kpr $secret_key) eph_pub_inviter payload.

        // Remember who I am redeeming (name + expected inviter cid; no secrets) and
        // KEEP my ephemeral private key (secret store) so leg 3 can be opened.
        contact_name = (custom_name == NIL ?? "" ; custom_name?).
        pending_redemptions invite_id -> ($inviter_cid -> inviter_cid, $inviter_name -> inviter_name, $custom_name -> contact_name).
        pending_redemption_keys invite_id -> (kpr $secret_key).

        // BARE send (NOT send_encrypted_tx): the inviter is not registered, so the
        // box is the protection. Established pattern, cf. encrypted_channel.mm:73.
        return transaction::success [
            transaction::action::send inviter_cid (
                $name -> submit_invite_response_tx,
                $targ -> (
                    $invite_id -> invite_id,
                    $epk -> (kpr $public_key),
                    $v -> scheme,
                    $data -> data,
                    $pv -> a2a_versions::wire_version
                )
            ),
            _return_data (
                $pending -> contact_name,
                $invite_id -> invite_id,
                $container_id -> inviter_cid,
                $inviter_name -> inviter_name,
                // PUBLIC ephemeral key (already on the wire in leg 1) — surfaced so a
                // caller can correlate the outstanding redemption; carries no secret.
                $resp_eph_pub -> (kpr $public_key)
            ),
            _save_state NIL
        ].
    }

    // Mint (or RE-mint) a restore request toward a degraded contact: fresh
    // ephemeral keypair + correlation id, REPLACING any outstanding attempt (the
    // superseded eph key makes a stale leg-1 reply fail both the rid check and
    // the unbox). Returns the bare signed send action (leg 0); #77 signs every
    // envelope, so the receiver authenticates us from the envelope alone. The
    // CALLER emits _save_state.
    fn begin_contact_restore (target: global_id) -> transaction::action::type[]
    {
        attempts is int = 0.
        prev = pending_restores target.
        if prev != NIL { attempts -> (prev? $attempts). }
        scheme = _crypto_default_scheme_id().
        kp = _crypto_construct_encryption_keypair scheme.
        rid = _new_id "ours restore".
        now = (current_transaction_info::get_transaction_time())?.
        pending_restores target -> ($rid -> rid, $eph_pub -> (kp $public_key), $scheme -> scheme, $attempts -> attempts + 1, $created -> now).
        pending_restore_keys target -> (kp $secret_key).
        return [
            transaction::action::send target (
                $name -> request_contact_restore_tx,
                $targ -> ($rid -> rid, $epk -> (kp $public_key), $v -> scheme, $pv -> a2a_versions::wire_version)
            )
        ].
    }

    // $reply_to is optional: when set, it points at the message this one
    // replies to (its stamped wire id + an optional sentence index). Every
    // message gets a fresh stringified wire id — the stable, cross-side handle
    // a reply can reference (the receiver's msg_id is local to its own inbox).
    trn send_message _:($contact -> contact_ref: str, $text -> text: str, $reply_to -> reply_to: a2a_protocol::reply_ref_t+)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        target_id = resolve_contact contact_ref.
        sent_date = (current_transaction_info::get_transaction_time())?.
        wire_id = _str (_new_id "ours message").

        // DEGRADED contact (known cid, no address document — e.g. a breaking-change
        // migration dropped peer_ads): queue the message and (re)issue a restore
        // request instead of failing the send. flush_deferred (host-driven, fired
        // on the $contact_restored notify) drains the queue once the peer's AD is
        // re-established.
        if (peer_ads target_id) == NIL
        {
            q is deferred_msg_t[] = [].
            cur = deferred_msgs target_id.
            if cur != NIL { q -> cur?. }
            abort "Deferred queue for this contact is full (" + (_str deferred_msgs_cap) + ") — contact restore still pending." when (_count q|) >= deferred_msgs_cap.
            q (_count q|) -> ($text -> text, $wire_id -> wire_id, $reply_to -> reply_to, $date -> sent_date).
            deferred_msgs target_id -> q.
            actions is transaction::action::type[] = begin_contact_restore target_id.
            actions (_count actions|) -> _return_data ($sent_to -> target_id, $wire_id -> wire_id, $deferred -> TRUE, $queued -> (_count q|)).
            actions (_count actions|) -> _save_state NIL.
            return transaction::success actions.
        }

        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            actions is transaction::action::type[] = [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> receive_message_tx,
                    $targ -> ($text -> text, $wire_id -> wire_id, $reply_to -> reply_to, $pv -> a2a_versions::wire_version)
                )
            ].
            sc on_message_sent ($target_id -> target_id, $text -> text, $date -> sent_date, $wire_id -> wire_id, $reply_to -> reply_to) -- ( -> a)
            {
                actions (_count actions|) -> a.
            }
            // FORCED: emit the outbound monitoring copy as core code, after the app
            // hook, so the app cannot suppress it (self-gates on monitoring_proxy).
            sc monitor_copy_actions "out" target_id sent_date text -- ( -> a)
            {
                actions (_count actions|) -> a.
            }
            actions (_count actions|) -> _return_data ($sent_to -> target_id, $text -> text, $wire_id -> wire_id).
            actions (_count actions|) -> _save_state NIL.
            return transaction::success actions.
        }).
    }

    // Metadata-only monitoring line for a file (NEVER the bytes): the bound control
    // plane learns that a file moved + its name/mime/size, nothing more. monitoring_
    // copy_t.$body stays str, so no copy-shape change.
    fn file_monitor_summary (filename: str, mime: str, data: bin) -> str
    {
        return "[file] " + filename + " (" + mime + ", " + (_str (_binlen data)) + " B)".
    }

    // File transfer (core 3.1): a separate transaction from send_message — files and
    // text are always distinct messages. Mirrors send_message exactly: a wire_id from
    // the SAME _new_id namespace (so a reply_to can cross between messages and files),
    // an optional reply_to, and the app-side on_file_sent storage hook. Both send_file
    // and handle_receive_file emit a forced metadata-only monitoring copy (name/mime/size).
    trn send_file _:($contact -> contact_ref: str, $filename -> filename: str, $mime -> mime: str+, $data -> data: bin, $reply_to -> reply_to: a2a_protocol::reply_ref_t+)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        target_id = resolve_contact contact_ref.
        // Files do NOT queue (bulk binary); fail fast with the real reason instead
        // of an opaque channel error. send_message toward this contact will queue
        // and drive the restore.
        abort "Contact \"" + contact_ref + "\" is awaiting key restore (degraded) — retry the file after a message to it is delivered." when (peer_ads target_id) == NIL.
        sent_date = (current_transaction_info::get_transaction_time())?.
        wire_id = _str (_new_id "ours file").
        mime_s is str = "".
        if mime != NIL { mime_s -> mime safe str. }

        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            actions is transaction::action::type[] = [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> receive_file_tx,
                    $targ -> ($filename -> filename, $mime -> mime_s, $data -> data, $wire_id -> wire_id, $reply_to -> reply_to, $pv -> a2a_versions::wire_version)
                )
            ].
            sc on_file_sent ($target_id -> target_id, $filename -> filename, $mime -> mime_s, $data -> data, $date -> sent_date, $wire_id -> wire_id, $reply_to -> reply_to) -- ( -> a)
            {
                actions (_count actions|) -> a.
            }
            // FORCED metadata-only monitoring copy (app cannot suppress; self-gates on
            // monitoring_proxy). Mirrors send_message's forced "out" copy.
            sc monitor_copy_actions "out" target_id sent_date (file_monitor_summary filename mime_s data) -- ( -> a)
            {
                actions (_count actions|) -> a.
            }
            actions (_count actions|) -> _return_data ($sent_to -> target_id, $filename -> filename, $wire_id -> wire_id).
            actions (_count actions|) -> _save_state NIL.
            return transaction::success actions.
        }).
    }

    trn remove_contact _:($contact -> contact_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        target_id = resolve_contact contact_ref.
        // Guard the monitoring invariant "monitoring_proxy != NIL ⇒ the proxy is a
        // registered contact": removing the bound control plane would leave a
        // dangling monitoring_proxy, so the next send_message's forced copy would
        // fire send_encrypted_tx at an unregistered peer and ABORT the user's send —
        // and disable_monitoring is CP-only, so with the CP gone there is no
        // recovery (all messaging bricked). Block the removal instead; this is NOT
        // an app-callable clear (removal is refused, monitoring is not switched off).
        abort "Cannot remove the bound control plane while monitoring is active — the control plane must disable monitoring first." when monitoring_proxy != NIL && target_id == (monitoring_proxy? $proxy_cid).
        removed = contacts target_id.
        removed_name = removed? $name.

        delete contacts target_id.
        if peer_ads target_id != NIL { delete peer_ads target_id. }
        if contact_roots target_id != NIL { delete contact_roots target_id. }

        // Contact-restore stores too: an orphaned deferred queue would persist in
        // every export and, on a later RE-ADD of the same peer, the boot/GC sweep
        // would silently deliver the stale queued messages.
        if (deferred_msgs target_id) != NIL { delete deferred_msgs target_id. }
        if (pending_restores target_id) != NIL { delete pending_restores target_id. }
        if (pending_restore_keys target_id) != NIL { delete pending_restore_keys target_id. }
        if (pending_restore_replies target_id) != NIL { delete pending_restore_replies target_id. }
        if (pending_restore_reply_keys target_id) != NIL { delete pending_restore_reply_keys target_id. }

        actions is transaction::action::type[] = [].
        sc on_contact_removed ($container_id -> target_id) -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        actions (_count actions|) -> _return_data ($removed -> removed_name, $container_id -> target_id).
        actions (_count actions|) -> _save_state NIL.
        return transaction::success actions.
    }

    trn readonly list_contacts _
    {
        return contacts.
    }

    trn readonly list_contact_roots _
    {
        return contact_roots.
    }

    // ---- monitoring bind ceremony (writes hidden gate state) -----------------
    // These live HERE, not in a2a_monitoring, because monitoring_proxy/proxy_pending
    // are hidden and hidden state is mutable only by its declaring library — that is
    // the enforcement of "no app/library can flip monitoring off by direct assignment."

    // Start a proxy binding (host-fired): remember the host-generated 6-digit code
    // for one specific contact (the control plane). Restart overwrites any pending.
    trn set_proxy_pending _:($code -> code: str, $proxy -> proxy_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        pid = resolve_contact proxy_ref.
        proxy_pending -> (
            $code       -> code,
            $proxy_cid  -> pid,
            $created_at -> (current_transaction_info::get_transaction_time())?,
            $attempts   -> 0
        ).
        return transaction::success [
            _return_data ($pending -> TRUE, $proxy_cid -> (_str pid)),
            _save_state NIL
        ].
    }

    // Verify a proxy's code attempt (host-fired when the control plane's bind
    // request arrives; $sender is the channel-authenticated control-plane id the
    // daemon relays). Failures are returned as DATA — not aborts — so the attempt
    // counter and expiry clearing PERSIST atomically; an abort would roll them back
    // and reopen the brute-force window. On success, binds monitoring_proxy.
    //
    // Trust boundary (asymmetry vs disable_monitoring, intentional): BIND is
    // user-origin and trusts the daemon to relay the true $sender — a hostile
    // DAEMON could sham-bind — the accepted self-assertion limitation (ours
    // monitoring design, MCP repo). The
    // "app can't override" guarantee is against the app PACKET, which cannot issue
    // user-origin transactions at all. DISABLE is external-direct (sender == $from).
    // Core of the 6-digit bind ceremony, SHARED by the verify_proxy_code trn (the
    // legacy direct entry) and the core.monitoring `bind` verb handler (a2a_cluster).
    // ONE ceremony definition — no divergence. Verifies `code` from `sid` against
    // proxy_pending; on success SETS monitoring_proxy (sid becomes the controller).
    // Mutates hidden gate state, so it MUST live here. Returns the outcome; the
    // caller emits _save_state. $attempts_left is meaningful only for "wrong_code".
    fn do_verify_proxy_code (code: str, sid: global_id) -> ($verified -> bool, $reason -> str, $attempts_left -> int)
    {
        if proxy_pending == NIL { return ($verified -> FALSE, $reason -> "no_pending", $attempts_left -> 0). }
        p = proxy_pending?.
        now = (current_transaction_info::get_transaction_time())?.

        if (_substract_seconds now (p $created_at)) > proxy_code_max_age_seconds
        {
            proxy_pending -> NIL.
            return ($verified -> FALSE, $reason -> "expired", $attempts_left -> 0).
        }
        if sid != (p $proxy_cid) { return ($verified -> FALSE, $reason -> "wrong_sender", $attempts_left -> 0). }
        if code != (p $code)
        {
            attempts = (p $attempts) + 1.
            if attempts >= proxy_max_attempts
            {
                proxy_pending -> NIL.
                return ($verified -> FALSE, $reason -> "too_many_attempts", $attempts_left -> 0).
            }
            proxy_pending -> ($code -> p $code, $proxy_cid -> p $proxy_cid, $created_at -> p $created_at, $attempts -> attempts).
            return ($verified -> FALSE, $reason -> "wrong_code", $attempts_left -> proxy_max_attempts - attempts).
        }
        monitoring_proxy -> ($proxy_cid -> sid, $bound_at -> now).
        proxy_pending -> NIL.
        return ($verified -> TRUE, $reason -> "ok", $attempts_left -> 0).
    }

    // Clear the monitoring binding if `sid` IS the bound proxy. Shared by the
    // core.monitoring `disable` verb handler. Returns TRUE iff disabled.
    fn do_disable_monitoring (sid: global_id) -> bool
    {
        if monitoring_proxy == NIL { return FALSE. }
        if sid != (monitoring_proxy? $proxy_cid) { return FALSE. }
        monitoring_proxy -> NIL.
        proxy_pending -> NIL.
        return TRUE.
    }

    trn verify_proxy_code _:($code -> code: str, $sender -> sender_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        sid = resolve_contact sender_ref.
        r = do_verify_proxy_code code sid.
        if (r $verified) == TRUE
        {
            return transaction::success [ _return_data ($verified -> TRUE, $proxy_cid -> (_str sid)), _save_state NIL ].
        }
        if (r $reason) == "wrong_code"
        {
            return transaction::success [ _return_data ($verified -> FALSE, $reason -> "wrong_code", $attempts_left -> (r $attempts_left)), _save_state NIL ].
        }
        return transaction::success [ _return_data ($verified -> FALSE, $reason -> (r $reason)), _save_state NIL ].
    }

    // Disable monitoring. CP-AUTHENTICATED: only the bound control plane may clear
    // the binding — EXTERNAL, encrypted, sender must BE the bound proxy. There is
    // deliberately no user-origin / app-callable clear.
    trn disable_monitoring _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        abort "Monitoring is not bound." when monitoring_proxy == NIL.
        abort "Only the bound control plane can disable monitoring." when sender_id != (monitoring_proxy? $proxy_cid).

        monitoring_proxy -> NIL.
        proxy_pending -> NIL.
        return transaction::success [
            _notify_agent ($event -> $monitoring_disabled, $cid -> sender_id),
            _save_state NIL
        ].
    }

    // Observable monitoring state (readonly). monitored == a control plane is bound.
    trn readonly get_monitoring_status _
    {
        pending is bool = FALSE.
        if proxy_pending != NIL { pending -> TRUE. }
        proxy_out is str = "".
        if monitoring_proxy != NIL { proxy_out -> _str (monitoring_proxy? $proxy_cid). }
        return (
            $monitored     -> (monitoring_proxy != NIL),
            $proxy_pending -> pending,
            $proxy_cid     -> proxy_out
        ).
    }

    // ---- control-plane configuration (CP-gated; see config state above) ------

    // Store the opaque app config blob pushed by the bound control plane after the
    // user fills the schema form on the CP frontend. CP-AUTHENTICATED: external,
    // encrypted, sender must be the bound control plane. The blob is opaque to the
    // core; a $config_updated notify wakes the wrapper, which pulls it via
    // get_app_config and applies the operational parts.
    fn handle_set_app_config (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        require_bound_cp_or_abort sender_id.

        app_config -> (args $config) safe str.
        return transaction::success [
            _notify_agent ($event -> $config_updated),
            _save_state NIL
        ].
    }

    trn set_app_config args: any
    {
        return handle_set_app_config args.
    }

    trn readonly get_app_config _
    {
        return ($config -> app_config).
    }

    // NOTE: the core intentionally stores ONLY the opaque app_config blob and bakes
    // in NO policy semantics. Per-application policy (e.g. "outgoing-only to a
    // contact") is application logic, implemented in the wrapper from its own custom
    // config schema — it is deliberately NOT a protocol feature (human ruling).

    // ---- cluster enrollment: managed roots (core 2.1) -------------------------
    // CP SIDE, host-fired: record that this control plane manages a root. The daemon
    // calls this when a root binds the CP (one call conveys the whole cluster — every
    // child of the root becomes enrollable). It is the authorization half of
    // enroll_delegated_node: a child enrolls only when its delegation chain resolves
    // to a root recorded here. Idempotent; the root id is supplied by the host (the CP
    // learns it from the root-bind it just completed), so no chain is verified at this
    // step — the cryptographic check happens per-child in enroll_delegated_node.
    trn manage_root _:($root_cid -> root_cid: global_id)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        managed_roots root_cid -> TRUE.
        return transaction::success [
            _return_data ($managed_root -> (_str root_cid)),
            _save_state NIL
        ].
    }

    // CP SIDE, external inbound: a root relays one of its children's signed address
    // document so the CP can hold peer_ads[child] WITHOUT the child binding the CP
    // itself — the receiver half of "one root bind conveys the whole cluster". The
    // child never participates here; the root presents the child's public material
    // (AD + delegation cert + root profile) it already holds via the delegation chain.
    //
    // Authorization is TWO independent checks, all required (delegation material is
    // semi-public, so possession must not equal authorization):
    //   (1) the channel-authenticated sender IS the root named in the delegation chain
    //       (the root relays its OWN children — no third-party relay of a valid chain),
    //   (2) verify_peer_delegation proves the child's container id AND its AD hash
    //       chain to that root, root-signed.
    // There is deliberately NO managed_roots authorization gate: a bound host's children
    // are introduceable by default once it advertises core.connect; the operator clicking
    // Introduce is the consent. Authenticity is still fully enforced by (1) + (2), so a
    // node can only ever enroll children it legitimately delegated.
    // Plus the child AD's own self-signature is re-checked (proof-of-possession). Any
    // failure aborts; nothing is stored. Idempotent: a re-enroll just refreshes the AD.
    fn handle_enroll_delegated_node (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.

        child_ad = (args $child_ad) safe address_document_types::t_address_document.
        child_cid = child_ad $identity $container_id.
        abort "Cannot enroll myself." when child_cid == _get_container_id().

        // Proof-of-possession: re-authorize the child's own self-signed document before
        // storing it (child_cid is key-derived, so an existing contact's keyset can
        // never be silently overwritten with a different one).
        address_document::process_address_document child_ad TRUE.

        cert = (_read_or_abort ((args $delegation_cert) safe bin)) safe a2a_protocol::delegation_cert_t.
        rp = (_read_or_abort ((args $root_profile) safe bin)) safe a2a_protocol::root_profile_t.

        // (3) Verify the delegation chain: binds child_cid AND _value_id(child_ad) to a
        // root, root-signed (aborts on any mismatch). Returns the verified root linkage.
        child_root = a2a_protocol::verify_peer_delegation child_cid (_value_id child_ad) cert rp.
        enroll_root_cid = child_root $root_cid.

        // (1) The relayer must BE that root — possession of a valid chain is not enough.
        abort "Only a node's own root may enroll it." when sender_id != enroll_root_cid.
        // (managed_roots authorization gate intentionally removed: a bound host's children
        // enroll by default; authenticity is enforced by (1) + verify_peer_delegation above.)

        // Idempotent re-enrollment: refresh the stored AD/linkage, keep the contact.
        if (contacts child_cid) != NIL
        {
            peer_ads child_cid -> child_ad.
            contact_roots child_cid -> child_root.
            return transaction::success [
                _notify_agent ($event -> $reenrolled, $container_id -> child_cid, $root_cid -> enroll_root_cid),
                _save_state NIL
            ].
        }

        // New cluster child: register under the verified role label (root_name/role_id
        // are advisory display strings; the AD self-signature is the only trusted id).
        contacts child_cid -> ($name -> (child_root $root_name) + "/" + (child_root $role_id), $container_id -> child_cid).
        peer_ads child_cid -> child_ad.
        contact_roots child_cid -> child_root.

        return transaction::success [
            _notify_agent ($event -> $enrolled, $container_id -> child_cid, $root_cid -> enroll_root_cid),
            _save_state NIL
        ].
    }

    trn enroll_delegated_node args: any
    {
        return handle_enroll_delegated_node args.
    }

    // Host-fired (ROOT side, core 2.2): relay one of my children's signed AD +
    // delegation chain to my bound control plane — the SEND that drives the CP's
    // handle_enroll_delegated_node inbound above, so a single root bind enrolls the
    // whole cluster. The root presents PUBLIC material it already holds via the
    // delegation chain it signed; the child never participates. This carries NO new
    // trust: it is an authenticated relay over my existing CP channel, and the CP
    // independently re-verifies the chain, that I am the child's root, and that it
    // manages me. Root-only here too (a role's relay would fail the CP's sender==root
    // check anyway). Payload matches handle_enroll_delegated_node field-for-field:
    // $child_ad is the AD VALUE; the cert + root profile ride as blobs (the receiver
    // _read_or_abort's them). The CP derives the "root_name/role_id" display label from
    // the cert's role_id + the root profile's name — no name field is carried here.
    trn relay_enroll_delegated_node _:($proxy -> proxy_ref: str, $child_ad -> child_ad_blob: bin, $delegation_cert -> cert_blob: bin, $root_profile -> rp_blob: bin)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        abort "Only a root identity can relay a cluster enrollment." when delegation_cert != NIL.

        cp_cid = resolve_contact proxy_ref.
        child_ad = (_read_or_abort child_ad_blob) safe address_document_types::t_address_document.
        return encrypted_channel::execute_transaction cp_cid (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx cp_cid (
                    $name -> enroll_delegated_node_tx,
                    $targ -> ($child_ad -> child_ad, $delegation_cert -> cert_blob, $root_profile -> rp_blob, $pv -> a2a_versions::wire_version)
                ),
                _return_data ($enroll_relayed -> (_str cp_cid), $child -> (_str (child_ad $identity $container_id)))
            ].
        }).
    }

    // ---- control-plane introduction: core.connect ----------------------------
    // The control plane, bound to BOTH parties, introduces two nodes that are not
    // yet in each other's contacts. The CP already holds each managed node's peer-
    // signed address document (captured in peer_ads when the node bound the CP), so
    // an introduction is simply: send each node the OTHER's signed AD. The receiving
    // node verifies the AD's own self-signature (proof-of-possession), checks the
    // relay came from its bound CP, checks its OWN manifest still advertises
    // core.connect, and registers the contact immediately. No SAS, no confirmation
    // step, no CP signature on the introduction — the bound-CP channel IS the
    // authorization, and the node-side capability gate is the authoritative "do I
    // accept introductions". The CP-side manifest pre-check (refuse to introduce a
    // node whose app does not support it) is the daemon's job: it pulls get_manifest
    // for each target before calling introduce.

    // Pure helper: the two bare encrypted sends that make up one introduction — node
    // A receives B's address document (+ B's CP-supplied display name) and node B
    // receives A's. Bare send_encrypted_tx is sound here because both channels are
    // already established (each node bound the CP), so no execute_transaction
    // handshake is needed; the caller guards peer_ads presence before emitting.
    fn emit_pair (
        a_id: global_id, ad_a: address_document_types::t_address_document, name_a: str,
        b_id: global_id, ad_b: address_document_types::t_address_document, name_b: str
    ) -> transaction::action::type[]
    {
        return [
            encrypted_channel::send_encrypted_tx a_id (
                $name -> ingest_connect_descriptor_tx,
                $targ -> ($peer_ad -> ad_b, $peer_name -> name_b, $pv -> a2a_versions::wire_version)
            ),
            encrypted_channel::send_encrypted_tx b_id (
                $name -> ingest_connect_descriptor_tx,
                $targ -> ($peer_ad -> ad_a, $peer_name -> name_a, $pv -> a2a_versions::wire_version)
            )
        ].
    }

    // The display name the CP advertises for a managed node when introducing it: the
    // CP's own contact label, falling back to the stringified container id. This is
    // unauthenticated by design (a receiver-chosen display string); the AD self-
    // signature is the only authenticated identity the receiver actually trusts.
    fn introduce_name (cid: global_id) -> str
    {
        if (contacts cid) != NIL { return (contacts cid)? $name. }
        return _str cid.
    }

    // CP SIDE: introduce two managed nodes to each other (host-fired). Both must be
    // established contacts of the CP (peer_ads holds their signed ADs). The manifest
    // "supports introductions" pre-check is the daemon's job (it pulls get_manifest
    // for each before calling this); the node-side gate in ingest_connect_descriptor
    // is the authoritative enforcement. Emits both relays in one transaction.
    trn introduce _:($peer_a -> ref_a: str, $peer_b -> ref_b: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        a_id = resolve_contact ref_a.
        b_id = resolve_contact ref_b.
        abort "Cannot introduce a node to itself." when a_id == b_id.

        ad_a = peer_ads a_id.
        abort "First node is not an established contact (no stored address document)." when ad_a == NIL.
        ad_b = peer_ads b_id.
        abort "Second node is not an established contact (no stored address document)." when ad_b == NIL.

        actions is transaction::action::type[] = emit_pair a_id ad_a? (introduce_name a_id) b_id ad_b? (introduce_name b_id).
        actions (_count actions|) -> _return_data ($introduced -> ($peer_a -> (_str a_id), $peer_b -> (_str b_id))).
        return transaction::success actions.
    }

    // CP SIDE: introduce one joiner to every member of a group (cluster-root fan-out,
    // e.g. a new subagent under a cluster root). For each member it emits the same
    // pair of relays as introduce(joiner, member). All targets must be established
    // contacts. O(members) bare sends in a single transaction.
    trn introduce_to_group _:($joiner -> joiner_ref: str, $members -> member_refs: str[])
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        j_id = resolve_contact joiner_ref.
        ad_j = peer_ads j_id.
        abort "Joiner is not an established contact (no stored address document)." when ad_j == NIL.
        j_name = introduce_name j_id.

        actions is transaction::action::type[] = [].
        introduced is str[] = [].
        sc member_refs -- ( -> mref)
        {
            m_id = resolve_contact mref.
            abort "Cannot introduce the joiner to itself." when m_id == j_id.
            ad_m = peer_ads m_id.
            abort "A group member is not an established contact (no stored address document)." when ad_m == NIL.
            sc emit_pair j_id ad_j? j_name m_id ad_m? (introduce_name m_id) -- ( -> act)
            {
                actions (_count actions|) -> act.
            }
            introduced (_count introduced|) -> (_str m_id).
        }
        actions (_count actions|) -> _return_data ($joiner -> (_str j_id), $introduced -> introduced).
        return transaction::success actions.
    }

    // Ingest a peer's signed address document relayed by my control plane (core.connect).
    // Authorization model (radically simple): the relay must come from my bound CP
    // (require_bound_cp_or_abort) AND this node must itself advertise core.connect (the
    // node-side capability gate — the authoritative "I accept introductions"). The AD
    // carries its own self-signatures, re-checked by process_address_document (proof-of-
    // possession; aborts on a forged/inconsistent document). No SAS, no CP signature, no
    // confirmation step — the contact is established immediately. The CP-supplied
    // $peer_name is an unauthenticated display label.
    fn handle_ingest_connect_descriptor (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        // The relay must come from a CP authorized for me — EITHER one I bound directly
        // (legacy 6-digit ceremony) OR one my root designated and I inherited (core 2.1
        // cluster CP, verified locally against my pinned root_ad). Additive: the legacy
        // direct-bind path is unchanged.
        require_cluster_cp_or_abort sender_id.
        // Node-side capability gate (authoritative): refuse unless my OWN live manifest
        // advertises core.connect. Without this the manifest boolean would be a pure
        // CP-side courtesy rather than enforced.
        abort "This node does not support introductions (core.connect not in its manifest)." when a2a_capabilities::self_supports a2a_capabilities::cap_connect != TRUE.

        peer_ad = (args $peer_ad) safe address_document_types::t_address_document.
        peer_cid = peer_ad $identity $container_id.
        abort "Cannot introduce me to myself." when peer_cid == _get_container_id().

        // Proof-of-possession: re-authorize the peer's own self-signed document before
        // storing it (idempotent; peer_cid is key-derived, so an existing contact's keys
        // can never be silently overwritten with a different keyset).
        address_document::process_address_document peer_ad TRUE.

        // Idempotent re-introduction: if peer_cid is already a contact, just refresh the
        // stored AD and keep the existing name — never clobber it or re-notify as new.
        if (contacts peer_cid) != NIL
        {
            peer_ads peer_cid -> peer_ad.
            return transaction::success [
                _notify_agent ($event -> $reintroduced, $container_id -> peer_cid, $by_cp -> sender_id),
                _save_state NIL
            ].
        }

        // New contact: register under the CP-supplied display name (cid as last resort).
        peer_name is str = "".
        if (args $peer_name) != NIL { peer_name -> (args $peer_name) safe str. }
        contact_label is str = (peer_name == "" ?? (_str peer_cid) ; peer_name).
        contacts peer_cid -> ($name -> contact_label, $container_id -> peer_cid).
        peer_ads peer_cid -> peer_ad.

        return transaction::success [
            _notify_agent ($event -> $introduced, $container_id -> peer_cid, $name -> contact_label, $by_cp -> sender_id),
            _save_state NIL
        ].
    }

    trn ingest_connect_descriptor args: any
    {
        return handle_ingest_connect_descriptor args.
    }

    // The shared-core version this packet was compiled with (see version.mm).
    trn readonly get_version _
    {
        return ($core -> version::get_core_version()).
    }

    // ---- external (inbound) transactions ------------------------------------
    // Each inbound transaction's body is an exported handle_* fn so consumers'
    // ::actor:: compat shims (Option A) delegate to the exact same code path —
    // the stdlib trn-delegates-to-fn pattern (see address_document::handshake_init).

    // Args are taken as `any` (not a destructured shape) so old clients — whose
    // accept_contact payload has no hierarchy fields — keep working unchanged.
    fn handle_accept_contact (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.

        // --- 0.5.0 registry gate (acc) — BEFORE any strict read of the args.
        // The legacy redeem sibling of the sir gate: a version-incompatible
        // payload surfaces to the inviter as error-as-data (Addition A/B),
        // never an abort; the invite is NOT consumed.
        nr = a2a_versions::try_narrow_acc args.
        if (nr $ok) != TRUE
        {
            err = (nr $err)?.
            return transaction::success [
                _notify_agent (
                    $event     -> $protocol_error,
                    $context   -> $invite_redeem,
                    $message   -> invite_version_error_message err,
                    $error     -> err,
                    $invite_id -> (args $invite_id),
                    $peer_cid  -> sender_id
                )
            ].
        }
        narrowed is a2a_versions::acc_args_t = (nr $payload)?.

        invite_id = (args $invite_id) safe global_id.
        joiner_ad = (args $joiner_ad) safe address_document_types::t_address_document.

        // Only an invite I generated (and have not yet consumed) authorizes a
        // contact registration. Without this gate any invite blob would be a
        // multi-use bearer credential: anyone who ever saw one could register
        // themselves as my contact with a self-chosen name.
        // core 3.0: pending_invites is now a pending_invite_t record map; the
        // assigned name is its $assigned field. (This legacy accept path is removed
        // in M2 with the rest of the old redeem flow.)
        invite_rec = pending_invites invite_id.
        abort "Unknown or already-redeemed invite." when invite_rec == NIL.
        // D8: joiner_ad is attacker-supplied. Bind it to the channel-authenticated
        // sender and prove it is the joiner's OWN self-signed document before we
        // store it as the peer's identity. The cid gate stops a redeemer from
        // registering SOMEONE ELSE's address document under this contact, and
        // process_address_document re-authorizes the self-signatures (it aborts on
        // a forged/inconsistent document).
        abort "Address document does not belong to the sender." when (joiner_ad $identity $container_id) != sender_id.
        address_document::process_address_document joiner_ad TRUE.
        // An empty assigned name means the invite was generated without one:
        // the joiner's self-announced name wins (container id as a last resort
        // when the joiner never set a name either).
        contact_name is str = (invite_rec?) $assigned.
        if contact_name == ""
        {
            // REGISTRY DISPATCH replaces the strict $joiner_name read (the
            // sir incident's hygiene sibling): v3 returns the sent name; v2
            // has no such field and falls back to the sender cid.
            joiner_self = a2a_versions::acc_joiner_name narrowed.
            contact_name -> (joiner_self == "" ?? (_str sender_id) ; joiner_self).
        }

        // A delegated-role joiner carries its chain so I learn its root linkage
        // symmetrically; an invalid chain rejects the redemption outright.
        joiner_root is a2a_protocol::contact_root_t+ = NIL.
        if (args $joiner_cert) != NIL
        {
            cert = (_read_or_abort ((args $joiner_cert) safe bin)) safe a2a_protocol::delegation_cert_t.
            rp = (_read_or_abort ((args $joiner_root_profile) safe bin)) safe a2a_protocol::root_profile_t.
            joiner_root -> a2a_protocol::verify_peer_delegation sender_id (_value_id joiner_ad) cert rp.
            // §3c symmetric: pin the joiner's root binding if it carries one and
            // verifies against its root key list. Non-enforcing — a bad/absent
            // binding never rejects the redemption.
            if (args $joiner_cp_binding) != NIL
            {
                binding = (_read_or_abort ((args $joiner_cp_binding) safe bin)) safe a2a_protocol::root_cp_binding_t.
                if a2a_protocol::verify_root_cp_binding binding (rp $p $root_cid) (rp $p $keys) == TRUE
                {
                    contact_cp_bindings (rp $p $root_cid) -> binding.
                }
            }
        }

        contacts sender_id -> ($name -> contact_name, $container_id -> sender_id).
        // Passive version learning: this legacy surface never carries $pv or
        // $caps — record the shape-inferred dialect (2 or 3).
        learn_contact_version sender_id (a2a_versions::acc_version_of args) [].
        // Remember the joiner's address document for upgrade-time re-registration.
        peer_ads sender_id -> joiner_ad.
        if joiner_root != NIL
        {
            contact_roots sender_id -> joiner_root?.
        }
        delete pending_invites invite_id.

        return transaction::success [
            _notify_agent ($event -> $contact_accepted, $name -> contact_name, $container_id -> sender_id),
            _save_state NIL
        ].
    }

    trn accept_contact args: any
    {
        return handle_accept_contact args.
    }

    // core 3.0 LEG 2 (inviter): a responder redeemed my slim invite. The body is a
    // BARE inbound carrying a box, so this is the ONE inbound that intentionally
    // SKIPS check_encrypted_or_abort — confidentiality/integrity come from the box,
    // authenticity from the cid-bind + PoP below. INV-5: NO contact/peer_ads/
    // contact_roots write happens before ALL gates pass (lookup -> decrypt ->
    // cid-bind -> PoP -> chain). Single-use: the first valid leg-2 consumes BOTH
    // pending_invites AND pending_invite_keys; a failed gate consumes nothing.
    fn handle_submit_invite_response (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        invite_id = (args $invite_id) safe global_id.

        // --- gates (no state mutation until all pass) ---
        // single-use lookup: the invite must be one I minted and not yet redeemed.
        rec = pending_invites invite_id.
        abort "Unknown or already-redeemed invite." when rec == NIL.
        eph_priv = pending_invite_keys invite_id.
        abort "Invite ephemeral key missing (already consumed or not persisted)." when eph_priv == NIL.

        epk_r = (args $epk) safe publickey_encrypt.
        ct = (args $data) safe crypto_message.
        // box-open: aborts on tamper / wrong key BEFORE anything is consumed.
        payload = _read_or_abort (_crypto_decrypt_message eph_priv? epk_r ct).

        // --- 0.5.0 registry gate (BEFORE any strict read of the payload) ---
        // Dispatch on the peer's wire version and exact-cast to the registered
        // type (REG-4). A below-floor or unrecognized payload is the owner's
        // Addition A/B case: return the ERROR AS DATA to the INVITER via a
        // $protocol_error notify — transaction::success, NO abort, NO state
        // consumed (the invite stays redeemable: the peer can update and
        // redeem this same invite again). Crypto/tamper failures above and
        // identity-verification failures below remain HARD aborts by design.
        nr = a2a_versions::try_narrow_sir payload.
        if (nr $ok) != TRUE
        {
            err = (nr $err)?.
            return transaction::success [
                _notify_agent (
                    $event     -> $protocol_error,
                    $context   -> $invite_redeem,
                    $message   -> invite_version_error_message err,
                    $error     -> err,
                    $invite_id -> invite_id,
                    $peer_cid  -> sender_id
                )
            ].
        }
        // `narrowed` is union-typed: backward compat is visible in this
        // binding's type; per-version reads go through the registry accessors.
        narrowed is a2a_versions::sir_payload_t = (nr $payload)?.

        // Identity verification takes the RAW payload: narrow() rebuilds the
        // record to the registered fields, and verify must keep seeing exactly
        // what was sent (also future-proof for fields newer than we know).
        // D8 cid-bind + PoP self-sig, then the optional delegation chain — an
        // invalid chain or forged/inconsistent AD aborts before any write.
        vb = verify_identity_bundle payload sender_id.

        // --- all gates passed: register + single-use consume (INV-5) ---
        contact_name is str = (rec?) $assigned.
        if contact_name == ""
        {
            // REGISTRY DISPATCH replaces the 0.3.0 strict read that caused the
            // incident ((payload $name) safe str on a NIL): the v3/v5 branches
            // return the sent $name; the v2 branch returns "" (no such field
            // in sir_payload_v2_t) and we fall back to the sender cid.
            joiner_name is str = a2a_versions::sir_joiner_name narrowed.
            contact_name -> (joiner_name == "" ?? (_str sender_id) ; joiner_name).
        }
        contacts sender_id -> ($name -> contact_name, $container_id -> sender_id).
        // Passive version learning (SPEC §3): dialect + piggybacked caps.
        learn_contact_version sender_id (a2a_versions::sir_version_of payload) (a2a_versions::sir_caps narrowed).
        peer_ads sender_id -> (vb $ad).
        if (vb $root) != NIL { contact_roots sender_id -> (vb $root)?. }
        if (vb $pin_binding) != NIL { contact_cp_bindings ((vb $pin_binding_root)?) -> (vb $pin_binding)?. }
        delete pending_invites invite_id.
        delete pending_invite_keys invite_id.

        // reply leg 3 as a BARE BOXED send (NOT encrypted_channel): the responder
        // has NOT registered me yet, so it could not resolve my source key to open a
        // send_encrypted_tx (the M0 spike's "Unknown source key" on the receiver is
        // exactly this — see the leg-3 correction). Instead I box my identity bundle
        // to the responder's EPHEMERAL pubkey (epk_r, carried in leg 1) with a fresh
        // inviter ephemeral; the responder opens it with the ephemeral private key it
        // kept. encrypted_channel resumes for all post-contact traffic, both sides
        // being registered after leg 3.
        b = my_identity_bundle_fields NIL.
        kpi = _crypto_construct_encryption_keypair (rec? $scheme).
        // The literal cin_payload_v5_t shape ($pv/$caps; this surface never
        // carried $name). 0.2.0 responders ignore the additions.
        leg3_payload = _write (
            $ad -> (b $ad),
            $cert -> (b $cert),
            $root_profile -> (b $root_profile),
            $cp_binding -> (b $cp_binding),
            $invite_id -> invite_id,
            $pv   -> a2a_versions::wire_version,
            $caps -> (a2a_capabilities::self_cap_ids NIL)
        ).
        leg3_data = _crypto_encrypt_message (kpi $secret_key) epk_r leg3_payload.
        return transaction::success [
            transaction::action::send sender_id (
                $name -> complete_invite_tx,
                $targ -> (
                    $invite_id -> invite_id,
                    $epk -> (kpi $public_key),
                    $v -> (rec? $scheme),
                    $data -> leg3_data,
                    $pv -> a2a_versions::wire_version
                )
            ),
            _notify_agent ($event -> $contact_accepted, $name -> contact_name, $container_id -> sender_id),
            _save_state NIL
        ].
    }

    // core 3.0 LEG 3 (responder): the inviter completed the exchange. It is a BARE
    // BOXED send (NOT encrypted_channel — see the leg-2 reply), so it intentionally
    // SKIPS check_encrypted_or_abort; the box (to my kept ephemeral key) is the
    // confidentiality/integrity, and authenticity comes from the inviter-cid pin +
    // cid-bind + PoP. Gate discipline (INV-5): pend lookup -> inviter-cid pin ->
    // decrypt -> cid-bind -> PoP -> chain, all before the contact is registered.
    // Clears BOTH responder stores (pending_redemptions + pending_redemption_keys).
    fn handle_complete_invite (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        invite_id = (args $invite_id) safe global_id.

        // --- gates (no state mutation until all pass) ---
        pend = pending_redemptions invite_id.
        abort "Unsolicited completion." when pend == NIL.
        abort "Completion from unexpected inviter." when sender_id != (pend?) $inviter_cid.
        eph_priv_r = pending_redemption_keys invite_id.
        abort "Redemption ephemeral key missing (already completed or not persisted)." when eph_priv_r == NIL.

        epk_i = (args $epk) safe publickey_encrypt.
        ct = (args $data) safe crypto_message.
        // box-open with the kept responder ephemeral private key (aborts on tamper).
        payload = _read_or_abort (_crypto_decrypt_message eph_priv_r? epk_i ct).

        // --- 0.5.0 registry gate (cin) — error-as-data, never an abort ------
        // A version-incompatible completion surfaces to MY client as a
        // $protocol_error notify; the pending redemption stays (transient,
        // GC'd with the stores) so a corrected completion can still land.
        nr = a2a_versions::try_narrow_cin payload.
        if (nr $ok) != TRUE
        {
            err = (nr $err)?.
            return transaction::success [
                _notify_agent (
                    $event     -> $protocol_error,
                    $context   -> $invite_complete,
                    $message   -> ("An invite you redeemed was completed by an inviter running an unsupported protocol version. The contact was not added — ask them to update their client. (" + (err $message) + ")"),
                    $error     -> err,
                    $invite_id -> invite_id,
                    $peer_cid  -> sender_id
                )
            ].
        }
        narrowed is a2a_versions::cin_payload_t = (nr $payload)?.

        // D8 cid-bind + PoP self-sig, then the optional delegation chain — an
        // invalid chain or forged/inconsistent AD aborts before any write.
        vb = verify_identity_bundle payload sender_id.

        // --- all gates passed: register + clear the pending redemption ---
        // name: my chosen custom name, else the inviter's invite name, else its cid.
        contact_name is str = (pend?) $custom_name.
        if contact_name == "" { contact_name -> (pend?) $inviter_name. }
        if contact_name == "" { contact_name -> (_str sender_id). }
        contacts sender_id -> ($name -> contact_name, $container_id -> sender_id).
        learn_contact_version sender_id (a2a_versions::cin_version_of payload) (a2a_versions::cin_caps narrowed).
        peer_ads sender_id -> (vb $ad).
        if (vb $root) != NIL { contact_roots sender_id -> (vb $root)?. }
        if (vb $pin_binding) != NIL { contact_cp_bindings ((vb $pin_binding_root)?) -> (vb $pin_binding)?. }
        delete pending_redemptions invite_id.
        delete pending_redemption_keys invite_id.

        return transaction::success [
            _notify_agent ($event -> $contact_added, $name -> contact_name, $container_id -> sender_id),
            _save_state NIL
        ].
    }

    // Inbound trn stubs (declared AFTER their handlers — mufl requires
    // define-before-use, as with accept_contact/handle_accept_contact above).
    trn submit_invite_response args: any
    {
        return handle_submit_invite_response args.
    }

    trn complete_invite args: any
    {
        return handle_complete_invite args.
    }

    // ==== contact restore (spec 2026-07-01): re-run the key exchange between
    // MUTUALLY KNOWN addresses after a breaking change dropped peer_ads. Same
    // machinery as the eph-invite legs (bundle, box-to-eph-key, INV-5 gate
    // ordering); the trust gate is "#77-origin-verified signed request from an
    // address already in my contacts" instead of an OOB invite token.

    // LEG 0 (responder): a contact lost my address document and asks me to
    // re-exchange keys. BARE inbound — #77 signs every envelope and rejects
    // unsigned/forged origin, so the envelope $from IS the authenticated
    // requester. Gate: requester ∈ contacts, else a SILENT no-op (success with
    // no actions — no error reply, so whether an address is known never leaks).
    // NON-DESTRUCTIVE: nothing is installed or replaced here; my stored peer_ad
    // for the requester (possibly stale, possibly absent) is only replaced at
    // leg 2 after its bundle verifies. At most ONE outstanding reply record per
    // requester — a newer request replaces it (bounded by the contacts set).
    // Accepted trade-off: a replayed/duplicate leg 0 supersedes the previous
    // reply record, so an in-flight leg 2 for the older rid then fails its gate
    // — transient, self-heals on the next sweep; nothing is installable by the
    // replayer.
    fn handle_request_contact_restore (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        if (contacts sender_id) == NIL { return transaction::success []. }

        rid = (args $rid) safe global_id.
        epk_requester = (args $epk) safe publickey_encrypt.
        scheme = (args $v) safe int.
        now = (current_transaction_info::get_transaction_time())?.

        kpr = _crypto_construct_encryption_keypair scheme.
        pending_restore_replies sender_id -> ($rid -> rid, $scheme -> scheme, $created -> now).
        pending_restore_reply_keys sender_id -> (kpr $secret_key).

        b = my_identity_bundle_fields NIL.
        // rst_payload_v5_t shape ($pv/$caps piggyback, SPEC §3/§4).
        payload = _write (
            $ad -> (b $ad), $cert -> (b $cert), $root_profile -> (b $root_profile),
            $cp_binding -> (b $cp_binding), $rid -> rid,
            $pv -> a2a_versions::wire_version, $caps -> (a2a_capabilities::self_cap_ids NIL)
        ).
        data = _crypto_encrypt_message (kpr $secret_key) epk_requester payload.
        return transaction::success [
            transaction::action::send sender_id (
                $name -> submit_restore_response_tx,
                $targ -> ($rid -> rid, $epk -> (kpr $public_key), $v -> scheme, $data -> data, $pv -> a2a_versions::wire_version)
            ),
            _save_state NIL
        ].
    }

    trn request_contact_restore args: any
    {
        return handle_request_contact_restore args.
    }

    // LEG 1 (requester): the contact answered with its identity bundle boxed to
    // my leg-0 ephemeral pubkey. Gate discipline (INV-5): pend lookup -> rid pin
    // -> decrypt -> cid-bind -> PoP -> chain, all before any write. Single-use:
    // the first valid leg 1 consumes BOTH pending_restores and the hidden eph
    // key; a failed gate consumes nothing. Replies leg 2 as a BARE BOXED send —
    // the responder may not hold MY current AD until that bundle arrives, so the
    // encrypted channel cannot carry it (same reasoning as the invite leg 3).
    fn handle_submit_restore_response (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        rid = (args $rid) safe global_id.

        // --- gates (no state mutation until all pass) ---
        pend = pending_restores sender_id.
        abort "Unsolicited restore response." when pend == NIL.
        abort "Restore response does not match the outstanding request." when rid != ((pend?) $rid).
        eph_priv = pending_restore_keys sender_id.
        abort "Restore ephemeral key missing (superseded or already completed)." when eph_priv == NIL.
        abort "Restore response from a removed contact." when (contacts sender_id) == NIL.

        epk_r = (args $epk) safe publickey_encrypt.
        scheme = (args $v) safe int.
        ct = (args $data) safe crypto_message.
        payload = _read_or_abort (_crypto_decrypt_message eph_priv? epk_r ct).

        // --- 0.5.0 registry gate (rst) — error-as-data, never an abort ------
        // The degraded contact stays degraded (request not consumed: the boot
        // sweep re-attempts, and a corrected reply can still land).
        nr = a2a_versions::try_narrow_rst payload.
        if (nr $ok) != TRUE
        {
            err = (nr $err)?.
            return transaction::success [
                _notify_agent (
                    $event    -> $protocol_error,
                    $context  -> $contact_restore,
                    $message  -> ("A contact could not be restored: the peer runs an unsupported protocol version. Ask them to update their client. (" + (err $message) + ")"),
                    $error    -> err,
                    $peer_cid -> sender_id
                )
            ].
        }
        narrowed is a2a_versions::rst_payload_t = (nr $payload)?.

        // Post-gate the $rid domain is checked, so this strict read cannot abort.
        abort "Restore payload correlation mismatch." when ((payload $rid) safe global_id) != rid.
        vb = verify_identity_bundle payload sender_id.

        // --- all gates passed: (re)install the peer's keys + single-use consume ---
        learn_contact_version sender_id (a2a_versions::rst_version_of payload) (a2a_versions::rst_caps narrowed).
        peer_ads sender_id -> (vb $ad).
        if (vb $root) != NIL { contact_roots sender_id -> (vb $root)?. }
        if (vb $pin_binding) != NIL { contact_cp_bindings ((vb $pin_binding_root)?) -> (vb $pin_binding)?. }
        delete pending_restores sender_id.
        delete pending_restore_keys sender_id.

        b = my_identity_bundle_fields NIL.
        kp2 = _crypto_construct_encryption_keypair scheme.
        // rst_payload_v5_t shape ($pv/$caps piggyback, SPEC §3/§4).
        leg2_payload = _write (
            $ad -> (b $ad), $cert -> (b $cert), $root_profile -> (b $root_profile),
            $cp_binding -> (b $cp_binding), $rid -> rid,
            $pv -> a2a_versions::wire_version, $caps -> (a2a_capabilities::self_cap_ids NIL)
        ).
        leg2_data = _crypto_encrypt_message (kp2 $secret_key) epk_r leg2_payload.
        contact_name = ((contacts sender_id)?) $name.
        return transaction::success [
            transaction::action::send sender_id (
                $name -> complete_restore_tx,
                $targ -> ($rid -> rid, $epk -> (kp2 $public_key), $v -> scheme, $data -> leg2_data, $pv -> a2a_versions::wire_version)
            ),
            _notify_agent ($event -> $contact_restored, $name -> contact_name, $container_id -> sender_id),
            _save_state NIL
        ].
    }

    trn submit_restore_response args: any
    {
        return handle_submit_restore_response args.
    }

    // LEG 2 (responder): the requester completed with ITS bundle boxed to my
    // leg-1 ephemeral pubkey. Same gate discipline; only HERE do I REPLACE my
    // stored peer_ad for the requester — required even when one is present: a
    // #77 reseed rolls the peer a fresh ENCRYPT key, so a surviving stale AD
    // would break my sends toward it. Single-use consume of the reply stores.
    fn handle_complete_restore (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        rid = (args $rid) safe global_id.

        // --- gates (no state mutation until all pass) ---
        pend = pending_restore_replies sender_id.
        abort "Unsolicited restore completion." when pend == NIL.
        abort "Restore completion does not match the outstanding reply." when rid != ((pend?) $rid).
        eph_priv = pending_restore_reply_keys sender_id.
        abort "Restore reply key missing (superseded or already completed)." when eph_priv == NIL.
        abort "Restore completion from a removed contact." when (contacts sender_id) == NIL.

        epk_i = (args $epk) safe publickey_encrypt.
        ct = (args $data) safe crypto_message.
        payload = _read_or_abort (_crypto_decrypt_message eph_priv? epk_i ct).

        // --- 0.5.0 registry gate (rst) — error-as-data, never an abort ------
        nr = a2a_versions::try_narrow_rst payload.
        if (nr $ok) != TRUE
        {
            err = (nr $err)?.
            return transaction::success [
                _notify_agent (
                    $event    -> $protocol_error,
                    $context  -> $contact_restore,
                    $message  -> ("A contact could not complete a key restore: the peer runs an unsupported protocol version. Ask them to update their client. (" + (err $message) + ")"),
                    $error    -> err,
                    $peer_cid -> sender_id
                )
            ].
        }
        narrowed is a2a_versions::rst_payload_t = (nr $payload)?.

        // Post-gate the $rid domain is checked, so this strict read cannot abort.
        abort "Restore payload correlation mismatch." when ((payload $rid) safe global_id) != rid.
        vb = verify_identity_bundle payload sender_id.

        // --- all gates passed: replace + single-use consume ---
        learn_contact_version sender_id (a2a_versions::rst_version_of payload) (a2a_versions::rst_caps narrowed).
        peer_ads sender_id -> (vb $ad).
        if (vb $root) != NIL { contact_roots sender_id -> (vb $root)?. }
        if (vb $pin_binding) != NIL { contact_cp_bindings ((vb $pin_binding_root)?) -> (vb $pin_binding)?. }
        delete pending_restore_replies sender_id.
        delete pending_restore_reply_keys sender_id.

        contact_name = ((contacts sender_id)?) $name.
        return transaction::success [
            _notify_agent ($event -> $contact_restored, $name -> contact_name, $container_id -> sender_id),
            _save_state NIL
        ].
    }

    trn complete_restore args: any
    {
        return handle_complete_restore args.
    }

    metadef degraded_contact_t: ($container_id -> global_id, $name -> str, $attempts -> int, $queued -> int).
    metadef deferred_queue_info_t: ($container_id -> global_id, $name -> str, $queued -> int, $degraded -> bool).

    // Degraded contacts (known cid, no AD) with their restore-attempt counts and
    // queued-message counts — the host's boot/GC sweep + list_contacts marker.
    trn readonly list_degraded_contacts _
    {
        out is degraded_contact_t[] = [].
        sc contacts -- (cid -> c) ?? (peer_ads cid) == NIL
        {
            att is int = 0.
            pr = pending_restores cid.
            if pr != NIL { att -> ((pr?) $attempts). }
            nq is int = 0.
            dq = deferred_msgs cid.
            if dq != NIL { nq -> (_count dq?|). }
            out (_count out|) -> ($container_id -> cid, $name -> (c $name), $attempts -> att, $queued -> nq).
        }
        return ($degraded -> out).
    }

    // Every non-empty deferred queue + whether its contact is still degraded —
    // lets the host flush queues whose contact healed without a notify (e.g. a
    // daemon restart between restore and flush).
    trn readonly list_deferred_queues _
    {
        out is deferred_queue_info_t[] = [].
        sc deferred_msgs -- (cid -> q) ?? (_count q|) > 0
        {
            nm is str = "".
            c = contacts cid.
            if c != NIL { nm -> ((c?) $name). }
            out (_count out|) -> ($container_id -> cid, $name -> nm, $queued -> (_count q|), $degraded -> ((peer_ads cid) == NIL)).
        }
        return ($queues -> out).
    }

    // Host-fired sweep (boot + GC cadence): (re)issue a restore request for every
    // degraded contact, up to restore_max_attempts each. A peer that is offline
    // or not yet running a restore-capable version simply never answers — the
    // sweep retries on the host's cadence; no reply is a normal condition.
    trn restore_degraded_contacts _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        actions is transaction::action::type[] = [].
        requested is int = 0.
        exhausted is int = 0.
        sc contacts -- (cid -> c) ?? (peer_ads cid) == NIL
        {
            prev = pending_restores cid.
            if prev != NIL && ((prev?) $attempts) >= restore_max_attempts
            {
                exhausted -> exhausted + 1.
            }
            else
            {
                sc begin_contact_restore cid -- ( -> a) { actions (_count actions|) -> a. }
                requested -> requested + 1.
            }
        }
        actions (_count actions|) -> _return_data ($requested -> requested, $exhausted -> exhausted).
        if requested > 0 { actions (_count actions|) -> _save_state NIL. }
        return transaction::success actions.
    }

    // Drain the deferred queue toward a contact whose AD is re-established.
    // HOST-DRIVEN (fired on the $contact_restored notify + the boot/GC sweep) so
    // the encrypted sends never race the restore legs' bare sends on the wire —
    // the host round-trip guarantees leg 2 delivery precedes the flush.
    // Idempotent: an empty or still-degraded queue is a no-op result, not an error.
    trn flush_deferred _:($contact -> contact_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        target_id = resolve_contact contact_ref.
        q = deferred_msgs target_id.
        if q == NIL || (_count q?|) == 0 { return transaction::success [ _return_data ($flushed -> 0) ]. }
        if (peer_ads target_id) == NIL { return transaction::success [ _return_data ($flushed -> 0, $degraded -> TRUE) ]. }

        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            actions is transaction::action::type[] = [].
            sc q? -- ( -> m)
            {
                actions (_count actions|) -> encrypted_channel::send_encrypted_tx target_id (
                    $name -> receive_message_tx,
                    $targ -> ($text -> (m $text), $wire_id -> (m $wire_id), $reply_to -> (m $reply_to), $pv -> a2a_versions::wire_version)
                ).
                sc on_message_sent ($target_id -> target_id, $text -> (m $text), $date -> (m $date), $wire_id -> (m $wire_id), $reply_to -> (m $reply_to)) -- ( -> a)
                {
                    actions (_count actions|) -> a.
                }
                sc monitor_copy_actions "out" target_id (m $date) (m $text) -- ( -> a)
                {
                    actions (_count actions|) -> a.
                }
            }
            n = _count q?|.
            delete deferred_msgs target_id.
            actions (_count actions|) -> _return_data ($flushed -> n).
            actions (_count actions|) -> _save_state NIL.
            return transaction::success actions.
        }).
    }

    // Validation + contact resolution only; STORAGE is the app's, through the
    // on_message_received hook. $sender_name is NIL for an unknown sender —
    // the hook decides whether that is queueable (agent: pending-introduction
    // queue) or a rejection. Args are taken as `any` (not a destructured shape)
    // so a pre-wire_id sender — whose payload carries only $text — keeps working
    // unchanged, and so new optional fields ($wire_id, $reply_to) are tolerated.
    fn handle_receive_message (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        msg_date = (current_transaction_info::get_transaction_time())?.
        text = (args $text) safe str.

        // Optional, absent from pre-1.4 senders: the message's stable wire id
        // and an optional reply pointer. Default to "" / NIL so old payloads and
        // the agent storage hook behave exactly as before.
        wire_id is str = "".
        if (args $wire_id) != NIL { wire_id -> (args $wire_id) safe str. }
        reply_to is a2a_protocol::reply_ref_t+ = NIL.
        if (args $reply_to) != NIL { reply_to -> (args $reply_to) safe a2a_protocol::reply_ref_t. }

        sender = contacts sender_id.
        sender_name is str+ = NIL.
        if sender != NIL
        {
            sender_name -> sender? $name.
        }

        // Passive version learning: only a STAMPED $pv is evidence (an
        // unstamped message says just "pre-0.5", which must not overwrite the
        // more precise dialect the invite/restore legs shape-inferred).
        pv_seen = a2a_versions::peer_pv args.
        if pv_seen != 0 { learn_contact_version sender_id pv_seen []. }

        // The app hook owns storage; it may abort (unknown sender rejected) — in
        // which case nothing is delivered and no copy is emitted. When it accepts,
        // we append the FORCED inbound monitoring copy as core code (after the hook,
        // self-gating on monitoring_proxy) so the app cannot suppress it.
        actions is transaction::action::type[] = [].
        sc on_message_received (
            $sender_id   -> sender_id,
            $sender_name -> sender_name,
            $text        -> text,
            $date        -> msg_date,
            $wire_id     -> wire_id,
            $reply_to    -> reply_to
        ) -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        sc monitor_copy_actions "in" sender_id msg_date text -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        // core 0.7.0: DELIVERED receipt, emitted atomically with acceptance
        // (the hook above may abort = message rejected = no receipt; from here
        // the message IS stored). Fire-and-forget; gated on positive caps;
        // pre-wire_id senders have no handle (and no cap) — nothing emitted.
        if wire_id != ""
        {
            sc receipt_actions sender_id "delivered" [wire_id] -- ( -> a)
            {
                actions (_count actions|) -> a.
            }
        }
        return transaction::success actions.
    }

    trn receive_message args: any
    {
        return handle_receive_message args.
    }

    // File analogue of handle_receive_message: validate + resolve sender, then hand
    // the file to the app's on_file_received storage hook (the app owns storage; it
    // may abort an unknown sender). $mime/$wire_id/$reply_to are optional and default
    // to ""/""/NIL so a looser sender is tolerated. Forced metadata-only monitoring copy is appended after the hook.
    fn handle_receive_file (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        file_date = (current_transaction_info::get_transaction_time())?.
        filename = (args $filename) safe str.
        data = (args $data) safe bin.
        mime is str = "".
        if (args $mime) != NIL { mime -> (args $mime) safe str. }
        wire_id is str = "".
        if (args $wire_id) != NIL { wire_id -> (args $wire_id) safe str. }
        reply_to is a2a_protocol::reply_ref_t+ = NIL.
        if (args $reply_to) != NIL { reply_to -> (args $reply_to) safe a2a_protocol::reply_ref_t. }

        sender = contacts sender_id.
        sender_name is str+ = NIL.
        if sender != NIL
        {
            sender_name -> sender? $name.
        }

        // Passive version learning (see handle_receive_message).
        pv_seen = a2a_versions::peer_pv args.
        if pv_seen != 0 { learn_contact_version sender_id pv_seen []. }

        actions is transaction::action::type[] = [].
        sc on_file_received (
            $sender_id   -> sender_id,
            $sender_name -> sender_name,
            $filename    -> filename,
            $mime        -> mime,
            $data        -> data,
            $date        -> file_date,
            $wire_id     -> wire_id,
            $reply_to    -> reply_to
        ) -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        sc monitor_copy_actions "in" sender_id file_date (file_monitor_summary filename mime data) -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        // core 0.7.0: DELIVERED receipt (files share the wire_id namespace).
        if wire_id != ""
        {
            sc receipt_actions sender_id "delivered" [wire_id] -- ( -> a)
            {
                actions (_count actions|) -> a.
            }
        }
        return transaction::success actions.
    }

    trn receive_file args: any
    {
        return handle_receive_file args.
    }

    // core 0.7.0: receipt ingest — a peer confirms delivery/read of messages I
    // sent. TOLERANT AND NEVER LOAD-BEARING: content problems are ignored
    // (success no-op) — an unknown $kind is a future receipt kind (forward
    // compat), an unparseable payload is dropped, unknown wire_ids are the
    // hook's business (messages GC). Only channel/origin violations abort.
    // NO receipt is ever emitted for a receipt (terminal surface, no recursion).
    fn handle_receive_receipt (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.

        // Unknown senders: silent success (best-effort surface, no probe oracle).
        if (contacts sender_id) == NIL { return transaction::success []. }
        // Registry classification (rcp, M1 abort-free): bad shape => ignore.
        if a2a_versions::rcp_shape_ok args != TRUE { return transaction::success []. }
        kind = (args $kind) safe str.
        if kind != "delivered" && kind != "read" { return transaction::success []. }

        // Tolerant per-element wire_id extraction (mistyped entries skipped).
        ids is str[] = [].
        sc (args $wire_ids) -- ( -> w)
        {
            if w != NIL && (_typeof w) == "STRING" { ids (_count ids|) -> (w safe str). }
        }
        if (_count ids|) == 0 { return transaction::success []. }

        rdate is time+ = NIL.
        if (args $date) != NIL && (_typeof (args $date)) == "TIME" { rdate -> (args $date) safe time. }

        pv_seen = a2a_versions::peer_pv args.
        if pv_seen != 0 { learn_contact_version sender_id pv_seen []. }

        actions is transaction::action::type[] = [].
        sc on_receipt_received (
            $sender_id -> sender_id,
            $kind      -> kind,
            $wire_ids  -> ids,
            $date      -> rdate
        ) -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        return transaction::success actions.
    }

    trn receive_receipt args: any
    {
        return handle_receive_receipt args.
    }

    // ---- upgrade: state export / import helpers ------------------------------
    // NOT transactions: each app's export_state/import_state trn composes these
    // with its own app-side fields (inbox / chat history / local book). Field
    // names match the historical app-level blobs exactly, so a PRE-migration
    // export imports through here unchanged.

    fn export_core_state (_) -> any
    {
        return (
            $my_name         -> my_name,
            $contacts        -> contacts,
            $pending_invites -> pending_invites,
            $peer_ads        -> peer_ads,
            $my_bio          -> my_bio,
            $my_persona      -> my_persona,
            $delegation_cert -> delegation_cert,
            $root_ad         -> root_ad,
            $root_profile    -> root_profile,
            $root_cp_binding -> root_cp_binding,
            $contact_roots   -> contact_roots,
            $contact_cp_bindings -> contact_cp_bindings,
            $managed_roots    -> managed_roots,
            $proxy_pending    -> proxy_pending,
            $monitoring_proxy -> monitoring_proxy,
            $app_config       -> app_config,
            $format_version  -> core_format_version,
            $deferred_msgs   -> deferred_msgs,
            $contact_pv      -> contact_pv,
            $contact_caps    -> contact_caps
        ).
    }

    fn import_core_state (data: any) -> nil
    {
        // ---- format stamp + THE MIGRATION CONTRACT -------------------------------
        // Absent stamp == version 0 (every pre-stamp blob); all shipped migrations so
        // far are additive/field-optional, so 0 imports through the optional reads
        // below. The stamp exists so a future BREAKING blob change dispatches on an
        // explicit key instead of shape-sniffing. CONTRACT (binding on every future
        // format bump): a migration from version N MUST carry forward `contacts`,
        // `my_name`, `my_bio`, `my_persona` (and SHOULD carry contact_roots and the
        // consumer app's inbox/files); `peer_ads` is BEST-EFFORT — when a crypto/AD
        // change makes old documents unusable, DROP them: each dropped peer becomes a
        // degraded contact (contacts entry, no peer_ads entry) and self-heals through
        // request_contact_restore. NEVER let an incompatible optional field abort the
        // whole import — degrade, don't reset.
        fmt is int = 0.
        if (data $format_version) != NIL { fmt -> (data $format_version) safe int. }
        abort "State blob format_version " + (_str fmt) + " is newer than this code (supports up to " + (_str core_format_version) + ") — upgrade the software before importing." when fmt > core_format_version.

        // The original schema's fields are required; everything that arrived
        // with a later schema is optional and defaults stay in place when
        // absent (the whole point of code-independent state is that an old
        // export upgrades, never resets).
        my_name         -> (data $my_name) safe str.
        contacts        -> (data $contacts) safe (global_id ->> a2a_protocol::contact_t).
        // core 3.0 migration: pending_invites changed shape (pre-3.0 (global_id ->>
        // str) → (global_id ->> pending_invite_t)). It is reset to EMPTY on import,
        // unconditionally and for BOTH shapes: a pre-3.0 str-map is incompatible (so
        // it is dropped rather than safe-cast, which would abort), and even a 3.0
        // record-map entry is unredeemable after import because its matching
        // ephemeral private key (pending_invite_keys) is hidden + NEVER exported
        // (INV-4). The responder-side stores (pending_redemptions /
        // pending_redemption_keys) are likewise not exported and default to empty
        // here. Net: outstanding invites/redemptions are transient — they do not
        // survive export/import or a daemon restart, fail-closed (plan §4.4).
        pending_invites -> (,).
        // Restore handshake state is transient exactly like pending_invites: the eph
        // PRIVATE halves are hidden + never exported, so imported records would be
        // unanswerable. The boot sweep (restore_degraded_contacts) re-mints them.
        pending_restores -> (,).
        pending_restore_replies -> (,).
        peer_ads        -> (data $peer_ads) safe (global_id ->> address_document_types::t_address_document).

        if (data $my_bio) != NIL
        {
            my_bio -> (data $my_bio) safe str.
        }
        if (data $my_persona) != NIL
        {
            my_persona -> (data $my_persona) safe str.
        }
        if (data $delegation_cert) != NIL
        {
            delegation_cert -> (data $delegation_cert) safe a2a_protocol::delegation_cert_t.
        }
        if (data $root_ad) != NIL
        {
            root_ad -> (data $root_ad) safe address_document_types::t_address_document.
        }
        if (data $root_profile) != NIL
        {
            root_profile -> (data $root_profile) safe a2a_protocol::root_profile_t.
        }
        if (data $root_cp_binding) != NIL
        {
            root_cp_binding -> (data $root_cp_binding) safe a2a_protocol::root_cp_binding_t.
        }
        if (data $contact_roots) != NIL
        {
            contact_roots -> (data $contact_roots) safe (global_id ->> a2a_protocol::contact_root_t).
        }
        if (data $contact_cp_bindings) != NIL
        {
            contact_cp_bindings -> (data $contact_cp_bindings) safe (global_id ->> a2a_protocol::root_cp_binding_t).
        }
        // CP-side managed roots (absent from pre-2.1 exports → stays empty, i.e. this
        // node enrolls no cluster children until a root is registered via manage_root).
        if (data $managed_roots) != NIL
        {
            managed_roots -> (data $managed_roots) safe (global_id ->> bool).
        }
        // Forced-monitoring state (absent from pre-monitoring exports → defaults
        // stay NIL, i.e. unmonitored, until a control plane binds).
        if (data $proxy_pending) != NIL
        {
            proxy_pending -> (data $proxy_pending) safe proxy_pending_t.
        }
        if (data $monitoring_proxy) != NIL
        {
            monitoring_proxy -> (data $monitoring_proxy) safe proxy_binding_t.
        }
        // Control-plane config state (absent from pre-config exports → defaults).
        if (data $app_config) != NIL
        {
            app_config -> (data $app_config) safe str.
        }
        if (data $deferred_msgs) != NIL
        {
            deferred_msgs -> (data $deferred_msgs) safe (global_id ->> deferred_msg_t[]).
        }
        // core 0.5.0: learned peer dialects/caps (absent from pre-0.5 exports
        // → defaults stay empty; re-learned passively from inbound traffic).
        if (data $contact_pv) != NIL
        {
            contact_pv -> (data $contact_pv) safe (global_id ->> int).
        }
        if (data $contact_caps) != NIL
        {
            contact_caps -> (data $contact_caps) safe (global_id ->> str[]).
        }

        // Re-register every peer's keys so encrypted channels keep working after
        // the upgrade — no handshake needed (my own keys are unchanged, and the
        // peers' self-signed address documents re-authorize on this fresh packet).
        sc peer_ads -- ( -> ad)
        {
            address_document::process_address_document ad TRUE.
        }
    }
}
