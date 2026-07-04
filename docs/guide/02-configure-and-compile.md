# 02 · Configure & compile

The core is a set of pure MUFL libraries with no standalone build — *your* `config.mufl`
merges its exports with the MUFL stdlib, and *your* application file loads the libraries
by name. This page produces your first compiled packet (`.muflo`).

**Prereqs:**

- [01 · Vendor the core](./01-vendor-the-core.md) completed (`mufl_code/core` populated).
- `$ADAPT_TOOLKIT` exported (see [Start here](./index.md)).

**Steps:**

1. Create `mufl_code/config.mufl`. The core ships its own compile configuration whose
   `$exports` block lists the seven libraries; your top-level config pulls it in with
   `config_load #"core"` and merges it with the stdlib:

   ```mufl
   config script
   {
       stdlib_config = (config_load #$MUFL_STDLIB_PATH).
       core_config = (config_load #"core").
       (
           $imports ->
           (
               $libraries ->
                   (stdlib_config $exports $libraries)
                   '(core_config $exports $libraries)
                   '($protocol_container -> #"protocol_container.mm"),
           ),
           $exports -> ( $libraries -> (,), $applications -> (,) )
       ).
   }
   ```

2. Create `mufl_code/protocol_container.mm`. This is a **boot requirement**: the SDK
   runs `::protocol_container::init_my_ipd` on every packet during broker registration,
   so every application packet must ship this library (the config above maps it in).
   [03 · Wire the host](./03-wire-the-host.md) explains the boot sequence; the stub is:

   ```mufl
   // Minimal protocol_container library — provides ::protocol_container::init_my_ipd,
   // which the ADAPT wrapper runs on every packet during broker registration
   // (possession-proof / identity-proof-document setup). Mirrors the toolkit's
   // per-unit protocol_container stub; deps resolve from the stdlib.
   library protocol_container loads libraries
       identity_proof_document,
       identity_proof_document_types,
       native_attestation_document,
       browser_attestation_document,
       current_transaction_info
       uses transactions
   {
       trn init_my_ipd _ {
           current_transaction_info::validate_origin (::transaction::envelope::origin::user,).
           identity_proof_document_types::set_my_ipd(identity_proof_document::create()).
           return ::transaction::success [].
       }
   }
   ```

3. Create a minimal application, `mufl_code/my_agent.mu`. The file name is yours; the
   application **name** must be `actor` (the wire-visible inbound transaction names are
   `::actor::*` — [03 · Wire the host](./03-wire-the-host.md) covers why):

   ```mufl
   // Minimal first packet: proves the config merge + compile work.
   application actor loads libraries
       protocol_container,
       version
       uses transactions
   {
       trn readonly get_version _ { return ($core -> (version::get_core_version NIL)). }
   }
   ```

4. Compile from inside `mufl_code/`:

   ```sh
   cd mufl_code
   MUFL_STDLIB_PATH="$ADAPT_TOOLKIT/mufl_stdlib" \
     "$ADAPT_TOOLKIT/build.linux.release/mufl-compile" \
     -mp "$ADAPT_TOOLKIT/meta" -mp "$ADAPT_TOOLKIT/transactions" my_agent.mu
   ```

   `Unused symbol` warnings from stdlib libraries are expected noise.

**Verify:**

```sh
ls *.muflo
```

Success markers:

- The compiler's last line is `SAVED TO FILE: <…muflo>`.
- `ls *.muflo` shows exactly one content-hash-named unit, e.g.
  `2272124BF5B3D5E124487F68AFCC075581688F01A055EBC54F8C6EC6CC3047A5.muflo`.

Next: [03 · Wire the host](./03-wire-the-host.md).
