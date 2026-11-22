#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'Static validation failed: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "${repo_root}/$1" ]] || fail "missing $1"
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "${text}" "${repo_root}/${file}" || fail "${file} does not contain: ${text}"
}

version_value() {
  local key="$1"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*'([^']+)'.*$/\\1/p" \
    "${repo_root}/versions.psd1" | head -n 1
}

required_files=(
  .github/workflows/validate.yml
  .github/workflows/release-image.yml
  .github/dependabot.yml
  CHANGELOG.md
  CONTRIBUTING.md
  Makefile
  SECURITY.md
  versions.psd1
  container/Dockerfile
  container/containers.conf
  container/start-code-server.sh
  k8s/base/deployment.yaml
  k8s/base/admission-policy.yaml
  scripts/wsl/lib/common.sh
  scripts/wsl/check-version-pins.sh
  scripts/wsl/doctor.sh
  scripts/wsl/check-repository.sh
  scripts/wsl/install-tools.sh
  scripts/wsl/provision-cluster.sh
  scripts/wsl/deploy-workspace.sh
  scripts/wsl/verify-workspace.sh
  scripts/wsl/benchmark-podman.sh
  scripts/wsl/status.sh
  scripts/wsl/shell.sh
  docs/wsl.md
  docs/shadow-uidmap.md
  docs/benchmark-podman-20261121.md
  docs/storage-performance.md
  docs/production.md
  docs/upgrading.md
  k8s/overlays/production/kustomization.yaml
  k8s/overlays/production/ingress.yaml
  k8s/overlays/production/network-policy.yaml
  k8s/overlays/production/README.md
)
for file in "${required_files[@]}"; do
  assert_file "${file}"
done

while IFS= read -r -d '' script; do
  bash -n "${script}" || fail "bash syntax error in ${script#"${repo_root}/"}"
done < <(find "${repo_root}/scripts" "${repo_root}/tests" -type f -name '*.sh' -print0)

bash "${repo_root}/scripts/wsl/check-version-pins.sh"

if command -v shellcheck >/dev/null 2>&1; then
  mapfile -d '' shell_scripts < <(find "${repo_root}/scripts/wsl" "${repo_root}/tests" -type f -name '*.sh' -print0)
  shellcheck --severity=warning "${shell_scripts[@]}"
fi

base_image="$(version_value BaseImage)"
code_server_version="$(version_value CodeServerVersion)"
code_server_sha="$(version_value CodeServerAmd64Sha256)"
shadow_version="$(version_value ShadowVersion)"
shadow_sha="$(version_value ShadowSha256)"
workspace_image="$(version_value WorkspaceImage)"
kata_smoke_image="$(version_value KataSmokeImage)"
pod_startup_image="$(version_value PodStartupImage)"
for value in "${base_image}" "${code_server_version}" "${code_server_sha}" \
  "${shadow_version}" "${shadow_sha}" "${workspace_image}" \
  "${kata_smoke_image}" "${pod_startup_image}"; do
  [[ -n "${value}" ]] || fail 'versions.psd1 contains an empty required value'
done
[[ "${kata_smoke_image}" =~ ^docker\.io/library/busybox:[^@]+@sha256:[0-9a-f]{64}$ ]] || fail 'Kata smoke image is not digest-pinned'
[[ "${pod_startup_image}" =~ ^registry\.k8s\.io/e2e-test-images/agnhost:[^@]+@sha256:[0-9a-f]{64}$ ]] || fail 'Pod startup image is not digest-pinned'
assert_contains Makefile 'versions-check:'
assert_contains Makefile 'check: versions-check'
assert_contains scripts/linux/Install-K3sKata.sh '${KATA_SMOKE_IMAGE}'
assert_contains scripts/linux/Install-K3sKata.sh 'KATA_SMOKE_IMAGE must be pinned by a sha256 digest.'
assert_contains scripts/wsl/provision-cluster.sh 'version_value KataSmokeImage'
assert_contains scripts/windows/New-HyperVKataCluster.ps1 '$pinnedVersions.KataSmokeImage'
assert_contains scripts/windows/Benchmark.ps1 '$versions.InnerTestImage'
assert_contains scripts/windows/Benchmark.ps1 '$versions.PodStartupImage'
! grep -Fq -- 'docker.io/library/alpine:3.23' "${repo_root}/scripts/windows/Benchmark.ps1" || fail 'PowerShell benchmark contains an unpinned Alpine image'
! grep -Fq -- "registry.k8s.io/e2e-test-images/agnhost:2.57'" "${repo_root}/scripts/windows/Benchmark.ps1" || fail 'PowerShell benchmark contains an unpinned agnhost image'
grep -Fq -- '$(version_value InnerTestImage)' "${repo_root}/scripts/wsl/benchmark-podman.sh" || fail 'Podman benchmark does not use the pinned inner image'
grep -Fq -- '$(version_value WorkspaceImage)' "${repo_root}/scripts/wsl/benchmark-podman.sh" || fail 'Podman benchmark does not use the workspace image'
assert_contains scripts/wsl/benchmark-podman.sh 'privileged: true'
assert_contains scripts/wsl/benchmark-podman.sh 'privileged: false'
assert_contains scripts/wsl/benchmark-podman.sh 'driver = "vfs"'
assert_contains scripts/wsl/benchmark-podman.sh 'podman-build-user2000'

dockerfile="${repo_root}/container/Dockerfile"
grep -Fq -- "${base_image}" "${dockerfile}" || fail 'Ubuntu base image is not digest-pinned'
grep -Fq -- "${code_server_version}" "${dockerfile}" || fail 'code-server version is not pinned'
grep -Fq -- "${code_server_sha}" "${dockerfile}" || fail 'code-server checksum is not pinned'
grep -Fq -- "${shadow_version}" "${dockerfile}" || fail 'Shadow version is not pinned'
grep -Fq -- "${shadow_sha}" "${dockerfile}" || fail 'Shadow checksum is not pinned'
grep -Fq -- '#define HAVE_SYS_CAPABILITY_H 1' "${dockerfile}" || fail 'Shadow capability-aware build is not asserted'
grep -Eq 'COPY[[:space:]]+--from=uidmap-builder[[:space:]]+--chmod=4755[[:space:]]+/out/newuidmap' "${dockerfile}" || fail 'newuidmap is not copied from the pinned builder'
grep -Eq 'COPY[[:space:]]+--from=uidmap-builder[[:space:]]+--chmod=4755[[:space:]]+/out/newgidmap' "${dockerfile}" || fail 'newgidmap is not copied from the pinned builder'
grep -Fq -- 'test "$(find /usr -xdev -type f -perm /6000 | wc -l)" -eq 2' "${dockerfile}" || fail 'exact setid helper count is not asserted'
! grep -Eqi 'NOPASSWD' "${dockerfile}" || fail 'passwordless sudo is forbidden'

containers_conf="${repo_root}/container/containers.conf"
grep -Eq '^cgroups[[:space:]]*=[[:space:]]*"enabled"[[:space:]]*$' "${containers_conf}" || fail 'Podman cgroups must be enabled'
grep -Eq '^netns[[:space:]]*=[[:space:]]*"host"[[:space:]]*$' "${containers_conf}" || fail 'Podman must share the Kata network namespace'
grep -Eq '^pidns[[:space:]]*=[[:space:]]*"host"[[:space:]]*$' "${containers_conf}" || fail 'Podman must share the Kata PID namespace'

command -v kubectl >/dev/null 2>&1 || fail 'kubectl is required to render Kustomize overlays'
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT
for profile in kvm mshv; do
  rendered="${tmp_dir}/${profile}.yaml"
  kubectl kustomize "${repo_root}/k8s/overlays/${profile}" >"${rendered}"
  if [[ "${profile}" == kvm ]]; then
    expected_runtime='kata-qemu-runtime-rs'
  else
    expected_runtime='kata-clh-azure-runtime-rs'
  fi
  grep -Fq -- "${workspace_image}" "${rendered}" || fail "${profile} overlay does not use the pinned workspace image"
  grep -Eq "^[[:space:]]*runtimeClassName:[[:space:]]*${expected_runtime}[[:space:]]*$" "${rendered}" || fail "${profile} overlay RuntimeClass mismatch"
  ! grep -Eq '^[[:space:]]*privileged:[[:space:]]*true[[:space:]]*$' "${rendered}" || fail "${profile} overlay contains a privileged container"
  grep -Eq '^[[:space:]]*privileged:[[:space:]]*false[[:space:]]*$' "${rendered}" || fail "${profile} overlay does not disable privileged mode"
  grep -Eq '^[[:space:]]*allowPrivilegeEscalation:[[:space:]]*true[[:space:]]*$' "${rendered}" || fail "${profile} overlay must permit the audited setuid helpers"
  grep -Eq '^[[:space:]]*readOnlyRootFilesystem:[[:space:]]*true[[:space:]]*$' "${rendered}" || fail "${profile} overlay root filesystem is not read-only"
  grep -Eq '^[[:space:]]*runAsNonRoot:[[:space:]]*true[[:space:]]*$' "${rendered}" || fail "${profile} overlay does not require a non-root UID"
  grep -Eq '^[[:space:]]*type:[[:space:]]*Unconfined[[:space:]]*$' "${rendered}" || fail "${profile} overlay seccomp contract changed"
  grep -Eq '^[[:space:]]*supplementalGroupsPolicy:[[:space:]]*Strict[[:space:]]*$' "${rendered}" || fail "${profile} overlay does not enforce strict supplemental groups"
  [[ "$(grep -Ec '^[[:space:]]*- SETGID[[:space:]]*$' "${rendered}")" -eq 1 ]] || fail "${profile} overlay SETGID allowlist mismatch"
  [[ "$(grep -Ec '^[[:space:]]*- SETUID[[:space:]]*$' "${rendered}")" -eq 1 ]] || fail "${profile} overlay SETUID allowlist mismatch"
  [[ "$(grep -Ec '^[[:space:]]*- ALL[[:space:]]*$' "${rendered}")" -eq 1 ]] || fail "${profile} overlay drop ALL mismatch"
  ! grep -Eq '^[[:space:]]*- (SYS_ADMIN|DAC_OVERRIDE)[[:space:]]*$' "${rendered}" || fail "${profile} overlay adds a forbidden capability"
  grep -Eq '^[[:space:]]*claimName:[[:space:]]*code-server-home[[:space:]]*$' "${rendered}" || fail "${profile} overlay does not mount the home PVC"
  grep -Eq '^[[:space:]]*(-[[:space:]]+)?mountPath:[[:space:]]*/home/podman[[:space:]]*$' "${rendered}" || fail "${profile} overlay does not mount /home/podman"
  grep -Eq '^[[:space:]]*(-[[:space:]]+)?mountPath:[[:space:]]*/tmp[[:space:]]*$' "${rendered}" || fail "${profile} overlay does not mount /tmp"
  grep -Eq '^[[:space:]]*(-[[:space:]]+)?mountPath:[[:space:]]*/var/tmp[[:space:]]*$' "${rendered}" || fail "${profile} overlay does not mount /var/tmp"
  for cache_path in \
    /tmp/cache \
    /tmp/cache/npm \
    /tmp/cache/pip \
    /tmp/cache/go-build; do
    grep -Fq -- "value: ${cache_path}" "${rendered}" || fail "${profile} overlay does not route cache to ${cache_path}"
  done
  grep -Eq '^[[:space:]]*value:[[:space:]]*/tmp[[:space:]]*$' "${rendered}" || fail "${profile} overlay does not set TMPDIR=/tmp"
  grep -Eq '^[[:space:]]*nodePort:[[:space:]]*30443[[:space:]]*$' "${rendered}" || fail "${profile} overlay does not expose NodePort 30443"
  ! grep -Eq '^[[:space:]]*(hostPID|hostIPC|hostNetwork):[[:space:]]*true[[:space:]]*$' "${rendered}" || fail "${profile} overlay shares a Kubernetes host namespace"
  ! grep -Eq '^[[:space:]]*hostPath:' "${rendered}" || fail "${profile} overlay contains a hostPath"
done

production_rendered="${tmp_dir}/production.yaml"
kubectl kustomize "${repo_root}/k8s/overlays/production" >"${production_rendered}"
grep -Eq '^[[:space:]]*type:[[:space:]]*ClusterIP[[:space:]]*$' "${production_rendered}" || fail 'production Service is not internal'
! grep -Eq '^[[:space:]]*nodePort:' "${production_rendered}" || fail 'production overlay exposes a NodePort'
grep -Fq -- 'registry.example.invalid/code-server-podman@sha256:0000000000000000000000000000000000000000000000000000000000000000' "${production_rendered}" || fail 'production overlay must fail closed with a reserved image placeholder'
grep -Eq '^[[:space:]]*kind:[[:space:]]*Ingress[[:space:]]*$' "${production_rendered}" || fail 'production overlay has no TLS ingress'
grep -Eq '^[[:space:]]*kind:[[:space:]]*NetworkPolicy[[:space:]]*$' "${production_rendered}" || fail 'production overlay has no ingress policy'

policy="${repo_root}/k8s/base/admission-policy.yaml"
for term in runtimeClassName hostPath hostPID hostIPC hostNetwork supplementalGroupsPolicy privileged capabilities SETGID SETUID ephemeralContainers; do
  grep -Fq -- "${term}" "${policy}" || fail "admission policy does not constrain ${term}"
done

printf 'Static validation passed (WSL/Linux path).\n'
