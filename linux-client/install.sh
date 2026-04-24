#!/usr/bin/env bash
# OpenLay VPN Linux client — remote installer.
#
# Usage (one-liner from any Linux box):
#   curl -sSL https://raw.githubusercontent.com/openlay/openlay-vpn-client-release/main/linux-client/install.sh | sudo bash
#
# What it does:
#   1. Installs OS-level prerequisites (wireguard-tools, iptables, tpm2-tools,
#      systemd-resolved) via apt/dnf/pacman.
#   2. Downloads the latest olv-vpn binary (matching this machine's arch) from
#      this release repo, verifies its SHA256, installs at /usr/sbin/olv-vpn.
#   3. Installs the olv-vpn.service systemd unit (disabled by default).
#   4. Creates /etc/olv + /var/lib/olv state dirs.
#
# After install:
#   sudo olv-vpn enroll --code <10-digit> --server https://vpn.livevpn.com
#   sudo olv-vpn connect
#   sudo systemctl enable --now olv-vpn    # optional: auto-reconnect on TTL
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "install.sh must run as root (writes /usr/sbin, /etc, /var/lib)" >&2
    exit 1
fi

BASE_URL="${OLV_RELEASE_BASE:-https://raw.githubusercontent.com/openlay/openlay-vpn-client-release/main/linux-client}"
BIN_PATH=/usr/sbin/olv-vpn
SYSTEMD_UNIT=/etc/systemd/system/olv-vpn.service

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo x86_64 ;;
        aarch64|arm64)  echo aarch64 ;;
        *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
    esac
}

pkg_install() {
    local pkgs=("$@")
    if command -v apt-get >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
    elif command -v dnf >/dev/null; then
        dnf install -y "${pkgs[@]}"
    elif command -v yum >/dev/null; then
        yum install -y "${pkgs[@]}"
    elif command -v pacman >/dev/null; then
        pacman -Sy --noconfirm "${pkgs[@]}"
    else
        return 1
    fi
}

ARCH=$(detect_arch)
BIN_NAME="olv-vpn-linux-${ARCH}"

echo "[install] OS prerequisites (wireguard-tools, iptables, systemd-resolved)..."
if ! pkg_install wireguard-tools iptables systemd-resolved; then
    echo "[install] package manager not recognized; install manually:" >&2
    echo "          wireguard-tools, iptables, systemd-resolved" >&2
    exit 1
fi

echo "[install] optional: tpm2-tools (for TPM-backed device identity)..."
pkg_install tpm2-tools || echo "[install]   tpm2-tools not installed — falling back to software key"

# systemd-resolved is required by wg-quick's DNS= handling.
systemctl enable --now systemd-resolved 2>/dev/null || true

echo "[install] downloading $BIN_NAME from $BASE_URL ..."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$BASE_URL/$BIN_NAME"     -o "$TMP/$BIN_NAME"
curl -fsSL "$BASE_URL/SHA256SUMS"    -o "$TMP/SHA256SUMS"
curl -fsSL "$BASE_URL/VERSION"       -o "$TMP/VERSION"
curl -fsSL "$BASE_URL/olv-vpn.service" -o "$TMP/olv-vpn.service"

echo "[install] verifying SHA256 ..."
EXPECTED=$(grep -E "\\s\\*?${BIN_NAME}$" "$TMP/SHA256SUMS" | awk '{print $1}')
if [[ -z "$EXPECTED" ]]; then
    echo "[install] no checksum for $BIN_NAME in SHA256SUMS" >&2
    exit 1
fi
ACTUAL=$(sha256sum "$TMP/$BIN_NAME" | awk '{print $1}')
if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    echo "[install] checksum mismatch!" >&2
    echo "  expected: $EXPECTED" >&2
    echo "  actual:   $ACTUAL"   >&2
    exit 1
fi
echo "[install]   ok: $ACTUAL"

echo "[install] installing binary to $BIN_PATH ..."
install -m 0755 "$TMP/$BIN_NAME" "$BIN_PATH"

echo "[install] installing systemd unit to $SYSTEMD_UNIT ..."
install -m 0644 "$TMP/olv-vpn.service" "$SYSTEMD_UNIT"
systemctl daemon-reload

echo "[install] creating state dirs ..."
install -d -m 0755 /etc/olv
install -d -m 0700 /var/lib/olv

echo
echo "[install] done — version $(cat "$TMP/VERSION") on $ARCH"
echo "[install] sanity check:"
"$BIN_PATH" doctor || true
echo
echo "Next steps:"
echo "  sudo olv-vpn enroll --code <10-digit-code> --server https://vpn.livevpn.com"
echo "  sudo olv-vpn connect"
echo "  sudo systemctl enable --now olv-vpn   # optional — auto-reconnect on TTL"
echo
echo "Later: self-update with"
echo "  sudo olv-vpn update"
