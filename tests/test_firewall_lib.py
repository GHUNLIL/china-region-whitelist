import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures"
TOOL = ROOT / "tools" / "region_tool.py"
INSTALL_SH = ROOT / "install.sh"
FIREWALL_LIB = ROOT / "tools" / "firewall_lib.sh"


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
        self.assertIn("ipset create po0_region_whitelist hash:net family inet -exist", result.stdout)
        self.assertIn("ipset add po0_region_whitelist 10.0.0.0/8 -exist", result.stdout)
        self.assertIn("ipset add po0_region_whitelist 198.51.100.88 -exist", result.stdout)
        self.assertIn("iptables -A PO0_REGION_WHITELIST -m set --match-set po0_region_whitelist src -j ACCEPT", result.stdout)
        self.assertIn("iptables -A PO0_REGION_WHITELIST -j REJECT", result.stdout)

    def test_renders_forward_chain_jump_for_forwarded_ports(self):
        result = run_tool("render-apply", "990100")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "iptables -C FORWARD -j PO0_REGION_WHITELIST 2>/dev/null || "
            "iptables -I FORWARD 1 -j PO0_REGION_WHITELIST",
            result.stdout,
        )

    def test_clear_removes_forward_chain_jump(self):
        result = run_tool("render-clear")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "while iptables -C FORWARD -j PO0_REGION_WHITELIST 2>/dev/null; "
            "do iptables -D FORWARD -j PO0_REGION_WHITELIST; done",
            result.stdout,
        )

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

        self.assertIn("po0_install_dependencies()", script)
        self.assertIn("apt-get update", script)
        self.assertIn("apt-get install -y iptables ipset", script)
        self.assertIn("dnf install -y iptables ipset", script)
        self.assertIn("yum install -y iptables ipset", script)
        self.assertIn("apk add --no-cache iptables ipset", script)
        self.assertIn("zypper --non-interactive install iptables ipset", script)
        self.assertIn("po0_install_dependencies", script)

    def test_install_script_supports_update_and_restore_modes(self):
        script = INSTALL_SH.read_text(encoding="utf-8")

        self.assertIn("update-data", script)
        self.assertIn("restore", script)
        self.assertIn("--update-optional", script)
        self.assertIn("po0_save_config", script)
        self.assertIn("po0_install_systemd_service", script)

    def test_firewall_lib_configures_systemd_persistence(self):
        script = FIREWALL_LIB.read_text(encoding="utf-8")

        self.assertIn("PO0_CONFIG_FILE", script)
        self.assertIn("PO0_RUNTIME_DIR", script)
        self.assertIn("po0-region-whitelist.service", script)
        self.assertIn("systemctl enable", script)
        self.assertIn("restore --update-optional", script)
        self.assertIn("--output-dir", script)

    def test_prepare_data_can_refresh_and_force_downloads(self):
        script = (ROOT / "tools" / "prepare_data.py").read_text(encoding="utf-8")

        self.assertIn("--refresh-index", script)
        self.assertIn("--force", script)
        self.assertIn("DEFAULT_INDEX_URL", script)
        self.assertIn("DEFAULT_DATA_BASE_URL", script)


if __name__ == "__main__":
    unittest.main()
