#!/usr/bin/env node
// Cross-version matrix orchestrator: spawns OLD-runtime and NEW-runtime peers
// (compat_peer.mjs each, separate processes, own node_modules + own unit — see README),
// then drives the M-legs against the pair. Scorecard semantics: an MP leg failing (or not
// implemented) exits non-zero; NTH legs report but never gate. No leg ever silently skips.
import { spawn } from 'node:child_process';
import { openSync as fsOpenSync, appendFileSync as fsAppendFileSync } from 'node:fs';
import * as readline from 'node:readline';
import { resolve } from 'node:path';

const OLD_DIR = process.env.OLD_BUILD_DIR;
const NEW_DIR = process.env.NEW_BUILD_DIR;
const BROKER_URL = process.env.BROKER_URL || 'ws://127.0.0.1:9797';
if (!OLD_DIR || !NEW_DIR) { console.error('OLD_BUILD_DIR / NEW_BUILD_DIR required'); process.exit(2); }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let nextId = 1;

function spawnPeer(dir, name, extraEnv = {}) {
  // stderr goes to a per-peer log — handshake rejects surface there, and
  // discarding it turned real compat failures into blind timeouts.
  const errLog = fsOpenSync(resolve(dir, `${name}.stderr.log`), 'a');
  const child = spawn(process.execPath, [resolve(dir, 'compat_peer.mjs')], {
    cwd: dir, stdio: ['pipe', 'pipe', errLog],
    env: { ...process.env, BROKER_URL, PEER_NAME: name, PEER_SEED: `compat ${name} seed`,
      PEER_FLAVOR: dir === NEW_DIR ? (process.env.NEW_PEER_FLAVOR || 'actor') : (process.env.OLD_PEER_FLAVOR || 'actor'),
      ...extraEnv },
  });
  const peer = { name, dir, child, cid: '', events: [], waiters: new Map(), readyP: null, exited: null };
  const rl = readline.createInterface({ input: child.stdout });
  let readyResolve; peer.readyP = new Promise((r) => { readyResolve = r; });
  child.on('exit', (code, signal) => {
    peer.exited = { code, signal };
    console.log(`  [peer ${name}] exited code=${code} signal=${signal} (${peer.waiters.size} call(s) in flight)`);
    for (const [, w] of peer.waiters) w.reject(new Error(`peer ${name} exited (code=${code} signal=${signal})`));
    peer.waiters.clear();
    readyResolve(); // a dead peer resolves readyP; callers check peer.cid
  });
  rl.on('line', (line) => {
    let msg; try { msg = JSON.parse(line); } catch {
      // Non-JSON stdout (e.g. the sdk leak-detector dump on exit) must not
      // vanish — append it to the peer's log so leak totals are auditable.
      try { fsAppendFileSync(resolve(dir, `${name}.stderr.log`), `[stdout] ${line}\n`); } catch {}
      return;
    }
    if (msg.ready) { peer.cid = msg.cid; return readyResolve(); }
    if (msg.event) return void peer.events.push(msg.event);
    if (msg.fatal) { console.error(`[${name}] FATAL ${msg.fatal}`); return readyResolve(); }
    const w = peer.waiters.get(msg.id);
    if (w) { peer.waiters.delete(msg.id); msg.ok ? w.resolve(msg.value) : w.reject(new Error(msg.error)); }
  });
  return peer;
}

function call(peer, op, fields = {}, timeoutMs = 90000) {
  const id = nextId++;
  return new Promise((resolveP, rejectP) => {
    if (peer.exited && op !== 'exit') return rejectP(new Error(`peer ${peer.name} already exited`));
    const timer = setTimeout(() => {
      peer.waiters.delete(id);
      rejectP(new Error(`call ${op} on ${peer.name} timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    peer.waiters.set(id, {
      resolve: (v) => { clearTimeout(timer); resolveP(v); },
      reject: (e) => { clearTimeout(timer); rejectP(e); },
    });
    peer.child.stdin.write(JSON.stringify({ id, op, ...fields }) + '\n');
  });
}

// ---- shared drive helpers --------------------------------------------------
async function contactsInclude(peer, cid, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const contacts = String(await call(peer, 'contacts').catch(() => ''));
    if (contacts.includes(cid)) return true;
    if (Date.now() > deadline) return false;
    await sleep(1500);
  }
}
async function pair(inviter, redeemer) {
  const inviteB64 = await call(inviter, 'invite', { name: redeemer.name });
  await call(redeemer, 'redeem', { invite_b64: inviteB64, name: inviter.name });
  // Handshake is multi-leg and cross-runtime — poll until BOTH sides list the
  // peer instead of guessing a sleep. A timeout here is a real M1 verdict.
  const a = await contactsInclude(inviter, redeemer.cid);
  const b = await contactsInclude(redeemer, inviter.cid);
  if (!a || !b) throw new Error(`pairing incomplete after 30s (inviter-sees=${a} redeemer-sees=${b})`);
}
async function roundTrip(from, to, text, expectRoute) {
  const sent = await call(from, 'send', { cid: to.cid, text });
  if (expectRoute && sent?.route !== expectRoute) {
    throw new Error(`route mismatch: expected ${expectRoute}, got ${sent?.route} for "${text}"`);
  }
  await sleep(2500);
  const inbox = await call(to, 'inbox', { cid: from.cid });
  if (!String(inbox).includes(text)) throw new Error(`message not delivered: "${text}"`);
  return sent;
}

// ---- legs ------------------------------------------------------------------
const LEGS = [
  { id: 'M1', gate: 'MP', dod: 'D1', name: 'invite gen→redeem, both directions',
    run: async (ctx) => {
      await pair(ctx.oldPeer, ctx.newPeer); // OLD invites, NEW redeems (primary pair, reused by later legs)
      // Reverse direction on a fresh throwaway pair: NEW invites, OLD redeems.
      const old2 = spawnPeer(OLD_DIR, 'old2', { PEER_SEED: 'compat old2 seed' });
      const new2 = spawnPeer(NEW_DIR, 'new2', { PEER_SEED: 'compat new2 seed' });
      try {
        await old2.readyP; await new2.readyP;
        if (!old2.cid || !new2.cid) throw new Error('reverse-pair peers failed to boot');
        await pair(new2, old2);
        await roundTrip(new2, old2, 'reverse-pair first-contact new2→old2');
      } finally {
        await call(old2, 'exit').catch(() => {}); await call(new2, 'exit').catch(() => {});
      } } },
  { id: 'M2', gate: 'MP', dod: 'D1', name: 'first-contact message after redeem (new→old)',
    run: async (ctx) => { await roundTrip(ctx.newPeer, ctx.oldPeer, 'first-contact new->old'); } },
  { id: 'M3', gate: 'MP', dod: 'D1', name: 'steady-state send/receive both ways',
    run: async (ctx) => {
      await roundTrip(ctx.oldPeer, ctx.newPeer, 'steady old->new');
      await roundTrip(ctx.newPeer, ctx.oldPeer, 'steady new->old'); } },
  { id: 'M4', gate: 'MP', dod: 'D1', name: 'file transfer both ways',
    run: async (ctx) => {
      const data_b64 = Buffer.from('compat file payload').toString('base64');
      await call(ctx.oldPeer, 'send_file', { cid: ctx.newPeer.cid, filename: 'from-old.txt', data_b64 });
      await call(ctx.newPeer, 'send_file', { cid: ctx.oldPeer.cid, filename: 'from-new.txt', data_b64 });
      await sleep(3000);
      const fNew = String(await call(ctx.newPeer, 'files', { cid: ctx.oldPeer.cid }));
      const fOld = String(await call(ctx.oldPeer, 'files', { cid: ctx.newPeer.cid }));
      if (!fNew.includes('from-old.txt')) throw new Error('old→new file not received');
      if (!fOld.includes('from-new.txt')) throw new Error('new→old file not received'); } },
  { id: 'M5', gate: 'MP', dod: 'D1,D2', name: 'OLD restart: v0-blob export→reimport, channel resumes',
    run: async (ctx) => {
      await call(ctx.oldPeer, 'export_state', { file: resolve(OLD_DIR, 'state.bin') });
      await ctx.respawn('oldPeer', true);
      await roundTrip(ctx.newPeer, ctx.oldPeer, 'post-old-restart new->old'); } },
  { id: 'M6', gate: 'MP', dod: 'D1,D2', name: 'NEW restart: stamped blob + DR-session restore',
    run: async (ctx) => {
      await call(ctx.newPeer, 'export_state', { file: resolve(NEW_DIR, 'state.bin') });
      await ctx.respawn('newPeer', true);
      await roundTrip(ctx.oldPeer, ctx.newPeer, 'post-new-restart old->new'); } },
  { id: 'M7', gate: 'MP', dod: 'D1', name: 'NEW↔NEW DR handshake + ratchet + dual restart',
    run: async () => {
      const A = spawnPeer(NEW_DIR, 'newA', { PEER_SEED: 'compat newA seed' });
      const B = spawnPeer(NEW_DIR, 'newB', { PEER_SEED: 'compat newB seed' });
      try {
        await A.readyP; await B.readyP;
        if (!A.cid || !B.cid) throw new Error('M7 peers failed to boot');
        const CAPS = { advertise: ['core.e2e', 'core.e2e.migrate'] };
        await call(A, 'tx', { verb: '::actor::qa_init_caps', targ: CAPS });
        await call(B, 'tx', { verb: '::actor::qa_init_caps', targ: CAPS });
        await pair(A, B);
        // Drive migration sweeps until the route flips to the double ratchet.
        let route = '';
        const deadline = Date.now() + 45000;
        for (let i = 1; Date.now() < deadline && route !== 'e2e'; i++) {
          await call(A, 'tx', { verb: '::a2a_messaging::sweep_e2e_migrations', targ: {} }).catch(() => {});
          await call(B, 'tx', { verb: '::a2a_messaging::sweep_e2e_migrations', targ: {} }).catch(() => {});
          await sleep(2000);
          route = (await roundTrip(A, B, `dr-probe-${i}`))?.route ?? '';
        }
        if (route !== 'e2e') throw new Error(`route never reached e2e (last: ${route || 'legacy'})`);
        // Ratchet advance both directions on the live session.
        await roundTrip(A, B, 'dr-ratchet-a1', 'e2e');
        await roundTrip(B, A, 'dr-ratchet-b1', 'e2e');
        await roundTrip(A, B, 'dr-ratchet-a2', 'e2e');
        // Dual restart with state — DR sessions must survive on BOTH ends.
        await call(A, 'export_state', { file: resolve(NEW_DIR, 'stateA.bin') });
        await call(B, 'export_state', { file: resolve(NEW_DIR, 'stateB.bin') });
        await call(A, 'exit').catch(() => {}); await call(B, 'exit').catch(() => {});
        await sleep(1000);
        const A2 = spawnPeer(NEW_DIR, 'newA', { PEER_SEED: 'compat newA seed', PEER_STATE_FILE: resolve(NEW_DIR, 'stateA.bin') });
        const B2 = spawnPeer(NEW_DIR, 'newB', { PEER_SEED: 'compat newB seed', PEER_STATE_FILE: resolve(NEW_DIR, 'stateB.bin') });
        try {
          await A2.readyP; await B2.readyP;
          if (!A2.cid || !B2.cid) throw new Error('M7 respawn failed');
          await sleep(2000);
          await roundTrip(A2, B2, 'dr-post-restart-a');
          await roundTrip(B2, A2, 'dr-post-restart-b');
        } finally {
          await call(A2, 'exit').catch(() => {}); await call(B2, 'exit').catch(() => {});
        }
      } finally {
        await call(A, 'exit').catch(() => {}); await call(B, 'exit').catch(() => {});
      } } },
  { id: 'M8', gate: 'NTH', dod: 'D2', name: 'stale-snapshot restore → self-heal',
    run: async () => { throw new Error('NOT IMPLEMENTED'); } },
  { id: 'M9', gate: 'MP', dod: 'D2', name: 'corrupt blob import reject-to-functional (NEW)',
    run: async (ctx) => {
      await call(ctx.newPeer, 'export_state', { file: resolve(NEW_DIR, 'state.bin') });
      const { readFileSync, writeFileSync } = await import('node:fs');
      const good = readFileSync(resolve(NEW_DIR, 'state.bin'));
      writeFileSync(resolve(NEW_DIR, 'state.bin'), good.subarray(0, Math.floor(good.length / 2)));
      await ctx.respawn('newPeer', true);
      const failed = ctx.newPeer.events.some((e) => String(e).startsWith('import_failed'));
      if (!failed) throw new Error('corrupt blob did not surface import_failed');
      // Reject-to-FUNCTIONAL: the fresh identity must still pair + message.
      const inviteB64 = await call(ctx.oldPeer, 'invite', { name: 'renew' });
      await call(ctx.newPeer, 'redeem', { invite_b64: inviteB64, name: 'oldpeer-again' });
      const seen = await contactsInclude(ctx.newPeer, ctx.oldPeer.cid);
      if (!seen) throw new Error('post-corruption re-pairing failed');
      // Restore the good blob so later runs/legs are unaffected.
      writeFileSync(resolve(NEW_DIR, 'state.bin'), good);
    } },
  { id: 'M10', gate: 'NTH', dod: 'D1', name: 'version_error_t as data',
    run: async () => { throw new Error('NOT IMPLEMENTED — assertion pattern in tests/test.mjs V-series'); } },
  { id: 'M11', gate: 'NTH', dod: 'D1', name: 'pv re-learning on peer downgrade',
    run: async () => { throw new Error('NOT IMPLEMENTED'); } },
];

// ---- main ------------------------------------------------------------------
const ctx = {
  oldPeer: spawnPeer(OLD_DIR, 'oldpeer'),
  newPeer: spawnPeer(NEW_DIR, 'newpeer'),
  async respawn(ref, withState) {
    const prev = ctx[ref];
    await call(prev, 'exit').catch(() => {});
    await sleep(1000);
    const dir = ref === 'oldPeer' ? OLD_DIR : NEW_DIR;
    ctx[ref] = spawnPeer(dir, prev.name,
      withState ? { PEER_STATE_FILE: resolve(dir, 'state.bin') } : {});
    await ctx[ref].readyP;
    if (!ctx[ref].cid) throw new Error(`${prev.name} failed to respawn`);
    await sleep(2000);
  },
};

const results = [];
await ctx.oldPeer.readyP; await ctx.newPeer.readyP;
if (!ctx.oldPeer.cid || !ctx.newPeer.cid) { console.error('peer boot failed'); process.exit(1); }
console.log(`peers up: old=${ctx.oldPeer.cid.slice(0, 10)} new=${ctx.newPeer.cid.slice(0, 10)}`);
// LEG_FILTER=M7,M9 runs a subset (unlisted legs report as skipped-by-filter, never silently)
const filter = (process.env.LEG_FILTER || '').split(',').filter(Boolean);
for (const leg of LEGS) {
  if (filter.length && !filter.includes(leg.id)) {
    console.log(`  - ${leg.id} skipped by LEG_FILTER (not a verdict)`); continue;
  }
  try { await leg.run(ctx); results.push({ leg, pass: true }); console.log(`  ✓ ${leg.id} [${leg.gate}/${leg.dod}] ${leg.name}`); }
  catch (err) { results.push({ leg, pass: false, err }); console.log(`  ✗ ${leg.id} [${leg.gate}/${leg.dod}] ${leg.name}: ${err.message}`); }
}
await call(ctx.oldPeer, 'exit').catch(() => {}); await call(ctx.newPeer, 'exit').catch(() => {});
const mpFails = results.filter((r) => !r.pass && r.leg.gate === 'MP');
console.log(`\n${results.filter((r) => r.pass).length}/${LEGS.length} legs passed; MP failures: ${mpFails.length} (${mpFails.map((r) => r.leg.id).join(', ') || 'none'})`);
process.exit(mpFails.length ? 1 : 0);
