#!/usr/bin/env bash
# shellcheck disable=SC2034 # Selection results are consumed by the sourcing script.

# Generic terminal UI helpers shared by the installer. Feature-specific state
# and firewall decisions stay in install.sh and firewall_lib.sh.

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
  if [[ "${CN_READ_FROM_STDIN:-0}" != "1" && -r /dev/tty && ( -t 0 || -t 2 ) ]]; then
    read -r -p "${prompt}" value < /dev/tty
  else
    printf '%s' "${prompt}" >&2
    read -r value <&3 || value=""
  fi
  printf '%s\n' "${value}"
}

join_by_delim() {
  local delim="$1"
  shift
  local out="" item
  for item in "$@"; do
    [[ -n "${item}" ]] || continue
    if [[ -z "${out}" ]]; then
      out="${item}"
    else
      out+="${delim}${item}"
    fi
  done
  printf '%s\n' "${out}"
}

join_by_comma() {
  join_by_delim "," "$@"
}

join_by_semicolon() {
  join_by_delim ";" "$@"
}

ui_value_in_list() {
  local wanted="$1"
  shift
  local value
  for value in "$@"; do
    [[ "${value}" == "${wanted}" ]] && return 0
  done
  return 1
}

visual_menu_available() {
  [[ "${CN_VISUAL_MENU:-1}" != "0" && -r /dev/tty && ( -t 0 || -t 2 ) && "${TERM:-}" != "dumb" ]]
}

visual_clear_screen() {
  printf '\033[H\033[J' >&2
}

visual_read_key() {
  local key rest
  IFS= read -rsn1 key < /dev/tty || key=""
  if [[ "${key}" == $'\x1b' ]]; then
    IFS= read -rsn2 -t 1 rest < /dev/tty || rest=""
    key+="${rest}"
  fi
  printf '%s' "${key}"
}

visual_cancel_value() {
  local -a values=("$@")
  local wanted value
  for wanted in back cancel no skip; do
    for value in "${values[@]}"; do
      if [[ "${value}" == "${wanted}" ]]; then
        printf '%s\n' "${value}"
        return 0
      fi
    done
  done
  return 1
}

# Usage: visual_multi_select TITLE ALLOW_EMPTY "PRESELECTED VALUES" LABEL VALUE ...
visual_multi_select() {
  local title="$1"
  local allow_empty="$2"
  local preselected_text="$3"
  shift 3
  VISUAL_SELECTED_VALUES=()
  VISUAL_SELECTED_LABELS=()
  VISUAL_CANCELLED=0

  local -a labels values checked preselected
  local label value
  read -r -a preselected <<<"${preselected_text}"
  while (($# > 0)); do
    label="$1"
    value="$2"
    labels+=("${label}")
    values+=("${value}")
    if ui_value_in_list "${value}" "${preselected[@]}"; then
      checked+=(1)
    else
      checked+=(0)
    fi
    shift 2
  done

  local current=0
  local key selected_count i cursor mark
  while true; do
    visual_clear_screen
    printf '%s\n' "${title}" >&2
    printf '上/下键移动，空格勾选，回车保存。A 全选，C 清空，Esc/Q 取消。\n\n' >&2
    for ((i = 0; i < ${#labels[@]}; i++)); do
      cursor=" "
      [[ "${i}" -eq "${current}" ]] && cursor=">"
      mark="[ ]"
      [[ "${checked[$i]}" -eq 1 ]] && mark="[x]"
      printf '%s %s %s\n' "${cursor}" "${mark}" "${labels[$i]}" >&2
    done

    key="$(visual_read_key)"
    case "${key}" in
      $'\x1b[A'|k|K)
        current=$(((current + ${#labels[@]} - 1) % ${#labels[@]}))
        ;;
      $'\x1b[B'|j|J)
        current=$(((current + 1) % ${#labels[@]}))
        ;;
      " ")
        if [[ "${checked[$current]}" -eq 1 ]]; then
          checked[current]=0
        else
          checked[current]=1
        fi
        ;;
      a|A)
        for ((i = 0; i < ${#checked[@]}; i++)); do
          checked[i]=1
        done
        ;;
      c|C)
        for ((i = 0; i < ${#checked[@]}; i++)); do
          checked[i]=0
        done
        ;;
      q|Q|$'\x1b')
        VISUAL_CANCELLED=1
        visual_clear_screen
        return 0
        ;;
      "")
        selected_count=0
        for ((i = 0; i < ${#checked[@]}; i++)); do
          [[ "${checked[$i]}" -eq 1 ]] && selected_count=$((selected_count + 1))
        done
        if [[ "${selected_count}" -eq 0 && "${allow_empty}" != "1" ]]; then
          printf '\n至少选择一项，按任意键继续。' >&2
          IFS= read -rsn1 _ < /dev/tty || true
          continue
        fi
        for ((i = 0; i < ${#checked[@]}; i++)); do
          if [[ "${checked[$i]}" -eq 1 ]]; then
            VISUAL_SELECTED_VALUES+=("${values[$i]}")
            VISUAL_SELECTED_LABELS+=("${labels[$i]}")
          fi
        done
        visual_clear_screen
        return 0
        ;;
    esac
  done
}

visual_single_select() {
  local title="$1"
  shift
  VISUAL_SELECTED_VALUE=""

  local -a labels values
  while (($# > 0)); do
    labels+=("$1")
    values+=("$2")
    shift 2
  done

  local current=0
  local key i cursor cancel_value
  if [[ -n "${VISUAL_DEFAULT_VALUE:-}" ]]; then
    for ((i = 0; i < ${#values[@]}; i++)); do
      if [[ "${values[$i]}" == "${VISUAL_DEFAULT_VALUE}" ]]; then
        current="${i}"
        break
      fi
    done
  fi
  VISUAL_DEFAULT_VALUE=""
  cancel_value="$(visual_cancel_value "${values[@]}" 2>/dev/null || true)"

  while true; do
    visual_clear_screen
    printf '%s\n' "${title}" >&2
    if [[ -n "${cancel_value}" ]]; then
      printf '上/下键移动，回车确认，Esc/Q 返回。\n\n' >&2
    else
      printf '上/下键移动，回车确认。\n\n' >&2
    fi
    for ((i = 0; i < ${#labels[@]}; i++)); do
      cursor=" "
      [[ "${i}" -eq "${current}" ]] && cursor=">"
      printf '%s %s\n' "${cursor}" "${labels[$i]}" >&2
    done

    key="$(visual_read_key)"
    case "${key}" in
      $'\x1b[A'|k|K)
        current=$(((current + ${#labels[@]} - 1) % ${#labels[@]}))
        ;;
      $'\x1b[B'|j|J)
        current=$(((current + 1) % ${#labels[@]}))
        ;;
      q|Q|$'\x1b')
        [[ -n "${cancel_value}" ]] || continue
        VISUAL_SELECTED_VALUE="${cancel_value}"
        visual_clear_screen
        return 0
        ;;
      ""|" ")
        VISUAL_SELECTED_VALUE="${values[$current]}"
        visual_clear_screen
        return 0
        ;;
    esac
  done
}

pause_visual() {
  local message="${1:-按回车返回...}"
  read_from_tty "${message}" >/dev/null
}
