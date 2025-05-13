#!/bin/bash

# Default values (will try to auto-detect from server config when possible)
DEFAULT_SERVER_INTERFACE="wg0"
DEFAULT_CLIENT_COUNT=20
DEFAULT_CONFIG_DIR="wg-configs"
DEFAULT_CLIENT_PREFIX="client"
USE_PRESHARED_KEY=true

# Help function
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "Generate WireGuard client configurations from existing server configuration"
    echo
    echo "Optional Settings:"
    echo "  -h, --help                  Show this help message"
    echo "  -e, --server-endpoint       Server endpoint (IP:port) to override auto-detected value"
    echo "  -k, --server-public-key     Server public key (auto-detected if not specified)"
    echo "  -n, --num-clients           Number of clients to generate (default: $DEFAULT_CLIENT_COUNT)"
    echo "  -s, --subnet                Client subnet (auto-detected if not specified)"
    echo "  -o, --starting-ip           Starting IP offset for clients (auto-detected if not specified)"
    echo "  -a, --allowed-ips           Allowed IPs (default: auto-detected or subnet-based)"
    echo "  -m, --mtu                   MTU value (auto-detected if not specified)"
    echo "  -i, --interface             Server interface name (default: $DEFAULT_SERVER_INTERFACE)"
    echo "  -c, --config-dir            Directory to store configs (default: $DEFAULT_CONFIG_DIR)"
    echo "  -p, --prefix                Client name prefix (default: $DEFAULT_CLIENT_PREFIX)"
    echo "  -d, --dns                   DNS servers (default: auto-detected or none)"
    echo "  --no-preshared              Disable generation of preshared keys"
    echo "  --no-append                 Don't append to server config (just generate clients)"
    echo
    echo "Example with all auto-detection:"
    echo "  $0"
    echo
    echo "Example overriding endpoint (for port forwarding):"
    echo "  $0 -e public.example.com:51820"
}

# Parse command line arguments
SERVER_PUBLIC_KEY=""
SERVER_ENDPOINT=""
SERVER_INTERFACE=$DEFAULT_SERVER_INTERFACE
CLIENT_SUBNET=""
STARTING_IP=""
CLIENT_COUNT=$DEFAULT_CLIENT_COUNT
ALLOWED_IPS=""
MTU=""
DNS_SERVERS=""
CONFIG_DIR=$DEFAULT_CONFIG_DIR
CLIENT_PREFIX=$DEFAULT_CLIENT_PREFIX
APPEND_TO_SERVER=true

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -k|--server-public-key)
            SERVER_PUBLIC_KEY="$2"
            shift 2
            ;;
        -e|--server-endpoint)
            SERVER_ENDPOINT="$2"
            shift 2
            ;;
        -i|--interface)
            SERVER_INTERFACE="$2"
            shift 2
            ;;
        -s|--subnet)
            CLIENT_SUBNET="$2"
            shift 2
            ;;
        -o|--starting-ip)
            STARTING_IP="$2"
            shift 2
            ;;
        -n|--num-clients)
            CLIENT_COUNT="$2"
            shift 2
            ;;
        -a|--allowed-ips)
            ALLOWED_IPS="$2"
            shift 2
            ;;
        -m|--mtu)
            MTU="$2"
            shift 2
            ;;
        -d|--dns)
            DNS_SERVERS="$2"
            shift 2
            ;;
        -c|--config-dir)
            CONFIG_DIR="$2"
            shift 2
            ;;
        -p|--prefix)
            CLIENT_PREFIX="$2"
            shift 2
            ;;
        --no-preshared)
            USE_PRESHARED_KEY=false
            shift
            ;;
        --no-append)
            APPEND_TO_SERVER=false
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Create config directory
mkdir -p "$CONFIG_DIR"

# File to collect new peer entries for server
SERVER_PEERS_FILE="$CONFIG_DIR/new_server_peers.conf"
> "$SERVER_PEERS_FILE"  # Create/clear the file

# Server config path
SERVER_CONFIG="/etc/wireguard/${SERVER_INTERFACE}.conf"

# Check if WireGuard server configuration exists
if ! sudo test -f "$SERVER_CONFIG"; then
    echo "Error: WireGuard configuration file $SERVER_CONFIG not found."
    echo "Make sure WireGuard is properly installed and configured."
    exit 1
fi

echo "Extracting configuration from $SERVER_CONFIG..."

# Create a temporary copy of the server config to work with
TEMP_CONFIG=$(mktemp)
sudo cat "$SERVER_CONFIG" > "$TEMP_CONFIG"

# Auto-detect server's public key if not specified
if [ -z "$SERVER_PUBLIC_KEY" ]; then
    # Try to generate public key from private key
    SERVER_PRIVATE_KEY=$(grep -E "^PrivateKey\s*=" "$TEMP_CONFIG" | sed 's/PrivateKey\s*=\s*//' | tr -d ' \t')
    
    if [ -n "$SERVER_PRIVATE_KEY" ]; then
        # Generate public key from private key
        SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey 2>/dev/null)
        if [ -n "$SERVER_PUBLIC_KEY" ]; then
            echo "Generated server public key from private key: $SERVER_PUBLIC_KEY"
        else
            echo "Error: Failed to generate public key from private key."
            echo "Please specify the server's public key with -k option"
            exit 1
        fi
    else
        echo "Error: Unable to extract server's private key from $SERVER_CONFIG"
        echo "Please specify the server's public key with -k option"
        exit 1
    fi
fi

# Auto-detect server address if not specified
SERVER_ADDRESS=$(grep -E "^Address\s*=" "$TEMP_CONFIG" | sed 's/Address\s*=\s*//' | tr -d ' \t')
if [ -n "$SERVER_ADDRESS" ]; then
    # Extract subnet from server address (e.g., 192.168.48.254/24 -> 192.168.48)
    if [[ "$SERVER_ADDRESS" =~ ([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/[0-9]+ ]]; then
        CLIENT_SUBNET="${BASH_REMATCH[1]}"
        echo "Detected client subnet from server address: $CLIENT_SUBNET"
        # Extract server IP for later use
        if [[ "$SERVER_ADDRESS" =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/[0-9]+ ]]; then
            SERVER_IP="${BASH_REMATCH[1]}"
        fi
    fi
fi

# If still no subnet, use default
if [ -z "$CLIENT_SUBNET" ]; then
    CLIENT_SUBNET="192.168.48"  # Default based on your example
    echo "Using default client subnet: $CLIENT_SUBNET"
fi

# Auto-detect server listen port
SERVER_PORT=$(grep -E "^ListenPort\s*=" "$TEMP_CONFIG" | sed 's/ListenPort\s*=\s*//' | tr -d ' \t')
if [ -z "$SERVER_PORT" ]; then
    SERVER_PORT="51820"  # Default WireGuard port
    echo "Using default server port: $SERVER_PORT"
else
    echo "Detected server port: $SERVER_PORT"
fi

# Auto-detect server endpoint if not specified
if [ -z "$SERVER_ENDPOINT" ]; then
    # Try to get server's IP
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(hostname -I | awk '{print $1}')
    fi
    
    if [ -n "$SERVER_IP" ]; then
        SERVER_ENDPOINT="${SERVER_IP}:${SERVER_PORT}"
        echo "Auto-detected server endpoint: $SERVER_ENDPOINT"
        echo "NOTE: For external access, override with -e public.example.com:$SERVER_PORT"
    else
        echo "Warning: Could not auto-detect server IP"
        echo "Please specify server endpoint with -e option"
        exit 1
    fi
fi

# Auto-detect MTU if not specified
if [ -z "$MTU" ]; then
    AUTO_MTU=$(grep -E "^MTU\s*=" "$TEMP_CONFIG" | sed 's/MTU\s*=\s*//' | tr -d ' \t')
    if [ -n "$AUTO_MTU" ]; then
        MTU="$AUTO_MTU"
        echo "Detected MTU: $MTU"
    else
        MTU="1360"  # Default based on your example
        echo "Using default MTU: $MTU"
    fi
fi

# Set AllowedIPs if not specified
if [ -z "$ALLOWED_IPS" ]; then
    # In client configs, AllowedIPs determines what traffic goes through the VPN
    # Standard options:
    # - "0.0.0.0/0, ::/0" = Full tunnel (all traffic through VPN)
    # - "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16" = Split tunnel (only private IPs)
    # - "$CLIENT_SUBNET.0/24" = Only VPN subnet traffic
    
    # Default to full VPN routing (most common and secure setup)
    ALLOWED_IPS="0.0.0.0/0, ::/0"
    echo "Using default AllowedIPs for full tunnel: $ALLOWED_IPS"
    echo "To use split tunneling, use -a option with alternative settings"
fi

# Auto-detect last used IP if not specified
if [ -z "$STARTING_IP" ]; then
    # Get server IP last octet
    if [[ "$SERVER_ADDRESS" =~ [0-9]+\.[0-9]+\.[0-9]+\.([0-9]+)/[0-9]+ ]]; then
        SERVER_LAST_OCTET="${BASH_REMATCH[1]}"
        echo "Server is using IP: $SERVER_LAST_OCTET in subnet"
    else
        SERVER_LAST_OCTET="254"  # Default based on your example
    fi
    
    # More direct approach: Look for IP addresses in the config
    echo "Scanning for existing peer IPs..."
    # Extract all lines with AllowedIPs
    PEER_IPS=()
    
    # Use a completely different approach that doesn't rely on regex patterns
    # Instead, extract all AllowedIPs lines and then process each one
    # This is much more reliable than trying to match with a complex regex
    while IFS= read -r line; do
        # First, check if this line contains AllowedIPs
        if [[ "$line" == *"AllowedIPs"* ]]; then
            # Extract everything after the equals sign
            IP_PART=${line#*=}
            # Trim leading and trailing whitespace
            IP_PART=$(echo "$IP_PART" | xargs)
            
            # Now we have just the IP address part
            echo "Found allowed IP: $IP_PART"
            
            # Check if it's in our subnet
            if [[ "$IP_PART" == "$CLIENT_SUBNET"* ]]; then
                # Extract the last octet, with or without /32
                if [[ "$IP_PART" =~ $CLIENT_SUBNET\.([0-9]+)(/[0-9]+)? ]]; then
                    LAST_OCTET="${BASH_REMATCH[1]}"
                    echo "Found peer IP in our subnet: $CLIENT_SUBNET.$LAST_OCTET"
                    PEER_IPS+=("$LAST_OCTET")
                fi
            fi
        fi
    done < "$TEMP_CONFIG"
    
    # Find highest IP or set default
    if [ ${#PEER_IPS[@]} -gt 0 ]; then
        # Sort numerically and get highest
        HIGHEST_IP=$(printf '%s\n' "${PEER_IPS[@]}" | sort -n | tail -1)
        STARTING_IP=$((HIGHEST_IP + 1))
        echo "All peer IPs found: ${PEER_IPS[*]}"
        echo "Highest IP in use: ${CLIENT_SUBNET}.${HIGHEST_IP}"
        echo "Starting new clients at: ${CLIENT_SUBNET}.${STARTING_IP}"
    else
        # No peers found, avoid server IP and start at 2
        STARTING_IP=2
        echo "No existing peers found. Starting from ${CLIENT_SUBNET}.${STARTING_IP}"
    fi
    
    # Ensure we're not using the server's IP
    if [ "$STARTING_IP" -eq "$SERVER_LAST_OCTET" ]; then
        STARTING_IP=$((STARTING_IP + 1))
        echo "Adjusted starting IP to avoid server IP: ${CLIENT_SUBNET}.${STARTING_IP}"
    fi
fi

# Clean up temp file
rm -f "$TEMP_CONFIG"

echo "----------------------------------------"
echo "Configuration Summary:"
echo "Server endpoint:     $SERVER_ENDPOINT"
echo "Server public key:   $SERVER_PUBLIC_KEY"
echo "Client subnet:       $CLIENT_SUBNET"
echo "Starting IP:         $STARTING_IP"
echo "Clients to generate: $CLIENT_COUNT"
if [ -n "$MTU" ]; then
    echo "MTU:                 $MTU"
fi
echo "Allowed IPs:         $ALLOWED_IPS"
if [ -n "$DNS_SERVERS" ]; then
    echo "DNS Servers:        $DNS_SERVERS"
fi
echo "----------------------------------------"

# Generate configs for specified number of clients
for i in $(seq 1 $CLIENT_COUNT); do
    # Calculate IP for this client
    IP_NUM=$((STARTING_IP + i - 1))
    
    # Generate client name
    CLIENT_NAME="${CLIENT_PREFIX}$i"
    
    # Generate private and public keys
    CLIENT_PRIVATE_KEY=$(wg genkey)
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
    
    # Generate preshared key if enabled
    if [ "$USE_PRESHARED_KEY" = true ]; then
        PRESHARED_KEY=$(wg genpsk)
    fi
    
    # Assign IP address (incremental)
    CLIENT_IP="${CLIENT_SUBNET}.${IP_NUM}"
    
    # Create client config file
    cat > "$CONFIG_DIR/$CLIENT_NAME.conf" << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
EOF

    # Add MTU if specified
    if [ -n "$MTU" ]; then
        echo "MTU = $MTU" >> "$CONFIG_DIR/$CLIENT_NAME.conf"
    fi

    # Add DNS if specified
    if [ -n "$DNS_SERVERS" ]; then
        echo "DNS = $DNS_SERVERS" >> "$CONFIG_DIR/$CLIENT_NAME.conf"
    fi

    # Add peer section
    cat >> "$CONFIG_DIR/$CLIENT_NAME.conf" << EOF

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
EOF

    # Add preshared key if enabled
    if [ "$USE_PRESHARED_KEY" = true ]; then
        echo "PresharedKey = $PRESHARED_KEY" >> "$CONFIG_DIR/$CLIENT_NAME.conf"
    fi

    # Add remaining peer configuration
    cat >> "$CONFIG_DIR/$CLIENT_NAME.conf" << EOF
AllowedIPs = $ALLOWED_IPS
Endpoint = $SERVER_ENDPOINT
PersistentKeepalive = 25
EOF

    echo "Generated config for $CLIENT_NAME with IP $CLIENT_IP"
    
    # Add this client to the server peers file
    cat >> "$SERVER_PEERS_FILE" << EOF
[Peer]
# User $CLIENT_NAME
PublicKey = $CLIENT_PUBLIC_KEY
EOF

    # Add preshared key to server config if enabled
    if [ "$USE_PRESHARED_KEY" = true ]; then
        echo "PresharedKey = $PRESHARED_KEY" >> "$SERVER_PEERS_FILE"
    fi

    # Complete server peer entry
    cat >> "$SERVER_PEERS_FILE" << EOF
AllowedIPs = $CLIENT_IP/32

EOF
done

echo "----------------------------------------"
echo "All client configurations generated in the $CONFIG_DIR directory."

# Append to server config if requested
if [ "$APPEND_TO_SERVER" = true ]; then
    echo "Appending new peers to $SERVER_CONFIG"
    sudo cp "$SERVER_PEERS_FILE" /tmp/wg_peers_to_add.conf
    sudo sh -c "cat /tmp/wg_peers_to_add.conf >> $SERVER_CONFIG"
    sudo rm /tmp/wg_peers_to_add.conf
    
    echo "Reloading WireGuard configuration..."
    # Create a temporary file for the stripped config
    TMP_CONFIG=$(mktemp)
    if sudo wg-quick strip "$SERVER_INTERFACE" > "$TMP_CONFIG" 2>/dev/null; then
        if sudo wg syncconf "$SERVER_INTERFACE" "$TMP_CONFIG"; then
            echo "Successfully added $CLIENT_COUNT new peers to WireGuard server."
        else
            echo "Trying alternative reload method..."
            if sudo systemctl restart wg-quick@$SERVER_INTERFACE; then
                echo "Successfully added $CLIENT_COUNT new peers to WireGuard server."
            else
                echo "Warning: Failed to reload WireGuard configuration."
                echo "Please restart WireGuard manually with: sudo systemctl restart wg-quick@$SERVER_INTERFACE"
            fi
        fi
    else
        echo "Trying alternative reload method..."
        if sudo systemctl restart wg-quick@$SERVER_INTERFACE; then
            echo "Successfully added $CLIENT_COUNT new peers to WireGuard server."
        else
            echo "Warning: Failed to reload WireGuard configuration."
            echo "Please restart WireGuard manually with: sudo systemctl restart wg-quick@$SERVER_INTERFACE"
        fi
    fi
    rm -f "$TMP_CONFIG"
else
    echo "New server peer entries saved to $SERVER_PEERS_FILE"
    echo "--no-append option was specified; peers not added to server config."
fi

# Create a QR code for each client if qrencode is installed
if command -v qrencode &> /dev/null; then
    echo "Generating QR codes for client configurations..."
    mkdir -p "$CONFIG_DIR/qrcodes"
    for i in $(seq 1 $CLIENT_COUNT); do
        CLIENT_NAME="${CLIENT_PREFIX}$i"
        qrencode -t PNG -o "$CONFIG_DIR/qrcodes/$CLIENT_NAME.png" < "$CONFIG_DIR/$CLIENT_NAME.conf"
    done
    echo "QR codes saved to $CONFIG_DIR/qrcodes/"
else
    echo "Note: qrencode not installed. Install it to generate QR codes for mobile clients."
    echo "      (e.g., sudo apt install qrencode)"
fi

echo ""
echo "Done! Client configuration files are available in $CONFIG_DIR/"