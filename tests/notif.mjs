#!/usr/bin/env node
// a2a_notifications N-series loopback suite (+ the V5 CAP-1 notify-client gate).
//
// SPLIT from test.mjs: the notification tests run against their OWN compiled unit
// (notif_actor.mu, which loads BOTH a2a_messaging AND a2a_notifications) because
// test_actor.mu had to drop a2a_notifications to stay under the per-unit
// meta-reduction fuel ceiling (see notif_actor.mu header). The shared wrapper /
// packet bootstrap + mk/wire/mutate/ro/binv/mkPacket/sleep/log helpers live in
// ./test_common.mjs (imported here and by test.mjs — one copy).
//
// This unit is the ONLY one that loads both libraries, so the COMBINED core+notify
// export/import round-trip (N7/N16 — "both halves coexist in one blob and both
// restore") lives here.
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

async function main() {
  const h = await createHarness({ brokerUrl: BROKER_URL, unitDir: UNIT_DIR, logTag: 'n' });
  ({ wrapper, mutate, ro, binv, mkPacket, sleep, log } = h);
  const setName = (id, n) => mutate(id, '::a2a_messaging::set_my_name', { name: n });

  // ================= a2a_notifications scenarios (N-series) =================
  const nst = (id) => ro(id, '::actor::qa_notify_state', undefined).Visualize();
  const nst2 = (id) => ro(id, '::actor::qa_notify_state_v2', undefined).Visualize();

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
  // Per-contact-only model: registration mints NOTHING — no token exists until
  // issue_tokens is called.
  ok(ro(nsvc, '::actor::qa_notify_state', undefined).Reduce('token_index').Visualize().replace(/[(),\s]/g, '') === '',
    `register mints no token — notify_token_index empty after registration`);
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
  // Per-contact only: alice asks the service to mint nbob's scoped token first,
  // then exports nbob's handout from her contact-token mirror (nbob is not a
  // contact of alice, so the qa probe stands in for export_notify_address).
  await mutate(alice, '::a2a_notifications::notify_issue_tokens', { service: 'svc', contacts: [nbob.cid] });
  await sleep(2500);
  const naddr = Buffer.from(ro(alice, '::actor::qa_export_contact_notify_address',
                              { service: nsvc.cid, sender: nbob.cid }).Reduce('blob').GetBinary());
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

  // ---------- N4 rotate-all (old handout dies atomically, new one works) ----------
  CUR = 'N4-rotate';
  console.log('\n=== N4 rotate ===');
  const addr1 = naddr; // pre-rotation handout (nbob's scoped token)
  await mutate(alice, '::a2a_notifications::notify_rotate_token', { service: 'svc' });
  await sleep(2500);
  const addr2 = Buffer.from(ro(alice, '::actor::qa_export_contact_notify_address',
                               { service: nsvc.cid, sender: nbob.cid }).Reduce('blob').GetBinary());
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
  ok(ro(nsvc, '::actor::qa_notify_state', undefined).Reduce('token_index').Visualize().replace(/[(),\s]/g, '') === '', `token index entries gone (ALL scoped tokens purged on unregister)`);
  ok(ro(nsvc, '::actor::qa_notify_state_v2', undefined).Reduce('sender_tokens').Visualize().replace(/[(),\s]/g, '') === '', `scoped token slots purged on unregister`);
  ok(new RegExp(alice.cid).test(ro(nsvc, '::actor::qa_notify_state', undefined).Reduce('unregs_log').Visualize()), `on_unregistered fired with alice's cid`);
  ok(ro(alice, '::actor::qa_notify_state', undefined).Reduce('my_regs').Visualize().replace(/[(),\s]/g, '') === '', `client my_regs cleared`);
  ok(ro(alice, '::actor::qa_notify_state_v2', undefined).Reduce('contact_tokens').Visualize().replace(/[(),\s]/g, '') === '',
    `client contact-token mirror cleared on unregister (no stale-token source)`);
  const n5Before = nst(nsvc);
  await mutate(nbob, '::a2a_notifications::send_notification',
               { address: binv(nbob, addr2), payload: 'post-unregister-ping' });
  await sleep(2000);
  ok(nst(nsvc) === n5Before && !/post-unregister-ping/.test(nst(nsvc)), `post against a torn-down registration aborts, zero state change`);

  // ---------- N6 mark_read (ids subset + NIL=all; unregistered caller dies) ----------
  CUR = 'N6-mark-read';
  console.log('\n=== N6 mark_read ===');
  // N5 tore alice down (registration + all scoped tokens purged) — re-register
  // AND re-issue nbob's scoped token before posting again.
  await mutate(alice, '::a2a_notifications::notify_register', { service: 'svc', bindings: null });
  await sleep(2500);
  await mutate(alice, '::a2a_notifications::notify_issue_tokens', { service: 'svc', contacts: [nbob.cid] });
  await sleep(2500);
  const addr3 = Buffer.from(ro(alice, '::actor::qa_export_contact_notify_address',
                               { service: nsvc.cid, sender: nbob.cid }).Reduce('blob').GetBinary());
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
  const nsvc2 = mk('nsvc2'); await mkPacket(nsvc2, 'seed-nsvc-mig'); await sleep(1000);
  await mutate(nsvc2, '::actor::import_state',
    nsvc2.pw.packet.ParseValue(new Uint8Array(fs.readFileSync(resolve(UNIT_DIR, 'n7-svc.bin')))));
  const n7s = nst(nsvc2);
  ok(new RegExp(alice.cid).test(n7s) && /recipient_cid/.test(n7s), `service registrations restored on the replacement packet`);
  ok(!(ro(nsvc2, '::actor::qa_notify_state', undefined).Reduce('token_index').Visualize().replace(/[(),\s]/g, '') === ''), `token index restored`);
  ok(/VAPID_PUB_TEST/.test(n7s), `vapid public key restored`);
  // Byte-stability of the scoped token store: nbob's token_id (minted in N6)
  // must be identical on the replacement packet (post would validate on a
  // same-cid restart).
  const n7TidOrig = ro(nsvc, '::actor::qa_scoped_token_id',
    { recipient: alice.cid, sender: nbob.cid }).Reduce('token_id').Visualize();
  const n7TidRest = ro(nsvc2, '::actor::qa_scoped_token_id',
    { recipient: alice.cid, sender: nbob.cid }).Reduce('token_id').Visualize();
  ok(n7TidOrig !== '' && n7TidOrig === n7TidRest, `stored scoped token round-trips byte-stable (post would validate on a same-cid restart)`);
  const alice2 = mk('alice2'); await mkPacket(alice2, 'seed-alice-mig'); await sleep(1000);
  await mutate(alice2, '::actor::import_state',
    alice2.pw.packet.ParseValue(new Uint8Array(fs.readFileSync(resolve(UNIT_DIR, 'n7-alice.bin')))));
  const n7a = nst(alice2);
  ok(/VAPID_PUB_TEST/.test(n7a) && new RegExp(nsvc.cid).test(n7a), `client my_regs restored (vapid pub + service cid intact)`);

  // ====== N9-series: per-sender scoped tokens, issue_tokens, confirm extension ======

  // ---------- N9: pre-v2-era export — absent new fields import as empty maps ----------
  // Written FIRST per the brief: verifies that import_notify_state handles missing
  // v2 fields (keeps default empty maps) before the round-trip tests run.
  CUR = 'N9-v1era-import';
  console.log('\n=== N9 v1-era import ===');
  const v1Fresh = mk('v1fresh'); await mkPacket(v1Fresh, 'seed-v1fresh'); await sleep(1000);
  const v1Res = await mutate(v1Fresh, '::actor::qa_import_v1_notify_state',
    { vapid: 'V1_TEST_VAPID' });
  // new maps absent in the input record → kept as empty defaults.
  ok(v1Res.Reduce('sender_tokens').Visualize().replace(/[(),\s]/g, '') === '',
    `v1-era import: notify_sender_tokens stays empty (absent field keeps default)`);
  ok(v1Res.Reduce('contact_tokens').Visualize().replace(/[(),\s]/g, '') === '',
    `v1-era import: my_notify_contact_tokens stays empty (absent field keeps default)`);

  // ---------- N10 issue_tokens happy path — scoped tokens; confirm carries them ----------
  CUR = 'N10-issue-tokens';
  console.log('\n=== N10 issue_tokens happy path ===');
  // alice is registered with nsvc (re-registered in N6, state carried through N7).
  // nbob and neve are never contacts of nsvc.
  await mutate(alice, '::a2a_notifications::notify_issue_tokens',
    { service: 'svc', contacts: [nbob.cid, neve.cid] });
  await sleep(3000);
  const n10Svc = nst2(nsvc);
  const n10Alice = nst2(alice);
  // Service side: notify_sender_tokens[alice][nbob] and [neve] set.
  ok(new RegExp(nbob.cid).test(n10Svc), `service stores scoped token keyed to nbob's cid`);
  ok(new RegExp(neve.cid).test(n10Svc), `service stores scoped token keyed to neve's cid`);
  // Each token's $scope == _str(sender) (the sender's cid as a string).
  // In the visualization, the scope field's value should contain the sender cid.
  const n10NbobIdx = n10Svc.indexOf(nbob.cid);
  const n10NbobSection = n10NbobIdx >= 0 ? n10Svc.slice(n10NbobIdx, n10NbobIdx + 800) : '';
  ok(/scope/.test(n10NbobSection) && n10NbobSection.split('scope').length > 1 &&
     new RegExp(nbob.cid).test(n10NbobSection.split('scope')[1].slice(0, nbob.cid.length + 20)),
    `nbob's scoped token has $scope == _str(nbob) — i.e. scope value is nbob's cid`);
  // Token IDs appear in notify_token_index (service indexes them for revocation).
  // Stronger check: extract nbob's concrete scoped token_id from sender_tokens via
  // the probe and assert that exact id string is present in notify_token_index.
  // This FAILS if the 'notify_token_index (...) -> recipient' line in
  // handle_issue_tokens were removed — the token exists in sender_tokens but its
  // id would be absent from the index, breaking the revocation mechanism.
  const scopedTid = ro(nsvc, '::actor::qa_scoped_token_id',
      { recipient: alice.cid, sender: nbob.cid }).Reduce('token_id').Visualize();
  const tokenIndexVis = ro(nsvc, '::actor::qa_notify_state', undefined).Reduce('token_index').Visualize();
  ok(scopedTid !== '' && tokenIndexVis.includes(scopedTid),
      `scoped token_id for nbob is indexed in notify_token_index (revocation mechanism)`);
  // Client side: my_notify_contact_tokens[nsvc][nbob] and [neve] set on alice.
  ok(new RegExp(nbob.cid).test(n10Alice), `alice contact_tokens includes nbob's cid`);
  ok(new RegExp(neve.cid).test(n10Alice), `alice contact_tokens includes neve's cid`);
  // Confirm keeps carrying $vapid_pub/$bindings beside the token maps.
  ok(/VAPID_PUB_TEST/.test(nst(alice)),
    `confirm still carries $vapid_pub after issue_tokens`);

  // ---------- N11 idempotence: repeat issue_tokens for bob → token bytes unchanged ----------
  CUR = 'N11-idempotence';
  console.log('\n=== N11 idempotence ===');
  const n11Before = nst2(nsvc);
  await mutate(alice, '::a2a_notifications::notify_issue_tokens',
    { service: 'svc', contacts: [nbob.cid] });
  await sleep(3000);
  const n11After = nst2(nsvc);
  // Extract bob's token_id from before and after: they must be identical (byte-stable).
  const extractTokenLine = (vis, anchorCid) => {
    const idx = vis.indexOf(anchorCid);
    if (idx < 0) return '';
    return (vis.slice(idx, idx + 600).match(/token_id[^\n)]*\)?/) || [''])[0];
  };
  const tid11Before = extractTokenLine(n11Before, nbob.cid);
  const tid11After  = extractTokenLine(n11After,  nbob.cid);
  ok(tid11Before !== '' && tid11Before === tid11After,
    `nbob's scoped token_id unchanged after repeat issue_tokens (byte-stable)`);

  // ---------- N12 batch cap: 257 senders aborts; client wrapper pages ----------
  CUR = 'N12-batch-cap';
  console.log('\n=== N12 batch cap (V12) ===');
  // Direct raw call with 257 senders — should abort at the service.
  const n12SvcBefore = nst2(nsvc);
  const nsvcRejectsBefore12 = nsvc.rejects.length;
  await mutate(alice, '::actor::qa_issue_tokens_direct',
    { service: nsvc.cid, senders: Array(257).fill(nbob.cid) });
  await sleep(2500);
  ok(nsvc.rejects.slice(nsvcRejectsBefore12).some((m) => /cap|exceed|256/i.test(m)),
    `direct issue_tokens with 257 senders aborts at service (V12 cap error in rejects)`);
  ok(nst2(nsvc) === n12SvcBefore,
    `no state change on service after 257-sender abort (V12 zero-mutation)`);
  // Client wrapper pages 257 into batches of 256 + 1; both confirms land.
  const confirmsBefore12 = ro(alice, '::actor::qa_notify_state', undefined)
    .Reduce('regconfirm_log').Visualize();
  await mutate(alice, '::a2a_notifications::notify_issue_tokens',
    { service: 'svc', contacts: Array(257).fill(nbob.cid) });
  await sleep(6000); // two service round-trips: 256 + 1
  const confirmsAfter12 = ro(alice, '::actor::qa_notify_state', undefined)
    .Reduce('regconfirm_log').Visualize();
  // Stronger: count VAPID_PUB_TEST occurrences (appears exactly once per confirm in
  // regconfirm_log via my_registration_t.$vapid_pub). 257 contacts → 256+1 = 2 pages
  // → 2 service round-trips → 2 confirms, so the delta must be >= 2.
  const countVapid = (s) => (s.match(/VAPID_PUB_TEST/g) || []).length;
  const confirmDelta = countVapid(confirmsAfter12) - countVapid(confirmsBefore12);
  ok(confirmDelta >= 2,
    `paged issue_tokens with 257 contacts yields >=2 confirms (256-batch + 1-batch, delta=${confirmDelta})`);
  ok(/token_id/.test(nst2(alice)),
    `alice contact_tokens set after paged issue_tokens`);

  // ---------- N13 non-contact cid mints anyway (V1) ----------
  CUR = 'N13-noncontact-mint';
  console.log('\n=== N13 non-contact cid mints (V1) ===');
  // alice2.cid: a legitimate packet cid that is NOT a contact of either alice or nsvc.
  // The service mints regardless (can't know R's contact set — V1).
  await mutate(alice, '::a2a_notifications::notify_issue_tokens',
    { service: 'svc', contacts: [alice2.cid] });
  await sleep(3000);
  ok(new RegExp(alice2.cid).test(nst2(nsvc)),
    `service mints scoped token for alice2.cid (never met by nsvc — V1 non-contact mint)`);

  // ---------- N14 zero-contact issue → abort (V11) ----------
  CUR = 'N14-zero-senders';
  console.log('\n=== N14 zero senders (V11) ===');
  const nsvcRejectsBefore14 = nsvc.rejects.length;
  await mutate(alice, '::actor::qa_issue_tokens_direct',
    { service: nsvc.cid, senders: [] });
  await sleep(2500);
  ok(nsvc.rejects.slice(nsvcRejectsBefore14).some((m) => /non-empty|at least one|V11/i.test(m)),
    `empty $senders aborts at service (V11 — non-empty required)`);

  // ---------- N15 registered-recipient gate ----------
  CUR = 'N15-gate';
  console.log('\n=== N15 registered-recipient gate ===');
  // Temporarily unregister alice from nsvc to create the unregistered-caller scenario.
  await mutate(alice, '::a2a_notifications::notify_unregister', { service: 'svc' });
  await sleep(2500);
  const n15Before = nst2(nsvc);
  const nsvcRejectsBefore15 = nsvc.rejects.length;
  await mutate(alice, '::actor::qa_issue_tokens_direct',
    { service: nsvc.cid, senders: [nbob.cid] });
  await sleep(2500);
  ok(nst2(nsvc) === n15Before,
    `issue_tokens from unregistered caller: zero state change`);
  ok(nsvc.rejects.slice(nsvcRejectsBefore15).some((m) => /No notification registration/i.test(m)),
    `issue_tokens from unregistered caller aborts with registration gate error`);
  // Re-register alice and re-issue the scoped tokens the unregister purged
  // (so the export/import tests below have per-sender state to round-trip).
  await mutate(alice, '::a2a_notifications::notify_register', { service: 'svc', bindings: null });
  await sleep(2500);
  await mutate(alice, '::a2a_notifications::notify_issue_tokens',
    { service: 'svc', contacts: [nbob.cid, neve.cid] });
  await sleep(2500);

  // ---------- N16 export/import round-trip includes the three new maps ----------
  CUR = 'N16-export-import-v2';
  console.log('\n=== N16 export/import round-trip ===');
  const n16SvcExp = ro(nsvc, '::actor::export_state', undefined);
  fs.writeFileSync(resolve(UNIT_DIR, 'n16-svc.bin'), Buffer.from(n16SvcExp.Serialize()));
  const n16AliceExp = ro(alice, '::actor::export_state', undefined);
  fs.writeFileSync(resolve(UNIT_DIR, 'n16-alice.bin'), Buffer.from(n16AliceExp.Serialize()));
  const nsvc3 = mk('nsvc3'); await mkPacket(nsvc3, 'seed-nsvc3'); await sleep(1000);
  await mutate(nsvc3, '::actor::import_state',
    nsvc3.pw.packet.ParseValue(new Uint8Array(fs.readFileSync(resolve(UNIT_DIR, 'n16-svc.bin')))));
  const n16Svc3 = nst2(nsvc3);
  ok(new RegExp(nbob.cid).test(n16Svc3),
    `sender_tokens round-trips: nbob's entry restored on the replacement service packet`);
  ok(new RegExp(neve.cid).test(n16Svc3),
    `sender_tokens round-trips: neve's entry restored`);
  const alice3 = mk('alice3'); await mkPacket(alice3, 'seed-alice3'); await sleep(1000);
  await mutate(alice3, '::actor::import_state',
    alice3.pw.packet.ParseValue(new Uint8Array(fs.readFileSync(resolve(UNIT_DIR, 'n16-alice.bin')))));
  const n16Alice3 = nst2(alice3);
  ok(/token_id/.test(n16Alice3),
    `my_notify_contact_tokens round-trips: contact tokens restored on alice3`);

  // ====== N17-N21: post_notification validation ======

  // ---------- N17 scoped happy path ----------
  CUR = 'N17-scoped-post';
  console.log('\n=== N17 scoped post happy path ===');
  // alice has scoped tokens for nbob/neve (re-issued in N15 after the purging unregister).
  // Export a notify_address_t blob wrapping nbob's scoped token from alice's my_notify_contact_tokens.
  const n17ScopedAddrBlob = Buffer.from(
    ro(alice, '::actor::qa_export_contact_notify_address',
       { service: nsvc.cid, sender: nbob.cid }).Reduce('blob').GetBinary()
  );
  const n17Before = nst(nsvc);
  await mutate(nbob, '::a2a_notifications::send_notification',
               { address: binv(nbob, n17ScopedAddrBlob), payload: 'scoped-hello' });
  await sleep(2500);
  const n17After = nst(nsvc);
  ok(/scoped-hello/.test(n17After), `scoped token: nbob posts via scoped handout, hook fired`);
  // sender_cid comes before payload in notification_t; extract window around payload to verify.
  { const idx = n17After.indexOf('scoped-hello');
    ok(new RegExp(nbob.cid).test(n17After.slice(Math.max(0, idx - 500), idx + 50)),
       `scoped post: sender_cid recorded as nbob`); }

  // ---------- N18 $from != $scope ----------
  CUR = 'N18-from-ne-scope';
  console.log('\n=== N18 sender binding mismatch ($from != $scope) ===');
  const n18Before = nst(nsvc);
  // neve tries to post with nbob's scoped token — envelope $from == neve.cid, token.$scope == _str(nbob.cid).
  await mutate(neve, '::a2a_notifications::send_notification',
               { address: binv(neve, n17ScopedAddrBlob), payload: 'evil-neve' });
  await sleep(2500);
  ok(nst(nsvc) === n18Before, `$from≠$scope: service rejects (step 5 binding check), zero state change`);
  ok(!/evil-neve/.test(nst(nsvc)), `$from≠$scope: payload does not appear in log`);

  // ---------- N19 muted sender (real set_sender_muted round-trip) ----------
  CUR = 'N19-muted';
  console.log('\n=== N19 muted sender ===');
  // Capture nbob's scoped token_id BEFORE the mute cycle to assert no re-issue.
  const n19TokIdBefore = ro(nsvc, '::actor::qa_scoped_token_id',
    { recipient: alice.cid, sender: nbob.cid }).Reduce('token_id').Visualize();
  // Mute via the REAL service inbound (round-trip): alice tells nsvc to mute nbob.
  await mutate(alice, '::a2a_notifications::notify_set_sender_muted',
    { service: 'svc', contact: nbob.cid, muted: true });
  await sleep(2500);
  // Hook plumbing: the confirm's on_notify_registration hook carries the
  // $sender_muted map (the messenger engine's mirror feed) with nbob's entry.
  ok(new RegExp(nbob.cid).test(ro(alice, '::actor::qa_last_confirm_muted', undefined)
    .Reduce('sender_muted').Visualize()),
    `confirm hook carries $sender_muted with nbob's entry after mute`);
  const n19Before = nst(nsvc);
  await mutate(nbob, '::a2a_notifications::send_notification',
               { address: binv(nbob, n17ScopedAddrBlob), payload: 'muted-ping' });
  await sleep(2500);
  ok(nst(nsvc) === n19Before, `muted: post from muted sender aborts (step 6), no hook fired, zero state change`);
  ok(!/muted-ping/.test(nst(nsvc)), `muted: payload does not appear in log`);
  // Unmute via the REAL service inbound ($muted FALSE → delete entry; absent = enabled).
  await mutate(alice, '::a2a_notifications::notify_set_sender_muted',
    { service: 'svc', contact: nbob.cid, muted: false });
  await sleep(2500);
  await mutate(nbob, '::a2a_notifications::send_notification',
               { address: binv(nbob, n17ScopedAddrBlob), payload: 'unmuted-ping' });
  await sleep(2500);
  ok(/unmuted-ping/.test(nst(nsvc)), `unmuted: same token delivers after mute cleared (no re-issue needed)`);
  // Unmute deletes the entry — the hook's mute-map feed no longer names nbob.
  ok(!new RegExp(nbob.cid).test(ro(alice, '::actor::qa_last_confirm_muted', undefined)
    .Reduce('sender_muted').Visualize()),
    `confirm hook $sender_muted empty again after unmute (absent = enabled)`);
  // token_id must be byte-identical across the mute/unmute cycle — no re-issue.
  const n19TokIdAfter = ro(nsvc, '::actor::qa_scoped_token_id',
    { recipient: alice.cid, sender: nbob.cid }).Reduce('token_id').Visualize();
  ok(n19TokIdBefore !== '' && n19TokIdBefore === n19TokIdAfter,
    `token_id unchanged across mute/unmute cycle (no re-issue: ${n19TokIdBefore})`);

  // ---------- N21 scoped token for absent slot ----------
  CUR = 'N21-absent-slot';
  console.log('\n=== N21 scoped token for absent slot ===');
  // Clear nbob's slot from notify_sender_tokens[alice] via qa probe.
  // The token is now a "zombie" — valid artifact, but no matching slot → step 4 aborts.
  await mutate(nsvc, '::actor::qa_notify_clear_sender_slot', { recipient: alice.cid, sender: nbob.cid });
  const n21Before = nst(nsvc);
  await mutate(nbob, '::a2a_notifications::send_notification',
               { address: binv(nbob, n17ScopedAddrBlob), payload: 'absent-slot-ping' });
  await sleep(2500);
  ok(nst(nsvc) === n21Before, `absent slot: scoped post aborts at step 4, zero state change`);
  ok(!/absent-slot-ping/.test(nst(nsvc)), `absent slot: payload does not appear in log`);

  // ====== N23-N26: per-sender rotation, revocation, receive-mute ======

  // ---------- N23 per-sender rotate ----------
  CUR = 'N23-per-sender-rotate';
  console.log('\n=== N23 per-sender rotate ===');
  // N23 setup: re-register alice (E8 idempotent — she is still registered) then
  // re-issue scoped tokens for neve and nbob (N21 cleared nbob's slot directly).
  await mutate(alice, '::a2a_notifications::notify_register', { service: 'svc', bindings: null });
  await sleep(2500);
  await mutate(alice, '::a2a_notifications::notify_issue_tokens',
    { service: 'svc', contacts: [neve.cid, nbob.cid] });
  await sleep(2500);
  // Capture token_ids (qa_scoped_token_id reads notify_sender_tokens[alice][sender].$c.$token_id).
  const n23NeveTokId1 = ro(nsvc, '::actor::qa_scoped_token_id',
    { recipient: alice.cid, sender: neve.cid }).Reduce('token_id').Visualize();
  const n23NbobTokId1 = ro(nsvc, '::actor::qa_scoped_token_id',
    { recipient: alice.cid, sender: nbob.cid }).Reduce('token_id').Visualize();
  ok(n23NeveTokId1 !== '' && n23NbobTokId1 !== '', `N23 setup: both scoped token_ids available before rotation`);
  // Export neve's current blob via the REAL per-contact export trn (neve is
  // alice's contact 'Eve' — this covers export_notify_address end-to-end).
  const n23NeveBlob1 = Buffer.from(
    ro(alice, '::a2a_notifications::export_notify_address',
       { service: 'svc', contact: 'Eve' }).Reduce('blob').GetBinary()
  );
  const n23NbobBlob = Buffer.from(
    ro(alice, '::actor::qa_export_contact_notify_address',
       { service: nsvc.cid, sender: nbob.cid }).Reduce('blob').GetBinary()
  );
  // Per-sender rotate: rotate ONLY neve's token (contact = neve.cid).
  await mutate(alice, '::a2a_notifications::notify_rotate_token',
    { service: 'svc', contact: neve.cid });
  await sleep(2500);
  // neve's token_id must change; nbob's must be unchanged.
  const n23NeveTokId2 = ro(nsvc, '::actor::qa_scoped_token_id',
    { recipient: alice.cid, sender: neve.cid }).Reduce('token_id').Visualize();
  const n23NbobTokId2 = ro(nsvc, '::actor::qa_scoped_token_id',
    { recipient: alice.cid, sender: nbob.cid }).Reduce('token_id').Visualize();
  ok(n23NeveTokId2 !== '' && n23NeveTokId2 !== n23NeveTokId1,
    `neve's token_id changed after per-sender rotate`);
  ok(n23NbobTokId2 !== '' && n23NbobTokId2 === n23NbobTokId1,
    `nbob's token_id unchanged after rotating only neve`);
  // neve's OLD blob must abort at index lookup (old token_id deleted from notify_token_index).
  const n23Before = nst(nsvc);
  await mutate(neve, '::a2a_notifications::send_notification',
               { address: binv(neve, n23NeveBlob1), payload: 'neve-old-token-ping' });
  await sleep(2500);
  ok(nst(nsvc) === n23Before, `neve's old scoped blob aborts after per-sender rotate (zero state change)`);
  ok(!/neve-old-token-ping/.test(nst(nsvc)), `neve old payload absent`);
  // neve's NEW blob (from alice's updated contact-token mirror) must deliver.
  const n23NeveBlob2 = Buffer.from(
    ro(alice, '::actor::qa_export_contact_notify_address',
       { service: nsvc.cid, sender: neve.cid }).Reduce('blob').GetBinary()
  );
  await mutate(neve, '::a2a_notifications::send_notification',
               { address: binv(neve, n23NeveBlob2), payload: 'neve-new-token-ping' });
  await sleep(2500);
  ok(/neve-new-token-ping/.test(nst(nsvc)), `neve's new scoped blob delivers after per-sender rotation`);
  // nbob's blob is unchanged — must still deliver (only neve's token was rotated).
  await mutate(nbob, '::a2a_notifications::send_notification',
               { address: binv(nbob, n23NbobBlob), payload: 'nbob-unrotated-ping' });
  await sleep(2500);
  ok(/nbob-unrotated-ping/.test(nst(nsvc)), `nbob's token unaffected by neve's per-sender rotation`);

  // ---------- N24 rotate-all (Q9 panic button) ----------
  CUR = 'N24-rotate-all';
  console.log('\n=== N24 rotate-all (Q9) ===');
  // Export current neve and nbob blobs from alice's updated mirror (after N23 rotation of neve).
  const n24NeveBlob1 = Buffer.from(
    ro(alice, '::actor::qa_export_contact_notify_address',
       { service: nsvc.cid, sender: neve.cid }).Reduce('blob').GetBinary()
  );
  const n24NbobBlob1 = Buffer.from(
    ro(alice, '::actor::qa_export_contact_notify_address',
       { service: nsvc.cid, sender: nbob.cid }).Reduce('blob').GetBinary()
  );
  // Rotate-all: $contact absent → rotate ALL scoped slots (Q9).
  await mutate(alice, '::a2a_notifications::notify_rotate_token', { service: 'svc' });
  await sleep(2500);
  // OLD neve and nbob scoped blobs must abort (old token_ids deleted from index).
  const n24Before = nst(nsvc);
  await mutate(neve, '::a2a_notifications::send_notification',
               { address: binv(neve, n24NeveBlob1), payload: 'neve-rotate-all-old-ping' });
  await sleep(2500);
  ok(nst(nsvc) === n24Before, `rotate-all: neve's old scoped blob aborts after rotate-all (zero state change)`);
  ok(!/neve-rotate-all-old-ping/.test(nst(nsvc)), `rotate-all: neve old payload absent`);
  await mutate(nbob, '::a2a_notifications::send_notification',
               { address: binv(nbob, n24NbobBlob1), payload: 'nbob-rotate-all-old-ping' });
  await sleep(2500);
  ok(nst(nsvc) === n24Before, `rotate-all: nbob's old scoped blob aborts after rotate-all (zero state change)`);
  ok(!/nbob-rotate-all-old-ping/.test(nst(nsvc)), `rotate-all: nbob old payload absent`);
  // NEW blobs (from alice's updated mirror, populated by the rotate-all confirm) must deliver.
  const n24NeveBlob2 = Buffer.from(
    ro(alice, '::actor::qa_export_contact_notify_address',
       { service: nsvc.cid, sender: neve.cid }).Reduce('blob').GetBinary()
  );
  const n24NbobBlob2 = Buffer.from(
    ro(alice, '::actor::qa_export_contact_notify_address',
       { service: nsvc.cid, sender: nbob.cid }).Reduce('blob').GetBinary()
  );
  await mutate(neve, '::a2a_notifications::send_notification',
               { address: binv(neve, n24NeveBlob2), payload: 'neve-rotate-all-new-ping' });
  await sleep(2500);
  ok(/neve-rotate-all-new-ping/.test(nst(nsvc)), `rotate-all: neve's new scoped blob delivers`);
  await mutate(nbob, '::a2a_notifications::send_notification',
               { address: binv(nbob, n24NbobBlob2), payload: 'nbob-rotate-all-new-ping' });
  await sleep(2500);
  ok(/nbob-rotate-all-new-ping/.test(nst(nsvc)), `rotate-all: nbob's new scoped blob delivers`);
  // The registration record itself carries no token — rotate-all must leave it
  // untouched (assert against the registrations slice, not the whole dump).
  ok(!/token_id/.test(ro(nsvc, '::actor::qa_notify_state', undefined).Reduce('registrations').Visualize()),
    `registration record carries no token after rotate-all (per-contact-only model)`);

  // ---------- N25 revoke (revoke-without-replace) ----------
  CUR = 'N25-revoke';
  console.log('\n=== N25 revoke (revoke-without-replace) ===');
  // Export current neve and nbob blobs (from alice's mirror after N24 rotate-all).
  const n25NeveBlob = Buffer.from(
    ro(alice, '::actor::qa_export_contact_notify_address',
       { service: nsvc.cid, sender: neve.cid }).Reduce('blob').GetBinary()
  );
  const n25NbobBlob = Buffer.from(
    ro(alice, '::actor::qa_export_contact_notify_address',
       { service: nsvc.cid, sender: nbob.cid }).Reduce('blob').GetBinary()
  );
  // Revoke neve's token (no re-mint): alice tells nsvc to delete neve's index entry + slot.
  await mutate(alice, '::a2a_notifications::notify_revoke_contact_tokens',
    { service: 'svc', contacts: [neve.cid] });
  await sleep(2500);
  // neve's posts must abort (index entry deleted, slot gone, no re-mint).
  const n25Before = nst(nsvc);
  await mutate(neve, '::a2a_notifications::send_notification',
               { address: binv(neve, n25NeveBlob), payload: 'revoked-neve-ping' });
  await sleep(2500);
  ok(nst(nsvc) === n25Before, `neve's posts abort after revoke (index gone, zero state change)`);
  ok(!/revoked-neve-ping/.test(nst(nsvc)), `revoked neve payload absent`);
  // no re-mint — alice's contact_token mirror must no longer contain neve's entry.
  const n25Alice = nst2(alice);
  ok(!new RegExp(neve.cid).test(n25Alice),
    `neve absent from alice's contact_token mirror after revoke (confirm contains no neve re-mint)`);
  // nbob still delivers (unaffected by revoke of neve).
  await mutate(nbob, '::a2a_notifications::send_notification',
               { address: binv(nbob, n25NbobBlob), payload: 'post-revoke-nbob-ping' });
  await sleep(2500);
  ok(/post-revoke-nbob-ping/.test(nst(nsvc)), `nbob unaffected by neve revoke, still delivers`);
  // Revoke of never-issued sender: no-op success (E4/E8 — delete of absent slot tolerated).
  const n25V2Before = nst2(nsvc);
  const n25RejBefore = nsvc.rejects.length;
  await mutate(alice, '::a2a_notifications::notify_revoke_contact_tokens',
    { service: 'svc', contacts: [v1Fresh.cid] });
  await sleep(2500);
  ok(nst2(nsvc) === n25V2Before,
    `revoke never-issued sender: no-op (E4/E8) — service v2 state unchanged`);
  ok(nsvc.rejects.length === n25RejBefore,
    `revoke never-issued sender: no rejection (success response, idempotent)`);

  // ---------- N26 service-side gate (registered-recipient, set_sender_muted) ----------
  CUR = 'N26-service-gate';
  console.log('\n=== N26 service-side gate (set_sender_muted, unregistered caller) ===');
  // Unregister alice so the service has no registration for her.
  await mutate(alice, '::a2a_notifications::notify_unregister', { service: 'svc' });
  await sleep(2500);
  const n26V1Before = nst(nsvc);
  const n26V2Before = nst2(nsvc);
  const n26RejBefore = nsvc.rejects.length;
  // qa_set_sender_muted_direct bypasses the client-side registration check and injects
  // set_sender_muted directly over alice's encrypted channel with nsvc.
  // Service gate: "No notification registration for this sender." must abort and mutate nothing.
  await mutate(alice, '::actor::qa_set_sender_muted_direct',
    { service: nsvc.cid, sender: nbob.cid, muted: true });
  await sleep(2500);
  ok(nst(nsvc) === n26V1Before && nst2(nsvc) === n26V2Before,
    `service gate: set_sender_muted from unregistered caller: zero service state change`);
  ok(nsvc.rejects.slice(n26RejBefore).some((m) => /No notification registration/i.test(m)),
    `service gate: set_sender_muted from unregistered caller aborts at registered-recipient gate`);

  // ---------- V5 CAP-1 gate (deny only on positive evidence) ----------
  // Moved here from test.mjs: this exercises the a2a_notifications CLIENT
  // capability gate (notify_register), so it needs the notifications library +
  // the alice/nsvc notify nodes established above.
  CUR = 'V5 CAP-1';
  console.log('\n=== V5 CAP-1 capability gate at the notify client send ===');
  {
    // Positive evidence: alice "learned" nsvc advertises caps WITHOUT
    // core.notifications → register must be denied AS DATA (no send, no abort).
    await mutate(alice, '::actor::qa_set_contact_caps', { cid: nsvc.cid, caps: ['core.cluster'] });
    const den = await mutate(alice, '::a2a_notifications::notify_register', { service: nsvc.cid });
    ok(!isT(den.Reduce('ok').Visualize()), `CAP-1: register toward a caps-lacking service denied AS DATA ($ok FALSE)`);
    ok(den.Reduce('error').Reduce('code').Visualize() === 'capability_not_advertised',
      `CAP-1: denial carries stable code capability_not_advertised`);
    ok(/notification support/.test(den.Reduce('error').Reduce('message').Visualize()),
      `CAP-1: denial message is render-ready`);
    // Unknown/empty caps → pass-through (pre-0.5 contacts keep working).
    await mutate(alice, '::actor::qa_set_contact_caps', { cid: nsvc.cid, caps: [] });
    const allow = await mutate(alice, '::a2a_notifications::notify_register', { service: nsvc.cid });
    ok(allow.Reduce('sent_to').Visualize() === nsvc.cid, `CAP-1: EMPTY/unknown caps pass through (fail-open) — register sent`);
  }

  console.log('\n================ NOTIF ================');
  if (scorecard.length === 0) console.log('NOTIF: ALL GREEN');
  else { console.log(`${scorecard.length} FAILURE(S):`); scorecard.forEach((s) => console.log('  ' + s)); }
  await sleep(500);
  process.exit(scorecard.length === 0 ? 0 : 1);
}
main().catch((e) => { log('DRIVER ERR:', e.stack ?? e.message); process.exit(1); });
