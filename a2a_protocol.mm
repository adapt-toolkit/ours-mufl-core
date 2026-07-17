// Shared ours protocol library.
//
// The wire-facing shapes and verification logic common to every ours
// packet (the agent/MCP packet, the web messenger, and future clients).
// Everything here is network protocol surface: peers exchange these shapes
// byte-for-byte, so any change is a protocol revision — keep the shapes
// backward-compatible and bump version.mm with every edit to this core.
library a2a_protocol loads library
    key_utils,
    key_storage,
    address_document_types,
    a2a_capabilities
{
    metadef contact_t: ($name -> str, $container_id -> global_id).

    // ---- identity hierarchy wire shapes ---------------------------------
    // Delegation certificate: "role X belongs to root Y, signed by Y". The
    // signature is over the core's _value_id, binding the role's container
    // id AND its full key material (the address-document hash) to one root.
    // An identity carrying NIL here is a root (or a legacy flat identity) —
    // detection is structural, not a flag. v1 revocation == delete the role.
    metadef delegation_core_t: (
        $version      -> int,
        $role_cid     -> global_id,
        $role_ad_hash -> hash_code,
        $role_id      -> str,
        $root_cid     -> global_id,
        $issued_at    -> time
    ).
    metadef delegation_cert_t: ($c -> delegation_core_t, $s -> crypto_signature).
    // Self-signed root profile, carried in role invites so an external peer
    // learns WHO is behind the role. It includes the root's key list, so the
    // receiver can verify both this signature and the delegation cert with
    // no prior knowledge of the root.
    metadef root_profile_core_t: (
        $version  -> int,
        $root_cid -> global_id,
        $name     -> str,
        $bio      -> str,
        $keys     -> key_utils::t_publickey(,)
    ).
    metadef root_profile_t: ($p -> root_profile_core_t, $s -> crypto_signature).

    // §3c root-half CP binding. The root self-signs {version, context_tag,
    // root_cid, cid_cp} — see the verifier and context tag lower in this library
    // for the full rationale. Carried (as a blob) on the leg-1/leg-3 identity bundle.
    metadef root_cp_binding_core_t: (
        $version     -> int,
        $context_tag -> str,
        $root_cid    -> global_id,
        $cid_cp      -> global_id
    ).
    metadef root_cp_binding_t: ($c -> root_cp_binding_core_t, $s -> crypto_signature).
    // Verified root linkage learned about a contact (from its role invite or
    // a sibling introduction). Kept beside `contacts` so old state blobs
    // (whose contact_t has no such fields) import unchanged.
    metadef contact_root_t: ($root_cid -> global_id, $root_name -> str, $role_id -> str).

    // ---- core 3.0 ephemeral-key slim invite -----------------------------
    // THE invite shape (the fat invite_t / invite_role_t were removed in core 3.0
    // together with the old offline-redeem path). Carries ONLY an ephemeral
    // encryption pubkey, the inviter's routing/identity cid, a display name, and
    // the crypto scheme id — NO identity keys, NO self-sigs, NO cert, NO root
    // profile. The inviter's (and responder's) address documents + delegation
    // chains move to a two-message ENCRYPTED hop after redemption:
    //
    //   (OOB)  inviter ─► responder : invite_eph_t (this shape)
    //   leg 1  responder ─► inviter : submit_invite_response (BARE send; a box to
    //          eph_pub_inviter) — cleartext envelope:
    //            { $invite_id -> global_id, $epk -> publickey_encrypt /*responder eph pub*/,
    //              $v -> int /*scheme*/, $data -> crypto_message }
    //   leg 3  inviter ─► responder : complete_invite (ALSO a BARE send; a box to the
    //          RESPONDER's eph pub from leg 1 — it cannot ride encrypted_channel because
    //          the responder has not registered the inviter yet, and the stdlib exposes
    //          no raw long-term privkey to box against instead). Same envelope shape:
    //            { $invite_id -> global_id, $epk -> publickey_encrypt /*inviter eph pub*/,
    //              $v -> int /*scheme*/, $data -> crypto_message }
    //   Both boxes' `data` decrypt to the SAME identity bundle:
    //            { $ad -> t_address_document, $cert -> bin+, $root_profile -> bin+,
    //              $cp_binding -> bin+, $invite_id -> global_id }
    //   After leg 3, both sides hold the other's verified AD and encrypted_channel
    //   resumes for all subsequent send_message traffic.
    //   $d invite_id (correlates leg-1 to the stored eph privkey; single-use)
    //   $c inviter container_id (routing target + identity pin)
    //   $n inviter display name (metadata only)   $k eph_pub_inviter   $v scheme id
    //   $iv invite-format version (NULLABLE). The version of the invite/handshake
    //     contract the inviter speaks. A redeemer that reads it as NIL treats the
    //     inviter as a pre-versioning node (one that predates this field) and
    //     down-levels its own address document to v1 (omits $e2e_bundle, sets
    //     $version->1) so that older peer accepts it; a present value means the
    //     inviter understands this contract. The field is wire-safe in BOTH
    //     directions: an older decoder ignores the extra member and a newer decoder
    //     reads a missing one as NIL, because mufl metadefs are name-keyed and this
    //     field is nullable. Bump it ONLY for a change that breaks cross-version
    //     invite/handshake compatibility — one that forces the sender to know the
    //     peer's version to interoperate. The confirmed cases are:
    //       - invite_eph_t changing shape such that an older decoder cannot consume it;
    //       - the address-document format moving to an incompatible version (the
    //         v1->v2 $e2e_bundle bump) so a v1 peer would reject a v2 AD.
    metadef invite_eph_t: (
        $d -> global_id,
        $c -> global_id,
        $n -> str,
        $k -> publickey_encrypt,
        $v -> int,
        $iv -> int+
    ).

    // A reply pointer carried on a message: the stable wire id of the message
    // being replied to, plus an optional 1-based sentence index into that
    // message's text. wire_id is the stringified _new_id the sender stamped on
    // the original (msg_id is receiver-local, so it cannot be referenced across
    // sides). The recipient resolves this against its own copy of the referenced
    // message IF it still holds it — agents GC fast, so this is best-effort
    // context for the recipient, not durable thread state.
    metadef reply_ref_t: ($wire_id -> str, $sentence -> int+).

    // ---- local contact book wire shapes ---------------------------------
    // Introduction credential, minted PER CONNECT ATTEMPT by the host's
    // registrar packet (never stored in the book). It binds the joiner's
    // identity AND address document to one target, with freshness + a nonce,
    // so possession of book material alone authorizes nothing: only the
    // registrar (whose key never leaves the host) can mint one, which is
    // what makes "local" a cryptographic property rather than a convention.
    metadef intro_t: (
        $version       -> int,
        $joiner_cid    -> global_id,
        $joiner_ad_hash -> hash_code,
        $target_cid    -> global_id,
        $iat           -> time,
        $nonce         -> global_id
    ).
    metadef signed_intro_t: ($i -> intro_t, $s -> crypto_signature).
    // What the registrar signs for a contact-book entry (tamper-evidence for
    // the host-side book file; verified by the SENDER before connecting).
    metadef book_entry_t: ($version -> int, $name -> str, $ad_hash -> hash_code).

    // Verify a delegation chain presented by a peer: the root profile is
    // internally consistent and the cert binds the peer's container id AND
    // its address document to that root, both signed by the root's keys.
    // The chain is self-contained (the profile carries the root's key list),
    // so it proves "this role belongs to the root that signed it" — it does
    // NOT vouch for who the root is (root verification is deferred to v2).
    // Aborts on any mismatch; returns the linkage to record.
    fn verify_peer_delegation (peer_cid: global_id, peer_ad_hash: hash_code, cert: delegation_cert_t, rp: root_profile_t) -> contact_root_t
    {
        abort "Unsupported delegation certificate version." when (cert $c $version) != 1.
        abort "Unsupported root profile version." when (rp $p $version) != 1.
        abort "Delegation certificate was issued for a different identity." when (cert $c $role_cid) != peer_cid.
        abort "Delegation certificate does not match the peer's address document." when (cert $c $role_ad_hash) != peer_ad_hash.
        abort "Root profile does not match the delegation certificate's root." when (rp $p $root_cid) != (cert $c $root_cid).
        abort "Root profile signature is invalid." when key_storage::check_signature_new_container (_value_id (rp $p)) (rp $s) (rp $p $keys) != TRUE.
        abort "Delegation certificate was not signed by its root." when key_storage::check_signature_new_container (_value_id (cert $c)) (cert $s) (rp $p $keys) != TRUE.
        return ($root_cid -> cert $c $root_cid, $root_name -> rp $p $name, $role_id -> cert $c $role_id).
    }

    // (core 3.0: rebuild_peer_address_document was removed — the inviter's address
    // document now travels whole, inside the boxed leg-1/leg-3 identity bundle, and
    // is replayed directly through address_document::process_address_document; there
    // is no longer a key-list-only invite to reconstruct an AD from.)

    // ---- CP->root governance attestation (§3c, core 1.8) -----------------
    // NON-enforcing visibility only — the sole monitoring gate stays the 6-digit
    // proxy-bind ceremony. cid_cp is the CP's container_id, which IS the key-
    // derived commitment over the CP's SIGN key (P3, adapt-toolkit #77:
    // container_id == key_storage::address_of_key(sign_pub), a hash of the SIGN
    // key alone — NOT _value_id of the whole key_list), so pinning cid_cp pins
    // the CP's signing key and lazy resolution cannot substitute a different CP
    // without breaking it.
    metadef cp_attestation_commitment_t: (
        $version -> int,
        $cid_cp  -> global_id
    ).

    // The lazily-resolved full attestation: the CP signs the ROOT's container_id
    // (the key-derived commitment over the root's SIGN key, P3) — key material,
    // never a label. cp_cid pins it to the same CP as the inline commitment.
    metadef cp_attestation_core_t: (
        $version  -> int,
        $root_cid -> global_id,
        $cp_cid   -> global_id
    ).
    metadef cp_attestation_t: ($c -> cp_attestation_core_t, $s -> crypto_signature).

    // P3 (adapt-toolkit #77): container_id == key_storage::address_of_key(sign_pub)
    // — a hash of the SIGN key alone, not _value_id of the whole key_list. This
    // re-derives that commitment from an identity's own key material so
    // verify_cp_attestation below stays a SELF-CONTAINED check (independent of
    // whatever the caller already validated), mirroring address_document.mm's
    // own "container id does not commit to signing key" check and
    // identity_proof_document_impl.mm::validate.
    fn _address_of_signing_key (key_list: key_utils::t_publickey(,), default_keys: key_utils::t_function->>key_utils::t_key_id) -> global_id
    {
        sign_key_id = default_keys $SIGN.
        sign_pub IS publickey_sign+ = NIL.
        sc key_list -- (k->) {
            if _crypto_get_key_id k == sign_key_id {
                sign_pub -> k SAFE(publickey_sign).
                break.
            }
        }
        abort "verify_cp_attestation: SIGN key not found in cp_ad key_list" WHEN sign_pub == NIL.
        return key_storage::address_of_key sign_pub?.
    }

    // Verify a resolved §3c attestation. TRUE only when the commitment binds the
    // CP keys (cp_ad's key-derived container_id AND its own re-derived
    // address-of-SIGN-key both equal cid_cp), the attestation is pinned to that
    // same CP, it attests the ACTUAL root, and it is CP-signed. The CALLER must
    // have run process_address_document on cp_ad first (that enforces the CP AD
    // proof-of-possession self-sig) and must render an UNRESOLVABLE cp_ad as
    // present-but-unverified — never call this without a resolved, PoP-checked
    // cp_ad.
    fn verify_cp_attestation (commitment: cp_attestation_commitment_t, cp_ad: address_document_types::t_address_document, att: cp_attestation_t, root_cid: global_id) -> bool
    {
        return (commitment $version) == 1
            && (att $c $version) == 1
            && (cp_ad $identity $container_id) == (commitment $cid_cp)
            && (_address_of_signing_key (cp_ad $identity $key_list) (cp_ad $identity $default_keys)) == (commitment $cid_cp)
            && (att $c $cp_cid) == (commitment $cid_cp)
            && (att $c $root_cid) == root_cid
            && key_storage::check_signature_new_container (_value_id (att $c)) (att $s) (cp_ad $identity $key_list) == TRUE.
    }

    // ---- §3c root half: root-signed CP binding (core 1.9) ----------------
    // The root self-signs its governance edge so peers TOFU-pin "root R is
    // managed by CP cid_cp". A SEPARATE artifact from root_profile — keeps its
    // signature and persisted state byte-identical (no migration, no sig
    // invalidation), crypto-confirmed to preserve the §3c binding. Strip-evident
    // only via TOFU: a genesis-time strip downgrades to a visible "no attestation
    // present" — costs visibility, not security, since the edge is non-enforcing.
    cp_attestation_context_tag = "ours:cp-attestation:v1".

    // Verify the root half: root-signed and domain-separated, binding the root's
    // OWN key-derived container_id (P3 — NEVER a free root_cid label, the D1
    // trap) to the CP commitment. root_keys is the root key list the caller
    // already pins (the delegation chain / root_ad), so this proves the EDGE,
    // not who the root is.
    fn verify_root_cp_binding (binding: root_cp_binding_t, root_cid: global_id, root_keys: key_utils::t_publickey(,)) -> bool
    {
        return (binding $c $version) == 1
            && (binding $c $context_tag) == cp_attestation_context_tag
            && (binding $c $root_cid) == root_cid
            && key_storage::check_signature_new_container (_value_id (binding $c)) (binding $s) root_keys == TRUE.
    }
}
