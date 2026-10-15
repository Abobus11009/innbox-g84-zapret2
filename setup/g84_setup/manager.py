"""Router operations for the local Python web interface."""
import datetime, hashlib, pathlib, re, secrets, shlex, time
from .access import AccessError, RouterSSH, WebAccess, account_password, local_address

def resources():
    return pathlib.Path(__file__).resolve().parents[2]

def data_directory():
    import os
    base=pathlib.Path(os.environ.get('G84_DATA_DIR') or (pathlib.Path(os.environ.get('LOCALAPPDATA',pathlib.Path.home()/'.local/share'))/'InnboxG84'))
    base.mkdir(parents=True,exist_ok=True,mode=0o700)
    return base

def stamp():return datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+str(secrets.randbelow(10**12))

def private_write(path,data):
    path=pathlib.Path(path);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    with path.open('xb') as out:out.write(data)
    path.chmod(0o600)

def prune_backups(directory,keep=10):
    directory=pathlib.Path(directory);entries=[]
    for xml in directory.glob('g84-config-*.xml'):
        match=re.fullmatch(r'g84-config-(\d{8}-\d{6}(?:-\d+)?).xml',xml.name)
        if match and not xml.is_symlink() and not (directory/('.reserve-'+match[1])).exists():
            entries.append((xml.stat().st_mtime_ns,match[1]))
    for _,name in sorted(entries,reverse=True)[keep:]:
        for path in [directory/f'g84-config-{name}.xml',directory/f'g84-zapret2-{name}.tar.gz']:
            path.unlink(missing_ok=True)

class Manager:
    def __init__(self,root=None,state_dir=None,notify=lambda message:None):
        self.root=pathlib.Path(root or resources());self.state_dir=pathlib.Path(state_dir or data_directory())
        self.notify=notify;self.ssh=None;self.password=None;self.host=None
        self.manifest={}
        for line in (self.root/'manifest.env').read_text().splitlines():
            key,sep,value=line.partition('=')
            if sep:self.manifest[key]=value
        self.payload=(self.root/'g84-zapret2-payload.tar.gz').read_bytes()
        if hashlib.sha256(self.payload).hexdigest()!=self.manifest.get('PAYLOAD_SHA256'):raise AccessError('Пакет установки повреждён.')
        self.version=self.manifest['PROJECT_VERSION']
    def bootstrap(self,host,web_user='admin',web_password='',config=None,password=None):
        host=local_address(host);web=WebAccess(host);web_logged_in=False
        if password:
            self.password=password
        elif config:
            self.password=account_password(config)
            self.notify('Пароль superadmin получен из локального файла.')
        else:
            if not web_password:raise AccessError('Введите пароль веб-интерфейса. Если его не меняли, введите admin.')
            self.notify('Вход в веб-интерфейс и экспорт конфигурации…')
            web.login(web_user,web_password);web_logged_in=True
            raw=web.export();self.password=account_password(raw)
            private_write(self.state_dir/'backups'/('web-config-'+stamp()+'.bin'),raw)
            self.notify('Пароль superadmin получен; конфигурация сохранена локально.')
        # Enabling uses authenticated web access. Existing SSH requires no web mutation.
        from .access import ssh_open
        if not ssh_open(host):
            if not web_logged_in:
                if not web_password:raise AccessError('SSH закрыт. Укажите также пароль веб-интерфейса, чтобы разрешить SSH для этого компьютера.')
                web.login(web_user,web_password)
            self.notify('Добавляю доступ SSH только для этого компьютера через LAN…')
            web.enable_ssh()
        self.connect(host)
        info=self.compatibility()
        self.notify('Доступ superadmin с UID 0 подтверждён.')
        return info
    def connect(self,host=None):
        if self.ssh:self.ssh.close()
        self.ssh=None
        self.host=host or self.host
        self.ssh=RouterSSH(self.host,self.password,self.state_dir)
    def compatibility(self,require_space=False):
        if not self.ssh:raise AccessError('Сначала подготовьте доступ к роутеру.')
        self.ssh.run('grep -q EN7528 /proc/cpuinfo && grep -q en751221 /proc/cpuinfo && awk \'/^Uid:/{exit $2 != 0}\' /proc/self/status && test -x /bin/ash && test -w /var/SaaS && iptables --version >/dev/null && csmconf -H >/dev/null')
        _,out,_=self.ssh.run('df -k /var/SaaS')
        matches=[line.split()[3] for line in out.decode().splitlines() if len(line.split())>=4 and line.split()[3].isdigit()]
        if not matches:raise AccessError('Не удалось определить свободное место на роутере. Повторите проверку подключения.')
        if require_space and int(matches[-1])<650:raise AccessError('Для обновления требуется минимум 650 KiB свободного места в /var/SaaS.')
        _,version,_=self.ssh.run('if test -d /var/SaaS/zapret2; then cat /var/SaaS/zapret2/VERSION || exit 1; fi')
        installed=version.decode(errors='replace').strip()
        if installed and not re.fullmatch(r'[A-Za-z0-9._+-]{1,64}',installed):installed='неизвестна'
        return {'version':self.version,'host':self.host,'free_kib':int(matches[-1]),'installed_version':installed or None}

    def ensure_clean_transaction(self):
        if not self.ssh:raise AccessError('Сначала подключитесь к роутеру.')
        # Check before backups and NFQUEUE probes; never erase recovery data to
        # make an install retry succeed. Read failures must also fail closed.
        status,_,_=self.ssh.run('for p in /var/SaaS/zapret2.transaction /var/SaaS/zapret2.old /var/SaaS/zapret2.new /var/SaaS/zapret2.failed /var/tmp/zapret2-install /var/tmp/zapret2-uninstall; do test ! -e "$p" || exit 72; done',check=False)
        if status==72:raise AccessError('Повторная операция остановлена: есть данные предыдущей операции. Сохраните отчёт и проверьте инструкцию восстановления. Кнопка «Восстановить прежнее состояние» выполняет откат, а не просто очистку. Не удаляйте резервные копии.')
        if status:raise AccessError('Не удалось проверить данные восстановления. Переподключитесь к роутеру перед повторной установкой.')
    def backup(self):
        name=stamp();directory=self.state_dir/'backups';directory.mkdir(parents=True,exist_ok=True,mode=0o700)
        reservation=directory/('.reserve-'+name);reservation.mkdir(mode=0o700)
        temporary='/var/tmp/g84-setup-backup-'+name
        self.notify('Сохраняю конфигурацию и предыдущую установку…')
        # Firmware csmconf forces 0644 regardless of umask. Protect the parent
        # before export so another router process cannot read the credentials.
        script=f'''d={shlex.quote(temporary)}; umask 077
mkdir "$d" && chmod 700 "$d" || exit 1
trap 'rm -f "$d/config.xml"; rmdir "$d"' 0
trap 'exit 1' 1 2 15
csmconf -D "$d/config.xml" && chmod 600 "$d/config.xml" && test -s "$d/config.xml" && cat "$d/config.xml"'''
        _,config,_=self.ssh.run(script)
        if not config:raise AccessError('Роутер вернул пустую резервную копию.')
        private_write(directory/f'g84-config-{name}.xml',config)
        status,_,_=self.ssh.run('test -d /var/SaaS/zapret2',check=False)
        if status==0:
            _,archive,_=self.ssh.run('tar -czf - -C /var/SaaS zapret2')
            if not archive:raise AccessError('Пустая копия установленной версии.')
            private_write(directory/f'g84-zapret2-{name}.tar.gz',archive)
        elif status!=1:raise AccessError('Не удалось определить состояние предыдущей установки.')
        reservation.rmdir();prune_backups(directory)
        return str(directory)
    def slots(self):
        _,out,_=self.ssh.run('i=1; while [ $i -le 16 ]; do n=`csmconf -g /appmgr:$i/name` || exit 1; echo "$i:$n"; i=`expr $i + 1`; done')
        lines=out.decode().splitlines()
        if len(lines)!=16:raise AccessError('Не удалось прочитать таблицу appmgr.')
        values={};free=[]
        for index,line in enumerate(lines,1):
            number,sep,name=line.partition(':')
            if not sep or number!=str(index):raise AccessError('Некорректная таблица appmgr.')
            if name in ['zapret2','zapret2-rules']:
                if name in values:raise AccessError('Дубли регистрации zapret2 в appmgr.')
                values[name]=index
            elif not name:free.append(index)
        for name in ['zapret2','zapret2-rules']:
            if name not in values:
                if not free:raise AccessError('Для проекта нет двух свободных слотов appmgr.')
                values[name]=free.pop(0)
        return values['zapret2'],values['zapret2-rules']
    def stage(self):
        self.ssh.run('''umask 077
mkdir /var/tmp/zapret2-install || exit 1
trap 'rm -rf /var/tmp/zapret2-install' 0
trap 'exit 1' 1 2 15
tar -xzf - -C /var/tmp/zapret2-install || exit 1
trap - 0 1 2 15''',data=self.payload)
    def probe_nfqueue(self):
        def probe(table,address):
            return self.ssh.run(f'''{table} -t mangle -I OUTPUT 1 -d {address} -p tcp -j NFQUEUE --queue-num 299 --queue-bypass || exit 1
n=0
while ! {table} -t mangle -D OUTPUT -d {address} -p tcp -j NFQUEUE --queue-num 299 --queue-bypass; do
n=`expr "$n" + 1`; [ "$n" -lt 3 ] || exit 5; sleep 1
done''',check=False)[0]
        if probe('iptables','192.0.2.1'):raise AccessError('Проверка IPv4 NFQUEUE или очистка тестового правила не прошла.')
        status=probe('ip6tables','2001:db8::1')
        if status not in [0,1]:raise AccessError('Ошибка очистки IPv6-пробы. Установка прервана.')
        return 1 if status==0 else 0
    def install(self,reboot=False):
        self.ensure_clean_transaction();self.compatibility(require_space=True);slots=self.slots()
        _,out,_=self.ssh.run('route -n | awk \'$1=="0.0.0.0" {print $8; exit}\'')
        wan=out.decode().strip()
        if not re.fullmatch(r'[A-Za-z0-9_.:-]+',wan):raise AccessError('Не удалось определить WAN-интерфейс.')
        self.backup();ipv6=self.probe_nfqueue();self.stage()
        self.notify('Проверяю пакет и устанавливаю с журналом восстановления…')
        self.ssh.run(f'/bin/ash /var/tmp/zapret2-install/zapret2/install-transaction.sh install {shlex.quote(wan)} {ipv6} {slots[0]} {slots[1]} {shlex.quote(self.version)} 0',timeout=300)
        if reboot:
            _,before,_=self.ssh.run('cat /proc/sys/kernel/random/boot_id')
            self.notify('Перезагрузка. Компьютер может временно потерять Wi-Fi…')
            try:self.ssh.run('reboot',timeout=8,check=False)
            except Exception:pass
            deadline=time.monotonic()+300;verified=False
            while time.monotonic()<deadline:
                time.sleep(5)
                try:
                    self.connect();_,now,_=self.ssh.run('cat /proc/sys/kernel/random/boot_id')
                    if not now.strip() or now.strip()==before.strip():continue
                    self.verify();verified=True;break
                except (AccessError,OSError):continue
            if not verified:
                try:
                    self.connect();self.recover()
                except (AccessError,OSError):raise AccessError('Автозапуск не подтверждён и откат не завершён. Резервные копии и журнал сохранены; подключитесь снова для восстановления.') from None
                raise AccessError('Автозапуск не подтверждён; предыдущее состояние восстановлено.')
        else:
            try:self.verify()
            except AccessError:
                self.recover();raise AccessError('Проверка новой версии не прошла; выполнен откат.') from None
        status,_,_=self.ssh.run('rm -rf /var/SaaS/zapret2.old /var/SaaS/zapret2.transaction /var/tmp/zapret2-install',check=False)
        message='Установка проверена.' if reboot else 'Текущий запуск проверен; автозапуск после перезагрузки ещё не проверен.'
        if status:message='Установка работает, но временные данные не очищены. Сохраните журнал и проверьте инструкцию восстановления перед следующим обновлением.'
        self.notify(message)
        return {'cleanup_pending':bool(status),'message':message}
    def verify(self):
        self.ssh.run('test -x /var/SaaS/zapret2/verify.sh && /var/SaaS/zapret2/verify.sh')
        self.notify('Процессы, очередь и правила проверены. Приложения проверьте без VPN.')
    def uninstall(self):
        self.ensure_clean_transaction()
        status,_,_=self.ssh.run('test -d /var/SaaS/zapret2',check=False)
        if status==1:self.notify('Установка отсутствует.');return
        if status:raise AccessError('Не удалось определить состояние установки.')
        _,out,_=self.ssh.run('cat /var/SaaS/zapret2/appmgr-slots')
        pairs=re.findall(r'^(NFQWS_SLOT|WATCH_SLOT)=([0-9]+)$',out.decode(),re.M)
        if len(pairs)!=2 or len(out.decode().splitlines())!=2:raise AccessError('Неоднозначная карта слотов appmgr.')
        found=dict(pairs)
        if set(found)!={'NFQWS_SLOT','WATCH_SLOT'}:raise AccessError('Не распознана карта слотов appmgr.')
        slots=[int(found[n]) for n in ['NFQWS_SLOT','WATCH_SLOT']]
        if len(set(slots))!=2 or any(n not in range(1,17) for n in slots):raise AccessError('Неверная карта слотов appmgr.')
        self.backup();self.stage();self.notify('Удаляю с сохранением прежнего состояния для отката…')
        self.ssh.run(f'/bin/ash /var/tmp/zapret2-install/zapret2/install-transaction.sh uninstall {slots[0]} {slots[1]}',timeout=300)
        self.ssh.run('test ! -e /var/SaaS/zapret2 && test "`cat /var/SaaS/zapret2.transaction/result`" = uninstall-committed && rm -rf /var/SaaS/zapret2.old /var/SaaS/zapret2.transaction /var/tmp/zapret2-install')
        self.notify('Удаление подтверждено.')
    def recover(self):
        self.ssh.run('test -r /var/SaaS/zapret2.transaction/recover.sh && /bin/ash /var/SaaS/zapret2.transaction/recover.sh recover',timeout=300)
        name=stamp();_,journal,_=self.ssh.run('tar -czf - -C /var/SaaS zapret2.transaction')
        if not journal:raise AccessError('Не удалось сохранить журнал восстановления.')
        private_write(self.state_dir/'backups'/f'g84-recovery-{name}.tar.gz',journal)
        self.ssh.run('rm -rf /var/SaaS/zapret2.transaction /var/SaaS/zapret2.new /var/SaaS/zapret2.failed /var/tmp/zapret2-install /var/tmp/zapret2-uninstall')
        self.notify('Предыдущее состояние восстановлено.')
