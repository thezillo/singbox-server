#!/bin/bash
set -euo pipefail
umask 077

# Sing-box Server One-Click Deployment
# Supports: Ubuntu/Debian, RHEL/CentOS/Fedora
#
# Environment variables:
#   INSTALL_DIR       - Installation directory (default: /opt/sing-box)
#   SING_BOX_VERSION  - Sing-box Docker image version (default: v1.11.4)
#   CADDY_VERSION     - Caddy Docker image version (default: 2.9)
#   WARP_LICENSE_KEY  - WARP+ license key (implies --warp)
#   NON_INTERACTIVE   - Set to "true" to skip all prompts
#
# Usage:
#   sudo ./deploy.sh                              # Interactive, no WARP
#   sudo ./deploy.sh --warp                       # Interactive, with WARP
#   sudo WARP_LICENSE_KEY=xxxxx ./deploy.sh       # With WARP+ key
#   sudo ./deploy.sh --dry-run                    # Show what would be done
#   sudo ./deploy.sh --uninstall                  # Remove installation
#   sudo ./deploy.sh --update                     # Pull latest images, restart

# ============================================================================
# Constants
# ============================================================================
readonly SCRIPT_VERSION="1.2.0"
readonly CREDENTIALS_VERSION="2"
readonly CADDY_PORT_MIN=10000
readonly CADDY_PORT_MAX=60000
readonly CERT_VALIDITY_DAYS=825  # ~2.25 years, within CA/Browser Forum guidelines
readonly HYSTERIA_PASSWORD_LENGTH=24
readonly HEALTH_CHECK_TIMEOUT=30
readonly HEALTH_CHECK_INTERVAL=1

# ============================================================================
# Configuration
# ============================================================================
INSTALL_DIR="${INSTALL_DIR:-/opt/sing-box}"
SING_BOX_VERSION="${SING_BOX_VERSION:-v1.11.4}"
CADDY_VERSION="${CADDY_VERSION:-2.9}"
CONFIGS_DIR="${INSTALL_DIR}/www"
LOG_FILE="${INSTALL_DIR}/deploy.log"
DRY_RUN=false
USE_WARP=false

# WARP_LICENSE_KEY implies --warp
if [ -n "${WARP_LICENSE_KEY:-}" ]; then
    USE_WARP=true
fi

# Pipe detection: if stdin is not a terminal, go non-interactive
if [ ! -t 0 ] || [ "${NON_INTERACTIVE:-}" = "true" ]; then
    NON_INTERACTIVE=true
else
    NON_INTERACTIVE=false
fi

# Global state
SERVER_IP=""
DOMAIN=""
OS=""
WGCF_ARCH=""
STEP_CURRENT=0
STEP_TOTAL=7
DEFAULT_COUNTRY="ru"

# ============================================================================
# Signal handling
# ============================================================================
on_interrupt() {
    echo ""
    echo "[!] Deployment interrupted. Partial installation may exist at $INSTALL_DIR"
    echo "    Run: sudo $(basename "$0") --uninstall"
    exit 130
}

trap on_interrupt INT TERM

# ============================================================================
# Logging
# ============================================================================
log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true

    case "$level" in
        INFO)  echo "      $msg" ;;
        OK)    echo "      ✓ $msg" ;;
        WARN)  echo "      ! $msg" >&2 ;;
        ERROR) echo "[ERROR] $msg" >&2 ;;
    esac
}

log_secret() {
    # Log without exposing full secret
    local name="$1"
    local value="$2"
    if [ -n "$value" ]; then
        echo "  $name: ${value:0:8}..."
    fi
}

step() {
    STEP_CURRENT=$((STEP_CURRENT + 1))
    echo ""
    echo "[${STEP_CURRENT}/${STEP_TOTAL}] $1..."
}

# ============================================================================
# Error handling and cleanup
# ============================================================================
cleanup_on_error() {
    local exit_code=$?
    log ERROR "Deployment failed with exit code $exit_code"
    log ERROR "Check log file: $LOG_FILE"

    # Stop containers if they're in bad state
    if [ -f "$INSTALL_DIR/docker-compose.yaml" ]; then
        cd "$INSTALL_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
    fi

    exit "$exit_code"
}

trap cleanup_on_error ERR

# ============================================================================
# Utility functions
# ============================================================================
get_server_ip() {
    local services=("ifconfig.me" "icanhazip.com" "api.ipify.org" "ipecho.net/plain")
    local ip=""

    for service in "${services[@]}"; do
        ip=$(curl -s4 --connect-timeout 5 --max-time 10 "$service" 2>/dev/null | tr -d '[:space:]') || continue
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done

    log ERROR "Cannot determine server IP address"
    exit 1
}

urlencode() {
    local string="$1"
    jq -rn --arg s "$string" '$s | @uri'
}

safe_load_credentials() {
    local file="$1"
    [ ! -f "$file" ] && return 1

    # Validate file permissions
    local perms
    perms=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null)
    if [ "$perms" != "600" ]; then
        log WARN "Fixing permissions on $file"
        chmod 600 "$file"
    fi

    # Check version compatibility
    local file_version
    file_version=$(grep -E "^CREDENTIALS_VERSION=" "$file" 2>/dev/null | cut -d'=' -f2 || echo "0")
    if [ "$file_version" != "$CREDENTIALS_VERSION" ]; then
        log WARN "Credentials file version mismatch (got $file_version, expected $CREDENTIALS_VERSION)"
    fi

    # Safe parsing - only allow known variables
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue

        # Remove quotes from value
        value="${value#\'}"
        value="${value%\'}"
        value="${value#\"}"
        value="${value%\"}"

        case "$key" in
            CONFIG_URL|CONFIG_SECRET|CADDY_PORT|\
            VLESS_UUID_DEFAULT|VLESS_UUID_ADGUARD|VLESS_UUID_PROXY|\
            REALITY_PUBLIC_KEY|REALITY_PRIVATE_KEY|\
            REALITY_SHORT_ID|HYSTERIA_PASSWORD|\
            AUTH_USER|AUTH_PASS)
                declare -g "$key=$value"
                ;;
        esac
    done < "$file"

    return 0
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
    else
        log ERROR "Cannot detect OS (missing /etc/os-release)"
        exit 1
    fi
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  WGCF_ARCH="amd64" ;;
        aarch64) WGCF_ARCH="arm64" ;;
        *)
            log ERROR "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

pkg_install() {
    local packages=("$@")
    case "$OS" in
        ubuntu|debian)
            apt-get install -y "${packages[@]}"
            ;;
        centos|rhel|fedora|almalinux|rocky)
            dnf install -y "${packages[@]}"
            ;;
        *)
            log ERROR "Unsupported OS: $OS"
            exit 1
            ;;
    esac
}

pkg_update() {
    case "$OS" in
        ubuntu|debian)
            apt-get update
            ;;
        centos|rhel|fedora|almalinux|rocky)
            dnf makecache
            ;;
    esac
}

wait_for_port() {
    local port="$1"
    local protocol="${2:-tcp}"
    local timeout="${3:-$HEALTH_CHECK_TIMEOUT}"

    for ((i=0; i<timeout; i++)); do
        if [ "$protocol" = "tcp" ]; then
            if nc -z localhost "$port" 2>/dev/null; then
                return 0
            fi
        else
            # For UDP, just check if process is listening
            if ss -uln | grep -q ":$port "; then
                return 0
            fi
        fi
        sleep "$HEALTH_CHECK_INTERVAL"
    done

    return 1
}

check_docker_compose_v2() {
    if ! docker compose version &>/dev/null; then
        log ERROR "Docker Compose v2 is required (docker compose, not docker-compose)"
        log ERROR "Install: https://docs.docker.com/compose/install/"
        exit 1
    fi
}

# ============================================================================
# Installation functions
# ============================================================================
install_docker() {
    if command -v docker &> /dev/null; then
        log OK "Docker already installed"
        check_docker_compose_v2
        return
    fi

    log INFO "Installing Docker..."

    if $DRY_RUN; then
        log INFO "[DRY-RUN] Would install Docker"
        return
    fi

    case "$OS" in
        ubuntu|debian)
            pkg_install ca-certificates curl gnupg
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/$OS/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            pkg_update
            pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
            ;;
        centos|rhel|fedora|almalinux|rocky)
            pkg_install dnf-plugins-core
            dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
            systemctl start docker
            systemctl enable docker
            ;;
    esac

    check_docker_compose_v2
    log OK "Docker installed"
}

install_tools() {
    log INFO "Installing required tools..."

    if $DRY_RUN; then
        log INFO "[DRY-RUN] Would install: openssl jq curl nc"
        return
    fi

    pkg_install openssl jq curl

    # Install netcat for health checks
    case "$OS" in
        ubuntu|debian)
            pkg_install netcat-openbsd
            ;;
        centos|rhel|fedora|almalinux|rocky)
            pkg_install nc
            ;;
    esac
}

# ============================================================================
# WARP setup
# ============================================================================
download_wgcf() {
    log INFO "Downloading wgcf..."

    local api_response
    api_response=$(curl -sf --connect-timeout 10 "https://api.github.com/repos/ViRb3/wgcf/releases/latest") || {
        log ERROR "Failed to fetch wgcf release info from GitHub API"
        exit 1
    }

    local wgcf_url
    wgcf_url=$(echo "$api_response" | jq -r ".assets[] | select(.name | contains(\"linux_${WGCF_ARCH}\")) | .browser_download_url" | head -1)

    if [ -z "$wgcf_url" ] || [ "$wgcf_url" = "null" ]; then
        log ERROR "Cannot find wgcf download URL for architecture: $WGCF_ARCH"
        exit 1
    fi

    local version
    version=$(echo "$api_response" | jq -r '.tag_name')
    log INFO "Downloading wgcf $version..."

    curl -fsSL --connect-timeout 30 -o wgcf "$wgcf_url" || {
        log ERROR "Failed to download wgcf"
        exit 1
    }

    # Verify it's actually a binary
    if ! file wgcf | grep -q "executable"; then
        log ERROR "Downloaded file is not a valid executable"
        rm -f wgcf
        exit 1
    fi

    chmod +x wgcf
    log OK "wgcf $version downloaded"
}

setup_warp() {
    log INFO "Setting up Cloudflare WARP..."
    cd "$INSTALL_DIR"

    # Download wgcf if needed
    if [ ! -f wgcf ]; then
        download_wgcf
    fi

    # Get license key (from env or prompt)
    local license_key=""
    if [ -n "${WARP_LICENSE_KEY:-}" ]; then
        log INFO "WARP+ license from environment: ${WARP_LICENSE_KEY:0:8}..."
        license_key="$WARP_LICENSE_KEY"
    elif [ ! -f wgcf-account.toml ]; then
        # Only prompt on first install, when interactive
        if [ "$NON_INTERACTIVE" = "false" ]; then
            echo ""
            echo "      WARP+ license key (faster speeds)"
            echo "      Get in mobile app: 1.1.1.1 (WARP)"
            echo "      Format: xxxxxxxx-xxxxxxxx-xxxxxxxx"
            read -rp "      Enter key (or press Enter for free WARP): " license_key
        fi
    fi

    if $DRY_RUN; then
        log INFO "[DRY-RUN] Would setup WARP"
        return
    fi

    # Check existing registration
    local existing_key=""
    if [ -f wgcf-account.toml ]; then
        existing_key=$(grep "^license_key" wgcf-account.toml 2>/dev/null | sed "s/.*= '\\(.*\\)'/\\1/" || echo "")
    fi

    # Logic: reuse existing device, only update license if changed
    if [ -n "$license_key" ]; then
        if [ -f wgcf-account.toml ] && [ "$existing_key" = "$license_key" ]; then
            # Same license key - reuse existing device
            log OK "WARP+ device already registered with this license"
        elif [ -f wgcf-account.toml ]; then
            # Device exists but license different - update license
            log INFO "Updating license key on existing device..."
            sed -i "s/license_key = .*/license_key = '$license_key'/" wgcf-account.toml

            if ./wgcf update 2>&1 | tee /tmp/wgcf_update.log | grep -q "error\|Error\|Bad Request"; then
                log WARN "Failed to apply WARP+ license"
                if grep -q "Too many" /tmp/wgcf_update.log; then
                    log WARN "License has too many devices. Remove old devices in 1.1.1.1 app."
                    log INFO "Keeping existing registration..."
                elif grep -q "Invalid" /tmp/wgcf_update.log; then
                    log WARN "Invalid license key. Keeping existing registration..."
                fi
            else
                log OK "WARP+ license applied!"
                # Regenerate profile with new license data
                rm -f wgcf-profile.conf
            fi
            rm -f /tmp/wgcf_update.log
        else
            # No device yet - register new with license
            log INFO "Registering new WARP device with license..."
            ./wgcf register --accept-tos
            sed -i "s/license_key = .*/license_key = '$license_key'/" wgcf-account.toml

            if ./wgcf update 2>&1 | tee /tmp/wgcf_update.log | grep -q "error\|Error\|Bad Request"; then
                log WARN "Failed to apply WARP+ license"
                if grep -q "Too many" /tmp/wgcf_update.log; then
                    log WARN "License has too many devices. Remove old devices in 1.1.1.1 app."
                fi
                log INFO "Continuing with free WARP..."
            else
                log OK "WARP+ license applied!"
            fi
            rm -f /tmp/wgcf_update.log
        fi
    elif [ ! -f wgcf-account.toml ]; then
        log INFO "Registering free WARP account..."
        ./wgcf register --accept-tos
    else
        log OK "Using existing WARP registration"
    fi

    # Generate profile
    if [ ! -f wgcf-profile.conf ]; then
        log INFO "Generating WARP profile..."
        ./wgcf generate
    fi

    log OK "WARP configured"
}

# ============================================================================
# Credentials generation (with idempotency)
# ============================================================================
generate_reality_keys() {
    # Check if we already have keys
    if [ -n "${REALITY_PRIVATE_KEY:-}" ] && [ -n "${REALITY_PUBLIC_KEY:-}" ]; then
        log OK "Using existing REALITY keys"
        return
    fi

    log INFO "Generating REALITY keys..."

    if $DRY_RUN; then
        log INFO "[DRY-RUN] Would generate REALITY keys"
        REALITY_PRIVATE_KEY="dry-run-private-key"
        REALITY_PUBLIC_KEY="dry-run-public-key"
        return
    fi

    local keys
    keys=$(docker run --rm "ghcr.io/sagernet/sing-box:${SING_BOX_VERSION}" generate reality-keypair)
    REALITY_PRIVATE_KEY=$(echo "$keys" | grep "PrivateKey" | awk '{print $2}')
    REALITY_PUBLIC_KEY=$(echo "$keys" | grep "PublicKey" | awk '{print $2}')

    log_secret "Private key" "$REALITY_PRIVATE_KEY"
    log_secret "Public key" "$REALITY_PUBLIC_KEY"
}

generate_certificate() {
    cd "$INSTALL_DIR"

    if [ -f cert.pem ] && [ -f private.key ]; then
        log OK "Using existing certificate"
        return
    fi

    if $DRY_RUN; then
        log INFO "[DRY-RUN] Would generate certificate"
        return
    fi

    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout private.key -out cert.pem \
        -subj "/CN=bing.com" -days "$CERT_VALIDITY_DAYS"
    chmod 600 private.key cert.pem

    log OK "Certificate generated (valid for $CERT_VALIDITY_DAYS days)"
}

generate_credentials() {
    # Check if we already have credentials (v2 format: per-config UUIDs)
    if [ -n "${VLESS_UUID_DEFAULT:-}" ] && [ -n "${VLESS_UUID_ADGUARD:-}" ] && \
       [ -n "${VLESS_UUID_PROXY:-}" ] && [ -n "${HYSTERIA_PASSWORD:-}" ] && \
       [ -n "${REALITY_SHORT_ID:-}" ] && [ -n "${AUTH_USER:-}" ]; then
        log OK "Using existing credentials"
        return
    fi

    log INFO "Generating credentials..."

    VLESS_UUID_DEFAULT=$(cat /proc/sys/kernel/random/uuid)
    VLESS_UUID_ADGUARD=$(cat /proc/sys/kernel/random/uuid)
    VLESS_UUID_PROXY=$(cat /proc/sys/kernel/random/uuid)
    HYSTERIA_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c "$HYSTERIA_PASSWORD_LENGTH")
    REALITY_SHORT_ID=$(openssl rand -hex 4)
    AUTH_USER="vpn"
    AUTH_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

    log_secret "UUID (default)" "$VLESS_UUID_DEFAULT"
    log_secret "UUID (adguard)" "$VLESS_UUID_ADGUARD"
    log_secret "UUID (proxy)" "$VLESS_UUID_PROXY"
    log_secret "Hysteria Password" "$HYSTERIA_PASSWORD"
    log_secret "REALITY Short ID" "$REALITY_SHORT_ID"
}

generate_caddy_port() {
    if [ -n "${CADDY_PORT:-}" ]; then
        log OK "Using existing Caddy port: $CADDY_PORT"
        return
    fi

    CADDY_PORT=$(shuf -i "${CADDY_PORT_MIN}-${CADDY_PORT_MAX}" -n 1)
    log INFO "Generated Caddy port: $CADDY_PORT"
}

load_or_generate_secrets() {
    if safe_load_credentials "$INSTALL_DIR/.credentials"; then
        log OK "Loaded existing config (port: ${CADDY_PORT:-?}, path: ${CONFIG_SECRET:0:8}...)"
    else
        CONFIG_SECRET=$(openssl rand -hex 16)
        log INFO "Generated new secret path: ${CONFIG_SECRET:0:8}..."
    fi
}

# ============================================================================
# Firewall configuration
# ============================================================================
detect_ssh_port() {
    local ssh_port=22
    if [ -f /etc/ssh/sshd_config ]; then
        local configured_port
        configured_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
        if [ -n "$configured_port" ]; then
            ssh_port="$configured_port"
        fi
    fi
    echo "$ssh_port"
}

configure_firewall() {
    local ssh_port
    ssh_port=$(detect_ssh_port)

    # Detect firewall tool
    local fw_tool=""
    if command -v ufw &>/dev/null; then
        fw_tool="ufw"
    elif command -v firewall-cmd &>/dev/null; then
        fw_tool="firewalld"
    else
        log INFO "No firewall detected (ufw/firewalld). Skipping firewall configuration."
        return
    fi

    # Build list of ports to open
    local ports_desc=""
    ports_desc+="      + 443/tcp    (VLESS+REALITY)\n"
    ports_desc+="      + 8443/udp  (Hysteria2)\n"
    ports_desc+="      + 80/tcp    (ACME certificates)\n"
    ports_desc+="      + ${CADDY_PORT}/tcp  (config page)\n"

    # Check SSH
    local ssh_status="already open"
    if [ "$fw_tool" = "ufw" ]; then
        if ! ufw status 2>/dev/null | grep -qE "${ssh_port}/(tcp|udp).*ALLOW"; then
            ssh_status="will be opened"
            ports_desc+="      + ${ssh_port}/tcp    (SSH)\n"
        else
            ports_desc+="      ✓ ${ssh_port}/tcp    (SSH, already open)\n"
        fi
    elif [ "$fw_tool" = "firewalld" ]; then
        if ! firewall-cmd --list-ports 2>/dev/null | grep -q "${ssh_port}/tcp"; then
            ssh_status="will be opened"
            ports_desc+="      + ${ssh_port}/tcp    (SSH)\n"
        else
            ports_desc+="      ✓ ${ssh_port}/tcp    (SSH, already open)\n"
        fi
    fi

    echo ""
    echo "      Firewall changes ($fw_tool):"
    echo -e "$ports_desc"

    # Ask for confirmation (unless non-interactive)
    if [ "$NON_INTERACTIVE" = "false" ]; then
        read -rp "      Apply these firewall rules? [Y/n]: " fw_confirm
        if [[ "$fw_confirm" =~ ^[Nn] ]]; then
            log INFO "Skipping firewall configuration"
            return
        fi
    fi

    if $DRY_RUN; then
        log INFO "[DRY-RUN] Would configure firewall"
        return
    fi

    # Apply rules
    if [ "$fw_tool" = "ufw" ]; then
        # Ensure SSH is open first (safety)
        ufw allow "${ssh_port}/tcp" 2>/dev/null || true
        ufw allow 443/tcp 2>/dev/null || true
        ufw allow 8443/udp 2>/dev/null || true
        ufw allow 80/tcp 2>/dev/null || true
        ufw allow "${CADDY_PORT}/tcp" 2>/dev/null || true
        # Enable UFW if not already active
        if ! ufw status | grep -q "Status: active"; then
            echo "y" | ufw enable 2>/dev/null || true
        fi
        log OK "UFW rules applied"
    elif [ "$fw_tool" = "firewalld" ]; then
        # Ensure SSH is open first (safety)
        firewall-cmd --permanent --add-port="${ssh_port}/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port=443/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=8443/udp 2>/dev/null || true
        firewall-cmd --permanent --add-port=80/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port="${CADDY_PORT}/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        log OK "firewalld rules applied"
    fi
}

remove_firewall_rules() {
    # Load credentials to get CADDY_PORT
    if [ -f "$INSTALL_DIR/.credentials" ]; then
        safe_load_credentials "$INSTALL_DIR/.credentials"
    fi

    local fw_tool=""
    if command -v ufw &>/dev/null; then
        fw_tool="ufw"
    elif command -v firewall-cmd &>/dev/null; then
        fw_tool="firewalld"
    else
        return
    fi

    log INFO "Removing firewall rules..."

    if [ "$fw_tool" = "ufw" ]; then
        ufw delete allow 443/tcp 2>/dev/null || true
        ufw delete allow 8443/udp 2>/dev/null || true
        ufw delete allow 80/tcp 2>/dev/null || true
        [ -n "${CADDY_PORT:-}" ] && ufw delete allow "${CADDY_PORT}/tcp" 2>/dev/null || true
        log OK "UFW rules removed (SSH rule preserved)"
    elif [ "$fw_tool" = "firewalld" ]; then
        firewall-cmd --permanent --remove-port=443/tcp 2>/dev/null || true
        firewall-cmd --permanent --remove-port=8443/udp 2>/dev/null || true
        firewall-cmd --permanent --remove-port=80/tcp 2>/dev/null || true
        [ -n "${CADDY_PORT:-}" ] && firewall-cmd --permanent --remove-port="${CADDY_PORT}/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        log OK "firewalld rules removed (SSH rule preserved)"
    fi
}

# ============================================================================
# Configuration generation
# ============================================================================
setup_caddy() {
    log INFO "Setting up Caddy web server..."

    if $DRY_RUN; then
        log INFO "[DRY-RUN] Would setup Caddy"
        return
    fi

    # Create configs directory
    mkdir -p "$CONFIGS_DIR/$CONFIG_SECRET"

    # Hash password for Caddy basic_auth (bcrypt)
    local auth_pass_hash
    auth_pass_hash=$(docker run --rm "caddy:${CADDY_VERSION}" caddy hash-password --plaintext "$AUTH_PASS")

    # Create Caddyfile
    cat > "$INSTALL_DIR/Caddyfile" << EOF
{
    http_port 80
    https_port $CADDY_PORT
    admin off
}

$DOMAIN {
    root * /srv/www
    file_server browse

    # Only allow access to secret path (32-char hex = 2^128 combinations)
    @notallowed not path /$CONFIG_SECRET/*
    respond @notallowed 404

    # Basic auth on the config page (index.html and directory listing)
    @page {
        path /$CONFIG_SECRET/ /$CONFIG_SECRET/index.html
    }
    basic_auth @page {
        $AUTH_USER $auth_pass_hash
    }

    header {
        -Server
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        Referrer-Policy no-referrer
    }

    log {
        output file /var/log/caddy/access.log {
            roll_size 10mb
            roll_keep 5
        }
    }
}
EOF

    mkdir -p /var/log/caddy
    chmod 750 "$CONFIGS_DIR"

    log OK "Caddy configured (page auth: $AUTH_USER / $AUTH_PASS)"
}

generate_client_configs() {
    log INFO "Generating client config files from templates..."

    if $DRY_RUN; then
        log INFO "[DRY-RUN] Would generate client configs"
        return
    fi

    local config_base_url="https://${DOMAIN}:${CADDY_PORT}/${CONFIG_SECRET}"
    local sed_common=(
        -e "s|\${SERVER_IP}|$SERVER_IP|g"
        -e "s|\${REALITY_PUBLIC_KEY}|$REALITY_PUBLIC_KEY|g"
        -e "s|\${REALITY_SHORT_ID}|$REALITY_SHORT_ID|g"
        -e "s|\${HYSTERIA_PASSWORD}|$HYSTERIA_PASSWORD|g"
        -e "s|\${COUNTRY_CODE}|$DEFAULT_COUNTRY|g"
    )

    # Map template name → per-config UUID and output filename (UUID-based)
    for template in "$INSTALL_DIR/clients/"*.template.json; do
        [ -f "$template" ] || continue

        local tpl_name uuid_for_config out_filename
        tpl_name=$(basename "$template" .template.json)

        case "$tpl_name" in
            default)     uuid_for_config="$VLESS_UUID_DEFAULT";  out_filename="${VLESS_UUID_DEFAULT}.json" ;;
            adguard_dns) uuid_for_config="$VLESS_UUID_ADGUARD";  out_filename="${VLESS_UUID_ADGUARD}.json" ;;
            proxy)       uuid_for_config="$VLESS_UUID_PROXY";    out_filename="${VLESS_UUID_PROXY}.json" ;;
            *)           uuid_for_config="$VLESS_UUID_DEFAULT";  out_filename="${tpl_name}.json" ;;
        esac

        sed "${sed_common[@]}" \
            -e "s|\${VLESS_UUID}|$uuid_for_config|g" \
            "$template" > "$CONFIGS_DIR/$CONFIG_SECRET/$out_filename"

        chmod 640 "$CONFIGS_DIR/$CONFIG_SECRET/$out_filename"
        log INFO "  Created: $out_filename ($tpl_name)"
    done

    # Process shell script templates (linux.sh) — uses proxy UUID
    if [ -f "$INSTALL_DIR/clients/linux.template.sh" ]; then
        sed -e "s|\${CONFIG_URL}|${config_base_url}/${VLESS_UUID_PROXY}.json|g" \
            "$INSTALL_DIR/clients/linux.template.sh" > "$CONFIGS_DIR/$CONFIG_SECRET/linux.sh"
        chmod 644 "$CONFIGS_DIR/$CONFIG_SECRET/linux.sh"
        log INFO "  Created: linux.sh"
    fi

    # Build config URLs (UUID-named files)
    local default_url adguard_url
    default_url=$(urlencode "${config_base_url}/${VLESS_UUID_DEFAULT}.json")
    adguard_url=$(urlencode "${config_base_url}/${VLESS_UUID_ADGUARD}.json")

    # Check WARP status via API
    local warp_status="WARP"
    local warp_plus_class=""
    if [ "$USE_WARP" = true ] && [ -f "$INSTALL_DIR/wgcf-account.toml" ]; then
        local token device account_type
        token=$(grep access_token "$INSTALL_DIR/wgcf-account.toml" | sed "s/.*= '\\(.*\\)'/\\1/")
        device=$(grep device_id "$INSTALL_DIR/wgcf-account.toml" | sed "s/.*= '\\(.*\\)'/\\1/")
        account_type=$(curl -sf "https://api.cloudflareclient.com/v0a2158/reg/$device" \
            -H "Authorization: Bearer $token" 2>/dev/null | jq -r '.account.account_type // "free"') || true

        if [ "$account_type" = "unlimited" ] || [ "$account_type" = "plus" ]; then
            warp_status="WARP+"
            warp_plus_class=" plus"
        fi
    elif [ "$USE_WARP" = false ]; then
        warp_status="OFF"
        warp_plus_class=" off"
    fi
    log INFO "  WARP status: $warp_status"

    # Create index.html from template
    local update_date linux_script_url
    update_date=$(date +"%d.%m.%Y %H:%M")
    linux_script_url="${config_base_url}/linux.sh"

    sed -e "s|\${DEFAULT_URL}|$default_url|g" \
        -e "s|\${ADGUARD_URL}|$adguard_url|g" \
        -e "s|\${WARP_STATUS}|$warp_status|g" \
        -e "s|\${WARP_PLUS_CLASS}|$warp_plus_class|g" \
        -e "s|\${UPDATE_DATE}|$update_date|g" \
        -e "s|\${LINUX_SCRIPT_URL}|$linux_script_url|g" \
        "$INSTALL_DIR/index.template.html" > "$CONFIGS_DIR/$CONFIG_SECRET/index.html"

    chmod 644 "$CONFIGS_DIR/$CONFIG_SECRET/index.html"
    log OK "Client configs created (bypass: ${DEFAULT_COUNTRY^^})"
}

create_config() {
    log INFO "Creating sing-box config..."
    cd "$INSTALL_DIR"

    if $DRY_RUN; then
        log INFO "[DRY-RUN] Would create sing-box config"
        return
    fi

    # Common sed args for all 3 UUIDs
    local sed_common=(
        -e "s|\${VLESS_UUID_DEFAULT}|$VLESS_UUID_DEFAULT|g"
        -e "s|\${VLESS_UUID_ADGUARD}|$VLESS_UUID_ADGUARD|g"
        -e "s|\${VLESS_UUID_PROXY}|$VLESS_UUID_PROXY|g"
        -e "s|\${REALITY_PRIVATE_KEY}|$REALITY_PRIVATE_KEY|g"
        -e "s|\${REALITY_SHORT_ID}|$REALITY_SHORT_ID|g"
        -e "s|\${HYSTERIA_PASSWORD}|$HYSTERIA_PASSWORD|g"
    )

    if [ "$USE_WARP" = true ]; then
        # Parse WARP profile
        local warp_private_key warp_peer_public_key warp_address warp_ipv4 warp_ipv6
        warp_private_key=$(grep "PrivateKey" wgcf-profile.conf | awk -F' = ' '{print $2}')
        warp_peer_public_key=$(grep "PublicKey" wgcf-profile.conf | awk -F' = ' '{print $2}')
        warp_address=$(grep "Address" wgcf-profile.conf | awk -F' = ' '{print $2}')
        warp_ipv4=$(echo "$warp_address" | cut -d',' -f1 | tr -d ' ')
        warp_ipv6=$(echo "$warp_address" | cut -d',' -f2 | tr -d ' ')

        sed "${sed_common[@]}" \
            -e "s|\${WARP_PRIVATE_KEY}|$warp_private_key|g" \
            -e "s|\${WARP_PEER_PUBLIC_KEY}|$warp_peer_public_key|g" \
            -e "s|\${WARP_IPV4}|$warp_ipv4|g" \
            -e "s|\${WARP_IPV6}|$warp_ipv6|g" \
            config.warp.template.json > config.json
    else
        sed "${sed_common[@]}" config.template.json > config.json
    fi

    chmod 600 config.json
    log OK "sing-box config created"
}

create_docker_compose() {
    log INFO "Creating docker-compose.yaml..."

    if $DRY_RUN; then
        log INFO "[DRY-RUN] Would create docker-compose.yaml"
        return
    fi

    local sing_box_env=""
    if [ "$USE_WARP" = true ]; then
        sing_box_env="    environment:
      - ENABLE_DEPRECATED_WIREGUARD_OUTBOUND=true"
    fi

    cat > "$INSTALL_DIR/docker-compose.yaml" << EOF
# Generated by deploy.sh v${SCRIPT_VERSION}
services:
  sing-box:
    image: ghcr.io/sagernet/sing-box:${SING_BOX_VERSION}
    container_name: sing-box
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
${sing_box_env}
    volumes:
      - ./config.json:/etc/sing-box/config.json:ro
      - ./cert.pem:/etc/sing-box/cert.pem:ro
      - ./private.key:/etc/sing-box/private.key:ro
    command: ["run", "-c", "/etc/sing-box/config.json"]
    healthcheck:
      test: ["CMD", "sing-box", "check", "-c", "/etc/sing-box/config.json"]
      interval: 30s
      timeout: 10s
      retries: 3

  caddy:
    image: caddy:${CADDY_VERSION}
    container_name: caddy
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./www:/srv/www:ro
      - caddy_data:/data
      - caddy_config:/config
      - /var/log/caddy:/var/log/caddy
    healthcheck:
      test: ["CMD", "caddy", "validate", "--config", "/etc/caddy/Caddyfile"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  caddy_data:
  caddy_config:
EOF

    log OK "docker-compose.yaml created"
}

# ============================================================================
# Save and display info
# ============================================================================
save_client_info() {
    local config_url="https://${AUTH_USER}:${AUTH_PASS}@${DOMAIN}:${CADDY_PORT}/${CONFIG_SECRET}/"
    local config_url_noauth="https://${DOMAIN}:${CADDY_PORT}/${CONFIG_SECRET}/"

    if $DRY_RUN; then
        log INFO "[DRY-RUN] Would save client info"
        echo ""
        echo "=== CLIENT CONFIGURATION (DRY-RUN) ==="
        echo "Config page: $config_url"
        return
    fi

    cat > "$INSTALL_DIR/CLIENT_INFO.txt" << EOF
=== Sing-box Server Client Configuration ===
Generated: $(date)
Server IP: $SERVER_IP

--- Config Page (password-protected) ---
URL: $config_url
User: $AUTH_USER
Password: $AUTH_PASS

--- VLESS + REALITY (Port 443) ---
Protocol: vless
Address: $SERVER_IP
Port: 443
TLS: reality
SNI: www.google.com
Public Key: $REALITY_PUBLIC_KEY
Short ID: $REALITY_SHORT_ID

Users:
  default:  $VLESS_UUID_DEFAULT
  adguard:  $VLESS_UUID_ADGUARD
  proxy:    $VLESS_UUID_PROXY

--- Hysteria2 (Port 8443) ---
Protocol: hysteria2
Password: $HYSTERIA_PASSWORD
Address: $SERVER_IP
Port: 8443
TLS: true (skip verify / allow insecure)
EOF

    # Save credentials with version
    cat > "$INSTALL_DIR/.credentials" << EOF
CREDENTIALS_VERSION=$CREDENTIALS_VERSION
CONFIG_URL=$config_url
CONFIG_SECRET=$CONFIG_SECRET
CADDY_PORT=$CADDY_PORT
VLESS_UUID_DEFAULT=$VLESS_UUID_DEFAULT
VLESS_UUID_ADGUARD=$VLESS_UUID_ADGUARD
VLESS_UUID_PROXY=$VLESS_UUID_PROXY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
HYSTERIA_PASSWORD=$HYSTERIA_PASSWORD
AUTH_USER=$AUTH_USER
AUTH_PASS=$AUTH_PASS
EOF
    chmod 600 "$INSTALL_DIR/.credentials"

    CONFIG_URL="$config_url"
}

show_completion_box() {
    local config_url="$1"

    echo ""
    echo "  ✓ DEPLOYMENT COMPLETE"
    echo "  ─────────────────────"
    echo ""
    echo "  Config page:"
    echo "  $config_url"
    echo ""
    echo "  Open this link on your phone to set up VPN."
    echo ""
    echo "  Manage:"
    echo "    cd $INSTALL_DIR && docker compose logs -f"
    echo "    sudo $(basename "$0") --uninstall"
    [ "$USE_WARP" = false ] && echo "    sudo $(basename "$0") --warp  (add WARP)"
    echo ""
}

# ============================================================================
# Server control
# ============================================================================
start_server() {
    log INFO "Starting services..."
    cd "$INSTALL_DIR"

    if $DRY_RUN; then
        log INFO "[DRY-RUN] Would start containers"
        return
    fi

    docker compose up -d --force-recreate --remove-orphans

    log INFO "Checking services health..."

    # Wait for containers to be running
    local timeout=$HEALTH_CHECK_TIMEOUT
    for ((i=0; i<timeout; i++)); do
        local running
        running=$(docker compose ps --format json 2>/dev/null | jq -s 'map(select(.State == "running")) | length' 2>/dev/null || echo "0")
        if [ "$running" = "2" ]; then
            break
        fi
        sleep "$HEALTH_CHECK_INTERVAL"
    done

    # Check ports
    if wait_for_port 443 tcp 10; then
        log OK "sing-box (443/tcp, 8443/udp)"
    else
        log WARN "VLESS (443/tcp) may not be ready"
    fi

    if wait_for_port "$CADDY_PORT" tcp 10; then
        log OK "Caddy (${CADDY_PORT}/tcp)"
    else
        log WARN "Caddy ($CADDY_PORT/tcp) may not be ready"
    fi
}

stop_server() {
    log INFO "Stopping services..."
    cd "$INSTALL_DIR"
    docker compose down
    log OK "Services stopped"
}

# ============================================================================
# Update
# ============================================================================
update_services() {
    echo "=== Updating Sing-box Server ==="

    if [ ! -d "$INSTALL_DIR" ]; then
        log ERROR "Installation not found: $INSTALL_DIR"
        exit 1
    fi

    cd "$INSTALL_DIR"

    if [ ! -f docker-compose.yaml ]; then
        log ERROR "docker-compose.yaml not found in $INSTALL_DIR"
        exit 1
    fi

    log INFO "Pulling latest Docker images..."
    docker compose pull

    log INFO "Restarting services..."
    docker compose up -d

    # Health check
    log INFO "Checking services health..."
    sleep 3

    local running
    running=$(docker compose ps --format json 2>/dev/null | jq -s 'map(select(.State == "running")) | length' 2>/dev/null || echo "0")

    if [ "$running" = "2" ]; then
        log OK "All services running"
    else
        log WARN "Some services may not be ready (running: $running/2)"
        docker compose ps
    fi

    log OK "Update complete"
}

# ============================================================================
# Uninstall
# ============================================================================
uninstall() {
    echo "=== Uninstalling Sing-box Server ==="

    if [ ! -d "$INSTALL_DIR" ]; then
        log WARN "Installation directory not found: $INSTALL_DIR"
        exit 0
    fi

    echo ""
    echo "This will remove:"
    echo "  • Docker containers (sing-box, caddy)"
    echo "  • Docker volumes (caddy_data, caddy_config)"
    echo "  • All files in $INSTALL_DIR"
    echo "  • Caddy logs in /var/log/caddy"
    echo "  • Firewall rules added by this script"
    echo ""

    if [ "$NON_INTERACTIVE" = "false" ]; then
        read -rp "Continue? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    # Remove firewall rules first (needs .credentials for CADDY_PORT)
    remove_firewall_rules

    cd "$INSTALL_DIR"

    # Stop and remove containers
    if [ -f docker-compose.yaml ]; then
        docker compose down -v 2>/dev/null || true
    fi

    # Remove Docker images
    docker rmi "ghcr.io/sagernet/sing-box:${SING_BOX_VERSION}" 2>/dev/null || true
    docker rmi "caddy:${CADDY_VERSION}" 2>/dev/null || true

    # Remove caddy logs
    rm -rf /var/log/caddy

    # Remove installation directory (do last — LOG_FILE is inside)
    rm -rf "$INSTALL_DIR"

    echo "      ✓ Uninstallation complete"
}

# ============================================================================
# Main
# ============================================================================
show_help() {
    cat << EOF
Sing-box Server Deployment Script v${SCRIPT_VERSION}

Usage: $(basename "$0") [OPTIONS]

Options:
  --warp            Enable Cloudflare WARP outbound (default: off)
  --country XX      Set bypass country code (default: ru)
  --non-interactive Skip all interactive prompts
  --dry-run         Show what would be done without making changes
  --update          Pull latest Docker images and restart services
  --uninstall       Remove installation
  --help            Show this help

Environment variables:
  INSTALL_DIR       Installation directory (default: /opt/sing-box)
  SING_BOX_VERSION  Sing-box version (default: v1.11.4)
  CADDY_VERSION     Caddy version (default: 2.9)
  WARP_LICENSE_KEY  WARP+ license key (implies --warp)
  NON_INTERACTIVE   Set to "true" to skip all prompts

Examples:
  sudo ./deploy.sh                              # Install (no WARP)
  sudo ./deploy.sh --warp                       # Install with WARP
  sudo ./deploy.sh --country ir                 # Install with Iran bypass
  sudo WARP_LICENSE_KEY=xxx ./deploy.sh         # Install with WARP+
  sudo ./deploy.sh --dry-run                    # Preview changes
  sudo ./deploy.sh --update                     # Update images
  sudo ./deploy.sh --uninstall                  # Remove
EOF
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --warp)
                USE_WARP=true
                shift
                ;;
            --country)
                DEFAULT_COUNTRY=$(echo "$2" | tr '[:upper:]' '[:lower:]')
                shift 2
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --update)
                update_services
                exit 0
                ;;
            --uninstall)
                uninstall
                exit 0
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log ERROR "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [ "$EUID" -ne 0 ]; then
        log ERROR "Please run as root"
        exit 1
    fi

    # Calculate step count
    if [ "$USE_WARP" = true ]; then
        STEP_TOTAL=8
    else
        STEP_TOTAL=7
    fi

    echo ""
    echo "  Sing-box Server v${SCRIPT_VERSION}"
    echo "  Install directory: $INSTALL_DIR"
    $DRY_RUN && echo "  Mode: DRY-RUN (no changes will be made)"
    [ "$USE_WARP" = true ] && echo "  WARP: enabled" || echo "  WARP: disabled (use --warp to enable)"
    echo "  Bypass country: ${DEFAULT_COUNTRY}"
    echo ""

    # Get script directory BEFORE changing dirs
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"

    # Setup directories and logging
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/clients"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    log INFO "Deployment started"

    # Copy templates from source directory
    for f in config.template.json config.warp.template.json index.template.html; do
        if [ -f "$script_dir/$f" ] && [ "$script_dir" != "$INSTALL_DIR" ]; then
            cp "$script_dir/$f" "$INSTALL_DIR/"
        fi
    done
    if [ -d "$script_dir/clients" ] && [ "$script_dir" != "$INSTALL_DIR" ]; then
        cp "$script_dir/clients/"*.template.json "$INSTALL_DIR/clients/" 2>/dev/null || true
        cp "$script_dir/clients/"*.template.sh "$INSTALL_DIR/clients/" 2>/dev/null || true
    fi

    cd "$INSTALL_DIR"

    # Step 1: Detect environment
    step "Detecting environment"
    detect_os
    detect_arch
    SERVER_IP=$(get_server_ip)
    DOMAIN="${SERVER_IP//./-}.sslip.io"
    log OK "OS: $(. /etc/os-release && echo "$PRETTY_NAME") | Arch: $WGCF_ARCH | IP: $SERVER_IP | Bypass: ${DEFAULT_COUNTRY^^}"

    # Step 2: Install Docker
    step "Installing Docker"
    install_docker

    # Step 3: Install tools
    step "Installing tools"
    install_tools

    # Step 4 (optional): Setup WARP
    if [ "$USE_WARP" = true ]; then
        step "Setting up Cloudflare WARP"
        setup_warp
    fi

    # Step N: Generate credentials
    step "Generating credentials"
    load_or_generate_secrets
    generate_caddy_port
    generate_reality_keys
    generate_certificate
    generate_credentials

    # Step N+1: Create configuration
    step "Creating configuration"
    create_config
    setup_caddy
    generate_client_configs
    create_docker_compose

    # Step N+2: Start services
    step "Starting services"
    start_server
    save_client_info

    # Step N+3: Configure firewall
    step "Configuring firewall"
    configure_firewall

    log INFO "Deployment completed successfully"

    # Show final output
    show_completion_box "$CONFIG_URL"
}

main "$@"
