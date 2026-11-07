#!/usr/bin/env python3
"""Package reviewable source without local state, credentials or filesystem metadata."""
from pathlib import Path
import hashlib
import os
import plistlib
import zipfile

root = Path(__file__).resolve().parents[1]
skip_directories = {
    "bin", "vendor", ".cache", "__pycache__", "node_modules", ".wrangler",
    "dist", "coverage", ".git", ".build", ".swiftpm", "evidence", "validation",
}
secret_suffixes = {".pem", ".key", ".p12", ".pfx", ".mobileprovision"}
files = [root / name for name in ("Package.swift", "Package.resolved", "README.md", "LICENSE", ".gitignore")]
for directory in ("Sources", "Tests", "Resources", "scripts", "docs", ".github", "Networking", "Signaling"):
    for path in (root / directory).rglob("*"):
        rel = path.relative_to(root)
        if (not path.is_file() or path.is_symlink() or skip_directories.intersection(rel.parts)
                or path.name == ".DS_Store" or path.name.startswith(("._", ".dev.vars", ".env", ".deploy"))
                or path.suffix.lower() in secret_suffixes | {".pyc", ".log"}):
            continue
        files.append(path)

with (root / "Resources/Info.plist").open("rb") as stream:
    if plistlib.load(stream).get("FarReachSignalingURL", ""):
        raise SystemExit("Public packages must have no bundled signaling URL. Configure it in Setup.")

out = Path(os.environ.get("FARREACH_OUTPUT_DIR", str(root / "dist"))).resolve()
out.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(out / "FarReach-source.zip", "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(set(files)):
        data = path.read_bytes()
        data.decode("utf-8")  # Reject an accidentally included executable or binary dump.
        entry = zipfile.ZipInfo("FarReach/" + path.relative_to(root).as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
        entry.create_system = 3
        entry.compress_type = zipfile.ZIP_DEFLATED
        entry.external_attr = (0o100755 if path.stat().st_mode & 0o111 else 0o100644) << 16
        archive.writestr(entry, data)
with zipfile.ZipFile(out / "FarReach-source.zip") as archive:
    if archive.testzip() is not None:
        raise SystemExit("Source archive integrity check failed.")
    print(f"Packaged {len(archive.namelist())} source and notice files.")

paths = [out / "FarReach-macOS.zip", out / "FarReach-source.zip",
         out / "FarReach.app/Contents/MacOS/FarReach", out / "FarReach.app/Contents/Helpers/FarReachNetwork"]
(out / "SHA256SUMS.txt").write_text("".join(
    hashlib.sha256(path.read_bytes()).hexdigest() + "  " + str(path.relative_to(out)) + "\n"
    for path in paths if path.exists()
))
