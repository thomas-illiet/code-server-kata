#!/usr/bin/env bash

# Shared helpers for the WSL control-plane scripts. The workload itself runs in
# the Multipass/K3s/Kata VM; WSL is only the Linux-native administration shell.

WSL_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${WSL_LIB_DIR}/../../.." && pwd -P)"
VERSION_MANIFEST="${REPO_ROOT}/versions.psd1"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

ok() {
  printf '[ok] %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

require_command() {
  local command_name="$1"
  command -v "${command_name}" >/dev/null 2>&1 || \
    die "commande requise introuvable: ${command_name}"
}

is_wsl2() {
  [[ -r /proc/sys/kernel/osrelease ]] &&
    grep -qiE 'microsoft.*wsl2|wsl2.*microsoft' /proc/sys/kernel/osrelease
}

validate_vm_name() {
  local value="$1"
  [[ "${value}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || \
    die "nom de VM invalide: ${value}"
}

version_value() {
  local key="$1"
  local value

  [[ "${key}" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || die "clé de version invalide: ${key}"
  [[ -f "${VERSION_MANIFEST}" ]] || die "manifeste de versions absent: ${VERSION_MANIFEST}"

  value="$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*'([^']*)'[[:space:]]*$/\\1/p" "${VERSION_MANIFEST}")"
  [[ -n "${value}" ]] || die "versions.psd1 ne définit pas ${key}"
  if [[ "$(printf '%s\n' "${value}" | wc -l)" -ne 1 ]]; then
    die "versions.psd1 définit plusieurs valeurs pour ${key}"
  fi
  printf '%s\n' "${value}"
}

resolve_multipass() {
  local candidate

  if command -v multipass.exe >/dev/null 2>&1; then
    command -v multipass.exe
    return
  fi

  for candidate in \
    '/mnt/c/Program Files/Multipass/bin/multipass.exe' \
    '/mnt/c/Program Files/Canonical/Multipass/bin/multipass.exe'; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done

  # The supported VM belongs to the Windows Multipass/Hyper-V service. A
  # native WSL client is only a compatibility fallback.
  if command -v multipass >/dev/null 2>&1; then
    command -v multipass
    return
  fi

  return 1
}

multipass_uses_windows_paths() {
  local multipass_path="$1"
  [[ "${multipass_path,,}" == *.exe ]]
}

host_path_for_multipass() {
  local multipass_path="$1"
  local local_path="$2"

  if multipass_uses_windows_paths "${multipass_path}"; then
    require_command wslpath
    wslpath -w "${local_path}"
  else
    printf '%s\n' "${local_path}"
  fi
}

default_kubeconfig() {
  local vm_name="$1"
  printf '%s/.state/hyperv-kata/%s.kubeconfig\n' "${REPO_ROOT}" "${vm_name}"
}

normalize_kubeconfig_path() {
  local value="$1"
  if [[ "${value}" =~ ^[A-Za-z]:[\\/] ]]; then
    require_command wslpath
    wslpath -u "${value}"
  else
    printf '%s\n' "${value}"
  fi
}

kube() {
  [[ -n "${KUBECONFIG_PATH:-}" ]] || die 'KUBECONFIG_PATH non initialisé'
  kubectl --kubeconfig "${KUBECONFIG_PATH}" "$@"
}

first_workspace_pod() {
  local namespace="$1"
  kube -n "${namespace}" get pods \
    -l app.kubernetes.io/name=code-server-podman \
    -o jsonpath='{.items[0].metadata.name}'
}
