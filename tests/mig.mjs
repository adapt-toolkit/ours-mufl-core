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
    if (kind === 'notify_agent') { try { const pl=d.Reduce('payload'); const ev=pl.Reduce('event').Visualize(); if(/migration|protocol_error/.test(ev)) process.stderr.write(`[notify ${id.name}] ${ev} reason=${pl.Reduce('reason').Visualize()} cid=${pl.Reduce('cid').Visualize().slice(0,10)}\n`); } catch {} return; }
    if (kind === 'save_state') return;
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
const getBin = (p, k) => { try { return Buffer.from(p.Reduce(k).GetBinary()); } catch { return Buffer.alloc(0); } };
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

  console.log('=== mig: decode-seam (REAL decrypt_and_commit: install vs stage vs self-heal) ===');
  const C = await mkNode('mig-gate-C', 'C');
  const D = await mkNode('mig-gate-D', 'D'); await sleep(800);
  const cCid = C.cid, dCid = D.cid;
  const dBundle = getBin(ro(D, '::actor::qa_e2e_bundle', {}), 'bundle');
  const cIk = getBin(ro(C, '::actor::qa_e2e_ik', {}), 'ik');
  await mutate(D, '::actor::qa_e2e_install_mig_hook', {});   // hook reads the togglable flag (default FALSE)

  // (i) FIRST-CONTACT through the seam: no live session -> installs directly (0.8.0 preserved)
  const dp1 = Buffer.from('seam-first-contact');
  const denv1 = await mutate(C, '::actor::qa_e2e_first_send', { cid: dCid, pt: binv(C, dp1), peer: binv(C, dBundle) });
  const drec1 = await mutate(D, '::actor::qa_e2e_recv', { from: cCid, ik: binv(D, cIk),
    olm_type: +denv1.Reduce('olm_type').Visualize(), ciphertext: binv(D, getBin(denv1, 'ciphertext')) });
  ok(T(drec1.Reduce('ok').Visualize()) && getBin(drec1, 'plaintext').equals(dp1), 'seam: first-contact PRE_KEY installs + decrypts (no live session)');
  const dLive1 = getBin(ro(D, '::actor::qa_e2e_active', { cid: cCid }), 'sid');
  ok(dLive1.length > 0, 'seam: first-contact installed the live session');

  // (ii) LIVE SESSION + PRE_KEY + migration PENDING -> STAGE (m_sessions untouched)
  await mutate(D, '::actor::qa_e2e_set_mig_pending', { pending: true });
  const stagedC = getBin(await mutate(C, '::actor::qa_e2e_stage_out', { cid: dCid, peer: binv(C, dBundle) }), 'sid');
  const cenvS = await mutate(C, '::actor::qa_e2e_enc_staged', { cid: dCid, pt: binv(C, Buffer.from('seam-migration-prekey')) });
  const drecS = await mutate(D, '::actor::qa_e2e_recv', { from: cCid, ik: binv(D, cIk),
    olm_type: +cenvS.Reduce('olm_type').Visualize(), ciphertext: binv(D, getBin(cenvS, 'ciphertext')) });
  ok(T(drecS.Reduce('ok').Visualize()), 'seam: migration PRE_KEY on a live session decrypts (staged path)');
  const dLive2 = getBin(ro(D, '::actor::qa_e2e_active', { cid: cCid }), 'sid');
  ok(hex(dLive2) === hex(dLive1), 'seam: STAGE — the real decrypt_and_commit did NOT replace the live session');
  const dStaged2 = getBin(ro(D, '::actor::qa_e2e_staged', { cid: cCid }), 'sid');
  ok(hex(dStaged2) === hex(stagedC), 'seam: STAGE — fresh session parked in the staged slot (== sender staged id)');

  // (iii) LIVE SESSION + PRE_KEY + NO migration -> SELF-HEAL (replace, 0.8.0 preserved)
  await mutate(D, '::actor::qa_e2e_set_mig_pending', { pending: false });
  const stagedC2 = getBin(await mutate(C, '::actor::qa_e2e_stage_out', { cid: dCid, peer: binv(C, dBundle) }), 'sid');
  const cenvH = await mutate(C, '::actor::qa_e2e_enc_staged', { cid: dCid, pt: binv(C, Buffer.from('seam-self-heal')) });
  const drecH = await mutate(D, '::actor::qa_e2e_recv', { from: cCid, ik: binv(D, cIk),
    olm_type: +cenvH.Reduce('olm_type').Visualize(), ciphertext: binv(D, getBin(cenvH, 'ciphertext')) });
  ok(T(drecH.Reduce('ok').Visualize()), 'seam: self-heal PRE_KEY on a live session decrypts');
  const dLive3 = getBin(ro(D, '::actor::qa_e2e_active', { cid: cCid }), 'sid');
  ok(hex(dLive3) === hex(stagedC2) && hex(dLive3) !== hex(dLive1), 'seam: SELF-HEAL — live session REPLACED (no migration pending → 0.8.0 behavior)');

  console.log('=== mig: cross-lib atomicity gate (abort after adapt-write + core-write + action) ===');
  const E = await mkNode('mig-gate-E', 'E'); await sleep(600);
  let aborted = false;
  await mutate(E, '::actor::qa_atomicity_abort', { cid: dCid, peer: binv(E, dBundle) }).catch(() => { aborted = true; });
  ok(aborted, 'atomicity: the probe tx aborted as designed (adapt-write + core-write + queued action, then abort)');
  const ck = ro(E, '::actor::qa_atomicity_check', { cid: dCid });
  ok(!T(ck.Reduce('core_present').Visualize()), 'atomicity: CORE-library write (a2a_messaging contact_migration) rolled back on abort');
  ok(!T(ck.Reduce('adapt_present').Visualize()), 'atomicity: ADAPT-library write (e2e staged session) rolled back on abort');

  console.log('=== mig: fault-injection — self-heal replace whose inner dispatch ABORTS → live unchanged ===');
  const F = await mkNode('mig-gate-F', 'F');
  const G = await mkNode('mig-gate-G', 'G'); await sleep(800);
  const fCid = F.cid, gCid = G.cid;
  const gBundle = getBin(ro(G, '::actor::qa_e2e_bundle', {}), 'bundle');
  const fIk = getBin(ro(F, '::actor::qa_e2e_ik', {}), 'ik');
  await mutate(G, '::actor::qa_e2e_install_mig_hook', {});   // default FALSE → self-heal path
  const fenv1 = await mutate(F, '::actor::qa_e2e_first_send', { cid: gCid, pt: binv(F, Buffer.from('fi-live')), peer: binv(F, gBundle) });
  await mutate(G, '::actor::qa_e2e_recv', { from: fCid, ik: binv(G, fIk),
    olm_type: +fenv1.Reduce('olm_type').Visualize(), ciphertext: binv(G, getBin(fenv1, 'ciphertext')) });
  const gLive = getBin(ro(G, '::actor::qa_e2e_active', { cid: fCid }), 'sid');
  ok(gLive.length > 0, 'fault-injection: G established a live session with F');
  await mutate(F, '::actor::qa_e2e_stage_out', { cid: gCid, peer: binv(F, gBundle) });
  const fenvH = await mutate(F, '::actor::qa_e2e_enc_staged', { cid: gCid, pt: binv(F, Buffer.from('fi-selfheal')) });
  let fiAborted = false;
  await mutate(G, '::actor::qa_e2e_recv_abort', { from: fCid, ik: binv(G, fIk),
    olm_type: +fenvH.Reduce('olm_type').Visualize(), ciphertext: binv(G, getBin(fenvH, 'ciphertext')) }).catch(() => { fiAborted = true; });
  ok(fiAborted, 'fault-injection: the self-heal recv tx aborted (inner-dispatch failure modelled)');
  const gLive2 = getBin(ro(G, '::actor::qa_e2e_active', { cid: fCid }), 'sid');
  ok(hex(gLive2) === hex(gLive), 'fault-injection: live session UNCHANGED after the aborted self-heal (atomicity protects the immediate-replace)');

  console.log('=== mig: Phase-C §5.2 helpers (election + epoch) ===');
  // election: exactly one of the pair initiates (lower cid), both agree
  const aInit = T(ro(A, '::actor::qa_mig_initiator', { peer: bCid }).Reduce('initiator').Visualize());
  const bInit = T(ro(B, '::actor::qa_mig_initiator', { peer: aCid }).Reduce('initiator').Visualize());
  ok(aInit !== bInit, 'mig_initiator: exactly ONE of the pair initiates (deterministic election)');
  ok(aInit === (aCid < bCid), 'mig_initiator: the LOWER cid initiates (lexicographic total order)');
  // epoch: both sides derive the SAME epoch from the SAME cid-ordered inputs
  const lo = aCid < bCid ? aCid : bCid, hi = aCid < bCid ? bCid : aCid;
  const nlo = binv(A, Buffer.from('11111111111111111111111111111111', 'hex'));
  const nhi = binv(A, Buffer.from('22222222222222222222222222222222', 'hex'));
  const flo = binv(A, Buffer.from('33333333333333333333333333333333', 'hex'));
  const fhi = binv(A, Buffer.from('44444444444444444444444444444444', 'hex'));
  const epA = getBin(ro(A, '::actor::qa_mig_epoch', { lo, hi, nlo, nhi, flo, fhi }), 'epoch');
  const nloB = binv(B, Buffer.from('11111111111111111111111111111111', 'hex'));
  const nhiB = binv(B, Buffer.from('22222222222222222222222222222222', 'hex'));
  const floB = binv(B, Buffer.from('33333333333333333333333333333333', 'hex'));
  const fhiB = binv(B, Buffer.from('44444444444444444444444444444444', 'hex'));
  const epB = getBin(ro(B, '::actor::qa_mig_epoch', { lo, hi, nlo: nloB, nhi: nhiB, flo: floB, fhi: fhiB }), 'epoch');
  ok(epA.length === 32 && hex(epA) === hex(epB), 'mig_epoch: both sides derive the SAME 32-byte epoch from identical cid-ordered inputs');
  // input sensitivity: swap a nonce → different epoch (domain/agreement binding)
  const epA2 = getBin(ro(A, '::actor::qa_mig_epoch', { lo, hi, nlo: nhi, nhi: nlo, flo, fhi }), 'epoch');
  ok(hex(epA2) !== hex(epA), 'mig_epoch: swapping the nonces yields a DIFFERENT epoch (agreement-bound)');
  // e2e_bundle_fp is deterministic + 32 bytes
  const fpA = getBin(ro(A, '::actor::qa_mig_bundle_fp', {}), 'fp');
  const fpA2 = getBin(ro(A, '::actor::qa_mig_bundle_fp', {}), 'fp');
  ok(fpA.length === 32 && hex(fpA) === hex(fpA2), 'e2e_bundle_fp: deterministic 32-byte fingerprint of my e2e bundle');

  console.log('=== mig: FULL handshake offer→ack→commit→confirm→ACTIVE (bilateral rotation + pins) ===');
  const I2 = await mkNode('mig-gate-I2', 'I2');
  const R2 = await mkNode('mig-gate-R2', 'R2'); await sleep(1000);
  // establish mutual contact via the invite flow (so the encrypted_channel exists)
  const inv = await mutate(I2, '::a2a_messaging::generate_invite', { name: 'R2' });
  const invBlob = Buffer.from(inv.Reduce('invite').GetBinary());
  await mutate(R2, '::a2a_messaging::add_contact', { invite: binv(R2, invBlob), name: 'I2' });
  await sleep(6000);   // invite redeem round-trips over the broker
  // trigger the OFFER from the LOWER cid → the ack handler proceeds to commit, and the whole
  // offer→ack→commit→confirm handshake runs automatically over the broker to ACTIVE.
  const [loN, hiN] = I2.cid < R2.cid ? [I2, R2] : [R2, I2];
  await mutate(loN, '::actor::qa_mig_trigger_offer', { peer: hiN.cid });
  await sleep(10000);   // 4 legs: offer → ack → commit → confirm
  { const la=getBin(ro(loN,'::actor::qa_e2e_active',{cid:hiN.cid}),'sid'); const ha=getBin(ro(hiN,'::actor::qa_e2e_active',{cid:loN.cid}),'sid');
    const ls=ro(loN,'::actor::qa_mig_state',{cid:hiN.cid}); const hs=ro(hiN,'::actor::qa_mig_state',{cid:loN.cid});
    console.log(`  DIAG lo(init): phase=${ls.Reduce('phase').Visualize()} active=${hex(la).slice(0,12)||'NIL'}`);
    console.log(`  DIAG hi(resp): phase=${hs.Reduce('phase').Visualize()} active=${hex(ha).slice(0,12)||'NIL'}`); }
  const loSt = ro(loN, '::actor::qa_mig_state', { cid: hiN.cid });
  const hiSt = ro(hiN, '::actor::qa_mig_state', { cid: loN.cid });
  log('HANDSHAKE PHASES: initiator=' + loSt.Reduce('phase').Visualize() + ' responder=' + hiSt.Reduce('phase').Visualize());
  ok(loSt.Reduce('phase').Visualize() === 'active', 'handshake: initiator reaches ACTIVE');
  ok(hiSt.Reduce('phase').Visualize() === 'active', 'handshake: responder reaches ACTIVE');
  ok(T(loSt.Reduce('initiator').Visualize()) && !T(hiSt.Reduce('initiator').Visualize()), 'handshake: election roles correct (lower=initiator, higher=responder)');
  const loEp = getBin(loSt, 'epoch'), hiEp = getBin(hiSt, 'epoch');
  ok(loEp.length === 32 && hex(loEp) === hex(hiEp), 'handshake: both sides on the same 32-byte epoch');
  // both pins set at active (contact_e2e_epoch + contact_e2e_seen)
  const loPin = ro(loN, '::actor::qa_mig_pin', { cid: hiN.cid });
  const hiPin = ro(hiN, '::actor::qa_mig_pin', { cid: loN.cid });
  ok(T(loPin.Reduce('pinned').Visualize()) && T(hiPin.Reduce('pinned').Visualize()), 'handshake: contact_e2e_epoch pinned BOTH sides');
  ok(T(loPin.Reduce('seen').Visualize()) && T(hiPin.Reduce('seen').Visualize()), 'handshake: contact_e2e_seen set BOTH sides');
  ok(hex(getBin(loPin, 'epoch')) === hex(loEp), 'handshake: epoch pin == FSM epoch');
  // the bilateral rotation: both sides share the SAME fresh active session, == the pinned session
  const loAct = getBin(ro(loN, '::actor::qa_e2e_active', { cid: hiN.cid }), 'sid');
  const hiAct = getBin(ro(hiN, '::actor::qa_e2e_active', { cid: loN.cid }), 'sid');
  ok(loAct.length > 0 && hex(loAct) === hex(hiAct), 'handshake: both sides share the SAME active (fresh, rotated) session_id');
  ok(hex(getBin(loPin, 'session_id')) === hex(loAct), 'handshake: epoch pin session_id == active session_id (the exactly-once rotation)');
  // Phase D §5.6: at active (epoch pinned + peer bundle present) the app-data route is E2E-only
  // on BOTH sides — box is now unreachable for this cid's app data (barrier post-commit).
  ok(ro(loN, '::actor::qa_e2e_route', { cid: hiN.cid }).Reduce('route').Visualize() === 'e2e', 'route(§5.6): initiator app-data route == "e2e" at active (box unreachable)');
  ok(ro(hiN, '::actor::qa_e2e_route', { cid: loN.cid }).Reduce('route').Visualize() === 'e2e', 'route(§5.6): responder app-data route == "e2e" at active (box unreachable)');

  // Exhaustive phase handling: a duplicate offer redelivered when the pair is already ACTIVE
  // must be an idempotent NO-OP (not restart the FSM), per §5.6 / MigrationReview C.3 watch-item.
  await mutate(loN, '::actor::qa_mig_resend_offer', { peer: hiN.cid });
  await sleep(4000);
  const hiSt2 = ro(hiN, '::actor::qa_mig_state', { cid: loN.cid });
  ok(hiSt2.Reduce('phase').Visualize() === 'active', 'idempotency: duplicate offer at ACTIVE is a no-op (FSM not restarted)');
  ok(hex(getBin(hiSt2, 'epoch')) === hex(hiEp), 'idempotency: duplicate offer does NOT change the epoch');
  const hiAct2 = getBin(ro(hiN, '::actor::qa_e2e_active', { cid: loN.cid }), 'sid');
  ok(hex(hiAct2) === hex(hiAct), 'idempotency: duplicate offer does NOT disturb the active session');

  // decode_migration_envelope guard matrix — the point-1 divergence guard (recv_authenticated's
  // S1/S2 is REAL) + decode_migration_envelope binding gates + the forgery-abort vs replay-reject
  // split. P (sender) stages a rotation to M (receiver) and encrypts a known plaintext; M then
  // decodes it (happy) and rejects tampered variants.
  console.log('=== mig: decode_migration_envelope GUARD (divergence + binding + forgery/replay split) ===');
  const P = await mkNode('mig-guard-P', 'P');
  const M = await mkNode('mig-guard-M', 'M'); await sleep(800);
  const pAd = getBin(ro(P, '::actor::qa_produce_ad', {}), 'ad');
  const mBundle = getBin(ro(M, '::actor::qa_e2e_bundle', {}), 'bundle');
  await mutate(P, '::actor::qa_e2e_stage_out', { cid: M.cid, peer: binv(P, mBundle) });
  const marker = Buffer.from('guard-roundtrip-marker');
  const enc1 = await mutate(P, '::actor::qa_mig_enc_full', { cid: M.cid, pt: binv(P, marker) });
  const gEnv1 = getBin(enc1, 'env'), emsig1 = getBin(enc1, 'emsig');
  const enc2 = await mutate(P, '::actor::qa_mig_enc_full', { cid: M.cid, pt: binv(P, Buffer.from('guard-second')) });
  const emsig2 = getBin(enc2, 'emsig');   // a VALID emsig over a DIFFERENT envelope (foreign-emsig case)
  const dec = (t) => mutate(M, '::actor::qa_mig_decode', {
    from: t.from ?? P.cid, to: t.to ?? M.cid, ad: binv(M, t.ad ?? pAd),
    env: binv(M, t.env ?? gEnv1), emsig: binv(M, t.emsig ?? emsig1), pv_override: t.pv_override ?? -1 });
  const expectAbort = async (label, targ) => { try { await dec(targ); ok(false, label + ' (expected ABORT, got success)'); } catch { ok(true, label); } };
  // Forgery → ABORT (these never mutate M's session — atomicity), run before the happy establish.
  await expectAbort('guard: bad wire_pv (S2) → abort', { pv_override: 99 });
  await expectAbort('guard: foreign/tampered emsig (S1) → abort', { emsig: emsig2 });
  await expectAbort('guard: wrong $to recipient (S1) → abort', { to: P.cid });
  await expectAbort('guard: AD.cid ≠ box sender (relay re-box, binding) → abort', { from: M.cid });
  // Happy round-trip → establishes M's inbound session + returns the RIGHT plaintext.
  const hap = await dec({});
  ok(T(hap.Reduce('ok').Visualize()) && hex(getBin(hap, 'plaintext')) === hex(marker), 'guard: happy path decodes to the RIGHT plaintext (round-trip)');
  // Replay the SAME pre-key → session_matches → replayed() → !ok (reject, NOT abort): the split.
  const rep = await dec({});
  ok(!T(rep.Reduce('ok').Visualize()) && rep.Reduce('code').Visualize() === 'replayed_handshake', 'guard: replay (valid emsig, replayed ciphertext) → !ok reject NOT abort (forgery/replay split)');

  console.log('\n================ MIG ================');
  if (scorecard.length === 0) console.log('MIG: ALL GREEN');
  else { console.log(`${scorecard.length} FAILURE(S):`); scorecard.forEach((s) => console.log('  ' + s)); }
  await sleep(300);
  process.exit(scorecard.length === 0 ? 0 : 1);
}
main().catch((e) => { log('DRIVER ERR:', e.stack ?? e.message); process.exit(1); });
