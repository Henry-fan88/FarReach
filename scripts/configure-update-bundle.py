#!/usr/bin/env python3
"""Inject validated public update metadata into a built app, never a private key."""
import argparse
import plistlib
from update_config import load_config

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("configuration")
parser.add_argument("plist")
args = parser.parse_args()
try:
    config = load_config(args.configuration)
except (ValueError, OSError) as error:
    parser.exit(1, f"Invalid update configuration: {error}\n")
with open(args.plist, "rb") as stream:
    info = plistlib.load(stream)
info.pop("SUFeedURL", None)
info.pop("SUPublicEDKey", None)
if config:
    info["SUFeedURL"] = config["feedURL"]
    info["SUPublicEDKey"] = config["publicEDKey"]
with open(args.plist, "wb") as stream:
    plistlib.dump(info, stream, sort_keys=False)
print("Updater metadata configured." if config else "Updater disabled: no release feed/key configured.")
