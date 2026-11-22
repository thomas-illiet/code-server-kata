#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

VM_NAME="${VM_NAME:-kata-k8s}"
if (($#)); then
  if [[ ( "$1" == -h || "$1" == --help ) && $# -eq 1 ]]; then
    printf '%s\n' 'Usage: scripts/wsl/shell.sh [--vm-name NAME]'
    exit 0
  fi
  [[ ( "$1" == --vm || "$1" == --vm-name ) && $# -eq 2 ]] || die 'Usage: scripts/wsl/shell.sh [--vm-name NAME]'
  VM_NAME="$2"
fi
validate_vm_name "${VM_NAME}"

MULTIPASS="$(resolve_multipass)" || die 'multipass.exe introuvable'
"${MULTIPASS}" exec "${VM_NAME}" -- true >/dev/null 2>&1 || die "VM indisponible: ${VM_NAME}"
exec "${MULTIPASS}" shell "${VM_NAME}"
