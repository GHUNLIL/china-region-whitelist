import importlib.util
import ipaddress
from pathlib import Path
import shlex
import shutil
import tempfile
import unittest
from test_firewall_lib import ROOT, FIXTURES, run_firewall_lib


class MainlandIPv6Tests(unittest.TestCase):
    def test_cn_allowed_before_reject_in_input_and_dnat(self):
        for backend in ('nft', 'iptables'):
            r = run_firewall_lib(f"CN_FIREWALL_BACKEND={backend} CN_ALLOWED_COUNTRIES=CN cn_render_apply_commands '' all '' '' '' CN")
            self.assertEqual(r.returncode, 0, r.stderr)
            if backend == 'nft':
                self.assertIn('type ipv6_addr', r.stdout)
                self.assertLess(r.stdout.index('ip6 saddr @country_allowed_v6 counter accept'), r.stdout.index('meta nfproto ipv6 reject'))
                self.assertIn('ct status dnat ip6 saddr @country_allowed_v6 counter accept', r.stdout)
            else:
                self.assertIn('hash:net family inet6', r.stdout)
                self.assertLess(r.stdout.index('--match-set cn_region_whitelist_country6 src -j ACCEPT'), r.stdout.index('ip6tables -A CN_COUNTRY_V6 -j REJECT'))

    def test_no_cn_does_not_enable_ipv6(self):
        r = run_firewall_lib("CN_FIREWALL_BACKEND=nft CN_ALLOWED_COUNTRIES=JP cn_render_apply_commands '' all '' '' '' CN")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn('country_allowed_v6', r.stdout)
        self.assertIn('meta nfproto ipv6 reject', r.stdout)

    def test_bad_ipv6_data_stops_before_firewall_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / 'data'
            shutil.copytree(FIXTURES, data)
            for value in ['', '::/0', '240e::/0', '240e::bad::/32', '240e:::1/32', '240e::zzzz/32', '240e:12345::/32', '240e:1/32', '240e::/129', '240e::/32\n1.1.1.0/24']:
                (data / 'country6/CN.txt').write_text(value)
                for backend in ('nft', 'iptables'):
                    r = run_firewall_lib(f"DATA_DIR={shlex.quote(str(data))}; CN_ALLOWED_COUNTRIES=CN CN_FIREWALL_BACKEND={backend} cn_render_apply_commands '' all '' '' '' CN")
                    self.assertNotEqual(r.returncode, 0, value)
                    self.assertEqual(r.stdout, '', value)

    def test_apnic_parser_filters_countries_and_rejects_default_route(self):
        spec = importlib.util.spec_from_file_location('ipv6', ROOT / 'tools/prepare_ipv6_data.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        sample = 'apnic|CN|ipv6|240e::|18|20200101|allocated\napnic|JP|ipv6|2400::|32|20200101|allocated\napnic|CN|ipv6|2408::|16|20200101|available\n'
        self.assertEqual(module.parse_delegations(sample), [ipaddress.ip_network('240e::/18')])
        with self.assertRaises(ValueError):
            module.parse_delegations('apnic|CN|ipv6|::|0|20200101|allocated')
