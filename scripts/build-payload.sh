#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/scripts/embed-uninstall.py"
VERSION="$(tr -d '[:space:]' <"$ROOT/router/VERSION")"
STAGE="$ROOT/.build/payload"
PAYLOAD="$ROOT/release/g84-zapret2-payload.tar.gz"
MANIFEST="$ROOT/release/manifest.env"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

rm -rf "$ROOT/.build"
mkdir -p "$STAGE/zapret2" "$ROOT/release"

cp "$ROOT"/router/* "$STAGE/zapret2/"
cp "$ROOT/vendor/g84-lock/g84-lock" "$STAGE/zapret2/"
cp "$ROOT/vendor/zapret2-v1.0.4/nfqws2" "$STAGE/zapret2/"
cp "$ROOT/vendor/zapret2-v1.0.4/zapret-lib.lua" "$STAGE/zapret2/"
cp "$ROOT/vendor/zapret2-v1.0.4/zapret-antidpi.lua" "$STAGE/zapret2/"
cp "$ROOT/vendor/zapret2-v1.0.4/zapret-auto.lua" "$STAGE/zapret2/"
chmod 755 "$STAGE/zapret2"/*.sh "$STAGE/zapret2/nfqws2" "$STAGE/zapret2/g84-lock"
chmod 644 "$STAGE/zapret2"/VERSION "$STAGE/zapret2"/config "$STAGE/zapret2"/*.lua
# Normalize timestamps, owners, ordering and modes across macOS/Linux.
python3 "$ROOT/scripts/pack-payload.py" "$STAGE" "$PAYLOAD"

payload_sha="$(sha256_file "$PAYLOAD")"
nfqws_sha="$(sha256_file "$STAGE/zapret2/nfqws2")"
cat >"$MANIFEST" <<EOF
PROJECT_VERSION=$VERSION
UPSTREAM_ZAPRET2_VERSION=1.0.4
PAYLOAD_FILE=g84-zapret2-payload.tar.gz
PAYLOAD_SHA256=$payload_sha
NFQWS_ARCH=linux-mipsel-static
NFQWS_SHA256=$nfqws_sha
G84_LOCK_SHA256=$(sha256_file "$STAGE/zapret2/g84-lock")
EOF

cp "$PAYLOAD" "$ROOT/g84-zapret2-payload.tar.gz"
cp "$MANIFEST" "$ROOT/manifest.env"
installer_sha="$(sha256_file "$ROOT/g84-zapret2.sh")"
printf '%s  %s\n%s  %s\n' \
  "$payload_sha" "g84-zapret2-payload.tar.gz" \
  "$installer_sha" "g84-zapret2.sh" >"$ROOT/release-checksums.txt"
printf 'Built %s\nSHA-256 %s\n' "$PAYLOAD" "$payload_sha"
