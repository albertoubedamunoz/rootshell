"""Exercise contributor identities and rejection of incompatible VPN profiles."""
import copy
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "vpn_signing", Path(__file__).resolve().parents[1] / "vpn-signing.py")
vpn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vpn)


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.team = "ABCDE12345"
        self.group = "group.org.contributor.ghostty"
        self.host_id = "org.contributor.rootshellvpn"
        self.settings = [
            {"target": name, "buildSettings": {
                "ROOTSHELL_DEVELOPMENT_TEAM": self.team,
                "ROOTSHELL_DEFAULT_APP_GROUP": self.group,
                "PRODUCT_BUNDLE_IDENTIFIER": identifier,
            }}
            for name, identifier in (
                ("rootshellvpn", self.host_id), ("tunnel", self.host_id + ".tunnel"))
        ]
        self.profiles = []
        for identifier in (self.host_id, self.host_id + ".tunnel"):
            self.profiles.append({
                "ExpirationDate": datetime.datetime(2099, 1, 1),
                "TeamIdentifier": [self.team],
                # Legacy application prefixes need not equal the team.
                "ApplicationIdentifierPrefix": ["OLDPREFIX1"],
                "Entitlements": {
                    "com.apple.application-identifier": "OLDPREFIX1." + identifier,
                    "com.apple.developer.team-identifier": self.team,
                    "com.apple.security.application-groups": [self.group],
                    "com.apple.developer.networking.networkextension":
                        ["packet-tunnel-provider-systemextension"],
                    "com.apple.developer.system-extension.install": True,
                },
            })

    def prepare(self, directory):
        with patch.object(vpn.subprocess, "check_output",
                          side_effect=[plistlib.dumps(p) for p in self.profiles]):
            vpn.prepare(self.settings, Path(directory), ("host.profile", "tunnel.profile"))

    def test_contributor_and_legacy_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            self.prepare(directory)
            host = plistlib.loads((Path(directory) / "host.entitlements").read_bytes())
            tunnel = plistlib.loads((Path(directory) / "tunnel.entitlements").read_bytes())
            self.assertEqual(host["com.apple.application-identifier"], "OLDPREFIX1." + self.host_id)
            self.assertEqual(tunnel["com.apple.security.application-groups"], [self.group])
            self.assertTrue(tunnel["com.apple.security.network.client"])
            self.assertNotIn("com.apple.developer.system-extension.install", tunnel)

    def test_build_only_needs_no_profiles(self):
        with tempfile.TemporaryDirectory() as directory:
            vpn.prepare(self.settings, Path(directory))
            identity = json.loads((Path(directory) / "identity.json").read_text())
            self.assertEqual(identity["team"], self.team)

    def test_reject_incompatible_profiles(self):
        changes = [
            ("com.apple.developer.team-identifier", "WRONG12345"),
            ("com.apple.application-identifier", "OLDPREFIX1.org.other.rootshellvpn"),
            ("com.apple.security.application-groups", ["group.other"]),
            ("com.apple.developer.networking.networkextension", ["packet-tunnel-provider"]),
            ("com.apple.developer.system-extension.install", False),
        ]
        original = copy.deepcopy(self.profiles)
        for key, value in changes:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                self.profiles = copy.deepcopy(original)
                self.profiles[0]["Entitlements"][key] = value
                with self.assertRaises(ValueError):
                    self.prepare(directory)
        self.profiles = original
        self.profiles[1]["ExpirationDate"] = datetime.datetime(2000, 1, 1)
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            self.prepare(directory)

    def test_reject_mixed_build_identities(self):
        self.settings[1]["buildSettings"]["ROOTSHELL_DEVELOPMENT_TEAM"] = "OTHER12345"
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            vpn.prepare(self.settings, Path(directory))

    def test_profile_certificate_pairing(self):
        certificate = b"original certificate DER"
        fingerprint = hashlib.sha1(certificate).hexdigest().upper()
        profile = {"DeveloperCertificates": [certificate]}
        vpn.check_profile_certificate(profile, fingerprint, "host")
        with self.assertRaisesRegex(ValueError, "not authorized"):
            vpn.check_profile_certificate(profile, "E" * 40, "host")

    def test_explicit_keychain_and_fingerprint(self):
        fingerprint = "A" * 40
        listing = f'  1) {fingerprint} "Developer ID Application: Example (ABCDE12345)"\n'
        with patch.object(vpn.subprocess, "check_output", return_value=listing) as command:
            self.assertEqual(vpn.resolve_identity(fingerprint, "/example.keychain-db"), fingerprint)
            self.assertEqual(command.call_args.args[0][-1], "/example.keychain-db")
            with self.assertRaisesRegex(ValueError, "exactly one"):
                vpn.resolve_identity("B" * 40)

    def test_ambiguous_certificate_name_requires_fingerprint(self):
        name = "Developer ID Application: Example (ABCDE12345)"
        listing = f'  1) {"A" * 40} "{name}"\n  2) {"B" * 40} "{name}"\n'
        with patch.object(vpn.subprocess, "check_output", return_value=listing):
            with self.assertRaisesRegex(ValueError, "exactly one"):
                vpn.resolve_identity(name)

    def test_both_profiles_must_authorize_selected_certificate(self):
        original = b"original certificate"
        selected = hashlib.sha1(original).hexdigest().upper()
        self.profiles[0]["DeveloperCertificates"] = [original]
        self.profiles[1]["DeveloperCertificates"] = [b"different certificate"]
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(vpn, "resolve_identity", return_value=selected):
                with patch.object(vpn.subprocess, "check_output",
                                  side_effect=[plistlib.dumps(p) for p in self.profiles]):
                    with self.assertRaisesRegex(ValueError, "tunnel: signing certificate"):
                        vpn.prepare(self.settings, Path(directory),
                                    ("host.profile", "tunnel.profile"), selected)
            self.assertFalse((Path(directory) / "identity.json").exists())


if __name__ == "__main__":
    unittest.main()
