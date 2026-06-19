#!/usr/bin/env bash
set -euo pipefail

CN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CN_PREPARE_DATA="${CN_ROOT}/tools/prepare_data.py"
REGIONS_JSON="${REGIONS_JSON:-${CN_ROOT}/data/regions.json}"
DATA_DIR="${DATA_DIR:-${CN_ROOT}/data}"
CN_REGIONS_TSV="${CN_REGIONS_TSV:-${DATA_DIR}/regions.tsv}"
CN_RUNTIME_DIR="${CN_RUNTIME_DIR:-/var/lib/china-region-whitelist}"
CN_CONFIG_FILE="${CN_CONFIG_FILE:-/etc/china-region-whitelist.conf}"
CN_SERVICE_NAME="china-region-whitelist.service"
CN_CHAIN_NAME="CN_REGION_WHITELIST"
CN_SET_NAME="cn_region_whitelist"
CN_GITHUB_PROXY="${CN_GITHUB_PROXY:-https://gh-proxy.com/}"
CN_UPSTREAM_INDEX_URL="https://raw.githubusercontent.com/metowolf/iplist/master/docs/cncity.md"
CN_UPSTREAM_DATA_BASE_URL="https://raw.githubusercontent.com/metowolf/iplist/master/data/cncity"

cn_python_for_update() {
  if command -v python3 >/dev/null 2>&1; then
    python3 "$@"
  elif command -v python >/dev/null 2>&1; then
    python "$@"
  else
    echo "实时同步上游数据需要 python3/python；默认运行不需要 Python，可使用仓库内置数据继续。" >&2
    return 127
  fi
}

cn_set_data_dir() {
  local output_dir="$1"
  REGIONS_JSON="${output_dir}/data/regions.json"
  DATA_DIR="${output_dir}/data"
  CN_REGIONS_TSV="${DATA_DIR}/regions.tsv"
}

cn_github_proxy_url() {
  local raw_url="$1"
  local proxy="${CN_GITHUB_PROXY}"
  case "${proxy}" in
    ""|direct|none)
      printf '%s\n' "${raw_url}"
      ;;
    */)
      printf '%s%s\n' "${proxy}" "${raw_url}"
      ;;
    *)
      printf '%s/%s\n' "${proxy}" "${raw_url}"
      ;;
  esac
}

cn_use_runtime_data_if_available() {
  if [[ -s "${CN_RUNTIME_DIR}/data/regions.json" && -d "${CN_RUNTIME_DIR}/data/regions" ]]; then
    cn_set_data_dir "${CN_RUNTIME_DIR}"
  fi
}

cn_update_runtime_data() {
  cn_require_root
  mkdir -p "${CN_RUNTIME_DIR}"

  local -a args
  args=(--output-dir "${CN_RUNTIME_DIR}" --refresh-index --force)
  if [[ -n "${CN_INDEX_URL:-}" ]]; then
    args+=(--index-url "${CN_INDEX_URL}")
  else
    args+=(--index-url "$(cn_github_proxy_url "${CN_UPSTREAM_INDEX_URL}")")
  fi
  if [[ -n "${CN_DATA_BASE_URL:-}" ]]; then
    args+=(--data-base-url "${CN_DATA_BASE_URL}")
  else
    args+=(--data-base-url "$(cn_github_proxy_url "${CN_UPSTREAM_DATA_BASE_URL}")")
  fi

  echo "正在同步最新省级 CIDR 数据（需要 python3；默认安装流程不需要同步）..." >&2
  cn_python_for_update "${CN_PREPARE_DATA}" "${args[@]}"
  cn_set_data_dir "${CN_RUNTIME_DIR}"
}

cn_require_region_index() {
  if [[ ! -r "${CN_REGIONS_TSV}" ]]; then
    echo "缺少省份索引：${CN_REGIONS_TSV}" >&2
    echo "请重新拉取最新仓库，或在有 Python 的机器上运行 tools/prepare_data.py 生成 data/regions.tsv。" >&2
    return 1
  fi
}

cn_normalize_region_name() {
  local name="$1"
  local suffix
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"
  for suffix in 特别行政区 维吾尔自治区 壮族自治区 回族自治区 自治区 省 市; do
    if [[ "${name}" == *"${suffix}" ]]; then
      printf '%s\n' "${name%"${suffix}"}"
      return
    fi
  done
  printf '%s\n' "${name}"
}

cn_list_provinces() {
  cn_require_region_index
  awk -F '\t' '$1 == "province" {print $2 "\t" $6 "\t" $7}' "${CN_REGIONS_TSV}"
}

cn_show_provinces() {
  echo "可选省份："
  cn_list_provinces | awk -F '\t' '{print $1 "." $3}'
}

cn_resolve_province() {
  local selector="$1"
  local selector_norm code=""
  local match_count=0
  selector="${selector#"${selector%%[![:space:]]*}"}"
  selector="${selector%"${selector##*[![:space:]]}"}"
  selector_norm="$(cn_normalize_region_name "${selector}")"

  local index province_code name
  while IFS=$'\t' read -r index province_code name; do
    if [[ "${selector}" == "${index}" || "${selector}" == "${province_code}" || "${selector}" == "${name}" || "${selector_norm}" == "$(cn_normalize_region_name "${name}")" ]]; then
      code="${province_code}"
      match_count=$((match_count + 1))
    fi
  done < <(cn_list_provinces)

  if [[ "${match_count}" -eq 1 ]]; then
    printf '%s\n' "${code}"
    return
  fi
  if [[ "${match_count}" -eq 0 ]]; then
    echo "未找到省份：${selector}" >&2
  else
    echo "省份名称不唯一：${selector}" >&2
  fi
  return 1
}

cn_collect_cidrs() {
  local code region_file full_path
  for code in "$@"; do
    region_file="$(cn_region_file_for_code "${code}")" || return 1
    full_path="${DATA_DIR}/${region_file}"
    if [[ ! -r "${full_path}" ]]; then
      echo "缺少省级 CIDR 文件：${full_path}" >&2
      return 1
    fi
    sed 's/[[:space:]]*$//' "${full_path}" | awk 'NF && $0 !~ /^#/'
  done | awk '!seen[$0]++'
}

cn_province_name() {
  local code="$1"
  cn_require_region_index
  awk -F '\t' -v code="${code}" '$1 == "province" && $6 == code {print $7; exit}' "${CN_REGIONS_TSV}"
}

cn_region_file_for_code() {
  local code="$1"
  if ! [[ "${code}" =~ ^[0-9]{6}$ ]]; then
    echo "非法省份代码：${code}" >&2
    return 1
  fi
  cn_require_region_index
  local file
  file="$(awk -F '\t' -v code="${code}" '$1 == "province" && $6 == code {print $8; exit}' "${CN_REGIONS_TSV}")"
  if [[ -z "${file}" ]]; then
    echo "未知省份代码：${code}" >&2
    return 1
  fi
  printf '%s\n' "${file}"
}

cn_remove_jump_command() {
  local entry_chain="$1"
  printf "iptables -S %s | awk '\$0 ~ / -j %s( |\$)/ { sub(/^-A /, \"-D \"); print \"iptables \" \$0 }' | sh\n" \
    "${entry_chain}" "${CN_CHAIN_NAME}"
}

cn_add_jump_command() {
  local entry_chain="$1"
  shift || true
  local arg_string=""
  if [[ "$#" -gt 0 ]]; then
    arg_string="$* "
  fi
  printf 'iptables -C %s %s-j %s 2>/dev/null || iptables -I %s 1 %s-j %s\n' \
    "${entry_chain}" "${arg_string}" "${CN_CHAIN_NAME}" "${entry_chain}" "${arg_string}" "${CN_CHAIN_NAME}"
}

cn_validate_client_ip() {
  local ip="$1"
  [[ "${ip}" =~ ^[0-9A-Fa-f:.]+$ ]]
}

cn_render_apply_commands() {
  local client_ip="${1:-}"
  local forward_mode="${2:-all}"
  local forward_ifaces="${3:-}"
  shift 3 || true

  case "${forward_mode}" in
    all|"")
      ;;
    none)
      args+=(--no-forward)
      ;;
    selected)
      if [[ -z "${forward_ifaces}" ]]; then
        echo "已选择指定转发接口模式，但没有提供接口名。" >&2
        return 1
      fi
      local iface
      for iface in ${forward_ifaces}; do
        cn_validate_interface_name "${iface}" || return 1
        args+=(--forward-iface "${iface}")
      done
      ;;
    *)
      echo "未知转发接口模式：${forward_mode}" >&2
      return 1
      ;;
  esac

  local cidrs cidr
  cidrs="$(cn_collect_cidrs "$@")" || return 1
  if [[ -z "${cidrs}" ]]; then
    echo "所选省份没有可用 CIDR 段。" >&2
    return 1
  fi

  printf 'ipset create %s hash:net family inet -exist\n' "${CN_SET_NAME}"
  printf 'ipset flush %s\n' "${CN_SET_NAME}"
  while IFS= read -r cidr; do
    [[ -n "${cidr}" ]] || continue
    printf 'ipset add %s %s -exist\n' "${CN_SET_NAME}" "${cidr}"
  done <<<"${cidrs}"
  if [[ -n "${client_ip}" ]]; then
    if ! cn_validate_client_ip "${client_ip}"; then
      echo "非法客户端 IP：${client_ip}" >&2
      return 1
    fi
    printf 'ipset add %s %s -exist\n' "${CN_SET_NAME}" "${client_ip}"
  fi

  printf 'iptables -N %s 2>/dev/null || true\n' "${CN_CHAIN_NAME}"
  cn_remove_jump_command INPUT
  cn_remove_jump_command FORWARD
  printf 'iptables -F %s\n' "${CN_CHAIN_NAME}"
  cn_add_jump_command INPUT
  if [[ "${forward_mode}" != "none" ]]; then
    if [[ "${forward_mode}" == "selected" ]]; then
      local iface
      for iface in ${forward_ifaces}; do
        cn_add_jump_command FORWARD -i "${iface}"
        cn_add_jump_command FORWARD -o "${iface}"
      done
    else
      cn_add_jump_command FORWARD
    fi
  fi
  printf 'iptables -A %s -i lo -j ACCEPT\n' "${CN_CHAIN_NAME}"
  printf 'iptables -A %s -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n' "${CN_CHAIN_NAME}"
  printf 'iptables -A %s -m set --match-set %s src -j ACCEPT\n' "${CN_CHAIN_NAME}" "${CN_SET_NAME}"
  printf 'iptables -A %s -j REJECT\n' "${CN_CHAIN_NAME}"
}

cn_render_clear_commands() {
  cn_remove_jump_command INPUT
  cn_remove_jump_command FORWARD
  printf 'iptables -F %s 2>/dev/null || true\n' "${CN_CHAIN_NAME}"
  printf 'iptables -X %s 2>/dev/null || true\n' "${CN_CHAIN_NAME}"
  printf 'ipset destroy %s 2>/dev/null || true\n' "${CN_SET_NAME}"
}

cn_save_config() {
  cn_require_root
  local forward_mode="$1"
  local forward_ifaces="$2"
  shift 2 || true
  local -a codes=("$@")
  if [[ "${#codes[@]}" -eq 0 ]]; then
    echo "没有可保存的省份代码。" >&2
    return 1
  fi
  case "${forward_mode}" in
    all|none|selected) ;;
    *)
      echo "未知转发接口模式：${forward_mode}" >&2
      return 1
      ;;
  esac

  mkdir -p "$(dirname "${CN_CONFIG_FILE}")"
  {
    echo "# Generated by china-region-whitelist. Edit CN_CODES only if you know the province codes."
    printf 'CN_CODES="%s"\n' "${codes[*]}"
    printf 'CN_FORWARD_MODE="%s"\n' "${forward_mode}"
    printf 'CN_FORWARD_IFACES="%s"\n' "${forward_ifaces}"
    printf 'CN_ROOT="%s"\n' "${CN_ROOT}"
    printf 'CN_RUNTIME_DIR="%s"\n' "${CN_RUNTIME_DIR}"
  } > "${CN_CONFIG_FILE}"
  chmod 0644 "${CN_CONFIG_FILE}"
}

cn_source_config() {
  if [[ ! -r "${CN_CONFIG_FILE}" ]]; then
    echo "未找到配置文件：${CN_CONFIG_FILE}，请先运行 apply。" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "${CN_CONFIG_FILE}"
}

cn_load_config_codes() {
  cn_source_config
  if [[ -z "${CN_CODES:-}" ]]; then
    echo "配置文件缺少 CN_CODES：${CN_CONFIG_FILE}" >&2
    return 1
  fi

  local code
  for code in ${CN_CODES}; do
    if ! [[ "${code}" =~ ^[0-9]{6}$ ]]; then
      echo "配置文件中存在非法省份代码：${code}" >&2
      return 1
    fi
    printf '%s\n' "${code}"
  done
}

cn_load_config_forward_mode() {
  cn_source_config
  printf '%s\n' "${CN_FORWARD_MODE:-all}"
}

cn_load_config_forward_ifaces() {
  cn_source_config
  local iface
  for iface in ${CN_FORWARD_IFACES:-}; do
    cn_validate_interface_name "${iface}" || return 1
    printf '%s\n' "${iface}"
  done
}

cn_install_systemd_service() {
  cn_require_root
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "未检测到 systemd，已应用当前规则，但无法自动配置开机恢复。" >&2
    return 0
  fi

  local service_path="/etc/systemd/system/${CN_SERVICE_NAME}"
  cat > "${service_path}" <<EOF
[Unit]
Description=china region whitelist firewall
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${CN_ROOT}/install.sh restore --offline

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${CN_SERVICE_NAME}"
}

cn_disable_systemd_service() {
  cn_require_root
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable "${CN_SERVICE_NAME}" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${CN_SERVICE_NAME}"
    systemctl daemon-reload || true
  fi
  rm -f "${CN_CONFIG_FILE}"
}

cn_show_persistence_status() {
  echo
  echo "== persistence =="
  if [[ -r "${CN_CONFIG_FILE}" ]]; then
    echo "config: ${CN_CONFIG_FILE}"
    # shellcheck disable=SC1090
    source "${CN_CONFIG_FILE}"
    echo "regions: ${CN_CODES:-未配置}"
    echo "forward: ${CN_FORWARD_MODE:-all}${CN_FORWARD_IFACES:+ (${CN_FORWARD_IFACES})}"
  else
    echo "config: 未配置"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-enabled "${CN_SERVICE_NAME}" 2>/dev/null || true
  else
    echo "systemd: 未检测到"
  fi
}

cn_require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "此操作需要 root 权限，请使用 sudo 或 root 用户运行。" >&2
    exit 1
  fi
}

cn_install_dependencies() {
  echo "检测到缺少 iptables/ipset，开始使用系统默认软件源自动安装..." >&2

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y iptables ipset
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y iptables ipset
  elif command -v yum >/dev/null 2>&1; then
    yum install -y iptables ipset
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache iptables ipset
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive refresh || true
    zypper --non-interactive install iptables ipset
  else
    echo "未识别到 apt-get/dnf/yum/apk/zypper，无法自动安装 iptables/ipset。" >&2
    return 1
  fi
}

cn_require_commands() {
  local missing=0
  for command_name in iptables ipset; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      echo "缺少命令：${command_name}" >&2
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    cn_install_dependencies || {
      echo "自动安装失败，请检查系统软件源后重试。" >&2
      exit 1
    }
  fi

  missing=0
  for command_name in iptables ipset; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      echo "安装后仍缺少命令：${command_name}" >&2
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    echo "依赖未安装完整，请检查系统软件源或包名。" >&2
    exit 1
  fi
}

cn_detect_ssh_client_ip() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    awk '{print $1}' <<<"${SSH_CONNECTION}"
  else
    true
  fi
}

cn_validate_interface_name() {
  local iface="$1"
  if [[ "${iface}" =~ ^[A-Za-z0-9_.:-]{1,64}\+?$ ]]; then
    return 0
  fi
  echo "非法接口名：${iface}" >&2
  return 1
}

cn_list_network_interfaces() {
  if command -v ip >/dev/null 2>&1; then
    ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | sort -u
  elif [[ -d /sys/class/net ]]; then
    local iface_path
    for iface_path in /sys/class/net/*; do
      [[ -e "${iface_path}" ]] || continue
      basename "${iface_path}"
    done | sort -u
  fi
}

cn_is_tunnel_interface() {
  local iface="$1"
  if [[ -e "/sys/class/net/${iface}/tun_flags" ]]; then
    return 0
  fi
  case "${iface}" in
    tun*|tap*|wg*|tailscale*|ts*|zt*|utun*|warp*|nebula*|mihomo*|sing*|clash*)
      return 0
      ;;
  esac
  return 1
}

cn_list_tunnel_interfaces() {
  local iface
  while IFS= read -r iface; do
    [[ -n "${iface}" ]] || continue
    cn_is_tunnel_interface "${iface}" && printf '%s\n' "${iface}"
  done < <(cn_list_network_interfaces)
}

cn_run_rendered_commands() {
  local command_line
  while IFS= read -r command_line; do
    [[ -z "${command_line}" ]] && continue
    echo "+ ${command_line}"
    eval "${command_line}"
  done
}
