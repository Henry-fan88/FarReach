"""Validate public updater configuration shared by build/release tools."""
import base64
import json
from pathlib import Path
from urllib.parse import urlsplit


def https_url(value):
    if not isinstance(value, str) or any(c.isspace() for c in value):
        raise ValueError("Update URL must be an HTTPS URL without whitespace.")
    url = urlsplit(value)
    if (url.scheme != "https" or not url.hostname or url.username is not None
            or url.password is not None or "?" in value or "#" in value):
        raise ValueError("Update URL must use HTTPS without credentials, query, or fragment.")
    _ = url.port
    return value


def load_config(path, required=False):
    config = json.loads(Path(path).read_text())
    if not isinstance(config, dict) or set(config) != {"feedURL", "publicEDKey"}:
        raise ValueError("UpdateConfiguration.json must contain only feedURL and publicEDKey.")
    feed, key = config["feedURL"], config["publicEDKey"]
    if feed == "" and key == "":
        if required:
            raise ValueError("Configure a public update feed and Ed25519 public key before preparing a release.")
        return None
    https_url(feed)
    if not isinstance(key, str):
        raise ValueError("publicEDKey must be a base64 Ed25519 public key.")
    data = base64.b64decode(key, validate=True)
    if len(data) != 32 or base64.b64encode(data).decode() != key:
        raise ValueError("publicEDKey must be the canonical base64 encoding of 32 bytes.")
    return config
