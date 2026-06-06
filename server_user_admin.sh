#!/usr/bin/env bash

set -u
set -o pipefail

SUDOERS_DIR="/etc/sudoers.d"
MANAGED_SUDOERS_PREFIX="90-user-"
OS_ID=""
OS_NAME=""
SUDO_GROUP=""

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

warn() {
  printf '警告：%s\n' "$*" >&2
}

info() {
  printf '%s\n' "$*"
}

pause() {
  printf '\n按回车继续... '
  read -r _
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 执行本脚本"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

detect_supported_os() {
  if [ ! -r /etc/os-release ]; then
    die "无法读取 /etc/os-release。本脚本仅支持 Ubuntu 和 CentOS"
  fi

  . /etc/os-release

  OS_ID="${ID:-}"
  OS_NAME="${PRETTY_NAME:-$OS_ID}"

  case "$OS_ID" in
    ubuntu)
      SUDO_GROUP="sudo"
      ;;
    centos)
      SUDO_GROUP="wheel"
      ;;
    *)
      die "当前系统不支持：${OS_NAME:-unknown}。本脚本仅支持 Ubuntu 和 CentOS"
      ;;
  esac

  if ! getent group "$SUDO_GROUP" >/dev/null; then
    die "当前系统缺少 $SUDO_GROUP 组，无法管理 sudo 权限"
  fi

  info "当前系统：$OS_NAME"
  info "sudo 管理组：$SUDO_GROUP"
}

validate_username() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z_][A-Za-z0-9_-]{0,31}$'
}

user_exists() {
  getent passwd "$1" >/dev/null
}

user_uid() {
  getent passwd "$1" | awk -F: '{print $3}'
}

user_home() {
  getent passwd "$1" | awk -F: '{print $6}'
}

user_shell() {
  getent passwd "$1" | awk -F: '{print $7}'
}

primary_group() {
  id -gn "$1" 2>/dev/null || true
}

is_regular_user() {
  local user="$1"
  local uid

  uid="$(user_uid "$user")"
  [ -n "$uid" ] || return 1
  [ "$user" != "root" ] || return 1
  [ "$user" != "nobody" ] || return 1
  [ "$uid" -ge 1000 ] || return 1
  [ "$uid" -ne 65534 ] || return 1
}

is_user_in_group() {
  local user="$1"
  local group="$2"

  id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"
}

clear_screen() {
  printf '\033[2J\033[H' >&2
}

select_menu() {
  local title="$1"
  shift

  local -a options=("$@")
  local selected=0
  local count="${#options[@]}"
  local key
  local rest
  local i

  if [ "$count" -eq 0 ]; then
    warn "没有可选择的项目"
    return 1
  fi

  while true; do
    clear_screen
    printf '%s\n' "$title" >&2
    printf '使用 ↑/↓ 选择，回车确认，q 取消\n\n' >&2

    for i in "${!options[@]}"; do
      if [ "$i" -eq "$selected" ]; then
        printf '\033[7m> %s\033[0m\n' "${options[$i]}" >&2
      else
        printf '  %s\n' "${options[$i]}" >&2
      fi
    done

    IFS= read -rsn1 key

    case "$key" in
      $'\x1b')
        IFS= read -rsn2 -t 0.1 rest || true
        case "$rest" in
          "[A") selected=$(( (selected + count - 1) % count )) ;;
          "[B") selected=$(( (selected + 1) % count )) ;;
          *) return 1 ;;
        esac
        ;;
      "")
        printf '%s\n' "$selected"
        return 0
        ;;
      q|Q)
        return 1
        ;;
    esac
  done
}

select_checklist() {
  local title="$1"
  shift

  local -a options=("$@")
  local -a checked=()
  local selected=0
  local count="${#options[@]}"
  local key
  local rest
  local i
  local mark
  local message=""
  local has_checked

  if [ "$count" -eq 0 ]; then
    warn "没有可选择的项目"
    return 1
  fi

  for i in "${!options[@]}"; do
    checked[$i]=0
  done

  while true; do
    clear_screen
    printf '%s\n' "$title" >&2
    printf '使用 ↑/↓ 移动，空格勾选/取消，回车执行，q 取消\n\n' >&2

    if [ -n "$message" ]; then
      printf '%s\n\n' "$message" >&2
    fi

    for i in "${!options[@]}"; do
      if [ "${checked[$i]}" -eq 1 ]; then
        mark="[x]"
      else
        mark="[ ]"
      fi

      if [ "$i" -eq "$selected" ]; then
        printf '\033[7m> %s %s\033[0m\n' "$mark" "${options[$i]}" >&2
      else
        printf '  %s %s\n' "$mark" "${options[$i]}" >&2
      fi
    done

    IFS= read -rsn1 key

    case "$key" in
      $'\x1b')
        IFS= read -rsn2 -t 0.1 rest || true
        case "$rest" in
          "[A") selected=$(( (selected + count - 1) % count )) ;;
          "[B") selected=$(( (selected + 1) % count )) ;;
          *) return 1 ;;
        esac
        ;;
      " ")
        if [ "${checked[$selected]}" -eq 1 ]; then
          checked[$selected]=0
        else
          checked[$selected]=1
        fi
        message=""
        ;;
      "")
        has_checked=0
        for i in "${!checked[@]}"; do
          if [ "${checked[$i]}" -eq 1 ]; then
            has_checked=1
            printf '%s\n' "$i"
          fi
        done

        if [ "$has_checked" -eq 1 ]; then
          return 0
        fi

        message="请先按空格勾选至少一项"
        ;;
      q|Q)
        return 1
        ;;
    esac
  done
}

sudoers_file_for_user() {
  printf '%s/%s%s\n' "$SUDOERS_DIR" "$MANAGED_SUDOERS_PREFIX" "$1"
}

has_nopasswd_rule() {
  local user="$1"

  grep -R -E "^[[:space:]]*${user}[[:space:]]+ALL=.*NOPASSWD:.*ALL" \
    /etc/sudoers "$SUDOERS_DIR" 2>/dev/null | grep -q .
}

check_sudoers() {
  require_command visudo
  visudo -c
}

print_user_table_header() {
  printf '%-20s %-8s %-12s %-8s %-10s %s\n' "用户名" "UID" "SUDO组" "SUDO" "免密SUDO" "Shell"
  printf '%-20s %-8s %-12s %-8s %-10s %s\n' "----" "---" "----------" "----" "--------" "-----"
}

regular_user_names() {
  while IFS=: read -r name _ uid _ _ _ _; do
    if [ "$uid" -ge 1000 ] && [ "$uid" -ne 65534 ] && [ "$name" != "nobody" ]; then
      printf '%s\n' "$name"
    fi
  done < /etc/passwd
}

user_menu_label() {
  local user="$1"
  local in_sudo="no"
  local nopasswd="no"

  if is_user_in_group "$user" "$SUDO_GROUP"; then
    in_sudo="yes"
  fi

  if has_nopasswd_rule "$user"; then
    nopasswd="yes"
  fi

  printf '%s  UID=%s  sudo=%s  免密=%s  shell=%s' \
    "$user" "$(user_uid "$user")" "$in_sudo" "$nopasswd" "$(user_shell "$user")"
}

list_regular_users() {
  print_user_table_header

  while IFS=: read -r name _ uid _ _ _ shell; do
    if [ "$uid" -ge 1000 ] && [ "$uid" -ne 65534 ] && [ "$name" != "nobody" ]; then
      local in_sudo="no"
      local nopasswd="no"

      if is_user_in_group "$name" "$SUDO_GROUP"; then
        in_sudo="yes"
      fi

      if has_nopasswd_rule "$name"; then
        nopasswd="yes"
      fi

      printf '%-20s %-8s %-12s %-8s %-10s %s\n' "$name" "$uid" "$SUDO_GROUP" "$in_sudo" "$nopasswd" "$shell"
    fi
  done < /etc/passwd
}

read_username() {
  local prompt="$1"
  local user

  printf '%s' "$prompt" >&2
  read -r user

  if ! validate_username "$user"; then
    warn "用户名不合法：$user"
    return 1
  fi

  printf '%s\n' "$user"
}

show_user_detail() {
  local user

  user="$(choose_existing_user)" || return 1

  if ! user_exists "$user"; then
    warn "用户不存在：$user"
    return 1
  fi

  printf '\n'
  printf 'passwd 记录：%s\n' "$(getent passwd "$user")"
  printf '用户 ID：     %s\n' "$(id "$user")"
  printf '家目录：      %s\n' "$(user_home "$user")"
  printf 'Shell：       %s\n' "$(user_shell "$user")"
  printf '\n匹配到的 sudoers 规则：\n'
  grep -R --line-number -e "$user" -e NOPASSWD /etc/sudoers "$SUDOERS_DIR" 2>/dev/null || true
}

add_user() {
  local user

  user="$(read_username "新用户名：")" || return 1

  if user_exists "$user"; then
    warn "用户已存在：$user"
    return 1
  fi

  useradd -m -s /bin/bash "$user" || return 1
  info "已创建用户：$user"

  if confirm "是否现在为 $user 设置密码？"; then
    passwd "$user"
  fi

  if confirm "是否为 $user 添加 SSH 公钥？"; then
    add_ssh_key_for_user "$user"
  fi

  if confirm "是否把 $user 加入 $SUDO_GROUP 组？"; then
    add_user_to_sudo "$user"
  fi

  if confirm "是否为 $user 开启免密 sudo？"; then
    enable_nopasswd_sudo "$user"
  fi
}

confirm() {
  local question="$1"
  local answer

  printf '%s [y/N]: ' "$question"
  read -r answer

  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

choose_existing_user() {
  local -a users=()
  local -a labels=()
  local user
  local selected

  mapfile -t users < <(regular_user_names)

  if [ "${#users[@]}" -eq 0 ]; then
    warn "没有可选择的普通用户"
    return 1
  fi

  for user in "${users[@]}"; do
    labels+=("$(user_menu_label "$user")")
  done

  selected="$(select_menu "选择用户" "${labels[@]}")" || return 1
  clear_screen
  user="${users[$selected]}"

  printf '%s\n' "$user"
}

choose_existing_users() {
  local title="${1:-选择用户}"
  local -a users=()
  local -a labels=()
  local -a selected_indexes=()
  local user
  local selected_output
  local index

  mapfile -t users < <(regular_user_names)

  if [ "${#users[@]}" -eq 0 ]; then
    warn "没有可选择的普通用户"
    return 1
  fi

  for user in "${users[@]}"; do
    labels+=("$(user_menu_label "$user")")
  done

  selected_output="$(select_checklist "$title" "${labels[@]}")" || return 1
  mapfile -t selected_indexes <<< "$selected_output"
  clear_screen

  for index in "${selected_indexes[@]}"; do
    printf '%s\n' "${users[$index]}"
  done
}

add_user_to_sudo() {
  local user="${1:-}"
  local -a users=()
  local selected_output

  if [ -n "$user" ]; then
    users=("$user")
  else
    selected_output="$(choose_existing_users "选择要加入 $SUDO_GROUP 组的用户")" || return 1
    mapfile -t users <<< "$selected_output"
  fi

  for user in "${users[@]}"; do
    usermod -aG "$SUDO_GROUP" "$user" || return 1
    info "已把 $user 加入 $SUDO_GROUP"
  done
}

remove_user_from_sudo() {
  local -a users=()
  local selected_output
  local user

  selected_output="$(choose_existing_users "选择要移出 $SUDO_GROUP 组的用户")" || return 1
  mapfile -t users <<< "$selected_output"

  for user in "${users[@]}"; do
    if ! is_user_in_group "$user" "$SUDO_GROUP"; then
      warn "$user 不在 $SUDO_GROUP 组中"
      continue
    fi

    gpasswd -d "$user" "$SUDO_GROUP" || return 1
    info "已把 $user 从 $SUDO_GROUP 移出"
  done
}

enable_nopasswd_sudo() {
  local user="${1:-}"
  local -a users=()
  local selected_output
  local file
  local tmp

  require_command visudo

  if [ -n "$user" ]; then
    users=("$user")
  else
    selected_output="$(choose_existing_users "选择要开启免密 sudo 的用户")" || return 1
    mapfile -t users <<< "$selected_output"
  fi

  for user in "${users[@]}"; do
    file="$(sudoers_file_for_user "$user")"
    tmp="$(mktemp)"

    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" > "$tmp"

    if ! visudo -cf "$tmp"; then
      rm -f "$tmp"
      warn "sudoers 语法检查失败"
      return 1
    fi

    install -m 0440 -o root -g root "$tmp" "$file"
    rm -f "$tmp"
    info "已开启免密 sudo：$file"
  done

  check_sudoers || return 1
}

disable_nopasswd_sudo() {
  local -a users=()
  local selected_output
  local user
  local file

  selected_output="$(choose_existing_users "选择要关闭免密 sudo 的用户")" || return 1
  mapfile -t users <<< "$selected_output"

  for user in "${users[@]}"; do
    file="$(sudoers_file_for_user "$user")"

    if [ -f "$file" ]; then
      rm -f "$file"
      info "已移除本脚本管理的免密 sudo 文件：$file"
    else
      warn "未找到本脚本管理的 sudoers 文件：$file"
    fi

    if has_nopasswd_rule "$user"; then
      warn "$user 仍然存在其他 NOPASSWD 规则，不在本脚本管理文件中"
    fi
  done

  check_sudoers || return 1
}

add_ssh_key() {
  local user

  user="$(choose_existing_user)" || return 1
  add_ssh_key_for_user "$user"
}

add_ssh_key_for_user() {
  local user="$1"
  local home
  local group
  local key
  local ssh_dir
  local auth_keys

  home="$(user_home "$user")"
  group="$(primary_group "$user")"
  ssh_dir="$home/.ssh"
  auth_keys="$ssh_dir/authorized_keys"

  if [ -z "$home" ] || [ "$home" = "/" ]; then
    warn "$user 的家目录不合法：$home"
    return 1
  fi

  printf '粘贴 SSH 公钥：'
  read -r key

  if [ -z "$key" ]; then
    warn "SSH 公钥为空"
    return 1
  fi

  install -d -m 0700 -o "$user" -g "$group" "$ssh_dir" || return 1
  touch "$auth_keys" || return 1

  if grep -qxF "$key" "$auth_keys"; then
    info "SSH 公钥已存在"
  else
    printf '%s\n' "$key" >> "$auth_keys"
    info "已追加 SSH 公钥"
  fi

  chown "$user:$group" "$auth_keys"
  chmod 0600 "$auth_keys"
}

delete_user() {
  local -a users=()
  local selected_output
  local user
  local uid
  local typed
  local failed=0

  selected_output="$(choose_existing_users "选择要删除的用户")" || return 1
  mapfile -t users <<< "$selected_output"

  printf '\n即将删除以下用户：\n'

  for user in "${users[@]}"; do
    uid="$(user_uid "$user")"

    if [ "$user" = "root" ]; then
      warn "拒绝删除 root"
      return 1
    fi

    if [ "$uid" -lt 1000 ] || [ "$uid" -eq 65534 ]; then
      warn "拒绝删除系统用户：$user uid=$uid"
      return 1
    fi

    printf '  - %s  UID=%s  家目录=%s\n' "$user" "$uid" "$(user_home "$user")"

    if who | awk '{print $1}' | grep -qx "$user"; then
      warn "$user 当前可能已登录"
    fi

    if pgrep -u "$user" >/dev/null 2>&1; then
      warn "$user 仍有运行中进程"
    fi
  done

  if ! confirm "确认继续删除以上用户？"; then
    return 1
  fi

  printf '请输入 "DELETE" 确认删除：'
  read -r typed

  if [ "$typed" != "DELETE" ]; then
    warn "删除已取消"
    return 1
  fi

  for user in "${users[@]}"; do
    if userdel -r "$user"; then
      rm -f "$(sudoers_file_for_user "$user")"
      info "已删除用户：$user"
    else
      warn "删除失败：$user"
      failed=1
    fi
  done

  check_sudoers || return 1
  return "$failed"
}

show_menu() {
  cat <<'MENU'

===============================
 服务器用户管理
===============================
1. 查看普通用户
2. 查看用户详情
3. 添加用户
4. 删除用户
5. 加入 sudo/wheel 组
6. 移出 sudo/wheel 组
7. 开启免密 sudo
8. 关闭免密 sudo
9. 添加 SSH 公钥
0. 退出
===============================
MENU
}

main() {
  local choice

  require_root
  detect_supported_os

  while true; do
    show_menu
    printf '请选择：'
    read -r choice
    clear_screen

    case "$choice" in
      1) list_regular_users; pause ;;
      2) show_user_detail; pause ;;
      3) add_user; pause ;;
      4) delete_user; pause ;;
      5) add_user_to_sudo; pause ;;
      6) remove_user_from_sudo; pause ;;
      7) enable_nopasswd_sudo; pause ;;
      8) disable_nopasswd_sudo; pause ;;
      9) add_ssh_key; pause ;;
      0) exit 0 ;;
      *) warn "未知选项：$choice"; pause ;;
    esac
  done
}

main "$@"
