#!/usr/bin/env bash
# Display the xui-stack certificate fingerprint, paths and public PEM chain.

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_STATE_FILE="/etc/xui-stack/state.env"
STATE_FILE=${XUI_STACK_STATE_FILE:-$DEFAULT_STATE_FILE}

die() {
  printf '[错误] %s\n' "$*" >&2
  exit 1
}

read_state() {
  local key=$1
  [[ -r "$STATE_FILE" ]] || die "无法读取状态文件：$STATE_FILE（请使用 sudo 运行）"
  sed -n "s/^${key}=//p" "$STATE_FILE" | head -n1
}

main() {
  local cert key fingerprint
  command -v openssl >/dev/null 2>&1 || die "未找到 openssl。"

  cert=${1:-$(read_state CERT_FILE)}
  key=${2:-$(read_state KEY_FILE)}
  [[ -n "$cert" ]] || die "状态文件中缺少 CERT_FILE。"
  [[ -n "$key" ]] || die "状态文件中缺少 KEY_FILE。"
  [[ -r "$cert" ]] || die "无法读取证书链：$cert"
  openssl x509 -in "$cert" -noout >/dev/null || die "证书格式无效：$cert"
  fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | cut -d= -f2-)
  [[ -n "$fingerprint" ]] || die "无法计算证书 SHA-256 指纹。"

  printf '证书链（公钥证书）路径：%s\n' "$cert"
  printf '私钥路径（仅显示路径，不输出私钥）：%s\n' "$key"
  printf '证书指纹（SHA-256）：%s\n' "$fingerprint"
  printf '\n证书信息：\n'
  openssl x509 -in "$cert" -noout -subject -issuer -dates -ext subjectAltName
  printf '\n完整证书链（PEM，可复制到 v2rayN）：\n'
  cat -- "$cert"
  printf '\n'
}

main "$@"
