"""Exercise all three scripts with isolated files and mocked SSH/services/packages.

No host services, network, or real WireGuard configuration are changed.
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import time


REPO = Path(__file__).resolve().parents[1]
DEVICE_PUBLIC = base64.b64encode(b"d" * 32).decode()
SERVER_PUBLIC = base64.b64encode(b"s" * 32).decode()
OTHER_PUBLIC = base64.b64encode(b"o" * 32).decode()
PRIVATE = base64.b64encode(b"k" * 32).decode()


class WireGuard(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pureedge-wg-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "pi-home"
        self.home.mkdir()
        (self.root / "systemd").mkdir()
        self.services = self.root / "services.json"
        self.services.write_text(json.dumps({"wg-quick@wg0.service": {"active": True, "enabled": True}}))
        self.fleet = self.root / "fleet.json"
        self.fleet.write_text('{"peers":[]}')
        self.wg_dir = self.root / "wireguard"
        self.conf = self.wg_dir / "wg-neon.conf"
        self.key = self.wg_dir / "wg-neon.key"
        self.keypair = self.root / "admin key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.keypair)],
                       check=True, capture_output=True)
        self.pub = Path(str(self.keypair) + ".pub")
        self.env = dict(os.environ, PATH=str(self.bin) + ":" + os.environ["PATH"],
                        TEST_ROOT=str(self.root), DEVICE_PUBLIC=DEVICE_PUBLIC,
                        SERVER_PUBLIC=SERVER_PUBLIC, TEST_PRIVATE=PRIVATE)
        source = (REPO / "wireguard-pi.sh").read_text()
        for before, after in [
            ("PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH", "PATH=$PATH"),
            ("WG_DIR=/etc/wireguard", "WG_DIR='" + str(self.wg_dir) + "'"),
            ("/run/systemd/system", str(self.root / "systemd")),
            ("/run/lock/pureedge-wireguard.lock", str(self.root / "install.lock")),
            ("/etc/ssh/ssh_host_ed25519_key.pub", str(self.pub)),
            ("/usr/sbin/sshd", str(self.bin / "sshd")),
        ]:
            source = source.replace(before, after)
        self.pi_payload = self.root / "pi.sh"
        self.pi_payload.write_text(source)
        (self.root / "neon-bin").mkdir()
        (self.root / "neon-systemd").mkdir()
        self.neon_payload = self.root / "neon.sh"
        self.neon_payload.write_text((REPO / "wireguard-neon.sh").read_text()
                                     .replace("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "PATH=$PATH")
                                     .replace("/usr/local/bin", str(self.root / "neon-bin"))
                                     .replace("/etc/systemd/system", str(self.root / "neon-systemd")))
        self.env.update(PUREEDGE_WG_PI_PAYLOAD=str(self.pi_payload),
                        PUREEDGE_WG_NEON_PAYLOAD=str(self.neon_payload))
        self.mock("id", '''case "$1" in -u) echo 0 ;; -gn) echo pi ;; -un) echo pi ;; esac''')
        self.mock("getent", 'printf "pi:x:1000:1000:Pi:%s/pi-home:/bin/sh\\n" "$TEST_ROOT"')
        self.mock("flock", "exit 0")
        self.mock("sshd", 'exit "${TEST_SSHD_RC:-0}"')
        self.mock("chown", "exit 0")
        self.mock("ping", "exit 0")
        self.mock("sleep", "exit 0")
        self.mock("apt-get", 'echo package-call >> "$TEST_ROOT/packages"; exit 99')
        self.mock("wg-quick", "exit 0")
        self.mock_python("date", '''
import datetime, sys, time
args=sys.argv[1:]
if args == ['+%s']: print(int(time.time()))
elif args[:2] == ['-u','-d']:
    print(datetime.datetime.fromtimestamp(int(args[2][1:]), datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC'))
else: raise SystemExit('unexpected date call')
''')
        self.mock_python("age", '''
import os, pathlib, sys
if os.environ.get('TEST_DECRYPT_FAIL'): sys.exit(1)
args=sys.argv[1:]; assert args[0]=='--decrypt'
pathlib.Path(args[args.index('-o')+1]).write_bytes(pathlib.Path(args[-1]).read_bytes())
''')
        self.mock_python("install", '''
import os, pathlib, sys
args = sys.argv[1:]
p = pathlib.Path(args[-1]); p.mkdir(parents=True, exist_ok=True)
os.chmod(p, int(args[args.index('-m')+1], 8))
''')
        self.mock_python("ip", '''
import os, sys
args=sys.argv[1:]
if args == ['-4','route','show','scope','link']:
    print(os.environ.get('TEST_ROUTES', '192.168.1.0/24 dev eth0 proto kernel scope link'))
elif args[:3] == ['link','add','wgn-check']:
    sys.exit(int(os.environ.get('TEST_BAD_KERNEL','0')))
''')
        self.mock_python("wg", '''
import os, pathlib, sys, time
r=pathlib.Path(os.environ['TEST_ROOT']); args=sys.argv[1:]
if args == ['genkey']:
    with (r/'key-generations').open('a') as f: f.write('generated\\n')
    print(os.environ['TEST_PRIVATE'])
elif args == ['pubkey']:
    assert sys.stdin.read().strip() == os.environ['TEST_PRIVATE']
    print(os.environ['DEVICE_PUBLIC'])
elif args == ['show','wg0','public-key']:
    print(os.environ['SERVER_PUBLIC'])
elif args == ['show','wg-neon','latest-handshakes']:
    age=os.environ.get('TEST_HANDSHAKE_AGE','0')
    timestamp=0 if age=='none' else int(time.time())-int(age)
    print(os.environ['SERVER_PUBLIC']+'\\t'+str(timestamp))
else:
    raise SystemExit('unexpected wg call: '+repr(args))
''')
        self.mock_python("systemctl", '''
import json, os, pathlib, sys
r=pathlib.Path(os.environ['TEST_ROOT']); p=r/'services.json'
s=json.loads(p.read_text()); args=sys.argv[1:]; verb=args[0]; unit=args[-1]
with (r/'service-calls').open('a') as f: f.write(' '.join(args)+'\\n')
if verb == 'daemon-reload': sys.exit(0)
state=s.setdefault(unit, {'active':False,'enabled':False})
if verb == 'is-active': sys.exit(0 if state['active'] else 3)
if verb == 'is-enabled': sys.exit(0 if state['enabled'] else 1)
if unit == 'ssh.service' and os.environ.get('TEST_SSH_SERVICE_FAIL'): sys.exit(1)
if unit.endswith('.timer') and os.environ.get('TEST_TIMER_FAIL'): sys.exit(1)
if verb == 'restart' and os.environ.get('TEST_RESTART_FAIL'): sys.exit(1)
if verb in ['restart','start']: state['active']=True
elif verb == 'stop': state['active']=False
elif verb == 'enable': state.update(active=True, enabled=True)
else: raise SystemExit('unexpected systemctl call: '+repr(args))
p.write_text(json.dumps(s))
''')
        self.mock_python("neon-fleet", '''
import json, os, pathlib, sys
r=pathlib.Path(os.environ['TEST_ROOT']); p=r/'fleet.json'; f=json.loads(p.read_text())
args=sys.argv[1:]
if args == ['list','--json']:
    if os.environ.get('TEST_FLEET_READ_FAIL'): sys.exit(1)
    print(json.dumps(f))
elif args[0] == 'add':
    label=args[args.index('--label')+1]; key=args[args.index('--pubkey')+1]
    if any(x['label']==label or x['pubkey']==key for x in f['peers']): sys.exit(1)
    assert args[args.index('--class')+1] == 'production'
    f['peers'].append({'id':'drgb-'+str(len(f['peers'])+1),'label':label,'pubkey':key,'class':'production','ip':'10.88.2.'+str(len(f['peers'])+1)})
    p.write_text(json.dumps(f))
elif args[0] == 'remove':
    f['peers']=[x for x in f['peers'] if x.get('id')!=args[1]]
    p.write_text(json.dumps(f))
else:
    raise SystemExit('unexpected fleet call: '+repr(args))
''')
        self.mock_python("ssh", '''
import os, pathlib, shlex, subprocess, sys
args=sys.argv[1:]; r=pathlib.Path(os.environ['TEST_ROOT'])
if '-G' in args:
    print('identityfile '+str(r/'admin key'))
    sys.exit(0)
if '-O' in args: sys.exit(0)
i=0
while args[i] in ['-o','-i']: i+=2
target=args[i]; command=' '.join(args[i+1:])
with (r/'ssh-calls').open('a') as f: f.write(target+' '+command+'\\n')
if target.startswith('pi@10.88.'):
    assert 'StrictHostKeyChecking=yes' in args
    assert 'BatchMode=yes' in args
    hosts=next(x.split('=',1)[1] for x in args if x.startswith('UserKnownHostsFile='))
    assert pathlib.Path(hosts).read_text().startswith(target[3:]+' ssh-ed25519 ')
    if os.environ.get('TEST_SSH_VERIFY_FAIL'): sys.exit(1)
    assert command == 'test "$(id -un)" = pi'
    sys.exit(0)
if command.startswith('sudo -n '):
    if os.environ.get('TEST_SUDO_FAIL'): sys.exit(1)
    command=command[len('sudo -n '):]
payload=sys.stdin.read()
if command.startswith('sh -s --'):
    result=subprocess.run(shlex.split(command), input=payload, text=True, env=os.environ)
else:
    result=subprocess.run(['sh','-c',command], input=payload, text=True, env=os.environ)
sys.exit(result.returncode)
''')

    def mock(self, name, body):
        p = self.bin / name
        p.write_text("#!/bin/sh\n" + body + "\n")
        p.chmod(0o755)

    def mock_python(self, name, body):
        p = self.bin / name
        p.write_text("#!" + sys.executable + "\n" + body)
        p.chmod(0o755)

    def run_installer(self, extra=None, label="customer-pi", extra_args=()):
        return subprocess.run(["sh", str(REPO / "wireguard-installer-macos.command"),
                               "install", "192.168.1.50", label,
                               "--ssh-key", str(self.pub), *extra_args],
                              env=self.env | (extra or {}), text=True,
                              capture_output=True, timeout=30)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def peers(self):
        return json.loads(self.fleet.read_text())["peers"]

    def seed_peer(self, pubkey=DEVICE_PUBLIC, peer_class="production"):
        self.fleet.write_text(json.dumps({"peers": [{"id": "drgb-1", "label": "customer-pi", "pubkey": pubkey,
                                                     "class": peer_class, "ip": "10.88.2.1"}]}))

    def run_customer(self, extra=None, expires=None):
        bundle = self.root / "customer.age"
        bundle.write_text("\n".join([
            "VERSION=1", "LABEL=customer-pi", "EXPIRES=" + str(expires or int(time.time()) + 3600),
            "EXPIRES_UTC=test-expiry", "ADDRESS=10.88.2.1", "PRIVATE_KEY=" + PRIVATE,
            "SERVER_PUBLIC_KEY=" + SERVER_PUBLIC, "ENDPOINT=drgb.vivianh.dev:51820",
            "SSH_TYPE=" + self.pub.read_text().split()[0],
            "SSH_BODY=" + self.pub.read_text().split()[1], "",
        ]))
        return subprocess.run(["sh", str(REPO / "wireguard-customer-macos.command"),
                               "install", "192.168.1.50", str(bundle)],
                              env=self.env | (extra or {}), text=True, capture_output=True, timeout=30)

    def run_expiring_enrollment(self, extra=None, expires=None):
        return subprocess.run(["sh", str(self.neon_payload), "customer-pi", DEVICE_PUBLIC,
                               str(expires or int(time.time()) + 3600)],
                              env=self.env | (extra or {}), text=True, capture_output=True, timeout=30)

    def test_customer_install_needs_no_neon_access_and_keeps_secrets_out_of_logs(self):
        self.seed_peer()
        result = self.run_customer()
        self.assert_ok(result)
        self.assertIn("Support tunnel handshake verified", result.stdout)
        self.assertIn("Support must still verify its SSH login", result.stdout)
        self.assertNotIn(PRIVATE, result.stdout + result.stderr)
        self.assertFalse((self.root / "key-generations").exists())
        self.assertNotIn("neon ", (self.root / "ssh-calls").read_text())
        self.assertEqual(self.key.read_text().strip(), PRIVATE)
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)
        self.assert_ok(self.run_customer())
        self.assertEqual(len(self.peers()), 1)

    def test_wrong_bundle_password_or_expiry_stops_before_ssh(self):
        result = self.run_customer({"TEST_DECRYPT_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nothing installed", result.stderr)
        self.assertFalse((self.root / "ssh-calls").exists())
        result = self.run_customer(expires=int(time.time()) - 10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expired", result.stderr)
        self.assertFalse((self.root / "ssh-calls").exists())

    def test_expiring_enrollment_schedules_persistent_revocation(self):
        self.assert_ok(self.run_expiring_enrollment())
        timer = self.root / "neon-systemd" / "pureedge-support-customer-pi.timer"
        service = timer.with_suffix(".service")
        self.assertIn("Persistent=true", timer.read_text())
        self.assertIn("Restart=on-failure", service.read_text())
        self.assertIn(DEVICE_PUBLIC, service.read_text())
        before = timer.read_text()
        self.assertNotEqual(self.run_expiring_enrollment().returncode, 0)
        self.assertEqual(timer.read_text(), before)
        self.assertEqual(len(self.peers()), 1)

    def test_failed_expiry_timer_prevents_registration(self):
        result = self.run_expiring_enrollment({"TEST_TIMER_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.peers(), [])

    def test_expiry_removes_only_the_original_matching_peer(self):
        self.assert_ok(self.run_expiring_enrollment())
        helper = self.root / "neon-bin" / "pureedge-expire-support-peer"
        # A changed key must not cause an unrelated enrollment to be revoked.
        self.seed_peer(OTHER_PUBLIC)
        command = ["sh", str(helper), "customer-pi", DEVICE_PUBLIC]
        self.assert_ok(subprocess.run(command, env=self.env, capture_output=True, text=True))
        self.assertEqual(len(self.peers()), 1)
        self.seed_peer()
        self.assert_ok(subprocess.run(command, env=self.env, capture_output=True, text=True))
        self.assertEqual(self.peers(), [])

    def test_expiration_outside_24_hours_is_rejected(self):
        for expiry in [int(time.time()) - 1, int(time.time()) + 90000]:
            self.assertNotEqual(self.run_expiring_enrollment(expires=expiry).returncode, 0)
        self.assertEqual(self.peers(), [])

    def test_success_config_keys_services_and_verified_ssh(self):
        auth = self.home / ".ssh" / "authorized_keys"
        auth.parent.mkdir()
        auth.write_text("existing-entry-without-newline")
        result = self.run_installer()
        self.assert_ok(result)
        self.assertIn("WireGuard and SSH verified", result.stdout)
        self.assertIn("10.88.2.1", result.stdout)
        self.assertNotIn(PRIVATE, result.stdout + result.stderr)
        self.assertEqual(self.key.read_text().strip(), PRIVATE)
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.conf.stat().st_mode & 0o777, 0o600)
        self.assertIn("AllowedIPs = 10.88.0.0/16", self.conf.read_text())
        self.assertNotIn("0.0.0.0/0", self.conf.read_text())
        self.assertIn("PersistentKeepalive = 25", self.conf.read_text())
        self.assertTrue(auth.read_text().startswith("existing-entry-without-newline\n"))
        self.assertIn(self.pub.read_text().split()[1], auth.read_text())
        self.assertEqual(len(self.peers()), 1)
        state = json.loads(self.services.read_text())
        for unit in ["ssh.service", "wg-quick@wg-neon.service"]:
            self.assertEqual(state[unit], {"active": True, "enabled": True})

    def test_retry_reuses_key_peer_authorization_and_running_profile(self):
        self.assert_ok(self.run_installer())
        first = self.conf.read_text()
        self.assert_ok(self.run_installer())
        self.assertEqual(self.conf.read_text(), first)
        self.assertEqual(len(self.peers()), 1)
        self.assertEqual((self.root / "key-generations").read_text().count("generated"), 1)
        auth = (self.home / ".ssh" / "authorized_keys").read_text()
        self.assertEqual(auth.count(self.pub.read_text().split()[1]), 1)
        self.assertEqual((self.root / "service-calls").read_text().count("restart wg-quick@wg-neon.service"), 1)

    def test_conflicting_key_or_class_is_not_replaced(self):
        for key, cls in [(OTHER_PUBLIC, "production"), (DEVICE_PUBLIC, "admin")]:
            with self.subTest(peer_class=cls):
                self.seed_peer(key, cls)
                before = self.fleet.read_text()
                result = self.run_installer()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("different key or peer class", result.stderr)
                self.assertEqual(self.fleet.read_text(), before)
                self.assertFalse(self.conf.exists())

    def test_fleet_read_failure_never_registers(self):
        result = self.run_installer({"TEST_FLEET_READ_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.peers(), [])
        self.assertFalse(self.conf.exists())

    def test_unsupported_kernel_stops_before_registration(self):
        result = self.run_installer({"TEST_BAD_KERNEL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("kernel WireGuard support", result.stderr)
        self.assertEqual(self.peers(), [])
        self.assertFalse(self.key.exists())

    def test_overlapping_local_subnets_stop_before_registration(self):
        for route in ["10.88.4.0/24 dev eth0", "10.0.0.0/8 dev wlan0"]:
            with self.subTest(route=route):
                result = self.run_installer({"TEST_ROUTES": route})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("local subnet overlaps", result.stderr)
                self.assertEqual(self.peers(), [])

    def test_unmanaged_profile_is_not_overwritten(self):
        self.wg_dir.mkdir()
        self.conf.write_text("unrelated existing VPN")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.conf.read_text(), "unrelated existing VPN")
        self.assertEqual(self.peers(), [])

    def test_missing_passwordless_sudo_stops_before_registration(self):
        result = self.run_installer({"TEST_SUDO_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Pi preparation failed", result.stderr)
        self.assertEqual(self.peers(), [])

    def test_failed_ssh_verification_is_failure_and_can_retry(self):
        result = self.run_installer({"TEST_SSH_VERIFY_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("remote SSH verification failed", result.stderr)
        self.assertNotIn("WireGuard and SSH verified", result.stdout)
        self.assertTrue(self.conf.exists())
        self.assert_ok(self.run_installer())
        self.assertEqual(len(self.peers()), 1)

    def test_missing_or_stale_handshakes_are_not_success(self):
        for age in ["none", "3600"]:
            with self.subTest(age=age):
                result = self.run_installer({"TEST_HANDSHAKE_AGE": age})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no handshake with Neon", result.stderr)
                self.assertNotIn("WireGuard and SSH verified", result.stdout)
                self.assertTrue(self.conf.exists())

    def test_failed_restart_restores_existing_profile(self):
        self.assert_ok(self.run_installer())
        old = self.conf.read_text().replace("drgb.vivianh.dev:51820", "old.example:51820")
        self.conf.write_text(old)
        result = self.run_installer({"TEST_RESTART_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("previous profile restored", result.stderr)
        self.assertEqual(self.conf.read_text(), old)
        self.assertTrue(json.loads(self.services.read_text())["wg-quick@wg-neon.service"]["active"])

    def test_failed_initial_restart_does_not_leave_broken_profile(self):
        result = self.run_installer({"TEST_RESTART_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.conf.exists())
        self.assertTrue(self.key.exists())
        self.assert_ok(self.run_installer())
        self.assertEqual(len(self.peers()), 1)

    def test_failed_ssh_service_does_not_claim_success(self):
        result = self.run_installer({"TEST_SSH_SERVICE_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.conf.exists())
        self.assertNotIn("WireGuard and SSH verified", result.stdout)

    def test_invalid_inputs_rejected_before_any_ssh(self):
        for label in ["bad;touch-pwned", "bad label", "-option", "a" * 64]:
            with self.subTest(label=label):
                self.assertNotEqual(self.run_installer(label=label).returncode, 0)
        self.assertFalse((self.root / "ssh-calls").exists())
        self.assertNotEqual(self.run_installer(extra_args=["--neon", "bad;target"]).returncode, 0)

    def test_public_key_autodetection_for_neon_identity(self):
        result = subprocess.run(["sh", str(REPO / "wireguard-installer-macos.command"),
                                 "install", "192.168.1.50", "customer-pi"],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assert_ok(result)

    def test_shell_syntax_and_help_do_not_connect(self):
        for filename in ["wireguard-installer-macos.command", "wireguard-pi.sh", "wireguard-neon.sh"]:
            self.assert_ok(subprocess.run(["sh", "-n", str(REPO / filename)], capture_output=True, text=True))
        result = subprocess.run(["sh", str(REPO / "wireguard-installer-macos.command"), "--help"],
                                env=self.env, capture_output=True, text=True)
        self.assert_ok(result)
        self.assertFalse((self.root / "ssh-calls").exists())


if __name__ == "__main__":
    unittest.main()
