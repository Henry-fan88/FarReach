"""Release boundary checks; no production credentials, Keychain writes, or network."""
import base64
import importlib.util
import json
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("update_config", ROOT / "scripts/update_config.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class ReleaseToolsTests(unittest.TestCase):
    def test_configuration_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "config.json"
            path.write_text(json.dumps({"feedURL": "", "publicEDKey": ""}))
            self.assertIsNone(config.load_config(path))
            with self.assertRaises(ValueError):
                config.load_config(path, required=True)
            key = base64.b64encode(bytes([7]) * 32).decode()
            path.write_text(json.dumps({"feedURL": "https://example.com/appcast.xml", "publicEDKey": key}))
            self.assertIsNotNone(config.load_config(path, required=True))
            for url in ["http://example.com/feed", "https://u:p@example.com/feed", "https://example.com/feed?token=x", "https://example.com/feed#x", "https://", "https://bad host/feed"]:
                path.write_text(json.dumps({"feedURL": url, "publicEDKey": key}))
                with self.assertRaises(ValueError, msg=url):
                    config.load_config(path)

    def test_framework_symlinks_and_executable_permissions_survive_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            app = self.make_app(Path(temp))
            framework = app / "Contents/Frameworks/Example.framework"
            binary = framework / "Versions/A/Example"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"example executable")
            binary.chmod(0o755)
            (framework / "Versions/Current").symlink_to("A", target_is_directory=True)
            (framework / "Example").symlink_to("Versions/Current/Example")
            output = Path(temp) / "app.zip"
            subprocess.run([sys.executable, str(ROOT / "scripts/package-app.py"), str(app), str(output)], check=True)
            with zipfile.ZipFile(output) as archive:
                link = archive.getinfo("FarReach.app/Contents/Frameworks/Example.framework/Example")
                self.assertTrue(stat.S_ISLNK(link.external_attr >> 16))
                self.assertEqual(archive.read(link), b"Versions/Current/Example")
                item = archive.getinfo("FarReach.app/Contents/Frameworks/Example.framework/Versions/A/Example")
                self.assertTrue((item.external_attr >> 16) & 0o111)
                self.assertTrue(all(not i.extra and i.date_time == (1980, 1, 1, 0, 0, 0) for i in archive.infolist()))

    def test_symlink_cannot_include_files_outside_bundle(self):
        with tempfile.TemporaryDirectory() as temp:
            app = self.make_app(Path(temp))
            secret = Path(temp) / "outside.txt"
            secret.write_text("private fixture")
            (app / "Contents/link").symlink_to("../../outside.txt")
            result = subprocess.run([sys.executable, str(ROOT / "scripts/package-app.py"), str(app), str(Path(temp) / "app.zip")], capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    @staticmethod
    def make_app(root):
        app = root / "FarReach.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "org.farreach.mac"}))
        return app


if __name__ == "__main__":
    unittest.main()
