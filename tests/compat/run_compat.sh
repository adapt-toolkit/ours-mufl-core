#!/usr/bin/env bash
# Cross-version compat matrix: build TWO units — OLD core (git ref, OLD-era toolchain) and
# NEW core (this working tree, current toolchain) — each in its own build dir with its own
# node_modules symlink, boot ONE broker, run tests/compat/compat.mjs against the pair.
# See tests/compat/README.md for the env contract and leg inventory.
#
# Toolchain dirs auto-detect flavor (owner ruling: the OLD side should be the PUBLISHED
# @adapt-toolkit packages production actually pinned, not a from-scratch build):
#   - npm @adapt-toolkit/mufl package root  → prebuilds/linux-x64/mufl-compile
#   - adapt toolkit checkout                → build.<platform>.release/mufl-compile
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CORE_DIR=$(cd "$HERE/../.." && pwd)

OLD_CORE_REF=${OLD_CORE_REF:-v0.2.0}
OLD_TOOLCHAIN=${OLD_TOOLCHAIN:?set OLD_TOOLCHAIN (npm @adapt-toolkit/mufl pkg root of the OLD era, e.g. <stage>/node_modules/@adapt-toolkit/mufl — or an old toolkit checkout)}
OLD_SDK_NM=${OLD_SDK_NM:?set OLD_SDK_NM (node_modules with the OLD-era @adapt-toolkit sdk, e.g. sdk@0.9.1)}
NEW_TOOLCHAIN=${NEW_TOOLCHAIN:-${ADAPT_TOOLKIT:-}}
[ -n "$NEW_TOOLCHAIN" ] || { echo "set NEW_TOOLCHAIN (current @adapt-toolkit/mufl pkg root or toolkit checkout)"; exit 2; }
SDK_NM=${OURS_SDK_NODE_MODULES:?set OURS_SDK_NODE_MODULES (current sdk node_modules)}
DEV_BROKER=${DEV_BROKER:?set DEV_BROKER (dev-broker.mjs launcher)}
PORT=${PORT:-9797}

# resolve_toolchain <dir> → sets RESOLVED_COMPILE / RESOLVED_ROOT
resolve_toolchain() {
  local dir=$1 platform
  platform="$(uname | tr '[:upper:]' '[:lower:]')"
  for cand in "$dir/prebuilds/linux-x64/mufl-compile" \
              "$dir/build/mufl-compile" \
              "$dir/build.$platform.release/mufl-compile"; do
    if [ -x "$cand" ]; then RESOLVED_COMPILE="$cand"; RESOLVED_ROOT="$dir"; return 0; fi
  done
  echo "MISSING: no mufl-compile under $dir"; exit 2
}

for p in "$OLD_SDK_NM/@adapt-toolkit" "$SDK_NM/@adapt-toolkit" "$DEV_BROKER"; do
  [ -e "$p" ] || { echo "MISSING: $p"; exit 2; }
done

WORK=$(mktemp -d); echo "WORK=$WORK (kept for post-mortem when KEEP_WORK=1)"; if [ "${KEEP_WORK:-0}" = "1" ]; then trap '[ -n "${BROKER_PID:-}" ] && kill "$BROKER_PID" 2>/dev/null' EXIT; else trap 'rm -rf "$WORK"; [ -n "${BROKER_PID:-}" ] && kill "$BROKER_PID" 2>/dev/null' EXIT; fi

# build_unit <outdir> <core_src_dir> <toolchain_dir> <sdk_nm>
# Uses the era's OWN tests/test_actor.mu + protocol_container.mm (the actor surface
# matches its core), same compile shape as tests/run.sh / consumer compile-mufl.sh.
build_unit() {
  local out=$1 src=$2 tk=$3 nm=$4
  resolve_toolchain "$tk"
  mkdir -p "$out/core"
  cp "$src"/*.mm "$out/core/"; cp "$src/config.mufl" "$out/core/" 2>/dev/null || true
  cp "$src/tests/test_actor.mu" "$out/actor.mu"
  # Cross-process peers must REGISTER with the broker (single-wrapper suites
  # deliver locally and never need this): inject registration_proof, which the
  # real consumer actors (messenger.mu, tg actor.mu) load explicitly and the
  # core test actors deliberately omit. Without it, registration-message
  # creation fails client-side and no traffic ever crosses the broker.
  sed -i '0,/loads libraries/s//loads libraries\n    registration_proof,/' "$out/actor.mu"
  if [ -f "$src/tests/protocol_container.mm" ]; then cp "$src/tests/protocol_container.mm" "$out/"
  else cp "$CORE_DIR/tests/protocol_container.mm" "$out/"; fi
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
  ( cd "$out" && MUFL_STDLIB_PATH="$RESOLVED_ROOT/mufl_stdlib" "$RESOLVED_COMPILE" \
      -mp "$RESOLVED_ROOT/meta" -mp "$RESOLVED_ROOT/transactions" -d-c actor.mu >/dev/null ) \
    || { echo "COMPILE FAILED in $out"; exit 3; }
}

echo "== building OLD unit ($OLD_CORE_REF, $(basename "$OLD_TOOLCHAIN")) =="
OLD_SRC="$WORK/old-src"; mkdir -p "$OLD_SRC"
git -C "$CORE_DIR" archive "$OLD_CORE_REF" | tar -x -C "$OLD_SRC"
build_unit "$WORK/old" "$OLD_SRC" "$OLD_TOOLCHAIN" "$OLD_SDK_NM"

echo "== building NEW unit (working tree, $(basename "$NEW_TOOLCHAIN")) =="
build_unit "$WORK/new" "$CORE_DIR" "$NEW_TOOLCHAIN" "$SDK_NM"

echo "== broker on :$PORT =="
# dev-broker contract: --host/--port REQUIRED, --test_mode skips attestation. Runs under
# the NEW sdk (cwd with the current node_modules) — the broker relays opaque frames, so
# one broker serves both eras.
( cd "$WORK/new" && node "$DEV_BROKER" --host 127.0.0.1 --port "$PORT" --test_mode ) & BROKER_PID=$!
sleep 2

BROKER_URL="ws://127.0.0.1:$PORT" OLD_BUILD_DIR="$WORK/old" NEW_BUILD_DIR="$WORK/new" \
  node "$HERE/compat.mjs"
