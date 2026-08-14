# Recovery

## SSH работает, интернет пропал

```sh
/var/SaaS/zapret2/stop.sh
```

Правила используют `--queue-bypass`, поэтому остановка `nfqws2` обычно не должна
обрывать интернет. Затем проверьте `status` и `/var/tmp/zapret2.log`.

## nfqws2 не запускается

```sh
/var/SaaS/zapret2/nfqws2 --version
cat /var/tmp/zapret2.log
df -h /var/SaaS
```

Host-side команда `verify` возвращает ненулевой код, если PID-файл не относится
к ожидаемому бинарнику или отсутствуют firewall links.

## Правила исчезают

Проверьте watcher и запустите восстановление вручную:

```sh
/var/SaaS/zapret2/add-rules.sh
cat /var/tmp/zapret2-rules.log
```

## Повреждена регистрация appmgr

Посмотрите выбранные слоты:

```sh
cat /var/SaaS/zapret2/appmgr-slots
```

`uninstall` удаляет слот только после проверки, что его имя принадлежит проекту.

## Заполнен /var/SaaS

Удалите только оставшийся транзакционный каталог, если активная установка уже
проверена:

```sh
rm -rf /var/SaaS/zapret2.old
```

Не удаляйте другие каталоги `/var/SaaS`: они могут принадлежать прошивке.

## Полное удаление

С хоста:

```bash
./g84-zapret2.sh uninstall
```

Перед удалением создаётся приватная локальная резервная копия.
