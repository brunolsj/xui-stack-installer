#!/usr/bin/env bash
# 3x-ui + Xray + VLESS-TLS-Vision + Hysteria2 + acme.sh installer
# Supported: Ubuntu, Debian, CentOS Stream (systemd), amd64/arm64

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly SCRIPT_VERSION="0.1.4"
readonly STACK_DIR="/etc/xui-stack"
readonly CERT_ROOT="${STACK_DIR}/certs"
readonly STATE_FILE="${STACK_DIR}/state.env"
readonly LINKS_FILE="${STACK_DIR}/client-links.txt"
readonly BACKUP_ROOT="/var/backups/xui-stack"
readonly LIBEXEC_DIR="/usr/local/libexec"
readonly RELOAD_HOOK="${LIBEXEC_DIR}/xui-stack-cert-reload"
readonly STACKCTL_BIN="/usr/local/sbin/stackctl"
readonly XUI_BIN="/usr/local/x-ui/x-ui"
readonly XUI_INSTALL_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh"
readonly ACME_BOOTSTRAP_URL="https://get.acme.sh"
readonly MIN_XUI_VERSION="3.6.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

TEMP_DIR=""
LOG_FILE=""
OS_FAMILY=""
OS_ID=""
OS_VERSION=""
ARCH=""

DOMAIN=""
ACME_EMAIL=""
ACME_MODE=""
CF_AUTH_MODE=""
CF_TOKEN_VALUE=""
CF_ZONE_ID_VALUE=""
CF_ACCOUNT_ID_VALUE=""
CF_KEY_VALUE=""
CF_EMAIL_VALUE=""
INCLUDE_WILDCARD="false"
PANEL_PORT=""
VLESS_PORT=""
HY2_PORT=""
PANEL_USER=""
PANEL_PASSWORD=""
PANEL_PATH=""
VLESS_UUID=""
VLESS_EMAIL="vless-default"
HY2_AUTH=""
HY2_EMAIL="hysteria2-default"
CERT_DIR=""
CERT_FILE=""
KEY_FILE=""
XUI_API_TOKEN=""

info() { printf '%b[信息]%b %s\n' "$CYAN" "$PLAIN" "$*"; }
ok() { printf '%b[完成]%b %s\n' "$GREEN" "$PLAIN" "$*"; }
warn() { printf '%b[警告]%b %s\n' "$YELLOW" "$PLAIN" "$*" >&2; }
die() { printf '%b[错误]%b %s\n' "$RED" "$PLAIN" "$*" >&2; exit 1; }

cleanup() {
  local rc=$?
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
  CF_TOKEN_VALUE=""
  CF_KEY_VALUE=""
  PANEL_PASSWORD=""
  HY2_AUTH=""
  if (( rc != 0 )); then
    warn "安装未完成。请查看日志：${LOG_FILE:-尚未创建}"
  fi
}

on_error() {
  local rc=$1 line=$2
  warn "命令在第 ${line} 行失败，退出码 ${rc}。"
}

trap 'on_error "$?" "$LINENO"' ERR
trap cleanup EXIT INT TERM

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "必须使用 root 用户运行。"
}

require_tty() {
  [[ -t 0 && -t 1 ]] || die "本安装器包含破坏性操作确认，必须在交互式终端中运行。"
}

startup_menu() {
  local choice
  while true; do
    printf '\n%b3x-ui + VLESS + Hysteria2 管理菜单%b\n' "$CYAN" "$PLAIN"
    printf '  1. 清除现有配置和相关服务，并重新安装（无旧安装时为全新安装）\n'
    printf '  2. 显示当前保存的安装结果配置（只读，不修改服务）\n'
    printf '  0. 退出\n'
    read -r -p '请选择 [0-2]：' choice
    case "$choice" in
      1) return 0 ;;
      2)
        if [[ ! -r "$STATE_FILE" ]]; then
          warn "没有找到可读取的安装状态：$STATE_FILE"
          continue
        fi
        show_saved_installation
        exit 0
        ;;
      0) exit 0 ;;
      *) warn "无效选择，请输入 0、1 或 2。" ;;
    esac
  done
}

confirm() {
  local prompt=$1 default=${2:-no} answer
  if [[ "$default" == "yes" ]]; then
    read -r -p "${prompt} [Y/n]: " answer
    [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
  else
    read -r -p "${prompt} [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
  fi
}

read_required() {
  local prompt=$1 var_name=$2 value
  while true; do
    read -r -p "$prompt" value
    value=${value//$'\r'/}
    if [[ -n "$value" ]]; then
      printf -v "$var_name" '%s' "$value"
      return 0
    fi
    warn "此项不能为空。"
  done
}

validate_domain() {
  local value=$1
  [[ ${#value} -le 253 ]] || return 1
  [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

random_hex() {
  openssl rand -hex "$1"
}

random_base64url() {
  openssl rand -base64 "$1" | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

urlencode() {
  jq -nr --arg value "$1" '$value|@uri'
}

detect_platform() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID,,}
  OS_VERSION=${VERSION_ID:-0}

  case "$OS_ID" in
    ubuntu)
      OS_FAMILY="debian"
      ;;
    debian)
      OS_FAMILY="debian"
      ;;
    centos|centos-stream)
      OS_FAMILY="rhel"
      ;;
    *)
      die "不支持的操作系统：${PRETTY_NAME:-$OS_ID}。仅支持 Ubuntu、Debian、CentOS Stream。"
      ;;
  esac

  local major=${OS_VERSION%%.*}
  case "$OS_ID" in
    ubuntu) (( major >= 20 )) || die "最低支持 Ubuntu 20.04。" ;;
    debian) (( major >= 11 )) || die "最低支持 Debian 11。" ;;
    centos|centos-stream) (( major >= 9 )) || die "CentOS 7/8 已停止支持，请使用 CentOS Stream 9 或更高版本。" ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "仅支持 amd64/x86_64 和 arm64/aarch64。" ;;
  esac

  [[ -d /run/systemd/system ]] || die "此脚本要求 systemd。"
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl。"
  ok "系统：${PRETTY_NAME:-$OS_ID}，架构：${ARCH}"
}

init_runtime() {
  TEMP_DIR=$(mktemp -d -t xui-stack.XXXXXXXX)
  install -d -m 0700 "$STACK_DIR"
  LOG_FILE="${STACK_DIR}/install-$(date -u +%Y%m%dT%H%M%SZ).log"
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "安装日志：$LOG_FILE"
}

install_dependencies() {
  info "更新软件索引并安装依赖……"
  if [[ "$OS_FAMILY" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      ca-certificates curl wget tar unzip openssl socat cron jq iproute2 \
      util-linux coreutils findutils grep sed gawk uuid-runtime
    systemctl enable --now cron
  else
    dnf -y makecache
    dnf -y install \
      ca-certificates curl wget tar unzip openssl socat cronie jq iproute \
      util-linux coreutils findutils grep sed gawk
    dnf -y upgrade \
      ca-certificates curl wget tar unzip openssl socat cronie jq iproute \
      util-linux coreutils findutils grep sed gawk
    systemctl enable --now crond
  fi

  local cmd
  for cmd in curl openssl jq ss tar systemctl sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || die "依赖安装后仍未找到：$cmd"
  done
  update-ca-certificates >/dev/null 2>&1 || true
  ok "依赖已就绪。"
}

inventory_old_installation() {
  local -a units=(x-ui.service xray.service xray@.service hysteria-server.service hysteria.service)
  local -a paths=(
    /etc/x-ui
    /usr/local/x-ui
    /usr/bin/x-ui
    /usr/local/bin/xray
    /usr/local/etc/xray
    /etc/default/x-ui
    /etc/sysconfig/x-ui
    /etc/conf.d/x-ui
    /etc/systemd/system/x-ui.service
    /etc/systemd/system/xray.service
    /etc/systemd/system/xray@.service
    /etc/systemd/system/hysteria-server.service
    /etc/systemd/system/hysteria.service
    /usr/local/bin/hysteria
    /etc/hysteria
    /root/cert
    "$STACK_DIR"
    "$RELOAD_HOOK"
    "$STACKCTL_BIN"
  )
  local found=0 unit path

  printf '\n%b安装前扫描%b\n' "$CYAN" "$PLAIN"
  for unit in "${units[@]}"; do
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .; then
      printf '  服务：%s (%s)\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
      found=1
    fi
  done
  for path in "${paths[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
      printf '  路径：%s\n' "$path"
      found=1
    fi
  done

  if (( found == 0 )); then
    ok "未发现旧版 x-ui/Xray/Hysteria 安装。"
    return 0
  fi

  printf '\n'
  warn "将停止上述相关服务，备份后删除所列路径。不会删除 ~/.acme.sh 账户目录或其他网站证书。"
  read -r -p "如确认清理，请输入 DELETE：" answer
  [[ "$answer" == "DELETE" ]] || die "用户取消清理，安装终止。"
  backup_and_remove_old
}

backup_and_remove_old() {
  local stamp backup_file unit path rel
  local -a units=(x-ui.service xray.service xray@.service hysteria-server.service hysteria.service)
  local -a paths=(
    /etc/x-ui
    /usr/local/x-ui
    /usr/bin/x-ui
    /usr/local/bin/xray
    /usr/local/etc/xray
    /etc/default/x-ui
    /etc/sysconfig/x-ui
    /etc/conf.d/x-ui
    /etc/systemd/system/x-ui.service
    /etc/systemd/system/xray.service
    /etc/systemd/system/xray@.service
    /etc/systemd/system/hysteria-server.service
    /etc/systemd/system/hysteria.service
    /usr/local/bin/hysteria
    /etc/hysteria
    /root/cert
    "$STACK_DIR"
    "$RELOAD_HOOK"
    "$STACKCTL_BIN"
  )
  local -a relative_paths=()

  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  install -d -m 0700 "$BACKUP_ROOT"
  backup_file="${BACKUP_ROOT}/before-${stamp}.tar.gz"

  for path in "${paths[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
      rel=${path#/}
      relative_paths+=("$rel")
    fi
  done

  if (( ${#relative_paths[@]} > 0 )); then
    tar -czpf "$backup_file" -C / -- "${relative_paths[@]}"
    chmod 0600 "$backup_file"
    ok "旧文件已备份：$backup_file"
  fi

  for unit in "${units[@]}"; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
  done
  for path in "${paths[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
      rm -rf -- "$path"
    fi
  done
  systemctl daemon-reload
  ok "旧版程序、配置及其部署证书副本已清理。"

}

port_in_use() {
  local proto=$1 port=$2 output
  if [[ "$proto" == "tcp" ]]; then
    output=$(ss -H -lnt "sport = :${port}" 2>/dev/null || true)
  else
    output=$(ss -H -lnu "sport = :${port}" 2>/dev/null || true)
  fi
  [[ -n "$output" ]]
}

reserved_port() {
  local port=$1
  case "$port" in
    20|21|22|23|25|53|67|68|69|80|110|123|143|161|389|443|465|587|636|853|993|995|1433|1521|2049|2375|2376|3306|3389|5432|5672|6379|6443|8080|8443|9200|9300|11211|27017) return 0 ;;
    *) return 1 ;;
  esac
}

in_ephemeral_range() {
  local port=$1 low=32768 high=60999
  if [[ -r /proc/sys/net/ipv4/ip_local_port_range ]]; then
    read -r low high < /proc/sys/net/ipv4/ip_local_port_range || true
  fi
  (( port >= low && port <= high ))
}

generate_port() {
  local proto=$1 port raw i
  for ((i=0; i<300; i++)); do
    raw=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    port=$((10240 + raw % (65535 - 10240 + 1)))
    reserved_port "$port" && continue
    in_ephemeral_range "$port" && continue
    [[ "$port" == "$PANEL_PORT" || "$port" == "$VLESS_PORT" || "$port" == "$HY2_PORT" ]] && continue
    port_in_use "$proto" "$port" && continue
    printf '%s' "$port"
    return 0
  done
  return 1
}

prompt_port() {
  local label=$1 proto=$2 var_name=$3 value
  while true; do
    read -r -p "请输入 ${label}，直接回车随机生成：" value
    if [[ -z "$value" ]]; then
      value=$(generate_port "$proto") || die "无法生成可用的随机端口。"
    fi
    if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1024 || value > 65535 )); then
      warn "端口必须是 1024-65535 之间的整数。"
      continue
    fi
    if reserved_port "$value"; then
      warn "该端口属于常见保留服务端口，请换一个。"
      continue
    fi
    if port_in_use "$proto" "$value"; then
      warn "${value}/${proto} 已被占用。"
      continue
    fi
    if [[ "$value" == "$PANEL_PORT" || "$value" == "$VLESS_PORT" || "$value" == "$HY2_PORT" ]]; then
      warn "该端口已被本次安装的其他组件选中。"
      continue
    fi
    printf -v "$var_name" '%s' "$value"
    return 0
  done
}

collect_inputs() {
  printf '\n%b基础配置%b\n' "$CYAN" "$PLAIN"
  while true; do
    read_required "请输入证书和节点域名：" DOMAIN
    DOMAIN=${DOMAIN,,}
    validate_domain "$DOMAIN" && break
    warn "域名格式不正确，例如 node.example.com。"
  done
  while true; do
    read_required "请输入 ACME 注册邮箱：" ACME_EMAIL
    validate_email "$ACME_EMAIL" && break
    warn "邮箱格式不正确。"
  done

  printf '\n证书签发方式：\n  1. Cloudflare API Token（推荐）\n  2. Cloudflare Global API Key + 注册邮箱\n  3. HTTP-01 standalone\n'
  local choice
  while true; do
    read -r -p "请选择 [1-3]：" choice
    case "$choice" in
      1) ACME_MODE="dns_cf"; CF_AUTH_MODE="token"; break ;;
      2) ACME_MODE="dns_cf"; CF_AUTH_MODE="global"; break ;;
      3) ACME_MODE="http"; CF_AUTH_MODE=""; break ;;
      *) warn "请输入 1、2 或 3。" ;;
    esac
  done

  if [[ "$CF_AUTH_MODE" == "token" ]]; then
    read_required "请输入 Cloudflare API Token（输入内容可见）：" CF_TOKEN_VALUE
    printf '  1. Zone ID（单个 Zone，推荐）\n  2. Account ID（同一账户内多个 Zone）\n'
    while true; do
      read -r -p "请选择 ID 类型 [1-2]：" choice
      case "$choice" in
        1) read_required "请输入 Cloudflare Zone ID：" CF_ZONE_ID_VALUE; break ;;
        2) read_required "请输入 Cloudflare Account ID：" CF_ACCOUNT_ID_VALUE; break ;;
        *) warn "请输入 1 或 2。" ;;
      esac
    done
  elif [[ "$CF_AUTH_MODE" == "global" ]]; then
    warn "Global API Key 可控制整个 Cloudflare 账户，强烈建议改用最小权限 API Token。"
    confirm "仍然使用 Global API Key？" no || die "用户取消使用 Global API Key。"
    while true; do
      read_required "请输入 Cloudflare 注册邮箱：" CF_EMAIL_VALUE
      validate_email "$CF_EMAIL_VALUE" && break
      warn "邮箱格式不正确。"
    done
    read_required "请输入 Cloudflare Global API Key（输入内容可见）：" CF_KEY_VALUE
  fi

  if [[ "$ACME_MODE" == "dns_cf" ]]; then
    if confirm "是否同时申请 *.${DOMAIN} 通配符证书？" no; then
      INCLUDE_WILDCARD="true"
    fi
  fi

  prompt_port "3x-ui 面板 TCP 端口" tcp PANEL_PORT
  prompt_port "VLESS TCP 端口" tcp VLESS_PORT
  prompt_port "Hysteria2 UDP 端口" udp HY2_PORT

  PANEL_USER="admin_$(random_hex 4)"
  PANEL_PASSWORD=$(random_base64url 24)
  PANEL_PATH="panel-$(random_hex 12)"
  VLESS_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
  HY2_AUTH=$(random_base64url 32)
  CERT_DIR="${CERT_ROOT}/${DOMAIN}"
  CERT_FILE="${CERT_DIR}/fullchain.pem"
  KEY_FILE="${CERT_DIR}/privkey.pem"

  printf '\n%b配置摘要%b\n' "$CYAN" "$PLAIN"
  printf '  域名：%s\n  ACME：%s\n  面板：%s/tcp\n  VLESS：%s/tcp\n  Hysteria2：%s/udp\n' \
    "$DOMAIN" "$ACME_MODE" "$PANEL_PORT" "$VLESS_PORT" "$HY2_PORT"
  confirm "确认以上配置并开始安装？" yes || die "用户取消安装。"
}

verify_http_challenge_prerequisites() {
  [[ "$ACME_MODE" == "http" ]] || return 0
  if port_in_use tcp 80; then
    ss -H -lntp "sport = :80" || true
    die "HTTP-01 需要 TCP 80，目前端口已被占用。请释放端口或改用 Cloudflare DNS-01。"
  fi

  local resolved public4 public6
  resolved=$(getent ahosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)
  [[ -n "$resolved" ]] || die "域名 $DOMAIN 当前无法解析。"
  public4=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
  public6=$(curl -6fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)
  if [[ -n "$public4" || -n "$public6" ]]; then
    if ! grep -Fxq "$public4" <<<"$resolved" && ! grep -Fxq "$public6" <<<"$resolved"; then
      printf '域名解析结果：\n%s\n公网 IPv4：%s\n公网 IPv6：%s\n' "$resolved" "${public4:-无}" "${public6:-无}"
      die "域名解析未指向本机公网地址。"
    fi
  else
    warn "无法自动查询公网 IP，将由 ACME 服务完成最终校验。"
  fi
}

download_script() {
  local url=$1 output=$2 expected_sha=${3:-}
  curl -fL --retry 3 --connect-timeout 15 --proto '=https' --tlsv1.2 "$url" -o "$output"
  [[ -s "$output" ]] || die "下载结果为空：$url"
  grep -Eq '^#!.*(bash|sh)' "$output" || die "下载内容不像 Shell 脚本：$url"
  if [[ -n "$expected_sha" ]]; then
    printf '%s  %s\n' "$expected_sha" "$output" | sha256sum -c -
  fi
  info "已下载 $(basename "$output")，SHA256=$(sha256sum "$output" | awk '{print $1}')"
}

install_3xui() {
  local installer="${TEMP_DIR}/3x-ui-install.sh"
  download_script "$XUI_INSTALL_URL" "$installer" "${XUI_INSTALL_SHA256:-}"
  chmod 0700 "$installer"

  info "安装 3x-ui 稳定版……"
  export XUI_NONINTERACTIVE=1
  export XUI_USERNAME="$PANEL_USER"
  export XUI_PASSWORD="$PANEL_PASSWORD"
  export XUI_PANEL_PORT="$PANEL_PORT"
  export XUI_WEB_BASE_PATH="$PANEL_PATH"
  export XUI_SSL_MODE="none"
  export XUI_DB_TYPE="sqlite"

  if [[ -n ${XUI_VERSION:-} ]]; then
    bash "$installer" "$XUI_VERSION"
  else
    bash "$installer"
  fi

  unset XUI_USERNAME XUI_PASSWORD
  [[ -x "$XUI_BIN" ]] || die "3x-ui 安装完成后未找到 $XUI_BIN。"
  systemctl enable --now x-ui
  systemctl is-active --quiet x-ui || die "x-ui.service 未正常启动。"

  local installed_version
  installed_version=$($XUI_BIN -v 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
  if [[ -n "$installed_version" ]] && ! version_ge "$installed_version" "$MIN_XUI_VERSION"; then
    die "3x-ui ${installed_version} 低于 Hysteria2 所需最低版本 ${MIN_XUI_VERSION}。"
  fi
  ok "3x-ui 已安装${installed_version:+：$installed_version}。"
}

version_ge() {
  local highest
  highest=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)
  [[ "$highest" == "$1" ]]
}

install_reload_hook() {
  install -d -m 0755 "$LIBEXEC_DIR"
  cat > "$RELOAD_HOOK" <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE_FILE="/etc/xui-stack/state.env"
[[ -r "$STATE_FILE" ]] || exit 0

read_state() {
  local key=$1
  sed -n "s/^${key}=//p" "$STATE_FILE" | head -n1
}

CERT_FILE=$(read_state CERT_FILE)
KEY_FILE=$(read_state KEY_FILE)
DOMAIN=$(read_state DOMAIN)
[[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || exit 1

cert_pub=$(openssl x509 -in "$CERT_FILE" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
key_pub=$(openssl pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
[[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || exit 1
openssl x509 -in "$CERT_FILE" -checkend 86400 -noout >/dev/null
openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null | grep -Fq "$DOMAIN"

chmod 0644 "$CERT_FILE"
chmod 0640 "$KEY_FILE"
if systemctl is-active --quiet x-ui.service; then
  systemctl restart x-ui.service
  systemctl is-active --quiet x-ui.service
fi
HOOK
  chmod 0750 "$RELOAD_HOOK"
}

run_acme_issue() {
  local rc
  if "$@"; then
    return 0
  else
    rc=$?
  fi

  # acme.sh returns 2 when the existing certificate is not due for renewal.
  # It is still valid input for the --install-cert deployment step below.
  if (( rc == 2 )); then
    info "现有证书尚未到续期时间，将直接复用并部署该证书。"
    return 0
  fi
  return "$rc"
}

install_acme() {
  local acme="$HOME/.acme.sh/acme.sh"
  if [[ ! -x "$acme" ]]; then
    local bootstrap="${TEMP_DIR}/get-acme.sh"
    download_script "$ACME_BOOTSTRAP_URL" "$bootstrap" "${ACME_BOOTSTRAP_SHA256:-}"
    sh "$bootstrap" email="$ACME_EMAIL"
  fi
  [[ -x "$acme" ]] || die "acme.sh 安装失败。"
  "$acme" --upgrade --auto-upgrade
  "$acme" --set-default-ca --server letsencrypt
  install_reload_hook

  install -d -m 0750 "$CERT_DIR"
  : > "$CERT_FILE"
  : > "$KEY_FILE"
  chmod 0644 "$CERT_FILE"
  chmod 0640 "$KEY_FILE"

  info "申请证书……"
  local -a issue_args=(--issue -d "$DOMAIN" --keylength ec-256)
  if [[ "$INCLUDE_WILDCARD" == "true" ]]; then
    issue_args+=( -d "*.${DOMAIN}" )
  fi

  local issue_rc=0
  if [[ "$ACME_MODE" == "dns_cf" ]]; then
    if [[ "$CF_AUTH_MODE" == "token" ]]; then
      export CF_Token="$CF_TOKEN_VALUE"
      [[ -n "$CF_ZONE_ID_VALUE" ]] && export CF_Zone_ID="$CF_ZONE_ID_VALUE"
      [[ -n "$CF_ACCOUNT_ID_VALUE" ]] && export CF_Account_ID="$CF_ACCOUNT_ID_VALUE"
    else
      export CF_Key="$CF_KEY_VALUE"
      export CF_Email="$CF_EMAIL_VALUE"
    fi
    if run_acme_issue "$acme" "${issue_args[@]}" --dns dns_cf; then
      issue_rc=0
    else
      issue_rc=$?
    fi
    unset CF_Token CF_Zone_ID CF_Account_ID CF_Key CF_Email
  else
    if run_acme_issue "$acme" "${issue_args[@]}" --standalone; then
      issue_rc=0
    else
      issue_rc=$?
    fi
  fi
  (( issue_rc == 0 )) || die "acme.sh 证书签发失败，退出码：${issue_rc}。"

  "$acme" --install-cert -d "$DOMAIN" --ecc \
    --key-file "$KEY_FILE" \
    --fullchain-file "$CERT_FILE" \
    --reloadcmd "$RELOAD_HOOK"

  validate_certificate
  ok "证书已部署到 $CERT_DIR。"
}

validate_certificate() {
  [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || die "证书或私钥为空。"
  openssl x509 -in "$CERT_FILE" -noout >/dev/null || die "证书格式无效。"
  openssl pkey -in "$KEY_FILE" -noout >/dev/null || die "私钥格式无效。"
  local cert_pub key_pub
  cert_pub=$(openssl x509 -in "$CERT_FILE" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  key_pub=$(openssl pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  [[ "$cert_pub" == "$key_pub" ]] || die "证书和私钥不匹配。"
  openssl x509 -in "$CERT_FILE" -checkend 86400 -noout || die "证书有效期不足 24 小时。"
  openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null | grep -Fq "$DOMAIN" || die "证书 SAN 不包含 $DOMAIN。"
  chmod 0644 "$CERT_FILE"
  chmod 0640 "$KEY_FILE"
}

print_certificate_export() {
  local cert=${1:-$CERT_FILE} key=${2:-$KEY_FILE} fingerprint
  [[ -r "$cert" ]] || die "无法读取证书链：$cert"
  openssl x509 -in "$cert" -noout >/dev/null || die "证书格式无效：$cert"
  fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | cut -d= -f2-)
  [[ -n "$fingerprint" ]] || die "无法计算证书 SHA-256 指纹。"

  printf '\n%b================ TLS 证书（可复制到 v2rayN） ================%b\n' "$CYAN" "$PLAIN"
  printf '证书链（公钥证书）路径：%s\n' "$cert"
  printf '私钥路径（仅显示路径，不输出私钥）：%s\n' "$key"
  printf '证书指纹（SHA-256）：%s\n' "$fingerprint"
  printf '\n完整证书链（PEM）：\n'
  cat -- "$cert"
  printf '\n%b================================================================%b\n' "$CYAN" "$PLAIN"
}

configure_panel_tls() {
  info "为 3x-ui 面板配置 TLS……"
  if ! "$XUI_BIN" cert -webCert "$CERT_FILE" -webCertKey "$KEY_FILE"; then
    warn "cert 子命令不可用，尝试 setting 兼容方式。"
    "$XUI_BIN" setting -webCert "$CERT_FILE" -webCertKey "$KEY_FILE"
  fi
  systemctl restart x-ui
  wait_for_panel
  ok "面板 HTTPS 已启用。"
}

panel_url() {
  printf 'https://%s:%s/%s/' "$DOMAIN" "$PANEL_PORT" "$PANEL_PATH"
}

panel_curl() {
  curl -fsS --noproxy '*' --connect-timeout 5 --max-time 20 \
    --resolve "${DOMAIN}:${PANEL_PORT}:127.0.0.1" "$@"
}

wait_for_panel() {
  local url i
  url=$(panel_url)
  for ((i=0; i<30; i++)); do
    if panel_curl "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  systemctl status x-ui --no-pager || true
  journalctl -u x-ui -n 80 --no-pager || true
  die "面板未能在 HTTPS 地址启动。"
}

env_value() {
  local file=$1 key=$2 value
  value=$(sed -n "s/^${key}=//p" "$file" | head -n1)
  value=${value#\"}
  value=${value%\"}
  value=${value#\'}
  value=${value%\'}
  printf '%s' "$value"
}

load_xui_api_token() {
  local result_file="/etc/x-ui/install-result.env"
  [[ -r "$result_file" ]] || die "缺少 3x-ui 安装结果文件：$result_file"
  XUI_API_TOKEN=$(env_value "$result_file" XUI_API_TOKEN)
  [[ -n "$XUI_API_TOKEN" ]] || die "安装结果中没有 XUI_API_TOKEN。"
}

api_request() {
  local method=$1 endpoint=$2 data=${3:-}
  local -a args=(-X "$method" -H "Authorization: Bearer ${XUI_API_TOKEN}" -H 'Content-Type: application/json')
  [[ -n "$data" ]] && args+=(--data-binary "$data")
  panel_curl "${args[@]}" "$(panel_url)panel/api/${endpoint}"
}

tls_settings_json() {
  jq -nc \
    --arg domain "$DOMAIN" \
    --arg cert "$CERT_FILE" \
    --arg key "$KEY_FILE" \
    '{serverName:$domain,minVersion:"1.2",maxVersion:"1.3",cipherSuites:"",rejectUnknownSni:false,disableSystemRoot:false,enableSessionResumption:false,alpn:["h2","http/1.1"],echServerKeys:"",settings:{fingerprint:"chrome",echConfigList:"",pinnedPeerCertSha256:[],verifyPeerCertByName:""},certificates:[{certificateFile:$cert,keyFile:$key,ocspStapling:0,oneTimeLoading:false,usage:"encipherment",buildChain:false}]}'
}

create_vless_inbound() {
  local tls payload response sub_id
  tls=$(tls_settings_json)
  sub_id=$(random_hex 8)
  payload=$(jq -nc \
    --argjson port "$VLESS_PORT" \
    --arg uuid "$VLESS_UUID" \
    --arg email "$VLESS_EMAIL" \
    --arg sub "$sub_id" \
    --argjson tls "$tls" \
    '{enable:true,remark:"VLESS-TLS-Vision",listen:"",port:$port,protocol:"vless",expiryTime:0,total:0,settings:{clients:[{id:$uuid,email:$email,flow:"xtls-rprx-vision",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0}],decryption:"none",encryption:"none",fallbacks:[]},streamSettings:{network:"tcp",security:"tls",tlsSettings:$tls,tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}},sniffing:{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:false,domainsExcluded:[],ipsExcluded:[]}}')
  response=$(api_request POST inbounds/add "$payload")
  jq -e '.success == true' <<<"$response" >/dev/null || die "创建 VLESS 入站失败：$(jq -r '.msg // .' <<<"$response")"
  ok "VLESS-TLS-Vision 入站已创建：${VLESS_PORT}/tcp"
}

create_hy2_inbound() {
  local tls payload response sub_id
  tls=$(tls_settings_json | jq '.alpn=["h3"]')
  sub_id=$(random_hex 8)
  payload=$(jq -nc \
    --argjson port "$HY2_PORT" \
    --arg auth "$HY2_AUTH" \
    --arg email "$HY2_EMAIL" \
    --arg sub "$sub_id" \
    --argjson tls "$tls" \
    '{enable:true,remark:"Hysteria2",listen:"",port:$port,protocol:"hysteria",expiryTime:0,total:0,settings:{version:2,clients:[{auth:$auth,email:$email,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0}]},streamSettings:{network:"hysteria",security:"tls",tlsSettings:$tls,hysteriaSettings:{version:2,auth:"",udpIdleTimeout:60,masquerade:{type:"",dir:"",url:"",rewriteHost:false,insecure:false,content:"",headers:{},statusCode:0}}},sniffing:{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:false,domainsExcluded:[],ipsExcluded:[]}}')
  response=$(api_request POST inbounds/add "$payload")
  jq -e '.success == true' <<<"$response" >/dev/null || die "创建 Hysteria2 入站失败：$(jq -r '.msg // .' <<<"$response")"
  ok "Hysteria2 入站已创建：${HY2_PORT}/udp"
}

verify_api_configuration() {
  local response
  response=$(api_request GET inbounds/list)
  jq -e --argjson vp "$VLESS_PORT" --arg uuid "$VLESS_UUID" '
    .success == true and any(.obj[]; .protocol == "vless" and .port == $vp and any(.settings.clients[]; .id == $uuid))
  ' <<<"$response" >/dev/null || die "VLESS API 回读验证失败。"
  jq -e --argjson hp "$HY2_PORT" --arg auth "$HY2_AUTH" '
    .success == true and any(.obj[]; .protocol == "hysteria" and .port == $hp and any(.settings.clients[]; .auth == $auth))
  ' <<<"$response" >/dev/null || die "Hysteria2 auth 字段回读验证失败。"
}

save_state() {
  install -d -m 0700 "$STACK_DIR"
  cat > "$STATE_FILE" <<EOF
SCRIPT_VERSION=$SCRIPT_VERSION
DOMAIN=$DOMAIN
ACME_EMAIL=$ACME_EMAIL
ACME_MODE=$ACME_MODE
PANEL_PORT=$PANEL_PORT
PANEL_PATH=$PANEL_PATH
PANEL_USER=$PANEL_USER
CERT_FILE=$CERT_FILE
KEY_FILE=$KEY_FILE
VLESS_PORT=$VLESS_PORT
HY2_PORT=$HY2_PORT
VLESS_EMAIL=$VLESS_EMAIL
HY2_EMAIL=$HY2_EMAIL
EOF
  chmod 0600 "$STATE_FILE"
}

save_links() {
  local response links vless_link hy2_link
  response=$(api_request GET inbounds/allLinks || true)
  links=$(jq -r 'if .success == true and (.obj|type)=="array" then .obj[] else empty end' <<<"$response" 2>/dev/null || true)
  if [[ -z "$links" ]]; then
    vless_link="vless://${VLESS_UUID}@${DOMAIN}:${VLESS_PORT}?type=tcp&security=tls&sni=$(urlencode "$DOMAIN")&fp=chrome&flow=xtls-rprx-vision#VLESS-TLS-Vision"
    hy2_link="hysteria2://$(urlencode "$HY2_AUTH")@${DOMAIN}:${HY2_PORT}?sni=$(urlencode "$DOMAIN")#Hysteria2"
    links=$(printf '%s\n%s\n' "$vless_link" "$hy2_link")
  fi
  printf '%s\n' "$links" > "$LINKS_FILE"
  chmod 0600 "$LINKS_FILE"
}

install_stackctl() {
  cat > "$STACKCTL_BIN" <<'STACKCTL'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE_FILE="/etc/xui-stack/state.env"
LINKS_FILE="/etc/xui-stack/client-links.txt"
RESULT_FILE="/etc/x-ui/install-result.env"
ACME="/root/.acme.sh/acme.sh"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "请使用 root 运行 stackctl。" >&2; exit 1; }

read_state() {
  local key=$1
  [[ -r "$STATE_FILE" ]] || { echo "缺少 $STATE_FILE" >&2; exit 1; }
  sed -n "s/^${key}=//p" "$STATE_FILE" | head -n1
}

read_result() {
  local key=$1 value
  [[ -r "$RESULT_FILE" ]] || return 0
  value=$(sed -n "s/^${key}=//p" "$RESULT_FILE" | head -n1)
  value=${value#\"}
  value=${value%\"}
  value=${value#\'}
  value=${value%\'}
  printf '%s' "$value"
}

status() {
  local domain panel_port panel_path vless_port hy2_port
  domain=$(read_state DOMAIN)
  panel_port=$(read_state PANEL_PORT)
  panel_path=$(read_state PANEL_PATH)
  vless_port=$(read_state VLESS_PORT)
  hy2_port=$(read_state HY2_PORT)
  echo "面板：https://${domain}:${panel_port}/${panel_path}/"
  echo "VLESS：${vless_port}/tcp"
  echo "Hysteria2：${hy2_port}/udp"
  systemctl --no-pager --full status x-ui.service || true
  echo
  ss -H -lntup | grep -E ":(${panel_port}|${vless_port}|${hy2_port})([[:space:]]|$)" || true
}

cert_info() {
  local cert key fingerprint
  cert=$(read_state CERT_FILE)
  key=$(read_state KEY_FILE)
  [[ -r "$cert" ]] || { echo "无法读取证书链：$cert" >&2; exit 1; }
  openssl x509 -in "$cert" -noout >/dev/null || { echo "证书格式无效：$cert" >&2; exit 1; }
  fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | cut -d= -f2-)

  echo "证书链（公钥证书）路径：$cert"
  echo "私钥路径（仅显示路径，不输出私钥）：$key"
  echo "证书指纹（SHA-256）：$fingerprint"
  echo
  openssl x509 -in "$cert" -noout -subject -issuer -dates -ext subjectAltName
  echo
  echo "完整证书链（PEM，可复制到 v2rayN）："
  cat -- "$cert"
  echo
}

summary() {
  local domain panel_port panel_path panel_user panel_password vless_port hy2_port vless_email hy2_email cert expiry
  domain=$(read_state DOMAIN)
  panel_port=$(read_state PANEL_PORT)
  panel_path=$(read_state PANEL_PATH)
  panel_user=$(read_result XUI_USERNAME)
  [[ -n "$panel_user" ]] || panel_user=$(read_state PANEL_USER)
  panel_password=$(read_result XUI_PASSWORD)
  vless_port=$(read_state VLESS_PORT)
  hy2_port=$(read_state HY2_PORT)
  vless_email=$(read_state VLESS_EMAIL)
  hy2_email=$(read_state HY2_EMAIL)
  vless_email=${vless_email:-vless-default}
  hy2_email=${hy2_email:-hysteria2-default}
  cert=$(read_state CERT_FILE)
  expiry=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2- || true)

  echo "安装结果（保存值）："
  echo "面板地址：https://${domain}:${panel_port}/${panel_path}/"
  echo "面板用户名：${panel_user:-无法读取}"
  echo "面板密码：${panel_password:-无法从 /etc/x-ui/install-result.env 读取}"
  echo "VLESS：${vless_port}/tcp，初始用户：${vless_email}"
  echo "Hysteria2：${hy2_port}/udp，初始用户：${hy2_email}"
  echo "证书到期：${expiry:-无法读取}"
  echo "客户端链接：sudo stackctl links"
  echo "面板管理：x-ui"
  echo "统一管理：stackctl status"
  echo "安装结果：$RESULT_FILE"
  echo "本脚本状态：$STATE_FILE"
  echo
  cert_info
  echo "警告：显示的是上次安装时保存的初始密码；如果密码已在面板中修改，请以新密码为准。" >&2
}

renew() {
  local domain
  domain=$(read_state DOMAIN)
  [[ -x "$ACME" ]] || { echo "未找到 acme.sh" >&2; exit 1; }
  "$ACME" --renew -d "$domain" --ecc --force
}

case "${1:-status}" in
  status) status ;;
  summary) summary ;;
  links) cat "$LINKS_FILE" ;;
  logs) journalctl -u x-ui.service -n "${2:-100}" --no-pager ;;
  restart) systemctl restart x-ui.service; systemctl is-active --quiet x-ui.service ;;
  cert) cert_info ;;
  renew) renew ;;
  panel)
    echo "https://$(read_state DOMAIN):$(read_state PANEL_PORT)/$(read_state PANEL_PATH)/"
    ;;
  *)
    echo "用法：stackctl {status|summary|links|logs [行数]|restart|cert|renew|panel}" >&2
    exit 2
    ;;
esac
STACKCTL
  chmod 0750 "$STACKCTL_BIN"
}

configure_firewall() {
  printf '\n需要放行：\n  %s/tcp（面板）\n  %s/tcp（VLESS）\n  %s/udp（Hysteria2）\n' "$PANEL_PORT" "$VLESS_PORT" "$HY2_PORT"
  confirm "是否自动添加防火墙规则？" yes || { warn "未修改防火墙，请在云安全组和本机防火墙中手动放行。"; return 0; }

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${PANEL_PORT}/tcp"
    ufw allow "${VLESS_PORT}/tcp"
    ufw allow "${HY2_PORT}/udp"
    ok "已添加 UFW 规则。"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp"
    firewall-cmd --permanent --add-port="${VLESS_PORT}/tcp"
    firewall-cmd --permanent --add-port="${HY2_PORT}/udp"
    firewall-cmd --reload
    ok "已添加 firewalld 规则。"
  else
    warn "未检测到活动的 UFW/firewalld，没有自动改写 nftables/iptables。请同时检查云厂商安全组。"
  fi
}

final_verification() {
  info "执行安装后验证……"
  validate_certificate
  systemctl is-enabled --quiet x-ui || die "x-ui.service 未设置开机启动。"
  systemctl is-active --quiet x-ui || die "x-ui.service 未运行。"
  wait_for_panel
  verify_api_configuration

  port_in_use tcp "$PANEL_PORT" || die "面板端口未监听。"
  port_in_use tcp "$VLESS_PORT" || die "VLESS TCP 端口未监听。"
  port_in_use udp "$HY2_PORT" || die "Hysteria2 UDP 端口未监听。"
  ok "面板、证书、VLESS 和 Hysteria2 配置验证通过。"
}

print_configuration_summary() {
  local title=$1 expiry
  expiry=$(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2-)
  printf '\n%b============================================================%b\n' "$GREEN" "$PLAIN"
  printf '%b%s%b\n' "$GREEN" "$title" "$PLAIN"
  printf '面板地址：https://%s:%s/%s/\n' "$DOMAIN" "$PANEL_PORT" "$PANEL_PATH"
  printf '面板用户名：%s\n' "$PANEL_USER"
  if [[ -n "$PANEL_PASSWORD" ]]; then
    if [[ -t 1 ]]; then
      printf '面板密码：' > /dev/tty
      printf '%s\n' "$PANEL_PASSWORD" > /dev/tty
    else
      printf '面板密码：%s\n' "$PANEL_PASSWORD"
    fi
  else
    printf '面板密码：无法从 /etc/x-ui/install-result.env 读取\n'
  fi
  printf 'VLESS：%s/tcp，初始用户：%s\n' "$VLESS_PORT" "$VLESS_EMAIL"
  printf 'Hysteria2：%s/udp，初始用户：%s\n' "$HY2_PORT" "$HY2_EMAIL"
  printf '证书到期：%s\n' "$expiry"
  printf '证书查看：sudo stackctl cert\n'
  printf '客户端链接：sudo stackctl links\n'
  printf '面板管理：x-ui\n'
  printf '统一管理：stackctl status\n'
  printf '安装结果：/etc/x-ui/install-result.env\n'
  printf '本脚本状态：%s\n' "$STATE_FILE"
  printf '%b============================================================%b\n' "$GREEN" "$PLAIN"
  print_certificate_export "$CERT_FILE" "$KEY_FILE"
}

print_summary() {
  print_configuration_summary "安装完成"
  warn "密码只在本次摘要中显示；请妥善保存，并在首次登录后开启 2FA。"
}

show_saved_installation() {
  local result_file="/etc/x-ui/install-result.env" saved_user saved_password
  DOMAIN=$(env_value "$STATE_FILE" DOMAIN)
  PANEL_PORT=$(env_value "$STATE_FILE" PANEL_PORT)
  PANEL_PATH=$(env_value "$STATE_FILE" PANEL_PATH)
  PANEL_USER=$(env_value "$STATE_FILE" PANEL_USER)
  CERT_FILE=$(env_value "$STATE_FILE" CERT_FILE)
  KEY_FILE=$(env_value "$STATE_FILE" KEY_FILE)
  VLESS_PORT=$(env_value "$STATE_FILE" VLESS_PORT)
  HY2_PORT=$(env_value "$STATE_FILE" HY2_PORT)
  VLESS_EMAIL=$(env_value "$STATE_FILE" VLESS_EMAIL)
  HY2_EMAIL=$(env_value "$STATE_FILE" HY2_EMAIL)
  VLESS_EMAIL=${VLESS_EMAIL:-vless-default}
  HY2_EMAIL=${HY2_EMAIL:-hysteria2-default}

  if [[ -r "$result_file" ]]; then
    saved_user=$(env_value "$result_file" XUI_USERNAME)
    saved_password=$(env_value "$result_file" XUI_PASSWORD)
    [[ -n "$saved_user" ]] && PANEL_USER=$saved_user
    PANEL_PASSWORD=$saved_password
  else
    PANEL_PASSWORD=""
  fi

  [[ -n "$DOMAIN" && -n "$PANEL_PORT" && -n "$PANEL_PATH" ]] || die "状态文件缺少面板配置。"
  [[ -n "$CERT_FILE" && -n "$KEY_FILE" ]] || die "状态文件缺少证书路径。"
  print_configuration_summary "当前保存的安装结果"
  warn "显示的是上次安装时保存的初始密码；如果密码已在面板中修改，请以新密码为准。"
}

main() {
  require_root
  require_tty
  startup_menu
  detect_platform
  install_dependencies
  inventory_old_installation
  init_runtime
  collect_inputs
  verify_http_challenge_prerequisites
  install_3xui
  install_acme
  save_state
  configure_panel_tls
  load_xui_api_token
  create_vless_inbound
  create_hy2_inbound
  save_links
  install_stackctl
  configure_firewall
  final_verification
  print_summary
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
