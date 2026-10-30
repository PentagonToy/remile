"""SSH transport checks with synthetic archives. No device or credentials required."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('remarkable_ssh', ROOT / 'others/extensions/remarkable/ssh.py')
ssh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ssh)


class SSHChecks(unittest.TestCase):
    config = {'transport': 'ssh', 'host': '192.0.2.1', 'password': 'synthetic-secret'}

    def tar(self, members):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w') as archive:
            for name, body in members:
                entry = tarfile.TarInfo(name)
                entry.size = len(body)
                archive.addfile(entry, io.BytesIO(body))
        return data.getvalue()

    def item(self, id, parent='', deleted=False, folder=False):
        return {id + '.metadata': json.dumps({'type': 'CollectionType' if folder else 'DocumentType',
                'visibleName': 'Synthetic', 'parent': parent, 'deleted': deleted, 'lastModified': '42'}).encode(),
                id + '.content': b'{"fileType":"notebook"}'}

    def test_connection_rejects_shell_options_and_secrets_with_newlines(self):
        for host in ['-F/tmp/config', 'x;echo bad', 'root@host', 'host\nother', '../host', 'host:22']:
            with self.assertRaises(ssh.Error):
                ssh.connection(json.dumps(dict(self.config, host=host)))
        with self.assertRaises(ssh.Error):
            ssh.connection(json.dumps(dict(self.config, password='secret\ncommand')))
        self.assertEqual(ssh.connection(json.dumps(self.config)), self.config)

    def test_archive_refuses_traversal_duplicates_and_links(self):
        for members in [[('../outside.metadata', b'{}')], [('a.metadata', b'{}'), ('a.metadata', b'{}')]]:
            with self.assertRaises(ssh.Error):
                ssh.archive_entries(self.tar(members))
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w') as archive:
            link = tarfile.TarInfo('escape.metadata')
            link.type, link.linkname = tarfile.SYMTYPE, '/etc/passwd'
            archive.addfile(link)
        with self.assertRaises(ssh.Error):
            ssh.archive_entries(data.getvalue())

    def test_metadata_list_refuses_document_payloads(self):
        with self.assertRaises(ssh.Error):
            ssh.archive_entries(self.tar([('document.pdf', b'%PDF')]), metadata_only=True)

    def test_deleted_folders_cycles_and_trash_hide_descendants(self):
        folder, child, trash, cycle = [str(uuid.uuid4()) for _ in range(4)]
        files = self.item(folder, deleted=True, folder=True)
        files.update(self.item(child, parent=folder))
        files.update(self.item(trash, parent='trash'))
        files.update(self.item(cycle, parent=cycle))
        self.assertEqual(ssh.documents(files), [])

    def test_revision_tracks_metadata_and_page_index_changes(self):
        id = str(uuid.uuid4())
        files = self.item(id)
        before = ssh.documents(files)[0]['revision']
        files[id + '.content'] = b'{"fileType":"notebook","pages":[]}'
        self.assertNotEqual(before, ssh.documents(files)[0]['revision'])

    def test_selected_metadata_uses_only_validated_ids(self):
        id = str(uuid.uuid4())
        with patch.object(ssh, 'run', return_value=self.tar(list(self.item(id).items()))) as run:
            reply = ssh.handle({'operation': 'describe', 'token': json.dumps(self.config), 'ids': [id]})
            self.assertEqual(reply['documents'][0]['id'], id)
            command = run.call_args.args[1]
            self.assertIn(id + '.content', command)
            self.assertNotIn('*.content', command)
            self.assertNotIn('.pdf', command)
        with patch.object(ssh, 'run') as run:
            with self.assertRaises(ValueError):
                ssh.handle({'operation': 'describe', 'token': json.dumps(self.config), 'ids': ['; bad']})
            run.assert_not_called()

    def test_askpass_keeps_password_out_of_files_and_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            with ssh.authentication(self.config, Path(tmp)) as environment:
                self.assertNotIn(self.config['password'], str(environment))
                self.assertNotIn(self.config['password'], (Path(tmp) / 'askpass').read_text())
                reply = subprocess.run([str(Path(tmp) / 'askpass')], env=environment, capture_output=True, timeout=5)
                self.assertEqual(reply.returncode, 0)
                self.assertEqual(reply.stdout.decode(), self.config['password'])

    def test_helper_runs_when_native_launcher_already_created_a_process_group(self):
        reply = subprocess.run([sys.executable, '-I', '-B', str(ROOT / 'others/extensions/remarkable/ssh.py')],
                               input=b'{"operation":"probe"}', capture_output=True,
                               start_new_session=True, timeout=10)
        self.assertEqual(reply.returncode, 0)
        self.assertTrue(json.loads(reply.stdout)['ok'])


if __name__ == '__main__':
    unittest.main()
