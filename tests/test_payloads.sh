#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# ROOT_DIR is resolved at runtime so the test works from any checkout path.
# shellcheck disable=SC1091
source "$ROOT_DIR/install.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is required"; exit 77; }

TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT

export DOMAIN="node.example.com"
CERT_FILE="/etc/xui-stack/certs/node.example.com/fullchain.pem"
KEY_FILE="/etc/xui-stack/certs/node.example.com/privkey.pem"
export VLESS_PORT="23456"
export HY2_PORT="24567"
VLESS_UUID="11111111-2222-4333-8444-555555555555"
export VLESS_EMAIL="vless-default"
HY2_AUTH="hy2-test-auth"
export HY2_EMAIL="hysteria2-default"

# Called indirectly by the sourced create_* functions.
# shellcheck disable=SC2329
api_request() {
  local method=$1 endpoint=$2 data=${3:-}
  [[ "$method" == "POST" ]] || return 1
  printf '%s' "$data" > "${TEST_TMP}/${endpoint//\//_}.json"
  printf '{"success":true}'
}

create_vless_inbound
create_hy2_inbound

vless_payload="${TEST_TMP}/inbounds_add.json"
# The second API call overwrites the shared path; capture the Hysteria payload,
# then directly rebuild the VLESS payload once more under a distinct name.
cp "$vless_payload" "${TEST_TMP}/hy2.json"
# Called indirectly by the sourced create_vless_inbound function.
# shellcheck disable=SC2329
api_request() {
  local _method=$1 _endpoint=$2 data=${3:-}
  printf '%s' "$data" > "${TEST_TMP}/vless.json"
  printf '{"success":true}'
}
create_vless_inbound

jq -e --arg uuid "$VLESS_UUID" --arg cert "$CERT_FILE" --arg key "$KEY_FILE" '
  .protocol == "vless" and
  .port == 23456 and
  .streamSettings.network == "tcp" and
  .streamSettings.security == "tls" and
  .streamSettings.tlsSettings.certificates[0].certificateFile == $cert and
  .streamSettings.tlsSettings.certificates[0].keyFile == $key and
  any(.settings.clients[]; .id == $uuid and .flow == "xtls-rprx-vision")
' "${TEST_TMP}/vless.json" >/dev/null

jq -e --arg auth "$HY2_AUTH" --arg cert "$CERT_FILE" '
  .protocol == "hysteria" and
  .port == 24567 and
  .streamSettings.network == "hysteria" and
  .streamSettings.security == "tls" and
  .settings.version == 2 and
  .streamSettings.hysteriaSettings.version == 2 and
  .streamSettings.tlsSettings.alpn == ["h3"] and
  .streamSettings.tlsSettings.certificates[0].certificateFile == $cert and
  any(.settings.clients[]; .auth == $auth)
' "${TEST_TMP}/hy2.json" >/dev/null

printf 'PASS: generated VLESS and Hysteria2 API payloads\n'
