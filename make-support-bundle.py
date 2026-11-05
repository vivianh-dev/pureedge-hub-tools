#!/usr/bin/env python3
"""Admin-only: enroll one temporary peer and create an encrypted customer bundle."""
import argparse
import datetime as dt
import errno
import os
from pathlib import Path
import pty
import re
import secrets
import select
import shlex
import shutil
import signal
import subprocess
import tempfile
import time


REPO = Path(__file__).resolve().parent


def age_encrypt(source, destination, password):
    """Answer age's terminal prompts without exposing the password in argv/env/logs."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("age", ["age", "--passphrase", "-o", str(destination), str(source)])
    prompts = [b"Enter passphrase", b"Confirm passphrase"]
    buffer = b""
    sent = 0
    deadline = time.monotonic() + 60
    try:
        while True:
            if time.monotonic() >= deadline:
                os.kill(pid, signal.SIGTERM)
                raise RuntimeError("age encryption timed out")
            if not select.select([fd], [], [], 0.5)[0]:
                continue
            try:
                chunk = os.read(fd, 4096)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            buffer += chunk
            if sent < len(prompts) and prompts[sent] in buffer and b":" in buffer:
                os.write(fd, password.encode() + b"\n")
                sent += 1
                buffer = b""
    finally:
        os.close(fd)
        _, status = os.waitpid(pid, 0)
    if status or sent != 2 or not destination.is_file():
        raise RuntimeError("age encryption failed (terminal output withheld)")


def run(command, **kwargs):
    result = subprocess.run(command, text=True, capture_output=True, **kwargs)
    if result.returncode:
        # These commands receive only PUBLIC keys. Never include local private data.
        raise RuntimeError("Command failed: " + command[0] + "\n" + result.stderr)
    return result.stdout.strip()


def make_bundle(args):
    for tool in ["age", "wg", "ssh", "ssh-keygen"]:
        if not shutil.which(tool):
            raise ValueError(f"{tool} is required on the admin machine")
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}", args.label):
        raise ValueError("invalid device label")
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9@._-]*", args.neon):
        raise ValueError("invalid Neon SSH target")
    output = args.output.resolve()
    password_file = args.password_file.resolve()
    if password_file == REPO or REPO in password_file.parents:
        raise ValueError("the password file must be OUTSIDE the Git repository")
    if output.exists() or password_file.exists():
        raise ValueError("output/password file already exists; choose new paths")
    if output.suffix != ".age":
        raise ValueError("encrypted output filename must end in .age")
    run(["ssh-keygen", "-l", "-f", str(args.ssh_key)])
    key_parts = args.ssh_key.read_text().split()
    if len(key_parts) < 2 or not re.fullmatch(r"[A-Za-z0-9+/=]+", key_parts[1]):
        raise ValueError("invalid SSH public key")
    ssh_type, ssh_body = key_parts[:2]
    private_key = run(["wg", "genkey"])
    public_key = run(["wg", "pubkey"], input=private_key + "\n")
    expires = int(time.time()) + 86400
    expiry_utc = dt.datetime.fromtimestamp(expires, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    output.parent.mkdir(parents=True, exist_ok=True)
    password_file.parent.mkdir(parents=True, exist_ok=True)
    password = secrets.token_urlsafe(24)
    fd = os.open(password_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(password + "\n")
    helper = (REPO / "wireguard-neon.sh").read_text()
    registration = run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", args.neon,
                        shlex.join(["sh", "-s", "--", args.label, public_key, str(expires)])], input=helper)
    fields = dict(line.split("=", 1) for line in registration.splitlines() if "=" in line)
    address = fields["ADDRESS"]
    if not re.fullmatch(r"10\.88\.\d{1,3}\.\d{1,3}", address):
        raise ValueError("invalid address returned by Neon")
    server_public = fields["SERVER_PUBLIC_KEY"]
    if not re.fullmatch(r"[A-Za-z0-9+/]{43}=", server_public):
        raise ValueError("invalid server public key")
    values = dict(VERSION="1", LABEL=args.label, EXPIRES=str(expires), EXPIRES_UTC=expiry_utc,
                  ADDRESS=address, PRIVATE_KEY=private_key, SERVER_PUBLIC_KEY=server_public,
                  ENDPOINT="drgb.vivianh.dev:51820", SSH_TYPE=ssh_type, SSH_BODY=ssh_body)
    with tempfile.TemporaryDirectory(prefix="pureedge-bundle-") as temporary:
        source = Path(temporary) / "profile"
        fd = os.open(source, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write("".join(key + "=" + value + "\n" for key, value in values.items()))
        encrypted = Path(temporary) / "profile.age"
        age_encrypt(source, encrypted, password)
        # Only the authenticated ciphertext is copied into the repository.
        with output.open("xb") as stream:
            stream.write(encrypted.read_bytes())
    print(f"Encrypted customer bundle: {output}")
    print(f"Password file (send separately): {password_file}")
    print(f"Device: {args.label}\nWireGuard IP: {address}\nExpires: {expiry_utc}")
    print(f"Expiry timer: pureedge-support-{args.label}.timer on Neon")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", default="support-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d") + "-" + secrets.token_hex(3))
    parser.add_argument("--neon", default="neon")
    parser.add_argument("--ssh-key", required=True, type=Path, help="Your admin SSH PUBLIC key (.pub)")
    parser.add_argument("--output", required=True, type=Path, help="Encrypted .age file to upload")
    parser.add_argument("--password-file", required=True, type=Path, help="Private local file OUTSIDE this repository")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        make_bundle(args)
    except (ValueError, RuntimeError, OSError, KeyError) as exc:
        parser.exit(1, str(exc) + "\nA partially registered peer will still expire automatically.\n")


if __name__ == "__main__":
    main()
