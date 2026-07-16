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
  // ★ Q1=A test-only demonstration (endorsed by FleetCoordinator + MigrationReview): the rotated
  // session carries APP DATA end-to-end. Post-active, encrypt_to(peer) rides m_sessions[peer] —
  // the MIGRATED session (commit_rotation promoted it in) — which is the SAME call the daemon uses
  // for its app-e2e send (e2e.mm:281,290). Proves double-ratchet app delivery at the core-gate
  // level; the owner's real-node test covers the daemon-delivery-in-logs side. Zero prod surface.
  const hiBundle = getBin(ro(hiN, '::actor::qa_e2e_bundle', {}), 'bundle');
  const loIk = getBin(ro(loN, '::actor::qa_e2e_ik', {}), 'ik');
  const appPt = Buffer.from('post-migration app message over the rotated double-ratchet');
  const appEnv = await mutate(loN, '::actor::qa_e2e_first_send', { cid: hiN.cid, pt: binv(loN, appPt), peer: binv(loN, hiBundle) });
  ok(hex(getBin(appEnv, 'session_id')) === hex(loAct), 'app-data(§5.6/A): initiator app send rides the MIGRATED (pinned) session_id (not a stale/old session)');
  const appRec = await mutate(hiN, '::actor::qa_e2e_recv', { from: loN.cid, ik: binv(hiN, loIk), olm_type: +appEnv.Reduce('olm_type').Visualize(), ciphertext: binv(hiN, getBin(appEnv, 'ciphertext')) });
  ok(T(appRec.Reduce('ok').Visualize()) && hex(getBin(appRec, 'plaintext')) === hex(appPt), 'app-data(§5.6/A): responder decrypts the app message on the migrated session (double-ratchet delivers app data e2e)');

  // ═══ INCREMENT B — the REAL app-e2e RECEIVE path end-to-end (send_message → e2e box →
  // handle_receive_e2e_message → on_message_received), over the MIGRATED (epoch-pinned) session. ═══
  await mutate(hiN, '::actor::qa_recv_reset', {});
  const bMsg = 'increment-B: app text delivered over the migrated e2e session, REAL handlers';
  const bSend = await mutate(loN, '::a2a_messaging::send_message', { contact: hiN.name, text: bMsg });
  ok(bSend.Reduce('route').Visualize() === 'e2e', 'app-e2e(B) send: send_message routed "e2e" (cored over the migrated session as receive_e2e_message_tx, not boxed legacy)');
  await sleep(4000);   // the e2e box relays over the broker
  ok(ro(hiN, '::actor::qa_recv_last', {}).Reduce('text').Visualize() === bMsg, 'app-e2e(B) recv: handle_receive_e2e_message decrypted + DELIVERED the plaintext to on_message_received');
  const hiActX = getBin(ro(hiN, '::actor::qa_e2e_active', { cid: loN.cid }), 'sid');
  ok(hex(hiActX) === hex(hiAct) && hex(hiActX) === hex(loAct), 'app-e2e(B) recv: active session(loN) == the migrated session on BOTH sides (non-circular #1867 cross-check)');
  // File analogue: send_file → receive_e2e_file → on_file_received.
  await mutate(hiN, '::actor::qa_recv_reset', {});
  const bFile = Buffer.from('increment-B file bytes riding the migrated e2e session');
  const bfSend = await mutate(loN, '::a2a_messaging::send_file', { contact: hiN.name, filename: 'b.bin', mime: 'application/octet-stream', data: binv(loN, bFile) });
  ok(bfSend.Reduce('route').Visualize() === 'e2e', 'app-e2e(B) send_file: routed "e2e" (cored over the migrated session as receive_e2e_file_tx)');
  await sleep(4000);
  { const fr = ro(hiN, '::actor::qa_recv_last', {});
    ok(fr.Reduce('filename').Visualize() === 'b.bin' && +fr.Reduce('flen').Visualize() === bFile.length, 'app-e2e(B) recv_file: handle_receive_e2e_file decrypted + delivered the file to on_file_received'); }
  // §5.7 RECEIVE-SIDE DOWNGRADE REFUSAL over the epoch-pinned pair: a LEGACY plaintext from loN is
  // DROPPED by hiN (never delivered) — the receive-direction confidentiality property.
  await mutate(hiN, '::actor::qa_recv_reset', {});
  await mutate(loN, '::actor::qa_send_legacy', { contact: hiN.name, text: 'DOWNGRADE ATTEMPT: legacy plaintext to a migrated peer' });
  await sleep(4000);
  ok(ro(hiN, '::actor::qa_recv_last', {}).Reduce('text').Visualize() === '', 'downgrade-refusal(§5.7): legacy plaintext from an EPOCH-pinned contact is DROPPED (not delivered, no receipt)');
  // Phase D §5.6 flush-on-active: app sends queued during the initiator's commit window (route
  // "migrating" → mig_deferred) flush FIFO on active, preserving per-contact order, queue ends
  // empty. loN is epoch-pinned to hiN (active), so pins-before-flush holds; inject a 3-msg queue
  // then drive the flush (the real drain over flush_mig_deferred_actions).
  await mutate(loN, '::actor::qa_mig_inject_deferred', { cid: hiN.cid });
  ok(ro(loN, '::actor::qa_mig_deferred_ids', { cid: hiN.cid }).Reduce('count').Visualize() === '3', 'flush(§5.6): mig_deferred filled (3 queued app sends)');
  const flushed = await mutate(loN, '::actor::qa_mig_flush', { cid: hiN.cid });
  ok(flushed.Reduce('flushed').Visualize() === '3' && flushed.Reduce('order').Visualize() === 'w0,w1,w2,', 'flush(§5.6): drained FIFO in order (w0,w1,w2) over e2e');
  ok(ro(loN, '::actor::qa_mig_deferred_ids', { cid: hiN.cid }).Reduce('count').Visualize() === '0', 'flush(§5.6): mig_deferred empty after flush (queue drained in one pass)');
  // §5.4 trigger GATE — the criterion-1 boundary (old peers must NEVER get an offer). Tested via
  // the pure predicate mig_should_trigger (no send). ISOLATED cap advertise on loN (does not touch
  // the full-suite test_actor). synthetic peer cids.
  const CAP = 'core.e2e.migrate', synA = 'aa'.repeat(32), synB = 'bb'.repeat(32), synC = 'cc'.repeat(32);
  const fires = (cid) => T(ro(loN, '::actor::qa_mig_should_trigger', { cid }).Reduce('fire').Visualize());
  await mutate(loN, '::actor::qa_learn_peer', { cid: synA, pv: 9, caps: [] });
  ok(!fires(synA), 'trigger(§5.4): NO offer before we advertise cap_e2e_migrate (self-advertise gate, fail-closed)');
  await mutate(loN, '::actor::qa_init_caps', { advertise: [CAP] });
  ok(fires(synA), 'trigger(§5.4): 0.9 peer via pv>=9 → offer fires (pv self-heal leg)');
  await mutate(loN, '::actor::qa_learn_peer', { cid: synB, pv: 8, caps: [CAP] });
  ok(fires(synB), 'trigger(§5.4): 0.9 peer via advertised caps → offer fires (caps leg)');
  await mutate(loN, '::actor::qa_learn_peer', { cid: synC, pv: 8, caps: [] });
  ok(!fires(synC), 'trigger(§5.4): OLD peer (pv<9, no cap) → NO offer (CRITERION 1)');
  ok(!fires(hiN.cid), 'trigger(§5.4): already-migrated contact → NO offer (fires-once / in-flight gate)');
  // §5.8 old/old → ZERO migration traffic: the trigger is fail-closed on BOTH ends. hiN never
  // advertised cap_e2e_migrate (old self), so it stays dormant even toward a 0.9-capable peer;
  // combined with the old-PEER gate above (synC), a genuinely old/old pair generates no offers.
  const firesHi = (cid) => T(ro(hiN, '::actor::qa_mig_should_trigger', { cid }).Reduce('fire').Visualize());
  await mutate(hiN, '::actor::qa_learn_peer', { cid: synA, pv: 9, caps: [CAP] });
  ok(!firesHi(synA), 'trigger(§5.8 old/old): a self that never advertised cap_e2e_migrate stays DORMANT even toward a 0.9 peer (old-self fail-closed) — old/old → zero mig traffic');
  // §5.6 recovery sweep: re-drive a stalled migration + $attempts cap → $migration_stalled. (Runs
  // LAST — qa_mig_force_offered overwrites loN's contact_migration[hiN].) hiN is a registered contact
  // so the re-drive's send does not abort; hiN is active so it no-ops the stray re-offer.
  await mutate(loN, '::actor::qa_mig_force_offered', { cid: hiN.cid });
  const sw1 = await mutate(loN, '::a2a_messaging::sweep_e2e_migrations', {});
  ok(sw1.Reduce('redriven').Visualize() === '1' && sw1.Reduce('stalled').Visualize() === '0', 'sweep(§5.6): re-drives an offered migration (byte-identical retransmit), bumps $attempts');
  await mutate(loN, '::actor::qa_mig_set_attempts', { cid: hiN.cid, n: 30 });
  const sw2 = await mutate(loN, '::a2a_messaging::sweep_e2e_migrations', {});
  ok(sw2.Reduce('stalled').Visualize() === '1' && sw2.Reduce('redriven').Visualize() === '0', 'sweep(§5.6): $attempts cap → $migration_stalled (state kept, no re-drive)');
  // §5.4-5 rotation detector: my published bundle rotated since the snapshot → a byte-identical
  // resend would carry a stale fp under the same nonce → SUPERSEDE (fresh offer/epoch) instead.
  await mutate(loN, '::actor::qa_mig_force_offered', { cid: hiN.cid });
  await mutate(loN, '::actor::qa_mig_corrupt_fp', { cid: hiN.cid });
  const sw3 = await mutate(loN, '::a2a_messaging::sweep_e2e_migrations', {});
  ok(sw3.Reduce('superseded').Visualize() === '1' && sw3.Reduce('redriven').Visualize() === '0', 'sweep(§5.4-5): local bundle-fp rotation → SUPERSEDE (fresh offer/epoch), not stale byte-identical resend');
  // Phase D §5.6: at active (epoch pinned + peer bundle present) the app-data route is E2E-only
  // on BOTH sides — box is now unreachable for this cid's app data (barrier post-commit).
  ok(ro(loN, '::actor::qa_e2e_route', { cid: hiN.cid }).Reduce('route').Visualize() === 'e2e', 'route(§5.6): initiator app-data route == "e2e" at active (box unreachable)');
  ok(ro(hiN, '::actor::qa_e2e_route', { cid: loN.cid }).Reduce('route').Visualize() === 'e2e', 'route(§5.6): responder app-data route == "e2e" at active (box unreachable)');
  // §5.8 downgrade-attempt-after-active: the epoch pin is authoritative over caps — a peer whose
  // caps are stripped (a downgrade attempt) STILL routes e2e; the pins are untouched.
  await mutate(loN, '::actor::qa_learn_peer', { cid: hiN.cid, pv: 9, caps: [] });
  ok(ro(loN, '::actor::qa_e2e_route', { cid: hiN.cid }).Reduce('route').Visualize() === 'e2e', 'downgrade-after-active(§5.8): route STAYS e2e after a caps-strip (epoch pin is authoritative, not caps)');
  { const dp = ro(loN, '::actor::qa_mig_pin', { cid: hiN.cid });
    ok(T(dp.Reduce('pinned').Visualize()) && hex(getBin(dp, 'session_id')) === hex(loAct), 'downgrade-after-active(§5.8): epoch pin UNTOUCHED by the downgrade attempt (same session_id)'); }

  // Exhaustive phase handling: a duplicate offer redelivered when the pair is already ACTIVE
  // must be an idempotent NO-OP (not restart the FSM), per §5.6 / MigrationReview C.3 watch-item.
  await mutate(loN, '::actor::qa_mig_resend_offer', { peer: hiN.cid });
  await sleep(4000);
  const hiSt2 = ro(hiN, '::actor::qa_mig_state', { cid: loN.cid });
  ok(hiSt2.Reduce('phase').Visualize() === 'active', 'idempotency: duplicate offer at ACTIVE is a no-op (FSM not restarted)');
  ok(hex(getBin(hiSt2, 'epoch')) === hex(hiEp), 'idempotency: duplicate offer does NOT change the epoch');
  const hiAct2 = getBin(ro(hiN, '::actor::qa_e2e_active', { cid: loN.cid }), 'sid');
  ok(hex(hiAct2) === hex(hiAct), 'idempotency: duplicate offer does NOT disturb the active session');

  // ═══ INCREMENT B — SEEN-not-epoch send/receive CONSISTENCY (already-E2E pre-migration pair). ═══
  // The SEND gate boxes app as receive_e2e_message_tx for EVERY e2e-capable (seen) contact, not only
  // epoch-pinned/migrated ones. So the RECEIVE accept-gate must accept seen-not-epoch peers too (else
  // an already-E2E pair's app is silently DROPPED). And §5.7 downgrade-refusal stays EPOCH-only: a
  // seen-not-epoch peer's LEGACY plaintext is STILL accepted (seen is advertisement-strength).
  console.log('=== mig: INCREMENT B — seen-not-epoch already-E2E pair (send/receive consistency) ===');
  const E3 = await mkNode('mig-gate-E3', 'E3');
  const E4 = await mkNode('mig-gate-E4', 'E4'); await sleep(1000);
  const einv = await mutate(E3, '::a2a_messaging::generate_invite', { name: 'E4' });
  await mutate(E4, '::a2a_messaging::add_contact', { invite: binv(E4, Buffer.from(einv.Reduce('invite').GetBinary())), name: 'E3' });
  await sleep(6000);   // invite redeem round-trips (establishes contacts + peer_ads incl. e2e bundle)
  // Mark BOTH directions e2e-SEEN (cap_e2e) WITHOUT migrating — an already-E2E, non-epoch pair.
  await mutate(E3, '::actor::qa_learn_peer', { cid: E4.cid, pv: 9, caps: ['core.e2e'] });
  await mutate(E4, '::actor::qa_learn_peer', { cid: E3.cid, pv: 9, caps: ['core.e2e'] });
  ok(ro(E3, '::actor::qa_e2e_route', { cid: E4.cid }).Reduce('route').Visualize() === 'e2e', 'seen-not-epoch: app-data route == "e2e" for a seen (no-epoch) contact');
  await mutate(E4, '::actor::qa_recv_reset', {});
  const sMsg = 'seen-not-epoch: app over an already-E2E session, no migration in play';
  const sSend = await mutate(E3, '::a2a_messaging::send_message', { contact: 'E4', text: sMsg });
  ok(sSend.Reduce('route').Visualize() === 'e2e', 'seen-not-epoch: send_message boxed as receive_e2e_message_tx (send-side consistency)');
  await sleep(4000);
  ok(ro(E4, '::actor::qa_recv_last', {}).Reduce('text').Visualize() === sMsg, 'seen-not-epoch: receive ACCEPTS + decrypts + delivers (accept-gate = e2e_pinned/seen, closes the latent drop)');
  // Legacy plaintext from the SAME seen-not-epoch peer is STILL delivered (downgrade-refusal is epoch-only).
  await mutate(E4, '::actor::qa_recv_reset', {});
  await mutate(E3, '::actor::qa_send_legacy', { contact: 'E4', text: 'seen-not-epoch legacy — still delivered' });
  await sleep(4000);
  ok(ro(E4, '::actor::qa_recv_last', {}).Reduce('text').Visualize() === 'seen-not-epoch legacy — still delivered', 'seen-not-epoch: LEGACY plaintext STILL accepted (downgrade-refusal is EPOCH-only, not seen)');

  // ═══ INCREMENT C — ACCEPT-GATE REJECT: an e2e box from a peer THIS side has not seen (and is not
  // a committed initiator for) is REJECTED before decode — no delivery, no session mutation. ═══
  console.log('=== mig: INCREMENT C — accept-gate reject (non-e2e peer → dropped, never decoded) ===');
  const E5 = await mkNode('mig-gate-E5', 'E5');
  const E6 = await mkNode('mig-gate-E6', 'E6'); await sleep(1000);
  const e5inv = await mutate(E5, '::a2a_messaging::generate_invite', { name: 'E6' });
  await mutate(E6, '::a2a_messaging::add_contact', { invite: binv(E6, Buffer.from(e5inv.Reduce('invite').GetBinary())), name: 'E5' });
  await sleep(6000);
  // ONLY the sender marks the peer seen (so it routes e2e); the RECEIVER does NOT → accept-gate FALSE.
  await mutate(E5, '::actor::qa_learn_peer', { cid: E6.cid, pv: 9, caps: ['core.e2e'] });
  ok(ro(E5, '::actor::qa_e2e_route', { cid: E6.cid }).Reduce('route').Visualize() === 'e2e', 'accept-reject: sender routes e2e (it has seen the peer)');
  await mutate(E6, '::actor::qa_recv_reset', {});
  const rSend = await mutate(E5, '::a2a_messaging::send_message', { contact: 'E6', text: 'must be rejected — receiver has not seen this peer' });
  ok(rSend.Reduce('route').Visualize() === 'e2e', 'accept-reject: sender boxed the app as receive_e2e_message_tx');
  await sleep(4000);
  ok(ro(E6, '::actor::qa_recv_last', {}).Reduce('text').Visualize() === '', 'accept-reject: receiver DROPS the e2e box (not e2e_pinned, not committed → reject BEFORE decode, no delivery/session mutation)');

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

  // ═══ §5.8 simultaneous upgrades (crossing offers) → deterministic collapse ═══
  // Both peers trigger an offer at (nearly) the same time. The election (LOWER cid initiates)
  // collapses the crossing proposals to exactly ONE migration: the HIGHER-cid peer, on receiving the
  // lower's offer, abandons its own `offered` state and ACKs (GATE 4 collapse); the LOWER-cid peer
  // treats the higher's offer as a SOLICITATION and re-emits its authoritative offer. They converge —
  // lower=initiator, higher=responder, one shared epoch + session — regardless of arrival order.
  // (The offers cross while both are still `offered`, well before any 4-leg handshake completes, so
  // the lower reaches `active` on the lower's own nonce; a higher-cid peer never becomes initiator.)
  console.log('=== mig: §5.8 simultaneous upgrades (crossing offers) → deterministic collapse ===');
  const SU1 = await mkNode('mig-gate-SU1', 'SU1');
  const SU2 = await mkNode('mig-gate-SU2', 'SU2'); await sleep(1000);
  { const invS = await mutate(SU1, '::a2a_messaging::generate_invite', { name: 'SU2' });
    await mutate(SU2, '::a2a_messaging::add_contact', { invite: binv(SU2, Buffer.from(invS.Reduce('invite').GetBinary())), name: 'SU1' });
    await sleep(6000);
    const [lo, hi] = SU1.cid < SU2.cid ? [SU1, SU2] : [SU2, SU1];
    // BOTH trigger, back-to-back (crossing offers in flight before either handshake can complete).
    await mutate(lo, '::actor::qa_mig_trigger_offer', { peer: hi.cid });
    await mutate(hi, '::actor::qa_mig_trigger_offer', { peer: lo.cid });
    await sleep(20000);   // crossing offers + solicitation re-emit + ack → commit → confirm settle
    const ls = ro(lo, '::actor::qa_mig_state', { cid: hi.cid });
    const hs = ro(hi, '::actor::qa_mig_state', { cid: lo.cid });
    console.log(`  DIAG collapse: lo phase=${ls.Reduce('phase').Visualize()} init=${ls.Reduce('initiator').Visualize()} / hi phase=${hs.Reduce('phase').Visualize()} init=${hs.Reduce('initiator').Visualize()}`);
    ok(ls.Reduce('phase').Visualize() === 'active' && hs.Reduce('phase').Visualize() === 'active', '★ collapse: BOTH peers converge to active (crossing offers collapsed to ONE migration)');
    ok(T(ls.Reduce('initiator').Visualize()) && !T(hs.Reduce('initiator').Visualize()), '★ collapse: deterministic roles — the LOWER cid initiated, the HIGHER responded (election, not arrival order)');
    const le = getBin(ls, 'epoch'), he = getBin(hs, 'epoch');
    ok(le.length === 32 && hex(le) === hex(he), 'collapse: both settle on ONE shared epoch (no split-brain / no double migration)');
    const la = getBin(ro(lo, '::actor::qa_e2e_active', { cid: hi.cid }), 'sid');
    const ha = getBin(ro(hi, '::actor::qa_e2e_active', { cid: lo.cid }), 'sid');
    ok(la.length > 0 && hex(la) === hex(ha), 'collapse: both share ONE migrated session (exactly-once rotation)');
    const lp = ro(lo, '::actor::qa_mig_pin', { cid: hi.cid }), hp = ro(hi, '::actor::qa_mig_pin', { cid: lo.cid });
    ok(T(lp.Reduce('pinned').Visualize()) && T(hp.Reduce('pinned').Visualize()) && hex(getBin(lp, 'session_id')) === hex(la), 'collapse: both epoch-pinned to the shared migrated session'); }

  // ═══ §5.8 higher-cid-only evidence → solicitation → converge (lower initiates) ═══
  // Only the HIGHER-cid peer sees the 0.9 evidence first and offers. Its offer functions as a
  // SOLICITATION: the lower-cid peer (the elected initiator) does NOT ack it — it emits its OWN
  // authoritative offer, which the higher acks. Converges lower=initiator; no unelected (higher)
  // proposer can win, even as first mover.
  console.log('=== mig: §5.8 higher-cid-only evidence → solicitation → converge (lower initiates) ===');
  const HO1 = await mkNode('mig-gate-HO1', 'HO1');
  const HO2 = await mkNode('mig-gate-HO2', 'HO2'); await sleep(1000);
  { const invH = await mutate(HO1, '::a2a_messaging::generate_invite', { name: 'HO2' });
    await mutate(HO2, '::a2a_messaging::add_contact', { invite: binv(HO2, Buffer.from(invH.Reduce('invite').GetBinary())), name: 'HO1' });
    await sleep(6000);
    const [lo, hi] = HO1.cid < HO2.cid ? [HO1, HO2] : [HO2, HO1];
    // ONLY the HIGHER cid triggers (it saw evidence first) — its offer solicits the lower.
    await mutate(hi, '::actor::qa_mig_trigger_offer', { peer: lo.cid });
    await sleep(18000);   // solicitation → lower's authoritative offer → ack → commit → confirm
    const ls = ro(lo, '::actor::qa_mig_state', { cid: hi.cid });
    const hs = ro(hi, '::actor::qa_mig_state', { cid: lo.cid });
    console.log(`  DIAG solicit: lo phase=${ls.Reduce('phase').Visualize()} init=${ls.Reduce('initiator').Visualize()} / hi phase=${hs.Reduce('phase').Visualize()} init=${hs.Reduce('initiator').Visualize()}`);
    ok(ls.Reduce('phase').Visualize() === 'active' && hs.Reduce('phase').Visualize() === 'active', '★ solicitation: a higher-cid-only offer still drives BOTH to active (the lower emitted the authoritative offer)');
    ok(T(ls.Reduce('initiator').Visualize()) && !T(hs.Reduce('initiator').Visualize()), '★ solicitation: the LOWER cid initiated despite the HIGHER offering FIRST (election beats first-mover)');
    const le = getBin(ls, 'epoch'), he = getBin(hs, 'epoch');
    ok(le.length === 32 && hex(le) === hex(he), 'solicitation: both settle on the same epoch');
    const la = getBin(ro(lo, '::actor::qa_e2e_active', { cid: hi.cid }), 'sid');
    const ha = getBin(ro(hi, '::actor::qa_e2e_active', { cid: lo.cid }), 'sid');
    ok(la.length > 0 && hex(la) === hex(ha), 'solicitation: both share ONE migrated session'); }

  // ═══ §5.8 already-E2E pair → FULL-FSM handshake rotates ONCE (finding b) ═══
  // The C.3 handshake proves box-only pairs (no prior session). This proves a pair that ALREADY has a
  // LIVE e2e session runs the WHOLE migration FSM (offer→ack→commit→confirm) through the REAL handlers
  // and rotates EXACTLY ONCE onto a fresh migrated session that REPLACES the live one — the live
  // session is preserved (staged-not-installed) until commit_rotation promotes the rotation.
  console.log('=== mig: §5.8 already-E2E pair → FULL-FSM handshake rotates once (finding b) ===');
  const AE1 = await mkNode('mig-gate-AE1', 'AE1');
  const AE2 = await mkNode('mig-gate-AE2', 'AE2'); await sleep(1000);
  { const invA = await mutate(AE1, '::a2a_messaging::generate_invite', { name: 'AE2' });
    await mutate(AE2, '::a2a_messaging::add_contact', { invite: binv(AE2, Buffer.from(invA.Reduce('invite').GetBinary())), name: 'AE1' });
    await sleep(6000);
    const [lo, hi] = AE1.cid < AE2.cid ? [AE1, AE2] : [AE2, AE1];
    // Establish a PRE-MIGRATION live e2e session lo→hi (the "already-E2E" precondition).
    const hiBundle = getBin(ro(hi, '::actor::qa_e2e_bundle', {}), 'bundle');
    const loIk = getBin(ro(lo, '::actor::qa_e2e_ik', {}), 'ik');
    const lenv = await mutate(lo, '::actor::qa_e2e_first_send', { cid: hi.cid, pt: binv(lo, Buffer.from('pre-migration live traffic')), peer: binv(lo, hiBundle) });
    await mutate(hi, '::actor::qa_e2e_recv', { from: lo.cid, ik: binv(hi, loIk), olm_type: +lenv.Reduce('olm_type').Visualize(), ciphertext: binv(hi, getBin(lenv, 'ciphertext')) });
    const liveLo = getBin(ro(lo, '::actor::qa_e2e_active', { cid: hi.cid }), 'sid');
    const liveHi = getBin(ro(hi, '::actor::qa_e2e_active', { cid: lo.cid }), 'sid');
    ok(liveLo.length > 0 && hex(liveLo) === hex(liveHi), 'already-E2E setup: both peers share a LIVE pre-migration session');
    // Now run the FULL migration FSM through the real handlers.
    await mutate(lo, '::actor::qa_mig_trigger_offer', { peer: hi.cid });
    await sleep(12000);   // offer → ack → commit → confirm
    const ls = ro(lo, '::actor::qa_mig_state', { cid: hi.cid });
    const hs = ro(hi, '::actor::qa_mig_state', { cid: lo.cid });
    console.log(`  DIAG already-E2E: lo phase=${ls.Reduce('phase').Visualize()} / hi phase=${hs.Reduce('phase').Visualize()}`);
    ok(ls.Reduce('phase').Visualize() === 'active' && hs.Reduce('phase').Visualize() === 'active', '★ already-E2E: the full FSM reaches active on an ALREADY-live pair (offer→ack→commit→confirm through real handlers)');
    const migLo = getBin(ro(lo, '::actor::qa_e2e_active', { cid: hi.cid }), 'sid');
    const migHi = getBin(ro(hi, '::actor::qa_e2e_active', { cid: lo.cid }), 'sid');
    ok(migLo.length > 0 && hex(migLo) === hex(migHi), 'already-E2E: both converge on ONE fresh migrated session');
    ok(hex(migLo) !== hex(liveLo), '★ already-E2E: rotated ONCE — the migrated session REPLACED the pre-migration live session (distinct session_id, both peers)');
    const lp = ro(lo, '::actor::qa_mig_pin', { cid: hi.cid }), hp = ro(hi, '::actor::qa_mig_pin', { cid: lo.cid });
    ok(T(lp.Reduce('pinned').Visualize()) && T(hp.Reduce('pinned').Visualize()) && hex(getBin(lp, 'session_id')) === hex(migLo), 'already-E2E: both epoch-pinned to the migrated (not the old live) session'); }

  // ═══ §5.8 late/replayed HIGHER-cid offer at an ACTIVE lower node → NO-OP (solicitation phase-guard) ═══
  // A completed migration must not be restarted by a stale higher-cid offer. Before the guard, the
  // GATE4 solicitation path re-emitted `offered` unconditionally — diverging contact_migration from the
  // still-set epoch pin. The guard NO-OPs a higher-cid solicitation once the lower node is committed/
  // active (MigrationReview: exhaustive-phase invariant; only a genuinely new nonce/epoch drives §5.6).
  console.log('=== mig: §5.8 late higher-cid offer at an ACTIVE lower node → NO-OP (solicitation phase-guard) ===');
  const LG1 = await mkNode('mig-gate-LG1', 'LG1');
  const LG2 = await mkNode('mig-gate-LG2', 'LG2'); await sleep(1000);
  { const invL = await mutate(LG1, '::a2a_messaging::generate_invite', { name: 'LG2' });
    await mutate(LG2, '::a2a_messaging::add_contact', { invite: binv(LG2, Buffer.from(invL.Reduce('invite').GetBinary())), name: 'LG1' });
    await sleep(6000);
    const [lo, hi] = LG1.cid < LG2.cid ? [LG1, LG2] : [LG2, LG1];
    await mutate(lo, '::actor::qa_mig_trigger_offer', { peer: hi.cid });
    await sleep(12000);   // offer → ack → commit → confirm → active
    ok(ro(lo, '::actor::qa_mig_state', { cid: hi.cid }).Reduce('phase').Visualize() === 'active', 'setup: the lower node migrated to active');
    const pin0 = getBin(ro(lo, '::actor::qa_mig_pin', { cid: hi.cid }), 'session_id');
    const act0 = getBin(ro(lo, '::actor::qa_e2e_active', { cid: hi.cid }), 'sid');
    // Inject a LATE / stale HIGHER-cid offer at the now-active lower node.
    await mutate(hi, '::actor::qa_mig_trigger_offer', { peer: lo.cid });
    await sleep(5000);
    ok(ro(lo, '::actor::qa_mig_state', { cid: hi.cid }).Reduce('phase').Visualize() === 'active', '★ solicitation-guard: the active lower node NO-OPs the late higher-cid offer (stays active — NOT reset to offered)');
    ok(hex(getBin(ro(lo, '::actor::qa_mig_pin', { cid: hi.cid }), 'session_id')) === hex(pin0) && pin0.length > 0, 'solicitation-guard: epoch pin unchanged (contact_migration and the pin stay consistent)');
    ok(hex(getBin(ro(lo, '::actor::qa_e2e_active', { cid: hi.cid }), 'sid')) === hex(act0), 'solicitation-guard: active session unchanged (no rotation restarted by the stale offer)'); }

  console.log('\n================ MIG ================');
  if (scorecard.length === 0) console.log('MIG: ALL GREEN');
  else { console.log(`${scorecard.length} FAILURE(S):`); scorecard.forEach((s) => console.log('  ' + s)); }
  await sleep(300);
  process.exit(scorecard.length === 0 ? 0 : 1);
}
main().catch((e) => { log('DRIVER ERR:', e.stack ?? e.message); process.exit(1); });
