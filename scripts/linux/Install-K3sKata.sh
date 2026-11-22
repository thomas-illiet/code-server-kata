#!/usr/bin/env bash
set -Eeuo pipefail

K3S_VERSION="${K3S_VERSION:-v1.37.2+k3s1}"
KATA_VERSION="${KATA_VERSION:-4.4.0}"
HELM_VERSION="${HELM_VERSION:-v4.3.2}"
KATA_SMOKE_IMAGE="${KATA_SMOKE_IMAGE:?KATA_SMOKE_IMAGE must be a digest-pinned image reference}"
KATA_RUNTIME_CLASS="${KATA_RUNTIME_CLASS:-kata-qemu-runtime-rs}"
K3S_NODE_IP="${K3S_NODE_IP:-}"
KATA_VALUES_FILE="${KATA_VALUES_FILE:-/home/ubuntu/kata-values.yaml}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this installer as root." >&2
  exit 1
fi

if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
  echo "This lab currently supports amd64 only." >&2
  exit 1
fi

if [[ ! "${KATA_SMOKE_IMAGE}" =~ ^[^[:space:]@]+:[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]]; then
  echo "KATA_SMOKE_IMAGE must be pinned by a sha256 digest." >&2
  exit 1
fi

if ! grep -Eq '(vmx|svm)' /proc/cpuinfo; then
  echo "The Hyper-V host did not expose hardware virtualization to the VM." >&2
  exit 42
fi

modprobe kvm_amd 2>/dev/null || modprobe kvm_intel 2>/dev/null || true
modprobe vhost_vsock
modprobe vhost_net

if [[ ! -c /dev/kvm || ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  echo "/dev/kvm is not a usable character device; software emulation is refused." >&2
  exit 42
fi

if grep -q svm /proc/cpuinfo; then
  cpu_kvm_module='kvm_amd'
else
  cpu_kvm_module='kvm_intel'
fi
cat >/etc/modules-load.d/kata-kvm.conf <<EOF
kvm
${cpu_kvm_module}
vhost_vsock
vhost_net
EOF

swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
cat >/etc/sysctl.d/99-kubernetes-kata.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf -- "${tmp_dir}"
}
trap cleanup EXIT

curl --fail --location --retry 5 --output "${tmp_dir}/install-k3s.sh" https://get.k3s.io
chmod 0755 "${tmp_dir}/install-k3s.sh"

k3s_exec='server --write-kubeconfig-mode=0640 --disable=traefik --disable=servicelb'
if [[ -n "${K3S_NODE_IP}" ]]; then
  k3s_exec+=" --node-ip=${K3S_NODE_IP} --tls-san=${K3S_NODE_IP}"
fi

INSTALL_K3S_VERSION="${K3S_VERSION}" \
INSTALL_K3S_EXEC="${k3s_exec}" \
  "${tmp_dir}/install-k3s.sh"

systemctl enable --now k3s
for _ in $(seq 1 120); do
  if k3s kubectl get --raw=/readyz >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
k3s kubectl get --raw=/readyz >/dev/null
k3s kubectl wait --for=condition=Ready node --all --timeout=10m

helm_archive="helm-${HELM_VERSION}-linux-amd64.tar.gz"
curl --fail --location --retry 5 \
  --output "${tmp_dir}/${helm_archive}" \
  "https://get.helm.sh/${helm_archive}"
curl --fail --location --retry 5 \
  --output "${tmp_dir}/${helm_archive}.sha256sum" \
  "https://get.helm.sh/${helm_archive}.sha256sum"
expected_helm_sha="$(awk 'NR == 1 { print $1 }' "${tmp_dir}/${helm_archive}.sha256sum")"
actual_helm_sha="$(sha256sum "${tmp_dir}/${helm_archive}" | awk '{ print $1 }')"
if [[ -z "${expected_helm_sha}" || "${actual_helm_sha}" != "${expected_helm_sha}" ]]; then
  echo "Helm archive checksum verification failed." >&2
  exit 1
fi
tar -xzf "${tmp_dir}/${helm_archive}" -C "${tmp_dir}"
install -o root -g root -m 0755 "${tmp_dir}/linux-amd64/helm" /usr/local/bin/helm

if [[ ! -f "${KATA_VALUES_FILE}" ]]; then
  echo "Missing Kata values file: ${KATA_VALUES_FILE}" >&2
  exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
helm upgrade --install kata-deploy \
  oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
  --version "${KATA_VERSION}" \
  --namespace kata-system \
  --create-namespace \
  --values "${KATA_VALUES_FILE}" \
  --wait \
  --timeout 20m

k3s kubectl wait --for=create "runtimeclass/${KATA_RUNTIME_CLASS}" --timeout=3m
k3s kubectl wait --for=condition=Ready node --all --timeout=10m

k3s kubectl delete pod kata-smoke-test --ignore-not-found --wait=true
cat <<EOF | k3s kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: kata-smoke-test
  labels:
    app.kubernetes.io/name: kata-smoke-test
spec:
  runtimeClassName: ${KATA_RUNTIME_CLASS}
  restartPolicy: Never
  containers:
    - name: test
      image: ${KATA_SMOKE_IMAGE}
      command: ["sh", "-c", "sleep 1800"]
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: "1"
          memory: 512Mi
EOF

if ! k3s kubectl wait --for=condition=Ready pod/kata-smoke-test --timeout=10m; then
  k3s kubectl describe pod kata-smoke-test >&2 || true
  k3s kubectl get events --sort-by=.lastTimestamp >&2 || true
  exit 1
fi

node_kernel="$(uname -r)"
kata_kernel="$(k3s kubectl exec kata-smoke-test -- uname -r)"
if [[ -z "${kata_kernel}" || "${kata_kernel}" == "${node_kernel}" ]]; then
  echo "Kata isolation proof failed: node and pod report the same kernel (${node_kernel})." >&2
  exit 1
fi

k3s kubectl delete pod kata-smoke-test --wait=true

install -o ubuntu -g ubuntu -m 0600 \
  /etc/rancher/k3s/k3s.yaml /home/ubuntu/k3s-host.yaml
if [[ -n "${K3S_NODE_IP}" ]]; then
  sed -i "s#https://127.0.0.1:6443#https://${K3S_NODE_IP}:6443#" \
    /home/ubuntu/k3s-host.yaml
fi

cat >/home/ubuntu/.kata-install-complete <<EOF
k3s=${K3S_VERSION}
kata=${KATA_VERSION}
runtime_class=${KATA_RUNTIME_CLASS}
node_kernel=${node_kernel}
kata_kernel=${kata_kernel}
EOF
chown ubuntu:ubuntu /home/ubuntu/.kata-install-complete
chmod 0600 /home/ubuntu/.kata-install-complete

echo "K3s: $(k3s --version | head -n 1)"
echo 'containerd:'
k3s ctr version
echo "Kata RuntimeClass: ${KATA_RUNTIME_CLASS}"
echo "Node kernel: ${node_kernel}"
echo "Kata guest kernel: ${kata_kernel}"
echo "Kata Containers is installed and the hardware-isolated smoke test passed."
