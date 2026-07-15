#!/usr/bin/env bash
# Language-semantics pins for the versioned type registry (PLAN Step 4.3 / SPEC Q3-residual).
#
# The registry's safety rests on mufl behaviors that are pinned by tests, not yet by written
# language docs: safe-cast tolerates+strips extra record fields, disjunction casts pick
# alternatives in CANONICAL (not declaration) order and rebuild the result, and the
# dispatch-then-exact-cast pattern (t11) works across three wire versions. If the vendored
# toolchain ever regresses any of these, this runner fails BEFORE the behavioral suite runs.
#
#   MUFL_PKG  path to the vendored @adapt-toolkit/mufl package (default: ours-mcp's)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MUFL_PKG=${MUFL_PKG:-/home/fleet/ours.network/ours-mcp/node_modules/@adapt-toolkit/mufl}
RUN="node $MUFL_PKG/bin/mufl.js run"
fail=0

check () { # file, expected-grep...
  local f=$1; shift
  local out
  out=$(cd "$HERE" && $RUN "$f" 2>&1)
  for want in "$@"; do
    if ! grep -qF "$want" <<<"$out"; then
      echo "✗ $f: missing expected line: $want"
      echo "$out" | sed 's/^/    /'
      fail=1
      return
    fi
  done
  echo "✓ $f"
}

# safe cast: extra fields tolerated, STRIPPED from the rebuilt result (never abort).
check t2_extra_fields.mufl \
  "w \$c = %%NIL" \
  "same value_id: %%FALSE"

# runtime paths: stripping identical at runtime; disjunction picks by CANONICAL order
# under BOTH declaration orders (version-specific fields survive either way here, which
# is exactly why a cast-to-union must never be the version selector — REG-4).
check t7_runtime.mufl \
  "runtime extra-field: stripped" \
  "runtime old-first:   name kept" \
  "runtime new-first:   name kept"

# disjunction cast REBUILDS (new value id) and strips fields unknown to all alternatives.
check t9_passthrough.mufl \
  "disjunction cast: rebuilt" \
  "unknown extra across union: future field LOST"

# the full registry pattern: three wire versions in, three branches taken.
check t11_three_version.mufl \
  "v0.2 way: fallback name from sender cid" \
  "v0.3 way: name=Bob" \
  "v0.5 way: name=Carol pv=5"

# string '<' is a STRICT TOTAL ORDER — the invariant the 0.9.0 migration election
# (str_lt / mig_initiator) depends on; a regression here would split-brain the election.
check t_str_order.mufl \
  "irreflexive: F" \
  "lt: T" \
  "antisym: F" \
  "prefix1: T" \
  "prefix2: T" \
  "hexlt: T" \
  "hexeq: F" \
  "hexgt: F"

[ $fail -eq 0 ] && echo "SEMANTICS PINS: ALL GREEN" || echo "SEMANTICS PINS: FAILURES"
exit $fail
