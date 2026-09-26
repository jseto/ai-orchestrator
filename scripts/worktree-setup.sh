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

# --- shellcheck: declared dependency of this repository --------------------
# Official koalaman/shellcheck release assets for SHELLCHECK_VERSION. The
# pin and the checksums are the repo's single source of truth for the
# dependency: bump both together (hashes are of the .tar.xz release assets).
SHELLCHECK_VERSION=0.10.0

shellcheck_sha() { # <os.arch> -> sha256 of the official release tarball
  case "$1" in
    linux.x86_64)
      printf '%s\n' '6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87' ;;
    linux.aarch64)
      printf '%s\n' '324a7e89de8fa2aed0d0c28f3dab59cf84c6d74264022c00c22af665ed1a09bb' ;;
    darwin.x86_64)
      printf '%s\n' 'ef27684f23279d112d8ad84e0823642e43f838993bbb8c0963db9b58a90464c2' ;;
    darwin.aarch64)
      printf '%s\n' 'bbd2f14826328eee7679da7221f2bc3afb011f6a928b848c80c321f6046ddf81' ;;
    *) return 1 ;;
  esac
}

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

# --- shellcheck (declared repo dependency; provisioned automatically) ------
# The binary lives in a managed, versioned directory and is symlinked into
# ~/.local/bin, which is on PATH before the stray ~/bin installs agents make
# by hand — so `command -v shellcheck` resolves to the repo-provisioned copy
# in every worktree. The link tells "ours" apart from "the user's": managed
# links are refreshed when the pin changes, anything else is only warned
# about, never overwritten.
SHELLCHECK_SLOT_DIR="$HOME/.local/bin"
SHELLCHECK_SLOT="$SHELLCHECK_SLOT_DIR/shellcheck"
SHELLCHECK_MANAGED="${XDG_DATA_HOME:-$HOME/.local/share}/ai-orchestrator/shellcheck"

shellcheck_version_of() { # <path> -> version string, empty when unreadable
  "$1" --version 2>/dev/null | awk '/^version:/{print $2; exit}'
}

shellcheck_is_managed() { # <path> -> 0 when the slot is our own link
  case "$(readlink "$1" 2>/dev/null)" in
    "$SHELLCHECK_MANAGED"/*) return 0 ;;
    *) return 1 ;;
  esac
}

shellcheck_install() { # download the pinned release and link it into the slot
  local os arch asset url sha tmp src target got
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) fail "shellcheck unsupported operating system $(uname -s)"; return ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) fail "shellcheck unsupported architecture $(uname -m)"; return ;;
  esac
  asset="shellcheck-v$SHELLCHECK_VERSION.$os.$arch.tar.xz"
  url="https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/$asset"
  if ! sha=$(shellcheck_sha "$os.$arch"); then
    fail "shellcheck no pinned checksum for $os.$arch"
    return
  fi
  tmp=$(mktemp -d) || {
    fail "shellcheck mktemp -d"
    return
  }
  log "shellcheck: installing pinned $SHELLCHECK_VERSION -> $SHELLCHECK_SLOT"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp/$asset" "$url" || {
      fail "shellcheck download of $asset"
      rm -rf "$tmp"
      return
    }
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmp/$asset" "$url" || {
      fail "shellcheck download of $asset"
      rm -rf "$tmp"
      return
    }
  else
    fail "shellcheck neither curl nor wget available to download $asset"
    rm -rf "$tmp"
    return
  fi
  printf '%s  %s\n' "$sha" "$tmp/$asset" | sha256sum -c - >/dev/null 2>&1 || {
    fail "shellcheck checksum mismatch for $asset"
    rm -rf "$tmp"
    return
  }
  tar -xJf "$tmp/$asset" -C "$tmp" || {
    fail "shellcheck extract of $asset"
    rm -rf "$tmp"
    return
  }
  src="$tmp/shellcheck-v$SHELLCHECK_VERSION/shellcheck"
  target="$SHELLCHECK_MANAGED/v$SHELLCHECK_VERSION/shellcheck"
  [ -x "$src" ] || {
    fail "shellcheck $asset did not contain an executable"
    rm -rf "$tmp"
    return
  }
  mkdir -p "$SHELLCHECK_SLOT_DIR" "$(dirname "$target")" || {
    fail "shellcheck create install directories"
    rm -rf "$tmp"
    return
  }
  if ! cp -f "$src" "$target" || ! chmod +x "$target" || ! ln -sfn "$target" "$SHELLCHECK_SLOT"; then
    fail "shellcheck install to $SHELLCHECK_SLOT"
    rm -rf "$tmp"
    return
  fi
  rm -rf "$tmp"
  got=$(shellcheck_version_of "$SHELLCHECK_SLOT")
  if [ "$got" != "$SHELLCHECK_VERSION" ]; then
    fail "shellcheck verification failed (reports '${got:-unreadable}', expected $SHELLCHECK_VERSION)"
    return
  fi
  log "shellcheck: provisioned $SHELLCHECK_VERSION at $SHELLCHECK_SLOT"
}

shellcheck_step() {
  local found action=install resolved
  if [ -e "$SHELLCHECK_SLOT" ] || [ -L "$SHELLCHECK_SLOT" ]; then
    found=$(shellcheck_version_of "$SHELLCHECK_SLOT")
    if [ "$found" = "$SHELLCHECK_VERSION" ]; then
      log "shellcheck: already installed at $SHELLCHECK_SLOT (pinned $SHELLCHECK_VERSION) - skipping"
      action=none
    elif shellcheck_is_managed "$SHELLCHECK_SLOT"; then
      log "shellcheck: refreshing managed install at $SHELLCHECK_SLOT (${found:-unreadable} -> $SHELLCHECK_VERSION)"
      action=refresh
    else
      log "shellcheck: found ${found:-unknown version} at $SHELLCHECK_SLOT, pinned is $SHELLCHECK_VERSION - leaving it in place"
      action=none
    fi
  fi
  if [ "$action" != none ]; then
    shellcheck_install
  fi
  # Visibility: a worktree PATH must resolve shellcheck to the slot. A
  # mismatch (foreign directory earlier on PATH) is worth a note, not a fail.
  resolved=$(command -v shellcheck || true)
  if [ "$resolved" != "$SHELLCHECK_SLOT" ]; then
    log "shellcheck: note: PATH resolves shellcheck to ${resolved:-<not found>}, expected $SHELLCHECK_SLOT"
  fi
}

shellcheck_step

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
