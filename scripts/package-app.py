#!/usr/bin/env python3
"""Archive a signed FarReach bundle without copying local filesystem metadata."""
from pathlib import Path
import plistlib
import os
import stat
import sys
import zipfile

app, output = map(Path, sys.argv[1:])
with (app / "Contents/Info.plist").open("rb") as stream:
    if plistlib.load(stream).get("FarReachSignalingURL", ""):
        raise SystemExit("Public packages must have no bundled signaling URL. Configure it in Setup.")
with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            target = os.readlink(path)
            if os.path.isabs(target) or not path.resolve().is_relative_to(app.resolve()) or not path.exists():
                raise SystemExit("Application symlink must resolve inside the bundle.")
            entry = zipfile.ZipInfo(app.name + "/" + path.relative_to(app).as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(entry, target.encode("utf-8"))
            continue
        if not path.is_file() or path.name == ".DS_Store" or path.name.startswith("._"):
            continue
        entry = zipfile.ZipInfo(app.name + "/" + path.relative_to(app).as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
        entry.create_system = 3
        entry.compress_type = zipfile.ZIP_DEFLATED
        entry.external_attr = (0o100755 if path.stat().st_mode & 0o111 else 0o100644) << 16
        archive.writestr(entry, path.read_bytes())
with zipfile.ZipFile(output) as archive:
    if archive.testzip() is not None:
        raise SystemExit("Application archive integrity check failed.")
