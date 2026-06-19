#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT}/tools/firewall_lib.sh"
exec 3<&0

usage() {
  cat <<'EOF'
中国大陆省份白名单一键脚本

用法：
  ./install.sh apply [--offline|--update|--update-optional]
                         交互选择整机白名单和端口优先白名单、应用防火墙并配置开机恢复
  ./install.sh dry-run [--offline|--update|--update-optional]
                         交互选择整机白名单和端口优先白名单，只打印将执行的命令
  ./install.sh restore [--offline|--update|--update-optional]
                         使用上次保存的省份配置重新应用规则
  ./install.sh update-data
                         只同步最新省级 CIDR 数据到 /var/lib/china-region-whitelist
  ./install.sh update-asn
                         重新同步已保存的 ASN 白名单并恢复规则
  ./install.sh status    查看当前托管规则和开机恢复状态
  ./install.sh clear     清除本脚本创建的规则、保存配置和 systemd 服务

说明：
  apply 会让未命中白名单的所有入站端口全部拒绝。
  默认整机托管本机 INPUT 和 FORWARD 转发流量，包含 flvx/nftables 转发端口。
  可为单端口或端口范围设置更高优先级的白名单。
  使用 flvx/nftables 转发时，建议保留默认 nft 后端；本脚本会使用独立 nft 表，不会改写 flvx 表。
  apply/dry-run 默认使用仓库内置数据，不需要 Python；如需实时同步上游数据，加 --update。
  建议先运行 dry-run，确认省份和命令后再 apply。
EOF
}

pick_by_indices() {
  local prompt="$1"
  local max="$2"
  local input
  while true; do
    read -r -p "${prompt}" input
    input="${input//,/ }"
    [[ -n "${input}" ]] || continue
    local ok=1
    for value in ${input}; do
      if ! [[ "${value}" =~ ^[0-9]+$ ]] || (( value < 1 || value > max )); then
        ok=0
      fi
    done
    if [[ "${ok}" -eq 1 ]]; then
      echo "${input}"
      return
    fi
    echo "输入无效，请输入 1-${max} 范围内的编号，可用空格或逗号分隔。"
  done
}

split_user_list() {
  local input="$1"
  input="${input//,/ }"
  input="${input//，/ }"
  input="${input//、/ }"
  printf '%s\n' "${input}" | tr '[:space:]' '\n'
}

read_from_tty() {
  local prompt="$1"
  local value
  if [[ -t 0 && -r /dev/tty ]]; then
    read -r -p "${prompt}" value < /dev/tty
  else
    printf '%s' "${prompt}" >&2
    read -r value <&3 || value=""
  fi
  printf '%s\n' "${value}"
}

code_at_index() {
  local rows="$1"
  local index="$2"
  awk -F '\t' -v wanted="${index}" '$1 == wanted {print $2}' <<<"${rows}"
}

interactive_select_codes() {
  SELECTED_CODES=()
  echo "请选择省/自治区/直辖市：" >&2
  cn_show_provinces >&2
  echo >&2
  echo "输入编号或省份名称，多个用空格/逗号分隔；输入 全国 表示中国大陆全部省级 IP。" >&2

  local province_input
  province_input="$(read_from_tty "省份: ")"
  [[ -n "${province_input}" ]] || {
    echo "未输入省份。" >&2
    exit 1
  }

  local province_selector province_code
  while IFS= read -r province_selector; do
    [[ -n "${province_selector}" ]] || continue
    if cn_is_all_china_selector "${province_selector}"; then
      while IFS= read -r province_code; do
        [[ -n "${province_code}" ]] && SELECTED_CODES+=("${province_code}")
      done < <(cn_all_province_codes)
    else
      province_code="$(cn_resolve_province "${province_selector}")"
      SELECTED_CODES+=("${province_code}")
    fi
  done < <(split_user_list "${province_input}")
}

interactive_select_asns() {
  SELECTED_ASNS=()
  echo >&2
  echo "可选：额外 ASN 白名单，用于国外管理机或固定云厂商入口。" >&2
  echo "例如：AS16509 AS14061。留空则不添加 ASN 白名单。" >&2

  local asn_input asn_selector asn
  asn_input="$(read_from_tty "额外 ASN（可空）: ")"
  [[ -n "${asn_input}" ]] || return 0

  while IFS= read -r asn_selector; do
    [[ -n "${asn_selector}" ]] || continue
    asn="$(cn_normalize_asn "${asn_selector}")"
    SELECTED_ASNS+=("AS${asn}")
  done < <(split_user_list "${asn_input}")
}

interactive_select_port_policies() {
  SELECTED_PORT_POLICIES=""
  echo >&2
  echo "可选：端口优先白名单。命中端口策略时，会先按该端口自己的白名单判断。" >&2
  echo "格式：端口=白名单；多条用英文或中文分号分隔。" >&2
  echo "示例：22=上海市,AS16509,1.2.3.4/32;10000-20000=广东省,江苏省" >&2
  echo "白名单可写：全国/中国、具体省份、AS12345、IPv4 或 IPv4 CIDR。留空则只使用整机默认白名单。" >&2

  local policy_input
  policy_input="$(read_from_tty "端口优先白名单（可空）: ")"
  policy_input="${policy_input//；/;}"
  [[ -n "$(cn_trim "${policy_input}")" ]] || return 0
  cn_validate_port_policies "${policy_input}"
  SELECTED_PORT_POLICIES="${policy_input}"
}

append_unique_forward_iface() {
  local candidate="$1"
  local existing
  for existing in "${SELECTED_FORWARD_IFACES[@]}"; do
    [[ "${existing}" == "${candidate}" ]] && return 0
  done
  SELECTED_FORWARD_IFACES+=("${candidate}")
}

interactive_select_forward_interfaces() {
  SELECTED_FORWARD_MODE="${CN_FORWARD_MODE_DEFAULT:-all}"
  SELECTED_FORWARD_IFACES=()
  case "${SELECTED_FORWARD_MODE}" in
    all|"")
      SELECTED_FORWARD_MODE="all"
      echo >&2
      echo "整机白名单范围：本机服务 INPUT + 所有 FORWARD 转发流量（包含 flvx/nftables 转发）。" >&2
      ;;
    none)
      echo >&2
      echo "整机白名单范围：仅本机服务 INPUT，不托管 FORWARD 转发。" >&2
      ;;
    selected)
      local iface
      for iface in ${CN_FORWARD_IFACES_DEFAULT:-}; do
        cn_validate_interface_name "${iface}"
        append_unique_forward_iface "${iface}"
      done
      if [[ "${#SELECTED_FORWARD_IFACES[@]}" -eq 0 ]]; then
        echo "CN_FORWARD_MODE_DEFAULT=selected 时必须设置 CN_FORWARD_IFACES_DEFAULT。" >&2
        exit 1
      fi
      echo >&2
      echo "整机白名单范围：本机服务 INPUT + 指定 FORWARD 接口 ${SELECTED_FORWARD_IFACES[*]}。" >&2
      ;;
    *)
      echo "未知 CN_FORWARD_MODE_DEFAULT：${SELECTED_FORWARD_MODE}，可选 all/none/selected。" >&2
      exit 1
      ;;
  esac
}

describe_forward_selection() {
  local mode="$1"
  local ifaces="$2"
  case "${mode}" in
    all) echo "转发托管：所有 FORWARD 流量" ;;
    none) echo "转发托管：关闭，仅限制本机入站端口" ;;
    selected) echo "转发托管：指定接口 ${ifaces}（匹配入/出方向）" ;;
    *) echo "转发托管：未知模式 ${mode}" ;;
  esac
}

copy_selected_forward_ifaces() {
  selected_forward_ifaces=()
  if ((${#SELECTED_FORWARD_IFACES[@]} > 0)); then
    selected_forward_ifaces=("${SELECTED_FORWARD_IFACES[@]}")
  fi
}

confirm_client_ip() {
  local client_ip="$1"
  if [[ -z "${client_ip}" ]]; then
    echo ""
    return
  fi

  echo "检测到当前 SSH 客户端 IP：${client_ip}" >&2
  read -r -p "是否临时加入本次白名单以避免断连？[Y/n] " answer
  case "${answer:-Y}" in
    y|Y|yes|YES) echo "${client_ip}" ;;
    *) echo "" ;;
  esac
}

parse_update_mode() {
  UPDATE_MODE="$1"
  shift || true
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --update) UPDATE_MODE="required" ;;
      --offline|--no-update) UPDATE_MODE="offline" ;;
      --update-optional) UPDATE_MODE="optional" ;;
      *)
        echo "未知参数：${arg}" >&2
        usage
        exit 2
        ;;
    esac
  done
}

prepare_data_for_mode() {
  local mode="$1"
  case "${mode}" in
    required)
      cn_update_runtime_data
      ;;
    optional)
      if ! cn_update_runtime_data; then
        echo "同步上游数据失败，将使用仓库内置数据继续。" >&2
      fi
      ;;
    offline)
      true
      ;;
    *)
      echo "未知更新模式：${mode}" >&2
      exit 2
      ;;
  esac
}

run_apply_or_dry_run() {
  local dry_run="$1"
  local update_mode="$2"
  local -a selected_codes
  local -a selected_asns
  local -a selected_forward_ifaces
  local selected_forward_mode selected_forward_ifaces_text selected_asns_text selected_port_policies
  prepare_data_for_mode "${update_mode}"
  interactive_select_codes
  selected_codes=("${SELECTED_CODES[@]}")
  if [[ "${#selected_codes[@]}" -eq 0 ]]; then
    echo "未选择任何省份。" >&2
    exit 1
  fi
  interactive_select_asns
  selected_asns=("${SELECTED_ASNS[@]}")
  selected_asns_text=""
  if ((${#selected_asns[@]} > 0)); then
    selected_asns_text="${selected_asns[*]}"
  fi
  interactive_select_port_policies
  selected_port_policies="${SELECTED_PORT_POLICIES}"
  interactive_select_forward_interfaces
  selected_forward_mode="${SELECTED_FORWARD_MODE}"
  copy_selected_forward_ifaces
  selected_forward_ifaces_text=""
  if ((${#selected_forward_ifaces[@]} > 0)); then
    selected_forward_ifaces_text="${selected_forward_ifaces[*]}"
  fi

  local client_ip
  client_ip="$(confirm_client_ip "$(cn_detect_ssh_client_ip)")"

  echo
  echo "将使用以下省份代码：${selected_codes[*]}"
  if [[ -n "${selected_asns_text}" ]]; then
    echo "将额外加入 ASN 白名单：${selected_asns_text}"
  fi
  if [[ -n "${selected_port_policies}" ]]; then
    echo "端口优先白名单：${selected_port_policies}"
  fi
  describe_forward_selection "${selected_forward_mode}" "${selected_forward_ifaces_text}"
  echo "防火墙后端：$(cn_effective_firewall_backend)"
  echo

  if [[ "${dry_run}" == "1" ]]; then
    cn_render_apply_commands "${client_ip}" "${selected_forward_mode}" "${selected_forward_ifaces_text}" "${selected_asns_text}" "${selected_port_policies}" "${selected_codes[@]}"
    return
  fi

  cn_require_root
  cn_require_commands
  echo "即将应用规则：未命中白名单的所有入站端口都会被拒绝。"
  read -r -p "确认继续？输入 YES: " confirm
  if [[ "${confirm}" != "YES" ]]; then
    echo "已取消。"
    exit 0
  fi
  cn_render_apply_commands "${client_ip}" "${selected_forward_mode}" "${selected_forward_ifaces_text}" "${selected_asns_text}" "${selected_port_policies}" "${selected_codes[@]}" | cn_run_rendered_commands
  cn_save_config "${selected_forward_mode}" "${selected_forward_ifaces_text}" "${selected_asns_text}" "${selected_port_policies}" "${selected_codes[@]}"
  cn_install_systemd_service
  echo "规则已应用。"
  echo "已保存省份配置，重启后会由 ${CN_SERVICE_NAME} 自动恢复。"
}

restore_rules() {
  local update_mode="$1"
  local -a saved_codes
  local -a saved_asns
  local -a saved_forward_ifaces
  local saved_forward_mode saved_forward_ifaces_text saved_asns_text saved_port_policies
  cn_require_root
  cn_source_config
  cn_require_commands
  prepare_data_for_mode "${update_mode}"

  saved_codes=()
  while IFS= read -r code; do
    [[ -n "${code}" ]] && saved_codes+=("${code}")
  done < <(cn_load_config_codes)

  if [[ "${#saved_codes[@]}" -eq 0 ]]; then
    echo "配置文件中没有省份代码。" >&2
    exit 1
  fi

  saved_asns=()
  while IFS= read -r asn; do
    [[ -n "${asn}" ]] && saved_asns+=("${asn}")
  done < <(cn_load_config_asns)
  saved_asns_text=""
  if ((${#saved_asns[@]} > 0)); then
    saved_asns_text="${saved_asns[*]}"
    CN_ASN_OFFLINE="${CN_ASN_OFFLINE:-1}"
  fi
  saved_port_policies="$(cn_load_config_port_policies)"
  if [[ -n "${saved_port_policies}" ]]; then
    CN_ASN_OFFLINE="${CN_ASN_OFFLINE:-1}"
  fi

  saved_forward_mode="$(cn_load_config_forward_mode)"
  saved_forward_ifaces=()
  while IFS= read -r iface; do
    [[ -n "${iface}" ]] && saved_forward_ifaces+=("${iface}")
  done < <(cn_load_config_forward_ifaces)
  saved_forward_ifaces_text=""
  if ((${#saved_forward_ifaces[@]} > 0)); then
    saved_forward_ifaces_text="${saved_forward_ifaces[*]}"
  fi

  cn_render_apply_commands "" "${saved_forward_mode}" "${saved_forward_ifaces_text}" "${saved_asns_text}" "${saved_port_policies}" "${saved_codes[@]}" | cn_run_rendered_commands
  echo "已按保存配置恢复规则：${saved_codes[*]}"
  if [[ -n "${saved_asns_text}" ]]; then
    echo "已加载 ASN 白名单：${saved_asns_text}"
  fi
  if [[ -n "${saved_port_policies}" ]]; then
    echo "已加载端口优先白名单：${saved_port_policies}"
  fi
  describe_forward_selection "${saved_forward_mode}" "${saved_forward_ifaces_text}"
}

update_asn_rules() {
  local -a saved_asns
  local asn saved_port_policies
  cn_require_root
  saved_asns=()
  while IFS= read -r asn; do
    [[ -n "${asn}" ]] && saved_asns+=("${asn}")
  done < <(cn_load_config_asns)
  saved_port_policies="$(cn_load_config_port_policies)"
  while IFS= read -r asn; do
    [[ -n "${asn}" ]] && saved_asns+=("${asn}")
  done < <(cn_list_asns_from_port_policies "${saved_port_policies}")
  if [[ "${#saved_asns[@]}" -eq 0 ]]; then
    echo "配置文件中没有 ASN 白名单。" >&2
    exit 1
  fi
  CN_ASN_FORCE_UPDATE=1 cn_collect_asn_cidrs "${saved_asns[@]}" >/dev/null
  echo "ASN 白名单已更新：${saved_asns[*]}"
  restore_rules offline
}

status_rules() {
  cn_require_root
  echo "== nft table: ${CN_NFT_TABLE} =="
  if command -v nft >/dev/null 2>&1; then
    nft list table inet "${CN_NFT_TABLE}" 2>/dev/null || true
  else
    echo "nft 未安装"
  fi
  echo
  echo "== ipset: ${CN_SET_NAME} =="
  if command -v ipset >/dev/null 2>&1; then
    ipset list "${CN_SET_NAME}" 2>/dev/null || true
  else
    echo "ipset 未安装"
  fi
  echo
  echo "== iptables chain: ${CN_CHAIN_NAME} =="
  if command -v iptables >/dev/null 2>&1; then
    iptables -S "${CN_CHAIN_NAME}" 2>/dev/null || true
  else
    echo "iptables 未安装"
  fi
  cn_show_persistence_status
}

clear_rules() {
  cn_require_root
  cn_require_commands
  cn_render_clear_commands | cn_run_rendered_commands
  cn_disable_systemd_service
  echo "已清除本脚本管理的规则。"
}

main() {
  local command="${1:-apply}"
  shift || true
  case "${command}" in
    apply)
      parse_update_mode offline "$@"
      run_apply_or_dry_run 0 "${UPDATE_MODE}"
      ;;
    dry-run)
      parse_update_mode offline "$@"
      run_apply_or_dry_run 1 "${UPDATE_MODE}"
      ;;
    restore)
      parse_update_mode offline "$@"
      restore_rules "${UPDATE_MODE}"
      ;;
    update-data)
      parse_update_mode required "$@"
      prepare_data_for_mode "${UPDATE_MODE}"
      echo "数据已同步到：${CN_RUNTIME_DIR}"
      ;;
    update-asn) update_asn_rules ;;
    status) status_rules ;;
    clear) clear_rules ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
