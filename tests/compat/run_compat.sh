#!/usr/bin/env bash
# Cross-version compat matrix: build TWO units — OLD core (git ref, old toolkit) and NEW
# core (this working tree, current toolkit) — each in its own build dir with its own
# node_modules symlink, boot ONE broker, run tests/compat/compat.mjs against the pair.
# See tests/compat/README.md for the env contract and leg inventory.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CORE_DIR=$(cd "$HERE/../.." && pwd)

OLD_CORE_REF=${OLD_CORE_REF:-v0.2.0}
OLD_AT=${OLD_ADAPT_TOOLKIT:?set OLD_ADAPT_TOOLKIT (toolkit era matching the OLD core)}
OLD_SDK_NM=${OLD_SDK_NM:?set OLD_SDK_NM (node_modules with the OLD-era @adapt-toolkit sdk)}
AT=${ADAPT_TOOLKIT:?set ADAPT_TOOLKIT (current toolkit checkout)}
SDK_NM=${OURS_SDK_NODE_MODULES:?set OURS_SDK_NODE_MODULES (current sdk node_modules)}
DEV_BROKER=${DEV_BROKER:?set DEV_BROKER (dev-broker.mjs launcher)}
PORT=${PORT:-9797}

for p in "$OLD_AT/build.linux.release/mufl-compile" "$OLD_SDK_NM/@adapt-toolkit" \
         "$AT/build.linux.release/mufl-compile" "$SDK_NM/@adapt-toolkit" "$DEV_BROKER"; do
  [ -e "$p" ] || { echo "MISSING: $p"; exit 2; }
done

WORK=$(mktemp -d); trap 'rm -rf "$WORK"; [ -n "${BROKER_PID:-}" ] && kill "$BROKER_PID" 2>/dev/null' EXIT

# build_unit <outdir> <core_src_dir> <toolkit> <sdk_nm>
# Uses the era's OWN tests/test_actor.mu + protocol_container.mm (the actor surface
# matches its core), same compile shape as tests/run.sh.
build_unit() {
  local out=$1 src=$2 tk=$3 nm=$4
  mkdir -p "$out/core"
  cp "$src"/*.mm "$out/core/"; cp "$src/config.mufl" "$out/core/" 2>/dev/null || true
  cp "$src/tests/test_actor.mu" "$out/actor.mu"
  cp "$src/tests/protocol_container.mm" "$out/" 2>/dev/null || cp "$CORE_DIR/tests/protocol_container.mm" "$out/"
  ln -sfn "$nm" "$out/node_modules"
  cp "$HERE/compat_peer.mjs" "$out/"
  cat > "$out/config.mufl" <<'CFG'
config script
{
    stdlib_config = (config_load #$MUFL_STDLIB_PATH).
    core_config = (config_load #"core").
    (
        $imports ->
        (
            $libraries -> (stdlib_config $exports $libraries)'(core_config $exports $libraries)'($protocol_container -> #"protocol_container.mm"),
        ),
        $exports -> ( $libraries -> (,), $applications -> (,) )
    ).
}
CFG
  ( cd "$out" && MUFL_STDLIB_PATH="$tk/mufl_stdlib" "$tk/build.linux.release/mufl-compile" \
      -mp "$tk/meta" -mp "$tk/transactions" -d-c actor.mu ) \
    || { echo "COMPILE FAILED in $out"; exit 3; }
}

echo "== building OLD unit ($OLD_CORE_REF, $(basename "$OLD_AT")) =="
OLD_SRC="$WORK/old-src"; mkdir -p "$OLD_SRC"
git -C "$CORE_DIR" archive "$OLD_CORE_REF" | tar -x -C "$OLD_SRC"
build_unit "$WORK/old" "$OLD_SRC" "$OLD_AT" "$OLD_SDK_NM"

echo "== building NEW unit (working tree, $(basename "$AT")) =="
build_unit "$WORK/new" "$CORE_DIR" "$AT" "$SDK_NM"

echo "== broker on :$PORT =="
node "$DEV_BROKER" --port "$PORT" & BROKER_PID=$!
sleep 1

BROKER_URL="ws://127.0.0.1:$PORT" OLD_BUILD_DIR="$WORK/old" NEW_BUILD_DIR="$WORK/new" \
  node "$HERE/compat.mjs"
