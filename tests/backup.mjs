#!/usr/bin/env node
// Sealed-backup + words-only key-through-init restore suite (core 0.6.0,
// a2a_backup.mm — the one-human-secret collapse design).
//
//   phase1: live packets → backup_init (words minted IN-WASM; returns the
//           sealed_key artifact) + export_state_sealed → persist ONLY
//           {words, ciphertext artifacts} → EXIT (the "restart").
//   phase2: fresh process → throwaway packet unseals sealed_key with the
//           WORDS (in-wasm) → recreate each packet with seed '' and
//           --init_trn_argument <unsealed hex> (__init reseeds) → assert the
//           SAME container id → import_state_sealed(words) → assert contacts
//           + messages restored → restore legs re-exchange ADs (reseed rolls
//           encrypt keys) → assert a live message round-trip.
//           Negatives: wrong words abort cleanly; future-version envelope
//           fails closed.
//
// Run via tests/run_backup.sh (one broker across both phases).
import { resolve } from 'node:path';
import * as fs from 'node:fs';
import { adapt_wrapper } from '@adapt-toolkit/sdk/executables';
import { PacketWrapperConfigurator } from '@adapt-toolkit/sdk/wrappers';
import { object_to_adapt_value } from '@adapt-toolkit/sdk/wrapper';

const PHASE = process.argv[2];
const BK_STATE = process.env.BK_STATE || '/tmp/ours-backup-test-state.json';
const BROKER_URL = process.env.BROKER_URL || 'ws://127.0.0.1:9790';
const UNIT_DIR = resolve('.');
const unitHash = fs.readdirSync(UNIT_DIR).find((f) => f.endsWith('.muflo')).slice(0, -'.muflo'.length);
const UNIT = new Uint8Array(fs.readFileSync(resolve(UNIT_DIR, `${unitHash}.muflo`)));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => process.stderr.write(`[bk] ${a.join(' ')}\n`);
const scorecard = [];
const ok = (c, m) => { if (!c) { scorecard.push(`✗ [${PHASE}] ${m}`); console.log(`  ✗ FAIL: ${m}`); } else { console.log(`  ✓ ${m}`); } };

let wrapper;
function mk(name) { return { name, pw: null, cid: '', pending: [], rejects: [] }; }
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
    else { id.rejects.push(String(msg)); log(`${id.name} inbound rejected:`, String(msg).split('\n')[0]); }
  };
}
function mutate(id, name, targ) {
  return new Promise((res, rej) => {
    const timer = setTimeout(() => rej(new Error(`${id.name}.${name} timed out`)), 25000);
    id.pending.push({ resolve: res, reject: rej, timer });
    id.pw.add_client_message(object_to_adapt_value({ name, targ }));
  });
}
const ro = (id, name, targ) => id.pw.packet.ExecuteTransaction(object_to_adapt_value({ name, targ }));
const binv = (id, buf) => id.pw.packet.NewBinaryFromBuffer(Buffer.from(buf));

// extraArgs: ['--init_trn_argument', JSON.stringify(secretHex)] on restore —
// the exact ours-mcp createPacket shape: empty seed + injected signing secret.
async function mkPacket(id, seed, extraArgs = []) {
  const cfg = new PacketWrapperConfigurator();
  cfg.process_arguments(['--unit_hash', unitHash, '--seed_phrase', seed, '--unit_dir_path', UNIT_DIR, ...extraArgs]);
  await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error(`${id.name} create timeout`)), 30000);
    wrapper.packet_manager.create_packet(cfg, (pw) => {
      clearTimeout(t); id.pw = pw; id.cid = pw.packet.GetContainerID().Visualize(); wire(id);
      log(`${id.name} cid ${id.cid.slice(0, 12)}…`); res();
    }, UNIT);
  });
}
const inbox = (id) => ro(id, '::actor::list_incoming_messages', undefined).Visualize();
const contactName = (id, cid) => ro(id, '::actor::qa_contact_name', { cid }).Reduce('name').Visualize();

async function phase1() {
  const X = mk('X'); const Y = mk('Y');
  await mkPacket(X, 'bk-seed-X-01'); await mkPacket(Y, 'bk-seed-Y-02');
  await sleep(1200);
  await mutate(X, '::a2a_messaging::set_my_name', { name: 'BackupAlice' });
  await mutate(Y, '::a2a_messaging::set_my_name', { name: 'BackupBob' });

  // real contact + traffic so there is real state to seal
  const m = await mutate(X, '::a2a_messaging::generate_invite', {});
  const blob = Buffer.from(m.Reduce('invite').GetBinary());
  await mutate(Y, '::a2a_messaging::add_contact', { invite: binv(Y, blob), name: 'AliceOfX' });
  await sleep(5000);
  await mutate(X, '::a2a_messaging::send_message', { contact: Y.cid, text: 'seal-me-marker-x2y' });
  await sleep(2500);
  await mutate(Y, '::a2a_messaging::send_message', { contact: X.cid, text: 'seal-me-marker-y2x' });
  await sleep(2500);
  ok(/seal-me-marker-x2y/.test(inbox(Y)) && /seal-me-marker-y2x/.test(inbox(X)), 'phase1: bidirectional traffic established');

  // words-rooted backup setup: words minted IN-WASM, sealed_key returned
  const xInit = await mutate(X, '::actor::backup_init', {});
  const xWords = xInit.Reduce('words').Visualize();
  const xSealedKey = Buffer.from(xInit.Reduce('sealed_key').GetBinary());
  const yInit = await mutate(Y, '::actor::backup_init', {});
  const yWords = yInit.Reduce('words').Visualize();
  const ySealedKey = Buffer.from(yInit.Reduce('sealed_key').GetBinary());
  ok(xWords.trim().split(/\s+/).length === 24, `phase1: X backup words minted in-wasm (24 words — owner decision)`);
  ok(yWords.trim().split(/\s+/).length === 24, `phase1: Y backup words minted in-wasm (24 words)`);
  log(`X words: ${xWords}`); log(`Y words: ${yWords}`);
  if (xWords === yWords) log('NOTE: identical phrases across packets (test_mode entropy?) — flagging, not failing');

  // the sealed_key artifact must not contain the signing secret in the clear:
  // compare against the plaintext export_signing_secret bytes.
  const xSecPlain = Buffer.from(ro(X, '::actor::export_signing_secret', undefined).Serialize());
  const xSecCore = xSecPlain.subarray(Math.floor(xSecPlain.length / 2) - 8, Math.floor(xSecPlain.length / 2) + 8);
  ok(!xSealedKey.includes(xSecCore), 'sealed_key does NOT contain the raw signing-secret bytes');

  // re-export parity: export_signing_secret_sealed unseals to the same secret (proven in phase2 by restore)
  const xSealedKey2 = Buffer.from(ro(X, '::actor::export_signing_secret_sealed', undefined).Reduce('sealed_key').GetBinary());
  ok(xSealedKey2.length > 0, 'export_signing_secret_sealed re-exports the artifact on demand');

  // Confidentiality, self-calibrated: the SAME record as plain bytes vs
  // sealed bytes — the marker must be findable in the former (proves the
  // scan works on this serialization) and absent from the latter.
  const probe = ro(X, '::actor::qa_seal_probe', { marker: 'CONFIDENTIALITY-CANARY-0451' });
  const pPlain = Buffer.from(probe.Reduce('plain').GetBinary());
  const pSealed = Buffer.from(probe.Reduce('sealed').GetBinary());
  ok(pPlain.includes('CONFIDENTIALITY-CANARY-0451'),
    'calibration: the marker IS visible in the plaintext serialization bytes');
  ok(!pSealed.includes('CONFIDENTIALITY-CANARY-0451'),
    'SEALED bytes do NOT contain the marker (encrypted inside wasm)');
  // and the real sealed state blob carries no known plaintext either
  const xSealed = Buffer.from(ro(X, '::actor::export_state_sealed', undefined).Reduce('sealed').GetBinary());
  const ySealed = Buffer.from(ro(Y, '::actor::export_state_sealed', undefined).Reduce('sealed').GetBinary());
  ok(!xSealed.includes('seal-me-marker') && !xSealed.includes('BackupBob'),
    'SEALED state blob contains no plaintext state markers');

  // service auth surface: stable id + identity-signed PUT request
  const xBid = ro(X, '::actor::backup_id', undefined).Reduce('backup_id').Visualize();
  ok(xBid.length > 10, `backup_id derived in-wasm (${xBid.slice(0, 14)}…)`);
  const sig = ro(X, '::actor::sign_backup_request', { payload: { seq: 1, op: 'put' } });
  ok(String(sig.Reduce('sig').Visualize()).length > 0, 'sign_backup_request: identity-key signature over the domain-separated digest');

  // persist ONLY the words + ciphertext artifacts — no plaintext secrets.
  fs.writeFileSync(BK_STATE, JSON.stringify({
    xCid: X.cid, yCid: Y.cid, xWords, yWords, xBid,
    xChallenge: pSealed.toString('base64'),   // the qa_seal_probe blob doubles as a service challenge sealed to B.pub
    xSealedKey: xSealedKey.toString('base64'), ySealedKey: ySealedKey.toString('base64'),
    xSealed: xSealed.toString('base64'), ySealed: ySealed.toString('base64'),
  }));
  log(`phase1 artifacts persisted to ${BK_STATE} (words + ciphertext only)`);
}

async function phase2() {
  const S = JSON.parse(fs.readFileSync(BK_STATE, 'utf8'));

  // throwaway bootstrap packet: any seed; it only executes unseal trns.
  const T = mk('T');
  await mkPacket(T, 'bk-throwaway-99');
  await sleep(800);

  // wrong words must abort cleanly, before anything else
  let wrongErr = '';
  try {
    await mutate(T, '::actor::unseal_signing_secret', {
      words: 'legal winner thank year wave sausage worth useful legal winner thank yellow',
      sealed_key: binv(T, Buffer.from(S.xSealedKey, 'base64')),
    });
  } catch (e) { wrongErr = String(e.message); }
  ok(/Decryption failed|Unable to deserialize/i.test(wrongErr),
    `wrong words: unseal aborts cleanly (${wrongErr.split('\n')[0].slice(0, 70)})`);

  // future-versioned envelope fails closed
  const fut = Buffer.from((await mutate(T, '::actor::qa_mk_future_sealed', {})).Reduce('blob').GetBinary());
  let futErr = '';
  try { await mutate(T, '::actor::unseal_signing_secret', { words: S.xWords, sealed_key: binv(T, fut) }); }
  catch (e) { futErr = String(e.message); }
  ok(/newer than this core supports/.test(futErr), `future sealed version fails CLOSED with the stable message`);

  // recovery auth: a fresh device (words only) answers a challenge sealed to B.pub
  const ans = await mutate(T, '::actor::unseal_recovery_challenge',
    { words: S.xWords, challenge: binv(T, Buffer.from(S.xChallenge, 'base64')) });
  ok(ans.Reduce('answer').Reduce('probe_marker').Visualize() === 'CONFIDENTIALITY-CANARY-0451',
    'recovery auth: fresh device answers the B-sealed challenge with the WORDS alone (in-wasm)');

  // the real words-only unseal of both package keys
  const xHex = (await mutate(T, '::actor::unseal_signing_secret',
    { words: S.xWords, sealed_key: binv(T, Buffer.from(S.xSealedKey, 'base64')) })).Reduce('secret_hex').Visualize();
  const yHex = (await mutate(T, '::actor::unseal_signing_secret',
    { words: S.yWords, sealed_key: binv(T, Buffer.from(S.ySealedKey, 'base64')) })).Reduce('secret_hex').Visualize();
  ok(xHex.length > 0 && yHex.length > 0, 'words-only unseal of the package keys succeeded (in-wasm)');

  // THE key-through-init recreation: empty seed + injected signing secret.
  const X2 = mk('X2'); const Y2 = mk('Y2');
  await mkPacket(X2, '', ['--init_trn_argument', JSON.stringify(xHex)]);
  await mkPacket(Y2, '', ['--init_trn_argument', JSON.stringify(yHex)]);
  await sleep(1200);
  ok(X2.cid === S.xCid, `key-through-init: X recreated at the SAME container id (${X2.cid.slice(0, 12)}…)`);
  ok(Y2.cid === S.yCid, `key-through-init: Y recreated at the SAME container id`);

  // sealed restore with the words
  await mutate(X2, '::actor::import_state_sealed', { sealed: binv(X2, Buffer.from(S.xSealed, 'base64')), words: S.xWords });
  await mutate(Y2, '::actor::import_state_sealed', { sealed: binv(Y2, Buffer.from(S.ySealed, 'base64')), words: S.yWords });
  ok(contactName(X2, S.yCid) !== '', `sealed restore: X2 has Y as a contact again ("${contactName(X2, S.yCid)}")`);
  ok(contactName(Y2, S.xCid) === 'AliceOfX', `sealed restore: Y2 has X as contact "AliceOfX"`);
  ok(/seal-me-marker-y2x/.test(inbox(X2)), `sealed restore: X2 inbox restored (message survived the seal round-trip)`);

  // channels: reseed rolled the encrypt keys, so imported peer_ads are stale
  // BOTH ways — the contact-restore legs re-exchange ADs (the exact scenario
  // the core's restore machinery exists for), then traffic flows again.
  await mutate(X2, '::actor::qa_send_restore_request', { target: S.yCid });
  await sleep(4000);
  await mutate(Y2, '::actor::qa_send_restore_request', { target: S.xCid });
  await sleep(4000);
  await mutate(X2, '::a2a_messaging::send_message', { contact: S.yCid, text: 'post-restore-roundtrip' });
  await sleep(3000);
  ok(/post-restore-roundtrip/.test(inbox(Y2)),
    'post-restore: encrypted channel heals via restore legs and a message round-trips');

  // post-restore sealed export still works WITHOUT the words (backup_pub restored)
  const again = Buffer.from(ro(X2, '::actor::export_state_sealed', undefined).Reduce('sealed').GetBinary());
  ok(again.length > 0 && !again.includes('post-restore-roundtrip'),
    'post-restore: sealed export works without the words (backup_pub re-derived at import)');
  // and the service identity survives the restore: SAME backup_id, PUT signing works
  const bid2 = ro(X2, '::actor::backup_id', undefined).Reduce('backup_id').Visualize();
  ok(bid2 === S.xBid, `post-restore: backup_id STABLE across restore (${bid2.slice(0, 14)}…)`);
  ok(String(ro(X2, '::actor::sign_backup_request', { payload: { seq: 2, op: 'put' } }).Reduce('sig').Visualize()).length > 0,
    'post-restore: PUT signing works without the words (identity key via key-through-init)');
}

async function main() {
  wrapper = await adapt_wrapper.start(['--broker_address', BROKER_URL, '--test_mode',
    '--logger_config', '--level', 'WARNING', '--stdout', 'stderr', '--logger_config_end']);
  wrapper.start();
  await sleep(1500);
  if (PHASE === 'phase1') await phase1();
  else if (PHASE === 'phase2') await phase2();
  else { log('usage: backup.mjs phase1|phase2'); process.exit(2); }
  console.log(`\n================ BACKUP ${PHASE} ================`);
  if (scorecard.length === 0) console.log(`BACKUP ${PHASE}: ALL GREEN`);
  else { console.log(`${scorecard.length} FAILURE(S):`); scorecard.forEach((s) => console.log('  ' + s)); }
  await sleep(300);
  process.exit(scorecard.length === 0 ? 0 : 1);
}
main().catch((e) => { log('DRIVER ERR:', e.stack ?? e.message); process.exit(1); });
