# COMPATIBILITY — the versioned type registry (core 0.5.0)

This document is **binding on every core change**. It declares the oldest peer this core
interoperates with, the registry of versioned wire types, the discriminator rules, and the
PR checklist a wire change must satisfy. Companion mechanism doc:
`docs/how-it-works/versioning.md`. The registry itself lives in **`a2a_versions.mm`**.

## Invariant

> **OLD PEERS NEVER CRASH.** Any payload a peer ≥ OSP sends is either dispatched to a typed
> per-version branch, or converted into a **first-class error value returned as data**
> (`a2a_versions::version_error_t`) — never a raw `EVAL_ERROR` escaping to the client.
> Crypto/tamper failures and identity-verification failures remain hard aborts by design.

## OSP — oldest supported peer

**OSP = core 0.2.0** (`faa2b52`, the deployed ours-mcp pin) → version floor
`a2a_versions::min_wire_version = 2`.

Raising the OSP is an **owner decision recorded here**: drop the dead `v*_t` types from the
unions, delete their corpus fixtures (a visible, reviewed act), and update this section.

## The wire version id (`$pv`)

- `wire_version = 8` (minor-version ints: 0.5.0 stamped `$pv -> 5`; 0.7.x stamps `7` — the
  rcp/receipts surface registered in 0.7 warranted the bump; the initial 0.7.0 under-bump left
  pre-receipts contacts permanently receipt-gated, the fixed single-tick bug; 0.8.0 stamps `8` —
  the **e2e** signed-message surface registered in 0.8). Monotone; bump **only** when a wire
  surface registers a new versioned type — not on every release.
- Stamped on every core-originated send: cleartext `$targ` envelopes **and** inside the
  boxed identity-bundle payloads (invite legs 1/3, restore legs 1/2).
- Absence ⇒ pre-0.5 peer; the registry's per-surface **shape-inference rule** applies.
- A **mistyped** `$pv` (non-int) is treated as unstamped — reading the discriminator can
  never abort.
- `$pv` is peer-asserted metadata riding authenticated channels: it gates parsing branches,
  send-side feature selection, and diagnostics — **NEVER authz** (REG-6). Signed-artifact
  `$version` ints (fail-closed) remain the only security-relevant version checks.
- Passive learning: `a2a_messaging::contact_pv` (cid → last-seen dialect; 0 = pre-0.5) and
  `contact_caps` (cid → advertised capability ids), learned on invite/restore legs and from
  stamped `$pv` on message/file traffic (an *unstamped* message never overwrites the more
  precise invite-time inference). Both maps are additive in the export blob, guarded on
  import.
- **Refresh scope (by design):** ordinary message/file traffic refreshes **`$pv` only** —
  `$caps` refreshes solely via the bundle legs (invite redeem / contact restore) or a future
  daemon-driven `get_manifest` pull (backlog); it is deliberately NOT piggybacked on every
  message (wire cost). Consequence: a peer that upgrades and then only sends ordinary
  messages is re-learned as `contact_pv = 5` with stale/absent caps — **benign** under the
  fail-open CAP-1 gate (absent/empty caps pass). Learning is per-contact lazy; there is no
  bulk re-sync. Monotonicity: unstamped traffic writes nothing, and a caps entry is never
  downgraded to empty — only replaced by a newer non-empty advertisement; `contact_pv`
  itself is last-*stamped*-wins so an honest software downgrade is re-learned (a forged
  lower `$pv` only degrades the forger's own UX — REG-6).

## Registry rules (REG-1…6)

- **REG-1** — every wire-visible input surface has a registry entry; a never-changed surface
  registers a single version (pre-wiring the change procedure).
- **REG-2** — a wire shape change = registering a **new** `v*_t` beside the frozen old ones
  (shipped versioned types are historical facts, never mutated). Union + dispatch gain one
  branch; reviewers see the whole compat surface in the diff.
- **REG-3** — the handler accepts the union of **all** registered versions ≥ OSP. Dropping a
  version from the union = an OSP raise (owner decision, recorded here).
- **REG-4 (dispatch-then-narrow)** — dispatch reads the discriminator off the RAW value and
  exact-casts to the matched version's type. **Never** cast-to-union as the selector
  (disjunction casts pick alternatives in canonical — not declaration — order and rebuild/
  strip; pinned by `tests/mufl_semantics/`). A `$pv` **newer** than the newest registered
  version narrows as the newest (class-A additions are strippable by construction).
- **REG-5 (safety net)** — below the registry, display/UX-class optional fields keep the
  `opt_*` NIL-tolerant read idiom (`a2a_versions::opt_str/opt_int/opt_bool`) as defense in
  depth. Review rule: **any new `safe` on wire data must be inside a registry
  `narrow`/branch or an `opt_*` call.**
- **REG-6** — `$pv`/`$caps` never gate authorization.

## Error-as-data (`version_error_t`)

A below-floor or unrecognized payload produces, **as data** (never an abort):

```
version_error_t: ($code, $surface, $message, $peer_version, $min_supported, $max_supported)
```

Stable `$code` values (wire contract):

| code | meaning |
|---|---|
| `peer_version_unsupported` | peer dialect below `min_wire_version` (too old) |
| `payload_shape_unrecognized` | payload matches no registered version ≥ floor |

On async inbound surfaces the handler early-returns `transaction::success` carrying a
`_notify_agent` event **before any state write**:

```
($event -> $protocol_error, $context -> $invite_redeem | $invite_complete | $contact_restore,
 $message -> <context-specific, render-ready>, $error -> version_error_t,
 $peer_cid -> …, $invite_id -> … when applicable)
```

Consumer obligation: the MCP daemon / control-plane frontend surface `$message` (and may
resolve `$error` for details). **Client-side rendering is a separate follow-up task**; the
core guarantees the shape above.

Owner-specified UX (implemented): a version-incompatible **invite second phase** does NOT
consume the invite — after the peer updates, the **same invite** redeems successfully. The
inviter's message says exactly that.

The CAP-1 denial (below) uses the sibling shape
`($ok -> FALSE, $error -> ($code -> "capability_not_advertised", $cap, $message, $peer_cid))`
returned as the transaction's data result.

### Abort-free classification (M1) and its documented residual

`try_narrow_*` pre-checks every **non-nullable** field the exact cast reads: presence AND
runtime domain via `_typeof` (str→`STRING`, int→`INTEGER`; `global_id` rides `STRING`).
Nullable fields (`bin+`, `str[]+`) are exempt (absent ⇒ NIL passes). Residual, accepted:
`safe global_id` also hex-validates, so a STRING-but-not-valid-hex id still aborts inside
the exact cast — no shipped sender can produce that; reaching it requires a hostile
hand-crafted box, which is the malformed/tamper class where an abort is correct.

## Registry index (0.5.0)

| Surface | Registry | Registered versions | Discriminator (pre-`$pv` inference) |
|---|---|---|---|
| leg-1 boxed identity bundle (`submit_invite_response`) | **sir** | v2 / v3 (+`$name`) / v5 (+`$pv`,`$caps`) | `$pv`; else `$name` present ⇒ 3, else 2. `$pv` 3..4 ⇒ v3 (0.4.x never shipped; wire-identical to 0.3), ≥5 ⇒ v5 |
| leg-3 boxed identity bundle (`complete_invite`) | **cin** | v2 / v5 (+`$pv`,`$caps`; never carried `$name`) | `$pv`; else 2 |
| restore legs 1/2 boxed bundles (`submit_restore_response`, `complete_restore`) | **rst** | v2 / v5 (+`$pv`,`$caps`) | `$pv`; else 2 |
| legacy `accept_contact` args | **acc** | v2 / v3 (+`$joiner_name`) | `$pv`; else `$joiner_name` present ⇒ 3, else 2. Path slated for class-C removal at the next OSP raise |
| `receive_message` `$targ` | **rmsg** | single version (+`$pv` stamp in 0.5.0) | `$pv`; else 2 |
| `receive_file` `$targ` | **rfil** | single version (+`$pv` stamp in 0.5.0) | `$pv`; else 2 |
| `receive_receipt` `$targ` (0.7.0) | **rcp** | single version (v1: `$kind`, `$wire_ids`, `$date+`, `$pv+`) | `$pv`; else 7 (surface cannot predate 0.7). Reachable only behind positive `core.receipts.*` caps |
| `e2e_signed_message` variant (0.8.0) | **e2e** | single version (v1: `$e2e_envelope` = `t_e2e_envelope`(`$session_id`,`$olm_type`,`$ciphertext`,`$pv+`), `$emsignature`) | inner `$e2e_envelope.$pv`; else 8 (surface cannot predate 0.8). Reachable only behind the `core.e2e` cap + AD v2 bundle; decode branch keys on the `$e2e_envelope` marker |

**Deferred surfaces** (tolerant field-by-field readers today; register on their first shape
change, or when REG-1 is extended repo-wide — owner question SPEC Q9): invite/restore
cleartext envelopes (`{$invite_id/$rid, $epk, $v, $data}` — now `$pv`-stamped on send),
`ingest_connect_descriptor`, `enroll_delegated_node`, `control_message` envelope,
monitoring copies / `push_to_cp` pushes (generic pass-through `$targ`, not stamped),
`notify_*` service surfaces (all `$pv`-stamped on send), signed artifacts (class D,
fail-closed, unchanged), export/import blob (`core_format_version`, INV-C3).

## Capability piggyback + CAP-1

The v5 bundle payloads carry `$caps -> str[]` — the sender's capability **ids** (from
`a2a_capabilities::self_cap_ids`, captured at `init` from `$supported`; empty for an app
that never wired capabilities). Learned into `contact_caps`.

**CAP-1 gate** (at the notify client sends `notify_register` / `send_notification`): deny —
**as data, degrade never abort** — only on **positive evidence**: a non-empty learned caps
set that lacks `core.notifications`. Unknown / absent / empty caps pass (pre-0.5 peers and
pre-0.5-established contacts keep working). Owner-approved fail-open interpretation.

## Wire-change taxonomy

| Class | What | Procedure |
|---|---|---|
| **A** | add an optional field to a tolerant surface | register `v<next>_t` (REG-2); union + dispatch gain a branch; corpus proves OSP unaffected. MINOR |
| **B** | new transaction (new inbound name) | new registry, single version; sends gated by CAP-1/`$pv`. MINOR |
| **C** | change/remove a field, change semantics | BREAKING: parallel transaction (class B) or new registered version with a dual-accept window; old version leaves the union only on an OSP raise. MAJOR |
| **D** | evolve a signed artifact | mint `vN+1` core metadef beside `vN`; verifiers accept an explicit version set; unknown version **fail-closed** (authz). Never mutate a signed shape |

## Message receipts (core 0.7.0) — capability-gated, fail-closed

Two protocol events on the recipient produce two pings to the message sender, both carried
by ONE new class-B transaction `::a2a_messaging::receive_receipt`
(`$kind "delivered"|"read"`, `$wire_ids str[]` — the shared message+file namespace, `$date+`,
`$pv+`): **delivered** fires atomically inside the accepted
`receive_message`/`receive_file` transaction (app-hook abort = no receipt); **read** fires on
the consumer's get/mark-read path via `read_receipt_actions` (readonly trns cannot send, so
the unread→read MARK is the read event — exact-once for free).

**Gate (hybrid since the caps-relearn fix):** caps are exchanged only on invite/restore
bundle legs and never re-negotiate on app update, so an EXPLICIT caps opinion (any
`core.receipts.*` id in the learned set) is followed strictly (receive ⇒ send; opinion
without receive ⇒ opt-out), while a caps-silent peer with learned dialect `pv >= 7` gets
`receive` IMPLIED — `contact_pv` re-learns from every stamped ordinary message, so two
upgraded peers self-heal on their first exchange, no re-pair. Old peers (`pv < 7`) stay
silent. Same hybrid drives `receipt_expectation`.

Capabilities (2 flat ids in `a2a_capabilities`, advertised via the new **`$advertise`** init
param — protocol-surface ids with no control verbs, so the `$supported`
declared-implies-implemented handler guard doesn't apply to them):
`core.receipts.emit` ("I will emit both kinds") and `core.receipts.receive` ("send me
yours"). Delivery-vs-read is wire metadata, not a capability split.

**Gate polarity — deliberately the OPPOSITE of CAP-1:** receipts fail **CLOSED** on
unknown/absent caps. Emit iff self advertises `emit` AND the peer POSITIVELY advertises
`receive` in learned `contact_caps`. Old clients advertise neither id ⇒ nothing is ever sent
to them (nothing they can't parse) and nothing is expected from them — zero transaction
failures both directions, by construction. Sender-side state is DERIVED
(`receipt_expectation`: "expected" iff the peer advertises `emit`, else "unknown" — absence
of a receipt is NEVER failure; no timeout state in core). Ingest is tolerant and never
load-bearing: unknown `$kind` = future receipt kind (ignore-success), malformed shapes are
dropped abort-free (rcp M1 checks incl. the list-domain guard), unknown senders get silent
success, and no receipt is ever emitted for a receipt. Consumer hook
(`on_receipt_received`, optional, default no-op) contract: application is MONOTONIC per
(peer, wire_id) on `unknown < sent < delivered < read`.

## Golden-wire corpus (release gate)

One fixture per registered version per registry, built as the **exact wire shape** that
version's sender emits (fixtures-as-code in `tests/test_actor.mu::qa_corpus_narrow` — the
payloads carry real ids + a real AD, which JSON files cannot encode), replayed through
`try_narrow_*`; the driver asserts the branch taken, the error-as-data classifications
(below-floor, unrecognized, mistyped fields), forward-compat (`$pv=7`⇒newest, `$pv=4`⇒v3),
and that the strict `narrow_*` aborts with the stable message.

Run: `tests/run_corpus.sh` (fast) — also exercised by the full suite `tests/run.sh`
(V-series: cross-version leg-1 end-to-end, Additions A/B, CAP-1, `$pv` learning) and
`tests/mufl_semantics/run.sh` (toolchain-behavior pins; verified on the **vendored mufl
0.8.0**). **A release is green only if every registered version parses and dispatches to
its branch.** Raising the OSP deletes corpus entries deliberately.

## PR checklist — any wire change

- [ ] New `v<next>_t` metadef registered beside the frozen ones (never mutate a shipped type)
- [ ] Union + `versions_t` vector + `version_of`/`try_narrow` branch updated in `a2a_versions.mm`
- [ ] Non-nullable fields of the new type added to the `_typeof` shape check (M1)
- [ ] Corpus fixture added (`qa_corpus_narrow`) + driver assertion (`tests/corpus.mjs`)
- [ ] `wire_version` bumped iff the surface's shape changed; pv↔core table updated in `docs/how-it-works/versioning.md`
- [ ] Release note carries a **Wire delta** section (fields added, surfaces, OSP impact)
- [ ] `version.mm` bumped
- [ ] Registry index table above updated
