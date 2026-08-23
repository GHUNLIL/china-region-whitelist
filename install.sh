#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT}/tools/firewall_lib.sh"
source "${ROOT}/tools/ui_lib.sh"
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
                         从 GitHub 同步最新预制 IP 数据到 /var/lib/china-region-whitelist
  ./install.sh update-asn
                         重新同步已保存的 ASN 白名单并恢复规则
  ./install.sh status    查看当前托管规则和开机恢复状态
  ./install.sh clear     清除本脚本创建的规则、保存配置和 systemd 服务

说明：
  apply 会让未命中白名单的所有入站端口全部拒绝。
  默认整机托管本机 INPUT 和 DNAT 入站转发流量，包含 flvx/nftables 端口转发。
  可选择三大运营商公众接入网（近似普通家宽），并排除独立 IDC/企业专网 ASN。
  可配置全局单 IP 允许/屏蔽，以及最高优先级的单端口+IP/ASN 允许/屏蔽。
  所有端口规则同时支持 TCP、UDP 和 DNAT 原始目标端口。
  使用 flvx/nftables 转发时，建议保留默认 nft 后端；本脚本会使用独立 nft 表，不会改写 flvx 表。
  apply/dry-run 默认在进入菜单前拉取一次完整预制数据包；由 bootstrap 启动时直接使用它刚下载的完整包。
  加 --offline 可完全跳过联网；加 --update 则要求本次同步必须成功。服务器端不需要 Python。
  建议先运行 dry-run，确认省份和命令后再 apply。
EOF
}

# ---------- Menu data and compact summaries ----------

load_province_menu_options() {
  PROVINCE_MENU_LABELS=()
  PROVINCE_MENU_CODES=()
  PROVINCE_MENU_NAMES=()

  local index province_code name
  while IFS=$'\t' read -r index province_code name; do
    PROVINCE_MENU_LABELS+=("${index}. ${name}")
    PROVINCE_MENU_CODES+=("${province_code}")
    PROVINCE_MENU_NAMES+=("${name}")
  done < <(cn_list_provinces)
}

load_common_asn_menu_options() {
  COMMON_ASN_LABELS=()
  COMMON_ASN_VALUES=()

  local raw_asn provider description label
  while IFS=$'\t' read -r raw_asn provider description; do
    [[ -n "${raw_asn}" && -n "${provider}" ]] || continue
    label="${provider} — ${raw_asn}"
    [[ -n "${description}" ]] && label="${provider}（${description}）— ${raw_asn}"
    COMMON_ASN_LABELS+=("${label}")
    COMMON_ASN_VALUES+=("${raw_asn}")
  done < <(cn_list_asn_presets)
}

append_unique_selected_code() {
  local candidate="$1"
  local existing
  if cn_is_all_china_selector "${candidate}"; then
    SELECTED_CODES=("CN")
    return 0
  fi
  if ((${#SELECTED_CODES[@]} > 0)); then
    for existing in "${SELECTED_CODES[@]}"; do
      cn_is_all_china_selector "${existing}" && return 0
      [[ "${existing}" == "${candidate}" ]] && return 0
    done
  fi
  SELECTED_CODES+=("${candidate}")
}

append_unique_selected_asn() {
  local raw_asn="$1"
  local asn candidate existing
  asn="$(cn_normalize_asn "${raw_asn}")" || return 1
  candidate="AS${asn}"
  if ((${#SELECTED_ASNS[@]} > 0)); then
    for existing in "${SELECTED_ASNS[@]}"; do
      [[ "${existing}" == "${candidate}" ]] && return 0
    done
  fi
  SELECTED_ASNS+=("${candidate}")
}

codes_summary() {
  local -a codes=("$@")
  if [[ "${#codes[@]}" -eq 1 ]] && cn_is_all_china_selector "${codes[0]}"; then
    printf '全国'
  elif [[ "${#codes[@]}" -eq 1 ]] && cn_is_home_broadband_selector "${codes[0]}"; then
    printf '三大运营商家宽'
  else
    printf '%s 项' "${#codes[@]}"
  fi
}

asns_summary() {
  local -a asns=("$@")
  if [[ "${#asns[@]}" -eq 0 ]]; then
    printf '未配置'
  else
    printf '%s' "$(join_by_delim " " "${asns[@]}")"
  fi
}

port_policies_summary() {
  local -a policies=("$@")
  if [[ "${#policies[@]}" -eq 0 ]]; then
    printf '未配置'
  else
    printf '%s 条' "${#policies[@]}"
  fi
}

rule_text_summary() {
  local rules="$1"
  if [[ -n "$(cn_trim "${rules}")" ]]; then
    printf '已配置'
  else
    printf '未配置'
  fi
}

# ---------- Default source and ASN editors ----------

interactive_select_codes() {
  local -a initial_codes=("$@")
  SELECTED_CODES=()
  if visual_menu_available; then
    load_province_menu_options
    local -a menu_items
    local province_value i
    menu_items=(
      "全国（中国大陆 CN）" "CN"
      "三大运营商公众接入网（近似普通家宽）" "HOME"
    )
    for ((i = 0; i < ${#PROVINCE_MENU_LABELS[@]}; i++)); do
      menu_items+=("${PROVINCE_MENU_LABELS[$i]}" "${PROVINCE_MENU_CODES[$i]}")
    done

    visual_multi_select \
      "默认白名单（全国、家宽、具体省份可多选）" \
      0 \
      "$(join_by_delim " " "${initial_codes[@]}")" \
      "${menu_items[@]}"
    if [[ "${VISUAL_CANCELLED}" -eq 1 ]]; then
      SELECTED_CODES=("${initial_codes[@]}")
      return 1
    fi
    for province_value in "${VISUAL_SELECTED_VALUES[@]}"; do
      if [[ "${province_value}" == "CN" ]]; then
        append_unique_selected_code "CN"
      elif [[ "${province_value}" == "HOME" ]]; then
        append_unique_selected_code "HOME"
      else
        append_unique_selected_code "${province_value}"
      fi
    done
    return
  fi

  echo "请选择省/自治区/直辖市：" >&2
  cn_show_provinces >&2
  echo >&2
  echo "输入编号或省份名称，多个用空格/逗号分隔；输入 全国 表示 CN；输入 家庭宽带 表示三大运营商公众接入网。" >&2

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
      append_unique_selected_code "CN"
    elif cn_is_home_broadband_selector "${province_selector}"; then
      append_unique_selected_code "HOME"
    else
      province_code="$(cn_resolve_province "${province_selector}")"
      append_unique_selected_code "${province_code}"
    fi
  done < <(split_user_list "${province_input}")
}

interactive_select_asns() {
  local -a initial_asns=("$@")
  SELECTED_ASNS=()
  load_common_asn_menu_options
  local manual_input=0
  local asn_input asn_selector existing_asn i selected_value
  local -a menu_items
  if visual_menu_available; then
    menu_items=()
    for ((i = 0; i < ${#COMMON_ASN_LABELS[@]}; i++)); do
      menu_items+=("${COMMON_ASN_LABELS[$i]}" "${COMMON_ASN_VALUES[$i]}")
    done
    for existing_asn in "${initial_asns[@]}"; do
      if ! ui_value_in_list "${existing_asn}" "${COMMON_ASN_VALUES[@]}"; then
        menu_items+=("已配置的自定义 ASN — ${existing_asn}" "${existing_asn}")
      fi
    done
    menu_items+=("手动输入其他 ASN" "__MANUAL__")
    visual_multi_select \
      "ASN 白名单（可多选；已配置项会自动勾选）" \
      1 \
      "$(join_by_delim " " "${initial_asns[@]}")" \
      "${menu_items[@]}"
    if [[ "${VISUAL_CANCELLED}" -eq 1 ]]; then
      SELECTED_ASNS=("${initial_asns[@]}")
      return 1
    fi
    for selected_value in "${VISUAL_SELECTED_VALUES[@]}"; do
      if [[ "${selected_value}" == "__MANUAL__" ]]; then
        manual_input=1
      else
        append_unique_selected_asn "${selected_value}"
      fi
    done
    [[ "${manual_input}" -eq 0 ]] && return 0
  else
    echo >&2
    echo "可选：常用 ASN 白名单，用于国外管理机或固定云厂商入口。" >&2
    for ((i = 0; i < ${#COMMON_ASN_LABELS[@]}; i++)); do
      printf '  %d) %s\n' "$((i + 1))" "${COMMON_ASN_LABELS[$i]}" >&2
    done
    echo "输入预设编号或 ASN，多个用空格/逗号分隔；例如：1 3 AS14061。留空则不添加。" >&2
  fi

  asn_input="$(read_from_tty "常用 ASN 编号或其他 ASN（可空）: ")"
  [[ -n "${asn_input}" ]] || return 0

  while IFS= read -r asn_selector; do
    [[ -n "${asn_selector}" ]] || continue
    if [[ "${asn_selector}" =~ ^[0-9]+$ ]] && (( asn_selector >= 1 && asn_selector <= ${#COMMON_ASN_VALUES[@]} )); then
      append_unique_selected_asn "${COMMON_ASN_VALUES[$((asn_selector - 1))]}"
    else
      append_unique_selected_asn "${asn_selector}"
    fi
  done < <(split_user_list "${asn_input}")
}

# ---------- Explicit allow/deny rule editors ----------

interactive_select_global_ip_rules() {
  local initial_rules="${1:-}"
  local action_input action target candidate combined current_text done_label index i raw_rule parsed kind value
  local -a rules
  rules=()
  SELECTED_GLOBAL_IP_RULES=""
  while IFS= read -r raw_rule; do
    raw_rule="$(cn_trim "${raw_rule}")"
    [[ -n "${raw_rule}" ]] || continue
    parsed="$(cn_parse_ip_or_asn_action_rule "${raw_rule}")" || return 1
    IFS=$'\t' read -r action kind value <<<"${parsed}"
    [[ "${kind}" == "ip" ]] || return 1
    rules+=("${action}:${value}")
  done < <(cn_split_selector_list "${initial_rules}")

  while true; do
    current_text="$(join_by_comma "${rules[@]}")"
    if ((${#rules[@]} == 0)); then
      done_label="保存并返回（当前未配置）"
    else
      done_label="保存并返回（${#rules[@]} 条规则）"
    fi

    if visual_menu_available; then
      visual_single_select \
        "全局单 IP 允许/屏蔽

当前：${current_text:-未配置}" \
        "允许一个 IP" "allow" \
        "屏蔽一个 IP" "deny" \
        "删除一条已有规则" "delete" \
        "手动替换完整规则" "manual" \
        "清空全部规则" "clear" \
        "${done_label}" "done" \
        "取消，保留进入前的配置" "cancel"
      action_input="${VISUAL_SELECTED_VALUE}"
    else
      echo >&2
      echo "全局单 IP 规则（当前：${current_text:-未配置}）：" >&2
      echo "  1) 允许一个 IP" >&2
      echo "  2) 屏蔽一个 IP" >&2
      echo "  3) 完成" >&2
      echo "  4) 手动输入完整规则" >&2
      echo "  5) 删除一条规则" >&2
      echo "  6) 清空全部规则" >&2
      action_input="$(read_from_tty "请选择 [1-6]: ")"
      case "$(cn_trim "${action_input}")" in
        1|allow|ALLOW|允许|放行) action_input="allow" ;;
        2|deny|DENY|屏蔽|拒绝|禁止) action_input="deny" ;;
        3|done|DONE|完成|"") action_input="done" ;;
        4|manual|MANUAL|手动) action_input="manual" ;;
        5|delete|DELETE|删除) action_input="delete" ;;
        6|clear|CLEAR|清空) action_input="clear" ;;
        *)
          echo "无效选择，请输入 1-6。" >&2
          continue
          ;;
      esac
    fi

    case "${action_input}" in
      allow|deny)
        action="${action_input}"
        if [[ "${action}" == "allow" ]]; then
          target="$(read_from_tty "请输入要允许的单个 IPv4: ")"
        else
          target="$(read_from_tty "请输入要屏蔽的单个 IPv4: ")"
        fi
        target="$(cn_trim "${target}")"
        if [[ -z "${target}" ]]; then
          echo "未输入 IP，未添加规则。" >&2
          continue
        fi
        candidate="${action}:${target}"
        if ((${#rules[@]} > 0)); then
          combined="$(join_by_comma "${rules[@]}")","${candidate}"
        else
          combined="${candidate}"
        fi
        if ! cn_validate_global_ip_rules "${combined}"; then
          echo "IP 规则无效，未添加：${candidate}" >&2
          continue
        fi
        rules+=("${candidate}")
        printf '已添加：%s\n' "${candidate}" >&2
        ;;
      delete)
        if ((${#rules[@]} == 0)); then
          echo "当前没有可删除的全局单 IP 规则。" >&2
          if visual_menu_available; then
            pause_visual
          fi
          continue
        fi
        if visual_menu_available; then
          local -a delete_items
          delete_items=()
          for ((i = 0; i < ${#rules[@]}; i++)); do
            delete_items+=("$((i + 1)). ${rules[$i]}" "${i}")
          done
          delete_items+=("取消" "cancel")
          visual_single_select "选择要删除的全局单 IP 规则" "${delete_items[@]}"
          [[ "${VISUAL_SELECTED_VALUE}" != "cancel" ]] || continue
          index="${VISUAL_SELECTED_VALUE}"
        else
          for ((i = 0; i < ${#rules[@]}; i++)); do
            printf '  %d) %s\n' "$((i + 1))" "${rules[$i]}" >&2
          done
          index="$(read_from_tty "输入要删除的编号（留空取消）: ")"
          if ! [[ "${index}" =~ ^[0-9]+$ ]] || ((index < 1 || index > ${#rules[@]})); then
            continue
          fi
          index=$((index - 1))
        fi
        local -a next_rules
        next_rules=()
        for ((i = 0; i < ${#rules[@]}; i++)); do
          [[ "${i}" -eq "${index}" ]] || next_rules+=("${rules[$i]}")
        done
        rules=("${next_rules[@]}")
        ;;
      manual)
        echo "格式：allow:1.2.3.4,deny:5.6.7.8；也支持 +1.2.3.4,-5.6.7.8。" >&2
        combined="$(read_from_tty "完整规则（直接回车取消，输入 - 清空）: ")"
        [[ -n "$(cn_trim "${combined}")" ]] || continue
        [[ "$(cn_trim "${combined}")" != "-" ]] || {
          rules=()
          continue
        }
        if ! cn_validate_global_ip_rules "${combined}"; then
          echo "完整规则无效，未修改。" >&2
          if visual_menu_available; then
            pause_visual
          fi
          continue
        fi
        SELECTED_GLOBAL_IP_RULES="${combined}"
        return 0
        ;;
      clear)
        rules=()
        ;;
      done)
        if ((${#rules[@]} > 0)); then
          SELECTED_GLOBAL_IP_RULES="$(join_by_comma "${rules[@]}")"
        fi
        return 0
        ;;
      cancel)
        SELECTED_GLOBAL_IP_RULES="${initial_rules}"
        return 1
        ;;
    esac
  done
}

interactive_select_port_exceptions() {
  local initial_exceptions="${1:-}"
  local exceptions_input action
  if visual_menu_available; then
    visual_single_select \
      "端口 IP/ASN 例外（最高优先级）

当前：${initial_exceptions:-未配置}" \
      "手动替换完整配置" "replace" \
      "清空全部端口例外" "clear" \
      "返回，不修改" "back"
    action="${VISUAL_SELECTED_VALUE}"
    case "${action}" in
      back)
        SELECTED_PORT_EXCEPTIONS="${initial_exceptions}"
        return 1
        ;;
      clear)
        SELECTED_PORT_EXCEPTIONS=""
        return 0
        ;;
    esac
  fi
  echo >&2
  echo "可选：单端口+IP/ASN 允许/屏蔽（最高优先级，同时作用于 TCP/UDP）。" >&2
  echo "格式：22=allow:1.2.3.4,deny:AS4809;443=allow:AS4134,deny:5.6.7.8" >&2
  echo "每个端口只写一次；单 IP 比 ASN 更具体，因此优先于同端口 ASN 规则。" >&2
  if visual_menu_available; then
    exceptions_input="$(read_from_tty "输入新配置（直接回车取消）: ")"
    [[ -n "$(cn_trim "${exceptions_input}")" ]] || {
      SELECTED_PORT_EXCEPTIONS="${initial_exceptions}"
      return 1
    }
  else
    exceptions_input="$(read_from_tty "端口 IP/ASN 例外（可空）: ")"
  fi
  if ! cn_validate_port_exceptions "${exceptions_input}"; then
    echo "端口例外配置无效，未修改。" >&2
    if visual_menu_available; then
      pause_visual
    fi
    SELECTED_PORT_EXCEPTIONS="${initial_exceptions}"
    return 1
  fi
  SELECTED_PORT_EXCEPTIONS="${exceptions_input}"
}

read_manual_port_policies() {
  local prompt="${1:-端口优先白名单（可空）: }"
  local policy_input
  policy_input="$(read_from_tty "${prompt}")"
  policy_input="${policy_input//；/;}"
  [[ -n "$(cn_trim "${policy_input}")" ]] || {
    SELECTED_PORT_POLICIES=""
    return 0
  }
  cn_validate_port_policies "${policy_input}"
  SELECTED_PORT_POLICIES="${policy_input}"
}

# ---------- Port policy builders ----------

interactive_select_port_policies_line() {
  echo >&2
  echo "可选：端口优先白名单。命中端口策略时，会先按该端口自己的白名单判断。" >&2
  echo "格式：端口=白名单；多条用英文或中文分号分隔。" >&2
  echo "示例：22=上海市,AS16509,1.2.3.4/32;10000-20000=广东省,江苏省" >&2
  echo "白名单可写：全国/中国、家庭宽带、具体省份、AS12345、IPv4 或 IPv4 CIDR。留空则只使用整机默认白名单。" >&2
  read_manual_port_policies "端口优先白名单（可空）: "
}

normalize_extra_policy_selectors() {
  EXTRA_POLICY_SELECTORS=()
  local extra_input="$1"
  local selector asn
  while IFS= read -r selector; do
    selector="$(cn_trim "${selector}")"
    [[ -n "${selector}" ]] || continue
    if [[ "${selector}" =~ ^[Aa][Ss][0-9]+$ ]]; then
      asn="$(cn_normalize_asn "${selector}")"
      EXTRA_POLICY_SELECTORS+=("AS${asn}")
    elif cn_validate_ipv4_cidr "${selector}"; then
      EXTRA_POLICY_SELECTORS+=("${selector}")
    else
      echo "额外白名单只支持 ASN、IPv4 或 IPv4 CIDR：${selector}" >&2
      return 1
    fi
  done < <(split_user_list "${extra_input}")
}

append_unique_port_policy_selector() {
  local candidate="$1"
  local existing
  for existing in "${PORT_POLICY_SELECTORS[@]}"; do
    [[ "${existing}" == "${candidate}" ]] && return 0
  done
  PORT_POLICY_SELECTORS+=("${candidate}")
}

load_port_policy_editor_state() {
  local existing_policy="$1"
  PORT_POLICY_PORT=""
  PORT_POLICY_DOMESTIC_SELECTORS=()
  PORT_POLICY_EXTRA_SELECTORS=()
  [[ -n "${existing_policy}" ]] || return 0

  PORT_POLICY_PORT="$(cn_trim "${existing_policy%%=*}")"
  local selector code name asn
  while IFS= read -r selector; do
    selector="$(cn_trim "${selector}")"
    [[ -n "${selector}" ]] || continue
    if cn_is_all_china_selector "${selector}"; then
      PORT_POLICY_DOMESTIC_SELECTORS+=("全国")
    elif cn_is_home_broadband_selector "${selector}"; then
      PORT_POLICY_DOMESTIC_SELECTORS+=("HOME")
    elif [[ "${selector}" =~ ^[Aa][Ss][0-9]+$ ]]; then
      asn="$(cn_normalize_asn "${selector}")"
      PORT_POLICY_EXTRA_SELECTORS+=("AS${asn}")
    elif cn_validate_ipv4_cidr "${selector}"; then
      PORT_POLICY_EXTRA_SELECTORS+=("${selector}")
    else
      code="$(cn_resolve_province "${selector}")"
      name="$(cn_province_name "${code}")"
      PORT_POLICY_DOMESTIC_SELECTORS+=("${name}")
    fi
  done < <(cn_split_selector_list "${existing_policy#*=}")
}

build_port_policy_visual() {
  local existing_policy="${1:-}"
  PORT_POLICY_ITEM=""
  load_port_policy_editor_state "${existing_policy}"
  local port_spec extra_input selector selector_text i
  local -a menu_items selectors

  while true; do
    if [[ -n "${PORT_POLICY_PORT}" ]]; then
      port_spec="$(read_from_tty "端口或范围 [当前 ${PORT_POLICY_PORT}，回车保留，Q 取消]: ")"
      case "$(cn_trim "${port_spec}")" in
        q|Q) return 1 ;;
        "") port_spec="${PORT_POLICY_PORT}" ;;
      esac
    else
      port_spec="$(read_from_tty "端口或范围，例如 22 或 10000-20000（留空取消）: ")"
      [[ -n "$(cn_trim "${port_spec}")" ]] || return 1
    fi
    if cn_validate_port_spec "${port_spec}"; then
      break
    fi
    echo "非法端口或端口范围：${port_spec}" >&2
  done

  load_province_menu_options
  menu_items=(
    "全国（中国大陆 CN）" "全国"
    "三大运营商公众接入网（近似普通家宽）" "HOME"
  )
  for ((i = 0; i < ${#PROVINCE_MENU_LABELS[@]}; i++)); do
    menu_items+=("${PROVINCE_MENU_LABELS[$i]}" "${PROVINCE_MENU_NAMES[$i]}")
  done
  visual_multi_select \
    "端口 ${port_spec} 允许的国内来源（可空）" \
    1 \
    "$(join_by_delim " " "${PORT_POLICY_DOMESTIC_SELECTORS[@]}")" \
    "${menu_items[@]}"
  [[ "${VISUAL_CANCELLED}" -eq 0 ]] || return 1
  selectors=("${VISUAL_SELECTED_VALUES[@]}")

  if ((${#PORT_POLICY_EXTRA_SELECTORS[@]} > 0)); then
    extra_input="$(read_from_tty "额外 ASN/IP/CIDR [当前 ${PORT_POLICY_EXTRA_SELECTORS[*]}；回车保留，- 清空，Q 取消]: ")"
    case "$(cn_trim "${extra_input}")" in
      q|Q) return 1 ;;
      "") extra_input="${PORT_POLICY_EXTRA_SELECTORS[*]}" ;;
      -) extra_input="" ;;
    esac
  else
    extra_input="$(read_from_tty "额外 ASN/IP/CIDR（可空，多个用空格或逗号分隔）: ")"
    [[ "$(cn_trim "${extra_input}")" != "q" && "$(cn_trim "${extra_input}")" != "Q" ]] || return 1
  fi
  if [[ -n "$(cn_trim "${extra_input}")" ]]; then
    normalize_extra_policy_selectors "${extra_input}"
    selectors+=("${EXTRA_POLICY_SELECTORS[@]}")
  fi

  if [[ "${#selectors[@]}" -eq 0 ]]; then
    echo "端口策略至少需要一个省份、ASN、IPv4 或 CIDR 白名单。" >&2
    return 1
  fi

  PORT_POLICY_SELECTORS=()
  for selector in "${selectors[@]}"; do
    if [[ "${selector}" == "全国" ]]; then
      PORT_POLICY_SELECTORS=("全国")
      continue
    fi
    if ui_value_in_list "全国" "${PORT_POLICY_SELECTORS[@]}" && ! [[ "${selector}" =~ ^[Aa][Ss][0-9]+$ ]] && ! cn_validate_ipv4_cidr "${selector}"; then
      continue
    fi
    append_unique_port_policy_selector "${selector}"
  done
  selector_text="$(join_by_comma "${PORT_POLICY_SELECTORS[@]}")"
  PORT_POLICY_ITEM="${port_spec}=${selector_text}"
  cn_validate_port_policies "${PORT_POLICY_ITEM}"
}

interactive_select_port_policies() {
  SELECTED_PORT_POLICIES=""
  if ! visual_menu_available; then
    interactive_select_port_policies_line
    return
  fi

  local -a policies
  local done_label
  policies=()
  while true; do
    if [[ "${#policies[@]}" -eq 0 ]]; then
      done_label="完成，不添加端口优先白名单"
    else
      done_label="完成，使用已添加的 ${#policies[@]} 条端口策略"
    fi
    visual_single_select \
      "端口优先白名单" \
      "添加一条端口策略" "add" \
      "手动输入完整策略" "manual" \
      "${done_label}" "done"
    case "${VISUAL_SELECTED_VALUE}" in
      add)
        if build_port_policy_visual; then
          policies+=("${PORT_POLICY_ITEM}")
          printf '已添加：%s\n' "${PORT_POLICY_ITEM}" >&2
          read_from_tty "按回车继续..." >/dev/null
        fi
        ;;
      manual)
        read_manual_port_policies "完整端口策略（可空）: "
        return
        ;;
      done)
        if ((${#policies[@]} > 0)); then
          SELECTED_PORT_POLICIES="$(join_by_semicolon "${policies[@]}")"
        else
          SELECTED_PORT_POLICIES=""
        fi
        return
        ;;
    esac
  done
}

codes_detail() {
  local -a codes=("$@")
  local -a names
  local code name
  if [[ "${#codes[@]}" -eq 1 ]] && cn_is_all_china_selector "${codes[0]}"; then
    printf '全国'
    return
  fi
  names=()
  for code in "${codes[@]}"; do
    if cn_is_all_china_selector "${code}"; then
      name="全国"
    elif cn_is_home_broadband_selector "${code}"; then
      name="三大运营商公众接入网（近似普通家宽）"
    else
      name="$(cn_province_name "${code}")"
    fi
    names+=("${name:-${code}}")
  done
  join_by_delim " " "${names[@]}"
}

edit_global_codes_visual() {
  if interactive_select_codes "${CONFIG_CODES[@]}"; then
    CONFIG_CODES=()
    if ((${#SELECTED_CODES[@]} > 0)); then
      CONFIG_CODES=("${SELECTED_CODES[@]}")
    fi
  fi
}

edit_global_asns_visual() {
  if interactive_select_asns "${CONFIG_ASNS[@]}"; then
    CONFIG_ASNS=()
    if ((${#SELECTED_ASNS[@]} > 0)); then
      CONFIG_ASNS=("${SELECTED_ASNS[@]}")
    fi
  fi
}

edit_global_ip_rules_visual() {
  if interactive_select_global_ip_rules "${CONFIG_GLOBAL_IP_RULES}"; then
    CONFIG_GLOBAL_IP_RULES="${SELECTED_GLOBAL_IP_RULES}"
  fi
}

edit_port_exceptions_visual() {
  if interactive_select_port_exceptions "${CONFIG_PORT_EXCEPTIONS}"; then
    CONFIG_PORT_EXCEPTIONS="${SELECTED_PORT_EXCEPTIONS}"
  fi
}

set_config_port_policies_from_text() {
  local policy_text="$1"
  local raw_policy
  local -a policy_items next
  policy_text="${policy_text//；/;}"
  if [[ -z "$(cn_trim "${policy_text}")" ]]; then
    CONFIG_PORT_POLICIES=()
    return 0
  fi
  cn_validate_port_policies "${policy_text}" || return 1
  IFS=';' read -r -a policy_items <<<"${policy_text}"
  next=()
  for raw_policy in "${policy_items[@]}"; do
    raw_policy="$(cn_trim "${raw_policy}")"
    [[ -n "${raw_policy}" ]] && next+=("${raw_policy}")
  done
  CONFIG_PORT_POLICIES=()
  ((${#next[@]} == 0)) || CONFIG_PORT_POLICIES=("${next[@]}")
}

manual_edit_port_policies_visual() {
  local current input
  current="$(join_by_semicolon "${CONFIG_PORT_POLICIES[@]}")"
  printf '当前完整端口策略：%s\n' "${current:-未配置}" >&2
  input="$(read_from_tty "输入新策略；直接回车取消，输入 - 清空全部: ")"
  [[ -n "$(cn_trim "${input}")" ]] || return 0
  if [[ "$(cn_trim "${input}")" == "-" ]]; then
    CONFIG_PORT_POLICIES=()
    return 0
  fi
  if ! set_config_port_policies_from_text "${input}"; then
    echo "端口策略无效，已保留原配置。" >&2
    pause_visual
  fi
}

add_port_policy_visual() {
  if build_port_policy_visual; then
    CONFIG_PORT_POLICIES+=("${PORT_POLICY_ITEM}")
    printf '已添加：%s\n' "${PORT_POLICY_ITEM}" >&2
    pause_visual
  fi
}

choose_port_policy_index() {
  CHOSEN_PORT_POLICY_INDEX=""
  if [[ "${#CONFIG_PORT_POLICIES[@]}" -eq 0 ]]; then
    printf '当前没有端口白名单。\n' >&2
    pause_visual
    return 1
  fi

  local -a menu_items
  local i
  menu_items=()
  for ((i = 0; i < ${#CONFIG_PORT_POLICIES[@]}; i++)); do
    menu_items+=("$((i + 1)). ${CONFIG_PORT_POLICIES[$i]}" "${i}")
  done
  menu_items+=("取消" "cancel")
  visual_single_select "选择端口白名单" "${menu_items[@]}"
  [[ "${VISUAL_SELECTED_VALUE}" != "cancel" ]] || return 1
  CHOSEN_PORT_POLICY_INDEX="${VISUAL_SELECTED_VALUE}"
}

edit_port_policy_visual() {
  local index
  choose_port_policy_index || return 0
  index="${CHOSEN_PORT_POLICY_INDEX}"
  printf '正在修改：%s\n' "${CONFIG_PORT_POLICIES[$index]}" >&2
  if build_port_policy_visual "${CONFIG_PORT_POLICIES[$index]}"; then
    CONFIG_PORT_POLICIES[index]="${PORT_POLICY_ITEM}"
    printf '已修改为：%s\n' "${PORT_POLICY_ITEM}" >&2
    pause_visual
  fi
}

delete_port_policy_visual() {
  local index i
  local -a next
  choose_port_policy_index || return 0
  index="${CHOSEN_PORT_POLICY_INDEX}"
  visual_single_select \
    "确认删除端口策略

${CONFIG_PORT_POLICIES[$index]}" \
    "取消，保留该策略" "no" \
    "确认删除" "yes"
  [[ "${VISUAL_SELECTED_VALUE}" == "yes" ]] || return 0
  next=()
  for ((i = 0; i < ${#CONFIG_PORT_POLICIES[@]}; i++)); do
    [[ "${i}" -eq "${index}" ]] && continue
    next+=("${CONFIG_PORT_POLICIES[$i]}")
  done
  if ((${#next[@]} > 0)); then
    CONFIG_PORT_POLICIES=("${next[@]}")
  else
    CONFIG_PORT_POLICIES=()
  fi
  printf '已删除端口白名单。\n' >&2
  pause_visual
}

# ---------- Configuration dashboard and grouped menus ----------

forward_scope_summary() {
  local mode="$1"
  shift
  case "${mode}" in
    all) printf '本机服务 + 所有 DNAT 转发' ;;
    none) printf '仅本机服务' ;;
    selected) printf '本机服务 + 指定接口（%s）' "$(join_by_delim " " "$@")" ;;
    *) printf '未知（%s）' "${mode}" ;;
  esac
}

edit_forward_scope_visual() {
  local current_summary iface selected_mode
  local -a detected_ifaces menu_items
  current_summary="$(forward_scope_summary "${CONFIG_FORWARD_MODE}" "${CONFIG_FORWARD_IFACES[@]}")"
  VISUAL_DEFAULT_VALUE="${CONFIG_FORWARD_MODE}"
  visual_single_select \
    "入站托管范围

当前：${current_summary}" \
    "本机服务 + 所有 DNAT 入站转发（推荐）" "all" \
    "仅本机服务，不托管端口转发" "none" \
    "本机服务 + 指定接口的 DNAT 转发" "selected" \
    "返回，不修改" "back"
  selected_mode="${VISUAL_SELECTED_VALUE}"
  [[ "${selected_mode}" != "back" ]] || return 0

  if [[ "${selected_mode}" != "selected" ]]; then
    CONFIG_FORWARD_MODE="${selected_mode}"
    CONFIG_FORWARD_IFACES=()
    return 0
  fi

  detected_ifaces=()
  while IFS= read -r iface; do
    [[ -n "${iface}" && "${iface}" != "lo" ]] && detected_ifaces+=("${iface}")
  done < <(cn_list_network_interfaces)
  for iface in "${CONFIG_FORWARD_IFACES[@]}"; do
    ui_value_in_list "${iface}" "${detected_ifaces[@]}" || detected_ifaces+=("${iface}")
  done
  if ((${#detected_ifaces[@]} == 0)); then
    printf '没有检测到可选择的网络接口。\n' >&2
    pause_visual
    return 0
  fi

  menu_items=()
  for iface in "${detected_ifaces[@]}"; do
    if cn_is_tunnel_interface "${iface}"; then
      menu_items+=("${iface}（隧道接口）" "${iface}")
    else
      menu_items+=("${iface}" "${iface}")
    fi
  done
  visual_multi_select \
    "选择需要托管 DNAT 入站转发的接口" \
    0 \
    "$(join_by_delim " " "${CONFIG_FORWARD_IFACES[@]}")" \
    "${menu_items[@]}"
  [[ "${VISUAL_CANCELLED}" -eq 0 ]] || return 0
  CONFIG_FORWARD_MODE="selected"
  CONFIG_FORWARD_IFACES=("${VISUAL_SELECTED_VALUES[@]}")
}

config_editor_title() {
  local codes_text asns_text ports_text global_ip_text port_exception_text forward_text
  if [[ "${#CONFIG_CODES[@]}" -gt 0 ]]; then
    codes_text="$(codes_summary "${CONFIG_CODES[@]}")"
  else
    codes_text="未配置"
  fi
  if [[ "${#CONFIG_ASNS[@]}" -gt 0 ]]; then
    asns_text="$(asns_summary "${CONFIG_ASNS[@]}")"
  else
    asns_text="未配置"
  fi
  if [[ "${#CONFIG_PORT_POLICIES[@]}" -gt 0 ]]; then
    ports_text="$(port_policies_summary "${CONFIG_PORT_POLICIES[@]}")"
  else
    ports_text="未配置"
  fi
  global_ip_text="$(rule_text_summary "${CONFIG_GLOBAL_IP_RULES}")"
  port_exception_text="$(rule_text_summary "${CONFIG_PORT_EXCEPTIONS}")"
  forward_text="$(forward_scope_summary "${CONFIG_FORWARD_MODE}" "${CONFIG_FORWARD_IFACES[@]}")"
  cat <<EOF
白名单配置主界面

全局白名单：${codes_text}
全局 ASN：${asns_text}
托管范围：${forward_text}
全局单 IP：${global_ip_text}
端口白名单：${ports_text}
端口 IP/ASN 例外：${port_exception_text}

优先级：端口+单 IP > 端口+ASN > 端口白名单 > 全局单 IP > 全局白名单。
EOF
}

show_config_visual() {
  visual_clear_screen
  printf '当前配置\n\n' >&2
  if [[ "${#CONFIG_CODES[@]}" -gt 0 ]]; then
    printf '全局白名单：%s\n' "$(codes_detail "${CONFIG_CODES[@]}")" >&2
  else
    printf '全局白名单：未配置\n' >&2
  fi
  if [[ "${#CONFIG_ASNS[@]}" -gt 0 ]]; then
    printf '全局 ASN：%s\n' "$(asns_summary "${CONFIG_ASNS[@]}")" >&2
  else
    printf '全局 ASN：未配置\n' >&2
  fi
  printf '托管范围：%s\n' "$(forward_scope_summary "${CONFIG_FORWARD_MODE}" "${CONFIG_FORWARD_IFACES[@]}")" >&2
  printf '全局单 IP 允许/屏蔽：%s\n' "${CONFIG_GLOBAL_IP_RULES:-未配置}" >&2
  if [[ "${#CONFIG_PORT_POLICIES[@]}" -gt 0 ]]; then
    printf '端口白名单：\n' >&2
    local i
    for ((i = 0; i < ${#CONFIG_PORT_POLICIES[@]}; i++)); do
      printf '  %d. %s\n' "$((i + 1))" "${CONFIG_PORT_POLICIES[$i]}" >&2
    done
  else
    printf '端口白名单：未配置\n' >&2
  fi
  printf '端口 IP/ASN 例外：%s\n' "${CONFIG_PORT_EXCEPTIONS:-未配置}" >&2
  printf '\n优先级：端口+单 IP > 端口+ASN > 端口白名单 > 全局单 IP > 全局白名单。\n' >&2
  pause_visual
}

port_rules_menu_visual() {
  local title
  while true; do
    if ((${#CONFIG_PORT_POLICIES[@]} > 0)); then
      title="端口白名单

当前共 ${#CONFIG_PORT_POLICIES[@]} 条：$(join_by_semicolon "${CONFIG_PORT_POLICIES[@]}")"
    else
      title="端口白名单

当前未配置；未单独配置的端口使用全局白名单。"
    fi
    visual_single_select \
      "${title}" \
      "新增端口白名单" "add" \
      "修改端口白名单" "edit" \
      "删除端口白名单" "delete" \
      "手动编辑全部端口白名单" "manual" \
      "返回主菜单" "back"
    case "${VISUAL_SELECTED_VALUE}" in
      add) add_port_policy_visual ;;
      edit) edit_port_policy_visual ;;
      delete) delete_port_policy_visual ;;
      manual) manual_edit_port_policies_visual ;;
      back) return 0 ;;
    esac
  done
}

advanced_rules_menu_visual() {
  while true; do
    visual_single_select \
      "高级允许/屏蔽规则

全局单 IP：$(rule_text_summary "${CONFIG_GLOBAL_IP_RULES}")
端口 IP/ASN 例外：$(rule_text_summary "${CONFIG_PORT_EXCEPTIONS}")

端口例外优先级最高，请谨慎配置。" \
      "编辑全局单 IP 允许/屏蔽" "global_ip" \
      "编辑端口 IP/ASN 例外（最高优先级）" "port_exceptions" \
      "查看完整配置和优先级" "view" \
      "返回主菜单" "back"
    case "${VISUAL_SELECTED_VALUE}" in
      global_ip) edit_global_ip_rules_visual ;;
      port_exceptions) edit_port_exceptions_visual ;;
      view) show_config_visual ;;
      back) return 0 ;;
    esac
  done
}

confirm_clear_rules_visual() {
  visual_single_select \
    "确认清理本脚本已应用的规则和开机配置" \
    "取消，返回主界面" "no" \
    "清理规则、保存配置和 systemd 服务" "yes"
  [[ "${VISUAL_SELECTED_VALUE}" == "yes" ]]
}

update_region_data_visual() {
  visual_clear_screen
  printf '同步最新预制 IP 数据\n\n' >&2
  printf '将从 GitHub 仓库下载已预制好的 data/ 数据包。\n' >&2
  printf '服务器端不需要 Python；全国、省份和预制 ASN 数据由仓库定时生成。\n\n' >&2
  if [[ "${EUID}" -ne 0 ]]; then
    printf '此操作需要 root 权限，请使用 sudo 或 root 用户运行。\n' >&2
    pause_visual
    return 0
  fi
  if prepare_data_for_mode required; then
    printf '\n数据已同步到：%s/data\n' "${CN_RUNTIME_DIR}" >&2
  else
    printf '\n同步失败。请确认服务器可以访问 GitHub 或已设置可用的 CN_GITHUB_PROXY。\n' >&2
  fi
  pause_visual
}

load_saved_config_into_editor() {
  local item saved_ports
  CONFIG_GLOBAL_IP_RULES=""
  CONFIG_PORT_EXCEPTIONS=""
  CONFIG_FORWARD_MODE="${CN_FORWARD_MODE_DEFAULT:-all}"
  CONFIG_FORWARD_IFACES=()
  CONFIG_CODES=()
  CONFIG_ASNS=()
  CONFIG_PORT_POLICIES=()
  [[ -r "${CN_CONFIG_FILE}" ]] || return 0

  while IFS= read -r item; do
    [[ -n "${item}" ]] && CONFIG_CODES+=("${item}")
  done < <(cn_load_config_codes 2>/dev/null || true)

  while IFS= read -r item; do
    [[ -n "${item}" ]] && CONFIG_ASNS+=("${item}")
  done < <(cn_load_config_asns 2>/dev/null || true)

  saved_ports="$(cn_load_config_port_policies 2>/dev/null || true)"
  if [[ -n "$(cn_trim "${saved_ports}")" ]]; then
    if ! set_config_port_policies_from_text "${saved_ports}" 2>/dev/null; then
      CONFIG_PORT_POLICIES=()
    fi
  fi
  CONFIG_GLOBAL_IP_RULES="$(cn_load_config_global_ip_rules 2>/dev/null || true)"
  CONFIG_PORT_EXCEPTIONS="$(cn_load_config_port_exceptions 2>/dev/null || true)"
  CONFIG_FORWARD_MODE="$(cn_load_config_forward_mode 2>/dev/null || printf 'all\n')"
  while IFS= read -r item; do
    [[ -n "${item}" ]] && CONFIG_FORWARD_IFACES+=("${item}")
  done < <(cn_load_config_forward_ifaces 2>/dev/null || true)
}

maintenance_menu_visual() {
  local dry_run="$1"
  while true; do
    if [[ "${dry_run}" == "1" ]]; then
      visual_single_select \
        "维护工具" \
        "重新载入已保存配置" "reload" \
        "同步最新预制 IP 数据" "update_data" \
        "返回主菜单" "back"
    else
      visual_single_select \
        "维护工具" \
        "重新载入已保存配置" "reload" \
        "同步最新预制 IP 数据" "update_data" \
        "清理已应用规则和开机配置" "clear_applied" \
        "返回主菜单" "back"
    fi
    case "${VISUAL_SELECTED_VALUE}" in
      reload)
        if [[ ! -r "${CN_CONFIG_FILE}" ]]; then
          printf '当前没有已保存配置：%s\n' "${CN_CONFIG_FILE}" >&2
          pause_visual
          continue
        fi
        visual_single_select \
          "重新载入已保存配置会放弃当前未应用的草案。" \
          "取消" "no" \
          "确认重新载入" "yes"
        if [[ "${VISUAL_SELECTED_VALUE}" == "yes" ]]; then
          load_saved_config_into_editor
          printf '已重新载入保存配置。\n' >&2
          pause_visual
        fi
        ;;
      update_data) update_region_data_visual ;;
      clear_applied)
        if confirm_clear_rules_visual; then
          clear_rules
          exit 0
        fi
        ;;
      back) return 0 ;;
    esac
  done
}

interactive_config_editor() {
  local dry_run="${1:-0}"
  CONFIG_CODES=()
  CONFIG_ASNS=()
  CONFIG_PORT_POLICIES=()
  CONFIG_GLOBAL_IP_RULES=""
  CONFIG_PORT_EXCEPTIONS=""
  CONFIG_FORWARD_MODE="${CN_FORWARD_MODE_DEFAULT:-all}"
  CONFIG_FORWARD_IFACES=()
  load_saved_config_into_editor

  local done_label title
  while true; do
    title="$(config_editor_title)"
    if [[ "${dry_run}" == "1" ]]; then
      done_label="完成配置并预览规则"
    else
      done_label="完成配置并进入应用确认"
    fi
    visual_single_select \
      "${title}" \
      "编辑默认白名单（全国/家宽/省份）" "edit_global" \
      "编辑 ASN 白名单（常用预设/自定义）" "edit_asn" \
      "编辑入站托管范围" "edit_forward" \
      "管理端口白名单" "ports" \
      "管理高级允许/屏蔽规则" "advanced" \
      "查看当前完整配置" "view" \
      "维护工具" "maintenance" \
      "${done_label}" "done"
    case "${VISUAL_SELECTED_VALUE}" in
      edit_global)
        edit_global_codes_visual
        ;;
      edit_asn)
        edit_global_asns_visual
        ;;
      edit_forward) edit_forward_scope_visual ;;
      ports) port_rules_menu_visual ;;
      advanced) advanced_rules_menu_visual ;;
      view)
        show_config_visual
        ;;
      maintenance) maintenance_menu_visual "${dry_run}" ;;
      done)
        if [[ "${#CONFIG_CODES[@]}" -eq 0 ]]; then
          printf '请先配置全局白名单，至少选择家宽、一个省份或全国。\n' >&2
          pause_visual
          continue
        fi
        SELECTED_CODES=("${CONFIG_CODES[@]}")
        SELECTED_ASNS=()
        if ((${#CONFIG_ASNS[@]} > 0)); then
          SELECTED_ASNS=("${CONFIG_ASNS[@]}")
        fi
        if ((${#CONFIG_PORT_POLICIES[@]} > 0)); then
          SELECTED_PORT_POLICIES="$(join_by_semicolon "${CONFIG_PORT_POLICIES[@]}")"
        else
          SELECTED_PORT_POLICIES=""
        fi
        SELECTED_GLOBAL_IP_RULES="${CONFIG_GLOBAL_IP_RULES}"
        SELECTED_PORT_EXCEPTIONS="${CONFIG_PORT_EXCEPTIONS}"
        SELECTED_FORWARD_MODE="${CONFIG_FORWARD_MODE}"
        SELECTED_FORWARD_IFACES=("${CONFIG_FORWARD_IFACES[@]}")
        return
        ;;
    esac
  done
}

# ---------- Forward scope, confirmations and execution ----------

append_unique_forward_iface() {
  local candidate="$1"
  local existing
  if ((${#SELECTED_FORWARD_IFACES[@]} > 0)); then
    for existing in "${SELECTED_FORWARD_IFACES[@]}"; do
      [[ "${existing}" == "${candidate}" ]] && return 0
    done
  fi
  SELECTED_FORWARD_IFACES+=("${candidate}")
}

interactive_select_forward_interfaces() {
  SELECTED_FORWARD_MODE="${CN_FORWARD_MODE_DEFAULT:-all}"
  SELECTED_FORWARD_IFACES=()
  case "${SELECTED_FORWARD_MODE}" in
    all|"")
      SELECTED_FORWARD_MODE="all"
      echo >&2
      echo "整机白名单范围：本机服务 INPUT + DNAT 入站转发流量（包含 flvx/nftables 端口转发）。" >&2
      ;;
    none)
      echo >&2
      echo "整机白名单范围：仅本机服务 INPUT，不托管 DNAT 入站转发。" >&2
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
      echo "整机白名单范围：本机服务 INPUT + 指定接口的 DNAT 入站转发 ${SELECTED_FORWARD_IFACES[*]}。" >&2
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
    all) echo "转发托管：所有 DNAT 入站转发流量" ;;
    none) echo "转发托管：关闭，仅限制本机入站端口" ;;
    selected) echo "转发托管：指定接口 ${ifaces} 的 DNAT 入站转发" ;;
    *) echo "转发托管：未知模式 ${mode}" ;;
  esac
}

confirm_client_ip() {
  local client_ip="$1"
  if [[ -z "${client_ip}" ]]; then
    echo ""
    return
  fi

  if visual_menu_available; then
    visual_single_select \
      "检测到当前 SSH 客户端 IP：${client_ip}" \
      "加入本次白名单，避免断连" "yes" \
      "不加入" "no"
    [[ "${VISUAL_SELECTED_VALUE}" == "yes" ]] && echo "${client_ip}" || echo ""
    return
  fi

  echo "检测到当前 SSH 客户端 IP：${client_ip}" >&2
  read -r -p "是否临时加入本次白名单以避免断连？[Y/n] " answer
  case "${answer:-Y}" in
    y|Y|yes|YES) echo "${client_ip}" ;;
    *) echo "" ;;
  esac
}

confirm_apply_rules() {
  local summary="${1:-}"
  echo "即将应用规则：未命中白名单的所有入站端口都会被拒绝。"
  if visual_menu_available; then
    visual_single_select \
      "确认应用防火墙规则

${summary}

未命中白名单的新入站连接将被拒绝。" \
      "取消，不应用规则" "no" \
      "应用规则" "yes"
    [[ "${VISUAL_SELECTED_VALUE}" == "yes" ]]
    return
  fi

  local confirm
  read -r -p "确认继续？输入 YES/yes/y: " confirm
  is_yes_confirmation "${confirm}"
}

normalize_confirmation_input() {
  local value="${1:-}"
  local sequence
  # SSH terminals can leave cursor-key bytes in the input queue, while pasted
  # text may be wrapped in bracketed-paste markers. They are invisible on
  # screen but would otherwise turn a visible "y" into a rejected value.
  for sequence in \
    $'\x1b[A' $'\x1b[B' $'\x1b[C' $'\x1b[D' \
    $'\x1bOA' $'\x1bOB' $'\x1bOC' $'\x1bOD' \
    $'\x1b[H' $'\x1b[F' $'\x1bOH' $'\x1bOF' \
    $'\x1b[200~' $'\x1b[201~'; do
    value="${value//"${sequence}"/}"
  done
  value="${value//$'\r'/}"
  cn_trim "${value}"
}

is_yes_confirmation() {
  case "$(normalize_confirmation_input "${1:-}")" in
    YES|yes|Y|y) return 0 ;;
    *) return 1 ;;
  esac
}

confirm_post_apply_rules() {
  [[ "${CN_POST_APPLY_CONFIRM:-1}" != "0" ]] || return 0
  [[ -r /dev/tty && ( -t 0 || -t 2 ) ]] || return 0

  local timeout="${CN_POST_APPLY_TIMEOUT:-60}"
  local confirm=""
  visual_discard_pending_input
  echo
  echo "规则已临时应用。请立刻用新窗口测试 SSH/业务端口。"
  echo "如果 ${timeout} 秒内没有输入 YES/yes/y，脚本会自动清理本次规则，避免锁死。"
  if ! IFS= read -r -t "${timeout}" -p "确认新连接可访问并保存开机恢复？输入 YES/yes/y: " confirm < /dev/tty; then
    echo >&2
    echo "确认等待超时或终端输入已关闭。" >&2
    return 1
  fi
  if ! is_yes_confirmation "${confirm}"; then
    echo "确认内容无效；仅接受 YES、yes、Y 或 y。" >&2
    return 1
  fi
  return 0
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
      echo "启动预载：正在拉取完整预制数据包（全国、省份、家宽和全部内置 ASN）..." >&2
      cn_update_runtime_data
      ;;
    optional)
      if [[ "${EUID}" -ne 0 ]]; then
        echo "当前不是 root，跳过启动联网更新，使用随脚本提供的完整数据包。" >&2
      else
        echo "启动预载：正在拉取完整预制数据包（全国、省份、家宽和全部内置 ASN）..." >&2
        if ! cn_update_runtime_data; then
          echo "同步 GitHub 预制数据失败，将使用本机完整数据包继续。" >&2
        fi
      fi
      ;;
    offline)
      if [[ "${CN_BOOTSTRAP_DATA_READY:-0}" != "1" ]]; then
        cn_use_runtime_data_if_available || true
      fi
      ;;
    *)
      echo "未知更新模式：${mode}" >&2
      exit 2
      ;;
  esac

  cn_validate_prebuilt_data_dir "${DATA_DIR}"
  echo "本地预制数据已就绪：地区、家宽及全部内置 ASN；菜单和应用阶段不再临时下载这些 ASN。" >&2
}

run_apply_or_dry_run() {
  local dry_run="$1"
  local update_mode="$2"
  local -a selected_codes
  local -a selected_asns
  local -a selected_forward_ifaces
  local selected_forward_mode selected_forward_ifaces_text selected_asns_text selected_port_policies
  local final_summary selected_global_ip_rules selected_port_exceptions
  prepare_data_for_mode "${update_mode}"
  SELECTED_CODES=()
  SELECTED_ASNS=()
  SELECTED_PORT_POLICIES=""
  SELECTED_GLOBAL_IP_RULES=""
  SELECTED_PORT_EXCEPTIONS=""
  SELECTED_FORWARD_MODE=""
  SELECTED_FORWARD_IFACES=()
  if visual_menu_available; then
    interactive_config_editor "${dry_run}"
  else
    interactive_select_codes
    interactive_select_asns
    interactive_select_port_policies
    interactive_select_global_ip_rules
    interactive_select_port_exceptions
    interactive_select_forward_interfaces
  fi

  selected_codes=()
  if ((${#SELECTED_CODES[@]} > 0)); then
    selected_codes=("${SELECTED_CODES[@]}")
  fi
  if [[ "${#selected_codes[@]}" -eq 0 ]]; then
    echo "未选择任何全局白名单。" >&2
    exit 1
  fi
  selected_asns=()
  if ((${#SELECTED_ASNS[@]} > 0)); then
    selected_asns=("${SELECTED_ASNS[@]}")
  fi
  selected_asns_text=""
  if ((${#selected_asns[@]} > 0)); then
    selected_asns_text="${selected_asns[*]}"
  fi
  selected_port_policies="${SELECTED_PORT_POLICIES}"
  selected_global_ip_rules="${SELECTED_GLOBAL_IP_RULES}"
  selected_port_exceptions="${SELECTED_PORT_EXCEPTIONS}"
  CN_GLOBAL_IP_RULES="${selected_global_ip_rules}"
  CN_PORT_EXCEPTIONS="${selected_port_exceptions}"
  selected_forward_mode="${SELECTED_FORWARD_MODE}"
  selected_forward_ifaces=()
  if ((${#SELECTED_FORWARD_IFACES[@]} > 0)); then
    selected_forward_ifaces=("${SELECTED_FORWARD_IFACES[@]}")
  fi
  selected_forward_ifaces_text=""
  if ((${#selected_forward_ifaces[@]} > 0)); then
    selected_forward_ifaces_text="${selected_forward_ifaces[*]}"
  fi

  local client_ip
  client_ip="$(confirm_client_ip "$(cn_detect_ssh_client_ip)")"

  final_summary="默认白名单：$(codes_detail "${selected_codes[@]}")
ASN 白名单：${selected_asns_text:-未配置}
托管范围：$(forward_scope_summary "${selected_forward_mode}" "${selected_forward_ifaces[@]}")
端口白名单：${selected_port_policies:-未配置}
全局单 IP：${selected_global_ip_rules:-未配置}
端口 IP/ASN 例外：${selected_port_exceptions:-未配置}
SSH 临时白名单：${client_ip:-未加入}
防火墙后端：$(cn_effective_firewall_backend)"
  printf '\n配置预览\n\n%s\n\n' "${final_summary}"

  if [[ "${dry_run}" == "1" ]]; then
    cn_render_apply_commands "${client_ip}" "${selected_forward_mode}" "${selected_forward_ifaces_text}" "${selected_asns_text}" "${selected_port_policies}" "${selected_codes[@]}"
    return
  fi

  cn_require_root
  cn_require_commands
  if ! confirm_apply_rules "${final_summary}"; then
    echo "已取消。"
    exit 0
  fi
  cn_render_apply_commands "${client_ip}" "${selected_forward_mode}" "${selected_forward_ifaces_text}" "${selected_asns_text}" "${selected_port_policies}" "${selected_codes[@]}" | cn_run_rendered_commands
  if ! confirm_post_apply_rules; then
    echo "未确认新连接可访问，正在自动清理本次规则。"
    cn_disable_systemd_service
    cn_render_best_effort_clear_commands | cn_run_rendered_commands
    exit 1
  fi
  cn_save_config "${selected_forward_mode}" "${selected_forward_ifaces_text}" "${selected_asns_text}" "${selected_port_policies}" "${selected_codes[@]}"
  cn_install_systemd_service
  echo "规则已应用。"
  echo "已保存白名单配置，重启后会由 ${CN_SERVICE_NAME} 自动恢复。"
}

restore_rules() {
  local update_mode="$1"
  local -a saved_codes
  local -a saved_asns
  local -a saved_forward_ifaces
  local saved_forward_mode saved_forward_ifaces_text saved_asns_text saved_port_policies saved_global_ip_rules saved_port_exceptions
  cn_require_root
  cn_source_config
  cn_require_commands
  prepare_data_for_mode "${update_mode}"

  saved_codes=()
  while IFS= read -r code; do
    [[ -n "${code}" ]] && saved_codes+=("${code}")
  done < <(cn_load_config_codes)

  if [[ "${#saved_codes[@]}" -eq 0 ]]; then
    echo "配置文件中没有全局白名单代码。" >&2
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
  saved_global_ip_rules="$(cn_load_config_global_ip_rules)"
  saved_port_exceptions="$(cn_load_config_port_exceptions)"
  CN_GLOBAL_IP_RULES="${saved_global_ip_rules}"
  CN_PORT_EXCEPTIONS="${saved_port_exceptions}"
  if [[ -n "${saved_port_policies}" ]]; then
    CN_ASN_OFFLINE="${CN_ASN_OFFLINE:-1}"
  fi
  if [[ -n "${saved_port_exceptions}" ]]; then
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
  if [[ -n "${saved_global_ip_rules}" ]]; then
    echo "已加载全局单 IP 规则：${saved_global_ip_rules}"
  fi
  if [[ -n "${saved_port_exceptions}" ]]; then
    echo "已加载端口 IP/ASN 例外：${saved_port_exceptions}"
  fi
  describe_forward_selection "${saved_forward_mode}" "${saved_forward_ifaces_text}"
}

update_asn_rules() {
  local -a saved_asns
  local asn saved_port_policies saved_port_exceptions
  cn_require_root
  saved_asns=()
  while IFS= read -r asn; do
    [[ -n "${asn}" ]] && saved_asns+=("${asn}")
  done < <(cn_load_config_asns)
  saved_port_policies="$(cn_load_config_port_policies)"
  saved_port_exceptions="$(cn_load_config_port_exceptions)"
  while IFS= read -r asn; do
    [[ -n "${asn}" ]] && saved_asns+=("${asn}")
  done < <(cn_list_asns_from_port_policies "${saved_port_policies}")
  while IFS= read -r asn; do
    [[ -n "${asn}" ]] && saved_asns+=("${asn}")
  done < <(cn_list_asns_from_port_exceptions "${saved_port_exceptions}")
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
  echo "== managed ipsets: ${CN_SET_NAME}* =="
  if command -v ipset >/dev/null 2>&1; then
    local managed_set
    while IFS= read -r managed_set; do
      [[ -n "${managed_set}" ]] || continue
      ipset list "${managed_set}" 2>/dev/null || true
    done < <(ipset list -name 2>/dev/null | awk -v base="${CN_SET_NAME}" '$0 == base || index($0, base "_") == 1')
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
  cn_disable_systemd_service
  cn_render_best_effort_clear_commands | cn_run_rendered_commands
  echo "已清除本脚本管理的规则。"
  echo "如仍无法访问，请在控制台执行：nft list table inet ${CN_NFT_TABLE}"
}

main() {
  local command="${1:-apply}"
  local startup_update_mode="optional"
  shift || true
  if [[ "${CN_BOOTSTRAP_DATA_READY:-0}" == "1" ]]; then
    startup_update_mode="offline"
  fi
  case "${command}" in
    apply)
      parse_update_mode "${startup_update_mode}" "$@"
      run_apply_or_dry_run 0 "${UPDATE_MODE}"
      ;;
    dry-run)
      parse_update_mode "${startup_update_mode}" "$@"
      run_apply_or_dry_run 1 "${UPDATE_MODE}"
      ;;
    restore)
      parse_update_mode offline "$@"
      restore_rules "${UPDATE_MODE}"
      ;;
    update-data)
      parse_update_mode required "$@"
      prepare_data_for_mode "${UPDATE_MODE}"
      echo "数据已同步到：${CN_RUNTIME_DIR}/data"
      ;;
    update-asn) update_asn_rules ;;
    status) status_rules ;;
    clear) clear_rules ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
