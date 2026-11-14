#!/usr/bin/env bash
# Install the pinned cargo-deny release into the cargo bin directory.
#
# The scheduled advisory scan (.github/workflows/cargo-deny.yml) runs
# `cargo deny check advisories` against the repo-root Cargo.lock. The
# tarball and its .sha256 sidecar come from the EmbarkStudios release
# assets through scripts/github-download.sh (never an anonymous
# releases/download GET), and the checksum is verified before the binary
# is unpacked or installed.
#
# cargo-deny tags carry no `v` prefix: the 0.20.2 release is tag `0.20.2`.
set -euo pipefail

VERSION=0.20.2
here="$(cd "$(dirname "$0")" && pwd)"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64|Linux-amd64) triple=x86_64-unknown-linux-musl ;;
  Linux-aarch64|Linux-arm64) triple=aarch64-unknown-linux-musl ;;
  Darwin-x86_64) triple=x86_64-apple-darwin ;;
  Darwin-arm64|Darwin-aarch64) triple=aarch64-apple-darwin ;;
  MINGW*-x86_64|MSYS*-x86_64|CYGWIN*-x86_64) triple=x86_64-pc-windows-msvc ;;
  *) echo "install-cargo-deny: unsupported platform $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

asset="cargo-deny-${VERSION}-${triple}.tar.gz"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sh "$here/github-download.sh" \
  --repo EmbarkStudios/cargo-deny \
  --tag "${VERSION}" \
  --asset "$asset" \
  -o "$work/$asset"
sh "$here/github-download.sh" \
  --repo EmbarkStudios/cargo-deny \
  --tag "${VERSION}" \
  --asset "${asset}.sha256" \
  -o "$work/cargo-deny.sha256"

expected="$(awk '{print $1; exit}' "$work/cargo-deny.sha256")"
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$work/$asset" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "$work/$asset" | awk '{print $1}')"
fi
if [[ -z "$expected" || "$expected" != "$actual" ]]; then
  echo "install-cargo-deny: checksum mismatch for ${asset}" >&2
  exit 1
fi

tar --no-same-owner -xzf "$work/$asset" -C "$work"
bin="$(find "$work" -type f -name 'cargo-deny*' | head -n 1)"
if [[ -z "$bin" ]]; then
  echo "install-cargo-deny: archive did not contain cargo-deny" >&2
  exit 1
fi
bindir="${CARGO_HOME:-$HOME/.cargo}/bin"
mkdir -p "$bindir"
install -m 0755 "$bin" "$bindir/$(basename "$bin")"
echo "cargo-deny ${VERSION}"
