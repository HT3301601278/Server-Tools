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

  # shellcheck disable=SC1091
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
  # Conservative Linux username rule for this admin script.
  printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'
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

  user="$(read_username "用户名：")" || return 1

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
  local user

  list_regular_users >&2
  printf '\n' >&2

  user="$(read_username "选择用户名：")" || return 1

  if ! user_exists "$user"; then
    warn "用户不存在：$user"
    return 1
  fi

  printf '%s\n' "$user"
}

add_user_to_sudo() {
  local user="${1:-}"

  if [ -z "$user" ]; then
    user="$(choose_existing_user)" || return 1
  fi

  usermod -aG "$SUDO_GROUP" "$user" || return 1
  info "已把 $user 加入 $SUDO_GROUP"
}

remove_user_from_sudo() {
  local user

  user="$(choose_existing_user)" || return 1

  if ! is_user_in_group "$user" "$SUDO_GROUP"; then
    warn "$user 不在 $SUDO_GROUP 组中"
    return 0
  fi

  gpasswd -d "$user" "$SUDO_GROUP" || return 1
  info "已把 $user 从 $SUDO_GROUP 移出"
}

enable_nopasswd_sudo() {
  local user="${1:-}"
  local file
  local tmp

  require_command visudo

  if [ -z "$user" ]; then
    user="$(choose_existing_user)" || return 1
  fi

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

  check_sudoers || return 1
  info "已开启免密 sudo：$file"
}

disable_nopasswd_sudo() {
  local user
  local file

  user="$(choose_existing_user)" || return 1
  file="$(sudoers_file_for_user "$user")"

  if [ -f "$file" ]; then
    rm -f "$file"
    check_sudoers || return 1
    info "已移除本脚本管理的免密 sudo 文件：$file"
  else
    warn "未找到本脚本管理的 sudoers 文件：$file"
  fi

  if has_nopasswd_rule "$user"; then
    warn "$user 仍然存在其他 NOPASSWD 规则，不在本脚本管理文件中"
  fi
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
  local user
  local uid
  local expected
  local typed

  user="$(choose_existing_user)" || return 1
  uid="$(user_uid "$user")"

  if [ "$user" = "root" ]; then
    warn "拒绝删除 root"
    return 1
  fi

  if [ "$uid" -lt 1000 ] || [ "$uid" -eq 65534 ]; then
    warn "拒绝删除系统用户：$user uid=$uid"
    return 1
  fi

  printf '\n即将删除用户：\n'
  printf '  用户：   %s\n' "$user"
  printf '  UID：    %s\n' "$uid"
  printf '  家目录： %s\n' "$(user_home "$user")"
  printf '  ID：     %s\n' "$(id "$user")"

  if who | awk '{print $1}' | grep -qx "$user"; then
    warn "$user 当前可能已登录"
  fi

  if pgrep -u "$user" >/dev/null 2>&1; then
    warn "$user 仍有运行中进程"
    if ! confirm "仍然继续？"; then
      return 1
    fi
  fi

  expected="DELETE $user"
  printf '请输入 "%s" 确认删除：' "$expected"
  read -r typed

  if [ "$typed" != "$expected" ]; then
    warn "删除已取消"
    return 1
  fi

  userdel -r "$user" || return 1
  rm -f "$(sudoers_file_for_user "$user")"
  check_sudoers || return 1

  info "已删除用户：$user"
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
