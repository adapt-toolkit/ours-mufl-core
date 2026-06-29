# Ephemeral-Key Slim Invite — Implementation Plan (core 3.0)

> **Replace the fat, identity-bearing invite with a slim one carrying only an
> ephemeral encryption pubkey + the inviter's container_id + a name. Both parties'
> address documents (and, for roles, the delegation chain) are exchanged over a
> two-message encrypted hop instead of riding in the invite.** Dramatically smaller
> invites; the root cert / root profile never appear in the invite. This plan covers
> ONLY the shared mufl core change. Daemon / consumer / messenger integration and
> release-note prose are later phases.

**Status:** DESIGN — approved in shape by user 2026-06-20. Do **not** implement yet.

---

## 0. Decisions locked by the user (2026-06-20)

1. **Address in the invite = the inviter's `container_id`.** It is *not* key-derived
   today; key-derivation is planned later. We use `container_id` as-is now. The
   strength of the receiver's identity pin tracks that future work — this redesign
   neither improves nor regresses it (today's `add_contact`/`accept_contact` already
   pin on `container_id` the same way; see §6).
2. **Do NOT touch `encrypted_channel` (stdlib).** The eph keypair is generated in
   `a2a_messaging` with the raw `_crypto_*` primitives. The peer's AD is delivered
   one-shot, boxed to the eph key. Once the inviter runs `process_address_document`
   on the responder's AD, the responder is registered, so the reply (leg 3) and all
   future traffic ride the **existing** `encrypted_channel` unchanged.
3. **The inviter stores per-invite state anyway** (it already tracks `pending_invites`),
   so persisting the eph private key per outstanding invite is acceptable — with the
   secrecy guardrail in §4 (eph privkeys live in a **non-exported** state field).

---

## 0b. CORRECTION — leg-3 mechanism (empirical, during M2, 2026-06-20)

**The M0 spike's leg-3 conclusion is REVERSED.** `encrypted_channel` is NOT viable for leg-3:
`send_encrypted_tx` from the inviter to the responder fails RECEIVER-SIDE with
`"Unknown source key for message decryption"` (`key_storage.mm:291`) — the transport decrypt looks
up the SENDER (inviter) key by id, but the responder has not registered the inviter yet (it learns
the inviter only inside leg-3's payload). M0 Q1 validated only the inviter-side `is_container_registered`
gate, never the responder decrypting; the `"Unknown source key"` rejection the spike logged on node B
and dismissed as benign WAS the signal.

**Leg-3 is now BOXED (symmetric to leg-1)** — the only mechanism viable with the available primitives:
- The responder KEEPS its leg-1 ephemeral PRIVATE key in a NEW hidden, non-exported store
  `pending_redemption_keys` (same INV-4 treatment as `pending_invite_keys`).
- Leg-2 sends leg-3 as a BARE boxed send: a FRESH inviter ephemeral; box `{inviter_ad, cert?,
  root_profile?, cp_binding?}` to the RESPONDER's eph pub (the `$epk` carried in leg-1); ship the
  fresh inviter eph pub in cleartext.
- The leg-3 handler DROPS `check_encrypted_or_abort` and decrypts with the kept responder eph priv +
  the inviter eph pub from the envelope. All gates unchanged (pend lookup → inviter-cid pin →
  cid-bind → `process_address_document` PoP → chain; INV-5 preserved).
- The earlier §5.3 fallback ("box to the responder's REAL key") is ALSO wrong — the stdlib never
  exposes a raw long-term encryption privkey (§2 fact 3), so leg-3 must box to the EPH key.

**Consequences:** restart-transience now covers BOTH eph stores (`pending_invite_keys` AND
`pending_redemption_keys`), both excluded from `export_core_state`. `encrypted_channel` is unchanged
and resumes for ALL post-contact `send_message` traffic (after leg-3 both sides have registered each
other via `process_address_document`). **Supersedes the leg-3 mechanism in §2, §5.3, §5.4 below.**

---

## 1. What exists today (core 2.17 — being replaced)

- **Fat invite shapes** (`a2a_protocol.mm`):
  - `invite_t` (L27): `invite_id`, `name`, `container_id`, **full public key list**, **self-signatures**.
  - `invite_role_t` (L75): all of the above **plus** `delegation_cert`, **`root_profile`**
    (which embeds *the root's entire key list* + name + bio, L48), plus optional `root_cp_binding`.
    The root key list is the heavy part — exactly the bulk this change removes.
- **Mint** (`a2a_messaging.mm`): `mint_invite` (L467) builds the blob and registers
  `pending_invites[invite_id] = assigned_name`; shared by `generate_invite` (L503) and the
  cluster child-invite path (a2a_cluster relays the blob **opaquely** — it never parses it).
- **Redeem** (`add_contact`, L520): rebuilds the inviter AD from the carried keys
  (`rebuild_peer_address_document`), verifies self-sigs + delegation chain **offline from
  the invite**, stores `peer_ads`, then rides `encrypted_channel::execute_transaction` (L606)
  — a full ECDH handshake (≈3 legs) — to deliver `accept_contact`.
- **Accept** (`handle_accept_contact`, L1169): cid-binds the joiner AD to the channel sender
  (`joiner_ad.container_id == sender_id`), runs `process_address_document(ad, TRUE)` (PoP
  self-sig enforcement — the linchpin), verifies the joiner's chain, registers, consumes the
  invite (`delete pending_invites`).
- **State**: `pending_invites is (global_id ->> str)` (L75), **exported** in
  `export_core_state` and imported `safe (global_id ->> str)`.

Net today: invite is a *standing identity-disclosure token* (anyone who sees it gets the
inviter's keys, and for roles the whole root profile + org chain), and redemption costs
≈4 wire messages (ECDH handshake + accept).

---

## 2. Target flow (slim invite + 2-message exchange)

Roles: **Inviter** = generates the invite. **Responder** = redeems it.

```
  (OOB)  Inviter ──► Responder : slim invite { invite_id, inviter_cid, inviter_name,
                                               eph_pub_inviter, scheme }

  leg 1  Responder ──► Inviter : submit_invite_response (BARE send, NOT encrypted transport)
            { invite_id, eph_pub_responder, scheme,
              data = box(eph_priv_responder, eph_pub_inviter,
                         _write{ responder_AD, cert?, root_profile?, cp_binding?, invite_id }) }

  leg 3  Inviter ──► Responder : complete_invite (via encrypted_channel — responder now registered)
            { invite_id, inviter_AD, cert?, root_profile?, cp_binding? }
```

After leg 3, **both** sides hold the other's verified AD + contact + (optional) root linkage,
symmetric to today's end state. Subsequent `send_message` uses `encrypted_channel` normally.

**Wire cost: 1 OOB + 2 on-wire messages** — fewer than today's ≈4. The "extra step" the user
described is conceptual (the inviter must now actively send its AD back); on the wire this is
*cheaper*, not more expensive.

**Why a responder eph keypair is MANDATORY (not a design choice) — three facts stack:**
1. At leg 1 the responder does NOT hold the inviter's AD / default encryption key — the slim
   invite carries only an *ephemeral* pubkey (the whole size saving). So "encrypt with the
   counterparty's AD default key" is unavailable here; the inviter's real key arrives on leg 3.
2. The only primitive is a **two-key ECDH box** — `_crypto_encrypt_message(my_priv, their_pub, msg)`;
   to open it the inviter computes `box(eph_priv_inviter, responder_pub)`, so the responder's
   matching pubkey MUST travel in cleartext beside the ciphertext (the `authorize_packet` idiom,
   `encrypted_channel.mm:118-124`).
3. The responder cannot use its OWN long-term encryption key for that box: `_crypto_encrypt_message`
   needs a **raw private key**, and the stdlib never exposes your long-term encryption privkey as a
   raw value. `key_storage::default_encrypt` (`key_storage.mm:273`) keeps it internal AND only
   targets an *already-registered* recipient container (`:276` aborts otherwise) — it cannot encrypt
   to a bare ephemeral pubkey. The only raw privkey `a2a_messaging` can obtain is from
   `_crypto_construct_encryption_keypair` → a fresh ephemeral.

So the responder generates one fresh ephemeral keypair, ships `eph_pub_responder` in cleartext, and
discards it after the hop. Bonus: forward secrecy for the leg-1 "who is connecting" metadata.
**Everything from leg 3 onward is the unchanged current scheme** (inviter has the responder
registered → replies with its AD over `encrypted_channel` → responder `process_address_document`s
it). The only inherent change vs today: **disclosure order flips — the responder discloses first**
(to flip it, the inviter would have to encrypt to the responder before knowing any responder key,
which is impossible; moving the bulk off the OOB channel forces recipient-first).

---

## 3. Wire shapes (`a2a_protocol.mm`)

```
// Slim invite. Carries ONLY an ephemeral encryption pubkey, the inviter's
// routing/identity cid, a display name, and the crypto scheme id. No identity
// keys, no self-sigs, no cert, no root profile — those move to the encrypted hop.
metadef invite_eph_t: (
    $d -> global_id,            // invite_id (correlates leg-1 to the stored eph privkey; single-use)
    $c -> global_id,            // inviter container_id (routing target + identity pin)
    $n -> str,                  // inviter display name (metadata only)
    $k -> publickey_encrypt,    // eph_pub_inviter
    $v -> int                   // crypto scheme id (_crypto_default_scheme_id at mint time)
).
```

Leg-1 and leg-3 transaction payloads are passed as `any` (like `accept_contact` today) for
forward-compat; documented inner shapes:

```
// Cleartext envelope of leg 1 (the AD etc. live inside `data`, boxed).
//   { $invite_id -> global_id, $epk -> publickey_encrypt /*responder eph pub*/,
//     $v -> int /*scheme*/, $data -> crypto_message }
// Decrypted `data` payload (and the leg-3 cleartext payload) share this identity bundle:
//   { $ad -> t_address_document, $cert -> bin+, $root_profile -> bin+,
//     $cp_binding -> bin+, $invite_id -> global_id }
```

Legacy `invite_t` / `invite_role_t` and `rebuild_peer_address_document`: see §7 (versioning).

---

## 4. State changes (`a2a_messaging.mm`)

1. **`pending_invites` gains structure.** From `(global_id ->> str)` to a record map:
   ```
   metadef pending_invite_t: ($assigned -> str, $eph_pub -> publickey_encrypt, $scheme -> int).
   pending_invites is (global_id ->> pending_invite_t) = (,).
   ```
   (Keep `$assigned` = the existing empty-string "no assigned name" sentinel.)

2. **NEW non-exported secret store** for eph private keys:
   ```
   hidden { pending_invite_keys is (global_id ->> secretkey_encrypt) = (,). }   // invite_id -> eph_priv
   ```
   **Excluded from `export_core_state`** so the export blob never carries secrets. Consequence:
   invites outstanding at export time become unredeemable after import — acceptable (invites are
   transient). Document this in the 3.0 note. (`pending_invite_keys` is also where single-use
   consumption deletes the secret.)

3. **NEW responder-side pending-redemption store** (no secrets):
   ```
   metadef pending_redemption_t: ($inviter_cid -> global_id, $custom_name -> str).
   pending_redemptions is (global_id ->> pending_redemption_t) = (,).   // invite_id -> who I'm redeeming
   ```
   Needed so leg-3 (`complete_invite`) knows the chosen contact name + expected inviter cid.
   May be omitted from export (transient) or exported (no secrets) — pick in §10.

4. **`import_core_state` migration.** Old blobs have `pending_invites : (global_id ->> str)`.
   On import, if the value matches the old str-map shape, drop it (or wrap each into a
   `pending_invite_t` with NIL eph material → unredeemable, same outcome). Simplest: treat
   `pending_invites` as optional and reset to empty on a shape mismatch. New stores default empty.

---

## 5. Transaction-by-transaction spec (`a2a_messaging.mm`)

New tx-name consts (mirror L42-43):
```
submit_invite_response_tx = "::actor::submit_invite_response".
complete_invite_tx        = "::actor::complete_invite".
```

### 5.1 `mint_invite` → `mint_eph_invite (assigned: str)` (replaces L467)
- `scheme = _crypto_default_scheme_id()`.
- `kp = _crypto_construct_encryption_keypair scheme`.
- `invite_id = _new_id "ours invite"`.
- `pending_invites invite_id -> ($assigned -> assigned, $eph_pub -> kp $public_key, $scheme -> scheme)`.
- `pending_invite_keys invite_id -> kp $secret_key`.  *(secret store)*
- `my_ad = get_my_address_document()`.
- Build `invite_eph_t = ($d -> invite_id, $c -> (my_ad $identity $container_id), $n -> my_name, $k -> kp $public_key, $v -> scheme)`.
- Return `($blob -> _write invite_eph_t, $invite_id -> invite_id)`. **Caller emits `_save_state`.**
- No role branch — roles emit the same slim shape (the cert/root_profile move to leg 3).

`generate_invite` (L503) unchanged in signature; just calls `mint_eph_invite`. The cluster
child-invite path is unaffected (it relays the opaque blob).

### 5.2 `add_contact` → responder leg 1 (rework L520)
Keep the trn name `add_contact` (or rename to `redeem_invite`; decide in §10). Body:
- `validate_origin_or_abort(user)`.
- Parse `invite_eph_t`: `invite_id`, `inviter_cid`, `inviter_name`, `eph_pub_inviter`, `scheme`.
- `abort "This invite is your own." when inviter_cid == _get_container_id()`.
- `kpr = _crypto_construct_encryption_keypair scheme` (responder ephemeral).
- Assemble identity bundle:
  ```
  cert_blob, rp_blob, rpb_blob = (my role material, as today's add_contact L570-578)
  payload = _write ($ad -> my_ad, $cert -> cert_blob, $root_profile -> rp_blob,
                    $cp_binding -> rpb_blob, $invite_id -> invite_id).
  data = _crypto_encrypt_message (kpr $secret_key) eph_pub_inviter payload.
  ```
- `contact_name = (custom_name == NIL ?? "" ; custom_name?)`; store
  `pending_redemptions invite_id -> ($inviter_cid -> inviter_cid, $custom_name -> contact_name)`.
- Emit a **bare** send (NOT `send_encrypted_tx` — the inviter is not yet registered; raw
  `transaction::action::send` to an unregistered target is the established pattern, cf.
  `encrypted_channel.mm:73`):
  ```
  transaction::action::send inviter_cid
    ($name -> submit_invite_response_tx,
     $targ -> ($invite_id -> invite_id, $epk -> (kpr $public_key), $v -> scheme, $data -> data))
  ```
- `_return_data` (pending status — the contact is not final until leg 3) + `_save_state NIL`.
- Discard `kpr` (one-shot; not stored).

### 5.3 `submit_invite_response` → inviter leg 2 (NEW inbound)
`trn submit_invite_response args: any` → `handle_submit_invite_response`:
- `validate_origin_or_abort(external)`. **Do NOT `check_encrypted_or_abort`** — leg 1 is a bare
  transport carrying a box; confidentiality/integrity come from the box, authenticity from the
  cid-bind + PoP below. (Reviewer note: this is the one inbound that intentionally skips the
  encryption check; the box is the protection.)
- `sender_id = get_external_envelope_or_abort() $from`.
- `invite_id = (args $invite_id) safe global_id`.
- **Single-use gate:** `rec = pending_invites invite_id`; `abort "Unknown or already-redeemed invite." when rec == NIL`.
- `eph_priv = pending_invite_keys invite_id`; `abort when eph_priv == NIL`.
- `epk_r = (args $epk) safe publickey_encrypt`; `ct = (args $data) safe crypto_message`.
- `payload = _read_or_abort << _crypto_decrypt_message eph_priv epk_r ct` (aborts on tamper / wrong key).
- `responder_ad = (payload $ad) safe t_address_document`.
- **D8 cid-bind:** `abort "Address document does not belong to the sender." when (responder_ad $identity $container_id) != sender_id`.
- `process_address_document responder_ad TRUE` — PoP self-sig enforcement; **registers the responder**.
- Optional chain: if `(payload $cert) != NIL` → `verify_peer_delegation` + pin `cp_binding`
  (reuse the exact logic from today's `handle_accept_contact` L1191-1207).
- Register: `contacts[sender_id]`, `peer_ads[sender_id] = responder_ad`, `contact_roots` if any.
  Name = `rec $assigned` if non-empty, else the responder's self-name / cid (today's L1181-1186 rule).
- **Consume:** `delete pending_invites invite_id`; `delete pending_invite_keys invite_id`.
- **Reply leg 3 over `encrypted_channel`** (responder now registered, per decision #2):
  ```
  encrypted_channel::send_encrypted_tx sender_id
    ($name -> complete_invite_tx,
     $targ -> ($invite_id -> invite_id, $ad -> my_ad,
               $cert -> my_cert_blob, $root_profile -> my_rp_blob, $cp_binding -> my_rpb_blob))
  ```
  (my_* role material exactly as `add_contact` builds today, L570-578.)
- `_notify_agent contact_accepted` + `_save_state NIL`.

> **⚠ M1 spike — intra-transaction registration visibility.** This handler calls
> `process_address_document` (registers the responder) and then `send_encrypted_tx`
> (asserts `is_container_registered`) **in the same transaction**. The stdlib handshake does
> these across a continuation boundary (`encrypted_channel.mm:103-106`), so we must confirm the
> registration is visible *within the same tx*. **Validate this first.** If it does NOT hold,
> fallback: make leg 3 a **bare boxed send** too — encrypt `inviter_AD` to the responder's real
> encryption pubkey (now known from `responder_ad`) with a fresh inviter ephemeral, mirroring
> leg 1; `complete_invite` then decrypts with the responder's real key. (User preference is the
> `encrypted_channel` path; the fallback is only if the spike fails.)

### 5.4 `complete_invite` → responder leg 3 (NEW inbound)
`trn complete_invite args: any` → `handle_complete_invite`:
- `validate_origin_or_abort(external)`; `check_encrypted_or_abort()` (this leg IS via the channel).
- `sender_id = get_external_envelope_or_abort() $from`.
- `invite_id = (args $invite_id) safe global_id`.
- `pend = pending_redemptions invite_id`; `abort "Unsolicited completion." when pend == NIL`.
- `abort "Completion from unexpected inviter." when sender_id != pend $inviter_cid`.
- `inviter_ad = (args $ad) safe t_address_document`.
- **cid-bind:** `abort when (inviter_ad $identity $container_id) != sender_id`.
- `process_address_document inviter_ad TRUE`.
- Optional chain: `verify_peer_delegation` + pin `cp_binding` (same reuse).
- Register: `contacts[sender_id]` under `pend $custom_name` (or the inviter's self-name `args.../`
  invite name when empty), `peer_ads[sender_id] = inviter_ad`, `contact_roots` if any.
- `delete pending_redemptions invite_id`.
- `_notify_agent ($event -> $contact_added, ...)` + `_save_state NIL`.

---

## 6. Security analysis & invariants (critic will enforce)

**Properties preserved (vs today):**
- **Identity pin = OOB-delivered `container_id`.** Both leg 2 and leg 3 enforce
  `received_AD.container_id == envelope.$from` AND `process_address_document(ad, TRUE)`
  (PoP self-sig — see [[process-address-document-semantics]]). Identical to today's
  `handle_accept_contact` gate. Pin strength tracks the (planned) `container_id` key-derivation;
  not regressed.
- **Single-use redemption.** `pending_invites[invite_id]` + `pending_invite_keys[invite_id]`
  consumed on first valid leg 2 — same anti-multi-use role as today's `pending_invites` gate.
- **Delegation chain verification** unchanged (`verify_peer_delegation`, `verify_root_cp_binding`);
  only its transport moves (invite → encrypted hop). "No chain ⇒ treat as flat/root" stays the
  structural default — no downgrade.
- **MITM exposure unchanged** — both designs are TOFU rooted in the OOB invite channel; an active
  OOB attacker can substitute the whole invite in either design, and the defense is the same
  (verify the cid you ended up pinned to, out of band).

**Improvements:**
- **Privacy / reduced disclosure.** An intercepted invite leaks only `{eph_pub, cid, name}` —
  no keys, no `root_profile`, no org chain. Today's invite leaks the inviter's full identity (and
  for roles the entire root profile + delegation chain) to anyone who sees it. The identity bundle
  now travels only inside a box, to a party that has proven liveness.
- **Leaked-invite blast radius shrinks.** A leaked slim invite forces an attacker to actively
  round-trip (revealing its own cid) and is single-use; a leaked fat invite is passive total
  identity exposure.

**New risks (accepted / mitigated):**
- **Eph privkey at rest** (`pending_invite_keys`) per outstanding invite — weaker forward secrecy
  for the leg-1 payload than the truly-ephemeral handshake keys. Mitigations: kept in a
  **non-exported** hidden field (§4.2); single-use delete; **add an expiry/TTL sweep** (decision §10).
- **Leg 1 is an unauthenticated bare inbound.** Anyone holding the (leaked) invite can spam
  `submit_invite_response`, each forcing a decrypt attempt. Bounded DoS: aborts cheaply on the
  `pending_invites` lookup / box-open / cid-bind, and the first valid one consumes the invite.
  Note in the threat model; no state is mutated before the gates pass.
- **Disclosure order flips** — the responder reveals its identity first (boxed to an
  unauthenticated eph key) before learning the inviter's verified identity in leg 3. Neutral under
  OOB-trust; the responder can `abort`/discard at leg 3 if the inviter cid mismatches, but has by
  then disclosed to whoever held `eph_priv`. Acceptable; document it.
- **No hand-rolled handshake.** We use only one-shot `_crypto_encrypt_message`/`decrypt` (the
  established `authorize_packet` idiom) — there is no interactive multi-leg key agreement to get
  wrong. `encrypted_channel` is untouched (decision #2).

**Hard invariants (do not break):**
- Every inbound AD is cid-bound to `envelope.$from` **and** `process_address_document(ad, TRUE)`'d
  before it is stored or trusted.
- `pending_invite_keys` is NEVER included in `export_core_state`.
- The invite is consumed (both stores) exactly once, on the first valid leg 2.
- Leg 1 must not mutate persistent contact state before all gates (lookup → decrypt → cid-bind →
  PoP) pass.

---

## 7. Backward compatibility & versioning

This is a **breaking** invite-format + flow change → **`version.mm` 2.17 → 3.0 (MAJOR)**.

Options for the legacy `invite_t`/`invite_role_t` redemption path:
- **(A) Clean break (recommended).** Remove `invite_t`, `invite_role_t`,
  `rebuild_peer_address_document`, and the old `add_contact` body. Invites are short-lived
  artifacts, consumers pin/lag core versions and re-issue invites on upgrade, and dual flows
  double the security-critical surface. The 3.0 note states old invites are not redeemable.
- **(B) Transitional dual-redeem.** Keep the legacy metadefs + `rebuild_peer_address_document`;
  in `add_contact`, sniff the blob (e.g. `$k` is a single `publickey_encrypt` for slim vs a key
  list for legacy, or a format/version discriminator field) and branch to the old path. More
  code, more risk; only if a live deployment must redeem outstanding fat invites across the bump.

Recommend **(A)** unless a concrete outstanding-invite migration need surfaces.

---

## 8. Work breakdown (core mufl only)

| # | File | Change | Size |
|---|------|--------|------|
| 1 | `a2a_protocol.mm` | Add `invite_eph_t`; document leg-1/leg-3 payload shapes. Per §7: remove or retain legacy `invite_t`/`invite_role_t` + `rebuild_peer_address_document`. | S |
| 2 | `a2a_messaging.mm` | State: `pending_invites` → `(global_id ->> pending_invite_t)`; add hidden non-exported `pending_invite_keys`; add `pending_redemptions`. | S |
| 3 | `a2a_messaging.mm` | `mint_invite` → `mint_eph_invite` (§5.1). `generate_invite` rewires to it. | S |
| 4 | `a2a_messaging.mm` | Rework `add_contact`/`redeem_invite` → responder leg 1 (§5.2). | M |
| 5 | `a2a_messaging.mm` | New `submit_invite_response` + `handle_*` → inviter leg 2 (§5.3), incl. the M1 spike. | M |
| 6 | `a2a_messaging.mm` | New `complete_invite` + `handle_*` → responder leg 3 (§5.4). | M |
| 7 | `a2a_messaging.mm` | New tx-name consts; `export_core_state` (ensure NO eph secrets); `import_core_state` migration (§4.4). | S |
| 8 | `version.mm` | `create_version 2 17` → `create_version 3 0` (MAJOR). | XS |
| 9 | `release-notes/3.0.md` | New note per the existing release-notes convention (header + shipped txns + breaking-change + security notes). | S |
| 10 | (compile) | Clean compile against the ADAPT toolkit; no consumer wiring (see [[qa-toolchain-mufl-core]]). | — |

`a2a_cluster.mm`: **no change** — it relays the invite blob opaquely (host runs `generate_invite`
in the child packet; `register_child_invite` forwards an opaque bin). Confirm during review.

---

## 9. Test plan (core-level, loopback per [[qa-toolchain-mufl-core]])

1. **Compile** clean; `get_version` → 3.0.
2. **Slim invite shape** — `generate_invite` blob parses as `invite_eph_t`; carries no key list,
   no cert, no root_profile; size << a legacy role invite (assert byte-length drop).
3. **M1 spike (do first)** — confirm `process_address_document` registration is visible to
   `send_encrypted_tx` within the same tx (leg 2). If not, switch leg 3 to the boxed fallback (§5.3).
4. **Happy path (flat)** — inviter `generate_invite` → responder leg 1 → leg 2 registers responder +
   replies → leg 3 registers inviter. Both `list_contacts` show the other; `peer_ads` populated both
   ways; subsequent `send_message` round-trips.
5. **Happy path (role)** — inviter and/or responder are delegated roles; chains verify on the
   encrypted hop; `contact_roots` + `contact_cp_bindings` pinned both directions.
6. **Single-use** — a second leg 1 for the same `invite_id` aborts ("already-redeemed").
7. **Tamper** — corrupted `data` (box) aborts at decrypt; wrong `epk` aborts; no contact written.
8. **cid-bind** — leg-1 AD whose `container_id != $from` aborts; leg-3 from a sender `!= inviter_cid`
   aborts.
9. **PoP** — forged/inconsistent AD aborts in `process_address_document` (both legs).
10. **Export secrecy** — `export_core_state` output contains NO eph private key; an outstanding
    invite does not survive export→import (documented behavior).
11. **DoS gate** — unsolicited `submit_invite_response` with an unknown `invite_id` aborts before
    any state mutation.

---

## 10. Open decisions

- **Legacy redemption: clean break (A) or transitional dual path (B)?** Recommend A. (§7)
- **Trn naming:** keep `add_contact` for the responder leg, or rename to `redeem_invite`
  (clearer now that it no longer "adds" synchronously — the contact finalizes at leg 3)?
- **Eph-key TTL:** add an expiry sweep for `pending_invites`/`pending_invite_keys` (bounds the
  at-rest-secret window and stale-invite growth)? Recommend yes; needs a time source + sweep hook.
- **`pending_redemptions` export:** export it (no secrets, lets a mid-flight redemption survive
  upgrade) or keep transient (simpler)? Minor.
- **Metadata in the invite:** name only (locked), or also a short inviter bio? User said name only.

---

## 10a. Rejected alternative — two-keypair "symmetric key" invite

**Idea (considered 2026-06-20):** mint two ephemeral keypairs A, B; ship `(pub_A, priv_B)` in the
invite, retain `priv_A`. Both sides derive the same ECDH shared secret `K` (`box(priv_B,pub_A) ==
box(priv_A,pub_B)`), so the responder encrypts leg 1 with `K` **without generating its own keypair
or shipping a cleartext pubkey**. Correct observation that this is just a **pre-shared symmetric
key** encoded through the two-key box API.

**Rejected — it converts the invite from a PUBLIC token into a SECRET-bearing one,** for marginal
gain (saves the responder one `_crypto_construct_encryption_keypair`):
- **OOB channel requirement upgrades** from *authentic-only* to *authentic AND confidential* — the
  invite now carries `priv_B`, and anyone who sees the invite derives `K`.
- **Metadata privacy lost** vs an attacker who sees the invite *and* the wire: they derive `K` and
  decrypt leg 1 (who connected to whom). The single-pubkey design keeps this private (decryption
  needs `priv_eph_inviter`, which never leaves the inviter).
- **Human-factors footgun:** users paste/screenshot/log invites; a public-key invite is safe to
  handle carelessly, a secret-bearing one is not.
- **Fixed-`K` nonce hygiene** is sharper than per-box fresh ephemerals.
- **No authentication benefit:** identity still rests entirely on `process_address_document` +
  `container_id` pin; `K` is transport-only, so this changes confidentiality, never auth.

Keep the single ephemeral **public** key in the invite (§3). The responder keygen it requires is
cheap and keeps the invite safe to handle as a non-secret.

## 11. Sequencing

- **M0 — M1 spike** (§9.3): intra-tx registration visibility → fixes the leg-3 mechanism.
- **M1 — Shapes + state + mint** (#1–#3, #8): compile.
- **M2 — Three legs** (#4–#6) + happy-path + single-use + tamper + cid-bind tests.
- **M3 — Export/import + migration** (#7) + export-secrecy test.
- **M4 — Release note** (#9) + critic review against §6 invariants.
