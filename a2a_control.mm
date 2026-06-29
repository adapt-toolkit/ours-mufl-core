// Shared ours control-plane library.
//
// One symmetric, end-to-end-encrypted control transaction shared by every
// ours client: the MCP daemon's root packet receives control REQUESTS from
// its bound browser proxy, and the browser messenger receives control EVENTS
// (responses + monitoring batches) back from the root. Payloads are opaque
// strings (JSON by convention, see MONITORING-AND-SHARED-LIBRARY-DESIGN.md
// Part 4); the packet validates origin + sender only and delegates storage to
// the app through the on_control_received hook.
//
// Routing: this is a NEW protocol surface with no legacy clients, so both the
// inbound trn and the sender use the library-routed name directly — no
// ::actor:: compat shims.
library a2a_control loads libraries
    current_transaction_info,
    encrypted_channel,
    a2a_messaging
    uses transactions
{
    control_message_tx = "::a2a_control::control_message".

    hidden
    {
        // App-injected hook: on_control_received ($sender_id, $sender_name,
        // $payload, $app_id, $date) -> actions. Only fires for known contacts.
        on_control_received is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_control_received hook is unset in a2a_control (call a2a_control::init)." when TRUE. return []. }
        // App-declared application id, set once via init and auto-stamped onto
        // every outgoing control message so the receiver can trust which app it
        // is talking to without parsing the opaque payload. Plain string, no
        // format enforced yet; a controller (e.g. the browser messenger) passes
        // "" since it is not itself a configurable app.
        app_id is str = "".
    }

    init = fn (_:(
        $on_control_received -> received_cb: (any -> transaction::action::type[]),
        $app_id -> app_id_arg: str
    ))
    {
        on_control_received -> received_cb.
        app_id -> app_id_arg.
    }

    // Send an opaque control payload to a known contact over the encrypted
    // channel (handshake runs transparently on first contact).
    trn send_control _:($contact -> contact_ref: str, $payload -> payload: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        target_id = a2a_messaging::resolve_contact contact_ref.
        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> control_message_tx,
                    $targ -> ($payload -> payload, $app_id -> app_id)
                ),
                transaction::action::return_data ($kind -> $data, $payload -> ($sent_to -> target_id))
            ].
        }).
    }

    trn control_message args: any
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        payload = (args $payload) safe str.

        // Optional on the wire, absent from pre-1.5 senders: the sender app's
        // self-declared application id. Default "" so old payloads and hooks
        // that do not read it behave exactly as before.
        app_id is str = "".
        if (args $app_id) != NIL { app_id -> (args $app_id) safe str. }

        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        sender = a2a_messaging::contacts sender_id.
        abort "Control message from an unknown sender was rejected." when sender == NIL.
        msg_date = (current_transaction_info::get_transaction_time())?.

        return transaction::success (on_control_received (
            $sender_id   -> sender_id,
            $sender_name -> sender? $name,
            $payload     -> payload,
            $app_id      -> app_id,
            $date        -> msg_date
        )).
    }
}
