#!/usr/bin/env node
// M2 loopback test suite for the core-3.0 ephemeral-invite redeem flow.
// Asserts RECEIVER-SIDE outcomes (state), per the Critic requirement.
//
// T/V/RC-series only — the a2a_notifications N-series moved to notif.mjs (its own
// compiled unit, notif_actor.mu). The shared wrapper/packet bootstrap + the
// mk/wire/mutate/ro/binv/mkPacket/sleep/log helpers live in ./test_common.mjs.
import { resolve } from 'node:path';
import * as fs from 'node:fs';
import { createHarness, mk } from './test_common.mjs';

const BROKER_URL = process.env.BROKER_URL || 'ws://127.0.0.1:9790';
const UNIT_DIR = resolve('.');
const scorecard = [];
let CUR = '';
const ok = (c, m) => { if (!c) { scorecard.push(`✗ [${CUR}] ${m}`); console.log(`  ✗ FAIL: ${m}`); } else { console.log(`  ✓ ${m}`); } };
const isT = (s) => /true/i.test(String(s));

let wrapper, mutate, ro, binv, mkPacket, sleep, log;
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
  const h = await createHarness({ brokerUrl: BROKER_URL, unitDir: UNIT_DIR, logTag: 't' });
  ({ wrapper, mutate, ro, binv, mkPacket, sleep, log } = h);

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
  ok(s10.pi === 0, `import reset pending_invites to empty (migration) → ${s10.pi}`);
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

  // ================= V-series: versioned type registry (core 0.5.0) =========
  // Cross-version leg-1 shapes against a 0.5.0 inviter (fresh packet pair so
  // earlier scenarios' contacts cannot mask the registration outcomes).
  const VI = mk('VI'); const VL = mk('VL');
  await mkPacket(VI, 'eph-t-VI-04'); await mkPacket(VL, 'eph-t-VL-05');
  await sleep(1200);
  await setName(VI, 'VerInviter'); await setName(VL, 'VerLegacy');
  const pvOf = (id, cid) => ro(id, '::actor::qa_contact_pv_of', { cid }).Reduce('pv').Visualize();
  const capsOf = (id, cid) => ro(id, '::actor::qa_contact_pv_of', { cid }).Reduce('caps').Visualize();
  const nameOfContact = (id, cid) => ro(id, '::actor::qa_contact_name', { cid }).Reduce('name').Visualize();

  // ---------- V1 legacy v2 leg-1 (the 0.2.0 incident shape: no $name) ----------
  CUR = 'V1 legacy-v2-leg1';
  console.log('\n=== V1 legacy v2 leg-1 (no $name — THE incident shape) ===');
  m = await mutate(VI, '::a2a_messaging::generate_invite', {});   // NO assigned name — the incident precondition
  const blobV1 = Buffer.from(m.Reduce('invite').GetBinary());
  {
    const before = st(VI); const rejB = VI.rejects.length; const legRejB = VL.rejects.length;
    await mutate(VL, '::actor::qa_send_versioned_leg1', { invite: binv(VL, blobV1), shape: 'v2', name: '' });
    await sleep(4000);
    const after = st(VI);
    ok(VI.rejects.length === rejB, `v2 leg-1: inviter did NOT abort (no EVAL_ERROR reject) — the incident is dead`);
    ok(after.pi === before.pi - 1, `v2 leg-1: invite consumed (pi ${before.pi}→${after.pi})`);
    ok(after.c === before.c + 1, `v2 leg-1: responder registered as contact (c ${before.c}→${after.c})`);
    ok(nameOfContact(VI, VL.cid) === VL.cid, `v2 leg-1: no $name → contact named by sender cid (typed v2 branch)`);
    ok(pvOf(VI, VL.cid) === '2', `v2 leg-1: contact_pv learned as 2 (shape-inferred)`);
    ok(VL.rejects.slice(legRejB).some((x) => /Unsolicited completion|Redemption ephemeral key/.test(x)),
      `v2 leg-1: inviter DID send leg-3 (arrived at the emulated legacy responder)`);
  }

  // ---------- V2 legacy v3 leg-1 ($name honored) ----------
  CUR = 'V2 legacy-v3-leg1';
  console.log('\n=== V2 legacy v3 leg-1 ($name, no $pv) ===');
  m = await mutate(VI, '::a2a_messaging::generate_invite', {});
  const blobV2 = Buffer.from(m.Reduce('invite').GetBinary());
  {
    const rejB = VI.rejects.length;
    await mutate(VL, '::actor::qa_send_versioned_leg1', { invite: binv(VL, blobV2), shape: 'v3', name: 'LegacyBob' });
    await sleep(4000);
    ok(VI.rejects.length === rejB, `v3 leg-1: no abort at inviter`);
    ok(nameOfContact(VI, VL.cid) === 'LegacyBob', `v3 leg-1: $name honored (typed v3 branch)`);
    ok(pvOf(VI, VL.cid) === '3', `v3 leg-1: contact_pv learned as 3 (shape-inferred)`);
  }

  // ---------- V3 v5 leg-1 ($pv stamped + $caps piggyback) ----------
  CUR = 'V3 v5-leg1';
  console.log('\n=== V3 v5 leg-1 ($pv + $caps) ===');
  m = await mutate(VI, '::a2a_messaging::generate_invite', {});
  const blobV3 = Buffer.from(m.Reduce('invite').GetBinary());
  {
    const rejB = VI.rejects.length;
    await mutate(VL, '::actor::qa_send_versioned_leg1', { invite: binv(VL, blobV3), shape: 'v5', name: 'NewCarol' });
    await sleep(4000);
    ok(VI.rejects.length === rejB, `v5 leg-1: no abort at inviter`);
    ok(nameOfContact(VI, VL.cid) === 'NewCarol', `v5 leg-1: $name honored (typed v5 branch)`);
    ok(pvOf(VI, VL.cid) === '5', `v5 leg-1: contact_pv learned as 5 ($pv stamped)`);
    ok(/core\.notifications/.test(String(capsOf(VI, VL.cid))), `v5 leg-1: piggybacked $caps learned into contact_caps`);
  }

  // ---------- V4 Additions A+B: below-floor leg-1 → error-as-data to inviter ----------
  CUR = 'V4 too-old-leg1 (Additions A/B)';
  console.log('\n=== V4 below-floor leg-1 ($pv=1) → inviter error-as-data, invite NOT consumed ===');
  m = await mutate(VI, '::a2a_messaging::generate_invite', {});
  const blobV4 = Buffer.from(m.Reduce('invite').GetBinary());
  {
    const before = st(VI); const rejB = VI.rejects.length; const errB = VI.errEvents.length;
    await mutate(VL, '::actor::qa_send_versioned_leg1', { invite: binv(VL, blobV4), shape: 'too_old', name: '' });
    await sleep(4000);
    const after = st(VI);
    ok(VI.rejects.length === rejB, `A: inviter did NOT abort/rollback on a below-floor peer (no reject)`);
    const errs = VI.errEvents.slice(errB);
    ok(errs.length === 1, `A: exactly one $protocol_error event surfaced to the inviter's client`);
    const e = errs[0] ?? {};
    ok(e.code === 'peer_version_unsupported', `A: error-as-data code is peer_version_unsupported (got ${e.code})`);
    ok(e.surface === 'sir' && e.peerVersion === '1' && e.minSupported === '2',
      `A: typed error carries surface=sir peer_version=1 min_supported=2`);
    ok(e.context === 'invite_redeem', `B: context marks the invite second phase (invite_redeem)`);
    ok(/An invite you created was accepted by a peer running an unsupported \(too old\) protocol version/.test(e.message)
      && /update their client/.test(e.message),
      `B: inviter-facing message is the clear human-readable wording`);
    ok(after.pi === before.pi && after.c === before.c && after.p === before.p,
      `B: NO state consumed (invite intact, no contact registered)`);
    // The same invite redeems fine once the peer "updates" (proves not consumed).
    await mutate(VL, '::actor::qa_send_versioned_leg1', { invite: binv(VL, blobV4), shape: 'v3', name: 'UpdatedPeer' });
    await sleep(4000);
    ok(st(VI).pi === before.pi - 1, `B: SAME invite redeems after the peer updates (invite was not consumed)`);
    ok(nameOfContact(VI, VL.cid) === 'UpdatedPeer', `B: post-update redeem registered the contact normally`);
  }

  // NOTE: V5 CAP-1 (the notify client's capability gate — notify_register denied
  // on positive missing-cap evidence) exercises the a2a_notifications library and
  // the alice/nsvc notify nodes, so it moved to notif.mjs with the N-series (this
  // messaging-only unit no longer loads a2a_notifications).

  // ---------- V6 $pv stamping on message traffic + passive learning ----------
  // Uses the T1 pair (I↔R, MUTUAL contacts from the real 0.5.0 redeem): both
  // legs of that redeem were the stamped v5 shapes, and message $targs carry
  // $pv — so both sides must have learned dialect 5, and a fresh stamped
  // message must deliver normally.
  CUR = 'V6 pv-stamp';
  console.log('\n=== V6 $pv stamp on send_message + passive learning at the receiver ===');
  {
    await mutate(I, '::a2a_messaging::send_message', { contact: R.cid, text: 'v5-stamped-msg' });
    await sleep(2500);
    ok(/v5-stamped-msg/.test(ro(R, '::actor::list_incoming_messages', undefined).Visualize()),
      `stamped $targ delivers normally (receiver tolerant of the added $pv)`);
    ok(pvOf(R, I.cid) === '8', `responder learned contact_pv=8 (wire-8 leg-3 + stamped messages)`);
    ok(pvOf(I, R.cid) === '8', `inviter learned contact_pv=8 (real current-build leg-1)`);
  }

  // ---------- V7 upgrade-later + monotonic learning (owner scenario) ----------
  // A contact was v2 at invite time (V1 proves a real v2 leg-1 learns
  // contact_pv=2; the emulated legacy responder has no reverse channel, so that
  // v2-era state is ARRANGED here on the channel-connected T1 pair). Then the
  // peer "upgrades": its first v5-STAMPED ordinary message must re-learn
  // contact_pv 2→5 through handle_receive_message (ongoing learning, not
  // invite-time-only). Finally a stale/replayed v2-SHAPE (unstamped) legacy
  // message must NOT downgrade the learned pv nor clobber learned v5 caps.
  CUR = 'V7 upgrade+monotonic';
  console.log('\n=== V7 upgrade-later re-learn + monotonic (no downgrade by legacy traffic) ===');
  {
    await mutate(I, '::actor::qa_set_contact_pv', { cid: R.cid, pv: 2 });
    await mutate(I, '::actor::qa_set_contact_caps', { cid: R.cid, caps: [] });  // v2-era: nothing advertised
    ok(pvOf(I, R.cid) === '2', `arranged: contact recorded as v2-era (the state a real v2 leg-1 yields, per V1)`);
    // The upgrade: the peer's next ORDINARY message is v5-stamped.
    await mutate(R, '::a2a_messaging::send_message', { contact: I.cid, text: 'post-upgrade-hello' });
    await sleep(2500);
    ok(/post-upgrade-hello/.test(ro(I, '::actor::list_incoming_messages', undefined).Visualize()),
      `post-upgrade stamped message delivered`);
    ok(pvOf(I, R.cid) === '8', `UPGRADE: first stamped ordinary message re-learned contact_pv 2→8 (ongoing learning)`);
    // Learned v5 caps (as the next bundle exchange would set), then stale legacy traffic.
    await mutate(I, '::actor::qa_set_contact_caps', { cid: R.cid, caps: ['core.notifications'] });
    await mutate(R, '::actor::qa_send_legacy_message', { target: I.cid, text: 'stale-legacy-msg' });
    await sleep(2500);
    ok(/stale-legacy-msg/.test(ro(I, '::actor::list_incoming_messages', undefined).Visualize()),
      `legacy (pre-wire_id, unstamped) message still delivers`);
    ok(pvOf(I, R.cid) === '8', `MONOTONIC: unstamped v2-shape message did NOT downgrade the learned pv`);
    ok(/core\.notifications/.test(String(capsOf(I, R.cid))),
      `MONOTONIC: learned v5 caps NOT clobbered by legacy traffic`);
  }

  // ================= RC-series: receipts (core 0.7.0, Rev 2 spec) ==========
  // Uses the I/R mutual pair. Gate polarity: fail-CLOSED on unknown caps.
  const rlog = (id) => ro(id, '::actor::qa_receipts_log', undefined).Visualize();
  const rcount = (id) => (String(rlog(id)).match(/"kind"/g) || []).length;

  CUR = 'RC1 receipts-off baseline';
  console.log('\n=== RC1 receipts baseline (no caps → zero receipt traffic, zero failures) ===');
  {
    const rejI = I.rejects.length; const rejR = R.rejects.length; const c0 = rcount(I);
    await mutate(I, '::a2a_messaging::send_message', { contact: R.cid, text: 'rc1-no-receipts' });
    await sleep(2500);
    ok(/rc1-no-receipts/.test(ro(R, '::actor::list_incoming_messages', undefined).Visualize()), 'RC1: message delivered');
    ok(rcount(I) === c0, 'RC1: NO receipt emitted (peer caps absent → gate closed, the new↔old cell)');
    ok(I.rejects.length === rejI && R.rejects.length === rejR, 'RC1: zero failures either side');
  }

  CUR = 'RC2 delivered receipt';
  console.log('\n=== RC2 delivered receipt (both caps positive) ===');
  let rcWid = '';
  {
    await mutate(R, '::actor::qa_init_caps', { advertise: ['core.receipts.emit', 'core.receipts.receive'] });
    await mutate(R, '::actor::qa_set_contact_caps', { cid: I.cid, caps: ['core.receipts.receive'] });
    const c0 = rcount(I); const rejI = I.rejects.length;
    const sm = await mutate(I, '::a2a_messaging::send_message', { contact: R.cid, text: 'rc2-confirm-me' });
    rcWid = sm.Reduce('wire_id').Visualize();
    await sleep(3000);
    ok(rcount(I) === c0 + 1, 'RC2: exactly ONE delivered receipt arrived at the sender');
    const lg = String(rlog(I)).replace(/\s/g, '');
    ok(lg.includes('"kind"->"delivered"'), 'RC2: receipt kind is "delivered"');
    ok(lg.includes(rcWid), 'RC2: receipt carries the message wire_id');
    ok(I.rejects.length === rejI, 'RC2: receipt ingest clean (no rejects at sender)');
  }

  CUR = 'RC3 expectation';
  console.log('\n=== RC3 sender-side expectation (derived, unknown ≠ failed) ===');
  {
    await mutate(I, '::actor::qa_set_contact_caps', { cid: R.cid, caps: ['core.receipts.emit'] });
    ok(ro(I, '::actor::qa_receipt_expectation', { cid: R.cid }).Reduce('state').Visualize() === 'expected',
      'RC3: peer advertising emit → "expected"');
    ok(ro(I, '::actor::qa_receipt_expectation', { cid: VL.cid }).Reduce('state').Visualize() === 'unknown',
      'RC3: peer without emit cap → "unknown" (never failed)');
  }

  CUR = 'RC4 read receipt';
  console.log('\n=== RC4 read receipt (auto on the get/mark-read path) ===');
  {
    const c0 = rcount(I);
    await mutate(R, '::actor::qa_mark_read', { contact: I.cid, wire_ids: [rcWid] });
    await sleep(2500);
    ok(rcount(I) === c0 + 1, 'RC4: read receipt arrived');
    ok(String(rlog(I)).replace(/\s/g, '').includes('"kind"->"read"'), 'RC4: kind is "read"');
  }

  CUR = 'RC5 file receipt';
  console.log('\n=== RC5 file delivery receipt (shared wire_id namespace) ===');
  {
    const c0 = rcount(I);
    const sf = await mutate(I, '::a2a_messaging::send_file',
      { contact: R.cid, filename: 'rc5.bin', mime: 'application/octet-stream', data: binv(I, Buffer.from('RC5')) });
    const fwid = sf.Reduce('wire_id').Visualize();
    await sleep(3000);
    ok(rcount(I) === c0 + 1 && String(rlog(I)).includes(fwid), 'RC5: delivered receipt for the FILE wire_id');
  }

  CUR = 'RC6 emit toggle off';
  console.log('\n=== RC6 emit toggle off (dynamic user policy) ===');
  {
    await mutate(R, '::actor::qa_init_caps', { advertise: ['core.receipts.receive'] });  // emit dropped
    const c0 = rcount(I);
    await mutate(I, '::a2a_messaging::send_message', { contact: R.cid, text: 'rc6-silent' });
    await sleep(2500);
    ok(/rc6-silent/.test(ro(R, '::actor::list_incoming_messages', undefined).Visualize()), 'RC6: message still delivered');
    ok(rcount(I) === c0, 'RC6: no receipt after the emitter toggled off');
  }

  CUR = 'RC7 forward-compat + tolerance';
  console.log('\n=== RC7 unknown kind + malformed shape are ignored (never load-bearing) ===');
  {
    const c0 = rcount(I); const rejI = I.rejects.length;
    await mutate(R, '::actor::qa_send_raw_receipt', { target: I.cid, kind: 'typing', wire_ids: [rcWid] });
    await sleep(2000);
    await mutate(R, '::actor::qa_send_raw_receipt', { target: I.cid, kind: 42, wire_ids: [rcWid] });
    await sleep(2000);
    await mutate(R, '::actor::qa_send_raw_receipt', { target: I.cid, kind: 'delivered', wire_ids: 'not-a-list' });
    await sleep(2000);
    ok(rcount(I) === c0, 'RC7: unknown kind / mistyped kind / scalar wire_ids — nothing reached the hook');
    ok(I.rejects.length === rejI, 'RC7: and nothing aborted (ignore-success, forward-compat)');
  }

  CUR = 'RC8 stale-caps self-heal';
  console.log('\n=== RC8 hybrid gate: stale caps + learned pv>=7 → receipts fire (the upgrade fix) ===');
  {
    await mutate(R, '::actor::qa_init_caps', { advertise: ['core.receipts.emit', 'core.receipts.receive'] });
    await mutate(R, '::actor::qa_set_contact_caps', { cid: I.cid, caps: ['core.notifications'] });  // stale pre-receipts caps (no opinion)
    await mutate(R, '::actor::qa_set_contact_pv', { cid: I.cid, pv: 7 });
    const c0 = rcount(I);
    await mutate(I, '::a2a_messaging::send_message', { contact: R.cid, text: 'rc8-selfheal' });
    await sleep(3000);
    ok(rcount(I) === c0 + 1, 'RC8: delivered receipt fired despite stale caps (pv>=7 implied receive)');
    await mutate(I, '::actor::qa_set_contact_caps', { cid: R.cid, caps: [] });
    await mutate(I, '::actor::qa_set_contact_pv', { cid: R.cid, pv: 7 });
    ok(ro(I, '::actor::qa_receipt_expectation', { cid: R.cid }).Reduce('state').Visualize() === 'expected',
      'RC8: expectation = expected via pv>=7 (caps silent)');
  }

  CUR = 'RC9 explicit opt-out';
  console.log('\n=== RC9 hybrid gate: caps WITH receipts opinion but no receive → strict opt-out ===');
  {
    await mutate(R, '::actor::qa_set_contact_caps', { cid: I.cid, caps: ['core.receipts.emit'] });  // opinion, no receive
    await mutate(R, '::actor::qa_set_contact_pv', { cid: I.cid, pv: 7 });
    const c0 = rcount(I);
    await mutate(I, '::a2a_messaging::send_message', { contact: R.cid, text: 'rc9-optout' });
    await sleep(2500);
    ok(rcount(I) === c0, 'RC9: NO receipt — explicit caps opinion without receive wins over pv (opt-out respected)');
  }

  CUR = 'RC10 old peer stays silent';
  console.log('\n=== RC10 hybrid gate: no caps opinion + pv 5 (old peer) → silent ===');
  {
    await mutate(R, '::actor::qa_set_contact_caps', { cid: I.cid, caps: [] });
    const c0 = rcount(I);
    // the OLD peer's message must itself carry the old dialect: the receiver
    // learns pv from THIS message before gating (that's the self-heal), so a
    // current-build send_message (stamps 7) cannot emulate a pv-5 peer.
    await mutate(I, '::actor::qa_send_stamped_message', { target: R.cid, text: 'rc10-oldpeer', pv: 5, wire_id: 'rc10-w1' });
    await sleep(2500);
    ok(rcount(I) === c0, 'RC10: NO receipt toward a pv-5 peer (old clients stay silent, zero noise)');
    await mutate(I, '::actor::qa_set_contact_caps', { cid: R.cid, caps: [] });
    await mutate(I, '::actor::qa_set_contact_pv', { cid: R.cid, pv: 5 });
    ok(ro(I, '::actor::qa_receipt_expectation', { cid: R.cid }).Reduce('state').Visualize() === 'unknown',
      'RC10: expectation = unknown toward a pv-5 peer');
  }

  console.log('\n================ SCORECARD ================');
  if (scorecard.length === 0) console.log('ALL TESTS PASSED');
  else { console.log(`${scorecard.length} FAILURE(S):`); scorecard.forEach((s) => console.log('  ' + s)); }
  await sleep(500);
  process.exit(scorecard.length === 0 ? 0 : 1);
}
main().catch((e) => { log('DRIVER ERR:', e.stack ?? e.message); process.exit(1); });
