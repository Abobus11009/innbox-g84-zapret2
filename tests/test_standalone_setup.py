"""Exercise the single-file artifact without relying on the source package."""
import http.client
import importlib.util
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('standalone_setup', ROOT / 'g84-setup.py')
SETUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SETUP)


class StandaloneSetupTests(unittest.TestCase):
    def test_embedded_operations_can_prepare_known_ssh_access(self):
        with tempfile.TemporaryDirectory() as directory:
            manager = SETUP.Manager(state_dir=directory)
            with patch.object(SETUP, 'ssh_open', return_value=True), \
                 patch.object(SETUP, 'RouterSSH') as ssh, \
                 patch.object(manager, 'compatibility') as compatibility:
                manager.bootstrap('192.168.1.1', password='fixture-password')
                ssh.assert_called_once_with('192.168.1.1', 'fixture-password', pathlib.Path(directory))
                compatibility.assert_called_once_with()

    def test_embedded_resources_match_sources(self):
        for name in ['manifest.env', 'g84-zapret2-payload.tar.gz', 'setup/ui.html']:
            self.assertEqual((SETUP.resources() / name).read_bytes(), (ROOT / name).read_bytes())

    def test_only_script_is_needed_in_an_unrelated_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            script = root / 'g84-setup.py'
            shutil.copy2(ROOT / 'g84-setup.py', script)
            env = dict(os.environ, G84_DATA_DIR=str(root / 'state'))
            result = subprocess.run([sys.executable, str(script), '--self-test'],
                                    cwd=root, env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('resources', result.stdout)

    def test_generated_web_server_serves_embedded_ui_and_guards_api(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict('os.environ', {'G84_DATA_DIR':directory}):
            server = ThreadingHTTPServer(('127.0.0.1', 0), SETUP.Handler)
            server.app = SETUP.Application()
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=2)
                connection.request('GET', '/')
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(response.read(), (ROOT / 'setup/ui.html').read_bytes())
                connection.close()
                for headers, status in [({},403), ({'Authorization':'Bearer '+server.app.token},200)]:
                    connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=2)
                    connection.request('GET', '/state', headers=headers)
                    response = connection.getresponse()
                    self.assertEqual(response.status, status)
                    response.read()
                    connection.close()
            finally:
                server.shutdown()
                server.server_close()
                worker.join(2)
