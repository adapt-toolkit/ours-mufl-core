// Shared ours monitoring library — CONTROL-PLANE (receiver) side.
//
// Monitoring is split across two libraries by WHERE the state lives:
//
//   - NODE side (a2a_messaging): the forced copy GENERATION
//     (monitor_copy_actions in the send/receive chokepoint) AND the gate state
//     it reads (monitoring_proxy / proxy_pending) plus that state's mutators —
//     the 6-digit bind ceremony (set_proxy_pending / verify_proxy_code), the
//     CP-authenticated disable_monitoring, and get_monitoring_status. They MUST
//     live in a2a_messaging because the gate state is `hidden` there, and hidden
//     state is mutable only by its declaring library — that is precisely what
//     stops an app (or any other library) from assigning monitoring_proxy -> NIL
//     to switch monitoring off without the ceremony.
//
//   - CONTROL-PLANE side (HERE): the receiver for the copies a monitored node
//     forwards. It touches NO gate state — it only validates the sender is a
//     known contact and hands the copy to the app's storage hook. This is the
//     only piece that can safely live outside a2a_messaging.
//
// Security model (founder directive, the ours monitoring design's accepted self-assertion limitation): monitoring is secured by the
// bind ceremony + open source + eviction; a node self-asserts monitoring_status,
// it is NOT cert-enforced. The "app can't override" guarantee is the narrower,
// real one: copy generation is unconditional core code and the gate state is
// non-app-writable (hidden), so an honest app cannot silently disable monitoring.
library a2a_monitoring loads libraries
    current_transaction_info,
    encrypted_channel,
    a2a_messaging
    uses transactions
{
    hidden
    {
        // App-injected: store one received monitoring copy. Storage stays app-side
        // (the messenger persists the feed), like a2a_messaging's message hooks.
        // Receives ($source_id, $copy). Fires only for a known-contact sender.
        on_monitoring_copy_received is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_monitoring_copy_received hook is unset in a2a_monitoring (call a2a_monitoring::init)." when TRUE. return []. }
        // core 3.2: store one pushed roster snapshot. Fires only for a known-contact
        // sender (the node this control plane monitors). Receives ($source_id, $version, $members).
        on_roster_update is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_roster_update hook is unset in a2a_monitoring (call a2a_monitoring::init)." when TRUE. return []. }
    }

    init = fn (_:(
        $on_monitoring_copy_received -> cb: (any -> transaction::action::type[]),
        $on_roster_update -> rcb: (any -> transaction::action::type[])
    ))
    {
        on_monitoring_copy_received -> cb.
        on_roster_update -> rcb.
    }

    // Receive a forced copy from a node this control plane monitors. Storage is
    // the app's (the on_monitoring_copy_received hook); the source is the channel-
    // authenticated envelope sender, which must be a known contact. Touches no
    // gate state — purely the CP-side ingest.
    fn handle_receive_monitoring_copy (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        abort "Monitoring copy from an unknown sender was rejected." when (a2a_messaging::contacts sender_id) == NIL.
        copy = (args $copy) safe a2a_messaging::monitoring_copy_t.
        abort "Unsupported monitoring copy version." when (copy $version) != 1.

        return transaction::success (on_monitoring_copy_received (
            $source_id -> sender_id,
            $copy      -> copy
        )).
    }

    trn receive_monitoring_copy args: any
    {
        return handle_receive_monitoring_copy args.
    }

    // core 3.2: receive a roster snapshot pushed by a node we control. Same CP-side
    // ingest contract as receive_monitoring_copy — known-contact sender only, no gate
    // state touched; the app stores it (on_roster_update). $members is opaque (the app
    // interprets member_t); $version lets the app dedup/order.
    fn handle_receive_roster_update (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        abort "Roster update from an unknown sender was rejected." when (a2a_messaging::contacts sender_id) == NIL.
        return transaction::success (on_roster_update (
            $source_id -> sender_id,
            $version   -> (args $version),
            $members   -> (args $members)
        )).
    }

    trn receive_roster_update args: any { return handle_receive_roster_update args. }
}
