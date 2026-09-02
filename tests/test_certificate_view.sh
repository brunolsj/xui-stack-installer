#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${TEST_TMP}/privkey.pem" \
  -out "${TEST_TMP}/fullchain.pem" \
  -days 1 -subj '/CN=node.example.com' >/dev/null 2>&1

cat > "${TEST_TMP}/state.env" <<EOF
CERT_FILE=${TEST_TMP}/fullchain.pem
KEY_FILE=${TEST_TMP}/privkey.pem
EOF

output=$(XUI_STACK_STATE_FILE="${TEST_TMP}/state.env" bash "$ROOT_DIR/view-certificate.sh")

grep -Fq "证书链（公钥证书）路径：${TEST_TMP}/fullchain.pem" <<<"$output" || fail "certificate path missing"
grep -Fq "私钥路径（仅显示路径，不输出私钥）：${TEST_TMP}/privkey.pem" <<<"$output" || fail "private key path missing"
grep -Eq '证书指纹（SHA-256）：([0-9A-F]{2}:){31}[0-9A-F]{2}' <<<"$output" || fail "SHA-256 fingerprint missing"
grep -Fq -- '-----BEGIN CERTIFICATE-----' <<<"$output" || fail "PEM certificate missing"
if grep -Fq -- '-----BEGIN PRIVATE KEY-----' <<<"$output"; then
  fail "private key content was exposed"
fi

printf 'PASS: certificate viewer output\n'
