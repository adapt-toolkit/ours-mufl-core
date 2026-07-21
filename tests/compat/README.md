# tests/compat — cross-version back-compat matrix (M-legs) + upgrade-UX legs (U-legs)

The DR-rollout ship gate (DR-ROLLOUT-PLAN.md §5/§5.1): prove that an OLD-core peer and a
NEW-core peer interoperate (DoD D1) and that upgrades migrate seamlessly (D2/D3) — with the
two peers running in **separate processes, each under its own SDK runtime and its own
compiled unit**. That two-runtime split is what the rest of `tests/` deliberately avoids
(single node_modules, both peers in-process) and what production actually is mid-rollout.

## Peers

- **OLD** — core `v0.2.0` (`faa2b52`, the OSP: the deployed ours-mcp/tg-connector repo pin;
  no `$pv`, no DR, legacy `encrypted_channel`), compiled by and run under an 0.9.x-era
  toolkit (`OLD_ADAPT_TOOLKIT` / `OLD_SDK_NM`).
- **NEW** — THIS working tree's core, compiled by and run under the current pinned toolkit
  (`ADAPT_TOOLKIT` / `OURS_SDK_NODE_MODULES`, same knobs as `run.sh`).

Each peer's build dir gets its own `core/` sources, its own compiled `.muflo`, and its own
`node_modules` symlink — a packet is only ever loaded by the runtime whose compiler built
it (the eval_unit.h hash-check contract).

## Env (run_compat.sh)

| Var | Meaning | Default |
|---|---|---|
| `OLD_CORE_REF` | git ref for the OLD peer's core sources | `v0.2.0` |
| `OLD_ADAPT_TOOLKIT` | toolkit checkout whose `mufl-compile` + stdlib build the OLD unit | required |
| `OLD_SDK_NM` | node_modules with the OLD-era `@adapt-toolkit` sdk | required |
| `ADAPT_TOOLKIT` / `OURS_SDK_NODE_MODULES` / `DEV_BROKER` / `PORT` | as in `run.sh` | required |

## Leg inventory (status is explicit — an unimplemented leg FAILS, never skips silently)

| Leg | Gate | DoD | Status |
|---|---|---|---|
| M1 invite gen→redeem, both directions | MP | D1 | implemented |
| M2 first-contact message after redeem | MP | D1 | implemented |
| M3 steady-state send/receive both ways | MP | D1 | implemented |
| M4 file transfer both ways | MP | D1 | implemented |
| M5 OLD restarts: v0-blob export→reimport, channel resumes | MP | D1,D2 | implemented |
| M6 NEW restarts: stamped blob + DR sessions restore | MP | D1,D2 | implemented |
| M7 NEW↔NEW DR handshake + ratchet + dual restart | MP | D1 | not-implemented (needs 2× NEW peers — trivial config once M1–M6 green) |
| M8 stale-snapshot restore → self-heal | NTH | D2 | not-implemented |
| M9 corrupt blob import reject-to-empty | MP(NEW) | D2 | not-implemented |
| M10 version_error_t as data | NTH | D1 | not-implemented (assertion pattern exists in tests/test.mjs V-series) |
| M11 pv re-learning on peer downgrade | NTH | D1 | not-implemented |
| M12 cross-app tg-connector↔mcp | MP | D1,D4 | lives in the consumer repos (drives their packets, not this actor) |
| U1/U2/U3 npm-bump upgrade legs | MP | D2,D3 | live in the consumer repos' CI (install old → state → bump → verify) |

Related prior art this seeds from: control-plane `tests/blob-import.mjs` (old-unit→new-unit
same-seed gate) and `tests/mixed-unit.mjs` (4-cell pairing matrix) — single-runtime versions
of M5/M1; this harness generalizes them across runtimes.

## Run

```
OLD_ADAPT_TOOLKIT=... OLD_SDK_NM=... ADAPT_TOOLKIT=... OURS_SDK_NODE_MODULES=... \
DEV_BROKER=... bash tests/compat/run_compat.sh
```

## M12 — control-plane NEW ↔ mcp OLD (owner's named leg) — GREEN 2026-07-21

Reuses this orchestrator with per-side flavors (`NEW_PEER_FLAVOR=messenger` switches the
READ verbs to `::actor::get_conversation`; the whole `::a2a_messaging::` write surface is
shared). Peers: NEW = the control-plane DR unit (dev5/dr-e2e-integration, sdk 0.10.10,
core v0.8.0) · OLD = the REAL mcp actor (`packages/core/mufl_code/actor.mu`) at its
deployed pins (core `faa2b52` = v0.2.0/OSP) compiled+run under published sdk/mufl 0.9.1.
Result: M1–M6 all green (invites both ways, first-contact, steady both ways, files both
ways, both restart-restore legs).

```
# build dirs: old = mcp actor + 0.9.1 stage; new = cp unit + its node_modules
OLD_BUILD_DIR=<mcp-old> NEW_BUILD_DIR=<cp-new> NEW_PEER_FLAVOR=messenger \
  LEG_FILTER=M1,M2,M3,M4,M5,M6 node tests/compat/compat.mjs
```

## U3 — control-plane upgrade path — GREEN 2026-07-21

Under the fresh-address ruling (unpublished app, zero clients) the npm-bump leg's
meaningful nucleus is the control-plane's own blob-import gate: main-era unit sources
(messenger + core 0.7.1) compiled with the CURRENT toolchain → real state → import under
the DR unit → same seed ⇒ same cid, history/contacts preserved, zero rejects, re-export
round-trips. Run via the cp repo's tests/run-blob-import.sh with OLD_UNIT pointed at the
main-era build.
