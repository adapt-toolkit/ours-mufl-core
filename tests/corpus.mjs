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
  ok(!/too old/.test(g('sir.bad.msg')) && /no supported wire shape/.test(g('sir.bad.msg')), 'sir shape error message is DISTINCT from the too-old message (R2)');
  ok(T(g('sir.fut.ok')) && g('sir.fut.name') === 'Dee' && T(g('sir.fut.stripped_future')), 'sir $pv=7 (future): narrows as newest registered (v5), unknown field stripped');
  ok(!T(g('sir.wid.ok')) && g('sir.wid.code') === 'payload_shape_unrecognized', 'sir mistyped $invite_id (int): shape error-as-data, no cast abort (M1)');
  ok(!T(g('sir.wnm.ok')) && g('sir.wnm.code') === 'payload_shape_unrecognized', 'sir mistyped $name (int): shape error-as-data, no cast abort (M1)');
  ok(T(g('sir.wpv.ok')) && g('sir.wpv.v') === '3' && g('sir.wpv.name') === 'Eve', 'sir mistyped $pv (str): tolerated as unstamped, shape-inferred v3 (M1)');
  ok(T(g('sir.pv4.ok')) && g('sir.pv4.name') === 'Fay', 'sir synthetic $pv=4 (dead 0.4 line): narrows as v3, $name honored (R3)');

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

  console.log('=== corpus: registry e2e (v1 + floor + shape + M1 wrong-domain + future) ===');
  ok(T(g('e2e.pre.ok')) && g('e2e.pre.v') === '8' && g('e2e.pre.ot') === '0', 'e2e pre-key: ok, dispatched v8, $olm_type=0 round-trips');
  ok(T(g('e2e.nrm.ok')) && g('e2e.nrm.ot') === '1', 'e2e normal ratchet: ok, $olm_type=1 round-trips');
  ok(!T(g('e2e.old.ok')) && g('e2e.old.code') === 'peer_version_unsupported', 'e2e $pv=1 (below floor): error-as-data peer_version_unsupported');
  ok(g('e2e.old.peer_v') === '1' && g('e2e.old.min') === '2' && /too old/.test(g('e2e.old.msg')), 'e2e too-old error carries peer_version=1 min=2, human-readable');
  ok(!T(g('e2e.bad.ok')) && g('e2e.bad.code') === 'payload_shape_unrecognized' && /no supported wire shape/.test(g('e2e.bad.msg')), 'e2e no $e2e_envelope marker: error-as-data payload_shape_unrecognized (distinct msg)');
  ok(!T(g('e2e.nos.ok')) && g('e2e.nos.code') === 'payload_shape_unrecognized', 'e2e missing $emsignature: shape error-as-data (variant requires the outer sig)');
  ok(!T(g('e2e.wsid.ok')) && g('e2e.wsid.code') === 'payload_shape_unrecognized', 'e2e mistyped $session_id (int): shape error-as-data, no cast abort (M1)');
  ok(!T(g('e2e.wot.ok')) && g('e2e.wot.code') === 'payload_shape_unrecognized', 'e2e mistyped $olm_type (str): shape error-as-data, no cast abort (M1)');
  ok(!T(g('e2e.wct.ok')) && g('e2e.wct.code') === 'payload_shape_unrecognized', 'e2e mistyped $ciphertext (str): shape error-as-data, no cast abort (M1)');
  ok(!T(g('e2e.wpv.ok')) && g('e2e.wpv.code') === 'payload_shape_unrecognized', 'e2e mistyped $pv (str): malformed discriminator -> shape error-as-data, no cast abort (M1)');
  ok(T(g('e2e.uns.ok')) && g('e2e.uns.v') === '8' && g('e2e.uns.ot') === '0', 'e2e unstamped (no $pv): tolerated absent-discriminator, defaults to v8, ok (M1)');
  ok(T(g('e2e.fut.ok')) && g('e2e.fut.ot') === '1', 'e2e $pv=99 (future): narrows as v1 (single registered version), ok');

  console.log('=== corpus: registry mgb (offer/ack + floor + shape + unstamped + future) ===');
  ok(T(g('mgb.off.ok')) && g('mgb.off.v') === '9' && T(g('mgb.off.pn_absent')), 'mgb offer: ok, dispatched v9, $peer_nonce absent (offer form)');
  ok(T(g('mgb.ack.ok')) && T(g('mgb.ack.pn_present')), 'mgb ack: ok, $peer_nonce present (echoes offer nonce)');
  ok(!T(g('mgb.old.ok')) && g('mgb.old.code') === 'peer_version_unsupported' && g('mgb.old.peer_v') === '1' && g('mgb.old.min') === '2', 'mgb $pv=1 (below floor): error-as-data peer_version_unsupported');
  ok(!T(g('mgb.wn.ok')) && g('mgb.wn.code') === 'payload_shape_unrecognized', 'mgb mistyped $nonce (str): shape error-as-data, no cast abort (M1)');
  ok(!T(g('mgb.uns.ok')) && g('mgb.uns.code') === 'payload_shape_unrecognized', 'mgb unstamped (no $pv): shape error-as-data (surface requires the $pv stamp)');
  ok(T(g('mgb.fut.ok')) && g('mgb.fut.v') === '10', 'mgb $pv=10 (future): narrows as v1 (single registered version), ok');

  console.log('=== corpus: registry mgc (commit/confirm + floor + epoch-domain + M1) ===');
  ok(T(g('mgc.com.ok')) && T(g('mgc.com.has_sid')), 'mgc commit: ok, $session_id present (commit form)');
  ok(T(g('mgc.con.ok')) && T(g('mgc.con.no_sid')), 'mgc confirm: ok, $session_id absent (confirm form)');
  ok(!T(g('mgc.old.ok')) && g('mgc.old.code') === 'peer_version_unsupported', 'mgc $pv=1 (below floor): error-as-data peer_version_unsupported');
  ok(!T(g('mgc.ne.ok')) && g('mgc.ne.code') === 'payload_shape_unrecognized', 'mgc no $epoch: shape error-as-data (epoch-domain required)');
  ok(!T(g('mgc.we.ok')) && g('mgc.we.code') === 'payload_shape_unrecognized', 'mgc mistyped $epoch (str): shape error-as-data, no cast abort (M1)');
  ok(!T(g('mgc.ws.ok')) && g('mgc.ws.code') === 'payload_shape_unrecognized', 'mgc mistyped $session_id (int): shape error-as-data, no cast abort (M1)');
  ok(T(g('mgc.uns.ok')), 'mgc unstamped (no $pv): tolerated (E2E session authenticates), narrows v1');

  console.log('=== corpus: strict narrow aborts with the stable message ===');
  let strictMsg = '';
  try { await mutate('::actor::qa_corpus_narrow_strict_old', {}); } catch (e) { strictMsg = String(e.message); }
  ok(/too old/.test(strictMsg) && /minimum supported is v2/.test(strictMsg),
    `strict narrow on below-floor payload aborts with the registry message (got: ${strictMsg.split('\n')[0].slice(0, 120)})`);

  // NOTE: the e2e caps/anti-downgrade routing (a2a_messaging::e2e_route) is
  // production code that compiles clean, but its MUFL unit test cannot live in
  // the corpus unit — corpus_actor.mu deliberately does not load a2a_messaging
  // (the meta-stage type-reduction fuel is per compiled unit; see the header
  // comment in corpus_actor.mu). Routing is covered by the scenario suite
  // (test_actor.mu / test.mjs), which owns all state-touching trns.

  console.log('\n================ CORPUS ================');
  if (scorecard.length === 0) console.log('CORPUS: ALL GREEN');
  else { console.log(`${scorecard.length} FAILURE(S):`); scorecard.forEach((s) => console.log('  ' + s)); }
  await sleep(300);
  process.exit(scorecard.length === 0 ? 0 : 1);
}
main().catch((e) => { log('DRIVER ERR:', e.stack ?? e.message); process.exit(1); });
