#!/usr/bin/env python3
"""Run checks on a freshly created sparse FAT32 image, never a user disk."""
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

project = pathlib.Path(__file__).resolve().parent.parent
work = pathlib.Path(tempfile.mkdtemp(prefix="rufus-fat-test-"))
image = work / "test.sparseimage"
mount = work / "mount"
mount.mkdir()
attached = False
try:
    subprocess.run(["hdiutil", "create", "-quiet", "-size", "4g", "-fs", "MS-DOS", "-volname", "RUFUSTEST", "-type", "SPARSE", "-layout", "GPTSPUD", str(image)], check=True)
    subprocess.run(["hdiutil", "attach", "-quiet", "-nobrowse", "-mountpoint", str(mount), str(image)], check=True)
    attached = True
    info = plistlib.loads(subprocess.check_output(["diskutil", "info", "-plist", str(mount)]))
    if info.get("FilesystemName") != "MS-DOS FAT32":
        raise RuntimeError("Disposable image did not format as FAT32")
    sources = sorted(str(p) for p in (project / "Sources/RufusCore").glob("*.swift"))
    checker = work / "check"
    subprocess.run(["swiftc", *sources, str(project / "Checks/main.swift"), "-o", str(checker)], check=True)
    env = os.environ.copy()
    env["RUFUS_TEST_EMPTY_FAT_ROOT"] = str(mount)
    wimlib = project / ".deps/wimlib-1.14.5/bin/wimlib-imagex"
    if wimlib.is_file():
        env["RUFUS_TEST_WIMLIB"] = str(wimlib)
    subprocess.run([str(checker)], env=env, check=True)
finally:
    if attached:
        result = subprocess.run(["hdiutil", "detach", "-quiet", str(mount)])
        if result.returncode != 0:
            print(f"Detach failed; temporary image remains at {work}")
            raise SystemExit(result.returncode)
    shutil.rmtree(work)
