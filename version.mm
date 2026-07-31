/*
This library provides a simple version tracking mechanism for the shared
ours mufl core. It contains a hardcoded read-only version that can be
accessed by any library or application that loads it.
This library has no dependencies and can be included in any packet.
*/
library version
{
    metadef version_t: (
        $MAJ -> int,
        $MIN -> int,
        $PATCH -> int
    ).

    fn create_version (maj: int, min: int, patch: int) = ($MIN -> min, $MAJ -> maj, $PATCH -> patch).


    // This MUST be updated every time we update ANY code in the shared core.
    //
    // 0.13.0 — bilateral contact removal + explicit invite modes.
    // NOTE this is a jump from 0.9.0, which is a RECONCILIATION, not a version
    // skip: the in-code feature-era labels had already reached "core 0.12"
    // (a2a_messaging auto-advertise) while this constant was last bumped at the
    // 0.9 era, so the two had drifted apart. Nothing reads core_version to make a
    // decision — it is exposed informationally by ::a2a_messaging::get_version —
    // so realigning it is safe. Flagged for review rather than done silently.
    hidden {
        core_version = create_version 0 13 0.
    }

    fn get_core_version(_) = core_version.
}
