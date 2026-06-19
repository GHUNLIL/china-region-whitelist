#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT}/tools/firewall_lib.sh"

usage() {
  cat <<'EOF'
po0 省/市白名单一键脚本

用法：
  ./install.sh apply [--update|--offline|--update-optional]
                         更新数据、交互选择地区、应用防火墙并配置开机恢复
  ./install.sh dry-run [--update|--offline|--update-optional]
                         交互选择地区，只打印将执行的命令
  ./install.sh restore [--update|--offline|--update-optional]
                         使用上次保存的地区配置重新应用规则
  ./install.sh update-data
                         只同步最新地区 CIDR 数据到 /var/lib/po0-region-whitelist
  ./install.sh status    查看当前托管规则和开机恢复状态
  ./install.sh clear     清除本脚本创建的规则、保存配置和 systemd 服务

说明：
  apply 会让未命中白名单的所有入站端口全部拒绝。
  apply/dry-run 默认先同步最新上游数据；如需离线使用仓库内数据，加 --offline。
  建议先运行 dry-run，确认地区和命令后再 apply。
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
  if [[ -r /dev/tty ]]; then
    read -r -p "${prompt}" value < /dev/tty
  else
    read -r -p "${prompt}" value
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
  po0_show_provinces >&2
  echo >&2
  echo "输入编号或省份名称，多个用空格/逗号分隔，例如：1 2 广东省 江苏省" >&2

  local province_input
  province_input="$(read_from_tty "省份: ")"
  [[ -n "${province_input}" ]] || {
    echo "未输入省份。" >&2
    exit 1
  }

  local province_selector province_code city_input city_selector city_code
  while IFS= read -r province_selector; do
    [[ -n "${province_selector}" ]] || continue
    province_code="$(po0_resolve_province "${province_selector}")"

    echo >&2
    po0_show_cities "${province_code}" >&2
    echo "输入 0/全省/全市，或输入城市编号/城市名称，多个用空格/逗号分隔，例如：1 2 深圳市 广州市" >&2
    city_input="$(read_from_tty "城市: ")"
    [[ -n "${city_input}" ]] || {
      echo "未输入城市选择。" >&2
      exit 1
    }

    if [[ "${city_input}" == "0" || "${city_input}" == "全省" || "${city_input}" == "全市" ]]; then
      SELECTED_CODES+=("${province_code}")
    else
      while IFS= read -r city_selector; do
        [[ -n "${city_selector}" ]] || continue
        city_code="$(po0_resolve_city "${province_code}" "${city_selector}")"
        SELECTED_CODES+=("${city_code}")
      done < <(split_user_list "${city_input}")
    fi
  done < <(split_user_list "${province_input}")
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
      po0_update_runtime_data
      ;;
    optional)
      if ! po0_update_runtime_data; then
        echo "同步上游数据失败，将尝试使用已有运行时数据或仓库内置数据。" >&2
        po0_use_runtime_data_if_available
      fi
      ;;
    offline)
      po0_use_runtime_data_if_available
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
  prepare_data_for_mode "${update_mode}"
  interactive_select_codes
  selected_codes=("${SELECTED_CODES[@]}")
  if [[ "${#selected_codes[@]}" -eq 0 ]]; then
    echo "未选择任何地区。" >&2
    exit 1
  fi

  local client_ip
  client_ip="$(confirm_client_ip "$(po0_detect_ssh_client_ip)")"

  echo
  echo "将使用以下地区代码：${selected_codes[*]}"
  echo

  if [[ "${dry_run}" == "1" ]]; then
    po0_render_apply_commands "${client_ip}" "${selected_codes[@]}"
    return
  fi

  po0_require_root
  po0_require_commands
  echo "即将应用规则：未命中白名单的所有入站端口都会被拒绝。"
  read -r -p "确认继续？输入 YES: " confirm
  if [[ "${confirm}" != "YES" ]]; then
    echo "已取消。"
    exit 0
  fi
  po0_render_apply_commands "${client_ip}" "${selected_codes[@]}" | po0_run_rendered_commands
  po0_save_config "${selected_codes[@]}"
  po0_install_systemd_service
  echo "规则已应用。"
  echo "已保存地区配置，重启后会由 ${PO0_SERVICE_NAME} 自动恢复。"
}

restore_rules() {
  local update_mode="$1"
  local -a saved_codes
  po0_require_root
  po0_require_commands
  prepare_data_for_mode "${update_mode}"

  saved_codes=()
  while IFS= read -r code; do
    [[ -n "${code}" ]] && saved_codes+=("${code}")
  done < <(po0_load_config_codes)

  if [[ "${#saved_codes[@]}" -eq 0 ]]; then
    echo "配置文件中没有地区代码。" >&2
    exit 1
  fi

  po0_render_apply_commands "" "${saved_codes[@]}" | po0_run_rendered_commands
  echo "已按保存配置恢复规则：${saved_codes[*]}"
}

status_rules() {
  po0_require_root
  echo "== ipset: ${PO0_SET_NAME} =="
  if command -v ipset >/dev/null 2>&1; then
    ipset list "${PO0_SET_NAME}" 2>/dev/null || true
  else
    echo "ipset 未安装"
  fi
  echo
  echo "== iptables chain: ${PO0_CHAIN_NAME} =="
  if command -v iptables >/dev/null 2>&1; then
    iptables -S "${PO0_CHAIN_NAME}" 2>/dev/null || true
  else
    echo "iptables 未安装"
  fi
  po0_show_persistence_status
}

clear_rules() {
  po0_require_root
  po0_require_commands
  po0_render_clear_commands | po0_run_rendered_commands
  po0_disable_systemd_service
  echo "已清除本脚本管理的规则。"
}

main() {
  local command="${1:-apply}"
  shift || true
  case "${command}" in
    apply)
      parse_update_mode required "$@"
      run_apply_or_dry_run 0 "${UPDATE_MODE}"
      ;;
    dry-run)
      parse_update_mode required "$@"
      run_apply_or_dry_run 1 "${UPDATE_MODE}"
      ;;
    restore)
      parse_update_mode optional "$@"
      restore_rules "${UPDATE_MODE}"
      ;;
    update-data)
      parse_update_mode required "$@"
      prepare_data_for_mode "${UPDATE_MODE}"
      echo "数据已同步到：${PO0_RUNTIME_DIR}"
      ;;
    status) status_rules ;;
    clear) clear_rules ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
