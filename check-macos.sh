#!/bin/bash
#
# check-macos.sh — master validation runner for the macOS port.
#
# Runs, in order:
#   1. Bash syntax check on all macos-*.sh scripts
#   2. ShellCheck static analysis
#   3. plutil smoke-check on any sample .plist we ship
#   4. UMA-fit validation (validate-uma-fit.sh)
#   5. HuggingFace repo reachability (network — skipped by --quick)
#   6. Ollama model-tag reachability (network — skipped by --quick)
#
# Usage:
#   ./check-macos.sh              # full run (incl. network checks)
#   ./check-macos.sh --quick      # local-only (skip HF + Ollama probes)
#   ./check-macos.sh --install    # brew install shellcheck if missing
#
# Exit code is 0 iff every stage passed or was skipped intentionally.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/macos-prep-setup.sh"
RECONFIG_SCRIPT="$SCRIPT_DIR/macos-llama-reconfigure.sh"
UMA_FIT_SCRIPT="$SCRIPT_DIR/validate-uma-fit.sh"

QUICK_MODE=false
AUTO_INSTALL=false
TOTAL_ERRORS=0
TOTAL_WARNINGS=0
SCRIPT_START=$(date +%s)

for arg in "$@"; do
    case "$arg" in
        --quick)   QUICK_MODE=true ;;
        --install) AUTO_INSTALL=true ;;
        -h|--help)
            sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# //; s/^#//'
            exit 0 ;;
    esac
done

elapsed() {
    local secs=$(( $(date +%s) - SCRIPT_START ))
    printf "%dm%02ds" $(( secs / 60 )) $(( secs % 60 ))
}

# ─── Colors ────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'
    BLUE=$'\e[1;34m'; CYAN=$'\e[1;36m'; RESET=$'\e[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; RESET=""
fi

pass() { echo "  ${GREEN}✅ $1${RESET}"; }
fail() { echo "  ${RED}❌ $1${RESET}"; TOTAL_ERRORS=$((TOTAL_ERRORS + 1)); }
warn() { echo "  ${YELLOW}⚠️  $1${RESET}"; TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1)); }
header() { printf '\n%b\n' "${BLUE}=== $1 === [$(date '+%H:%M:%S') +$(elapsed)]${RESET}"; }

try_install() {
    local pkg="$1"
    [ "$AUTO_INSTALL" != true ] && return 1
    if command -v brew >/dev/null 2>&1; then
        echo "  Installing $pkg via brew…"
        brew install "$pkg" >/dev/null 2>&1 && return 0
    fi
    return 1
}

# ─── Banner ────────────────────────────────────────────────────────────
echo "${CYAN}╔═══════════════════════════════════════════════════╗${RESET}"
echo "${CYAN}║   macos-prep-setup.sh  —  Check Suite             ║${RESET}"
echo "${CYAN}╚═══════════════════════════════════════════════════╝${RESET}"
echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Mode:    $([ "$QUICK_MODE" = true ] && echo 'quick (local only)' || echo 'full (incl. network)')"

if [[ ! -f "$SETUP_SCRIPT" ]]; then
    fail "Cannot find macos-prep-setup.sh at $SETUP_SCRIPT"
    exit 1
fi

# ─── 1. Bash syntax ────────────────────────────────────────────────────
header "1. Bash Syntax Check"
for s in "$SETUP_SCRIPT" "$RECONFIG_SCRIPT" "$UMA_FIT_SCRIPT"; do
    [[ -f "$s" ]] || { warn "$(basename "$s") not found — skipping"; continue; }
    if bash -n "$s" 2>&1; then
        pass "$(basename "$s"): no syntax errors"
    else
        fail "$(basename "$s"): syntax errors"
    fi
done

# ─── 2. ShellCheck ─────────────────────────────────────────────────────
header "2. ShellCheck Static Analysis"
command -v shellcheck >/dev/null 2>&1 || try_install shellcheck || true

if command -v shellcheck >/dev/null 2>&1; then
    for s in "$SETUP_SCRIPT" "$RECONFIG_SCRIPT" "$UMA_FIT_SCRIPT"; do
        [[ -f "$s" ]] || continue
        sc_output=$(shellcheck -S warning "$s" 2>&1 || true)
        if [[ -z "$sc_output" ]]; then
            pass "$(basename "$s"): no warnings"
        else
            warning_count=$(echo "$sc_output" | grep -c "SC[0-9]" || true)
            fail "$(basename "$s"): $warning_count finding(s)"
            echo "$sc_output"
        fi
    done
else
    warn "shellcheck not installed — run with --install or: brew install shellcheck"
fi

# ─── 3. plutil sanity check ────────────────────────────────────────────
# macos-prep-setup.sh writes LaunchDaemon plists at runtime; we can't
# check those without running the installer. But if the repo ships any
# sample plists (e.g. under tests/fixtures) lint them here.
header "3. plutil Plist Lint"
if command -v plutil >/dev/null 2>&1; then
    plist_count=0
    while IFS= read -r -d '' p; do
        plist_count=$((plist_count + 1))
        if plutil -lint "$p" >/dev/null 2>&1; then
            pass "$(basename "$p"): valid"
        else
            fail "$(basename "$p"): plutil -lint failed"
        fi
    done < <(find "$SCRIPT_DIR" -name '*.plist' -print0 2>/dev/null)
    if [[ $plist_count -eq 0 ]]; then
        pass "no sample plists shipped — nothing to lint"
    fi
else
    warn "plutil not available (not macOS?) — skipping plist lint"
fi

# ─── 4. UMA fit validation ─────────────────────────────────────────────
header "4. UMA Fit Validation"
if [[ -x "$UMA_FIT_SCRIPT" ]]; then
    # Stream stdout live so the user sees each combo as it's checked,
    # but capture the exit code to roll up into our grand total.
    if SETUP_SCRIPT="$SETUP_SCRIPT" "$UMA_FIT_SCRIPT"; then
        pass "validate-uma-fit.sh: all tiers fit"
    else
        fail "validate-uma-fit.sh reported over-budget combinations"
    fi
else
    warn "validate-uma-fit.sh not found or not executable — skipping"
fi

# ─── 5. HuggingFace repo reachability (network) ────────────────────────
header "5. HuggingFace Repo Reachability"
if [[ "$QUICK_MODE" == true ]]; then
    warn "skipped (--quick)"
else
    if ! command -v curl >/dev/null 2>&1; then
        warn "curl not installed — skipping HF checks"
    else
        # Pull the unique HF repos from get_model_recommendations without
        # sourcing the whole setup script.
        eval "$(sed -n '/^get_model_recommendations() {/,/^}/p' "$SETUP_SCRIPT")"
        # macOS ships bash 3.2 (no associative arrays), so dedup via a
        # newline-delimited seen-string rather than `declare -A`.
        hf_seen=""
        hf_list=()
        for tier in 24 32 48 64 96 128; do
            get_model_recommendations llama "$tier"
            for m in "$REC_MODEL_CHAT" "$REC_MODEL_CODE" "$REC_MODEL_MOE" "$REC_MODEL_VISION"; do
                [[ -z "$m" || "$m" != */* ]] && continue
                if [[ $'\n'"$hf_seen"$'\n' != *$'\n'"$m"$'\n'* ]]; then
                    hf_seen="$hf_seen"$'\n'"$m"
                    hf_list+=("$m")
                fi
            done
        done

        hf_ok=0 hf_fail=0
        # bash 3.2: guard empty-array expansion against `set -u` unbound errors.
        auth_hdr=()
        [[ -n "${HF_TOKEN:-}" ]] && auth_hdr=(-H "Authorization: Bearer ${HF_TOKEN}")
        for repo in "${hf_list[@]}"; do
            status=$(curl -fsSL --max-time 15 -o /dev/null -w '%{http_code}' \
                ${auth_hdr[@]+"${auth_hdr[@]}"} "https://huggingface.co/api/models/$repo" 2>/dev/null || echo "000")
            if [[ "$status" == "200" ]]; then
                pass "$repo ($status)"
                hf_ok=$((hf_ok + 1))
            else
                fail "$repo (HTTP $status)"
                hf_fail=$((hf_fail + 1))
            fi
        done
        echo "    ${hf_ok}/${#hf_list[@]} reachable, ${hf_fail} failed"
    fi
fi

# ─── 6. Ollama tag reachability (network) ──────────────────────────────
header "6. Ollama Tag Reachability"
if [[ "$QUICK_MODE" == true ]]; then
    warn "skipped (--quick)"
else
    if ! command -v curl >/dev/null 2>&1; then
        warn "curl not installed — skipping Ollama checks"
    else
        ol_seen=""
        ol_list=()
        for tier in 24 32 48 64 96 128; do
            get_model_recommendations ollama "$tier"
            for m in "$REC_MODEL_CHAT" "$REC_MODEL_CODE" "$REC_MODEL_MOE" "$REC_MODEL_VISION"; do
                [[ -z "$m" || "$m" == */* ]] && continue
                if [[ $'\n'"$ol_seen"$'\n' != *$'\n'"$m"$'\n'* ]]; then
                    ol_seen="$ol_seen"$'\n'"$m"
                    ol_list+=("$m")
                fi
            done
        done

        ol_ok=0 ol_fail=0
        for tag in "${ol_list[@]}"; do
            # Ollama exposes an HTML library page per tag — 200 means the tag
            # exists. The JSON API (/api/tags) is local-only, so HTML is all
            # we can probe from outside the daemon.
            name="${tag%%:*}"
            variant="${tag#*:}"
            [[ "$variant" == "$tag" ]] && variant=""
            url="https://ollama.com/library/$name"
            [[ -n "$variant" ]] && url="$url:$variant"
            status=$(curl -fsSL --max-time 15 -o /dev/null -w '%{http_code}' \
                "$url" 2>/dev/null || echo "000")
            if [[ "$status" == "200" ]]; then
                pass "$tag ($status)"
                ol_ok=$((ol_ok + 1))
            else
                fail "$tag (HTTP $status)"
                ol_fail=$((ol_fail + 1))
            fi
        done
        echo "    ${ol_ok}/${#ol_list[@]} reachable, ${ol_fail} failed"
    fi
fi

# ─── Summary ───────────────────────────────────────────────────────────
echo
echo "${BLUE}══════════════════════════════════════════════════════${RESET}"
echo "  Finished: $(date '+%Y-%m-%d %H:%M:%S')  (elapsed $(elapsed))"
if [[ $TOTAL_ERRORS -eq 0 && $TOTAL_WARNINGS -eq 0 ]]; then
    echo "  ${GREEN}✅ All checks passed${RESET}"
    exit 0
elif [[ $TOTAL_ERRORS -eq 0 ]]; then
    echo "  ${YELLOW}⚠️  ${TOTAL_WARNINGS} warning(s), 0 errors${RESET}"
    exit 0
else
    echo "  ${RED}❌ ${TOTAL_ERRORS} error(s), ${TOTAL_WARNINGS} warning(s)${RESET}"
    exit 1
fi
