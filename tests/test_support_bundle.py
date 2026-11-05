"""Verify real age encryption when available, plus bundle factory secret handling."""
import argparse
import importlib.util
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("bundle_factory", REPO / "make-support-bundle.py")
factory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(factory)


@unittest.skipUnless(shutil.which("age"), "real encryption test needs age installed")
class Encryption(unittest.TestCase):
    def decrypt(self, encrypted, output, password):
        pid, fd = pty.fork()
        if pid == 0:
            os.execvp("age", ["age", "--decrypt", "-o", str(output), str(encrypted)])
        transcript = b""
        answered = False
        deadline = time.monotonic() + 30
        try:
            while time.monotonic() < deadline:
                if not select.select([fd], [], [], 0.5)[0]:
                    continue
                try:
                    data = os.read(fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                transcript += data
                if not answered and b"Enter passphrase:" in transcript:
                    os.write(fd, password.encode() + b"\n")
                    answered = True
        finally:
            os.close(fd)
            _, status = os.waitpid(pid, 0)
        return status

    def test_roundtrip_wrong_password_and_tamper_detection(self):
        with tempfile.TemporaryDirectory(prefix="support-crypto-test-") as temporary:
            root = Path(temporary)
            source, encrypted, output = [root / name for name in ["source", "profile.age", "output"]]
            secret = "private device config; never public"
            password = "test-only-strong-random-passphrase-123456789"
            source.write_text(secret)
            factory.age_encrypt(source, encrypted, password)
            self.assertNotIn(secret.encode(), encrypted.read_bytes())
            self.assertEqual(self.decrypt(encrypted, output, password), 0)
            self.assertEqual(output.read_text(), secret)
            self.assertNotEqual(self.decrypt(encrypted, root / "wrong-password", "incorrect-password"), 0)
            ciphertext = encrypted.read_bytes()
            encrypted.write_bytes(ciphertext[:-1] + bytes([ciphertext[-1] ^ 1]))
            self.assertNotEqual(self.decrypt(encrypted, root / "tampered", password), 0)


class Factory(unittest.TestCase):
    def test_password_cannot_be_written_into_git_repository(self):
        args = argparse.Namespace(label="customer-pi", neon="neon", output=REPO / "customer.age",
                                  password_file=REPO / "password.txt", ssh_key=Path("unused"))
        with patch.object(factory.shutil, "which", return_value="tool"):
            with self.assertRaisesRegex(ValueError, "OUTSIDE"):
                factory.make_bundle(args)

    def test_factory_never_sends_private_key_or_password_to_neon(self):
        with tempfile.TemporaryDirectory(prefix="support-factory-test-") as temporary:
            root = Path(temporary)
            pub = root / "operator.pub"
            pub.write_text("ssh-ed25519 AAAATEST comment\n")
            args = argparse.Namespace(label="customer-pi", neon="neon", output=root / "customer.age",
                                      password_file=root / "password", ssh_key=pub)
            private = "device-private-test-value"
            public = "c" * 43 + "="
            server = "s" * 43 + "="
            calls = []

            def command(argv, **kwargs):
                calls.append((argv, kwargs))
                if argv[:2] == ["wg", "genkey"]:
                    return private
                if argv[:2] == ["wg", "pubkey"]:
                    self.assertEqual(kwargs["input"], private + "\n")
                    return public
                if argv[0] == "ssh":
                    self.assertNotIn(private, repr(argv) + kwargs["input"])
                    return "ADDRESS=10.88.2.1\nSERVER_PUBLIC_KEY=" + server
                return ""

            def encrypt(source, destination, password):
                data = source.read_text()
                self.assertIn("PRIVATE_KEY=" + private, data)
                self.assertNotIn(password, data)
                self.assertGreaterEqual(len(password), 32)
                destination.write_bytes(b"authenticated ciphertext placeholder")

            with patch.object(factory.shutil, "which", return_value="tool"), \
                    patch.object(factory, "run", side_effect=command), \
                    patch.object(factory, "age_encrypt", side_effect=encrypt), \
                    patch("builtins.print"):
                factory.make_bundle(args)
            self.assertNotIn(private.encode(), args.output.read_bytes())
            self.assertEqual(args.password_file.stat().st_mode & 0o777, 0o600)
            password = args.password_file.read_text().strip()
            self.assertNotIn(password, repr(calls))


if __name__ == "__main__":
    unittest.main()
