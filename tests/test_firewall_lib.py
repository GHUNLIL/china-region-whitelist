import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures"
TOOL = ROOT / "tools" / "region_tool.py"
INSTALL_SH = ROOT / "install.sh"
FIREWALL_LIB = ROOT / "tools" / "firewall_lib.sh"
BOOTSTRAP_SH = ROOT / "bootstrap.sh"


def run_tool(*args: str) -> subprocess.CompletedProcess[str]:
    command = [
        sys.executable,
        str(TOOL),
        "--regions-json",
        str(FIXTURES / "regions.json"),
        "--data-dir",
        str(FIXTURES),
        *args,
    ]
    return subprocess.run(command, text=True, capture_output=True, check=False)


def run_firewall_lib(command: str) -> subprocess.CompletedProcess[str]:
    script = (
        f"source {FIREWALL_LIB}; "
        f"DATA_DIR={FIXTURES}; "
        f"CN_REGIONS_TSV={FIXTURES / 'regions.tsv'}; "
        f"{command}"
    )
    return subprocess.run(["bash", "-c", script], text=True, capture_output=True, check=False)


class FirewallLibTests(unittest.TestCase):
    def test_lists_provinces_with_indices(self):
        result = run_tool("list-provinces")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1\t990000\t测试省", result.stdout)
        self.assertIn("2\t980000\t直辖市", result.stdout)

    def test_lists_cities_for_province(self):
        result = run_tool("list-cities", "990000")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1\t990100\t甲市", result.stdout)
        self.assertIn("2\t990200\t乙市", result.stdout)

    def test_collects_unique_cidrs_for_multiple_region_codes(self):
        result = run_tool("collect-cidrs", "990100", "990200")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            ["10.0.0.0/8", "198.51.100.0/24", "203.0.113.0/24"],
        )

    def test_renders_dry_run_commands_with_current_client_ip(self):
        result = run_tool("render-apply", "--client-ip", "198.51.100.88", "990100")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ipset create cn_region_whitelist hash:net family inet -exist", result.stdout)
        self.assertIn("ipset add cn_region_whitelist 10.0.0.0/8 -exist", result.stdout)
        self.assertIn("ipset add cn_region_whitelist 198.51.100.88 -exist", result.stdout)
        self.assertIn("iptables -A CN_REGION_WHITELIST -m set --match-set cn_region_whitelist src -j ACCEPT", result.stdout)
        self.assertIn("iptables -A CN_REGION_WHITELIST -j REJECT", result.stdout)

    def test_renders_forward_chain_jump_for_forwarded_ports(self):
        result = run_tool("render-apply", "990100")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "iptables -C FORWARD -j CN_REGION_WHITELIST 2>/dev/null || "
            "iptables -I FORWARD 1 -j CN_REGION_WHITELIST",
            result.stdout,
        )

    def test_renders_selected_tun_forward_interface_jumps(self):
        result = run_tool("render-apply", "--forward-iface", "tun0", "990100")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "iptables -C FORWARD -i tun0 -j CN_REGION_WHITELIST 2>/dev/null || "
            "iptables -I FORWARD 1 -i tun0 -j CN_REGION_WHITELIST",
            result.stdout,
        )
        self.assertIn(
            "iptables -C FORWARD -o tun0 -j CN_REGION_WHITELIST 2>/dev/null || "
            "iptables -I FORWARD 1 -o tun0 -j CN_REGION_WHITELIST",
            result.stdout,
        )
        self.assertNotIn("iptables -C FORWARD -j CN_REGION_WHITELIST", result.stdout)

    def test_render_apply_can_disable_forward_management(self):
        result = run_tool("render-apply", "--no-forward", "990100")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "iptables -C INPUT -j CN_REGION_WHITELIST 2>/dev/null || "
            "iptables -I INPUT 1 -j CN_REGION_WHITELIST",
            result.stdout,
        )
        self.assertNotIn("iptables -C FORWARD", result.stdout)
        self.assertNotIn("iptables -I FORWARD", result.stdout)

    def test_clear_removes_forward_chain_jump(self):
        result = run_tool("render-clear")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "iptables -S FORWARD | awk",
            result.stdout,
        )
        self.assertIn("-j CN_REGION_WHITELIST", result.stdout)

    def test_show_provinces_renders_cli_table(self):
        result = run_tool("show-provinces")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("可选省份", result.stdout)
        self.assertIn("测试省", result.stdout)
        self.assertIn("直辖市", result.stdout)
        self.assertNotIn("990000", result.stdout)

    def test_show_cities_accepts_province_index(self):
        result = run_tool("show-cities", "测试省")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("测试省", result.stdout)
        self.assertIn("全省", result.stdout)
        self.assertIn("甲市", result.stdout)
        self.assertIn("乙市", result.stdout)
        self.assertNotIn("990100", result.stdout)

    def test_firewall_lib_lists_regions_without_python_runtime(self):
        provinces = run_firewall_lib("cn_show_provinces")
        cities = run_firewall_lib("cn_show_cities 测试省")

        self.assertEqual(provinces.returncode, 0, provinces.stderr)
        self.assertIn("1.测试省", provinces.stdout)
        self.assertIn("2.直辖市", provinces.stdout)
        self.assertEqual(cities.returncode, 0, cities.stderr)
        self.assertIn("测试省 可选城市", cities.stdout)
        self.assertIn("0.全省", cities.stdout)
        self.assertIn("1.甲市", cities.stdout)
        self.assertIn("2.乙市", cities.stdout)

    def test_firewall_lib_renders_rules_without_python_runtime(self):
        result = run_firewall_lib(
            "cn_render_apply_commands 198.51.100.88 selected tun0 990100"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ipset create cn_region_whitelist hash:net family inet -exist", result.stdout)
        self.assertIn("ipset add cn_region_whitelist 10.0.0.0/8 -exist", result.stdout)
        self.assertIn("ipset add cn_region_whitelist 198.51.100.88 -exist", result.stdout)
        self.assertIn("iptables -C FORWARD -i tun0 -j CN_REGION_WHITELIST", result.stdout)
        self.assertIn("iptables -C FORWARD -o tun0 -j CN_REGION_WHITELIST", result.stdout)

    def test_firewall_lib_rejects_unknown_region_code(self):
        result = run_firewall_lib("cn_render_apply_commands '' all '' 123456")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("未知地区代码", result.stderr)

    def test_resolves_province_and_city_names_to_codes(self):
        province = run_tool("resolve-province", "测试省")
        city = run_tool("resolve-city", "测试省", "甲市")

        self.assertEqual(province.returncode, 0, province.stderr)
        self.assertEqual(city.returncode, 0, city.stderr)
        self.assertEqual(province.stdout.strip(), "990000")
        self.assertEqual(city.stdout.strip(), "990100")

    def test_install_script_does_not_capture_interactive_function_with_mapfile(self):
        script = INSTALL_SH.read_text(encoding="utf-8")

        self.assertNotIn("mapfile -t selected_codes < <(interactive_select_codes)", script)
        self.assertIn("read_from_tty", script)
        self.assertIn("selected_codes=(\"${SELECTED_CODES[@]}\")", script)

    def test_firewall_lib_auto_installs_missing_iptables_and_ipset(self):
        script = FIREWALL_LIB.read_text(encoding="utf-8")

        self.assertIn("cn_install_dependencies()", script)
        self.assertIn("apt-get update", script)
        self.assertIn("apt-get install -y iptables ipset", script)
        self.assertIn("dnf install -y iptables ipset", script)
        self.assertIn("yum install -y iptables ipset", script)
        self.assertIn("apk add --no-cache iptables ipset", script)
        self.assertIn("zypper --non-interactive install iptables ipset", script)
        self.assertIn("cn_install_dependencies", script)

    def test_firewall_lib_runtime_does_not_auto_install_python3(self):
        script = FIREWALL_LIB.read_text(encoding="utf-8")

        self.assertNotIn("cn_install_python()", script)
        self.assertNotIn("apt-get install -y python3", script)
        self.assertIn("CN_REGIONS_TSV", script)
        self.assertIn("cn_python_for_update", script)
        self.assertIn("默认运行不需要 Python", script)

    def test_install_script_supports_update_and_restore_modes(self):
        script = INSTALL_SH.read_text(encoding="utf-8")

        self.assertIn("update-data", script)
        self.assertIn("restore", script)
        self.assertIn("--update-optional", script)
        self.assertIn("parse_update_mode offline \"$@\"", script)
        self.assertIn("cn_save_config", script)
        self.assertIn("cn_install_systemd_service", script)
        self.assertIn("interactive_select_forward_interfaces", script)
        self.assertIn("已自动选择全市/全省", script)

    def test_firewall_lib_configures_systemd_persistence(self):
        script = FIREWALL_LIB.read_text(encoding="utf-8")

        self.assertIn("CN_CONFIG_FILE", script)
        self.assertIn("CN_RUNTIME_DIR", script)
        self.assertIn("china-region-whitelist.service", script)
        self.assertIn("systemctl enable", script)
        self.assertIn("restore --offline", script)
        self.assertIn("--output-dir", script)
        self.assertIn("CN_FORWARD_MODE", script)
        self.assertIn("CN_FORWARD_IFACES", script)

    def test_default_downloads_use_github_proxy(self):
        firewall_lib = FIREWALL_LIB.read_text(encoding="utf-8")
        bootstrap = BOOTSTRAP_SH.read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn("CN_GITHUB_PROXY=\"${CN_GITHUB_PROXY:-https://gh-proxy.com/}\"", firewall_lib)
        self.assertIn("cn_github_proxy_url", firewall_lib)
        self.assertIn("CN_GITHUB_PROXY:-https://gh-proxy.com/", bootstrap)
        self.assertIn("https://gh-proxy.com/https://raw.githubusercontent.com", readme)
        self.assertIn("bash <(curl -fsSL", readme)

    def test_bootstrap_cleanup_trap_is_set_u_safe(self):
        bootstrap = BOOTSTRAP_SH.read_text(encoding="utf-8")

        self.assertIn('BOOTSTRAP_WORK_DIR=""', bootstrap)
        self.assertIn('BOOTSTRAP_WORK_DIR="$(mktemp -d)"', bootstrap)
        self.assertIn('${BOOTSTRAP_WORK_DIR:-}', bootstrap)
        self.assertNotIn('trap \'rm -rf "${work_dir}"\' EXIT', bootstrap)

    def test_firewall_lib_detects_and_persists_tunnel_interfaces(self):
        script = FIREWALL_LIB.read_text(encoding="utf-8")

        self.assertIn("cn_list_tunnel_interfaces()", script)
        self.assertIn("tun*|tap*|wg*|tailscale*", script)
        self.assertIn("--forward-iface", script)
        self.assertIn("--no-forward", script)

    def test_prepare_data_can_refresh_and_force_downloads(self):
        script = (ROOT / "tools" / "prepare_data.py").read_text(encoding="utf-8")

        self.assertIn("--refresh-index", script)
        self.assertIn("--force", script)
        self.assertIn("DEFAULT_INDEX_URL", script)
        self.assertIn("DEFAULT_DATA_BASE_URL", script)
        self.assertIn("write_regions_tsv", script)


if __name__ == "__main__":
    unittest.main()
