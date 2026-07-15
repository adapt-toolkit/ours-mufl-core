// Shared driver harness for the loopback test suites.
//
// Extracted from test.mjs so both test.mjs (T/V/RC-series, messaging-only unit)
// and notif.mjs (N-series, notifications unit) import ONE copy of the wrapper /
// packet bootstrap + the mk/wire/mutate/ro/binv/mkPacket/sleep/log helpers
// instead of duplicating them. Each driver keeps its own tiny scorecard/ok/CUR
// local (they differ in prose and are trivially cheap).
//
// The `wire` handler preserves the protocol_error/notify_agent error-as-data
// capture verbatim (the V-series Additions A/B assertions read code/message/
// context/surface off id.errEvents).
import { resolve } from 'node:path';
import * as fs from 'node:fs';
import { adapt_wrapper } from '@adapt-toolkit/sdk/executables';
import { PacketWrapperConfigurator } from '@adapt-toolkit/sdk/wrappers';
import { object_to_adapt_value } from '@adapt-toolkit/sdk/wrapper';

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Pure per-node state record.
export function mk(name) {
  return { name, pw: null, cid: '', pending: [], rejects: [], events: [], errEvents: [] };
}

// Build a harness bound to one broker + unit dir. Returns the driver helpers,
// each of which closes over the shared `wrapper` and unit metadata.
export async function createHarness({ brokerUrl, unitDir, logTag = 't' }) {
  const UNIT_DIR = resolve(unitDir);
  const unitHash = fs.readdirSync(UNIT_DIR).find((f) => f.endsWith('.muflo')).slice(0, -'.muflo'.length);
  const UNIT = new Uint8Array(fs.readFileSync(resolve(UNIT_DIR, `${unitHash}.muflo`)));
  const log = (...a) => process.stderr.write(`[${logTag}] ${a.join(' ')}\n`);

  function wire(id) {
    id.pw.on_return_data = (d) => {
      const kind = d.Reduce('kind').Visualize();
      if (kind === 'notify_agent') {
        const ev = d.Reduce('payload').Reduce('event').Visualize();
        id.events.push(ev);
        // Capture the full error-as-data payload for $protocol_error events
        // (Additions A/B assertions read code/message/context off it).
        if (ev === 'protocol_error') {
          const p = d.Reduce('payload');
          id.errEvents.push({
            context: p.Reduce('context').Visualize(),
            message: p.Reduce('message').Visualize(),
            code: p.Reduce('error').Reduce('code').Visualize(),
            errMessage: p.Reduce('error').Reduce('message').Visualize(),
            peerVersion: p.Reduce('error').Reduce('peer_version').Visualize(),
            minSupported: p.Reduce('error').Reduce('min_supported').Visualize(),
            surface: p.Reduce('error').Reduce('surface').Visualize(),
          });
        }
        return;
      }
      if (kind === 'save_state') return;
      const p = id.pending.shift(); if (!p) return;
      clearTimeout(p.timer); p.resolve(d.Reduce('payload'));
    };
    id.pw.on_transaction_failure = (msg) => {
      const p = id.pending.shift();
      if (p) { clearTimeout(p.timer); p.reject(new Error(msg)); }
      else { id.rejects.push(String(msg)); log(`${id.name} inbound rejected:`, String(msg).split('\n')[0]); }
    };
  }

  const wrapper = await adapt_wrapper.start(['--broker_address', brokerUrl, '--test_mode',
    '--logger_config', '--level', 'WARNING', '--stdout', 'stderr', '--logger_config_end']);
  wrapper.start();
  await sleep(1500);

  function mutate(id, name, targ) {
    return new Promise((res, rej) => {
      const timer = setTimeout(() => rej(new Error(`${id.name}.${name} timed out`)), 20000);
      id.pending.push({ resolve: res, reject: rej, timer });
      id.pw.add_client_message(object_to_adapt_value({ name, targ }));
    });
  }
  const ro = (id, name, targ) => id.pw.packet.ExecuteTransaction(object_to_adapt_value({ name, targ }));
  const binv = (id, buf) => id.pw.packet.NewBinaryFromBuffer(Buffer.from(buf));
  async function mkPacket(id, seed) {
    const cfg = new PacketWrapperConfigurator();
    cfg.process_arguments(['--unit_hash', unitHash, '--seed_phrase', seed, '--unit_dir_path', UNIT_DIR]);
    await new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error(`${id.name} create timeout`)), 30000);
      wrapper.packet_manager.create_packet(cfg, (pw) => {
        clearTimeout(t); id.pw = pw; id.cid = pw.packet.GetContainerID().Visualize(); wire(id);
        log(`${id.name} cid ${id.cid.slice(0, 12)}…`); res();
      }, UNIT);
    });
  }

  return { wrapper, UNIT_DIR, unitHash, mk, wire, mutate, ro, binv, mkPacket, sleep, log };
}
