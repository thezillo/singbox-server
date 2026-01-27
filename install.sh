#!/bin/bash
set -euo pipefail

# Sing-box Server Bootstrap Installer
# Downloads the latest release and runs deploy.sh
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/USER/singbox-server/main/install.sh | sudo bash
#   curl -sSL ... | sudo bash -s -- --warp
#   curl -sSL ... | sudo WARP_LICENSE_KEY=xxx bash -s -- --warp
#   curl -sSL ... | sudo bash -s -- --dry-run

REPO="thezillo/singbox-server"
BRANCH="main"

# ============================================================================
# Checks
# ============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Please run as root (sudo)"
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    echo "[ERROR] Unsupported system (missing /etc/os-release)"
    exit 1
fi

if ! command -v curl &>/dev/null; then
    echo "[ERROR] curl is required. Install: apt install curl / dnf install curl"
    exit 1
fi

# ============================================================================
# Download and extract
# ============================================================================
TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "[*] Downloading singbox-server..."
curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" \
    -o "$TMPDIR/repo.tar.gz"

echo "[*] Extracting..."
tar -xzf "$TMPDIR/repo.tar.gz" -C "$TMPDIR" --strip-components=1

# ============================================================================
# Run deploy
# ============================================================================
chmod +x "$TMPDIR/server/deploy.sh"
"$TMPDIR/server/deploy.sh" "$@"
