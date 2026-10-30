#!/bin/bash
# Build Debian bookworm arm64 rootfs with Bitcoin Knots for LXC.
# Uses Docker --platform linux/arm64.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# C4 supply-chain: version tags and pinned SHA256s come from build/version.env
# (single source of truth; version.env's KNOTS_TAG was previously unused here,
# a drift hazard). Normalize make 'VAR := value' lines for shell consumption.
VERSION_ENV="${ROOT}/build/version.env"
_version_env() {  # <VAR> — print value of 'VAR := value' from version.env
  sed -nE "s/^$1[[:space:]]*:=[[:space:]]*([^[:space:]#]+).*/\1/p" "$VERSION_ENV" | tail -n1
}
KNOTS_TAG="$(_version_env KNOTS_TAG)"
KNOTS_SHA256="$(_version_env KNOTS_SHA256)"
CORE_VER="$(_version_env CORE_VER)"
CORE_TAG="$(_version_env CORE_TAG)"
CORE_SHA256="$(_version_env CORE_SHA256)"
DEBIAN_IMAGE="$(_version_env DEBIAN_IMAGE)"
for v in KNOTS_TAG KNOTS_SHA256 CORE_VER CORE_TAG CORE_SHA256 DEBIAN_IMAGE; do
  if [ -z "${!v}" ]; then
    echo "==> ERROR: $v missing in $VERSION_ENV" >&2
    exit 1
  fi
done

# C4: verify a tarball against its pinned SHA256 — always, even when reused
# from the DL_DIR cache (cached files were trusted unchecked before). Call
# before any tar extraction.
verify_sha256() {  # <file> <pinned-sha256> <label>
  echo "==> Verifying $3 SHA256 ($(basename "$1"))"
  if ! echo "$2  $1" | sha256sum -c -; then
    echo "==> ERROR: SHA256 mismatch for $3 tarball: $1" >&2
    echo "    Expected $2 (build/version.env). Delete the file to re-download," >&2
    echo "    or update the pin if the release was intentionally bumped." >&2
    exit 1
  fi
}

# B4a — non-RDTS / non-BIP-110 parallel build (not *20260508)
KNOTS_DIRNAME="bitcoin-${KNOTS_TAG#v}"
KNOTS_TGZ="${KNOTS_DIRNAME}-aarch64-linux-gnu.tar.gz"
KNOTS_URL="https://github.com/bitcoinknots/bitcoin/releases/download/${KNOTS_TAG}/${KNOTS_TGZ}"

OUT_DIR="${ROOT}/lxc/out"
DL_DIR="${ROOT}/build/dl"
ROOTFS_DIR="${OUT_DIR}/rootfs"
STAGING="${OUT_DIR}/staging"
HELPERS="${OUT_DIR}/helpers"
CONTAINER="knots-rootfs-build-$$"

mkdir -p "$DL_DIR" "$OUT_DIR" "$STAGING" "$HELPERS"

cp "${ROOT}/lxc/knots-service" "${HELPERS}/knots-service"

CORE_DIRNAME="bitcoin-${CORE_TAG#v}"
CORE_TGZ="${CORE_DIRNAME}-aarch64-linux-gnu.tar.gz"
CORE_URL="https://bitcoincore.org/bin/bitcoin-core-${CORE_VER}/${CORE_TGZ}"

cat > "${HELPERS}/knots-init" <<'EOF'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mkdir -p /run /mnt/bitcoin
ip link set lo up 2>/dev/null || true
/usr/local/bin/knots-service start || true
# Keep PID 1 alive without busy-looping (bare `wait` returns immediately).
while true; do
  sleep 3600
done
EOF
chmod 755 "${HELPERS}/knots-service" "${HELPERS}/knots-init"

echo "==> Downloading Knots ${KNOTS_TAG}"
if [ ! -f "${DL_DIR}/${KNOTS_TGZ}" ]; then
  curl -fL -o "${DL_DIR}/${KNOTS_TGZ}.partial" "$KNOTS_URL"
  mv "${DL_DIR}/${KNOTS_TGZ}.partial" "${DL_DIR}/${KNOTS_TGZ}"
fi
verify_sha256 "${DL_DIR}/${KNOTS_TGZ}" "$KNOTS_SHA256" "Knots ${KNOTS_TAG}"

rm -rf "$STAGING"
mkdir -p "$STAGING"
tar -xzf "${DL_DIR}/${KNOTS_TGZ}" -C "$STAGING"

echo "==> Pulling ${DEBIAN_IMAGE} (arm64)"
# X5: pinned by digest (build/version.env) — a tag can be re-pointed upstream.
# If the registry is unreachable, reuse a local copy of the SAME digest only.
if ! docker pull --platform linux/arm64 "$DEBIAN_IMAGE"; then
	if docker image inspect "$DEBIAN_IMAGE" >/dev/null 2>&1; then
		echo "==> WARN: docker pull failed; using the local copy of ${DEBIAN_IMAGE}"
	else
		echo "==> ERROR: docker pull failed and ${DEBIAN_IMAGE} is not present locally" >&2
		exit 1
	fi
fi

# Host is x86_64; arm64 containers need qemu-user binfmt (otherwise: exec format error).
# X5: no privileged third-party container to register it — use the host's
# distro package (Debian/Ubuntu: qemu-user-static or qemu-user-binfmt).
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
	echo "==> ERROR: qemu-aarch64 binfmt is not registered on this host" >&2
	echo "    Install it from your distribution, e.g.: sudo apt install qemu-user-binfmt (older releases: qemu-user-static binfmt-support)" >&2
	exit 1
fi

echo "==> Creating container"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker create --name "$CONTAINER" --platform linux/arm64 "$DEBIAN_IMAGE" sleep infinity >/dev/null
docker start "$CONTAINER" >/dev/null
# Fail closed if sleep never starts (missing binfmt / wrong-arch local image).
if ! docker exec "$CONTAINER" true >/dev/null 2>&1; then
	echo "==> ERROR: arm64 container not runnable (exec format / binfmt)." >&2
	docker inspect "$CONTAINER" --format 'Status={{.State.Status}} Exit={{.State.ExitCode}} Error={{.State.Error}}' >&2 || true
	exit 1
fi

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Installing minimal runtime packages"
docker exec "$CONTAINER" bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates \
    libatomic1 \
    libevent-2.1-7 \
    libevent-pthreads-2.1-7 \
    libsqlite3-0 \
    libstdc++6 \
    iproute2 \
    iputils-ping \
    procps
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  mkdir -p /usr/local/bin /etc/bitcoin /mnt/bitcoin /run
'

echo "==> Downloading Bitcoin Core ${CORE_TAG} (selectable impl)"
if [ ! -f "${DL_DIR}/${CORE_TGZ}" ]; then
  curl -fL -o "${DL_DIR}/${CORE_TGZ}.partial" "$CORE_URL"
  mv "${DL_DIR}/${CORE_TGZ}.partial" "${DL_DIR}/${CORE_TGZ}"
fi
verify_sha256 "${DL_DIR}/${CORE_TGZ}" "$CORE_SHA256" "Bitcoin Core ${CORE_TAG}"
rm -rf "${STAGING}/core"
mkdir -p "${STAGING}/core"
tar -xzf "${DL_DIR}/${CORE_TGZ}" -C "${STAGING}/core"

echo "==> Installing Knots + Core binaries (shared datadir; Knots default)"
docker exec "$CONTAINER" mkdir -p \
  /usr/local/lib/bitcoin/knots/bin /usr/local/lib/bitcoin/core/bin /usr/local/bin /etc/bitcoin
docker cp "${STAGING}/${KNOTS_DIRNAME}/bin/bitcoind" "$CONTAINER:/usr/local/lib/bitcoin/knots/bin/bitcoind"
docker cp "${STAGING}/${KNOTS_DIRNAME}/bin/bitcoin-cli" "$CONTAINER:/usr/local/lib/bitcoin/knots/bin/bitcoin-cli"
docker cp "${STAGING}/core/${CORE_DIRNAME}/bin/bitcoind" "$CONTAINER:/usr/local/lib/bitcoin/core/bin/bitcoind"
docker cp "${STAGING}/core/${CORE_DIRNAME}/bin/bitcoin-cli" "$CONTAINER:/usr/local/lib/bitcoin/core/bin/bitcoin-cli"
docker exec "$CONTAINER" bash -c '
  ln -sfn /usr/local/lib/bitcoin/knots/bin/bitcoind /usr/local/bin/bitcoind
  ln -sfn /usr/local/lib/bitcoin/knots/bin/bitcoin-cli /usr/local/bin/bitcoin-cli
  chmod 755 /usr/local/lib/bitcoin/knots/bin/* /usr/local/lib/bitcoin/core/bin/*
'
docker cp "${ROOT}/lxc/bitcoin.conf" "$CONTAINER:/etc/bitcoin/bitcoin.conf"
docker cp "${HELPERS}/knots-service" "$CONTAINER:/usr/local/bin/knots-service"
docker cp "${HELPERS}/knots-init" "$CONTAINER:/sbin/knots-init"
docker exec "$CONTAINER" bash -c '
  chmod 755 /usr/local/bin/bitcoind /usr/local/bin/bitcoin-cli /usr/local/bin/knots-service /sbin/knots-init
  ln -sfn /sbin/knots-init /sbin/init
'

echo "==> Exporting rootfs"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"
docker export "$CONTAINER" | tar -x -C "$ROOTFS_DIR"
rm -f "$ROOTFS_DIR/etc/machine-id" "$ROOTFS_DIR/var/lib/dbus/machine-id"
mkdir -p "$ROOTFS_DIR/etc/bitcoin" "$ROOTFS_DIR/mnt/bitcoin"
# ensure init link survived export
ln -sfn knots-init "$ROOTFS_DIR/sbin/init"

TAR="${OUT_DIR}/knots-rootfs-arm64.tar.zst"
rm -f "$TAR"
tar -C "$ROOTFS_DIR" -cf - . | zstd -T0 -10 -o "$TAR"
echo "==> Rootfs: $ROOTFS_DIR ($(du -sh "$ROOTFS_DIR" | awk '{print $1}'))"
echo "==> Archive: $TAR ($(du -h "$TAR" | awk '{print $1}'))"
echo DONE
