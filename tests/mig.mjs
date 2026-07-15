#!/usr/bin/env node
// Phase-A migration store gate + Phase-B adapt staged-rotation gate.
//  A) the three 0.9.0 stores round-trip through export_core_state; a pre-0.9 blob
//     imports to empty (= legacy, spec §5.1) — single packet.
//  B) rotate-once property (spec §5.5): two peers establish a live e2e session,
//     stage a FRESH rotation, commit bilaterally, converge on the new session id,
//     and speak on the new session both directions — while staging never disturbs
//     the live session (unilateral-reset regression, crypto half).
// Runs mig_actor.mu (loads a2a_messaging + e2e, NOT a2a_notifications, so it stays
// under the per-unit meta-reduction fuel budget). Run via tests/run_mig.sh.
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
const T = (s) => /true/i.test(String(s));

let wrapper;
function mk(name) { return { name, pw: null, cid: '', pending: [] }; }
function wire(id) {
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
}
async function mkNode(seed, name) {
  const id = mk(name);
  const cfg = new PacketWrapperConfigurator();
  cfg.process_arguments(['--unit_hash', unitHash, '--seed_phrase', seed, '--unit_dir_path', UNIT_DIR]);
  await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error(`${name} create timeout`)), 30000);
    wrapper.packet_manager.create_packet(cfg, (pw) => {
      clearTimeout(t); id.pw = pw; id.cid = pw.packet.GetContainerID().Visualize(); wire(id); res();
    }, UNIT);
  });
  return id;
}
const mutate = (id, name, targ) => new Promise((res, rej) => {
  const timer = setTimeout(() => rej(new Error(`${id.name}.${name} timed out`)), 20000);
  id.pending.push({ resolve: res, reject: rej, timer });
  id.pw.add_client_message(object_to_adapt_value({ name, targ }));
});
const binv = (id, buf) => id.pw.packet.NewBinaryFromBuffer(Buffer.from(buf));
const ro = (id, name, targ) => id.pw.packet.ExecuteTransaction(object_to_adapt_value({ name, targ }));
const getBin = (p, k) => Buffer.from(p.Reduce(k).GetBinary());
const hex = (buf) => Buffer.from(buf).toString('hex');

async function main() {
  wrapper = await adapt_wrapper.start(['--broker_address', BROKER_URL, '--test_mode',
    '--logger_config', '--level', 'WARNING', '--stdout', 'stderr', '--logger_config_end']);
  wrapper.start();
  await sleep(1500);
  const A = await mkNode('mig-gate-A', 'A');
  await sleep(800);

  console.log('=== mig: export round-trip (3 new 0.9.0 stores travel the blob) ===');
  const r = await mutate(A, '::actor::qa_mig_export_roundtrip', {});
  const g = (k) => r.Reduce(k).Visualize();
  ok(T(g('has_migration')), 'export_core_state carries $contact_migration');
  ok(T(g('has_epoch')), 'export_core_state carries $contact_e2e_epoch');
  ok(T(g('has_deferred')), 'export_core_state carries $mig_deferred');
  ok(g('phase') === 'active', 'exported FSM entry preserves $phase (active)');
  ok(T(g('epoch_sid_present')), 'exported epoch pin preserves $session_id (canonical bytes)');
  ok(g('deferred_len') === '1', 'exported mig_deferred preserves the queued message');

  console.log('=== mig: pre-0.9 import → migration stores empty (absence = legacy) ===');
  const r2 = await mutate(A, '::actor::qa_mig_import_legacy', {});
  const g2 = (k) => r2.Reduce(k).Visualize();
  ok(T(g2('migration_absent')), 'pre-0.9 blob import: contact_migration stays empty');
  ok(T(g2('epoch_absent')), 'pre-0.9 blob import: contact_e2e_epoch stays empty');
  ok(T(g2('deferred_absent')), 'pre-0.9 blob import: mig_deferred stays empty');

  console.log('=== mig: rotate-once (two peers stage a fresh session, commit, converge) ===');
  const B = await mkNode('mig-gate-B', 'B'); await sleep(800);
  const aCid = A.cid, bCid = B.cid;
  const aBundle = getBin(ro(A, '::actor::qa_e2e_bundle', {}), 'bundle');
  const bBundle = getBin(ro(B, '::actor::qa_e2e_bundle', {}), 'bundle');
  const aIk = getBin(ro(A, '::actor::qa_e2e_ik', {}), 'ik');
  const bIk = getBin(ro(B, '::actor::qa_e2e_ik', {}), 'ik');

  // 1) first contact: A -> B establishes the LIVE session
  const pt1 = Buffer.from('rotate-once-live-1');
  const env1 = await mutate(A, '::actor::qa_e2e_first_send', { cid: bCid, pt: binv(A, pt1), peer: binv(A, bBundle) });
  const rec1 = await mutate(B, '::actor::qa_e2e_recv', { from: aCid, ik: binv(B, aIk),
    olm_type: +env1.Reduce('olm_type').Visualize(), ciphertext: binv(B, getBin(env1, 'ciphertext')) });
  ok(T(rec1.Reduce('ok').Visualize()) && getBin(rec1, 'plaintext').equals(pt1), 'live session established: B decrypts A\'s first message');
  const liveSidA = getBin(ro(A, '::actor::qa_e2e_active', { cid: bCid }), 'sid');
  const liveSidB = getBin(ro(B, '::actor::qa_e2e_active', { cid: aCid }), 'sid');
  ok(liveSidA.length > 0 && hex(liveSidA) === hex(liveSidB), 'live session_id converges A==B');

  // 2) A stages a FRESH rotation (live session untouched) and encrypts the commit body on it
  const stagedSid = getBin(await mutate(A, '::actor::qa_e2e_stage_out', { cid: bCid, peer: binv(A, bBundle) }), 'sid');
  ok(hex(stagedSid) !== hex(liveSidA), 'staged session_id differs from live (a FRESH key)');
  const liveSidA2 = getBin(ro(A, '::actor::qa_e2e_active', { cid: bCid }), 'sid');
  ok(hex(liveSidA2) === hex(liveSidA), 'staging does NOT disturb A\'s live session (unilateral-reset regression, send side)');
  const pt2 = Buffer.from('rotate-once-commit-body');
  const envC = await mutate(A, '::actor::qa_e2e_enc_staged', { cid: bCid, pt: binv(A, pt2) });

  // 3) B stages the inbound rotation from the pre-key; B's live session untouched
  const recC = await mutate(B, '::actor::qa_e2e_stage_in', { from: aCid, ik: binv(B, aIk), ciphertext: binv(B, getBin(envC, 'ciphertext')) });
  ok(T(recC.Reduce('ok').Visualize()) && getBin(recC, 'plaintext').equals(pt2), 'B stages inbound rotation + decrypts the commit body');
  const liveSidB2 = getBin(ro(B, '::actor::qa_e2e_active', { cid: aCid }), 'sid');
  ok(hex(liveSidB2) === hex(liveSidB), 'inbound staging does NOT disturb B\'s live session (unilateral-reset regression, recv side)');
  const stagedSidB = getBin(ro(B, '::actor::qa_e2e_staged', { cid: aCid }), 'sid');
  ok(hex(stagedSidB) === hex(stagedSid), 'B staged session_id == A staged session_id (converged fresh session)');

  // 4) commit both -> promote
  const cA = await mutate(A, '::actor::qa_e2e_commit', { cid: bCid });
  const cB = await mutate(B, '::actor::qa_e2e_commit', { cid: aCid });
  ok(T(cA.Reduce('committed').Visualize()) && T(cB.Reduce('committed').Visualize()), 'both sides commit the rotation');
  const newSidA = getBin(ro(A, '::actor::qa_e2e_active', { cid: bCid }), 'sid');
  const newSidB = getBin(ro(B, '::actor::qa_e2e_active', { cid: aCid }), 'sid');
  ok(hex(newSidA) === hex(stagedSid) && hex(newSidB) === hex(stagedSid), 'after commit: active session_id == the rotation on BOTH sides');
  const cA2 = await mutate(A, '::actor::qa_e2e_commit', { cid: bCid });
  ok(!T(cA2.Reduce('committed').Visualize()), 'commit is idempotent: a second commit is a no-op (staged slot already cleared)');
  ok(hex(newSidA) !== hex(liveSidA), 'the OLD live session is superseded (new session_id != old)');

  // 5) new session works BOTH ways: B->A first (confirm direction), then A->B
  const pt4 = Buffer.from('post-rotation-confirm-B-to-A');
  const env4 = await mutate(B, '::actor::qa_e2e_first_send', { cid: aCid, pt: binv(B, pt4), peer: binv(B, aBundle) });
  const rec4 = await mutate(A, '::actor::qa_e2e_recv', { from: bCid, ik: binv(A, bIk),
    olm_type: +env4.Reduce('olm_type').Visualize(), ciphertext: binv(A, getBin(env4, 'ciphertext')) });
  ok(T(rec4.Reduce('ok').Visualize()) && getBin(rec4, 'plaintext').equals(pt4), 'post-rotation: B->A works on the NEW session');
  const pt5 = Buffer.from('post-rotation-A-to-B');
  const env5 = await mutate(A, '::actor::qa_e2e_first_send', { cid: bCid, pt: binv(A, pt5), peer: binv(A, bBundle) });
  const rec5 = await mutate(B, '::actor::qa_e2e_recv', { from: aCid, ik: binv(B, aIk),
    olm_type: +env5.Reduce('olm_type').Visualize(), ciphertext: binv(B, getBin(env5, 'ciphertext')) });
  ok(T(rec5.Reduce('ok').Visualize()) && getBin(rec5, 'plaintext').equals(pt5), 'post-rotation: A->B works on the NEW session (bidirectional)');

  console.log('\n================ MIG ================');
  if (scorecard.length === 0) console.log('MIG: ALL GREEN');
  else { console.log(`${scorecard.length} FAILURE(S):`); scorecard.forEach((s) => console.log('  ' + s)); }
  await sleep(300);
  process.exit(scorecard.length === 0 ? 0 : 1);
}
main().catch((e) => { log('DRIVER ERR:', e.stack ?? e.message); process.exit(1); });
