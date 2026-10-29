"""Regression tests: every host probe, package and service call is mocked."""
import ipaddress
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
UNIX = ['wiz-keepalive-installer-linux.sh', 'wiz-keepalive-installer-macos.command']


class Scripts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='wiz-tests-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        (self.root / 'systemd').mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        CALLS=str(self.root / 'calls'), TEST_ROOT=str(self.root))
        self.mock('id', 'echo 0')
        self.mock('uname', 'echo "${TEST_PLATFORM:-Linux}"')
        self.mock('ip', '''case "$*" in
            '-4 route show default') echo 'default via 192.168.1.129 dev eth0' ;;
            '-o -4 addr show dev eth0 scope global') echo "2: eth0 inet ${TEST_ADDRESS:-192.168.1.200/25} scope global eth0" ;;
            '-o -4 addr show dev wlan0 scope global') echo '3: wlan0 inet 10.2.3.4/24 scope global wlan0' ;;
        esac''')
        self.mock('route', "echo 'interface: en0'")
        self.mock('ifconfig', "echo \"inet 192.168.1.200 netmask ${TEST_MASK:-0xffffff80} broadcast 192.168.1.255\"")
        self.mock('ping', 'echo "ping $*" >> "$CALLS"; exit "${TEST_PING_RC:-1}"')
        self.mock('nmap', 'echo "nmap $*" >> "$CALLS"; exit "${TEST_NMAP_RC:-0}"')
        self.mock('nc', 'exit 1')
        self.mock('apt-get', 'echo "apt-get $*" >> "$CALLS"; exit 1')
        self.mock('cron', 'exit 0')
        self.mock('flock', 'exit 0')
        self.mock('service', 'echo "service $*" >> "$CALLS"; exit "${TEST_SERVICE_RC:-0}"')
        self.mock('systemctl', '''echo "systemctl $*" >> "$CALLS"
            case "$*" in
                'is-enabled --quiet cron') exit "${TEST_ENABLED_RC:-0}" ;;
                'is-active --quiet cron') exit "${TEST_ACTIVE_RC:-0}" ;;
                'start cron') exit "${TEST_START_RC:-0}" ;;
                *) exit "${TEST_SYSTEMCTL_RC:-0}" ;;
            esac''')
        source = (REPO / 'wiz-keepalive.sh').read_text()
        for key, name in [('WRAPPER', 'sweep'), ('CRONFILE', 'cron'), ('UNITFILE', 'service'), ('TIMERFILE', 'timer')]:
            source = re.sub(r'^' + key + r'=.*$', key + '=' + str(self.root/name), source, flags=re.M)
        source = source.replace('/run/systemd/system', str(self.root/'systemd'))
        source = source.replace('/run/lock/wiz-keepalive.lock', str(self.root/'lock'))
        self.hub = source
        self.functions = source.rsplit('\ncase "$1" in', 1)[0]

    def mock(self, name, content):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + content + '\n')
        path.chmod(0o755)

    def run_shell(self, text, args=(), extra=None, stdin=None):
        env = self.env | (extra or {})
        return subprocess.run(['sh', '-c', text, 'test', *args], input=stdin,
                              env=env, cwd=self.root, text=True, capture_output=True, timeout=20)

    def call_function(self, body, extra=None):
        return self.run_shell(self.functions + '\n' + body, extra=extra)

    def lines(self):
        p = self.root/'calls'
        return p.read_text().splitlines() if p.exists() else []

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_shell_syntax(self):
        for name in ['wiz-keepalive.sh', *UNIX]:
            with self.subTest(file=name):
                self.assert_ok(subprocess.run(['sh', '-n', str(REPO/name)], text=True, capture_output=True))

    def test_cron_has_six_even_ten_minute_gaps(self):
        result = self.call_function('stagger_minutes')
        self.assert_ok(result)
        minutes = list(map(int, result.stdout.strip().split(',')))
        self.assertEqual(len(minutes), 6)
        self.assertEqual([b-a for a,b in zip(minutes, minutes[1:] + [minutes[0]+60])], [10]*6)

    def test_cidr_ranges_match_independent_ipaddress_reference(self):
        for address in ['192.168.1.200/25', '10.2.3.244/26', '10.2.3.244/27',
                        '10.2.3.244/28', '10.2.3.244/29', '10.2.3.244/30',
                        '10.2.3.244/31', '10.2.3.244/32', '10.2.3.244/23',
                        '10.2.3.244/16', '255.255.255.255/32']:
            with self.subTest(cidr=address):
                result = self.run_shell(self.functions + '\nipv4_range "$1" hosts', [address])
                self.assert_ok(result)
                network = ipaddress.ip_network(address, strict=False)
                self.assertEqual(result.stdout.splitlines(), list(map(str, network.hosts())))

    def test_invalid_and_oversized_cidrs_fail(self):
        for value in ['1.2.3.4/15', '1.2.3.4/33', '1.2.3.4/x', '999.2.3.4/24', '1.2.3/24', 'garbage']:
            with self.subTest(cidr=value):
                result = self.run_shell(self.functions + '\nipv4_range "$1" hosts', [value])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_mac_netmasks(self):
        for mask, expected in [('0xffffff80', '192.168.1.128/25'), ('0xfffffe00', '192.168.0.0/23'), ('255.255.255.128', '192.168.1.128/25')]:
            with self.subTest(mask=mask):
                result = self.call_function('detect_cidr', {'TEST_PLATFORM': 'Darwin', 'TEST_MASK': mask})
                self.assert_ok(result)
                self.assertEqual(result.stdout.strip(), expected)
        self.assertNotEqual(self.call_function('detect_cidr', {'TEST_PLATFORM': 'Darwin', 'TEST_MASK': '0xffff00ff'}).returncode, 0)

    def test_fallback_targets_correct_subnet_and_reports_broken_ping(self):
        result = self.call_function('ping_hosts 192.168.1.200/25 sweep', {'TEST_PING_RC': '1'})
        self.assert_ok(result)
        targets = [line.split()[-1] for line in self.lines()]
        self.assertEqual(set(targets), set(map(str, ipaddress.ip_network('192.168.1.128/25').hosts())))
        result = self.call_function('ping_hosts 192.168.1.200/30 sweep', {'TEST_PING_RC': '127'})
        self.assertNotEqual(result.returncode, 0)

    def test_failed_cron_start_is_install_failure(self):
        result = self.run_shell(self.hub, ['install'], {'TEST_ACTIVE_RC': '3', 'TEST_START_RC': '1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('installed: every', result.stdout)
        self.assertFalse((self.root/'cron').exists())

    def test_inactive_cron_status_fails(self):
        self.assert_ok(self.run_shell(self.hub, ['install']))
        result = self.run_shell(self.hub, ['status'], {'TEST_ACTIVE_RC': '3'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cron is not running', result.stdout)

    def test_install_status_reinstall_remove(self):
        self.assert_ok(self.run_shell(self.hub, ['install']))
        first = (self.root/'cron').read_text()
        self.assertFalse(any('disable --now wiz-keepalive.timer' in x for x in self.lines()))
        self.assert_ok(self.run_shell(self.hub, ['status']))
        self.assert_ok(self.run_shell(self.hub, ['install']))
        self.assertEqual((self.root/'cron').read_text(), first)
        self.assert_ok(self.run_shell(self.hub, ['remove']))
        self.assertFalse((self.root/'cron').exists())
        self.assertFalse((self.root/'sweep').exists())
        self.assertNotEqual(self.run_shell(self.hub, ['status']).returncode, 0)

    def test_interface_override_survives_install(self):
        self.assert_ok(self.run_shell(self.hub, ['install'], {'WIZ_KEEPALIVE_INTERFACE': 'wlan0'}))
        status = self.run_shell(self.hub, ['status'])
        self.assert_ok(status)
        self.assertIn('subnet 10.2.3.0/24', status.stdout)
        self.assert_ok(subprocess.run(['sh', str(self.root/'sweep')], env=self.env, text=True, capture_output=True))
        self.assertTrue(any('10.2.3.0/24' in line for line in self.lines()))

    def test_wrapper_reports_nmap_failure_and_prevents_overlap(self):
        self.assert_ok(self.run_shell(self.hub, ['install']))
        result = subprocess.run(['sh', str(self.root/'sweep')], env=self.env | {'TEST_NMAP_RC': '2'}, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.mock('flock', 'exit 75')
        (self.root/'calls').write_text('')
        result = subprocess.run(['sh', str(self.root/'sweep')], env=self.env, text=True, capture_output=True)
        self.assert_ok(result)
        self.assertEqual(self.lines(), [])

    def test_real_lock_skips_a_competing_sweep(self):
        real_flock = shutil.which('flock')
        if not real_flock:
            self.skipTest('native flock is not installed on this test platform')
        import fcntl
        self.mock('flock', 'exec "' + real_flock + '" "$@"')
        self.assert_ok(self.run_shell(self.hub, ['install']))
        (self.root/'calls').write_text('')
        with (self.root/'lock').open('w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = subprocess.run(['sh', str(self.root/'sweep')], env=self.env, text=True, capture_output=True)
        self.assert_ok(result)
        self.assertEqual(self.lines(), [])

    def test_timer_install_failure_is_not_success(self):
        timer_hub = self.hub.replace('command -v cron >/dev/null 2>&1 || command -v crontab >/dev/null 2>&1', 'false')
        result = self.run_shell(timer_hub, ['install'], {'TEST_SYSTEMCTL_RC': '1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('installed:', result.stdout)

    def test_scheduler_switching_removes_alternate_only_after_success(self):
        timer_hub = self.hub.replace('command -v cron >/dev/null 2>&1 || command -v crontab >/dev/null 2>&1', 'false')
        self.assert_ok(self.run_shell(self.hub, ['install']))
        self.assert_ok(self.run_shell(timer_hub, ['install']))
        self.assertFalse((self.root/'cron').exists())
        self.assertTrue((self.root/'timer').exists())
        self.assert_ok(self.run_shell(self.hub, ['status']))
        self.assert_ok(self.run_shell(self.hub, ['install']))
        self.assertTrue((self.root/'cron').exists())
        self.assertFalse((self.root/'timer').exists())
        self.assertTrue(any('disable --now wiz-keepalive.timer' in line for line in self.lines()))

    def test_failed_migration_keeps_previous_cron_entry(self):
        timer_hub = self.hub.replace('command -v cron >/dev/null 2>&1 || command -v crontab >/dev/null 2>&1', 'false')
        self.assert_ok(self.run_shell(self.hub, ['install']))
        previous = (self.root/'cron').read_text()
        result = self.run_shell(timer_hub, ['install'], {'TEST_SYSTEMCTL_RC': '1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root/'cron').read_text(), previous)

    def test_no_route_fallback(self):
        self.mock('ip', '''case "$*" in
            '-4 route show default') exit 0 ;;
            '-o -4 addr show scope global') printf '3: wlan0 inet 192.168.50.2/24 scope global wlan0\\n' ;;
            '-o -4 addr show dev wlan0 scope global') printf '3: wlan0 inet 192.168.50.2/24 scope global wlan0\\n' ;;
        esac''')
        result = self.call_function('detect_cidr')
        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), '192.168.50.0/24')

    def test_discovery_scan_failure_is_not_empty_success(self):
        for name in UNIX:
            for platform in ['Linux', 'Darwin']:
                with self.subTest(file=name, platform=platform):
                    result = subprocess.run(['sh', str(REPO/name), 'discover'], env=self.env | {'TEST_NMAP_RC': '2', 'TEST_PLATFORM': platform}, text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('nmap discovery failed', result.stderr)

    def test_bad_action_and_bad_host_fail_before_ssh(self):
        self.mock('ssh', 'echo SSH >> "$CALLS"; exit 0')
        for name in UNIX:
            for args in [('instal', '192.0.2.1'), ('install', 'bad;hostname')]:
                with self.subTest(file=name, args=args):
                    result = subprocess.run(['sh', str(REPO/name), *args], env=self.env, text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.lines(), [])

    def test_piped_installers_download_instead_of_using_sidecar(self):
        (self.root/'wiz-keepalive.sh').write_text('# stale payload\n')
        self.mock('curl', '''for arg in "$@"; do destination=$arg; done
            printf '#!/bin/sh\\n# downloaded payload\\n' > "$destination"''')
        self.mock('ssh', 'cat >> "$CALLS"; exit 0')
        for name in UNIX:
            with self.subTest(file=name):
                (self.root/'calls').write_text('')
                result = subprocess.run(['sh', '-s', '--', 'install', '192.0.2.1'], input=(REPO/name).read_text(), cwd=self.root, env=self.env, text=True, capture_output=True)
                self.assert_ok(result)
                self.assertIn('# downloaded payload', self.lines())
                self.assertNotIn('# stale payload', self.lines())

    def test_remote_failure_is_preserved_and_retry_file_exists(self):
        payload = self.root/'payload'
        payload.write_text('#!/bin/sh\nexit 0\n')
        self.mock('sudo', 'exit 23')
        # Rewrite only the remote mktemp template to keep test files isolated.
        self.mock('ssh', '''while [ "$1" = '-o' ]; do shift 2; done
            shift
            remote=$(printf '%s' "$1" | sed "s|/tmp/wiz-keepalive.XXXXXX|$TEST_ROOT/remote.XXXXXX|g")
            exec sh -c "$remote"''')
        for name in UNIX:
            with self.subTest(file=name):
                result = subprocess.run(['sh', str(REPO/name), 'install', '192.0.2.1'], env=self.env | {'WIZ_KEEPALIVE_PAYLOAD': str(payload)}, text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                match = re.search(r'Retry on the hub: sudo sh (\S+) install', result.stderr)
                self.assertIsNotNone(match, result.stdout + result.stderr)
                self.assertEqual(Path(match[1]).read_text(), payload.read_text())

    def test_multiple_hubs_keep_failed_exit_status(self):
        payload = self.root/'payload'
        payload.write_text('#!/bin/sh\nexit 0\n')
        self.mock('ssh', '''while [ "$1" = '-o' ]; do shift 2; done
            case "$1" in pi@192.0.2.1) exit 23 ;; *) exit 0 ;; esac''')
        for name in UNIX:
            with self.subTest(file=name):
                result = subprocess.run(['sh', str(REPO/name), 'install', '192.0.2.1', '192.0.2.2'], env=self.env | {'WIZ_KEEPALIVE_PAYLOAD': str(payload)}, text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('192.0.2.2: succeeded', result.stdout)

    def test_download_failure_prevents_ssh(self):
        self.mock('curl', 'exit 22')
        self.mock('ssh', 'echo SSH >> "$CALLS"; exit 0')
        for name in UNIX:
            result = subprocess.run(['sh', str(REPO/name), 'install', '192.0.2.1'], env=self.env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.lines(), [])


if __name__ == '__main__':
    unittest.main()
