#!/usr/bin/env node
// Cross-version matrix orchestrator: spawns one OLD-runtime peer and one NEW-runtime peer
// (compat_peer.mjs each, separate processes, own node_modules + own unit — see README),
// then drives the M-legs against the pair. Scorecard semantics: an MP leg failing (or not
// implemented) exits non-zero; NTH legs report but never gate. No leg ever silently skips.
//
// Verb maps are per-era DATA. The OLD map targets the v0.2.0 test actor surface and must
// be validated when the OLD toolchain is first staged — a wrong verb fails loudly
// (transaction failure / timeout), which is the intended behavior, not a hazard.
import { spawn } from 'node:child_process';
import * as readline from 'node:readline';
import { resolve } from 'node:path';

const OLD_DIR = process.env.OLD_BUILD_DIR;
const NEW_DIR = process.env.NEW_BUILD_DIR;
const BROKER_URL = process.env.BROKER_URL || 'ws://127.0.0.1:9797';
if (!OLD_DIR || !NEW_DIR) { console.error('OLD_BUILD_DIR / NEW_BUILD_DIR required'); process.exit(2); }

const VERBS = {
  old: { invite: '::a2a_messaging::generate_invite', redeem: '::a2a_messaging::add_contact',
         send: '::a2a_messaging::send_message', sendFile: '::a2a_messaging::send_file',
         contacts: '::a2a_messaging::list_contacts', inbox: '::actor::get_messages', files: '::actor::get_files' },
  new: { invite: '::a2a_messaging::generate_invite', redeem: '::a2a_messaging::add_contact',
         send: '::a2a_messaging::send_message', sendFile: '::a2a_messaging::send_file',
         contacts: '::a2a_messaging::list_contacts', inbox: '::actor::get_messages', files: '::actor::get_files' },
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let nextId = 1;

function spawnPeer(dir, name, era, extraEnv = {}) {
  const child = spawn(process.execPath, [resolve(dir, 'compat_peer.mjs')], {
    cwd: dir, stdio: ['pipe', 'pipe', 'inherit'],
    env: { ...process.env, BROKER_URL, PEER_NAME: name, PEER_SEED: `compat ${name} seed`, ...extraEnv },
  });
  const peer = { name, era, verbs: VERBS[era], child, cid: '', events: [], waiters: new Map(), readyP: null };
  const rl = readline.createInterface({ input: child.stdout });
  let readyResolve; peer.readyP = new Promise((r) => { readyResolve = r; });
  rl.on('line', (line) => {
    let msg; try { msg = JSON.parse(line); } catch { return; }
    if (msg.ready) { peer.cid = msg.cid; return readyResolve(); }
    if (msg.event) return void peer.events.push(msg.event);
    if (msg.fatal) { console.error(`[${name}] FATAL ${msg.fatal}`); return readyResolve(); }
    const w = peer.waiters.get(msg.id);
    if (w) { peer.waiters.delete(msg.id); msg.ok ? w.resolve(msg.value) : w.reject(new Error(msg.error)); }
  });
  return peer;
}

function call(peer, op, fields = {}) {
  const id = nextId++;
  return new Promise((resolveP, rejectP) => {
    peer.waiters.set(id, { resolve: resolveP, reject: rejectP });
    peer.child.stdin.write(JSON.stringify({ id, op, ...fields }) + '\n');
  });
}
const tx = (peer, verb, arg, readonly = false) => call(peer, 'tx', { verb, arg, readonly });

// ---- legs ------------------------------------------------------------------
// Each leg: { id, gate: 'MP'|'NTH', dod, run(ctx) } — run throws on failure.
// ctx = { oldPeer, newPeer, respawn(peerRef, withState) }.
async function pair(a, b) {
  const inv = await tx(a, a.verbs.invite, { name: b.name });
  await tx(b, b.verbs.redeem, { invite: inv, name: a.name });
  await sleep(1500);
  const ca = await tx(a, a.verbs.contacts, undefined, true);
  const cb = await tx(b, b.verbs.contacts, undefined, true);
  if (!String(ca).includes(b.name) && !String(cb).includes(a.name)) throw new Error('pairing not reflected in contacts');
}
async function roundTrip(a, b, text) {
  await tx(a, a.verbs.send, { contact: b.name, text });
  await sleep(1500);
  const inbox = await tx(b, b.verbs.inbox, undefined, false);
  if (!String(inbox).includes(text)) throw new Error(`message not delivered: "${text}"`);
}

const LEGS = [
  { id: 'M1', gate: 'MP', dod: 'D1', name: 'invite gen→redeem, both directions',
    run: async ({ oldPeer, newPeer }) => { await pair(oldPeer, newPeer); } },
  { id: 'M2', gate: 'MP', dod: 'D1', name: 'first-contact message after redeem',
    run: async ({ oldPeer, newPeer }) => { await roundTrip(newPeer, oldPeer, 'first-contact new→old'); } },
  { id: 'M3', gate: 'MP', dod: 'D1', name: 'steady-state send/receive both ways',
    run: async ({ oldPeer, newPeer }) => {
      await roundTrip(oldPeer, newPeer, 'steady old→new'); await roundTrip(newPeer, oldPeer, 'steady new→old'); } },
  { id: 'M4', gate: 'MP', dod: 'D1', name: 'file transfer both ways',
    run: async ({ oldPeer, newPeer }) => {
      const data = Buffer.from('compat file payload').toString('base64');
      await tx(oldPeer, oldPeer.verbs.sendFile, { contact: newPeer.name, filename: 'a.txt', data });
      await tx(newPeer, newPeer.verbs.sendFile, { contact: oldPeer.name, filename: 'b.txt', data });
      await sleep(2000);
      const fa = await tx(newPeer, newPeer.verbs.files, undefined, false);
      const fb = await tx(oldPeer, oldPeer.verbs.files, undefined, false);
      if (!String(fa).includes('a.txt') || !String(fb).includes('b.txt')) throw new Error('file not received'); } },
  { id: 'M5', gate: 'MP', dod: 'D1,D2', name: 'OLD restart: v0-blob export→reimport, channel resumes',
    run: async (ctx) => {
      await call(ctx.oldPeer, 'export_state', { file: resolve(OLD_DIR, 'state.bin') });
      await ctx.respawn('oldPeer', true);
      await roundTrip(ctx.newPeer, ctx.oldPeer, 'post-old-restart new→old'); } },
  { id: 'M6', gate: 'MP', dod: 'D1,D2', name: 'NEW restart: stamped blob + DR-session restore',
    run: async (ctx) => {
      await call(ctx.newPeer, 'export_state', { file: resolve(NEW_DIR, 'state.bin') });
      await ctx.respawn('newPeer', true);
      await roundTrip(ctx.oldPeer, ctx.newPeer, 'post-new-restart old→new'); } },
  { id: 'M7', gate: 'MP', dod: 'D1', name: 'NEW↔NEW DR handshake + ratchet + dual restart',
    run: async () => { throw new Error('NOT IMPLEMENTED — needs a second NEW peer (config-only once M1–M6 are green)'); } },
  { id: 'M8', gate: 'NTH', dod: 'D2', name: 'stale-snapshot restore → self-heal',
    run: async () => { throw new Error('NOT IMPLEMENTED'); } },
  { id: 'M9', gate: 'MP', dod: 'D2', name: 'corrupt blob import reject-to-empty (NEW)',
    run: async () => { throw new Error('NOT IMPLEMENTED'); } },
  { id: 'M10', gate: 'NTH', dod: 'D1', name: 'version_error_t as data',
    run: async () => { throw new Error('NOT IMPLEMENTED — assertion pattern in tests/test.mjs V-series'); } },
  { id: 'M11', gate: 'NTH', dod: 'D1', name: 'pv re-learning on peer downgrade',
    run: async () => { throw new Error('NOT IMPLEMENTED'); } },
];

// ---- main ------------------------------------------------------------------
const ctx = {
  oldPeer: spawnPeer(OLD_DIR, 'oldpeer', 'old'),
  newPeer: spawnPeer(NEW_DIR, 'newpeer', 'new'),
  async respawn(ref, withState) {
    const prev = ctx[ref];
    await call(prev, 'exit').catch(() => {});
    await sleep(500);
    const dir = ref === 'oldPeer' ? OLD_DIR : NEW_DIR;
    ctx[ref] = spawnPeer(dir, prev.name, prev.era,
      withState ? { PEER_STATE_FILE: resolve(dir, 'state.bin') } : {});
    await ctx[ref].readyP;
  },
};

const results = [];
await ctx.oldPeer.readyP; await ctx.newPeer.readyP;
console.log(`peers up: old=${ctx.oldPeer.cid.slice(0, 10)} new=${ctx.newPeer.cid.slice(0, 10)}`);
for (const leg of LEGS) {
  try { await leg.run(ctx); results.push({ leg, pass: true }); console.log(`  ✓ ${leg.id} [${leg.gate}/${leg.dod}] ${leg.name}`); }
  catch (err) { results.push({ leg, pass: false, err }); console.log(`  ✗ ${leg.id} [${leg.gate}/${leg.dod}] ${leg.name}: ${err.message}`); }
}
await call(ctx.oldPeer, 'exit').catch(() => {}); await call(ctx.newPeer, 'exit').catch(() => {});
const mpFails = results.filter((r) => !r.pass && r.leg.gate === 'MP');
console.log(`\n${results.filter((r) => r.pass).length}/${LEGS.length} legs passed; MP failures: ${mpFails.length}`);
process.exit(mpFails.length ? 1 : 0);
