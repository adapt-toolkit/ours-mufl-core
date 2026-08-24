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

- `wire_version = 9` (minor-version ints: 0.5.0 stamped `$pv -> 5`; 0.7.x stamps `7` — the
  rcp/receipts surface registered in 0.7 warranted the bump; the initial 0.7.0 under-bump left
  pre-receipts contacts permanently receipt-gated, the fixed single-tick bug; 0.8.0 stamps `8` —
  the **e2e** signed-message surface registered in 0.8; 0.13 stamps `9` — the **crm**
  contact-removal surface registered in 0.13). Monotone; bump **only** when a wire
  surface registers a new versioned type — not on every release. Every consumer of a
  learned `$pv` is a `>=` threshold, so a bump never changes an existing gate.
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
| `receive_contact_removal` `$targ` (0.13) | **crm** | single version (v1: `$reason+`, `$pv+`) | `$pv`; else 9 (surface cannot predate 0.13). Reachable only behind the positive `core.contact.removal` cap (or the caps-silent `pv >= 9` fallback). Payload carries NO target id — the removed party is the channel-authenticated envelope `$from`, so the surface cannot be aimed at a third party |
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

## Bilateral contact removal (core 0.13) — capability-gated, fail-closed

`remove_contact` now has a remote half: one new class-B transaction
`::a2a_messaging::receive_contact_removal` (`$reason+`, `$pv+`).

**Authorization is the envelope.** The payload deliberately carries **no target id**. The
receiver removes the channel-authenticated envelope `$from` and nothing else, so a peer can
only ever make me forget *it* — never a third party. `check_encrypted_or_abort` keeps the
notice on the established channel. This is what makes it a protocol operation rather than an
unauthenticated hint.

**Gate (sender side, receipts polarity — fail CLOSED):** emit iff self advertises
`core.contact.removal` **and** the peer positively advertises it in learned `contact_caps`;
a caps-**silent** peer with learned `contact_pv >= 9` also qualifies (the stale-caps
self-heal, since caps refresh only on invite/restore legs). A pre-0.13 client is therefore
never sent a transaction it cannot parse. The **receive** side is ungated and unconditional,
so a peer that declines to advertise still gets removed when *it* removes *me*.

**§5.6 control-leg carve-out, ROUTED — the notice is NOT exempt from the app-data
barrier.** `contact_removal_notice_actions` consults `e2e_route` exactly as `send_message`
does: an **epoch-pinned (migrated)** peer is told over the **e2e session** (an inner
`$contact_removal` marker carried by `receive_e2e_message`, reusing the proven `$rekey_ping`
contentless-marker pattern — same envelope, same authenticated session, no new wire
surface); an unmigrated pair uses the plain `crm` transaction; and `downgrade_refused` /
`migrating` send **nothing at all** (`$notified` FALSE, local removal still proceeds — an
un-notified removal is honest, a downgraded one is not).

**Receive-side §5.7 refusal.** A **legacy** `crm` from an **epoch-pinned** contact is a
downgrade attempt and is refused: nothing is purged, no pin is touched, and a
`$downgrade_refused` notify (`$context -> $contact_removal`) is surfaced. It is a
`transaction::success`, not an abort — a hostile sender must not learn more from a failure
than from a success. Both halves must agree: routing emission to e2e without this barrier
(or vice-versa) would leave exactly the hole it closes.

**Bound control plane — atomic inbound transition.** The outbound trn still **refuses** to
remove the bound CP (pre-existing behaviour, retained). Inbound cannot refuse the same way —
the CP has already dropped us, so staying bound would keep monitoring copies addressed to a
peer that is no longer a contact. So an authenticated `crm` **from the bound CP** clears the
binding via `do_disable_monitoring` **first, in the same transaction**, before the purge.
The reason no copy can follow is direct: `monitor_copy_actions` returns `[]` when
`monitoring_proxy == NIL`. It is **not** "a later send would otherwise abort" — copy
emission is a separate queued action and the success of a send says nothing reliable about
it. The regression asserts the binding is cleared and that no copy reaches the removed CP.
This grants the CP no new power (the notice is authenticated as coming from that CP, and
`disable_monitoring` is already CP-only) and leaves a recoverable state rather than an
unrecoverable one. Both inbound routes funnel through one `apply_peer_removal_actions`, so
this guard and the pin policy cannot drift between the legacy and e2e surfaces.

**Delivery is best-effort and is NOT retried.** The notice is fire-and-forget over the relay,
and unlike ordinary traffic it cannot be redriven — the redrive buffer is keyed by contact
and the contact is gone. `remove_contact` returns `$notified` (a notice was *queued*, not
acknowledged) and `$key_material_retained`; consumers MUST NOT render either as "the peer
removed you". Local removal always succeeds regardless.

**Idempotent / replay-safe by construction:** the operation is "ensure this sender is
absent". Duplicates, replays, and notices from a non-contact all converge on the same state
and return success, so no replay ledger exists. A crossed removal is two no-ops.

**Scope of the purge — contact-layer state, queued plaintext, and the peer's E2E sessions.**
`purge_contact_state(cid)` names every store literally — deliberately NOT derived from a
`contacts` keep-list, which would also delete peers legitimately mid-handshake (pending
redemptions, in-flight restores, FSM entries for a not-yet-registered contact). It clears
contact/AD/caps/pv state, the restore stores, the plaintext queues (`deferred_msgs`,
`unacked_e2e`, `mig_deferred`), `delivered_wire`, `contact_origin`, the transient
`contact_migration` FSM entry, and — via `e2e::forget_peer` in the same transaction — the
peer's live Olm session and any staged rotation.

**The anti-downgrade pins are RETAINED** — `contact_e2e_seen`, `contact_e2e_epoch`,
`contact_born_dr`. They are irreversible, monotone evidence that this cid once proved it
speaks e2e, and removal is **peer-triggerable**: clearing them on the inbound path would let
a peer that can reach the legacy channel erase the very evidence that forbids the legacy
channel. An earlier revision cleared them, justified by "retaining them bricks a re-add
(epoch-pinned with no live session ⇒ `downgrade_refused` forever)". **That justification is
false and is retracted:** `e2e_route`'s epoch branch is
`if peer_has_e2e_bundle cid { return "e2e". } return "downgrade_refused".`, and
`peer_has_e2e_bundle` reads `peer_ads[cid]`, which a re-add restores from the fresh
handshake AD — so a re-added v2 peer routes `"e2e"` with the pin intact. `downgrade_refused`
fires only for a peer presenting no e2e bundle, which is exactly when refusing is correct.
There is no brick, so there was never anything to trade the pins for.

**Consequence for room-close:** the primitive is factored out so a future room-close can call
it per participant (that caller does not exist yet), but what it guarantees is removal of
contact-layer state and queued plaintext — **not** the absence of cryptographic residue.

**Former known residual — now closed:** the adapt `e2e` library grew `forget_peer(cid)`
(deletes both the live session and the staged rotation, idempotent, exposes no session
material), and `purge_contact_state` calls it in the same state transaction as the contact
deletion, so a removed peer's Olm ratchet no longer survives in packet state or in the
exported `$e2e_sessions`. The removal result keeps the `$key_material_retained` field for
shape compatibility; it now reports FALSE. Requires an adapt toolkit with `e2e::forget_peer`
(the toolchain pin covers this). Sessions orphaned by removals that predate this fix are not
swept at runtime — that is a one-time reconciliation over persisted state, deferred to the
deployment phase (backup + dry-run against real state first).

## Invite modes (core 0.13) — class-A, default-preserving

`invite_eph_t` gains a nullable `$m` (mode). Class-A by taxonomy: an older decoder ignores the
extra member, a newer decoder reads a missing one as NIL. `$iv` is **not** bumped — neither
direction needs to know the peer's version to interoperate.

- `invite_mode_t = <$one_time, $public>` is a closed ADAPT enum; the symbolic enum value is
  used consistently on the wire, in state, and at the transaction API.
- `$one_time` is the historical behaviour and the **default** for an absent mode, on the
  wire and in state. Every existing caller keeps minting exactly what it minted before.
- `$public` is reusable; leg 2 does not consume `pending_invites` /
  `pending_invite_keys`.

An unknown present mode is rejected by the enum type boundary. It is never interpreted as
`$public`; only the compatibility absence (`NIL`) defaults to `$one_time`.

**The wire `$m` is advisory.** The mode that decides consumption is the one in the
**inviter's own** `pending_invite_t.$mode`, so a redeemer cannot promote a one-time invite by
editing its copy.

**Why reuse does not share secrets.** What is retained is the *inviter's* ephemeral keypair,
used only to OPEN leg-1 boxes addressed to it. Each redeemer boxes with its own fresh
ephemeral, so redeemer B cannot open redeemer A's leg 1; leg 3 already mints a fresh inviter
ephemeral per redemption; all resulting session state is cid-keyed. A public invite is many
independent two-party handshakes that happen to start from one published pubkey.

**Replay:** for a public invite a replayed leg 1 from the same authenticated sender
re-registers that sender — idempotent, and semantically what the mode means. It also means
re-redemption can re-add a previously removed peer. `revoke_invite` is the control, which is
why it ships with the mode rather than after it.

**Known limitation:** `import_core_state` still resets `pending_invites` to empty, so a public
invite does not survive a daemon restart and must be re-published. The blocker is INV-4 — the
invite's ephemeral private key cannot ride the export blob. Making a public invite genuinely
perpetual requires either a local-only secret sidecar the host re-injects at boot, or a
secret-free public leg 1; that is an owner-level security decision and is deliberately not
taken here. `generate_invite` and the MCP tool text state the limitation rather than implying
durability the code does not provide.

**Provenance:** `contact_origin` (cid → `$via`/`$invite_id`/`$at`, exported additively,
readable via `list_contact_origins`) records how each contact was admitted, so a future trust
level can mark public-invite entrants. Nothing in this core reads it; the trust UI/policy is
deliberately not implemented.

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
