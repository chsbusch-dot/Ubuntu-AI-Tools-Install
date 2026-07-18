#!/usr/bin/env bash
# wg-ionos-setup.sh — WireGuard "exit node" setup for an IONOS (or any) Ubuntu VPS.
#
# Purpose: let a UniFi gateway at home dial this VPS as a WireGuard VPN client,
# so selected LAN devices (e.g. two Fire TVs) can be policy-routed out through
# the VPS's German IP.
#
#   Fire TV ──▶ UniFi gateway ──(WireGuard tunnel)──▶ this VPS ──▶ internet (DE)
#
# Usage (as root on the VPS):
#   bash wg-ionos-setup.sh              # install + configure + print UniFi config
#   bash wg-ionos-setup.sh show-client  # reprint the UniFi client config
#   bash wg-ionos-setup.sh status      # wg status + forwarding/NAT sanity checks
#
# Idempotent: keys and config are only generated if missing. Re-running is safe.
#
# Remember to also open UDP ${WG_PORT} in the IONOS Cloud Panel firewall —
# the panel firewall sits in front of the VPS and drops the port otherwise.

set -euo pipefail

WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_NET="${WG_NET:-10.66.0}"          # /24 base; server=.1, UniFi peer=.2
WG_DIR="/etc/wireguard"
SERVER_ADDR="${WG_NET}.1"
PEER_ADDR="${WG_NET}.2"

info() { printf '\033[1;32m[wg-setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[wg-setup]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[wg-setup]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo bash $0)."

detect_wan() {
    WAN_IF=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)
    [ -n "${WAN_IF}" ] || die "Could not detect the default (WAN) interface."
    PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") print $(i+1)}' | head -n1)
    # VPS interface addresses are usually the public IP; fall back to a lookup.
    case "${PUBLIC_IP}" in
        10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*|100.6[4-9].*|100.[7-9]*.*|100.1[0-2]*.*|"")
            PUBLIC_IP=$(curl -4fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)
            ;;
    esac
    [ -n "${PUBLIC_IP}" ] || die "Could not determine the public IP. Set PUBLIC_IP=x.x.x.x and re-run."
}

install_packages() {
    if ! command -v wg >/dev/null 2>&1; then
        info "Installing WireGuard..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq wireguard iptables curl
    fi
}

generate_keys() {
    umask 077
    mkdir -p "${WG_DIR}"
    for name in server unifi; do
        if [ ! -f "${WG_DIR}/${name}.key" ]; then
            info "Generating ${name} key pair..."
            wg genkey | tee "${WG_DIR}/${name}.key" | wg pubkey > "${WG_DIR}/${name}.pub"
        fi
    done
}

write_config() {
    if [ -f "${WG_DIR}/${WG_IF}.conf" ]; then
        info "${WG_DIR}/${WG_IF}.conf already exists — leaving it untouched."
        return
    fi
    info "Writing ${WG_DIR}/${WG_IF}.conf..."
    umask 077
    cat > "${WG_DIR}/${WG_IF}.conf" <<EOF
[Interface]
Address = ${SERVER_ADDR}/24
ListenPort = ${WG_PORT}
PrivateKey = $(cat "${WG_DIR}/server.key")
PostUp = iptables -t nat -A POSTROUTING -s ${WG_NET}.0/24 -o ${WAN_IF} -j MASQUERADE; iptables -A FORWARD -i ${WG_IF} -j ACCEPT; iptables -A FORWARD -o ${WG_IF} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NET}.0/24 -o ${WAN_IF} -j MASQUERADE; iptables -D FORWARD -i ${WG_IF} -j ACCEPT; iptables -D FORWARD -o ${WG_IF} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# UniFi gateway at home. It source-NATs LAN clients behind ${PEER_ADDR},
# so a /32 is all the routing this side needs.
[Peer]
PublicKey = $(cat "${WG_DIR}/unifi.pub")
AllowedIPs = ${PEER_ADDR}/32
EOF
}

enable_forwarding() {
    info "Enabling IPv4 forwarding..."
    cat > /etc/sysctl.d/99-wireguard-forward.conf <<EOF
net.ipv4.ip_forward = 1
EOF
    sysctl -q -p /etc/sysctl.d/99-wireguard-forward.conf
}

open_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        info "Allowing UDP ${WG_PORT} in ufw..."
        ufw allow "${WG_PORT}/udp" >/dev/null
    fi
}

start_service() {
    info "Enabling wg-quick@${WG_IF}..."
    systemctl enable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 \
        || systemctl restart "wg-quick@${WG_IF}"
}

print_client_config() {
    detect_wan
    cat <<EOF

============================================================
 UniFi VPN Client configuration (WireGuard)
============================================================
Paste these values in the UniFi Network app under
Settings -> VPN -> VPN Client -> Create New -> WireGuard:

  Tunnel (interface) IP .... ${PEER_ADDR}/32
  Private key .............. $(cat "${WG_DIR}/unifi.key")
  Server (peer) public key . $(cat "${WG_DIR}/server.pub")
  Endpoint ................. ${PUBLIC_IP}:${WG_PORT}
  Allowed IPs .............. 0.0.0.0/0
  Persistent keepalive ..... 25

Equivalent importable wg-quick file:

[Interface]
PrivateKey = $(cat "${WG_DIR}/unifi.key")
Address = ${PEER_ADDR}/32

[Peer]
PublicKey = $(cat "${WG_DIR}/server.pub")
Endpoint = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25

Then route only the Fire TVs through it:
Settings -> Routing -> Policy-Based Routing -> Create Entry ->
source: the two Fire TV devices, interface: this VPN client.

If you prefer UniFi to generate its own private key, replace the
[Peer] PublicKey in ${WG_DIR}/${WG_IF}.conf with UniFi's public
key and run: systemctl restart wg-quick@${WG_IF}
============================================================
EOF
}

show_status() {
    wg show "${WG_IF}" || warn "Interface ${WG_IF} is not up."
    printf 'ip_forward: %s\n' "$(sysctl -n net.ipv4.ip_forward)"
    iptables -t nat -S POSTROUTING | grep -F "${WG_NET}.0/24" \
        || warn "No MASQUERADE rule found for ${WG_NET}.0/24."
}

case "${1:-install}" in
    install)
        install_packages
        detect_wan
        generate_keys
        write_config
        enable_forwarding
        open_firewall
        start_service
        info "Server is up on ${PUBLIC_IP}:${WG_PORT} (interface ${WG_IF})."
        print_client_config
        ;;
    show-client)
        [ -f "${WG_DIR}/unifi.key" ] || die "No client key yet — run the installer first."
        print_client_config
        ;;
    status)
        show_status
        ;;
    *)
        die "Unknown command '$1'. Use: install (default), show-client, status."
        ;;
esac
