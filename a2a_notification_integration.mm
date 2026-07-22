// Core-owned notification integration for ordinary message sends.
//
// Recipients hand each sender a scoped notify_address_t over their established
// encrypted channel. This library owns those opaque handouts, persists them,
// and installs the optional a2a_messaging successful-send middleware. Missing
// or deleted handouts are no-ops; notification delivery is fire-and-forget.
library a2a_notification_integration loads libraries
    current_transaction_info,
    encrypted_channel,
    a2a_messaging,
    a2a_notifications
    uses transactions
{
    receive_notify_address_tx = "::a2a_notification_integration::receive_notify_address".

    // Peer cid -> validated serialized notify_address_t. Opaque serialized
    // storage composes cleanly beside a2a_messaging::export_core_state.
    received_notify_addresses is (global_id ->> bin) = (,).

    metadef integration_state_t: (
        $version -> int,
        $received_notify_addresses -> (global_id ->> bin)
    ).

    fn _save_state (_) = (transaction::action::return_data ($kind -> $save_state)).

    // Relationship binding is checked at the handout boundary. The service
    // later validates the token against its signed live exact-token store; the
    // current protocol intentionally requires no sender<->service contact.
    fn validate_address_for (recipient: global_id, blob: bin) -> a2a_notifications::notify_address_t
    {
        addr = a2a_notifications::decode_notify_address blob.
        abort "Notify address token recipient does not match its sender." when (addr $token $c $recipient_cid) != recipient.
        abort "Notify address token is not scoped to this sender." when (addr $token $c $scope) != _str (_get_container_id()).
        return addr.
    }

    // Ordinary consumers are notification clients, not notification services.
    // Install safe no-op service/UI callbacks here so they only need to init
    // this integration. A service host may call a2a_notifications::init after
    // this function to replace the defaults with durable/WebPush hooks.
    init = fn (_:($_read_or_abort -> read: (bin->any)))
    {
        a2a_notifications::init (
            $_read_or_abort -> read,
            $on_notification_posted -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_notifications_marked_read -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_unregistered -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_notify_registration -> fn (_: any) -> transaction::action::type[] { return []. }
        ).
        a2a_messaging::set_post_send_middleware (fn (arg: any) -> transaction::action::type[]
        {
            target_id = (arg $target_id) safe global_id.
            address = received_notify_addresses target_id.
            if address == NIL { return []. }

            wire_id = (arg $wire_id) safe str.
            // Built only from stringified global ids and wire ids, whose hex
            // alphabets require no JSON escaping.
            payload = "{\"v\":1,\"kind\":\"message\",\"sender\":\"" +
                (_str (_get_container_id())) + "\",\"wire_id\":\"" + wire_id + "\"}".
            return [ a2a_notifications::notification_send_action address? payload wire_id ].
        }).
    }

    fn handle_receive_notify_address (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort ().
        from = current_transaction_info::get_external_envelope_or_abort() $from.

        if (args $address) == NIL
        {
            if (received_notify_addresses from) != NIL { delete received_notify_addresses from. }
            return transaction::success [ _save_state NIL ].
        }

        blob = (args $address) safe bin.
        validate_address_for from blob.
        received_notify_addresses from -> blob.
        return transaction::success [ _save_state NIL ].
    }

    trn receive_notify_address args: any
    {
        return handle_receive_notify_address args.
    }

    // Recipient-side distribution: build the sender-scoped handout from the
    // notification client mirror and deliver it over the existing encrypted
    // contact channel. Consumers retain only UI policy, not protocol state.
    trn send_notify_address _:($service -> service_ref: str, $contact -> contact_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        target_id = a2a_messaging::resolve_contact contact_ref.
        blob = a2a_notifications::build_notify_address service_ref contact_ref.
        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> receive_notify_address_tx,
                    $targ -> ($address -> blob)
                ),
                transaction::action::return_data ($kind -> $data, $payload -> ($sent_to -> target_id)),
                _save_state NIL
            ].
        }).
    }

    // NIL is the wire-level mute/removal signal and intentionally leaves the
    // ordinary messaging relationship untouched.
    trn delete_notify_address _:($contact -> contact_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        target_id = a2a_messaging::resolve_contact contact_ref.
        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> receive_notify_address_tx,
                    $targ -> ($address -> NIL)
                ),
                transaction::action::return_data ($kind -> $data, $payload -> ($sent_to -> target_id)),
                _save_state NIL
            ].
        }).
    }

    fn export_state (_) -> integration_state_t
    {
        return (
            $version -> 1,
            $received_notify_addresses -> received_notify_addresses
        ).
    }

    fn import_state (data: any) -> nil
    {
        abort "Unsupported notification integration state version." when ((data $version) safe int) != 1.
        imported = (data $received_notify_addresses) safe (global_id ->> bin).
        // Validate now so a corrupt local snapshot cannot turn a later accepted
        // send_message into a middleware parse abort.
        sc imported -- (peer -> blob) { validate_address_for peer blob. }
        received_notify_addresses -> imported.
    }
}
