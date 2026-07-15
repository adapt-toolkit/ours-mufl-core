#!/usr/bin/env node
// App-e2e RECEIVE-path guard matrix (spec §5.5/§5.6/§4, increment C). Drives the REAL
// handle_receive_e2e_message through the broker against a SYNTHESIZED box-only committed
// initiator (crypto-layer stage/commit primitives build the FSM state without a live
// handshake), proving the §5.5 must-fix-C implicit-confirm branches:
//   1) implicit-confirm POSITIVE, PRODUCTION-LIKE (seen==TRUE at committed) → promote+deliver
//   2) must-fix-C ROLLBACK (app hook aborts → promotion+pins+flush roll back, stays committed)
//   3) negative already-e2e (committed WITH a live session → deliver, NO promote)
//   4) both interleave orders {app→confirm}/{confirm→app} → both decode, EXACTLY ONE promotion
// Runs migapp_actor.mu (loads a2a_messaging + e2e, fresh meta-fuel budget). Via run_migapp.sh.
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
const log = (...a) => process.stderr.write(`[migapp] ${a.join(' ')}\n`);
const scorecard = [];
const ok = (c, m) => { if (!c) { scorecard.push(`✗ ${m}`); console.log(`  ✗ FAIL: ${m}`); } else { console.log(`  ✓ ${m}`); } };
const T = (s) => /true/i.test(String(s));

let wrapper;
function mk(name) { return { name, pw: null, cid: '', pending: [] }; }
function wire(id) {
  id.pw.on_return_data = (d) => {
    const kind = d.Reduce('kind').Visualize();
    if (kind === 'notify_agent') { try { const pl=d.Reduce('payload'); const ev=pl.Reduce('event').Visualize(); if(/migration|protocol_error/.test(ev)) process.stderr.write(`[notify ${id.name}] ${ev} cid=${pl.Reduce('cid').Visualize().slice(0,10)}\n`); } catch {} return; }
    if (kind === 'save_state') return;
    const p = id.pending.shift(); if (!p) return;
    clearTimeout(p.timer); p.resolve(d.Reduce('payload'));
  };
  id.pw.on_transaction_failure = (msg) => { const p = id.pending.shift(); if (p) { clearTimeout(p.timer); p.reject(new Error(msg)); } };
}
async function mkNode(seed, name) {
  const id = mk(name);
  const cfg = new PacketWrapperConfigurator();
  cfg.process_arguments(['--unit_hash', unitHash, '--seed_phrase', seed, '--unit_dir_path', UNIT_DIR]);
  await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error(`${name} create timeout`)), 30000);
    wrapper.packet_manager.create_packet(cfg, (pw) => { clearTimeout(t); id.pw = pw; id.cid = pw.packet.GetContainerID().Visualize(); wire(id); res(); }, UNIT);
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
const getBin = (p, k) => { try { return Buffer.from(p.Reduce(k).GetBinary()); } catch { return Buffer.alloc(0); } };
const hex = (buf) => Buffer.from(buf).toString('hex');
const seq = (() => { let n = 0; return () => n++; })();

// Build a box-only (or with-live-session, when opts.live) COMMITTED-INITIATOR I over a real staged
// rotation shared with responder R. Returns { I, R, sid, ic1Ik } where R has PROMOTED the rotation
// (its m_sessions == the shared session) and I is committed+seen (production-like). No live handshake.
async function synthCommitted(tag, opts = {}) {
  const n = seq();
  const I = await mkNode(`migapp-${tag}-I${n}`, `I_${tag}`);
  const R = await mkNode(`migapp-${tag}-R${n}`, `R_${tag}`); await sleep(1000);
  const inv = await mutate(I, '::a2a_messaging::generate_invite', { name: R.name });
  await mutate(R, '::a2a_messaging::add_contact', { invite: binv(R, Buffer.from(inv.Reduce('invite').GetBinary())), name: I.name });
  await sleep(6000);
  const iBundle = getBin(ro(I, '::actor::qa_e2e_bundle', {}), 'bundle');
  const rBundle = getBin(ro(R, '::actor::qa_e2e_bundle', {}), 'bundle');
  const iIk = getBin(ro(I, '::actor::qa_e2e_ik', {}), 'ik');
  // Optional pre-migration LIVE session (the already-E2E negative case).
  if (opts.live) {
    const lenv = await mutate(I, '::actor::qa_e2e_first_send', { cid: R.cid, pt: binv(I, Buffer.from('pre-migration-live')), peer: binv(I, rBundle) });
    await mutate(R, '::actor::qa_e2e_recv', { from: I.cid, ik: binv(R, iIk), olm_type: +lenv.Reduce('olm_type').Visualize(), ciphertext: binv(R, getBin(lenv, 'ciphertext')) });
  }
  // I stages a fresh outbound rotation (box-only when !opts.live), encrypts the commit pre-key.
  const sid = getBin(await mutate(I, '::actor::qa_e2e_stage_out', { cid: R.cid, peer: binv(I, rBundle) }), 'sid');
  const cenv = await mutate(I, '::actor::qa_e2e_enc_staged', { cid: R.cid, pt: binv(I, Buffer.from('migration-commit-prekey')) });
  // R stages that rotation inbound and PROMOTES it (goes "active" on the rotation).
  await mutate(R, '::actor::qa_e2e_stage_in', { from: I.cid, ik: binv(R, iIk), ciphertext: binv(R, getBin(cenv, 'ciphertext')) });
  await mutate(R, '::actor::qa_e2e_commit', { cid: I.cid });
  // I is committed-initiator over that staged session; seen==TRUE ⇒ PRODUCTION-LIKE (advertised cap_e2e).
  await mutate(I, '::actor::qa_mig_set_committed', { cid: R.cid, session_id: binv(I, sid), seen: true });
  // R must route e2e to I (seen + bundle) so its app rides receive_e2e_message_tx.
  await mutate(R, '::actor::qa_learn_peer', { cid: I.cid, pv: 9, caps: ['core.e2e'] });
  return { I, R, sid, iBundle };
}

async function main() {
  wrapper = await adapt_wrapper.start(['--broker_address', BROKER_URL, '--test_mode',
    '--logger_config', '--level', 'WARNING', '--stdout', 'stderr', '--logger_config_end']);
  wrapper.start();
  await sleep(1500);

  // ── (1) IMPLICIT-CONFIRM POSITIVE, PRODUCTION-LIKE (seen==TRUE at committed → do_ic MUST fire).
  console.log('=== migapp: implicit-confirm POSITIVE (production-like: seen==TRUE, box-only committed) ===');
  { const { I, R, sid } = await synthCommitted('pos');
    ok(ro(I, '::actor::qa_mig_state', { cid: R.cid }).Reduce('phase').Visualize() === 'committed', 'setup: initiator is box-only committed');
    ok(T(ro(I, '::actor::qa_mig_pin', { cid: R.cid }).Reduce('seen').Visualize()), 'setup: initiator has contact_e2e_seen==TRUE (production-like — the exact state that masked the do_ic bug)');
    ok(getBin(ro(I, '::actor::qa_e2e_active', { cid: R.cid }), 'sid').length === 0, 'setup: initiator is BOX-ONLY (no live session)');
    await mutate(I, '::actor::qa_recv_reset', {});
    const appPt = 'responder app on the new session BEFORE the explicit confirm';
    const s = await mutate(R, '::a2a_messaging::send_message', { contact: I.name, text: appPt });
    ok(s.Reduce('route').Visualize() === 'e2e', 'responder boxed its app as receive_e2e_message_tx (routes e2e)');
    await sleep(4000);
    ok(ro(I, '::actor::qa_recv_last', {}).Reduce('text').Visualize() === appPt, 'implicit-confirm: app DELIVERED to the app hook');
    ok(ro(I, '::actor::qa_mig_state', { cid: R.cid }).Reduce('phase').Visualize() === 'active', '★ implicit-confirm PROMOTED to active DESPITE seen==TRUE (do_ic decoupled — the fix works)');
    const pin = ro(I, '::actor::qa_mig_pin', { cid: R.cid });
    ok(T(pin.Reduce('pinned').Visualize()) && hex(getBin(pin, 'session_id')) === hex(sid), 'implicit-confirm: epoch pin set to the promoted (migrated) session');
    ok(hex(getBin(ro(I, '::actor::qa_e2e_active', { cid: R.cid }), 'sid')) === hex(sid), 'implicit-confirm: active session == the promoted rotation'); }

  // ── (2) MUST-FIX-C ROLLBACK: app hook aborts → promotion+pins+flush all roll back, stays committed.
  console.log('=== migapp: must-fix-C ROLLBACK (app-hook abort → full rollback, FSM stays committed) ===');
  { const { I, R } = await synthCommitted('rb');
    await mutate(I, '::actor::qa_recv_reset', {});
    await mutate(I, '::actor::qa_recv_set_abort', { abort: true });
    await mutate(R, '::a2a_messaging::send_message', { contact: I.name, text: 'should roll back — app hook will abort' });
    await sleep(4000);
    ok(ro(I, '::actor::qa_recv_last', {}).Reduce('text').Visualize() === '', 'rollback: nothing delivered (app hook aborted)');
    ok(ro(I, '::actor::qa_mig_state', { cid: R.cid }).Reduce('phase').Visualize() === 'committed', '★ rollback: FSM stays COMMITTED (promotion rolled back with the tx)');
    ok(!T(ro(I, '::actor::qa_mig_pin', { cid: R.cid }).Reduce('pinned').Visualize()), 'rollback: epoch pin NOT set (rolled back)');
    ok(getBin(ro(I, '::actor::qa_e2e_active', { cid: R.cid }), 'sid').length === 0, 'rollback: no active session (commit_rotation rolled back — still box-only)');
    await mutate(I, '::actor::qa_recv_set_abort', { abort: false }); }

  // ── (3) NEGATIVE ALREADY-E2E: committed WITH a pre-migration live session → deliver, NO promote.
  console.log('=== migapp: negative already-E2E (committed non-box-only → deliver, NO promote) ===');
  { const { I, R, sid } = await synthCommitted('ae2e', { live: true });
    const liveSid = getBin(ro(I, '::actor::qa_e2e_active', { cid: R.cid }), 'sid');
    ok(liveSid.length > 0 && hex(liveSid) !== hex(sid), 'setup: initiator has a LIVE session distinct from the staged rotation');
    await mutate(I, '::actor::qa_recv_reset', {});
    const appPt = 'already-e2e committed: app on the rotation';
    await mutate(R, '::a2a_messaging::send_message', { contact: I.name, text: appPt });
    await sleep(4000);
    ok(ro(I, '::actor::qa_recv_last', {}).Reduce('text').Visualize() === appPt, 'already-e2e: app DELIVERED (decoded on the staged rotation)');
    ok(ro(I, '::actor::qa_mig_state', { cid: R.cid }).Reduce('phase').Visualize() === 'committed', '★ already-e2e: NO promote (stays committed — explicit confirm promotes, not the app)');
    ok(getBin(ro(I, '::actor::qa_e2e_staged', { cid: R.cid }), 'sid').length > 0, 'already-e2e: staged rotation still present (not promoted)');
    ok(hex(getBin(ro(I, '::actor::qa_e2e_active', { cid: R.cid }), 'sid')) === hex(liveSid), 'already-e2e: live session UNCHANGED (rotation not promoted over it)'); }

  // ── (4a) INTERLEAVE {app → confirm}: app promotes (do_ic), then the explicit confirm is a NO-OP.
  console.log('=== migapp: interleave {app→confirm} — app promotes, confirm no-op → EXACTLY ONE promotion ===');
  { const { I, R, sid } = await synthCommitted('iac');
    await mutate(I, '::actor::qa_recv_reset', {});
    await mutate(R, '::a2a_messaging::send_message', { contact: I.name, text: 'app first' });
    await sleep(4000);
    ok(ro(I, '::actor::qa_mig_state', { cid: R.cid }).Reduce('phase').Visualize() === 'active', 'interleave A: app promoted to active (1st promotion)');
    const act1 = hex(getBin(ro(I, '::actor::qa_e2e_active', { cid: R.cid }), 'sid'));
    await mutate(R, '::actor::qa_send_confirm', { contact: I.name, peer: binv(R, getBin(ro(I, '::actor::qa_e2e_bundle', {}), 'bundle')), epoch: binv(R, sid) });
    await sleep(4000);
    ok(ro(I, '::actor::qa_mig_state', { cid: R.cid }).Reduce('phase').Visualize() === 'active', 'interleave A: still active after the confirm');
    ok(hex(getBin(ro(I, '::actor::qa_e2e_active', { cid: R.cid }), 'sid')) === act1 && act1 === hex(sid), '★ interleave A: confirm is a NO-OP (session unchanged) → EXACTLY ONE promotion'); }

  // ── (4b) INTERLEAVE {confirm → app}: confirm promotes, then the app delivers with NO extra promotion.
  console.log('=== migapp: interleave {confirm→app} — confirm promotes, app delivers → EXACTLY ONE promotion ===');
  { const { I, R, sid } = await synthCommitted('ica');
    await mutate(I, '::actor::qa_recv_reset', {});
    await mutate(R, '::actor::qa_send_confirm', { contact: I.name, peer: binv(R, getBin(ro(I, '::actor::qa_e2e_bundle', {}), 'bundle')), epoch: binv(R, sid) });
    await sleep(4000);
    ok(ro(I, '::actor::qa_mig_state', { cid: R.cid }).Reduce('phase').Visualize() === 'active', 'interleave B: confirm promoted to active (the ONLY promotion)');
    ok(hex(getBin(ro(I, '::actor::qa_e2e_active', { cid: R.cid }), 'sid')) === hex(sid), 'interleave B: active == the migrated session');
    await mutate(R, '::a2a_messaging::send_message', { contact: I.name, text: 'app after confirm' });
    await sleep(4000);
    ok(ro(I, '::actor::qa_recv_last', {}).Reduce('text').Visualize() === 'app after confirm', 'interleave B: app DELIVERED on the migrated session');
    ok(hex(getBin(ro(I, '::actor::qa_e2e_active', { cid: R.cid }), 'sid')) === hex(sid), '★ interleave B: session unchanged by the app → EXACTLY ONE promotion (the confirm)'); }

  console.log('\n================ MIGAPP ================');
  if (scorecard.length === 0) console.log('MIGAPP: ALL GREEN');
  else { console.log(`${scorecard.length} FAILURE(S):`); scorecard.forEach((s) => console.log('  ' + s)); }
  await sleep(300);
  process.exit(scorecard.length === 0 ? 0 : 1);
}
main().catch((e) => { log('DRIVER ERR:', e.stack ?? e.message); process.exit(1); });
