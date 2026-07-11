// Shared ours sealed-backup library (core 0.6.0).
//
// THE at-rest protection for a consumer packet's exported state, and the
// words-rooted key custody that goes with it: everything cryptographic
// happens INSIDE the packet (wasm) — the host only ever stores ciphertext
// (the owner's rule: no crypto in JS, no plaintext keys in IndexedDB).
//
// ONE human secret: a BIP39 phrase ("the words"), mintable IN-WASM
// (_eth_generate_mnemonic — the toolchain ships BIP39 as primitives). From
// the words, a dedicated backup ENCRYPTION keypair B is derived
// DETERMINISTICALLY and purpose-separated:
//
//   words --_eth_seed_from_mnemonic--> seed64
//         --_value_id($purpose,$seed) (domain-separated 32B)-->
//         --_crypto_construct_encryption_keypair_from_seed--> B
//
// (All primitives verified on the vendored toolchain; the derivation is
// stable across processes. The $purpose tag versions the derivation — a
// changed chain gets a NEW tag beside this one, never a mutation.)
//
// Backup artifacts (both pure ciphertext, safe in IndexedDB / any service):
//   sealed_key   — the packet's root SIGN secret sealed to B. At restore the
//                  host feeds the unsealed secret to --init_trn_argument and
//                  the consumer's __init reseeds (ours-mcp pattern) so the
//                  packet returns at the SAME container address (adapt #77).
//   sealed_state — the composed export-state record sealed to B, refreshed
//                  per save. Sealing needs only B's PUBLIC key (kept as
//                  consumer packet state), so the words are NOT needed — and
//                  must not be held by the host — between restores.
//
// WHY B is not the identity's default ENCRYPT key: reseed_identity_from_
// secret WIPES the key stores and rolls FRESH encrypt keys (stdlib
// key_storage.mm), so anything sealed to the identity encrypt key dies on
// restore. B is words-derived and packet-independent, so an independently
// created packet re-derives it from the same words — that IS the restore.
//
// The seal itself is the invite-leg box pattern (proven in a2a_messaging):
// fresh ephemeral sender keypair per seal, _crypto_encrypt_message to the
// target PUBLIC key. key_storage-independent: works before/during/after
// reseeds, and on a throwaway bootstrap packet.
//
// The sealed envelope is a HOST-FACING versioned type: it never crosses the
// peer wire, but it IS a long-lived stored artifact, so it follows the
// COMPATIBILITY.md discipline — frozen $v versions, dispatch on $v, a new
// shape registers v2 beside v1, unknown-newer fails with a clear message.
library a2a_backup
{
    hidden
    {
        // The deserialization primitive is application-scoped; the consumer
        // wires it at boot exactly as it does for key_storage/a2a_messaging:
        //   a2a_backup::init ($_read_or_abort -> grab(_read_or_abort)).
        _read_or_abort is (bin -> any) = fn (_: bin)
        {
            abort "_read_or_abort is unset in a2a_backup (call a2a_backup::init)." when TRUE.
        }
    }

    init = fn (_:($_read_or_abort -> read: (bin -> any)))
    {
        _read_or_abort -> read.
    }

    // Sealed-envelope format version. Bump ONLY on an envelope shape change
    // (new field / new construction), registering a new branch below.
    sealed_v = 1.
    // Derivation domain tag (versions the words->B chain itself).
    derive_purpose = "ours-backup-seal-v1".
    // Default phrase strength (BIP39 words). 24 per owner decision 2026-07-11.
    backup_word_count = 24.

    // v1 sealed envelope: the ephemeral sender PUBLIC key + the box. $v is
    // the discriminator (host-facing sibling of the wire registry's $pv).
    metadef sealed_state_v1_t: (
        $v   -> int,
        $epk -> publickey_encrypt,
        $ct  -> crypto_message
    ).

    metadef backup_keypair_t: ($pub -> publickey_encrypt, $sec -> secretkey_encrypt).

    // ---- words + derivation (all in-wasm) ----------------------------------

    // Mint a fresh BIP39 phrase inside the packet (entropy is the wrapper-fed
    // per-call entropy). The consumer returns it ONCE for user display; it is
    // never packet state and never host storage.
    fn generate_backup_words (_) -> str
    {
        return _eth_generate_mnemonic backup_word_count.
    }

    // The shared, audited words->seed32 chain, generic over the PURPOSE tag —
    // every consumer-level derivation from the same words (e.g. the recovery-
    // request signing keypair, purpose "ours-recover-sign-v1") uses THIS so
    // domain separation is uniform and reviewed in one place.
    fn derive_seed32 (words: str, purpose: str) -> bin
    {
        seed64 = _eth_seed_from_mnemonic words.
        return _hex_string_to_binary (_str (_value_id ($purpose -> purpose, $seed -> seed64))).
    }

    // words -> the deterministic, purpose-separated backup keypair B.
    fn derive_backup_keypair (words: str) -> backup_keypair_t
    {
        kp = _crypto_construct_encryption_keypair_from_seed (_crypto_default_scheme_id()) (derive_seed32 words derive_purpose).
        return ($pub -> (kp $public_key), $sec -> (kp $secret_key)).
    }

    // Generic mint (non-derived variant — kept for designs that prefer a
    // random backup keypair whose secret the host custodies; same seal fns).
    fn mint_backup_keypair (_) -> ($pub -> publickey_encrypt, $sec_blob -> bin)
    {
        kp = _crypto_construct_encryption_keypair (_crypto_default_scheme_id()).
        return ($pub -> (kp $public_key), $sec_blob -> (_write (kp $secret_key))).
    }

    // ---- seal / unseal (generic over the target keypair) -------------------

    // Seal any composed record to a backup PUBLIC key. Fresh ephemeral sender
    // keypair per seal (no key reuse across blobs); the plaintext
    // serialization exists only inside this call.
    fn seal_state (state: any, backup_pub: publickey_encrypt) -> bin
    {
        eph = _crypto_construct_encryption_keypair (_crypto_default_scheme_id()).
        ct = _crypto_encrypt_message (eph $secret_key) backup_pub (_write state).
        sealed is sealed_state_v1_t = ($v -> sealed_v, $epk -> (eph $public_key), $ct -> ct).
        return _write sealed.
    }

    // Unseal with an explicit secret. Aborts with a stable, render-ready
    // message on an unsupported envelope version or a wrong-key/tampered blob
    // (user-origin restore flow: abort IS the clean surface — nothing async,
    // nothing to roll back).
    fn unseal_state (blob: bin, backup_sec: secretkey_encrypt) -> any
    {
        raw = _read_or_abort blob.
        v = raw $v.
        if v == NIL || (_typeof v) != "INTEGER"
        {
            abort "Not a sealed backup blob (missing version tag)." when TRUE.
        }
        abort "Sealed backup version " + (_str (v safe int)) + " is newer than this core supports (up to " + (_str sealed_v) + ") — update the software before restoring." when (v safe int) > sealed_v.
        sealed = raw safe sealed_state_v1_t.
        return _read_or_abort (_crypto_decrypt_message backup_sec (sealed $epk) (sealed $ct)).
    }

    // Words-flow conveniences (the default path).
    fn unseal_state_with_words (blob: bin, words: str) -> any
    {
        return unseal_state blob ((derive_backup_keypair words) $sec).
    }

    // The packet's root SIGN secret, sealed to B — the "sealed_key" artifact.
    // Wrapped in a purpose-tagged record so an unsealed blob is self-
    // describing; $hex is ready for --init_trn_argument (hex of the _write'd
    // secretkey_sign — the exact encoding __init inverts).
    fn seal_signing_secret (secret: secretkey_sign, backup_pub: publickey_encrypt) -> bin
    {
        return seal_state ($kind -> "ours-package-key-v1", $hex -> (_hex_string_from_binary (_write secret))) backup_pub.
    }

    fn unseal_signing_secret_hex (blob: bin, words: str) -> str
    {
        data = unseal_state_with_words blob words.
        k = data $kind.
        abort "Not a sealed package key." when k == NIL || (_typeof k) != "STRING" || (k safe str) != "ours-package-key-v1".
        return (data $hex) safe str.
    }
}
