#!/usr/bin/env bash
# AnyTLS manager for Alpine Linux + OpenRC
# Project: https://github.com/anytls/anytls-go
#
# Interactive usage:
#   bash anytls-alpine.sh
#
# CLI usage:
#   bash anytls-alpine.sh install|update|config|status|logs|port|password|network|uninstall

set -uo pipefail

SCRIPT_VERSION="1.1.0"
UPSTREAM_REPO="anytls/anytls-go"
CONFIG_DIR="/etc/AnyTLS"
SERVER_BIN="${CONFIG_DIR}/server"
VERSION_FILE="${CONFIG_DIR}/version"
METADATA_FILE="${CONFIG_DIR}/config.yaml"
OPENRC_SERVICE="anytls"
OPENRC_SCRIPT="/etc/init.d/${OPENRC_SERVICE}"
OPENRC_CONFIG="/etc/conf.d/${OPENRC_SERVICE}"
STDOUT_LOG="/var/log/anytls.log"
STDERR_LOG="/var/log/anytls.err"
CLIENT_NAME="AnyTLS-Alpine"

TEMP_DIR=""
ANYTLS_PORT=""
ANYTLS_PASSWORD=""
ANYTLS_NETWORK_MODE=""
ANYTLS_LISTEN_HOST=""
DOWNLOADED_BIN=""

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
fi

info() { printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

cleanup_temp() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    case "$TEMP_DIR" in
      /tmp/anytls-alpine.*) rm -rf -- "$TEMP_DIR" ;;
    esac
  fi
  TEMP_DIR=""
}

trap cleanup_temp EXIT

ensure_root() {
  if (( EUID != 0 )); then
    fail "必须使用 root 运行此脚本。"
    exit 1
  fi
}

ensure_alpine() {
  if [[ ! -f /etc/alpine-release ]] || ! command -v apk >/dev/null 2>&1; then
    fail "此脚本仅支持 Alpine Linux。"
    exit 1
  fi
}

ensure_openrc_running() {
  if ! command -v rc-service >/dev/null 2>&1 || ! command -v rc-update >/dev/null 2>&1; then
    fail "未找到 OpenRC 命令。请确认这是完整的 Alpine 系统，而不是精简容器。"
    return 1
  fi

  if [[ ! -e /run/openrc/softlevel ]]; then
    fail "OpenRC 当前没有作为系统服务管理器运行。"
    fail "若这是 Docker 容器，请使用容器自身的前台进程或 supervisor 管理 AnyTLS。"
    return 1
  fi
}

ensure_dependencies() {
  info "正在通过 apk 安装依赖……"
  if ! apk add --no-cache bash ca-certificates curl unzip openrc iproute2; then
    fail "依赖安装失败，请检查 Alpine 软件源和网络。"
    return 1
  fi
  update-ca-certificates >/dev/null 2>&1 || true
  ensure_openrc_running
}

get_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    *)
      fail "AnyTLS 官方预编译文件不支持当前架构：$(uname -m)"
      return 1
      ;;
  esac
}

get_latest_version() {
  local version="" effective_url=""

  version="$(
    curl -fsSL --connect-timeout 10 --max-time 30 \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1
  )"

  if [[ -z "$version" ]]; then
    effective_url="$(
      curl -fsSLI --connect-timeout 10 --max-time 30 \
        -o /dev/null -w '%{url_effective}' \
        "https://github.com/${UPSTREAM_REPO}/releases/latest" 2>/dev/null || true
    )"
    version="${effective_url##*/}"
  fi

  if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([._-][0-9A-Za-z.-]+)?$ ]]; then
    fail "无法获取有效的 AnyTLS 最新版本号。"
    return 1
  fi

  printf '%s\n' "$version"
}

prepare_download() {
  local version="$1" arch="$2" archive url candidate

  cleanup_temp
  TEMP_DIR="$(mktemp -d /tmp/anytls-alpine.XXXXXX)" || {
    fail "无法创建临时目录。"
    return 1
  }

  archive="${TEMP_DIR}/anytls.zip"
  url="https://github.com/${UPSTREAM_REPO}/releases/download/${version}/anytls_${version#v}_linux_${arch}.zip"

  info "正在下载 AnyTLS ${version} (${arch})……"
  if ! curl -fL --retry 2 --connect-timeout 10 --max-time 180 "$url" -o "$archive"; then
    fail "下载失败：${url}"
    return 1
  fi

  if ! unzip -q "$archive" -d "${TEMP_DIR}/unpacked"; then
    fail "下载文件不是有效的 ZIP 压缩包。"
    return 1
  fi

  candidate="${TEMP_DIR}/unpacked/anytls-server"
  if [[ ! -f "$candidate" ]]; then
    candidate="$(find "${TEMP_DIR}/unpacked" -type f -name anytls-server 2>/dev/null | head -n 1)"
  fi

  if [[ -z "$candidate" || ! -f "$candidate" ]]; then
    fail "压缩包内未找到 anytls-server。"
    return 1
  fi

  chmod 755 "$candidate"
  if ! "$candidate" -h >/dev/null 2>&1; then
    fail "下载的 anytls-server 无法在当前系统运行。"
    return 1
  fi

  DOWNLOADED_BIN="$candidate"
}

generate_password() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '\n' </proc/sys/kernel/random/uuid
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

random_port() {
  local random_number
  random_number="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')"
  printf '%s\n' "$((2000 + random_number % 63001))"
}

valid_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

valid_network_mode() {
  [[ "${1:-}" == "ipv4" || "${1:-}" == "ipv6" ]]
}

network_mode_label() {
  case "${1:-}" in
    ipv6) printf 'IPv6\n' ;;
    *) printf 'IPv4\n' ;;
  esac
}

network_mode_listen_host() {
  case "${1:-}" in
    ipv6) printf '[::]\n' ;;
    *) printf '0.0.0.0\n' ;;
  esac
}

detect_legacy_network_mode() {
  if [[ -r "$OPENRC_SCRIPT" ]] && grep -Fq '[::]:' "$OPENRC_SCRIPT"; then
    printf 'ipv6\n'
  else
    printf 'ipv4\n'
  fi
}

port_in_use() {
  local port="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\])${port}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk 'NR > 2 {print $4}' | grep -Eq "(^|:|\])${port}$"
  else
    return 1
  fi
}

choose_port() {
  local allowed_current="${1:-}" input=""

  while true; do
    if ! read -r -t 15 -p "输入端口 [1-65535]；直接回车或等待 15 秒随机生成：" input; then
      input=""
      printf '\n' >&2
    fi
    [[ -n "$input" ]] || input="$(random_port)"

    if ! valid_port "$input"; then
      warn "端口无效：${input}"
      continue
    fi

    if [[ "$input" != "$allowed_current" ]] && port_in_use "$input"; then
      warn "端口 ${input} 已被占用，请选择其他端口。"
      continue
    fi

    printf '%s\n' "$input"
    return 0
  done
}

choose_network_mode() {
  local current="${1:-}" choice="" current_text=""

  while true; do
    printf '\n请选择服务监听模式：\n' >&2
    printf '  1. IPv4（监听 0.0.0.0，客户端使用 IPv4）\n' >&2
    printf '  2. IPv6（监听 [::]，客户端使用 IPv6）\n' >&2

    if valid_network_mode "$current"; then
      current_text="$(network_mode_label "$current")"
      read -r -p "请输入 [1-2]；直接回车保留 ${current_text}：" choice
      [[ -n "$choice" ]] || {
        printf '%s\n' "$current"
        return 0
      }
    else
      read -r -p "请输入 [1-2]：" choice
    fi

    case "$choice" in
      1 | ipv4 | IPv4 | IPV4)
        printf 'ipv4\n'
        return 0
        ;;
      2 | ipv6 | IPv6 | IPV6)
        printf 'ipv6\n'
        return 0
        ;;
      *) warn "无效选择，请输入 1 或 2。" ;;
    esac
  done
}

load_config() {
  ANYTLS_PORT=""
  ANYTLS_PASSWORD=""
  ANYTLS_NETWORK_MODE=""
  ANYTLS_LISTEN_HOST=""

  if [[ ! -r "$OPENRC_CONFIG" ]]; then
    return 1
  fi

  # This file is created by this script, owned by root, and mode 0600.
  # shellcheck disable=SC1090
  source "$OPENRC_CONFIG"

  if ! valid_network_mode "${ANYTLS_NETWORK_MODE:-}"; then
    ANYTLS_NETWORK_MODE="$(detect_legacy_network_mode)"
  fi
  ANYTLS_LISTEN_HOST="$(network_mode_listen_host "$ANYTLS_NETWORK_MODE")"

  valid_port "${ANYTLS_PORT:-}" && [[ -n "${ANYTLS_PASSWORD:-}" ]]
}

write_config() {
  local port="$1" password="$2" network_mode="$3" listen_host config_tmp metadata_tmp

  if ! valid_port "$port" \
    || [[ ! "$password" =~ ^[A-Za-z0-9._~-]+$ ]] \
    || ! valid_network_mode "$network_mode"; then
    fail "拒绝写入无效配置。"
    return 1
  fi

  listen_host="$(network_mode_listen_host "$network_mode")"

  if ! mkdir -p "$CONFIG_DIR" "$(dirname "$OPENRC_CONFIG")"; then
    fail "无法创建配置目录。"
    return 1
  fi
  config_tmp="${OPENRC_CONFIG}.tmp.$$"
  metadata_tmp="${METADATA_FILE}.tmp.$$"

  if ! {
    printf 'ANYTLS_PORT="%s"\n' "$port"
    printf 'ANYTLS_PASSWORD="%s"\n' "$password"
    printf 'ANYTLS_NETWORK_MODE="%s"\n' "$network_mode"
    printf 'ANYTLS_LISTEN_HOST="%s"\n' "$listen_host"
  } >"$config_tmp"; then
    fail "无法写入 ${OPENRC_CONFIG}。"
    return 1
  fi
  if ! chmod 600 "$config_tmp" || ! mv -f "$config_tmp" "$OPENRC_CONFIG"; then
    fail "无法安装 ${OPENRC_CONFIG}。"
    rm -f -- "$config_tmp"
    return 1
  fi

  if ! {
    printf 'listen: "%s:%s"\n' "$listen_host" "$port"
    printf 'network_mode: "%s"\n' "$network_mode"
    printf 'auth:\n'
    printf '  type: password\n'
    printf '  password: "%s"\n' "$password"
  } >"$metadata_tmp"; then
    fail "无法写入 ${METADATA_FILE}。"
    return 1
  fi
  if ! chmod 600 "$metadata_tmp" || ! mv -f "$metadata_tmp" "$METADATA_FILE"; then
    fail "无法安装 ${METADATA_FILE}。"
    rm -f -- "$metadata_tmp"
    return 1
  fi
}

write_openrc_service() {
  local service_tmp="${OPENRC_SCRIPT}.tmp.$$"

  if ! mkdir -p "$(dirname "$OPENRC_SCRIPT")"; then
    fail "无法创建 OpenRC 服务目录。"
    return 1
  fi

  if ! cat >"$service_tmp" <<'OPENRC_EOF'
#!/sbin/openrc-run

name="AnyTLS"
description="AnyTLS proxy server"
command="/etc/AnyTLS/server"
command_args="-l ${ANYTLS_LISTEN_HOST:-0.0.0.0}:${ANYTLS_PORT} -p ${ANYTLS_PASSWORD}"

supervisor=supervise-daemon
respawn_delay=5
respawn_max=0

output_log="/var/log/anytls.log"
error_log="/var/log/anytls.err"

depend() {
    need net
    after firewall
}
OPENRC_EOF
  then
    fail "无法写入 OpenRC 服务文件。"
    return 1
  fi

  if ! chmod 755 "$service_tmp" || ! mv -f "$service_tmp" "$OPENRC_SCRIPT"; then
    fail "无法安装 OpenRC 服务文件。"
    rm -f -- "$service_tmp"
    return 1
  fi
}

install_binary_file() {
  local source="$1" new_file="${SERVER_BIN}.new"

  if ! mkdir -p "$CONFIG_DIR" \
    || ! cp "$source" "$new_file" \
    || ! chmod 755 "$new_file" \
    || ! mv -f "$new_file" "$SERVER_BIN"; then
    fail "无法安装 AnyTLS 服务端文件。"
    rm -f -- "$new_file"
    return 1
  fi
}

is_installed() {
  [[ -x "$SERVER_BIN" && -f "$OPENRC_SCRIPT" && -f "$OPENRC_CONFIG" ]]
}

service_running() {
  rc-service "$OPENRC_SERVICE" status >/dev/null 2>&1
}

start_or_restart_service() {
  if service_running; then
    rc-service "$OPENRC_SERVICE" restart
  else
    rc-service "$OPENRC_SERVICE" start
  fi
}

get_public_ip() {
  local network_mode="${1:-ipv4}" ip=""

  if command -v curl >/dev/null 2>&1; then
    if [[ "$network_mode" == "ipv6" ]]; then
      ip="$(
        curl -6fsS --connect-timeout 5 --max-time 10 \
          https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
          | awk -F= '/^ip=/{print $2; exit}' || true
      )"
      [[ -n "$ip" ]] || ip="$(curl -6fsS --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null || true)"
    else
      ip="$(
        curl -4fsS --connect-timeout 5 --max-time 10 \
          https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
          | awk -F= '/^ip=/{print $2; exit}' || true
      )"
      [[ -n "$ip" ]] || ip="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    fi
  fi

  printf '%s\n' "$ip"
}

show_config() {
  local ip host uri mode_label address_placeholder

  if ! is_installed || ! load_config; then
    fail "AnyTLS 尚未安装或配置不完整。"
    return 1
  fi

  mode_label="$(network_mode_label "$ANYTLS_NETWORK_MODE")"
  address_placeholder="服务器${mode_label}地址"
  ip="$(get_public_ip "$ANYTLS_NETWORK_MODE")"
  if [[ -z "$ip" ]]; then
    ip="$address_placeholder"
    warn "无法自动获取公网 ${mode_label} 地址，请在导入链接中手动替换“${address_placeholder}”。"
  fi

  host="$ip"
  [[ "$ANYTLS_NETWORK_MODE" == "ipv6" ]] && host="[${ip}]"
  uri="anytls://${ANYTLS_PASSWORD}@${host}:${ANYTLS_PORT}/?insecure=1#${CLIENT_NAME}"

  printf '\n========== AnyTLS 客户端配置 ==========\n'
  printf '网络模式：%s\n' "$mode_label"
  printf '监听地址：%s:%s\n' "$ANYTLS_LISTEN_HOST" "$ANYTLS_PORT"
  printf '地址：%s\n' "$ip"
  printf '端口：%s\n' "$ANYTLS_PORT"
  printf '密码：%s\n' "$ANYTLS_PASSWORD"
  printf 'TLS：启用\n'
  printf '跳过证书验证：true\n'
  printf '导入链接：%s\n' "$uri"
  printf '========================================\n\n'
  warn "服务使用运行时生成的自签名证书，客户端必须允许不安全/跳过证书验证。"
  warn "请只放行 TCP ${ANYTLS_PORT}；本脚本不会关闭系统防火墙。"
  if [[ "$ANYTLS_NETWORK_MODE" == "ipv6" ]]; then
    warn "当前为 IPv6 模式，客户端所在网络也必须能够访问 IPv6。"
  fi
}

current_version() {
  if [[ -r "$VERSION_FILE" ]]; then
    tr -d '\r\n' <"$VERSION_FILE"
  else
    printf 'unknown\n'
  fi
}

snapshot_file() {
  local source="$1" destination="$2"
  [[ -e "$source" ]] && cp -p "$source" "$destination"
}

restore_file() {
  local backup="$1" destination="$2"
  if [[ -e "$backup" ]]; then
    cp -p "$backup" "$destination"
  else
    rm -f -- "$destination"
  fi
}

install_anytls() {
  local arch latest port password network_mode existing_mode="" answer="" had_install=0
  local backup_bin backup_config backup_metadata backup_service backup_version

  ensure_dependencies || return 1
  arch="$(get_arch)" || return 1
  latest="$(get_latest_version)" || return 1
  prepare_download "$latest" "$arch" || return 1

  backup_bin="${TEMP_DIR}/backup.server"
  backup_config="${TEMP_DIR}/backup.conf"
  backup_metadata="${TEMP_DIR}/backup.yaml"
  backup_service="${TEMP_DIR}/backup.init"
  backup_version="${TEMP_DIR}/backup.version"

  if is_installed; then
    had_install=1
    snapshot_file "$SERVER_BIN" "$backup_bin"
    snapshot_file "$OPENRC_CONFIG" "$backup_config"
    snapshot_file "$METADATA_FILE" "$backup_metadata"
    snapshot_file "$OPENRC_SCRIPT" "$backup_service"
    snapshot_file "$VERSION_FILE" "$backup_version"

    load_config || true
    existing_mode="${ANYTLS_NETWORK_MODE:-$(detect_legacy_network_mode)}"
    read -r -p "检测到已有安装，是否保留当前端口和密码？[Y/n] " answer
    if [[ ! "$answer" =~ ^[Nn]$ ]] && valid_port "${ANYTLS_PORT:-}" && [[ -n "${ANYTLS_PASSWORD:-}" ]]; then
      port="$ANYTLS_PORT"
      password="$ANYTLS_PASSWORD"
    else
      port="$(choose_port "${ANYTLS_PORT:-}")" || return 1
      password="$(generate_password)"
    fi
    network_mode="$(choose_network_mode "$existing_mode")" || return 1
  else
    network_mode="$(choose_network_mode)" || return 1
    port="$(choose_port)" || return 1
    password="$(generate_password)"
  fi

  install_binary_file "$DOWNLOADED_BIN" || return 1

  if ! write_config "$port" "$password" "$network_mode" || ! write_openrc_service; then
    fail "写入配置失败。"
    return 1
  fi

  if ! rc-update add "$OPENRC_SERVICE" default >/dev/null; then
    fail "无法添加 OpenRC 开机自启服务。"
    return 1
  fi

  info "正在启动 AnyTLS……"
  if ! start_or_restart_service || ! service_running; then
    fail "AnyTLS 启动失败。"
    [[ -f "$STDERR_LOG" ]] && tail -n 30 "$STDERR_LOG" >&2 || true

    if (( had_install == 1 )); then
      warn "正在恢复安装前的版本和配置……"
      restore_file "$backup_bin" "$SERVER_BIN"
      restore_file "$backup_config" "$OPENRC_CONFIG"
      restore_file "$backup_metadata" "$METADATA_FILE"
      restore_file "$backup_service" "$OPENRC_SCRIPT"
      restore_file "$backup_version" "$VERSION_FILE"
      rc-service "$OPENRC_SERVICE" restart >/dev/null 2>&1 || true
    fi
    return 1
  fi

  printf '%s\n' "$latest" >"$VERSION_FILE"
  chmod 644 "$VERSION_FILE"
  ok "AnyTLS ${latest} 已安装并启动。"
  show_config
}

update_anytls() {
  local arch latest installed backup_bin

  if ! is_installed; then
    fail "AnyTLS 尚未安装。"
    return 1
  fi

  ensure_dependencies || return 1
  arch="$(get_arch)" || return 1
  latest="$(get_latest_version)" || return 1
  installed="$(current_version)"

  if [[ "$installed" == "$latest" ]]; then
    ok "当前已经是最新版本：${latest}"
    return 0
  fi

  prepare_download "$latest" "$arch" || return 1
  backup_bin="${TEMP_DIR}/backup.server"
  cp -p "$SERVER_BIN" "$backup_bin"

  install_binary_file "$DOWNLOADED_BIN" || return 1

  info "正在重启 AnyTLS……"
  if ! start_or_restart_service || ! service_running; then
    fail "新版本启动失败，正在恢复 ${installed}。"
    cp -p "$backup_bin" "$SERVER_BIN"
    rc-service "$OPENRC_SERVICE" restart >/dev/null 2>&1 || true
    return 1
  fi

  printf '%s\n' "$latest" >"$VERSION_FILE"
  chmod 644 "$VERSION_FILE"
  ok "AnyTLS 已从 ${installed} 更新至 ${latest}。"
  show_config
}

change_port() {
  local old_port old_password old_network_mode new_port

  if ! is_installed || ! load_config; then
    fail "AnyTLS 尚未安装或配置不完整。"
    return 1
  fi

  ensure_openrc_running || return 1
  old_port="$ANYTLS_PORT"
  old_password="$ANYTLS_PASSWORD"
  old_network_mode="$ANYTLS_NETWORK_MODE"
  new_port="$(choose_port "$old_port")" || return 1

  write_config "$new_port" "$old_password" "$old_network_mode" || return 1
  if ! start_or_restart_service || ! service_running; then
    fail "使用新端口启动失败，正在恢复端口 ${old_port}。"
    write_config "$old_port" "$old_password" "$old_network_mode" || true
    rc-service "$OPENRC_SERVICE" restart >/dev/null 2>&1 || true
    return 1
  fi

  ok "端口已改为 ${new_port}。"
  show_config
}

change_password() {
  local old_port old_password old_network_mode new_password

  if ! is_installed || ! load_config; then
    fail "AnyTLS 尚未安装或配置不完整。"
    return 1
  fi

  ensure_openrc_running || return 1
  old_port="$ANYTLS_PORT"
  old_password="$ANYTLS_PASSWORD"
  old_network_mode="$ANYTLS_NETWORK_MODE"
  new_password="$(generate_password)"

  write_config "$old_port" "$new_password" "$old_network_mode" || return 1
  if ! start_or_restart_service || ! service_running; then
    fail "使用新密码启动失败，正在恢复旧密码。"
    write_config "$old_port" "$old_password" "$old_network_mode" || true
    rc-service "$OPENRC_SERVICE" restart >/dev/null 2>&1 || true
    return 1
  fi

  ok "密码已随机更新。"
  show_config
}

change_network_mode() {
  local old_port old_password old_network_mode new_network_mode

  if ! is_installed || ! load_config; then
    fail "AnyTLS 尚未安装或配置不完整。"
    return 1
  fi

  ensure_openrc_running || return 1
  old_port="$ANYTLS_PORT"
  old_password="$ANYTLS_PASSWORD"
  old_network_mode="$ANYTLS_NETWORK_MODE"
  new_network_mode="$(choose_network_mode "$old_network_mode")" || return 1

  if [[ "$new_network_mode" == "$old_network_mode" ]]; then
    ok "网络模式保持为 $(network_mode_label "$old_network_mode")。"
    show_config
    return 0
  fi

  if ! write_config "$old_port" "$old_password" "$new_network_mode" || ! write_openrc_service; then
    fail "写入新网络模式失败，正在恢复旧配置。"
    write_config "$old_port" "$old_password" "$old_network_mode" || true
    write_openrc_service || true
    return 1
  fi

  if ! start_or_restart_service || ! service_running; then
    fail "使用 $(network_mode_label "$new_network_mode") 启动失败，正在恢复旧模式。"
    write_config "$old_port" "$old_password" "$old_network_mode" || true
    write_openrc_service || true
    rc-service "$OPENRC_SERVICE" restart >/dev/null 2>&1 || true
    return 1
  fi

  ok "网络模式已改为 $(network_mode_label "$new_network_mode")。"
  show_config
}

show_status() {
  if ! is_installed; then
    warn "AnyTLS 未安装。"
    return 1
  fi

  printf '安装版本：%s\n' "$(current_version)"
  rc-service "$OPENRC_SERVICE" status || true
  if load_config; then
    printf '网络模式：%s\n' "$(network_mode_label "$ANYTLS_NETWORK_MODE")"
    printf '监听地址：%s:%s/TCP\n' "$ANYTLS_LISTEN_HOST" "$ANYTLS_PORT"
  fi
}

show_logs() {
  if ! is_installed; then
    fail "AnyTLS 尚未安装。"
    return 1
  fi

  printf '%s\n' "----- ${STDOUT_LOG} -----"
  [[ -f "$STDOUT_LOG" ]] && tail -n 100 "$STDOUT_LOG" || printf '暂无标准输出日志。\n'
  printf '%s\n' "----- ${STDERR_LOG} -----"
  [[ -f "$STDERR_LOG" ]] && tail -n 100 "$STDERR_LOG" || printf '暂无错误日志。\n'
}

uninstall_anytls() {
  local answer=""

  if ! is_installed && [[ ! -e "$SERVER_BIN" && ! -e "$OPENRC_SCRIPT" ]]; then
    warn "AnyTLS 未安装。"
    return 0
  fi

  read -r -p "确认停止服务并删除 AnyTLS 程序、配置和日志？[y/N] " answer
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    info "已取消卸载。"
    return 0
  fi

  if command -v rc-service >/dev/null 2>&1; then
    rc-service "$OPENRC_SERVICE" stop >/dev/null 2>&1 || true
  fi
  if command -v rc-update >/dev/null 2>&1; then
    rc-update del "$OPENRC_SERVICE" default >/dev/null 2>&1 || true
  fi

  rm -f -- "$OPENRC_SCRIPT" "$OPENRC_CONFIG" "$STDOUT_LOG" "$STDERR_LOG"
  rm -rf -- "$CONFIG_DIR"
  ok "AnyTLS 已卸载。"
}

installation_status() {
  if is_installed; then
    if service_running; then
      printf '%s已安装，运行中%s' "$C_GREEN" "$C_RESET"
    else
      printf '%s已安装，未运行%s' "$C_YELLOW" "$C_RESET"
    fi
  else
    printf '%s未安装%s' "$C_RED" "$C_RESET"
  fi
}

pause_menu() {
  read -r -p "按回车返回菜单……" _ || true
}

menu() {
  local choice=""

  while true; do
    clear 2>/dev/null || true
    printf '%s\n' '========================================'
    printf ' AnyTLS Alpine/OpenRC 管理脚本 v%s\n' "$SCRIPT_VERSION"
    printf ' 系统：Alpine %s\n' "$(cat /etc/alpine-release)"
    printf ' 状态：%s\n' "$(installation_status)"
    is_installed && printf ' 版本：%s\n' "$(current_version)"
    printf '%s\n' '========================================'
    printf ' 1. 安装/重装 AnyTLS\n'
    printf ' 2. 更新 AnyTLS\n'
    printf ' 3. 查看客户端配置\n'
    printf ' 4. 更改端口\n'
    printf ' 5. 更改密码\n'
    printf ' 6. 更改 IPv4/IPv6 模式\n'
    printf ' 7. 查看服务状态\n'
    printf ' 8. 查看日志\n'
    printf ' 9. 卸载 AnyTLS\n'
    printf ' 0. 退出\n'
    printf '%s\n' '========================================'
    read -r -p "请输入数字 [0-9]：" choice || exit 0

    case "$choice" in
      1) install_anytls; pause_menu ;;
      2) update_anytls; pause_menu ;;
      3) show_config; pause_menu ;;
      4) change_port; pause_menu ;;
      5) change_password; pause_menu ;;
      6) change_network_mode; pause_menu ;;
      7) show_status; pause_menu ;;
      8) show_logs; pause_menu ;;
      9) uninstall_anytls; pause_menu ;;
      0) exit 0 ;;
      *) warn "无效选项。"; pause_menu ;;
    esac
  done
}

usage() {
  cat <<'USAGE_EOF'
用法：
  bash anytls-alpine.sh                 打开交互菜单
  bash anytls-alpine.sh install         安装或重装
  bash anytls-alpine.sh update          更新
  bash anytls-alpine.sh config          查看客户端配置
  bash anytls-alpine.sh status          查看服务状态
  bash anytls-alpine.sh logs            查看最近日志
  bash anytls-alpine.sh port            更改端口
  bash anytls-alpine.sh password        更改密码
  bash anytls-alpine.sh network         更改 IPv4/IPv6 模式
  bash anytls-alpine.sh uninstall       卸载
USAGE_EOF
}

main() {
  local action="${1:-menu}"

  case "$action" in
    -h | --help | help)
      usage
      return 0
      ;;
  esac

  ensure_root
  ensure_alpine

  case "$action" in
    menu) menu ;;
    install | reinstall) install_anytls ;;
    update) update_anytls ;;
    config | show) show_config ;;
    status) show_status ;;
    logs | log) show_logs ;;
    port) change_port ;;
    password | passwd) change_password ;;
    network | mode | ip) change_network_mode ;;
    uninstall | remove) uninstall_anytls ;;
    *)
      fail "未知命令：${action}"
      usage
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
