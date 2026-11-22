#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

VM_NAME="${VM_NAME:-kata-k8s}"
KUBECONFIG_PATH=""

usage() {
  cat <<'EOF'
Usage: scripts/wsl/doctor.sh [--vm-name NAME] [--kubeconfig PATH]

Vérifie WSL2, les outils Linux, l'interop Multipass Windows, la VM Kata et le
kubeconfig. Aucun état n'est modifié.
EOF
}

while (($#)); do
  case "$1" in
    --vm|--vm-name) VM_NAME="${2:?valeur manquante pour --vm-name}"; shift 2 ;;
    --kubeconfig) KUBECONFIG_PATH="${2:?valeur manquante pour --kubeconfig}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "option inconnue: $1" ;;
  esac
done

validate_vm_name "${VM_NAME}"
is_wsl2 || die 'ce parcours doit être lancé depuis une distribution WSL2'
ok 'WSL2 détecté'

for tool in bash curl jq make tar kubectl wslpath; do
  require_command "${tool}"
done
ok 'outils Linux présents: bash curl jq make tar kubectl wslpath'

MULTIPASS="$(resolve_multipass)" || die 'multipass.exe introuvable; installer Multipass sur Windows'
"${MULTIPASS}" version >/dev/null
ok "Multipass accessible: ${MULTIPASS}"

"${MULTIPASS}" info "${VM_NAME}" --format json >/dev/null 2>&1 || \
  die "VM Multipass absente: ${VM_NAME}; exécuter le bootstrap Hyper-V Windows"
"${MULTIPASS}" exec "${VM_NAME}" -- true >/dev/null
ok "VM Multipass prête: ${VM_NAME}"

if [[ -z "${KUBECONFIG_PATH}" ]]; then
  KUBECONFIG_PATH="$(default_kubeconfig "${VM_NAME}")"
else
  KUBECONFIG_PATH="$(normalize_kubeconfig_path "${KUBECONFIG_PATH}")"
fi
[[ -f "${KUBECONFIG_PATH}" ]] || \
  die "kubeconfig absent: ${KUBECONFIG_PATH}; exécuter make cluster"

api_server="$(kubectl --kubeconfig "${KUBECONFIG_PATH}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
if ! curl --insecure --silent --show-error --connect-timeout 3 --max-time 5 \
  --output /dev/null "${api_server}/version"; then
  die "l’API ${api_server} n’est pas joignable depuis le réseau WSL. Activez networkingMode=mirrored dans %UserProfile%\\.wslconfig, exécutez 'wsl.exe --shutdown', puis relancez make doctor"
fi
ok "API Kubernetes joignable depuis WSL: ${api_server}"

kube get node --request-timeout=10s >/dev/null
kube get runtimeclass kata-qemu-runtime-rs >/dev/null
ok "Kubernetes et RuntimeClass Kata joignables via ${KUBECONFIG_PATH}"

printf 'WSL control plane ready.\n'
