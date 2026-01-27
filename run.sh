#!/bin/bash
set -e

# Local sing-box client runner
# Expects config.json in the same directory (see clients/ for templates)
#
# Usage:
#   ./run.sh              # Uses config.json in current directory
#
# To create a config, copy a template and fill in your server details:
#   cp clients/default.template.json config.json
#   # Edit config.json with your server IP, UUID, keys, etc.

SINGBOX_VERSION="1.11.4"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/sing-box"
CONFIG="$SCRIPT_DIR/config.json"

detect_platform() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case "$OS" in
        darwin) OS="darwin" ;;
        linux) OS="linux" ;;
        *) echo "Unsupported OS: $OS"; exit 1 ;;
    esac

    case "$ARCH" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
    esac

    echo "${OS}-${ARCH}"
}

download_singbox() {
    PLATFORM=$(detect_platform)
    URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-${PLATFORM}.tar.gz"

    echo "Downloading sing-box ${SINGBOX_VERSION} for ${PLATFORM}..."
    curl -fsSL "$URL" -o /tmp/sing-box.tar.gz

    echo "Extracting..."
    tar -xzf /tmp/sing-box.tar.gz -C /tmp
    mv "/tmp/sing-box-${SINGBOX_VERSION}-${PLATFORM}/sing-box" "$BINARY"
    chmod +x "$BINARY"
    rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${SINGBOX_VERSION}-${PLATFORM}"

    echo "Installed: $BINARY"
}

if [[ ! -f "$BINARY" ]]; then
    download_singbox
fi

if [[ ! -f "$CONFIG" ]]; then
    echo "Config not found: $CONFIG"
    echo "Copy a template: cp clients/default.template.json config.json"
    exit 1
fi

echo "Starting sing-box..."
echo "Press Ctrl+C to stop"
sudo "$BINARY" run -c "$CONFIG"
