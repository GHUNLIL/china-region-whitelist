#!/usr/bin/env bash
# Sourced by firewall_lib.sh; country data remains local at runtime.
CN_ALLOWED_COUNTRIES="${CN_ALLOWED_COUNTRIES:-}"

cn_is_country_code() {
  [[ "$1" =~ ^[A-Za-z]{2}$ ]]
}

cn_normalize_country_code() {
  local code
  code="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  if ! cn_is_country_code "${code}" || ! awk -F '\t' -v code="${code}" '$1 == code {found=1} END {exit !found}' "${DATA_DIR}/countries.tsv"; then
    echo "未知国家/地区代码：$1（使用 CN、JP、US 等两位代码）" >&2
    return 1
  fi
  printf '%s\n' "${code}"
}

cn_normalize_countries() {
  local input="$1" code normalized result=""
  input="${input//,/ }"
  for code in ${input}; do
    normalized="$(cn_normalize_country_code "${code}")" || return 1
    case " ${result} " in *" ${normalized} "*) continue ;; esac
    result="${result:+${result} }${normalized}"
  done
  [[ -n "${result}" ]] || { echo '请至少选择一个国家/地区。' >&2; return 1; }
  printf '%s\n' "${result}"
}

cn_read_country_cidrs() {
  local code="$1" file
  if cn_is_all_china_selector "${code}"; then
    code=CN
    file="${CN_COUNTRY_FILE}"
  else
    code="$(cn_normalize_country_code "${code}")" || return 1
    file="${DATA_DIR}/country/${code}.txt"
  fi
  [[ -s "${file}" ]] || { echo "缺少国家级 ${code} CIDR 文件：${file}" >&2; return 1; }
  # Never let an empty, malformed, or default-route country list reach the firewall.
  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    {sub(/[[:space:]]+$/, ""); n=split($0,p,"/"); m=split(p[1],a,".");
     if(n!=2 || m!=4 || p[2]!~/^[0-9]+$/ || p[2]<1 || p[2]>32) bad=1;
     for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/ || a[i]>255) bad=1;
     lines[++count]=$0}
    END {if(bad || !count) exit 1; for(i=1;i<=count;i++) print lines[i]}
  ' "${file}" || { echo "国家级 ${code} IPv4 数据为空或格式错误。" >&2; return 1; }
}

cn_country_gate_cidrs() {
  [[ -n "${CN_ALLOWED_COUNTRIES}" ]] || return 0
  local countries code
  countries="$(cn_normalize_countries "${CN_ALLOWED_COUNTRIES}")" || return 1
  for code in ${countries}; do
    cn_read_country_cidrs "${code}" || return 1
  done
}

cn_render_nft_country_gate() {
  local prefix="${1:-}"
  [[ -n "${CN_ALLOWED_COUNTRIES}" ]] || return 0
  if [[ -z "${prefix}" ]]; then
    # Keep IPv6 neighbor discovery and error reporting, but no new IPv6 services.
    printf '    meta nfproto ipv6 meta l4proto ipv6-icmp icmpv6 type { 1, 2, 3, 4 } accept\n'
    printf '    meta nfproto ipv6 ip6 hoplimit 255 meta l4proto ipv6-icmp icmpv6 type { 133, 134, 135, 136 } accept\n'
  fi
  printf '    %smeta nfproto ipv6 reject\n' "${prefix}"
  printf '    %sip saddr != @country_allowed_v4 reject\n' "${prefix}"
}

cn_render_clear_country_ipv6() {
  local entry
  printf 'if command -v ip6tables >/dev/null 2>&1; then\n'
  for entry in INPUT FORWARD; do
    printf "ip6tables -S %s | awk '\$0 ~ / -j CN_COUNTRY_V6( |\$)/ { sub(/^-A /, \"-D \"); print \"ip6tables \" \$0 }' | sh\n" "${entry}"
  done
  printf 'ip6tables -F CN_COUNTRY_V6 2>/dev/null || true\n'
  printf 'ip6tables -X CN_COUNTRY_V6 2>/dev/null || true\n'
  printf 'fi\n'
}

cn_render_country_ipv6_guard() {
  local mode="$1" ifaces="$2" iface kind
  cn_render_clear_country_ipv6
  [[ -n "${CN_ALLOWED_COUNTRIES}" ]] || return 0
  printf 'ip6tables -N CN_COUNTRY_V6\n'
  printf 'ip6tables -A CN_COUNTRY_V6 -i lo -j ACCEPT\n'
  printf 'ip6tables -A CN_COUNTRY_V6 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n'
  for kind in 1 2 3 4; do
    printf 'ip6tables -A CN_COUNTRY_V6 -p ipv6-icmp --icmpv6-type %s -j ACCEPT\n' "${kind}"
  done
  for kind in 133 134 135 136; do
    printf 'ip6tables -A CN_COUNTRY_V6 -p ipv6-icmp --icmpv6-type %s -m hl --hl-eq 255 -j ACCEPT\n' "${kind}"
  done
  printf 'ip6tables -A CN_COUNTRY_V6 -j REJECT\n'
  printf 'ip6tables -I INPUT 1 -j CN_COUNTRY_V6\n'
  if [[ "${mode}" == "all" ]]; then
    printf 'ip6tables -I FORWARD 1 -m conntrack --ctstate DNAT -j CN_COUNTRY_V6\n'
  elif [[ "${mode}" == "selected" ]]; then
    for iface in ${ifaces}; do
      printf 'ip6tables -I FORWARD 1 -i %s -m conntrack --ctstate DNAT -j CN_COUNTRY_V6\n' "${iface}"
      printf 'ip6tables -I FORWARD 1 -o %s -m conntrack --ctstate DNAT -j CN_COUNTRY_V6\n' "${iface}"
    done
  fi
}
