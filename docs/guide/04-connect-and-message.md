# 04 · Connect & message

Time to run the packet. The `@adapt-toolkit` Node SDK boots compiled units, a local
dev broker relays between them, and a small driver script walks the protocol:
`generate_invite` on one packet, `add_contact` on the other, then `send_message` both
ways — asserting **receiver-side** state (the peer's inbox and contact book), not just
that a send returned. This is the same loopback pattern the core's own
[`tests/test.mjs`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/tests/test.mjs)
uses. For what the three legs of the invite redeem do on the wire, see
[Invites & contacts](../how-it-works/invites-and-contacts.md).

**Prereqs:**

- [03 · Wire the host](./03-wire-the-host.md) completed (wired `.muflo` in `mufl_code/`).
- `$OURS_SDK_NODE_MODULES` and `$DEV_BROKER` exported (see [Start here](./index.md)).
- Node 18+.

**Steps:**

1. Make the SDK resolvable from `mufl_code/` (both the driver and the broker launcher
   need a `node_modules` that contains `@adapt-toolkit`):

   ```sh
   cd mufl_code
   ln -sfn "$OURS_SDK_NODE_MODULES" node_modules
   ```

2. Create `mufl_code/drive.mjs`:

   ```js
   #!/usr/bin/env node
   // Loopback driver: two packets of YOUR app on one local broker.
   // invite -> contact -> message, asserted RECEIVER-side.
   import { resolve } from 'node:path';
   import * as fs from 'node:fs';
   import { adapt_wrapper } from '@adapt-toolkit/sdk/executables';
   import { PacketWrapperConfigurator } from '@adapt-toolkit/sdk/wrappers';
   import { object_to_adapt_value } from '@adapt-toolkit/sdk/wrapper';

   const BROKER_URL = process.env.BROKER_URL || 'ws://127.0.0.1:9799';
   const UNIT_DIR = resolve('.');
   const unitHash = fs.readdirSync(UNIT_DIR).find((f) => f.endsWith('.muflo')).slice(0, -'.muflo'.length);
   const UNIT = new Uint8Array(fs.readFileSync(resolve(UNIT_DIR, `${unitHash}.muflo`)));
   const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
   let failures = 0;
   const ok = (c, m) => { console.log(`${c ? 'ok' : 'FAIL'} - ${m}`); if (!c) failures++; };

   let wrapper;
   function mk(name) { return { name, pw: null, cid: '', pending: [] }; }
   function wire(id) {
     id.pw.on_return_data = (d) => {
       const kind = d.Reduce('kind').Visualize();
       if (kind !== 'data') return; // ignore save_state / notify_agent here
       const p = id.pending.shift(); if (!p) return;
       clearTimeout(p.timer); p.resolve(d.Reduce('payload'));
     };
     id.pw.on_transaction_failure = (msg) => {
       const p = id.pending.shift();
       if (p) { clearTimeout(p.timer); p.reject(new Error(msg)); }
     };
   }
   function mutate(id, name, targ) {
     return new Promise((res, rej) => {
       const timer = setTimeout(() => rej(new Error(`${id.name}.${name} timed out`)), 20000);
       id.pending.push({ resolve: res, reject: rej, timer });
       id.pw.add_client_message(object_to_adapt_value({ name, targ }));
     });
   }
   const ro = (id, name) => id.pw.packet.ExecuteTransaction(object_to_adapt_value({ name, targ: undefined }));
   const binv = (id, buf) => id.pw.packet.NewBinaryFromBuffer(Buffer.from(buf));
   async function mkPacket(id, seed) {
     const cfg = new PacketWrapperConfigurator();
     cfg.process_arguments(['--unit_hash', unitHash, '--seed_phrase', seed, '--unit_dir_path', UNIT_DIR]);
     await new Promise((res, rej) => {
       const t = setTimeout(() => rej(new Error(`${id.name} create timeout`)), 30000);
       wrapper.packet_manager.create_packet(cfg, (pw) => {
         clearTimeout(t); id.pw = pw; id.cid = pw.packet.GetContainerID().Visualize(); wire(id); res();
       }, UNIT);
     });
   }

   async function main() {
     wrapper = await adapt_wrapper.start(['--broker_address', BROKER_URL, '--test_mode',
       '--logger_config', '--level', 'WARNING', '--stdout', 'stderr', '--logger_config_end']);
     wrapper.start();
     await sleep(1500);

     const A = mk('A'); const B = mk('B');
     await mkPacket(A, 'my-app-A-01'); await mkPacket(B, 'my-app-B-02');
     await sleep(1200);
     await mutate(A, '::a2a_messaging::set_my_name', { name: 'Alice' });
     await mutate(B, '::a2a_messaging::set_my_name', { name: 'Bob' });

     // compiled-in core version is observable at runtime
     console.log('core version:', ro(A, '::actor::get_version').Reduce('core').Visualize());

     // 1. A mints an invite
     const m = await mutate(A, '::a2a_messaging::generate_invite', { name: 'Bob' });
     const invite = Buffer.from(m.Reduce('invite').GetBinary());
     ok(invite.length > 0, 'generate_invite returned an invite blob');

     // 2. B redeems it
     await mutate(B, '::a2a_messaging::add_contact', { invite: binv(B, invite), name: 'Alice' });
     await sleep(5000);

     // 3. RECEIVER-side: both contact books list the other
     const lcA = ro(A, '::a2a_messaging::list_contacts').Visualize();
     const lcB = ro(B, '::a2a_messaging::list_contacts').Visualize();
     ok(new RegExp(B.cid).test(lcA), 'A list_contacts includes B cid');
     ok(new RegExp(A.cid).test(lcB), 'B list_contacts includes A cid');

     // 4. message round-trips over the encrypted channel, both directions
     await mutate(A, '::a2a_messaging::send_message', { contact: B.cid, text: 'hello from Alice' });
     await sleep(2500);
     ok(/hello from Alice/.test(ro(B, '::actor::list_incoming_messages').Visualize()),
       'B received A message (receiver-side inbox)');
     await mutate(B, '::a2a_messaging::send_message', { contact: A.cid, text: 'hello from Bob' });
     await sleep(2500);
     ok(/hello from Bob/.test(ro(A, '::actor::list_incoming_messages').Visualize()),
       'A received B message (receiver-side inbox)');

     console.log(failures === 0 ? 'ROUND-TRIP OK' : `${failures} FAILURE(S)`);
     await sleep(500);
     process.exit(failures === 0 ? 0 : 1);
   }
   main().catch((e) => { console.error('DRIVER ERR:', e.stack ?? e.message); process.exit(1); });
   ```

   Reading the driver: `mutate` submits a state-changing transaction through the
   wrapper's client-message path and resolves on the `$kind -> $data` action your hooks
   returned; `ro` executes a read-only transaction synchronously. The SDK's leak-tracker
   prints `###` lines at exit — expected noise.

3. Start the dev broker, run the driver, stop the broker:

   ```sh
   node "$DEV_BROKER" --host 127.0.0.1 --port 9799 --test_mode > broker.log 2>&1 &
   sleep 3
   BROKER_URL=ws://127.0.0.1:9799 node drive.mjs 2>/dev/null | grep -vE '^###'
   echo "EXIT=${PIPESTATUS[0]}"
   kill %1
   ```

**Verify:** the driver prints a `core version:` line (the `MAJ`/`MIN`/`PATCH` of the
core revision you vendored — see [Versioning](../how-it-works/versioning.md)) and five
`ok -` assertion lines, ending with the success markers:

```
ok - A received B message (receiver-side inbox)
ROUND-TRIP OK
EXIT=0
```

Any `FAIL -` line or a non-zero `EXIT` means the round-trip did not complete.

Next: [05 · Test your app](./05-test-your-app.md).
