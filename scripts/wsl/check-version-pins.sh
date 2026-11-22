#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

fail() {
  printf 'Version pin validation failed: %s\n' "$*" >&2
  exit 1
}

assert_matches() {
  local name="$1"
  local value="$2"
  local pattern="$3"
  [[ "${value}" =~ ${pattern} ]] || fail "${name} has an invalid format: ${value}"
}

assert_contains() {
  local relative_path="$1"
  local expected="$2"
  grep -Fq -- "${expected}" "${REPO_ROOT}/${relative_path}" || \
    fail "${relative_path} is not synchronized with versions.psd1: ${expected}"
}

required_keys=(
  PodmanMinimum
  BaseImage
  CodeServerVersion
  CodeServerAmd64Sha256
  ShadowVersion
  ShadowSha256
  WorkspaceImage
  InnerTestImage
  KataSmokeImage
  PodStartupImage
  K3sVersion
  HelmVersion
  UbuntuImage
  MultipassVersion
  KindVersion
  KubernetesVersion
  KindNodeImage
  KataVersion
  KataChart
)
for key in "${required_keys[@]}"; do
  value="$(version_value "${key}")"
  [[ -n "${value}" ]] || fail "versions.psd1 contains an empty ${key}"
done

base_image="$(version_value BaseImage)"
code_server_version="$(version_value CodeServerVersion)"
code_server_sha="$(version_value CodeServerAmd64Sha256)"
shadow_version="$(version_value ShadowVersion)"
shadow_sha="$(version_value ShadowSha256)"
workspace_image="$(version_value WorkspaceImage)"
inner_test_image="$(version_value InnerTestImage)"
kata_smoke_image="$(version_value KataSmokeImage)"
pod_startup_image="$(version_value PodStartupImage)"
k3s_version="$(version_value K3sVersion)"
helm_version="$(version_value HelmVersion)"
ubuntu_image="$(version_value UbuntuImage)"
kubernetes_version="$(version_value KubernetesVersion)"
kind_node_image="$(version_value KindNodeImage)"
kata_version="$(version_value KataVersion)"

sha_pattern='^[0-9a-f]{64}$'
image_pattern='^[^[:space:]@]+:[^[:space:]@]+@sha256:[0-9a-f]{64}$'
semver_pattern='^[0-9]+\.[0-9]+\.[0-9]+$'

assert_matches CodeServerAmd64Sha256 "${code_server_sha}" "${sha_pattern}"
assert_matches ShadowSha256 "${shadow_sha}" "${sha_pattern}"
for pair in \
  "BaseImage|${base_image}" \
  "InnerTestImage|${inner_test_image}" \
  "KataSmokeImage|${kata_smoke_image}" \
  "PodStartupImage|${pod_startup_image}" \
  "KindNodeImage|${kind_node_image}"; do
  name="${pair%%|*}"
  image="${pair#*|}"
  assert_matches "${name}" "${image}" "${image_pattern}"
done

assert_matches CodeServerVersion "${code_server_version}" "${semver_pattern}"
assert_matches KubernetesVersion "${kubernetes_version}" "${semver_pattern}"
assert_matches KataVersion "${kata_version}" "${semver_pattern}"
assert_matches HelmVersion "${helm_version}" '^v[0-9]+\.[0-9]+\.[0-9]+$'
assert_matches K3sVersion "${k3s_version}" '^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$'

expected_base_prefix="docker.io/library/ubuntu:${ubuntu_image}@sha256:"
[[ "${base_image}" == "${expected_base_prefix}"* ]] || \
  fail "BaseImage must use UbuntuImage ${ubuntu_image}"
[[ "${inner_test_image}" == docker.io/library/alpine:* ]] || \
  fail 'InnerTestImage must be the digest-pinned Alpine test image'
[[ "${kata_smoke_image}" == docker.io/library/busybox:* ]] || \
  fail 'KataSmokeImage must be the digest-pinned BusyBox smoke-test image'
[[ "${pod_startup_image}" == registry.k8s.io/e2e-test-images/agnhost:* ]] || \
  fail 'PodStartupImage must be the digest-pinned Kubernetes agnhost image'

expected_workspace="localhost/code-server-podman:${code_server_version}-ubuntu${ubuntu_image}"
[[ "${workspace_image}" == "${expected_workspace}" ]] || \
  fail "WorkspaceImage must be ${expected_workspace}"
expected_kind_prefix="kindest/node:v${kubernetes_version}@sha256:"
[[ "${kind_node_image}" == "${expected_kind_prefix}"* ]] || \
  fail "KindNodeImage must use KubernetesVersion ${kubernetes_version}"

[[ "${k3s_version}" =~ ^v([0-9]+)\.([0-9]+)\. ]] || \
  fail "cannot parse K3sVersion: ${k3s_version}"
k3s_minor="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
[[ "${kubernetes_version}" =~ ^([0-9]+)\.([0-9]+)\. ]] || \
  fail "cannot parse KubernetesVersion: ${kubernetes_version}"
kubernetes_minor="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
[[ "${k3s_minor}" == "${kubernetes_minor}" ]] || \
  fail "K3s ${k3s_minor} and kubectl/Kubernetes ${kubernetes_minor} use different minor versions"

assert_contains container/Dockerfile "${base_image}"
assert_contains container/Dockerfile "${code_server_version}"
assert_contains container/Dockerfile "${code_server_sha}"
assert_contains container/Dockerfile "${shadow_version}"
assert_contains container/Dockerfile "${shadow_sha}"
assert_contains k8s/base/deployment.yaml "${workspace_image}"
assert_contains kind/cluster.yaml "${kind_node_image}"
assert_contains scripts/linux/Install-K3sKata.sh "K3S_VERSION=\"\${K3S_VERSION:-${k3s_version}}\""
assert_contains scripts/linux/Install-K3sKata.sh "KATA_VERSION=\"\${KATA_VERSION:-${kata_version}}\""
assert_contains scripts/linux/Install-K3sKata.sh "HELM_VERSION=\"\${HELM_VERSION:-${helm_version}}\""
assert_contains scripts/linux/Install-K3sKata.sh '${KATA_SMOKE_IMAGE}'
assert_contains scripts/wsl/provision-cluster.sh 'version_value KataSmokeImage'
assert_contains scripts/wsl/deploy-workspace.sh 'BASE_IMAGE=${base_image}'
assert_contains scripts/wsl/deploy-workspace.sh 'CODE_SERVER_AMD64_SHA256=${code_server_amd64_sha256}'
assert_contains scripts/windows/New-HyperVKataCluster.ps1 '$pinnedVersions.KataSmokeImage'
assert_contains scripts/windows/New-HyperVKataCluster.ps1 '$pinnedVersions.K3sVersion'
assert_contains scripts/windows/New-HyperVKataCluster.ps1 '$pinnedVersions.KataVersion'
assert_contains scripts/windows/New-HyperVKataCluster.ps1 '$pinnedVersions.HelmVersion'
assert_contains scripts/windows/Benchmark.ps1 '$versions.InnerTestImage'
assert_contains scripts/windows/Benchmark.ps1 '$versions.PodStartupImage'

scan_roots=(container k8s kind scripts)
external_references="$(
  grep -RInE \
    --include='Dockerfile' --include='*.yaml' --include='*.yml' \
    --include='*.sh' --include='*.ps1' --exclude='check-version-pins.sh' \
    "(docker\\.io|quay\\.io|ghcr\\.io|registry\\.k8s\\.io)/[^[:space:]\"']+:[^[:space:]\"']+" \
    "${scan_roots[@]/#/${REPO_ROOT}/}" || true
)"
if [[ -n "${external_references}" ]]; then
  while IFS= read -r reference; do
    [[ "${reference}" == *'@sha256:'* ]] || \
      fail "external image reference is not digest-pinned: ${reference}"
  done <<<"${external_references}"
fi

printf 'Version pin validation passed.\n'
