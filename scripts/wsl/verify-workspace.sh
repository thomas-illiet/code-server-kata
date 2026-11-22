#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

vm_name="${VM_NAME:-kata-k8s}"
namespace="${NAMESPACE:-code-server}"
kubeconfig="${KUBECONFIG:-}"
skip_inner_container_run=false

usage() {
  cat <<'EOF'
Usage: verify-workspace.sh [options]

Options:
  --vm-name NAME                  Multipass VM name (default: kata-k8s)
  --kubeconfig PATH               Kubernetes config file
  --namespace NAME                Must remain code-server
  --skip-inner-container-run      Skip Podman pull/run/build tests
  -h, --help                      Show this help
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

if [[ -z "$kubeconfig" ]]; then
  kubeconfig="${REPO_ROOT}/.state/hyperv-kata/${vm_name}.kubeconfig"
else
  kubeconfig="$(normalize_kubeconfig_path "$kubeconfig")"
fi
[[ -f "$kubeconfig" ]] || die "Kubeconfig not found: ${kubeconfig}"
kubeconfig="$(cd -- "$(dirname -- "$kubeconfig")" && pwd -P)/$(basename -- "$kubeconfig")"

require_command kubectl
require_command jq
require_command curl

runtime_class="kata-qemu-runtime-rs"
inner_test_image="${INNER_TEST_IMAGE:-$(version_value InnerTestImage)}"
[[ "$inner_test_image" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@+-]{0,511}$ ]] || \
  die "Invalid inner test image reference"

kube() {
  kubectl --kubeconfig "$kubeconfig" "$@"
}

assert_equal() {
  local name="$1" expected="$2" actual="$3"
  [[ "$actual" == "$expected" ]] || die "${name}: expected '${expected}', got '${actual}'"
  ok "${name}: ${actual}"
}

normalize_map() {
  awk 'NF { print $1 " " $2 " " $3 }' | paste -sd ';' -
}

log "Inspecting the live Kata workspace"
pod_list="$(kube get pods --namespace "$namespace" --selector app.kubernetes.io/name=code-server-podman -o json)"
pod_count="$(jq '[.items[] | select(
  .status.phase == "Running" and
  ((.status.containerStatuses // []) | length) == 1 and
  .status.containerStatuses[0].ready == true
)] | length' <<<"$pod_list")"
assert_equal "running workspace pod count" "1" "$pod_count"
pod_name="$(jq -er '.items[] | select(
  .status.phase == "Running" and
  .status.containerStatuses[0].ready == true
) | .metadata.name' <<<"$pod_list")"
pod_json="$(kube get pod "$pod_name" --namespace "$namespace" -o json)"

jq -e '
  (.spec.containers | length) == 1 and
  .spec.containers[0].name == "code-server" and
  ((.spec.initContainers // []) | length) == 0 and
  ((.spec.ephemeralContainers // []) | length) == 0
' >/dev/null <<<"$pod_json" || die "Pod must contain exactly one code-server container"
ok "Single code-server container"

jq -e '
  any(.spec.volumes[]; .name == "developer-home" and .persistentVolumeClaim.claimName == "code-server-home") and
  any(.spec.containers[0].volumeMounts[]; .name == "developer-home" and .mountPath == "/home/podman") and
  any(.spec.containers[0].volumeMounts[]; .name == "code-server-tmp" and .mountPath == "/tmp") and
  any(.spec.containers[0].volumeMounts[]; .name == "code-server-var-tmp" and .mountPath == "/var/tmp")
' >/dev/null <<<"$pod_json" || die "Writable home/tmp mounts differ from the expected read-only-rootfs design"
assert_equal "workspace PVC phase" "Bound" "$(kube get pvc code-server-home --namespace "$namespace" -o jsonpath='{.status.phase}' | tr -d '\r')"
ok "Read-only rootfs writable mounts: /home/podman, /tmp, /var/tmp"

assert_equal "Kata RuntimeClass" "$runtime_class" "$(jq -r '.spec.runtimeClassName' <<<"$pod_json")"

security_json="$(jq -c '.spec.containers[0].securityContext' <<<"$pod_json")"
jq -e '
  .privileged == false and
  .allowPrivilegeEscalation == true and
  .readOnlyRootFilesystem == true and
  .runAsNonRoot == true and
  .runAsUser == 1000 and
  .runAsGroup == 1000 and
  .seccompProfile.type == "Unconfined" and
  ((.capabilities.drop | sort) == ["ALL"]) and
  ((.capabilities.add | sort) == ["SETGID", "SETUID"])
' >/dev/null <<<"$security_json" || die "Container securityContext differs from the exact hardened profile"
ok "SecurityContext: non-privileged, drop ALL, add SETGID|SETUID"

assert_equal "supplementalGroupsPolicy" "Strict" "$(jq -r '.spec.securityContext.supplementalGroupsPolicy' <<<"$pod_json")"
assert_equal "code-server UID" "1000" "$(kube exec --namespace "$namespace" "$pod_name" -- id -u | tr -d '\r')"
assert_equal "code-server groups" "1000" "$(kube exec --namespace "$namespace" "$pod_name" -- id -G | tr -d '\r')"

node_name="$(jq -r '.spec.nodeName' <<<"$pod_json")"
node_kernel="$(kube get node "$node_name" -o jsonpath='{.status.nodeInfo.kernelVersion}' | tr -d '\r')"
guest_kernel="$(kube exec --namespace "$namespace" "$pod_name" -- uname -r | tr -d '\r')"
[[ -n "$guest_kernel" && "$guest_kernel" != "$node_kernel" ]] || die "Kata guest kernel does not differ from node kernel"
ok "Kata guest kernel: node=${node_kernel}, guest=${guest_kernel}"

capability_status="$(kube exec --namespace "$namespace" "$pod_name" -- sh -lc \
  "grep -E '^(CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs|Seccomp):' /proc/1/status" | tr -d '\r')"
for field in CapInh CapPrm CapEff CapAmb; do
  grep -Eq "^${field}:[[:space:]]+0000000000000000$" <<<"$capability_status" || die "${field} is not zero"
done
grep -Eq '^CapBnd:[[:space:]]+00000000000000c0$' <<<"$capability_status" || die "CapBnd is not SETGID|SETUID only"
grep -Eq '^NoNewPrivs:[[:space:]]+0$' <<<"$capability_status" || die "NoNewPrivs must be 0 for uidmap helpers"
grep -Eq '^Seccomp:[[:space:]]+0$' <<<"$capability_status" || die "Unexpected seccomp state for the validated Kata configuration"
ok "Capability state: CapBnd=0xc0 and persistent process sets are zero"

setid_paths="$(kube exec --namespace "$namespace" "$pod_name" -- sh -lc \
  "find /usr -xdev -type f -perm /6000 -printf '%p\\n' 2>/dev/null | sort" | tr -d '\r')"
expected_setid_paths=$'/usr/bin/newgidmap\n/usr/bin/newuidmap'
assert_equal "setid helper allowlist" "$expected_setid_paths" "$setid_paths"

helper_modes="$(kube exec --namespace "$namespace" "$pod_name" -- sh -lc \
  "stat -c '%a %u:%g %n' /usr/bin/newgidmap /usr/bin/newuidmap" | tr -d '\r')"
grep -Fxq '4755 0:0 /usr/bin/newgidmap' <<<"$helper_modes" || die "newgidmap mode/owner mismatch"
grep -Fxq '4755 0:0 /usr/bin/newuidmap' <<<"$helper_modes" || die "newuidmap mode/owner mismatch"
ok "uidmap helpers: 4755 root:root"

assert_equal "Podman rootless" "true" "$(kube exec --namespace "$namespace" "$pod_name" -- podman info --format '{{.Host.Security.Rootless}}' | tr -d '\r')"
assert_equal "Podman storage driver" "overlay" "$(kube exec --namespace "$namespace" "$pod_name" -- podman info --format '{{.Store.GraphDriverName}}' | tr -d '\r')"

storage_details="$(kube exec --namespace "$namespace" "$pod_name" -- podman info \
  --format '{{.Store.GraphRoot}}|{{.Store.RunRoot}}|{{json .Store.GraphOptions}}' | tr -d '\r')"
[[ "$storage_details" == /tmp/podman-storage\|/tmp/run-user-1000/containers\|* ]] || die "Unexpected Podman storage paths: ${storage_details}"
[[ "$storage_details" != *mount_program* ]] || die "Podman unexpectedly uses a FUSE mount program"
ok "Podman native overlay on tmpfs"

containers_conf="$(kube exec --namespace "$namespace" "$pod_name" -- cat /etc/containers/containers-rootless.conf | tr -d '\r')"
grep -Eq '^cgroups[[:space:]]*=[[:space:]]*"enabled"$' <<<"$containers_conf" || die "Podman cgroups must be enabled"
grep -Eq '^netns[[:space:]]*=[[:space:]]*"host"$' <<<"$containers_conf" || die "Podman netns must be host (Kata pod)"
grep -Eq '^pidns[[:space:]]*=[[:space:]]*"host"$' <<<"$containers_conf" || die "Podman pidns must be host (Kata pod)"
ok "Podman uses the Kata pod network/PID namespaces"

uid_map="$(kube exec --namespace "$namespace" "$pod_name" -- podman unshare cat /proc/self/uid_map | tr -d '\r' | normalize_map)"
gid_map="$(kube exec --namespace "$namespace" "$pod_name" -- podman unshare cat /proc/self/gid_map | tr -d '\r' | normalize_map)"
expected_map='0 1000 1;1 100000 65536'
assert_equal "rootless UID map" "$expected_map" "$uid_map"
assert_equal "rootless GID map" "$expected_map" "$gid_map"

kube exec --namespace "$namespace" "$pod_name" -- curl --fail --silent http://127.0.0.1:8080/healthz >/dev/null
ok "code-server health endpoint"

policy_probe_base="$(jq '
  del(
    .status,
    .metadata.uid,
    .metadata.resourceVersion,
    .metadata.generation,
    .metadata.creationTimestamp,
    .metadata.managedFields,
    .metadata.ownerReferences,
    .spec.nodeName
  )
' <<<"$pod_json")"
privileged_probe="$(jq '
  .metadata.name = "policy-probe-privileged" |
  .spec.containers[0].securityContext.privileged = true
' <<<"$policy_probe_base")"
if privileged_probe_output="$(printf '%s\n' "$privileged_probe" | kube create --dry-run=server -f - 2>&1)"; then
  die "Admission policy accepted privileged=true"
fi
grep -Fq 'only SETGID and SETUID' <<<"$privileged_probe_output" ||
  die "Admission policy rejected privileged probe for an unexpected reason: ${privileged_probe_output}"

extra_cap_probe="$(jq '
  .metadata.name = "policy-probe-extra-cap" |
  .spec.containers[0].securityContext.capabilities.add += ["SYS_ADMIN"]
' <<<"$policy_probe_base")"
if extra_cap_probe_output="$(printf '%s\n' "$extra_cap_probe" | kube create --dry-run=server -f - 2>&1)"; then
  die "Admission policy accepted SYS_ADMIN"
fi
grep -Fq 'only SETGID and SETUID' <<<"$extra_cap_probe_output" ||
  die "Admission policy rejected capability probe for an unexpected reason: ${extra_cap_probe_output}"
ok "Admission policy denies privileged mode and extra capabilities"

if [[ "$skip_inner_container_run" == false ]]; then
  log "Running nested Podman and multi-UID build proofs"
  inner_output="$(kube exec --namespace "$namespace" "$pod_name" -- podman run --rm --pull=always \
    "$inner_test_image" sh -lc 'id -u; cat /proc/self/uid_map; readlink /proc/self/ns/pid' | tr -d '\r')"
  grep -Eq '^0$' <<<"$inner_output" || die "Nested container did not run as inner root"
  grep -Eq '^[[:space:]]*0[[:space:]]+1000[[:space:]]+1[[:space:]]*$' <<<"$inner_output" || die "Nested container root mapping is wrong"

  pod_pid_namespace="$(kube exec --namespace "$namespace" "$pod_name" -- readlink /proc/1/ns/pid | tr -d '\r')"
  grep -Fxq "$pod_pid_namespace" <<<"$inner_output" || die "Nested container does not share the Kata pod PID namespace"

  user_2000="$(kube exec --namespace "$namespace" "$pod_name" -- podman run --rm --pull=never \
    --user 2000:2000 "$inner_test_image" id -u | tr -d '\r')"
  assert_equal "nested subordinate UID" "2000" "$user_2000"

  multi_uid_build_script=$(cat <<EOF
set -eu
export TMPDIR=/tmp
proof_dir=/tmp/podman-user2000-proof
proof_image=localhost/podman-user2000-proof:latest
cleanup() {
  podman image rm -f "\$proof_image" >/dev/null 2>&1 || true
  rm -rf "\$proof_dir"
}
trap cleanup EXIT
mkdir -p "\$proof_dir"
printf 'FROM %s\n%s\n%s\n%s\n' "\$1" 'USER 2000:2000' 'RUN id -u | grep -qx 2000' 'CMD ["id", "-u"]' > "\$proof_dir/Containerfile"
podman build --pull=never --no-cache --tag "\$proof_image" "\$proof_dir"
result="\$(podman run --rm --pull=never "\$proof_image")"
test "\$result" = 2000
printf '%s\n' "\$result"
EOF
)
  build_output="$(kube exec --namespace "$namespace" "$pod_name" -- \
    sh -lc "$multi_uid_build_script" sh "$inner_test_image" | tr -d '\r')"
  grep -Eq '^2000$' <<<"$build_output" || die "USER 2000 build/run proof failed"
  ok "Nested Podman run and USER 2000 build"
fi

node_ip="$(kube get node "$node_name" -o json | jq -er '.status.addresses[] | select(.type == "InternalIP") | .address' | head -n 1)"
node_port="$(kube get service code-server --namespace "$namespace" -o jsonpath='{.spec.ports[0].nodePort}' | tr -d '\r')"
[[ "$node_port" =~ ^[0-9]+$ ]] || die "Could not determine code-server NodePort"
curl --fail --silent --show-error --max-time 10 "http://${node_ip}:${node_port}/login" >/dev/null
ok "NodePort HTTP endpoint: http://${node_ip}:${node_port}"

printf '\nWorkspace verified successfully.\n'
printf 'Pod: %s/%s\n' "$namespace" "$pod_name"
printf 'URL: http://%s:%s\n' "$node_ip" "$node_port"
printf 'The password remains in Secret code-server-auth.\n'
