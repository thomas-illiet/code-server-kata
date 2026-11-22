#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if (($#)); then
  case "$1" in
    -h|--help)
      [[ $# -eq 1 ]] || die 'Usage: scripts/wsl/install-tools.sh'
      printf '%s\n' 'Usage: scripts/wsl/install-tools.sh'
      exit 0
      ;;
    *) die 'Usage: scripts/wsl/install-tools.sh' ;;
  esac
fi

is_wsl2 || die 'ce script installe les outils dans une distribution WSL2'
[[ "$(dpkg --print-architecture)" == amd64 ]] || die 'seule l’architecture amd64 est prise en charge'

KUBERNETES_VERSION="$(version_value KubernetesVersion)"
SUDO=()
if ((EUID != 0)); then
  require_command sudo
  SUDO=(sudo)
fi

log 'Installation des dépendances WSL'
"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install -y --no-install-recommends \
  ca-certificates curl jq make openssl shellcheck tar xz-utils

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf -- "${tmp_dir}"
}
trap cleanup EXIT

kubectl_url="https://dl.k8s.io/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kubectl"
log "Installation de kubectl v${KUBERNETES_VERSION}"
curl --fail --location --retry 5 --output "${tmp_dir}/kubectl" "${kubectl_url}"
curl --fail --location --retry 5 --output "${tmp_dir}/kubectl.sha256" "${kubectl_url}.sha256"
printf '%s  %s\n' "$(tr -d '[:space:]' < "${tmp_dir}/kubectl.sha256")" "${tmp_dir}/kubectl" | sha256sum --check --strict
"${SUDO[@]}" install -o root -g root -m 0755 "${tmp_dir}/kubectl" /usr/local/bin/kubectl

kubectl version --client
if MULTIPASS="$(resolve_multipass)"; then
  "${MULTIPASS}" version
  ok "client Multipass Windows accessible: ${MULTIPASS}"
else
  warn 'Multipass Windows reste à installer; voir docs/wsl.md'
fi

ok 'outils WSL installés'
