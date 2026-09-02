#!/usr/bin/env bash
set -euo pipefail

# Asserts that the toolchain versions pinned in the Dockerfile match the crate
# versions they have to match, under the same `set -euo pipefail` everything
# else runs with.
#
# **Why this exists.** The Dockerfile installs `wasm-bindgen-cli` at a literal
# version which must equal the `wasm-bindgen` crate in `Cargo.lock`, and
# `dioxus-cli` at one which must match `crates/ui`'s `dioxus` dependency. Its
# own comment says why: a mismatched dx/wasm-bindgen version is a known source
# of wasm build failures here, and it fails confusingly rather than cleanly.
#
# Nothing checked that they agreed. Moving to dioxus 0.7 (#290) needed
# wasm-bindgen 0.2.127 while the Dockerfile still said 0.2.103, and the only
# reason that was caught is that somebody read both files on the same morning.
#
# `setup-dev-environment.sh` reads the wasm-bindgen version out of the lock
# rather than repeating it, which is the right shape. The Dockerfile cannot:
# `Cargo.lock` is not in the build context at the layer that installs the
# tools, and moving the COPY earlier would break the caching that makes the
# layer worth having. So the version is repeated, and this checks the copies.

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$HERE"
failures=0

check() {
  local what="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    printf '  ok   %s (%s)\n' "$what" "$got"
  else
    printf '  FAIL %s\n       %s says: %s\n' "$what" "$4" "$got"
    printf '       should be:   %s\n' "$want"
    failures=$((failures + 1))
  fi
}

# The wasm-bindgen crate the build will link against.
LOCK_WASM_BINDGEN="$(awk '/^name = "wasm-bindgen"$/{getline; gsub(/version = |"/, ""); print; exit}' Cargo.lock)"
DOCKER_WASM_BINDGEN="$(grep -oP 'wasm-bindgen-cli --version \K[0-9.]+' Dockerfile || true)"
check "wasm-bindgen-cli matches the wasm-bindgen crate" \
  "$LOCK_WASM_BINDGEN" "$DOCKER_WASM_BINDGEN" "Dockerfile"

# **Exactly**, not to minor. `dx` compares its own version against the resolved
# `dioxus` crate and refuses outright:
#
#     ERROR dx and dioxus versions are incompatible!
#           • dx version: 0.7.10
#           • dioxus versions: [0.7.5]
#
# This check said "to minor" until 2026-09-02, passed, and `dx build` failed
# anyway — the looser rule was written from what seemed reasonable rather than
# from what dx does. So it reads the *lock*, which is what dx reads, not the
# dependency range in Cargo.toml.
LOCK_DIOXUS="$(awk '/^name = "dioxus"$/{getline; gsub(/version = |"/, ""); print; exit}' Cargo.lock)"
DOCKER_DX_FULL="$(grep -oP 'dioxus-cli --version \K[0-9.]+' Dockerfile || true)"
check "dioxus-cli matches the resolved dioxus exactly" \
  "$LOCK_DIOXUS" "$DOCKER_DX_FULL" "Dockerfile"

# The dev machine and the image must install the same dx, or a bundle that
# builds in one fails in the other — which is the confusing half of the failure.
SETUP_DX="$(grep -oP 'DIOXUS_VERSION="\K[0-9.]+' scripts/setup-dev-environment.sh || true)"
check "the dev machine installs the same dx as the image" \
  "$DOCKER_DX_FULL" "$SETUP_DX" "setup-dev-environment.sh"

# docs/3.1 tells a person what to expect from `dx --version`, and a stale
# number there sends somebody to reinstall a version that is already right.
DOCS_DX="$(grep -oP 'dx --version.*should include \K[0-9.]+' docs/3.1-setup.md || true)"
check "docs/3.1 names the dx version the setup installs" \
  "$SETUP_DX" "$DOCS_DX" "docs/3.1-setup.md"

if (( failures )); then
  echo "  $failures pin(s) disagree"
  exit 1
fi
echo "  all toolchain pins agree"
