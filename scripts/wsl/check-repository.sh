#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

fail() {
  printf 'Repository release check failed: %s\n' "$*" >&2
  exit 1
}

cd -- "${repo_root}"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  forbidden_tracked="$({
    git ls-files '.state/**' 'benchmark-results/**' '*.kubeconfig' '*.key' \
      '*.pem' '*.p12' '*.pfx' '*.jks' '*.keystore' '*.age' 'secrets/**'
  } || true)"
  [[ -z "${forbidden_tracked}" ]] || \
    fail "private or generated files are tracked:\n${forbidden_tracked}"
fi

scan_args=(
  -RInP
  --exclude-dir=.git
  --exclude-dir=.state
  --exclude-dir=benchmark-results
)

if grep "${scan_args[@]}" 'C:\\Users\\(?!<|%)[A-Za-z0-9._-]+\\' .; then
  fail 'a personal Windows home path remains in publishable files'
fi

if grep "${scan_args[@]}" '(-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16})' .; then
  fail 'content resembling a private key or access token was found'
fi

large_files="$({
  find . -type f -size +5M \
    ! -path './.git/*' \
    ! -path './.state/*' \
    ! -path './benchmark-results/*' \
    -print
} || true)"
[[ -z "${large_files}" ]] || fail "unexpected files larger than 5 MiB:\n${large_files}"

printf 'Repository release check passed.\n'
