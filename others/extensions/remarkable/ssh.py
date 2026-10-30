"""Read-only SSH transport. Credentials enter over stdin and remain in memory."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

spec = importlib.util.spec_from_file_location('remarkable_ink', Path(__file__).with_name('ink.py'))
ink = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ink)
Error = ink.InkInputError
ROOT = '/home/root/.local/share/remarkable/xochitl'


def connection(value):
    try:
        config = json.loads(value)
        host, password = config['host'], config.get('password', '')
        if (config.get('transport') != 'ssh' or not isinstance(host, str)
                or len(host) > 253 or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*', host)
                or '..' in host or not isinstance(password, str) or len(password) > 1024
                or any(c in password for c in '\r\n\0')):
            raise ValueError()
        return {'transport': 'ssh', 'host': host, 'password': password}
    except (ValueError, KeyError, TypeError):
        raise Error('Enter the device address and SSH password.') from None


def askpass():
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(5)
        client.connect(os.environ['REMILE_ASKPASS_SOCKET'])
        data = bytearray()
        while chunk := client.recv(1024):
            data.extend(chunk)
            if len(data) > 4096:
                raise ValueError('Invalid authentication response.')
        sys.stdout.buffer.write(data)


@contextlib.contextmanager
def authentication(config, folder):
    # A private local socket avoids putting passwords in files, arguments or environment.
    address = str(folder / 'auth')
    server = socket.socket(socket.AF_UNIX)
    server.bind(address)
    os.chmod(address, 0o600)
    server.listen(1)
    server.settimeout(0.2)
    stop = threading.Event()

    def serve():
        while not stop.is_set():
            try:
                client, _ = server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with client:
                client.settimeout(2)
                try:
                    client.sendall(config['password'].encode())
                except OSError:
                    pass

    script = folder / 'askpass'
    script.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' -I -B '
                      + shlex.quote(str(Path(__file__).resolve())) + ' --askpass\n')
    script.chmod(0o700)
    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        yield dict(os.environ, SSH_ASKPASS=str(script), SSH_ASKPASS_REQUIRE='force',
                   DISPLAY='remile', REMILE_ASKPASS_SOCKET=address)
    finally:
        stop.set()
        thread.join(timeout=1)
        server.close()


def run(config, command, limit):
    with tempfile.TemporaryDirectory(prefix='rm-ssh-') as tmp:
        folder = Path(tmp)
        with authentication(config, folder) as environment, (folder / 'out').open('w+b') as output, (folder / 'err').open('w+b') as errors:
            args = ['/usr/bin/ssh', '-T', '-o', 'StrictHostKeyChecking=yes',
                    '-o', 'ConnectTimeout=8', '-o', 'ConnectionAttempts=1',
                    '-o', 'NumberOfPasswordPrompts=1', '-o', 'PermitLocalCommand=no',
                    '-o', 'ClearAllForwardings=yes', '-o', 'ProxyCommand=none',
                    '-o', 'ProxyJump=none', '-o', 'RemoteCommand=none',
                    '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2',
                    'root@' + config['host'], command]
            process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=output,
                                       stderr=errors, env=environment)
            try:
                deadline = time.monotonic() + 120
                while process.poll() is None:
                    if (os.fstat(output.fileno()).st_size > limit
                            or os.fstat(errors.fileno()).st_size > 16384):
                        raise Error('The device response exceeds its size limit.')
                    if time.monotonic() > deadline:
                        raise Error('The device took too long. Try a smaller document.')
                    time.sleep(0.05)
                output.seek(0)
                data = output.read(limit + 1)
                if len(data) > limit:
                    raise Error('The device response exceeds its size limit.')
                if process.returncode:
                    errors.seek(0)
                    diagnostic = errors.read(16384).lower()
                    if b'host key' in diagnostic or b'authenticity' in diagnostic:
                        raise Error('Verify this device in Terminal with ssh root@' + config['host'] + ', then connect again.')
                    if b'permission denied' in diagnostic:
                        raise Error('SSH authentication failed. Check the device password.')
                    raise Error('The device is unavailable. Check its address, connection and SSH access.')
                return data
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


def archive_entries(data, metadata_only=False):
    result, total = {}, 0
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as archive:
            for member in archive:
                name = member.name.removeprefix('./')
                path = PurePosixPath(name)
                if (path.is_absolute() or '..' in path.parts or '\\' in name
                        or member.issym() or member.islnk()):
                    raise Error('The device returned an unsafe document path.')
                if member.isdir():
                    continue
                if not member.isfile() or len(result) >= 10000 or name in result:
                    raise Error('The device returned an unsupported document archive.')
                total += member.size
                if total > ink.MAX_EXPANDED or member.size > ink.MAX_ARCHIVE:
                    raise Error('The document exceeds the transfer limit.')
                if path.suffix not in {'.metadata', '.content', '.pdf', '.rm'}:
                    continue
                if metadata_only and (len(path.parts) != 1 or path.suffix not in {'.metadata', '.content'}):
                    raise Error('The device returned unexpected library data.')
                if path.suffix in {'.metadata', '.content'} and member.size > 2 * 1024 * 1024:
                    raise Error('The document metadata exceeds its limit.')
                result[name] = archive.extractfile(member).read()
    except (tarfile.TarError, EOFError, OSError):
        raise Error('The device returned an unreadable archive.') from None
    return result


def entries(config, ids=None):
    if ids is None:
        names = '*.metadata *.content'
    else:
        names = ' '.join(item + suffix for item in ids for suffix in ['.metadata', '.content'])
    return archive_entries(run(config, 'cd ' + ROOT + ' && tar c -f - ' + names, 16 * 1024 * 1024), True)


def documents(files):
    found = {}
    for name, raw in files.items():
        if not name.endswith('.metadata'):
            continue
        item_id = ink.identifier(name[:-9])
        meta = json.loads(raw)
        content_raw = files.get(item_id + '.content', b'{}')
        content = json.loads(content_raw)
        if meta.get('type') not in {'CollectionType', 'DocumentType'}:
            continue
        found[item_id] = {'id': item_id, 'title': str(meta.get('visibleName', 'Untitled'))[:500],
                          'revision': hashlib.sha256(b'remile-pdf-v2\0' + raw + b'\0' + content_raw).hexdigest(),
                          'parentID': meta.get('parent') or None, 'folder': meta['type'] == 'CollectionType',
                          'createdTime': str(meta['createdTime']) if meta.get('createdTime') else None,
                          'modifiedTime': str(meta['lastModified']) if meta.get('lastModified') else None,
                          'fileType': content.get('fileType'), '_deleted': meta.get('deleted', False)}

    def visible(item):
        seen = set()
        while item:
            if item['id'] in seen or item['_deleted'] or item['parentID'] == 'trash':
                return False
            seen.add(item['id'])
            parent = item['parentID']
            if parent and parent not in found:
                # Exact selected reads do not include ancestors. The caller checks the full list.
                break
            item = found.get(parent)
        return True

    result = [dict(item) for item in found.values() if visible(item)]
    for item in result:
        item.pop('_deleted')
    if len(result) > 5000:
        raise Error('This library exceeds the extension limit.')
    return result


def handle(request):
    operation = request.get('operation')
    if operation == 'probe':
        import rmc
        return {'ok': True}
    if operation not in {'pair', 'list', 'describe', 'receive'}:
        raise Error('Unknown device operation.')
    config = connection(request.get('code') if operation == 'pair' else request.get('token'))
    if operation in {'pair', 'list'}:
        result = {'ok': True, 'documents': documents(entries(config))}
        if operation == 'pair':
            result['token'] = json.dumps(config)
        return result
    if operation == 'describe':
        selected = request.get('ids')
        if not isinstance(selected, list) or not 1 <= len(selected) <= 200:
            raise Error('Choose between one and 200 documents.')
        ids = sorted({ink.identifier(value) for value in selected})
        result = documents(entries(config, ids))
        if {x['id'] for x in result if not x['folder']} != set(ids):
            raise Error('Some selected documents are unavailable. Refresh the list.')
        return {'ok': True, 'documents': result}
    item = ink.identifier(request.get('id'))
    directory = Path(request['directory'])
    if (not directory.is_absolute() or not directory.is_dir() or any(directory.iterdir())
            or directory.is_symlink()):
        raise Error('Choose an empty private document directory.')
    command = ('cd ' + ROOT + ' || exit; set -- ' + item + '.metadata ' + item + '.content; '
               'for p in ' + item + '.pdf ' + item + '; do '
               '[ ! -e "$p" ] || set -- "$@" "$p"; done; tar c -f - "$@"')
    files = archive_entries(run(config, command, ink.MAX_ARCHIVE))
    received = documents(files)
    current = next((x for x in received if x['id'] == item and not x['folder']), None)
    if current is None:
        raise Error('The document is unavailable. Refresh the list.')
    # Refuse a snapshot changed during transfer. Existing Reference copies stay intact.
    if entries(config, [item]) != {k: v for k, v in files.items() if k in {item + '.metadata', item + '.content'}}:
        raise Error('The document changed during transfer. Finish writing, then try again.')
    data = io.BytesIO()
    import zipfile
    with zipfile.ZipFile(data, 'w') as archive:
        for name, content in files.items():
            archive.writestr(name, content)
    return dict(ink.prepare(data.getvalue(), directory, item), ok=True, revision=current['revision'])


def main():
    if os.getpgrp() != os.getpid():
        os.setsid()
    try:
        data = sys.stdin.buffer.read(32769)
        if len(data) > 32768:
            raise Error('The connection request exceeds its limit.')
        with contextlib.redirect_stdout(io.StringIO()):
            reply = handle(json.loads(data))
    except Error as error:
        reply = {'ok': False, 'error': str(error)}
    except Exception:
        reply = {'ok': False, 'error': 'The device document could not be read. Check its format and try again.'}
    sys.stdout.write(json.dumps(reply))


if __name__ == '__main__':
    if sys.argv[1:] == ['--askpass']:
        askpass()
    else:
        main()
