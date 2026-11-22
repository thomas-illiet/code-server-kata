# syntax=docker/dockerfile:1.7

ARG BASE_IMAGE=docker.io/library/ubuntu:24.04@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289
FROM ${BASE_IMAGE} AS uidmap-builder

ARG SHADOW_VERSION=4.13
ARG SHADOW_SHA256=9afe245d79a2e7caac5f1ed62519b17416b057ec89df316df1c3935502f9dd2c

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      libcap-dev \
      pkg-config \
      xz-utils; \
    archive="shadow-${SHADOW_VERSION}.tar.xz"; \
    curl --fail --location --retry 5 --output "/tmp/${archive}" \
      "https://github.com/shadow-maint/shadow/releases/download/${SHADOW_VERSION}/${archive}"; \
    echo "${SHADOW_SHA256}  /tmp/${archive}" | sha256sum --check --strict; \
    mkdir /tmp/shadow; \
    tar --extract --xz --file "/tmp/${archive}" --directory /tmp/shadow --strip-components=1; \
    cd /tmp/shadow; \
    ./configure \
      --disable-nls \
      --without-audit \
      --without-libpam \
      --without-btrfs \
      --without-selinux \
      --without-acl \
      --without-attr \
      --without-skey \
      --without-tcb \
      --without-yescrypt \
      --without-nscd \
      --without-sssd \
      --without-su \
      --enable-subordinate-ids; \
    grep -qx '#define HAVE_SYS_CAPABILITY_H 1' config.h; \
    make -j"$(nproc)"; \
    strip src/newuidmap src/newgidmap; \
    install -D -m 4755 src/newuidmap /out/newuidmap; \
    install -D -m 4755 src/newgidmap /out/newgidmap

FROM ${BASE_IMAGE}

ARG CODE_SERVER_VERSION=4.146.0
ARG CODE_SERVER_AMD64_SHA256=cf7e82ca5fe1df664d43a43d900c3c9710f8f3403a5e8d0e18f6a12d10d7401b
ARG TARGETARCH=amd64

USER root

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bash \
      buildah \
      ca-certificates \
      curl \
      git \
      gzip \
      iproute2 \
      aardvark-dns \
      netavark \
      openssh-client \
      passt \
      podman \
      procps \
      tar \
      tini \
      uidmap; \
    rm -rf /var/lib/apt/lists/* /etc/sudoers.d; \
    test ! -e /usr/bin/sudo

COPY --from=uidmap-builder --chmod=4755 /out/newuidmap /usr/bin/newuidmap
COPY --from=uidmap-builder --chmod=4755 /out/newgidmap /usr/bin/newgidmap

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) code_server_sha256="${CODE_SERVER_AMD64_SHA256}" ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    archive="code-server-${CODE_SERVER_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    curl --fail --location --retry 5 --output "/tmp/${archive}" \
      "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/${archive}"; \
    echo "${code_server_sha256}  /tmp/${archive}" | sha256sum --check --strict; \
    tar --extract --gzip --file "/tmp/${archive}" --directory /opt; \
    mv "/opt/code-server-${CODE_SERVER_VERSION}-linux-${TARGETARCH}" /opt/code-server; \
    ln -s /opt/code-server/bin/code-server /usr/local/bin/code-server; \
    rm -f "/tmp/${archive}"

RUN set -eux; \
    existing_group="$(getent group 1000 | cut -d: -f1 || true)"; \
    if [ -n "${existing_group}" ] && [ "${existing_group}" != podman ]; then \
      groupmod --new-name podman "${existing_group}"; \
    elif [ -z "${existing_group}" ]; then \
      groupadd --gid 1000 podman; \
    fi; \
    existing_user="$(getent passwd 1000 | cut -d: -f1 || true)"; \
    if [ -n "${existing_user}" ] && [ "${existing_user}" != podman ]; then \
      usermod --login podman --home /home/podman --move-home "${existing_user}"; \
    elif [ -z "${existing_user}" ]; then \
      useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash podman; \
    fi; \
    usermod --gid 1000 --groups '' --shell /bin/bash podman; \
    test "$(id -G podman)" = 1000; \
    printf 'podman:100000:65536\n' > /etc/subuid; \
    printf 'podman:100000:65536\n' > /etc/subgid; \
    find /usr -xdev -type f -perm /6000 \
      ! -path /usr/bin/newuidmap \
      ! -path /usr/bin/newgidmap \
      -exec chmod a-s {} +; \
    test "$(stat -c '%a %u:%g' /usr/bin/newuidmap)" = '4755 0:0'; \
    test "$(stat -c '%a %u:%g' /usr/bin/newgidmap)" = '4755 0:0'; \
    test "$(find /usr -xdev -type f -perm /6000 | wc -l)" -eq 2; \
    install -d -o 1000 -g 1000 -m 0750 \
      /home/podman; \
    podman --version

COPY --chmod=0644 container/containers.conf /etc/containers/containers-rootless.conf
COPY --chmod=0644 container/storage-overlay.conf /etc/containers/storage-overlay.conf
COPY --chmod=0755 container/start-code-server.sh /usr/local/bin/start-code-server

ENV HOME=/home/podman \
    USER=podman \
    XDG_RUNTIME_DIR=/tmp/run-user-1000 \
    XDG_CONFIG_HOME=/home/podman/.config \
    CONTAINERS_CONF=/etc/containers/containers-rootless.conf \
    CONTAINERS_STORAGE_CONF=/home/podman/.config/containers/storage.conf

WORKDIR /home/podman
EXPOSE 8080

USER 1000:1000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/start-code-server"]
