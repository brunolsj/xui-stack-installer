#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# ROOT_DIR is resolved at runtime so the test works from any checkout path.
# shellcheck disable=SC1091
source "$ROOT_DIR/install.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

validate_domain "node.example.com" || fail "valid domain rejected"
validate_domain "a-b.example.co.uk" || fail "valid multi-label domain rejected"
! validate_domain "example" || fail "single label accepted"
! validate_domain "-bad.example.com" || fail "leading hyphen accepted"
! validate_domain "bad_.example.com" || fail "underscore accepted"

validate_email "admin@example.com" || fail "valid email rejected"
! validate_email "admin example.com" || fail "invalid email accepted"

version_ge "3.6.0" "3.6.0" || fail "equal version rejected"
version_ge "3.7.0" "3.6.0" || fail "newer version rejected"
! version_ge "3.5.9" "3.6.0" || fail "older version accepted"

acme_success() { return 0; }
acme_not_due() { return 2; }
acme_failure() { return 5; }
run_acme_issue acme_success || fail "acme success rejected"
run_acme_issue acme_not_due || fail "acme not-due exit code rejected"
! run_acme_issue acme_failure || fail "real acme failure accepted"

reserved_port 443 || fail "known port not reserved"
! reserved_port 23456 || fail "ordinary port marked reserved"

secret=$(random_base64url 32)
[[ "$secret" =~ ^[A-Za-z0-9_-]+$ ]] || fail "base64url secret has invalid characters"
(( ${#secret} >= 40 )) || fail "base64url secret too short"

if grep -Eq -- '--no-check-certificate|chmod[[:space:]]+777|iptables[[:space:]].*-F' "$ROOT_DIR/install.sh"; then
  fail "forbidden unsafe pattern found"
fi

printf 'PASS: function and safety tests\n'
