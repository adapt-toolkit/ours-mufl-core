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
    hidden {
        core_version = create_version 0 7 0.
    }

    fn get_core_version(_) = core_version.
}
