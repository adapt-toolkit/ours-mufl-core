#!/usr/bin/env bash
# Sealed-backup + words-only key-through-init restore gate: compile the test
# actor against THIS core, boot ONE broker, run backup.mjs phase1 (live
# packets + backup, then process exit = the "restart") and phase2 (fresh
# process: throwaway unseal → same-cid recreation → sealed restore).
# Same env knobs as run.sh: ADAPT_TOOLKIT / OURS_SDK_NODE_MODULES / DEV_BROKER / PORT.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CORE_DIR=$(cd "$HERE/.." && pwd)
AT=${ADAPT_TOOLKIT:-/home/shakhvit/work/adapt/adapt-toolkit}
SDK_NM=${OURS_SDK_NODE_MODULES:-/home/shakhvit/work/adapt/ours/ours-mcp/node_modules}
DEV_BROKER=${DEV_BROKER:-/home/shakhvit/work/adapt/ours/ours-mcp/scripts/dev-broker.mjs}
PORT=${PORT:-9797}
COMPILE="$AT/build.linux.release/mufl-compile"

for p in "$COMPILE" "$AT/mufl_stdlib" "$SDK_NM/@adapt-toolkit" "$DEV_BROKER"; do
  [ -e "$p" ] || { echo "MISSING: $p (set ADAPT_TOOLKIT / OURS_SDK_NODE_MODULES / DEV_BROKER)"; exit 2; }
done

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$BUILD/core"
cp "$CORE_DIR"/*.mm "$CORE_DIR"/config.mufl "$BUILD/core/"
cp "$HERE/test_actor.mu" "$HERE/backup.mjs" "$HERE/protocol_container.mm" "$BUILD/"
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
MUFL_STDLIB_PATH="$AT/mufl_stdlib" "$COMPILE" -mp "$AT/meta" -mp "$AT/transactions" test_actor.mu 2>&1 \
  | grep -vE "Unused symbol|browser_attestation|identity_proof_document_impl" | tail -4
ls ./*.muflo >/dev/null 2>&1 || { echo "COMPILE FAILED"; exit 1; }

node "$DEV_BROKER" --host 127.0.0.1 --port "$PORT" --test_mode >broker.log 2>&1 &
BPID=$!
sleep 2.5
kill -0 "$BPID" 2>/dev/null || { echo "BROKER FAILED TO START:"; cat broker.log; exit 3; }

export BK_STATE="$BUILD/bk-state.json"
BROKER_URL="ws://127.0.0.1:$PORT" node backup.mjs phase1 2> >(grep -E 'DRIVER ERR|words:' >&2)
RC1=$?
if [ $RC1 -eq 0 ]; then
  BROKER_URL="ws://127.0.0.1:$PORT" node backup.mjs phase2 2> >(grep -E 'DRIVER ERR' >&2)
  RC2=$?
else
  RC2=1
fi
kill "$BPID" 2>/dev/null
[ $RC1 -eq 0 ] && [ $RC2 -eq 0 ] && exit 0 || exit 1
