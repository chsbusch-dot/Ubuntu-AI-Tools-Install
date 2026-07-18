#!/bin/bash
# SessionStart hook for Claude Code on the web: bring up a WireGuard tunnel
# to the home network using secrets configured in the environment settings.
#
# Required environment secrets (set in the Claude Code environment, never in git):
#   WG_PRIVATE_KEY     - private key of the dedicated peer created for Claude
#   WG_PEER_PUBLIC_KEY - public key of the home WireGuard server
#   WG_PEER_ENDPOINT   - public endpoint of the home server, e.g. "vpn.example.com:51820"
#   WG_ADDRESS         - tunnel address for this peer, e.g. "10.13.13.10/32"
#   WG_ALLOWED_IPS     - comma-separated CIDRs routed through the tunnel,
#                        e.g. "192.168.7.42/32,192.168.7.0/24" (keep this narrow)
# Optional:
#   WG_PRESHARED_KEY   - preshared key if the server peer uses one
#   WG_MTU             - tunnel MTU (default 1280, safe inside containers)
#   WG_KEEPALIVE       - persistent keepalive seconds (default 25)
#
# If the WG_* secrets are absent the hook exits quietly, so sessions in
# environments without them are unaffected. Failures never block the session.
set -euo pipefail

# Only relevant in remote (web) sessions.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

missing=""
for var in WG_PRIVATE_KEY WG_PEER_PUBLIC_KEY WG_PEER_ENDPOINT WG_ADDRESS WG_ALLOWED_IPS; do
  [ -n "${!var:-}" ] || missing="$missing $var"
done
if [ -n "$missing" ]; then
  echo "WireGuard: not configured (missing:$missing) - skipping tunnel setup."
  exit 0
fi

# A setup failure should be reported, not brick the session.
trap 'echo "WireGuard: setup failed at line $LINENO - continuing without tunnel."; exit 0' ERR

WG_IF="wg0"
export DEBIAN_FRONTEND=noninteractive

# --- dependencies (cached in the container snapshot after first run) ---------
need_pkgs=""
command -v ip >/dev/null 2>&1 || need_pkgs="$need_pkgs iproute2"
command -v wg >/dev/null 2>&1 || need_pkgs="$need_pkgs wireguard-tools"
if [ -n "$need_pkgs" ]; then
  # shellcheck disable=SC2086  # word splitting of the package list is intended
  apt-get install -y -qq $need_pkgs >/dev/null 2>&1 \
    || { apt-get update -qq >/dev/null 2>&1 || true; apt-get install -y -qq $need_pkgs >/dev/null; }
fi

# Userspace daemon, needed when the kernel module is unavailable (the usual
# case in this container). Built once, then cached with the container state.
if ! ip link add "$WG_IF" type wireguard 2>/dev/null; then
  if ! command -v wireguard-go >/dev/null 2>&1; then
    echo "WireGuard: building wireguard-go (first run only)..."
    command -v go >/dev/null 2>&1 || apt-get install -y -qq golang-go >/dev/null
    build_dir="$(mktemp -d)"
    git clone --quiet --depth 1 https://github.com/WireGuard/wireguard-go.git "$build_dir"
    (cd "$build_dir" && go build -o /usr/local/bin/wireguard-go .)
    rm -rf "$build_dir"
  fi
  # Recreate the interface from scratch for a deterministic state. Daemon
  # output goes to a log file to keep session context clean.
  ip link del "$WG_IF" 2>/dev/null || true
  LOG_LEVEL=error wireguard-go "$WG_IF" >>"/tmp/wireguard-go.$WG_IF.log" 2>&1
else
  ip link del "$WG_IF" 2>/dev/null || true
  ip link add "$WG_IF" type wireguard
fi

# --- configuration -----------------------------------------------------------
umask 077
key_dir="$(mktemp -d)"
printf '%s\n' "$WG_PRIVATE_KEY" > "$key_dir/private.key"
psk_args=()
if [ -n "${WG_PRESHARED_KEY:-}" ]; then
  printf '%s\n' "$WG_PRESHARED_KEY" > "$key_dir/preshared.key"
  psk_args=(preshared-key "$key_dir/preshared.key")
fi

wg set "$WG_IF" private-key "$key_dir/private.key" \
  peer "$WG_PEER_PUBLIC_KEY" \
  endpoint "$WG_PEER_ENDPOINT" \
  allowed-ips "$WG_ALLOWED_IPS" \
  persistent-keepalive "${WG_KEEPALIVE:-25}" \
  "${psk_args[@]}"
rm -rf "$key_dir"

ip address add "$WG_ADDRESS" dev "$WG_IF"
ip link set mtu "${WG_MTU:-1280}" up dev "$WG_IF"
IFS=',' read -ra cidrs <<< "$WG_ALLOWED_IPS"
for cidr in "${cidrs[@]}"; do
  ip route replace "$cidr" dev "$WG_IF"
done

# --- verify ------------------------------------------------------------------
for _ in $(seq 1 15); do
  handshake="$(wg show "$WG_IF" latest-handshakes | awk '{print $2}')"
  if [ "${handshake:-0}" != "0" ]; then
    echo "WireGuard: tunnel up on $WG_IF, handshake with $WG_PEER_ENDPOINT OK. Routed: $WG_ALLOWED_IPS"
    exit 0
  fi
  sleep 1
done

echo "WireGuard: interface $WG_IF configured but no handshake after 15s." \
  "Check WG_PEER_ENDPOINT reachability and keys. Continuing without a verified tunnel."
exit 0
