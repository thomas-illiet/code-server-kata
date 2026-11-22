#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" == "0" ]]; then
  echo "code-server must not run as root" >&2
  exit 1
fi
if [[ "$(id -G)" != "1000" ]]; then
  echo "code-server must not inherit image-defined supplemental groups" >&2
  exit 1
fi

expected_cap_bnd="00000000000000c0"
for field in CapInh CapPrm CapEff CapAmb; do
  value="$(awk -v field="${field}:" '$1 == field { print $2 }' /proc/self/status)"
  if [[ "${value}" != "0000000000000000" ]]; then
    echo "${field} must be zero, got ${value}" >&2
    exit 1
  fi
done
cap_bnd="$(awk '$1 == "CapBnd:" { print $2 }' /proc/self/status)"
if [[ "${cap_bnd}" != "${expected_cap_bnd}" ]]; then
  echo "CapBnd must contain only SETGID and SETUID; got ${cap_bnd}" >&2
  exit 1
fi
no_new_privs="$(awk '$1 == "NoNewPrivs:" { print $2 }' /proc/self/status)"
if [[ "${no_new_privs}" != "0" ]]; then
  echo "NoNewPrivs must be 0 so the two setuid uidmap helpers can run" >&2
  exit 1
fi

: "${PASSWORD:?PASSWORD must be supplied from a Kubernetes Secret}"

umask 0027
mkdir -p \
  "${HOME}/.config/code-server" \
  "${HOME}/.config/containers" \
  "${HOME}/.local/share/code-server" \
  "${HOME}/workspace" \
  "${XDG_CACHE_HOME:-/tmp/cache}" \
  "${npm_config_cache:-/tmp/cache/npm}" \
  "${PIP_CACHE_DIR:-/tmp/cache/pip}" \
  "${GOCACHE:-/tmp/cache/go-build}" \
  "${XDG_RUNTIME_DIR:-/tmp/run-user-1000}" \
  /tmp/podman-storage
cp /etc/containers/storage-overlay.conf "${HOME}/.config/containers/storage.conf"
chmod 0600 "${HOME}/.config/containers/storage.conf"

for helper in newuidmap newgidmap; do
  helper_path="$(command -v "${helper}" || true)"
  if [[ -z "${helper_path}" ||
        "$(stat -c '%a %u:%g' "${helper_path}")" != "4755 0:0" ]]; then
    echo "${helper} must be the root-owned, libcap-aware setuid helper" >&2
    exit 1
  fi
done
setid_paths="$(find /usr -xdev -type f -perm /6000 -printf '%p\n' | sort)"
expected_setid_paths=$'/usr/bin/newgidmap\n/usr/bin/newuidmap'
if [[ "${setid_paths}" != "${expected_setid_paths}" ]]; then
  echo "Only newuidmap and newgidmap may carry a setid bit" >&2
  exit 1
fi
grep -qx 'podman:100000:65536' /etc/subuid
grep -qx 'podman:100000:65536' /etc/subgid

unset CONTAINER_HOST DOCKER_HOST
rootless="$(podman info --format '{{.Host.Security.Rootless}}')"
driver="$(podman info --format '{{.Store.GraphDriverName}}')"
if [[ "${rootless}" != "true" ]]; then
  echo "Podman did not initialize in rootless mode" >&2
  exit 1
fi
if [[ "${driver}" != "overlay" ]]; then
  echo "Unexpected Podman storage driver: ${driver}" >&2
  exit 1
fi

exec code-server \
  --auth password \
  --bind-addr 0.0.0.0:8080 \
  --disable-telemetry \
  --extensions-dir "${HOME}/.local/share/code-server/extensions" \
  --user-data-dir "${HOME}/.local/share/code-server/user-data" \
  "${HOME}/workspace"
