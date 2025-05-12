# WireGuard Client Configuration Generator

A bash script to automatically generate WireGuard client configurations from an existing WireGuard server setup.

## Overview

This tool simplifies the process of adding new clients to an existing WireGuard VPN server by:

1. Auto-detecting server settings from your existing configuration
2. Generating client configuration files with unique keys and IPs
3. Automatically appending new peer entries to your server config
4. Creating QR codes for easy mobile client setup (if qrencode is installed)

## Requirements

- WireGuard already installed and configured on the server
- Bash shell
- `wg` and `wg-quick` commands available
- `qrencode` (optional, for QR code generation)

## Usage

```bash
./wireguard_gen.sh [OPTIONS]
```

### Basic Usage

Run the script without any parameters to auto-detect settings from your server configuration:

```bash
sudo ./wireguard_gen.sh
```

This will:
- Extract your server's public key, subnet, port, etc. from `/etc/wireguard/wg0.conf`
- Generate 20 client configurations in the `wg-configs` directory
- Add the new clients to your server configuration
- Reload the WireGuard service

### Options

```
Optional Settings:
  -h, --help                  Show this help message
  -e, --server-endpoint       Server endpoint (IP:port) to override auto-detected value
  -k, --server-public-key     Server public key (auto-detected if not specified)
  -n, --num-clients           Number of clients to generate (default: 20)
  -s, --subnet                Client subnet (auto-detected if not specified)
  -o, --starting-ip           Starting IP offset for clients (auto-detected if not specified)
  -a, --allowed-ips           Allowed IPs (default: auto-detected or subnet-based)
  -m, --mtu                   MTU value (auto-detected if not specified)
  -i, --interface             Server interface name (default: wg0)
  -c, --config-dir            Directory to store configs (default: wg-configs)
  -p, --prefix                Client name prefix (default: client)
  -d, --dns                   DNS servers (default: auto-detected or none)
  --no-preshared              Disable generation of preshared keys
  --no-append                 Don't append to server config (just generate clients)
```

### Examples

**Generate 5 client configurations with a custom name prefix:**
```bash
sudo ./wireguard_gen.sh -n 5 -p employee
```

**Specify a different endpoint for the server (useful when behind NAT) and generate 5 client configurations with it:**
```bash
sudo ./wireguard_gen.sh -e 192.168.9.1:51820 -n 5
```

**Generate configs without modifying the server:**
```bash
./wireguard_gen.sh --no-append
```

**Generate configs with custom DNS servers:**
```bash
sudo ./wireguard_gen.sh -d "1.1.1.1, 1.0.0.1"
```

## Output

The script creates:
- Client configuration files in the `wg-configs` directory
- QR code PNG images in the `wg-configs/qrcodes` directory (if qrencode is installed)
- A summary of new peer entries in `wg-configs/new_server_peers.conf`

## Security Notes

- The script generates unique private, public, and preshared keys for each client
- Keys are stored in plain text in configuration files, so secure the `wg-configs` directory
- Consider deleting configurations after distributing them to clients

## Troubleshooting

If the WireGuard service fails to reload automatically:
1. The script will attempt alternative reload methods
2. If all fail, manually restart with: `sudo systemctl restart wg-quick@wg0`

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
