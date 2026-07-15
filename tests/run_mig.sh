#!/usr/bin/env bash
# Phase-A migration store + export/import gate: compile the test actor against THIS core, boot a
# local broker, run ONLY tests/mig.mjs (single packet, no peer traffic).
# Same env knobs as run.sh: ADAPT_TOOLKIT / OURS_SDK_NODE_MODULES / DEV_BROKER / PORT.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CORE_DIR=$(cd "$HERE/.." && pwd)
AT=${ADAPT_TOOLKIT:-/home/shakhvit/work/adapt/adapt-toolkit}
SDK_NM=${OURS_SDK_NODE_MODULES:-/home/shakhvit/work/adapt/ours/ours-mcp/node_modules}
DEV_BROKER=${DEV_BROKER:-/home/shakhvit/work/adapt/ours/ours-mcp/scripts/dev-broker.mjs}
PORT=${PORT:-9798}
COMPILE="$AT/build.linux.release/mufl-compile"

for p in "$COMPILE" "$AT/mufl_stdlib" "$SDK_NM/@adapt-toolkit" "$DEV_BROKER"; do
  [ -e "$p" ] || { echo "MISSING: $p (set ADAPT_TOOLKIT / OURS_SDK_NODE_MODULES / DEV_BROKER)"; exit 2; }
done

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$BUILD/core"
cp "$CORE_DIR"/*.mm "$CORE_DIR"/config.mufl "$BUILD/core/"
cp "$HERE/mig_actor.mu" "$HERE/mig.mjs" "$HERE/protocol_container.mm" "$BUILD/"
ln -sfn "$SDK_NM" "$BUILD/node_modules"
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
echo "compiling test actor against $CORE_DIR core…"
MUFL_STDLIB_PATH="$AT/mufl_stdlib" "$COMPILE" -mp "$AT/meta" -mp "$AT/transactions" mig_actor.mu 2>&1 \
  | grep -vE "Unused symbol|browser_attestation|identity_proof_document_impl" | tail -4
ls ./*.muflo >/dev/null 2>&1 || { echo "COMPILE FAILED"; exit 1; }

node "$DEV_BROKER" --host 127.0.0.1 --port "$PORT" --test_mode >broker.log 2>&1 &
BPID=$!
sleep 2.5
kill -0 "$BPID" 2>/dev/null || { echo "BROKER FAILED TO START:"; cat broker.log; exit 3; }

BROKER_URL="ws://127.0.0.1:$PORT" node mig.mjs 2> >(grep -E 'DRIVER ERR' >&2)
RC=$?
kill "$BPID" 2>/dev/null
exit $RC
