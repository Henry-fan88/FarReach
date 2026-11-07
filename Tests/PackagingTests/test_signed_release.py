"""Exercise real Sparkle signing with disposable keys; never touch login Keychain."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
APP = ROOT / "dist/FarReach.app"


@unittest.skipUnless(sys.platform == "darwin" and APP.exists() and TOOLS.exists(), "Build FarReach.app and resolve Sparkle first")
class SignedReleaseTests(unittest.TestCase):
    def test_signed_feed_archive_and_tamper_rejection(self):
        with tempfile.TemporaryDirectory(prefix="farreach-release-test-") as temp:
            base = Path(temp)
            repo = base / "repo"
            (repo / "scripts").mkdir(parents=True)
            (repo / "Resources").mkdir()
            for name in ["update_config.py", "package-app.py", "prepare-release.py"]:
                shutil.copyfile(ROOT / "scripts" / name, repo / "scripts" / name)
            tool_link = repo / ".build/artifacts/sparkle/Sparkle/bin"
            tool_link.parent.mkdir(parents=True)
            tool_link.symlink_to(TOOLS, target_is_directory=True)
            generator = base / "fixture.swift"
            generator.write_text('''import Foundation
import CryptoKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("update.key"), atomically: true, encoding: .utf8)
try key.publicKey.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("public.txt"), atomically: true, encoding: .utf8)
''')
            subprocess.run(["swift", str(generator), str(base)], check=True, capture_output=True)
            key_file = base / "update.key"
            key_file.chmod(0o600)
            config = {"feedURL": "https://github.com/example/farreach/releases/latest/download/appcast.xml", "publicEDKey": (base / "public.txt").read_text()}
            (repo / "Resources/UpdateConfiguration.json").write_text(json.dumps(config))
            app = repo / "dist/FarReach.app"
            shutil.copytree(APP, app, symlinks=True)
            plist = app / "Contents/Info.plist"
            info = plistlib.loads(plist.read_bytes())
            info.update(SUFeedURL=config["feedURL"], SUPublicEDKey=config["publicEDKey"])
            plist.write_bytes(plistlib.dumps(info))
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
            output = base / "release"
            result = subprocess.run([sys.executable, str(repo / "scripts/prepare-release.py"), "--repository", "example/farreach", "--key-file", str(key_file), "--output", str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            feed = output / "appcast.xml"
            item = ET.parse(feed).getroot().find("./channel/item")
            ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
            enclosure = item.find("enclosure")
            signature = enclosure.get(ns + "edSignature")
            archive = output / f"FarReach-{info['CFBundleShortVersionString']}-macOS.zip"
            self.assertIn("/releases/download/v", enclosure.get("url"))
            self.assertEqual(int(enclosure.get("length")), archive.stat().st_size)
            # Verification already succeeded in prepare-release. Modified artifacts must fail.
            with archive.open("ab") as stream:
                stream.write(b"tampered")
            result = subprocess.run([str(TOOLS / "sign_update"), "--ed-key-file", str(key_file), "--verify", str(archive), signature], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            feed.write_bytes(feed.read_bytes().replace(b"FarReach", b"Tampered", 1))
            result = subprocess.run([str(TOOLS / "sign_update"), "--ed-key-file", str(key_file), "--verify", str(feed)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
