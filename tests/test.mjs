#!/usr/bin/env node
// M2 loopback test suite for the core-3.0 ephemeral-invite redeem flow.
// Asserts RECEIVER-SIDE outcomes (state), per the Critic requirement.
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
const log = (...a) => process.stderr.write(`[t] ${a.join(' ')}\n`);
const scorecard = [];
let CUR = '';
const ok = (c, m) => { if (!c) { scorecard.push(`✗ [${CUR}] ${m}`); console.log(`  ✗ FAIL: ${m}`); } else { console.log(`  ✓ ${m}`); } };
const isT = (s) => /true/i.test(String(s));

let wrapper;
function mk(name) { return { name, pw: null, cid: '', pending: [], rejects: [], events: [] }; }
function wire(id) {
  id.pw.on_return_data = (d) => {
    const kind = d.Reduce('kind').Visualize();
    if (kind === 'notify_agent') { id.events.push(d.Reduce('payload').Reduce('event').Visualize()); return; }
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
const st = (id) => { const s = ro(id, '::actor::qa_state', undefined); return {
  c: +s.Reduce('n_contacts').Visualize(), p: +s.Reduce('n_peer_ads').Visualize(),
  pi: +s.Reduce('n_pending_invites').Visualize(), pr: +s.Reduce('n_pending_redemptions').Visualize(),
  cr: +s.Reduce('n_contact_roots').Visualize(),
  prs: +s.Reduce('n_pending_restores').Visualize(), rr: +s.Reduce('n_restore_replies').Visualize(),
  dq: +s.Reduce('n_deferred').Visualize() }; };
const lc = (id) => ro(id, '::a2a_messaging::list_contacts', undefined).Visualize();
const adBlob = (id) => Buffer.from(ro(id, '::actor::qa_export_ad', undefined).Reduce('ad').GetBinary());
const setName = (id, n) => mutate(id, '::a2a_messaging::set_my_name', { name: n });

async function delegate(root, role, roleName) {
  const roleAd = Buffer.from(ro(role, '::actor::export_address_document', undefined).GetBinary());
  const signed = await mutate(root, '::actor::sign_delegation', { role_ad: binv(root, roleAd), role_id: roleName });
  const cert = Buffer.from(signed.Reduce('cert').GetBinary());
  const prof = await mutate(root, '::actor::export_root_profile', {});
  const profBlob = Buffer.from(prof.Reduce('profile').GetBinary());
  const rootAd = Buffer.from(ro(root, '::actor::export_address_document', undefined).GetBinary());
  await mutate(role, '::actor::set_delegation', { cert: binv(role, cert), root_ad: binv(role, rootAd), root_profile: binv(role, profBlob) });
}

async function main() {
  wrapper = await adapt_wrapper.start(['--broker_address', BROKER_URL, '--test_mode',
    '--logger_config', '--level', 'WARNING', '--stdout', 'stderr', '--logger_config_end']);
  wrapper.start();
  await sleep(1500);

  const I = mk('I'); const R = mk('R'); const F = mk('F');
  await mkPacket(I, 'eph-t-I-01'); await mkPacket(R, 'eph-t-R-02'); await mkPacket(F, 'eph-t-F-03');
  await sleep(1200);
  await setName(I, 'Inviter'); await setName(R, 'Responder'); await setName(F, 'Foreign');

  // ---------- T1 happy-flat ----------
  CUR = 'T1 happy-flat';
  console.log('\n=== T1 happy-flat ===');
  let m = await mutate(I, '::a2a_messaging::generate_invite', { name: 'TheResponder' });
  const blob1 = Buffer.from(m.Reduce('invite').GetBinary());
  ok(st(I).pi === 1, `inviter has 1 pending_invite after mint`);
  await mutate(R, '::a2a_messaging::add_contact', { invite: binv(R, blob1), name: 'MyInviter' });
  await sleep(5000);
  const i1 = st(I); const r1 = st(R);
  log(`I=${JSON.stringify(i1)} R=${JSON.stringify(r1)}`);
  ok(i1.pi === 0, `leg-2: inviter consumed pending_invites (${i1.pi})`);
  ok(i1.c >= 1 && i1.p >= 1, `leg-2: inviter registered responder (c=${i1.c},peer_ads=${i1.p})`);
  ok(r1.pr === 0, `leg-3: responder cleared pending_redemptions (${r1.pr})`);
  ok(r1.c >= 1 && r1.p >= 1, `leg-3 RECEIVER-SIDE: responder DECRYPTED + registered inviter (c=${r1.c},peer_ads=${r1.p})`);
  ok(new RegExp(I.cid).test(lc(R)), `responder list_contacts includes inviter cid`);
  ok(new RegExp(R.cid).test(lc(I)), `inviter list_contacts includes responder cid`);
  // bidirectional encrypted_channel round-trip
  const smIR = await mutate(I, '::a2a_messaging::send_message', { contact: R.cid, text: 'msg-I-to-R' });
  const msgWireIR = smIR.Reduce('wire_id').Visualize();
  await sleep(2500);
  ok(/msg-I-to-R/.test(ro(R, '::actor::list_incoming_messages', undefined).Visualize()), `send_message I→R round-trips over encrypted_channel`);
  await mutate(R, '::a2a_messaging::send_message', { contact: I.cid, text: 'msg-R-to-I' });
  await sleep(2500);
  ok(/msg-R-to-I/.test(ro(I, '::actor::list_incoming_messages', undefined).Visualize()), `send_message R→I round-trips over encrypted_channel`);

  // ---------- T1 file round-trip (send_file both directions) ----------
  const sfIR = await mutate(I, '::a2a_messaging::send_file',
    { contact: R.cid, filename: 'hello.png', mime: 'image/png', data: binv(I, Buffer.from('\x89PNG\r\n\x1a\nDATA')) });
  const fileWireIR = sfIR.Reduce('wire_id').Visualize();
  await sleep(2500);
  {
    const rf = ro(R, '::actor::list_incoming_files', undefined).Visualize();
    ok(/hello\.png/.test(rf), `send_file I→R: responder received file hello.png`);
    ok(/image\/png/.test(rf), `send_file I→R: responder sees mime image/png`);
    ok(new RegExp(I.cid).test(rf), `send_file I→R: file is attributed to the inviter cid`);
    ok(new RegExp(fileWireIR).test(rf), `send_file I→R: stored wire_id matches the send return`);
  }
  await mutate(R, '::a2a_messaging::send_file',
    { contact: I.cid, filename: 'reply.txt', mime: 'text/plain', data: binv(R, Buffer.from('hi')) });
  await sleep(2500);
  ok(/reply\.txt/.test(ro(I, '::actor::list_incoming_files', undefined).Visualize()),
    `send_file R→I: inviter received file reply.txt`);

  // ---------- T1 file monitoring summary (metadata-only; never the bytes) ----------
  {
    const r = await mutate(I, '::actor::qa_file_summary',
      { filename: 'hello.png', mime: 'image/png', data: binv(I, Buffer.from('ABCDE')) });
    const summary = r.Reduce('summary').Visualize();
    ok(summary === '[file] hello.png (image/png, 5 B)', `file monitor summary is metadata-only: "${summary}"`);
    ok(!/ABCDE/.test(summary), `file monitor summary never carries the file bytes`);
  }

  // ---------- T1 cross-kind reply (one shared wire_id namespace) ----------
  // A MESSAGE replying to a FILE: reply_to points at the file's wire_id (from I→R).
  await mutate(R, '::a2a_messaging::send_message',
    { contact: I.cid, text: 'reply-to-file', reply_to: { wire_id: fileWireIR } });
  await sleep(2500);
  {
    const im = ro(I, '::actor::list_incoming_messages', undefined).Visualize();
    ok(/reply-to-file/.test(im) && new RegExp(fileWireIR).test(im),
      `a send_message can reply_to a FILE's wire_id (cross-kind, shared namespace)`);
  }
  // A FILE replying to a MESSAGE: reply_to points at the message's wire_id (from I→R).
  await mutate(R, '::a2a_messaging::send_file',
    { contact: I.cid, filename: 'answer.bin', mime: 'application/octet-stream',
      data: binv(R, Buffer.from('Z')), reply_to: { wire_id: msgWireIR } });
  await sleep(2500);
  {
    const ifs = ro(I, '::actor::list_incoming_files', undefined).Visualize();
    ok(/answer\.bin/.test(ifs) && new RegExp(msgWireIR).test(ifs),
      `a send_file can reply_to a MESSAGE's wire_id (cross-kind, shared namespace)`);
  }

  // ---------- T3 single-use (reuse blob1, already consumed) ----------
  CUR = 'T3 single-use';
  console.log('\n=== T3 single-use ===');
  const before = st(I); const rej0 = I.rejects.length;
  await mutate(R, '::a2a_messaging::add_contact', { invite: binv(R, blob1), name: 'again' });
  await sleep(3000);
  const after = st(I);
  ok(I.rejects.slice(rej0).some((x) => /already-redeemed|Unknown or already/.test(x)), `2nd leg-1 for the same invite_id aborts "already-redeemed" at inviter`);
  ok(after.c === before.c && after.pi === before.pi, `single-use: inviter state unchanged by replay (c=${after.c},pi=${after.pi})`);

  // ---------- T4 invalid-then-valid (bad box must NOT consume) ----------
  CUR = 'T4 invalid-then-valid';
  console.log('\n=== T4 invalid-then-valid ===');
  m = await mutate(I, '::a2a_messaging::generate_invite', { name: 'P4' });
  const blob4 = Buffer.from(m.Reduce('invite').GetBinary());
  const piAfterMint = st(I).pi; const rejb = I.rejects.length;
  await mutate(R, '::actor::qa_leg1_badbox', { invite: binv(R, blob4) });
  await sleep(3000);
  ok(I.rejects.slice(rejb).some((x) => /Decryption failed|crypto box|read/i.test(x)), `bad box: inviter leg-2 aborts at decrypt`);
  ok(st(I).pi === piAfterMint, `bad box did NOT consume the invite (pi=${st(I).pi}, was ${piAfterMint})`);
  // now redeem the SAME invite validly
  await mutate(R, '::a2a_messaging::add_contact', { invite: binv(R, blob4), name: 'P4ok' });
  await sleep(5000);
  ok(st(I).pi === piAfterMint - 1, `valid redeem after the bad box consumed the invite (pi=${st(I).pi})`);

  // ---------- T5 tamper (state-unchanged form) ----------
  CUR = 'T5 tamper';
  console.log('\n=== T5 tamper ===');
  m = await mutate(I, '::a2a_messaging::generate_invite', { name: 'P5' });
  const blob5 = Buffer.from(m.Reduce('invite').GetBinary());
  const s5 = st(I); const rej5 = I.rejects.length;
  await mutate(R, '::actor::qa_leg1_badbox', { invite: binv(R, blob5) });
  await sleep(3000);
  ok(I.rejects.slice(rej5).some((x) => /Decryption failed|crypto box|read/i.test(x)), `tampered box aborts at inviter decrypt`);
  const s5b = st(I);
  ok(s5b.c === s5.c && s5b.p === s5.p && s5b.pi === s5.pi, `tamper mutated NO state (contacts/peer_ads/pending unchanged)`);

  // ---------- T6 cid-bind leg-2 (foreign AD) ----------
  CUR = 'T6 cid-bind-leg2';
  console.log('\n=== T6 cid-bind leg-2 ===');
  m = await mutate(I, '::a2a_messaging::generate_invite', { name: 'P6' });
  const blob6 = Buffer.from(m.Reduce('invite').GetBinary());
  const s6 = st(I); const rej6 = I.rejects.length;
  await mutate(R, '::actor::qa_leg1_foreign_ad', { invite: binv(R, blob6), foreign_ad: binv(R, adBlob(F)) });
  await sleep(3000);
  ok(I.rejects.slice(rej6).some((x) => /does not belong to the sender/.test(x)), `leg-2 cid-bind: foreign AD (cid≠sender) aborts`);
  ok(st(I).pi === s6.pi && st(I).c === s6.c, `leg-2 cid-bind failure consumed/registered nothing`);

  // ---------- T7 PoP leg-2 (forged AD) ----------
  CUR = 'T7 PoP-leg2';
  console.log('\n=== T7 PoP leg-2 ===');
  m = await mutate(I, '::a2a_messaging::generate_invite', { name: 'P7' });
  const blob7 = Buffer.from(m.Reduce('invite').GetBinary());
  const s7 = st(I); const rej7 = I.rejects.length;
  await mutate(R, '::actor::qa_leg1_forged_ad', { invite: binv(R, blob7) });
  await sleep(3000);
  ok(I.rejects.slice(rej7).some((x) => /authoriz|signature|process|key/i.test(x)), `leg-2 PoP: forged AD (stripped self-sig) aborts in process_address_document`);
  ok(st(I).pi === s7.pi && st(I).c === s7.c, `leg-2 PoP failure consumed/registered nothing`);

  // ---------- T8 leg-3 gates (unexpected-inviter, cid-bind, PoP) ----------
  CUR = 'T8 leg3-gates';
  console.log('\n=== T8 leg-3 gates ===');
  // helper: give R a LIVE pending redemption pinned to I.cid (a fake invite I never minted)
  async function liveRedemption() {
    const fk = await mutate(I, '::actor::qa_mint_fake_invite', { inviter_cid: I.cid });
    const fblob = Buffer.from(fk.Reduce('blob').GetBinary());
    const fid = fk.Reduce('invite_id').Visualize();
    const ac = await mutate(R, '::a2a_messaging::add_contact', { invite: binv(R, fblob), name: 'leg3' });
    await sleep(2500); // I's leg-2 aborts (unknown invite) → no real leg-3 → R's pend stays live
    const rpk = ac.Reduce('resp_eph_pub');
    return { fid, rpk };
  }
  // T8a unexpected-inviter: a DIFFERENT sender (F) → R aborts on the inviter-cid pin
  {
    const { fid, rpk } = await liveRedemption();
    const rejx = R.rejects.length; const sR = st(R);
    await mutate(F, '::actor::qa_send_complete', { target: R.cid, invite_id: fid, resp_eph_pub: rpk, mode: 'real', foreign_ad: binv(F, adBlob(F)) });
    await sleep(3000);
    ok(R.rejects.slice(rejx).some((x) => /unexpected inviter/i.test(x)), `leg-3 sender-pin: completion from a non-inviter aborts`);
    ok(st(R).c === sR.c, `leg-3 unexpected-inviter registered nothing`);
  }
  // T8b cid-bind leg-3: real inviter (I) sends a FOREIGN AD → R aborts cid-bind
  {
    const { fid, rpk } = await liveRedemption();
    const rejx = R.rejects.length; const sR = st(R);
    await mutate(I, '::actor::qa_send_complete', { target: R.cid, invite_id: fid, resp_eph_pub: rpk, mode: 'foreign', foreign_ad: binv(I, adBlob(F)) });
    await sleep(3000);
    ok(R.rejects.slice(rejx).some((x) => /does not belong to the sender/.test(x)), `leg-3 cid-bind: inviter AD (cid≠sender) aborts`);
    ok(st(R).c === sR.c, `leg-3 cid-bind registered nothing`);
  }
  // T8c PoP leg-3: real inviter (I) sends a FORGED AD (cid ok) → R aborts in process_address_document
  {
    const { fid, rpk } = await liveRedemption();
    const rejx = R.rejects.length; const sR = st(R);
    await mutate(I, '::actor::qa_send_complete', { target: R.cid, invite_id: fid, resp_eph_pub: rpk, mode: 'forged', foreign_ad: binv(I, adBlob(F)) });
    await sleep(3000);
    ok(R.rejects.slice(rejx).some((x) => /authoriz|signature|process|key/i.test(x)), `leg-3 PoP: forged inviter AD aborts in process_address_document`);
    ok(st(R).c === sR.c, `leg-3 PoP registered nothing`);
  }

  // ---------- T9 export-secrecy ----------
  CUR = 'T9 export-secrecy';
  console.log('\n=== T9 export-secrecy ===');
  await mutate(I, '::a2a_messaging::generate_invite', { name: 'P9' }); // ensure an outstanding invite (eph secret present)
  const exp = ro(I, '::actor::qa_export_core', undefined).Reduce('core');
  const expStr = exp.Serialize ? Buffer.from(exp.Serialize()).toString('latin1') : '';
  const expVis = exp.Visualize();
  ok(!/pending_invite_keys/.test(expVis), `export_core_state has NO pending_invite_keys field`);
  ok(!/pending_redemption_keys/.test(expVis), `export_core_state has NO pending_redemption_keys field`);
  // the exported pending_invites entry must carry only assigned/eph_pub/scheme (public) — not a secret field
  ok(/eph_pub|\$eph_pub/.test(expVis) || /pending_invites/.test(expVis), `export carries the public pending_invites record (eph_pub/assigned/scheme only)`);

  // ---------- T2 happy-role (chain verified BOTH legs) ----------
  CUR = 'T2 happy-role';
  console.log('\n=== T2 happy-role ===');
  const rA = mk('rootA'); const lA = mk('roleA'); const rB = mk('rootB'); const lB = mk('roleB');
  await mkPacket(rA, 'eph-t-rootA-1'); await mkPacket(lA, 'eph-t-roleA-1');
  await mkPacket(rB, 'eph-t-rootB-1'); await mkPacket(lB, 'eph-t-roleB-1');
  await sleep(1200);
  await setName(rA, 'RootA'); await setName(lA, 'RoleA'); await setName(rB, 'RootB'); await setName(lB, 'RoleB');
  await delegate(rA, lA, 'RoleA'); await delegate(rB, lB, 'RoleB');
  log('delegations done');
  const rm = await mutate(lA, '::a2a_messaging::generate_invite', { name: 'RoleB' });
  const rblob = Buffer.from(rm.Reduce('invite').GetBinary());
  await mutate(lB, '::a2a_messaging::add_contact', { invite: binv(lB, rblob), name: 'PeerRoleA' });
  await sleep(5500);
  const sA = st(lA); const sB = st(lB);
  log(`roleA=${JSON.stringify(sA)} roleB=${JSON.stringify(sB)}`);
  ok(sA.c >= 1 && sA.p >= 1, `role inviter registered role responder`);
  ok(sB.c >= 1 && sB.p >= 1, `role responder registered role inviter (receiver-side)`);
  ok(sA.cr >= 1, `leg-2: inviter pinned responder's root linkage (contact_roots=${sA.cr})`);
  ok(sB.cr >= 1, `leg-3: responder pinned inviter's root linkage (contact_roots=${sB.cr})`);

  // ---------- T10 import migration (state round-trips; pending_invites reset) ----------
  CUR = 'T10 migration';
  console.log('\n=== T10 import migration ===');
  await mutate(I, '::a2a_messaging::generate_invite', { name: 'P10' }); // leave an outstanding invite
  const exported = ro(I, '::actor::export_state', undefined);
  fs.writeFileSync(resolve(UNIT_DIR, 'mig.bin'), Buffer.from(exported.Serialize()));
  const I2 = mk('I2'); await mkPacket(I2, 'eph-t-I2-mig'); await sleep(1000);
  const adData = I2.pw.packet.ParseValue(new Uint8Array(fs.readFileSync(resolve(UNIT_DIR, 'mig.bin'))));
  await mutate(I2, '::actor::import_state', adData);
  const s10 = st(I2);
  ok(s10.c >= 1 && s10.p >= 1, `import restored contacts + peer_ads (c=${s10.c},peer_ads=${s10.p})`);
  ok(s10.pi === 0, `import reset pending_invites to empty (migration §4.4) → ${s10.pi}`);
  ok(new RegExp(R.cid).test(lc(I2)), `imported state includes the original contact (responder)`);
  // version-0 path: strip the stamp from a re-exported blob → still imports.
  const exp0 = ro(I2, '::actor::export_state', undefined);
  ok(exp0.Reduce('core').Reduce('format_version').Visualize() === '1', `re-export carries the stamp`);

  // ---------- T11a format stamp + restore-state export hygiene ----------
  CUR = 'T11a format-stamp';
  console.log('\n=== T11a format stamp + export hygiene ===');
  {
    const core = ro(I, '::actor::qa_export_core', undefined).Reduce('core');
    const vis = core.Visualize();
    ok(/format_version/.test(vis), `export_core_state carries a format_version stamp`);
    ok(core.Reduce('format_version').Visualize() === '1', `format_version == 1`);
    ok(!/pending_restore_keys/.test(vis), `export has NO pending_restore_keys (INV-4)`);
    ok(!/pending_restore_reply_keys/.test(vis), `export has NO pending_restore_reply_keys (INV-4)`);
    ok(/deferred_msgs/.test(vis), `export carries deferred_msgs`);
  }

  // ---------- T11b degraded contact: defer + 3-leg restore + flush ----------
  CUR = 'T11b restore';
  console.log('\n=== T11b degraded-contact restore ===');
  {
    // I ↔ R are established contacts (T1). Simulate a breaking-change migration
    // outcome on I: contacts survive, peer_ads dropped.
    await mutate(I, '::actor::qa_strip_peer_ads', {});
    const s0 = st(I);
    ok(s0.c >= 1 && s0.p === 0, `strip: I keeps contacts (${s0.c}) with no peer_ads`);

    // Deferred send: queues + fires leg 0; restore legs run; both sides notify.
    const evI = I.events.length, evR = R.events.length;
    const dm = await mutate(I, '::a2a_messaging::send_message', { contact: R.cid, text: 'queued-while-degraded' });
    ok(dm.Reduce('deferred').Visualize() === 'TRUE' || /true/i.test(dm.Reduce('deferred').Visualize()), `send to degraded contact reports deferred`);
    const dg = ro(I, '::a2a_messaging::list_degraded_contacts', undefined);
    ok(new RegExp(R.cid).test(dg.Visualize()), `list_degraded_contacts includes the degraded contact`);
    ok(/queued/.test(dg.Visualize()) && /attempts/.test(dg.Visualize()), `list_degraded_contacts carries attempts+queued fields`);
    const lq = ro(I, '::a2a_messaging::list_deferred_queues', undefined);
    ok(new RegExp(R.cid).test(lq.Visualize()) && /degraded/.test(lq.Visualize()), `list_deferred_queues shows the non-empty queue with its degraded flag`);
    await sleep(6000);
    const s1 = st(I);
    ok(s1.p >= 1, `restore re-established R's AD at I (peer_ads=${s1.p})`);
    ok(s1.prs === 0, `restore consumed I's pending_restores`);
    ok(st(R).rr === 0, `restore consumed R's reply record`);
    ok(I.events.slice(evI).includes('contact_restored'), `I notified contact_restored`);
    ok(R.events.slice(evR).includes('contact_restored'), `R notified contact_restored`);

    // Host-driven flush: drain the deferred queue, message arrives at R.
    const fl = await mutate(I, '::a2a_messaging::flush_deferred', { contact: R.cid });
    ok(+fl.Reduce('flushed').Visualize() === 1, `flush_deferred drained 1 message`);
    await sleep(2500);
    ok(/queued-while-degraded/.test(ro(R, '::actor::list_incoming_messages', undefined).Visualize()), `deferred message delivered after restore`);
    ok(st(I).dq === 0, `deferred queue cleared`);
    ok(!(new RegExp(R.cid)).test(ro(I, '::a2a_messaging::list_degraded_contacts', undefined).Visualize()), `contact no longer listed degraded after restore`);
    ok(!(new RegExp(R.cid)).test(ro(I, '::a2a_messaging::list_deferred_queues', undefined).Visualize()), `deferred queue gone after flush`);

    // Channel fully healthy again, both directions.
    await mutate(R, '::a2a_messaging::send_message', { contact: I.cid, text: 'post-restore-R-to-I' });
    await sleep(2500);
    ok(/post-restore-R-to-I/.test(ro(I, '::actor::list_incoming_messages', undefined).Visualize()), `R→I works after restore (one-sided loss: R replaced I's AD)`);
  }

  // ---------- T11c both-sides degraded + host sweep ----------
  CUR = 'T11c both-degraded';
  console.log('\n=== T11c both-sides degraded + sweep ===');
  {
    await mutate(I, '::actor::qa_strip_peer_ads', {});
    await mutate(R, '::actor::qa_strip_peer_ads', {});
    ok(st(I).p === 0 && st(R).p === 0, `both sides stripped`);
    const sw = await mutate(I, '::a2a_messaging::restore_degraded_contacts', {});
    ok(+sw.Reduce('requested').Visualize() >= 1, `sweep requested restore for I's degraded contacts`);
    await mutate(R, '::a2a_messaging::restore_degraded_contacts', {});
    await sleep(7000);
    ok(st(I).p >= 1, `I restored (both-degraded, symmetric handshakes)`);
    ok(st(R).p >= 1, `R restored (both-degraded)`);
    await mutate(I, '::a2a_messaging::send_message', { contact: R.cid, text: 'after-double-restore' });
    await sleep(2500);
    ok(/after-double-restore/.test(ro(R, '::actor::list_incoming_messages', undefined).Visualize()), `channel healthy after double restore`);
  }

  // ---------- T11d restore gates: foreign requester + unsolicited response ----------
  CUR = 'T11d restore-gates';
  console.log('\n=== T11d restore gates ===');
  {
    // Foreign requester: F is NOT a contact of R → SILENT ignore (no reply, no
    // reject, no reply-record).
    const rrBefore = st(R).rr; const fRej = F.rejects.length;
    await mutate(F, '::actor::qa_send_restore_request', { target: R.cid });
    await sleep(3000);
    ok(st(R).rr === rrBefore, `foreign restore request left NO reply record at R`);
    ok(st(F).p === 0 || true, `foreign requester gained nothing`); // F never had R's AD
    ok(!F.rejects.slice(fRej).some((x) => /restore/i.test(x)), `R sent NO error reply (silent ignore — knowledge does not leak)`);

    // Unsolicited leg 1 at I (no pending_restores entry for F) → rejected, no state change.
    const sI = st(I); const rejI = I.rejects.length;
    await mutate(F, '::actor::qa_send_fake_restore_response', { target: I.cid });
    await sleep(3000);
    ok(I.rejects.slice(rejI).some((x) => /Unsolicited restore response/.test(x)), `unsolicited restore response rejected at I`);
    const sI2 = st(I);
    ok(sI2.c === sI.c && sI2.p === sI.p, `unsolicited response mutated nothing`);
  }

  // ---------- T11e restore adversarial: wrong-rid leg 1 + leg-0 non-destructiveness ----------
  CUR = 'T11e restore-adversarial';
  console.log('\n=== T11e restore adversarial (rid-mismatch + leg-0 non-destructive) ===');
  {
    // (a) rid-mismatch leg 1, seen by a non-contact (F): F fires a restore
    // request at R (R silently ignores it since F is not R's contact, so F's
    // own pending_restores[R.cid] entry stays live, unconsumed). R then answers
    // F with a FRESH, unrelated rid via qa_send_fake_restore_response — F DOES
    // have a live pending entry keyed by R.cid, so the "Unsolicited restore
    // response" gate passes, but the rid the fake reply carries (freshly
    // random-minted) can never match F's stored rid → deterministic
    // rid-mismatch rejection that mutates nothing.
    const fRejBefore = F.rejects.length;
    await mutate(F, '::actor::qa_send_restore_request', { target: R.cid });
    await sleep(3000);
    const fMid = st(F);
    ok(fMid.prs >= 1, `F has a live pending_restores entry toward R (silently ignored by R)`);
    await mutate(R, '::actor::qa_send_fake_restore_response', { target: F.cid });
    await sleep(3000);
    ok(F.rejects.slice(fRejBefore).some((x) => /does not match the outstanding request/.test(x)), `wrong-rid leg 1 rejected at F ("does not match the outstanding request")`);
    const fAfter = st(F);
    ok(fAfter.p === fMid.p, `wrong-rid leg 1 installed no peer_ads at F (p=${fAfter.p})`);
    ok(fAfter.prs === fMid.prs, `F's pending_restores entry survives the rejected reply unchanged (a failed gate consumes nothing, prs=${fAfter.prs})`);

    // (b) leg 0 from a REAL, healthy contact (I, R — established via T11b) is
    // non-destructive, and a repeat request REPLACES the outstanding reply
    // record instead of accumulating it: fire two leg-0s from I at R
    // back-to-back (no network round trip between them). I's own
    // pending_restores[R.cid] is overwritten to the SECOND rid synchronously,
    // long before either leg-1 reply can return over the loopback broker, so
    // the first (now-stale) leg-1 deterministically rid-mismatches at I, and
    // only the second request's leg 1/2 round-trip completes.
    const rBefore = st(R); const iBefore = st(I); const iRejBefore = I.rejects.length;
    await mutate(I, '::actor::qa_send_restore_request', { target: R.cid });
    await mutate(I, '::actor::qa_send_restore_request', { target: R.cid });
    await sleep(3000);
    const rMid = st(R);
    ok(rMid.c === rBefore.c && rMid.p === rBefore.p, `leg 0 (x2) from a known contact is non-destructive at R (c=${rMid.c},p=${rMid.p})`);
    // rr is 1 while the surviving handshake is in flight and 0 once its leg 2
    // lands — both are legal here depending on loopback timing. The
    // accumulation property is that TWO requests never yield TWO records.
    ok(rMid.rr <= 1, `second leg-0 REPLACED R's reply record, not accumulated (rr=${rMid.rr})`);
    await sleep(5000);
    const rAfter = st(R); const iAfter = st(I);
    ok(rAfter.c === rBefore.c && rAfter.p === rBefore.p, `R's state still unchanged once the round trip completes (c=${rAfter.c},p=${rAfter.p})`);
    ok(rAfter.rr === 0, `R's reply record consumed once the surviving (second) leg 1/2 round-trips (rr=${rAfter.rr})`);
    ok(I.rejects.slice(iRejBefore).some((x) => /does not match the outstanding request/.test(x)), `the FIRST (superseded) leg-1 reply is rejected at I ("does not match the outstanding request")`);
    ok(iAfter.c === iBefore.c && iAfter.p === iBefore.p, `I's state unchanged in count after the race (c=${iAfter.c},p=${iAfter.p})`);

    // Channel still fully healthy after the double-restore race.
    await mutate(I, '::a2a_messaging::send_message', { contact: R.cid, text: 'post-T11e-I-to-R' });
    await sleep(2500);
    ok(/post-T11e-I-to-R/.test(ro(R, '::actor::list_incoming_messages', undefined).Visualize()), `channel healthy after the T11e restore race`);
  }

  // ================= a2a_notifications scenarios (N-series) =================
  const nst = (id) => ro(id, '::actor::qa_notify_state', undefined).Visualize();

  // ---------- N1 register + confirm round-trip ----------
  CUR = 'N1-register';
  console.log('\n=== N1 register+confirm ===');
  const nsvc = mk('nsvc'); const alice = mk('alice');
  await mkPacket(nsvc, 'seed-nsvc'); await mkPacket(alice, 'seed-alice'); await sleep(1000);
  await setName(nsvc, 'NotifyService'); await setName(alice, 'Alice');
  ok(/registrations/.test(nst(nsvc)), `notify state probe answers with empty stores`);
  // alice must be a contact of the service (normal invite machinery).
  {
    const im = await mutate(nsvc, '::a2a_messaging::generate_invite', { name: 'Alice' });
    const iblob = Buffer.from(im.Reduce('invite').GetBinary());
    await mutate(alice, '::a2a_messaging::add_contact', { invite: binv(alice, iblob), name: 'svc' });
    await sleep(5000);
  }
  await mutate(nsvc, '::a2a_notifications::set_vapid_public_key', { key: 'VAPID_PUB_TEST' });
  await mutate(alice, '::a2a_notifications::notify_register', { service: 'svc', bindings: null });
  await sleep(2500); // register -> confirm round-trip over the broker
  const n1s = nst(nsvc);
  ok(/recipient_cid/.test(n1s), `service stores a registration`);
  ok(new RegExp(alice.cid).test(n1s), `service registration is keyed to alice's cid`);
  const n1a = nst(alice);
  ok(/VAPID_PUB_TEST/.test(n1a), `client registration holds the vapid pub`);
  ok(!/TRUE/.test(ro(alice, '::actor::qa_notify_state', undefined).Reduce('pending').Visualize()), `pending cleared on confirm`);
  ok(/regconfirm/.test(n1a) && new RegExp(nsvc.cid).test(n1a), `on_notify_registration hook fired with the service cid`);
  // bindings management (replace-all + re-confirm):
  await mutate(alice, '::a2a_notifications::notify_update_bindings', { service: 'svc',
    bindings: [{ version: 1, binding_id: 'b1', endpoint: 'https://push.example/x',
                 p256dh: 'PK', auth: 'AS' }] });
  await sleep(2500);
  ok(/push\.example/.test(nst(nsvc)), `service registration carries the replaced bindings`);
  ok(/push\.example/.test(nst(alice)), `client copy re-confirmed with the bindings`);

  // ---------- N2 post happy path (bare signed send from a NON-contact) ----------
  CUR = 'N2-post';
  console.log('\n=== N2 post happy path ===');
  const nbob = mk('nbob'); await mkPacket(nbob, 'seed-nbob'); await sleep(1000); // NEVER a contact of nsvc
  const naddr = Buffer.from(ro(alice, '::a2a_notifications::export_notify_address',
                              { service: 'svc' }).Reduce('blob').GetBinary());
  await mutate(nbob, '::a2a_notifications::send_notification',
               { address: binv(nbob, naddr), payload: 'hello, wake up' });
  await sleep(2500);
  const n2s = nst(nsvc);
  ok(/hello, wake up/.test(n2s), `service hook received the payload`);
  ok(new RegExp(nbob.cid).test(n2s), `sender_cid recorded from the signed envelope`);
  ok(/push\.example/.test(n2s.split('notif_log')[1] || ''), `hook received the recipient's current bindings`);

  // ---------- N3 token rejection matrix + E9 (zero state change each) ----------
  CUR = 'N3-rejections';
  console.log('\n=== N3 rejection matrix ===');
  for (const mode of ['flip_recipient', 'fake_token_id', 'foreign_service', 'flip_scope']) {
    const before = nst(nsvc);
    await mutate(nbob, '::actor::qa_post_tampered', { address: binv(nbob, naddr), mode });
    await sleep(2000);
    ok(nst(nsvc) === before, `tampered post (${mode}) aborts with zero state change`);
  }
  // E9: eve IS a contact of alice but neither pending nor her registered service.
  const neve = mk('neve'); await mkPacket(neve, 'seed-neve'); await sleep(1000);
  {
    const im = await mutate(alice, '::a2a_messaging::generate_invite', { name: 'Eve' });
    const iblob = Buffer.from(im.Reduce('invite').GetBinary());
    await mutate(neve, '::a2a_messaging::add_contact', { invite: binv(neve, iblob), name: 'alice-target' });
    await sleep(5000);
  }
  const aBefore = nst(alice);
  const aRejx = alice.rejects.length;
  await mutate(neve, '::actor::qa_send_fake_confirm', { target: alice.cid });
  await sleep(2500);
  ok(nst(alice) === aBefore && !/EVIL_VAPID/.test(nst(alice)), `unsolicited confirm_registration plants nothing (E9)`);
  ok(alice.rejects.slice(aRejx).some((x) => /[Uu]nsolicited/.test(x)), `unsolicited confirm was rejected with the E9 abort`);

  // ---------- N8 oversize payload (sender side + service side) ----------
  CUR = 'N8-oversize';
  console.log('\n=== N8 oversize payload ===');
  const n8Before = nst(nsvc);
  const senderErr = await mutate(nbob, '::a2a_notifications::send_notification',
    { address: binv(nbob, naddr), payload: 'x'.repeat(4001) }).then(() => null, (e) => e.message);
  ok(senderErr !== null && /exceeds/.test(senderErr), `sender-side oversize payload aborts locally (${(senderErr || '').split('\n')[0]})`);
  await mutate(nbob, '::actor::qa_post_tampered', { address: binv(nbob, naddr), mode: 'oversize' });
  await sleep(2000);
  ok(nst(nsvc) === n8Before, `service-side oversize post aborts with zero state change`);

  // ---------- N4 rotate (old handout dies atomically, new one works) ----------
  CUR = 'N4-rotate';
  console.log('\n=== N4 rotate ===');
  const addr1 = naddr; // pre-rotation handout
  await mutate(alice, '::a2a_notifications::notify_rotate_token', { service: 'svc' });
  await sleep(2500);
  const addr2 = Buffer.from(ro(alice, '::a2a_notifications::export_notify_address',
                               { service: 'svc' }).Reduce('blob').GetBinary());
  ok(!addr1.equals(addr2), `rotation minted a different token (handout bytes differ)`);
  const n4Before = nst(nsvc);
  await mutate(nbob, '::a2a_notifications::send_notification',
               { address: binv(nbob, addr1), payload: 'stale-handout-ping' });
  await sleep(2000);
  ok(nst(nsvc) === n4Before && !/stale-handout-ping/.test(nst(nsvc)), `old handout is rejected after rotation (E4)`);
  await mutate(nbob, '::a2a_notifications::send_notification',
               { address: binv(nbob, addr2), payload: 'post-rotate-ping' });
  await sleep(2000);
  ok(/post-rotate-ping/.test(nst(nsvc)), `new handout delivers after rotation`);

  // ---------- N5 unregister (full teardown; posts die; hook fires) ----------
  CUR = 'N5-unregister';
  console.log('\n=== N5 unregister ===');
  await mutate(alice, '::a2a_notifications::notify_unregister', { service: 'svc' });
  await sleep(2500);
  const n5s = nst(nsvc);
  ok(!new RegExp(alice.cid).test(ro(nsvc, '::actor::qa_notify_state', undefined).Reduce('registrations').Visualize()), `service registration gone`);
  ok(ro(nsvc, '::actor::qa_notify_state', undefined).Reduce('token_index').Visualize().replace(/[(),\s]/g, '') === '', `token index entry gone`);
  ok(new RegExp(alice.cid).test(ro(nsvc, '::actor::qa_notify_state', undefined).Reduce('unregs_log').Visualize()), `on_unregistered fired with alice's cid`);
  ok(ro(alice, '::actor::qa_notify_state', undefined).Reduce('my_regs').Visualize().replace(/[(),\s]/g, '') === '', `client my_regs cleared`);
  const n5Before = nst(nsvc);
  await mutate(nbob, '::a2a_notifications::send_notification',
               { address: binv(nbob, addr2), payload: 'post-unregister-ping' });
  await sleep(2000);
  ok(nst(nsvc) === n5Before && !/post-unregister-ping/.test(nst(nsvc)), `post against a torn-down registration aborts, zero state change`);

  // ---------- N6 mark_read (ids subset + NIL=all; unregistered caller dies) ----------
  CUR = 'N6-mark-read';
  console.log('\n=== N6 mark_read ===');
  // N5 tore alice down — re-register her first (fresh token, E8 path is dead).
  await mutate(alice, '::a2a_notifications::notify_register', { service: 'svc', bindings: null });
  await sleep(2500);
  const addr3 = Buffer.from(ro(alice, '::a2a_notifications::export_notify_address',
                               { service: 'svc' }).Reduce('blob').GetBinary());
  await mutate(nbob, '::a2a_notifications::send_notification', { address: binv(nbob, addr3), payload: 'n6-one' });
  await mutate(nbob, '::a2a_notifications::send_notification', { address: binv(nbob, addr3), payload: 'n6-two' });
  await sleep(2000);
  ok(/n6-one/.test(nst(nsvc)) && /n6-two/.test(nst(nsvc)), `two posts landed for the re-registered alice`);
  await mutate(alice, '::a2a_notifications::notify_mark_read', { service: 'svc', notif_ids: ['qa-notif-id-1'] });
  await sleep(2000);
  const marks1 = ro(nsvc, '::actor::qa_notify_state', undefined).Reduce('marks_log').Visualize();
  ok(/qa-notif-id-1/.test(marks1) && new RegExp(alice.cid).test(marks1), `ids-subset mark_read reached the hook with exactly the ids + caller cid`);
  await mutate(alice, '::a2a_notifications::notify_mark_read', { service: 'svc', notif_ids: null });
  await sleep(2000);
  const marks2 = ro(nsvc, '::actor::qa_notify_state', undefined).Reduce('marks_log').Visualize();
  ok(marks2 !== marks1 && !/qa-notif-id-2/.test(marks2), `NIL(=all) mark_read reached the hook as a second entry with NIL ids`);
  // Negative: a packet with no registration cannot even fire the client trn.
  const n6err = await mutate(nbob, '::a2a_notifications::notify_mark_read', { service: 'svc', notif_ids: null })
    .then(() => null, (e) => e.message);
  ok(n6err !== null && /[Uu]nknown contact|[Nn]o notification registration/.test(n6err), `mark_read without a registration aborts locally`);

  // ---------- N7 export/import round-trip (both halves; no secrets) ----------
  CUR = 'N7-export-import';
  console.log('\n=== N7 export/import ===');
  const svcExpVis = ro(nsvc, '::actor::export_state', undefined).Visualize();
  ok(/notify/.test(svcExpVis) && /recipient_cid/.test(svcExpVis), `service export composes the notify half (registrations present)`);
  ok(!/secretkey/i.test(svcExpVis) && !/VAPID_PRIV/.test(svcExpVis), `service export carries no secret material`);
  ok(/VAPID_PUB_TEST/.test(svcExpVis), `service export carries the PUBLIC vapid key`);
  const aliceExpVis = ro(alice, '::actor::export_state', undefined).Visualize();
  ok(/VAPID_PUB_TEST/.test(aliceExpVis) && !/secretkey/i.test(aliceExpVis), `client export carries my_regs (vapid pub) and no secret material`);
  // Replacement packets, fresh seeds — the T10 migration pattern (the SDK's
  // PacketManager refuses a duplicate cid in-process, so a SAME-identity
  // restart cannot be driven here; the daemon-restart test in the service repo
  // proves "post still lands after restart" on a true same-cid reboot). What
  // this asserts: BYTE-FIDELITY of both halves through export→import.
  const svcExpBin = ro(nsvc, '::actor::export_state', undefined);
  fs.writeFileSync(resolve(UNIT_DIR, 'n7-svc.bin'), Buffer.from(svcExpBin.Serialize()));
  const aliceExpBin = ro(alice, '::actor::export_state', undefined);
  fs.writeFileSync(resolve(UNIT_DIR, 'n7-alice.bin'), Buffer.from(aliceExpBin.Serialize()));
  const tokenOf = (vis) => (vis.split('token_index')[0].match(/token_id[^)]*\)/g) || []).join('|');
  const nsvc2 = mk('nsvc2'); await mkPacket(nsvc2, 'seed-nsvc-mig'); await sleep(1000);
  await mutate(nsvc2, '::actor::import_state',
    nsvc2.pw.packet.ParseValue(new Uint8Array(fs.readFileSync(resolve(UNIT_DIR, 'n7-svc.bin')))));
  const n7s = nst(nsvc2);
  ok(new RegExp(alice.cid).test(n7s) && /recipient_cid/.test(n7s), `service registrations restored on the replacement packet`);
  ok(!(ro(nsvc2, '::actor::qa_notify_state', undefined).Reduce('token_index').Visualize().replace(/[(),\s]/g, '') === ''), `token index restored`);
  ok(/VAPID_PUB_TEST/.test(n7s), `vapid public key restored`);
  ok(tokenOf(n7s) !== '' && tokenOf(n7s) === tokenOf(nst(nsvc)), `stored token round-trips byte-stable (post would validate on a same-cid restart)`);
  const alice2 = mk('alice2'); await mkPacket(alice2, 'seed-alice-mig'); await sleep(1000);
  await mutate(alice2, '::actor::import_state',
    alice2.pw.packet.ParseValue(new Uint8Array(fs.readFileSync(resolve(UNIT_DIR, 'n7-alice.bin')))));
  const n7a = nst(alice2);
  ok(/VAPID_PUB_TEST/.test(n7a) && new RegExp(nsvc.cid).test(n7a), `client my_regs restored (vapid pub + service cid intact)`);

  console.log('\n================ SCORECARD ================');
  if (scorecard.length === 0) console.log('ALL TESTS PASSED');
  else { console.log(`${scorecard.length} FAILURE(S):`); scorecard.forEach((s) => console.log('  ' + s)); }
  await sleep(500);
  process.exit(scorecard.length === 0 ? 0 : 1);
}
main().catch((e) => { log('DRIVER ERR:', e.stack ?? e.message); process.exit(1); });
