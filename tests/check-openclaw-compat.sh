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
#   3. openclaw's install.sh is still fetchable (we skip it, but good to know)
#   4. The install.sh still uses npm as its install method (not a custom binary)
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

NPM_META=$(curl -sf "https://registry.npmjs.org/openclaw/latest" 2>/dev/null) || true

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
        fail "No 'bin' field in package.json — npm install -g won't create a binary"
    else
        warn "bin field changed (no 'openclaw' key): $BIN_FIELD"
        warn "Our script calls 'openclaw onboard' — this may need updating"
        ERRORS=$((ERRORS + 1))
    fi
else
    fail "Skipped (npm metadata unavailable)"
fi

# ── 3. Check openclaw@beta (current primary) and @next as fallbacks ───

info "Checking npm registry for openclaw@beta (primary install tag)..."

BETA_META=$(curl -sf "https://registry.npmjs.org/openclaw/beta" 2>/dev/null) || true

if [[ -z "$BETA_META" ]]; then
    fail "openclaw@beta not found — our primary install tag is missing"
else
    BETA_VERSION=$(echo "$BETA_META" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
    pass "openclaw@beta exists (version: $BETA_VERSION)"
fi

info "Checking npm registry for openclaw@next (fallback tag)..."

NEXT_META=$(curl -sf "https://registry.npmjs.org/openclaw/next" 2>/dev/null) || true

if [[ -z "$NEXT_META" ]]; then
    warn "openclaw@next not found — fallback tag doesn't exist (non-fatal)"
else
    NEXT_VERSION=$(echo "$NEXT_META" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
    pass "openclaw@next exists (version: $NEXT_VERSION)"
fi

# ── 4. Check install.sh is still fetchable ────────────────────────────

info "Checking https://openclaw.ai/install.sh..."

INSTALL_HTTP=$(curl -sf -o /dev/null -w "%{http_code}" "https://openclaw.ai/install.sh" 2>/dev/null) || INSTALL_HTTP="000"

if [[ "$INSTALL_HTTP" == "200" ]]; then
    pass "install.sh is reachable (HTTP $INSTALL_HTTP)"
else
    warn "install.sh returned HTTP $INSTALL_HTTP (we don't use it, but notable)"
fi

# ── 5. Check install.sh still uses npm ────────────────────────────────

info "Checking install.sh still uses npm as install method..."

INSTALL_SCRIPT=$(curl -sf "https://openclaw.ai/install.sh" 2>/dev/null) || true

if [[ -n "$INSTALL_SCRIPT" ]]; then
    if echo "$INSTALL_SCRIPT" | grep -q "npm.*install.*-g"; then
        pass "install.sh still uses 'npm install -g' (our approach is compatible)"
    else
        warn "install.sh may have changed install method — 'npm install -g' not found"
        warn "Review: https://openclaw.ai/install.sh"
    fi

    # Check if they added a different binary name
    if echo "$INSTALL_SCRIPT" | grep -q "openclaw onboard\|openclaw doctor\|openclaw "; then
        pass "install.sh still references 'openclaw' command (binary name unchanged)"
    else
        warn "install.sh no longer references 'openclaw' command — binary may be renamed"
        ERRORS=$((ERRORS + 1))
    fi
else
    warn "Could not fetch install.sh for analysis"
fi

# ── 6. Check that onboard subcommand exists ───────────────────────────

info "Checking 'onboard' subcommand in package..."

if [[ -n "$NPM_META" ]]; then
    # Check if the readme or description mentions onboard
    PKG_DESC=$(echo "$NPM_META" | python3 -c "import sys,json; print(json.load(sys.stdin).get('description',''))" 2>/dev/null || echo "")

    # Check scripts field for onboard references
    HAS_ONBOARD=$(echo "$INSTALL_SCRIPT" | grep -c "onboard" 2>/dev/null || echo "0")

    if [[ "$HAS_ONBOARD" -gt 0 ]]; then
        pass "'onboard' subcommand still referenced in install.sh ($HAS_ONBOARD occurrences)"
    else
        warn "'onboard' not found in install.sh — subcommand may have been renamed"
    fi
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
