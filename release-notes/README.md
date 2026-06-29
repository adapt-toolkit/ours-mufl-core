# ours mufl core — release notes

One note file per **core version**, where the version is the `MAJ.MIN` reported
by `version::get_core_version` (`version.mm`). This replaces the single
`RELEASE_NOTES_core_config.md` that previously covered a whole range (1.10→2.0);
that file is now `2.0.md` (the 2.0 lineage record), unchanged in content.

## Versions (newest first)

| Core | Bump | Summary |
|------|------|---------|
| [3.0](3.0.md) | MAJ (breaking) | **Ephemeral-key slim invite** — the fat identity-bearing invite is replaced by a slim `invite_eph_t` (ephemeral encryption pubkey + cid + name + scheme only); both address documents + the delegation chain move to a two-message **bare boxed** redeem hop (legs 1/2/3). Removes `invite_t` / `invite_role_t` / `rebuild_peer_address_document` + the old `add_contact` body. Per-invite ephemeral secrets are `hidden` + never exported → outstanding invites are restart-transient (fail-closed). |
| [2.2](2.2.md) | MIN (additive) | **Cluster root-side producers** — the root half core 2.1 deferred: a root mints its CP binding (`sign_root_cp_binding`), pushes it to roles (`set_root_cp_binding` widened to verify a role's inherited binding against its pinned `root_ad`), and relays children to the CP (`relay_enroll_delegated_node`). Additive; legacy paths untouched. |
| [2.1](2.1.md) | MIN (additive) | **Cluster CP-introduction** — one root↔CP bind enrolls a whole cluster; children inherit the root's CP binding and accept CP introductions with zero per-child ceremony. New `manage_root`, `set_root_cp_binding`, `enroll_delegated_node`; `ingest` gate widened (additive). |
| [2.0](2.0.md) | MAJ (breaking) | Configuration / control-plane lineage (1.10→2.0): forced monitoring (B1), opaque control-plane config (B3), and the **radically simplified** `core.connect` introduction (B2) — SAS / CP-signed-intro / `connect_descriptor_t` removed. |

## Convention

- **Filename** = the core version string `MAJ.MIN.md`, matching
  `version::get_core_version` for the change.
- **Every `MAJ`/`MIN` bump in `version.mm` REQUIRES a matching
  `release-notes/<version>.md` in the same change** — a reviewer checklist item.
  A version bump with no matching note (or a note with no bump) is a review block.
- Each note opens with a **header line** stating the version, the bump type
  (`MAJ` breaking / `MIN` additive) and a one-line summary, then these sections:
  - **What shipped**
  - **New/changed transactions**
  - **Breaking changes** (only if `MAJ`)
  - **Integration TODO for consumers**
  - **Security notes**
- This `README.md` carries the version table above, **newest first**, one line
  each. Add a row in the same change that adds the note.
