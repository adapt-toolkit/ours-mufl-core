# 03 · Wire the host

The core deliberately owns **no storage**: your application decides where messages,
files, and state live, and hands the core a set of hooks at init time. This page
replaces the minimal actor from page 02 with the real host wiring. The core's own
[`tests/test_actor.mu`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/tests/test_actor.mu)
is the living reference implementation of this minimal wiring — the actor below is a
trimmed version of the same pattern.

Four things every host actor must get right:

1. **The application is named `actor`.** Two wire-visible inbound transaction names are
   fixed as `::actor::accept_contact` and `::actor::receive_message` (compatibility with
   pre-migration clients — see the header of
   [`a2a_messaging.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_messaging.mm)).
   A peer's `send_message` delivers to `::actor::receive_message`, so your application
   must carry that name and ship a one-line shim that delegates to
   `a2a_messaging::handle_receive_message`. All newer inbound legs (invite redeem,
   files, restore) are library-routed and need no shim.
2. **Init wiring.** `key_storage`, `encrypted_channel`, and `a2a_messaging` each take an
   `init` call in your actor's `hidden` block: the first two need the `_read_or_abort`
   deserialization primitive; `a2a_messaging::init` additionally takes your storage
   hooks (`on_message_received`, `on_message_sent`, `on_contact_removed`,
   `on_file_received`, `on_file_sent`). Hooks return host-protocol *actions* — the
   `return_data` records your Node driver resolves on (page 04).
3. **Export/import composition.** The core's portable state is
   `a2a_messaging::export_core_state` / `import_core_state`; your `export_state` wraps
   it under a `$core` key **alongside** your own app state, so a migration moves both.
   Ephemeral invite secrets are deliberately excluded from the export.
4. **Packet-boot requirement.** The SDK runs `::protocol_container::init_my_ipd` on
   every packet during broker registration — that is why page 02 shipped the
   `protocol_container` stub and why the actor loads it. Note: REAL multi-process broker
   routing additionally requires a `registration_proof` (a broker nonce-challenge); the
   local loopback used in pages 04–05 delivers packets inside one wrapper process, so it
   never exercises that step. When you move to a deployed broker, use a consumer repo's
   registration wiring as your reference.

**Prereqs:**

- [02 · Configure & compile](./02-configure-and-compile.md) completed (first `.muflo` built).
- `$ADAPT_TOOLKIT` exported.

**Steps:**

1. Replace `mufl_code/my_agent.mu` with the wired actor:

   ```mufl
   // my_agent — a minimal host actor consuming the ours-mufl-core protocol.
   // Modeled on the core's own tests/test_actor.mu (the living reference for
   // minimal host wiring): storage hooks, init wiring, export/import composition.
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
       a2a_protocol,
       a2a_messaging,
       current_transaction_info,
       protocol_container,
       version
       uses transactions
   {
       hidden
       {
           // The app owns message storage; the core calls the hook.
           metadef msg_t: ($sender -> global_id, $text -> str, $wire_id -> str).
           inbox is msg_t[] = [].

           // Wire the deserialization primitive into the libraries that need it.
           _read_or_abort = grab( _read_or_abort ).
           key_storage::init ($_read_or_abort -> _read_or_abort).
           encrypted_channel::init ($_read_or_abort -> _read_or_abort).

           // Host-protocol action helpers (the driver resolves on kind "data").
           fn _save_state (_) = (transaction::action::return_data ($kind -> $save_state)).
           fn _return_data (payload: any) = (transaction::action::return_data ($kind -> $data, $payload -> payload)).
           fn _notify_agent (payload: any) = (transaction::action::return_data ($kind -> $notify_agent, $payload -> payload)).

           // Storage hooks: deposit inbound messages; the rest are no-ops here.
           a2a_messaging::init (
               $_read_or_abort -> _read_or_abort,
               $on_message_received -> fn (arg: any) -> transaction::action::type[]
               {
                   sid = (arg $sender_id) safe global_id.
                   txt = (arg $text) safe str.
                   wid is str = "".
                   if (arg $wire_id) != NIL { wid -> (arg $wire_id) safe str. }
                   inbox (_count inbox|) -> ($sender -> sid, $text -> txt, $wire_id -> wid).
                   return [ _notify_agent ($event -> $message_received), _save_state NIL ].
               },
               $on_message_sent -> fn (_: any) -> transaction::action::type[] { return []. },
               $on_contact_removed -> fn (_: any) -> transaction::action::type[] { return []. },
               $on_file_received -> fn (_: any) -> transaction::action::type[] { return []. },
               $on_file_sent -> fn (_: any) -> transaction::action::type[] { return []. }
           ).
       }

       // The core's send_message delivers to the legacy ::actor::receive_message name;
       // this shim routes it into the core receive handler (→ on_message_received hook).
       trn receive_message args: any { return a2a_messaging::handle_receive_message args. }
       trn readonly list_incoming_messages _ { return ($inbox -> inbox). }

       // Version probe: the compiled-in core version, observable at runtime.
       trn readonly get_version _ { return ($core -> (version::get_core_version NIL)). }

       // Migration: compose YOUR app state around the core's portable export.
       trn readonly export_state _
       {
           return ($core -> (a2a_messaging::export_core_state NIL), $app -> ($inbox -> inbox)).
       }
       trn import_state data: any
       {
           current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
           a2a_messaging::import_core_state (data $core).
           inbox -> ((data $app $inbox) safe (msg_t[])).
           return transaction::success [ _return_data ($imported -> TRUE), _save_state NIL ].
       }
   }
   ```

   Syntax gotcha: typed-list casts need parentheses — `safe (msg_t[])`, not
   `safe msg_t[]`.

2. Recompile (remove the previous unit first; the output name is a content hash, so a
   changed source produces a *second* `.muflo` otherwise):

   ```sh
   cd mufl_code
   rm -f *.muflo
   MUFL_STDLIB_PATH="$ADAPT_TOOLKIT/mufl_stdlib" \
     "$ADAPT_TOOLKIT/build.linux.release/mufl-compile" \
     -mp "$ADAPT_TOOLKIT/meta" -mp "$ADAPT_TOOLKIT/transactions" my_agent.mu
   ```

**Verify:**

```sh
ls *.muflo
```

Success markers:

- Compiler ends with `SAVED TO FILE: <…muflo>`.
- `ls *.muflo` shows exactly one unit (a new hash — the old one is gone).

For what the hooks feed into — deferred sends, degraded contacts, restore — see
[Messaging](../how-it-works/messaging.md). Next:
[04 · Connect & message](./04-connect-and-message.md).
