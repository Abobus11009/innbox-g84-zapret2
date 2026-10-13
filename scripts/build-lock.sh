#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
: "${ZIG:=zig}"
mkdir -p "$ROOT/vendor/g84-lock"
"$ZIG" cc -target mipsel-linux-musl -mcpu=mips32r2 -msoft-float \
  -static -Os -s -Wall -Wextra -Werror \
  "$ROOT/native/g84-lock.c" -o "$ROOT/vendor/g84-lock/g84-lock"
echo 'Built static MIPS32r2 little-endian g84-lock'
