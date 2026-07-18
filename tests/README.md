# core 3.0 ephemeral-invite — loopback test suite

End-to-end behavioural tests for the slim ephemeral-key invite + two-message boxed
redeem (legs 1/2/3) shipped in core 3.0 (`release-notes/3.0.md`).

The core repo is pure mufl libraries with no standalone build, so these tests run
through a small **self-contained test actor** (`test_actor.mu`) that loads the
shared core and supplies the minimum host wiring (storage hooks, a tiny inbox, the
identity-hierarchy helpers, export/import wrappers) plus `qa_*` probe transactions
the driver uses to inject adversarial inputs and read state. **No consumer/daemon
source is vendored** — the actor is derived locally for this repo.

## Files

- **`test_actor.mu`** — the derived test actor (pure mufl; compiles against this
  repo's `core/` via the toolkit).
- **`test.mjs`** — the loopback driver: spins up multiple packets on one broker and
  runs the scenarios, asserting **receiver-side state** (not just send emission).
- **`run.sh`** — builds a throwaway harness, compiles, boots a local broker, runs
  the driver. Exit 0 = all green.
- **`corpus.mjs` / `run_corpus.sh`** — the **golden-wire corpus gate**
  (`COMPATIBILITY.md`): replays one fixture per registered wire version per
  registry through the `a2a_versions` dispatch and asserts the branch taken.
  Fast (single packet); a release is green only if this passes.
- **`mufl_semantics/run.sh`** — toolchain-behavior pins the registry rests on
  (safe-cast extra-field strip, disjunction canonical-order rebuild, 3-version
  dispatch), run against the vendored `@adapt-toolkit/mufl` package.

## Prerequisites (external to this repo)

1. **ADAPT toolkit** — the `mufl-compile` binary + `mufl_stdlib` / `meta` /
   `transactions` (default root `…/adapt-toolkit`).
2. **`@adapt-toolkit` Node SDK** — from any consumer checkout's `node_modules`
   (e.g. `ours-mcp/node_modules`); used only to drive packets in the loopback.
3. **`dev-broker.mjs`** — the local relay launcher (ships in `ours-mcp/scripts`).

Node 18+ (tested on v20).

## Run

```sh
./tests/run.sh
# or override paths:
ADAPT_TOOLKIT=/path/to/adapt-toolkit \
OURS_SDK_NODE_MODULES=/path/to/ours-mcp/node_modules \
DEV_BROKER=/path/to/ours-mcp/scripts/dev-broker.mjs \
PORT=9799 ./tests/run.sh
```

The SDK's leak-tracker prints `###`/`Leak for AdaptValue` lines at exit and inbound
aborts surface as `EVAL_ERROR` on stderr — both are expected noise (the adversarial
scenarios deliberately trigger aborts; `run.sh` forwards only the meaningful
`inbound rejected` lines). The verdict is the final `SCORECARD` + exit code.

## Scenarios asserted (10 scenarios, 36 assertions)

| # | Scenario | What it proves |
|---|----------|----------------|
| T1 | happy-flat | leg-2 consumes the invite + registers the responder; **leg-3 receiver-side**: the responder decrypts the boxed leg-3 with its kept eph priv and registers the inviter; both `list_contacts` show the other; `send_message` round-trips **both** directions over `encrypted_channel`. |
| T2 | happy-role | both sides are delegated roles; the delegation chain verifies and `contact_roots` is pinned on **both** legs. |
| T3 | single-use | a 2nd leg-1 for the same `invite_id` aborts (`already-redeemed`); inviter state unchanged. |
| T4 | invalid-then-valid | a bad box aborts at decrypt and does **not** consume the invite; a subsequent valid redeem then consumes it. |
| T5 | tamper | a tampered box aborts and mutates **no** state. |
| T6 | cid-bind leg-2 | a boxed AD whose `container_id` ≠ sender aborts; nothing registered/consumed. |
| T7 | PoP leg-2 | an AD with stripped self-signatures aborts in `process_address_document`. |
| T8 | leg-3 gates | unexpected-inviter (sender ≠ pinned cid), cid-bind leg-3, and PoP leg-3 each abort and register nothing. |
| T9 | export-secrecy | `export_core_state` contains **neither** `pending_invite_keys` **nor** `pending_redemption_keys`; `pending_invites` carries only public `{assigned, eph_pub, scheme}` (INV-4). |
| T10 | import migration | `export_state`→`import_state` preserves contacts/peer_ads and resets `pending_invites` (plan §4.4). |

Hard invariants exercised: **INV-5** (no `contacts`/`peer_ads`/`contact_roots`
write before lookup → decrypt → cid-bind → PoP → chain) on both legs; **single-use**
consumes both per-side ephemeral stores; **INV-4** (ephemeral secrets never
exported).

The R- and N-series (contact restore, notifications v1/v2) and the 0.5.0
**V-series** follow the same pattern. V-series (versioned type registry,
`COMPATIBILITY.md`): V1 the exact 0.2.0 leg-1 shape (no `$name` — the incident)
registers under the sender cid with **no abort**; V2 the 0.3.0 shape honors
`$name`; V3 the v5 shape learns `contact_pv`/`contact_caps`; V4 a below-floor
peer (`$pv=1`) produces the **error-as-data** `$protocol_error` notify at the
inviter, consumes **nothing**, and the same invite redeems after the peer
"updates"; V5 the CAP-1 capability gate denies as data only on positive
evidence; V6 stamped `$targ`s deliver normally and are learned passively.
