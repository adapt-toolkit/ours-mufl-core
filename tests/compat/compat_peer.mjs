#!/usr/bin/env node
// Per-process peer driver for the compat matrix. One process = one runtime = one packet.
//
// Loaded from a build dir whose node_modules symlink points at THIS peer's sdk era and
// whose cwd holds THIS peer's compiled unit — the orchestrator (compat.mjs) never mixes
// runtimes in-process. Commands arrive as JSON lines on stdin; every command produces
// exactly one JSON line on stdout: {id, ok, value?, error?}. Async inbound traffic is
// surfaced via unsolicited {event: ...} lines the orchestrator collects per peer.
//
// The verb surface is data, not code: cross-version differences live in the legs
// (compat.mjs), which pick per-era transaction names; this driver just executes them.
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

const out = (obj) => process.stdout.write(JSON.stringify(obj) + '\n');
const pending = [];
let pw = null;
let saveRequested = false;

function wire(p) {
  p.on_return_data = (d) => {
    const kind = d.Reduce('kind').Visualize();
    if (kind === 'notify_agent') {
      try { out({ event: d.Reduce('payload').Reduce('event').Visualize() }); } catch { out({ event: 'unparsed' }); }
      return;
    }
    if (kind === 'save_state') { saveRequested = true; return; }
    const w = pending.shift(); if (!w) return;
    clearTimeout(w.timer); w.resolve(d.Reduce('payload'));
  };
  p.on_transaction_failure = (msg) => {
    const w = pending.shift();
    if (w) { clearTimeout(w.timer); w.reject(new Error(msg)); }
  };
}

function tx(verb, arg, readonly, timeoutMs = 20000) {
  return new Promise((resolveP, rejectP) => {
    const timer = setTimeout(() => { pending.shift(); rejectP(new Error(`timeout: ${verb}`)); }, timeoutMs);
    pending.push({ resolve: resolveP, reject: rejectP, timer });
    const v = arg === undefined ? object_to_adapt_value({}) : object_to_adapt_value(arg);
    if (readonly) pw.packet.ExecuteReadonlyTransaction(verb, v); else pw.packet.ExecuteTransaction(verb, v);
  });
}

async function boot() {
  const wrapper = adapt_wrapper.start(['--broker_url', BROKER_URL]);
  await new Promise((r) => { wrapper.on_started = r; wrapper.start(); });
  const conf = new PacketWrapperConfigurator();
  conf.process_arguments(['--unit_hash', unitHash, '--seed_phrase', SEED, '--unit_dir_path', UNIT_DIR]);
  pw = await new Promise((r) => { wrapper.packet_manager.create_packet(conf, (p) => r(p), { [unitHash]: UNIT }); });
  wire(pw);
  if (STATE_FILE && fs.existsSync(STATE_FILE)) {
    const bytes = new Uint8Array(fs.readFileSync(STATE_FILE));
    await tx('::actor::import_state', pw.packet.ParseValue(bytes), false);
    out({ event: 'state_imported' });
  }
  out({ ready: true, cid: pw.packet.GetContainerID().Visualize() });
}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', async (line) => {
  let cmd;
  try { cmd = JSON.parse(line); } catch { return out({ id: null, ok: false, error: 'bad json' }); }
  const { id, op } = cmd;
  try {
    if (op === 'tx') {
      const payload = await tx(cmd.verb, cmd.arg, !!cmd.readonly);
      return out({ id, ok: true, value: payload ? payload.Visualize() : null });
    }
    if (op === 'export_state') {
      const payload = await tx('::actor::export_state', undefined, true);
      fs.writeFileSync(cmd.file, Buffer.from(payload.Serialize()));
      return out({ id, ok: true, value: { saveRequested } });
    }
    if (op === 'exit') { out({ id, ok: true }); process.exit(0); }
    return out({ id, ok: false, error: `unknown op ${op}` });
  } catch (err) {
    return out({ id, ok: false, error: String(err) });
  }
});

boot().catch((e) => { out({ fatal: String(e) }); process.exit(1); });
