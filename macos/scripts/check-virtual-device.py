#!/usr/bin/env python3
"""Exercise raw writes only against a newly created hdiutil image."""
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

project = pathlib.Path(__file__).resolve().parent.parent
work = pathlib.Path(tempfile.mkdtemp(prefix='rufus-raw-device-'))
image = work / 'blank.sparseimage'
device = None
try:
    subprocess.run(['hdiutil', 'create', '-quiet', '-size', '64m', '-type', 'SPARSE', '-layout', 'NONE', str(image)], check=True)
    attachment = plistlib.loads(subprocess.check_output(['hdiutil', 'attach', '-nomount', '-plist', str(image)]))
    device = attachment['system-entities'][0]['dev-entry']
    if not device.startswith('/dev/disk') or not device[9:].isdigit():
        raise RuntimeError('Unexpected disk identifier')
    checker = work / 'check'
    subprocess.run(['swiftc', *sorted(str(p) for p in (project / 'Sources/RufusCore').glob('*.swift')), str(project / 'Checks/main.swift'), '-o', str(checker)], check=True)
    env = os.environ.copy()
    env['RUFUS_TEST_VIRTUAL_DISK'] = device.removeprefix('/dev/')
    env['RUFUS_TEST_VIRTUAL_BACKING'] = str(image)
    wimlib = project / '.deps/wimlib-1.14.5/bin/wimlib-imagex'
    if wimlib.is_file(): env['RUFUS_TEST_WIMLIB'] = str(wimlib)
    subprocess.run([str(checker)], check=True, env=env)
finally:
    if device:
        result = subprocess.run(['hdiutil', 'detach', '-quiet', device])
        if result.returncode:
            print(f'Detach failed; temporary files retained in {work}')
            raise SystemExit(result.returncode)
    shutil.rmtree(work)
