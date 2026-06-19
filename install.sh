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
                         交互选择省份和 TUN/转发接口、应用防火墙并配置开机恢复
  ./install.sh dry-run [--offline|--update|--update-optional]
                         交互选择省份和 TUN/转发接口，只打印将执行的命令
  ./install.sh restore [--offline|--update|--update-optional]
                         使用上次保存的省份配置重新应用规则
  ./install.sh update-data
                         只同步最新省级 CIDR 数据到 /var/lib/china-region-whitelist
  ./install.sh status    查看当前托管规则和开机恢复状态
  ./install.sh clear     清除本脚本创建的规则、保存配置和 systemd 服务

说明：
  apply 会让未命中白名单的所有入站端口全部拒绝。
  转发流量可选择全部托管、仅托管指定 TUN/TAP/WireGuard 接口，或不托管。
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
  printf '%s\n' ${input}
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
  echo "输入编号或省份名称，多个用空格/逗号分隔，例如：1 2 广东省 江苏省" >&2

  local province_input
  province_input="$(read_from_tty "省份: ")"
  [[ -n "${province_input}" ]] || {
    echo "未输入省份。" >&2
    exit 1
  }

  local province_selector province_code
  while IFS= read -r province_selector; do
    [[ -n "${province_selector}" ]] || continue
    province_code="$(cn_resolve_province "${province_selector}")"
    SELECTED_CODES+=("${province_code}")
  done < <(split_user_list "${province_input}")
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
  SELECTED_FORWARD_MODE="all"
  SELECTED_FORWARD_IFACES=()

  local -a tunnel_ifaces=()
  local iface
  while IFS= read -r iface; do
    [[ -n "${iface}" ]] && tunnel_ifaces+=("${iface}")
  done < <(cn_list_tunnel_interfaces)

  local input item index ok
  while true; do
    echo >&2
    echo "请选择 TUN/转发接口托管方式：" >&2
    echo "0. 不托管 FORWARD 转发，只限制服务器本机入站端口" >&2
    echo "1. 托管所有 FORWARD 转发流量（默认，兼容旧版本）" >&2

    index=2
    if [[ "${#tunnel_ifaces[@]}" -gt 0 ]]; then
      echo "检测到的 TUN/TAP/WireGuard 类接口：" >&2
      for iface in "${tunnel_ifaces[@]}"; do
        printf '%d. %s\n' "${index}" "${iface}" >&2
        index=$((index + 1))
      done
    else
      echo "未自动检测到 TUN/TAP/WireGuard 类接口。" >&2
    fi
    echo "也可以直接输入接口名，多个用空格/逗号分隔，例如：tun0 wg0 tailscale0" >&2

    input="$(read_from_tty "转发接口 [1]: ")"
    input="${input:-1}"

    if [[ "${input}" == "0" ]]; then
      SELECTED_FORWARD_MODE="none"
      SELECTED_FORWARD_IFACES=()
      return
    fi
    if [[ "${input}" == "1" ]]; then
      SELECTED_FORWARD_MODE="all"
      SELECTED_FORWARD_IFACES=()
      return
    fi

    SELECTED_FORWARD_MODE="selected"
    SELECTED_FORWARD_IFACES=()
    ok=1
    while IFS= read -r item; do
      [[ -n "${item}" ]] || continue
      if [[ "${item}" =~ ^[0-9]+$ ]]; then
        if (( item >= 2 && item < 2 + ${#tunnel_ifaces[@]} )); then
          append_unique_forward_iface "${tunnel_ifaces[$((item - 2))]}"
        else
          ok=0
        fi
      elif cn_validate_interface_name "${item}"; then
        append_unique_forward_iface "${item}"
      else
        ok=0
      fi
    done < <(split_user_list "${input}")

    if [[ "${ok}" -eq 1 && "${#SELECTED_FORWARD_IFACES[@]}" -gt 0 ]]; then
      return
    fi
    echo "输入无效：请输入 0、1、接口编号，或合法接口名；多个接口可用空格/逗号分隔。" >&2
  done
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
  local -a selected_forward_ifaces
  local selected_forward_mode selected_forward_ifaces_text
  prepare_data_for_mode "${update_mode}"
  interactive_select_codes
  selected_codes=("${SELECTED_CODES[@]}")
  if [[ "${#selected_codes[@]}" -eq 0 ]]; then
    echo "未选择任何省份。" >&2
    exit 1
  fi
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
  describe_forward_selection "${selected_forward_mode}" "${selected_forward_ifaces_text}"
  echo

  if [[ "${dry_run}" == "1" ]]; then
    cn_render_apply_commands "${client_ip}" "${selected_forward_mode}" "${selected_forward_ifaces_text}" "${selected_codes[@]}"
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
  cn_render_apply_commands "${client_ip}" "${selected_forward_mode}" "${selected_forward_ifaces_text}" "${selected_codes[@]}" | cn_run_rendered_commands
  cn_save_config "${selected_forward_mode}" "${selected_forward_ifaces_text}" "${selected_codes[@]}"
  cn_install_systemd_service
  echo "规则已应用。"
  echo "已保存省份配置，重启后会由 ${CN_SERVICE_NAME} 自动恢复。"
}

restore_rules() {
  local update_mode="$1"
  local -a saved_codes
  local -a saved_forward_ifaces
  local saved_forward_mode saved_forward_ifaces_text
  cn_require_root
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

  saved_forward_mode="$(cn_load_config_forward_mode)"
  saved_forward_ifaces=()
  while IFS= read -r iface; do
    [[ -n "${iface}" ]] && saved_forward_ifaces+=("${iface}")
  done < <(cn_load_config_forward_ifaces)
  saved_forward_ifaces_text=""
  if ((${#saved_forward_ifaces[@]} > 0)); then
    saved_forward_ifaces_text="${saved_forward_ifaces[*]}"
  fi

  cn_render_apply_commands "" "${saved_forward_mode}" "${saved_forward_ifaces_text}" "${saved_codes[@]}" | cn_run_rendered_commands
  echo "已按保存配置恢复规则：${saved_codes[*]}"
  describe_forward_selection "${saved_forward_mode}" "${saved_forward_ifaces_text}"
}

status_rules() {
  cn_require_root
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
    status) status_rules ;;
    clear) clear_rules ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
