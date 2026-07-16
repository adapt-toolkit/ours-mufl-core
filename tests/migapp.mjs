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
// Bring up two fresh nodes I,R and connect them (invite → add_contact → both learn each other's
// AD, so peer_ads is populated BOTH ways). Returns the nodes + their e2e bundles + I's ik.
async function connect(tag) {
  const n = seq();
  const I = await mkNode(`migapp-${tag}-I${n}`, `I_${tag}`);
  const R = await mkNode(`migapp-${tag}-R${n}`, `R_${tag}`); await sleep(1000);
  const inv = await mutate(I, '::a2a_messaging::generate_invite', { name: R.name });
  await mutate(R, '::a2a_messaging::add_contact', { invite: binv(R, Buffer.from(inv.Reduce('invite').GetBinary())), name: I.name });
  await sleep(6000);
  const iBundle = getBin(ro(I, '::actor::qa_e2e_bundle', {}), 'bundle');
  const rBundle = getBin(ro(R, '::actor::qa_e2e_bundle', {}), 'bundle');
  const iIk = getBin(ro(I, '::actor::qa_e2e_ik', {}), 'ik');
  return { I, R, iBundle, rBundle, iIk };
}

async function synthCommitted(tag, opts = {}) {
  const { I, R, iBundle, rBundle, iIk } = await connect(tag);
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
    ok(hex(getBin(ro(I, '::actor::qa_e2e_active', { cid: R.cid }), 'sid')) === hex(sid), 'implicit-confirm: active session == the promoted rotation');
    // §5.8 mixed-contact independence: this node is epoch-pinned to R (routes e2e) while an
    // unrelated non-e2e contact routes "legacy" — per-contact routing is independent.
    ok(ro(I, '::actor::qa_e2e_route', { cid: R.cid }).Reduce('route').Visualize() === 'e2e', 'mixed-contact(§5.8): the migrated peer routes e2e');
    ok(ro(I, '::actor::qa_e2e_route', { cid: 'ab'.repeat(32) }).Reduce('route').Visualize() === 'legacy', 'mixed-contact(§5.8): an unrelated non-e2e contact routes legacy — routes are per-contact independent'); }

  // ── §5.8 ROUTE-LEVEL rows (single node, store-synthesized): imported pin + no bundle → fail closed.
  console.log('=== migapp: §5.8 route-level (import-pin-no-session → downgrade_refused; fresh → legacy) ===');
  { const A = await mkNode('migapp-route-A', 'A'); await sleep(800);
    const pinnedCid = 'cd'.repeat(32), freshCid = 'ef'.repeat(32);
    await mutate(A, '::actor::qa_set_epoch_pin', { cid: pinnedCid, session_id: binv(A, Buffer.from('imported-session-id-32-bytes-xx!')) });
    ok(ro(A, '::actor::qa_e2e_route', { cid: pinnedCid }).Reduce('route').Visualize() === 'downgrade_refused', 'route(§5.6/§5.8): imported epoch pin + NO peer bundle → downgrade_refused (fail closed — never box a migrated peer; recovery re-rotates over the carve-out)');
    ok(ro(A, '::actor::qa_e2e_route', { cid: freshCid }).Reduce('route').Visualize() === 'legacy', 'route(§5.8): a fresh non-e2e contact → legacy (independent of the pinned one on the same node)');
    // Complete the 5-state route matrix on one node: a committed-INITIATOR (commit window) → "migrating".
    const migratingCid = '01'.repeat(32);
    await mutate(A, '::actor::qa_mig_set_committed', { cid: migratingCid, session_id: binv(A, Buffer.from('committed-window-session-32byte!')), seen: false });
    ok(ro(A, '::actor::qa_e2e_route', { cid: migratingCid }).Reduce('route').Visualize() === 'migrating', 'route(§5.8): a committed-initiator (commit window) → "migrating" (app-data queues to mig_deferred, flushes on active) — 5-state matrix complete'); }

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
    ok(hex(getBin(ro(I, '::actor::qa_e2e_active', { cid: R.cid }), 'sid')) === hex(sid), '★ interleave B: session unchanged by the app → EXACTLY ONE promotion (the confirm)');
    // §5.8 broker-redelivery: a REDELIVERED confirm after promotion is an idempotent NO-OP (phase
    // already active → handle_e2e_migrate_confirm returns []; no re-promotion, session untouched).
    await mutate(R, '::actor::qa_send_confirm', { contact: I.name, peer: binv(R, getBin(ro(I, '::actor::qa_e2e_bundle', {}), 'bundle')), epoch: binv(R, sid) });
    await sleep(4000);
    ok(ro(I, '::actor::qa_mig_state', { cid: R.cid }).Reduce('phase').Visualize() === 'active' && hex(getBin(ro(I, '::actor::qa_e2e_active', { cid: R.cid }), 'sid')) === hex(sid), 'dup-confirm(§5.8): a REDELIVERED confirm at active is a NO-OP (idempotent — no second promotion, session unchanged)'); }

  // ── §5.8 dup-COMMIT re-confirm (responder) + lost-confirm recovery (initiator promotes).
  // The responder's confirm was lost, so the initiator is stuck at "committed". Its sweep re-sends
  // the commit; the responder is already active, so handle_e2e_migrate_commit routes to
  // mig_handle_replayed_commit — a NO-decode, NO-state-change idempotent re-confirm on the pinned
  // active session. That re-confirm reaches the initiator, which finally promotes. Proves BOTH
  // §5.8 rows: "dup-commit → re-confirm (idempotent)" and "lost-confirm + redelivered-commit → re-confirm".
  console.log('=== migapp: §5.8 dup-commit re-confirm (responder) + lost-confirm recovery (initiator promotes) ===');
  { const { I, R, sid } = await synthCommitted('dupc');
    // R is crypto-promoted over the shared rotation; make it an ACTIVE responder in the FSM, pinned
    // to that live session, carrying the initiator's committed epoch (== sid).
    const setA = await mutate(R, '::actor::qa_mig_set_active', { cid: I.cid, epoch: binv(R, sid), initiator: false });
    ok(hex(getBin(setA, 'asid')) === hex(sid), 'setup: responder active session == the shared rotation (both peers pin the SAME session_id — #1867 invariant)');
    ok(ro(R, '::actor::qa_mig_state', { cid: I.cid }).Reduce('phase').Visualize() === 'active', 'setup: responder is ACTIVE (already promoted + sent its now-lost confirm)');
    ok(ro(I, '::actor::qa_mig_state', { cid: R.cid }).Reduce('phase').Visualize() === 'committed', 'setup: initiator is still COMMITTED (its responder confirm was lost)');
    ok(getBin(ro(I, '::actor::qa_e2e_active', { cid: R.cid }), 'sid').length === 0, 'setup: initiator has no active session yet (box-only committed, staged rotation survives)');
    // Production lost-confirm recovery: the committed initiator's sweep re-encrypts the commit on its
    // surviving staged session and re-sends it. (Deterministic — no wall-clock; single host-fired sweep.)
    const sw = await mutate(I, '::a2a_messaging::sweep_e2e_migrations', {});
    ok(+sw.Reduce('redriven').Visualize() >= 1, 'sweep: the committed initiator re-drives its commit (redriven ≥ 1) — a redelivered commit is now in flight to the active responder');
    await sleep(4000);
    ok(ro(I, '::actor::qa_mig_state', { cid: R.cid }).Reduce('phase').Visualize() === 'active', '★ lost-confirm recovery: redelivered commit → active responder re-confirmed → initiator PROMOTED to active');
    ok(hex(getBin(ro(I, '::actor::qa_e2e_active', { cid: R.cid }), 'sid')) === hex(sid), 'recovery: initiator active session == the migrated rotation (same session both peers)');
    const ipin = ro(I, '::actor::qa_mig_pin', { cid: R.cid });
    ok(T(ipin.Reduce('pinned').Visualize()) && hex(getBin(ipin, 'session_id')) === hex(sid), 'recovery: initiator epoch pin == the migrated session');
    // The responder never mutated on the replay: mig_handle_replayed_commit writes NOTHING (re-confirm only).
    ok(ro(R, '::actor::qa_mig_state', { cid: I.cid }).Reduce('phase').Visualize() === 'active' &&
       hex(getBin(ro(R, '::actor::qa_e2e_active', { cid: I.cid }), 'sid')) === hex(sid),
       '★ dup-commit: responder UNCHANGED by the replayed commit (idempotent re-confirm — no decode, no state mutation)'); }

  // ── §5.8 forged commit at the REAL handler → GATE 3 reject. A crypto-VALID commit (S1/S2 + decrypt
  // succeed) whose INNER epoch is forged (≠ the responder's stored epoch) must be discarded by
  // handle_e2e_migrate_commit's inner epoch/session gate: discard_rotation, stay acknowledged, no
  // promotion. A positive control on a fresh pair (correct epoch) promotes — proving the ONLY reason
  // for the reject is the forged epoch, not a broken crypto path.
  console.log('=== migapp: §5.8 forged commit (wrong inner epoch) at REAL handle_e2e_migrate_commit → GATE3 reject ===');
  { const { I, R, rBundle } = await connect('fce');
    const epoch = Buffer.from('acknowledged-epoch-32-bytes-xx!!');
    await mutate(R, '::actor::qa_mig_set_acknowledged', { cid: I.cid, epoch: binv(R, epoch) });
    ok(ro(R, '::actor::qa_mig_state', { cid: I.cid }).Reduce('phase').Visualize() === 'acknowledged', 'setup: responder is acknowledged with a stored epoch');
    // Crypto-valid commit whose inner epoch is FORGED (session_id is correct — the ONLY bad field is epoch).
    await mutate(I, '::actor::qa_send_commit', { contact: R.name, peer: binv(I, rBundle), epoch: binv(I, Buffer.from('FORGED-wrong-epoch-32-bytes-xx!!')) });
    await sleep(4000);
    ok(ro(R, '::actor::qa_mig_state', { cid: I.cid }).Reduce('phase').Visualize() === 'acknowledged', '★ forged commit (wrong epoch): responder STAYS acknowledged (GATE3 reject — the decode succeeded, the inner epoch gate did not)');
    ok(!T(ro(R, '::actor::qa_mig_pin', { cid: I.cid }).Reduce('pinned').Visualize()), '★ forged commit: NO epoch pin (the epoch pin is the SOLE migration authority — a forgery can never set it)');
    ok(getBin(ro(R, '::actor::qa_e2e_staged', { cid: I.cid }), 'sid').length === 0, 'forged commit: staged slot cleared (discard_rotation ran on the GATE3 reject)');
    // A box-only (no prior session) rejected commit MAY leave a TRANSIENT UNPINNED session in
    // m_sessions: the decode of a first-contact PRE_KEY establishes it directly (there is no live
    // session to rotate FROM, so it does not go through the staged slot), and discard_rotation only
    // clears m_staged. This is a KNOWN, REVIEWED, ACCEPTED artifact (Impl3 finding (d)) — it is
    // UNPINNED, so it is NOT authoritative (route/FSM ignore it; the epoch pin governs) and it
    // self-corrects on the next valid rotation. The security invariant that matters — no pin, no
    // promotion, phase unchanged — holds above. }
  }
  // Positive control: the SAME path with the CORRECT epoch promotes the responder to active.
  console.log('=== migapp: §5.8 forged-commit positive control (correct epoch → responder promotes) ===');
  { const { I, R, rBundle } = await connect('fcp');
    const epoch = Buffer.from('acknowledged-epoch-32-bytes-xx!!');
    await mutate(R, '::actor::qa_mig_set_acknowledged', { cid: I.cid, epoch: binv(R, epoch) });
    const c = await mutate(I, '::actor::qa_send_commit', { contact: R.name, peer: binv(I, rBundle), epoch: binv(I, epoch) });
    await sleep(4000);
    ok(ro(R, '::actor::qa_mig_state', { cid: I.cid }).Reduce('phase').Visualize() === 'active', '★ positive control: a CORRECT-epoch commit at the same handler PROMOTES to active (the reject above is epoch-specific, not a broken crypto path)');
    ok(hex(getBin(ro(R, '::actor::qa_e2e_active', { cid: I.cid }), 'sid')) === hex(getBin(c, 'sid')), 'positive control: active session == the committed rotation (both peers pin the same session_id)');
    const rpin = ro(R, '::actor::qa_mig_pin', { cid: I.cid });
    ok(T(rpin.Reduce('pinned').Visualize()) && hex(getBin(rpin, 'session_id')) === hex(getBin(c, 'sid')), 'positive control: epoch pin set to the committed session'); }

  // ── §5.8 restart, SAME-packet (staged SURVIVES) → sweep resumes the SAME epoch. A same-packet
  // restart persists m_staged (packet-state reloaded), so the committed initiator's staged rotation
  // is intact. The sweep re-drives byte-identically on that surviving session — it does NOT mint a
  // fresh epoch. Resume-same-epoch: the responder's session_matches collapses the duplicate commit.
  console.log('=== migapp: §5.8 restart same-packet (staged survives) → sweep resumes the SAME epoch ===');
  { const { I, R, sid } = await synthCommitted('rsr');
    const staged0 = getBin(ro(I, '::actor::qa_e2e_staged', { cid: R.cid }), 'sid');
    ok(staged0.length > 0 && hex(staged0) === hex(sid), 'setup: committed initiator with a SURVIVING staged session (same-packet restart preserves m_staged)');
    const sw = await mutate(I, '::a2a_messaging::sweep_e2e_migrations', {});
    ok(+sw.Reduce('redriven').Visualize() === 1 && +sw.Reduce('superseded').Visualize() === 0, '★ restart-resume: the sweep RE-DRIVES the committed entry (staged survives → byte-identical re-send, NOT a supersede)');
    ok(ro(I, '::actor::qa_mig_state', { cid: R.cid }).Reduce('phase').Visualize() === 'committed', 'restart-resume: FSM stays committed (same migration, not restarted from scratch)');
    ok(hex(getBin(ro(I, '::actor::qa_e2e_staged', { cid: R.cid }), 'sid')) === hex(sid), '★ restart-resume: the re-drive resumes the SAME staged rotation (session_id unchanged → same epoch, no fresh rotation)'); }

  // ── §5.8 restart, UNIT-SWAP (staged session LOST) → supersede. A unit-swap (new packet code)
  // drops the in-memory m_staged (packet-state, never exported per INV-4). A committed initiator whose
  // staged session is gone is UNRESUMABLE — the sweep abandons + supersedes with a fresh offer/epoch,
  // never re-sends a commit it can no longer produce, and never strands a half-migrated pin.
  console.log('=== migapp: §5.8 restart unit-swap (staged session LOST) → supersede ===');
  { const { I, R } = await connect('rsl');
    await mutate(I, '::actor::qa_mig_set_committed', { cid: R.cid, session_id: binv(I, Buffer.from('lost-staging-session-32-bytes!!!')), seen: false });
    ok(ro(I, '::actor::qa_mig_state', { cid: R.cid }).Reduce('phase').Visualize() === 'committed', 'setup: committed initiator');
    ok(getBin(ro(I, '::actor::qa_e2e_staged', { cid: R.cid }), 'sid').length === 0, 'setup: staged session GONE (unit-swap dropped m_staged — never exported, INV-4)');
    const sw = await mutate(I, '::a2a_messaging::sweep_e2e_migrations', {});
    ok(+sw.Reduce('superseded').Visualize() === 1 && +sw.Reduce('redriven').Visualize() === 0, '★ staged-lost: the sweep SUPERSEDES (unresumable committed — staged gone → fresh offer/epoch, never a stale commit)');
    ok(ro(I, '::actor::qa_mig_state', { cid: R.cid }).Reduce('phase').Visualize() === 'offered', 'staged-lost: FSM reset to offered (a fresh migration with a new nonce/epoch)');
    ok(!T(ro(I, '::actor::qa_mig_pin', { cid: R.cid }).Reduce('pinned').Visualize()), 'staged-lost: no epoch pin left behind (clean supersede — nothing was ever completed)'); }

  // ── §5.8 recovery composition (br1): pin + peer_ads ABSENT → RESTORE first, then migrate. When a
  // contact is epoch-pinned (migrated) but its peer AD was lost (a breaking-change migration/restart
  // dropped peer_ads = degraded), send_message's DEGRADED branch (peer_ads==NIL) precedes the
  // migration route: the message is queued to the RESTORE queue + a restore request is (re)issued —
  // NOT boxed, NOT queued to mig_deferred, NOT a downgrade refusal. Restore composes BEFORE migrate;
  // once the AD is re-established the SAME epoch pin routes e2e (proven by the setup + route tests).
  console.log('=== migapp: §5.8 recovery composition — pin + peer_ads ABSENT → restore FIRST, then migrate ===');
  { const { I, R } = await connect('rec');
    await mutate(I, '::actor::qa_set_epoch_pin', { cid: R.cid, session_id: binv(I, Buffer.from('migrated-but-degraded-session!!!')) });
    ok(ro(I, '::actor::qa_e2e_route', { cid: R.cid }).Reduce('route').Visualize() === 'e2e', 'setup: with peer_ads present + epoch pin, the contact is MIGRATE-READY (route e2e)');
    await mutate(I, '::actor::qa_strip_peer_ads', {});
    ok(ro(I, '::actor::qa_e2e_route', { cid: R.cid }).Reduce('route').Visualize() === 'downgrade_refused', 'route-level view: pin present but peer bundle GONE → downgrade_refused (never box a migrated peer)');
    const s = await mutate(I, '::a2a_messaging::send_message', { contact: R.name, text: 'sent while pinned + degraded' });
    ok(T(s.Reduce('deferred').Visualize()), '★ restore-first: the send is DEFERRED to the restore queue + a restore is (re)issued — the peer_ads-absent branch precedes the migration route');
    ok(!T(s.Reduce('migrating').Visualize()) && !T(s.Reduce('downgrade_refused').Visualize()), '★ restore-first: NOT the migration paths (mig_deferred / downgrade_refused) — restore composes BEFORE migrate (§5.6 br1)'); }

  // ── §5.8 peer re-keys between ack and commit → supersede-or-complete (NO downgrade either way).
  // The epoch is FROZEN at ack time (from both bundle fps). A bundle change after ack is therefore
  // irrelevant to the epoch. Two outcomes, both safe:
  //   (a) the acked bundle is still installable (v1 uses a REUSABLE fallback key — a routine rekey does
  //       NOT consume it) → the commit decodes on the frozen bundle and COMPLETES on the frozen epoch.
  //   (b) the acked bundle is gone (a full account regen) → the responder cannot Olm-establish the
  //       commit's PRE_KEY → it is rejected at decode, the responder does NOT promote, NO epoch pin is
  //       set, and NOTHING is delivered as plaintext (NO downgrade). The migration simply does not
  //       complete on the stale identity; a fresh offer (new epoch on the new bundle) is the recovery.
  console.log('=== migapp: §5.8 peer-rekey (a) — commit on the acked bundle COMPLETES on the FROZEN epoch ===');
  { const { I, R, rBundle } = await connect('prkA');
    const epoch = Buffer.from('acknowledged-epoch-32-bytes-xx!!');
    await mutate(R, '::actor::qa_mig_set_acknowledged', { cid: I.cid, epoch: binv(R, epoch) });
    const c = await mutate(I, '::actor::qa_send_commit', { contact: R.name, peer: binv(I, rBundle), epoch: binv(I, epoch) });
    await sleep(4000);
    ok(ro(R, '::actor::qa_mig_state', { cid: I.cid }).Reduce('phase').Visualize() === 'active', '★ peer-rekey (a): the commit on the acked bundle COMPLETES on the FROZEN epoch (a post-ack rekey is irrelevant — the epoch froze at ack)');
    const rpin = ro(R, '::actor::qa_mig_pin', { cid: I.cid });
    ok(T(rpin.Reduce('pinned').Visualize()) && hex(getBin(rpin, 'session_id')) === hex(getBin(c, 'sid')), 'peer-rekey (a): epoch-pinned to the committed session (e2e — no downgrade)'); }

  console.log('=== migapp: §5.8 peer-rekey (b) — acked bundle GONE → commit un-decryptable → safe reject, NO downgrade ===');
  { const { I, R } = await connect('prkB');
    const X = await mkNode('migapp-prkB-X', 'X'); await sleep(600);
    const xBundle = getBin(ro(X, '::actor::qa_e2e_bundle', {}), 'bundle');
    const epoch = Buffer.from('acknowledged-epoch-32-bytes-xx!!');
    await mutate(R, '::actor::qa_mig_set_acknowledged', { cid: I.cid, epoch: binv(R, epoch) });
    // Stage the commit to a DIFFERENT bundle (throwaway X) so R's account cannot Olm-establish it —
    // exactly what a rotated-away (regenerated) responder fallback yields at the decode seam.
    await mutate(I, '::actor::qa_send_commit', { contact: R.name, peer: binv(I, xBundle), epoch: binv(I, epoch) });
    await sleep(4000);
    ok(ro(R, '::actor::qa_mig_state', { cid: I.cid }).Reduce('phase').Visualize() === 'acknowledged', '★ peer-rekey (b): an un-decryptable commit is REJECTED — responder STAYS acknowledged (never promotes on a stale identity)');
    ok(!T(ro(R, '::actor::qa_mig_pin', { cid: I.cid }).Reduce('pinned').Visualize()), '★ peer-rekey (b): NO epoch pin — the failed migration NEVER downgrades a session (no pin = no e2e authority claimed)');
    ok(getBin(ro(R, '::actor::qa_e2e_active', { cid: I.cid }), 'sid').length === 0, 'peer-rekey (b): no active session (nothing staged or consumed)');
    ok(ro(R, '::actor::qa_recv_last', {}).Reduce('text').Visualize() === '', 'peer-rekey (b): nothing delivered as plaintext (no downgrade — the commit is rejected as data, not delivered)'); }

  console.log('\n================ MIGAPP ================');
  if (scorecard.length === 0) console.log('MIGAPP: ALL GREEN');
  else { console.log(`${scorecard.length} FAILURE(S):`); scorecard.forEach((s) => console.log('  ' + s)); }
  await sleep(300);
  process.exit(scorecard.length === 0 ? 0 : 1);
}
main().catch((e) => { log('DRIVER ERR:', e.stack ?? e.message); process.exit(1); });
