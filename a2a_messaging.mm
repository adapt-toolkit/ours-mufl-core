// Shared ours messaging library.
//
// The contact + message wire path common to every ours client: identity
// profile (name/bio), invite generation/redemption, contact registry, the
// encrypted send/receive pair, and the export/import helpers for the shared
// state. Message STORAGE stays app-side — each consumer injects storage hooks
// via init (the agent keeps its inbox lifecycle, the messenger its per-contact
// history); this library handles wire + validation + contact resolution only.
//
// Routing: this library's transactions are addressed ::a2a_messaging::<name>.
// The four NETWORK-VISIBLE inbound names stay ::actor::* for compatibility
// with pre-migration clients (Option A): consumers keep one-line ::actor::
// delegating shims, and this library keeps SENDING to the ::actor:: names
// (the *_tx constants below). Drop both only when no old clients remain.
//
// Identity-hierarchy state (delegation_cert, root_ad, root_profile,
// contact_roots) lives HERE because generate_invite/add_contact read it; the
// hierarchy transactions themselves arrive in a2a_hierarchy.mm, which loads
// this library and shares this state.
//
// The contact/identity state is deliberately non-hidden: consumers (and
// a2a_hierarchy) read and assign it directly during the migration's transition
// steps. The EXCEPTION is the monitoring + config gate state (monitoring_proxy,
// proxy_pending, app_config), which is `hidden` so neither the app nor any other
// library can switch monitoring off or rewrite the stored config by assigning it
// directly — the "app can't override" guarantee. Its mutators (the bind ceremony,
// disable, set_app_config) therefore live in THIS library.
library a2a_messaging loads libraries
    address_document,
    address_document_types,
    key_utils,
    key_storage,
    current_transaction_info,
    encrypted_channel,
    e2e,
    a2a_versions,
    a2a_protocol,
    a2a_capabilities,
    version
    uses transactions
{
    // Network-visible inbound transaction names (embedded in what peers send).
    // Pre-migration clients listen on these, so the core keeps sending to them.
    accept_contact_tx = "::actor::accept_contact".
    receive_message_tx = "::actor::receive_message".
    // File transfer inbound (core 3.1). NEW surface, no legacy clients, so
    // LIBRARY-routed like submit_invite_response/complete_invite — no ::actor:: shim.
    receive_file_tx = "::a2a_messaging::receive_file".
    // Distinct inbound name on the control plane for a forced monitoring copy.
    // The CP-side receiver lives in a2a_monitoring; held as a literal so this
    // library keeps no code dependency on it (a2a_monitoring loads THIS library).
    receive_monitoring_copy_tx = "::a2a_monitoring::receive_monitoring_copy".
    // Node-side inbound for a control-plane introduction (core.connect): the CP
    // relays a peer's signed address document here. Library-routed (new surface,
    // no legacy clients), so introduce/introduce_to_group send to this literal.
    ingest_connect_descriptor_tx = "::a2a_messaging::ingest_connect_descriptor".
    // CP-side inbound for cluster enrollment (core 2.2): a root relays one of its
    // children's signed AD + delegation chain here so the CP can hold peer_ads for
    // the whole cluster off a single root bind. handle_enroll_delegated_node is the
    // receiver; relay_enroll_delegated_node (root side) sends to this literal.
    enroll_delegated_node_tx = "::a2a_messaging::enroll_delegated_node".
    // core 3.0 ephemeral-invite redeem legs. NEW surfaces (no legacy clients), so
    // both are LIBRARY-routed — no ::actor:: shim needed, unlike the pre-migration
    // names above. leg 1 (responder->inviter) is a BARE send carrying a box; leg 3
    // (inviter->responder) is ALSO a bare boxed send (NOT encrypted_channel — the
    // box to the responder's kept ephemeral key is the confidentiality/integrity).
    // See submit_invite_response / complete_invite below.
    submit_invite_response_tx = "::a2a_messaging::submit_invite_response".
    complete_invite_tx        = "::a2a_messaging::complete_invite".
    // contact-restore wire names (LIBRARY-routed, new surface — no ::actor:: shims).
    request_contact_restore_tx = "::a2a_messaging::request_contact_restore".
    submit_restore_response_tx = "::a2a_messaging::submit_restore_response".
    complete_restore_tx        = "::a2a_messaging::complete_restore".
    // core 0.7.0 receipts inbound (LIBRARY-routed, new surface, no legacy
    // listeners; reachable only behind positive core.receipts.* caps).
    receive_receipt_tx         = "::a2a_messaging::receive_receipt".
    // core 0.9.0 E2E-migration inbound (LIBRARY-routed, wire 9). offer/ack ride the
    // legacy encrypted_channel; commit/confirm are inner txs on the fresh e2e session.
    e2e_migrate_offer_tx       = "::a2a_messaging::e2e_migrate_offer".
    e2e_migrate_ack_tx         = "::a2a_messaging::e2e_migrate_ack".
    e2e_migrate_commit_tx      = "::a2a_messaging::e2e_migrate_commit".
    e2e_migrate_confirm_tx     = "::a2a_messaging::e2e_migrate_confirm".
    // core 0.10 (B1): stateless AD re-advertise pushed to pre-existing legacy contacts on
    // upgrade, so an idle legacy pair learns both sides are now v2 and the migration FSM fires.
    readvertise_ad_tx          = "::a2a_messaging::readvertise_ad".
    capability_advertise_tx    = "::a2a_capabilities::advertise".
    capability_advertise_ack_tx = "::a2a_capabilities::advertise_ack".
    // core 0.9.0 boxed APP-E2E (Option B): app data over the MIGRATED session rides these named
    // boxes ($targ = the e2e_signed_message). DISTINCT from legacy receive_message_tx so the wire
    // separates e2e-carrying box from legacy box (an attacker cannot confuse them).
    receive_e2e_message_tx     = "::a2a_messaging::receive_e2e_message".
    receive_e2e_file_tx        = "::a2a_messaging::receive_e2e_file".
    // core 0.11 (session self-heal): authenticated re-key request. Sent by the side whose
    // e2e DECODE failed (no_session / session_mismatch / tampered from an accepted contact —
    // the TRUE-loss signature: since persist-primary a normal restart RESUMES its sessions,
    // so this fires only when the persisted state was lost/rejected and the account was
    // re-minted, making my old advertised bundle stale) so the peer refreshes my AD and
    // the elected initiator re-establishes a fresh born-DR session, then redrives unacked.
    // A pre-0.11 peer does not understand the tx and ignores it (readvertise precedent).
    e2e_rekey_request_tx       = "::a2a_messaging::e2e_rekey_request".

    // Version stamp of the portable export blob (see import_core_state for the
    // migration contract). Bump ONLY on a breaking blob-shape change, together
    // with a migration from the previous stamp.
    core_format_version = 1.
    // Invite-format version stamped on every invite this build mints (invite_eph_t
    // $iv). A redeemer that reads NIL there treats the inviter as pre-versioning and
    // down-levels its address document to v1. See invite_eph_t in a2a_protocol for
    // the exact cases that bump this.
    invite_current_version = 1.
    // Give up re-requesting a restore after this many attempts per contact (the
    // host sweep re-fires on its GC cadence; a peer that upgraded and came back
    // online answers on the first post-upgrade attempt).
    restore_max_attempts = 30.
    // Per-contact cap on messages queued while its keys are being restored.
    deferred_msgs_cap = 50.
    // core 0.9.0: give up re-driving a per-contact E2E migration after this many
    // host-sweep attempts (mirrors restore_max_attempts). Exhaustion surfaces a
    // $migration_stalled notify and KEEPS the FSM state — legacy still flows in
    // offered/acknowledged; committed keeps queueing — nothing silently downgrades.
    mig_max_attempts = 30.
    // core 0.11 (session self-heal): give up re-sending an e2e_rekey_request for the SAME
    // dead session after this many decode failures (strictly per (cid, failed session_id);
    // cleared on the first successful decode from that cid). Low on purpose: one request
    // usually heals; the cap only bounds a lost-request retry, never a per-message storm.
    rekey_max_attempts = 3.
    // Per-contact cap on unacknowledged (no delivered-receipt yet) e2e sends retained for
    // redrive after a re-key (mirrors deferred_msgs_cap; oldest dropped first, never abort).
    unacked_cap = 50.
    // Age before the periodic sweep re-sends a stuck unacked message (no delivered
    // receipt). Covers a PRE-fix peer that silently rejected our sends and cannot ask
    // us to re-key (it heals once our boot-readvertise refreshed its copy of our AD),
    // and a lost receipt. Repeats are harmless: the receiver's delivered_wire dedup
    // re-acks without re-depositing, and the re-ack clears our buffer.
    redrive_min_age_seconds = 120.
    // Review #12 + ship-review major-4: per-sweep budgets — one txn re-driving 50×N
    // contacts (or emitting one expiry notify per contact across thousands) could hit
    // fuel/action limits and lose the WHOLE sweep, cyclically. A contact's queue is
    // capped at unacked_cap (50) < the crypto budget, so every contact is individually
    // processable; overflow defers the remainder to the (exported) cursor.
    // The crypto budget is DELIBERATELY denominated in CRYPTO OPERATIONS (each entry =
    // one e2e::encrypt_to = 1 ratchet encryption + 1 signature GENERATION; this path
    // performs zero sig-verifies), NOT in fuel: the fuel model undercounts fixed
    // crypto costs (cross-fleet finding), so a fuel number would be a weaker guard.
    // The action budget bounds emitted SEND/RET actions INCLUDING the per-contact
    // expiry notifies of the purge phase.
    redrive_sweep_max_entries = 100.
    redrive_sweep_max_actions = 250.
    // Data-at-rest bounds for the retained plaintext (review: a peer withholding
    // receipts must not pin our plaintext forever): total per-contact byte budget
    // (oldest dropped first; an entry alone above the budget is never retained),
    // and a hard TTL — the periodic sweep purges expired entries.
    unacked_max_bytes = 8388608.
    unacked_ttl_seconds = 172800.
    // Per-ENTRY byte ceiling for retained FILES ("f") — a large file body would bloat
    // the exported blob (data-at-rest) and one entry could evict the whole message
    // window. An oversized file is simply not retained (not auto-redriven; surfaced
    // by the send notify as usual — the app owns re-sending it after a heal).
    unacked_file_entry_max_bytes = 2097152.
    // Responder-side re-key throttle: minimum seconds between session rotations
    // served to one cid (see handle_e2e_rekey_request — requester-side rate-limit
    // alone does not bound a misbehaving authenticated contact).
    rekey_min_interval_seconds = 30.
    // Review #9: the rekey_served attempts cap used to be PERMANENT (until restart) —
    // a peer that legitimately needed >5 rotations over a long uptime was stalled
    // forever. Entries older than this window are treated as expired: a fresh budget.
    rekey_served_reset_seconds = 3600.

    // 6-digit bind ceremony limits (code is generated host-side — MUFL has no
    // random source — and handed to set_proxy_pending).
    proxy_code_max_age_seconds = 300.
    proxy_max_attempts = 3.

    // ---- shared packet state ---------------------------------------------
    // The display name peers see for me (set via set_my_name).
    my_name is str = "".
    // My profile bio (free-text, self-asserted; carried in role invites).
    my_bio is str = "".
    // My LOCAL operating contract. Adopted as the bound agent's persona ONLY with
    // the user's explicit consent (never silently). NEVER carried in invites; shared
    // only via the control-plane cluster registry (a2a_cluster set_persona).
    my_persona is str = "".
    // Known contacts, keyed by their container id.
    contacts is (global_id ->> a2a_protocol::contact_t) = (,).
    // core 0.5.0: passively learned peer wire dialects + capability ids
    // (SPEC §3/§4). Written on every inbound that carries version evidence
    // (last-seen wins); absent = nothing learned, 0 = pre-0.5 peer. $pv is
    // peer-asserted — these gate send-side feature selection and diagnostics,
    // NEVER authz (REG-6). Both maps are additive in the export blob and
    // guarded on import (pre-0.5 exports import unchanged).
    contact_pv is (global_id ->> int) = (,).
    contact_caps is (global_id ->> str[]) = (,).
    // ACK-confirmed capability fingerprint per contact. A missing/stale entry
    // is retried by reconcile_advertise; only the encrypted ACK advances it.
    contact_advertised_caps is (global_id ->> str) = (,).
    // core 0.8.0: monotonic E2E anti-downgrade pin (SPEC §4). Positive-evidence,
    // set TRUE the first time a peer advertises core.e2e and NEVER cleared — it
    // CANNOT be derived from contact_caps (which is last-seen-wins, so a later
    // caps-absent inbound would erase the evidence and permit a silent downgrade).
    // Exported so the guarantee survives restart/migration. Gates send-side routing
    // (e2e_route), never authz (REG-6).
    contact_e2e_seen is (global_id ->> bool) = (,).
    // core 0.10: born-on-DR marker. TRUE when a contact was FIRST established with a
    // v2 (bundle-carrying) address document — it started on the double ratchet
    // (born-DR), never on a legacy session. A pre-existing LEGACY contact (a v1 AD at
    // registration, INCLUDING an A-down-levelled peer) is NEVER marked. Read by
    // mig_should_trigger to keep migration STRICTLY for legacy sessions: a born-DR
    // contact is already on the ratchet and must not be "migrated". Exported.
    contact_born_dr is (global_id ->> bool) = (,).
    // core 3.0: invites I generated, keyed by invite id. Holds the NON-secret
    // per-invite material — the assigned contact name ("" = none), the ephemeral
    // encryption PUBLIC key shipped in the slim invite, and the crypto scheme id.
    // The matching ephemeral PRIVATE key lives in the hidden, non-exported
    // pending_invite_keys store (INV-4) and is consumed together on first redeem.
    metadef pending_invite_t: ($assigned -> str, $eph_pub -> publickey_encrypt, $scheme -> int).
    pending_invites is (global_id ->> pending_invite_t) = (,).
    // core 3.0: responder-side pending redemptions, keyed by invite id — who I am
    // redeeming, so leg 3 (complete_invite) can name the contact and pin the
    // expected inviter cid. No secrets; transient (not exported — outstanding
    // invites do not survive a restart; see the 3.0 release note).
    metadef pending_redemption_t: ($inviter_cid -> global_id, $inviter_name -> str, $custom_name -> str).
    pending_redemptions is (global_id ->> pending_redemption_t) = (,).
    // contact-restore (spec 2026-07-01): a DEGRADED contact is derivable state —
    // cid present in `contacts`, absent from `peer_ads` (e.g. a breaking-change
    // migration carried the contact but dropped its address document). These
    // stores drive the self-heal handshake; see request_contact_restore below.
    // Requester side, keyed by the TARGET cid. Non-secret half (the eph PRIVATE
    // key lives in the hidden pending_restore_keys, INV-4).
    metadef pending_restore_t: ($rid -> global_id, $eph_pub -> publickey_encrypt, $scheme -> int, $attempts -> int, $created -> time).
    pending_restores is (global_id ->> pending_restore_t) = (,).
    // Responder side, keyed by the REQUESTER cid — at most ONE outstanding reply
    // per requester (bounded by the contacts set; a newer request replaces it).
    metadef restore_reply_t: ($rid -> global_id, $scheme -> int, $created -> time).
    pending_restore_replies is (global_id ->> restore_reply_t) = (,).
    // Messages queued toward a degraded contact, flushed (host-driven,
    // flush_deferred) once its AD is re-established. Plain data — EXPORTED.
    metadef deferred_msg_t: ($text -> str, $wire_id -> str, $reply_to -> a2a_protocol::reply_ref_t+, $date -> time).
    deferred_msgs is (global_id ->> deferred_msg_t[]) = (,).

    // ---- core 0.9.0: per-connection E2E migration FSM (spec §5) -----------
    // ABSENCE = legacy (pre-migration, or the peer is not yet capable). Every
    // store is keyed by cid, so mixed-contact independence is structural: no
    // global mode flag exists anywhere. Exported/imported additively (guarded,
    // absent -> empty); a pre-0.9 blob imports with all three empty = legacy.
    // Phase A lands the TYPES + STORES + export/import wiring only — NO handlers,
    // NO route change, NO advertise wiring (those are phases C/D).
    metadef mig_state_t: (
        $phase        -> str,        // "offered" | "acknowledged" | "committed" | "active"
        $initiator    -> bool,       // deterministic election result (mig_initiator; lower cid initiates)
        $local_nonce  -> bin,        // my proposal nonce (agreement uniquifier, not key material)
        $peer_nonce   -> bin+,       // set from acknowledged on
        $epoch        -> bin+,       // set from acknowledged on (mig_epoch)
        $session_id   -> bin+,       // CANONICAL session-id BYTES (adapt session_id()); set from committed on
        $local_bundle -> bin+,       // _write'd SNAPSHOT of ($ad,$cert,$root_profile,$cp_binding) THIS attempt —
                                     // retransmits reuse it byte-identically (§5.4-5); PUBLIC signed material
                                     // only, so INV-4 holds (no session pickle ever rides the FSM entry)
        $local_fp     -> bin+,       // e2e_bundle_fp of the snapshot — the epoch input AND the rotation
                                     // detector (live-fp != $local_fp at retransmit => supersede)
        $attempts     -> int,        // sweep re-send counter (cap: mig_max_attempts)
        $updated      -> time
    ).
    // $local_bundle/$local_fp are bin+ ONLY for import compatibility (pre-0.9
    // blobs lack them); semantically offered/acknowledged REQUIRE both non-NIL —
    // they are written together with the phase in one record assignment, so no
    // code path produces the phase without the snapshot (spec §5.4 phase invariant).
    contact_migration is (global_id ->> mig_state_t) = (,).

    // The COMMITTED-EPOCH pin — the §5.7 split of contact_e2e_seen. Set ONLY at
    // the `active` transition (cryptographic commit); superseded only by a NEWER
    // committed epoch via a full FSM run; NEVER cleared. Once set, legacy APP-DATA
    // transport to this contact is PROHIBITED (§5.6 carves out migration-CONTROL
    // legs). Strictly stronger than contact_e2e_seen (which is advertisement-class
    // and kept, unchanged, with its 0.8.0 refusal semantics). Canonical bytes.
    metadef e2e_epoch_t: ($epoch -> bin, $session_id -> bin).
    contact_e2e_epoch is (global_id ->> e2e_epoch_t) = (,).

    // Sends queued during the initiator's commit window; flushed E2E on `active`.
    // Reuses deferred_msg_t; bounded by deferred_msgs_cap (same overflow abort).
    mig_deferred is (global_id ->> deferred_msg_t[]) = (,).

    // ---- core 0.11: e2e session self-heal (restart desync recovery) --------
    // Re-key request rate-limit ledger, keyed by cid. Strictly per (cid, failed
    // session_id): a broker backlog of N messages on one dead session produces at
    // most rekey_max_attempts requests, and a NEW dead session gets a fresh budget.
    // Cleared on the first successful decode from the cid (the pair healed).
    // NOT exported: worst case after a restart is one duplicate request (idempotent).
    metadef rekey_state_t: ($session_id -> bin, $attempts -> int, $updated -> time).
    rekey_pending is (global_id ->> rekey_state_t) = (,).
    // Unacknowledged e2e app sends (no delivered/read receipt yet), keyed by cid —
    // the redrive source that turns "session healed" into "the message still reached
    // the receiver's inbox". Holds the serialized INNER app body ($text/$wire_id/...):
    // the SAME plaintext class the exported inbox already persists at rest, never key
    // material (INV-4 untouched — no session pickle here). Bounded (unacked_cap,
    // oldest-first drop); entries clear on delivered/read receipt; EXPORTED so a
    // sender-side restart (offline-pair case) does not lose undelivered messages.
    // $kind: "m" (message, redriven as receive_e2e_message_tx) | "f" (file,
    // redriven as receive_e2e_file_tx) — files silently lost on restart are the
    // owner's primary case too, so BOTH app payload kinds retain (review fix).
    metadef unacked_entry_t: ($kind -> str, $wire_id -> str, $inner -> bin, $date -> time).
    unacked_e2e is (global_id ->> unacked_entry_t[]) = (,).
    // Responder-side re-key ledger, keyed STRICTLY by cid (review: never key the
    // budget by attacker-controlled fields like the claimed session id). $attempts
    // caps total served rotations between successful decodes from that cid (the
    // ledger clears when the pair provably healed); $updated drives the cooldown.
    // Transient, not exported — worst case after restart is one extra rotation.
    metadef rekey_served_t: ($attempts -> int, $updated -> time).
    rekey_served is (global_id ->> rekey_served_t) = (,).
    rekey_served_max = 5.
    // Review #9: responder-side AD-response cooldown — its OWN ledger. The old check
    // read rekey_served, which only maybe_init_rekey writes, so the NON-initiator
    // responder had no cooldown: every authenticated rekey_request minted a fresh
    // signed AD + save. Transient (not exported): worst case after restart is one
    // extra readvertise.
    ad_response_last is (global_id ->> time) = (,).
    // Review #12 + ship-review major-4: resume point for the budgeted sweep, covering
    // BOTH phases (TTL purge and redrive). EXPORTED: a deployment that only ever runs
    // boot sweeps (short-lived daemons) would otherwise re-scan the same prefix every
    // boot and starve the tail forever. A sweep-txn failure rolls the cursor back with
    // everything else, so a retried sweep resumes from the last COMMITTED position.
    redrive_sweep_cursor is global_id+ = NIL.
    // Recently DELIVERED inbound wire_ids per contact — the receive-side dedup for the
    // at-least-once redrive: a re-delivered wire_id re-acks (delivered receipt, so the
    // sender's buffer clears) but never re-deposits into the inbox. EXPORTED (tiny):
    // the inbox it guards is persisted too, so the guard must survive the same restarts.
    // Retention is AGE-ONLY (finding H + ship-review major-3): an entry lives exactly
    // as long as the SENDER can still redrive it (unacked_ttl_seconds). There is
    // deliberately NO count-based eviction inside that window — any count cap could be
    // pushed past by heavy (still authenticated) traffic while one receipt was lost,
    // and the late redrive would re-deposit a duplicate. The storage bound is the
    // AUTHENTICATED per-contact inbound rate over the 2-day window (each entry is one
    // wire_id string + a date; only accepted contacts reach delivered_note).
    metadef delivered_entry_t: ($w -> str, $d -> time).
    delivered_wire is (global_id ->> delivered_entry_t[]) = (,).
    // Storage CEILING (not a dedup window): an authenticated flooder must not grow
    // delivered_wire without bound over the 2-day window (memory-DoS). Reaching it is
    // a GUARANTEE-LOSS event — the oldest in-TTL entry is dropped AND the loss is
    // SURFACED ($dedup_degraded notify), never a silent eviction. ~16k entries ≈ low
    // single-digit MB per pathological contact.
    delivered_wire_hard_cap = 16384.
    // Peer address documents, captured when a contact is established. Self-
    // signed, code-independent, and seed-stable: import_core_state replays
    // them through address_document::process_address_document so encrypted
    // channels survive a code upgrade with no re-handshake. Only peer PUBLIC
    // keys travel here, never secrets.
    peer_ads is (global_id ->> address_document_types::t_address_document) = (,).
    // My delegation cert. NIL == I am a root or a legacy flat identity.
    delegation_cert is a2a_protocol::delegation_cert_t+ = NIL.
    // My delegation cert bound to my v1 (down-levelled, bundle-less) address
    // document — the SAME chain, but its $role_ad_hash commits to _value_id of
    // produce_v1_address_document() instead of the current v2 AD. Sent INSTEAD of
    // delegation_cert whenever I down-level my AD to v1 for a pre-E2E (0.11.2)
    // peer, so that peer's verify_peer_delegation (which hashes the v1 AD it
    // actually received) finds a matching cert. NIL for a root, a legacy flat
    // identity, or a role whose host has not yet minted the v1 cert (in which
    // case the down-level omits the chain rather than send a mismatching v2 cert).
    delegation_cert_v1 is a2a_protocol::delegation_cert_t+ = NIL.
    // My root's address document (set with the cert; its key list is what
    // sibling introductions and my own cert are verified against).
    root_ad is address_document_types::t_address_document+ = NIL.
    // My root's self-signed profile, embedded in the invites I generate.
    root_profile is a2a_protocol::root_profile_t+ = NIL.
    // My root's §3c CP binding (root half), distributed to me by the host
    // (set_root_cp_binding) and carried beside root_profile in my invites so
    // peers can TOFU-pin my governance edge. NIL until a CP is bound.
    root_cp_binding is a2a_protocol::root_cp_binding_t+ = NIL.
    // Verified root linkage per contact, keyed by the contact's container id.
    contact_roots is (global_id ->> a2a_protocol::contact_root_t) = (,).
    // Peers' verified §3c root bindings, keyed by the ROOT's container id (one
    // edge per root, shared across its roles). Populated when a peer's invite or
    // introduction carries a binding that verifies against its root key list.
    contact_cp_bindings is (global_id ->> a2a_protocol::root_cp_binding_t) = (,).
    // CP SIDE: the set of ROOTS this control plane manages, keyed by the root's
    // container id (value is a presence marker). A child may be enrolled
    // (enroll_delegated_node) ONLY when the delegation chain it presents resolves
    // to a root in this set — the host asserts membership via manage_root when it
    // binds a root, so the cryptographic chain + this set together authorize a
    // cluster enrollment and forbid unsolicited ones. Empty on a non-CP node.
    managed_roots is (global_id ->> bool) = (,).
    // ---- forced monitoring + config types --------------------------------
    // FORCED monitoring lives HERE, in the chokepoint, because send_message /
    // handle_receive_message are the single path every app routes through —
    // monitoring copies are generated as UNCONDITIONAL core code (see
    // monitor_copy_actions). CRITICAL: the gate STATE (monitoring_proxy etc.) is
    // declared `hidden` below, so ONLY this library can mutate it — an app or any
    // other loading library cannot write `a2a_messaging::monitoring_proxy -> NIL`
    // to switch monitoring off. That is why the bind ceremony + disable + the
    // config writers all live IN THIS library (hidden state is mutable only by its
    // declaring library); a2a_monitoring keeps only the CP-side copy RECEIVER.
    //
    // One monitored message copy, re-encrypted to the bound control plane. The
    // source is the channel-authenticated envelope $from on the receiver, so it
    // is not carried in the body. (Types are public; only the STATE is hidden.)
    metadef monitoring_copy_t: (
        $version   -> int,
        $direction -> str,        // "out" (I sent) | "in" (I received)
        $peer_cid  -> global_id,
        $peer_name -> str,
        $date      -> time,
        $body      -> str
    ).
    metadef proxy_pending_t: ($code -> str, $proxy_cid -> global_id, $created_at -> time, $attempts -> int).
    metadef proxy_binding_t: ($proxy_cid -> global_id, $bound_at -> time).

    hidden
    {
        // core 0.11 persist hardening (finding C redo): the $e2e_sessions blob from the
        // boot import is PARKED here UNVALIDATED and UNASSIGNED — validation happens in
        // the dedicated commit_e2e_restore transaction, where a corrupt pickle's hard
        // BAD_PICKLE error fails that txn alone (atomic rollback, nothing assigned) and
        // the host observes an identity-scoped failure. Transient boot state: NOT
        // exported (the source blob is still on disk; a crash between import and commit
        // simply re-stages on the next boot).
        e2e_restore_staged is ( $v -> int, $account -> bin+, $sessions -> (global_id ->> bin)+ )+ = NIL.

        // ---- monitoring + config gate state (NON-app-writable) -----------
        // Hidden so only this library mutates it (the "app can't override"
        // guarantee). A pending 6-digit bind, and the verified control plane that
        // replaces it on success.
        proxy_pending    is proxy_pending_t+ = NIL.
        // The verified control plane: set ONLY by verify_proxy_code, cleared ONLY
        // by the CP-authenticated disable_monitoring (both in this library). It is
        // also the configuration authority for set_app_config.
        monitoring_proxy is proxy_binding_t+ = NIL.
        // Opaque, app-custom JSON config the TS wrapper owns; the core NEVER parses
        // it and bakes in NO policy semantics — per-application policy (e.g. anything
        // like "outgoing-only") is the application's job, implemented in the wrapper
        // from this blob. Written ONLY by the bound CP via set_app_config.
        app_config is str = "".

        // core 3.2 cluster roster push: monotonic sequence bumped on every real
        // roster change. Carried in each push and in the list/bind result so the CP
        // can order/dedup. No opt-in flag — push is gated only on monitoring_proxy.
        roster_push_seq is int = 0.

        // core 0.12 (2b auto-advertise): the wire_version + a fingerprint of my self cap-id
        // set captured at the LAST reconcile_advertise. Persisted so a post-upgrade boot
        // NOTICES a version/cap change and re-advertises to legacy peers exactly once — the
        // core owns the trigger, so the app stops orchestrating readvertise_on_upgrade.
        // 0/"" = never reconciled (⇒ the first reconcile after any boot advertises).
        advertised_pv is int = 0.
        advertised_caps is str = "".

        // core 3.0: per-outstanding-invite ephemeral PRIVATE keys, keyed by invite id.
        // hidden ⇒ only this library mutates it AND it is structurally invisible to the
        // export record builder, but `hidden` governs VISIBILITY, not persistence — it
        // is deliberately NEVER added to export_core_state (INV-4: secrets must not ride
        // the portable export blob; empirically the SDK export serializer also corrupts
        // raw secret keys). Consumed (deleted) together with pending_invites[id] on the
        // first valid redemption. Outstanding entries do not survive a daemon restart.
        pending_invite_keys is (global_id ->> secretkey_encrypt) = (,).

        // core 3.0: RESPONDER-side per-redemption ephemeral PRIVATE keys, keyed by
        // invite id. The responder keeps its leg-1 ephemeral private key here so it
        // can OPEN the inviter's leg-3 reply (which is a bare send boxed to the
        // responder's ephemeral PUBLIC key — leg 3 cannot ride encrypted_channel
        // because the responder has not registered the inviter yet, and the stdlib
        // never exposes a raw long-term encryption privkey to box against instead).
        // Same INV-4 treatment as pending_invite_keys: hidden AND never exported;
        // consumed with pending_redemptions[id] on the leg-3 completion.
        pending_redemption_keys is (global_id ->> secretkey_encrypt) = (,).

        // contact-restore ephemeral PRIVATE keys — same INV-4 treatment as the
        // invite stores: hidden AND never exported; consumed with their public-half
        // records on the first valid completion. Requester side keyed by target cid,
        // responder side keyed by requester cid.
        pending_restore_keys is (global_id ->> secretkey_encrypt) = (,).
        pending_restore_reply_keys is (global_id ->> secretkey_encrypt) = (,).

        _read_or_abort is (bin->any) = fn (_: bin) { abort "_read_or_abort is unset in a2a_messaging (call a2a_messaging::init)." when TRUE. }

        // App-injected storage hooks. Each receives one record and returns the
        // transaction actions to append (storage writes + notify/save actions).
        //
        // on_message_received ($sender_id, $sender_name, $text, $date,
        //   $wire_id, $reply_to):
        //   $sender_name is NIL when the sender is NOT a known contact — the
        //   app decides what an unknown sender means (the agent checks its
        //   pending-introduction queue; a plain client aborts). $wire_id is the
        //   message's stable cross-side id ("" from pre-1.4 senders) and
        //   $reply_to is its optional reply pointer (NIL when not a reply).
        on_message_received is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_message_received hook is unset in a2a_messaging (call a2a_messaging::init)." when TRUE. return []. }
        // on_message_sent ($target_id, $text, $date, $wire_id, $reply_to):
        //   fired after the wire send is queued (agent: no-op; messenger:
        //   append "out" history, keyed by $wire_id so a peer's reply pointer
        //   resolves back to it). $reply_to is NIL unless this send is a reply.
        on_message_sent is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_message_sent hook is unset in a2a_messaging (call a2a_messaging::init)." when TRUE. return []. }
        // on_contact_removed ($container_id): fired after a contact is dropped
        //   (agent: no-op; messenger: delete that contact's history).
        on_contact_removed is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_contact_removed hook is unset in a2a_messaging (call a2a_messaging::init)." when TRUE. return []. }
        // on_file_received ($sender_id, $sender_name, $filename, $mime, $data,
        //   $date, $wire_id, $reply_to): the file analogue of on_message_received.
        //   $sender_name is NIL for an unknown sender; $mime is "" when omitted;
        //   $wire_id shares the message namespace; $reply_to is NIL unless a reply.
        on_file_received is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_file_received hook is unset in a2a_messaging (call a2a_messaging::init)." when TRUE. return []. }
        // on_file_sent ($target_id, $filename, $mime, $data, $date, $wire_id,
        //   $reply_to): fired after the wire send is queued (agent: no-op;
        //   messenger: append an outgoing file history entry keyed by $wire_id).
        on_file_sent is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { abort "on_file_sent hook is unset in a2a_messaging (call a2a_messaging::init)." when TRUE. return []. }
        // on_receipt_received ($sender_id, $kind "delivered"|"read", $wire_ids
        //   str[], $date time+): a peer confirmed delivery/read of messages we
        //   sent (core 0.7.0 receipts). DEFAULT NO-OP — receipts are best-effort
        //   UX, never load-bearing; an app that doesn't wire the hook silently
        //   drops them. Hook contract (normative): application is MONOTONIC per
        //   (peer, wire_id) on unknown < sent < delivered < read — duplicates
        //   and out-of-order arrivals collapse to no-ops.
        on_receipt_received is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { return []. }
        // Optional core middleware at the successful message-send choke point.
        // Integration modules install it without coupling messaging to them.
        // Default no-op preserves every existing consumer.
        post_send_middleware is (any -> transaction::action::type[]) = fn (_: any) -> transaction::action::type[] { return []. }
    }

    init = fn (_:(
        $_read_or_abort -> read: (bin->any),
        $on_message_received -> received_cb: (any -> transaction::action::type[]),
        $on_message_sent -> sent_cb: (any -> transaction::action::type[]),
        $on_contact_removed -> removed_cb: (any -> transaction::action::type[]),
        $on_file_received -> file_received_cb: (any -> transaction::action::type[]),
        $on_file_sent -> file_sent_cb: (any -> transaction::action::type[]),
        // core 0.7.0, OPTIONAL (absent from pre-0.7 callers): receipt consumer.
        $on_receipt_received -> receipt_cb: (any -> transaction::action::type[])+
    ))
    {
        _read_or_abort -> read.
        on_message_received -> received_cb.
        on_message_sent -> sent_cb.
        on_contact_removed -> removed_cb.
        on_file_received -> file_received_cb.
        on_file_sent -> file_sent_cb.
        if receipt_cb != NIL { on_receipt_received -> receipt_cb?. }
        // core 0.9.0 (spec §5.5): register the decode-seam migration-pending predicate so
        // the adapt e2e receive path STAGES an inbound migration-commit PRE_KEY (instead of
        // unilaterally replacing the live session). TRUE only while a migration is genuinely
        // IN-FLIGHT for the cid (offered/acknowledged/committed) — NEVER post-active: an
        // epoch-pinned contact's self-heal pre-key must go through recovery/route, not raw
        // staging. Empty FSM (no migration) -> FALSE -> pure 0.8.0 decode behavior.
        e2e::set_mig_pending_hook (fn (c: global_id) -> bool
        {
            st = contact_migration c.
            if st == NIL { return FALSE. }
            ph = (st?) $phase.
            return ph == "offered" || ph == "acknowledged" || ph == "committed".
        }).
    }

    // Separate from init so an integration importing a2a_messaging can install
    // after the consumer has wired its ordinary storage hooks.
    fn set_post_send_middleware (cb: (any -> transaction::action::type[])) -> nil
    {
        post_send_middleware -> cb.
    }

    // ---- shared action builders -------------------------------------------
    // Signal the host to persist the packet. Only emitted at the end of a
    // complete procedure — intermediate states (e.g. channel handshake) are
    // never saved, so a crash mid-handshake restores to the last stable point.
    fn _save_state (_) = (transaction::action::return_data ($kind -> $save_state)).
    fn _return_data (payload: any) = (transaction::action::return_data ($kind -> $data, $payload -> payload)).
    fn _notify_agent (payload: any) = (transaction::action::return_data ($kind -> $notify_agent, $payload -> payload)).

    // ---- forced monitoring copy (UNCONDITIONAL core; see a2a_monitoring) ----
    // Uniform rule: if a control plane is bound, fire-and-forget ONE re-encrypted
    // copy of this message to it; otherwise nothing. No local queue and no
    // liveness wait — if the control plane is offline the ADAPT broker holds the
    // pending message (delivery is the framework's job, not the app's). The copy
    // rides a DISTINCT transaction name (receive_monitoring_copy), never
    // send_message, so the copy traffic is not itself monitored (no recursion).
    // Called unconditionally by send_message + handle_receive_message; it
    // self-gates on monitoring_proxy, which only the bind ceremony can set.
    fn monitor_copy_actions (direction: str, peer_cid: global_id, date: time, body: str) -> transaction::action::type[]
    {
        if monitoring_proxy == NIL { return []. }
        peer_name is str = "".
        p = contacts peer_cid.
        if p != NIL { peer_name -> p? $name. }
        copy is monitoring_copy_t = (
            $version   -> 1,
            $direction -> direction,
            $peer_cid  -> peer_cid,
            $peer_name -> peer_name,
            $date      -> date,
            $body      -> body
        ).
        // The control plane is a registered contact (the bind established its
        // channel), so this is a plain encrypted send action — ciphertext on the
        // wire under the control-plane key, never plaintext.
        return [
            encrypted_channel::send_encrypted_tx (monitoring_proxy? $proxy_cid) (
                $name -> receive_monitoring_copy_tx,
                $targ -> ($copy -> copy, $pv -> a2a_versions::wire_version)
            )
        ].
    }

    // core 3.2: generic fire-and-forget push to the bound control plane. Same rule
    // as monitor_copy_actions: self-gates on monitoring_proxy, rides a DISTINCT trn
    // name (so the push is not itself monitored), native record (no JSON).
    fn push_to_cp_actions (tx_name: str, targ: any) -> transaction::action::type[]
    {
        if monitoring_proxy == NIL { return []. }
        return [
            encrypted_channel::send_encrypted_tx (monitoring_proxy? $proxy_cid) (
                $name -> tx_name,
                $targ -> targ
            )
        ].
    }

    // Authorize a control-plane configuration write: the sender must BE the bound
    // control plane (monitoring_proxy). Config authority == the same CP that
    // monitoring is bound to. Aborts otherwise.
    fn require_bound_cp_or_abort (sender_id: global_id) -> nil
    {
        abort "No control plane is bound." when monitoring_proxy == NIL.
        abort "Only the bound control plane may configure this node." when sender_id != (monitoring_proxy? $proxy_cid).
    }

    // RR-9 single pre-dispatch authz gate (CLUSTER_API.md §3). The STATEFUL half:
    // a2a_capabilities holds the pure control_auth_class policy (it cannot read
    // monitoring_proxy — hidden HERE, and a2a_capabilities is the lower layer);
    // this fn combines that class with the bound-proxy identity. Wired into
    // a2a_capabilities::init as $authorizer, called by dispatch BEFORE routing any
    // controller-class verb. Returns TRUE iff the sender may run (cap,verb):
    //   public/bootstrap -> TRUE (bind's own 6-digit check is in its handler);
    //   deny             -> FALSE;
    //   controller       -> the sender must BE the bound control proxy.
    // Takes `any` (not a typed arg record) so it is DIRECTLY assignable to
    // a2a_capabilities::init's $authorizer field, which is (any -> bool): a typed
    // arg signature is not assignable there under function-arg contravariance, so
    // an app would otherwise need a wrapper. Extract the fields here instead.
    fn authorize_control (args: any) -> bool
    {
        cap = (args $cap) safe str.
        verb = (args $verb) safe str.
        klass = a2a_capabilities::control_auth_class ($cap -> cap, $verb -> verb).
        if klass == "public" || klass == "bootstrap" { return TRUE. }
        if klass == "deny" { return FALSE. }
        return monitoring_proxy != NIL && ((args $sender_id) safe global_id) == (monitoring_proxy? $proxy_cid).
    }

    // This node's ceremony-pinned cluster CP (its monitoring_proxy $proxy_cid), or
    // NIL if unbound. The cluster set_monitoring handler DERIVES the CP a child is
    // host-bound to from THIS — never a caller parameter (critic's load-bearing
    // condition): a child's monitoring_proxy is only ever set to the root's OWN
    // ceremony-pinned CP, so host-mediation cannot bind a child to an un-ceremonied
    // CP (which would be a developer-held-credential equivalent / ceremony bypass).
    fn bound_cp_cid (_) -> global_id+
    {
        if monitoring_proxy == NIL { return NIL. }
        return monitoring_proxy? $proxy_cid.
    }

    fn next_roster_seq (_) -> int { roster_push_seq -> roster_push_seq + 1. return roster_push_seq. }
    fn current_roster_seq (_) -> int { return roster_push_seq. }

    // Host-mediated REVOCATION of a CHILD's monitoring (origin::user, host-fired on
    // the child packet). CHILD-ONLY: aborts on a root/standalone (delegation_cert==NIL)
    // so the standalone "only the bound CP may disable" property is preserved —
    // cluster children's monitoring is host-propagated-from-the-root-ceremony, so the
    // root-operator (host-control posture, SECURITY-MODEL.md) revokes it. REAL
    // revocation (criterion e): clears monitoring_proxy so monitor_copy_actions stops
    // forwarding immediately. (Enable reuses set_proxy_pending+verify_proxy_code,
    // host-run on the child — no new bind path, ceremony pin preserved.)
    trn host_clear_child_monitoring _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        abort "host_clear_child_monitoring is cluster-children-only (a root/standalone node's monitoring is CP-cleared, not host-cleared)." when delegation_cert == NIL.
        // RR9-C12 full teardown (minimal-exposure): also DROP the CP contact that
        // host_register_monitoring_cp injected, so the child↔CP relationship does not
        // outlive the monitoring it was established for. Read the cp from monitoring_proxy
        // BEFORE clearing it. Re-enable cheaply re-injects via host_register_monitoring_cp.
        if monitoring_proxy != NIL
        {
            cp_cid = monitoring_proxy? $proxy_cid.
            peer_ads cp_cid -> NIL.
            contacts cp_cid -> NIL.
        }
        monitoring_proxy -> NIL.
        proxy_pending -> NIL.
        // Trivial ack so the daemon's mutatingTx await resolves immediately (a
        // save-only trn emits no $data → await blocks to timeout under the root lock).
        return transaction::success [ _return_data ($ok -> TRUE), _save_state NIL ].
    }

    // Host-mediated delivery of the cluster CP as a CONTACT to a CHILD packet
    // (origin::user, host-fired), so per-child monitoring can RESOLVE and FORWARD to
    // the CP. Why host-mediated, not a network introduce: the child's introduction
    // acceptance gate (ingest_connect_descriptor / require_cluster_cp_or_abort) only
    // accepts a relay FROM the child's own CP, so a ROOT-relayed introduce is rejected
    // (the root isn't the child's CP) AND a network introduce would race the ceremony.
    // The daemon, which hosts the child, injects the CP contact directly. SECURITY: the
    // CP AD is still VERIFIED here (process_address_document = self-sig + proof-of-
    // possession, aborts on a forged/inconsistent document), so a forged CP cannot be
    // injected. Stores peer_ads + a contacts entry so resolve_contact(cp) resolves and
    // monitor_copy_actions' encrypted send can establish the child->CP channel. Only the
    // host (origin::user) can call it; ordered by the daemon BEFORE the bind ceremony.
    trn host_register_monitoring_cp _:($cp_ad -> cp_ad: address_document_types::t_address_document)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        address_document::process_address_document cp_ad TRUE.
        cp_cid = cp_ad $identity $container_id.
        peer_ads cp_cid -> cp_ad.
        if (contacts cp_cid) == NIL { contacts cp_cid -> ($name -> "control-plane", $container_id -> cp_cid). }
        // Trivial ack so the daemon's mutatingTx await resolves immediately (save-only
        // → no $data → await blocks to timeout under the root lock).
        return transaction::success [ _return_data ($ok -> TRUE), _save_state NIL ].
    }

    // Authorize an introduction relay (core.connect) — ADDITIVE successor to
    // require_bound_cp_or_abort. A relay is accepted on EITHER of two grounds:
    //   (a) Legacy direct bind — this node ran the 6-digit ceremony itself, so the
    //       sender IS its own monitoring_proxy. Unchanged behaviour, non-breaking.
    //   (b) Inherited cluster CP — the sender is the CP my ROOT designated. The role
    //       binds nothing itself: it inherits root_cp_binding (the root-signed edge)
    //       and root_ad (the root's pinned keys), and verifies the edge LOCALLY, with
    //       no round-trip and no per-child ceremony.
    // Security (critic invariant #3): the inherited branch re-derives trust from the
    // pinned root_ad on EVERY call — verify_root_cp_binding does NOT check cid_cp, so
    // we (1) assert sender_id == root_cp_binding.cid_cp AND (2) verify the binding's
    // signature/context/root_cid against root_ad's OWN container id + key list (never
    // the cid_cp stored in the binding, never keys carried by the binding). A
    // signature-valid binding whose cid_cp is unpinned, or that verifies against the
    // wrong root keys, is rejected.
    fn require_cluster_cp_or_abort (sender_id: global_id) -> nil
    {
        // (a) legacy direct bind: short-circuit, leave the inherited path unevaluated.
        legacy_ok = monitoring_proxy != NIL && sender_id == (monitoring_proxy? $proxy_cid).
        if legacy_ok != TRUE
        {
            // (b) inherited cluster CP — require both the binding and the pinned root.
            abort "Unauthorized introduction relay: no bound control plane and no inherited root CP binding." when root_cp_binding == NIL || root_ad == NIL.
            // (1) the relay must come from the exact CP my root designated.
            abort "Unauthorized introduction relay: sender is not the CP my root designated." when sender_id != (root_cp_binding? $c $cid_cp).
            // (2) re-verify the root-signed edge against my pinned root identity every call.
            abort "Unauthorized introduction relay: root CP binding does not verify against my pinned root identity." when a2a_protocol::verify_root_cp_binding (root_cp_binding?) (root_ad? $identity $container_id) (root_ad? $identity $key_list) != TRUE.
        }
    }

    // Resolve a contact reference (a display name or stringified container id)
    // to a container id; aborts if no contact matches.
    fn resolve_contact (ref: str) -> global_id
    {
        found is global_id+ = NIL.
        sc contacts -- (cid -> c) ?? found == NIL && ((c $name) == ref || (_str cid) == ref)
        {
            found -> cid.
        }
        abort "Unknown contact: " + ref when found == NIL.
        return found?.
    }

    // ---- user transactions --------------------------------------------------

    trn set_my_name _:($name -> name: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        my_name -> name.
        return transaction::success [
            _return_data ($name -> name),
            _save_state NIL
        ].
    }

    trn set_my_bio _:($bio -> bio: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        my_bio -> bio.
        return transaction::success [
            _return_data ($bio -> bio),
            _save_state NIL
        ].
    }

    trn set_my_persona _:($persona -> persona: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        my_persona -> persona.
        return transaction::success [
            _return_data ($persona -> persona),
            _save_state NIL
        ].
    }

    // Host-fired (ROOT only, core 2.2): mint this root's §3c CP binding. The root
    // self-signs {context_tag, root_cid=me, cid_cp} so its roles can TOFU-pin "my
    // root designated CP X" and accept that CP's introductions locally. STATELESS and
    // root-only, mirroring sign_delegation: it returns the signed blob; the daemon
    // stores it on the root via set_root_cp_binding (own-identity verify) and pushes
    // the SAME blob to each role via set_root_cp_binding (root_ad verify). This is the
    // root-side PRODUCER core 2.1 deferred (it shipped only the verifier + store + the
    // accept gate); without it nothing could create the binding the cluster needs.
    trn sign_root_cp_binding _:($proxy -> proxy_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        abort "Only a root identity can mint a CP binding." when delegation_cert != NIL.

        cid_cp = resolve_contact proxy_ref.
        core is a2a_protocol::root_cp_binding_core_t = (
            $version     -> 1,
            $context_tag -> a2a_protocol::cp_attestation_context_tag,
            $root_cid    -> _get_container_id(),
            $cid_cp      -> cid_cp
        ).
        binding is a2a_protocol::root_cp_binding_t = ($c -> core, $s -> key_storage::default_sign (_value_id core)).
        return transaction::success [
            _return_data ($binding -> (_write binding), $cid_cp -> (_str cid_cp))
        ].
    }

    // Host-fired: store a root-signed CP binding for THIS node's root edge. DUAL-MODE
    // (core 2.2 widened the verify path — additive, rejects strictly more):
    //   • ROOT (delegation_cert == NIL): the binding is the root's OWN self-signed edge
    //     (sign_root_cp_binding above); verified against this node's own identity —
    //     unchanged from 2.1.
    //   • ROLE (delegation_cert != NIL): the binding is the root's edge INHERITED by the
    //     role; verified against the role's PINNED root_ad — the SAME keys and verifier
    //     the require_cluster_cp_or_abort accept gate uses, so a role can store only an
    //     edge its OWN root actually signed. This fills root_cp_binding (which the gate
    //     reads), letting a child accept CP introductions with zero per-child ceremony.
    // verify_root_cp_binding enforces, on the role path: (a) binding.root_cid == the
    // pinned root_ad's container id — an edge signed by ANY other root is rejected;
    // (b) the signature against root_ad's key list under the domain-separated context_tag,
    // which also covers (c) cid_cp integrity (cid_cp is inside the signed core record).
    // Fails CLOSED on any mismatch. The binding also rides the existing invite/state-push
    // paths (generate_invite $rpb, export/import_core_state).
    trn set_root_cp_binding _:($binding -> binding_blob: bin)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        binding = (_read_or_abort binding_blob) safe a2a_protocol::root_cp_binding_t.
        if delegation_cert != NIL
        {
            abort "Cannot inherit a root CP binding without pinned root material." when root_ad == NIL.
            abort "Inherited root CP binding does not verify against my pinned root identity." when a2a_protocol::verify_root_cp_binding binding (root_ad? $identity $container_id) (root_ad? $identity $key_list) != TRUE.
        }
        else
        {
            my_ad = address_document::get_my_address_document().
            abort "Root CP binding does not verify against this node's own root identity." when a2a_protocol::verify_root_cp_binding binding (my_ad $identity $container_id) (my_ad $identity $key_list) != TRUE.
        }
        root_cp_binding -> binding.
        return transaction::success [
            _return_data ($cid_cp -> _str (binding $c $cid_cp)),
            _save_state NIL
        ].
    }

    // ---- shared identity-bundle helpers (invite legs + contact-restore legs) ----
    // My identity bundle payload fields: my AD plus, when I am a delegated role,
    // my chain blobs (cert / root profile / optional §3c cp binding). The caller
    // appends its own correlation id ($invite_id or $rid) and _write's the record.
    // peer_is_v1 (NULLABLE): TRUE emits a v1 (down-levelled, bundle-less) address
    // document so an older peer accepts it; NIL/FALSE emits the current AD. The
    // invite/handshake down-level sites pass a computed bool; the contact-restore
    // sites pass NIL (unchanged behaviour).
    fn my_identity_bundle_fields (peer_is_v1: bool+) -> ($ad -> address_document_types::t_address_document, $cert -> bin+, $root_profile -> bin+, $cp_binding -> bin+)
    {
        my_cert_blob is bin+ = NIL.
        my_rp_blob is bin+ = NIL.
        my_rpb_blob is bin+ = NIL.
        down_level = (peer_is_v1 != NIL) && (peer_is_v1?).
        // The cert I attach MUST commit to the same AD version I attach: a v1 peer
        // hashes the v1 AD it receives and compares it to cert.$role_ad_hash, so a
        // down-level MUST carry the v1-AD-bound cert (delegation_cert_v1). If it is
        // absent (a role whose host predates the v1-cert mint), send the AD WITHOUT
        // a chain rather than a mismatching v2 cert — a bundle-less contact with no
        // recorded root linkage still connects (verify_identity_bundle treats a NIL
        // cert as a flat identity); attaching the v2 cert would abort the peer.
        eff_cert is a2a_protocol::delegation_cert_t+ = delegation_cert.
        if down_level { eff_cert -> delegation_cert_v1. }
        if eff_cert != NIL && root_profile != NIL
        {
            my_cert_blob -> (_write eff_cert?).
            my_rp_blob -> (_write root_profile?).
            if root_cp_binding != NIL { my_rpb_blob -> (_write root_cp_binding?). }
        }
        return ($ad -> address_document::get_my_address_document_versioned(peer_is_v1), $cert -> my_cert_blob, $root_profile -> my_rp_blob, $cp_binding -> my_rpb_blob).
    }

    // ---- core 0.8.0 E2E capability + monotonic anti-downgrade ----------------
    // Positive-evidence pin: the FIRST time a peer's advertised caps include
    // core.e2e, mark it — and never unmark. Called from every version-learning
    // leg (via learn_contact_version), so the pin tracks the same evidence as
    // contact_caps but MONOTONICALLY (contact_caps is last-seen-wins and would
    // lose the evidence on a caps-absent inbound). A no-op when caps lack core.e2e.
    // Inline cap-scan (not caps_contains, which is defined later — MUFL resolves
    // symbols define-before-use).
    fn note_e2e_seen (cid: global_id, caps: str[]) -> nil
    {
        sc caps -- ( -> c) { if c == a2a_capabilities::cap_e2e { contact_e2e_seen cid -> TRUE.  return. } }
    }
    fn e2e_pinned (cid: global_id) -> bool { return (contact_e2e_seen cid) == TRUE. }

    // Does the peer's cached AD carry an AD v2 $e2e_bundle (adapt owns the type
    // and populates it via process_address_document)? Read via `as any` so this
    // compiles against a pre-v2 address_document type and lights up once adapt's
    // AD v2 lands. NIL/absent -> FALSE (no bundle -> cannot establish a session).
    fn peer_has_e2e_bundle (cid: global_id) -> bool
    {
        ad = peer_ads cid.
        if ad == NIL { return FALSE. }
        return (((ad?) as any) $identity $e2e_bundle) != NIL.
    }

    // Send-side APP-DATA routing (spec §5.6, five-state, error-as-data — NOT a hard
    // abort; cf. receipt_gate which returns without aborting). Core is the single
    // routing authority; the daemon obeys this verdict for its e2e app-send path.
    // The four e2e_migrate_* CONTROL legs are EXEMPT (carve-out, must-fix #5): they
    // ride encrypted_channel (mgb offer/ack) / the fresh e2e session (mgc commit/
    // confirm) BY CONSTRUCTION and never pass through this route.
    //   "e2e"               -> app data rides the migrated e2e session (daemon path)
    //   "legacy"            -> first-contact / genuinely-v1 peer / pre-commit: box
    //                          (or a pre-epoch e2e session for already-E2E pairs)
    //   "migrating"         -> initiator commit window: QUEUE in mig_deferred, flush on active
    //   "downgrade_refused" -> once E2E (pinned) but no current v2 bundle: fail CLOSED
    //                          (never silently box a migrated peer) → typed refusal + recovery
    fn e2e_route (cid: global_id) -> str
    {
        ep = contact_migration cid.
        if (contact_e2e_epoch cid) != NIL
        {   // cryptographically committed (epoch pinned): legacy PROHIBITED, irreversibly.
            if peer_has_e2e_bundle cid { return "e2e". }   // session errors surface at the adapt seam
            return "downgrade_refused".
        }
        // Only the INITIATOR sits in a committed app-send window (the responder's
        // committed->active is atomic in one tx, so it never queues app data).
        if ep != NIL && ((ep?) $phase) == "committed" && ((ep?) $initiator) == TRUE { return "migrating". }
        seen = e2e_pinned cid.   v2 = peer_has_e2e_bundle cid.
        if seen && v2 != TRUE { return "downgrade_refused". }   // imported 0.8.0 pin, AD absent
        return ((seen || v2) ?? "e2e" ; "legacy").
    }

    // ---- core 0.9.0 migration helpers (spec §5.2) ----------------------------
    // Deterministic total order on the hex container ids. MUFL '<' is lexicographic
    // on strings (pinned in tests/mufl_semantics), which is a total order — both
    // sides compute the same answer from the pinned cids (§5.9-2: any deterministic
    // shared order works). Used ONLY to elect exactly one proposer; never authz.
    fn str_lt (a: str, b: str) -> bool { return a < b. }

    // Exactly-once agreement needs exactly one proposer: the LOWER cid initiates.
    // Stable across restarts/imports/simultaneous upgrades — both sides derive it
    // from the pinned ids, so no tie-breaking state is ever needed.
    fn mig_initiator (peer: global_id) -> bool
    { return str_lt (_str (_get_container_id())) (_str peer). }

    // Fingerprint of an AD's E2E prekey bundle — the epoch input AND the rotation
    // detector (a live-vs-snapshot fp mismatch at retransmit forces supersession).
    fn e2e_bundle_fp (ad: address_document_types::t_address_document) -> bin
    { return _hash_code_to_binary (_value_id (((ad as any) $identity $e2e_bundle))). }

    // Epoch: both parties derive the SAME 32-byte id from authenticated inputs — the
    // cid-ORDERED ids, both proposal nonces, both FRESH bundle fingerprints. Domain-
    // separated; any input change (re-offer / re-published AD) => a new epoch, so a
    // stale commit can never validate against a refreshed agreement. Callers MUST pass
    // the inputs in cid order (lo < hi) so both sides agree regardless of who proposed.
    fn mig_epoch (lo: global_id, hi: global_id, n_lo: bin, n_hi: bin, f_lo: bin, f_hi: bin) -> bin
    {
        return _hash_code_to_binary (_value_id (
            $proto -> "ours/e2e-migration/v1",
            $a -> lo, $b -> hi, $na -> n_lo, $nb -> n_hi, $fa -> f_lo, $fb -> f_hi )).
    }

    // FRESH identity bundle (§5.9-4): the migration legs must carry the CURRENT
    // signed AD, so they build via produce_my_address_document (rebuild + re-sign,
    // embedding e2e::my_public_bundle) rather than the CACHED get_my_address_document
    // (which can pre-date the live account fallback). Same shape as
    // my_identity_bundle_fields; only the AD source differs.
    fn my_identity_bundle_fields_fresh (_) -> ($ad -> address_document_types::t_address_document, $cert -> bin+, $root_profile -> bin+, $cp_binding -> bin+)
    {
        my_cert_blob is bin+ = NIL.
        my_rp_blob is bin+ = NIL.
        my_rpb_blob is bin+ = NIL.
        if delegation_cert != NIL && root_profile != NIL
        {
            my_cert_blob -> (_write delegation_cert?).
            my_rp_blob -> (_write root_profile?).
            if root_cp_binding != NIL { my_rpb_blob -> (_write root_cp_binding?). }
        }
        return ($ad -> address_document::produce_my_address_document(), $cert -> my_cert_blob, $root_profile -> my_rp_blob, $cp_binding -> my_rpb_blob).
    }

    // core 0.11 self-heal TRIGGER (receive side of a failed decode). A decode failure with
    // one of the desync codes from an ACCEPTED e2e contact means the pair's session views
    // diverged. Since persist-primary a clean restart RESUMES the live sessions, so this is
    // the TRUE-loss path (state lost/rejected → account re-minted, sessions gone): the peer
    // sends olm_type=1 on a session I no longer hold, or its fresh pre-key carries an ik my
    // stored peer_ads predates. The message itself is undecryptable forever — recovery =
    // tell the peer, authenticated, to re-key AND to refresh my AD (my re-minted account
    // makes my previously advertised e2e_bundle stale). Rate-limited per (cid, session_id).
    fn rekey_desync_code (code: str) -> bool
    {
        return code == "no_session" || code == "session_mismatch" || code == "tampered".
    }
    // Retain an outbound e2e app send until its delivered/read receipt (redrive source).
    // Bounded three ways, never an abort: entry count (unacked_cap, oldest first),
    // per-contact bytes (unacked_max_bytes — an entry alone above the budget is not
    // retained at all), and age (unacked_ttl_seconds, purged by the periodic sweep).
    // Typed retention result (review #7): the caller must SURFACE what the redrive
    // guarantee actually covers. $retained FALSE = this send exceeded its byte budget
    // and will NOT auto-resend on a lost session; $evicted = wire_ids of OLDER sends
    // shed to admit this one (their at-least-once guarantee just ended) — never a
    // silent drop.
    fn unacked_note (cid: global_id, kind: str, wire_id: str, inner: bin, date: time)
        -> ( $retained -> bool, $evicted -> str[] )
    {
        new_len = _binlen inner.
        entry_cap is int = unacked_max_bytes.
        if kind == "f" { entry_cap -> unacked_file_entry_max_bytes. }
        if new_len > entry_cap { return ( $retained -> FALSE, $evicted -> [] ). }
        evicted is str[] = [].
        q0 = unacked_e2e cid.
        kept is unacked_entry_t[] = [].
        if q0 != NIL
        {
            // Totals INCLUDING the new entry, then shed oldest-first until both
            // budgets (count, bytes) hold; copy the surviving suffix in order.
            total is int = new_len.
            cnt is int = 1.
            sc q0? -- ( -> ent) { total -> total + (_binlen (ent $inner)).  cnt -> cnt + 1. }
            drop is int = 0.
            sc q0? -- ( -> ent)
            {
                if cnt > unacked_cap || total > unacked_max_bytes
                {
                    total -> total - (_binlen (ent $inner)).
                    cnt -> cnt - 1.
                    drop -> drop + 1.
                    evicted (_count evicted|) -> (ent $wire_id).
                }
            }
            i is int = 0.
            sc q0? -- ( -> ent) { if i >= drop { kept (_count kept|) -> ent. }  i -> i + 1. }
        }
        kept (_count kept|) -> ($kind -> kind, $wire_id -> wire_id, $inner -> inner, $date -> date).
        unacked_e2e cid -> kept.
        return ( $retained -> TRUE, $evicted -> evicted ).
    }
    // Receive-side dedup store (see delivered_wire above): membership probe + bounded note.
    fn wire_seen (cid: global_id, wire_id: str) -> bool
    {
        q = delivered_wire cid.
        if q == NIL { return FALSE. }
        hit is bool = FALSE.
        sc q? -- ( -> e) { if (e $w) == wire_id { hit -> TRUE. } }
        return hit.
    }
    // AGE-ONLY retention (ship-review major-3): an entry is evicted only past
    // unacked_ttl_seconds — no count-based eviction inside the sender's redrive
    // window. The hard storage ceiling above is the sole exception; crossing it
    // returns the dropped wire_id so the CALLER surfaces the guarantee loss.
    fn delivered_note (cid: global_id, wire_id: str) -> ( $dropped -> str+ )
    {
        dropped is str+ = NIL.
        if wire_id != ""
        {
            now = (current_transaction_info::get_transaction_time())?.
            q0 = delivered_wire cid.
            aged is delivered_entry_t[] = [].
            if q0 != NIL
            {
                sc q0? -- ( -> e)
                { if (_substract_seconds now (e $d)) <= unacked_ttl_seconds { aged (_count aged|) -> e. } }
            }
            q is delivered_entry_t[] = [].
            skip is int = 0.
            if (_count aged|) >= delivered_wire_hard_cap
            {
                skip -> 1.
                sc aged -- ( -> e) { if dropped == NIL { dropped -> (e $w). } }
            }
            i is int = 0.
            sc aged -- ( -> e) { if i >= skip { q (_count q|) -> e. }  i -> i + 1. }
            q (_count q|) -> ($w -> wire_id, $d -> now).
            delivered_wire cid -> q.
        }
        return ( $dropped -> dropped ).
    }
    // Drop the entries a delivered/read receipt covers. Returns TRUE when anything cleared.
    fn unacked_clear (cid: global_id, ids: str[]) -> bool
    {
        q0 = unacked_e2e cid.
        if q0 == NIL { return FALSE. }
        q is unacked_entry_t[] = [].
        dropped is bool = FALSE.
        sc q0? -- ( -> ent)
        {
            hit is bool = FALSE.
            sc ids -- ( -> w) { if w == (ent $wire_id) { hit -> TRUE. } }
            if hit { dropped -> TRUE. } else { q (_count q|) -> ent. }
        }
        if dropped != TRUE { return FALSE. }
        if (_count q|) == 0 { delete unacked_e2e cid. } else { unacked_e2e cid -> q. }
        return TRUE.
    }
    // Re-send every retained unacked message to cid, re-encrypted on the CURRENT session
    // (encrypt_to lazily establishes a fresh born-DR pre-key when none is live). Entries
    // STAY in the buffer — they clear on the delivered receipt (at-least-once; receivers
    // key receipts/dedup by wire_id). No-op without a usable peer bundle.
    // Does this peer advertise the self-heal cap (Leg-5 compat gate)? A pre-0.11 peer never
    // receives the unknown e2e_rekey_request tx — it gets a readvertise_ad instead.
    fn peer_supports_rekey (cid: global_id) -> bool
    {
        pcaps = contact_caps cid.
        if pcaps == NIL { return FALSE. }
        hit is bool = FALSE.
        sc pcaps? -- ( -> c) { if c == a2a_capabilities::cap_e2e_rekey { hit -> TRUE. } }
        return hit.
    }
    fn redrive_unacked_actions (cid: global_id) -> transaction::action::type[]
    {
        // Cap-gate (finding F): the at-least-once redrive REQUIRES receive-side
        // wire_id dedup, which only a 0.11 (cap_e2e_rekey) peer has. Replaying into
        // a pre-0.11 peer would deposit duplicates it cannot recognize. Its heal
        // path stays the readvertise + next-real-send establish (pre-existing).
        if (peer_supports_rekey cid) != TRUE { return []. }
        q = unacked_e2e cid.
        if q == NIL || (_count (q?)|) == 0 { return []. }
        pad = peer_ads cid.
        if pad == NIL { return []. }
        epb = (((pad?) as any) $identity $e2e_bundle) safe address_document_types::t_e2e_bundle.
        if epb == NIL { return []. }
        acts is transaction::action::type[] = [].
        sc q? -- ( -> ent)
        {
            eenv = e2e::encrypt_to cid (ent $inner) epb.
            acts (_count acts|) -> encrypted_channel::send_encrypted_tx cid (
                $name -> ((ent $kind) == "f" ?? receive_e2e_file_tx ; receive_e2e_message_tx),
                $targ -> ( $e2e_envelope -> (eenv $e2e_envelope), $emsignature -> (eenv $emsignature) ) ).
            acts (_count acts|) -> _notify_agent ( $event -> $e2e_app_send, $cid -> cid,
                $session_id -> ((eenv $e2e_envelope) $session_id), $olm_type -> ((eenv $e2e_envelope) $olm_type),
                $wire_id -> (ent $wire_id), $redriven -> TRUE ).
        }
        return acts.
    }
    // A CONTENTLESS e2e pre-key ("rekey ping"): the initiator sends it to BOOTSTRAP the shared
    // session when it has minted a fresh outbound but has no buffered app data to carry the
    // pre-key. The peer's decode establishes the session (and its session-replace redrives its
    // own buffer); the $rekey_ping marker suppresses any inbox deposit. Requires a live/just-
    // minted session (caller mints first); no-op without a peer bundle.
    fn rekey_ping_actions (cid: global_id) -> transaction::action::type[]
    {
        // Cap-gate (finding F): a pre-0.11 peer does not understand the $rekey_ping
        // marker — its receive path would treat the contentless bootstrap as an app
        // message. Only cap-advertising peers get pings.
        if (peer_supports_rekey cid) != TRUE { return []. }
        pad = peer_ads cid.
        if pad == NIL { return []. }
        epb = (((pad?) as any) $identity $e2e_bundle) safe address_document_types::t_e2e_bundle.
        if epb == NIL { return []. }
        pinner = _write ( $rekey_ping -> TRUE, $pv -> a2a_versions::wire_version ).
        eenv = e2e::encrypt_to cid pinner epb.
        return [ encrypted_channel::send_encrypted_tx cid (
                     $name -> receive_e2e_message_tx,
                     $targ -> ( $e2e_envelope -> (eenv $e2e_envelope), $emsignature -> (eenv $emsignature) ) ),
                 _notify_agent ( $event -> $e2e_app_send, $cid -> cid, $rekey_ping -> TRUE,
                     $session_id -> ((eenv $e2e_envelope) $session_id), $olm_type -> ((eenv $e2e_envelope) $olm_type) ) ].
    }
    // SIGNAL the peer to (re-)establish: carry my FRESH AD so it can authenticate my pre-keys,
    // and — if it speaks the cap — ask it to re-key. fsid is ADVISORY ($failed_session_id, NIL
    // for a proactive send-side nudge). Rate-limited per cid (attempts within a window) so a
    // decode-fail storm or a spammer cannot amplify. Sends exactly ONE control message. Does
    // NOT mint or redrive — the caller decides that by role (only the initiator mints).
    fn rekey_signal_actions (cid: global_id, fsid: bin+) -> transaction::action::type[]
    {
        now = (current_transaction_info::get_transaction_time())?.
        st = rekey_pending cid.
        att is int = 1.
        if st != NIL && (_substract_seconds now ((st?) $updated)) < rekey_min_interval_seconds
        {
            if ((st?) $attempts) >= rekey_max_attempts { return []. }
            att -> ((st?) $attempts) + 1.
        }
        rekey_pending cid -> ($session_id -> fsid, $attempts -> att, $updated -> now).
        b = my_identity_bundle_fields_fresh NIL.
        supports = peer_supports_rekey cid.
        acts is transaction::action::type[] = [].
        if supports
        {
            acts (_count acts|) -> encrypted_channel::send_encrypted_tx cid (
                $name -> e2e_rekey_request_tx,
                $targ -> ( $ad -> (b $ad), $cert -> (b $cert), $root_profile -> (b $root_profile),
                           $cp_binding -> (b $cp_binding),
                           $pv -> a2a_versions::wire_version,
                           $caps -> (a2a_capabilities::self_cap_ids NIL),
                           $failed_session_id -> fsid ) ).
        }
        else
        {
            acts (_count acts|) -> encrypted_channel::send_encrypted_tx cid (
                $name -> readvertise_ad_tx,
                $targ -> ( $ad -> (b $ad), $cert -> (b $cert), $root_profile -> (b $root_profile),
                           $cp_binding -> (b $cp_binding),
                           $pv -> a2a_versions::wire_version,
                           $caps -> (a2a_capabilities::self_cap_ids NIL) ) ).
        }
        acts (_count acts|) -> _notify_agent ($event -> $e2e_rekey, $cid -> cid, $role -> $requester, $session_id -> fsid, $attempts -> att, $peer_supports -> supports).
        return acts.
    }
    // INITIATOR-ONLY re-establishment: mint ONE fresh outbound session (the sole new session
    // the pair converges on) and drive a pre-key to the peer — redriving buffered sends, or a
    // contentless ping if there is nothing to carry. Returns [] (mints nothing) unless I am the
    // elected initiator (lower cid), the cid-keyed budget allows it, the advisory fsid is not
    // stale, and no migration is in flight (the FSM owns re-key then). The NON-initiator never
    // calls through here — it signals and waits for THIS side's pre-key.
    fn maybe_init_rekey (cid: global_id, fsid: bin+) -> transaction::action::type[]
    {
        // Review #5: the whole self-heal replay/bootstrap is cap-gated, not just the
        // rekey_request leg — a pre-0.11 peer has no delivered_wire dedup (replay
        // would deposit duplicates) and no $rekey_ping handling (the contentless
        // bootstrap would surface as a broken app message). Its heal path remains
        // readvertise + the next real outbound establishing a fresh session.
        if (peer_supports_rekey cid) != TRUE { return []. }
        if (mig_initiator cid) != TRUE { return []. }
        if (peer_has_e2e_bundle cid) != TRUE { return []. }
        st = contact_migration cid.
        if st != NIL
        {
            ph = (st?) $phase.
            if ph == "offered" || ph == "acknowledged" || ph == "committed" { return []. }
        }
        now = (current_transaction_info::get_transaction_time())?.
        active is bin+ = e2e::active_session_id cid.
        if fsid != NIL && active != NIL && (active?) != (fsid?) { return []. }   // stale request — I already rotated
        served is rekey_served_t+ = rekey_served cid.
        // Review #9: an aged ledger entry grants a fresh budget instead of a
        // permanent (until-restart) stall at the attempts cap.
        if served != NIL && (_substract_seconds now ((served?) $updated)) >= rekey_served_reset_seconds
        {
            delete rekey_served cid.
            served -> NIL.
        }
        if served != NIL
        {
            if ((served?) $attempts) >= rekey_served_max { return []. }
            if (_substract_seconds now ((served?) $updated)) < rekey_min_interval_seconds { return []. }
        }
        epb = ((((peer_ads cid)?) as any) $identity $e2e_bundle) safe address_document_types::t_e2e_bundle.
        if epb == NIL { return []. }
        att is int = 1.
        if served != NIL { att -> ((served?) $attempts) + 1. }
        rekey_served cid -> ($attempts -> att, $updated -> now).
        // Discard any orphaned staged slot (occupied outside an in-flight migration) so the
        // fresh rotation is the SOLE promotion; then mint the new outbound session.
        if (e2e::staged_session_id cid) != NIL { e2e::discard_rotation cid. }
        e2e::stage_outbound_rotation cid (epb?).
        e2e::commit_rotation cid.
        acts is transaction::action::type[] = [].
        sc redrive_unacked_actions cid -- ( -> a) { acts (_count acts|) -> a. }
        if (_count acts|) == 0 { sc rekey_ping_actions cid -- ( -> a) { acts (_count acts|) -> a. } }
        acts (_count acts|) -> _notify_agent ($event -> $e2e_rekey, $cid -> cid, $role -> $initiator, $session_id -> (e2e::active_session_id cid), $attempts -> att).
        return acts.
    }

    // Build + persist + send an OFFER (spec §5.4). Snapshot the fresh public bundle
    // into the FSM entry FIRST, then build the wire targ FROM the snapshot (decoded),
    // so first-send and every retransmit share ONE construction path and are
    // byte-identical (the epoch depends on the snapshot's fp under a fixed nonce).
    // INV-4: only public signed material (AD/cert/root_profile/cp_binding) is snapshotted,
    // never a session pickle. Caller emits _save_state alongside these actions (atomic
    // persist-with-send). Rides the legacy encrypted_channel (peer must be an established
    // contact); the migration-control carve-out (phase D) keeps this send legal even when
    // app-data route is refused.
    fn mig_offer_actions (peer: global_id) -> transaction::action::type[]
    {
        b  = my_identity_bundle_fields_fresh NIL.
        lb = _write ( $ad -> (b $ad), $cert -> (b $cert),
                      $root_profile -> (b $root_profile), $cp_binding -> (b $cp_binding) ).
        fp = e2e_bundle_fp (b $ad).
        n  = _hash_code_to_binary (_value_id (_new_id "ours e2e migration")).
        now = (current_transaction_info::get_transaction_time())?.
        contact_migration peer -> ( $phase -> "offered", $initiator -> (mig_initiator peer),
            $local_nonce -> n, $peer_nonce -> NIL, $epoch -> NIL, $session_id -> NIL,
            $local_bundle -> lb, $local_fp -> fp, $attempts -> 1, $updated -> now ).
        s = _read_or_abort lb.
        return [ encrypted_channel::send_encrypted_tx peer (
            $name -> e2e_migrate_offer_tx,
            $targ -> ( $ad -> (s $ad), $cert -> (s $cert), $root_profile -> (s $root_profile),
                       $cp_binding -> (s $cp_binding), $nonce -> n, $peer_nonce -> NIL,
                       $pv -> a2a_versions::wire_version,
                       $caps -> (a2a_capabilities::self_cap_ids NIL) ) ) ].
    }

    // §5.4 TRIGGER (liveness): on inbound stamped traffic from a peer we now know is 0.9-capable
    // (its caps advertise cap_e2e_migrate, OR its learned pv>=9) and for which NO migration exists
    // yet, emit OUR offer. ANY side offers on first evidence — NOT conditioned on mig_initiator
    // (election is resolved in the handlers; a higher-cid offer functions as a solicitation that
    // makes the elected lower-cid side emit the authoritative offer). Fail-closed (§1.5): if we
    // don't advertise the cap, or the peer isn't known-0.9, emit nothing — an old peer never gets
    // an offer. Returns [] (NO state write) when the trigger doesn't fire; the CALLER emits
    // _save_state alongside the returned offer (mig_offer_actions persists `offered`).
    // The trigger GATE (pure predicate — testable in isolation; THIS is the criterion-1 boundary:
    // an old peer must NEVER satisfy it). TRUE iff: no migration yet ∧ WE advertise cap_e2e_migrate
    // ∧ the peer is known-0.9 (its caps advertise cap_e2e_migrate, OR its learned pv>=9). Any gate
    // fails → FALSE (no offer). Fail-closed (§1.5).
    fn mig_should_trigger (cid: global_id) -> bool
    {
        if (contact_migration cid) != NIL { return FALSE. }                  // already in-flight / done
        if (contact_e2e_epoch cid) != NIL { return FALSE. }                  // already epoch-pinned (migrated) — never re-offer; defense-in-depth vs any future contact_migration-clearing path (MR2)
        if (contact_born_dr cid) == TRUE { return FALSE. }                   // born-on-DR (fresh v2 contact): already on the ratchet — migration is reserved STRICTLY for pre-existing legacy sessions
        if (a2a_capabilities::self_advertises a2a_capabilities::cap_e2e_migrate) != TRUE { return FALSE. }
        peer_capable is bool = FALSE.
        caps = contact_caps cid.
        if caps != NIL { sc caps? -- ( -> c) { if c == a2a_capabilities::cap_e2e_migrate { peer_capable -> TRUE. } } }
        pv = contact_pv cid.
        if peer_capable != TRUE && (pv == NIL || pv? < 9) { return FALSE. }  // not known-0.9
        return TRUE.
    }

    fn mig_trigger_actions (cid: global_id) -> transaction::action::type[]
    {
        if (mig_should_trigger cid) != TRUE { return []. }
        return mig_offer_actions cid.
    }

    // §5.4 PROACTIVE reconciler — the receive-INDEPENDENT counterpart of mig_trigger_actions: offer to
    // EVERY contact that passes mig_should_trigger (already-known e2e peers with no migration yet). This
    // is the core of the missing-trigger-path fix: an already-e2e-pinned pair (caps learned at invite,
    // ZERO plaintext app traffic) never hits the plaintext receive trigger, so it must be offered
    // proactively. Reused by advertise_migrate (runtime cap-enable) and sweep_e2e_migrations (the
    // default-cap-boot / GC reconciler). Fail-closed + idempotent BY CONSTRUCTION — mig_should_trigger
    // gates on self-advertise ∧ peer-known-0.9 ∧ contact_migration==NIL ∧ contact_e2e_epoch==NIL, so it
    // is inert pre-cap and never re-offers an in-flight/migrated pair. The CALLER emits _save_state
    // (mig_offer_actions persists each `offered` snapshot). One send action per newly-offered contact.
    fn mig_offer_eligible_actions (_) -> transaction::action::type[]
    {
        acts is transaction::action::type[] = [].
        sc contacts -- (cid -> c) ?? (mig_should_trigger cid) { sc mig_offer_actions cid -- ( -> a) { acts (_count acts|) -> a. } }
        return acts.
    }

    // §5.6 flush: drain mig_deferred[cid] FIFO and emit each queued app message for E2E delivery
    // (the daemon sends over the now-active migrated session — core is routing-authority only).
    // The CALLER MUST have set the epoch pin FIRST (else a re-injected send routes "migrating" and
    // re-queues). Clears the queue; an empty queue yields no actions; per-contact order preserved.
    fn flush_mig_deferred_actions (cid: global_id) -> transaction::action::type[]
    {
        out is transaction::action::type[] = [].
        q = mig_deferred cid.
        if q == NIL || (_count q?|) == 0 { return out. }
        sc q? -- ( -> m)
        {
            out (_count out|) -> _notify_agent ( $event -> $migration_deferred_flush, $cid -> cid,
                $wire_id -> (m $wire_id), $text -> (m $text), $reply_to -> (m $reply_to), $route -> $e2e ).
        }
        delete mig_deferred cid.
        return out.
    }

    // ---- core 0.5.0 versioning helpers ---------------------------------------
    // Passive version learning (SPEC §3): record the peer's wire dialect (and
    // its advertised capability ids, when it piggybacked any) off an inbound
    // that carried version evidence. Guarded writes — state only mutates when
    // the learned value actually changes, so handlers that do not _save_state
    // are not left with silently divergent persistence.
    fn learn_contact_version (cid: global_id, pv: int, caps: str[]) -> nil
    {
        prev = contact_pv cid.
        if prev == NIL || prev? != pv { contact_pv cid -> pv. }
        if (_count caps|) != 0 { contact_caps cid -> caps.  note_e2e_seen cid caps. }
    }

    // Owner Addition B: the inviter-facing, render-ready message for a version-
    // incompatible invite second phase. Context-specific wording layered over
    // the registry's generic version_error_t (which rides beside it verbatim).
    fn invite_version_error_message (err: a2a_versions::version_error_t) -> str
    {
        if (err $code) == "peer_version_unsupported"
        {
            return "An invite you created was accepted by a peer running an unsupported (too old) protocol version (v" + (_str (err $peer_version)) + "; minimum supported is v" + (_str (err $min_supported)) + "). The contact was not added — ask them to update their client, then they can redeem the same invite again.".
        }
        return "An invite you created was accepted by a peer whose payload matches no supported protocol shape. The contact was not added — ask them to update their client, then they can redeem the same invite again.".
    }

    // ---- core 0.7.0 receipts (delivery + read confirmations) -----------------
    // Gate (BOTH kinds, one capability pair; polarity is deliberately the
    // OPPOSITE of CAP-1): emit iff THIS node advertises core.receipts.emit
    // (user policy, manifest-captured) AND the peer POSITIVELY advertises
    // core.receipts.receive in learned contact_caps. Absent/unknown caps =>
    // nothing is sent — emitting to a client that cannot parse receipts is the
    // incident class (undeliverable inbound). REG-6: never authz.
    // Does this caps list mention ANY receipts id (i.e. the peer's build is
    // receipts-aware and its advertisement is an EXPLICIT opinion)?
    fn caps_receipts_opinion (caps: str[]) -> bool
    {
        sc caps -- ( -> c)
        {
            if c == a2a_capabilities::cap_receipts_receive { return TRUE. }
            if c == a2a_capabilities::cap_receipts_emit { return TRUE. }
        }
        return FALSE.
    }
    fn caps_contains (caps: str[], cap: str) -> bool
    {
        sc caps -- ( -> c) { if c == cap { return TRUE. } }
        return FALSE.
    }

    // HYBRID GATE (stale-caps self-heal): capability ids are exchanged only on
    // invite/restore bundle legs, so a contact paired PRE-receipts keeps its
    // old caps forever unless re-paired — which froze receipts off for every
    // existing contact after the 0.7 update (owner-reported single-tick bug).
    // Rule: if the peer's learned caps express ANY receipts opinion, follow
    // them STRICTLY (preserves explicit emit/receive toggles); if they are
    // silent on receipts, imply `receive` from the peer's learned dialect
    // pv >= 7 — pv IS re-learned from every stamped ordinary message (ongoing
    // learning), and a pv>=7 peer is KNOWN to parse receive_receipt (the rcp
    // surface registered in 0.7). Old peers (pv < 7 / unknown) stay silent.
    // REG-6 holds: this shapes traffic, never authz.
    fn receipt_gate (peer: global_id) -> bool
    {
        if a2a_capabilities::self_advertises a2a_capabilities::cap_receipts_emit != TRUE { return FALSE. }
        caps = contact_caps peer.
        if caps != NIL && caps_receipts_opinion (caps?)
        {
            return caps_contains (caps?) a2a_capabilities::cap_receipts_receive.
        }
        pv = contact_pv peer.
        return pv != NIL && pv? >= 7.
    }

    // Build the receipt send (fire-and-forget over the established encrypted
    // channel; receipts always FOLLOW message traffic, so the channel exists).
    // Returns [] when gated off or nothing to confirm — callers append blindly.
    fn receipt_actions (peer: global_id, kind: str, wire_ids: str[]) -> transaction::action::type[]
    {
        if (_count wire_ids|) == 0 { return []. }
        if receipt_gate peer != TRUE { return []. }
        return [
            encrypted_channel::send_encrypted_tx peer (
                $name -> receive_receipt_tx,
                $targ -> (
                    $kind     -> kind,
                    $wire_ids -> wire_ids,
                    $date     -> (current_transaction_info::get_transaction_time())?,
                    $pv       -> a2a_versions::wire_version
                )
            )
        ].
    }

    // READ receipts ride the consumer's get/mark-read path: mufl readonly trns
    // cannot emit sends, so the consumer's (mutating) unread->read MARK is the
    // read event — it appends these actions for the ids it JUST transitioned,
    // which makes emission exact-once for free (no transition, no receipt).
    fn read_receipt_actions (sender_id: global_id, wire_ids: str[]) -> transaction::action::type[]
    {
        return receipt_actions sender_id "read" wire_ids.
    }

    // Sender-side expectation, DERIVED from learned caps (no wire traffic):
    // "expected" iff the peer positively advertises the emit capability, else
    // "unknown" — absence of a receipt is NEVER a failure state.
    // Same hybrid as the gate: explicit caps opinion wins; otherwise a
    // pv>=7 peer is expected to emit (its build does by default).
    fn receipt_expectation (cid: global_id) -> str
    {
        caps = contact_caps cid.
        if caps != NIL && caps_receipts_opinion (caps?)
        {
            return (caps_contains (caps?) a2a_capabilities::cap_receipts_emit ?? "expected" ; "unknown").
        }
        pv = contact_pv cid.
        if pv != NIL && pv? >= 7 { return "expected". }
        return "unknown".
    }

    // Verify a received identity bundle against the authenticated sender: D8
    // cid-bind + PoP self-sig (process_address_document aborts on a forged or
    // inconsistent document), then the OPTIONAL delegation chain (an invalid
    // chain aborts; a verifying §3c cp binding is STAGED in the returned record,
    // never written here — INV-5: the CALLER performs all registration writes
    // together after every gate has passed).
    metadef verified_bundle_t: ($ad -> address_document_types::t_address_document, $root -> a2a_protocol::contact_root_t+, $pin_binding -> a2a_protocol::root_cp_binding_t+, $pin_binding_root -> global_id+).
    fn verify_identity_bundle (payload: any, sender_id: global_id) -> verified_bundle_t
    {
        ad = (payload $ad) safe address_document_types::t_address_document.
        abort "Address document does not belong to the sender." when (ad $identity $container_id) != sender_id.
        address_document::process_address_document ad TRUE.
        peer_root is a2a_protocol::contact_root_t+ = NIL.
        pin_binding is a2a_protocol::root_cp_binding_t+ = NIL.
        pin_binding_root is global_id+ = NIL.
        if (payload $cert) != NIL
        {
            cert = (_read_or_abort ((payload $cert) safe bin)) safe a2a_protocol::delegation_cert_t.
            rp = (_read_or_abort ((payload $root_profile) safe bin)) safe a2a_protocol::root_profile_t.
            peer_root -> a2a_protocol::verify_peer_delegation sender_id (_value_id ad) cert rp.
            if (payload $cp_binding) != NIL
            {
                binding = (_read_or_abort ((payload $cp_binding) safe bin)) safe a2a_protocol::root_cp_binding_t.
                if a2a_protocol::verify_root_cp_binding binding (rp $p $root_cid) (rp $p $keys) == TRUE
                {
                    pin_binding -> binding.
                    pin_binding_root -> (rp $p $root_cid).
                }
            }
        }
        return ($ad -> ad, $root -> peer_root, $pin_binding -> pin_binding, $pin_binding_root -> pin_binding_root).
    }

    // core 3.0: mint a SLIM ephemeral-key invite assigned to `assigned` (empty
    // string = no assigned name). Reusable fn so BOTH generate_invite (user trn)
    // and the core.cluster `contact` verb (a2a_cluster, which relays the blob
    // OPAQUELY) share ONE construction path. Generates a fresh ephemeral encryption
    // keypair, registers its PUBLIC half (+ assigned name + scheme) in pending_invites
    // and its PRIVATE half in the hidden, non-exported pending_invite_keys store, and
    // emits ONLY {invite_id, inviter_cid, name, eph_pub, scheme} — no keys, no cert,
    // no root profile (those move to the encrypted two-message redeem hop). No role
    // branch: roles emit the same slim shape. Side effect: registers both stores; the
    // CALLER must emit _save_state. Returns the _write'd blob + its invite_id.
    fn mint_eph_invite (assigned: str) -> ($blob -> bin, $invite_id -> global_id)
    {
        scheme = _crypto_default_scheme_id().
        kp = _crypto_construct_encryption_keypair scheme.
        invite_id = _new_id "ours invite".

        pending_invites invite_id -> ($assigned -> assigned, $eph_pub -> (kp $public_key), $scheme -> scheme).
        pending_invite_keys invite_id -> (kp $secret_key).

        my_ad = address_document::get_my_address_document().
        invite is a2a_protocol::invite_eph_t = (
            $d -> invite_id,
            $c -> (my_ad $identity $container_id),
            $n -> my_name,
            $k -> (kp $public_key),
            $v -> scheme,
            $iv -> invite_current_version
        ).
        return ($blob -> (_write invite), $invite_id -> invite_id).
    }

    trn generate_invite _:($name -> name: str+)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        // Empty string is the "no assigned name" sentinel: accept_contact then
        // registers the joiner under its self-announced name instead.
        assigned = (name == NIL ?? "" ; name?).
        minted = mint_eph_invite assigned.
        return transaction::success [
            _return_data (
                $invite     -> (minted $blob),
                $invite_id  -> (minted $invite_id),
                $peer_name  -> assigned
            ),
            _save_state NIL
        ].
    }

    // core 3.0 LEG 1 (responder): redeem a slim ephemeral invite. Generate a
    // one-shot responder ephemeral keypair, BOX my identity bundle (AD + optional
    // role chain) to the invite's ephemeral pubkey, and BARE-send it to the inviter
    // — the inviter is not registered yet, so confidentiality/integrity come from
    // the box and authenticity from the cid-bind + PoP the inviter enforces at leg 2.
    // The contact is NOT final here: it is registered when the inviter's leg-3
    // complete_invite arrives (pending_redemptions remembers the chosen name +
    // expected inviter cid; pending_redemption_keys keeps my ephemeral PRIVATE key
    // so I can open the inviter's leg-3, which is boxed to my ephemeral pubkey — see
    // the leg-3 handler for why encrypted_channel cannot carry it). Disclosure order
    // flips vs the old fat invite — the responder discloses first — see
    // EPHEMERAL_INVITE_PLAN.md §2/§6.
    trn add_contact _:($invite -> invite_blob: bin, $name -> custom_name: str+)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        inv = (_read_or_abort invite_blob) safe a2a_protocol::invite_eph_t.
        inviter_cid = inv $c.
        abort "This invite is your own — you cannot add yourself." when inviter_cid == _get_container_id().
        invite_id = inv $d.
        inviter_name = inv $n.
        eph_pub_inviter = inv $k.
        scheme = inv $v.

        // Responder ephemeral keypair. The PUBLIC half travels (cleartext, beside
        // the box); the PRIVATE half is KEPT in pending_redemption_keys so I can open
        // the inviter's leg-3 reply (boxed to this pubkey). Forward secrecy for the
        // leg-1 "who is connecting" metadata; both halves are dropped at leg 3.
        kpr = _crypto_construct_encryption_keypair scheme.

        // My identity bundle: my AD plus, if I am a delegated role, my chain so the
        // inviter learns my root linkage symmetrically. All inside the box.
        // A NIL invite version ($iv) means the inviter predates the invite-version
        // field (an old node) — down-level my AD to v1 so it accepts my leg-1 bundle.
        peer_is_v1 = ((inv $iv) == NIL).
        b = my_identity_bundle_fields peer_is_v1.
        // The literal sir_payload_v5_t shape: 0.5.0 stamps its wire dialect +
        // capability ids (SPEC §3/§4). Pre-0.5 inviters ignore both (unknown
        // fields — shipped, proven behavior).
        payload = _write (
            $ad -> (b $ad),
            $cert -> (b $cert),
            $root_profile -> (b $root_profile),
            $cp_binding -> (b $cp_binding),
            $invite_id -> invite_id,
            $name -> my_name,
            $pv   -> a2a_versions::wire_version,
            $caps -> (a2a_capabilities::self_cap_ids NIL)
        ).
        data = _crypto_encrypt_message (kpr $secret_key) eph_pub_inviter payload.

        // Remember who I am redeeming (name + expected inviter cid; no secrets) and
        // KEEP my ephemeral private key (secret store) so leg 3 can be opened.
        contact_name = (custom_name == NIL ?? "" ; custom_name?).
        pending_redemptions invite_id -> ($inviter_cid -> inviter_cid, $inviter_name -> inviter_name, $custom_name -> contact_name).
        pending_redemption_keys invite_id -> (kpr $secret_key).

        // BARE send (NOT send_encrypted_tx): the inviter is not registered, so the
        // box is the protection. Established pattern, cf. encrypted_channel.mm:73.
        return transaction::success [
            transaction::action::send inviter_cid (
                $name -> submit_invite_response_tx,
                $targ -> (
                    $invite_id -> invite_id,
                    $epk -> (kpr $public_key),
                    $v -> scheme,
                    $data -> data,
                    $pv -> a2a_versions::wire_version
                )
            ),
            _return_data (
                $pending -> contact_name,
                $invite_id -> invite_id,
                $container_id -> inviter_cid,
                $inviter_name -> inviter_name,
                // PUBLIC ephemeral key (already on the wire in leg 1) — surfaced so a
                // caller can correlate the outstanding redemption; carries no secret.
                $resp_eph_pub -> (kpr $public_key)
            ),
            _save_state NIL
        ].
    }

    // Mint (or RE-mint) a restore request toward a degraded contact: fresh
    // ephemeral keypair + correlation id, REPLACING any outstanding attempt (the
    // superseded eph key makes a stale leg-1 reply fail both the rid check and
    // the unbox). Returns the bare signed send action (leg 0); #77 signs every
    // envelope, so the receiver authenticates us from the envelope alone. The
    // CALLER emits _save_state.
    fn begin_contact_restore (target: global_id) -> transaction::action::type[]
    {
        attempts is int = 0.
        prev = pending_restores target.
        if prev != NIL { attempts -> (prev? $attempts). }
        scheme = _crypto_default_scheme_id().
        kp = _crypto_construct_encryption_keypair scheme.
        rid = _new_id "ours restore".
        now = (current_transaction_info::get_transaction_time())?.
        pending_restores target -> ($rid -> rid, $eph_pub -> (kp $public_key), $scheme -> scheme, $attempts -> attempts + 1, $created -> now).
        pending_restore_keys target -> (kp $secret_key).
        return [
            transaction::action::send target (
                $name -> request_contact_restore_tx,
                $targ -> ($rid -> rid, $epk -> (kp $public_key), $v -> scheme, $pv -> a2a_versions::wire_version)
            )
        ].
    }

    // $reply_to is optional: when set, it points at the message this one
    // replies to (its stamped wire id + an optional sentence index). Every
    // message gets a fresh stringified wire id — the stable, cross-side handle
    // a reply can reference (the receiver's msg_id is local to its own inbox).
    trn send_message _:($contact -> contact_ref: str, $text -> text: str, $reply_to -> reply_to: a2a_protocol::reply_ref_t+)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        target_id = resolve_contact contact_ref.
        sent_date = (current_transaction_info::get_transaction_time())?.
        wire_id = _str (_new_id "ours message").

        // DEGRADED contact (known cid, no address document — e.g. a breaking-change
        // migration dropped peer_ads): queue the message and (re)issue a restore
        // request instead of failing the send. flush_deferred (host-driven, fired
        // on the $contact_restored notify) drains the queue once the peer's AD is
        // re-established.
        if (peer_ads target_id) == NIL
        {
            q is deferred_msg_t[] = [].
            cur = deferred_msgs target_id.
            if cur != NIL { q -> cur?. }
            abort "Deferred queue for this contact is full (" + (_str deferred_msgs_cap) + ") — contact restore still pending." when (_count q|) >= deferred_msgs_cap.
            q (_count q|) -> ($text -> text, $wire_id -> wire_id, $reply_to -> reply_to, $date -> sent_date).
            deferred_msgs target_id -> q.
            actions is transaction::action::type[] = begin_contact_restore target_id.
            actions (_count actions|) -> _return_data ($sent_to -> target_id, $wire_id -> wire_id, $deferred -> TRUE, $queued -> (_count q|)).
            actions (_count actions|) -> _save_state NIL.
            return transaction::success actions.
        }

        // Phase D §5.6 — APP-DATA traffic barrier. Consult the route BEFORE the box send
        // (core is the single routing authority; the daemon obeys the verdict for its e2e
        // app-send path). Every non-legacy verdict is DATA, never an abort, never a silent box.
        route = e2e_route target_id.
        if route == "migrating"
        {   // initiator commit window: QUEUE in mig_deferred (distinct from the restore
            // deferred_msgs), preserving per-contact order; flushed E2E on active. Bounded.
            mq is deferred_msg_t[] = [].
            mcur = mig_deferred target_id.
            if mcur != NIL { mq -> mcur?. }
            abort "Migration queue for this contact is full (" + (_str deferred_msgs_cap) + ") — commit window still open." when (_count mq|) >= deferred_msgs_cap.
            mq (_count mq|) -> ($text -> text, $wire_id -> wire_id, $reply_to -> reply_to, $date -> sent_date).
            mig_deferred target_id -> mq.
            return transaction::success [
                _return_data ($sent_to -> target_id, $wire_id -> wire_id, $deferred -> TRUE, $migrating -> TRUE, $queued -> (_count mq|)),
                _save_state NIL ].
        }
        if route == "downgrade_refused"
        {   // epoch-pinned but no current v2 bundle: fail CLOSED (never box a migrated peer).
            // Recovery (re-offer over the carve-out) is driven by the migration sweep.
            return transaction::success [ _return_data ($sent_to -> target_id, $wire_id -> wire_id, $downgrade_refused -> TRUE, $code -> $e2e_downgrade_refused) ].
        }
        if route == "e2e" && (e2e_pinned target_id || (contact_e2e_epoch target_id) != NIL)
        {   // KNOWN-E2E peer (epoch-pinned): CORE DELIVERS over the MIGRATED session (Option B —
            // the thin daemon has no transport, and a bare e2e envelope can't be action::send-ed).
            // encrypt_to advances m_sessions[cid] (the migrated session); the e2e ciphertext rides
            // a DISTINCT box (receive_e2e_message_tx) so the wire separates it from legacy plaintext.
            // A FRESH v2 contact (never pinned) falls through to the legacy box below (unchanged).
            epb = ((((peer_ads target_id)?) as any) $identity $e2e_bundle) safe address_document_types::t_e2e_bundle.
            einner = _write ( $text -> text, $wire_id -> wire_id, $reply_to -> reply_to, $pv -> a2a_versions::wire_version ).
            eenv = e2e::encrypt_to target_id einner epb.
            // core 0.11 self-heal: retain until the delivered receipt — the redrive source
            // if the peer restarted and this send lands on a dead session (silent-drop fix).
            m_res = unacked_note target_id "m" wire_id einner sent_date.
            eacts is transaction::action::type[] = [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> receive_e2e_message_tx,
                    $targ -> ( $e2e_envelope -> (eenv $e2e_envelope), $emsignature -> (eenv $emsignature) ) ) ].
            sc on_message_sent ($target_id -> target_id, $text -> text, $date -> sent_date, $wire_id -> wire_id, $reply_to -> reply_to) -- ( -> a) { eacts (_count eacts|) -> a. }
            sc post_send_middleware ($target_id -> target_id, $text -> text, $date -> sent_date, $wire_id -> wire_id, $reply_to -> reply_to) -- ( -> a) { eacts (_count eacts|) -> a. }
            sc monitor_copy_actions "out" target_id sent_date text -- ( -> a) { eacts (_count eacts|) -> a. }
            // §4 observability: source $session_id from the ACTUAL envelope (NOT a re-read of
            // active_session_id — that would make the #1867 "session_id==pin" assertion CIRCULAR;
            // the real envelope id proves the app traversed the migrated session).
            eacts (_count eacts|) -> _notify_agent ( $event -> $e2e_app_send, $cid -> target_id, $session_id -> ((eenv $e2e_envelope) $session_id), $olm_type -> ((eenv $e2e_envelope) $olm_type), $wire_id -> wire_id, $retained -> (m_res $retained), $evicted -> (m_res $evicted) ).
            eacts (_count eacts|) -> _return_data ($sent_to -> target_id, $wire_id -> wire_id, $route -> $e2e, $retained -> (m_res $retained)).
            eacts (_count eacts|) -> _save_state NIL.
            return transaction::success eacts.
        }
        // route == "legacy" (or a fresh-v2 "e2e", box legacy-allowed) -> unchanged box send below.
        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            actions is transaction::action::type[] = [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> receive_message_tx,
                    $targ -> ($text -> text, $wire_id -> wire_id, $reply_to -> reply_to, $pv -> a2a_versions::wire_version)
                )
            ].
            sc on_message_sent ($target_id -> target_id, $text -> text, $date -> sent_date, $wire_id -> wire_id, $reply_to -> reply_to) -- ( -> a)
            {
                actions (_count actions|) -> a.
            }
            sc post_send_middleware ($target_id -> target_id, $text -> text, $date -> sent_date, $wire_id -> wire_id, $reply_to -> reply_to) -- ( -> a)
            {
                actions (_count actions|) -> a.
            }
            // FORCED: emit the outbound monitoring copy as core code, after the app
            // hook, so the app cannot suppress it (self-gates on monitoring_proxy).
            sc monitor_copy_actions "out" target_id sent_date text -- ( -> a)
            {
                actions (_count actions|) -> a.
            }
            actions (_count actions|) -> _return_data ($sent_to -> target_id, $text -> text, $wire_id -> wire_id).
            actions (_count actions|) -> _save_state NIL.
            return transaction::success actions.
        }).
    }

    // Metadata-only monitoring line for a file (NEVER the bytes): the bound control
    // plane learns that a file moved + its name/mime/size, nothing more. monitoring_
    // copy_t.$body stays str, so no copy-shape change.
    fn file_monitor_summary (filename: str, mime: str, data: bin) -> str
    {
        return "[file] " + filename + " (" + mime + ", " + (_str (_binlen data)) + " B)".
    }

    // File transfer (core 3.1): a separate transaction from send_message — files and
    // text are always distinct messages. Mirrors send_message exactly: a wire_id from
    // the SAME _new_id namespace (so a reply_to can cross between messages and files),
    // an optional reply_to, and the app-side on_file_sent storage hook. Both send_file
    // and handle_receive_file emit a forced metadata-only monitoring copy (name/mime/size).
    trn send_file _:($contact -> contact_ref: str, $filename -> filename: str, $mime -> mime: str+, $data -> data: bin, $reply_to -> reply_to: a2a_protocol::reply_ref_t+)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        target_id = resolve_contact contact_ref.
        // Files do NOT queue (bulk binary); fail fast with the real reason instead
        // of an opaque channel error. send_message toward this contact will queue
        // and drive the restore.
        abort "Contact \"" + contact_ref + "\" is awaiting key restore (degraded) — retry the file after a message to it is delivered." when (peer_ads target_id) == NIL.
        sent_date = (current_transaction_info::get_transaction_time())?.
        wire_id = _str (_new_id "ours file").
        mime_s is str = "".
        if mime != NIL { mime_s -> mime safe str. }

        // Phase D §5.6 — app-data barrier. Files NEVER queue (bulk binary); a non-legacy
        // route is a typed result telling the caller to retry (migrating) or that box is
        // refused (downgrade_refused) / to use e2e (daemon path). Never a silent box.
        froute = e2e_route target_id.
        if froute == "migrating"
        { return transaction::success [ _return_data ($sent_to -> target_id, $wire_id -> wire_id, $migrating -> TRUE, $code -> $e2e_migrating) ]. }
        if froute == "downgrade_refused"
        { return transaction::success [ _return_data ($sent_to -> target_id, $wire_id -> wire_id, $downgrade_refused -> TRUE, $code -> $e2e_downgrade_refused) ]. }
        if froute == "e2e" && (e2e_pinned target_id || (contact_e2e_epoch target_id) != NIL)
        {   // CORE delivers the file over the MIGRATED session (Option B), boxed under a distinct name.
            fepb = ((((peer_ads target_id)?) as any) $identity $e2e_bundle) safe address_document_types::t_e2e_bundle.
            finner = _write ( $filename -> filename, $mime -> mime_s, $data -> data, $wire_id -> wire_id, $reply_to -> reply_to, $pv -> a2a_versions::wire_version ).
            fenv = e2e::encrypt_to target_id finner fepb.
            // core 0.11 self-heal: files retain for redrive exactly like messages (review
            // fix — a restarted receiver silently losing FILES is the owner's primary case).
            // finding J: an oversized file (> unacked_file_entry_max_bytes) is NOT retained —
            // that MUST be surfaced, not silently reported as a plain success.
            f_res = unacked_note target_id "f" wire_id finner sent_date.
            feacts is transaction::action::type[] = [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> receive_e2e_file_tx,
                    $targ -> ( $e2e_envelope -> (fenv $e2e_envelope), $emsignature -> (fenv $emsignature) ) ) ].
            sc on_file_sent ($target_id -> target_id, $filename -> filename, $mime -> mime_s, $data -> data, $date -> sent_date, $wire_id -> wire_id, $reply_to -> reply_to) -- ( -> a) { feacts (_count feacts|) -> a. }
            sc monitor_copy_actions "out" target_id sent_date (file_monitor_summary filename mime_s data) -- ( -> a) { feacts (_count feacts|) -> a. }
            feacts (_count feacts|) -> _notify_agent ( $event -> $e2e_app_send, $cid -> target_id, $session_id -> ((fenv $e2e_envelope) $session_id), $olm_type -> ((fenv $e2e_envelope) $olm_type), $wire_id -> wire_id, $retained -> (f_res $retained), $evicted -> (f_res $evicted) ).
            feacts (_count feacts|) -> _return_data ($sent_to -> target_id, $wire_id -> wire_id, $route -> $e2e, $retained -> (f_res $retained)).
            feacts (_count feacts|) -> _save_state NIL.
            return transaction::success feacts.
        }
        // route == "legacy" (or a fresh-v2 "e2e", box legacy-allowed) -> unchanged box send below.
        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            actions is transaction::action::type[] = [
                encrypted_channel::send_encrypted_tx target_id (
                    $name -> receive_file_tx,
                    $targ -> ($filename -> filename, $mime -> mime_s, $data -> data, $wire_id -> wire_id, $reply_to -> reply_to, $pv -> a2a_versions::wire_version)
                )
            ].
            sc on_file_sent ($target_id -> target_id, $filename -> filename, $mime -> mime_s, $data -> data, $date -> sent_date, $wire_id -> wire_id, $reply_to -> reply_to) -- ( -> a)
            {
                actions (_count actions|) -> a.
            }
            // FORCED metadata-only monitoring copy (app cannot suppress; self-gates on
            // monitoring_proxy). Mirrors send_message's forced "out" copy.
            sc monitor_copy_actions "out" target_id sent_date (file_monitor_summary filename mime_s data) -- ( -> a)
            {
                actions (_count actions|) -> a.
            }
            actions (_count actions|) -> _return_data ($sent_to -> target_id, $filename -> filename, $wire_id -> wire_id).
            actions (_count actions|) -> _save_state NIL.
            return transaction::success actions.
        }).
    }

    trn remove_contact _:($contact -> contact_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        target_id = resolve_contact contact_ref.
        // Guard the monitoring invariant "monitoring_proxy != NIL ⇒ the proxy is a
        // registered contact": removing the bound control plane would leave a
        // dangling monitoring_proxy, so the next send_message's forced copy would
        // fire send_encrypted_tx at an unregistered peer and ABORT the user's send —
        // and disable_monitoring is CP-only, so with the CP gone there is no
        // recovery (all messaging bricked). Block the removal instead; this is NOT
        // an app-callable clear (removal is refused, monitoring is not switched off).
        abort "Cannot remove the bound control plane while monitoring is active — the control plane must disable monitoring first." when monitoring_proxy != NIL && target_id == (monitoring_proxy? $proxy_cid).
        removed = contacts target_id.
        removed_name = removed? $name.

        delete contacts target_id.
        if peer_ads target_id != NIL { delete peer_ads target_id. }
        if contact_roots target_id != NIL { delete contact_roots target_id. }
        if contact_pv target_id != NIL { delete contact_pv target_id. }
        if contact_caps target_id != NIL { delete contact_caps target_id. }
        if contact_advertised_caps target_id != NIL { delete contact_advertised_caps target_id. }

        // Contact-restore stores too: an orphaned deferred queue would persist in
        // every export and, on a later RE-ADD of the same peer, the boot/GC sweep
        // would silently deliver the stale queued messages.
        if (deferred_msgs target_id) != NIL { delete deferred_msgs target_id. }
        // core 0.11 self-heal stores (review fix): unacked_e2e is EXPORTED plaintext —
        // removal must erase it (delete semantics), and a later re-add of the same cid
        // must never redrive removed-era messages or dedup against stale wire_ids.
        if (unacked_e2e target_id) != NIL { delete unacked_e2e target_id. }
        if (delivered_wire target_id) != NIL { delete delivered_wire target_id. }
        if (rekey_pending target_id) != NIL { delete rekey_pending target_id. }
        if (rekey_served target_id) != NIL { delete rekey_served target_id. }
        if (pending_restores target_id) != NIL { delete pending_restores target_id. }
        if (pending_restore_keys target_id) != NIL { delete pending_restore_keys target_id. }
        if (pending_restore_replies target_id) != NIL { delete pending_restore_replies target_id. }
        if (pending_restore_reply_keys target_id) != NIL { delete pending_restore_reply_keys target_id. }

        actions is transaction::action::type[] = [].
        sc on_contact_removed ($container_id -> target_id) -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        actions (_count actions|) -> _return_data ($removed -> removed_name, $container_id -> target_id).
        actions (_count actions|) -> _save_state NIL.
        return transaction::success actions.
    }

    trn readonly list_contacts _
    {
        return contacts.
    }

    trn readonly list_contact_roots _
    {
        return contact_roots.
    }

    // ---- monitoring bind ceremony (writes hidden gate state) -----------------
    // These live HERE, not in a2a_monitoring, because monitoring_proxy/proxy_pending
    // are hidden and hidden state is mutable only by its declaring library — that is
    // the enforcement of "no app/library can flip monitoring off by direct assignment."

    // Start a proxy binding (host-fired): remember the host-generated 6-digit code
    // for one specific contact (the control plane). Restart overwrites any pending.
    trn set_proxy_pending _:($code -> code: str, $proxy -> proxy_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        pid = resolve_contact proxy_ref.
        proxy_pending -> (
            $code       -> code,
            $proxy_cid  -> pid,
            $created_at -> (current_transaction_info::get_transaction_time())?,
            $attempts   -> 0
        ).
        return transaction::success [
            _return_data ($pending -> TRUE, $proxy_cid -> (_str pid)),
            _save_state NIL
        ].
    }

    // Verify a proxy's code attempt (host-fired when the control plane's bind
    // request arrives; $sender is the channel-authenticated control-plane id the
    // daemon relays). Failures are returned as DATA — not aborts — so the attempt
    // counter and expiry clearing PERSIST atomically; an abort would roll them back
    // and reopen the brute-force window. On success, binds monitoring_proxy.
    //
    // Trust boundary (asymmetry vs disable_monitoring, intentional): BIND is
    // user-origin and trusts the daemon to relay the true $sender — a hostile
    // DAEMON could sham-bind — the accepted self-assertion limitation (ours
    // monitoring design, MCP repo). The
    // "app can't override" guarantee is against the app PACKET, which cannot issue
    // user-origin transactions at all. DISABLE is external-direct (sender == $from).
    // Core of the 6-digit bind ceremony, SHARED by the verify_proxy_code trn (the
    // legacy direct entry) and the core.monitoring `bind` verb handler (a2a_cluster).
    // ONE ceremony definition — no divergence. Verifies `code` from `sid` against
    // proxy_pending; on success SETS monitoring_proxy (sid becomes the controller).
    // Mutates hidden gate state, so it MUST live here. Returns the outcome; the
    // caller emits _save_state. $attempts_left is meaningful only for "wrong_code".
    fn do_verify_proxy_code (code: str, sid: global_id) -> ($verified -> bool, $reason -> str, $attempts_left -> int)
    {
        if proxy_pending == NIL { return ($verified -> FALSE, $reason -> "no_pending", $attempts_left -> 0). }
        p = proxy_pending?.
        now = (current_transaction_info::get_transaction_time())?.

        if (_substract_seconds now (p $created_at)) > proxy_code_max_age_seconds
        {
            proxy_pending -> NIL.
            return ($verified -> FALSE, $reason -> "expired", $attempts_left -> 0).
        }
        if sid != (p $proxy_cid) { return ($verified -> FALSE, $reason -> "wrong_sender", $attempts_left -> 0). }
        if code != (p $code)
        {
            attempts = (p $attempts) + 1.
            if attempts >= proxy_max_attempts
            {
                proxy_pending -> NIL.
                return ($verified -> FALSE, $reason -> "too_many_attempts", $attempts_left -> 0).
            }
            proxy_pending -> ($code -> p $code, $proxy_cid -> p $proxy_cid, $created_at -> p $created_at, $attempts -> attempts).
            return ($verified -> FALSE, $reason -> "wrong_code", $attempts_left -> proxy_max_attempts - attempts).
        }
        monitoring_proxy -> ($proxy_cid -> sid, $bound_at -> now).
        proxy_pending -> NIL.
        return ($verified -> TRUE, $reason -> "ok", $attempts_left -> 0).
    }

    // Clear the monitoring binding if `sid` IS the bound proxy. Shared by the
    // core.monitoring `disable` verb handler. Returns TRUE iff disabled.
    fn do_disable_monitoring (sid: global_id) -> bool
    {
        if monitoring_proxy == NIL { return FALSE. }
        if sid != (monitoring_proxy? $proxy_cid) { return FALSE. }
        monitoring_proxy -> NIL.
        proxy_pending -> NIL.
        return TRUE.
    }

    trn verify_proxy_code _:($code -> code: str, $sender -> sender_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        sid = resolve_contact sender_ref.
        r = do_verify_proxy_code code sid.
        if (r $verified) == TRUE
        {
            return transaction::success [ _return_data ($verified -> TRUE, $proxy_cid -> (_str sid)), _save_state NIL ].
        }
        if (r $reason) == "wrong_code"
        {
            return transaction::success [ _return_data ($verified -> FALSE, $reason -> "wrong_code", $attempts_left -> (r $attempts_left)), _save_state NIL ].
        }
        return transaction::success [ _return_data ($verified -> FALSE, $reason -> (r $reason)), _save_state NIL ].
    }

    // Disable monitoring. CP-AUTHENTICATED: only the bound control plane may clear
    // the binding — EXTERNAL, encrypted, sender must BE the bound proxy. There is
    // deliberately no user-origin / app-callable clear.
    trn disable_monitoring _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        abort "Monitoring is not bound." when monitoring_proxy == NIL.
        abort "Only the bound control plane can disable monitoring." when sender_id != (monitoring_proxy? $proxy_cid).

        monitoring_proxy -> NIL.
        proxy_pending -> NIL.
        return transaction::success [
            _notify_agent ($event -> $monitoring_disabled, $cid -> sender_id),
            _save_state NIL
        ].
    }

    // Observable monitoring state (readonly). monitored == a control plane is bound.
    trn readonly get_monitoring_status _
    {
        pending is bool = FALSE.
        if proxy_pending != NIL { pending -> TRUE. }
        proxy_out is str = "".
        if monitoring_proxy != NIL { proxy_out -> _str (monitoring_proxy? $proxy_cid). }
        return (
            $monitored     -> (monitoring_proxy != NIL),
            $proxy_pending -> pending,
            $proxy_cid     -> proxy_out
        ).
    }

    // ---- control-plane configuration (CP-gated; see config state above) ------

    // Store the opaque app config blob pushed by the bound control plane after the
    // user fills the schema form on the CP frontend. CP-AUTHENTICATED: external,
    // encrypted, sender must be the bound control plane. The blob is opaque to the
    // core; a $config_updated notify wakes the wrapper, which pulls it via
    // get_app_config and applies the operational parts.
    fn handle_set_app_config (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        require_bound_cp_or_abort sender_id.

        app_config -> (args $config) safe str.
        return transaction::success [
            _notify_agent ($event -> $config_updated),
            _save_state NIL
        ].
    }

    trn set_app_config args: any
    {
        return handle_set_app_config args.
    }

    trn readonly get_app_config _
    {
        return ($config -> app_config).
    }

    // NOTE: the core intentionally stores ONLY the opaque app_config blob and bakes
    // in NO policy semantics. Per-application policy (e.g. "outgoing-only to a
    // contact") is application logic, implemented in the wrapper from its own custom
    // config schema — it is deliberately NOT a protocol feature (human ruling).

    // ---- cluster enrollment: managed roots (core 2.1) -------------------------
    // CP SIDE, host-fired: record that this control plane manages a root. The daemon
    // calls this when a root binds the CP (one call conveys the whole cluster — every
    // child of the root becomes enrollable). It is the authorization half of
    // enroll_delegated_node: a child enrolls only when its delegation chain resolves
    // to a root recorded here. Idempotent; the root id is supplied by the host (the CP
    // learns it from the root-bind it just completed), so no chain is verified at this
    // step — the cryptographic check happens per-child in enroll_delegated_node.
    trn manage_root _:($root_cid -> root_cid: global_id)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        managed_roots root_cid -> TRUE.
        return transaction::success [
            _return_data ($managed_root -> (_str root_cid)),
            _save_state NIL
        ].
    }

    // CP SIDE, external inbound: a root relays one of its children's signed address
    // document so the CP can hold peer_ads[child] WITHOUT the child binding the CP
    // itself — the receiver half of "one root bind conveys the whole cluster". The
    // child never participates here; the root presents the child's public material
    // (AD + delegation cert + root profile) it already holds via the delegation chain.
    //
    // Authorization is TWO independent checks, all required (delegation material is
    // semi-public, so possession must not equal authorization):
    //   (1) the channel-authenticated sender IS the root named in the delegation chain
    //       (the root relays its OWN children — no third-party relay of a valid chain),
    //   (2) verify_peer_delegation proves the child's container id AND its AD hash
    //       chain to that root, root-signed.
    // There is deliberately NO managed_roots authorization gate: a bound host's children
    // are introduceable by default once it advertises core.connect; the operator clicking
    // Introduce is the consent. Authenticity is still fully enforced by (1) + (2), so a
    // node can only ever enroll children it legitimately delegated.
    // Plus the child AD's own self-signature is re-checked (proof-of-possession). Any
    // failure aborts; nothing is stored. Idempotent: a re-enroll just refreshes the AD.
    fn handle_enroll_delegated_node (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.

        child_ad = (args $child_ad) safe address_document_types::t_address_document.
        child_cid = child_ad $identity $container_id.
        abort "Cannot enroll myself." when child_cid == _get_container_id().

        // Proof-of-possession: re-authorize the child's own self-signed document before
        // storing it (child_cid is key-derived, so an existing contact's keyset can
        // never be silently overwritten with a different one).
        address_document::process_address_document child_ad TRUE.

        cert = (_read_or_abort ((args $delegation_cert) safe bin)) safe a2a_protocol::delegation_cert_t.
        rp = (_read_or_abort ((args $root_profile) safe bin)) safe a2a_protocol::root_profile_t.

        // (3) Verify the delegation chain: binds child_cid AND _value_id(child_ad) to a
        // root, root-signed (aborts on any mismatch). Returns the verified root linkage.
        child_root = a2a_protocol::verify_peer_delegation child_cid (_value_id child_ad) cert rp.
        enroll_root_cid = child_root $root_cid.

        // (1) The relayer must BE that root — possession of a valid chain is not enough.
        abort "Only a node's own root may enroll it." when sender_id != enroll_root_cid.
        // (managed_roots authorization gate intentionally removed: a bound host's children
        // enroll by default; authenticity is enforced by (1) + verify_peer_delegation above.)

        // Idempotent re-enrollment: refresh the stored AD/linkage, keep the contact.
        if (contacts child_cid) != NIL
        {
            peer_ads child_cid -> child_ad.
            contact_roots child_cid -> child_root.
            return transaction::success [
                _notify_agent ($event -> $reenrolled, $container_id -> child_cid, $root_cid -> enroll_root_cid),
                _save_state NIL
            ].
        }

        // New cluster child: register under the verified role label (root_name/role_id
        // are advisory display strings; the AD self-signature is the only trusted id).
        contacts child_cid -> ($name -> (child_root $root_name) + "/" + (child_root $role_id), $container_id -> child_cid).
        peer_ads child_cid -> child_ad.
        contact_roots child_cid -> child_root.

        return transaction::success [
            _notify_agent ($event -> $enrolled, $container_id -> child_cid, $root_cid -> enroll_root_cid),
            _save_state NIL
        ].
    }

    trn enroll_delegated_node args: any
    {
        return handle_enroll_delegated_node args.
    }

    // Host-fired (ROOT side, core 2.2): relay one of my children's signed AD +
    // delegation chain to my bound control plane — the SEND that drives the CP's
    // handle_enroll_delegated_node inbound above, so a single root bind enrolls the
    // whole cluster. The root presents PUBLIC material it already holds via the
    // delegation chain it signed; the child never participates. This carries NO new
    // trust: it is an authenticated relay over my existing CP channel, and the CP
    // independently re-verifies the chain, that I am the child's root, and that it
    // manages me. Root-only here too (a role's relay would fail the CP's sender==root
    // check anyway). Payload matches handle_enroll_delegated_node field-for-field:
    // $child_ad is the AD VALUE; the cert + root profile ride as blobs (the receiver
    // _read_or_abort's them). The CP derives the "root_name/role_id" display label from
    // the cert's role_id + the root profile's name — no name field is carried here.
    trn relay_enroll_delegated_node _:($proxy -> proxy_ref: str, $child_ad -> child_ad_blob: bin, $delegation_cert -> cert_blob: bin, $root_profile -> rp_blob: bin)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        abort "Only a root identity can relay a cluster enrollment." when delegation_cert != NIL.

        cp_cid = resolve_contact proxy_ref.
        child_ad = (_read_or_abort child_ad_blob) safe address_document_types::t_address_document.
        return encrypted_channel::execute_transaction cp_cid (fn (_) -> transaction::results::type {
            return transaction::success [
                encrypted_channel::send_encrypted_tx cp_cid (
                    $name -> enroll_delegated_node_tx,
                    $targ -> ($child_ad -> child_ad, $delegation_cert -> cert_blob, $root_profile -> rp_blob, $pv -> a2a_versions::wire_version)
                ),
                _return_data ($enroll_relayed -> (_str cp_cid), $child -> (_str (child_ad $identity $container_id)))
            ].
        }).
    }

    // ---- control-plane introduction: core.connect ----------------------------
    // The control plane, bound to BOTH parties, introduces two nodes that are not
    // yet in each other's contacts. The CP already holds each managed node's peer-
    // signed address document (captured in peer_ads when the node bound the CP), so
    // an introduction is simply: send each node the OTHER's signed AD. The receiving
    // node verifies the AD's own self-signature (proof-of-possession), checks the
    // relay came from its bound CP, checks its OWN manifest still advertises
    // core.connect, and registers the contact immediately. No SAS, no confirmation
    // step, no CP signature on the introduction — the bound-CP channel IS the
    // authorization, and the node-side capability gate is the authoritative "do I
    // accept introductions". The CP-side manifest pre-check (refuse to introduce a
    // node whose app does not support it) is the daemon's job: it pulls get_manifest
    // for each target before calling introduce.

    // Pure helper: the two bare encrypted sends that make up one introduction — node
    // A receives B's address document (+ B's CP-supplied display name) and node B
    // receives A's. Bare send_encrypted_tx is sound here because both channels are
    // already established (each node bound the CP), so no execute_transaction
    // handshake is needed; the caller guards peer_ads presence before emitting.
    fn emit_pair (
        a_id: global_id, ad_a: address_document_types::t_address_document, name_a: str,
        b_id: global_id, ad_b: address_document_types::t_address_document, name_b: str
    ) -> transaction::action::type[]
    {
        return [
            encrypted_channel::send_encrypted_tx a_id (
                $name -> ingest_connect_descriptor_tx,
                $targ -> ($peer_ad -> ad_b, $peer_name -> name_b, $pv -> a2a_versions::wire_version)
            ),
            encrypted_channel::send_encrypted_tx b_id (
                $name -> ingest_connect_descriptor_tx,
                $targ -> ($peer_ad -> ad_a, $peer_name -> name_a, $pv -> a2a_versions::wire_version)
            )
        ].
    }

    // The display name the CP advertises for a managed node when introducing it: the
    // CP's own contact label, falling back to the stringified container id. This is
    // unauthenticated by design (a receiver-chosen display string); the AD self-
    // signature is the only authenticated identity the receiver actually trusts.
    fn introduce_name (cid: global_id) -> str
    {
        if (contacts cid) != NIL { return (contacts cid)? $name. }
        return _str cid.
    }

    // CP SIDE: introduce two managed nodes to each other (host-fired). Both must be
    // established contacts of the CP (peer_ads holds their signed ADs). The manifest
    // "supports introductions" pre-check is the daemon's job (it pulls get_manifest
    // for each before calling this); the node-side gate in ingest_connect_descriptor
    // is the authoritative enforcement. Emits both relays in one transaction.
    trn introduce _:($peer_a -> ref_a: str, $peer_b -> ref_b: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        a_id = resolve_contact ref_a.
        b_id = resolve_contact ref_b.
        abort "Cannot introduce a node to itself." when a_id == b_id.

        ad_a = peer_ads a_id.
        abort "First node is not an established contact (no stored address document)." when ad_a == NIL.
        ad_b = peer_ads b_id.
        abort "Second node is not an established contact (no stored address document)." when ad_b == NIL.

        actions is transaction::action::type[] = emit_pair a_id ad_a? (introduce_name a_id) b_id ad_b? (introduce_name b_id).
        actions (_count actions|) -> _return_data ($introduced -> ($peer_a -> (_str a_id), $peer_b -> (_str b_id))).
        return transaction::success actions.
    }

    // CP SIDE: introduce one joiner to every member of a group (cluster-root fan-out,
    // e.g. a new subagent under a cluster root). For each member it emits the same
    // pair of relays as introduce(joiner, member). All targets must be established
    // contacts. O(members) bare sends in a single transaction.
    trn introduce_to_group _:($joiner -> joiner_ref: str, $members -> member_refs: str[])
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).

        j_id = resolve_contact joiner_ref.
        ad_j = peer_ads j_id.
        abort "Joiner is not an established contact (no stored address document)." when ad_j == NIL.
        j_name = introduce_name j_id.

        actions is transaction::action::type[] = [].
        introduced is str[] = [].
        sc member_refs -- ( -> mref)
        {
            m_id = resolve_contact mref.
            abort "Cannot introduce the joiner to itself." when m_id == j_id.
            ad_m = peer_ads m_id.
            abort "A group member is not an established contact (no stored address document)." when ad_m == NIL.
            sc emit_pair j_id ad_j? j_name m_id ad_m? (introduce_name m_id) -- ( -> act)
            {
                actions (_count actions|) -> act.
            }
            introduced (_count introduced|) -> (_str m_id).
        }
        actions (_count actions|) -> _return_data ($joiner -> (_str j_id), $introduced -> introduced).
        return transaction::success actions.
    }

    // Ingest a peer's signed address document relayed by my control plane (core.connect).
    // Authorization model (radically simple): the relay must come from my bound CP
    // (require_bound_cp_or_abort) AND this node must itself advertise core.connect (the
    // node-side capability gate — the authoritative "I accept introductions"). The AD
    // carries its own self-signatures, re-checked by process_address_document (proof-of-
    // possession; aborts on a forged/inconsistent document). No SAS, no CP signature, no
    // confirmation step — the contact is established immediately. The CP-supplied
    // $peer_name is an unauthenticated display label.
    fn handle_ingest_connect_descriptor (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        // The relay must come from a CP authorized for me — EITHER one I bound directly
        // (legacy 6-digit ceremony) OR one my root designated and I inherited (core 2.1
        // cluster CP, verified locally against my pinned root_ad). Additive: the legacy
        // direct-bind path is unchanged.
        require_cluster_cp_or_abort sender_id.
        // Node-side capability gate (authoritative): refuse unless my OWN live manifest
        // advertises core.connect. Without this the manifest boolean would be a pure
        // CP-side courtesy rather than enforced.
        abort "This node does not support introductions (core.connect not in its manifest)." when a2a_capabilities::self_supports a2a_capabilities::cap_connect != TRUE.

        peer_ad = (args $peer_ad) safe address_document_types::t_address_document.
        peer_cid = peer_ad $identity $container_id.
        abort "Cannot introduce me to myself." when peer_cid == _get_container_id().

        // Proof-of-possession: re-authorize the peer's own self-signed document before
        // storing it (idempotent; peer_cid is key-derived, so an existing contact's keys
        // can never be silently overwritten with a different keyset).
        address_document::process_address_document peer_ad TRUE.

        peer_name is str = "".
        if (args $peer_name) != NIL { peer_name -> (args $peer_name) safe str. }

        // Idempotent re-introduction: refresh the stored AD. A contact created from a
        // nameless/legacy introduction may still be labelled by its CID; in that one
        // case adopt the now-available peer label. Any better name (including an
        // explicit invite alias) remains authoritative and is never overwritten.
        if (contacts peer_cid) != NIL
        {
            existing = (contacts peer_cid)?.
            if peer_name != "" && (existing $name) == (_str peer_cid)
            {
                contacts peer_cid -> ($name -> peer_name, $container_id -> peer_cid).
            }
            peer_ads peer_cid -> peer_ad.
            return transaction::success [
                _notify_agent ($event -> $reintroduced, $container_id -> peer_cid, $by_cp -> sender_id),
                _save_state NIL
            ].
        }

        // New contact: register under the CP-supplied display name (cid as last resort).
        contact_label is str = (peer_name == "" ?? (_str peer_cid) ; peer_name).
        contacts peer_cid -> ($name -> contact_label, $container_id -> peer_cid).
        peer_ads peer_cid -> peer_ad.

        return transaction::success [
            _notify_agent ($event -> $introduced, $container_id -> peer_cid, $name -> contact_label, $by_cp -> sender_id),
            _save_state NIL
        ].
    }

    trn ingest_connect_descriptor args: any
    {
        return handle_ingest_connect_descriptor args.
    }

    // The shared-core version this packet was compiled with (see version.mm).
    trn readonly get_version _
    {
        return ($core -> version::get_core_version()).
    }

    // ---- external (inbound) transactions ------------------------------------
    // Each inbound transaction's body is an exported handle_* fn so consumers'
    // ::actor:: compat shims (Option A) delegate to the exact same code path —
    // the stdlib trn-delegates-to-fn pattern (see address_document::handshake_init).

    // Args are taken as `any` (not a destructured shape) so old clients — whose
    // accept_contact payload has no hierarchy fields — keep working unchanged.
    fn handle_accept_contact (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.

        // --- 0.5.0 registry gate (acc) — BEFORE any strict read of the args.
        // The legacy redeem sibling of the sir gate: a version-incompatible
        // payload surfaces to the inviter as error-as-data (Addition A/B),
        // never an abort; the invite is NOT consumed.
        nr = a2a_versions::try_narrow_acc args.
        if (nr $ok) != TRUE
        {
            err = (nr $err)?.
            return transaction::success [
                _notify_agent (
                    $event     -> $protocol_error,
                    $context   -> $invite_redeem,
                    $message   -> invite_version_error_message err,
                    $error     -> err,
                    $invite_id -> (args $invite_id),
                    $peer_cid  -> sender_id
                )
            ].
        }
        narrowed is a2a_versions::acc_args_t = (nr $payload)?.

        invite_id = (args $invite_id) safe global_id.
        joiner_ad = (args $joiner_ad) safe address_document_types::t_address_document.

        // Only an invite I generated (and have not yet consumed) authorizes a
        // contact registration. Without this gate any invite blob would be a
        // multi-use bearer credential: anyone who ever saw one could register
        // themselves as my contact with a self-chosen name.
        // core 3.0: pending_invites is now a pending_invite_t record map; the
        // assigned name is its $assigned field. (This legacy accept path is removed
        // in M2 with the rest of the old redeem flow.)
        invite_rec = pending_invites invite_id.
        abort "Unknown or already-redeemed invite." when invite_rec == NIL.
        // D8: joiner_ad is attacker-supplied. Bind it to the channel-authenticated
        // sender and prove it is the joiner's OWN self-signed document before we
        // store it as the peer's identity. The cid gate stops a redeemer from
        // registering SOMEONE ELSE's address document under this contact, and
        // process_address_document re-authorizes the self-signatures (it aborts on
        // a forged/inconsistent document).
        abort "Address document does not belong to the sender." when (joiner_ad $identity $container_id) != sender_id.
        address_document::process_address_document joiner_ad TRUE.
        // An empty assigned name means the invite was generated without one:
        // the joiner's self-announced name wins (container id as a last resort
        // when the joiner never set a name either).
        contact_name is str = (invite_rec?) $assigned.
        if contact_name == ""
        {
            // REGISTRY DISPATCH replaces the strict $joiner_name read (the
            // sir incident's hygiene sibling): v3 returns the sent name; v2
            // has no such field and falls back to the sender cid.
            joiner_self = a2a_versions::acc_joiner_name narrowed.
            contact_name -> (joiner_self == "" ?? (_str sender_id) ; joiner_self).
        }

        // A delegated-role joiner carries its chain so I learn its root linkage
        // symmetrically; an invalid chain rejects the redemption outright.
        joiner_root is a2a_protocol::contact_root_t+ = NIL.
        if (args $joiner_cert) != NIL
        {
            cert = (_read_or_abort ((args $joiner_cert) safe bin)) safe a2a_protocol::delegation_cert_t.
            rp = (_read_or_abort ((args $joiner_root_profile) safe bin)) safe a2a_protocol::root_profile_t.
            joiner_root -> a2a_protocol::verify_peer_delegation sender_id (_value_id joiner_ad) cert rp.
            // §3c symmetric: pin the joiner's root binding if it carries one and
            // verifies against its root key list. Non-enforcing — a bad/absent
            // binding never rejects the redemption.
            if (args $joiner_cp_binding) != NIL
            {
                binding = (_read_or_abort ((args $joiner_cp_binding) safe bin)) safe a2a_protocol::root_cp_binding_t.
                if a2a_protocol::verify_root_cp_binding binding (rp $p $root_cid) (rp $p $keys) == TRUE
                {
                    contact_cp_bindings (rp $p $root_cid) -> binding.
                }
            }
        }

        contacts sender_id -> ($name -> contact_name, $container_id -> sender_id).
        // Passive version learning: this legacy surface never carries $pv or
        // $caps — record the shape-inferred dialect (2 or 3).
        learn_contact_version sender_id (a2a_versions::acc_version_of args) [].
        // Remember the joiner's address document for upgrade-time re-registration.
        peer_ads sender_id -> joiner_ad.
        if joiner_root != NIL
        {
            contact_roots sender_id -> joiner_root?.
        }
        delete pending_invites invite_id.

        return transaction::success [
            _notify_agent ($event -> $contact_accepted, $name -> contact_name, $container_id -> sender_id),
            _save_state NIL
        ].
    }

    trn accept_contact args: any
    {
        return handle_accept_contact args.
    }

    // core 3.0 LEG 2 (inviter): a responder redeemed my slim invite. The body is a
    // BARE inbound carrying a box, so this is the ONE inbound that intentionally
    // SKIPS check_encrypted_or_abort — confidentiality/integrity come from the box,
    // authenticity from the cid-bind + PoP below. INV-5: NO contact/peer_ads/
    // contact_roots write happens before ALL gates pass (lookup -> decrypt ->
    // cid-bind -> PoP -> chain). Single-use: the first valid leg-2 consumes BOTH
    // pending_invites AND pending_invite_keys; a failed gate consumes nothing.
    fn handle_submit_invite_response (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        invite_id = (args $invite_id) safe global_id.

        // --- gates (no state mutation until all pass) ---
        // single-use lookup: the invite must be one I minted and not yet redeemed.
        rec = pending_invites invite_id.
        abort "Unknown or already-redeemed invite." when rec == NIL.
        eph_priv = pending_invite_keys invite_id.
        abort "Invite ephemeral key missing (already consumed or not persisted)." when eph_priv == NIL.

        epk_r = (args $epk) safe publickey_encrypt.
        ct = (args $data) safe crypto_message.
        // box-open: aborts on tamper / wrong key BEFORE anything is consumed.
        payload = _read_or_abort (_crypto_decrypt_message eph_priv? epk_r ct).

        // --- 0.5.0 registry gate (BEFORE any strict read of the payload) ---
        // Dispatch on the peer's wire version and exact-cast to the registered
        // type (REG-4). A below-floor or unrecognized payload is the owner's
        // Addition A/B case: return the ERROR AS DATA to the INVITER via a
        // $protocol_error notify — transaction::success, NO abort, NO state
        // consumed (the invite stays redeemable: the peer can update and
        // redeem this same invite again). Crypto/tamper failures above and
        // identity-verification failures below remain HARD aborts by design.
        nr = a2a_versions::try_narrow_sir payload.
        if (nr $ok) != TRUE
        {
            err = (nr $err)?.
            return transaction::success [
                _notify_agent (
                    $event     -> $protocol_error,
                    $context   -> $invite_redeem,
                    $message   -> invite_version_error_message err,
                    $error     -> err,
                    $invite_id -> invite_id,
                    $peer_cid  -> sender_id
                )
            ].
        }
        // `narrowed` is union-typed: backward compat is visible in this
        // binding's type; per-version reads go through the registry accessors.
        narrowed is a2a_versions::sir_payload_t = (nr $payload)?.

        // Identity verification takes the RAW payload: narrow() rebuilds the
        // record to the registered fields, and verify must keep seeing exactly
        // what was sent (also future-proof for fields newer than we know).
        // D8 cid-bind + PoP self-sig, then the optional delegation chain — an
        // invalid chain or forged/inconsistent AD aborts before any write.
        vb = verify_identity_bundle payload sender_id.

        // --- all gates passed: register + single-use consume (INV-5) ---
        contact_name is str = (rec?) $assigned.
        if contact_name == ""
        {
            // REGISTRY DISPATCH replaces the 0.3.0 strict read that caused the
            // incident ((payload $name) safe str on a NIL): the v3/v5 branches
            // return the sent $name; the v2 branch returns "" (no such field
            // in sir_payload_v2_t) and we fall back to the sender cid.
            joiner_name is str = a2a_versions::sir_joiner_name narrowed.
            contact_name -> (joiner_name == "" ?? (_str sender_id) ; joiner_name).
        }
        contacts sender_id -> ($name -> contact_name, $container_id -> sender_id).
        // Passive version learning (SPEC §3): dialect + piggybacked caps.
        learn_contact_version sender_id (a2a_versions::sir_version_of payload) (a2a_versions::sir_caps narrowed).
        peer_ads sender_id -> (vb $ad).
        // Born-on-DR iff the peer presented a v2 (bundle-carrying) AD at first contact.
        if (peer_has_e2e_bundle sender_id) { contact_born_dr sender_id -> TRUE. }
        if (vb $root) != NIL { contact_roots sender_id -> (vb $root)?. }
        if (vb $pin_binding) != NIL { contact_cp_bindings ((vb $pin_binding_root)?) -> (vb $pin_binding)?. }
        delete pending_invites invite_id.
        delete pending_invite_keys invite_id.

        // reply leg 3 as a BARE BOXED send (NOT encrypted_channel): the responder
        // has NOT registered me yet, so it could not resolve my source key to open a
        // send_encrypted_tx (the M0 spike's "Unknown source key" on the receiver is
        // exactly this — see the leg-3 correction). Instead I box my identity bundle
        // to the responder's EPHEMERAL pubkey (epk_r, carried in leg 1) with a fresh
        // inviter ephemeral; the responder opens it with the ephemeral private key it
        // kept. encrypted_channel resumes for all post-contact traffic, both sides
        // being registered after leg 3.
        // The responder's just-verified AD tells me its version directly: a v1 AD
        // ($version==1, no $e2e_bundle) is an old peer — down-level my leg-3 AD to v1
        // so it accepts my bundle. (leg 1 read the invite version blind; here I have
        // the real AD, so I key off it.)
        peer_is_v1 = (((vb $ad) $version) == 1).
        b = my_identity_bundle_fields peer_is_v1.
        kpi = _crypto_construct_encryption_keypair (rec? $scheme).
        // The literal cin_payload_v5_t shape ($pv/$caps; this surface never
        // carried $name). 0.2.0 responders ignore the additions.
        leg3_payload = _write (
            $ad -> (b $ad),
            $cert -> (b $cert),
            $root_profile -> (b $root_profile),
            $cp_binding -> (b $cp_binding),
            $invite_id -> invite_id,
            $pv   -> a2a_versions::wire_version,
            $caps -> (a2a_capabilities::self_cap_ids NIL)
        ).
        leg3_data = _crypto_encrypt_message (kpi $secret_key) epk_r leg3_payload.
        return transaction::success [
            transaction::action::send sender_id (
                $name -> complete_invite_tx,
                $targ -> (
                    $invite_id -> invite_id,
                    $epk -> (kpi $public_key),
                    $v -> (rec? $scheme),
                    $data -> leg3_data,
                    $pv -> a2a_versions::wire_version
                )
            ),
            _notify_agent ($event -> $contact_accepted, $name -> contact_name, $container_id -> sender_id),
            _save_state NIL
        ].
    }

    // core 3.0 LEG 3 (responder): the inviter completed the exchange. It is a BARE
    // BOXED send (NOT encrypted_channel — see the leg-2 reply), so it intentionally
    // SKIPS check_encrypted_or_abort; the box (to my kept ephemeral key) is the
    // confidentiality/integrity, and authenticity comes from the inviter-cid pin +
    // cid-bind + PoP. Gate discipline (INV-5): pend lookup -> inviter-cid pin ->
    // decrypt -> cid-bind -> PoP -> chain, all before the contact is registered.
    // Clears BOTH responder stores (pending_redemptions + pending_redemption_keys).
    fn handle_complete_invite (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        invite_id = (args $invite_id) safe global_id.

        // --- gates (no state mutation until all pass) ---
        pend = pending_redemptions invite_id.
        abort "Unsolicited completion." when pend == NIL.
        abort "Completion from unexpected inviter." when sender_id != (pend?) $inviter_cid.
        eph_priv_r = pending_redemption_keys invite_id.
        abort "Redemption ephemeral key missing (already completed or not persisted)." when eph_priv_r == NIL.

        epk_i = (args $epk) safe publickey_encrypt.
        ct = (args $data) safe crypto_message.
        // box-open with the kept responder ephemeral private key (aborts on tamper).
        payload = _read_or_abort (_crypto_decrypt_message eph_priv_r? epk_i ct).

        // --- 0.5.0 registry gate (cin) — error-as-data, never an abort ------
        // A version-incompatible completion surfaces to MY client as a
        // $protocol_error notify; the pending redemption stays (transient,
        // GC'd with the stores) so a corrected completion can still land.
        nr = a2a_versions::try_narrow_cin payload.
        if (nr $ok) != TRUE
        {
            err = (nr $err)?.
            return transaction::success [
                _notify_agent (
                    $event     -> $protocol_error,
                    $context   -> $invite_complete,
                    $message   -> ("An invite you redeemed was completed by an inviter running an unsupported protocol version. The contact was not added — ask them to update their client. (" + (err $message) + ")"),
                    $error     -> err,
                    $invite_id -> invite_id,
                    $peer_cid  -> sender_id
                )
            ].
        }
        narrowed is a2a_versions::cin_payload_t = (nr $payload)?.

        // D8 cid-bind + PoP self-sig, then the optional delegation chain — an
        // invalid chain or forged/inconsistent AD aborts before any write.
        vb = verify_identity_bundle payload sender_id.

        // --- all gates passed: register + clear the pending redemption ---
        // name: my chosen custom name, else the inviter's invite name, else its cid.
        contact_name is str = (pend?) $custom_name.
        if contact_name == "" { contact_name -> (pend?) $inviter_name. }
        if contact_name == "" { contact_name -> (_str sender_id). }
        contacts sender_id -> ($name -> contact_name, $container_id -> sender_id).
        learn_contact_version sender_id (a2a_versions::cin_version_of payload) (a2a_versions::cin_caps narrowed).
        peer_ads sender_id -> (vb $ad).
        // Born-on-DR iff the peer presented a v2 (bundle-carrying) AD at first contact.
        if (peer_has_e2e_bundle sender_id) { contact_born_dr sender_id -> TRUE. }
        if (vb $root) != NIL { contact_roots sender_id -> (vb $root)?. }
        if (vb $pin_binding) != NIL { contact_cp_bindings ((vb $pin_binding_root)?) -> (vb $pin_binding)?. }
        delete pending_redemptions invite_id.
        delete pending_redemption_keys invite_id.

        return transaction::success [
            _notify_agent ($event -> $contact_added, $name -> contact_name, $container_id -> sender_id),
            _save_state NIL
        ].
    }

    // Inbound trn stubs (declared AFTER their handlers — mufl requires
    // define-before-use, as with accept_contact/handle_accept_contact above).
    trn submit_invite_response args: any
    {
        return handle_submit_invite_response args.
    }

    trn complete_invite args: any
    {
        return handle_complete_invite args.
    }

    // ==== contact restore (spec 2026-07-01): re-run the key exchange between
    // MUTUALLY KNOWN addresses after a breaking change dropped peer_ads. Same
    // machinery as the eph-invite legs (bundle, box-to-eph-key, INV-5 gate
    // ordering); the trust gate is "#77-origin-verified signed request from an
    // address already in my contacts" instead of an OOB invite token.

    // LEG 0 (responder): a contact lost my address document and asks me to
    // re-exchange keys. BARE inbound — #77 signs every envelope and rejects
    // unsigned/forged origin, so the envelope $from IS the authenticated
    // requester. Gate: requester ∈ contacts, else a SILENT no-op (success with
    // no actions — no error reply, so whether an address is known never leaks).
    // NON-DESTRUCTIVE: nothing is installed or replaced here; my stored peer_ad
    // for the requester (possibly stale, possibly absent) is only replaced at
    // leg 2 after its bundle verifies. At most ONE outstanding reply record per
    // requester — a newer request replaces it (bounded by the contacts set).
    // Accepted trade-off: a replayed/duplicate leg 0 supersedes the previous
    // reply record, so an in-flight leg 2 for the older rid then fails its gate
    // — transient, self-heals on the next sweep; nothing is installable by the
    // replayer.
    fn handle_request_contact_restore (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        if (contacts sender_id) == NIL { return transaction::success []. }

        rid = (args $rid) safe global_id.
        epk_requester = (args $epk) safe publickey_encrypt.
        scheme = (args $v) safe int.
        now = (current_transaction_info::get_transaction_time())?.

        kpr = _crypto_construct_encryption_keypair scheme.
        pending_restore_replies sender_id -> ($rid -> rid, $scheme -> scheme, $created -> now).
        pending_restore_reply_keys sender_id -> (kpr $secret_key).

        b = my_identity_bundle_fields NIL.
        // rst_payload_v5_t shape ($pv/$caps piggyback, SPEC §3/§4).
        payload = _write (
            $ad -> (b $ad), $cert -> (b $cert), $root_profile -> (b $root_profile),
            $cp_binding -> (b $cp_binding), $rid -> rid,
            $pv -> a2a_versions::wire_version, $caps -> (a2a_capabilities::self_cap_ids NIL)
        ).
        data = _crypto_encrypt_message (kpr $secret_key) epk_requester payload.
        return transaction::success [
            transaction::action::send sender_id (
                $name -> submit_restore_response_tx,
                $targ -> ($rid -> rid, $epk -> (kpr $public_key), $v -> scheme, $data -> data, $pv -> a2a_versions::wire_version)
            ),
            _save_state NIL
        ].
    }

    trn request_contact_restore args: any
    {
        return handle_request_contact_restore args.
    }

    // LEG 1 (requester): the contact answered with its identity bundle boxed to
    // my leg-0 ephemeral pubkey. Gate discipline (INV-5): pend lookup -> rid pin
    // -> decrypt -> cid-bind -> PoP -> chain, all before any write. Single-use:
    // the first valid leg 1 consumes BOTH pending_restores and the hidden eph
    // key; a failed gate consumes nothing. Replies leg 2 as a BARE BOXED send —
    // the responder may not hold MY current AD until that bundle arrives, so the
    // encrypted channel cannot carry it (same reasoning as the invite leg 3).
    fn handle_submit_restore_response (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        rid = (args $rid) safe global_id.

        // --- gates (no state mutation until all pass) ---
        pend = pending_restores sender_id.
        abort "Unsolicited restore response." when pend == NIL.
        abort "Restore response does not match the outstanding request." when rid != ((pend?) $rid).
        eph_priv = pending_restore_keys sender_id.
        abort "Restore ephemeral key missing (superseded or already completed)." when eph_priv == NIL.
        abort "Restore response from a removed contact." when (contacts sender_id) == NIL.

        epk_r = (args $epk) safe publickey_encrypt.
        scheme = (args $v) safe int.
        ct = (args $data) safe crypto_message.
        payload = _read_or_abort (_crypto_decrypt_message eph_priv? epk_r ct).

        // --- 0.5.0 registry gate (rst) — error-as-data, never an abort ------
        // The degraded contact stays degraded (request not consumed: the boot
        // sweep re-attempts, and a corrected reply can still land).
        nr = a2a_versions::try_narrow_rst payload.
        if (nr $ok) != TRUE
        {
            err = (nr $err)?.
            return transaction::success [
                _notify_agent (
                    $event    -> $protocol_error,
                    $context  -> $contact_restore,
                    $message  -> ("A contact could not be restored: the peer runs an unsupported protocol version. Ask them to update their client. (" + (err $message) + ")"),
                    $error    -> err,
                    $peer_cid -> sender_id
                )
            ].
        }
        narrowed is a2a_versions::rst_payload_t = (nr $payload)?.

        // Post-gate the $rid domain is checked, so this strict read cannot abort.
        abort "Restore payload correlation mismatch." when ((payload $rid) safe global_id) != rid.
        vb = verify_identity_bundle payload sender_id.

        // --- all gates passed: (re)install the peer's keys + single-use consume ---
        learn_contact_version sender_id (a2a_versions::rst_version_of payload) (a2a_versions::rst_caps narrowed).
        peer_ads sender_id -> (vb $ad).
        if (vb $root) != NIL { contact_roots sender_id -> (vb $root)?. }
        if (vb $pin_binding) != NIL { contact_cp_bindings ((vb $pin_binding_root)?) -> (vb $pin_binding)?. }
        delete pending_restores sender_id.
        delete pending_restore_keys sender_id.

        b = my_identity_bundle_fields NIL.
        kp2 = _crypto_construct_encryption_keypair scheme.
        // rst_payload_v5_t shape ($pv/$caps piggyback, SPEC §3/§4).
        leg2_payload = _write (
            $ad -> (b $ad), $cert -> (b $cert), $root_profile -> (b $root_profile),
            $cp_binding -> (b $cp_binding), $rid -> rid,
            $pv -> a2a_versions::wire_version, $caps -> (a2a_capabilities::self_cap_ids NIL)
        ).
        leg2_data = _crypto_encrypt_message (kp2 $secret_key) epk_r leg2_payload.
        contact_name = ((contacts sender_id)?) $name.
        return transaction::success [
            transaction::action::send sender_id (
                $name -> complete_restore_tx,
                $targ -> ($rid -> rid, $epk -> (kp2 $public_key), $v -> scheme, $data -> leg2_data, $pv -> a2a_versions::wire_version)
            ),
            _notify_agent ($event -> $contact_restored, $name -> contact_name, $container_id -> sender_id),
            _save_state NIL
        ].
    }

    trn submit_restore_response args: any
    {
        return handle_submit_restore_response args.
    }

    // LEG 2 (responder): the requester completed with ITS bundle boxed to my
    // leg-1 ephemeral pubkey. Same gate discipline; only HERE do I REPLACE my
    // stored peer_ad for the requester — required even when one is present: a
    // #77 reseed rolls the peer a fresh ENCRYPT key, so a surviving stale AD
    // would break my sends toward it. Single-use consume of the reply stores.
    fn handle_complete_restore (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        rid = (args $rid) safe global_id.

        // --- gates (no state mutation until all pass) ---
        pend = pending_restore_replies sender_id.
        abort "Unsolicited restore completion." when pend == NIL.
        abort "Restore completion does not match the outstanding reply." when rid != ((pend?) $rid).
        eph_priv = pending_restore_reply_keys sender_id.
        abort "Restore reply key missing (superseded or already completed)." when eph_priv == NIL.
        abort "Restore completion from a removed contact." when (contacts sender_id) == NIL.

        epk_i = (args $epk) safe publickey_encrypt.
        ct = (args $data) safe crypto_message.
        payload = _read_or_abort (_crypto_decrypt_message eph_priv? epk_i ct).

        // --- 0.5.0 registry gate (rst) — error-as-data, never an abort ------
        nr = a2a_versions::try_narrow_rst payload.
        if (nr $ok) != TRUE
        {
            err = (nr $err)?.
            return transaction::success [
                _notify_agent (
                    $event    -> $protocol_error,
                    $context  -> $contact_restore,
                    $message  -> ("A contact could not complete a key restore: the peer runs an unsupported protocol version. Ask them to update their client. (" + (err $message) + ")"),
                    $error    -> err,
                    $peer_cid -> sender_id
                )
            ].
        }
        narrowed is a2a_versions::rst_payload_t = (nr $payload)?.

        // Post-gate the $rid domain is checked, so this strict read cannot abort.
        abort "Restore payload correlation mismatch." when ((payload $rid) safe global_id) != rid.
        vb = verify_identity_bundle payload sender_id.

        // --- all gates passed: replace + single-use consume ---
        learn_contact_version sender_id (a2a_versions::rst_version_of payload) (a2a_versions::rst_caps narrowed).
        peer_ads sender_id -> (vb $ad).
        if (vb $root) != NIL { contact_roots sender_id -> (vb $root)?. }
        if (vb $pin_binding) != NIL { contact_cp_bindings ((vb $pin_binding_root)?) -> (vb $pin_binding)?. }
        delete pending_restore_replies sender_id.
        delete pending_restore_reply_keys sender_id.

        contact_name = ((contacts sender_id)?) $name.
        return transaction::success [
            _notify_agent ($event -> $contact_restored, $name -> contact_name, $container_id -> sender_id),
            _save_state NIL
        ].
    }

    trn complete_restore args: any
    {
        return handle_complete_restore args.
    }

    metadef degraded_contact_t: ($container_id -> global_id, $name -> str, $attempts -> int, $queued -> int).
    metadef deferred_queue_info_t: ($container_id -> global_id, $name -> str, $queued -> int, $degraded -> bool).

    // Degraded contacts (known cid, no AD) with their restore-attempt counts and
    // queued-message counts — the host's boot/GC sweep + list_contacts marker.
    trn readonly list_degraded_contacts _
    {
        out is degraded_contact_t[] = [].
        sc contacts -- (cid -> c) ?? (peer_ads cid) == NIL
        {
            att is int = 0.
            pr = pending_restores cid.
            if pr != NIL { att -> ((pr?) $attempts). }
            nq is int = 0.
            dq = deferred_msgs cid.
            if dq != NIL { nq -> (_count dq?|). }
            out (_count out|) -> ($container_id -> cid, $name -> (c $name), $attempts -> att, $queued -> nq).
        }
        return ($degraded -> out).
    }

    // Every non-empty deferred queue + whether its contact is still degraded —
    // lets the host flush queues whose contact healed without a notify (e.g. a
    // daemon restart between restore and flush).
    trn readonly list_deferred_queues _
    {
        out is deferred_queue_info_t[] = [].
        sc deferred_msgs -- (cid -> q) ?? (_count q|) > 0
        {
            nm is str = "".
            c = contacts cid.
            if c != NIL { nm -> ((c?) $name). }
            out (_count out|) -> ($container_id -> cid, $name -> nm, $queued -> (_count q|), $degraded -> ((peer_ads cid) == NIL)).
        }
        return ($queues -> out).
    }

    // Host-fired sweep (boot + GC cadence): (re)issue a restore request for every
    // degraded contact, up to restore_max_attempts each. A peer that is offline
    // or not yet running a restore-capable version simply never answers — the
    // sweep retries on the host's cadence; no reply is a normal condition.
    trn restore_degraded_contacts _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        actions is transaction::action::type[] = [].
        requested is int = 0.
        exhausted is int = 0.
        sc contacts -- (cid -> c) ?? (peer_ads cid) == NIL
        {
            prev = pending_restores cid.
            if prev != NIL && ((prev?) $attempts) >= restore_max_attempts
            {
                exhausted -> exhausted + 1.
            }
            else
            {
                sc begin_contact_restore cid -- ( -> a) { actions (_count actions|) -> a. }
                requested -> requested + 1.
            }
        }
        actions (_count actions|) -> _return_data ($requested -> requested, $exhausted -> exhausted).
        if requested > 0 { actions (_count actions|) -> _save_state NIL. }
        return transaction::success actions.
    }

    // Drain the deferred queue toward a contact whose AD is re-established.
    // HOST-DRIVEN (fired on the $contact_restored notify + the boot/GC sweep) so
    // the encrypted sends never race the restore legs' bare sends on the wire —
    // the host round-trip guarantees leg 2 delivery precedes the flush.
    // Idempotent: an empty or still-degraded queue is a no-op result, not an error.
    trn flush_deferred _:($contact -> contact_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        target_id = resolve_contact contact_ref.
        q = deferred_msgs target_id.
        if q == NIL || (_count q?|) == 0 { return transaction::success [ _return_data ($flushed -> 0) ]. }
        if (peer_ads target_id) == NIL { return transaction::success [ _return_data ($flushed -> 0, $degraded -> TRUE) ]. }

        return encrypted_channel::execute_transaction target_id (fn (_) -> transaction::results::type {
            actions is transaction::action::type[] = [].
            sc q? -- ( -> m)
            {
                actions (_count actions|) -> encrypted_channel::send_encrypted_tx target_id (
                    $name -> receive_message_tx,
                    $targ -> ($text -> (m $text), $wire_id -> (m $wire_id), $reply_to -> (m $reply_to), $pv -> a2a_versions::wire_version)
                ).
                sc on_message_sent ($target_id -> target_id, $text -> (m $text), $date -> (m $date), $wire_id -> (m $wire_id), $reply_to -> (m $reply_to)) -- ( -> a)
                {
                    actions (_count actions|) -> a.
                }
                sc post_send_middleware ($target_id -> target_id, $text -> (m $text), $date -> (m $date), $wire_id -> (m $wire_id), $reply_to -> (m $reply_to)) -- ( -> a)
                {
                    actions (_count actions|) -> a.
                }
                sc monitor_copy_actions "out" target_id (m $date) (m $text) -- ( -> a)
                {
                    actions (_count actions|) -> a.
                }
            }
            n = _count q?|.
            delete deferred_msgs target_id.
            actions (_count actions|) -> _return_data ($flushed -> n).
            actions (_count actions|) -> _save_state NIL.
            return transaction::success actions.
        }).
    }

    // Validation + contact resolution only; STORAGE is the app's, through the
    // on_message_received hook. $sender_name is NIL for an unknown sender —
    // the hook decides whether that is queueable (agent: pending-introduction
    // queue) or a rejection. Args are taken as `any` (not a destructured shape)
    // so a pre-wire_id sender — whose payload carries only $text — keeps working
    // unchanged, and so new optional fields ($wire_id, $reply_to) are tolerated.
    fn handle_receive_message (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        msg_date = (current_transaction_info::get_transaction_time())?.
        text = (args $text) safe str.

        // Optional, absent from pre-1.4 senders: the message's stable wire id
        // and an optional reply pointer. Default to "" / NIL so old payloads and
        // the agent storage hook behave exactly as before.
        wire_id is str = "".
        if (args $wire_id) != NIL { wire_id -> (args $wire_id) safe str. }
        reply_to is a2a_protocol::reply_ref_t+ = NIL.
        if (args $reply_to) != NIL { reply_to -> (args $reply_to) safe a2a_protocol::reply_ref_t. }

        // §5.7 RECEIVE-SIDE DOWNGRADE REFUSAL (MigrationReview — the receive-direction
        // confidentiality property). A legacy PLAINTEXT app message from an EPOCH-PINNED (migrated)
        // contact is a downgrade attempt: a migrated peer's app data MUST arrive over the e2e box
        // (receive_e2e_message). DROP it (never deliver to the app, no receipt) + a typed notify;
        // the migration sweep re-heals the session if the peer genuinely regressed. Pins UNTOUCHED.
        if (contact_e2e_epoch sender_id) != NIL
        { return transaction::success [ _notify_agent ($event -> $downgrade_refused, $cid -> sender_id, $wire_id -> wire_id) ]. }

        sender = contacts sender_id.
        sender_name is str+ = NIL.
        if sender != NIL
        {
            sender_name -> sender? $name.
        }

        // Passive version learning: only a STAMPED $pv is evidence (an
        // unstamped message says just "pre-0.5", which must not overwrite the
        // more precise dialect the invite/restore legs shape-inferred).
        pv_seen = a2a_versions::peer_pv args.
        if pv_seen != 0 { learn_contact_version sender_id pv_seen []. }

        // The app hook owns storage; it may abort (unknown sender rejected) — in
        // which case nothing is delivered and no copy is emitted. When it accepts,
        // we append the FORCED inbound monitoring copy as core code (after the hook,
        // self-gating on monitoring_proxy) so the app cannot suppress it.
        actions is transaction::action::type[] = [].
        // NOTE (core 0.9.0): the §5.5 implicit-confirm evidence RELOCATED to handle_receive_e2e_
        // message — under Option B a responder's post-active app arrives on the DISTINCT e2e box,
        // not here. This legacy plaintext handler no longer promotes; an epoch-pinned sender is
        // already refused above (downgrade), and a still-migrating pair's plaintext is ordinary
        // pre-migration traffic.
        sc on_message_received (
            $sender_id   -> sender_id,
            $sender_name -> sender_name,
            $text        -> text,
            $date        -> msg_date,
            $wire_id     -> wire_id,
            $reply_to    -> reply_to
        ) -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        sc monitor_copy_actions "in" sender_id msg_date text -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        // core 0.7.0: DELIVERED receipt, emitted atomically with acceptance
        // (the hook above may abort = message rejected = no receipt; from here
        // the message IS stored). Fire-and-forget; gated on positive caps;
        // pre-wire_id senders have no handle (and no cap) — nothing emitted.
        if wire_id != ""
        {
            sc receipt_actions sender_id "delivered" [wire_id] -- ( -> a)
            {
                actions (_count actions|) -> a.
            }
        }
        // §5.4 trigger: liveness offer on first 0.9 evidence from this peer (fires once — then
        // contact_migration is set and mig_trigger_actions returns []). _save_state persists it.
        trig is transaction::action::type[] = mig_trigger_actions sender_id.
        if (_count trig|) > 0
        {
            sc trig -- ( -> a) { actions (_count actions|) -> a. }
            actions (_count actions|) -> _save_state NIL.
        }
        return transaction::success actions.
    }

    trn receive_message args: any
    {
        return handle_receive_message args.
    }

    // File analogue of handle_receive_message: validate + resolve sender, then hand
    // the file to the app's on_file_received storage hook (the app owns storage; it
    // may abort an unknown sender). $mime/$wire_id/$reply_to are optional and default
    // to ""/""/NIL so a looser sender is tolerated. Forced metadata-only monitoring copy is appended after the hook.
    fn handle_receive_file (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().

        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        file_date = (current_transaction_info::get_transaction_time())?.
        filename = (args $filename) safe str.
        data = (args $data) safe bin.
        mime is str = "".
        if (args $mime) != NIL { mime -> (args $mime) safe str. }
        wire_id is str = "".
        if (args $wire_id) != NIL { wire_id -> (args $wire_id) safe str. }
        reply_to is a2a_protocol::reply_ref_t+ = NIL.
        if (args $reply_to) != NIL { reply_to -> (args $reply_to) safe a2a_protocol::reply_ref_t. }

        // §5.7 RECEIVE-SIDE DOWNGRADE REFUSAL (file analogue): a legacy plaintext file from an
        // epoch-PINNED contact is a downgrade attempt — drop + typed notify, never delivered.
        if (contact_e2e_epoch sender_id) != NIL
        { return transaction::success [ _notify_agent ($event -> $downgrade_refused, $cid -> sender_id, $wire_id -> wire_id) ]. }

        sender = contacts sender_id.
        sender_name is str+ = NIL.
        if sender != NIL
        {
            sender_name -> sender? $name.
        }

        // Passive version learning (see handle_receive_message).
        pv_seen = a2a_versions::peer_pv args.
        if pv_seen != 0 { learn_contact_version sender_id pv_seen []. }

        actions is transaction::action::type[] = [].
        sc on_file_received (
            $sender_id   -> sender_id,
            $sender_name -> sender_name,
            $filename    -> filename,
            $mime        -> mime,
            $data        -> data,
            $date        -> file_date,
            $wire_id     -> wire_id,
            $reply_to    -> reply_to
        ) -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        sc monitor_copy_actions "in" sender_id file_date (file_monitor_summary filename mime data) -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        // core 0.7.0: DELIVERED receipt (files share the wire_id namespace).
        if wire_id != ""
        {
            sc receipt_actions sender_id "delivered" [wire_id] -- ( -> a)
            {
                actions (_count actions|) -> a.
            }
        }
        return transaction::success actions.
    }

    trn receive_file args: any
    {
        return handle_receive_file args.
    }

    // Shared helpers for the two app-e2e RECEIVE handlers (message + file). FACTORED so the
    // meta-heavy record literals — the $e2e_app_recv notify, the implicit-confirm contact_migration
    // write + $migration_active notify — are type-reduced ONCE, not inlined in both handlers: the
    // full daemon packet compiles the migration surface near the per-unit meta-fuel ceiling, and the
    // duplicated inlines pushed it over (see the transaction/AD any-typing fixes). Behavior is
    // byte-identical to the inlined form.
    // A rejected inbound (no-downgrade GATE0 / accept-gate / decode !ok): $e2e_app_recv $ok=FALSE,
    // never delivered. $session_id is the inbound envelope's (NIL for a malformed GATE0 envelope).
    // core 0.11: $code names WHY (additive notify field — observability, never silent):
    //   "malformed" (GATE0) | "gate" (accept gate) | "no_peer_ad" (GATE1.5) |
    //   the typed e2e decode code ("no_session" | "session_mismatch" | "tampered" | ...).
    fn mig_e2e_reject_actions (sender_id: global_id, env_sid: bin+, code: str) -> transaction::action::type[]
    {
        return [ _notify_agent ($event -> $e2e_app_recv, $cid -> sender_id, $session_id -> env_sid, $ok -> FALSE, $wire_id -> "", $code -> code) ].
    }
    fn mig_e2e_reject (sender_id: global_id, env_sid: bin+, code: str) -> transaction::results::type
    {
        return transaction::success (mig_e2e_reject_actions sender_id env_sid code).
    }
    // Shared ACCEPT-gate + do_ic computation for the two app-e2e RECEIVE handlers. Returns
    // ($accept, $do_ic). accept = e2e_pinned/seen OR committed-initiator-with-staged-match. do_ic
    // (§5.5 must-fix-C) is DECOUPLED — a box-only committed initiator (staged==committed session, NO
    // live session, NOT yet epoch-pinned) even when seen, so implicit-confirm stays reachable in
    // production (a real migrating pair advertises cap_e2e ⇒ seen by `committed`).
    fn mig_e2e_accept (sender_id: global_id) -> (any)
    {
        st = contact_migration sender_id.
        committed_match is bool = FALSE.
        do_ic is bool = FALSE.
        if st != NIL && ((st?) $phase) == "committed" && ((st?) $initiator) == TRUE
        {
            staged_sid = e2e::staged_session_id sender_id.
            if staged_sid != NIL && ((st?) $session_id) != NIL && staged_sid == ((st?) $session_id)
            {
                committed_match -> TRUE.
                if (e2e::active_session_id sender_id) == NIL && (contact_e2e_epoch sender_id) == NIL { do_ic -> TRUE. }
            }
        }
        return ($accept -> (committed_match || (e2e_pinned sender_id)), $do_ic -> do_ic).
    }
    // §5.5 must-fix-C IMPLICIT-CONFIRM promotion (box-only committed initiator → active): commit_
    // rotation (SOLE promotion) + BOTH pins + active + EXTENDED $migration_active + flush, returned
    // as actions to append BEFORE the deliver hook so the whole thing rides the app hook's tx (an
    // abort rolls promotion + pins + flush back and the FSM stays `committed`).
    fn mig_e2e_promote_actions (sender_id: global_id, st: mig_state_t) -> transaction::action::type[]
    {
        e2e::commit_rotation sender_id.
        ic_fin = e2e::active_session_id sender_id.
        ic_ep = (st $epoch)?.
        contact_e2e_epoch sender_id -> ( $epoch -> ic_ep, $session_id -> (ic_fin?) ).
        contact_e2e_seen sender_id -> TRUE.
        ic_now = (current_transaction_info::get_transaction_time())?.
        contact_migration sender_id -> ( $phase -> "active", $initiator -> TRUE,
            $local_nonce -> (st $local_nonce), $peer_nonce -> (st $peer_nonce), $epoch -> ic_ep, $session_id -> (ic_fin?),
            $local_bundle -> (st $local_bundle), $local_fp -> (st $local_fp), $attempts -> (st $attempts), $updated -> ic_now ).
        acts is transaction::action::type[] = [ _notify_agent ($event -> $migration_active, $cid -> sender_id, $role -> $initiator, $epoch -> ic_ep, $session_id -> (ic_fin?)) ].
        sc flush_mig_deferred_actions sender_id -- ( -> a) { acts (_count acts|) -> a. }
        return acts.
    }
    // Delivery tail shared by both handlers: DELIVERED receipt (gated on a wire_id) + the §4
    // $e2e_app_recv notify (session_id from the ACTUAL inbound envelope, non-circular #1867 proof) +
    // _save_state (the e2e decode advanced the ratchet — persist unconditionally on the accept path).
    fn mig_e2e_deliver_tail (sender_id: global_id, wire_id: str, env_sid: bin+) -> transaction::action::type[]
    {
        acts is transaction::action::type[] = [].
        // core 0.11 self-heal: a successful decode from this cid means the pair converged —
        // reset BOTH re-key budgets (requester + responder ledgers) so a FUTURE genuine
        // desync gets a fresh one.
        if (rekey_pending sender_id) != NIL { delete rekey_pending sender_id. }
        if (rekey_served sender_id) != NIL { delete rekey_served sender_id. }
        // Record the delivery for the at-least-once redrive dedup (no-op on ""). Rides the
        // same tx as the deposit, so guard and inbox commit or roll back together.
        // Ship-review major-3: crossing the storage ceiling drops the oldest in-TTL
        // entry — a real dedup-guarantee loss, surfaced, never silent.
        dn = delivered_note sender_id wire_id.
        if (dn $dropped) != NIL
        { acts (_count acts|) -> _notify_agent ($event -> $dedup_degraded, $cid -> sender_id, $dropped_wire_id -> ((dn $dropped)?)). }
        if wire_id != ""
        { sc receipt_actions sender_id "delivered" [wire_id] -- ( -> a) { acts (_count acts|) -> a. } }
        acts (_count acts|) -> _notify_agent ($event -> $e2e_app_recv, $cid -> sender_id, $session_id -> env_sid, $ok -> TRUE, $wire_id -> wire_id).
        acts (_count acts|) -> _save_state NIL.
        return acts.
    }

    // ── core 0.9.0 boxed APP-E2E RECEIVE (Option B, spec §5.6/§4). App data over a MIGRATED
    // session rides a DISTINCT box (receive_e2e_message_tx) carrying the e2e_signed_message as
    // $targ. THIS handler drives the same audited decode the commit/confirm handlers use
    // (e2e::decode_migration_envelope: S2 wire-pv, S1 emsig over $from/$to/$envelope bound to the
    // box sender + me, then decrypt+commit on the migrated session), delivers the plaintext to the
    // app hook, and — for the §5.5 box-only committed-initiator window — folds in the IMPLICIT
    // CONFIRM (relocated here from the legacy handler). SECURITY invariants (MigrationReview #27):
    //   • no-downgrade: a missing/garbage e2e envelope FAILS closed (never a legacy/plaintext read);
    //   • ACCEPT-gate: deliver ONLY from an epoch-PINNED contact OR a committed-initiator whose
    //     staged rotation IS the committed session (an unpinned peer never reaches the decrypt);
    //   • authenticated decode: $from == box sender, forged emsig/wire ABORTS inside the decode;
    //   • no plaintext leak: the decrypted body is delivered ONLY through on_message_received;
    //   • must-fix-C: implicit-confirm promotion + pins + flush ride the SAME tx as the app hook —
    //     if the hook ABORTS, they all roll back and the FSM stays `committed`.
    // §4 observability: $e2e_app_recv $session_id is sourced from the ACTUAL inbound envelope (NOT
    // a re-read of active_session_id — that would make the #1867 "session_id == pin" check circular).
    fn handle_receive_e2e_message (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        msg_date = (current_transaction_info::get_transaction_time())?.

        // GATE 0 — carrier shape (no-downgrade: fail CLOSED on a missing/garbage envelope).
        env is e2e::t_e2e_envelope+ = (args $e2e_envelope) safe e2e::t_e2e_envelope.
        emsig is crypto_signature+ = (args $emsignature) safe crypto_signature.
        if env == NIL || emsig == NIL { return mig_e2e_reject sender_id NIL "malformed". }
        env_sid = (env? $session_id).

        // GATE 1 — ACCEPT gate. The SEND side boxes app as receive_e2e_message_tx whenever the route
        // is "e2e" AND the peer is (seen || epoch-pinned) — EVERY e2e-capable pair, not just migrated
        // ones (an already-E2E pre-migration pair rides the e2e box too). ACCEPT from any e2e_pinned/
        // seen contact OR a committed INITIATOR whose STAGED rotation is the committed session (the
        // responder's post-active app arriving BEFORE our explicit confirm). Any other state → reject
        // as data, NEVER decode (no session mutation from a non-e2e peer). BROADER than the §5.7
        // downgrade-refusal (epoch-only): a seen-not-epoch peer's LEGACY plaintext is still accepted.
        // do_ic (§5.5 must-fix-C IMPLICIT CONFIRM) is computed on its OWN merits (see mig_e2e_accept),
        // DECOUPLED from the accept branch — else it would be UNREACHABLE in production (a real
        // migrating pair is `seen` by `committed`).
        g = mig_e2e_accept sender_id.
        if (g $accept) != TRUE { return mig_e2e_reject sender_id env_sid "gate". }
        do_ic is bool = (g $do_ic).

        // GATE 1.5 — the box sender's VERIFIED AD is required to authenticate the envelope.
        pad = peer_ads sender_id.
        if pad == NIL { return mig_e2e_reject sender_id env_sid "no_peer_ad". }

        // GATE 2 — handler-driven AUTHENTICATED decode (shared audited path). For a pinned/active
        // contact mig_pending is FALSE → decrypt_and_commit advances m_sessions[cid] (the migrated
        // session). For the do_ic box-only committed initiator, the responder's post-active
        // olm_type=1 rides the STAGED slot (m_sessions still NIL until commit_rotation in the
        // promote helper). A !ok is OLM-level (tampered/replay) — forged emsig/wire already ABORTED
        // inside decode_migration_envelope. Reject-as-data, never delivered.
        pre_sid is bin+ = e2e::active_session_id sender_id.
        r = e2e::decode_migration_envelope sender_id (_get_container_id()) (pad?) (env?) (emsig?).
        if (r $ok) != TRUE
        {
            // core 0.11 self-heal: surface the typed code, and on a desync signature
            // (no_session / session_mismatch / tampered) fire the rate-limited re-key
            // request back to the sender — the message is undecryptable forever, but the
            // pair re-keys and the sender's unacked redrive re-delivers it (no silent drop).
            code is str = "internal".
            if (r $error) != NIL { code -> ((r $error)?) $code. }
            racts is transaction::action::type[] = mig_e2e_reject_actions sender_id env_sid code.
            if rekey_desync_code code
            {
                // Signal the peer (carry my fresh AD; ask for re-key if it speaks the cap),
                // then — only if I am the elected initiator — mint the fresh session myself.
                sc rekey_signal_actions sender_id env_sid -- ( -> a) { racts (_count racts|) -> a. }
                sc maybe_init_rekey sender_id env_sid -- ( -> a) { racts (_count racts|) -> a. }
                racts (_count racts|) -> _save_state NIL.
            }
            return transaction::success racts.
        }
        // Decrypted inner app body (mirrors send_message's einner _write shape).
        iv = key_storage::read_external ((r $plaintext)?).
        // core 0.11 self-heal: a rekey PING (contentless bootstrap pre-key) — the decode above
        // established/replaced our session; redrive our buffer onto it and deliver NOTHING to
        // the inbox. Heals the pair without an app message.
        if (iv $rekey_ping) == TRUE
        {
            pacts is transaction::action::type[] = [].
            if (rekey_pending sender_id) != NIL { delete rekey_pending sender_id. }
            if (rekey_served sender_id) != NIL { delete rekey_served sender_id. }
            sc redrive_unacked_actions sender_id -- ( -> a) { pacts (_count pacts|) -> a. }
            pacts (_count pacts|) -> _notify_agent ($event -> $e2e_rekey, $cid -> sender_id, $role -> $healed, $session_id -> env_sid).
            pacts (_count pacts|) -> _save_state NIL.
            return transaction::success pacts.
        }
        text = (iv $text) safe str.
        wire_id is str = "".
        if (iv $wire_id) != NIL { wire_id -> (iv $wire_id) safe str. }
        reply_to is a2a_protocol::reply_ref_t+ = NIL.
        if (iv $reply_to) != NIL { reply_to -> (iv $reply_to) safe a2a_protocol::reply_ref_t. }

        // core 0.11 self-heal: at-least-once redrive dedup. An already-delivered wire_id
        // RE-ACKS (so the sender's unacked buffer clears even when the first receipt was
        // lost) but never re-deposits into the inbox. The decode above ADVANCED the
        // ratchet — persist it (the _save_state below), or a restart would desync again.
        if wire_id != "" && (wire_seen sender_id wire_id)
        {
            dacts is transaction::action::type[] = [].
            // Review #10: a duplicate can be the FIRST proof of the migrated session —
            // the implicit-confirm promotion must not be skipped or committed stalls.
            if do_ic { sc mig_e2e_promote_actions sender_id ((contact_migration sender_id)?) -- ( -> a) { dacts (_count dacts|) -> a. } }
            sc receipt_actions sender_id "delivered" [wire_id] -- ( -> a) { dacts (_count dacts|) -> a. }
            // Convergence must not be skipped on the duplicate path (finding I): the
            // decode above was a REAL successful decode — reset both re-key budgets
            // (a future genuine desync needs a fresh one), and if it was a pre-key
            // that REPLACED our live session (the peer restarted and is redriving),
            // re-encrypt our own retained sends onto the fresh session NOW — the
            // duplicate is often the FIRST inbound after the peer's recovery.
            if (rekey_pending sender_id) != NIL { delete rekey_pending sender_id. }
            if (rekey_served sender_id) != NIL { delete rekey_served sender_id. }
            dup_post_sid is bin+ = e2e::active_session_id sender_id.
            if pre_sid != NIL && dup_post_sid != NIL && (pre_sid?) != (dup_post_sid?)
            { sc redrive_unacked_actions sender_id -- ( -> a) { dacts (_count dacts|) -> a. } }
            dacts (_count dacts|) -> _notify_agent ($event -> $e2e_app_recv, $cid -> sender_id, $session_id -> env_sid, $ok -> TRUE, $wire_id -> wire_id, $duplicate -> TRUE).
            dacts (_count dacts|) -> _save_state NIL.
            return transaction::success dacts.
        }

        actions is transaction::action::type[] = [].
        // do_ic: promote BEFORE deliver, SAME tx (must-fix-C rollback — see mig_e2e_promote_actions).
        if do_ic { sc mig_e2e_promote_actions sender_id ((contact_migration sender_id)?) -- ( -> a) { actions (_count actions|) -> a. } }

        sender = contacts sender_id.
        sender_name is str+ = NIL.
        if sender != NIL { sender_name -> sender? $name. }
        // Deliver plaintext through the app hook (the ONLY exit for the decrypted body). It may ABORT
        // (unknown sender / rejected) — then nothing is delivered, the do_ic promotion rolls back, and
        // no receipt/notify is emitted (the tx is atomic).
        sc on_message_received (
            $sender_id   -> sender_id,
            $sender_name -> sender_name,
            $text        -> text,
            $date        -> msg_date,
            $wire_id     -> wire_id,
            $reply_to    -> reply_to
        ) -- ( -> a) { actions (_count actions|) -> a. }
        sc monitor_copy_actions "in" sender_id msg_date text -- ( -> a) { actions (_count actions|) -> a. }
        // core 0.11 self-heal: the decode REPLACED our live session (the peer's fresh pre-key
        // after ITS restart — the 0.8.0 establish path swapped m_sessions[cid]). Any sends we
        // retained re-encrypt on the fresh session NOW, so the pair converges without waiting
        // for a rekey round-trip.
        post_sid is bin+ = e2e::active_session_id sender_id.
        if pre_sid != NIL && post_sid != NIL && (pre_sid?) != (post_sid?)
        { sc redrive_unacked_actions sender_id -- ( -> a) { actions (_count actions|) -> a. } }
        sc mig_e2e_deliver_tail sender_id wire_id env_sid -- ( -> a) { actions (_count actions|) -> a. }
        // §5.4 trigger (the PRODUCTION-GAP fix): an already-e2e pair receives app data HERE (it never
        // plaintext-receives), so mirror the plaintext-handler liveness offer. Fires once — then
        // contact_migration!=NIL (+ the epoch pin) gate it. Reads STORED contact_caps/pv (no re-learn).
        // do_ic (committed) and the trigger are mutually exclusive (do_ic ⇒ contact_migration!=NIL ⇒
        // mig_should_trigger FALSE), so this never interacts with the implicit-confirm promotion above.
        trig is transaction::action::type[] = mig_trigger_actions sender_id.
        if (_count trig|) > 0
        {
            sc trig -- ( -> a) { actions (_count actions|) -> a. }
            actions (_count actions|) -> _save_state NIL.
        }
        return transaction::success actions.
    }

    trn receive_e2e_message args: any
    {
        return handle_receive_e2e_message args.
    }

    // File analogue of handle_receive_e2e_message — same decode/accept-gate/implicit-confirm/
    // downgrade discipline; delivers to on_file_received. Files ride the migrated session identically.
    fn handle_receive_e2e_file (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        file_date = (current_transaction_info::get_transaction_time())?.

        // GATE 0 — carrier shape (no-downgrade).
        env is e2e::t_e2e_envelope+ = (args $e2e_envelope) safe e2e::t_e2e_envelope.
        emsig is crypto_signature+ = (args $emsignature) safe crypto_signature.
        if env == NIL || emsig == NIL { return mig_e2e_reject sender_id NIL "malformed". }
        env_sid = (env? $session_id).

        // GATE 1 — ACCEPT gate + do_ic (shared with the message handler; do_ic decoupled).
        g = mig_e2e_accept sender_id.
        if (g $accept) != TRUE { return mig_e2e_reject sender_id env_sid "gate". }
        do_ic is bool = (g $do_ic).

        pad = peer_ads sender_id.
        if pad == NIL { return mig_e2e_reject sender_id env_sid "no_peer_ad". }

        // GATE 2 — authenticated decode.
        pre_sid is bin+ = e2e::active_session_id sender_id.
        r = e2e::decode_migration_envelope sender_id (_get_container_id()) (pad?) (env?) (emsig?).
        if (r $ok) != TRUE
        {
            // core 0.11 self-heal (file analogue — same desync trigger as the message handler).
            code is str = "internal".
            if (r $error) != NIL { code -> ((r $error)?) $code. }
            racts is transaction::action::type[] = mig_e2e_reject_actions sender_id env_sid code.
            if rekey_desync_code code
            {
                sc rekey_signal_actions sender_id env_sid -- ( -> a) { racts (_count racts|) -> a. }
                sc maybe_init_rekey sender_id env_sid -- ( -> a) { racts (_count racts|) -> a. }
                racts (_count racts|) -> _save_state NIL.
            }
            return transaction::success racts.
        }
        // Decrypted inner file body (mirrors send_file's finner _write shape).
        iv = key_storage::read_external ((r $plaintext)?).
        filename = (iv $filename) safe str.
        data = (iv $data) safe bin.
        mime is str = "".
        if (iv $mime) != NIL { mime -> (iv $mime) safe str. }
        wire_id is str = "".
        if (iv $wire_id) != NIL { wire_id -> (iv $wire_id) safe str. }
        reply_to is a2a_protocol::reply_ref_t+ = NIL.
        if (iv $reply_to) != NIL { reply_to -> (iv $reply_to) safe a2a_protocol::reply_ref_t. }

        // At-least-once redrive dedup for FILES (finding E) — mirrors the message
        // handler: a re-delivered wire_id RE-ACKS (the sender's buffer clears even
        // when the first receipt was lost) but never re-deposits the file. Includes
        // the same convergence as the message path (finding I): budget resets + the
        // session-replace redrive. Without this a file redrive deposited a duplicate.
        if wire_id != "" && (wire_seen sender_id wire_id)
        {
            fdacts is transaction::action::type[] = [].
            // Review #10: same implicit-confirm promotion as the message dup path.
            if do_ic { sc mig_e2e_promote_actions sender_id ((contact_migration sender_id)?) -- ( -> a) { fdacts (_count fdacts|) -> a. } }
            sc receipt_actions sender_id "delivered" [wire_id] -- ( -> a) { fdacts (_count fdacts|) -> a. }
            if (rekey_pending sender_id) != NIL { delete rekey_pending sender_id. }
            if (rekey_served sender_id) != NIL { delete rekey_served sender_id. }
            fdup_post_sid is bin+ = e2e::active_session_id sender_id.
            if pre_sid != NIL && fdup_post_sid != NIL && (pre_sid?) != (fdup_post_sid?)
            { sc redrive_unacked_actions sender_id -- ( -> a) { fdacts (_count fdacts|) -> a. } }
            fdacts (_count fdacts|) -> _notify_agent ($event -> $e2e_app_recv, $cid -> sender_id, $session_id -> env_sid, $ok -> TRUE, $wire_id -> wire_id, $duplicate -> TRUE, $file -> TRUE).
            fdacts (_count fdacts|) -> _save_state NIL.
            return transaction::success fdacts.
        }

        actions is transaction::action::type[] = [].
        if do_ic { sc mig_e2e_promote_actions sender_id ((contact_migration sender_id)?) -- ( -> a) { actions (_count actions|) -> a. } }

        sender = contacts sender_id.
        sender_name is str+ = NIL.
        if sender != NIL { sender_name -> sender? $name. }
        sc on_file_received (
            $sender_id   -> sender_id,
            $sender_name -> sender_name,
            $filename    -> filename,
            $mime        -> mime,
            $data        -> data,
            $date        -> file_date,
            $wire_id     -> wire_id,
            $reply_to    -> reply_to
        ) -- ( -> a) { actions (_count actions|) -> a. }
        sc monitor_copy_actions "in" sender_id file_date (file_monitor_summary filename mime data) -- ( -> a) { actions (_count actions|) -> a. }
        // core 0.11 self-heal: session replaced by the peer's fresh pre-key → redrive unacked.
        post_sid is bin+ = e2e::active_session_id sender_id.
        if pre_sid != NIL && post_sid != NIL && (pre_sid?) != (post_sid?)
        { sc redrive_unacked_actions sender_id -- ( -> a) { actions (_count actions|) -> a. } }
        sc mig_e2e_deliver_tail sender_id wire_id env_sid -- ( -> a) { actions (_count actions|) -> a. }
        // §5.4 trigger (the PRODUCTION-GAP fix, _file analogue of the message handler): an already-e2e
        // pair receiving a FILE over e2e must also auto-offer. Fires once; contact_migration!=NIL (+ epoch
        // pin) gate it; do_ic and the trigger stay mutually exclusive (see handle_receive_e2e_message).
        trig is transaction::action::type[] = mig_trigger_actions sender_id.
        if (_count trig|) > 0
        {
            sc trig -- ( -> a) { actions (_count actions|) -> a. }
            actions (_count actions|) -> _save_state NIL.
        }
        return transaction::success actions.
    }

    trn receive_e2e_file args: any
    {
        return handle_receive_e2e_file args.
    }

    // core 0.7.0: receipt ingest — a peer confirms delivery/read of messages I
    // sent. TOLERANT AND NEVER LOAD-BEARING: content problems are ignored
    // (success no-op) — an unknown $kind is a future receipt kind (forward
    // compat), an unparseable payload is dropped, unknown wire_ids are the
    // hook's business (messages GC). Only channel/origin violations abort.
    // NO receipt is ever emitted for a receipt (terminal surface, no recursion).
    fn handle_receive_receipt (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.

        // Unknown senders: silent success (best-effort surface, no probe oracle).
        if (contacts sender_id) == NIL { return transaction::success []. }
        // Registry classification (rcp, M1 abort-free): bad shape => ignore.
        if a2a_versions::rcp_shape_ok args != TRUE { return transaction::success []. }
        kind = (args $kind) safe str.
        if kind != "delivered" && kind != "read" { return transaction::success []. }

        // Tolerant per-element wire_id extraction (mistyped entries skipped).
        ids is str[] = [].
        sc (args $wire_ids) -- ( -> w)
        {
            if w != NIL && (_typeof w) == "STRING" { ids (_count ids|) -> (w safe str). }
        }
        if (_count ids|) == 0 { return transaction::success []. }

        rdate is time+ = NIL.
        if (args $date) != NIL && (_typeof (args $date)) == "TIME" { rdate -> (args $date) safe time. }

        pv_seen = a2a_versions::peer_pv args.
        if pv_seen != 0 { learn_contact_version sender_id pv_seen []. }

        actions is transaction::action::type[] = [].
        sc on_receipt_received (
            $sender_id -> sender_id,
            $kind      -> kind,
            $wire_ids  -> ids,
            $date      -> rdate
        ) -- ( -> a)
        {
            actions (_count actions|) -> a.
        }
        // core 0.11 self-heal: a delivered/read receipt retires the redrive retention for
        // these wire_ids. Persist the shrink — otherwise a restart resurrects acked entries
        // and a later redrive would duplicate them.
        if unacked_clear sender_id ids
        {
            actions (_count actions|) -> _save_state NIL.
        }
        return transaction::success actions.
    }

    trn receive_receipt args: any
    {
        return handle_receive_receipt args.
    }

    // ---- core 0.9.0 E2E-migration handlers (spec §5.4) -----------------------
    // STRICT GATE LADDER, error-as-data: narrow -> verify_identity_bundle (forgery
    // ABORTS by design) -> bundle-presence -> election-collapse/solicitation ->
    // nonce/epoch -> WRITES LAST. No abort is reachable from a well-formed-but-wrong
    // payload; only cryptographic/identity forgery aborts (verify_identity_bundle).
    // Both legs ride the legacy encrypted_channel (origin::external + check_encrypted).
    fn handle_e2e_migrate_offer (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        // GATE 1 — narrow (error-as-data).
        nr = a2a_versions::try_narrow_mgb args.
        if (nr $ok) != TRUE
        { return transaction::success [ _notify_agent ($event -> $protocol_error, $context -> $e2e_migrate_offer, $message -> (((nr $err)?) $message), $error -> (nr $err)?, $peer_cid -> sender_id) ]. }
        p = (nr $payload)?.
        // GATE 2 — verify identity bundle (cid-bind + PoP + optional chain). FORGERY
        // ABORTS here (by design); also refreshes peer_ads via process_address_document.
        vb = verify_identity_bundle (p as any) sender_id.
        // GATE 3 — bundle presence: the peer claims migration, so its verified AD MUST
        // carry an $e2e_bundle; otherwise a typed refusal (error-as-data, no state write).
        if (((vb $ad) as any) $identity $e2e_bundle) == NIL
        { return transaction::success [ _notify_agent ($event -> $migration_rejected, $cid -> sender_id, $reason -> $peer_offered_without_e2e_bundle) ]. }
        // This offer/ack exchange IS the missing caps/AD refresh — learn the piggyback AND install the
        // refreshed AD. Storing peer_ads here is REQUIRED for a pre-existing legacy contact whose stored
        // AD is still v1 (no $e2e_bundle): the epoch/decode below reads the peer bundle off peer_ads, so
        // without this refresh a legacy upgrade would fail the bundle cast. Idempotent for an already-v2 peer.
        pv_seen = a2a_versions::peer_pv args.
        learn_contact_version sender_id ((pv_seen != 0 ?? pv_seen ; 9)) (((p $caps) == NIL ?? [] ; (p $caps)?)).
        peer_ads sender_id -> (vb $ad).
        // GATE 4 — election collapse / solicitation. If the offer came from the HIGHER
        // cid (mig_initiator sender_id TRUE => I am the elected LOWER-cid initiator), it
        // is a SOLICITATION: keep the AD/caps refresh above, supersede any of my own
        // offered state, and (re)emit MY authoritative offer — do NOT ack.
        if (mig_initiator sender_id) == TRUE
        {
            // EXHAUSTIVE-PHASE NO-OP (MigrationReview): a stale/late higher-cid solicitation must NOT
            // restart a migration that already progressed past negotiation. At committed I hold the
            // agreed epoch; at active the epoch PIN is set. Re-emitting `offered` here would diverge
            // contact_migration from the pin. Mirror the ACK-path's committed/active early-return
            // (only a genuinely new nonce/epoch AFTER active drives §5.6 re-rotation, handled elsewhere).
            sol_prev = contact_migration sender_id.
            if sol_prev != NIL && (((sol_prev?) $phase) == "committed" || ((sol_prev?) $phase) == "active")
            { return transaction::success []. }
            solicit is transaction::action::type[] = mig_offer_actions sender_id.
            solicit (_count solicit|) -> _save_state NIL.
            return transaction::success solicit.
        }
        // Otherwise the offer came from the LOWER (elected) cid: proceed to ACK,
        // abandoning any competing proposal of mine (deterministic collapse).
        offer_nonce = (p $nonce) safe bin.
        // §5.4-5 IDEMPOTENCY / retransmit reproducibility: a REDELIVERED offer (SAME nonce —
        // broker dup or the initiator's sweep retransmit) must re-send the STORED ack
        // byte-identically from the snapshot — NEVER recompute a fresh nonce/epoch, which
        // would diverge from the epoch the initiator already holds from the first ack. First
        // verify my snapshot fp still matches my LIVE produce-path bundle; on mismatch (my
        // bundle rotated since acknowledging) supersede with a fresh nonce/epoch instead of
        // re-sending a stale ack under the same nonce.
        prev = contact_migration sender_id.
        // §5.6 / exhaustive phase handling: a redelivered offer AFTER the migration already
        // progressed to committed/active is an idempotent NO-OP — never restart the FSM. Only a
        // genuinely new agreement after `active` (a NEW nonce/epoch, epoch-pinned) triggers §5.6
        // re-rotation recovery (phase D/E); a stale same-nonce redeliver here is a late duplicate.
        if prev != NIL && (((prev?) $phase) == "committed" || ((prev?) $phase) == "active")
        { return transaction::success []. }
        if prev != NIL && ((prev?) $phase) == "acknowledged" && ((prev?) $peer_nonce) != NIL && ((prev?) $peer_nonce) == offer_nonce
        {
            live_fp = e2e_bundle_fp (address_document::produce_my_address_document()).
            if ((prev?) $local_fp) != NIL && ((prev?) $local_bundle) != NIL && live_fp == ((prev?) $local_fp)?
            {
                // Byte-identical re-send from the snapshot — NO state write, NO _save_state.
                rs = _read_or_abort (((prev?) $local_bundle)?).
                return transaction::success [
                    encrypted_channel::send_encrypted_tx sender_id (
                        $name -> e2e_migrate_ack_tx,
                        $targ -> ( $ad -> (rs $ad), $cert -> (rs $cert), $root_profile -> (rs $root_profile),
                                   $cp_binding -> (rs $cp_binding), $nonce -> ((prev?) $local_nonce), $peer_nonce -> offer_nonce,
                                   $pv -> a2a_versions::wire_version, $caps -> (a2a_capabilities::self_cap_ids NIL) ) ) ].
            }
            // else: my bundle rotated since acknowledging — fall through to supersede below.
        }
        // GATE 5 — nonce/epoch (first offer, a NEW nonce that supersedes, or supersession after
        // an fp mismatch). Snapshot my fresh bundle, compute the shared epoch.
        b  = my_identity_bundle_fields_fresh NIL.
        lb = _write ( $ad -> (b $ad), $cert -> (b $cert), $root_profile -> (b $root_profile), $cp_binding -> (b $cp_binding) ).
        my_fp   = e2e_bundle_fp (b $ad).
        peer_fp = e2e_bundle_fp (vb $ad).
        my_n = _hash_code_to_binary (_value_id (_new_id "ours e2e migration")).
        now  = (current_transaction_info::get_transaction_time())?.
        // cid-ordered: sender (elected initiator) is the LOWER cid; I am the HIGHER.
        epoch = mig_epoch sender_id (_get_container_id()) offer_nonce my_n peer_fp my_fp.
        // WRITES LAST — persist acknowledged WITH my snapshot, in the SAME tx as the ack send.
        contact_migration sender_id -> ( $phase -> "acknowledged", $initiator -> FALSE,
            $local_nonce -> my_n, $peer_nonce -> offer_nonce, $epoch -> epoch, $session_id -> NIL,
            $local_bundle -> lb, $local_fp -> my_fp, $attempts -> 1, $updated -> now ).
        s = _read_or_abort lb.
        return transaction::success [
            encrypted_channel::send_encrypted_tx sender_id (
                $name -> e2e_migrate_ack_tx,
                $targ -> ( $ad -> (s $ad), $cert -> (s $cert), $root_profile -> (s $root_profile),
                           $cp_binding -> (s $cp_binding), $nonce -> my_n, $peer_nonce -> offer_nonce,
                           $pv -> a2a_versions::wire_version, $caps -> (a2a_capabilities::self_cap_ids NIL) ) ),
            _notify_agent ($event -> $migration_started, $cid -> sender_id, $role -> $responder),
            _save_state NIL ].
    }
    trn e2e_migrate_offer args: any { return handle_e2e_migrate_offer args. }

    // core 0.10 (B1): RE-ADVERTISE handler. A contact that has upgraded to v2 pushes its fresh
    // AD (with $e2e_bundle + the caps piggyback) to me. This is a STATELESS refresh — unlike a
    // migration offer it creates NO FSM state, so a still-v1 peer that never sends one is never
    // left with a stalled `offered` entry that would permanently block a later genuine upgrade. I
    // verify + ingest the AD (refreshes peer_ads + learns caps/pv), then nudge the migration
    // trigger: if this is a still-legacy contact I now know is v2 (and it carries a bundle),
    // mig_trigger_actions elects the initiator and emits the authoritative offer, and the existing
    // offer/ack/commit/confirm FSM upgrades the pre-existing legacy session to the double ratchet.
    // A born-DR / epoch-pinned / in-flight contact is a no-op (mig_should_trigger returns FALSE).
    fn handle_readvertise_ad (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        // Only known contacts; an unknown sender is a silent no-op (no state, no leak).
        if (contacts sender_id) == NIL { return transaction::success []. }
        // Verify + ingest the refreshed AD (cid-bind + PoP; forgery aborts). Caller writes peer_ads.
        vb = verify_identity_bundle (args as any) sender_id.
        // F187 anti-downgrade (core 0.11): a KNOWN-e2e contact never legitimately refreshes
        // to a bundle-less (v1, down-levelled) AD — accepting one would overwrite the v2
        // peer_ads entry and brick the pair into downgrade_refused (state poisoning by an
        // authenticated-but-misbehaving peer). Validate BEFORE the write; ignore otherwise.
        ra_bundle = (((vb $ad) as any) $identity $e2e_bundle) safe address_document_types::t_e2e_bundle.
        if (e2e_pinned sender_id || (contact_e2e_epoch sender_id) != NIL) && ra_bundle == NIL
        { return transaction::success []. }
        peer_ads sender_id -> (vb $ad).
        // Learn the peer's version + caps piggyback so it becomes known-0.9 (the mig_should_trigger gate).
        pv_seen = a2a_versions::peer_pv args.
        caps_in is str[] = ((args $caps) == NIL ?? [] ; ((args $caps) safe (str[]))).
        learn_contact_version sender_id ((pv_seen != 0 ?? pv_seen ; 9)) caps_in.
        // Nudge the trigger only when the refreshed AD actually carries a v2 bundle (a real
        // upgrade). mig_trigger_actions internally gates on mig_should_trigger (skips born-DR /
        // epoch-pinned / in-flight / not-known-0.9), so this is a safe no-op otherwise.
        actions is transaction::action::type[] = [].
        if (peer_has_e2e_bundle sender_id)
        {
            trig is transaction::action::type[] = mig_trigger_actions sender_id.
            sc trig -- ( -> a) { actions (_count actions|) -> a. }
        }
        actions (_count actions|) -> _save_state NIL.
        return transaction::success actions.
    }
    trn readvertise_ad args: any { return handle_readvertise_ad args. }

    // core 0.11 (session self-heal): the peer's DECODE of my e2e traffic failed with a desync
    // code — it cannot read my current session (typically: it restarted and lost its sessions,
    // so my olm_type=1 traffic is undecryptable for it, and/or my stored copy of its AD
    // predates its re-minted account, so its fresh pre-keys fail MY authenticated decode).
    // The request carries the peer's FRESH identity bundle: verify (forgery aborts — same
    // verify_identity_bundle trust as readvertise, which already overwrites peer_ads),
    // refresh peer_ads, then REPLACE my dead outbound session with a fresh born-DR one via
    // the SOLE promotion APIs (stage_outbound_rotation + commit_rotation — never a raw write)
    // and redrive my retained unacked sends on it (re-encrypted; the dropped originals are
    // undecryptable forever, re-delivery is the only path to the peer's inbox). Answer with
    // MY fresh AD (readvertise back) so a MUTUALLY-stale pair (both restarted) converges in
    // one exchange: both peer_ads fresh → all surviving traffic is fresh pre-keys → the
    // 0.8.0 establish path accepts them. No epoch/pin state is touched (no downgrade
    // surface). Replay/spam is bounded RESPONDER-side (see the gating below): a rotation
    // is served only for MY CURRENT session id and at most once per cooldown window —
    // a replayed or repeated request degrades to the idempotent peer_ads refresh. The
    // requester side is additionally rate-limited per (cid, session_id). A migration
    // genuinely in flight owns its staged slot — never clobbered here; the sweep
    // supersedes it.
    fn handle_e2e_rekey_request (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        // Only known contacts; an unknown sender is a silent no-op (no state, no leak).
        if (contacts sender_id) == NIL { return transaction::success []. }
        // Verify the refreshed AD (cid-bind + PoP; forgery aborts) — but VALIDATE BEFORE
        // ANY WRITE (F187 anti-downgrade/poisoning): a known-e2e contact's refresh MUST
        // carry an e2e_bundle. A bundle-less (v1, down-levelled) AD from an authenticated
        // -but-misbehaving peer would otherwise overwrite the known-v2 peer_ads entry and
        // brick the pair into downgrade_refused until the next genuine readvertise.
        vb = verify_identity_bundle (args as any) sender_id.
        vb_bundle = (((vb $ad) as any) $identity $e2e_bundle) safe address_document_types::t_e2e_bundle.
        if (e2e_pinned sender_id || (contact_e2e_epoch sender_id) != NIL) && vb_bundle == NIL
        { return transaction::success [ _notify_agent ($event -> $e2e_rekey, $cid -> sender_id, $role -> $responder, $rejected -> $bundle_less) ]. }
        peer_ads sender_id -> (vb $ad).
        pv_seen = a2a_versions::peer_pv args.
        caps_in is str[] = ((args $caps) == NIL ?? [] ; ((args $caps) safe (str[]))).
        learn_contact_version sender_id ((pv_seen != 0 ?? pv_seen ; 9)) caps_in.
        actions is transaction::action::type[] = [].
        fsid is bin+ = (args $failed_session_id) safe bin.
        now = (current_transaction_info::get_transaction_time())?.
        // CONVERGENCE LEG (Dev-1 residual LOW): readvertise my fresh AD BACK — this is how the
        // requester refreshes ITS stored copy of MY bundle when I (not it) re-minted my account.
        // It must NOT hide behind the rotation gate (a throttled/non-initiator request would then
        // starve the one-side-restarted case).
        // Review #9: the cooldown now has its OWN ledger (ad_response_last) — the old check read
        // rekey_served, which only maybe_init_rekey writes, so a NON-initiator responder had NO
        // cooldown at all: every authenticated request minted a fresh signed AD + save.
        prev_resp = ad_response_last sender_id.
        cool_ok is bool = prev_resp == NIL || (_substract_seconds now (prev_resp?)) >= rekey_min_interval_seconds.
        if cool_ok
        {
            ad_response_last sender_id -> now.
            b = my_identity_bundle_fields_fresh NIL.
            actions (_count actions|) -> encrypted_channel::send_encrypted_tx sender_id (
                $name -> readvertise_ad_tx,
                $targ -> ( $ad -> (b $ad), $cert -> (b $cert), $root_profile -> (b $root_profile),
                           $cp_binding -> (b $cp_binding),
                           $pv -> a2a_versions::wire_version,
                           $caps -> (a2a_capabilities::self_cap_ids NIL) ) ).
        }
        // SINGLE-INITIATOR re-establishment: mint the fresh session ONLY if I am the elected
        // initiator (maybe_init_rekey enforces role + cid-keyed budget + advisory-sid + no
        // in-flight migration). As the NON-initiator I only refreshed peer_ads + readvertised
        // back; the initiator (the requester, here) mints on ITS side and its pre-key
        // establishes the shared session on mine. Exactly one minter ⇒ no glare.
        sc maybe_init_rekey sender_id fsid -- ( -> a) { actions (_count actions|) -> a. }
        // TRUE-loss liveness, higher-cid side (review #6 — NO MINT, no glare). When the
        // REQUESTER is the elected initiator (I am NOT), it lost its state: it has
        // nothing to redrive and nothing re-triggers its own mint — my readvertise
        // above only refreshes its copy of my bundle, and my own sweep waits up to a
        // GC period. fsid == my ACTIVE session id proves the request is about my
        // CURRENT session (not stale/replayed). Re-drive my buffer (or send a
        // cap-gated ping) on the EXISTING session NOW: the requester cannot decode
        // those (it lost the session), each failed decode fires its reject path —
        // rekey_signal + maybe_init_rekey — and by then it holds my fresh AD from the
        // readvertise above, so THE INITIATOR mints, exactly one minter, no glare.
        // Bounded by the same ad_response cooldown as the readvertise (cool_ok).
        if cool_ok && (mig_initiator sender_id) != TRUE && (contact_migration sender_id) == NIL
        {
            g_active is bin+ = e2e::active_session_id sender_id.
            if fsid != NIL && g_active != NIL && (g_active?) == (fsid?)
            {
                pre_cnt is int = (_count actions|).
                sc redrive_unacked_actions sender_id -- ( -> a) { actions (_count actions|) -> a. }
                if (_count actions|) == pre_cnt
                { sc rekey_ping_actions sender_id -- ( -> a) { actions (_count actions|) -> a. } }
                if (_count actions|) > pre_cnt
                { actions (_count actions|) -> _notify_agent ($event -> $e2e_rekey, $cid -> sender_id, $role -> $responder_retrigger, $session_id -> fsid). }
            }
        }
        actions (_count actions|) -> _save_state NIL.
        return transaction::success actions.
    }
    trn e2e_rekey_request args: any { return handle_e2e_rekey_request args. }

    // ACK handler (initiator). Gates: narrow -> FSM phase==offered ∧ ack echoes my nonce
    // -> verify bundle (forgery aborts) -> bundle-presence -> compute the SAME epoch ->
    // WRITES LAST. NOTE: the §5.5 COMMIT continuation (stage_outbound_rotation + send
    // commit, same tx) is the NEXT increment; this cut reaches `acknowledged` with a
    // converged epoch on both sides.
    fn handle_e2e_migrate_ack (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        // GATE 1 — narrow.
        nr = a2a_versions::try_narrow_mgb args.
        if (nr $ok) != TRUE
        { return transaction::success [ _notify_agent ($event -> $protocol_error, $context -> $e2e_migrate_ack, $message -> (((nr $err)?) $message), $error -> (nr $err)?, $peer_cid -> sender_id) ]. }
        p = (nr $payload)?.
        // GATE 2 — FSM phase==offered ∧ the ack echoes MY offer nonce (else stale/foreign, drop as data).
        st = contact_migration sender_id.
        if st == NIL || ((st?) $phase) != "offered" { return transaction::success []. }
        my_local_nonce = (st?) $local_nonce.
        ack_peer_nonce = (p $peer_nonce).
        if ack_peer_nonce == NIL || ack_peer_nonce != my_local_nonce { return transaction::success []. }
        // GATE 3 — verify bundle (forgery aborts; peer_ads refresh) + bundle presence.
        vb = verify_identity_bundle (p as any) sender_id.
        if (((vb $ad) as any) $identity $e2e_bundle) == NIL
        { return transaction::success [ _notify_agent ($event -> $migration_rejected, $cid -> sender_id, $reason -> $peer_acked_without_e2e_bundle) ]. }
        pv_seen = a2a_versions::peer_pv args.
        learn_contact_version sender_id ((pv_seen != 0 ?? pv_seen ; 9)) (((p $caps) == NIL ?? [] ; (p $caps)?)).
        // Install the ack's refreshed AD (REQUIRED for a legacy contact whose stored AD is still v1):
        // GATE 4 below reads the peer $e2e_bundle off peer_ads, which must now be the v2 AD.
        peer_ads sender_id -> (vb $ad).
        // GATE 4 — compute the SAME epoch (I am the elected initiator = LOWER cid).
        ack_nonce = (p $nonce) safe bin.
        my_fp   = ((st?) $local_fp)?.       // my offer snapshot fp (same bundle -> same fp)
        peer_fp = e2e_bundle_fp (vb $ad).
        now = (current_transaction_info::get_transaction_time())?.
        epoch = mig_epoch (_get_container_id()) sender_id my_local_nonce ack_nonce my_fp peer_fp.
        // §5.5 COMMIT (same tx, atomic — cross-lib rollback proven, plan B gate 5): stage a
        // FRESH outbound session to the peer's ACKED bundle, encrypt the commit body on it
        // (PRE_KEY), persist committed, send. The commit is END-TO-END bound — epoch +
        // session_id ride INSIDE the fresh session's ciphertext (a relay cannot re-target,
        // replay across pairs, or splice epochs; the outer $emsignature binds $from/$to).
        pb = (((vb $ad) as any) $identity $e2e_bundle) safe address_document_types::t_e2e_bundle.
        sid = e2e::stage_outbound_rotation sender_id pb.
        commit_body = _write ( $name -> e2e_migrate_commit_tx,
                               $targ -> ( $epoch -> epoch, $session_id -> sid, $pv -> a2a_versions::wire_version ) ).
        env = e2e::encrypt_staged sender_id commit_body.
        // WRITES LAST — persist committed(session_id) atomically with the commit send.
        contact_migration sender_id -> ( $phase -> "committed", $initiator -> TRUE,
            $local_nonce -> my_local_nonce, $peer_nonce -> ack_nonce, $epoch -> epoch, $session_id -> sid,
            $local_bundle -> ((st?) $local_bundle), $local_fp -> my_fp, $attempts -> ((st?) $attempts), $updated -> now ).
        // BOXED transport (B): the SDK wire schema has no e2e_signed_message transaction variant
        // yet (a coordinated plan-F SDK-bundle regen), so the staged-session Olm ciphertext rides
        // as $targ INSIDE the legacy encrypted_channel box; the responder handler drives the e2e
        // decode. The box is PURE TRANSPORT — epoch + session_id stay INSIDE the Olm ciphertext,
        // the $emsignature still binds $from/$to/$envelope (verified handler-side, decode_migration_envelope).
        return transaction::success [
            encrypted_channel::send_encrypted_tx sender_id (
                $name -> e2e_migrate_commit_tx,
                $targ -> ( $e2e_envelope -> (env $e2e_envelope), $emsignature -> (env $emsignature) ) ),
            _notify_agent ($event -> $migration_started, $cid -> sender_id, $role -> $initiator),
            _save_state NIL ].
    }
    trn e2e_migrate_ack args: any { return handle_e2e_migrate_ack args. }

    // A redelivered migration COMMIT after we already promoted to active (§5.5 lost-confirm: the
    // initiator's sweep re-sends its commit because our confirm was lost). Evidence rule: re-send
    // the confirm ONLY when we are genuinely active for this cid on the PINNED session (the epoch
    // pin's $session_id == the live active session) — proof we already completed THIS rotation.
    // NO decode (never risk self-healing the live session at active), NO inner re-dispatch, NO
    // state change; a stale/foreign replay drops silently.
    fn mig_handle_replayed_commit (sender_id: global_id) -> transaction::results::type
    {
        st = contact_migration sender_id.
        if st == NIL || ((st?) $phase) != "active" { return transaction::success []. }
        pin = contact_e2e_epoch sender_id.
        active_sid = e2e::active_session_id sender_id.
        if pin == NIL || active_sid == NIL || ((pin?) $session_id) != active_sid { return transaction::success []. }
        confirm_body = _write ( $name -> e2e_migrate_confirm_tx, $targ -> ( $epoch -> ((pin?) $epoch), $pv -> a2a_versions::wire_version ) ).
        cpb = ((((peer_ads sender_id)?) as any) $identity $e2e_bundle) safe address_document_types::t_e2e_bundle.
        cenv = e2e::encrypt_to sender_id confirm_body cpb.
        return transaction::success [
            encrypted_channel::send_encrypted_tx sender_id (
                $name -> e2e_migrate_confirm_tx,
                $targ -> ( $e2e_envelope -> (cenv $e2e_envelope), $emsignature -> (cenv $emsignature) ) ) ].
    }

    // COMMIT handler (responder). Under B the commit rides a NAMED box carrying the staged-session
    // Olm ciphertext as $targ = {$e2e_envelope, $emsignature}; the __t_wrapper decode-seam is NOT
    // invoked, so THIS handler drives the e2e decode (via the shared, audited e2e::decode_migration_
    // envelope — S1/S2 verify bound to the box sender + me, then decrypt+STAGE on the fresh session).
    // Gate ALL before any write: phase==acknowledged; carrier shape; S1/S2 + decrypt; narrow(mgc) of
    // the DECRYPTED inner body; inner $epoch==stored epoch; inner $session_id==the CARRIER session
    // (staged if staged, else the just-installed active). ANY mismatch: discard the staged rotation,
    // typed reject, REMAIN acknowledged (sweep re-drives). A dup at active -> idempotent re-confirm.
    // Success: promote atomically in ONE tx — commit_rotation + BOTH pins + active + send confirm.
    fn handle_e2e_migrate_commit (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        st = contact_migration sender_id.
        if st == NIL { return transaction::success []. }
        ph = ((st?) $phase).
        // A commit arriving after we went active (peer lost our confirm): idempotent re-confirm on
        // the pinned active session — NO decode. Any other non-acknowledged phase drops as data.
        if ph == "active" { return mig_handle_replayed_commit sender_id. }
        if ph != "acknowledged" { return transaction::success []. }
        // GATE 0 — carrier shape (no-downgrade: a missing/garbage e2e envelope FAILS closed; the
        // box is never treated as a legacy/plaintext commit).
        env is e2e::t_e2e_envelope+ = (args $e2e_envelope) safe e2e::t_e2e_envelope.
        emsig is crypto_signature+ = (args $emsignature) safe crypto_signature.
        if env == NIL || emsig == NIL
        { return transaction::success [ _notify_agent ($event -> $migration_rejected, $cid -> sender_id, $reason -> $commit_malformed_envelope) ]. }
        // GATE 1 — need the box sender's VERIFIED AD (refreshed at offer/ack) to authenticate the
        // envelope: sign key + e2e identity key are read from THIS cid's AD (tight $from binding).
        pad = peer_ads sender_id.
        if pad == NIL
        { return transaction::success [ _notify_agent ($event -> $migration_rejected, $cid -> sender_id, $reason -> $commit_no_peer_ad) ]. }
        // GATE 2 — handler-driven e2e decode (ALL crypto in e2e.mm). At acknowledged mig_pending is
        // TRUE, so the decode-seam STAGES onto a fresh session (the live session is untouched).
        r = e2e::decode_migration_envelope sender_id (_get_container_id()) (pad?) (env?) (emsig?).
        if (r $ok) != TRUE
        {   // OLM-LEVEL failure only — tampered ciphertext / session_mismatch / no_session /
            // replay-at-acknowledged → !ok reject-as-data. (emsig/wire FORGERY already ABORTED
            // inside decode_migration_envelope, §1.1 — it never reaches here.) Drop the staged
            // rotation, REMAIN acknowledged (never fall back to legacy). The sweep re-drives.
            e2e::discard_rotation sender_id.
            return transaction::success [ _notify_agent ($event -> $migration_rejected, $cid -> sender_id, $reason -> $commit_decrypt_failed), _save_state NIL ].
        }
        // GATE 3 — narrow the DECRYPTED inner commit body (used ONLY for gating, never emitted).
        inner = (key_storage::read_external ((r $plaintext)?)) safe transaction::unsigned_message.
        if inner == NIL
        { e2e::discard_rotation sender_id.
          return transaction::success [ _notify_agent ($event -> $migration_rejected, $cid -> sender_id, $reason -> $commit_inner_malformed), _save_state NIL ]. }
        nr = a2a_versions::try_narrow_mgc ((inner?) $targ).
        if (nr $ok) != TRUE
        { e2e::discard_rotation sender_id.
          return transaction::success [ _notify_agent ($event -> $migration_rejected, $cid -> sender_id, $reason -> $commit_inner_malformed), _save_state NIL ]. }
        p = (nr $payload)?.
        stored_epoch = ((st?) $epoch)?.
        staged_sid = e2e::staged_session_id sender_id.
        active_sid = e2e::active_session_id sender_id.
        carrier_sid = (staged_sid != NIL ?? staged_sid ; active_sid).   // where the commit landed
        inner_sid = (p $session_id).
        if (p $epoch) != stored_epoch || inner_sid == NIL || carrier_sid == NIL || inner_sid != carrier_sid
        {
            e2e::discard_rotation sender_id.
            return transaction::success [ _notify_agent ($event -> $migration_rejected, $cid -> sender_id, $reason -> $commit_epoch_or_session_mismatch), _save_state NIL ].
        }
        // SUCCESS — one atomic tx. commit_rotation is the SOLE promotion point (promotes a
        // staged rotation; a no-op when the fresh session was already installed directly).
        e2e::commit_rotation sender_id.
        final_sid = e2e::active_session_id sender_id.   // the now-active fresh session (== carrier)
        contact_e2e_epoch sender_id -> ( $epoch -> stored_epoch, $session_id -> (final_sid?) ).
        contact_e2e_seen sender_id -> TRUE.
        now = (current_transaction_info::get_transaction_time())?.
        contact_migration sender_id -> ( $phase -> "active", $initiator -> FALSE,
            $local_nonce -> ((st?) $local_nonce), $peer_nonce -> ((st?) $peer_nonce), $epoch -> stored_epoch, $session_id -> (final_sid?),
            $local_bundle -> ((st?) $local_bundle), $local_fp -> ((st?) $local_fp), $attempts -> ((st?) $attempts), $updated -> now ).
        // Confirm rides the NEW (now-active) session — encrypt_to targets m_sessions[sender] —
        // BOXED (same wire-schema constraint). The initiator decodes it on its staged slot.
        confirm_body = _write ( $name -> e2e_migrate_confirm_tx, $targ -> ( $epoch -> stored_epoch, $pv -> a2a_versions::wire_version ) ).
        cpb = ((((peer_ads sender_id)?) as any) $identity $e2e_bundle) safe address_document_types::t_e2e_bundle.
        cenv = e2e::encrypt_to sender_id confirm_body cpb.
        return transaction::success [
            encrypted_channel::send_encrypted_tx sender_id (
                $name -> e2e_migrate_confirm_tx,
                $targ -> ( $e2e_envelope -> (cenv $e2e_envelope), $emsignature -> (cenv $emsignature) ) ),
            _notify_agent ($event -> $migration_active, $cid -> sender_id, $role -> $responder, $epoch -> stored_epoch, $session_id -> (final_sid?)),
            _save_state NIL ].
    }
    trn e2e_migrate_commit args: any { return handle_e2e_migrate_commit args. }

    // CONFIRM handler (initiator). Under B the confirm rides a NAMED box carrying the responder's
    // olm_type=1 ciphertext (encrypted on its now-active session) as $targ; THIS handler drives the
    // decode via e2e::decode_migration_envelope, which decrypts on the initiator's STAGED slot (not
    // yet promoted). Gate: phase==committed; carrier shape; S1/S2 + decrypt; narrow(mgc); inner
    // $epoch matches. Success: promote atomically — commit_rotation + BOTH pins + active
    // (+ flush mig_deferred over the new e2e path — that flush is wired in phase D).
    fn handle_e2e_migrate_confirm (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        st = contact_migration sender_id.
        if st == NIL { return transaction::success []. }
        ph = ((st?) $phase).
        if ph == "active" { return transaction::success []. }   // dup confirm after promotion: no-op
        if ph != "committed" { return transaction::success []. }
        // GATE 0 — carrier shape (no-downgrade).
        env is e2e::t_e2e_envelope+ = (args $e2e_envelope) safe e2e::t_e2e_envelope.
        emsig is crypto_signature+ = (args $emsignature) safe crypto_signature.
        if env == NIL || emsig == NIL
        { return transaction::success [ _notify_agent ($event -> $migration_rejected, $cid -> sender_id, $reason -> $confirm_malformed_envelope) ]. }
        pad = peer_ads sender_id.
        if pad == NIL
        { return transaction::success [ _notify_agent ($event -> $migration_rejected, $cid -> sender_id, $reason -> $confirm_no_peer_ad) ]. }
        // GATE 1 — handler-driven decode: olm_type=1 on the STAGED slot (initiator reads confirm
        // pre-promotion). A tampered/foreign confirm fails closed; the staged slot is untouched.
        r = e2e::decode_migration_envelope sender_id (_get_container_id()) (pad?) (env?) (emsig?).
        if (r $ok) != TRUE
        { return transaction::success [ _notify_agent ($event -> $migration_rejected, $cid -> sender_id, $reason -> $confirm_decrypt_failed) ]. }
        // GATE 2 — narrow the DECRYPTED inner confirm body + epoch match (used ONLY for gating).
        inner = (key_storage::read_external ((r $plaintext)?)) safe transaction::unsigned_message.
        if inner == NIL
        { return transaction::success [ _notify_agent ($event -> $migration_rejected, $cid -> sender_id, $reason -> $confirm_inner_malformed) ]. }
        nr = a2a_versions::try_narrow_mgc ((inner?) $targ).
        if (nr $ok) != TRUE
        { return transaction::success [ _notify_agent ($event -> $migration_rejected, $cid -> sender_id, $reason -> $confirm_inner_malformed) ]. }
        p = (nr $payload)?.
        stored_epoch = ((st?) $epoch)?.
        if (p $epoch) != stored_epoch { return transaction::success []. }   // stale/foreign confirm, drop
        // SUCCESS — promote atomically. commit_rotation promotes the initiator's staged session.
        e2e::commit_rotation sender_id.
        final_sid = e2e::active_session_id sender_id.
        contact_e2e_epoch sender_id -> ( $epoch -> stored_epoch, $session_id -> (final_sid?) ).
        contact_e2e_seen sender_id -> TRUE.
        now = (current_transaction_info::get_transaction_time())?.
        contact_migration sender_id -> ( $phase -> "active", $initiator -> TRUE,
            $local_nonce -> ((st?) $local_nonce), $peer_nonce -> ((st?) $peer_nonce), $epoch -> stored_epoch, $session_id -> (final_sid?),
            $local_bundle -> ((st?) $local_bundle), $local_fp -> ((st?) $local_fp), $attempts -> ((st?) $attempts), $updated -> now ).
        // §5.6 FLUSH-ON-ACTIVE — PINS-BEFORE-FLUSH: the epoch pin above is now set, so a re-injected
        // app send routes "e2e" (not "migrating") and won't re-queue. Drain mig_deferred[cid] FIFO
        // over e2e (the daemon delivers on the migrated session) — preserves per-contact order.
        acts is transaction::action::type[] = [ _notify_agent ($event -> $migration_active, $cid -> sender_id, $role -> $initiator, $epoch -> stored_epoch, $session_id -> (final_sid?)) ].
        sc flush_mig_deferred_actions sender_id -- ( -> a) { acts (_count acts|) -> a. }
        acts (_count acts|) -> _save_state NIL.
        return transaction::success acts.
    }
    trn e2e_migrate_confirm args: any { return handle_e2e_migrate_confirm args. }

    // Host-fired flush (boot/GC cadence + on the $migration_active notify): drain a contact's
    // mig_deferred over e2e. Idempotent; a contact NOT yet epoch-pinned (still migrating) is a
    // no-op ($not_active) — never flush before the pin (would re-queue).
    trn flush_mig_deferred _:($contact -> contact_ref: str)
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        target_id = resolve_contact contact_ref.
        q = mig_deferred target_id.
        if q == NIL || (_count q?|) == 0 { return transaction::success [ _return_data ($flushed -> 0) ]. }
        if (contact_e2e_epoch target_id) == NIL { return transaction::success [ _return_data ($flushed -> 0, $not_active -> TRUE) ]. }
        n = _count q?|.
        acts is transaction::action::type[] = flush_mig_deferred_actions target_id.
        acts (_count acts|) -> _return_data ($flushed -> n, $route -> $e2e).
        acts (_count acts|) -> _save_state NIL.
        return transaction::success acts.
    }

    // Enable the migration capability at RUNTIME (mid-session), no restart. Appends cap_e2e_migrate to
    // self_caps; the next outbound message's self_cap_ids piggyback carries it, the peer re-learns, and
    // its mig_should_trigger fires — so an ALREADY-established e2e session is preserved and the migration
    // ROTATES that live session (a restart would re-key the Olm ratchet and lose the pre-migration
    // session — see the OWNER-TEST-GUIDE staged flow). A genuine production capability (turn on migration
    // without a restart), not only a test hook. cap_e2e_migrate is $advertise-class (no control-verb
    // handler), so add_self_cap is safe here (init's declared-implies-implemented guard is for $supported).
    trn advertise_migrate _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        was is bool = a2a_capabilities::self_advertises a2a_capabilities::cap_e2e_migrate.
        a2a_capabilities::add_self_cap a2a_capabilities::cap_e2e_migrate.
        // Now that the cap is LIVE, proactively offer to every already-known eligible e2e contact — a
        // runtime cap-enable must start the SAME migrations a default-cap boot would, else an already-e2e
        // pair with no inbound traffic would never migrate (mig_should_trigger keeps it fail-closed +
        // idempotent). This is what turns the OWNER-TEST-GUIDE staged-advertise flow into a real trigger.
        elig is transaction::action::type[] = mig_offer_eligible_actions NIL.
        acts is transaction::action::type[] = [ _return_data (
            $was_advertising  -> was,
            $advertising      -> (a2a_capabilities::self_advertises a2a_capabilities::cap_e2e_migrate),
            $offers_initiated -> (_count elig|) ) ].
        sc elig -- ( -> a) { acts (_count acts|) -> a. }
        acts (_count acts|) -> _save_state NIL.
        return transaction::success acts.
    }

    // ---- §5.6 recovery sweep (host boot/GC cadence, mirrors restore_degraded_contacts) --------
    // Re-drive a stalled migration by RETRANSMITTING the persisted phase's leg. offer/ack rebuild
    // BYTE-IDENTICALLY from the $local_bundle snapshot (§5.4-5 — same nonce, so the peer's already-
    // computed epoch stays valid); commit re-encrypts on the SURVIVING staged session. Pure builders
    // (no state write) — the sweep trn bumps $attempts + persists.
    fn mig_resend_offer_actions (cid: global_id, st: mig_state_t) -> transaction::action::type[]
    {
        if (st $local_bundle) == NIL { return []. }
        s = _read_or_abort ((st $local_bundle)?).
        return [ encrypted_channel::send_encrypted_tx cid (
            $name -> e2e_migrate_offer_tx,
            $targ -> ( $ad -> (s $ad), $cert -> (s $cert), $root_profile -> (s $root_profile),
                       $cp_binding -> (s $cp_binding), $nonce -> (st $local_nonce), $peer_nonce -> NIL,
                       $pv -> a2a_versions::wire_version, $caps -> (a2a_capabilities::self_cap_ids NIL) ) ) ].
    }
    fn mig_resend_ack_actions (cid: global_id, st: mig_state_t) -> transaction::action::type[]
    {
        if (st $local_bundle) == NIL || (st $peer_nonce) == NIL { return []. }
        s = _read_or_abort ((st $local_bundle)?).
        return [ encrypted_channel::send_encrypted_tx cid (
            $name -> e2e_migrate_ack_tx,
            $targ -> ( $ad -> (s $ad), $cert -> (s $cert), $root_profile -> (s $root_profile),
                       $cp_binding -> (s $cp_binding), $nonce -> (st $local_nonce), $peer_nonce -> ((st $peer_nonce)?),
                       $pv -> a2a_versions::wire_version, $caps -> (a2a_capabilities::self_cap_ids NIL) ) ) ].
    }
    // Commit re-drive: re-encrypt on the SURVIVING staged session (still PRE_KEY; the responder's
    // session_matches collapses the duplicate). NIL when the staged session is GONE (crash / m_staged
    // lost, e.g. post-import) → UNRESUMABLE; the caller abandons + supersedes (fresh offer/epoch).
    fn mig_resend_commit_actions (cid: global_id, st: mig_state_t) -> transaction::action::type[]+
    {
        sid = e2e::staged_session_id cid.
        if sid == NIL { return NIL. }
        commit_body = _write ( $name -> e2e_migrate_commit_tx,
                               $targ -> ( $epoch -> ((st $epoch)?), $session_id -> sid, $pv -> a2a_versions::wire_version ) ).
        env = e2e::encrypt_staged cid commit_body.
        return [ encrypted_channel::send_encrypted_tx cid (
            $name -> e2e_migrate_commit_tx,
            $targ -> ( $e2e_envelope -> (env $e2e_envelope), $emsignature -> (env $emsignature) ) ) ].
    }

    // Host-fired sweep (boot + GC cadence): re-drive every non-terminal migration. $attempts capped
    // at mig_max_attempts → $migration_stalled notify (state KEPT — legacy still flows offered/ack,
    // committed keeps queueing; NOTHING silently downgrades). A committed entry whose staged session
    // was lost is abandoned + superseded (fresh offer). Idempotent; re-fires on the host cadence.
    // core 0.10 (B1): boot/upgrade RE-ADVERTISE. The daemon calls this at startup (see the DAEMON
    // CONTRACT). It pushes my fresh v2 AD (+ caps piggyback) to every PRE-EXISTING LEGACY contact —
    // one that is NOT epoch-pinned, NOT born-DR, and has NO migration in flight — over the legacy
    // encrypted_channel. A v2 peer ingests it (handle_readvertise_ad) and offers back; a still-v1
    // peer does not understand the tx and ignores it, leaving NO state that could block a future
    // upgrade. STATELESS (no _save_state): it only sends, changing no local state, so it is idempotent
    // and safe to call on every boot. A still-legacy contact becomes migration-eligible only after
    // this re-advertise round-trips, so no separate production boot sweep is needed.
    trn readvertise_on_upgrade _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        b  = my_identity_bundle_fields_fresh NIL.
        actions is transaction::action::type[] = [].
        n is int = 0.
        sc contacts -- (cid -> ) ?? ((contact_e2e_epoch cid) == NIL && (contact_born_dr cid) != TRUE && (contact_migration cid) == NIL)
        {
            actions (_count actions|) -> encrypted_channel::send_encrypted_tx cid (
                $name -> readvertise_ad_tx,
                $targ -> ( $ad -> (b $ad), $cert -> (b $cert), $root_profile -> (b $root_profile),
                           $cp_binding -> (b $cp_binding),
                           $pv -> a2a_versions::wire_version,
                           $caps -> (a2a_capabilities::self_cap_ids NIL) ) ).
            n -> n + 1.
        }
        actions (_count actions|) -> _return_data ($readvertised -> n).
        return transaction::success actions.
    }

    // Coherence probe (finding #3 evidence): the ik_curve of MY CURRENT account's
    // public bundle. Host compares it against the transport IPD's advertised bundle
    // post-restore. Readonly; account() only mutates when NO account exists — never
    // the case on this call path (ctor mints one before any host-driven restore).
    trn readonly e2e_self_fp _
    {
        return ( $ik -> ((e2e::my_public_bundle NIL) $ik_curve) ).
    }

    // Finding C redo — the VALIDATION transaction. Runs alone (host-driven, boot,
    // pre-exposure): validates + assigns the staged $e2e_sessions blob. A corrupt
    // pickle raises the engine's HARD BAD_PICKLE inside e2e::import_sessions, which
    // fails THIS txn atomically — nothing assigned, staging untouched — and the host
    // observes the failure (unambiguous: nothing but validation runs here) and calls
    // reject_e2e_restore. Success persists the restored sessions with the txn.
    trn commit_e2e_restore _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        if e2e_restore_staged == NIL
        { return transaction::success [ _return_data ($status -> $none) ]. }
        n = e2e::import_sessions (e2e_restore_staged?).
        e2e_restore_staged -> NIL.
        return transaction::success [ _return_data ($status -> $ok, $sessions -> n), _save_state NIL ].
    }

    // Finding C redo — the REJECT leg: discard the corrupt staged blob (the live e2e
    // state is untouched — the ctor-minted fresh account stays, the self-heal fallback
    // re-establishes) and surface the rejection. Host calls this after observing a
    // commit_e2e_restore failure; the _save_state persists the now-clean export so the
    // corrupt pickles never come back on the next boot.
    trn reject_e2e_restore _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        e2e_restore_staged -> NIL.
        return transaction::success [
            _notify_agent ($event -> $e2e_restore_rejected),
            _return_data ($status -> $rejected),
            _save_state NIL ].
    }

    // core 0.11 (session self-heal, boot leg): push my FRESH AD to every E2E-CAPABLE contact —
    // the complement of readvertise_on_upgrade's legacy-only set. Since persist-primary a
    // clean restart RESUMES the account+sessions and this push is a cheap refresh; it is
    // LOAD-BEARING on the fallback path (persisted state lost/rejected → the account was
    // re-minted, so the e2e_bundle every peer holds for me is stale; until a peer refreshes
    // it, my fresh pre-keys fail its authenticated decode (session_mismatch) while its
    // olm_type=1 traffic to me is undecryptable (no_session) — the two-sided black hole).
    // This stateless push re-arms the 0.8.0 pre-key-replace self-heal. A pre-0.10 peer
    // ignores the tx (readvertise precedent). The daemon calls this on EVERY boot, alongside
    // readvertise_on_upgrade and sweep_e2e_migrations (DAEMON CONTRACT).
    trn readvertise_e2e_recovery _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        b  = my_identity_bundle_fields_fresh NIL.
        actions is transaction::action::type[] = [].
        n is int = 0.
        sc contacts -- (cid -> ) ?? ((contact_e2e_epoch cid) != NIL || (contact_born_dr cid) == TRUE || (e2e_pinned cid) || (contact_migration cid) != NIL)
        {
            actions (_count actions|) -> encrypted_channel::send_encrypted_tx cid (
                $name -> readvertise_ad_tx,
                $targ -> ( $ad -> (b $ad), $cert -> (b $cert), $root_profile -> (b $root_profile),
                           $cp_binding -> (b $cp_binding),
                           $pv -> a2a_versions::wire_version,
                           $caps -> (a2a_capabilities::self_cap_ids NIL) ) ).
            n -> n + 1.
        }
        actions (_count actions|) -> _return_data ($readvertised -> n).
        return transaction::success actions.
    }

    // core 0.12 (2b): comma-joined fingerprint of my advertised cap-id set. self_cap_ids is
    // captured at init in a stable order (supported ∪ advertise, then any runtime
    // add_self_cap APPENDS), so this string changes iff my advertised caps change — the cheap
    // change-detector reconcile_advertise gates the legacy upgrade push on.
    fn caps_fingerprint (_) -> str
    {
        s is str = "".
        sc (a2a_capabilities::self_cap_ids NIL) -- ( -> c) { s -> (s + c) + ",". }
        return s.
    }

    fn fingerprint_caps (caps: str[]) -> str
    {
        s is str = "".
        sc caps -- ( -> c) { s -> (s + c) + ",". }
        return s.
    }

    // Generic capability snapshot receiver. Exact replacement is intentional:
    // removals must propagate. The E2E pin remains monotonic, so an advertised
    // removal cannot reopen plaintext routing. Duplicate snapshots still ACK,
    // which repairs a lost ACK without duplicating delta-side effects.
    fn handle_capability_advertise (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        if (contacts sender_id) == NIL { return transaction::success []. }
        caps is str[] = ((args $caps) safe (str[])).
        fp = (args $fingerprint) safe str.
        abort "Capability advertisement fingerprint mismatch." when fp != fingerprint_caps caps.
        pv = (args $pv) safe int.
        prev = contact_caps sender_id.
        prev_fp is str = "".
        if prev != NIL { prev_fp -> fingerprint_caps prev?. }
        contact_caps sender_id -> caps.
        contact_pv sender_id -> pv.
        note_e2e_seen sender_id caps.
        actions is transaction::action::type[] = [
            encrypted_channel::send_encrypted_tx sender_id (
                $name -> capability_advertise_ack_tx,
                $targ -> ($fingerprint -> fp)
            )
        ].
        if prev_fp != fp
        {
            actions (_count actions|) -> _notify_agent (
                $event -> $peer_capabilities_changed, $cid -> sender_id,
                $previous_fingerprint -> prev_fp, $fingerprint -> fp, $caps -> caps
            ).
            // DR migration is a subscriber/special-case of the generic delta:
            // all eligibility, election, born-DR and epoch gates remain inside
            // the existing trigger unchanged.
            sc mig_trigger_actions sender_id -- ( -> a) { actions (_count actions|) -> a. }
        }
        actions (_count actions|) -> _save_state NIL.
        return transaction::success actions.
    }

    fn handle_capability_advertise_ack (args: any) -> transaction::results::type
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::external,).
        encrypted_channel::check_encrypted_or_abort().
        sender_id = current_transaction_info::get_external_envelope_or_abort() $from.
        if (contacts sender_id) == NIL { return transaction::success []. }
        fp = (args $fingerprint) safe str.
        // A stale/replayed ACK cannot suppress a newer capability snapshot.
        if fp != caps_fingerprint NIL { return transaction::success []. }
        contact_advertised_caps sender_id -> fp.
        return transaction::success [ _save_state NIL ].
    }

    // Part C: the SINGLE generic capability re-advertise entrypoint. The app declares
    // capabilities once at init and calls this on boot/GC. A persisted global fingerprint
    // detects code-defined changes; a persisted per-contact ACK ledger prevents repeat sends
    // while retrying offline/lost-ACK contacts. On a global change, the legacy full-AD push
    // remains a migration bootstrap subscriber/special-case. E2E account/session recovery is
    // intentionally still the separate readvertise_e2e_recovery daemon sweep.
    trn reconcile_advertise _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        cur_pv  = a2a_versions::wire_version.
        cur_fp  = caps_fingerprint NIL.
        changed is bool = (advertised_pv != cur_pv) || (cur_fp != advertised_caps).
        actions is transaction::action::type[] = [].
        cap_n    is int = 0.
        legacy_n is int = 0.
        // Per-contact ACK ledger: retry missing/stale peers on the next cadence,
        // but never re-spam a peer that confirmed this exact capability set.
        sc contacts -- (cid -> ) ?? ((contact_advertised_caps cid) != cur_fp)
        {
            actions (_count actions|) -> encrypted_channel::send_encrypted_tx cid (
                $name -> capability_advertise_tx,
                $targ -> ($pv -> cur_pv, $caps -> (a2a_capabilities::self_cap_ids NIL), $fingerprint -> cur_fp) ).
            cap_n -> cap_n + 1.
        }
        // ON CHANGE ONLY: the legacy upgrade push to pre-existing legacy contacts.
        if changed
        {
            b = my_identity_bundle_fields_fresh NIL.
            sc contacts -- (cid -> ) ?? ((contact_e2e_epoch cid) == NIL && (contact_born_dr cid) != TRUE && (contact_migration cid) == NIL)
            {
                actions (_count actions|) -> encrypted_channel::send_encrypted_tx cid (
                    $name -> readvertise_ad_tx,
                    $targ -> ( $ad -> (b $ad), $cert -> (b $cert), $root_profile -> (b $root_profile),
                               $cp_binding -> (b $cp_binding),
                               $pv -> a2a_versions::wire_version,
                               $caps -> (a2a_capabilities::self_cap_ids NIL) ) ).
                legacy_n -> legacy_n + 1.
            }
        }
        advertised_pv   -> cur_pv.
        advertised_caps -> cur_fp.
        actions (_count actions|) -> _return_data (
            $changed -> changed, $capability_advertised -> cap_n,
            $e2e_readvertised -> 0, $legacy_readvertised -> legacy_n
        ).
        actions (_count actions|) -> _save_state NIL.
        return transaction::success actions.
    }

    // core 0.11 (session self-heal, retry leg): re-send unacked e2e messages stuck without
    // a delivered receipt for redrive_min_age_seconds+ (see the const above). Host calls
    // this on the boot/GC cadence next to readvertise_e2e_recovery. Mutates session state
    // (encrypt_to advances the ratchet) → _save_state when anything was redriven.
    trn redrive_unacked_sweep _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        now = (current_transaction_info::get_transaction_time())?.
        actions is transaction::action::type[] = [].
        // Separate counters (finding K / review #15): a TTL purge is NOT a redrive,
        // and a deferred contact is neither — the log must say what actually happened.
        purged is int = 0.
        redriven is int = 0.
        deferred is int = 0.
        // Ship-review major-4: ONE bounded, resumable pass over BOTH phases. Per
        // contact: (1) TTL purge — entries past unacked_ttl_seconds drop for good
        // (a peer withholding receipts cannot pin plaintext forever) with ONE
        // $e2e_delivery_expired RET per affected contact (review #7: explicit, never
        // silent) — then (2) the aged redrive. Budgets bound the WHOLE txn: crypto
        // ops (ratchet encryptions — this path performs zero sig-verifies, so the op
        // count is exact, not a fuel proxy) and emitted actions (SEND/RET including
        // the expiry notifies). A contact whose worst case would overflow either
        // budget is deferred; the EXPORTED cursor resumes there next sweep, and a
        // sweep-txn abort rolls the cursor back so a retry covers the same segment.
        crypto_budget is int = redrive_sweep_max_entries.
        // Ship-review round-2 minor: reserve the fixed 2-action tail (_save_state +
        // _return_data) up front so the emitted total NEVER exceeds
        // redrive_sweep_max_actions — the no-save case uses only 1 of the 2 (the
        // _return_data), which is slack, not overflow.
        action_budget is int = redrive_sweep_max_actions - 2.
        resume_after is global_id+ = redrive_sweep_cursor.
        past_cursor is bool = (resume_after == NIL).
        last_done is global_id+ = NIL.
        exhausted is bool = FALSE.
        expired is global_id[] = [].
        sc unacked_e2e -- (cid -> q) ?? (_count q|) > 0
        {
            if past_cursor != TRUE
            {
                deferred -> deferred + 1.
                if cid == (resume_after?) { past_cursor -> TRUE. }
            }
            else
            {
                // worst case for this contact: 1 expiry RET + (1 crypto op + 2 actions)
                // per redriven entry
                if exhausted || (_count q|) > crypto_budget || action_budget < ((_count q|) * 2 + 1)
                {
                    exhausted -> TRUE.
                    deferred -> deferred + 1.
                }
                else
                {
                    live is unacked_entry_t[] = [].
                    gone is str[] = [].
                    sc q -- ( -> ent)
                    {
                        if (_substract_seconds now (ent $date)) <= unacked_ttl_seconds { live (_count live|) -> ent. }
                        else { gone (_count gone|) -> (ent $wire_id). }
                    }
                    if (_count gone|) > 0
                    {
                        actions (_count actions|) -> _notify_agent ($event -> $e2e_delivery_expired, $cid -> cid, $wire_ids -> gone).
                        action_budget -> action_budget - 1.
                        if (_count live|) == 0 { expired (_count expired|) -> cid. } else { unacked_e2e cid -> live. }
                        purged -> purged + 1.
                    }
                    if (_count live|) > 0
                    {
                        oldest is time+ = NIL.
                        sc live -- ( -> ent) { if oldest == NIL { oldest -> (ent $date). } }
                        if oldest != NIL && (_substract_seconds now (oldest?)) > redrive_min_age_seconds
                        {
                            pre_cnt is int = (_count actions|).
                            sc redrive_unacked_actions cid -- ( -> a) { actions (_count actions|) -> a. }
                            // Count only contacts something was actually re-sent for (the
                            // cap-gate or a missing bundle can make the redrive a no-op).
                            if (_count actions|) > pre_cnt
                            {
                                redriven -> redriven + 1.
                                crypto_budget -> crypto_budget - (_count live|).
                                action_budget -> action_budget - ((_count actions|) - pre_cnt).
                            }
                        }
                    }
                    last_done -> cid.
                }
            }
        }
        sc expired -- ( -> cid) { delete unacked_e2e cid. }
        if past_cursor != TRUE { redrive_sweep_cursor -> NIL. }
        else { if exhausted { redrive_sweep_cursor -> last_done. } else { redrive_sweep_cursor -> NIL. } }
        if purged > 0 || redriven > 0 || exhausted { actions (_count actions|) -> _save_state NIL. }
        actions (_count actions|) -> _return_data ($redriven_contacts -> redriven, $purged_contacts -> purged, $deferred_contacts -> deferred).
        return transaction::success actions.
    }

    trn sweep_e2e_migrations _
    {
        current_transaction_info::validate_origin_or_abort (transaction::envelope::origin::user,).
        actions is transaction::action::type[] = [].
        redriven is int = 0.  stalled is int = 0.  superseded is int = 0.
        now = (current_transaction_info::get_transaction_time())?.
        sc contact_migration -- (cid -> st) ?? (((st) $phase) == "offered" || ((st) $phase) == "acknowledged" || ((st) $phase) == "committed")
        {
            att is int = (st $attempts).
            ph = (st $phase).
            // §5.6 LIVENESS BACKSTOP: a COMMITTED initiator must never PERMANENTLY stall (that would
            // strand its mig_deferred app data forever — the peer-rekey / responder-full-regen case,
            // where our staged commit can never decode on the peer's rotated identity). At the attempts
            // cap it SUPERSEDES (fresh offer/epoch) instead of only notifying, releasing the barrier and
            // re-attempting onto the peer's current bundle (the fresh ack re-freezes the epoch on it). It
            // was NEVER epoch-pinned, so re-offering — legacy flows at `offered` — is NOT a downgrade.
            // offered/acknowledged still terminate at $migration_stalled (legacy already flows there).
            if att >= mig_max_attempts && ph != "committed"
            {
                actions (_count actions|) -> _notify_agent ($event -> $migration_stalled, $cid -> cid, $phase -> ph, $attempts -> att).
                stalled -> stalled + 1.
            }
            else
            {
                do_supersede is bool = FALSE.
                leg is transaction::action::type[] = [].
                if ph == "offered"
                {
                    // §5.4-5 ROTATION DETECTOR: if my published bundle rotated since this snapshot, a
                    // byte-identical resend would carry a STALE fp under the SAME nonce (breaking epoch
                    // equality with the responder's already-acked bundle) → SUPERSEDE (fresh nonce/epoch)
                    // instead of resending. Unchanged fp → byte-identical retransmit (idempotent).
                    live_fp = e2e_bundle_fp (address_document::produce_my_address_document()).
                    if (st $local_fp) != NIL && ((st $local_fp)?) != live_fp { do_supersede -> TRUE. }
                    else { leg -> mig_resend_offer_actions cid st. }
                }
                elif ph == "acknowledged" { leg -> mig_resend_ack_actions cid st. }
                else
                {
                    // committed: staged session lost (rc==NIL, unresumable) OR the attempts-cap liveness
                    // backstop above → SUPERSEDE (fresh offer/epoch); otherwise re-encrypt on the
                    // surviving staged session and re-send (the responder's session_matches collapses it).
                    rc = mig_resend_commit_actions cid st.
                    if rc == NIL || att >= mig_max_attempts { do_supersede -> TRUE. } else { leg -> rc?. }
                }
                if do_supersede
                {
                    sc mig_offer_actions cid -- ( -> a) { actions (_count actions|) -> a. }   // fresh offer/epoch
                    superseded -> superseded + 1.
                }
                else
                {
                    sc leg -- ( -> a) { actions (_count actions|) -> a. }
                    contact_migration cid -> ( $phase -> (st $phase), $initiator -> (st $initiator),
                        $local_nonce -> (st $local_nonce), $peer_nonce -> (st $peer_nonce), $epoch -> (st $epoch),
                        $session_id -> (st $session_id), $local_bundle -> (st $local_bundle), $local_fp -> (st $local_fp),
                        $attempts -> (att + 1), $updated -> now ).
                    redriven -> redriven + 1.
                }
            }
        }
        // §5.4 INITIATE (MR2-ruled): beyond re-driving in-flight migrations, the sweep is the
        // eventually-consistent reconciler — it proactively OFFERS to every eligible contact with no
        // migration yet (mig_should_trigger: contact_migration==NIL ∧ epoch==NIL ∧ self-advertises ∧
        // peer-known-0.9). This is the ONLY path that covers the post-version-bump default-cap boot with
        // pre-existing e2e contacts and NO inbound traffic (advertise_migrate isn't called at boot, and
        // the receive triggers need inbound traffic). Inert pre-cap (self-advertise gate); an already-
        // migrated pair is never re-offered (never-cleared contact_migration + the epoch-pin guard).
        elig is transaction::action::type[] = mig_offer_eligible_actions NIL.
        initiated is int = (_count elig|).
        sc elig -- ( -> a) { actions (_count actions|) -> a. }
        actions (_count actions|) -> _return_data ($redriven -> redriven, $stalled -> stalled, $superseded -> superseded, $initiated -> initiated).
        if (redriven + superseded + initiated) > 0 { actions (_count actions|) -> _save_state NIL. }
        return transaction::success actions.
    }

    // ---- upgrade: state export / import helpers ------------------------------
    // NOT transactions: each app's export_state/import_state trn composes these
    // with its own app-side fields (inbox / chat history / local book). Field
    // names match the historical app-level blobs exactly, so a PRE-migration
    // export imports through here unchanged.

    fn export_core_state (_) -> any
    {
        return (
            $my_name         -> my_name,
            $contacts        -> contacts,
            $pending_invites -> pending_invites,
            $peer_ads        -> peer_ads,
            $my_bio          -> my_bio,
            $my_persona      -> my_persona,
            $delegation_cert -> delegation_cert,
            $delegation_cert_v1 -> delegation_cert_v1,
            $root_ad         -> root_ad,
            $root_profile    -> root_profile,
            $root_cp_binding -> root_cp_binding,
            $contact_roots   -> contact_roots,
            $contact_cp_bindings -> contact_cp_bindings,
            $managed_roots    -> managed_roots,
            $proxy_pending    -> proxy_pending,
            $monitoring_proxy -> monitoring_proxy,
            $app_config       -> app_config,
            $format_version  -> core_format_version,
            $deferred_msgs   -> deferred_msgs,
            $contact_pv      -> contact_pv,
            $contact_caps    -> contact_caps,
            $contact_advertised_caps -> contact_advertised_caps,
            $contact_e2e_seen -> contact_e2e_seen,
            $contact_born_dr -> contact_born_dr,
            // core 0.9.0 migration FSM metadata — additive, all keyed by cid. Only
            // PUBLIC FSM/epoch/queue metadata travels; the staged/active Olm session
            // pickles stay packet-local in the adapt e2e library (INV-4 / spec §5.1).
            $contact_migration  -> contact_migration,
            $contact_e2e_epoch  -> contact_e2e_epoch,
            $mig_deferred       -> mig_deferred,
            // core 0.11 Signal-model restart survival: the pickle_key-SEALED Olm account +
            // LIVE per-peer session pickles (opaque bin). m_staged is deliberately NOT
            // exported — a restart mid-migration drops the transient staged session and the
            // migration sweep supersedes it (review #16: this comment previously claimed
            // staged was persisted). Persisting account+live lets a restart RESUME the exact
            // ratchet instead of re-minting a fresh account (the desync root cause) —
            // self-heal then only runs on TRUE loss (reinstall/corruption). state_data.bin
            // is LOCAL-ONLY, so this stays off any peer/broker; the sealed bytes carry no raw
            // secretkey type. NOTE: if state_data.bin is ever repurposed as a CROSS-NODE portable
            // blob, move this to a local sidecar (the material is local-secrecy class).
            $e2e_sessions       -> (e2e::export_sessions NIL),
            // core 0.11 self-heal: unacked e2e sends (additive; app payload class, NO key
            // material — INV-4 holds). rekey_pending is deliberately NOT exported (transient
            // rate-limit ledger; a restart at worst re-sends one idempotent request).
            $unacked_e2e        -> unacked_e2e,
            $delivered_wire     -> delivered_wire,
            // Ship-review major-4: the sweep resume cursor survives restarts, else a
            // boot-sweep-only lifecycle re-scans the same prefix forever (tail starves).
            $redrive_cursor     -> redrive_sweep_cursor,
            // core 0.12 (2b): the pv + cap-set fingerprint of my last self-advertise
            // reconcile, so a post-upgrade boot detects the change and re-advertises once.
            $advertised_pv      -> advertised_pv,
            $advertised_caps    -> advertised_caps
        ).
    }

    fn import_core_state (data: any) -> nil
    {
        // ---- format stamp + THE MIGRATION CONTRACT -------------------------------
        // Absent stamp == version 0 (every pre-stamp blob); all shipped migrations so
        // far are additive/field-optional, so 0 imports through the optional reads
        // below. The stamp exists so a future BREAKING blob change dispatches on an
        // explicit key instead of shape-sniffing. CONTRACT (binding on every future
        // format bump): a migration from version N MUST carry forward `contacts`,
        // `my_name`, `my_bio`, `my_persona` (and SHOULD carry contact_roots and the
        // consumer app's inbox/files); `peer_ads` is BEST-EFFORT — when a crypto/AD
        // change makes old documents unusable, DROP them: each dropped peer becomes a
        // degraded contact (contacts entry, no peer_ads entry) and self-heals through
        // request_contact_restore. NEVER let an incompatible optional field abort the
        // whole import — degrade, don't reset.
        fmt is int = 0.
        if (data $format_version) != NIL { fmt -> (data $format_version) safe int. }
        abort "State blob format_version " + (_str fmt) + " is newer than this code (supports up to " + (_str core_format_version) + ") — upgrade the software before importing." when fmt > core_format_version.

        // The original schema's fields are required; everything that arrived
        // with a later schema is optional and defaults stay in place when
        // absent (the whole point of code-independent state is that an old
        // export upgrades, never resets).
        my_name         -> (data $my_name) safe str.
        contacts        -> (data $contacts) safe (global_id ->> a2a_protocol::contact_t).
        // core 3.0 migration: pending_invites changed shape (pre-3.0 (global_id ->>
        // str) → (global_id ->> pending_invite_t)). It is reset to EMPTY on import,
        // unconditionally and for BOTH shapes: a pre-3.0 str-map is incompatible (so
        // it is dropped rather than safe-cast, which would abort), and even a 3.0
        // record-map entry is unredeemable after import because its matching
        // ephemeral private key (pending_invite_keys) is hidden + NEVER exported
        // (INV-4). The responder-side stores (pending_redemptions /
        // pending_redemption_keys) are likewise not exported and default to empty
        // here. Net: outstanding invites/redemptions are transient — they do not
        // survive export/import or a daemon restart, fail-closed (plan §4.4).
        pending_invites -> (,).
        // Restore handshake state is transient exactly like pending_invites: the eph
        // PRIVATE halves are hidden + never exported, so imported records would be
        // unanswerable. The boot sweep (restore_degraded_contacts) re-mints them.
        pending_restores -> (,).
        pending_restore_replies -> (,).
        peer_ads        -> (data $peer_ads) safe (global_id ->> address_document_types::t_address_document).

        if (data $my_bio) != NIL
        {
            my_bio -> (data $my_bio) safe str.
        }
        if (data $my_persona) != NIL
        {
            my_persona -> (data $my_persona) safe str.
        }
        if (data $delegation_cert) != NIL
        {
            delegation_cert -> (data $delegation_cert) safe a2a_protocol::delegation_cert_t.
        }
        // Additive (absent in pre-fix exports → stays NIL; the host re-mints it on
        // the next set_delegation, so an un-upgraded role degrades to omitting the
        // chain on down-level rather than aborting the peer).
        if (data $delegation_cert_v1) != NIL
        {
            delegation_cert_v1 -> (data $delegation_cert_v1) safe a2a_protocol::delegation_cert_t.
        }
        if (data $root_ad) != NIL
        {
            root_ad -> (data $root_ad) safe address_document_types::t_address_document.
        }
        if (data $root_profile) != NIL
        {
            root_profile -> (data $root_profile) safe a2a_protocol::root_profile_t.
        }
        if (data $root_cp_binding) != NIL
        {
            root_cp_binding -> (data $root_cp_binding) safe a2a_protocol::root_cp_binding_t.
        }
        if (data $contact_roots) != NIL
        {
            contact_roots -> (data $contact_roots) safe (global_id ->> a2a_protocol::contact_root_t).
        }
        if (data $contact_cp_bindings) != NIL
        {
            contact_cp_bindings -> (data $contact_cp_bindings) safe (global_id ->> a2a_protocol::root_cp_binding_t).
        }
        // CP-side managed roots (absent from pre-2.1 exports → stays empty, i.e. this
        // node enrolls no cluster children until a root is registered via manage_root).
        if (data $managed_roots) != NIL
        {
            managed_roots -> (data $managed_roots) safe (global_id ->> bool).
        }
        // Forced-monitoring state (absent from pre-monitoring exports → defaults
        // stay NIL, i.e. unmonitored, until a control plane binds).
        if (data $proxy_pending) != NIL
        {
            proxy_pending -> (data $proxy_pending) safe proxy_pending_t.
        }
        if (data $monitoring_proxy) != NIL
        {
            monitoring_proxy -> (data $monitoring_proxy) safe proxy_binding_t.
        }
        // Control-plane config state (absent from pre-config exports → defaults).
        if (data $app_config) != NIL
        {
            app_config -> (data $app_config) safe str.
        }
        if (data $deferred_msgs) != NIL
        {
            deferred_msgs -> (data $deferred_msgs) safe (global_id ->> deferred_msg_t[]).
        }
        // core 0.5.0: learned peer dialects/caps (absent from pre-0.5 exports
        // → defaults stay empty; re-learned passively from inbound traffic).
        if (data $contact_pv) != NIL
        {
            contact_pv -> (data $contact_pv) safe (global_id ->> int).
        }
        if (data $contact_caps) != NIL
        {
            contact_caps -> (data $contact_caps) safe (global_id ->> str[]).
        }
        // core 0.8.0: E2E anti-downgrade pin (absent from pre-0.8 exports →
        // stays empty; re-learned positively from inbound core.e2e evidence).
        if (data $contact_e2e_seen) != NIL
        {
            contact_e2e_seen -> (data $contact_e2e_seen) safe (global_id ->> bool).
        }
        if (data $contact_born_dr) != NIL
        {
            contact_born_dr -> (data $contact_born_dr) safe (global_id ->> bool).
        }
        // core 0.9.0: migration FSM metadata (absent from pre-0.9 exports → all
        // three stay empty = legacy, spec §5.1). Guarded exactly like the pins.
        // Since persist-primary the ACTIVE session pickles ride $e2e_sessions and
        // survive export/import (validated commit); only the transient STAGED pickle
        // is gone after a restart — a non-active FSM entry is re-driven by the host
        // sweep, a committed-with-lost-staged rotation is superseded by it (§5.6).
        if (data $contact_migration) != NIL
        {
            contact_migration -> (data $contact_migration) safe (global_id ->> mig_state_t).
        }
        if (data $contact_e2e_epoch) != NIL
        {
            contact_e2e_epoch -> (data $contact_e2e_epoch) safe (global_id ->> e2e_epoch_t).
        }
        if (data $mig_deferred) != NIL
        {
            mig_deferred -> (data $mig_deferred) safe (global_id ->> deferred_msg_t[]).
        }
        // core 0.11 self-heal: unacked e2e sends (absent from pre-0.11 exports → empty).
        if (data $unacked_e2e) != NIL
        {
            unacked_e2e -> (data $unacked_e2e) safe (global_id ->> unacked_entry_t[]).
        }
        if (data $delivered_wire) != NIL
        {
            // Current shape first; a pre-H blob carried bare wire_id strings — migrate
            // them with the import time as the delivery date (they age out on the same
            // TTL clock from now, which can only RETAIN LONGER, never dedup less).
            dwn = (data $delivered_wire) safe (global_id ->> delivered_entry_t[]).
            if dwn != NIL { delivered_wire -> dwn?. }
            else
            {
                dwo = (data $delivered_wire) safe (global_id ->> str[]).
                if dwo != NIL
                {
                    mnow = (current_transaction_info::get_transaction_time())?.
                    sc dwo? -- (mcid -> ws)
                    {
                        mq is delivered_entry_t[] = [].
                        sc ws -- ( -> w) { mq (_count mq|) -> ($w -> w, $d -> mnow). }
                        delivered_wire mcid -> mq.
                    }
                }
            }
        }
        // core 0.11 Signal-model restart survival: the SEALED Olm account + LIVE session
        // pickles (no staged — see export). A pre-0.11 blob lacks the field → safe-cast
        // NIL → no restore → a fresh account is lazily minted and the self-heal fallback
        // re-establishes (clean degrade). A STRUCTURALLY corrupt field safe-casts to NIL
        // (same fallback); content-corrupt sealed bytes are caught later by the validated
        // commit (finding C redo below).
        // GUARD (pre-#137-blob fix): `safe` does NOT turn an ABSENT field into a
        // clean NIL for record targets — meta.mm's record checker aborts on any
        // non-dictionary input ("SAFE cast to record failed"), with no NIL
        // branch even for nullable targets (verified identically on 0.10.10 and
        // 0.10.12; see meta.mm record-path). Without this pre-check the WHOLE
        // import failed for every pre-#137 blob. Same explicit `!= NIL` guard as
        // $redrive_cursor below (the ship-review-major-4 pattern).
        es is ( $v -> int, $account -> bin+, $sessions -> (global_id ->> bin)+ )+ = NIL.
        if (data $e2e_sessions) != NIL
        {
            es -> (data $e2e_sessions) safe ( $v -> int, $account -> bin+, $sessions -> (global_id ->> bin)+ ).
        }
        // Finding C redo: do NOT validate or assign here — a corrupt pickle raises a
        // HARD engine error that would fail the whole boot import (contacts and inbox
        // included). Park the blob; the host drives commit_e2e_restore next (still
        // pre-exposure), where a validation failure is isolated + atomic.
        if es != NIL { e2e_restore_staged -> es. }
        // Ship-review major-4: restore the sweep resume cursor (absent in older blobs).
        if (data $redrive_cursor) != NIL
        { redrive_sweep_cursor -> (data $redrive_cursor) safe global_id. }
        // core 0.12 (2b): restore the last-advertised pv + cap fingerprint (absent in older
        // blobs → stays 0/"" → the first reconcile_advertise after upgrade sees a change and
        // re-advertises, which is exactly the desired post-upgrade behavior).
        if (data $advertised_pv) != NIL { advertised_pv -> (data $advertised_pv) safe int. }
        if (data $advertised_caps) != NIL { advertised_caps -> (data $advertised_caps) safe str. }
        if (data $contact_advertised_caps) != NIL
        { contact_advertised_caps -> (data $contact_advertised_caps) safe (global_id ->> str). }

        // Re-register every peer's keys so encrypted channels keep working after
        // the upgrade — no handshake needed (my own keys are unchanged, and the
        // peers' self-signed address documents re-authorize on this fresh packet).
        sc peer_ads -- ( -> ad)
        {
            address_document::process_address_document ad TRUE.
        }
    }
}
