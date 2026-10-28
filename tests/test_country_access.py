"""Country-policy regressions; never execute real firewall commands."""
import importlib.util
import io
import ipaddress
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import unittest

from test_firewall_lib import ROOT, FIXTURES, INSTALL_SH, FIREWALL_LIB, run_firewall_lib, run_tool


class CountryAccessTests(unittest.TestCase):
    def test_country_union_case_normalization_and_port_selection(self):
        result = run_firewall_lib("cn_normalize_countries 'cn,jp,JP,us'; cn_collect_cidrs CN JP; cn_collect_selector_cidrs 'jp,US'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['CN JP US', '198.18.0.0/15', '203.0.113.0/24', '203.0.113.0/24', '192.0.2.0/24'])
        result = run_tool('collect-cidrs', 'JP')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '203.0.113.0/24')

    def test_country_gate_precedes_all_allow_exceptions_in_both_backends(self):
        for backend in ('nft', 'iptables'):
            with self.subTest(backend=backend):
                result = run_firewall_lib(
                    f"CN_FIREWALL_BACKEND={backend} CN_ALLOWED_COUNTRIES='CN JP' "
                    "CN_GLOBAL_IP_RULES='allow:192.0.2.1' CN_PORT_EXCEPTIONS='443=allow:AS64500' "
                    "cn_render_apply_commands '192.0.2.2' all '' AS64501 '22=US' CN JP")
                self.assertEqual(result.returncode, 0, result.stderr)
                out = result.stdout
                if backend == 'nft':
                    self.assertIn('set country_allowed_v4 {', out)
                    self.assertIn('ct status dnat ip saddr != @country_allowed_v4 reject', out)
                    self.assertLess(out.index('ip saddr != @country_allowed_v4 reject'), out.index('tcp dport 443 ip saddr'))
                    self.assertIn('meta nfproto ipv6 reject', out)
                    self.assertLess(out.index('ct state established,related accept'), out.index('ip saddr != @country_allowed_v4 reject'))
                else:
                    gate = '-m set ! --match-set cn_region_whitelist_country src -j REJECT'
                    self.assertIn(gate, out)
                    self.assertLess(out.index(gate), out.index('--ctorigdstport 443'))
                    self.assertIn('ip6tables -A CN_COUNTRY_V6 -j REJECT', out)
                    self.assertIn('ip6tables -I FORWARD 1 -m conntrack --ctstate DNAT -j CN_COUNTRY_V6', out)
                # Shell parsing of generated commands (without running them).
                parsed = subprocess.run(['bash', '-n'], input=out, text=True, capture_output=True)
                self.assertEqual(parsed.returncode, 0, parsed.stderr)

    def test_selected_interfaces_and_none_scope(self):
        for backend in ('nft', 'iptables'):
            selected = run_firewall_lib(f"CN_FIREWALL_BACKEND={backend} CN_ALLOWED_COUNTRIES=CN cn_render_apply_commands '' selected 'tun0 wg0' '' '' CN")
            self.assertEqual(selected.returncode, 0, selected.stderr)
            for iface in ('tun0', 'wg0'):
                if backend == 'nft':
                    for direction in ('iifname', 'oifname'):
                        self.assertIn(f'{direction} "{iface}" ct status dnat ip saddr != @country_allowed_v4 reject', selected.stdout)
                else:
                    for direction in ('-i', '-o'):
                        self.assertIn(f'{direction} {iface} -m conntrack --ctstate DNAT -j CN_COUNTRY_V6', selected.stdout)
            none = run_firewall_lib(f"CN_FIREWALL_BACKEND={backend} CN_ALLOWED_COUNTRIES=CN cn_render_apply_commands '' none '' '' '' CN")
            self.assertEqual(none.returncode, 0, none.stderr)
            self.assertNotIn('chain forward {', none.stdout)
            self.assertNotIn('ip6tables -I FORWARD', none.stdout)
            self.assertNotIn('iptables -I FORWARD', none.stdout)

    def test_invalid_country_rejected_before_any_firewall_output(self):
        for backend in ('nft', 'iptables'):
            for countries in ('ZZ', '../CN', 'CN ZZ', 'CN;echo unsafe'):
                result = run_firewall_lib(f"CN_FIREWALL_BACKEND={backend} CN_ALLOWED_COUNTRIES={shlex.quote(countries)} cn_render_apply_commands '' all '' '' '' CN")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(result.stdout, '')
        for selector in ('ZZ',):
            result = run_firewall_lib(f"cn_collect_allowed_cidrs '' {selector}")
            self.assertNotEqual(result.returncode, 0)

    def test_corrupt_or_missing_country_data_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / 'data'
            shutil.copytree(FIXTURES, data)
            for content in ('', '# no prefixes\n', '0.0.0.0/0\n', '999.1.1.0/24\n', '192.0.2.0/24\nnot-cidr\n', '2001:db8::/32\n'):
                (data / 'country/JP.txt').write_text(content)
                result = run_firewall_lib(f"DATA_DIR={shlex.quote(str(data))}; CN_ALLOWED_COUNTRIES=JP cn_render_apply_commands '' all '' '' '' CN")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
            (data / 'country/JP.txt').unlink()
            result = run_firewall_lib(f"cn_validate_prebuilt_data_dir {shlex.quote(str(data))}")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('JP', result.stderr)

    def test_saved_country_policy_restores_and_legacy_config_disables_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / 'config'
            result = run_firewall_lib(
                f"CN_CONFIG_FILE={shlex.quote(str(config))}; cn_require_root() {{ :; }}; "
                "CN_FIREWALL_BACKEND=nft; CN_ALLOWED_COUNTRIES='CN JP'; "
                "cn_save_config all '' '' '' CN JP; CN_ALLOWED_COUNTRIES='US'; "
                "cn_source_config; printf '%s\\n' \"${CN_ALLOWED_COUNTRIES}\"; cn_load_config_codes")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ['CN JP', 'CN', 'JP'])
            config.write_text('CN_CODES="CN"\n')
            result = run_firewall_lib(f"CN_CONFIG_FILE={shlex.quote(str(config))}; CN_ALLOWED_COUNTRIES=US; cn_source_config; printf '<%s>' \"${{CN_ALLOWED_COUNTRIES}}\"")
            self.assertEqual(result.stdout, '<>')

    def test_restore_uses_saved_gate_without_network_or_firewall(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / 'config'
            config.write_text('CN_CODES="CN JP"\nCN_ALLOWED_COUNTRIES="CN JP"\nCN_FIREWALL_BACKEND=nft\n')
            script = f'''source {shlex.quote(str(INSTALL_SH))}
CN_CONFIG_FILE={shlex.quote(str(config))}
cn_set_data_dir {shlex.quote(str(FIXTURES.parent))}
DATA_DIR={shlex.quote(str(FIXTURES))}
CN_COUNTRY_FILE={shlex.quote(str(FIXTURES / 'country/CN.txt'))}
cn_require_root() {{ :; }}
cn_require_commands() {{ :; }}
prepare_data_for_mode() {{ :; }}
cn_run_rendered_commands() {{ cat; }}
restore_rules offline
'''
            result = subprocess.run(['bash', '-c', script], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('ip saddr != @country_allowed_v4 reject', result.stdout)
            self.assertIn('203.0.113.0/24', result.stdout)

    def test_cli_presets_and_invalid_empty_list(self):
        env = {**os.environ, 'CN_FIREWALL_BACKEND': 'nft', 'CN_BOOTSTRAP_DATA_READY': '1', 'SSH_CONNECTION': '', 'SSH_CLIENT': ''}
        for option, expected in [('--block-foreign', '国家限制：CN'), ('--allow-countries=cn,jp', '国家限制：CN JP')]:
            result = subprocess.run(['bash', str(INSTALL_SH), 'dry-run', '--offline', option], env=env, text=True, input='', capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, result.stdout)
            self.assertIn('country_allowed_v4', result.stdout)
        result = subprocess.run(['bash', str(INSTALL_SH), 'dry-run', '--offline', '--allow-countries='], env=env, text=True, input='', capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('nft -f', result.stdout)

    def test_clear_removes_ipv6_guard_and_country_set(self):
        result = run_firewall_lib('cn_render_best_effort_clear_commands')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ip6tables -X CN_COUNTRY_V6', result.stdout)
        self.assertIn('(country|port_', result.stdout)
        result = run_firewall_lib("CN_FIREWALL_BACKEND=iptables cn_render_apply_commands '' all '' '' '' CN")
        self.assertNotIn('ip6tables -I INPUT', result.stdout)
        self.assertIn('ip6tables -X CN_COUNTRY_V6', result.stdout)
        self.assertNotIn('! --match-set', result.stdout)

    def test_real_bundles_and_wave_sample(self):
        rows = [s.split('\t')[0] for s in (ROOT / 'data/countries.tsv').read_text().splitlines() if s and not s.startswith('#')]
        self.assertGreaterEqual(len(rows), 200)
        for code in rows:
            nets = (ROOT / 'data/country' / f'{code}.txt').read_text().splitlines()
            self.assertTrue(nets, code)
            for value in nets:
                self.assertIsInstance(ipaddress.ip_network(value), ipaddress.IPv4Network)
        for asn in (45090, 132203, 137718, 11404, 6939):
            text = (ROOT / 'data/asn' / f'AS{asn}.txt').read_text()
            nets = [ipaddress.ip_network(s) for s in text.splitlines() if s and not s.startswith('#')]
            self.assertTrue(nets)
            if asn == 11404:
                self.assertTrue(any(ipaddress.ip_address('208.76.154.155') in n for n in nets))

    def test_archive_rejects_bad_data_and_ignores_non_country_members(self):
        spec = importlib.util.spec_from_file_location('countries', ROOT / 'tools/prepare_country_data.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        def archive(content):
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode='w:gz') as tar:
                for name, value in [('jp.zone', content), ('README', b'not a prefix')]:
                    entry = tarfile.TarInfo(name)
                    entry.size = len(value)
                    tar.addfile(entry, io.BytesIO(value))
            return buffer.getvalue()
        self.assertEqual(list(module.parse_archive(archive(b'203.0.113.0/24\n'))), ['JP'])
        for value in (b'0.0.0.0/0', b'invalid', b'2001:db8::/32'):
            with self.assertRaises(ValueError):
                module.parse_archive(archive(value))
