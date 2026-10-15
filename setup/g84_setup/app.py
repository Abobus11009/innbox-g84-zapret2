"""Local web server and explicit operation state for the setup wizard."""
import base64
import json
import secrets
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from .access import AccessError, MAX_CONFIG, discover
from .manager import Manager, resources

ACTIONS = {
    'discover': ('Поиск роутера', 'Поиск завершён.'),
    'access': ('Подключение', 'Доступ к роутеру подтверждён.'),
    'check': ('Проверка совместимости', 'Совместимость проверена без изменений.'),
    'verify': ('Проверка сервиса', 'Сервис проверен. Доступность приложений проверьте отдельно.'),
    'install': ('Установка', 'Установка проверена.'),
    'uninstall': ('Удаление', 'Удаление подтверждено.'),
    'recover': ('Восстановление', 'Предыдущее состояние восстановлено.'),
}
DEVICE_ACTIONS = {'check', 'verify', 'install', 'uninstall', 'recover'}


class Application:
    def __init__(self):
        self.token = secrets.token_urlsafe(32)
        self.lock = threading.Lock()
        self.state_lock = threading.RLock()
        self.events = []
        self.busy = False
        self.ready = False
        self.result = {}
        self.device = {}
        self.routers = []
        self.operation = {'id': 0, 'action': None, 'status': 'idle', 'message': 'Подключите роутер, чтобы начать.'}
        self.manager = Manager(notify=self.notify)

    def notify(self, message):
        with self.state_lock:
            self.events.append(str(message))
            self.events = self.events[-150:]
            if self.busy:
                self.operation['message'] = str(message)

    def snapshot(self):
        with self.state_lock:
            return {
                'busy': self.busy, 'ready': self.ready,
                'host': self.manager.host if self.ready else None,
                'events': list(self.events), 'result': dict(self.result),
                'device': dict(self.device), 'routers': list(self.routers),
                'operation': dict(self.operation), 'version': self.manager.version,
                'backups': str(self.manager.state_dir / 'backups'),
            }

    def job(self, action, data):
        if action not in ACTIONS:
            raise AccessError('Неизвестная операция.')
        if not self.lock.acquire(blocking=False):
            raise AccessError('Другая операция ещё выполняется.')
        with self.state_lock:
            self.busy = True
            self.result = {}
            self.operation = {'id': self.operation['id'] + 1, 'action': action,
                              'status': 'running', 'message': ACTIONS[action][0] + '…'}
            operation_id = self.operation['id']

        def work():
            try:
                if action in DEVICE_ACTIONS:
                    if not self.ready:
                        raise AccessError('Сначала подключитесь к роутеру.')
                    if not self.manager.host or data.get('host') != self.manager.host:
                        raise AccessError('Адрес изменился. Подключитесь к выбранному роутеру заново.')
                if action == 'discover':
                    self.routers = discover()
                    self.result = {'routers': self.routers}
                elif action == 'access':
                    self.ready = False
                    self.device = {}
                    if self.manager.ssh:
                        self.manager.ssh.close()
                    self.manager.ssh = None
                    self.manager.host = None
                    self.manager.password = None
                    method = data.get('method', 'web')
                    if method not in {'web', 'config', 'ssh'}:
                        raise AccessError('Выберите способ подключения.')
                    config = None
                    if method == 'config':
                        try:
                            config = base64.b64decode(data.get('config', ''), validate=True)
                        except (ValueError, TypeError):
                            raise AccessError('Файл конфигурации не прочитан. Выберите его заново.') from None
                        if not config or len(config) > MAX_CONFIG:
                            raise AccessError('Выберите непустую конфигурацию размером до 16 MiB.')
                    password = data.get('ssh_password') if method == 'ssh' else None
                    if method == 'ssh' and not password:
                        raise AccessError('Введите пароль superadmin.')
                    if method == 'web' and not data.get('web_password'):
                        raise AccessError('Введите пароль веб-интерфейса. Если его не меняли, введите admin.')
                    info = self.manager.bootstrap(data.get('host', ''), data.get('web_user', 'admin'),
                                                  data.get('web_password', ''), config, password)
                    self.ready = True
                    self.device = dict(info or {})
                    self.result = {'host': self.manager.host, **self.device}
                elif action == 'check':
                    self.result = self.manager.compatibility()
                    self.device.update(self.result)
                elif action == 'install':
                    reboot = data.get('reboot', False)
                    if not isinstance(reboot, bool):
                        raise AccessError('Параметр перезагрузки должен быть true или false.')
                    result = self.manager.install(reboot=reboot)
                    if isinstance(result, dict):
                        self.result = result
                    self.device['installed_version'] = self.manager.version
                    self.device['free_kib'] = None
                else:
                    getattr(self.manager, action)()
                    if action == 'uninstall':
                        self.device['installed_version'] = None
                        self.device['free_kib'] = None
                    elif action == 'recover':
                        self.device = {}  # Do not display the newer version after rollback.
                with self.state_lock:
                    self.operation.update(status='success', message=self.result.get('message', ACTIONS[action][1]))
            except AccessError as error:
                self._failed(action, str(error))
            except Exception as error:
                # Record only the exception class, not values or a traceback
                # that can contain credentials or configuration contents.
                with self.state_lock:
                    self.operation['error_type'] = type(error).__name__
                self._failed(action, 'Операция не завершена. Проверьте подключение. Данные восстановления сохранены, если изменения начались.')
            finally:
                with self.state_lock:
                    self.busy = False
                self.lock.release()

        threading.Thread(target=work, daemon=True).start()
        return operation_id

    def _failed(self, action, message):
        ssh = self.manager.ssh
        if action == 'access' or ssh is None or (hasattr(ssh, 'alive') and not ssh.alive()):
            if self.manager.ssh:
                try:
                    self.manager.ssh.close()
                except Exception:
                    pass
            self.manager.ssh = None
            self.manager.password = None
            self.ready = False
        self.notify('Ошибка: ' + message)
        with self.state_lock:
            self.operation.update(status='error', message=message)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # Credentials and request bodies never go to logs.

    def authorized(self):
        expected = f'127.0.0.1:{self.server.server_port}'
        if self.headers.get('Host') != expected:
            return False
        origin = self.headers.get('Origin')
        if origin and origin != 'http://' + expected:
            return False
        return secrets.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + self.server.app.token)

    def reply(self, status, data, kind='application/json'):
        raw = data if isinstance(data, bytes) else json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', kind)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == '/' and self.headers.get('Host') == f'127.0.0.1:{self.server.server_port}':
            self.reply(200, (resources() / 'setup/ui.html').read_bytes(), 'text/html; charset=utf-8')
            return
        if not self.authorized():
            self.reply(403, {'error': 'Сессия мастера недоступна. Откройте ссылку из терминала, где запущен скрипт.'})
            return
        if self.path != '/state':
            self.reply(404, {})
            return
        self.reply(200, self.server.app.snapshot())

    def do_POST(self):
        if not self.authorized():
            self.reply(403, {'error': 'Сессия мастера недоступна. Откройте ссылку из терминала.'})
            return
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if size < 0 or size > 24 * 1024 * 1024:
                raise AccessError('Запрос слишком большой.')
            body = json.loads(self.rfile.read(size))
            if not isinstance(body, dict):
                raise AccessError('Неверный запрос.')
            if self.path == '/quit':
                if not self.server.app.lock.acquire(blocking=False):
                    raise AccessError('Дождитесь завершения операции перед закрытием.')
                self.reply(200, {'closed': True})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            operation_id = self.server.app.job(self.path.strip('/'), body)
            self.reply(202, {'accepted': True, 'operation_id': operation_id})
        except (ValueError, KeyError, AccessError) as error:
            self.reply(400, {'error': str(error) if isinstance(error, AccessError) else 'Неверный запрос.'})


def main():
    if '--self-test' in sys.argv:
        app = Application()
        assert app.manager.payload and (resources() / 'setup/ui.html').is_file()
        import paramiko, cryptography
        print('Setup resources and SSH/crypto modules verified.')
        return
    app = Application()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.app = app
    url = f'http://127.0.0.1:{server.server_port}/#' + app.token
    print('Мастер запущен. Если браузер не открылся, откройте эту ссылку:\n' + url, flush=True)
    try:
        webbrowser.open(url)
    except Exception:
        pass  # The printed link also works without an automatic browser launch.
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if app.manager.ssh:
            app.manager.ssh.close()
        server.server_close()
