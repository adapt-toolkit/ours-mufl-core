// Shared ours group-chat library (core 0.8.0).
//
// A group = a shared chat_id + a CREATOR-AUTHORITATIVE roster + the full MESH
// of mutual contacts it induces (GROUP_CHAT_DESIGN.md / GROUP_CHAT_PLAN.md).
// Joining a group makes members mutual contacts, so a message is a bare N-way
// send_encrypted_tx fan-out over the EXISTING 1:1 encrypted channels — no group
// key, no relay, no server SPOF. v1 is rudimentary: ONE creator/admin (no
// multi-admin, no succession), invite + explicit accept, owner-only disclosure,
// one-by-one mesh wiring, admin remove + self-leave, creator delete_group,
// epoch-based lost-message repair.
//
// Layering: this is its own library (mirroring a2a_cluster) so a2a_messaging
// stays intact. It reuses a2a_messaging's peer_ads / contacts / resolve_contact
// / the monitoring copy, encrypted_channel's bare send, address_document's PoP,
// and narrows every inbound through the a2a_versions grp_* registry entries.
//
// Storage stays APP-SIDE (the core's rule): the core does roster resolution +
// validation + fan-out; two injected hooks (on_group_message_received /
// on_group_message_sent) thread history by chat_id app-side. Group state holds
// NO secrets → it exports/imports losslessly.
library a2a_group loads libraries
    current_transaction_info,
    encrypted_channel,
    address_document,
    address_document_types,
    a2a_versions,
    a2a_protocol,
    a2a_capabilities,
    a2a_messaging,
    version
    uses transactions
{
    // Network-visible inbound names (LIBRARY-routed — NEW surfaces, no legacy
    // ::actor:: shims). Peers exchange these; a pre-0.8 peer never receives one
    // (it was never invited/added).
    group_invite_tx          = "::a2a_group::receive_group_invite".
    group_invite_response_tx = "::a2a_group::receive_group_invite_response".
    group_member_add_tx      = "::a2a_group::receive_group_member_add".
    group_roster_sync_tx     = "::a2a_group::receive_group_roster_sync".
    group_member_remove_tx   = "::a2a_group::receive_group_member_remove".
    group_member_leave_tx    = "::a2a_group::receive_group_member_leave".
    group_delete_tx          = "::a2a_group::receive_group_delete".
    group_message_tx         = "::a2a_group::receive_group_message".
    group_not_member_tx      = "::a2a_group::receive_group_not_member".
    group_stale_tx           = "::a2a_group::receive_group_stale".
    request_group_roster_tx  = "::a2a_group::receive_group_roster_request".

    // ---- state (no secrets; exported) -------------------------------------
    // A roster entry: display label only; the trusted identity is the AD
    // self-signature already verified into a2a_messaging::peer_ads.
    metadef group_member_t: ($cid -> global_id, $name -> str).
    metadef group_t: (
        $chat_id   -> global_id,
        $name      -> str,
        $admin_cid -> global_id,                   // pinned authority for this group
        $epoch     -> int,                          // last roster epoch I know
        $status    -> str,                          // "active" | "invited" | "accepting"
        $members   -> (global_id ->> group_member_t)
    ).
    groups is (global_id ->> group_t) = (,).        // keyed by chat_id

    // Admin side: invitees I have offered who have not yet accepted/declined.
    // Keyed by chat_id then invitee cid. No secrets.
    pending_group_invites is (global_id ->> (global_id ->> bool)) = (,).

    hidden
    {
        _read_or_abort is (bin -> any) = fn (_: bin)
        {
            abort "_read_or_abort is unset in a2a_group (call a2a_group::init)." when TRUE.
        }
        // App storage hooks (default abort until init wires them — a consumer
        // that loads a2a_group MUST wire both, like a2a_messaging's hooks).
        on_group_message_received is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_group_message_received hook is unset in a2a_group (call a2a_group::init)." when TRUE. return []. }
        on_group_message_sent is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_group_message_sent hook is unset in a2a_group (call a2a_group::init)." when TRUE. return []. }
    }

    init = fn (_:(
        $_read_or_abort -> read: (bin -> any),
        $on_group_message_received -> recv_cb: (any -> transaction::action::type[]),
        $on_group_message_sent -> sent_cb: (any -> transaction::action::type[])
    ))
    {
        _read_or_abort -> read.
        on_group_message_received -> recv_cb.
        on_group_message_sent -> sent_cb.
    }

    // ---- shared action builders (mirror a2a_messaging) ---------------------
    fn _save_state (_) = (transaction::action::return_data ($kind -> $save_state)).
    fn _return_data (payload: any) = (transaction::action::return_data ($kind -> $data, $payload -> payload)).
    fn _notify_agent (payload: any) = (transaction::action::return_data ($kind -> $notify_agent, $payload -> payload)).

    // ---- M0 skeleton read surface -----------------------------------------
    // (create/invite/respond/send/remove/leave/delete/repair land in M1-M3.)
    // These readonly trns return group state whole; the driver reads it at
    // RUNTIME (Reduce over the nested map is fine — the earlier failure was a
    // COMPILE-time cross-library type re-reduction, not a runtime one).
    trn readonly list_groups _
    {
        return ($groups -> groups).
    }
    trn readonly get_group _:($chat_id -> chat_id: global_id)
    {
        g = groups chat_id.
        abort "Unknown group." when g == NIL.
        return ($group -> g?).
    }
}
