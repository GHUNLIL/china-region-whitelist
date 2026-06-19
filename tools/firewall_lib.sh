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
CN_FIREWALL_BACKEND="${CN_FIREWALL_BACKEND:-auto}"
CN_NFT_TABLE="china_region_whitelist"
CN_NFT_SET_NAME="allowed_v4"
CN_NFT_HOOK_PRIORITY="${CN_NFT_HOOK_PRIORITY:--10}"
CN_GITHUB_PROXY="${CN_GITHUB_PROXY:-https://gh-proxy.com/}"
CN_UPSTREAM_INDEX_URL="https://raw.githubusercontent.com/metowolf/iplist/master/docs/cncity.md"
CN_UPSTREAM_DATA_BASE_URL="https://raw.githubusercontent.com/metowolf/iplist/master/data/cncity"
CN_ASN_BASE_URL="${CN_ASN_BASE_URL:-https://raw.githubusercontent.com/ipverse/as-ip-blocks/master/as}"
CN_ASN_CACHE_DIR="${CN_ASN_CACHE_DIR:-${CN_RUNTIME_DIR}/asn}"

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

cn_proxy_url_if_github() {
  local raw_url="$1"
  case "${raw_url}" in
    https://raw.githubusercontent.com/*|https://github.com/*)
      cn_github_proxy_url "${raw_url}"
      ;;
    *)
      printf '%s\n' "${raw_url}"
      ;;
  esac
}

cn_effective_firewall_backend() {
  case "${CN_FIREWALL_BACKEND}" in
    nft|iptables)
      printf '%s\n' "${CN_FIREWALL_BACKEND}"
      ;;
    auto|"")
      if command -v nft >/dev/null 2>&1; then
        printf '%s\n' "nft"
      else
        printf '%s\n' "iptables"
      fi
      ;;
    *)
      echo "未知防火墙后端：${CN_FIREWALL_BACKEND}，可选 auto/nft/iptables。" >&2
      return 1
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

cn_normalize_asn() {
  local asn="$1"
  asn="${asn#"${asn%%[![:space:]]*}"}"
  asn="${asn%"${asn##*[![:space:]]}"}"
  case "${asn}" in
    AS*|as*|As*|aS*) asn="${asn:2}" ;;
  esac
  if ! [[ "${asn}" =~ ^[0-9]{1,10}$ ]]; then
    echo "非法 ASN：${asn}" >&2
    return 1
  fi
  if (( asn < 1 || asn > 4294967295 )); then
    echo "ASN 超出范围：${asn}" >&2
    return 1
  fi
  printf '%s\n' "${asn}"
}

cn_asn_prefix_url() {
  local asn="$1"
  local base_url
  base_url="$(cn_proxy_url_if_github "${CN_ASN_BASE_URL}")"
  printf '%s/%s/ipv4-aggregated.txt\n' "${base_url%/}" "${asn}"
}

cn_download_asn_prefixes() {
  local asn="$1"
  local target="$2"
  local tmp url
  if [[ "${CN_ASN_OFFLINE:-0}" == "1" ]]; then
    echo "缺少 ASN${asn} 缓存：${target}；请先运行 apply 或 update-asn 在线同步。" >&2
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "同步 ASN${asn} 前缀需要 curl。" >&2
    return 1
  fi
  mkdir -p "$(dirname "${target}")"
  tmp="${target}.tmp.$$"
  url="$(cn_asn_prefix_url "${asn}")"
  echo "正在同步 ASN${asn} IPv4 前缀：${url}" >&2
  if ! curl -fsSL --connect-timeout 20 --retry 2 --retry-delay 1 -o "${tmp}" "${url}"; then
    rm -f "${tmp}"
    echo "同步 ASN${asn} 前缀失败。" >&2
    return 1
  fi
  mv "${tmp}" "${target}"
}

cn_collect_asn_cidrs() {
  local raw_asn asn file
  for raw_asn in "$@"; do
    [[ -n "${raw_asn}" ]] || continue
    asn="$(cn_normalize_asn "${raw_asn}")" || return 1
    file="${CN_ASN_CACHE_DIR}/AS${asn}.txt"
    if [[ ! -s "${file}" || "${CN_ASN_FORCE_UPDATE:-0}" == "1" ]]; then
      cn_download_asn_prefixes "${asn}" "${file}" || return 1
    fi
    awk 'NF && $0 !~ /^#/ && $0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {print $0}' "${file}"
  done
}

cn_collect_allowed_cidrs() {
  local asns="$1"
  shift || true
  {
    cn_collect_cidrs "$@"
    # shellcheck disable=SC2086
    cn_collect_asn_cidrs ${asns}
  } | awk '!seen[$0]++'
}

cn_is_ipv4_address() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
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
  local backend
  backend="$(cn_effective_firewall_backend)" || return 1
  case "${backend}" in
    nft) cn_render_apply_commands_nft "$@" ;;
    iptables) cn_render_apply_commands_iptables "$@" ;;
  esac
}

cn_validate_forward_selection() {
  local forward_mode="$1"
  local forward_ifaces="$2"
  case "${forward_mode}" in
    all|"")
      ;;
    none)
      ;;
    selected)
      if [[ -z "${forward_ifaces}" ]]; then
        echo "已选择指定转发接口模式，但没有提供接口名。" >&2
        return 1
      fi
      local iface
      for iface in ${forward_ifaces}; do
        cn_validate_interface_name "${iface}" || return 1
      done
      ;;
    *)
      echo "未知转发接口模式：${forward_mode}" >&2
      return 1
      ;;
  esac
}

cn_render_apply_commands_iptables() {
  local client_ip="${1:-}"
  local forward_mode="${2:-all}"
  local forward_ifaces="${3:-}"
  local asns="${4:-}"
  shift 4 || true

  cn_validate_forward_selection "${forward_mode}" "${forward_ifaces}" || return 1

  local cidrs cidr
  cidrs="$(cn_collect_allowed_cidrs "${asns}" "$@")" || return 1
  if [[ -z "${cidrs}" ]]; then
    echo "所选省份/ASN 没有可用 IPv4 CIDR 段。" >&2
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

cn_render_apply_commands_nft() {
  local client_ip="${1:-}"
  local forward_mode="${2:-all}"
  local forward_ifaces="${3:-}"
  local asns="${4:-}"
  shift 4 || true

  cn_validate_forward_selection "${forward_mode}" "${forward_ifaces}" || return 1

  local cidrs cidr iface
  cidrs="$(cn_collect_allowed_cidrs "${asns}" "$@")" || return 1
  if [[ -z "${cidrs}" ]]; then
    echo "所选省份/ASN 没有可用 IPv4 CIDR 段。" >&2
    return 1
  fi

  printf 'nft delete table inet %s 2>/dev/null || true\n' "${CN_NFT_TABLE}"
  printf 'nft add table inet %s\n' "${CN_NFT_TABLE}"
  printf "nft add set inet %s %s '{ type ipv4_addr; flags interval; }'\n" "${CN_NFT_TABLE}" "${CN_NFT_SET_NAME}"
  while IFS= read -r cidr; do
    [[ -n "${cidr}" ]] || continue
    printf "nft add element inet %s %s '{ %s }'\n" "${CN_NFT_TABLE}" "${CN_NFT_SET_NAME}" "${cidr}"
  done <<<"${cidrs}"
  if [[ -n "${client_ip}" ]]; then
    if ! cn_validate_client_ip "${client_ip}"; then
      echo "非法客户端 IP：${client_ip}" >&2
      return 1
    fi
    if cn_is_ipv4_address "${client_ip}"; then
      printf "nft add element inet %s %s '{ %s }'\n" "${CN_NFT_TABLE}" "${CN_NFT_SET_NAME}" "${client_ip}"
    else
      echo "nft 后端当前只托管 IPv4 白名单，已跳过 IPv6 客户端临时白名单：${client_ip}" >&2
    fi
  fi

  printf "nft add chain inet %s input '{ type filter hook input priority %s; policy accept; }'\n" "${CN_NFT_TABLE}" "${CN_NFT_HOOK_PRIORITY}"
  printf 'nft add rule inet %s input iifname "lo" accept\n' "${CN_NFT_TABLE}"
  printf 'nft add rule inet %s input ct state established,related accept\n' "${CN_NFT_TABLE}"
  printf 'nft add rule inet %s input ip saddr @%s accept\n' "${CN_NFT_TABLE}" "${CN_NFT_SET_NAME}"
  printf 'nft add rule inet %s input meta nfproto ipv4 reject\n' "${CN_NFT_TABLE}"

  if [[ "${forward_mode}" != "none" ]]; then
    printf "nft add chain inet %s forward '{ type filter hook forward priority %s; policy accept; }'\n" "${CN_NFT_TABLE}" "${CN_NFT_HOOK_PRIORITY}"
    printf 'nft add rule inet %s forward ct state established,related accept\n' "${CN_NFT_TABLE}"
    if [[ "${forward_mode}" == "selected" ]]; then
      for iface in ${forward_ifaces}; do
        printf 'nft add rule inet %s forward iifname "%s" ip saddr @%s accept\n' "${CN_NFT_TABLE}" "${iface}" "${CN_NFT_SET_NAME}"
        printf 'nft add rule inet %s forward iifname "%s" meta nfproto ipv4 reject\n' "${CN_NFT_TABLE}" "${iface}"
        printf 'nft add rule inet %s forward oifname "%s" ip saddr @%s accept\n' "${CN_NFT_TABLE}" "${iface}" "${CN_NFT_SET_NAME}"
        printf 'nft add rule inet %s forward oifname "%s" meta nfproto ipv4 reject\n' "${CN_NFT_TABLE}" "${iface}"
      done
    else
      printf 'nft add rule inet %s forward ip saddr @%s accept\n' "${CN_NFT_TABLE}" "${CN_NFT_SET_NAME}"
      printf 'nft add rule inet %s forward meta nfproto ipv4 reject\n' "${CN_NFT_TABLE}"
    fi
  fi
}

cn_render_clear_commands() {
  local backend
  backend="$(cn_effective_firewall_backend)" || return 1
  case "${backend}" in
    nft)
      printf 'nft delete table inet %s 2>/dev/null || true\n' "${CN_NFT_TABLE}"
      ;;
    iptables)
      cn_remove_jump_command INPUT
      cn_remove_jump_command FORWARD
      printf 'iptables -F %s 2>/dev/null || true\n' "${CN_CHAIN_NAME}"
      printf 'iptables -X %s 2>/dev/null || true\n' "${CN_CHAIN_NAME}"
      printf 'ipset destroy %s 2>/dev/null || true\n' "${CN_SET_NAME}"
      ;;
  esac
}

cn_save_config() {
  cn_require_root
  local forward_mode="$1"
  local forward_ifaces="$2"
  local asns="$3"
  shift 3 || true
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
    printf 'CN_ASNS="%s"\n' "${asns}"
    printf 'CN_FORWARD_MODE="%s"\n' "${forward_mode}"
    printf 'CN_FORWARD_IFACES="%s"\n' "${forward_ifaces}"
    printf 'CN_FIREWALL_BACKEND="%s"\n' "$(cn_effective_firewall_backend)"
    printf 'CN_ROOT="%s"\n' "${CN_ROOT}"
    printf 'CN_RUNTIME_DIR="%s"\n' "${CN_RUNTIME_DIR}"
    printf 'CN_ASN_CACHE_DIR="%s"\n' "${CN_ASN_CACHE_DIR}"
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

cn_load_config_asns() {
  cn_source_config
  local raw_asn asn
  for raw_asn in ${CN_ASNS:-}; do
    asn="$(cn_normalize_asn "${raw_asn}")" || return 1
    printf 'AS%s\n' "${asn}"
  done
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
    echo "asns: ${CN_ASNS:-未配置}"
    echo "backend: ${CN_FIREWALL_BACKEND:-auto}"
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

cn_dependency_packages() {
  local backend="$1"
  case "${backend}" in
    nft) printf '%s\n' "nftables" ;;
    iptables) printf '%s\n' "iptables ipset" ;;
  esac
}

cn_install_dependencies() {
  local backend="$1"
  local packages
  packages="$(cn_dependency_packages "${backend}")"
  echo "检测到缺少 ${packages}，开始使用系统默认软件源自动安装..." >&2

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    # shellcheck disable=SC2086
    apt-get install -y ${packages}
  elif command -v dnf >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    dnf install -y ${packages}
  elif command -v yum >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    yum install -y ${packages}
  elif command -v apk >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    apk add --no-cache ${packages}
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive refresh || true
    # shellcheck disable=SC2086
    zypper --non-interactive install ${packages}
  else
    echo "未识别到 apt-get/dnf/yum/apk/zypper，无法自动安装 ${packages}。" >&2
    return 1
  fi
}

cn_require_commands() {
  local backend command_name
  backend="$(cn_effective_firewall_backend)" || exit 1
  local missing=0
  local -a required_commands=()
  case "${backend}" in
    nft) required_commands=(nft) ;;
    iptables) required_commands=(iptables ipset) ;;
  esac

  for command_name in "${required_commands[@]}"; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      echo "缺少命令：${command_name}" >&2
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    cn_install_dependencies "${backend}" || {
      echo "自动安装失败，请检查系统软件源后重试。" >&2
      exit 1
    }
  fi

  missing=0
  for command_name in "${required_commands[@]}"; do
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
