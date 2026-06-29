# Group Chat — Design (core 3.1)

> **A group is a shared `chat_id` + a creator-authoritative roster + the full mesh
> of mutual contacts it induces.** Joining a group makes members mutual contacts so
> a message is a bare N-way fan-out over the existing encrypted channels — no group
> key, no relay, no SPOF. v1 is invite-and-explicit-accept, owner-only disclosure,
> one-by-one add, with admin remove + self leave and a lost-message repair path.
> This design covers ONLY the shared mufl core change (a new `a2a_group` library +
> wire shapes + version bump + tests). Daemon / messenger / agent integration and
> release-note prose are later phases.

**Status:** DESIGN — approved in shape by the user 2026-06-21. Do **not** implement
yet (writing-plans produces `GROUP_CHAT_PLAN.md` next).

---

## 0. Decisions locked by the user (2026-06-21)

1. **Explicit accept only — no all-at-once.** A group starts empty; the creator
   invites existing contacts one at a time; each invitee explicitly accepts before
   any address documents change hands.
2. **Owner-only disclosure invite.** The join offer reveals only the group name and
   the owner (creator) — **not** the member list. (Resolves the "A sends B & C each
   other's ADs, then B declines" leak: a decliner discloses nothing, and no member
   AD is disclosed to a non-acceptor.)
3. **One-by-one add after accept.** On each acceptance the creator wires the new
   member into the mesh: it sends the joiner every existing member's AD and sends
   each existing member the joiner's AD.
4. **Creator/admin-only roster authority.** Only the creator adds/removes members
   and is the source of truth for the roster.
5. **add + remove + leave.** Removal (admin) propagates to all members and to the
   removed peer; self-leave propagates to all members. **Neither deletes the
   contact** — group membership is a layer *on top of* contacts ("you can add the
   contact though").
6. **Lost-removal repair: bounce + epoch/admin-resync** (not silent ignore). See §5.
7. **Explicit transactions** (one inbound per event), not a single dispatch inbound.
8. **Creator cannot leave; it `delete_group`s** (no admin succession in v1).

---

## 1. What exists today (the primitives we build on)

All in `a2a_messaging.mm` unless noted. Verified against the tree at core 3.0.

- **Contacts + peer ADs.** `contacts is (global_id ->> contact_t)` (L80) and
  `peer_ads is (global_id ->> t_address_document)` (L99). A peer is *registered*
  (its keys usable for an encrypted send) once its self-signed AD has been through
  `address_document::process_address_document(ad, TRUE)` — which enforces the
  self-signature / proof-of-possession and aborts on a forged document (see
  [[process-address-document-semantics]]). `resolve_contact(ref)` (L392) maps a
  display name / stringified cid to a cid.
- **1:1 messaging.** `send_message` (L631) rides `encrypted_channel::execute_transaction`
  + `send_encrypted_tx`; inbound `receive_message`/`handle_receive_message` (L1430)
  validates origin + `check_encrypted_or_abort`, resolves the sender, and delegates
  STORAGE to the app via the `on_message_received` hook (L197). The core does wire +
  validation + contact resolution; the app owns storage.
- **Bare N-way encrypted send (THE broadcast primitive).** `encrypted_channel::send_encrypted_tx`
  is a pure fn returning ONE send action; a single transaction can emit it to N
  different targets **bare** (no `execute_transaction`) as long as each target is
  `key_storage::is_container_registered` — true for every established contact in
  `peer_ads`. Live precedents: `monitor_copy_actions` (L255) and `emit_pair` (L1010).
  `execute_transaction` is ONLY for the lazy first-contact handshake and is not
  needed (or nestable) for multi-target. (Confirmed finding, [[connect-feature-redesign]].)
- **CP-brokered introduction (the trust model we must NOT reuse).** `introduce` /
  `introduce_to_group` (L1042 / L1064) send each party the other's signed AD via
  `ingest_connect_descriptor` (L1099). The receiver gate is
  `require_cluster_cp_or_abort(sender)` (L375) — it accepts a relayed AD ONLY from
  the node's bound/inherited **control plane**. A normal peer therefore *cannot*
  introduce its own contacts to each other. Group chat is the **peer/contact-gated**
  analogue and needs its own acceptance gate; the CP gate stays untouched (different
  trust model).
- **Forced monitoring.** `monitor_copy_actions(direction, peer_cid, date, body)`
  (L238) emits one re-encrypted copy of a message to the bound control plane,
  self-gating on the hidden `monitoring_proxy`. It is called UNCONDITIONALLY as core
  code from the send/recv chokepoints so the app cannot suppress it.
- **State export/import.** `export_core_state`/`import_core_state` (L1488 / L1510)
  are composed by each app's `export_state`/`import_state`; import replays every
  `peer_ad` through `process_address_document` so channels survive an upgrade.
- **Capabilities.** `a2a_capabilities::self_supports(cap)` (L219) reads the live
  manifest. `core.connect` / `core.cluster` are control-plane caps dispatched through
  the RR-9 authz chokepoint. **Group chat is user-driven peer messaging, not a
  control-plane capability** — so it lives in dedicated transactions (like
  `send_message`), NOT the `dispatch` path.

---

## 2. The model

```
            creator (admin, authority)
            /        |         \           every edge = a mutual contact
         memberA — memberB — memberC        (peer_ads both ways)
            \________|_________/
                  full mesh

  group = { chat_id, name, admin_cid, epoch, roster:{cids} }   (replicated to each member)
  message = bare send_encrypted_tx to every other roster member, tagged {chat_id, epoch}
```

- **Roster is a new state layer on top of contacts.** Membership references contact
  cids; the ADs themselves live in the shared `a2a_messaging::peer_ads`. Removing a
  member or leaving edits only the roster — it NEVER touches `contacts`/`peer_ads`.
- **Mesh, not star.** Because every member is every other member's contact, any
  member broadcasts directly (no creator relay → no single point of failure or
  surveillance). The creator's only special role is **roster authority** (who may
  add/remove); message flow is symmetric peer-to-peer.
- **New library `a2a_group.mm`.** Keeps the 1593-line `a2a_messaging` intact and
  gives group chat one clear responsibility, mirroring how `a2a_cluster` is its own
  library. It `loads` `a2a_messaging` (reuse `peer_ads`, `contacts`, `resolve_contact`,
  the monitoring copy), `encrypted_channel` (the bare send), `address_document(_types)`
  (PoP), `current_transaction_info` (origin/envelope), `a2a_protocol` (wire shapes),
  `version`.

---

## 3. v1 flow (create → invite → accept → one-by-one add → broadcast)

Roles: **Owner/admin** = the creator. **Invitee/joiner** = an existing contact of
the owner. Every hop below is over an **already-established** encrypted channel
(invitees are the owner's contacts; members are mutual contacts), so every send is a
bare `send_encrypted_tx` — no handshake.

```
  create   owner: create_group("trip")            -> mint chat_id; roster={owner}; epoch=0

  invite   owner ─► invitee : group_invite { chat_id, name, admin_cid=owner }   (owner only)
                                              ^ no members disclosed

  accept   invitee: respond_to_group_invite(chat_id, accept=true)
           invitee ─► owner : group_invite_response { chat_id, accepted=true }
           (decline ⇒ accepted=false; NOTHING else is sent, no AD disclosed)

  add      owner (on accept) bumps epoch, then:
           owner ─► joiner          : group_roster_sync { chat_id, members:[{ad,name}…], epoch }
           owner ─► each member M≠owner : group_member_add { chat_id, member_ad=joiner_ad, name, epoch }
           owner: roster += joiner

  joiner   on roster_sync: process_address_document each member AD (PoP) → register any
           new contact → roster := members → status=active.  Mesh complete for joiner.
  member   on member_add : PoP joiner AD → register joiner contact → roster += joiner.

  chat     any member: send_group_message(chat_id, "hi")
                       ─► bare send_encrypted_tx to every other roster member
                          group_message { chat_id, epoch, text, wire_id, reply_to? }
```

The owner already holds the joiner's AD (the joiner is its contact), so "add" relays
public material it possesses; the joiner's AD reaches other members **only after the
joiner accepts**. First invite: roster is just `{owner}`, so the joiner's `roster_sync`
carries only the owner's AD; subsequent invites carry the growing roster — the mesh
is built incrementally, one acceptance at a time.

---

## 4. Roster operations & authority

**Authority is pinned at join.** Each member stores `admin_cid` (learned from the
`group_invite`, equal to the inviter). All roster-mutating relays —
`group_member_add`, `group_member_remove`, `group_roster_sync` — are honored **only
when `sender == admin_cid`** for that `chat_id`. A non-admin can never alter another
node's roster.

| Op | Verb | Who | Effect | Propagation |
|----|------|-----|--------|-------------|
| Create | `create_group` | anyone | mint chat_id, roster={me}, admin=me | none (local) |
| Invite | `invite_to_group` | admin | offer, owner-only disclosure | → invitee |
| Accept/decline | `respond_to_group_invite` | invitee | accept ⇒ status `accepting` | → admin |
| Add | (admin handler on accept) | admin | wire joiner into mesh, `epoch++` | → joiner + all members |
| Remove | `remove_from_group` | admin | drop member, `epoch++`; **keep contact** | → all members + removed peer |
| Leave | `leave_group` | member (not admin) | drop group locally; **keep contacts** | → all members (self-assert) |
| Delete | `delete_group` | admin | disband | → all members |
| Resync | `request_group_roster` | member | repair (§5) | → admin → roster_sync back |

- **Leave / not-member are self-assertions.** They only ever remove the *sender*
  from a roster, so they are safely honored from any current roster member (no admin
  needed) — you can always evict yourself from others' view.
- **Creator exit = `delete_group`.** `leave_group` aborts for the admin (no
  succession in v1); the owner disbands instead.
- **Remove vs contact.** Removal and leave edit the roster only. `contacts`/`peer_ads`
  are untouched, so the ex-member remains a normal 1:1 contact (re-addable later).

---

## 5. Consistency & repair (lost removals/adds)

`epoch` is a per-group monotonic counter **bumped by the admin on every roster
change** and stamped on every group message. It is a **staleness hint, never a
security control** — authority is the admin pin (§4), so a forged epoch cannot mutate
a roster; at worst it triggers a harmless resync request to the real admin.

Receiver logic in `receive_group_message(chat_id, from=S, epoch=e)`:

1. **I am not a member of `chat_id`** (I left, was removed, or never joined) →
   reply `group_not_member { chat_id }` to S and drop the message. Self-assertion
   ("drop me"); S removes me from its roster. Loop-free (the reply is a distinct
   transaction, never itself a group message). *Heals: I'm out but S didn't get the
   removal/leave.*
2. **I am a member but S is not in my roster** → I must NOT evict S (admin-only).
   Reply `group_stale { chat_id, epoch=my_epoch }` and `request_group_roster` from
   the admin; drop the message. After the admin's `group_roster_sync` I either learn
   S is gone (stays dropped) or learn I missed S's add (S now accepted). *Heals both
   a missed remove and a missed add.*
3. **I am a member and S is in my roster** → accept: app `on_group_message_received`
   hook + forced monitoring copy. If `e > my_epoch`, also fire `request_group_roster`
   (async self-heal) but still deliver — S is a valid roster member.

Companion inbounds: `group_not_member` (drop the sender from my roster),
`group_stale` (if I'm behind, request a resync from the admin), and the admin-side
`receive_group_roster_request` (reply `group_roster_sync` if the requester is a
member, else `group_not_member`).

Net: removals/adds are **eventually consistent and self-healing over the existing
channels**, with the authoritative decision always routed back to the creator — no
signatures, no gossip protocol. Messaging never blocks on repair. (Hardening note:
rate-limit the `group_not_member` bounce per `(sender, chat_id)` to bound a hostile
peer; honest senders self-terminate because the bounce makes them drop the receiver.)

---

## 6. Wire shapes (`a2a_protocol.mm`)

Only the OOB-equivalent offer is a fixed metadef; per-event payloads ride as `any`
(forward-compat, exactly like `accept_contact` / `receive_message` today), with their
inner shapes documented.

```
// The join offer. Owner-only disclosure: name + owner cid, NO member list, NO ADs.
metadef group_invite_t: (
    $chat_id   -> global_id,   // the group id (minted by the owner via _new_id)
    $name      -> str,         // group display name (metadata only)
    $admin_cid -> global_id    // the owner/authority; the receiver PINS this
).

// Documented `any` payload shapes (carried as $targ on each inbound):
//   group_invite_response : { $chat_id -> global_id, $accepted -> bool }
//   group_member_add      : { $chat_id, $member_ad -> t_address_document, $name -> str, $epoch -> int }
//   group_roster_sync     : { $chat_id, $epoch -> int,
//                             $members -> ($member_view)[]  where
//                               $member_view = ($ad -> t_address_document, $name -> str) }
//   group_member_remove   : { $chat_id, $removed_cid -> global_id, $epoch -> int }
//   group_member_leave    : { $chat_id }
//   group_delete          : { $chat_id }
//   group_message         : { $chat_id, $epoch -> int, $text -> str,
//                             $wire_id -> str, $reply_to -> reply_ref_t+ }
//   group_not_member      : { $chat_id }                         // repair: "drop me"
//   group_stale           : { $chat_id, $epoch -> int }          // repair: epoch hint
//   request_group_roster  : { $chat_id, $epoch -> int }          // repair: pull roster
```

`reply_ref_t` (L101) is reused for in-group replies. All ADs travel as the native
`t_address_document` value (no key-list-only reconstruction — the AD is whole and
goes straight through `process_address_document`).

---

## 7. State (`a2a_group.mm`)

```
metadef group_member_t: ($cid -> global_id, $name -> str).   // display label; AD ∈ peer_ads
metadef group_t: (
    $chat_id   -> global_id,
    $name      -> str,
    $admin_cid -> global_id,                 // pinned authority for this group
    $epoch     -> int,                        // last roster epoch I know
    $status    -> str,                        // "active" | "invited" | "accepting"
    $members   -> (global_id ->> group_member_t)
).
groups is (global_id ->> group_t) = (,).      // keyed by chat_id

// Admin side: invitees I have offered but who have not yet accepted/declined.
// Keyed by chat_id then invitee cid. No secrets.
pending_group_invites is (global_id ->> (global_id ->> bool)) = (,).

// Monotonic chat_id/epoch helpers: chat_id via _new_id "ours group"; epoch is a
// plain int on group_t bumped by the admin (MUFL has no RNG; this is fine).
```

- **No secrets** in any group state → it exports cleanly. `groups` and
  `pending_group_invites` are exported via a new `export_group_state` /
  `import_group_state` (composed by the app's `export_state`/`import_state`, beside
  `export_core_state`). Import needs no special replay: `a2a_messaging::import_core_state`
  already re-registers every `peer_ad`, which is what the roster references.
- **Display names** in `group_member_t` are advisory; the only trusted identity is
  the AD self-signature already verified into `peer_ads`.

---

## 8. Transaction-by-transaction spec

New tx-name consts (library-routed — NEW surfaces, no legacy `::actor::` shims):

```
group_invite_tx          = "::a2a_group::receive_group_invite".
group_invite_response_tx = "::a2a_group::receive_group_invite_response".
group_member_add_tx      = "::a2a_group::receive_group_member_add".
group_roster_sync_tx     = "::a2a_group::receive_group_roster_sync".
group_member_remove_tx   = "::a2a_group::receive_group_member_remove".
group_member_leave_tx    = "::a2a_group::receive_group_member_leave".
group_delete_tx          = "::a2a_group::receive_group_delete".
group_message_tx         = "::a2a_group::receive_group_message".
group_not_member_tx      = "::a2a_group::receive_group_not_member".
group_stale_tx           = "::a2a_group::receive_group_stale".
request_group_roster_tx  = "::a2a_group::receive_group_roster_request".
```

### 8.1 User transactions (`origin::user`)

- **`create_group ($name)`** — `chat_id = _new_id "ours group"`;
  `groups[chat_id] = {name, admin_cid=me, epoch=0, status="active", members={me:{my_name}}}`.
  Return `chat_id`; `_save_state`.
- **`invite_to_group ($chat_id, $contact)`** — admin-gate (`groups[chat_id].admin_cid == me`,
  else abort); `invitee = resolve_contact contact` (must be an existing contact);
  abort if invitee already a member or already pending; `pending_group_invites[chat_id][invitee]=TRUE`;
  bare `send_encrypted_tx invitee {name: group_invite_tx, targ: group_invite_t}`. `_save_state`.
- **`respond_to_group_invite ($chat_id, $accept)`** — require `groups[chat_id].status=="invited"`.
  Accept → `status="accepting"`; send admin `{group_invite_response_tx, {chat_id, accepted:TRUE}}`.
  Decline → send `{accepted:FALSE}`; `delete groups[chat_id]`. `_save_state`.
- **`send_group_message ($chat_id, $text, $reply_to?)`** — require active membership;
  `wire_id`, `date` as in `send_message`; for each roster cid ≠ me emit a bare
  `send_encrypted_tx cid {group_message_tx, {chat_id, epoch, text, wire_id, reply_to}}`;
  append `on_group_message_sent` hook actions; append the FORCED group monitoring copy
  (§9); `_save_state`.
- **`remove_from_group ($chat_id, $member)`** — admin-gate; `m=resolve roster member`;
  `epoch++`; `delete members[m]`; broadcast `group_member_remove_tx{chat_id, removed_cid:m, epoch}`
  to every remaining member **and** to `m`. `_save_state`.
- **`leave_group ($chat_id)`** — require member; abort if I am the admin ("the owner
  disbands with delete_group"); broadcast `group_member_leave_tx{chat_id}` to all
  roster members; `delete groups[chat_id]`. `_save_state`.
- **`delete_group ($chat_id)`** — admin-gate; broadcast `group_delete_tx{chat_id}` to
  all members; `delete groups[chat_id]`. `_save_state`.
- **`request_group_roster ($chat_id)`** — send admin `{request_group_roster_tx,
  {chat_id, epoch}}`. (Also fired internally by the repair gates in §5.)
- **`readonly list_groups`** / **`readonly list_group_members ($chat_id)`**.

### 8.2 Inbound transactions (`origin::external`, `check_encrypted_or_abort`)

Each: `validate_origin_or_abort(external)` → `check_encrypted_or_abort()` →
`sender = envelope.$from`, then:

- **`receive_group_invite`** — parse `group_invite_t`; abort if `admin_cid != sender`
  (the inviter must claim itself as admin); store `groups[chat_id]={name, admin_cid:sender,
  epoch:0, status:"invited", members:{}}` (idempotent refresh if already invited);
  `_notify_agent($group_invited)`. (No contact added, no AD disclosed.)
- **`receive_group_invite_response`** (admin) — require I am admin + `sender ∈ pending[chat_id]`.
  **Accept** → `epoch++`; emit `group_roster_sync` to `sender` (every current member's
  AD+name) and `group_member_add{member_ad:peer_ads[sender]}` to each existing member
  ≠ me; `members[sender]={contacts[sender].name}`; clear pending; `_notify_agent($group_member_joined)`.
  **Decline** → clear pending; `_notify_agent($group_invite_declined)`. `_save_state`.
- **`receive_group_member_add`** — **admin-gate:** `groups[chat_id].admin_cid == sender`,
  status ∈ {active, accepting}. `process_address_document(member_ad, TRUE)`; if not a
  contact, register `contacts/peer_ads`; `members[member_cid]={name}`; `epoch=max(epoch,e)`;
  notify. (Contact-gated add atom: accepted because the relayer is my pinned admin.)
- **`receive_group_roster_sync`** — admin-gate; for each entry `process_address_document(ad,TRUE)`,
  register contact if new, set `members`; `epoch=e`; `status="active"`; notify. (Joiner
  finalize + repair.)
- **`receive_group_member_remove`** — admin-gate. If `removed_cid == me` → `delete groups[chat_id]`
  (keep contacts). Else `delete members[removed_cid]`; `epoch=max(epoch,e)`. Notify.
- **`receive_group_member_leave`** — require `sender ∈ members[chat_id]`; `delete members[sender]`
  (self-assertion, no admin needed, no epoch change). Notify.
- **`receive_group_delete`** — admin-gate; `delete groups[chat_id]`. Notify.
- **`receive_group_message`** — apply the §5 gates (not-member → bounce `group_not_member`;
  unknown-sender → `group_stale` + `request_group_roster`, drop; valid → `on_group_message_received`
  hook + forced monitoring copy + optional async resync if `e>epoch`).
- **`receive_group_not_member`** — if `sender ∈ members[chat_id]` → `delete members[sender]`. Save.
- **`receive_group_stale`** — if `e > my epoch` and I am not the admin → `request_group_roster`. Save.
- **`receive_group_roster_request`** (admin) — require I am admin; if `sender ∈ members`
  → reply `group_roster_sync` (full roster, epoch); else reply `group_not_member`.

---

## 9. Broadcast, storage & monitoring integration

- **Storage stays app-side.** Two new hooks on `a2a_group::init`, mirroring
  `a2a_messaging`: `on_group_message_received ($chat_id,$sender_id,$sender_name,$text,$date,$wire_id,$reply_to)`
  and `on_group_message_sent ($chat_id,$text,$date,$wire_id,$reply_to)`. The core does
  roster resolution + validation; the app threads history by `chat_id`. (Consumers
  also wire the group-event `_notify_agent` payloads into their UX.)
- **Forced monitoring for group traffic.** Group messages must not be a monitoring
  hole. Add `a2a_messaging::monitor_group_copy_actions (direction, chat_id, group_name,
  date, body)` — a sibling of `monitor_copy_actions` that reads the hidden
  `monitoring_proxy` (so it MUST live in `a2a_messaging`) and emits one re-encrypted
  copy tagged with group context. `monitoring_copy_t` gains an optional `$chat_id`
  (additive). `a2a_group` calls it unconditionally from `send_group_message` and
  `receive_group_message` — core code the app cannot suppress. The `a2a_monitoring`
  receiver passes the extra field through to its hook unchanged.

---

## 10. Security analysis & invariants (critic will enforce)

**Properties:**
- **PoP on every inbound AD.** `group_member_add` / `group_roster_sync` run
  `process_address_document(ad, TRUE)` before storing — a forged/inconsistent AD
  aborts; a key-derived cid can never be silently overwritten.
- **Roster authority = the pinned admin.** `member_add` / `member_remove` /
  `roster_sync` are honored ONLY from `groups[chat_id].admin_cid`. A non-admin contact
  cannot add, remove, or resync anyone's roster.
- **Self-assertions only remove the sender.** `leave` / `not_member` are accepted
  from any roster member but can only drop *that sender* — never a third party.
- **No disclosure without consent.** A decline (or no response) discloses nothing; a
  member's AD reaches the joiner, and the joiner's AD reaches members, ONLY after the
  joiner accepts.
- **Membership ≠ contact.** Remove/leave/delete edit `groups` only; `contacts`/`peer_ads`
  are never deleted by a group op.
- **`epoch` is advisory.** It drives repair only; it is never an authorization input,
  so a forged epoch cannot mutate state (worst case: a harmless resync to the real admin).
- **Forced monitoring covers group messages** (§9) — uniform with 1:1.
- **Bare multi-send is sound.** Every roster member is a registered contact by
  construction of the mesh, so `send_encrypted_tx` to each is valid without a handshake.

**Hard invariants (do not break):**
1. No `contacts`/`peer_ads` write before `process_address_document(ad, TRUE)` passes.
2. No roster mutation from a relay whose `sender != admin_cid` (except the
   sender-only self-assertions).
3. A group op never deletes a contact.
4. `receive_group_message` mutates no group state before its §5 gate decision.
5. Group state carries no secrets and exports/imports losslessly.

**Residual trust (documented, unchanged class):** TOFU on the OOB-equivalent first
contact (same as `add_contact` today) and "my admin honestly relays" — bounded by the
admin-only authority and the PoP on every AD. An active admin can add/remove at will
within its own groups; that is the definition of owner authority for v1.

---

## 11. Backward compatibility & versioning

**Additive** — a new library, new wire shapes, new transactions, plus one additive
field on `monitoring_copy_t`. No existing wire shape or verification semantics change.
→ **`version.mm` 3.0 → 3.1 (MIN).** `config.mufl` exports the new `a2a_group` library;
consumers `load` it and wire the two storage hooks + the group-event notifies. New
inbound names are library-routed, so no `::actor::` shims. `release-notes/3.1.md` per
the existing convention.

---

## 12. Work breakdown (core mufl only)

| # | File | Change | Size |
|---|------|--------|------|
| 1 | `a2a_protocol.mm` | Add `group_invite_t`; document the `any` payload shapes (§6). | S |
| 2 | `a2a_messaging.mm` | Add `monitor_group_copy_actions`; add optional `$chat_id` to `monitoring_copy_t`. | S |
| 3 | `a2a_group.mm` (NEW) | State (§7) + `init` (storage hooks) + tx-name consts. | S |
| 4 | `a2a_group.mm` | User trns: create/invite/respond/send/remove/leave/delete/request/list (§8.1). | L |
| 5 | `a2a_group.mm` | Inbound trns: invite/response/add/roster_sync/remove/leave/delete/message/not_member/stale/request (§8.2). | L |
| 6 | `a2a_group.mm` | `export_group_state`/`import_group_state` (§7). | S |
| 7 | `a2a_monitoring.mm` | Pass the optional `$chat_id` through `receive_monitoring_copy` to its hook. | XS |
| 8 | `config.mufl` | Export `a2a_group`. | XS |
| 9 | `version.mm` | `create_version 3 0` → `create_version 3 1` (MIN). | XS |
| 10 | `release-notes/3.1.md` | New note (shipped txns + integration TODO + security notes). | S |
| 11 | (compile) | Clean compile against the toolkit; no consumer wiring ([[qa-toolchain-mufl-core]]). | — |

---

## 13. Test plan (loopback, per [[qa-toolchain-mufl-core]])

Extend `tests/test_actor.mu` (load `a2a_group`, wire group storage hooks + `qa_*`
probes) and `tests/test.mjs` (multi-packet loopback, asserting **receiver-side** state).

1. **Compile**; `get_version` → 3.1.
2. **Create + invite + accept (2 members)** — owner creates, invites A; A accepts;
   owner roster = {owner, A}; A roster_sync registers owner; A `status=active`.
3. **Third member, incremental mesh** — owner invites B; B accepts; B's roster_sync
   carries owner+A; A gets `member_add(B)`. All three rosters equal; all pairwise
   `peer_ads` present (full mesh).
4. **Owner-only disclosure** — the `group_invite` to B carries no member ADs/names;
   a declining invitee's AD never reaches any member.
5. **Broadcast** — any member `send_group_message`; every other member's
   `on_group_message_received` fires with the right `chat_id`; bare multi-send (no
   handshake) to N registered contacts.
6. **Decline** — invitee declines; owner clears pending; no roster change, no AD sent.
7. **Admin remove** — owner removes A; A's group dropped (A keeps owner/B as
   contacts); B drops A from roster; A↔B `peer_ads` retained.
8. **Self leave** — B leaves; owner+A drop B from roster; contacts retained; admin
   `leave_group` aborts.
9. **Authority** — a non-admin `group_member_add`/`remove`/`roster_sync` is rejected
   (admin_cid mismatch); a `group_member_leave`/`not_member` only ever drops the sender.
10. **PoP** — a `member_add`/`roster_sync` with a stripped/forged AD aborts in
    `process_address_document`; nothing registered.
11. **Repair — bounce** — a removed/left node that receives a `group_message` replies
    `group_not_member`; the sender drops it from the roster.
12. **Repair — epoch/resync** — a member with a stale roster gets an unknown-sender
    `group_message` → `group_stale` + `request_group_roster` → admin `roster_sync`
    reconciles (missed add appears / missed remove confirmed).
13. **Delete** — owner `delete_group`; every member drops the group; contacts retained.
14. **Export/import** — `export_state`→`import_state` preserves `groups` + rosters;
    no secrets present; channels still work post-import.
15. **Monitoring** — with a bound CP, a `send_group_message` emits one forced copy
    tagged with `chat_id`; the app cannot suppress it.

---

## 14. Milestones / sequencing

- **M0 — Shapes + state + skeleton:** items #1, #3, #9 + `config.mufl`. Compile;
  `get_version` → 3.1.
- **M1 — Create/invite/accept/add:** the membership-formation path (create,
  invite_to_group, respond, the admin accept handler, member_add, roster_sync) +
  tests 2–4, 6, 10.
- **M2 — Broadcast + storage + monitoring:** send/receive_group_message, the hooks,
  `monitor_group_copy_actions` (#2, #7) + tests 5, 15.
- **M3 — Remove/leave/delete + repair:** the roster-op + repair inbounds + tests
  7–9, 11–13.
- **M4 — Export/import + release note + critic:** #6, #10 + test 14, critic review
  against §10.

---

## 15. Open decisions (deferred, not v1)

- **Admin succession / co-admins.** v1 is single-owner; owner exit = `delete_group`.
- **Group key / sender-keys multicast.** v1 fans out per-recipient over existing 1:1
  channels (no shared group key, no forward secrecy beyond the 1:1 channels).
- **Signed membership tombstones** (peer-gossipable, admin-offline repair). v1 routes
  repair through the live admin (`request_group_roster`); tombstones are the upgrade
  if admin-offline healing is later required.
- **Bounce rate-limiting / anti-amplification hardening** beyond the per-pair note in §5.
- **Role-delegated members** (a member that is a delegated role): the AD + chain ride
  the same way as in `accept_contact`; v1 treats members as flat identities and may
  pin `contact_roots` opportunistically — confirm during M1.
