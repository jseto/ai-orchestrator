#!/usr/bin/env bash
# treehouse post_create hook: install dependencies in a fresh worktree.
# Runs in the worktree directory (cwd) via [hooks] post_create in
# ~/.config/treehouse/config.toml. One failing step is reported but does not
# skip the rest; treehouse tolerates a non-zero exit (logged, get continues).
set -uo pipefail

log() { printf '[worktree-setup] %s\n' "$*"; }

rc=0
fail() { log "FAILED: $*"; rc=1; }

log "setup in $PWD"

# Install the JS deps only when needed: no node_modules (fresh worktree) or a
# changed dependency manifest. A warm, matching node_modules from a reused
# worktree is left alone — that cache is the point of the pool. Content hashes
# are used instead of directory mtimes, which are unreliable across copies.
js_fingerprint() {
  local manifest=$1
  {
    sha256sum "$manifest"
    [ -f package.json ] && sha256sum package.json
  } 2>/dev/null | sha256sum | awk '{print $1}'
}

# $1 = lockfile/manifest, rest = command words
js_install() {
  local lock=$1
  local marker="node_modules/.treehouse-deps.sha256"
  local expected
  shift
  expected=$(js_fingerprint "$lock")
  if [ -d node_modules ] && [ -f "$marker" ] && [ "$(cat "$marker")" = "$expected" ]; then
    log "$lock: node_modules match manifests - skipping"
    return 0
  fi
  if [ -d node_modules ]; then
    log "$lock/package.json changed - refreshing node_modules -> $*"
  else
    log "$lock: no node_modules -> $*"
  fi
  if "$@"; then
    mkdir -p node_modules
    printf '%s\n' "$expected" > "$marker"
    return 0
  fi
  log "FAILED: $*"
  return 1
}

# Retry a package-manager command without the warm-cache guard. This is used
# after a strict lockfile mode fails; that failure may have created a partial
# node_modules directory, which must not make the fallback look "warm".
js_install_retry() {
  local lock=$1
  local marker="node_modules/.treehouse-deps.sha256"
  local expected
  shift
  expected=$(js_fingerprint "$lock")
  log "retrying dependency install -> $*"
  if "$@"; then
    mkdir -p node_modules
    printf '%s\n' "$expected" > "$marker"
    return 0
  fi
  return 1
}

# --- JS package managers, chosen by lockfile -------------------------------
if [ -f pnpm-lock.yaml ]; then
  js_install pnpm-lock.yaml pnpm install --frozen-lockfile \
    || js_install_retry pnpm-lock.yaml pnpm install \
    || fail "pnpm install"
elif [ -f yarn.lock ]; then
  js_install yarn.lock yarn install --immutable \
    || js_install_retry yarn.lock yarn install \
    || fail "yarn install"
elif [ -f bun.lock ] || [ -f bun.lockb ]; then
  bun_lock=bun.lock
  [ -f bun.lockb ] && bun_lock=bun.lockb
  js_install "$bun_lock" bun install || fail "bun install"
elif [ -f package-lock.json ]; then
  js_install package-lock.json npm ci \
    || js_install_retry package-lock.json npm install \
    || fail "npm ci/install"
elif [ -f package.json ]; then
  js_install package.json npm install || fail "npm install"
fi

# --- dart / flutter --------------------------------------------------------
if [ -f pubspec.yaml ]; then
  if command -v flutter >/dev/null 2>&1; then
    log "pubspec.yaml -> flutter pub get"
    flutter pub get || fail "flutter pub get"
  elif command -v dart >/dev/null 2>&1; then
    log "pubspec.yaml -> dart pub get"
    dart pub get || fail "dart pub get"
  else
    log "pubspec.yaml present but no flutter/dart on PATH - skipped"
  fi
fi

# --- rust / go (fetch only; cheap and non-destructive) ---------------------
if [ -f Cargo.toml ] && command -v cargo >/dev/null 2>&1; then
  log "Cargo.toml -> cargo fetch"
  cargo fetch || fail "cargo fetch"
fi
if [ -f go.mod ] && command -v go >/dev/null 2>&1; then
  log "go.mod -> go mod download"
  go mod download || fail "go mod download"
fi

if [ "$rc" = 0 ]; then
  log "done (nothing to install or all steps OK)"
fi
exit "$rc"
