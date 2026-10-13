import copy, json, os, pathlib, shutil, subprocess, sys, tempfile, time, unittest

REPO=pathlib.Path(__file__).resolve().parents[1]
VERSION=(REPO/'router/VERSION').read_text().strip()
WORK=pathlib.Path(tempfile.mkdtemp(prefix='g84-tests-'))
HELPER=WORK/'g84-lock'
subprocess.run([os.environ.get('CC','cc'),'-std=c99','-Wall','-Wextra','-Werror',
                str(REPO/'native/g84-lock.c'),'-o',str(HELPER)],check=True)

class Firmware:
    def __init__(self, existing=True):
        self.temp=tempfile.TemporaryDirectory(prefix='g84-firmware-')
        self.home=pathlib.Path(self.temp.name)
        self.base=self.home/'zapret2'; self.stage=self.home/'stage'
        self.proc=self.home/'proc';self.tmp=self.home/'tmp';self.bin=self.home/'bin'
        for p in (self.stage,self.proc/'net/netfilter',self.tmp,self.bin):p.mkdir(parents=True)
        for path in REPO.joinpath('router').iterdir():
            if path.is_file():shutil.copy2(path,self.stage/path.name)
        shutil.copy2(HELPER,self.stage/'g84-lock')
        (self.stage/'nfqws2').write_text('#!/bin/sh\nexit 0\n')
        for name in ['zapret-lib.lua','zapret-antidpi.lua','zapret-auto.lua']:(self.stage/name).write_text('-- fixture\n')
        # Production uses bundled ash; use the host POSIX shell for simulation.
        for p in self.stage.glob('*.sh'):
            p.write_text(p.read_text().replace('#!/bin/ash','#!/bin/sh',1));p.chmod(0o755)
        (self.stage/'nfqws2').chmod(0o755)
        if existing:
            shutil.copytree(self.stage,self.base)
            (self.base/'VERSION').write_text('0.3.0\n')
            (self.base/'appmgr-slots').write_text('NFQWS_SLOT=1\nWATCH_SLOT=2\n')
        scripts=['cp','chmod','mv','sleep','csmconf','csmctl','appmgrcmd','iptables','ip6tables']
        mock=(REPO/'tests/mock-firmware.py').read_text().replace('#!/usr/bin/env python3','#!'+sys.executable,1)
        for name in scripts:
            p=self.bin/name;p.write_text(mock);p.chmod(0o755)
        self.env=dict(os.environ,Z2_BASE=str(self.base),Z2_STAGE=str(self.stage),
                      Z2_TMP=str(self.tmp),Z2_PROC=str(self.proc),Z2_SHELL='/bin/sh',
                      MOCK_HOME=str(self.home),PATH=str(self.bin)+os.pathsep+os.environ['PATH'])
        slots={}
        if existing:
            for i,name,script in [(1,'zapret2','run.sh'),(2,'zapret2-rules','watch-rules.sh')]:
                slots[f'appmgr:{i}']=dict(name=name,path=str(self.base/script),argument='legacy-start',
                                         auto_start='0',crash_start='0',custom='untouched')
        state=dict(slots=slots,active={'zapret2':False,'zapret2-rules':False},starts=[],failures=[],
                   tables={t:{c:[] for c in ['POSTROUTING','FORWARD','INPUT']} for t in ['iptables','ip6tables']})
        (self.home/'state.json').write_text(json.dumps(state))
        (self.proc/'net/netfilter/nfnetlink_queue').write_text('')
        if existing:
            for name,script in [('zapret2','run.sh'),('zapret2-rules','watch-rules.sh')]:
                subprocess.run([str(self.bin/'appmgrcmd'),'add',name,str(self.base/script),'legacy-start','0'],env=self.env,capture_output=True)
        self.original=copy.deepcopy(self.state())
    def state(self):return json.loads((self.home/'state.json').read_text())
    def run(self, script, *args, fault=None):
        env=dict(self.env)
        if fault:env['FAIL_AT']=fault
        return subprocess.run(['/bin/sh',str(script),*args],env=env,capture_output=True,text=True,timeout=45)
    def install(self,fault=None):return self.run(self.stage/'install-transaction.sh','install','nas1','1','1','2',VERSION,fault=fault)
    def assert_original(self,case):
        now=self.state()
        case.assertEqual(now['slots'],self.original['slots'])
        case.assertEqual(now['active'],self.original['active'])
        case.assertEqual(now['tables'],self.original['tables'])
        if self.base.exists():case.assertEqual((self.base/'VERSION').read_text().strip(),'0.3.0')
    def close(self):self.temp.cleanup()

class VerifyTests(unittest.TestCase):
    def setUp(self):self.f=Firmware()
    def tearDown(self):self.f.close()
    def verify(self):return self.f.run(self.f.base/'verify.sh')
    def test_healthy(self):self.assertEqual(self.verify().returncode,0)
    def test_missing_binary(self):
        (self.f.base/'nfqws2').unlink();self.assertNotEqual(self.verify().returncode,0)
    def test_missing_process_even_with_last_jump(self):
        (self.f.proc/'90001/cmdline').unlink();(self.f.proc/'90002/cmdline').unlink()
        self.assertNotEqual(self.verify().returncode,0)
    def test_unrelated_pid_containing_binary_path(self):
        (self.f.proc/'90001/cmdline').write_bytes(('/bin/cat\0'+str(self.f.base/'nfqws2')+'\0').encode())
        self.assertNotEqual(self.verify().returncode,0)
    def test_wrong_queue_owner(self):
        (self.f.proc/'net/netfilter/nfnetlink_queue').write_text('200 888 0 2 65531 0 0 0 1\n')
        self.assertNotEqual(self.verify().returncode,0)
    def test_each_rule_and_jump_required_in_both_families(self):
        snapshot=self.f.state()
        for family,chains in snapshot['tables'].items():
            for chain,rules in chains.items():
                for i in range(len(rules)):
                    with self.subTest(family=family,chain=chain,index=i):
                        altered=copy.deepcopy(snapshot);del altered['tables'][family][chain][i]
                        (self.f.home/'state.json').write_text(json.dumps(altered))
                        self.assertNotEqual(self.verify().returncode,0)
        (self.f.home/'state.json').write_text(json.dumps(snapshot))
    def test_duplicate_jump_fails(self):
        d=self.f.state();d['tables']['iptables']['INPUT']*=2
        (self.f.home/'state.json').write_text(json.dumps(d))
        self.assertNotEqual(self.verify().returncode,0)
    def test_host_verify_propagates_failure(self):
        code=f'source "{REPO}/g84-zapret2.sh"; remote() {{ return 1; }}; verify'
        result=subprocess.run(['bash','-c',code],capture_output=True)
        self.assertNotEqual(result.returncode,0)

class RebootTests(unittest.TestCase):
    def run_wait(self, current, verify_status=0):
        previous='11111111-1111-1111-1111-111111111111'
        code=f"""source '{REPO}/g84-zapret2.sh'
sleep() {{ :; }}
c=0
port_open() {{ c=$((c+1)); test "$c" -gt 1; }}
remote() {{ printf '%s\\n' '{current}'; }}
verify() {{ return {verify_status}; }}
wait_after_reboot '{previous}'
"""
        return subprocess.run(['bash','-c',code],capture_output=True)
    def test_same_boot_is_not_success(self):
        self.assertNotEqual(self.run_wait('11111111-1111-1111-1111-111111111111').returncode,0)
    def test_new_boot_propagates_verify_failure(self):
        self.assertNotEqual(self.run_wait('22222222-2222-2222-2222-222222222222',1).returncode,0)
    def test_new_boot_and_healthy_service(self):
        self.assertEqual(self.run_wait('22222222-2222-2222-2222-222222222222').returncode,0)

class TransactionTests(unittest.TestCase):
    def test_success(self):
        f=Firmware()
        try:
            r=f.install();self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual((f.base/'VERSION').read_text().strip(),VERSION)
            self.assertEqual(f.base.stat().st_mode & 0o777,0o755)
            self.assertTrue(pathlib.Path(str(f.base)+'.old').exists())
            self.assertEqual(f.state()['slots']['appmgr:1']['auto_start'],'1')
            self.assertEqual(f.run(f.base/'verify.sh').returncode,0)
        finally:f.close()
    def test_failure_restores_files_slots_rules_and_running_services(self):
        for point in ['copy','chmod','rename-old','rename-new','register','save','start','verify']:
            with self.subTest(point=point):
                f=Firmware()
                try:
                    r=f.install(point);self.assertNotEqual(r.returncode,0,r.stdout)
                    self.assertIn('Rollback completed',r.stderr)
                    f.assert_original(self)
                    self.assertTrue(f.stage.exists())
                    # Recovery is idempotent; it must not move/delete restored files.
                    recover=pathlib.Path(str(f.base)+'.transaction')/'recover.sh'
                    self.assertEqual(f.run(recover,'recover').returncode,0)
                    f.assert_original(self)
                finally:f.close()
    def test_fresh_partial_registration_removes_new_slots(self):
        f=Firmware(existing=False)
        try:
            r=f.install('register');self.assertNotEqual(r.returncode,0)
            self.assertEqual(f.state()['slots'],{})
            self.assertFalse(f.base.exists())
        finally:f.close()
    def test_rollback_failure_is_explicit_and_recoverable(self):
        f=Firmware()
        try:
            r=f.install('rollback');self.assertEqual(r.returncode,52,r.stderr)
            self.assertIn('ROLLBACK FAILED',r.stderr)
            recovery=pathlib.Path(str(f.base)+'.transaction')/'recover.sh'
            self.assertTrue(recovery.exists())
            r=f.run(recovery,'recover');self.assertEqual(r.returncode,0,r.stderr)
            f.assert_original(self)
        finally:f.close()
    def test_preparation_failure_does_not_stop_old_service(self):
        f=Firmware()
        try:
            (f.stage/'nfqws2').write_text('#!/bin/sh\nexit 8\n')
            r=f.install();self.assertNotEqual(r.returncode,0)
            f.assert_original(self)
        finally:f.close()
    def test_previously_stopped_services_remain_stopped(self):
        f=Firmware()
        try:
            for name in ['zapret2','zapret2-rules']:
                subprocess.run([str(f.bin/'appmgrcmd'),'stop',name],env=f.env,capture_output=True)
            f.original=copy.deepcopy(f.state())
            r=f.install('register');self.assertNotEqual(r.returncode,0)
            f.assert_original(self)
        finally:f.close()
    def test_check_mode_validates_without_rules_or_existing_pid_shortcut(self):
        f=Firmware()
        try:
            nfq=f.base/'nfqws2'
            nfq.write_text('#!/bin/sh\ncase "$*" in *--intercept=0*) exit 9 ;; *) exit 8 ;; esac\n')
            snapshot=copy.deepcopy(f.state())
            r=f.run(f.base/'run.sh','check');self.assertEqual(r.returncode,9)
            self.assertEqual(f.state(),snapshot)
        finally:f.close()
    def test_missing_snapshot_field_fails_closed(self):
        f=Firmware()
        try:
            d=f.state();del d['slots']['appmgr:1']['argument']
            (f.home/'state.json').write_text(json.dumps(d));f.original=copy.deepcopy(d)
            r=f.install();self.assertNotEqual(r.returncode,0)
            self.assertIn('before service changes',r.stderr)
            f.assert_original(self)
        finally:f.close()

class UpgradeSettingsTests(unittest.TestCase):
    def test_preserves_user_files_verbatim(self):
        f=Firmware()
        try:
            files={'config':(f.base/'config').read_bytes()+b"\nDEBUG_LOG=1\nQNUM=701\nMARK=0x80000000\n# custom setting\nCUSTOM_OPTION=retained\n",
                   'hosts.txt':b'custom.example\n', 'hosts-exclude.txt':b'private.example\n'}
            for name,data in files.items():(f.base/name).write_bytes(data)
            (f.base/'config').chmod(0o600)
            r=f.install();self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual((f.base/'config').stat().st_mode & 0o777,0o600)
            for name,data in files.items():self.assertEqual((f.base/name).read_bytes(),data)
        finally:f.close()
    def test_preservation_failure_leaves_old_service_untouched(self):
        f=Firmware()
        try:
            (f.base/'hosts.txt').write_text('custom.example\n')
            r=f.install('preserve');self.assertNotEqual(r.returncode,0)
            f.assert_original(self)
            self.assertEqual((f.base/'hosts.txt').read_text(),'custom.example\n')
        finally:f.close()
    def test_explicit_wan_override_preserves_other_settings(self):
        f=Firmware()
        try:
            config=(f.base/'config').read_text()+'\nDEBUG_LOG=1\n'
            (f.base/'config').write_text(config)
            r=f.run(f.stage/'install-transaction.sh','install','wan9','1','1','2',VERSION,'1')
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual((f.base/'config').read_text(),config+'\nWAN=wan9\n')
        finally:f.close()
    def test_does_not_enable_user_disabled_ipv6(self):
        f=Firmware()
        try:
            config=(f.base/'config').read_text().replace('ENABLE_IPV6=1','ENABLE_IPV6=0')
            (f.base/'config').write_text(config)
            r=f.install();self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual((f.base/'config').read_text(),config)
        finally:f.close()

class UninstallTests(unittest.TestCase):
    def setUp(self):self.f=Firmware()
    def tearDown(self):self.f.close()
    def uninstall(self,fault=None):
        env=dict(self.f.env)
        if fault:env['FAIL_AT']=fault
        code=rf"""source '{REPO}/g84-zapret2.sh'
NO_REBOOT=1
backup_router() {{ :; }}
remote() {{
    if [ "${{FAIL_AT:-}}" = ssh ]; then return 255; fi
    script="${{1//\/var\/SaaS\/zapret2/$Z2_BASE}}"
    /bin/sh -c "$script"
}}
uninstall_zapret2
"""
        return subprocess.run(['bash','-c',code],env=env,capture_output=True,text=True)
    def test_transport_failure_is_not_absence(self):
        r=self.uninstall('ssh');self.assertEqual(r.returncode,53)
        self.assertNotIn('already absent',r.stdout);self.assertTrue(self.f.base.exists())
        self.f.assert_original(self)
    def test_confirmed_absence(self):
        shutil.rmtree(self.f.base)
        r=self.uninstall();self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('already absent',r.stdout)
    def test_mapping_read_failure_keeps_files(self):
        (self.f.base/'appmgr-slots').unlink()
        r=self.uninstall();self.assertNotEqual(r.returncode,0);self.f.assert_original(self)
    def test_read_failures_before_mutation(self):
        for fault in ['slot-read','slot-path-read']:
            r=self.uninstall(fault);self.assertEqual(r.returncode,53,r.stderr)
            self.assertTrue(self.f.base.exists());self.f.assert_original(self)
    def test_delete_readback_and_save_failures_keep_files(self):
        for fault in ['slot-delete','slot-readback','save']:
            with self.subTest(fault=fault):
                f=Firmware();original=self.f;self.f=f
                try:
                    r=self.uninstall(fault);self.assertEqual(r.returncode,53,r.stderr)
                    self.assertTrue(f.base.exists())
                finally:f.close();self.f=original
    def test_foreign_slot_is_refused(self):
        d=self.f.state();d['slots']['appmgr:1']['name']='another-service'
        (self.f.home/'state.json').write_text(json.dumps(d));self.f.original=copy.deepcopy(d)
        r=self.uninstall();self.assertEqual(r.returncode,53);self.f.assert_original(self)
    def test_invalid_mapping_is_refused(self):
        (self.f.base/'appmgr-slots').write_text('NFQWS_SLOT=17\nWATCH_SLOT=2\n')
        r=self.uninstall();self.assertEqual(r.returncode,53);self.f.assert_original(self)
    def test_success_removes_only_project(self):
        d=self.f.state();d['slots']['appmgr:3']={'name':'another-service'}
        (self.f.home/'state.json').write_text(json.dumps(d))
        r=self.uninstall();self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse(self.f.base.exists())
        self.assertEqual(self.f.state()['slots'],{'appmgr:3':{'name':'another-service'}})

class LockTests(unittest.TestCase):
    def test_serializes_competing_owners(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)
            code='import pathlib,time,sys; p=pathlib.Path(sys.argv[1]); (p/"critical").mkdir(); time.sleep(.025); (p/"critical").rmdir()'
            jobs=[subprocess.Popen([str(HELPER),str(p/'lock'),'10',sys.executable,'-c',code,d],stderr=subprocess.PIPE) for _ in range(12)]
            for j in jobs:
                _,err=j.communicate(timeout=15)
                self.assertEqual(j.returncode,0,err.decode())
    def test_timeout_then_kernel_releases_after_sigkill(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d);ready=p/'ready';lock=p/'lock'
            code='import pathlib,time,sys; pathlib.Path(sys.argv[1]).touch(); time.sleep(20)'
            holder=subprocess.Popen([str(HELPER),str(lock),'0',sys.executable,'-c',code,str(ready)])
            try:
                for _ in range(100):
                    if ready.exists():break
                    time.sleep(.01)
                self.assertTrue(ready.exists())
                r=subprocess.run([str(HELPER),str(lock),'0',shutil.which('true')],capture_output=True)
                self.assertEqual(r.returncode,75)
                inode=lock.stat().st_ino
                holder.kill();holder.wait()
                self.assertEqual(subprocess.run([str(HELPER),str(lock),'1',shutil.which('true')]).returncode,0)
                self.assertEqual(inode,lock.stat().st_ino)
            finally:
                if holder.poll() is None:holder.kill();holder.wait()

if __name__=='__main__':
    try:unittest.main(verbosity=2)
    finally:shutil.rmtree(WORK)
