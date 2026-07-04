# Start here

> **These docs are written for agents.** ours.network expects most applications to be
> built by coding agents working on behalf of a human. Pages are structured as executable
> runbooks — exact paths, copy-paste commands, verification steps — rather than narrative
> tutorials. Humans are welcome; give your agent the URL of
> [`llms-full.txt`](/ours-mufl-core/llms-full.txt) and it can ingest the entire
> documentation in one fetch.

This guide takes you from an empty directory to a working ours.network application:
a MUFL packet that **consumes** the shared protocol core, plus the host-side driver
that boots it, connects it to a peer, and exchanges encrypted messages. Every
ours.network client is built this way — it vendors this repo as a git submodule and
compiles it into its own packet (see [Overview](../how-it-works/overview.md)).

**Scope note — integration only.** This guide never touches protocol code. You will not
edit any `.mm` file of the core; a change there is a protocol revision for the whole
network. Everything you write here — your `config.mufl`, your actor (`.mu` file), your
Node driver — is *your application*, layered on top of an unmodified core. If you think
the protocol itself needs a change, read
[Contributing](../reference/contributing.md) instead.

## What you will build

| Page | Result |
|------|--------|
| [01 · Vendor the core](./01-vendor-the-core.md) | The core checked out as a git submodule under `mufl_code/core` |
| [02 · Configure & compile](./02-configure-and-compile.md) | A `config.mufl` that merges the core with the stdlib, and a first compiled packet |
| [03 · Wire the host](./03-wire-the-host.md) | An actor with the storage hooks, init wiring, and export/import composition the core expects |
| [04 · Connect & message](./04-connect-and-message.md) | Two packets on a local broker: invite → contact → encrypted message round-trip |
| [05 · Test your app](./05-test-your-app.md) | A loopback test pattern for your app, plus the core's own suite as a sanity check |

**Prereqs:**

- The **ADAPT toolkit** — the `mufl-compile` binary plus the `mufl_stdlib` / `meta` /
  `transactions` module trees. The pages refer to its root as `$ADAPT_TOOLKIT`
  (`$ADAPT_TOOLKIT/build.linux.release/mufl-compile` must exist).
- The **`@adapt-toolkit` Node SDK** — a `node_modules` directory containing
  `@adapt-toolkit` (any ours.network consumer checkout has one). The pages refer to it
  as `$OURS_SDK_NODE_MODULES`.
- A **local dev broker launcher** — `dev-broker.mjs`, a thin launcher over the SDK's
  broker exports (ships with the consumer repos). The pages refer to it as `$DEV_BROKER`.
  It must run from a directory whose `node_modules` resolves `@adapt-toolkit`; the
  layout built in this guide takes care of that.
- **git** and **Node 18+**.

These are the same three knobs the core's own test suite takes
(`ADAPT_TOOLKIT` / `OURS_SDK_NODE_MODULES` / `DEV_BROKER` — see
[05 · Test your app](./05-test-your-app.md)). Export them once per shell:

```sh
export ADAPT_TOOLKIT=/path/to/adapt-toolkit
export OURS_SDK_NODE_MODULES=/path/to/consumer/node_modules
export DEV_BROKER=/path/to/dev-broker.mjs
```

**Steps:** start at [01 · Vendor the core](./01-vendor-the-core.md); each page builds
on the previous one and ends with a Verify block whose success markers come from a
live run of exactly the commands shown.

**Verify:** after page 04 you have a bidirectional encrypted round-trip
(`ROUND-TRIP OK`, exit 0); after page 05 the core's own suite reports
`SCORECARD` / `ALL TESTS PASSED` with exit 0.
