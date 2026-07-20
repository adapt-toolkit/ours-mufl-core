#!/usr/bin/env node
// Per-process peer driver for the compat matrix. One process = one runtime = one packet.
//
// Loaded from a build dir whose node_modules symlink points at THIS peer's sdk era and
// whose cwd holds THIS peer's compiled unit — the orchestrator (compat.mjs) never mixes
// runtimes in-process. Commands arrive as JSON lines on stdin; every command produces
// exactly one JSON line on stdout: {id, ok, value?, error?}. Async inbound traffic is
// surfaced via unsolicited {event} lines. Boot/mutate/ro shapes mirror tests/test_common.mjs
// (the era-stable driver conventions: add_client_message + on_return_data pending queue).
import { resolve } from 'node:path';
import * as fs from 'node:fs';
import * as readline from 'node:readline';
import { adapt_wrapper } from '@adapt-toolkit/sdk/executables';
import { PacketWrapperConfigurator } from '@adapt-toolkit/sdk/wrappers';
import { object_to_adapt_value } from '@adapt-toolkit/sdk/wrapper';

const BROKER_URL = process.env.BROKER_URL || 'ws://127.0.0.1:9797';
const SEED = process.env.PEER_SEED || `compat seed ${process.env.PEER_NAME || 'peer'}`;
const STATE_FILE = process.env.PEER_STATE_FILE || ''; // set ⇒ import on boot if present
const UNIT_DIR = resolve('.');
const unitHash = fs.readdirSync(UNIT_DIR).find((f) => f.endsWith('.muflo')).slice(0, -'.muflo'.length);
const UNIT = new Uint8Array(fs.readFileSync(resolve(UNIT_DIR, `${unitHash}.muflo`)));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const out = (obj) => process.stdout.write(JSON.stringify(obj) + '\n');
const pending = [];
let pw = null;

function wire() {
  pw.on_return_data = (d) => {
    const kind = d.Reduce('kind').Visualize();
    if (kind === 'notify_agent') {
      try { out({ event: d.Reduce('payload').Reduce('event').Visualize() }); } catch { out({ event: 'unparsed' }); }
      return;
    }
    if (kind === 'save_state') return;
    const w = pending.shift(); if (!w) return;
    clearTimeout(w.timer); w.resolve(d.Reduce('payload'));
  };
  pw.on_transaction_failure = (msg) => {
    const w = pending.shift();
    if (w) { clearTimeout(w.timer); w.reject(new Error(msg)); }
    else out({ event: `inbound-reject: ${String(msg).split('\n')[0]}` });
  };
}

function mutate(name, targ) {
  return new Promise((res, rej) => {
    const timer = setTimeout(() => { rej(new Error(`timeout: ${name}`)); }, 20000);
    pending.push({ resolve: res, reject: rej, timer });
    pw.add_client_message(object_to_adapt_value({ name, targ }));
  });
}
const ro = (name, targ) => pw.packet.ExecuteTransaction(object_to_adapt_value({ name, targ }));
const binv = (buf) => pw.packet.NewBinaryFromBuffer(Buffer.from(buf));

async function boot() {
  const wrapper = await adapt_wrapper.start(['--broker_address', BROKER_URL, '--test_mode',
    '--logger_config', '--level', 'WARNING', '--stdout', 'stderr', '--logger_config_end']);
  wrapper.start();
  await sleep(1500);
  const cfg = new PacketWrapperConfigurator();
  cfg.process_arguments(['--unit_hash', unitHash, '--seed_phrase', SEED, '--unit_dir_path', UNIT_DIR]);
  await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error('create timeout')), 30000);
    wrapper.packet_manager.create_packet(cfg, (p) => { clearTimeout(t); pw = p; wire(); res(); }, UNIT);
  });
  if (STATE_FILE && fs.existsSync(STATE_FILE)) {
    // Import failure must not kill the peer — mirror the consumer posture
    // (tg-connector: continue with the fresh identity, blob preserved): the
    // M9 leg asserts exactly this reject-to-functional behavior.
    try {
      const bytes = fs.readFileSync(STATE_FILE);
      await mutate('::actor::import_state', pw.packet.ParseValue(new Uint8Array(bytes)));
      out({ event: 'state_imported' });
    } catch (err) {
      out({ event: `import_failed: ${String(err).split('\n')[0]}` });
    }
  }
  out({ ready: true, cid: pw.packet.GetContainerID().Visualize() });
}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', async (line) => {
  let cmd;
  try { cmd = JSON.parse(line); } catch { return out({ id: null, ok: false, error: 'bad json' }); }
  const { id, op } = cmd;
  try {
    switch (op) {
      case 'invite': {
        const m = await mutate('::a2a_messaging::generate_invite', { name: cmd.name });
        return out({ id, ok: true, value: Buffer.from(m.Reduce('invite').GetBinary()).toString('base64') });
      }
      case 'redeem': {
        await mutate('::a2a_messaging::add_contact',
          { invite: binv(Buffer.from(cmd.invite_b64, 'base64')), name: cmd.name });
        return out({ id, ok: true });
      }
      case 'send': {
        const m = await mutate('::a2a_messaging::send_message', { contact: cmd.cid, text: cmd.text });
        // route: 'e2e' (double ratchet) | 'migrating' | absent/NIL = legacy box
        return out({ id, ok: true, value: { wire_id: m.Reduce('wire_id').Visualize(), route: m.Reduce('route').Visualize() } });
      }
      case 'tx': {
        const m = await mutate(cmd.verb, cmd.targ);
        return out({ id, ok: true, value: m ? m.Visualize() : null });
      }
      case 'send_file': {
        const m = await mutate('::a2a_messaging::send_file', {
          contact: cmd.cid, filename: cmd.filename, mime: cmd.mime || 'application/octet-stream',
          data: binv(Buffer.from(cmd.data_b64, 'base64')),
        });
        return out({ id, ok: true, value: m.Reduce('wire_id').Visualize() });
      }
      case 'contacts': return out({ id, ok: true, value: ro('::a2a_messaging::list_contacts', undefined).Visualize() });
      case 'inbox': return out({ id, ok: true, value: ro('::actor::list_incoming_messages', undefined).Visualize() });
      case 'files': return out({ id, ok: true, value: ro('::actor::list_incoming_files', undefined).Visualize() });
      case 'export_state': {
        const exported = ro('::actor::export_state', undefined);
        fs.writeFileSync(cmd.file, Buffer.from(exported.Serialize()));
        return out({ id, ok: true });
      }
      case 'exit': out({ id, ok: true }); return process.exit(0);
      default: return out({ id, ok: false, error: `unknown op ${op}` });
    }
  } catch (err) {
    return out({ id, ok: false, error: String(err) });
  }
});

boot().catch((e) => { out({ fatal: String(e) }); process.exit(1); });
