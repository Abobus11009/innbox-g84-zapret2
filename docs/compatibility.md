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

## Проверка версии 0.3.1

На физическом G84 проверены обновление, восстановление после неудачной установки,
системная блокировка, разбор профиля и Lua-тест в роутерном движке. После reboot
оба сервиса запущены `appmgrd`; строгая проверка IPv4/IPv6 прошла. Повторный полный
цикл удаления/чистой установки 0.3.1 на оборудовании не выполнялся; эти сценарии
проверяются в изолированной модели. Историческая проверка удаления/чистой
установки относится к 0.3.0.

При недоступном IPC appmgr установщик может запустить сервис напрямую; после
перезагрузки проверяется запуск через менеджер прошивки. Сравнивается boot ID,
поэтому оставшийся доступным SSH сам по себе не считается подтверждением reboot.
