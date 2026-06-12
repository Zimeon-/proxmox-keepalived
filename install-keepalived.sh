#!/bin/bash

# Proxmox Keepalived + Nginx Deployment Script
# Based on: https://zenn.dev/tjst_t/articles/260214-proxmox-keepalived-nginx?locale=en
# Enhanced with robust auto-detection for Proxmox environments

set -eu
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# --- Default Configuration ---
VIP=""                     # Virtual IP (required)
INTERFACE=""               # Network interface (auto-detected if empty)
ROUTER_ID="51"             # Keepalived router ID
PRIORITY=""                # Keepalived priority value
NODE_ID=""                 #
LOCAL_IP=""                # Local Node IP
PEER_IPS=()                # Peer IPs
AUTH_PASS=""               # Authentication password (required for clusters)
NGINX_CONFIG_DIR="/etc/nginx/conf.d"  # Nginx configuration directory
AUTO_DETECT=false          # Enable auto-detection
VERBOSE=false              # Enable verbose output
FORCE=false                # Force overwrite existing configs
CLEANUP=false              # Cleanup existing installation

# --- Color Codes for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Logging Functions ---
log_info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
}

# --- Help Function ---
show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --vip <ip>           Virtual IP address (e.g., 192.168.1.100)"
    echo "  --interface <iface>  Network interface (e.g., vmbr0)"
    echo "  --router-id <id>     Keepalived router ID (default: $ROUTER_ID)"
    echo "  --auth-pass <pass>   Authentication password for Keepalived (required for clusters)"
    echo "  --auto-detect        Enable auto-detection of interface, IPs, and peers"
    echo "  --verbose            Enable verbose output"
    echo "  --force              Force overwrite existing configs"
    echo "  --cleanup           Remove existing Keepalived + Nginx installation"
    echo "  --help, -h           Show this help message"
    echo ""
    echo "Examples:"
    echo "  # First node
    echo "  $0 --vip 192.168.1.100 --auto-detect --auth-pass mypassword
    echo ""
    echo "  # Subsequent nodes
    echo "  $0 --vip 192.168.1.100 --auto-detect --auth-pass mypassword"
    echo ""
    echo "  # Cleanup existing installation"
    echo "  $0 --cleanup"
    exit 0
}


#Script Dependencies
check_dependencies() {

    if command -v arping >/dev/null 2>&1; then
        return 0
    fi

    log_warn "Required dependency not found: arping"
    echo
    read -rp "Install iputils-arping now? (Y/n) " REPLY

    case "${REPLY:-Y}" in
        y|Y|"")
            log_info "Installing iputils-arping..."
            apt-get update
            apt-get install -y iputils-arping

            if ! command -v arping >/dev/null 2>&1; then
                log_error "Failed to install arping."
                exit 1
            fi

            log_info "arping installed successfully."
            ;;
        *)
            log_error "arping is required for VIP validation."
            log_error "Install manually: apt install -y iputils-arping"
            exit 1
            ;;
    esac
}
check_dependencies
# --- Cleanup Function ---
cleanup_installation() {
    log_info "Checking for existing Keepalived + Nginx installation..."
    
    # Check for installed packages
    PACKAGES_INSTALLED=false
    if dpkg -s keepalived > /dev/null 2>&1; then
        PACKAGES_INSTALLED=true
        log_info "Found installed package: keepalived"
    fi
    if dpkg -s nginx > /dev/null 2>&1; then
        PACKAGES_INSTALLED=true
        log_info "Found installed package: nginx"
    fi
    
    # Check for configuration files
    CONFIGS_FOUND=false
    if [ -f /etc/keepalived/keepalived.conf ]; then
        CONFIGS_FOUND=true
        log_info "Found configuration: /etc/keepalived/keepalived.conf"
    fi
    if [ -f "$NGINX_CONFIG_DIR/proxmox_forward.conf" ]; then
        CONFIGS_FOUND=true
        log_info "Found configuration: $NGINX_CONFIG_DIR/proxmox_forward.conf"
    fi
    if [ -f /etc/nginx/sites-enabled/default ]; then
        CONFIGS_FOUND=true
        log_info "Found configuration: /etc/nginx/sites-enabled/default"
    fi
    
    # Check for services
    SERVICES_RUNNING=false
    if systemctl is-active --quiet keepalived > /dev/null 2>&1; then
        SERVICES_RUNNING=true
        log_info "Found running service: keepalived"
    fi
    if systemctl is-active --quiet nginx > /dev/null 2>&1; then
        SERVICES_RUNNING=true
        log_info "Found running service: nginx"
    fi
    
    # If nothing found, exit
    if [ "$PACKAGES_INSTALLED" = false ] && [ "$CONFIGS_FOUND" = false ] && [ "$SERVICES_RUNNING" = false ]; then
        log_error "No existing Keepalived + Nginx installation found."
        log_error "This script has not been run, or configuration could not be found."
        exit 1
    fi
    
    # Show what will be removed
    log_warn ""
    log_warn "The following will be removed:"
    if [ "$PACKAGES_INSTALLED" = true ]; then
        log_warn "  - Packages: keepalived, nginx"
    fi
    if [ "$CONFIGS_FOUND" = true ]; then
        log_warn "  - Configuration files"
    fi
    if [ "$SERVICES_RUNNING" = true ]; then
        log_warn "  - Services: keepalived, nginx"
    fi
    log_warn "  - Firewall rules for VIP/VRRP"
    log_warn ""
    
    # Prompt for confirmation
    read -rp "Are you sure you want to remove the existing installation? (y/N) " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        log_info "Cleanup cancelled."
        exit 0
    fi
    
    log_info "Starting cleanup..."
    
    # Stop and disable services
    if [ "$SERVICES_RUNNING" = true ]; then
        if systemctl is-active --quiet keepalived > /dev/null 2>&1; then
            systemctl stop keepalived
            systemctl disable keepalived
            log_info "Stopped and disabled keepalived service."
        fi
        if systemctl is-active --quiet nginx > /dev/null 2>&1; then
            systemctl stop nginx
            systemctl disable nginx
            log_info "Stopped and disabled nginx service."
        fi
    fi
    
    # Remove packages
    if [ "$PACKAGES_INSTALLED" = true ]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y keepalived nginx
        log_info "Removed packages: keepalived, nginx"
    fi
    
    # Remove configuration files
    if [ "$CONFIGS_FOUND" = true ]; then
        if [ -f /etc/keepalived/keepalived.conf ]; then
            rm -f /etc/keepalived/keepalived.conf
            rm -f /etc/keepalived/keepalived.conf.bak
            log_info "Removed Keepalived configuration."
        fi
        if [ -f "$NGINX_CONFIG_DIR/proxmox_forward.conf" ]; then
            rm -f "$NGINX_CONFIG_DIR/proxmox_forward.conf"
            rm -f "$NGINX_CONFIG_DIR/proxmox_forward.conf.bak"
            log_info "Removed Nginx configuration."
        fi
        if [ -f /etc/nginx/sites-enabled/default ]; then
            rm -f /etc/nginx/sites-enabled/default
            log_info "Removed default Nginx site."
        fi
    fi
    
    # Remove SSL symlinks
    if [ -L "/etc/ssl/certs/proxmox.pem" ]; then
        rm -f /etc/ssl/certs/proxmox.pem
        log_info "Removed SSL certificate symlink."
    fi
    if [ -L "/etc/ssl/private/proxmox.key" ]; then
        rm -f /etc/ssl/private/proxmox.key
        log_info "Removed SSL key symlink."
    fi
    
    # Remove firewall rules
    if [ -f /etc/pve/corosync.conf ]; then
        get_cluster_peers
    fi
    for peer in "${PEER_IPS[@]}"; do
        iptables -D INPUT \
            -p vrrp \
            -s "$peer" \
            -j ACCEPT 2>/dev/null || true
    done
    if command -v netfilter-persistent > /dev/null 2>&1; then
        netfilter-persistent save > /dev/null 2>&1
        log_info "Saved updated firewall rules."
    fi
    
    log_info ""
    log_info "Cleanup complete!"
    exit 0
}

# --- Auto-Detection Functions ---

# Detect the primary Proxmox bridge interface
detect_interface() {
    if [ -n "$INTERFACE" ]; then
        log_info "Using provided interface: $INTERFACE"
        return
    fi

    log_info "Auto-detecting Proxmox bridge interface..."

    if [ -n "${LOCAL_IP:-}" ]; then

        INTERFACE=$(ip -o -4 addr show \
            | awk -v ip="$LOCAL_IP" '
            {
                split($4,a,"/");
                if (a[1] == ip) {
                    print $2
                    exit
                }
            }')
        
        if [[ "$INTERFACE" =~ ^vmbr ]]; then
            log_info "Detected interface from cluster IP: $INTERFACE"
            return
        fi

        if [ -n "$INTERFACE" ]; then
            log_info "Detected interface from Corosync IP: $INTERFACE"
            return
        fi
    fi

    INTERFACE=$(ip -o link show |
        awk -F': ' '{print $2}' |
        grep '^vmbr' |
        head -n1)

    if [ -n "$INTERFACE" ]; then
        log_info "Fallback detected interface: $INTERFACE"
        return
    fi

    INTERFACE="vmbr0"
    log_warn "No bridge interface detected. Using default: $INTERFACE"
}

# Detect existing IP addresses on the interface
detect_existing_ips() {
    if [ -z "$INTERFACE" ]; then
        log_error "No interface specified or detected. Cannot detect IPs."
        return 1
    fi
    
    log_info "Detecting IP addresses on $INTERFACE..."
    IPS=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | tr '\n' ' ' || true)
    
    if [ -n "$IPS" ]; then
        log_info "Found IPs on $INTERFACE: $IPS"
    else
        log_warn "No IP addresses found on $INTERFACE"
    fi
}

#Light cluster peer detection
get_cluster_peers() {

    local corosync="/etc/pve/corosync.conf"

    [ -f "$corosync" ] || return 0

    mapfile -t PEER_IPS < <(
        awk '
        $1=="node" { in_node=1; name="" }
        in_node && $1=="name:" { name=$2 }
        in_node && $1=="ring0_addr:" {
            if(name!="'"$(hostname -s)"'")
                print $2
        }
        ' "$corosync"
    )
}

# Detect peer nodes in a Proxmox cluster using corosync configuration
detect_cluster_info() {

    local corosync="/etc/pve/corosync.conf"

    if [ ! -f "$corosync" ]; then
        log_error "Proxmox cluster configuration not found."
        log_error "Keepalived HA requires a Proxmox cluster."
        exit 1
    fi

    NODE_COUNT=$(awk '
        $1=="node" { count++ }
        END { print count+0 }
    ' "$corosync")

    if [ "$NODE_COUNT" -lt 2 ]; then
        log_error "Only $NODE_COUNT cluster node detected."
        log_error "Keepalived HA requires at least two Proxmox nodes."
        exit 1
    fi

    LOCAL_NODE=$(hostname -s)

    NODE_ID=$(awk '
        $1=="node" { in_node=1; name=""; nodeid="" }
        in_node && $1=="name:" { name=$2 }
        in_node && $1=="nodeid:" {
            nodeid=$2
            if(name=="'"$LOCAL_NODE"'")
                print nodeid
        }
    ' "$corosync")

    if [ -z "$NODE_ID" ]; then
        log_error "Unable to determine local cluster node ID"
        return 1
    fi

    PRIORITY=$((254 - NODE_ID))

    if [ "$PRIORITY" -lt 50 ]; then
        PRIORITY=50
    fi

    mapfile -t PEER_IPS < <(
        awk '
        $1=="node" { in_node=1; name="" }
        in_node && $1=="name:" { name=$2 }
        in_node && $1=="ring0_addr:" {
            if(name!="'"$LOCAL_NODE"'")
                print $2
        }
        ' "$corosync" | while read -r addr; do
            if echo "$addr" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                echo "$addr"
            else
                getent ahostsv4 "$addr" \
                | awk '!seen[$1]++ {print $1; exit}'
            fi
        done
    )
    if [ "${#PEER_IPS[@]}" -eq 0 ]; then
        log_error "No cluster peers detected"
        exit 1
    fi
    
    log_info "Detected node ID: $NODE_ID"
    log_info "Assigned Keepalived priority: $PRIORITY"

    for peer in "${PEER_IPS[@]}"; do
        log_info "Detected peer: $peer"
    done
}

# Detect local proxmox management ipv4 address
detect_local_ip() {

    local ring0

    ring0=$(awk '
        $1=="node" { in_node=1; name="" }
        in_node && $1=="name:" { name=$2 }
        in_node && $1=="ring0_addr:" {
            if(name=="'"$(hostname -s)"'")
                print $2
        }
    ' /etc/pve/corosync.conf)

    if echo "$ring0" | grep -Eq '^[0-9]+\.'; then
        LOCAL_IP="$ring0"
    else
        LOCAL_IP=$(getent ahostsv4 "$ring0" | awk '{print $1; exit}')
    fi

    if [ -z "$LOCAL_IP" ]; then
        log_error "Unable to determine cluster IP"
        exit 1
    fi

    log_info "Cluster IP: $LOCAL_IP"
}

detect_keepalived_ip() {

    LOCAL_IP=$(ip -o -4 addr show dev "$INTERFACE" scope global \
        | awk '{print $4}' \
        | cut -d/ -f1 \
        | grep -Fxv "$VIP" \
        | head -n1)

    if [ -z "$LOCAL_IP" ]; then
        log_error "Unable to determine IP on $INTERFACE"
        exit 1
    fi

    log_info "Keepalived source IP: $LOCAL_IP"
}

# Detect available IP range for VIP
detect_ip_range() {
    if [ -n "$VIP" ]; then
        log_info "Using provided VIP: $VIP"
        return
    fi
    
    log_info "Auto-detecting available IP range for VIP..."
    
    # Get the first non-loopback IP and its subnet
    INTERFACE_IP=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1 || true)
    if [ -z "$INTERFACE_IP" ]; then
        log_error "No local IP detected on $INTERFACE"
        return
    fi
    
    # Extract the first three octets (e.g., 192.168.1)
    SUBNET=$(echo "$INTERFACE_IP" | awk -F. '{print $1 "." $2 "." $3}')
    
    # Suggest a VIP in the same subnet (e.g., .100)
    VIP="${SUBNET}.100"
    log_info "Suggested VIP: $VIP (based on $INTERFACE_IP)"
    log_warn "Please verify this VIP is available and not in use."
}

# Detect and symlink Proxmox SSL certificates
detect_and_link_ssl() {
    log_info "Detecting Proxmox SSL certificates..."
    
    PROXMOX_CERT_DIR="/etc/pve/local"
    NGINX_SSL_CERT="/etc/ssl/certs/proxmox.pem"
    NGINX_SSL_KEY="/etc/ssl/private/proxmox.key"
    
    # Create directories if they don't exist
    mkdir -p /etc/ssl/certs /etc/ssl/private
    
    # Priority 1: Use uploaded custom certificates (pveproxy-ssl.pem/key)
    if [ -f "$PROXMOX_CERT_DIR/pveproxy-ssl.pem" ] && [ -f "$PROXMOX_CERT_DIR/pveproxy-ssl.key" ]; then
        log_info "Found uploaded custom SSL certificates in $PROXMOX_CERT_DIR"
        ln -sf "$PROXMOX_CERT_DIR/pveproxy-ssl.pem" "$NGINX_SSL_CERT"
        ln -sf "$PROXMOX_CERT_DIR/pveproxy-ssl.key" "$NGINX_SSL_KEY"
        log_info "Symlinked custom SSL certificates:"
        log_info "  $NGINX_SSL_CERT -> $PROXMOX_CERT_DIR/pveproxy-ssl.pem"
        log_info "  $NGINX_SSL_KEY -> $PROXMOX_CERT_DIR/pveproxy-ssl.key"
        return
    fi
    
    # Priority 2: Fall back to installation defaults (pve-ssl.pem/key)
    if [ -f "$PROXMOX_CERT_DIR/pve-ssl.pem" ] && [ -f "$PROXMOX_CERT_DIR/pve-ssl.key" ]; then
        log_info "Found default SSL certificates in $PROXMOX_CERT_DIR"
        ln -sf "$PROXMOX_CERT_DIR/pve-ssl.pem" "$NGINX_SSL_CERT"
        ln -sf "$PROXMOX_CERT_DIR/pve-ssl.key" "$NGINX_SSL_KEY"
        log_info "Symlinked default SSL certificates:"
        log_info "  $NGINX_SSL_CERT -> $PROXMOX_CERT_DIR/pve-ssl.pem"
        log_info "  $NGINX_SSL_KEY -> $PROXMOX_CERT_DIR/pve-ssl.key"
        return
    fi
    
    # If neither custom nor default certs are found, warn the user
    log_warn "No Proxmox SSL certificates found in $PROXMOX_CERT_DIR."
    log_warn "You must provide SSL certificates at:"
    log_warn "  $NGINX_SSL_CERT"
    log_warn "  $NGINX_SSL_KEY"
    log_warn "Or upload custom certificates to Proxmox via the web interface (Datacenter > [Your DC] > SSL)."
}

# Validate VIP is in the same subnet as the interface and not in use
validate_vip_preinstall() {

    if [ -z "$VIP" ]; then
        log_error "No VIP specified or detected."
        return 1
    fi

    log_info "Validating VIP: $VIP"

    if ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$VIP"; then
        log_error "VIP $VIP already exists on this host."
        return 1
    fi
    
    if arping -D -c 3 -I "$INTERFACE" "$VIP"; then

        log_info "VIP appears unused on network."

    else

        log_warn "VIP is already responding on the network."

        read -rp \
            "Is this node joining an existing Keepalived cluster? (y/N) " \
            JOIN_CLUSTER

        if [[ "$JOIN_CLUSTER" =~ ^[Yy]$ ]]; then
            log_info "Continuing installation as additional cluster node."
        else
            log_error "VIP appears to already exist on network."
            return 1
        fi
    fi

    return 0
}
generate_unicast_peers() {

    local peers=""

    for peer in "${PEER_IPS[@]}"; do
        peers="${peers}
        ${peer}"
    done

    printf "%s" "$peers"
}

# --- Installation Functions ---

# Install required packages
install_packages() {
    log_info "Installing required packages..."
    DEBIAN_FRONTEND=noninteractive apt-get update > /dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y keepalived nginx > /dev/null 2>&1
}

# --- Configuration Functions ---

# Configure Keepalived
configure_keepalived() {
    log_info "Configuring Keepalived..."
    
    # Backup existing config if it exists and --force is not set
    if [ -f /etc/keepalived/keepalived.conf ] && [ "$FORCE" = false ]; then
        log_info "Keepalived config already exists. Use --force to overwrite."
        return
    fi
    
    if [ -f /etc/keepalived/keepalived.conf ]; then
        cp /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.bak
        log_info "Backed up existing Keepalived config to /etc/keepalived/keepalived.conf.bak"
    fi
    
    # Get correct CIDR for VIP
    VIP_CIDR=$(ip -4 addr show "$INTERFACE" \
    | awk '/inet / {print $2}' \
    | head -n1 \
    | cut -d/ -f2)
    
    if [ -z "$LOCAL_IP" ]; then
        detect_keepalived_ip
    fi
    
    # Write new config
    UNICAST_PEERS=$(generate_unicast_peers)

    cat > /etc/keepalived/keepalived.conf <<EOF
! Configuration File for keepalived

global_defs {
    router_id PVE${NODE_ID}
    enable_script_security
    vrrp_garp_master_delay 1
    vrrp_garp_master_repeat 5
}

vrrp_script check_nginx {
    script "/usr/bin/systemctl is-active --quiet nginx"
    user root
    interval 2
    weight -20
    fall 2
    rise 2
}

vrrp_instance VI_1 {

    state BACKUP

    interface $INTERFACE

    virtual_router_id $ROUTER_ID

    priority $PRIORITY
    
    nopreempt

    advert_int 1

    unicast_src_ip $LOCAL_IP

    unicast_peer {
$UNICAST_PEERS
    }

    authentication {
        auth_type PASS
        auth_pass $AUTH_PASS
    }
    
    virtual_ipaddress {
        $VIP/$VIP_CIDR
    }

    track_script {
        check_nginx
    }
}
EOF
    
    log_info "Keepalived configuration written to /etc/keepalived/keepalived.conf"
    
    if ! keepalived -t -f /etc/keepalived/keepalived.conf; then
        log_error "Keepalived configuration validation failed."
        return 1
    fi
    
    # Enable and start Keepalived
    systemctl enable keepalived --now > /dev/null 2>&1
    log_info "Keepalived enabled and started."
}

# Configure Nginx for port forwarding: 80 -> 443, 443 -> 8006
configure_nginx() {
    log_info "Configuring Nginx..."
    
    # Create directory if it doesn't exist
    mkdir -p "$NGINX_CONFIG_DIR"
    
    # Backup and remove default Nginx config to prevent "Welcome to nginx!" page
    if [ -f /etc/nginx/sites-enabled/default ]; then
        rm -f /etc/nginx/sites-enabled/default
        log_info "Removed default Nginx site configuration."
    fi
    
    # Backup existing config if it exists and --force is not set
    if [ -f "$NGINX_CONFIG_DIR/proxmox_forward.conf" ] && [ "$FORCE" = false ]; then
        log_info "Nginx config already exists. Use --force to overwrite."
        return
    fi
    
    if [ -f "$NGINX_CONFIG_DIR/proxmox_forward.conf" ]; then
        cp "$NGINX_CONFIG_DIR/proxmox_forward.conf" "$NGINX_CONFIG_DIR/proxmox_forward.conf.bak"
        log_info "Backed up existing Nginx config to $NGINX_CONFIG_DIR/proxmox_forward.conf.bak"
    fi
    
    # Write new config for port forwarding
    cat > "$NGINX_CONFIG_DIR/proxmox_forward.conf" <<EOF
# Forward HTTP (80) to HTTPS (443)
server {
    listen 80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}

# Forward HTTPS (443) to Proxmox management port (8006)
server {
    listen 443 ssl default_server;
    server_name _;
    
    ssl_certificate /etc/ssl/certs/proxmox.pem;
    ssl_certificate_key /etc/ssl/private/proxmox.key;

    location / {

        proxy_pass https://127.0.0.1:8006;
        proxy_ssl_verify off;

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_buffering off;
        proxy_request_buffering off;

        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }
}
EOF
    
    log_info "Nginx configuration written to $NGINX_CONFIG_DIR/proxmox_forward.conf"
    
    # Test Nginx configuration
    if nginx -t > /dev/null 2>&1; then
        log_info "Nginx configuration test passed."
    else
        log_error "Nginx configuration test failed. Check for syntax errors."
        return 1
    fi
    
    # Enable and start Nginx
    systemctl enable nginx --now > /dev/null 2>&1
    log_info "Nginx enabled and started."
}

# Configure firewall for VIP and VRRP traffic
configure_firewall() {

    log_info "Configuring VRRP firewall rules..."

    for peer in "${PEER_IPS[@]}"; do

        iptables -C INPUT \
            -p vrrp \
            -s "$peer" \
            -j ACCEPT 2>/dev/null || \
        iptables -A INPUT \
            -p vrrp \
            -s "$peer" \
            -j ACCEPT

    done

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
    fi
}

# --- Validation Functions ---

# Validate the entire setup
validate_setup() {
    log_info "Validating setup..."
       
    # Check Keepalived
    if systemctl is-active --quiet keepalived > /dev/null 2>&1; then
        log_info "Keepalived is running."
    else
        log_error "Keepalived is not running."
        return 1
    fi
    
    # Check Nginx
    if systemctl is-active --quiet nginx > /dev/null 2>&1; then
        log_info "Nginx is running."
    else
        log_error "Nginx is not running."
        return 1
    fi
    
    # Check if VIP is assigned
    if ip -4 addr show "$INTERFACE" | grep -qw "$VIP" || true; then
        log_info "VIP $VIP is assigned to an interface."
    else
        log_warn "VIP $VIP is not yet assigned. Check Keepalived logs: journalctl -u keepalived -f"
    fi
    
    # Check SSL symlinks
    if [ -L "/etc/ssl/certs/proxmox.pem" ] && [ -L "/etc/ssl/private/proxmox.key" ]; then
        log_info "SSL certificates are symlinked to Proxmox certs."
    else
        log_warn "SSL certificates are not symlinked. Check Proxmox certs at /etc/pve/local/."
    fi
    
    return 0
}

# --- Main Script ---

# If no arguments are passed, show help
if [ $# -eq 0 ]; then
    show_help
fi

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --vip)
            VIP="$2"
            shift 2
            ;;
        --interface)
            INTERFACE="$2"
            shift 2
            ;;
        --router-id)
            ROUTER_ID="$2"
            shift 2
            ;;
        --auth-pass)
            AUTH_PASS="$2"
            shift 2
            ;;
        --auto-detect)
            AUTO_DETECT=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --cleanup)
            CLEANUP=true
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            ;;
    esac
done

# If cleanup mode is requested, run cleanup and exit
if [ "$CLEANUP" = true ]; then
    cleanup_installation
fi

# AUTH PASS is required, always and a maximum of 8 characters
if [ -z "$AUTH_PASS" ]; then
    log_error "--auth-pass is required"
    exit 1
fi
if [ ${#AUTH_PASS} -gt 8 ]; then
    AUTH_PASS=${AUTH_PASS:0:8}
    log_warn "Keepalived PASS authentication is limited to 8 characters; using: $AUTH_PASS"
fi

# Enable verbose output if requested
if [ "$VERBOSE" = true ]; then
    set -x
fi

# --- Execution ---

log_info "Starting Proxmox Keepalived + Nginx deployment..."
detect_cluster_info

# Auto-detection
if [ "$AUTO_DETECT" = true ]; then  
    detect_local_ip      # Corosync discovery only
    detect_interface
    detect_keepalived_ip
    detect_existing_ips
    detect_ip_range
fi

# Validate required parameters
if [ -z "$VIP" ]; then
    log_error "VIP is required. Use --vip or --auto-detect."
    show_help
fi

if [ -z "$INTERFACE" ]; then
    log_error "Network interface is required. Use --interface or --auto-detect."
    show_help
fi

# Validate VIP
# This also handles auth-pass requirement for secondary nodes
validate_vip_preinstall || exit 1

# Install packages
install_packages

# Detect and symlink Proxmox SSL certificates
detect_and_link_ssl

# Configure services
configure_nginx
configure_keepalived
configure_firewall

# Validate setup
if validate_setup; then
    log_info ""
    log_info "=== Deployment Summary ==="
    log_info "Virtual IP:       $VIP"
    log_info "Interface:        $INTERFACE"
    log_info "Router ID:        $ROUTER_ID"
    log_info "Node ID:        $NODE_ID"
    log_info "Priority:       $PRIORITY"
    log_info "Local IP:       $LOCAL_IP"
    log_info "Cluster Peers:  ${#PEER_IPS[@]}"
    log_info "Auth Password:    ${AUTH_PASS:-Randomly generated}"
    log_info "Nginx Config:     $NGINX_CONFIG_DIR/proxmox_forward.conf"
    log_info "SSL Cert:         /etc/ssl/certs/proxmox.pem (symlinked to Proxmox certs)"
    log_info "SSL Key:          /etc/ssl/private/proxmox.key (symlinked to Proxmox key)"
    log_info ""   
   
    log_info "Next steps:"
    log_info "1. Verify SSL symlinks: ls -l /etc/ssl/certs/proxmox.pem /etc/ssl/private/proxmox.key"
    log_info "2. If symlinks are broken, upload custom certificates to Proxmox via the web interface."
    log_info "3. Restart Nginx: systemctl restart nginx"
    log_info "4. Monitor Keepalived: journalctl -u keepalived -f"
    log_info ""
    log_info "Deployment complete!"
else
    log_error "Deployment validation failed. Check the logs above."
    exit 1
fi
