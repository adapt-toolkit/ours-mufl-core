#!/usr/bin/env bash
# Loopback test runner for the core-3.0 ephemeral-invite suite.
#
# The core repo is pure mufl libraries; running a behavioural test needs (a) the
# ADAPT toolkit compiler + stdlib, and (b) the @adapt-toolkit Node SDK + a dev
# broker to actually execute packets. Both are external to this repo. This script
# builds a throwaway harness dir, compiles the self-contained test actor against
# THIS repo's core, boots a local broker, and runs the driver.
#
# Override any path via env:
#   ADAPT_TOOLKIT               toolkit root (has build.linux.release/mufl-compile, mufl_stdlib, meta, transactions)
#   OURS_SDK_NODE_MODULES    a node_modules dir containing @adapt-toolkit (e.g. an ours-mcp checkout's)
#   DEV_BROKER                  path to dev-broker.mjs (ships in ours-mcp/scripts)
#   PORT                        broker port (default 9799)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CORE_DIR=$(cd "$HERE/.." && pwd)
AT=${ADAPT_TOOLKIT:-/home/shakhvit/work/adapt/adapt-toolkit}
SDK_NM=${OURS_SDK_NODE_MODULES:-/home/shakhvit/work/adapt/ours/ours-mcp/node_modules}
DEV_BROKER=${DEV_BROKER:-/home/shakhvit/work/adapt/ours/ours-mcp/scripts/dev-broker.mjs}
PORT=${PORT:-9799}
COMPILE="$AT/build.linux.release/mufl-compile"

for p in "$COMPILE" "$AT/mufl_stdlib" "$SDK_NM/@adapt-toolkit" "$DEV_BROKER"; do
  [ -e "$p" ] || { echo "MISSING: $p (set ADAPT_TOOLKIT / OURS_SDK_NODE_MODULES / DEV_BROKER)"; exit 2; }
done

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$BUILD/core"
cp "$CORE_DIR"/*.mm "$CORE_DIR"/config.mufl "$BUILD/core/"
cp "$HERE/test_actor.mu" "$HERE/test.mjs" "$BUILD/"
# SDK 0.6.x (adapt #77) runs ::protocol_container::init_my_ipd on every packet
# during broker registration — the harness needs the same stub the consumers
# ship. Prefer a checkout-local copy; fall back to the ours-mcp one.
PC_STUB=${PROTOCOL_CONTAINER_MM:-/home/shakhvit/work/adapt/ours.network/ours-mcp/packages/core/mufl_code/protocol_container.mm}
[ -e "$PC_STUB" ] || { echo "MISSING: $PC_STUB (set PROTOCOL_CONTAINER_MM)"; exit 2; }
cp "$PC_STUB" "$BUILD/protocol_container.mm"
ln -sfn "$SDK_NM" "$BUILD/node_modules"
# Top-level compile config: merge the stdlib with this repo's core (the core/ subdir).
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
MUFL_STDLIB_PATH="$AT/mufl_stdlib" "$COMPILE" -mp "$AT/meta" -mp "$AT/transactions" test_actor.mu 2>&1 \
  | grep -vE "Unused symbol|browser_attestation|identity_proof_document_impl" | tail -4
ls ./*.muflo >/dev/null 2>&1 || { echo "COMPILE FAILED"; exit 1; }

node "$DEV_BROKER" --host 127.0.0.1 --port "$PORT" --test_mode >broker.log 2>&1 &
BPID=$!
sleep 2.5
kill -0 "$BPID" 2>/dev/null || { echo "BROKER FAILED TO START:"; cat broker.log; exit 3; }

BROKER_URL="ws://127.0.0.1:$PORT" node test.mjs 2> >(grep -E 'inbound rejected|DRIVER ERR' >&2)
RC=$?
kill "$BPID" 2>/dev/null
exit $RC
