#!/usr/bin/env bash
# a2a_notifications N-series gate: compile the notif test actor (loads BOTH
# a2a_messaging AND a2a_notifications) against THIS core, boot a local broker, and
# run tests/notif.mjs. Split from run.sh because notif_actor.mu is its own compiled
# unit (test_actor.mu dropped a2a_notifications to stay under the per-unit
# meta-reduction fuel ceiling). Same env knobs as run.sh:
# ADAPT_TOOLKIT / OURS_SDK_NODE_MODULES / DEV_BROKER / PORT.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CORE_DIR=$(cd "$HERE/.." && pwd)
AT=${ADAPT_TOOLKIT:-/home/shakhvit/work/adapt/adapt-toolkit}
STDLIB=${MUFL_STDLIB_OVERRIDE:-$AT/mufl_stdlib}   # Phase-B: point at the adapt worktree stdlib to pick up e2e.mm staged API
SDK_NM=${OURS_SDK_NODE_MODULES:-/home/shakhvit/work/adapt/ours/ours-mcp/node_modules}
DEV_BROKER=${DEV_BROKER:-/home/shakhvit/work/adapt/ours/ours-mcp/scripts/dev-broker.mjs}
PORT=${PORT:-9798}
COMPILE=${MUFL_COMPILE_OVERRIDE:-$AT/build.linux.release/mufl-compile}
META=${MUFL_META_OVERRIDE:-$AT/meta}
TRANSACTIONS=${MUFL_TRANSACTIONS_OVERRIDE:-$AT/transactions}

for p in "$COMPILE" "$STDLIB" "$META" "$TRANSACTIONS" "$SDK_NM/@adapt-toolkit" "$DEV_BROKER"; do
  [ -e "$p" ] || { echo "MISSING: $p (set ADAPT_TOOLKIT / OURS_SDK_NODE_MODULES / DEV_BROKER)"; exit 2; }
done

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$BUILD/core"
cp "$CORE_DIR"/*.mm "$CORE_DIR"/config.mufl "$BUILD/core/"
# notif.mjs imports ./test_common.mjs, so copy it alongside into the build dir.
cp "$HERE/notif_actor.mu" "$HERE/notif.mjs" "$HERE/test_common.mjs" "$HERE/protocol_container.mm" "$BUILD/"
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
echo "compiling notif test actor against $CORE_DIR core…"
MUFL_STDLIB_PATH="$STDLIB" "$COMPILE" -mp "$META" -mp "$TRANSACTIONS" notif_actor.mu 2>&1 \
  | grep -vE "Unused symbol|browser_attestation|identity_proof_document_impl" | tail -4
ls ./*.muflo >/dev/null 2>&1 || { echo "COMPILE FAILED"; exit 1; }

node "$DEV_BROKER" --host 127.0.0.1 --port "$PORT" --test_mode >broker.log 2>&1 &
BPID=$!
sleep 2.5
kill -0 "$BPID" 2>/dev/null || { echo "BROKER FAILED TO START:"; cat broker.log; exit 3; }

BROKER_URL="ws://127.0.0.1:$PORT" node notif.mjs 2> >(grep -E 'inbound rejected|DRIVER ERR' >&2)
RC=$?
kill "$BPID" 2>/dev/null
exit $RC
