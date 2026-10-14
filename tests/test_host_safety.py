import os,pathlib,subprocess,sys,tempfile,unittest
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

 def test_slot_discovery_rejects_duplicate_and_malformed_tables(self):
  healthy=[f'{i}:' for i in range(1,17)]
  for label,lines in [('duplicate service',['1:zapret2','2:zapret2']+healthy[2:]),('duplicate index',['1:','1:']+healthy[2:]),('reordered',healthy[::-1]),('missing separator',['1']+healthy[1:]),('duplicate watcher',['1:zapret2-rules','2:zapret2-rules']+healthy[2:])]:
   with self.subTest(label=label):
    table='\n'.join(lines)
    r=self.run_shell('remote() { printf "%s\\n" "$TEST_SLOTS"; }; find_appmgr_slots',dict(os.environ,TEST_SLOTS=table))
    self.assertNotEqual(r.returncode,0,r.stdout)
 def test_reboot_wait_tolerates_old_boot_and_transient_ssh_failure(self):
  body='''sleep() { :; }
port_open() { return 0; }
verify() { return 0; }
# A subshell cannot keep a counter, so the stub uses a small state file.
remote() { n=$(cat "$TEST_COUNTER"); n=$((n+1)); echo "$n" > "$TEST_COUNTER"; case "$n" in 1) return 255 ;; 2) echo old ;; *) echo new ;; esac; }
wait_after_reboot old'''
  with tempfile.TemporaryDirectory() as d:
   counter=pathlib.Path(d)/'counter';counter.write_text('0')
   r=self.run_shell(body,dict(os.environ,TEST_COUNTER=str(counter)))
   self.assertEqual(r.returncode,0,r.stderr)
 def test_slot_discovery_accepts_free_and_owned_tables(self):
  for first,second in [('', ''),('zapret2','zapret2-rules')]:
   table='\n'.join([f'1:{first}',f'2:{second}']+[f'{i}:foreign' for i in range(3,17)])
   r=self.run_shell('remote() { printf "%s\\n" "$TEST_SLOTS"; }; find_appmgr_slots',dict(os.environ,TEST_SLOTS=table))
   self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(r.stdout.strip(),'1 2')
 def test_shell_export_is_contained_and_cleaned_on_failure(self):
  for failure in [False,True]:
   with self.subTest(failure=failure),tempfile.TemporaryDirectory() as d:
    root=pathlib.Path(d);router=root/'router';router.mkdir()
    csm=root/'csmconf'
    csm.write_text('#!'+sys.executable+'''
import os,pathlib,sys
p=pathlib.Path(sys.argv[2]);p.write_bytes(b'fixture-config')
p.chmod(0o644) # Real csmconf ignores umask.
pathlib.Path(os.environ['TEST_MODE']).write_text(str(p.parent.stat().st_mode & 0o777))
raise SystemExit(9 if os.environ['TEST_EXPORT_FAIL']=='1' else 0)
''');csm.chmod(0o755)
    body=r'''BACKUP_DIR="$TEST_BACKUPS"
remote() {
 if [[ "$1" == 'test -d /var/SaaS/zapret2' ]]; then return 1; fi
 script="${1//\/var\/tmp/$TEST_ROUTER_TMP}"
 /bin/sh -c "$script"
}
backup_router'''
    env=dict(os.environ,PATH=str(root)+os.pathsep+os.environ['PATH'],TEST_BACKUPS=str(root/'backups'),TEST_ROUTER_TMP=str(router),TEST_MODE=str(root/'mode'),TEST_EXPORT_FAIL=str(int(failure)))
    r=self.run_shell(body,env)
    self.assertEqual(r.returncode,38 if failure else 0,r.stderr)
    self.assertEqual((root/'mode').read_text(),str(0o700))
    self.assertEqual(list(router.iterdir()),[])
