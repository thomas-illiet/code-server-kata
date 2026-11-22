#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

iterations=10
warmups=1
runtime_class="kata-qemu-runtime-rs"
kubeconfig="${KUBECONFIG:-}"
namespace=""
output_dir="${REPO_ROOT}/benchmark-results"
keep_namespace=false

usage() {
  cat <<'EOF'
Usage: benchmark-podman.sh [options]

Compare deux profils complets demandés : Podman rootful dans un pod runc
privilégié (« sans sécurité »), et Podman rootless non privilégié dans Kata.

Options:
  --kubeconfig PATH               Kubernetes config file
  --runtime-class NAME            Kata RuntimeClass (default: kata-qemu-runtime-rs)
  --iterations N                  Samples per metric/profile (default: 10)
  --warmups N                     Warmups per metric/profile (default: 1)
  --namespace NAME                Temporary namespace name
  --output-dir PATH               CSV output directory
  --keep-namespace                Do not delete the benchmark namespace
  -h, --help                      Show this help

Metrics:
  podman-run-true                 Warm container create/start/remove
  podman-run-write-128mib         Same plus 128 MiB synchronized overlay write
  podman-build-user2000           No-cache 32 MiB build with USER 2000
EOF
}

while (($#)); do
  case "$1" in
    --kubeconfig)
      (($# >= 2)) || die "--kubeconfig requires a value"
      kubeconfig="$2"
      shift 2
      ;;
    --runtime-class)
      (($# >= 2)) || die "--runtime-class requires a value"
      runtime_class="$2"
      shift 2
      ;;
    --iterations)
      (($# >= 2)) || die "--iterations requires a value"
      iterations="$2"
      shift 2
      ;;
    --warmups)
      (($# >= 2)) || die "--warmups requires a value"
      warmups="$2"
      shift 2
      ;;
    --namespace)
      (($# >= 2)) || die "--namespace requires a value"
      namespace="$2"
      shift 2
      ;;
    --output-dir)
      (($# >= 2)) || die "--output-dir requires a value"
      output_dir="$2"
      shift 2
      ;;
    --keep-namespace)
      keep_namespace=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "$iterations" =~ ^[0-9]+$ ]] || die "iterations must be an integer"
[[ "$warmups" =~ ^[0-9]+$ ]] || die "warmups must be an integer"
((iterations >= 3 && iterations <= 50)) || die "iterations must be between 3 and 50"
((warmups >= 1 && warmups <= 5)) || die "warmups must be between 1 and 5"
[[ "$runtime_class" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die "Invalid RuntimeClass name"

if [[ -z "$namespace" ]]; then
  namespace="podman-benchmark-$(date -u +%Y%m%d%H%M%S)-$$"
fi
[[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#namespace} -le 63 ]] || \
  die "Invalid benchmark namespace"

if [[ -z "$kubeconfig" ]]; then
  kubeconfig="$(default_kubeconfig kata-k8s)"
else
  kubeconfig="$(normalize_kubeconfig_path "$kubeconfig")"
fi
output_dir="$(normalize_kubeconfig_path "$output_dir")"
[[ -f "$kubeconfig" ]] || die "Kubeconfig not found: ${kubeconfig}"
kubeconfig="$(cd -- "$(dirname -- "$kubeconfig")" && pwd -P)/$(basename -- "$kubeconfig")"

for command_name in kubectl awk date sort mktemp tr; do
  require_command "$command_name"
done

workspace_image="$(version_value WorkspaceImage)"
inner_image="$(version_value InnerTestImage)"
for image in "$workspace_image" "$inner_image"; do
  [[ "$image" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@+-]{0,511}$ ]] || \
    die "Invalid benchmark image reference"
done

kube() {
  kubectl --kubeconfig "$kubeconfig" "$@"
}

mkdir -p -- "$output_dir"
output_dir="$(cd -- "$output_dir" && pwd -P)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
raw_path="${output_dir}/${timestamp}-podman-raw.csv"
summary_path="${output_dir}/${timestamp}-podman-summary.csv"
environment_path="${output_dir}/${timestamp}-podman-environment.txt"
tmp_dir="$(mktemp -d)"
namespace_created=false

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  rm -rf -- "$tmp_dir"
  if [[ "$namespace_created" == true && "$keep_namespace" == false ]]; then
    log "Deleting temporary namespace ${namespace}"
    kube delete namespace "$namespace" --wait=true --timeout=5m >/dev/null || \
      warn "Could not delete namespace ${namespace}"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

kube get node --request-timeout=10s >/dev/null
kube get runtimeclass "$runtime_class" >/dev/null

log "Creating temporary namespace ${namespace}"
kube create namespace "$namespace" >/dev/null
namespace_created=true
# The requested runc baseline is explicitly privileged/rootful. Kata keeps the
# audited non-privileged rootless profile; the temporary namespace is isolated
# from the code-server admission-policy binding.
kube label namespace "$namespace" --overwrite \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged >/dev/null

printf '%s\n' 'profile,metric,iteration,milliseconds,runtime_class' >"$raw_path"

write_manifest() {
  local profile="$1"
  local runtime_line=""
  local container_security
  if [[ "$profile" == kata ]]; then
    runtime_line="  runtimeClassName: ${runtime_class}"
    container_security=$(cat <<'EOF'
        privileged: false
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        allowPrivilegeEscalation: true
        readOnlyRootFilesystem: true
        procMount: Default
        seccompProfile:
          type: Unconfined
        capabilities:
          drop: ["ALL"]
          add: ["SETGID", "SETUID"]
EOF
)
  else
    container_security=$(cat <<'EOF'
        privileged: true
        runAsNonRoot: false
        runAsUser: 0
        runAsGroup: 0
        allowPrivilegeEscalation: true
        readOnlyRootFilesystem: false
        seccompProfile:
          type: Unconfined
EOF
)
  fi

  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: podman-${profile}
  namespace: ${namespace}
  labels:
    benchmark.code-server-kata/profile: ${profile}
spec:
${runtime_line}
  automountServiceAccountToken: false
  enableServiceLinks: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext:
    fsGroup: 1000
    fsGroupChangePolicy: OnRootMismatch
    supplementalGroupsPolicy: Strict
  containers:
    - name: podman
      image: ${workspace_image}
      imagePullPolicy: IfNotPresent
      command: ["/usr/bin/tini", "--", "/bin/bash", "-lc"]
      env:
        - name: TMPDIR
          value: /tmp
      args:
        - |
          set -euo pipefail
          umask 0027
          mkdir -p /home/podman/.cache /home/podman/.config/containers /tmp/podman-storage /tmp/run-user-1000 /var/tmp
          cat > /home/podman/.config/containers/storage.conf <<'STORAGE'
          [storage]
          driver = "vfs"
          runroot = "/tmp/run-user-1000/containers"
          graphroot = "/tmp/podman-storage"
          rootless_storage_path = "/tmp/podman-storage"
          STORAGE
          chmod 0600 /home/podman/.config/containers/storage.conf
          podman info --format '{{.Host.Security.Rootless}}|{{.Store.GraphDriverName}}'
          exec sleep infinity
      resources:
        requests:
          cpu: 500m
          memory: 512Mi
          ephemeral-storage: 256Mi
        limits:
          cpu: "2"
          memory: 2Gi
          ephemeral-storage: 2Gi
      securityContext:
${container_security}
      volumeMounts:
        - name: home
          mountPath: /home/podman
        - name: tmp
          mountPath: /tmp
        - name: var-tmp
          mountPath: /var/tmp
  volumes:
    - name: home
      emptyDir: {}
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 1Gi
    - name: var-tmp
      emptyDir:
        sizeLimit: 256Mi
EOF
}

for profile in runc-insecure kata; do
  write_manifest "$profile" | kube create -f - >/dev/null
done
for profile in runc-insecure kata; do
  if ! kube wait --namespace "$namespace" "pod/podman-${profile}" \
    --for=condition=Ready --timeout=5m >/dev/null; then
    kube describe pod "podman-${profile}" --namespace "$namespace" >&2 || true
    kube logs "podman-${profile}" --namespace "$namespace" >&2 || true
    die "Podman benchmark pod did not become Ready: ${profile}"
  fi
done

prepare_script=$(cat <<'EOF'
set -euo pipefail
image="$1"
expected_rootless="$2"
podman pull "$image" >/dev/null
test "$(podman info --format '{{.Host.Security.Rootless}}')" = "$expected_rootless"
test "$(podman info --format '{{.Store.GraphDriverName}}')" = vfs
rm -rf /tmp/podman-benchmark-context
mkdir -p /tmp/podman-benchmark-context
printf 'FROM %s\n%s\n%s\n%s\n%s\n' \
  "$image" \
  'RUN dd if=/dev/zero of=/payload bs=1M count=32 2>/dev/null && sha256sum /payload >/dev/null' \
  'USER 2000:2000' \
  'RUN test "$(id -u)" = 2000' \
  'CMD ["true"]' > /tmp/podman-benchmark-context/Containerfile
EOF
)

log "Pulling the pinned inner image and preparing identical build contexts"
for profile in runc-insecure kata; do
  expected_rootless=true
  [[ "$profile" == runc-insecure ]] && expected_rootless=false
  kube exec --namespace "$namespace" "pod/podman-${profile}" -- \
    bash -lc "$prepare_script" bash "$inner_image" "$expected_rootless"
done

{
  printf 'timestamp_utc=%s\n' "$timestamp"
  printf 'node=%s\n' "$(kube get node -o jsonpath='{.items[0].metadata.name}')"
  printf 'node_kernel=%s\n' "$(kube get node -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}')"
  printf 'container_runtime=%s\n' "$(kube get node -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}')"
  printf 'baseline_runtime=default-runc; privileged=true; rootless=false\n'
  printf 'kata_runtime_class=%s\n' "$runtime_class"
  printf 'workspace_image=%s\n' "$workspace_image"
  printf 'inner_image=%s\n' "$inner_image"
  printf 'iterations=%s\n' "$iterations"
  printf 'warmups=%s\n' "$warmups"
  printf 'note=complete-profile comparison; not isolated Kata overhead\n'
  printf 'benchmark_storage_driver=vfs (common denominator; production Kata uses overlay)\n'
  for profile in runc-insecure kata; do
    printf '%s_kernel=%s\n' "$profile" "$(kube exec --namespace "$namespace" "pod/podman-${profile}" -- uname -r | tr -d '\r')"
    printf '%s_podman=%s\n' "$profile" "$(kube exec --namespace "$namespace" "pod/podman-${profile}" -- podman --version | tr -d '\r')"
    printf '%s_storage=%s\n' "$profile" "$(kube exec --namespace "$namespace" "pod/podman-${profile}" -- podman info --format '{{.Host.Security.Rootless}}|{{.Store.GraphDriverName}}|{{.Store.GraphRoot}}' | tr -d '\r')"
  done
} >"$environment_path"

append_result() {
  local profile="$1" metric="$2" iteration="$3" milliseconds="$4"
  local runtime="default-runc-privileged-rootful"
  [[ "$profile" == kata ]] && runtime="$runtime_class"
  printf '%s,%s,%s,%s,%s\n' "$profile" "$metric" "$iteration" "$milliseconds" "$runtime" >>"$raw_path"
}

run_metric() {
  local profile="$1" metric="$2" iteration="$3" record="$4"
  local script elapsed_ns elapsed_ms
  case "$metric" in
    podman-run-true)
      script=$(cat <<'EOF'
set -euo pipefail
start=$(date +%s%N)
if ! podman run --rm --pull=never "$1" true >/tmp/podman-benchmark.log 2>&1; then
  cat /tmp/podman-benchmark.log >&2
  exit 1
fi
end=$(date +%s%N)
echo $((end-start))
EOF
)
      ;;
    podman-run-write-128mib)
      script=$(cat <<'EOF'
set -euo pipefail
start=$(date +%s%N)
if ! podman run --rm --pull=never "$1" sh -c \
  'dd if=/dev/zero of=/tmp/payload bs=1M count=128 conv=fsync 2>/dev/null' \
  >/tmp/podman-benchmark.log 2>&1; then
  cat /tmp/podman-benchmark.log >&2
  exit 1
fi
end=$(date +%s%N)
echo $((end-start))
EOF
)
      ;;
    podman-build-user2000)
      script=$(cat <<'EOF'
set -euo pipefail
export TMPDIR=/tmp
tag=localhost/podman-benchmark:latest
podman image rm -f "$tag" >/dev/null 2>&1 || true
start=$(date +%s%N)
if ! podman build --pull=never --no-cache --layers=false --tag "$tag" \
  /tmp/podman-benchmark-context >/tmp/podman-benchmark.log 2>&1; then
  cat /tmp/podman-benchmark.log >&2
  exit 1
fi
end=$(date +%s%N)
echo $((end-start))
podman image rm -f "$tag" >/dev/null 2>&1 || true
podman image prune -f >/dev/null 2>&1 || true
EOF
)
      ;;
    *) die "Unknown benchmark metric: ${metric}" ;;
  esac

  elapsed_ns="$(kube exec --namespace "$namespace" "pod/podman-${profile}" -- \
    bash -lc "$script" bash "$inner_image" | tr -d '\r\n')"
  [[ "$elapsed_ns" =~ ^[0-9]+$ ]] || \
    die "Invalid timing returned by ${profile}/${metric}: ${elapsed_ns}"
  elapsed_ms="$(awk -v ns="$elapsed_ns" 'BEGIN { printf "%.3f", ns/1000000 }')"
  if [[ "$record" == true ]]; then
    append_result "$profile" "$metric" "$iteration" "$elapsed_ms"
    printf '%-27s %-4s %2s/%s: %9s ms\n' \
      "$metric" "$profile" "$iteration" "$iterations" "$elapsed_ms"
  fi
}

metrics=(podman-run-true podman-run-write-128mib podman-build-user2000)

log "Warming Podman operations (${warmups} run per metric/profile)"
for ((i=1; i<=warmups; i++)); do
  for profile in runc-insecure kata; do
    for metric in "${metrics[@]}"; do
      run_metric "$profile" "$metric" "$i" false
    done
  done
done

log "Measuring Podman inside runc and Kata pods"
for ((i=1; i<=iterations; i++)); do
  if ((i % 2)); then
    profiles=(runc-insecure kata)
  else
    profiles=(kata runc-insecure)
  fi
  for profile in "${profiles[@]}"; do
    for metric in "${metrics[@]}"; do
      run_metric "$profile" "$metric" "$i" true
    done
  done
done

printf '%s\n' 'profile,metric,samples,p50_milliseconds,p95_milliseconds,mean_milliseconds' >"$summary_path"

summarize() {
  local profile="$1" metric="$2"
  local -a values
  local count p50_index p95_index p50 p95 mean
  mapfile -t values < <(awk -F, -v p="$profile" -v m="$metric" \
    'NR > 1 && $1 == p && $2 == m { print $4 }' "$raw_path" | sort -n)
  count="${#values[@]}"
  ((count > 0)) || die "No samples for ${profile}/${metric}"
  p50_index=$(( (50 * count + 99) / 100 - 1 ))
  p95_index=$(( (95 * count + 99) / 100 - 1 ))
  p50="${values[$p50_index]}"
  p95="${values[$p95_index]}"
  mean="$(printf '%s\n' "${values[@]}" | awk '{ sum += $1 } END { printf "%.3f", sum/NR }')"
  printf '%s,%s,%s,%s,%s,%s\n' \
    "$profile" "$metric" "$count" "$p50" "$p95" "$mean" >>"$summary_path"
}

for metric in "${metrics[@]}"; do
  summarize runc-insecure "$metric"
  summarize kata "$metric"
done

printf '\nPodman benchmark summary\n'
cat "$summary_path"
printf '\nRaw samples: %s\n' "$raw_path"
printf 'Summary:     %s\n' "$summary_path"
printf 'Environment: %s\n' "$environment_path"
printf 'Interpretation: runc-insecure is privileged/rootful; Kata is non-privileged/rootless.\n'
