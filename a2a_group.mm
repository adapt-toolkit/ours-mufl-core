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
// Layering: its own library (mirroring a2a_cluster). It reuses a2a_messaging's
// peer_ads / contacts / resolve_contact, encrypted_channel's bare send,
// address_document's PoP, and narrows every inbound through the a2a_versions
// grp_* registry entries. Storage stays APP-SIDE via two injected hooks.
//
// STATE SHAPE (deliberate): the roster is a plain member-cid LIST per group
// (global_id[]), NOT a map of member records. Members are mutual contacts by
// construction, so a member's DISPLAY NAME is its contact name
// (a2a_messaging::contacts[cid]) — no duplication. This also keeps every group
// type trivial: a map-of-named-record roster drives the meta type-reducer over
// its step budget once the handlers reference it widely (verified), whereas a
// cid list costs almost nothing.
library a2a_group loads libraries
    current_transaction_info,
    encrypted_channel,
    address_document,
    address_document_types,
    a2a_versions,
    a2a_protocol,
    a2a_messaging,
    version
    uses transactions
{
    // Network-visible inbound names (LIBRARY-routed — NEW surfaces, no legacy
    // ::actor:: shims). A pre-0.8 peer never receives one (never invited/added).
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
    // Group metadata (flat). admin_cid is the PINNED roster authority.
    metadef group_t: (
        $chat_id   -> global_id,
        $name      -> str,
        $admin_cid -> global_id,
        $epoch     -> int,
        $status    -> str                            // "active" | "invited" | "accepting"
    ).
    groups is (global_id ->> group_t) = (,).         // metadata, keyed by chat_id
    // Roster: member cid LIST per group (semantically the member set; names via
    // contacts). Parallel to `groups` — created/updated/deleted together.
    group_rosters is (global_id ->> global_id[]) = (,).
    // Admin side: invitee cids offered but not yet accepted/declined, per group.
    pending_group_invites is (global_id ->> global_id[]) = (,).

    hidden
    {
        _read_or_abort is (bin -> any) = fn (_: bin)
        {
            abort "_read_or_abort is unset in a2a_group (call a2a_group::init)." when TRUE.
        }
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

    // ---- shared action builders -------------------------------------------
    fn _save_state (_) = (transaction::action::return_data ($kind -> $save_state)).
    fn _return_data (payload: any) = (transaction::action::return_data ($kind -> $data, $payload -> payload)).
    fn _notify_agent (payload: any) = (transaction::action::return_data ($kind -> $notify_agent, $payload -> payload)).

    // ---- roster helpers (plain cid lists — trivial types) -----------------
    fn roster_of (chat_id: global_id) -> global_id[]
    {
        if (group_rosters chat_id) == NIL { return []. }
        return (group_rosters chat_id)?.
    }
    fn list_contains (xs: global_id[], x: global_id) -> bool
    {
        sc xs -- ( -> v) { if v == x { return TRUE. } }
        return FALSE.
    }
    fn is_member (chat_id: global_id, cid: global_id) -> bool
    {
        return list_contains (roster_of chat_id) cid.
    }
    fn roster_add (chat_id: global_id, cid: global_id) -> nil
    {
        r is global_id[] = roster_of chat_id.
        if list_contains r cid != TRUE { r (_count r|) -> cid. }
        group_rosters chat_id -> r.
    }
    fn roster_remove (chat_id: global_id, cid: global_id) -> nil
    {
        out is global_id[] = [].
        sc (roster_of chat_id) -- ( -> v) ?? v != cid { out (_count out|) -> v. }
        group_rosters chat_id -> out.
    }
    // Display name for a member cid (contacts is the source of truth; the mesh
    // guarantees a member is a contact). Falls back to the stringified cid.
    fn member_name (cid: global_id) -> str
    {
        if (a2a_messaging::contacts cid) != NIL { return ((a2a_messaging::contacts cid)? $name). }
        return _str cid.
    }
    // group_t field-update helper (flat → cheap).
    fn _grp (chat_id: global_id, name: str, admin: global_id, epoch: int, status: str) -> group_t
    {
        return ($chat_id -> chat_id, $name -> name, $admin_cid -> admin, $epoch -> epoch, $status -> status).
    }
    fn _clear_group (chat_id: global_id) -> nil
    {
        if (groups chat_id) != NIL { delete groups chat_id. }
        if (group_rosters chat_id) != NIL { delete group_rosters chat_id. }
        if (pending_group_invites chat_id) != NIL { delete pending_group_invites chat_id. }
    }
    fn _sender (_) -> global_id
    {
        return current_transaction_info::get_external_envelope_or_abort() $from.
    }

    // ---- read surface ------------------------------------------------------
    trn readonly list_groups _
    {
        return ($groups -> groups).
    }
    trn readonly list_group_members _:($chat_id -> chat_id: global_id)
    {
        return ($members -> (roster_of chat_id)).
    }
    trn readonly get_group _:($chat_id -> chat_id: global_id)
    {
        g = groups chat_id.
        abort "Unknown group." when g == NIL.
        return ($group -> g?, $members -> (roster_of chat_id)).
    }

    // ==== M1: membership formation =========================================

    // ---- user transactions (origin::user) --------------------------------
    trn create_group _:($name -> name: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        me = _get_container_id().
        chat_id = _new_id "ours group".
        groups chat_id -> (_grp chat_id name me 0 "active").
        roster_add chat_id me.
        return transaction::success [ _return_data ($chat_id -> chat_id), _save_state NIL ].
    }

    // Admin invites an EXISTING contact. Owner-only disclosure: the offer
    // carries only name + admin_cid. Bare send (invitee is a registered contact).
    trn invite_to_group _:($chat_id -> chat_id: global_id, $contact -> contact_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        g = groups chat_id.
        abort "Unknown group." when g == NIL.
        abort "Only the group admin can invite." when (g? $admin_cid) != _get_container_id().
        invitee = a2a_messaging::resolve_contact contact_ref.
        abort "That peer is already a member." when is_member chat_id invitee.
        pend is global_id[] = [].
        if (pending_group_invites chat_id) != NIL { pend -> (pending_group_invites chat_id)?. }
        abort "That contact already has a pending invite." when list_contains pend invitee.
        pend (_count pend|) -> invitee.
        pending_group_invites chat_id -> pend.
        return transaction::success [
            encrypted_channel::send_encrypted_tx invitee (
                $name -> group_invite_tx,
                $targ -> ($chat_id -> chat_id, $name -> (g? $name), $admin_cid -> (g? $admin_cid), $pv -> a2a_versions::wire_version)
            ),
            _return_data ($invited -> invitee),
            _save_state NIL
        ].
    }

    // Invitee accepts/declines. Accept → status "accepting", tell the admin.
    // Decline → drop locally, tell the admin (nothing else disclosed).
    trn respond_to_group_invite _:($chat_id -> chat_id: global_id, $accept -> accept: bool)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        g = groups chat_id.
        abort "No such group invite." when g == NIL.
        abort "This group is not in the invited state." when (g? $status) != "invited".
        admin = g? $admin_cid.
        if accept
        {
            groups chat_id -> (_grp chat_id (g? $name) admin (g? $epoch) "accepting").
            return transaction::success [
                encrypted_channel::send_encrypted_tx admin ($name -> group_invite_response_tx, $targ -> ($chat_id -> chat_id, $accepted -> TRUE, $pv -> a2a_versions::wire_version)),
                _return_data ($accepted -> TRUE), _save_state NIL
            ].
        }
        _clear_group chat_id.
        return transaction::success [
            encrypted_channel::send_encrypted_tx admin ($name -> group_invite_response_tx, $targ -> ($chat_id -> chat_id, $accepted -> FALSE, $pv -> a2a_versions::wire_version)),
            _return_data ($accepted -> FALSE), _save_state NIL
        ].
    }

    // ---- inbound handlers (origin::external, encrypted) -------------------

    // The join OFFER. The inviter must claim ITSELF as admin. Store an "invited"
    // shell — NO contact added, NO AD disclosed.
    fn handle_receive_group_invite (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender = _sender NIL.
        nr = a2a_versions::try_narrow_grp_invite args.
        if (nr $ok) != TRUE { return transaction::success [ _notify_agent ($event -> $group_protocol_error, $error -> (nr $err)?) ]. }
        chat_id = (args $chat_id) safe global_id.
        admin_cid = (args $admin_cid) safe global_id.
        if admin_cid != sender { return transaction::success []. }
        name = (args $name) safe str.
        groups chat_id -> (_grp chat_id name sender 0 "invited").
        if (group_rosters chat_id) != NIL { delete group_rosters chat_id. }
        return transaction::success [ _notify_agent ($event -> $group_invited, $chat_id -> chat_id, $name -> name, $admin_cid -> sender), _save_state NIL ].
    }
    trn receive_group_invite args: any { return handle_receive_group_invite args. }

    // Admin receives accept/decline. Accept → epoch++, roster_sync the joiner +
    // member_add to each existing member, register the joiner into the roster.
    fn handle_receive_group_invite_response (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender = _sender NIL.
        nr = a2a_versions::try_narrow_grp_invite_resp args.
        if (nr $ok) != TRUE { return transaction::success [ _notify_agent ($event -> $group_protocol_error, $error -> (nr $err)?) ]. }
        chat_id = (args $chat_id) safe global_id.
        g = groups chat_id.
        if g == NIL { return transaction::success []. }
        me = _get_container_id().
        if (g? $admin_cid) != me { return transaction::success []. }
        pend is global_id[] = [].
        if (pending_group_invites chat_id) != NIL { pend -> (pending_group_invites chat_id)?. }
        if list_contains pend sender != TRUE { return transaction::success []. }
        accepted = (args $accepted) safe bool.
        np is global_id[] = [].
        sc pend -- ( -> v) ?? v != sender { np (_count np|) -> v. }
        if (_count np|) == 0 { if (pending_group_invites chat_id) != NIL { delete pending_group_invites chat_id. } }
        else { pending_group_invites chat_id -> np. }
        if accepted != TRUE
        {
            return transaction::success [ _notify_agent ($event -> $group_invite_declined, $chat_id -> chat_id, $peer_cid -> sender), _save_state NIL ].
        }
        joiner_ad = a2a_messaging::peer_ads sender.
        if joiner_ad == NIL { return transaction::success []. }
        joiner_name = member_name sender.
        ne = (g? $epoch) + 1.
        actions is transaction::action::type[] = [].
        sc (roster_of chat_id) -- ( -> mcid) ?? mcid != me && mcid != sender
        {
            actions (_count actions|) -> encrypted_channel::send_encrypted_tx mcid (
                $name -> group_member_add_tx,
                $targ -> ($chat_id -> chat_id, $member_ad -> (joiner_ad?), $name -> joiner_name, $epoch -> ne, $pv -> a2a_versions::wire_version)
            ).
        }
        views is any[] = [].
        sc (roster_of chat_id) -- ( -> mcid)
        {
            mad = a2a_messaging::peer_ads mcid.
            if mad != NIL { views (_count views|) -> ($ad -> (mad?), $name -> (member_name mcid)). }
        }
        actions (_count actions|) -> encrypted_channel::send_encrypted_tx sender (
            $name -> group_roster_sync_tx,
            $targ -> ($chat_id -> chat_id, $epoch -> ne, $members -> views, $pv -> a2a_versions::wire_version)
        ).
        groups chat_id -> (_grp chat_id (g? $name) me ne (g? $status)).
        roster_add chat_id sender.
        actions (_count actions|) -> _notify_agent ($event -> $group_member_joined, $chat_id -> chat_id, $peer_cid -> sender, $name -> joiner_name).
        actions (_count actions|) -> _save_state NIL.
        return transaction::success actions.
    }
    trn receive_group_invite_response args: any { return handle_receive_group_invite_response args. }

    // A member learns of a new joiner from the ADMIN (admin-gate). PoP the AD,
    // register the contact if new, add to roster.
    fn handle_receive_group_member_add (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender = _sender NIL.
        nr = a2a_versions::try_narrow_grp_member_add args.
        if (nr $ok) != TRUE { return transaction::success [ _notify_agent ($event -> $group_protocol_error, $error -> (nr $err)?) ]. }
        chat_id = (args $chat_id) safe global_id.
        g = groups chat_id.
        if g == NIL { return transaction::success []. }
        if (g? $admin_cid) != sender { return transaction::success []. }
        st = g? $status.
        if st != "active" && st != "accepting" { return transaction::success []. }
        member_ad = (args $member_ad) safe address_document_types::t_address_document.
        member_cid = member_ad $identity $container_id.
        address_document::process_address_document member_ad TRUE.
        name = (args $name) safe str.
        e = (args $epoch) safe int.
        if (a2a_messaging::contacts member_cid) == NIL { a2a_messaging::contacts member_cid -> ($name -> name, $container_id -> member_cid). }
        a2a_messaging::peer_ads member_cid -> member_ad.
        cur_e = g? $epoch.
        groups chat_id -> (_grp chat_id (g? $name) (g? $admin_cid) (e > cur_e ?? e ; cur_e) (g? $status)).
        roster_add chat_id member_cid.
        return transaction::success [ _notify_agent ($event -> $group_member_added, $chat_id -> chat_id, $peer_cid -> member_cid, $name -> name), _save_state NIL ].
    }
    trn receive_group_member_add args: any { return handle_receive_group_member_add args. }

    // Joiner (or a member repairing) receives the full roster from the ADMIN
    // (admin-gate). PoP every AD, register new contacts, set roster, go active.
    fn handle_receive_group_roster_sync (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender = _sender NIL.
        nr = a2a_versions::try_narrow_grp_roster_sync args.
        if (nr $ok) != TRUE { return transaction::success [ _notify_agent ($event -> $group_protocol_error, $error -> (nr $err)?) ]. }
        chat_id = (args $chat_id) safe global_id.
        g = groups chat_id.
        if g == NIL { return transaction::success []. }
        if (g? $admin_cid) != sender { return transaction::success []. }
        me = _get_container_id().
        e = (args $epoch) safe int.
        newroster is global_id[] = [].
        newroster (_count newroster|) -> me.
        sc (args $members) -- ( -> entry)
        {
            ad = (entry $ad) safe address_document_types::t_address_document.
            cid = ad $identity $container_id.
            nm = (entry $name) safe str.
            address_document::process_address_document ad TRUE.
            if cid != me
            {
                if (a2a_messaging::contacts cid) == NIL { a2a_messaging::contacts cid -> ($name -> nm, $container_id -> cid). }
                a2a_messaging::peer_ads cid -> ad.
                if list_contains newroster cid != TRUE { newroster (_count newroster|) -> cid. }
            }
        }
        groups chat_id -> (_grp chat_id (g? $name) sender e "active").
        group_rosters chat_id -> newroster.
        return transaction::success [ _notify_agent ($event -> $group_roster_synced, $chat_id -> chat_id, $epoch -> e), _save_state NIL ].
    }
    trn receive_group_roster_sync args: any { return handle_receive_group_roster_sync args. }
}
