#!/usr/bin/env node
// Golden-wire corpus gate (COMPATIBILITY.md §corpus): replay one fixture per
// REGISTERED version per registry through the a2a_versions try_narrow_* dispatch
// and assert the branch taken. Fast (single packet, no peer traffic) — run it
// via tests/run_corpus.sh, or as part of the full suite via tests/run.sh.
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
const log = (...a) => process.stderr.write(`[corpus] ${a.join(' ')}\n`);
const scorecard = [];
const ok = (c, m) => { if (!c) { scorecard.push(`✗ ${m}`); console.log(`  ✗ FAIL: ${m}`); } else { console.log(`  ✓ ${m}`); } };

async function main() {
  const wrapper = await adapt_wrapper.start(['--broker_address', BROKER_URL, '--test_mode',
    '--logger_config', '--level', 'WARNING', '--stdout', 'stderr', '--logger_config_end']);
  wrapper.start();
  await sleep(1500);

  const id = { name: 'C', pw: null, pending: [], rejects: [] };
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
      else { id.rejects.push(String(msg)); }
    };
  };
  const cfg = new PacketWrapperConfigurator();
  cfg.process_arguments(['--unit_hash', unitHash, '--seed_phrase', 'corpus-gate-01', '--unit_dir_path', UNIT_DIR]);
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

  const r = await mutate('::actor::qa_corpus_narrow', {});
  const g = (path) => path.split('.').reduce((v, k) => v.Reduce(k), r).Visualize();
  const T = (s) => /true/i.test(String(s));

  console.log('=== corpus: registry sir (v2/v3/v5 + floor + shape + future) ===');
  ok(T(g('sir.v2.ok')) && g('sir.v2.v') === '2' && g('sir.v2.name') === '', 'sir v2: ok, dispatched v2, joiner_name empty (cid fallback branch)');
  ok(T(g('sir.v3.ok')) && g('sir.v3.v') === '3' && g('sir.v3.name') === 'Bob', 'sir v3: ok, dispatched v3, $name honored');
  ok(T(g('sir.v5.ok')) && g('sir.v5.v') === '5' && g('sir.v5.name') === 'Carol', 'sir v5: ok, dispatched v5, $name honored');
  ok(!T(g('sir.old.ok')) && g('sir.old.code') === 'peer_version_unsupported', 'sir $pv=1 (below floor): error-as-data peer_version_unsupported');
  ok(g('sir.old.peer_v') === '1' && g('sir.old.min') === '2', `sir too-old error carries peer_version=1 min_supported=2`);
  ok(/too old/.test(g('sir.old.msg')) && /update/.test(g('sir.old.msg')), 'sir too-old error message is human-readable ("too old", "update")');
  ok(!T(g('sir.bad.ok')) && g('sir.bad.code') === 'payload_shape_unrecognized', 'sir unrecognized shape: error-as-data payload_shape_unrecognized');
  ok(T(g('sir.fut.ok')) && g('sir.fut.name') === 'Dee' && T(g('sir.fut.stripped_future')), 'sir $pv=7 (future): narrows as newest registered (v5), unknown field stripped');

  console.log('=== corpus: registry cin (v2/v5 + floor) ===');
  ok(T(g('cin.v2.ok')), 'cin v2: ok');
  ok(T(g('cin.v5.ok')), 'cin v5: ok');
  ok(!T(g('cin.old.ok')) && g('cin.old.code') === 'peer_version_unsupported', 'cin below floor: error-as-data');

  console.log('=== corpus: registry rst (v2/v5 + floor) ===');
  ok(T(g('rst.v2.ok')), 'rst v2: ok');
  ok(T(g('rst.v5.ok')), 'rst v5: ok');
  ok(!T(g('rst.old.ok')) && g('rst.old.code') === 'peer_version_unsupported', 'rst below floor: error-as-data');

  console.log('=== corpus: registry acc (v2/v3 + floor) ===');
  ok(T(g('acc.v2.ok')) && g('acc.v2.name') === '', 'acc v2: ok, joiner_name empty (cid fallback branch)');
  ok(T(g('acc.v3.ok')) && g('acc.v3.name') === 'Joi', 'acc v3: ok, $joiner_name honored');
  ok(!T(g('acc.old.ok')) && g('acc.old.code') === 'peer_version_unsupported', 'acc below floor: error-as-data');

  console.log('=== corpus: strict narrow aborts with the stable message ===');
  let strictMsg = '';
  try { await mutate('::actor::qa_corpus_narrow_strict_old', {}); } catch (e) { strictMsg = String(e.message); }
  ok(/too old/.test(strictMsg) && /minimum supported is v2/.test(strictMsg),
    `strict narrow on below-floor payload aborts with the registry message (got: ${strictMsg.split('\n')[0].slice(0, 120)})`);

  console.log('\n================ CORPUS ================');
  if (scorecard.length === 0) console.log('CORPUS: ALL GREEN');
  else { console.log(`${scorecard.length} FAILURE(S):`); scorecard.forEach((s) => console.log('  ' + s)); }
  await sleep(300);
  process.exit(scorecard.length === 0 ? 0 : 1);
}
main().catch((e) => { log('DRIVER ERR:', e.stack ?? e.message); process.exit(1); });
