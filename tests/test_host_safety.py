import os,pathlib,subprocess,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class HostSafetyTests(unittest.TestCase):
 def run_shell(self,body,env=None):
  return subprocess.run(['bash','-c',f'source "{ROOT}/g84-zapret2.sh"\n'+body],env=env,capture_output=True,text=True)
 def test_dry_run_never_calls_mutating_helpers(self):
  r=self.run_shell('''DRY_RUN=1
preflight_install() { :; }
detect_wan() { echo nas1; }
find_appmgr_slots() { echo '1 2'; }
nfqueue_preflight() { echo MUTATION >&2; return 99; }
backup_router() { echo MUTATION >&2; return 99; }
upload_payload() { echo MUTATION >&2; return 99; }
install_zapret2''')
  self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn('MUTATION',r.stderr)
 def test_shell_retention_keeps_ten_complete_pairs(self):
  with tempfile.TemporaryDirectory() as d:
   p=pathlib.Path(d)
   for i in range(12):
    stamp=f'20260101-000000-{i}'
    for prefix,ext in [('g84-config','xml'),('g84-zapret2','tar.gz')]:
     file=p/f'{prefix}-{stamp}.{ext}';file.write_text('x');os.utime(file,(100+i,100+i))
   r=self.run_shell('BACKUP_DIR="$TEST_BACKUPS"; prune_backups',dict(os.environ,TEST_BACKUPS=d))
   self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(len(list(p.glob('*.xml'))),10);self.assertEqual(len(list(p.glob('*.tar.gz'))),10)
   self.assertFalse((p/'g84-config-20260101-000000-0.xml').exists())
 def test_status_and_dry_run_do_not_require_nc(self):
  for action,dry,status in [('status',0,0),('install',1,0),('install',0,10)]:
   body=f"""ACTION={action}; DRY_RUN={dry}
command() {{ if [[ "$2" = nc ]]; then return 1; else builtin command "$@"; fi; }}
check_dependencies"""
   r=self.run_shell(body);self.assertEqual(r.returncode,status,r.stderr)
