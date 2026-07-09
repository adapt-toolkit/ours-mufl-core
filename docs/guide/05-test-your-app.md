# 05 · Test your app

Two layers of testing keep a consumer honest: a **loopback suite for your own app**,
and the **core's own suite** run against the exact core revision you vendored.

## The loopback pattern for your app

Grow `drive.mjs` from page 04 into a real suite the way the core's tests do
(see [`tests/README.md`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/tests/README.md)):

- **A derived test actor.** Don't test against your production actor alone — derive a
  test build that adds `qa_*` probe transactions: read-only state counters
  (`qa_state`-style counts of contacts, peer ADs, pending invites), exporters
  (`qa_export_ad`), and adversarial injectors that bare-send crafted wire payloads. The
  core's [`tests/test_actor.mu`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/tests/test_actor.mu)
  shows the full probe vocabulary.
- **Assert receiver-side.** A send that "succeeded" proves little; assert the *peer's*
  state changed (its inbox, its contact book) and that rejected inputs changed
  *nothing* — the core suite's negative scenarios (replayed invites, tampered boxes,
  foreign address documents) all assert state-unchanged on the target.
- **One broker, many packets.** Spin all packets on one `dev-broker.mjs` in
  `--test_mode`; inbound aborts surface via `on_transaction_failure`, so collect them
  per-packet and grep them in assertions.

## Run the core's own suite (sanity check)

The vendored submodule ships its suite: 10 scenarios, 36+ assertions over invite
redeem, tamper rejection, export secrecy, and migration
(see [Invites & contacts](../how-it-works/invites-and-contacts.md)). Running it against
your checkout proves your toolkit + SDK + broker environment is sound and the core
revision you pinned behaves as released.

**Prereqs:**

- Pages [01](./01-vendor-the-core.md)–[04](./04-connect-and-message.md) completed.
- `$ADAPT_TOOLKIT`, `$OURS_SDK_NODE_MODULES`, `$DEV_BROKER` exported.
- No leftover dev broker on the chosen port (the suite boots its own; `PORT=9791`
  below avoids clashing with page 04's broker if you left it running).

**Steps:**

1. From your app repo **root** (`my-app`, not `mufl_code/`), run the suite inside the
   submodule, pointing it at your
   environment (`tests/run.sh` honors these as env overrides; it bundles the
   `protocol_container.mm` stub itself, so you no longer pass one in):

   ```sh
   cd mufl_code/core
   ADAPT_TOOLKIT="$ADAPT_TOOLKIT" \
   OURS_SDK_NODE_MODULES="$OURS_SDK_NODE_MODULES" \
   DEV_BROKER="$DEV_BROKER" \
   PORT=9791 ./tests/run.sh
   ```

   The run takes a few minutes: it copies the core into a throwaway harness, compiles
   the test actor, boots a broker on `PORT`, and drives all scenarios. `###` /
   `Leak for AdaptValue` lines and `EVAL_ERROR` stderr noise are expected — the
   adversarial scenarios deliberately trigger aborts.

**Verify:**

```sh
echo "EXIT=$?"
```

Success markers (the verdict is the final scorecard plus the exit code):

```
================ SCORECARD ================
ALL TESTS PASSED
EXIT=0
```

That closes the loop: an empty directory, a vendored core, a compiled packet, a live
encrypted round-trip, and the protocol's own suite green against your environment.
