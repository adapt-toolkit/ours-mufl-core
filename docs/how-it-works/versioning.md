# Versioning

`version.mm` is the single source of truth for the shared core's version. Every
library in the core loads it, so any packet that links the core carries exactly
one version stamp.

Source: [`version.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/version.mm).

## The version type

```mufl
metadef version_t: (
    $MAJ -> int,
    $MIN -> int,
    $PATCH -> int
).
```

The current version is stored in the `hidden` `core_version` field and exposed
via `get_core_version`. The source comment states:

> This MUST be updated every time we update ANY code in the shared core.

Because every library loads `version`, a single edit to any `.mm` file in the
core requires a version bump before the change ships.

## Runtime observability

Each deployed packet exposes its compiled-in version through the read-only
`get_version` transaction described in the README. An integrator can query any
running node to confirm which core version it is running — no out-of-band
coordination needed.

## What changes mean for integrators

| Change | What to do |
|---|---|
| `$PATCH` bump | Wire format is unchanged. Re-compile against the updated submodule; re-run integration tests to confirm nothing regressed. |
| `$MIN` bump | New features added; no existing behaviour removed. Re-compile, re-run integration tests, and read the diff to find new transactions or capability verbs you may want to use. |
| `$MAJ` bump | Breaking changes. Re-compile, re-run all integration tests, and read the diff carefully — wire shapes, transaction names, or type contracts may have changed. |

The docs on this site track `main`; always check the current `core_version` in
`version.mm` to confirm which version the docs describe.

## The versioned type registry (core 0.5.0)

Since 0.5.0, wire-level backward compatibility is an **explicit mechanism**, not a
convention: for every wire input surface whose shape ever changed,
[`a2a_versions.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_versions.mm)
declares one frozen metadef **per shipped wire version** of its payload, the accepted
**union** (the handler's visible contract), the ordered version vector, a **discriminator**,
and a dispatch function:

```mufl
metadef sir_payload_t: sir_payload_v5_t || sir_payload_v3_t || sir_payload_v2_t.

fn try_narrow_sir (raw: any) -> sir_narrowed_t   // ($ok, $payload, $err)
```

`try_narrow_*` reads the discriminator off the RAW value and exact-casts to the matched
version's type (**dispatch-then-narrow** — never cast-to-union as the selector, because
disjunction casts pick alternatives in canonical order and rebuild/strip; those toolchain
behaviors are pinned by `tests/mufl_semantics/`). Handlers then branch per version: the
v2 branch handles the payload the 0.2.0 way, the v5 branch the new way — backward
compatibility is visible in the types and the branches, not buried in NIL defaults.

### `$pv` — the wire dialect id

Every 0.5.0+ core-originated send stamps `$pv -> 5` (minor-version ints) on its `$targ`
and inside the boxed identity-bundle payloads. Absence means a pre-0.5 peer; the registry
infers the shape (e.g. leg-1 bundle: `$name` present ⇒ v3, else v2).

| `$pv` | core | notes |
|---|---|---|
| *(absent)* | 0.2.0 / 0.3.0 / 0.4.x | shape-inferred per registry |
| 2 | 0.2.0 dialect | synthetic (0.2.0 never stamps) |
| 3–4 | 0.3.0 dialect | 0.4.x never shipped; wire-identical to 0.3 |
| 5 | 0.5.0 | first stamped dialect |
| > 5 | future | narrows as the newest registered version (class-A additions strip safely) |

Peers' dialects are learned passively into `a2a_messaging::contact_pv` (and their
advertised capability ids into `contact_caps`, from the `$caps` piggyback on the invite/
restore bundles) — no handshake round-trip. Both gate feature selection and diagnostics
only, **never authorization**.

### Errors as data — old peers never crash

A payload from below the version floor (or matching no registered shape) is converted into
a first-class **error value** — `a2a_versions::version_error_t`
`($code, $surface, $message, $peer_version, $min_supported, $max_supported)` — delivered to
the local client as a `$protocol_error` notify event, while the transaction completes
successfully with **zero state writes**. A version-incompatible invite redeem therefore
does not consume the invite: the peer can update and redeem the very same invite.
Crypto/tamper and identity-verification failures remain hard aborts.

### The four-class change taxonomy

| Class | Change | Cost |
|---|---|---|
| A | add an optional field | new registered version + one dispatch branch (MINOR) |
| B | new transaction | new single-version registry (MINOR) |
| C | change/remove a field or semantics | breaking — parallel transaction or dual-accept window (MAJOR) |
| D | evolve a signed artifact | new versioned metadef, verifiers fail-closed on unknown versions |

The binding rules (REG-1…6), the OSP declaration, the full registry index, and the wire-
change PR checklist live in
[`COMPATIBILITY.md`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/COMPATIBILITY.md).

## Message receipts (core 0.7.0)

Delivery + read confirmations, capability-gated and **fail-closed**: a recipient emits
`receive_receipt` pings (`$kind "delivered"` on arrival, `"read"` on its get/mark-read path)
only when it advertises `core.receipts.emit` AND the sender positively advertises
`core.receipts.receive` — so old clients exchange no receipt traffic at all and the sender's
per-peer state is simply *unknown*, never *failed*. Details in
[`COMPATIBILITY.md`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/COMPATIBILITY.md).
