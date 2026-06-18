#!/usr/bin/env bash
set -euo pipefail

PO0_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PO0_REGION_TOOL="${PO0_ROOT}/tools/region_tool.py"
REGIONS_JSON="${REGIONS_JSON:-${PO0_ROOT}/data/regions.json}"
DATA_DIR="${DATA_DIR:-${PO0_ROOT}/data}"
PO0_CHAIN_NAME="PO0_REGION_WHITELIST"
PO0_SET_NAME="po0_region_whitelist"

po0_python() {
  if command -v python3 >/dev/null 2>&1; then
    python3 "$@"
  elif command -v python >/dev/null 2>&1; then
    python "$@"
  else
    echo "未找到 python3/python，无法读取本地地区数据。" >&2
    return 127
  fi
}

po0_region_tool() {
  po0_python "${PO0_REGION_TOOL}" --regions-json "${REGIONS_JSON}" --data-dir "${DATA_DIR}" "$@"
}

po0_list_provinces() {
  po0_region_tool list-provinces
}

po0_list_cities() {
  po0_region_tool list-cities "$1"
}

po0_show_provinces() {
  po0_region_tool show-provinces
}

po0_show_cities() {
  po0_region_tool show-cities "$1"
}

po0_resolve_province() {
  po0_region_tool resolve-province "$1"
}

po0_resolve_city() {
  po0_region_tool resolve-city "$1" "$2"
}

po0_collect_cidrs() {
  po0_region_tool collect-cidrs "$@"
}

po0_render_apply_commands() {
  local client_ip="${1:-}"
  shift || true
  if [[ -n "${client_ip}" ]]; then
    po0_region_tool render-apply --client-ip "${client_ip}" "$@"
  else
    po0_region_tool render-apply "$@"
  fi
}

po0_render_clear_commands() {
  po0_region_tool render-clear
}

po0_require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "此操作需要 root 权限，请使用 sudo 或 root 用户运行。" >&2
    exit 1
  fi
}

po0_install_dependencies() {
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

po0_require_commands() {
  local missing=0
  for command_name in iptables ipset; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      echo "缺少命令：${command_name}" >&2
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    po0_install_dependencies || {
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

po0_detect_ssh_client_ip() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    awk '{print $1}' <<<"${SSH_CONNECTION}"
  else
    true
  fi
}

po0_run_rendered_commands() {
  local command_line
  while IFS= read -r command_line; do
    [[ -z "${command_line}" ]] && continue
    echo "+ ${command_line}"
    eval "${command_line}"
  done
}
