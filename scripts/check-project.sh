#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

for file in "$ROOT/g84-zapret2.sh" "$ROOT"/scripts/*.sh; do
  bash -n "$file"
done
for file in "$ROOT"/router/*.sh; do
  sh -n "$file"
done

"$ROOT/scripts/build-payload.sh" >/dev/null
source "$ROOT/manifest.env"
actual="$(sha256_file "$ROOT/$PAYLOAD_FILE")"
[[ "$actual" == "$PAYLOAD_SHA256" ]]
[[ "$(tr -d '[:space:]' <"$ROOT/router/VERSION")" == "$PROJECT_VERSION" ]]
archive_list="$(tar -tzf "$ROOT/$PAYLOAD_FILE")"
grep -q '^zapret2/nfqws2$' <<<"$archive_list"
grep -q '^zapret2/VERSION$' <<<"$archive_list"

if rg -n 'gh[pousr]_[A-Za-z0-9_]{20,}|BEGIN [A-Z ]*PRIVATE KEY' "$ROOT" \
  -g '!vendor/**' -g '!.git/**' -g '!release/**'; then
  echo 'Potential secret found' >&2
  exit 1
fi

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$ROOT/g84-zapret2.sh" "$ROOT"/scripts/*.sh
fi

echo 'Project checks passed.'
