#!/bin/bash
#
# check-openclaw-compat.sh — Verify our direct npm install approach still works
#
# Checks that the openclaw npm package is available and its binary entry point
# hasn't changed in a way that would break our "npm install -g openclaw" approach
# in ubuntu-prep-setup.sh.
#
# What it tests:
#   1. openclaw@latest exists on the npm registry
#   2. The package.json "bin" field maps "openclaw" to a known entry point
#   3. openclaw@beta exists (our primary install tag)
#   4. openclaw.ai/install.sh is reachable and still references 'onboard'
#
# NOT checked (intentionally):
#   - Whether install.sh uses npm (we bypass their installer; irrelevant)
#   - openclaw@next (that tag has never existed; removed to avoid noise)
#
# Usage:
#   ./tests/check-openclaw-compat.sh           # run all checks
#   ./tests/check-openclaw-compat.sh --quiet   # exit code only
#
# Exit codes:
#   0 = all checks passed
#   1 = one or more checks failed (our install approach may be broken)
#

set -euo pipefail

QUIET=false
ERRORS=0

for arg in "$@"; do
    [[ "$arg" == "--quiet" ]] && QUIET=true
done

info()  { $QUIET || echo -e "\e[1;36mINFO\e[0m  $*"; }
pass()  { $QUIET || echo -e "\e[1;32m  ✅\e[0m  $*"; }
fail()  { echo -e "\e[1;31m  ❌\e[0m  $*"; ERRORS=$((ERRORS + 1)); }
warn()  { $QUIET || echo -e "\e[1;33m  ⚠️\e[0m  $*"; }

# ── 1. Check npm registry for openclaw@latest ────────────────────────

info "Checking npm registry for openclaw@latest..."

NPM_META=$(curl -sf --max-time 15 "https://registry.npmjs.org/openclaw/latest" 2>/dev/null) || true

if [[ -z "$NPM_META" ]]; then
    fail "openclaw@latest not found on npm registry"
else
    PKG_VERSION=$(echo "$NPM_META" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
    pass "openclaw@latest exists on npm (version: $PKG_VERSION)"
fi

# ── 2. Check bin field in package.json ────────────────────────────────

info "Checking package.json bin field..."

if [[ -n "$NPM_META" ]]; then
    BIN_FIELD=$(echo "$NPM_META" | python3 -c "
import sys, json
d = json.load(sys.stdin)
b = d.get('bin', {})
if isinstance(b, str):
    print(f'default={b}')
elif isinstance(b, dict):
    for k,v in b.items():
        print(f'{k}={v}')
else:
    print('NONE')
" 2>/dev/null || echo "PARSE_ERROR")

    if echo "$BIN_FIELD" | grep -q "^openclaw="; then
        BIN_TARGET=$(echo "$BIN_FIELD" | grep "^openclaw=" | cut -d= -f2)
        pass "bin.openclaw -> $BIN_TARGET"
    elif [[ "$BIN_FIELD" == "NONE" || "$BIN_FIELD" == "PARSE_ERROR" ]]; then
        fail "No 'openclaw' bin entry in package.json — npm install -g won't create the binary"
    else
        warn "bin field changed (no 'openclaw' key): $BIN_FIELD"
        warn "Our script calls 'openclaw onboard' — this may need updating"
        ERRORS=$((ERRORS + 1))
    fi
else
    fail "Skipped (npm metadata unavailable)"
fi

# ── 3. Check openclaw@beta exists (our primary install tag) ───────────

info "Checking npm registry for openclaw@beta (primary install tag)..."

BETA_META=$(curl -sf --max-time 15 "https://registry.npmjs.org/openclaw/beta" 2>/dev/null) || true

if [[ -z "$BETA_META" ]]; then
    fail "openclaw@beta not found — our primary install tag is missing"
else
    BETA_VERSION=$(echo "$BETA_META" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
    pass "openclaw@beta exists (version: $BETA_VERSION)"
fi

# ── 4. Check install.sh reachability and 'onboard' subcommand ────────
#
# We fetch install.sh ONCE into a temp file to avoid double-request flakiness.
# We don't check whether it uses npm (their installer changed from npm to pnpm
# internally, but we bypass their installer and call npm directly, so it doesn't
# matter). We only care that:
#   a) the site is up
#   b) the 'onboard' subcommand hasn't been renamed

info "Fetching https://openclaw.ai/install.sh..."

_INSTALL_TMP=$(mktemp)
trap 'rm -f "$_INSTALL_TMP"' EXIT

_INSTALL_HTTP=$(curl -sf --max-time 20 -o "$_INSTALL_TMP" -w "%{http_code}" \
    "https://openclaw.ai/install.sh" 2>/dev/null) || _INSTALL_HTTP="000"

if [[ "$_INSTALL_HTTP" == "200" ]]; then
    pass "install.sh is reachable (HTTP 200)"

    ONBOARD_COUNT=$(grep -c "onboard" "$_INSTALL_TMP" 2>/dev/null || echo "0")
    if [[ "$ONBOARD_COUNT" -gt 0 ]]; then
        pass "'onboard' subcommand still referenced in install.sh ($ONBOARD_COUNT occurrences)"
    else
        warn "'onboard' not found in install.sh — subcommand may have been renamed"
        warn "Review: https://openclaw.ai/install.sh"
        ERRORS=$((ERRORS + 1))
    fi
else
    warn "install.sh returned HTTP $_INSTALL_HTTP (non-fatal — we don't use their installer)"
fi

# ── Summary ───────────────────────────────────────────────────────────

echo ""
if [[ $ERRORS -eq 0 ]]; then
    info "\e[1;32mAll checks passed.\e[0m Our direct npm install approach is still compatible."
    exit 0
else
    info "\e[1;31m$ERRORS check(s) failed.\e[0m The openclaw package may have changed."
    info "Review the warnings above and update install_openclaw() in ubuntu-prep-setup.sh."
    exit 1
fi
