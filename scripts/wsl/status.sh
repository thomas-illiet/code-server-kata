#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

VM_NAME="${VM_NAME:-kata-k8s}"
NAMESPACE="${NAMESPACE:-code-server}"
KUBECONFIG_PATH=""

while (($#)); do
  case "$1" in
    --vm|--vm-name) VM_NAME="${2:?valeur manquante pour --vm-name}"; shift 2 ;;
    --namespace) NAMESPACE="${2:?valeur manquante pour --namespace}"; shift 2 ;;
    --kubeconfig) KUBECONFIG_PATH="${2:?valeur manquante pour --kubeconfig}"; shift 2 ;;
    -h|--help) echo 'Usage: scripts/wsl/status.sh [--vm-name NAME] [--kubeconfig PATH] [--namespace NAME]'; exit 0 ;;
    *) die "option inconnue: $1" ;;
  esac
done

validate_vm_name "${VM_NAME}"
require_command kubectl
if [[ -z "${KUBECONFIG_PATH}" ]]; then
  KUBECONFIG_PATH="$(default_kubeconfig "${VM_NAME}")"
else
  KUBECONFIG_PATH="$(normalize_kubeconfig_path "${KUBECONFIG_PATH}")"
fi
[[ -f "${KUBECONFIG_PATH}" ]] || die "kubeconfig absent: ${KUBECONFIG_PATH}"

kube get nodes -o wide
printf '\n'
kube get runtimeclass kata-qemu-runtime-rs
printf '\n'
kube -n "${NAMESPACE}" get deployment,pod,pvc,service -o wide

node_ip="$(kube get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
node_port="$(kube -n "${NAMESPACE}" get service code-server -o jsonpath='{.spec.ports[0].nodePort}')"
printf '\nURL: http://%s:%s\n' "${node_ip}" "${node_port}"
