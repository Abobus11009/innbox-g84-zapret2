## Что нового

- Адаптивный подбор стратегий TCP и QUIC по признакам сбоя соединения.
- Независимый выбор для домена, устройства и IPv4/IPv6.
- Списки обрабатываемых доменов и исключений.
- Улучшенная совместимость со штатной оболочкой Innbox G84.
- Обновлённый пакет, документация и проверки Lua.

## Установка

Скачайте `g84-zapret2.sh`, `g84-zapret2-payload.tar.gz` и `manifest.env`
из вложений релиза в одну папку. `release-checksums.txt` содержит контрольные суммы.

```bash
chmod +x g84-zapret2.sh
./g84-zapret2.sh diagnose
./g84-zapret2.sh install --dry-run
./g84-zapret2.sh install
```

Для применения без перезагрузки используйте `install --no-reboot`.
Настройка: [адаптивные стратегии](https://github.com/Abobus11009/innbox-g84-zapret2/blob/v0.3.0/docs/adaptive.md).

Доступность сервисов зависит от сети провайдера и конфигурации DPI.

**Полный список изменений:** https://github.com/Abobus11009/innbox-g84-zapret2/compare/v0.2.0...v0.3.0
