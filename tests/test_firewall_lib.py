import subprocess
import sys
import unittest
import importlib.util
import ipaddress
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures"
TOOL = ROOT / "tools" / "region_tool.py"
INSTALL_SH = ROOT / "install.sh"
FIREWALL_LIB = ROOT / "tools" / "firewall_lib.sh"
UI_LIB = ROOT / "tools" / "ui_lib.sh"
BOOTSTRAP_SH = ROOT / "bootstrap.sh"


def load_prepare_data_module():
    spec = importlib.util.spec_from_file_location("prepare_data", ROOT / "tools" / "prepare_data.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


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
        f"CN_BUNDLED_ASN_DIR={FIXTURES / 'asn'}; "
        f"CN_ASN_PRESETS_FILE={FIXTURES / 'asn' / 'presets.tsv'}; "
        f"CN_ASN_CACHE_DIR={FIXTURES / 'asn'}; "
        f"CN_HOME_BROADBAND_FILE={FIXTURES / 'carriers' / 'home-broadband.txt'}; "
        f"CN_HOME_BROADBAND_ASNS_FILE={FIXTURES / 'carriers' / 'home-broadband-asns.tsv'}; "
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
            "iptables -C FORWARD -m conntrack --ctstate DNAT -j CN_REGION_WHITELIST 2>/dev/null || "
            "iptables -I FORWARD 1 -m conntrack --ctstate DNAT -j CN_REGION_WHITELIST",
            result.stdout,
        )

    def test_renders_selected_tun_forward_interface_jumps(self):
        result = run_tool("render-apply", "--forward-iface", "tun0", "990000")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "iptables -C FORWARD -i tun0 -m conntrack --ctstate DNAT -j CN_REGION_WHITELIST 2>/dev/null || "
            "iptables -I FORWARD 1 -i tun0 -m conntrack --ctstate DNAT -j CN_REGION_WHITELIST",
            result.stdout,
        )
        self.assertIn(
            "iptables -C FORWARD -o tun0 -m conntrack --ctstate DNAT -j CN_REGION_WHITELIST 2>/dev/null || "
            "iptables -I FORWARD 1 -o tun0 -m conntrack --ctstate DNAT -j CN_REGION_WHITELIST",
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
        self.assertIn("iptables -C FORWARD -i tun0 -m conntrack --ctstate DNAT -j CN_REGION_WHITELIST", result.stdout)
        self.assertIn("iptables -C FORWARD -o tun0 -m conntrack --ctstate DNAT -j CN_REGION_WHITELIST", result.stdout)

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
        self.assertNotIn("cn_python_for_update", script)
        self.assertIn("CN_REGIONS_TSV", script)
        self.assertIn("cn_download_repo_archive", script)
        self.assertIn("cn_validate_prebuilt_data_dir", script)
        self.assertIn("GitHub 预制 IP 数据", script)

    def test_firewall_lib_prefers_bundled_asn_prefixes(self):
        result = run_firewall_lib("CN_ASN_OFFLINE=1 CN_ASN_CACHE_DIR=/tmp/missing-asn-cache cn_collect_asn_cidrs AS64500")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["203.0.113.0/24"])

    def test_install_script_supports_update_and_restore_modes(self):
        script = INSTALL_SH.read_text(encoding="utf-8")
        ui_script = UI_LIB.read_text(encoding="utf-8")

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
        self.assertIn('source "${ROOT}/tools/ui_lib.sh"', script)
        self.assertIn("interactive_config_editor", script)
        self.assertIn("load_saved_config_into_editor", script)
        self.assertIn("cn_load_config_codes", script)
        self.assertIn("cn_load_config_port_policies", script)
        self.assertIn("update_region_data_visual", script)
        self.assertIn("同步最新预制 IP 数据", script)
        self.assertIn("prepare_data_for_mode required", script)
        self.assertIn("cn_use_runtime_data_if_available", script)
        self.assertIn("白名单配置主界面", script)
        self.assertIn("confirm_post_apply_rules", script)
        self.assertIn("CN_POST_APPLY_TIMEOUT", script)
        self.assertIn("is_yes_confirmation", script)
        self.assertIn("YES/yes/y", script)
        self.assertIn("未确认新连接可访问，正在自动清理本次规则。", script)
        self.assertIn("新增端口白名单", script)
        self.assertIn("修改端口白名单", script)
        self.assertIn("删除端口白名单", script)
        self.assertIn("端口+单 IP > 端口+ASN > 端口白名单 > 全局单 IP > 全局白名单", script)
        self.assertIn("所有端口规则同时支持 TCP、UDP", script)
        self.assertIn("上/下键移动，空格勾选，回车保存", ui_script)
        self.assertIn("Esc/Q 取消", ui_script)
        self.assertIn("清理已应用规则和开机配置", script)
        self.assertIn("confirm_clear_rules_visual", script)
        self.assertIn("update-asn", script)
        self.assertNotIn("请选择 TUN/转发接口托管方式", script)
        self.assertNotIn("cn_resolve_city", script)

    def test_visual_editor_groups_options_and_preserves_saved_state(self):
        script = INSTALL_SH.read_text(encoding="utf-8")

        for expected in (
            "编辑默认白名单（全国/家宽/省份）",
            "编辑 ASN 白名单（常用预设/自定义）",
            "编辑入站托管范围",
            "管理端口白名单",
            "管理高级允许/屏蔽规则",
            "维护工具",
            "重新载入已保存配置",
        ):
            self.assertIn(expected, script)
        self.assertIn('interactive_select_codes "${CONFIG_CODES[@]}"', script)
        self.assertIn('interactive_select_asns "${CONFIG_ASNS[@]}"', script)
        self.assertIn('interactive_select_global_ip_rules "${CONFIG_GLOBAL_IP_RULES}"', script)
        self.assertIn('build_port_policy_visual "${CONFIG_PORT_POLICIES[$index]}"', script)

    def test_visual_helpers_restore_preselected_values_and_default_cursor(self):
        command = (
            f"source {UI_LIB}; "
            "visual_clear_screen() { :; }; visual_read_key() { printf ''; }; "
            "visual_multi_select 'test' 1 'b' 'A' 'a' 'B' 'b'; "
            "printf '%s|' \"${VISUAL_SELECTED_VALUES[*]}\"; "
            "VISUAL_DEFAULT_VALUE=b; visual_single_select 'test' 'A' 'a' 'B' 'b'; "
            "printf '%s\\n' \"${VISUAL_SELECTED_VALUE}\""
        )
        result = subprocess.run(
            ["bash", "-c", command],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "b|b")

    def test_visual_multi_select_cancel_does_not_return_partial_values(self):
        command = (
            f"source {UI_LIB}; "
            "visual_clear_screen() { :; }; visual_read_key() { printf q; }; "
            "visual_multi_select 'test' 1 'b' 'A' 'a' 'B' 'b'; "
            "printf '%s|%s\\n' \"${VISUAL_CANCELLED}\" \"${VISUAL_SELECTED_VALUES[*]}\""
        )
        result = subprocess.run(
            ["bash", "-c", command],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "1|")

    def test_install_script_offers_common_asn_presets_and_manual_input(self):
        script = INSTALL_SH.read_text(encoding="utf-8")
        presets = (ROOT / "data" / "asn" / "presets.tsv").read_text(encoding="utf-8")

        self.assertIn("load_common_asn_menu_options", script)
        self.assertIn("ASN 白名单（可多选；已配置项会自动勾选）", script)
        self.assertIn("手动输入其他 ASN", script)
        for expected in (
            "AS906\tDMIT\tDMIT Cloud Services",
            "AS16509\tAWS\tAmazon.com, Inc.",
            "AS3462\tHiNet\tChunghwa Telecom Co., Ltd.",
            "AS51847\tNearoute\tNearoute Limited",
            "AS2527\tSo-net\tSony Network Communications Inc.",
            "AS17676\tSoftBank\tSoftBank Corp.",
        ):
            self.assertIn(expected, presets)

    def test_common_asn_presets_have_valid_bundled_ipv4_prefixes(self):
        preset_file = ROOT / "data" / "asn" / "presets.tsv"
        preset_asns = []
        for line in preset_file.read_text(encoding="utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            preset_asns.append(line.split("\t", 1)[0])

        self.assertEqual(
            preset_asns,
            ["AS906", "AS16509", "AS3462", "AS51847", "AS2527", "AS17676"],
        )
        for asn in preset_asns:
            prefix_file = ROOT / "data" / "asn" / f"{asn}.txt"
            prefixes = [
                line
                for line in prefix_file.read_text(encoding="utf-8").splitlines()
                if line and not line.startswith("#")
            ]
            self.assertTrue(prefixes, f"{asn} has no bundled prefixes")
            for prefix in prefixes:
                self.assertIsInstance(ipaddress.ip_network(prefix), ipaddress.IPv4Network)

    def test_text_asn_selector_accepts_presets_and_manual_asns_without_duplicates(self):
        command = (
            f"source {INSTALL_SH}; "
            "CN_VISUAL_MENU=0; CN_READ_FROM_STDIN=1; "
            "interactive_select_asns; printf '%s\\n' \"${SELECTED_ASNS[*]}\""
        )
        result = subprocess.run(
            ["bash", "-c", command],
            input="1 3 AS14061 AS906\n",
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "AS906 AS3462 AS14061")

    def test_global_ip_editor_keeps_existing_rules_when_saved_without_changes(self):
        command = (
            f"source {INSTALL_SH}; "
            "CN_VISUAL_MENU=0; CN_READ_FROM_STDIN=1; "
            "interactive_select_global_ip_rules 'allow:198.51.100.8,deny:198.51.100.9'; "
            "printf '%s\\n' \"${SELECTED_GLOBAL_IP_RULES}\""
        )
        result = subprocess.run(
            ["bash", "-c", command],
            input="3\n",
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "allow:198.51.100.8,deny:198.51.100.9")

    def test_global_ip_editor_can_delete_one_existing_rule(self):
        command = (
            f"source {INSTALL_SH}; "
            "CN_VISUAL_MENU=0; CN_READ_FROM_STDIN=1; "
            "interactive_select_global_ip_rules 'allow:198.51.100.8,deny:198.51.100.9'; "
            "printf '%s\\n' \"${SELECTED_GLOBAL_IP_RULES}\""
        )
        result = subprocess.run(
            ["bash", "-c", command],
            input="5\n1\n3\n",
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "deny:198.51.100.9")

    def test_saved_editor_state_includes_forward_scope(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_file = Path(temp_dir) / "china-region-whitelist.conf"
            config_file.write_text(
                'CN_CODES="HOME"\n'
                'CN_ASNS="AS64500"\n'
                'CN_PORT_POLICIES="22=HOME"\n'
                'CN_GLOBAL_IP_RULES="allow:198.51.100.8"\n'
                'CN_PORT_EXCEPTIONS="443=deny:AS64501"\n'
                'CN_FORWARD_MODE="selected"\n'
                'CN_FORWARD_IFACES="tun0 wg0"\n',
                encoding="utf-8",
            )
            command = (
                f"source {INSTALL_SH}; CN_CONFIG_FILE={config_file}; "
                "load_saved_config_into_editor; "
                "printf '%s|%s|%s|%s\\n' \"${CONFIG_CODES[*]}\" \"${CONFIG_ASNS[*]}\" "
                '"${CONFIG_FORWARD_MODE}" "${CONFIG_FORWARD_IFACES[*]}"'
            )
            result = subprocess.run(
                ["bash", "-c", command],
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "HOME|AS64500|selected|tun0 wg0")

    def test_port_policy_editor_loads_existing_values(self):
        command = (
            f"source {INSTALL_SH}; "
            "load_port_policy_editor_state '22=全国,上海市,AS64500,198.51.100.0/24'; "
            "printf '%s|%s|%s\\n' \"${PORT_POLICY_PORT}\" "
            '"${PORT_POLICY_DOMESTIC_SELECTORS[*]}" "${PORT_POLICY_EXTRA_SELECTORS[*]}"'
        )
        result = subprocess.run(
            ["bash", "-c", command],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "22|全国 上海市|AS64500 198.51.100.0/24")

    def test_firewall_lib_configures_systemd_persistence(self):
        script = FIREWALL_LIB.read_text(encoding="utf-8")

        self.assertIn("CN_CONFIG_FILE", script)
        self.assertIn("CN_RUNTIME_DIR", script)
        self.assertIn("china-region-whitelist.service", script)
        self.assertIn("systemctl enable", script)
        self.assertIn("restore --offline", script)
        self.assertIn("CN_REPO_ARCHIVE_URL", script)
        self.assertIn("CN_RUNTIME_DIR}/data", script)
        self.assertIn("CN_FORWARD_MODE", script)
        self.assertIn("CN_FORWARD_IFACES", script)
        self.assertIn("CN_ASNS", script)
        self.assertIn("CN_PORT_POLICIES", script)
        self.assertIn("CN_GLOBAL_IP_RULES", script)
        self.assertIn("CN_PORT_EXCEPTIONS", script)
        self.assertIn("CN_FIREWALL_BACKEND", script)
        self.assertIn("cn_render_best_effort_clear_commands", script)
        self.assertIn("systemctl stop", script)
        self.assertIn("port_[0-9]+|g[ad]|e[0-9]+", script)

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
        self.assertIn("ct status dnat ip saddr @allowed_v4 accept", result.stdout)
        self.assertIn("ct status dnat meta nfproto ipv4 reject", result.stdout)
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
        self.assertIn("ct status dnat ct original proto-dst @port_policy_2_ports ip saddr @port_policy_2_v4 accept", result.stdout)
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

    def test_home_broadband_selector_uses_bundled_carrier_prefixes(self):
        result = run_firewall_lib(
            "CN_FIREWALL_BACKEND=nft cn_render_apply_commands '' all '' '' '' HOME"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("100.64.0.0/10", result.stdout)
        self.assertNotIn("10.0.0.0/8", result.stdout)

    def test_global_single_ip_allow_and_deny_apply_to_input_and_forward(self):
        result = run_firewall_lib(
            "CN_FIREWALL_BACKEND=nft "
            "CN_GLOBAL_IP_RULES='allow:198.51.100.8,deny:198.51.100.9' "
            "cn_render_apply_commands '' all '' '' '' 990000"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("set global_ip_deny_v4 {", result.stdout)
        self.assertIn("set global_ip_allow_v4 {", result.stdout)
        self.assertIn("ip saddr @global_ip_deny_v4 reject", result.stdout)
        self.assertIn("ip saddr @global_ip_allow_v4 accept", result.stdout)
        self.assertIn("ct status dnat ip saddr @global_ip_deny_v4 reject", result.stdout)
        self.assertIn("ct status dnat ip saddr @global_ip_allow_v4 accept", result.stdout)
        self.assertLess(
            result.stdout.index("ip saddr @global_ip_deny_v4 reject"),
            result.stdout.index("ip saddr @allowed_v4 accept"),
        )

    def test_global_ip_interaction_chooses_action_before_ip(self):
        script = (
            f"CN_READ_FROM_STDIN=1 CN_VISUAL_MENU=0 source {INSTALL_SH}; "
            "interactive_select_global_ip_rules; "
            "printf '%s\\n' \"${SELECTED_GLOBAL_IP_RULES}\""
        )
        result = subprocess.run(
            ["bash", "-c", script],
            input="1\n210.51.42.156\n2\n198.51.100.9\n3\n",
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.strip(),
            "allow:210.51.42.156,deny:198.51.100.9",
        )
        self.assertIn("请输入要允许的单个 IPv4", result.stderr)
        self.assertIn("请输入要屏蔽的单个 IPv4", result.stderr)

    def test_port_ip_and_asn_exceptions_are_highest_priority_for_tcp_udp_and_dnat(self):
        result = run_firewall_lib(
            "CN_FIREWALL_BACKEND=nft "
            "CN_PORT_EXCEPTIONS='22=allow:198.51.100.8,deny:198.51.100.9,allow:AS64500,deny:AS64501' "
            "cn_render_apply_commands '' all '' '' '22=测试省' 990000"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("tcp dport 22 ip saddr @port_exception_1_ip_deny_v4 reject", result.stdout)
        self.assertIn("udp dport 22 ip saddr @port_exception_1_ip_allow_v4 accept", result.stdout)
        self.assertIn("tcp dport 22 ip saddr @port_exception_1_asn_deny_v4 reject", result.stdout)
        self.assertIn("udp dport 22 ip saddr @port_exception_1_asn_allow_v4 accept", result.stdout)
        self.assertIn(
            "ct status dnat ct original proto-dst 22 ip saddr @port_exception_1_ip_deny_v4 reject",
            result.stdout,
        )
        self.assertLess(
            result.stdout.index("tcp dport 22 ip saddr @port_exception_1_ip_allow_v4 accept"),
            result.stdout.index("tcp dport 22 ip saddr @port_exception_1_asn_deny_v4 reject"),
        )
        self.assertLess(
            result.stdout.index("tcp dport 22 ip saddr @port_exception_1_asn_allow_v4 accept"),
            result.stdout.index("tcp dport @port_policy_1_ports ip saddr @port_policy_1_v4 accept"),
        )

    def test_iptables_port_exceptions_cover_tcp_udp_and_original_dnat_port(self):
        result = run_firewall_lib(
            "CN_FIREWALL_BACKEND=iptables "
            "CN_PORT_EXCEPTIONS='53=allow:198.51.100.8,deny:AS64501' "
            "cn_render_apply_commands '' all '' '' '' 990000"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-p tcp --dport 53 -m set --match-set cn_region_whitelist_e1ia src -j ACCEPT", result.stdout)
        self.assertIn("-p udp --dport 53 -m set --match-set cn_region_whitelist_e1ia src -j ACCEPT", result.stdout)
        self.assertIn(
            "-p udp -m conntrack --ctstate DNAT --ctorigdstport 53 "
            "-m set --match-set cn_region_whitelist_e1ad src -j REJECT",
            result.stdout,
        )

    def test_port_exception_conflicts_and_duplicate_ports_are_rejected(self):
        conflict = run_firewall_lib(
            "cn_validate_port_exceptions '22=allow:1.2.3.4,deny:1.2.3.4'"
        )
        duplicate = run_firewall_lib(
            "cn_validate_port_exceptions '22=allow:1.2.3.4;22=deny:AS64500'"
        )

        self.assertNotEqual(conflict.returncode, 0)
        self.assertIn("同时配置了允许和屏蔽", conflict.stderr)
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertIn("同一端口只能出现一条例外配置", duplicate.stderr)

    def test_global_ip_conflicts_and_cidrs_are_rejected(self):
        conflict = run_firewall_lib(
            "cn_validate_global_ip_rules 'allow:1.2.3.4,deny:1.2.3.4'"
        )
        cidr = run_firewall_lib(
            "cn_validate_global_ip_rules 'allow:1.2.3.0/24'"
        )

        self.assertNotEqual(conflict.returncode, 0)
        self.assertIn("同时配置了允许和屏蔽", conflict.stderr)
        self.assertNotEqual(cidr.returncode, 0)
        self.assertIn("只支持单个 IPv4 或 ASN", cidr.stderr)

    def test_selected_forward_mode_scopes_port_exceptions_to_selected_interface(self):
        result = run_firewall_lib(
            "CN_FIREWALL_BACKEND=nft "
            "CN_PORT_EXCEPTIONS='22=deny:198.51.100.9' "
            "cn_render_apply_commands '' selected tun0 '' '' 990000"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            'iifname "tun0" ct status dnat ct original proto-dst 22 '
            "ip saddr @port_exception_1_ip_deny_v4 reject",
            result.stdout,
        )
        self.assertIn(
            'oifname "tun0" ct status dnat ct original proto-dst 22 '
            "ip saddr @port_exception_1_ip_deny_v4 reject",
            result.stdout,
        )

    def test_real_home_broadband_bundle_is_valid_and_excludes_premium_asns(self):
        asn_list = (ROOT / "data" / "carriers" / "home-broadband-asns.tsv").read_text(encoding="utf-8")
        prefixes = [
            line.strip()
            for line in (ROOT / "data" / "carriers" / "home-broadband.txt").read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.startswith("#")
        ]

        self.assertIn("AS4134\ttelecom", asn_list)
        self.assertIn("AS4837\tunicom", asn_list)
        self.assertIn("AS9808\tmobile", asn_list)
        for excluded_asn in ("AS4809\t", "AS9929\t", "AS58453\t"):
            self.assertNotIn(excluded_asn, asn_list)
        self.assertGreater(len(prefixes), 1000)
        for prefix in prefixes:
            self.assertIsInstance(ipaddress.ip_network(prefix), ipaddress.IPv4Network)

    def test_new_ip_and_port_exception_rules_are_saved_and_loaded(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_file = Path(temp_dir) / "china-region-whitelist.conf"
            result = run_firewall_lib(
                "cn_require_root() { return 0; }; "
                f"CN_CONFIG_FILE={config_file}; "
                "CN_FIREWALL_BACKEND=nft; "
                "CN_GLOBAL_IP_RULES='allow:1.2.3.4,deny:5.6.7.8'; "
                "CN_PORT_EXCEPTIONS='22=allow:1.2.3.4,deny:AS64501'; "
                "cn_save_config all '' '' '' HOME; "
                "CN_GLOBAL_IP_RULES=''; CN_PORT_EXCEPTIONS=''; "
                "cn_source_config; "
                "printf '%s\n%s\n' \"${CN_GLOBAL_IP_RULES}\" \"${CN_PORT_EXCEPTIONS}\""
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "allow:1.2.3.4,deny:5.6.7.8",
                "22=allow:1.2.3.4,deny:AS64501",
            ],
        )

    def test_default_downloads_use_github_proxy(self):
        firewall_lib = FIREWALL_LIB.read_text(encoding="utf-8")
        bootstrap = BOOTSTRAP_SH.read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn("CN_GITHUB_PROXY=\"${CN_GITHUB_PROXY:-https://gh-proxy.com/}\"", firewall_lib)
        self.assertIn("cn_github_proxy_url", firewall_lib)
        self.assertIn("CN_REPO_ARCHIVE_URL", firewall_lib)
        self.assertIn("cn_download_repo_archive", firewall_lib)
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
        self.assertIn("DEFAULT_COUNTRY_URL", script)
        self.assertIn("parse_apnic_country_ipv4", script)
        self.assertIn("write_regions_tsv", script)
        self.assertIn("COUNTRY_FILE", script)
        self.assertIn("write_country_file", script)

    def test_prepare_data_parses_apnic_country_ipv4(self):
        prepare_data = load_prepare_data_module()
        cidrs = prepare_data.parse_apnic_country_ipv4(
            "\n".join(
                [
                    "apnic|CN|ipv4|123.184.0.0|524288|20200101|allocated",
                    "apnic|HK|ipv4|123.192.0.0|65536|20200101|allocated",
                    "apnic|CN|ipv6|2408:4000::|22|20200101|allocated",
                ]
            )
        )

        self.assertEqual(cidrs, ["123.184.0.0/13"])


if __name__ == "__main__":
    unittest.main()
