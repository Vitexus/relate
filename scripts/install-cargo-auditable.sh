#!/usr/bin/env bash
# Install the pinned cargo-auditable release that .github/workflows/release.yml
# builds shipped Rust binaries through: `cargo auditable build` embeds the
# Zlib-compressed dependency list in the `.dep-v0` linker section of every
# built artifact, so a shipped binary answers `cargo audit bin` (and trivy,
# grype, syft, osv-scanner, wasm-tools) with its exact crate versions.
#
# Version and SHA-256 follow the repo's tarball-plus-sha256 pattern
# (ADR-0258, the install-opencode.sh / install-binaryen.sh shape): the digest
# pins the artifact content, so a swapped or corrupted asset at the download
# endpoint fails the check before anything runs on the runner. Bump VERSION
# and the four per-target SHA256 values here together, from the release's
# published checksum sidecars.
#
# Usage: scripts/install-cargo-auditable.sh DIR
#   Unpacks the cargo-auditable binary into DIR and prints DIR. In GitHub
#   Actions, append the printed line to $GITHUB_PATH:
#     bash scripts/install-cargo-auditable.sh "$RUNNER_TEMP/cargo-auditable" >> "$GITHUB_PATH"
#
# x86_64 Linux, x86_64/aarch64 macOS, and x64 Windows (through git-bash —
# the windows runners' bash; the zip is extracted with Expand-Archive
# because Git for Windows ships no unzip).
set -euo pipefail

VERSION=0.7.7

if [[ $# -ne 1 || "$1" == -h || "$1" == --help ]]; then
  echo "usage: $0 DIR" >&2
  exit 2
fi
DIR="$1"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64 | Linux-amd64)
    target=x86_64-unknown-linux-gnu
    SHA256=4c8d3b08c3c34e9f2333367224dbbfb4aab68067698b43de59fe19aded3416dd
    ;;
  Darwin-x86_64)
    target=x86_64-apple-darwin
    SHA256=4b87f06ea13d32466bbc68b1f5715ac11753a052d9935245380bddce8a3f0e50
    ;;
  Darwin-arm64)
    target=aarch64-apple-darwin
    SHA256=a66ad6392861ca1abfe0b02b522622d91edf63e5d7b60f4d3088b5c23d240c72
    ;;
  MINGW*-x86_64 | MSYS*-x86_64 | CYGWIN*-x86_64)
    target=x86_64-pc-windows-msvc
    SHA256=717ba2d3ed7997c501e9987ee7c94bebf9d7219b18b185a03009420ec7029c7d
    ;;
  *)
    echo "install-cargo-auditable.sh: unsupported host $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

# Digest helper: sha256sum where coreutils is present (Linux, git-bash),
# shasum otherwise (macOS ships no sha256sum). Same policy either way — a
# mismatch fails the install below.
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR"

if [[ "$target" == x86_64-pc-windows-msvc ]]; then
  ARCHIVE="cargo-auditable-$target.zip"
  sh "$here/github-download.sh" \
    --repo rust-secure-code/cargo-auditable \
    --tag "v$VERSION" \
    --asset "$ARCHIVE" \
    -o "$DIR/$ARCHIVE"
  if [[ "$(file_sha256 "$DIR/$ARCHIVE")" != "$SHA256" ]]; then
    echo "install-cargo-auditable.sh: sha256 mismatch for $ARCHIVE (want $SHA256)" >&2
    exit 1
  fi
  # The zip unpacks flat (cargo-auditable.exe at the archive root).
  powershell -NoLogo -NonInteractive -Command \
    "Expand-Archive -LiteralPath '$(cygpath -w "$DIR/$ARCHIVE")' -DestinationPath '$(cygpath -w "$DIR")' -Force" >&2
  rm "$DIR/$ARCHIVE"
  BIN="cargo-auditable.exe"
  # Print the Windows form of DIR: cargo.exe resolves subcommands through
  # the PATH it inherits, and MSYS paths (/d/a/...) are invisible to it.
  OUT="$(cygpath -w "$DIR")"
else
  ARCHIVE="cargo-auditable-$target.tar.xz"
  sh "$here/github-download.sh" \
    --repo rust-secure-code/cargo-auditable \
    --tag "v$VERSION" \
    --asset "$ARCHIVE" \
    -o "$DIR/$ARCHIVE"
  if [[ "$(file_sha256 "$DIR/$ARCHIVE")" != "$SHA256" ]]; then
    echo "install-cargo-auditable.sh: sha256 mismatch for $ARCHIVE (want $SHA256)" >&2
    exit 1
  fi
  # The tarball unpacks a cargo-auditable-<target>/ directory; the binary
  # goes straight into DIR.
  tar --no-same-owner -xJf "$DIR/$ARCHIVE" -C "$DIR" --strip-components=1 >&2
  rm "$DIR/$ARCHIVE"
  BIN="cargo-auditable"
  OUT="$DIR"
fi

[[ -f "$DIR/$BIN" ]] || {
  echo "install-cargo-auditable.sh: $BIN missing after unpack" >&2
  exit 1
}

# The wrapper refuses direct invocation ('should be invoked through Cargo');
# `cargo auditable --version` proves the binary runs and cargo finds it.
PATH="$DIR:$PATH" cargo auditable --version >&2
echo "$OUT"
