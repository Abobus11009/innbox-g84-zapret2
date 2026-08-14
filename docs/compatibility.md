# Compatibility

| Model | SoC / kernel | Status | Notes |
|---|---|---|---|
| Innbox G84 | EcoNet EN7528 / Linux 3.18.21 #8 | Tested | MIPS32r2 little-endian, WAN `nas1`, IPv4+IPv6 NFQUEUE, reboot verified |
| Other EN7528 gateways | Unknown firmware | Expected with review | Run `diagnose` and `--dry-run`; do not assume appmgr/storage layout |
| Other MIPSEL routers | Varies | Unsupported/unknown | Static binary may run, but installer intentionally checks G84 platform |

Support labels mean:

- **Tested** — physical install, uninstall/reinstall and reboot completed;
- **Expected with review** — architecture is promising but firmware integration differs;
- **Unsupported/unknown** — no safety claim.
