#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

vm_name="${VM_NAME:-kata-k8s}"
namespace="${NAMESPACE:-code-server}"
kubeconfig="${KUBECONFIG:-}"
password_file=""
skip_image_build=false
skip_inner_container_run=false

usage() {
  cat <<'EOF'
Usage: deploy-workspace.sh [options]

Options:
  --vm-name NAME                  Multipass VM name (default: kata-k8s)
  --kubeconfig PATH               Kubernetes config file
  --namespace NAME                Must remain code-server
  --password-file PATH            Read the code-server password from a file
  --skip-image-build              Reuse the image already imported into K3s
  --skip-inner-container-run      Skip the nested Podman run/build proof
  -h, --help                      Show this help

The password can also be supplied with CODE_SERVER_PASSWORD. It is never
printed. If neither source is supplied, an existing Secret is reused or a new
random password is generated.
EOF
}

while (($#)); do
  case "$1" in
    --vm-name)
      (($# >= 2)) || die "--vm-name requires a value"
      vm_name="$2"
      shift 2
      ;;
    --vm)
      (($# >= 2)) || die "--vm requires a value"
      vm_name="$2"
      shift 2
      ;;
    --kubeconfig)
      (($# >= 2)) || die "--kubeconfig requires a value"
      kubeconfig="$2"
      shift 2
      ;;
    --namespace)
      (($# >= 2)) || die "--namespace requires a value"
      namespace="$2"
      shift 2
      ;;
    --password-file)
      (($# >= 2)) || die "--password-file requires a value"
      password_file="$2"
      shift 2
      ;;
    --skip-image-build)
      skip_image_build=true
      shift
      ;;
    --skip-inner-container-run)
      skip_inner_container_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ "$vm_name" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "Invalid Multipass VM name: ${vm_name}"
[[ "$namespace" == "code-server" ]] || die "The checked-in manifests require namespace code-server"

# Remove the exported secret before invoking any child process. The copied
# shell variable is not exported.
password="${CODE_SERVER_PASSWORD:-}"
unset CODE_SERVER_PASSWORD

if [[ -n "$password_file" ]]; then
  password_file="$(normalize_kubeconfig_path "$password_file")"
fi

if [[ -z "$kubeconfig" ]]; then
  kubeconfig="${REPO_ROOT}/.state/hyperv-kata/${vm_name}.kubeconfig"
else
  kubeconfig="$(normalize_kubeconfig_path "$kubeconfig")"
fi
[[ -f "$kubeconfig" ]] || die "Kubeconfig not found: ${kubeconfig}. Run make cluster first."
kubeconfig="$(cd -- "$(dirname -- "$kubeconfig")" && pwd -P)/$(basename -- "$kubeconfig")"

require_command kubectl
require_command jq
require_command curl
require_command sha256sum
multipass_bin="$(resolve_multipass)" || die "Multipass Windows client not found"

workspace_image="$(version_value WorkspaceImage)"
inner_test_image="$(version_value InnerTestImage)"
base_image="$(version_value BaseImage)"
code_server_version="$(version_value CodeServerVersion)"
code_server_amd64_sha256="$(version_value CodeServerAmd64Sha256)"
shadow_version="$(version_value ShadowVersion)"
shadow_sha256="$(version_value ShadowSha256)"
runtime_class="kata-qemu-runtime-rs"

kube() {
  kubectl --kubeconfig "$kubeconfig" "$@"
}

mp() {
  "$multipass_bin" "$@"
}

remote_build_root=""
cleanup_remote_build() {
  if [[ -n "$remote_build_root" ]]; then
    if [[ "$remote_build_root" =~ ^/home/ubuntu/\.cache/code-server-kata-build-[0-9a-f]{32}$ ]]; then
      mp exec "$vm_name" -- sudo rm -rf -- "$remote_build_root" >/dev/null 2>&1 || true
    fi
    remote_build_root=""
  fi
}
trap cleanup_remote_build EXIT

log "Checking Multipass VM, Kubernetes node and Kata RuntimeClass"
mp exec "$vm_name" -- true >/dev/null
kube wait --for=condition=Ready node --all --timeout=2m >/dev/null
kube get runtimeclass "$runtime_class" -o name >/dev/null

kata_containerd_config="$(mp exec "$vm_name" -- sudo cat /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/kata-deploy.toml | tr -d '\r')"
grep -Fq ".runtimes.${runtime_class}]" <<<"$kata_containerd_config" || die "Kata runtime handler is absent from containerd config"
grep -Eq '^privileged_without_host_devices[[:space:]]*=[[:space:]]*true[[:space:]]*$' <<<"$kata_containerd_config" || die "Kata device isolation is not enabled"
ok "Kata runtime and device isolation"

image_built=false
if [[ "$skip_image_build" == false ]]; then
  build_id="$(tr -d '-' </proc/sys/kernel/random/uuid)"
  remote_build_root="/home/ubuntu/.cache/code-server-kata-build-${build_id}"
  [[ "$remote_build_root" =~ ^/home/ubuntu/\.cache/code-server-kata-build-[0-9a-f]{32}$ ]] || die "Unsafe remote build path"

  local_context="${REPO_ROOT}/container"
  local_context="$(host_path_for_multipass "$multipass_bin" "$local_context")"

  log "Transferring the image context to ${vm_name}"
  mp exec "$vm_name" -- mkdir -p "$remote_build_root"
  mp transfer --recursive "$local_context" "${vm_name}:${remote_build_root}"
  mp exec "$vm_name" -- test -f "${remote_build_root}/container/Dockerfile"

  log "Building ${workspace_image} inside the Linux VM"
  mp exec "$vm_name" -- sudo podman build \
    --pull=missing \
    --tag "$workspace_image" \
    --build-arg "BASE_IMAGE=${base_image}" \
    --build-arg "CODE_SERVER_VERSION=${code_server_version}" \
    --build-arg "CODE_SERVER_AMD64_SHA256=${code_server_amd64_sha256}" \
    --build-arg "SHADOW_VERSION=${shadow_version}" \
    --build-arg "SHADOW_SHA256=${shadow_sha256}" \
    --file "${remote_build_root}/container/Dockerfile" \
    "$remote_build_root"

  archive="${remote_build_root}/code-server-podman.oci.tar"
  log "Importing the OCI image into K3s containerd"
  mp exec "$vm_name" -- sudo podman save \
    --format oci-archive --output "$archive" "$workspace_image"
  mp exec "$vm_name" -- sudo k3s ctr images import "$archive"
  image_built=true
  cleanup_remote_build
fi

if ! mp exec "$vm_name" -- sudo k3s ctr images list -q | tr -d '\r' | grep -Fxq "$workspace_image"; then
  die "Workspace image is not present in K3s containerd: ${workspace_image}"
fi
ok "Workspace image imported"

log "Applying namespace and authentication Secret"
kube apply -f "${REPO_ROOT}/k8s/base/namespace.yaml" >/dev/null

secret_exists=false
if kube get secret code-server-auth --namespace "$namespace" -o name >/dev/null 2>&1; then
  secret_exists=true
fi

if [[ -n "$password_file" ]]; then
  [[ -f "$password_file" ]] || die "Password file not found: ${password_file}"
  IFS= read -r password <"$password_file" || true
  password="${password%$'\r'}"
fi

secret_changed=false
if [[ -z "$password" && "$secret_exists" == true ]]; then
  log "Reusing the existing code-server authentication Secret"
else
  if [[ -z "$password" ]]; then
    password="$(head -c 24 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
  fi
  [[ -n "$password" ]] || die "The supplied password is empty"
  secret_yaml="$(printf '%s' "$password" | kube create secret generic code-server-auth \
    --namespace "$namespace" \
    --from-file=PASSWORD=/dev/stdin \
    --dry-run=client -o yaml)"
  printf '%s\n' "$secret_yaml" | kube apply -f - >/dev/null
  secret_changed=true
fi
unset password secret_yaml

log "Deploying the single-container Kata workspace"
kube apply -k "${REPO_ROOT}/k8s/overlays/kvm" >/dev/null
if [[ "$image_built" == true || "$secret_changed" == true ]]; then
  kube rollout restart deployment/code-server-podman --namespace "$namespace" >/dev/null
fi
kube rollout status deployment/code-server-podman --namespace "$namespace" --timeout=15m

verify_args=(
  --vm-name "$vm_name"
  --kubeconfig "$kubeconfig"
  --namespace "$namespace"
)
if [[ "$skip_inner_container_run" == true ]]; then
  verify_args+=(--skip-inner-container-run)
fi

INNER_TEST_IMAGE="$inner_test_image" bash "${SCRIPT_DIR}/verify-workspace.sh" "${verify_args[@]}"
