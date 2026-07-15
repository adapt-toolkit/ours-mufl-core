#!/usr/bin/env node
// Phase-A migration gate: the three new 0.9.0 stores (contact_migration /
// contact_e2e_epoch / mig_deferred) round-trip through export_core_state, and a
// pre-0.9 blob (fields absent) imports to empty (= legacy, spec §5.1). Runs the
// lean mig_actor.mu unit (loads a2a_messaging WITHOUT a2a_notifications, so it
// stays well under the per-unit meta-reduction fuel budget). Single packet, no
// peer traffic. Run via tests/run_mig.sh.
import { resolve } from 'node:path';
import * as fs from 'node:fs';
import { adapt_wrapper } from '@adapt-toolkit/sdk/executables';
import { PacketWrapperConfigurator } from '@adapt-toolkit/sdk/wrappers';
import { object_to_adapt_value } from '@adapt-toolkit/sdk/wrapper';

const BROKER_URL = process.env.BROKER_URL || 'ws://127.0.0.1:9790';
const UNIT_DIR = resolve('.');
const unitHash = fs.readdirSync(UNIT_DIR).find((f) => f.endsWith('.muflo')).slice(0, -'.muflo'.length);
const UNIT = new Uint8Array(fs.readFileSync(resolve(UNIT_DIR, `${unitHash}.muflo`)));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => process.stderr.write(`[mig] ${a.join(' ')}\n`);
const scorecard = [];
const ok = (c, m) => { if (!c) { scorecard.push(`✗ ${m}`); console.log(`  ✗ FAIL: ${m}`); } else { console.log(`  ✓ ${m}`); } };

async function main() {
  const wrapper = await adapt_wrapper.start(['--broker_address', BROKER_URL, '--test_mode',
    '--logger_config', '--level', 'WARNING', '--stdout', 'stderr', '--logger_config_end']);
  wrapper.start();
  await sleep(1500);

  const id = { name: 'M', pw: null, pending: [] };
  id.wire = () => {
    id.pw.on_return_data = (d) => {
      const kind = d.Reduce('kind').Visualize();
      if (kind === 'notify_agent' || kind === 'save_state') return;
      const p = id.pending.shift(); if (!p) return;
      clearTimeout(p.timer); p.resolve(d.Reduce('payload'));
    };
    id.pw.on_transaction_failure = (msg) => {
      const p = id.pending.shift();
      if (p) { clearTimeout(p.timer); p.reject(new Error(msg)); }
    };
  };
  const cfg = new PacketWrapperConfigurator();
  cfg.process_arguments(['--unit_hash', unitHash, '--seed_phrase', 'mig-gate-01', '--unit_dir_path', UNIT_DIR]);
  await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error('packet create timeout')), 30000);
    wrapper.packet_manager.create_packet(cfg, (pw) => { clearTimeout(t); id.pw = pw; id.wire(); res(); }, UNIT);
  });
  await sleep(800);
  const mutate = (name, targ) => new Promise((res, rej) => {
    const timer = setTimeout(() => rej(new Error(`${name} timed out`)), 20000);
    id.pending.push({ resolve: res, reject: rej, timer });
    id.pw.add_client_message(object_to_adapt_value({ name, targ }));
  });
  const T = (s) => /true/i.test(String(s));

  console.log('=== mig: export round-trip (3 new 0.9.0 stores travel the blob) ===');
  const r = await mutate('::actor::qa_mig_export_roundtrip', {});
  const g = (k) => r.Reduce(k).Visualize();
  ok(T(g('has_migration')), 'export_core_state carries $contact_migration');
  ok(T(g('has_epoch')), 'export_core_state carries $contact_e2e_epoch');
  ok(T(g('has_deferred')), 'export_core_state carries $mig_deferred');
  ok(g('phase') === 'active', 'exported FSM entry preserves $phase (active)');
  ok(T(g('epoch_sid_present')), 'exported epoch pin preserves $session_id (canonical bytes)');
  ok(g('deferred_len') === '1', 'exported mig_deferred preserves the queued message');

  console.log('=== mig: pre-0.9 import → migration stores empty (absence = legacy) ===');
  const r2 = await mutate('::actor::qa_mig_import_legacy', {});
  const g2 = (k) => r2.Reduce(k).Visualize();
  ok(T(g2('migration_absent')), 'pre-0.9 blob import: contact_migration stays empty');
  ok(T(g2('epoch_absent')), 'pre-0.9 blob import: contact_e2e_epoch stays empty');
  ok(T(g2('deferred_absent')), 'pre-0.9 blob import: mig_deferred stays empty');

  console.log('\n================ MIG ================');
  if (scorecard.length === 0) console.log('MIG: ALL GREEN');
  else { console.log(`${scorecard.length} FAILURE(S):`); scorecard.forEach((s) => console.log('  ' + s)); }
  await sleep(300);
  process.exit(scorecard.length === 0 ? 0 : 1);
}
main().catch((e) => { log('DRIVER ERR:', e.stack ?? e.message); process.exit(1); });
