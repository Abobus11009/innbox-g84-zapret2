# Roadmap and reviewed suggestions

## Implemented in 0.2.0

- dynamic, owned `appmgr` slots and `appmgr-slots` record;
- staging plus temporary `zapret2.old` directory rollback;
- automatic post-reboot SSH wait and `verify`;
- payload SHA-256, version and release manifest;
- MIPSEL/static binary provenance and upstream tag;
- reversible IPv4/IPv6 NFQUEUE preflight;
- WAN autodetection plus `--wan` override;
- PID-scoped stop instead of global `killall`;
- idempotent start/stop/rules and stale-lock recovery;
- free-space check, private backups, pruning and logs;
- `--dry-run`, `verify`, extended diagnose/status;
- hardware NAT visibility without automatic disabling;
- recovery and compatibility documentation;
- local validation and GitHub CI;

## Deliberately deferred

- replacing the firmware BusyBox — unsafe and unnecessary for zapret2;
- bundling an optional second BusyBox — useful, but 2 MiB JFFS2 requires a
  separately size-tested profile;
- disabling `mt_whnat` — only an expert diagnostic option if counters stop;
- automatic live failure injection into `nfqws2`/watcher — valuable but briefly
  disrupts a production router and should be an explicit chaos-test command;
- restoring a full `csmconf` XML on rollback — too broad; rollback should remain
  limited to project-owned appmgr keys;
- automatic external HTTP tests from the router — its TLS/DNS tools are too old;
  host-side service tests should be a separate optional command.
