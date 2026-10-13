import base64, json, os, pathlib, secrets, sys, threading, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from .access import AccessError, MAX_CONFIG, discover
from .manager import Manager, resources

class Application:
    def __init__(self):
        self.token=secrets.token_urlsafe(32);self.lock=threading.Lock();self.events=[];self.busy=False;self.ready=False
        self.manager=Manager(notify=self.notify);self.result={}
    def notify(self,message):self.events.append(str(message));self.events=self.events[-150:]
    def job(self,action,data):
        if not self.lock.acquire(blocking=False):raise AccessError('Другая операция ещё выполняется.')
        self.busy=True
        def work():
            try:
                if action=='discover':self.result={'routers':discover()}
                elif action=='access':
                    self.ready=False;self.result={}
                    if self.manager.ssh:self.manager.ssh.close()
                    self.manager.ssh=None;self.manager.host=None;self.manager.password=None
                    config=base64.b64decode(data['config'],validate=True) if data.get('config') else None
                    if config and len(config)>MAX_CONFIG:raise AccessError('Конфигурация слишком большая.')
                    self.manager.bootstrap(data['host'],data.get('web_user','admin'),data.get('web_password',''),config,data.get('ssh_password'))
                    self.ready=True;self.result={'host':self.manager.host}
                elif action in ['check','verify','install','uninstall','recover']:
                    if not self.ready:raise AccessError('Сначала подготовьте доступ.')
                    if action=='check':self.result=self.manager.compatibility();self.notify('Совместимость проверена без изменений на роутере.')
                    elif action=='install':self.manager.install(reboot=bool(data.get('reboot',True)))
                    else:getattr(self.manager,action)()
                else:raise AccessError('Неизвестная операция.')
            except AccessError as e:self.notify('Ошибка: '+str(e))
            except Exception:self.notify('Операция не завершена. Проверьте подключение; данные восстановления не очищены.')
            finally:self.busy=False;self.lock.release()
        threading.Thread(target=work,daemon=True).start()

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass # No passwords, tokens or request bodies in logs.
    def authorized(self):
        expected=f'127.0.0.1:{self.server.server_port}'
        if self.headers.get('Host')!=expected:return False
        origin=self.headers.get('Origin')
        if origin and origin!='http://'+expected:return False
        return secrets.compare_digest(self.headers.get('Authorization',''),'Bearer '+self.server.app.token)
    def reply(self,status,data,kind='application/json'):
        raw=data if isinstance(data,bytes) else json.dumps(data,ensure_ascii=False).encode()
        self.send_response(status);self.send_header('Content-Type',kind);self.send_header('Cache-Control','no-store');self.send_header('X-Content-Type-Options','nosniff');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
    def do_GET(self):
        if self.path=='/' and self.headers.get('Host')==f'127.0.0.1:{self.server.server_port}':
            self.reply(200,(resources()/'desktop/ui.html').read_bytes(),'text/html; charset=utf-8');return
        if not self.authorized():self.reply(403,{'error':'Нет доступа.'});return
        if self.path!='/state':self.reply(404,{});return
        app=self.server.app
        self.reply(200,{'busy':app.busy,'ready':app.ready,'events':app.events,'result':app.result,'version':app.manager.version,'backups':str(app.manager.state_dir/'backups')})
    def do_POST(self):
        if not self.authorized():self.reply(403,{'error':'Нет доступа.'});return
        try:
            size=int(self.headers.get('Content-Length','0'))
            if size<0 or size>24*1024*1024:raise AccessError('Запрос слишком большой.')
            body=json.loads(self.rfile.read(size))
            if not isinstance(body,dict):raise AccessError('Неверный запрос.')
            if self.path=='/quit':
                if not self.server.app.lock.acquire(blocking=False):raise AccessError('Дождитесь завершения операции перед закрытием.')
                self.reply(200,{'closed':True})
                threading.Thread(target=self.server.shutdown,daemon=True).start();return
            self.server.app.job(self.path.strip('/'),body);self.reply(202,{'accepted':True})
        except (ValueError,KeyError,AccessError) as e:
            self.reply(400,{'error':str(e) if isinstance(e,AccessError) else 'Неверный запрос.'})

def main():
    if '--self-test' in sys.argv:
        app=Application();assert app.manager.payload and (resources()/'desktop/ui.html').is_file()
        import paramiko,cryptography
        print('Packaged resources and SSH/crypto modules verified.');return
    app=Application();server=ThreadingHTTPServer(('127.0.0.1',0),Handler);server.app=app
    url=f'http://127.0.0.1:{server.server_port}/#'+app.token
    webbrowser.open(url)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:
        if app.manager.ssh:app.manager.ssh.close()
        server.server_close()
