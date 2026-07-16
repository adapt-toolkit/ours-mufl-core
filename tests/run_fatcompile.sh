#!/usr/bin/env bash
# COMPILE-ONLY regression guard (no broker, no driver): compile fatcompile_actor.mu — which loads
# the heavy daemon-side libs TOGETHER (a2a_messaging migration surface + a2a_cluster) through the
# __t_wrapper meta path — against THIS core. Producing a .muflo IS the pass. Guards against a
# migration-core change re-inflating per-unit meta-stage reduction past the 1M-step ceiling for a
# multi-heavy-lib packet (the class of failure that broke the ours-mcp daemon build @ 7a14d65 via
# the dead 5th transaction::type union variant). NOTE: the FULL daemon actor.mu (messaging+cluster+
# its app trns) is the authoritative check and lives in the daemon repo's CI; this is the in-core
# early-warning for the heavy-lib combo. Same env knobs as run_mig.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CORE_DIR=$(cd "$HERE/.." && pwd)
AT=${ADAPT_TOOLKIT:-/home/shakhvit/work/adapt/adapt-toolkit}
STDLIB=${MUFL_STDLIB_OVERRIDE:-$AT/mufl_stdlib}
COMPILE="$AT/build.linux.release/mufl-compile"
for p in "$COMPILE" "$STDLIB"; do
  [ -e "$p" ] || { echo "MISSING: $p (set ADAPT_TOOLKIT)"; exit 2; }
done
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$BUILD/core"
cp "$CORE_DIR"/*.mm "$CORE_DIR"/config.mufl "$BUILD/core/"
cp "$HERE/fatcompile_actor.mu" "$HERE/protocol_container.mm" "$BUILD/"
cat > "$BUILD/config.mufl" <<'CFG'
config script
{
    stdlib_config = (config_load #$MUFL_STDLIB_PATH).
    core_config = (config_load #"core").
    (
        $imports -> ( $libraries -> (stdlib_config $exports $libraries)'(core_config $exports $libraries)'($protocol_container -> #"protocol_container.mm"), ),
        $exports -> ( $libraries -> (,), $applications -> (,) )
    ).
}
CFG
cd "$BUILD"
echo "compiling fatcompile_actor (a2a_messaging + a2a_cluster) against $CORE_DIR core…"
MUFL_STDLIB_PATH="$STDLIB" "$COMPILE" -mp "$AT/meta" -mp "$AT/transactions" fatcompile_actor.mu 2>&1 \
  | grep -vE "Unused symbol|browser_attestation|identity_proof_document_impl" | tail -6
if ls ./*.muflo >/dev/null 2>&1; then echo "FATCOMPILE: OK (heavy-lib combo compiles under the meta-fuel ceiling)"; exit 0
else echo "FATCOMPILE: FAILED (meta-fuel ceiling — a migration-core change re-inflated the daemon build path)"; exit 1; fi
