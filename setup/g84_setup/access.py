"""Local discovery, legacy-config decoding, web bootstrap and scoped SSH."""
import concurrent.futures, gzip, hashlib, html, http.cookiejar, io, ipaddress
import json, os, pathlib, re, secrets, shlex, socket, subprocess, time
import urllib.parse, urllib.request, xml.etree.ElementTree as ET
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding

MAX_CONFIG=16*1024*1024
class AccessError(RuntimeError): pass

def local_address(value):
    try: addr=ipaddress.IPv4Address(value)
    except ValueError: raise AccessError('Нужен локальный IPv4-адрес роутера.') from None
    networks=['10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','127.0.0.0/8']
    if not any(addr in ipaddress.ip_network(n) for n in networks):
        raise AccessError('Мастер подключается только к локальной сети.')
    return str(addr)

def decode_config(data):
    if len(data)>MAX_CONFIG: raise AccessError('Файл конфигурации слишком большой.')
    raw=data
    if not raw.lstrip().startswith(b'<') and not raw.startswith(b'\x1f\x8b'):
        start=raw.find(b'Salted__',0,4096)
        if start<0 or len(raw)-start<32: raise AccessError('Не распознан старый формат экспорта G84.')
        salt=raw[start+8:start+16];encrypted=raw[start+16:]
        if len(encrypted)%16: raise AccessError('Файл конфигурации обрезан.')
        material=b'';previous=b''
        while len(material)<48:
            previous=hashlib.md5(previous+b'InnboxG84'+salt).digest();material+=previous
        try:
            decrypt=Cipher(algorithms.AES(material[:32]),modes.CBC(material[32:48])).decryptor()
            padded=decrypt.update(encrypted)+decrypt.finalize()
            unpad=padding.PKCS7(128).unpadder();raw=unpad.update(padded)+unpad.finalize()
        except ValueError: raise AccessError('Этот экспорт не расшифровывается методом InnboxG84.') from None
    if raw.startswith(b'\x1f\x8b'):
        try:
            with gzip.GzipFile(fileobj=io.BytesIO(raw)) as gz:raw=gz.read(MAX_CONFIG+1)
        except (OSError,EOFError):raise AccessError('Повреждён архив конфигурации.') from None
    if len(raw)>MAX_CONFIG:raise AccessError('Распакованная конфигурация слишком большая.')
    if b'<!DOCTYPE' in raw.upper() or b'<!ENTITY' in raw.upper():raise AccessError('DTD в конфигурации не поддерживается.')
    # Native csmconf emits invalid XML tags such as <2G>; normalize only tag names.
    normalized=re.sub(rb'<(/?)([0-9][A-Za-z0-9_.:-]*)(?=[\s/>])',rb'<\1_\2',raw)
    try:root=ET.fromstring(normalized)
    except ET.ParseError:raise AccessError('XML конфигурации не распознан.') from None
    return root,raw

def account_password(data,account='superadmin'):
    root,_=decode_config(data);found=[]
    for users in root.iter('user'):
        for record in users:
            if record.findtext('name')==account:
                value=record.findtext('password')
                if value and len(value)<=256 and '\x00' not in value:found.append(value)
    if len(found)!=1:raise AccessError('В конфигурации нет единственной учётной записи '+account+'.')
    return found[0]

class LocalRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self,origin):self.origin=origin
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        p=urllib.parse.urlsplit(newurl)
        if (p.scheme,p.netloc)!=self.origin:raise AccessError('Роутер перенаправил запрос на другой адрес.')
        return super().redirect_request(req,fp,code,msg,headers,newurl)

class WebAccess:
    def __init__(self,host,port=80):
        self.host=local_address(host);self.base=f'http://{self.host}:{port}'
        self.jar=http.cookiejar.CookieJar()
        self.opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPCookieProcessor(self.jar),LocalRedirect(('http',f'{self.host}:{port}')))
    def fetch(self,path,data=None,limit=2*1024*1024):
        if not path.startswith('/') or path.startswith('//'):raise AccessError('Неверный адрес страницы.')
        request=urllib.request.Request(self.base+path,data=data,headers={'User-Agent':'Mozilla/5.0 G84-Setup','Referer':self.base+'/','Origin':self.base})
        try:
            with self.opener.open(request,timeout=8) as response:result=response.read(limit+1)
        except AccessError:raise
        except Exception:raise AccessError('Не удалось прочитать веб-интерфейс G84.') from None
        if len(result)>limit:raise AccessError('Ответ роутера слишком большой.')
        return result
    def identify(self):
        page=self.fetch('/').decode(errors='replace')
        # Some firmware sends a script redirect after rejected web login. Only
        # follow these fixed local pages, never arbitrary script destinations.
        if 'old_login_error.htm' in page:page=self.fetch('/old_login_error.htm').decode(errors='replace')
        elif 'new_login_error.htm' in page:page=self.fetch('/new_login_error.htm').decode(errors='replace')
        if not re.search(r'(?:Innbox\s*G84|InnboxG84)',page,re.I):raise AccessError('На этом адресе не распознан Innbox G84.')
    def login(self,user,password):
        self.identify();login_page=self.fetch('/old_login.htm').decode(errors='replace')
        retry='old_login_error.htm' in login_page
        if retry:
            login_page=self.fetch('/old_login_error.htm').decode(errors='replace')
            if 'action="/login_error.htm"' not in login_page or 'f.pwd.value = ""' not in login_page:
                raise AccessError('Форма повторного веб-входа не поддерживается. Используйте конфигурацию или известный SSH-пароль.')
        self.jar.set_cookie(http.cookiejar.Cookie(0,'cookieId',secrets.token_hex(5),None,False,self.host,False,False,'/',True,False,None,True,None,None,{}))
        body=urllib.parse.urlencode({'f_username':user,'password':password,'f_password':hashlib.md5(password.encode()).hexdigest(),'current_url':self.base+'/old_login.htm'}).encode()
        if retry:body=urllib.parse.urlencode({'f_username':user,'pwd':'','f_password':hashlib.md5(password.encode()).hexdigest()}).encode()
        self.fetch('/login_error.htm' if retry else '/login.htm',body)
        page=self.fetch('/maintenance/mt_system_tl.htm').decode(errors='replace')
        if 'save_old_cfg' not in page or 'config_old_tl.xgi' not in page:
            raise AccessError('Вход или старый экспорт недоступен. Проверьте веб-пароль либо импортируйте конфигурацию.')
        return page
    def session_key(self):
        key=self.fetch('/advanced/conSession.htm?id='+str(secrets.randbelow(10**9))).decode().strip()
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,256}',key):raise AccessError('Не распознан ключ веб-сессии.')
        return key
    def export(self):
        return self.fetch('/config_old_tl.xgi?'+urllib.parse.urlencode({'sessionKey':self.session_key()}),limit=MAX_CONFIG)
    @staticmethod
    def array(page,name):
        m=re.search(r'\bvar\s+'+re.escape(name)+r'\s*=\s*(\[)',page)
        if not m:raise AccessError('Эта версия формы доступа пока не поддерживается.')
        try:value,_=json.JSONDecoder().raw_decode(page[m.start(1):])
        except ValueError:raise AccessError('Не распознаны поля формы доступа.') from None
        if not isinstance(value,list):raise AccessError('Некорректная форма доступа.')
        return value
    def enable_ssh(self):
        # Existing SSH is left unchanged; do not create duplicate ACL entries.
        if ssh_open(self.host):return False
        page=self.fetch('/maintenance/mt_acremote_tl.htm').decode(errors='replace')
        if 'mt_acremote_tl.xgi?' not in page or 'get_Interface("LAN","ins4"' not in page:
            raise AccessError('Автоматическое включение SSH не поддерживается этой формой.')
        lanes=self.array(page,'lan_lists');rows=self.array(page,'dataLists')
        count=re.search(r'var\s+data_count\s*=\s*parseInt\("(\d+)"\)',page)
        if not count or int(count[1])!=len(rows) or len(rows)>=64:raise AccessError('Не удалось безопасно выбрать новый слот доступа.')
        lan=[row for row in lanes if len(row)>=3 and row[2]=='br0' and re.fullmatch(r'[1-9]\d*-[1-9]\d*',str(row[0]))]
        if len(lan)!=1:raise AccessError('Не распознан основной LAN-интерфейс. WAN автоматически не используется.')
        first,second=lan[0][0].split('-');interface=f'InternetGatewayDevice.LANDevice.{first}.LANHostConfigManagement.IPInterface.{second}'
        with socket.create_connection((self.host,80),timeout=5) as sock:client=local_address(sock.getsockname()[0])
        index=len(rows)+1
        fields={'sessionKey':self.session_key(),'setPath':f'/InternetGatewayDevice/UserInterface/RemoteAccess:{index}/','IP':client,'Mask':'255.255.255.255','Protocol':'SSH','Enable':'1','Port':'22','Interface':interface,'endSetPath':'1','CMT':'0','APPLY':'1'}
        vendor=re.search(r'&([A-Za-z_][A-Za-z0-9_]*mode)=',page)
        if vendor:fields[vendor[1]]='accept'
        self.fetch('/maintenance/mt_acremote_tl.xgi?'+urllib.parse.urlencode(fields))
        # Read-back protects against a rejected request; never trust HTTP 200 alone.
        after=self.array(self.fetch('/maintenance/mt_acremote_tl.htm').decode(errors='replace'),'dataLists')
        wanted=after[index-1] if len(after)>=index else []
        good=len(wanted)>=6 and wanted[:6]==['1',client,'255.255.255.255','22','SSH',interface]
        if after[:len(rows)]!=rows or not good:raise AccessError('Изменение доступа не подтверждено; проверьте форму роутера.')
        for _ in range(10):
            if ssh_open(self.host):return True
            time.sleep(1)
        # Roll back only our exact new row, after checking that no other writer
        # changed the table. An ambiguous read retains the row for manual recovery.
        current=self.array(self.fetch('/maintenance/mt_acremote_tl.htm').decode(errors='replace'),'dataLists')
        if current!=after or '&del/InternetGatewayDevice/UserInterface/RemoteAccess:' not in page:
            raise AccessError('SSH не отвечает; автоматическая очистка небезопасна. Проверьте добавленное LAN-правило в веб-интерфейсе.')
        delete={'sessionKey':self.session_key(),f'del/InternetGatewayDevice/UserInterface/RemoteAccess:{index}':'1','CMT':'0','APPLY':'1'}
        self.fetch('/maintenance/mt_acremote_tl.xgi?'+urllib.parse.urlencode(delete))
        restored=self.array(self.fetch('/maintenance/mt_acremote_tl.htm').decode(errors='replace'),'dataLists')
        if restored!=rows:raise AccessError('Не подтверждён откат нового LAN-правила. Проверьте веб-интерфейс.')
        raise AccessError('SSH не отвечает; добавленное LAN-правило удалено, прежние правила сохранены.')

def ssh_open(host):
    try:
        with socket.create_connection((local_address(host),22),timeout=1) as s:
            s.settimeout(1);return s.recv(64).startswith(b'SSH-')
    except OSError:return False

def gateway_candidates():
    commands=[]
    if os.name=='nt':commands=[['powershell','-NoProfile','-Command',"Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -ExpandProperty NextHop"]]
    elif os.uname().sysname=='Darwin':commands=[['route','-n','get','default'],['arp','-an']]
    else:commands=[['ip','-j','route','show','default'],['ip','-j','neigh']]
    values=[]
    for cmd in commands:
        try:output=subprocess.check_output(cmd,text=True,stderr=subprocess.DEVNULL,timeout=5)
        except (OSError,subprocess.SubprocessError):continue
        for value in re.findall(r'(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])',output):
            try:value=local_address(value)
            except AccessError:continue
            if value not in values and not value.startswith('127.'):values.append(value)
    if '192.168.1.1' not in values:values.append('192.168.1.1')
    return values[:16]

def discover(candidates=None):
    def probe(host):
        try:WebAccess(host).identify();return host
        except AccessError:return None
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        return [host for host in pool.map(probe,candidates or gateway_candidates()) if host]

class RouterSSH:
    def __init__(self,host,password,state_dir,username='superadmin'):
        import paramiko
        self.host=local_address(host);self.transport=None
        sock=socket.create_connection((self.host,22),timeout=8)
        t=paramiko.Transport(sock);self.transport=t
        try:
            # Compatibility belongs to this connection, never ~/.ssh/config.
            options=t.get_security_options()
            if 'diffie-hellman-group1-sha1' not in options.kex:options.kex=options.kex+('diffie-hellman-group1-sha1',)
            if 'ssh-rsa' not in options.key_types:options.key_types=options.key_types+('ssh-rsa',)
            t.start_client(timeout=8);key=t.get_remote_server_key().get_base64()
            state=pathlib.Path(state_dir);state.mkdir(parents=True,exist_ok=True,mode=0o700)
            pins=state/'ssh-host-keys.json';known=json.loads(pins.read_text()) if pins.exists() else {}
            if self.host in known and known[self.host]!=key:raise AccessError('SSH-ключ роутера изменился. Подключение остановлено до передачи пароля.')
            if self.host not in known:
                known[self.host]=key
                temporary=state/('keys-'+secrets.token_hex(8)+'.tmp')
                with temporary.open('x') as f:json.dump(known,f)
                temporary.chmod(0o600);temporary.replace(pins)
            t.auth_password(username,password)
            if not t.is_authenticated():raise AccessError('SSH-пароль не принят.')
        except Exception as e:
            t.close()
            if isinstance(e,AccessError):raise
            raise AccessError('Не удалось подключиться по SSH. Проверьте пароль и доступ.') from None
    def close(self):
        if self.transport:self.transport.close()
    def alive(self):
        return bool(self.transport and self.transport.is_active() and self.transport.is_authenticated())
    def run(self,script,data=None,timeout=180,check=True):
        import paramiko
        channel=None
        try:
            channel=self.transport.open_session(timeout=8);channel.settimeout(8)
            channel.exec_command('/bin/ash -c '+shlex.quote(script))
            if data:channel.sendall(data)
            channel.shutdown_write();out=bytearray();err=bytearray();deadline=time.monotonic()+timeout
            while not channel.exit_status_ready() or channel.recv_ready() or channel.recv_stderr_ready():
                if channel.recv_ready():out.extend(channel.recv(65536))
                if channel.recv_stderr_ready():err.extend(channel.recv_stderr(65536))
                if len(out)>MAX_CONFIG or len(err)>1048576:raise AccessError('Ответ SSH слишком большой.')
                if time.monotonic()>deadline:raise AccessError('SSH-команда не завершилась вовремя; проверьте журнал восстановления.')
                time.sleep(.01)
            status=channel.recv_exit_status()
            if check and status:raise AccessError(f'Операция роутера завершилась ошибкой {status}. Данные восстановления сохранены, если операция началась.')
            return status,bytes(out),bytes(err)
        except (paramiko.SSHException,OSError,EOFError):
            raise AccessError('Соединение SSH прервалось. Подключитесь к роутеру заново. Если установка уже началась, сначала проверьте данные восстановления.') from None
        finally:
            if channel:
                try:channel.close()
                except Exception:pass
