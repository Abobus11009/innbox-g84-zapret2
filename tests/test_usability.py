"""Regression checks for user-visible state and safe operation boundaries."""
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'setup'))
from g84_setup.app import Application
from g84_setup.access import AccessError
from g84_setup.manager import Manager


def done(app):
    deadline = time.monotonic() + 3
    while app.busy and time.monotonic() < deadline:
        time.sleep(.01)
    if app.busy:
        raise AssertionError('Test operation did not finish')


class WizardStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {'G84_DATA_DIR':self.temp.name})
        self.env.start()
        self.app = Application()
        self.app.manager.host = '192.168.1.1'
        self.app.ready = True

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def test_failed_operation_is_explicit_and_stays_after_reading_state(self):
        with patch.object(self.app.manager, 'verify', side_effect=AccessError('fixture failure')):
            job_id = self.app.job('verify', {'host':'192.168.1.1'})
            done(self.app)
        first = self.app.snapshot()
        self.assertFalse(first['busy'])
        self.assertEqual(first['operation'], dict(id=job_id, action='verify', status='error', message='fixture failure'))
        self.assertEqual(self.app.snapshot()['operation'], first['operation'])

    def test_unexpected_error_diagnostics_do_not_include_secret_values(self):
        with patch.object(self.app.manager, 'verify', side_effect=KeyError('fixture-secret')):
            self.app.job('verify', {'host':'192.168.1.1'})
            done(self.app)
        state = self.app.snapshot()
        self.assertEqual(state['operation']['error_type'], 'KeyError')
        self.assertNotIn('fixture-secret', str(state))

    def test_cleanup_warning_is_visible_in_operation_result(self):
        with patch.object(self.app.manager, 'install', return_value={'cleanup_pending':True, 'message':'fixture cleanup warning'}):
            self.app.job('install', {'host':'192.168.1.1'})
            done(self.app)
        self.assertEqual(self.app.snapshot()['operation']['message'], 'fixture cleanup warning')
        self.assertTrue(self.app.snapshot()['result']['cleanup_pending'])

    def test_recovery_does_not_keep_the_newer_version_on_screen(self):
        self.app.device = {'installed_version':'0.4.2', 'free_kib':788}
        with patch.object(self.app.manager, 'recover'):
            self.app.job('recover', {'host':'192.168.1.1'})
            done(self.app)
        self.assertEqual(self.app.snapshot()['device'], {})

    def test_all_device_actions_refuse_the_wrong_target(self):
        for action in ['check','verify','install','uninstall','recover']:
            self.app.ready = True
            self.app.manager.ssh = Mock()
            self.app.manager.ssh.alive.return_value = True
            with self.subTest(action=action), patch.object(self.app.manager, 'compatibility' if action=='check' else action) as call:
                self.app.job(action, {'host':'192.168.1.254'})
                done(self.app)
                call.assert_not_called()
                self.assertEqual(self.app.snapshot()['operation']['status'], 'error')
                self.assertIn('Адрес изменился', self.app.snapshot()['operation']['message'])

    def test_duplicate_submit_is_refused_until_operation_finishes(self):
        started = threading.Event()
        release = threading.Event()
        def verify():
            started.set()
            release.wait(2)
        with patch.object(self.app.manager, 'verify', side_effect=verify):
            self.app.job('verify', {'host':'192.168.1.1'})
            self.assertTrue(started.wait(1))
            try:
                with self.assertRaises(AccessError):
                    self.app.job('verify', {'host':'192.168.1.1'})
                self.assertEqual(self.app.snapshot()['operation']['status'], 'running')
            finally:
                release.set()
                done(self.app)
        self.assertEqual(self.app.snapshot()['operation']['status'], 'success')

    def test_explicit_access_method_ignores_stale_alternative_credentials(self):
        def bootstrap(host, user, web_password, config, password):
            self.app.manager.host = host
            self.assertIsNone(config)
            self.assertIsNone(password)
            return dict(host=host, installed_version='0.3.1', free_kib=788)
        with patch.object(self.app.manager, 'bootstrap', side_effect=bootstrap):
            self.app.job('access',dict(host='192.168.1.1',method='web',web_password='fixture',ssh_password='stale',config='not-base64'))
            done(self.app)
        state = self.app.snapshot()
        self.assertTrue(state['ready'])
        self.assertEqual(state['device']['installed_version'], '0.3.1')
        self.assertNotIn('password', state)
        self.assertNotIn('fixture', str(state))

    def test_empty_web_password_never_attempts_default_password(self):
        with patch.object(self.app.manager, 'bootstrap') as bootstrap:
            self.app.job('access', {'host':'192.168.1.1','method':'web'})
            done(self.app)
            bootstrap.assert_not_called()
        self.assertEqual(self.app.snapshot()['operation']['status'], 'error')


class OperationPreflightTests(unittest.TestCase):
    def test_existing_recovery_data_blocks_install_before_any_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            manager = Manager(state_dir=directory)
            manager.ssh = Mock()
            manager.ssh.run.return_value = (72, b'', b'')
            with patch.object(manager, 'backup') as backup, patch.object(manager, 'probe_nfqueue') as probe:
                with self.assertRaisesRegex(AccessError, 'предыдущей операции'):
                    manager.install()
                backup.assert_not_called()
                probe.assert_not_called()
            self.assertEqual(manager.ssh.run.call_count, 1)

    def test_reconnect_failure_does_not_keep_closed_connection(self):
        with tempfile.TemporaryDirectory() as directory:
            manager = Manager(state_dir=directory)
            previous = Mock()
            manager.ssh = previous
            with patch('g84_setup.manager.RouterSSH', side_effect=AccessError('offline')):
                with self.assertRaises(AccessError):
                    manager.connect('192.168.1.1')
            previous.close.assert_called_once()
            self.assertIsNone(manager.ssh)

    @unittest.skipIf(os.name == 'nt', 'POSIX staging shell test')
    def test_failed_upload_cleans_only_its_own_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            scripts = []
            class SSH:
                def run(self, script, **kwargs):
                    scripts.append(script)
                    result = subprocess.run(['/bin/sh','-c',script.replace('/var/tmp',str(root))],input=b'not-a-gzip',capture_output=True)
                    if result.returncode:raise AccessError('upload failed')
            manager = Manager(state_dir=root / 'state')
            manager.ssh = SSH()
            with self.assertRaises(AccessError):manager.stage()
            self.assertFalse((root / 'zapret2-install').exists())
            existing = root / 'zapret2-install'
            existing.mkdir()
            (existing / 'unrelated').write_text('preserve')
            with self.assertRaises(AccessError):manager.stage()
            self.assertEqual((existing / 'unrelated').read_text(),'preserve')

class SSHErrorTests(unittest.TestCase):
    def test_channel_creation_failure_becomes_actionable_safe_error(self):
        import paramiko
        from g84_setup.access import RouterSSH
        ssh = RouterSSH.__new__(RouterSSH)
        ssh.transport = Mock()
        ssh.transport.open_session.side_effect = paramiko.SSHException('fixture-secret')
        with self.assertRaisesRegex(AccessError, 'Подключитесь') as raised:
            ssh.run('true')
        self.assertNotIn('fixture-secret', str(raised.exception))
