#!/usr/bin/env python3
"""Prepare a signed update archive and appcast locally; never publish a release."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from update_config import load_config

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--repository", required=True, help="Public GitHub repository, OWNER/REPO")
parser.add_argument("--app", type=Path, default=root / "dist/FarReach.app")
parser.add_argument("--output", type=Path)
parser.add_argument("--notes", type=Path, help="Markdown release notes")
parser.add_argument("--account", default="FarReach-updates", help="Sparkle signing-key account in login Keychain")
parser.add_argument("--key-file", type=Path, help="Optional private key file outside this repository; never a key value")
args = parser.parse_args()
try:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        raise ValueError("Repository must be OWNER/REPO.")
    config = load_config(root / "Resources/UpdateConfiguration.json", required=True)
    feed = f"https://github.com/{args.repository}/releases/latest/download/appcast.xml"
    if config["feedURL"] != feed:
        raise ValueError("feedURL must match this repository's releases/latest/download/appcast.xml URL.")
    if args.key_file and args.key_file.resolve().is_relative_to(root):
        raise ValueError("Keep the private signing key outside the repository.")
    with (args.app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "org.farreach.mac" or args.app.name != "FarReach.app":
        raise ValueError("Expected the built FarReach.app bundle.")
    if info.get("SUFeedURL") != feed or info.get("SUPublicEDKey") != config["publicEDKey"]:
        raise ValueError("Built app update configuration differs from source. Rebuild it first.")
    if not info.get("SURequireSignedFeed") or not info.get("SUVerifyUpdateBeforeExtraction"):
        raise ValueError("Release must require signed feeds and verification before extraction.")
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version) or not re.fullmatch(r"[0-9]+", build):
        raise ValueError("Use a numeric release version and a monotonically increasing integer build number.")
    tools = root / ".build/artifacts/sparkle/Sparkle/bin"
    if not (tools / "generate_appcast").is_file():
        raise ValueError("Run swift package resolve first.")
    output = args.output or root / "dist/releases" / f"{version}-{build}"
    if output.exists() and any(output.iterdir()):
        raise ValueError("Release output must be empty; never overwrite a published archive.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(args.app)], check=True)
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"FarReach-{version}-macOS.zip"
    subprocess.run([sys.executable, str(root / "scripts/package-app.py"), str(args.app), str(archive)], check=True)
    if args.notes:
        shutil.copyfile(args.notes, archive.with_suffix(".md"))
    signing = ["--ed-key-file", str(args.key_file.resolve())] if args.key_file else ["--account", args.account]
    subprocess.run([str(tools / "generate_appcast"), *signing,
                    "--download-url-prefix", f"https://github.com/{args.repository}/releases/download/v{version}/",
                    "--maximum-deltas", "0", "--embed-release-notes", str(output)], check=True)
    appcast = output / "appcast.xml"
    items = ET.parse(appcast).getroot().findall("./channel/item")
    ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    if len(items) != 1 or items[0].findtext(ns + "version") != build:
        raise ValueError("Generated feed does not contain exactly this build.")
    enclosure = items[0].find("enclosure")
    if enclosure is None or not enclosure.get(ns + "edSignature"):
        raise ValueError("Update archive was not signed; verify that the signing key matches publicEDKey.")
    subprocess.run([str(tools / "sign_update"), *signing, "--verify", str(archive), enclosure.get(ns + "edSignature")], check=True)
    subprocess.run([str(tools / "sign_update"), *signing, "--verify", str(appcast)], check=True)
    (output / "SHA256SUMS.txt").write_text("".join(
        hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name + "\n" for p in (archive, appcast)
    ))
    print(f"Prepared signed release v{version} (build {build}); nothing uploaded.")
    print(f"Review and publish {archive.name}, appcast.xml, and SHA256SUMS.txt from {output}.")
except (ValueError, OSError, subprocess.CalledProcessError, ET.ParseError) as error:
    parser.exit(1, f"Release preparation failed: {error}\n")
