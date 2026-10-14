import importlib.util, pathlib, sys, tempfile, threading, time, unittest
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'desktop'))
try:
 from g84_setup.access import AccessError,account_password
 from g84_setup.manager import Manager,prune_backups
 from g84_setup.app import Application
 AVAILABLE=True
except ImportError:AVAILABLE=False

@unittest.skipUnless(AVAILABLE,'desktop dependencies required')
class DesktopTests(unittest.TestCase):
 def test_failed_access_invalidates_existing_session(self):
  with tempfile.TemporaryDirectory() as d,patch.dict('os.environ',{'G84_DATA_DIR':d}):
   app=Application();app.ready=True
   with patch.object(app.manager,'bootstrap',side_effect=AccessError('failed')):
    app.job('access',{'host':'192.168.1.1'})
    deadline=time.monotonic()+2
    while app.busy and time.monotonic()<deadline:time.sleep(.01)
   self.assertFalse(app.ready)
 def test_duplicate_slot_mapping_refused_before_backup(self):
  with tempfile.TemporaryDirectory() as d:
   m=Manager(state_dir=d)
   class SSH:
    def run(self,script,**kw):
     if script.startswith('test -d'):return 0,b'',b''
     return 0,b'NFQWS_SLOT=1\nNFQWS_SLOT=2\nWATCH_SLOT=3\n',b''
   m.ssh=SSH()
   with patch.object(m,'backup',side_effect=AssertionError('mutation before validation')):
    with self.assertRaises(AccessError):m.uninstall()
 def test_backup_retention_uses_pairs_and_mtime(self):
  import os
  with tempfile.TemporaryDirectory() as d:
   p=pathlib.Path(d)
   for i in range(12):
    stamp=f'20260101-000000-{i}'
    xml=p/f'g84-config-{stamp}.xml';xml.write_bytes(b'x');os.utime(xml,(100+i,100+i))
    (p/f'g84-zapret2-{stamp}.tar.gz').write_bytes(b'x')
   prune_backups(p)
   self.assertEqual(len(list(p.glob('*.xml'))),10)
   self.assertEqual(len(list(p.glob('*.tar.gz'))),10)
   self.assertFalse((p/'g84-config-20260101-000000-0.xml').exists())
 def test_account_boundaries_and_invalid_native_tag(self):
  xml=b'<root><2G/><user><M-O-N><name>admin</name><password>wrong</password></M-O-N><M-O-N><name>superadmin</name><password>right</password></M-O-N></user></root>'
  self.assertEqual(account_password(xml),'right')
 def test_entity_configuration_refused(self):
  with self.assertRaises(AccessError):account_password(b'<!DOCTYPE r [<!ENTITY x "secret">]><r/>')

@unittest.skipUnless(AVAILABLE,'desktop dependencies required')
class HttpBoundaryTests(unittest.TestCase):
 def test_api_requires_token_and_local_origin(self):
  import http.client
  from http.server import ThreadingHTTPServer
  from g84_setup.app import Handler
  with tempfile.TemporaryDirectory() as d,patch.dict('os.environ',{'G84_DATA_DIR':d}):
   server=ThreadingHTTPServer(('127.0.0.1',0),Handler);server.app=Application()
   worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
   try:
    for headers,status in [({},403),({'Authorization':'Bearer '+server.app.token,'Origin':'https://example.com'},403),({'Authorization':'Bearer '+server.app.token},200)]:
     c=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=2);c.request('GET','/state',headers=headers);r=c.getresponse();self.assertEqual(r.status,status);r.read();c.close()
   finally:server.shutdown();server.server_close();worker.join(2)
 def test_legacy_encrypted_export_roundtrip(self):
  import gzip,hashlib
  from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes
  from cryptography.hazmat.primitives import padding
  raw=b'<r><user><M-O-N><name>superadmin</name><password>fixture-secret</password></M-O-N></user></r>'
  salt=b'12345678';material=b'';previous=b''
  while len(material)<48:
   previous=hashlib.md5(previous+b'InnboxG84'+salt).digest();material+=previous
  pad=padding.PKCS7(128).padder();payload=pad.update(gzip.compress(raw))+pad.finalize()
  encrypt=Cipher(algorithms.AES(material[:32]),modes.CBC(material[32:48])).encryptor()
  encoded=b'firmware-prefix'+b'Salted__'+salt+encrypt.update(payload)+encrypt.finalize()
  self.assertEqual(account_password(encoded),'fixture-secret')

@unittest.skipUnless(AVAILABLE,'desktop dependencies required')
class WebAccessTests(unittest.TestCase):
 def test_enable_is_lan_only_and_failure_restores_previous_table(self):
  import json,urllib.parse
  from g84_setup.access import WebAccess
  interface='InternetGatewayDevice.LANDevice.1.LANHostConfigManagement.IPInterface.1'
  old=[['1','192.168.1.2','255.255.255.255','443','HTTPS',interface,'LAN','1','br0','accept']]
  new=['1','192.168.1.9','255.255.255.255','22','SSH',interface,'LAN','1','br0','accept']
  for available in [True,False]:
   with self.subTest(available=available):
    rows=[r[:] for r in old];calls=[]
    web=WebAccess('192.168.1.1')
    def page():return ('mt_acremote_tl.xgi? get_Interface("LAN","ins4" &del/InternetGatewayDevice/UserInterface/RemoteAccess: &X_mode= var lan_lists = [["1-1","LAN0","br0"]]; var data_count = parseInt("'+str(len(rows))+'"); var dataLists = '+json.dumps(rows)+';').encode()
    def fetch(path,**kw):
     if path.startswith('/maintenance/mt_acremote_tl.xgi?'):
      fields=urllib.parse.parse_qs(urllib.parse.urlsplit(path).query,keep_blank_values=True);calls.append(fields)
      if 'setPath' in fields:rows.append(new[:])
      else:rows.pop()
     return page()
    class Socket:
     def __enter__(self):return self
     def __exit__(self,*args):pass
     def getsockname(self):return ('192.168.1.9',12345)
    with patch.object(web,'fetch',side_effect=fetch),patch.object(web,'session_key',return_value='fixture'),patch('g84_setup.access.socket.create_connection',return_value=Socket()),patch('g84_setup.access.time.sleep'),patch('g84_setup.access.ssh_open',side_effect=[False]+[available]*10):
     if available:self.assertTrue(web.enable_ssh())
     else:
      with self.assertRaisesRegex(AccessError,'удалено'):web.enable_ssh()
    fields=calls[0]
    self.assertEqual(fields['Interface'],[interface]);self.assertEqual(fields['Mask'],['255.255.255.255']);self.assertEqual(fields['IP'],['192.168.1.9'])
    self.assertEqual(rows,old+[new] if available else old)

@unittest.skipUnless(AVAILABLE,'desktop dependencies required')
class RetryLoginTests(unittest.TestCase):
 def test_retry_form_uses_its_endpoint_and_hash_without_clear_password(self):
  import urllib.parse,hashlib
  from g84_setup.access import WebAccess
  web=WebAccess('192.168.1.1');posts=[]
  def fetch(path,data=None,**kw):
   if data:posts.append((path,urllib.parse.parse_qs(data.decode(),keep_blank_values=True)))
   if path=='/':return b'<title>InnboxG84</title>'
   if path=='/old_login.htm':return b'self.location.href="/old_login_error.htm";'
   if path=='/old_login_error.htm':return b'<form action="/login_error.htm"> f.pwd.value = "";'
   return b'save_old_cfg config_old_tl.xgi'
  with patch.object(web,'fetch',side_effect=fetch):web.login('admin','test-secret')
  self.assertEqual(posts,[('/login_error.htm',dict(f_username=['admin'],pwd=[''],f_password=[hashlib.md5(b'test-secret').hexdigest()]))])
