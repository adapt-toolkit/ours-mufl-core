// COMPILE-ONLY regression guard for the daemon build path (issue: the migration core
// overflowed the per-unit meta-stage reduction fuel — adapt src/eval/meta_reduction_fuel.h,
// 1M steps — when compiled into a FULL ours-mcp daemon packet, because a dead 5th
// transaction::type wire-union variant (e2e_signed_message, Option A) inflated __t_wrapper's
// per-transaction body SAFE-cast reduction; fixed by dropping the variant → 4 variants).
//
// This actor deliberately loads the HEAVY daemon-side libraries TOGETHER —
//   a2a_messaging (the migration surface) + a2a_cluster + a2a_capabilities —
// which is the composition the real ours-mcp daemon actor.mu uses (per its compile trace: it loads
// a2a_messaging + a2a_cluster). It goes through the SAME __t_wrapper meta path at ~daemon
// transaction-count scale that no other test unit exercised (mig/migapp/test/notif each load a
// SUBSET, and none combine messaging+cluster). If the migration core ever re-inflates __t_wrapper's
// per-transaction body SAFE-cast reduction past the ceiling, THIS compile fails — catching it in-repo
// instead of at the daemon. It defines NO qa probes and runs no driver; producing a .muflo IS the
// whole test (see run_fatcompile.sh). Keep it lean: it stresses type-level reduction, not runtime.
application actor loads libraries
    identity_proof_document,
    attestation_document,
    native_attestation_document,
    transaction_message_decoder,
    address_document,
    address_document_types,
    key_utils,
    key_storage,
    continuation,
    encrypted_channel,
    a2a_versions,
    a2a_capabilities,
    a2a_protocol,
    a2a_messaging,
    a2a_cluster,
    current_transaction_info,
    protocol_container,
    version
    uses transactions
{
    hidden
    {
        _read_or_abort = grab( _read_or_abort ).
        key_storage::init ($_read_or_abort -> _read_or_abort).
        encrypted_channel::init ($_read_or_abort -> _read_or_abort).
        a2a_messaging::init (
            $_read_or_abort      -> _read_or_abort,
            $on_message_received -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_message_sent     -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_contact_removed  -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_file_received    -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_file_sent        -> fn (_: any) -> transaction::action::type[] { return []. },
            $on_receipt_received -> fn (_: any) -> transaction::action::type[] { return []. }
        ).
    }
}
