#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT}/tools/firewall_lib.sh"

usage() {
  cat <<'EOF'
po0 省/市白名单一键脚本

用法：
  ./install.sh apply     交互选择地区并应用防火墙
  ./install.sh dry-run   交互选择地区，只打印将执行的命令
  ./install.sh status    查看当前托管规则
  ./install.sh clear     清除本脚本创建的规则和 ipset

说明：
  apply 会让未命中白名单的所有入站端口全部拒绝。
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

run_apply_or_dry_run() {
  local dry_run="$1"
  local -a selected_codes
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
  echo "规则已应用。"
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
}

clear_rules() {
  po0_require_root
  po0_require_commands
  po0_render_clear_commands | po0_run_rendered_commands
  echo "已清除本脚本管理的规则。"
}

main() {
  local command="${1:-apply}"
  case "${command}" in
    apply) run_apply_or_dry_run 0 ;;
    dry-run) run_apply_or_dry_run 1 ;;
    status) status_rules ;;
    clear) clear_rules ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
