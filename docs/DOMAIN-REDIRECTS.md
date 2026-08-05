# Canonical Domain Consolidation

Last updated: 2026-08-05

## Decision

Canonical domain: **christianbusch.de**

All other domains 301-redirect to it:

| Source domain | Destination | Status |
|---|---|---|
| christianbusch.org | https://christianbusch.de | 301 |
| christianbusch.info | https://christianbusch.de | 301 |
| christianbusch.us | https://christianbusch.de | 301 |
| christianbusch.net | https://christianbusch.de | 301 |
| cbus.ch | https://christianbusch.de | 301 |

Note: per `docs/INFRASTRUCTURE.md`, DNS for these domains is consolidated on
**Cloudflare** (`cbus.ch` stays at Dynadot for registration, but can still
proxy through Cloudflare for redirects). There is no Apache/nginx origin
server behind them, so the `.htaccess`/nginx snippets below are reference
implementations for if/when a domain is pointed at an Apache or nginx origin
directly. The redirect that is actually actionable today is the **Cloudflare
Bulk Redirects** config at the bottom of this doc.

## .htaccess (Apache)

Place this at the document root of each source domain:

```apacheconf
RewriteEngine On
RewriteCond %{HTTPS} off
RewriteRule ^(.*)$ https://christianbusch.de/$1 [R=301,L]

RewriteCond %{HTTPS} on
RewriteRule ^(.*)$ https://christianbusch.de/$1 [R=301,L]
```

## nginx

Add a `server` block per source domain:

```nginx
server {
    listen 80;
    listen 443 ssl;
    server_name christianbusch.org www.christianbusch.org
                christianbusch.info www.christianbusch.info
                christianbusch.us www.christianbusch.us
                christianbusch.net www.christianbusch.net
                cbus.ch www.cbus.ch;

    # ssl_certificate / ssl_certificate_key as needed per domain

    return 301 https://christianbusch.de$request_uri;
}
```

## Cloudflare Bulk Redirects (actual current infra)

Since DNS is proxied through Cloudflare, the redirect is best implemented as
a **Bulk Redirect List** applied to each source domain's zone:

1. Cloudflare dashboard → **Rules → Redirect Rules → Bulk Redirects**.
2. Create a list, e.g. `canonical-domain-redirects`.
3. Add one entry per source domain:
   - Source URL: `christianbusch.org/*` (repeat for each source domain)
   - Target URL: `https://christianbusch.de/$1`
   - Status code: `301`
   - Preserve query string: enabled
4. Attach the Bulk Redirect rule to each source domain's zone.
5. Confirm each source domain has an active Cloudflare proxy (orange-cloud)
   A/AAAA record so the redirect rule can intercept the request before DNS
   resolves to any origin.

## Person schema: sameAs

On the canonical site (christianbusch.de), add a `sameAs` array to the
`Person` JSON-LD block so search engines associate the redirected domains
and external profiles with the same entity:

```json
{
  "@context": "https://schema.org",
  "@type": "Person",
  "name": "Christian Busch",
  "url": "https://christianbusch.de",
  "sameAs": [
    "https://christianbusch.org",
    "https://christianbusch.info",
    "https://christianbusch.us",
    "https://christianbusch.net",
    "https://cbus.ch",
    "https://www.linkedin.com/in/cbusch",
    "https://github.com/chsbusch-dot"
  ]
}
```

Note: the canonical URL itself (christianbusch.de) belongs in the `url`
property, not repeated inside `sameAs` — `sameAs` is for the *other*
profiles/domains that represent the same entity, which is why it isn't
listed twice here.

## Follow-up

- Verify SSL/TLS is issued for every source domain (Cloudflare Universal SSL
  or per-domain certs) before flipping redirects live, otherwise browsers
  will hit certificate errors on HTTPS requests.
- After redirects are live, submit a change-of-address / 301 verification in
  Google Search Console for each source domain pointing at
  christianbusch.de.
- Add the `Person` JSON-LD block above (with `sameAs`) to the christianbusch.de
  site's `<head>` once the site codebase is available to this repo — no
  website source exists in this repo to place it in directly.
