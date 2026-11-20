#!/usr/bin/env nix-shell
#!nix-shell --pure -i python3 -p "python3.withPackages (ps: with ps; [ requests ])"

import hashlib
import json
import os
import re
import requests
import sys

all_feature_versions = (11, 17, 21, 25)
oses = {"linux": "linux", "mac": "macosx"}
arch_to_nixos = {
    "x64": "x86_64",
    "aarch64": "aarch64",
}


def fetch_asset(feature_version, os_name, corretto_os):
    out = {}
    for nixos_arch, corretto_arch in arch_to_nixos.items():
        url = f"https://corretto.aws/downloads/latest/amazon-corretto-{feature_version}-{nixos_arch}-{os_name}-jdk.tar.gz"
        resp = requests.get(url, stream=True, allow_redirects=True)
        if resp.status_code != 200:
            print(f"error: could not fetch {url} (code {resp.status_code})", file=sys.stderr)
            sys.exit(1)

        resolved_url = resp.url
        match = re.search(
            rf"amazon-corretto-([0-9.]+)-{corretto_os}-{corretto_arch}\.tar\.gz$", resolved_url
        )
        if not match:
            print(f"error: could not parse version from {resolved_url}", file=sys.stderr)
            sys.exit(1)
        version = match.group(1)

        digest = hashlib.sha256()
        for chunk in resp.iter_content(chunk_size=1 << 20):
            digest.update(chunk)

        out[nixos_arch] = {
            "url": resolved_url,
            "sha256": digest.hexdigest(),
            "version": version,
        }
    return out


if len(sys.argv) > 1:
    try:
        feature_versions = tuple(int(v) for v in sys.argv[1:])
    except ValueError:
        print(f"usage: {sys.argv[0]} [version ...]", file=sys.stderr)
        print("  version: one or more feature version numbers, e.g. 21 25", file=sys.stderr)
        sys.exit(1)
    unknown = [v for v in feature_versions if v not in all_feature_versions]
    if unknown:
        print(f"warning: unknown feature version(s): {', '.join(str(v) for v in unknown)}", file=sys.stderr)
else:
    feature_versions = all_feature_versions

sources_path = os.path.join(os.path.dirname(__file__), "sources.json")

try:
    with open(sources_path) as f:
        out = json.load(f)
except FileNotFoundError:
    out = {}

for feature_version in feature_versions:
    for os_name, corretto_os in oses.items():
        arch_map = out.setdefault(os_name, {}).setdefault("jdk", {}).setdefault(
            f"corretto{feature_version}", {"packageType": "jdk"}
        )
        arch_map.update(fetch_asset(feature_version, os_name, corretto_os))

with open(sources_path, "w") as f:
    json.dump(out, f, indent=2, sort_keys=True)
    f.write("\n")
