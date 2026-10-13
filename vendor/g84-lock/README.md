# g84-lock

Project-owned helper; source: `native/g84-lock.c`, MIT license (repository LICENSE).
The checked-in executable is static Linux MIPS32r2 little-endian with soft-float,
compiled with Zig 0.13.0 and musl. musl attribution: `MUSL-COPYRIGHT`.

Build from the repository root:

```bash
ZIG=/path/to/zig ./scripts/build-lock.sh
./scripts/build-payload.sh
```

The helper holds `flock(LOCK_EX)` on a permanent file descriptor, then directly
executes the command without closing the descriptor. Do not unlink the lock
file. The kernel releases the lock when the last descriptor closes, including
after crashes. Exit codes: 64 usage, 73 open, 74 locking/system error, 75 timeout,
126 exec failure; otherwise the executed command supplies the exit status.

CI tests the C source with a native compiler (contention, timeout, SIGKILL) and
executes the bundled MIPS binary in QEMU. Hardware compatibility is checked
separately before the installer stops existing services.
