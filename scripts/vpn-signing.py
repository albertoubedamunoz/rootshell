#!/usr/bin/env python3
"""Resolve VPN build identity and validate Developer ID profiles before building."""

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess


def resolve_identity(selector, keychain=None):
    command = ["security", "find-identity", "-v", "-p", "codesigning"]
    if keychain:
        command.append(str(keychain))
    listing = subprocess.check_output(command, text=True)
    candidates = re.findall(r'\b([0-9A-F]{40}) "([^"]+)"', listing)
    matches = {fingerprint for fingerprint, name in candidates
               if name.startswith("Developer ID Application:")
               and (selector.upper() == fingerprint or selector == name)}
    if len(matches) != 1:
        raise ValueError("Signing identity must resolve to exactly one valid Developer ID "
                         "certificate; use its SHA-1 and SIGNING_KEYCHAIN if necessary")
    return matches.pop()


def check_profile_certificate(profile, fingerprint, name):
    authorized = {hashlib.sha1(cert).hexdigest().upper()
                  for cert in profile.get("DeveloperCertificates", [])}
    if fingerprint not in authorized:
        raise ValueError(f"{name}: signing certificate {fingerprint} is not authorized "
                         f"by the profile (authorized: {', '.join(sorted(authorized)) or 'none'})")


def prepare(settings, output, profiles=None, signing_identity=None, keychain=None):
    targets = {entry["target"]: entry["buildSettings"] for entry in settings}
    host, tunnel = targets["rootshellvpn"], targets["tunnel"]
    team = host["ROOTSHELL_DEVELOPMENT_TEAM"]
    group = host["ROOTSHELL_DEFAULT_APP_GROUP"]
    host_id = host["PRODUCT_BUNDLE_IDENTIFIER"]
    tunnel_id = tunnel["PRODUCT_BUNDLE_IDENTIFIER"]
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Invalid ROOTSHELL_DEVELOPMENT_TEAM")
    for value in (host_id, tunnel_id, group):
        if not re.fullmatch(r"[A-Za-z0-9.-]+", value):
            raise ValueError(f"Invalid resolved identifier: {value!r}")
    if not host_id.endswith(".rootshellvpn") or tunnel_id != host_id + ".tunnel":
        raise ValueError("VPN host and tunnel bundle identifiers do not match")
    if any(tunnel[key] != host[key] for key in
           ("ROOTSHELL_DEVELOPMENT_TEAM", "ROOTSHELL_DEFAULT_APP_GROUP")):
        raise ValueError("VPN host and tunnel must use the same team and App Group")
    output.mkdir(parents=True, exist_ok=True)
    identity = {
        "team": team, "host_id": host_id, "tunnel_id": tunnel_id, "app_group": group,
    }
    fingerprint = resolve_identity(signing_identity, keychain) if signing_identity else None
    if fingerprint:
        identity["signing_identity"] = fingerprint
    if profiles is None:
        (output / "identity.json").write_text(json.dumps(identity))
        return
    for name, bundle_id, profile_path in zip(
            ("host", "tunnel"), (host_id, tunnel_id), profiles):
        profile = plistlib.loads(subprocess.check_output(
            ["security", "cms", "-D", "-i", str(profile_path)]))
        if fingerprint:
            check_profile_certificate(profile, fingerprint, name)
        entitlements = profile["Entitlements"]
        if profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
            raise ValueError(f"{name}: provisioning profile has expired")
        if team not in profile["TeamIdentifier"] or entitlements.get(
                "com.apple.developer.team-identifier") != team:
            raise ValueError(f"{name}: profile belongs to a different team")
        app_id = entitlements.get("com.apple.application-identifier", "")
        prefixes = profile.get("ApplicationIdentifierPrefix", [])
        if app_id not in [prefix + "." + bundle_id for prefix in prefixes]:
            raise ValueError(f"{name}: profile does not authorize {bundle_id}")
        if group not in entitlements.get("com.apple.security.application-groups", []):
            raise ValueError(f"{name}: profile does not authorize App Group {group}")
        network_key = "com.apple.developer.networking.networkextension"
        if "packet-tunnel-provider-systemextension" not in entitlements.get(network_key, []):
            raise ValueError(f"{name}: requires a Developer ID Network Extensions profile")
        signed = {
            "com.apple.application-identifier": app_id,
            "com.apple.developer.team-identifier": team,
            "com.apple.security.application-groups": [group],
            network_key: ["packet-tunnel-provider-systemextension"],
        }
        if name == "host":
            key = "com.apple.developer.system-extension.install"
            if entitlements.get(key) is not True:
                raise ValueError("host: profile must authorize System Extension installation")
            signed[key] = True
        else:
            signed["com.apple.security.network.client"] = True
            signed["com.apple.security.network.server"] = True
        with (output / f"{name}.entitlements").open("wb") as stream:
            plistlib.dump(signed, stream)
    (output / "identity.json").write_text(json.dumps(identity))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("settings", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--host-profile", type=Path)
    parser.add_argument("--tunnel-profile", type=Path)
    parser.add_argument("--signing-identity")
    parser.add_argument("--keychain", type=Path)
    args = parser.parse_args()
    if bool(args.host_profile) != bool(args.tunnel_profile):
        parser.error("Provide both provisioning profiles")
    if args.host_profile and not args.signing_identity:
        parser.error("Signed builds require --signing-identity")
    try:
        prepare(json.loads(args.settings.read_text()), args.output,
                (args.host_profile, args.tunnel_profile) if args.host_profile else None,
                args.signing_identity, args.keychain)
    except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"VPN signing: {error}\n")


if __name__ == "__main__":
    main()
