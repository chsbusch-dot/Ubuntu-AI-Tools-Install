# Infrastructure Notes

Last updated: 2026-07-28

## Servers

| Item | Status | Notes |
|---|---|---|
| IONOS VPS (Germany) | **Active** | Compute only — the IONOS domain/hosting products were cancelled, the VPS itself is intact. Planned/used as WireGuard exit node (`tools/wg-ionos-setup.sh`). |
| GoDaddy hosting | Cancelled | |
| IONOS (1&1) domain + hosting | Cancelled | Domains moved out; see below. |

## Domains

All domains are consolidated at **Porkbun** and **Cloudflare**, with one
exception currently at Dynadot.

| Domain | Registrar / DNS | Notes |
|---|---|---|
| mvp.sv | DNS on Cloudflare | Formerly at IONOS (1&1); points to Cloudflare as of July 2026. |
| cbus.ch | Dynadot | Moved to Dynadot as of July 2026. |
| (all others) | Porkbun / Cloudflare | Consolidated after the IONOS and GoDaddy cancellations. |

## Open items

- Private email domain search (see `tools/find_mx_coms.py`): 208 confirmed
  candidates as of 2026-07-28, all standard-price ($11.25/yr) — shortlist
  favourite: treemx.com. Not yet registered.
- WireGuard exit node on the IONOS VPS: installer ready
  (`tools/wg-ionos-setup.sh`), not yet deployed. UniFi side: VPN client +
  policy-based route for the two Fire TVs.
