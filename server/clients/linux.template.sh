#!/bin/bash
set -euo pipefail

# Sing-box Linux Client Installer
# Auto-updating proxy with systemd service
#
# Usage:
#   curl -fsSL https://SERVER/linux.sh | sudo bash                       # Basic install
#   curl -fsSL https://SERVER/linux.sh | sudo bash -s -- --system-proxy  # + system proxy
#   curl -fsSL https://SERVER/linux.sh | sudo bash -s -- --remove-proxy  # Remove system proxy

readonly CONFIG_URL="${CONFIG_URL}"
readonly INSTALL_DIR="/opt/sing-box-client"
readonly SERVICE_NAME="sing-box-client"
readonly UPDATE_INTERVAL=30
readonly PROXY_PORT=1080

# Parse flags
SYSTEM_PROXY=false
REMOVE_PROXY=false
for arg in "$@"; do
    case "$arg" in
        --system-proxy) SYSTEM_PROXY=true ;;
        --remove-proxy) REMOVE_PROXY=true ;;
    esac
done

# Handle --remove-proxy quickly
if $REMOVE_PROXY; then
    echo "Removing system proxy configuration..."
    rm -f /etc/profile.d/proxy.sh
    rm -f /etc/apt/apt.conf.d/99proxy 2>/dev/null || true
    [ -f /etc/dnf/dnf.conf ] && sed -i '/^proxy=/d' /etc/dnf/dnf.conf 2>/dev/null || true
    echo "Done! Restart your shell or run: unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY"
    cat > /dev/null 2>&1 || true  # Consume remaining stdin to avoid curl error
    exit 0
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[*]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# Check root
[[ $EUID -ne 0 ]] && error "Please run as root: curl ... | sudo bash"

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║           Sing-box Linux Client Installer                 ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Proxy: 127.0.0.1:${PROXY_PORT} (SOCKS5 & HTTP)                    ║"
echo "║  Auto-update: every ${UPDATE_INTERVAL}s                               ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    error "Cannot detect OS"
fi

# Install sing-box
install_singbox() {
    if command -v sing-box &>/dev/null; then
        log "sing-box already installed: $(sing-box version | head -1)"
        return
    fi

    log "Installing sing-box..."

    case "$OS" in
        ubuntu|debian)
            apt-get update
            apt-get install -y curl
            curl -fsSL https://sing-box.app/gpg.key | gpg --dearmor -o /etc/apt/keyrings/sing-box.gpg
            echo "deb [signed-by=/etc/apt/keyrings/sing-box.gpg] https://deb.sagernet.org/ * *" > /etc/apt/sources.list.d/sing-box.list
            apt-get update
            apt-get install -y sing-box
            ;;
        fedora|centos|rhel|rocky|almalinux)
            dnf install -y dnf-plugins-core
            dnf config-manager --add-repo https://sing-box.app/sing-box.repo
            dnf install -y sing-box
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm sing-box
            ;;
        *)
            # Fallback: download binary
            log "Installing from GitHub releases..."
            ARCH=$(uname -m)
            case "$ARCH" in
                x86_64) SB_ARCH="amd64" ;;
                aarch64) SB_ARCH="arm64" ;;
                *) error "Unsupported architecture: $ARCH" ;;
            esac

            VERSION=$(curl -sf https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d'"' -f4)
            curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION#v}-linux-${SB_ARCH}.tar.gz" | tar xz -C /tmp
            mv /tmp/sing-box-*/sing-box /usr/local/bin/
            chmod +x /usr/local/bin/sing-box
            rm -rf /tmp/sing-box-*
            ;;
    esac

    log "sing-box installed: $(sing-box version | head -1)"
}

# Setup directories and config
setup_config() {
    log "Setting up configuration..."

    mkdir -p "$INSTALL_DIR"

    # Download initial config
    curl -fsSL "${CONFIG_URL}" -o "$INSTALL_DIR/config.json"
    chmod 600 "$INSTALL_DIR/config.json"

    # Save config URL for updater
    echo "${CONFIG_URL}" > "$INSTALL_DIR/.config_url"
    chmod 600 "$INSTALL_DIR/.config_url"

    log "Config downloaded"
}

# Create updater script
create_updater() {
    log "Creating config updater..."

    cat > "$INSTALL_DIR/updater.sh" << 'UPDATER_EOF'
#!/bin/bash
set -euo pipefail

INSTALL_DIR="/opt/sing-box-client"
CONFIG_URL=$(cat "$INSTALL_DIR/.config_url")
CONFIG_FILE="$INSTALL_DIR/config.json"

# Download new config
NEW_CONFIG=$(curl -sf "$CONFIG_URL") || exit 0

# Check if changed
NEW_HASH=$(echo "$NEW_CONFIG" | sha256sum | cut -d' ' -f1)
OLD_HASH=$(sha256sum "$CONFIG_FILE" 2>/dev/null | cut -d' ' -f1 || echo "")

if [ "$NEW_HASH" != "$OLD_HASH" ]; then
    echo "[$(date)] Config changed, updating..."
    echo "$NEW_CONFIG" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    # Validate config
    if sing-box check -c "$CONFIG_FILE" 2>/dev/null; then
        systemctl restart sing-box-client
        echo "[$(date)] Service restarted"
    else
        echo "[$(date)] Invalid config, skipping"
    fi
fi
UPDATER_EOF

    chmod +x "$INSTALL_DIR/updater.sh"
}

# Create systemd service
create_service() {
    log "Creating systemd service..."

    cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Sing-box Client Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/sing-box run -c ${INSTALL_DIR}/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    # Create timer for auto-update
    cat > /etc/systemd/system/${SERVICE_NAME}-updater.timer << EOF
[Unit]
Description=Sing-box Config Updater Timer

[Timer]
OnBootSec=30
OnUnitActiveSec=${UPDATE_INTERVAL}

[Install]
WantedBy=timers.target
EOF

    cat > /etc/systemd/system/${SERVICE_NAME}-updater.service << EOF
[Unit]
Description=Sing-box Config Updater

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/updater.sh
StandardOutput=journal
EOF

    systemctl daemon-reload
    systemctl enable --now ${SERVICE_NAME}
    systemctl enable --now ${SERVICE_NAME}-updater.timer

    log "Service started"
}

# Configure system proxy (only if --system-proxy flag passed)
setup_system_proxy() {
    if ! $SYSTEM_PROXY; then
        return
    fi

    log "Configuring system-wide proxy..."

    # Environment file
    cat > /etc/profile.d/proxy.sh << EOF
export http_proxy="http://127.0.0.1:${PROXY_PORT}"
export https_proxy="http://127.0.0.1:${PROXY_PORT}"
export HTTP_PROXY="http://127.0.0.1:${PROXY_PORT}"
export HTTPS_PROXY="http://127.0.0.1:${PROXY_PORT}"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="localhost,127.0.0.1,::1"
EOF
    chmod 644 /etc/profile.d/proxy.sh

    # For apt
    if [ -d /etc/apt/apt.conf.d ]; then
        cat > /etc/apt/apt.conf.d/99proxy << EOF
Acquire::http::Proxy "http://127.0.0.1:${PROXY_PORT}";
Acquire::https::Proxy "http://127.0.0.1:${PROXY_PORT}";
EOF
    fi

    # For dnf/yum
    if [ -f /etc/dnf/dnf.conf ]; then
        grep -q "^proxy=" /etc/dnf/dnf.conf || echo "proxy=http://127.0.0.1:${PROXY_PORT}" >> /etc/dnf/dnf.conf
    fi

    log "System proxy configured. Run: source /etc/profile.d/proxy.sh"
}

# Show status
show_status() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                  Installation Complete!                   ║"
    echo "╠═══════════════════════════════════════════════════════════╣"
    echo "║                                                           ║"
    echo "║  Proxy:     127.0.0.1:${PROXY_PORT}                                ║"
    echo "║  Protocol:  SOCKS5 / HTTP                                 ║"
    echo "║  Auto-update: every ${UPDATE_INTERVAL} seconds                        ║"
    echo "║                                                           ║"
    echo "╠═══════════════════════════════════════════════════════════╣"
    echo "║  Commands:                                                ║"
    echo "║                                                           ║"
    echo "║  Status:    systemctl status ${SERVICE_NAME}          ║"
    echo "║  Logs:      journalctl -u ${SERVICE_NAME} -f          ║"
    echo "║  Restart:   systemctl restart ${SERVICE_NAME}         ║"
    echo "║  Stop:      systemctl stop ${SERVICE_NAME}            ║"
    echo "║  Uninstall: ${INSTALL_DIR}/uninstall.sh            ║"
    echo "║                                                           ║"
    echo "╠═══════════════════════════════════════════════════════════╣"
    echo "║  Test:                                                    ║"
    echo "║  curl -x socks5://127.0.0.1:${PROXY_PORT} https://ifconfig.me    ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
}

# Create uninstall script
create_uninstaller() {
    cat > "$INSTALL_DIR/uninstall.sh" << 'EOF'
#!/bin/bash
set -e

echo "Uninstalling sing-box client..."

systemctl stop sing-box-client 2>/dev/null || true
systemctl stop sing-box-client-updater.timer 2>/dev/null || true
systemctl disable sing-box-client 2>/dev/null || true
systemctl disable sing-box-client-updater.timer 2>/dev/null || true

rm -f /etc/systemd/system/sing-box-client.service
rm -f /etc/systemd/system/sing-box-client-updater.timer
rm -f /etc/systemd/system/sing-box-client-updater.service
rm -f /etc/profile.d/proxy.sh
rm -f /etc/apt/apt.conf.d/99proxy 2>/dev/null || true

systemctl daemon-reload

rm -rf /opt/sing-box-client

echo "Uninstalled successfully"
EOF
    chmod +x "$INSTALL_DIR/uninstall.sh"
}

# Main
main() {
    install_singbox
    setup_config
    create_updater
    create_service
    create_uninstaller
    setup_system_proxy
    show_status
}

main
