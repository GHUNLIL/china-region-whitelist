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
        f"CN_COUNTRY_FILE={FIXTURES / 'country' / 'CN.txt'}; "
        f"CN_ASN_CACHE_DIR={FIXTURES / 'asn'}; "
        f"{command}"
    )
    return subprocess.run(["bash", "-c", script], text=True, capture_output=True, check=False)


class FirewallLibTests(unittest.TestCase):
    def test_lists_provinces_with_indices(self):
        result = run_tool("list-provinces")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1\t990000\t测试省", result.stdout)
        self.assertIn("2\t980000\t直辖市", result.stdout)

    def test_collects_unique_cidrs_for_multiple_region_codes(self):
        result = run_tool("collect-cidrs", "990000", "980000")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            ["10.0.0.0/8", "192.0.2.0/24", "172.16.0.0/12"],
        )

    def test_collects_country_cn_cidrs(self):
        result = run_tool("collect-cidrs", "CN")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["198.18.0.0/15"])

    def test_renders_dry_run_commands_with_current_client_ip(self):
        result = run_tool("render-apply", "--client-ip", "198.51.100.88", "990000")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ipset create cn_region_whitelist hash:net family inet -exist", result.stdout)
        self.assertIn("ipset add cn_region_whitelist 10.0.0.0/8 -exist", result.stdout)
        self.assertIn("ipset add cn_region_whitelist 198.51.100.88 -exist", result.stdout)
        self.assertIn("iptables -A CN_REGION_WHITELIST -m set --match-set cn_region_whitelist src -j ACCEPT", result.stdout)
        self.assertIn("iptables -A CN_REGION_WHITELIST -j REJECT", result.stdout)

    def test_renders_forward_chain_jump_for_forwarded_ports(self):
        result = run_tool("render-apply", "990000")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "iptables -C FORWARD -j CN_REGION_WHITELIST 2>/dev/null || "
            "iptables -I FORWARD 1 -j CN_REGION_WHITELIST",
            result.stdout,
        )

    def test_renders_selected_tun_forward_interface_jumps(self):
        result = run_tool("render-apply", "--forward-iface", "tun0", "990000")

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
        result = run_tool("render-apply", "--no-forward", "990000")

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

    def test_firewall_lib_lists_regions_without_python_runtime(self):
        provinces = run_firewall_lib("cn_show_provinces")

        self.assertEqual(provinces.returncode, 0, provinces.stderr)
        self.assertIn("1.测试省", provinces.stdout)
        self.assertIn("2.直辖市", provinces.stdout)

    def test_firewall_lib_renders_rules_without_python_runtime(self):
        result = run_firewall_lib(
            "CN_FIREWALL_BACKEND=iptables cn_render_apply_commands 198.51.100.88 selected tun0 '' '' 990000"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ipset create cn_region_whitelist hash:net family inet -exist", result.stdout)
        self.assertIn("ipset add cn_region_whitelist 10.0.0.0/8 -exist", result.stdout)
        self.assertIn("ipset add cn_region_whitelist 198.51.100.88 -exist", result.stdout)
        self.assertIn("iptables -C FORWARD -i tun0 -j CN_REGION_WHITELIST", result.stdout)
        self.assertIn("iptables -C FORWARD -o tun0 -j CN_REGION_WHITELIST", result.stdout)

    def test_firewall_lib_rejects_unknown_region_code(self):
        result = run_firewall_lib("cn_render_apply_commands '' all '' '' '' 123456")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("未知省份代码", result.stderr)

    def test_firewall_lib_rejects_non_province_code_at_runtime(self):
        result = run_firewall_lib("cn_render_apply_commands '' all '' '' '' 990100")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("未知省份代码", result.stderr)

    def test_resolves_province_names_to_codes(self):
        province = run_tool("resolve-province", "测试省")

        self.assertEqual(province.returncode, 0, province.stderr)
        self.assertEqual(province.stdout.strip(), "990000")

    def test_install_script_does_not_capture_interactive_function_with_mapfile(self):
        script = INSTALL_SH.read_text(encoding="utf-8")

        self.assertNotIn("mapfile -t selected_codes < <(interactive_select_codes)", script)
        self.assertIn("read_from_tty", script)
        self.assertIn("selected_codes=(\"${SELECTED_CODES[@]}\")", script)

    def test_firewall_lib_auto_installs_missing_iptables_and_ipset(self):
        script = FIREWALL_LIB.read_text(encoding="utf-8")

        self.assertIn("cn_install_dependencies()", script)
        self.assertIn("nftables", script)
        self.assertIn("apt-get update", script)
        self.assertIn("apt-get install -y ${packages}", script)
        self.assertIn("dnf install -y ${packages}", script)
        self.assertIn("yum install -y ${packages}", script)
        self.assertIn("apk add --no-cache ${packages}", script)
        self.assertIn("zypper --non-interactive install ${packages}", script)
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
        self.assertIn("interactive_select_asns", script)
        self.assertIn("interactive_select_port_policies", script)
        self.assertIn("visual_multi_select", script)
        self.assertIn("visual_single_select", script)
        self.assertIn("interactive_config_editor", script)
        self.assertIn("白名单配置主界面", script)
        self.assertIn("新增端口白名单", script)
        self.assertIn("修改端口白名单", script)
        self.assertIn("删除端口白名单", script)
        self.assertIn("端口白名单优先于全局白名单生效", script)
        self.assertIn("上/下键移动，空格勾选，回车确认", script)
        self.assertIn("清理已应用规则和开机配置", script)
        self.assertIn("confirm_clear_rules_visual", script)
        self.assertIn("update-asn", script)
        self.assertNotIn("请选择 TUN/转发接口托管方式", script)
        self.assertNotIn("cn_resolve_city", script)

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
        self.assertIn("CN_ASNS", script)
        self.assertIn("CN_PORT_POLICIES", script)
        self.assertIn("CN_FIREWALL_BACKEND", script)
        self.assertIn("cn_render_best_effort_clear_commands", script)
        self.assertIn("systemctl stop", script)
        self.assertIn("^%s_port_[0-9]+$", script)

    def test_firewall_lib_renders_nft_rules_without_touching_flvx_table(self):
        result = run_firewall_lib(
            "CN_FIREWALL_BACKEND=nft cn_render_apply_commands 198.51.100.88 all '' AS64500 '' 990000"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nft delete table inet china_region_whitelist", result.stdout)
        self.assertIn("nft -f - <<'NFT'", result.stdout)
        self.assertIn("table inet china_region_whitelist {", result.stdout)
        self.assertIn("set allowed_v4 {", result.stdout)
        self.assertIn("10.0.0.0/8", result.stdout)
        self.assertIn("203.0.113.0/24", result.stdout)
        self.assertIn("198.51.100.88", result.stdout)
        self.assertIn("chain forward {", result.stdout)
        self.assertIn("ip saddr @allowed_v4 accept", result.stdout)
        self.assertIn("meta nfproto ipv4 reject", result.stdout)
        self.assertNotIn("nft add element inet china_region_whitelist allowed_v4", result.stdout)
        self.assertNotIn("table inet flvx", result.stdout)

    def test_firewall_lib_renders_nft_input_only_mode(self):
        result = run_firewall_lib(
            "CN_FIREWALL_BACKEND=nft cn_render_apply_commands '' none '' '' '' 990000"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("chain input {", result.stdout)
        self.assertNotIn("chain forward {", result.stdout)

    def test_firewall_lib_uses_country_cn_for_global_china(self):
        result = run_firewall_lib(
            "CN_FIREWALL_BACKEND=nft cn_render_apply_commands '' all '' '' '' CN"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("198.18.0.0/15", result.stdout)
        self.assertNotIn("10.0.0.0/8", result.stdout)
        self.assertNotIn("172.16.0.0/12", result.stdout)

    def test_firewall_lib_uses_country_cn_for_port_policy_china(self):
        result = run_firewall_lib(
            "CN_FIREWALL_BACKEND=nft cn_render_apply_commands '' all '' '' '22=全国' 990000"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("set allowed_v4 {", result.stdout)
        self.assertIn("10.0.0.0/8", result.stdout)
        self.assertIn("set port_policy_1_v4 {", result.stdout)
        self.assertIn("198.18.0.0/15", result.stdout)

    def test_firewall_lib_renders_nft_port_policy_before_global_rules(self):
        result = run_firewall_lib(
            "CN_FIREWALL_BACKEND=nft cn_render_apply_commands '' all '' AS64500 '22=测试省;10000-20000=AS64500,198.51.100.7/32' 990000"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("set port_policy_1_ports {", result.stdout)
        self.assertIn("elements = { 22 }", result.stdout)
        self.assertIn("set port_policy_1_v4 {", result.stdout)
        self.assertIn("10.0.0.0/8", result.stdout)
        self.assertIn("set port_policy_2_ports {", result.stdout)
        self.assertIn("elements = { 10000-20000 }", result.stdout)
        self.assertIn("set port_policy_2_v4 {", result.stdout)
        self.assertIn("203.0.113.0/24", result.stdout)
        self.assertIn("198.51.100.7/32", result.stdout)
        self.assertIn("tcp dport @port_policy_1_ports ip saddr @port_policy_1_v4 accept", result.stdout)
        self.assertIn("tcp dport @port_policy_1_ports meta nfproto ipv4 reject", result.stdout)
        self.assertIn("ct original proto-dst @port_policy_2_ports ip saddr @port_policy_2_v4 accept", result.stdout)
        policy_reject = result.stdout.index("tcp dport @port_policy_1_ports meta nfproto ipv4 reject")
        global_accept = result.stdout.index("ip saddr @allowed_v4 accept")
        self.assertLess(policy_reject, global_accept)

    def test_firewall_lib_skips_client_ip_when_nft_set_already_covers_it(self):
        result = run_firewall_lib(
            "CN_FIREWALL_BACKEND=nft cn_render_apply_commands 203.0.113.7 all '' AS64500 '' 990000"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("客户端 IPv4 已被现有 nft 白名单覆盖，跳过重复加入：203.0.113.7", result.stderr)
        self.assertEqual(result.stdout.count("203.0.113.7"), 0)

    def test_firewall_lib_removes_overlapping_nft_port_policy_cidrs(self):
        result = run_firewall_lib(
            "CN_FIREWALL_BACKEND=nft cn_render_apply_commands '' all '' '' '22=AS64500,203.0.113.7/32' 990000"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("set port_policy_1_v4 {", result.stdout)
        self.assertIn("203.0.113.0/24", result.stdout)
        self.assertNotIn("203.0.113.7/32", result.stdout)

    def test_default_downloads_use_github_proxy(self):
        firewall_lib = FIREWALL_LIB.read_text(encoding="utf-8")
        bootstrap = BOOTSTRAP_SH.read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn("CN_GITHUB_PROXY=\"${CN_GITHUB_PROXY:-https://gh-proxy.com/}\"", firewall_lib)
        self.assertIn("cn_github_proxy_url", firewall_lib)
        self.assertIn("CN_ASN_BASE_URL", firewall_lib)
        self.assertIn("cn_proxy_url_if_github", firewall_lib)
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
        self.assertIn("CN_FORWARD_IFACES", script)
        self.assertIn("cn_validate_forward_selection", script)

    def test_prepare_data_can_refresh_and_force_downloads(self):
        script = (ROOT / "tools" / "prepare_data.py").read_text(encoding="utf-8")

        self.assertIn("--refresh-index", script)
        self.assertIn("--force", script)
        self.assertIn("DEFAULT_INDEX_URL", script)
        self.assertIn("DEFAULT_DATA_BASE_URL", script)
        self.assertIn("write_regions_tsv", script)
        self.assertIn("COUNTRY_FILE", script)
        self.assertIn("write_country_file", script)


if __name__ == "__main__":
    unittest.main()
