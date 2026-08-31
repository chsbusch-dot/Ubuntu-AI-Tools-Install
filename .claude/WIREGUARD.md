# WireGuard tunnel for Claude Code on the web sessions

The `SessionStart` hook in this repo (`.claude/hooks/session-start.sh`) brings up a
WireGuard tunnel to the home network at the start of every remote session — but only
when the environment is configured with the secrets below. Environments without them
are completely unaffected.

The container has no WireGuard kernel module, so the hook falls back to userspace
`wireguard-go` over a TUN device (verified working in this environment). The first
session builds the binary (~1–2 min); afterwards it is cached with the container state.

## One-time setup on the home WireGuard server

Create a **dedicated peer** for Claude — do not reuse an existing device's keys:

```sh
wg genkey | tee claude.key | wg pubkey > claude.pub
```

Add the peer to the server config, scoped as narrowly as possible:

```ini
[Peer]
# Claude Code remote sessions
PublicKey = <contents of claude.pub>
AllowedIPs = 10.13.13.10/32        # the tunnel IP you assign this peer
```

Recommended: firewall this peer's tunnel IP on the server so it can only reach the
specific hosts/ports it needs (e.g. the Hubitat hub on TCP 80/443), not the whole LAN.

## One-time setup in the Claude Code environment

In the environment settings on claude.ai/code, add these environment secrets:

| Variable             | Required | Example                      | Notes                                   |
|----------------------|----------|------------------------------|-----------------------------------------|
| `WG_PRIVATE_KEY`     | yes      | contents of `claude.key`     | keep it only here, never in git         |
| `WG_PEER_PUBLIC_KEY` | yes      | server's public key          |                                         |
| `WG_PEER_ENDPOINT`   | yes      | `vpn.example.com:51820`      | must be reachable over UDP              |
| `WG_ADDRESS`         | yes      | `10.13.13.10/32`             | matches the server-side `AllowedIPs`    |
| `WG_ALLOWED_IPS`     | yes      | `192.168.7.42/32`            | comma-separated CIDRs; keep it narrow   |
| `WG_PRESHARED_KEY`   | no       |                              | if the server peer sets one             |
| `WG_MTU`             | no       | `1280`                       | default 1280                            |
| `WG_KEEPALIVE`       | no       | `25`                         | default 25s, keeps NAT mappings alive   |

## Behavior

- Secrets absent → hook prints one line and exits; nothing is installed or changed.
- Secrets present → tunnel comes up as `wg0`, routes are added for `WG_ALLOWED_IPS`,
  and the hook waits up to 15 s for a verified handshake, reporting either way.
- Any failure is reported but never blocks the session from starting.
- DNS is deliberately left untouched — use IP addresses (or public DNS names) for
  hosts behind the tunnel.

## Security notes

- Traffic to RFC1918 ranges bypasses the sandbox's HTTPS egress proxy, which is what
  allows tunnel traffic to flow — and also why `WG_ALLOWED_IPS` should list only the
  hosts Claude actually needs.
- Rotating the peer key: generate a new pair, update the server peer and the
  `WG_PRIVATE_KEY` secret. Revoking access is deleting the peer from the server.
