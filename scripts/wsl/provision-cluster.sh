#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

VM_NAME="${VM_NAME:-kata-k8s}"
KUBECONFIG_PATH=""

usage() {
  cat <<'EOF'
Usage: scripts/wsl/provision-cluster.sh [--vm-name NAME] [--kubeconfig PATH]

Provisionne ou répare K3s et Kata dans une VM Multipass Hyper-V déjà créée et
configurée pour la virtualisation imbriquée. Le bootstrap Hyper-V hôte reste une
opération Windows administrateur distincte.
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
is_wsl2 || die 'ce script doit être lancé depuis WSL2'
for tool in jq kubectl wslpath; do require_command "${tool}"; done

MULTIPASS="$(resolve_multipass)" || die 'multipass.exe introuvable'
"${MULTIPASS}" exec "${VM_NAME}" -- true >/dev/null 2>&1 || \
  die "VM ${VM_NAME} indisponible; exécuter d’abord le bootstrap Hyper-V Windows"

K3S_VERSION="$(version_value K3sVersion)"
KATA_VERSION="$(version_value KataVersion)"
HELM_VERSION="$(version_value HelmVersion)"
KATA_SMOKE_IMAGE="$(version_value KataSmokeImage)"

info_json="$("${MULTIPASS}" info "${VM_NAME}" --format json | tr -d '\r')"
node_ip="$(jq -r --arg vm "${VM_NAME}" '.info[$vm].ipv4[]? | select(test("^[0-9]+(\\.[0-9]+){3}$"))' <<<"${info_json}" | head -n1)"
[[ -n "${node_ip}" ]] || die "adresse IPv4 introuvable pour ${VM_NAME}"

installer="${REPO_ROOT}/scripts/linux/Install-K3sKata.sh"
values="${REPO_ROOT}/hyperv/kata-values.yaml"
[[ -f "${installer}" && -f "${values}" ]] || die 'fichiers de provisionnement manquants'

installer_host="$(host_path_for_multipass "${MULTIPASS}" "${installer}")"
values_host="$(host_path_for_multipass "${MULTIPASS}" "${values}")"

log "Transfert du provisionneur vers ${VM_NAME}"
"${MULTIPASS}" transfer "${installer_host}" "${VM_NAME}:/home/ubuntu/install-k3s-kata.sh"
"${MULTIPASS}" transfer "${values_host}" "${VM_NAME}:/home/ubuntu/kata-values.yaml"

log "Installation K3s ${K3S_VERSION} + Kata ${KATA_VERSION}"
"${MULTIPASS}" exec "${VM_NAME}" -- sudo env \
  "K3S_VERSION=${K3S_VERSION}" \
  "KATA_VERSION=${KATA_VERSION}" \
  "HELM_VERSION=${HELM_VERSION}" \
  "KATA_SMOKE_IMAGE=${KATA_SMOKE_IMAGE}" \
  "K3S_NODE_IP=${node_ip}" \
  KATA_VALUES_FILE=/home/ubuntu/kata-values.yaml \
  bash /home/ubuntu/install-k3s-kata.sh

if [[ -z "${KUBECONFIG_PATH}" ]]; then
  KUBECONFIG_PATH="$(default_kubeconfig "${VM_NAME}")"
else
  KUBECONFIG_PATH="$(normalize_kubeconfig_path "${KUBECONFIG_PATH}")"
fi
mkdir -p -- "$(dirname -- "${KUBECONFIG_PATH}")"
tmp_kubeconfig="$(mktemp "$(dirname -- "${KUBECONFIG_PATH}")/.kubeconfig.XXXXXX")"
cleanup() {
  rm -f -- "${tmp_kubeconfig}"
}
trap cleanup EXIT
"${MULTIPASS}" exec "${VM_NAME}" -- cat /home/ubuntu/k3s-host.yaml > "${tmp_kubeconfig}"
chmod 0600 "${tmp_kubeconfig}"
mv -f -- "${tmp_kubeconfig}" "${KUBECONFIG_PATH}"
trap - EXIT

kube wait --for=condition=Ready node --all --timeout=10m
kube get runtimeclass kata-qemu-runtime-rs >/dev/null
ok "cluster prêt: ${node_ip}; kubeconfig=${KUBECONFIG_PATH}"
