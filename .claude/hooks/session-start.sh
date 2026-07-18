#!/bin/bash
# SessionStart hook for Claude Code on the web. Two jobs:
#
#   1. Bring up a WireGuard tunnel to the home network (WG_* secrets).
#   2. Provision the home-infrastructure MCP servers declared in .mcp.json
#      that need an install step (ESXi, iDRAC) or a cache warm-up (UniFi).
#
# Everything is driven by environment secrets configured in the Claude Code
# environment settings:
#   Tunnel: WG_PRIVATE_KEY, WG_PEER_PUBLIC_KEY, WG_PEER_ENDPOINT, WG_ADDRESS,
#           WG_ALLOWED_IPS (+ optional WG_PRESHARED_KEY, WG_MTU, WG_KEEPALIVE)
#   UniFi:  UNIFI_HOST, UNIFI_API_KEY
#   ESXi:   ESXI_HOST, ESXI_PASSWORD (+ optional ESXI_USER, ESXI_DATASTORE,
#           ESXI_NETWORK)
#   iDRAC:  IDRAC_HOST, IDRAC_PASSWORD (+ optional IDRAC_USER)
#   Hubitat: HUBITAT_MCP_URL (MCP Rule Server endpoint on the hub)
# Hosts reached via the tunnel must be included in WG_ALLOWED_IPS.
# Services whose secrets are absent are skipped quietly, and no failure here
# ever blocks the session from starting. Installs land in fixed paths that
# are cached with the container state, so only the first session pays them.
set -euo pipefail

# Only relevant in remote (web) sessions.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

trap 'echo "session-start: step failed at line $LINENO - continuing session anyway."; exit 0' ERR
export DEBIAN_FRONTEND=noninteractive

# --- WireGuard tunnel --------------------------------------------------------
WG_IF="wg0"
wg_missing=""
for var in WG_PRIVATE_KEY WG_PEER_PUBLIC_KEY WG_PEER_ENDPOINT WG_ADDRESS WG_ALLOWED_IPS; do
  [ -n "${!var:-}" ] || wg_missing="$wg_missing $var"
done

if [ -n "$wg_missing" ]; then
  echo "WireGuard: not configured (missing:$wg_missing) - skipping tunnel setup."
else
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

  wg_up=false
  for _ in $(seq 1 15); do
    handshake="$(wg show "$WG_IF" latest-handshakes | awk '{print $2}')"
    if [ "${handshake:-0}" != "0" ]; then wg_up=true; break; fi
    sleep 1
  done
  if $wg_up; then
    echo "WireGuard: tunnel up on $WG_IF, handshake with $WG_PEER_ENDPOINT OK. Routed: $WG_ALLOWED_IPS"
  else
    echo "WireGuard: interface $WG_IF configured but no handshake after 15s." \
      "Check WG_PEER_ENDPOINT reachability and keys. Continuing without a verified tunnel."
  fi
fi

# --- MCP: ESXi (vcenter-mcp) -------------------------------------------------
if [ -n "${ESXI_HOST:-}" ]; then
  esxi_venv="/usr/local/lib/vcenter-mcp-venv"
  if [ ! -x "$esxi_venv/bin/python" ]; then
    echo "MCP esxi: installing vcenter-mcp (first run only)..."
    python3 -m venv "$esxi_venv" 2>/dev/null \
      || { apt-get install -y -qq python3-venv >/dev/null; python3 -m venv "$esxi_venv"; }
    "$esxi_venv/bin/pip" install --quiet "git+https://github.com/michaelrice/vcenter-mcp.git"
  fi
  # vcenter-mcp normally configures itself via an interactive wizard; write
  # its config file directly from the environment secrets instead.
  umask 077
  mkdir -p "$HOME/.config/vcenter-mcp"
  ESXI_HOST="$ESXI_HOST" python3 - <<'PYEOF'
import json, os
cfg = {
    "default_target": "esxi",
    "targets": {
        "esxi": {
            "host": os.environ["ESXI_HOST"],
            "user": os.environ.get("ESXI_USER", "root"),
            "password": os.environ.get("ESXI_PASSWORD", ""),
            "type": "esxi",
            "networks": {"standard": [os.environ.get("ESXI_NETWORK", "VM Network")]},
            "default_network": "standard",
            "datastore": os.environ.get("ESXI_DATASTORE", "datastore1"),
        }
    },
}
path = os.path.expanduser("~/.config/vcenter-mcp/config.json")
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(path, 0o600)
PYEOF
  echo "MCP esxi: vcenter-mcp ready for $ESXI_HOST."
else
  echo "MCP esxi: ESXI_HOST not set - skipped."
fi

# --- MCP: iDRAC (mcp-redfish) ------------------------------------------------
if [ -n "${IDRAC_HOST:-}" ]; then
  redfish_dir="/usr/local/lib/mcp-redfish"
  if [ ! -f "$redfish_dir/dist/index.js" ]; then
    echo "MCP idrac: building mcp-redfish (first run only)..."
    command -v node >/dev/null 2>&1 || apt-get install -y -qq nodejs npm >/dev/null
    rm -rf "$redfish_dir"
    git clone --quiet --depth 1 https://github.com/fredriksknese/mcp-redfish.git "$redfish_dir"
    (cd "$redfish_dir" && npm install --silent >/dev/null 2>&1 && npm run build --silent >/dev/null 2>&1)
  fi
  echo "MCP idrac: mcp-redfish ready for $IDRAC_HOST."
else
  echo "MCP idrac: IDRAC_HOST not set - skipped."
fi

# --- MCP: UniFi (mcp-unifi via uvx) ------------------------------------------
if [ -n "${UNIFI_HOST:-}" ]; then
  if command -v uvx >/dev/null 2>&1; then
    # Warm the uvx build cache so the server starts instantly when the
    # session connects to it. Runs in stub mode; failures are non-fatal.
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"warmup","version":"0"}}}' \
      | STUB_MODE=true MCP_TRANSPORT=stdio timeout 120 \
        uvx --from git+https://github.com/pete-builds/mcp-unifi mcp-unifi >/dev/null 2>&1 || true
    echo "MCP unifi: mcp-unifi ready for $UNIFI_HOST."
  else
    echo "MCP unifi: uvx not found - the unifi server in .mcp.json will not start."
  fi
else
  echo "MCP unifi: UNIFI_HOST not set - skipped."
fi

# --- MCP: Hubitat (MCP Rule Server on the hub, HTTP) -------------------------
if [ -n "${HUBITAT_MCP_URL:-}" ]; then
  echo "MCP hubitat: endpoint configured."
else
  echo "MCP hubitat: HUBITAT_MCP_URL not set - skipped."
fi

exit 0
