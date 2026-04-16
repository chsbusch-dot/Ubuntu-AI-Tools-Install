#!/bin/bash
#
# test.sh — Complete test suite for ubuntu-prep-setup.sh
#
# Runs all validations in order:
#   1. Bash syntax check
#   2. ShellCheck static analysis
#   3. shfmt formatting consistency
#   4. VRAM fit validation (model weights + KV cache + runtime overhead)
#   5. Repair helper logic validation
#   6. Bats unit tests (tests/*.bats)
#   7. Kcov coverage (opt-in via --coverage)
#   8. Ollama model name validation (network)
#   9. HuggingFace repo validation (network)
#  10. OpenClaw npm package compatibility (network)
#
# Usage:
#   ./test.sh              # Full run (includes network checks)
#   ./test.sh --quick      # Local-only (skip network checks)
#   ./test.sh --install    # Auto-install shellcheck / shfmt / bats / kcov if missing
#   ./test.sh --coverage   # Also run kcov coverage on bats tests
#
# Remote usage:
#   scp test.sh ubuntu-prep-setup.sh user@host:/tmp/
#   ssh user@host "cd /tmp && bash test.sh"
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/ubuntu-prep-setup.sh"
QUICK_MODE=false
AUTO_INSTALL=false
RUN_COVERAGE=false
TOTAL_ERRORS=0
TOTAL_WARNINGS=0
SCRIPT_START=$(date +%s)

# Print elapsed time since script start
elapsed() {
    local secs=$(( $(date +%s) - SCRIPT_START ))
    printf "%dm%02ds" $(( secs / 60 )) $(( secs % 60 ))
}

# ── Heartbeat: print a dot every 5 s so the user knows we're alive ───────────
# Start before a slow blocking operation, stop after.
_HEARTBEAT_PID=""
start_heartbeat() {
    local msg="${1:-  ⏳ working}"
    printf "%s" "$msg"
    ( while true; do sleep 5; printf "."; done ) &
    _HEARTBEAT_PID=$!
}
stop_heartbeat() {
    if [[ -n "$_HEARTBEAT_PID" ]]; then
        kill "$_HEARTBEAT_PID" 2>/dev/null || true
        wait "$_HEARTBEAT_PID" 2>/dev/null || true
        _HEARTBEAT_PID=""
    fi
    echo  # newline after the dots
}
# Clean up heartbeat if the script exits unexpectedly
trap 'stop_heartbeat 2>/dev/null; exit' EXIT INT TERM

for arg in "$@"; do
    case "$arg" in
        --quick) QUICK_MODE=true ;;
        --install) AUTO_INSTALL=true ;;
        --coverage) RUN_COVERAGE=true ;;
    esac
done

# Install a tool via apt or brew when --install is given
try_install() {
    local pkg="$1"
    [ "$AUTO_INSTALL" != true ] && return 1
    echo "  Installing $pkg..."
    if command -v apt-get &>/dev/null; then
        # Check for dpkg lock before attempting install — unattended-upgrades
        # can hold it for 10-30 min and apt-get will hang silently.
        if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
            echo "  ⚠️  dpkg lock is held (unattended-upgrades running)."
            echo "     Wait for it to finish, then re-run with --install."
            echo "     Or: sudo systemctl stop unattended-upgrades"
            return 1
        fi
        start_heartbeat "  ⏳ apt-get install $pkg"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -yqq "$pkg"
        stop_heartbeat
    elif command -v brew &>/dev/null; then
        brew install "$pkg" 2>/dev/null
    else
        return 1
    fi
}

extract_function() {
    local fn_name="$1"
    sed -n "/^${fn_name}() {/,/^}/p" "$SETUP_SCRIPT"
}

# ─── Colors (disable if not a terminal) ──────────────────────────
if [ -t 1 ]; then
    RED='\e[1;31m'
    GREEN='\e[1;32m'
    YELLOW='\e[1;33m'
    BLUE='\e[1;34m'
    CYAN='\e[1;36m'
    RESET='\e[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    RESET=''
fi

pass() { echo -e "  ${GREEN}✅ $1${RESET}"; }
fail() {
    echo -e "  ${RED}❌ $1${RESET}"
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
}
warn() {
    echo -e "  ${YELLOW}⚠️  $1${RESET}"
    TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
}
# Header shows section name + wall-clock time so a stall is immediately visible
header() { echo -e "\n${BLUE}=== $1 === [$(date '+%H:%M:%S') +$(elapsed)]${RESET}"; }

echo -e "${CYAN}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║   ubuntu-prep-setup.sh  —  Test Suite             ║${RESET}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════╝${RESET}"
echo -e "  Started: $(date '+%Y-%m-%d %H:%M:%S')"

if [ ! -f "$SETUP_SCRIPT" ]; then
    fail "Cannot find ubuntu-prep-setup.sh at $SETUP_SCRIPT"
    exit 1
fi

# ─── 1. Bash Syntax Check ────────────────────────────────────────
header "1. Bash Syntax Check"
if bash -n "$SETUP_SCRIPT" 2>&1; then
    pass "No syntax errors"
else
    fail "Syntax errors found"
fi

# ─── 2. ShellCheck Static Analysis ───────────────────────────────
header "2. ShellCheck Static Analysis"
command -v shellcheck &>/dev/null || try_install shellcheck || true

if command -v shellcheck &>/dev/null; then
    sc_output=$(shellcheck -S warning "$SETUP_SCRIPT" 2>&1 || true)
    if [ -z "$sc_output" ]; then
        pass "No shellcheck warnings"
    else
        warning_count=$(echo "$sc_output" | grep -c "SC[0-9]" || true)
        fail "$warning_count shellcheck finding(s)"
        echo "$sc_output"
    fi
else
    warn "shellcheck not installed — run with --install or: sudo apt install shellcheck"
fi

# ─── 3. shfmt Formatting Consistency ─────────────────────────────
header "3. shfmt Formatting Consistency"
command -v shfmt &>/dev/null || try_install shfmt || true

if command -v shfmt &>/dev/null; then
    # -i 4 : 4-space indent, -ci : indent switch cases, -d : diff mode
    shfmt_output=$(shfmt -i 4 -ci -d "$SETUP_SCRIPT" 2>&1 || true)
    if [ -z "$shfmt_output" ]; then
        pass "Formatting is consistent (shfmt -i 4 -ci)"
    else
        diff_lines=$(echo "$shfmt_output" | wc -l | awk '{print $1}')
        warn "shfmt reports formatting drift ($diff_lines diff lines — run: shfmt -i 4 -ci -w ubuntu-prep-setup.sh)"
    fi
else
    warn "shfmt not installed — run with --install or: sudo apt install shfmt"
fi

# ─── 4. VRAM Fit Validation ──────────────────────────────────────
header "4. VRAM Fit Validation"

# Extract the function from the setup script
eval "$(sed -n '/^get_model_recommendations() {/,/^}/p' "$SETUP_SCRIPT")"

# Model size lookup: returns "weight_gb" for Q4_K_M weights.
# KV cache is computed dynamically using the same heuristic as the setup script
# (cache_type_bytes + estimate_vram_usage) at each tier's default context/cache.
get_model_weight() {
    local model="$1"
    case "$model" in
        # --- Ollama models ---
        "gemma4:e4b") echo "5" ;;
        "gemma4:e2b") echo "3" ;;
        "gemma4:26b") echo "17" ;;
        "gemma4:31b") echo "18" ;;
        "gemma3:4b") echo "3" ;;
        "gemma3:12b") echo "7" ;;
        "gemma3:27b") echo "17" ;;
        "qwen2.5:7b") echo "5" ;;
        "qwen2.5:14b") echo "9" ;;
        "qwen2.5:32b") echo "20" ;;
        "qwen2.5:72b") echo "47" ;;
        "qwen2.5-coder:3b") echo "2" ;;
        "qwen2.5-coder:7b") echo "5" ;;
        "qwen2.5-coder:14b") echo "9" ;;
        "qwen2.5-coder:32b") echo "20" ;;
        "mixtral:8x7b") echo "26" ;;
        "mixtral:8x22b") echo "86" ;;
        "command-r-plus") echo "63" ;;
        "command-r-plus:104b") echo "63" ;;
        "llama3.1:8b") echo "5" ;;
        "llama3.3:70b") echo "43" ;;
        "llava:7b") echo "5" ;;
        "llava:13b") echo "8" ;;
        "llava:34b") echo "20" ;;
        "minicpm-v") echo "5" ;;
        "qwen2.5vl:3b") echo "2" ;;
        "qwen2.5vl:7b") echo "5" ;;
        "qwen2.5vl:32b") echo "20" ;;
        "qwen2.5vl:72b") echo "47" ;;
        "deepseek-r1:14b") echo "9" ;;
        "deepseek-r1:32b") echo "20" ;;
        "deepseek-r1:70b") echo "43" ;;
        "devstral:24b") echo "14" ;;
        "mistral-small:24b") echo "14" ;;
        "mistral-nemo") echo "7" ;;
        "phi4:14b") echo "9" ;;
        # --- HuggingFace GGUF repos ---
        "unsloth/gemma-4-E4B-it-GGUF") echo "5" ;;
        "unsloth/gemma-4-E2B-it-GGUF") echo "3" ;;
        "unsloth/gemma-4-26B-A4B-it-GGUF") echo "17" ;;
        "unsloth/gemma-4-31B-it-GGUF") echo "18" ;;
        "bartowski/Qwen2.5-7B-Instruct-GGUF") echo "5" ;;
        "bartowski/Qwen2.5-14B-Instruct-GGUF") echo "9" ;;
        "bartowski/Qwen2.5-32B-Instruct-GGUF") echo "20" ;;
        "bartowski/Qwen2.5-72B-Instruct-GGUF") echo "47" ;;
        "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF") echo "5" ;;
        "bartowski/Qwen2.5-Coder-14B-Instruct-GGUF") echo "9" ;;
        "bartowski/Qwen2.5-Coder-32B-Instruct-GGUF") echo "20" ;;
        "bartowski/Llama-3.3-70B-Instruct-GGUF") echo "43" ;;
        "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF") echo "5" ;;
        "TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF") echo "26" ;;
        "MaziyarPanahi/Mixtral-8x22B-v0.1-GGUF") echo "86" ;;
        "bartowski/c4ai-command-r-plus-08-2024-GGUF") echo "63" ;;
        "cjpais/llava-1.6-mistral-7b-gguf") echo "4" ;;
        "cjpais/llava-v1.6-vicuna-13b-gguf") echo "8" ;;
        "cjpais/llava-v1.6-34B-gguf") echo "20" ;;
        "unsloth/Qwen2.5-VL-7B-Instruct-GGUF") echo "5" ;;
        "unsloth/Qwen2.5-VL-32B-Instruct-GGUF") echo "20" ;;
        "unsloth/Qwen2.5-VL-72B-Instruct-GGUF") echo "47" ;;
        "unsloth/DeepSeek-R1-Distill-Qwen-14B-GGUF") echo "9" ;;
        "unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF") echo "20" ;;
        "bartowski/DeepSeek-R1-Distill-Llama-70B-GGUF") echo "43" ;;
        "unsloth/Devstral-Small-2505-GGUF") echo "14" ;;
        "unsloth/Mistral-Small-3.1-24B-Instruct-2503-GGUF") echo "14" ;;
        "bartowski/Mistral-Nemo-Instruct-2407-GGUF") echo "7" ;;
        "MaziyarPanahi/phi-4-GGUF") echo "9" ;;
        *) echo "0" ;;
    esac
}

# Same heuristic as the setup script's estimate_vram_usage():
# KV cache ≈ ctx_size/1024 * bytes_per/2.0 * sqrt(model_gb/7.0) * 0.10
# Uses sqrt scaling because KV cache grows sublinearly with model size (GQA, MoE).
compute_kv_gb() {
    local model_gb="$1" ctx_size="$2" cache_bytes="$3"
    awk "BEGIN { printf \"%.1f\", ($ctx_size / 1024.0) * ($cache_bytes / 2.0) * sqrt($model_gb / 7.0) * 0.10 }"
}

# Minimum guaranteed context: 65536 tokens at q4_0 (0.5 bytes/element).
# Higher tier defaults (81K, 128K, 256K) are user-tunable via the VRAM estimator.
CTX_FLOOR=65536
CACHE_BYTES_Q4=0.5

RUNTIME_OVERHEAD=0.5
VRAM_ERRORS=0
VRAM_WARNINGS=0
VRAM_CHECKS=0

for backend in ollama llama; do
    label="Ollama"
    [ "$backend" = "llama" ] && label="llama.cpp"

    for vram in 8 16 24 32 48 72 96; do
        get_model_recommendations "$backend" "$vram"

        for pair in "CHAT:$REC_MODEL_CHAT" "CODE:$REC_MODEL_CODE" "MOE:$REC_MODEL_MOE" "VISION:$REC_MODEL_VISION"; do
            category="${pair%%:*}"
            model="${pair#*:}"
            [ -z "$model" ] && continue
            VRAM_CHECKS=$((VRAM_CHECKS + 1))

            weight_gb=$(get_model_weight "$model")

            if [ "$weight_gb" = "0" ]; then
                warn "${label} ${vram}GB ${category}: $model — size unknown (add to lookup)"
                VRAM_WARNINGS=$((VRAM_WARNINGS + 1))
                continue
            fi

            kv_gb=$(compute_kv_gb "$weight_gb" "$CTX_FLOOR" "$CACHE_BYTES_Q4")
            needed=$(echo "$weight_gb $kv_gb $RUNTIME_OVERHEAD" | awk '{printf "%.1f", $1 + $2 + $3}')
            fits=$(echo "$needed $vram" | awk '{print ($1 <= $2) ? "yes" : "no"}')

            if [ "$fits" = "no" ]; then
                fail "${label} ${vram}GB ${category}: $model — needs ~${needed}GB (wt:${weight_gb}+kv:${kv_gb}+rt:${RUNTIME_OVERHEAD}) > ${vram}GB [ctx=${CTX_FLOOR} q4_0]"
                VRAM_ERRORS=$((VRAM_ERRORS + 1))
            fi
        done
    done
done

if [ $VRAM_ERRORS -eq 0 ] && [ $VRAM_WARNINGS -eq 0 ]; then
    pass "All $VRAM_CHECKS model/tier combinations fit (weights + KV@q4_0 + ${RUNTIME_OVERHEAD}GB runtime)"
elif [ $VRAM_ERRORS -eq 0 ]; then
    warn "$VRAM_WARNINGS model(s) have unknown sizes ($VRAM_CHECKS checked)"
fi

# ─── 5. Repair Helper Logic ──────────────────────────────────────
header "5. Repair Helper Logic"

derive_status_src=$(extract_function derive_component_status)
derive_action_src=$(extract_function derive_component_action)
llama_requires_src=$(extract_function llama_requires_model_selection)
llama_launch_src=$(extract_function llama_should_launch_server)
llama_args_src=$(extract_function build_llama_hf_args)

if [ -z "$derive_status_src" ] || [ -z "$derive_action_src" ] || [ -z "$llama_requires_src" ] || [ -z "$llama_launch_src" ] || [ -z "$llama_args_src" ]; then
    fail "Could not extract repair/model helper functions from ubuntu-prep-setup.sh"
else
    eval "$derive_status_src"
    eval "$derive_action_src"
    eval "$llama_requires_src"
    eval "$llama_launch_src"
    eval "$llama_args_src"

    [ "$(derive_component_status true false true)" = "installed" ] &&
        pass "derive_component_status marks healthy full installs as installed" ||
        fail "derive_component_status should return 'installed' for healthy full installs"

    [ "$(derive_component_status true true false)" = "broken" ] &&
        pass "derive_component_status marks unhealthy installs as broken" ||
        fail "derive_component_status should return 'broken' for unhealthy full installs"

    [ "$(derive_component_status false true true)" = "broken" ] &&
        pass "derive_component_status marks partial installs as broken" ||
        fail "derive_component_status should return 'broken' for partial installs"

    [ "$(derive_component_status false false true)" = "missing" ] &&
        pass "derive_component_status marks empty state as missing" ||
        fail "derive_component_status should return 'missing' when nothing is present"

    [ "$(derive_component_action missing 1)" = "install" ] &&
        pass "derive_component_action maps selected missing components to install" ||
        fail "derive_component_action should return 'install' for selected missing components"

    [ "$(derive_component_action installed 1)" = "repair" ] &&
        pass "derive_component_action maps selected installed components to repair" ||
        fail "derive_component_action should return 'repair' for selected installed components"

    [ "$(derive_component_action broken 1)" = "repair" ] &&
        pass "derive_component_action maps selected broken components to repair" ||
        fail "derive_component_action should return 'repair' for selected broken components"

    [ "$(derive_component_action installed 0)" = "skip" ] &&
        pass "derive_component_action skips unselected components" ||
        fail "derive_component_action should return 'skip' for unselected components"

    LLAMA_COMPONENT_ACTION="install"
    RUN_LLAMA_BENCH="y"
    LOAD_DEFAULT_MODEL="n"
    INSTALL_LLAMA_SERVICE="n"
    EXPOSE_LLM_ENGINE="n"
    FRONTEND_BACKEND_TARGET=""
    OPENWEBUI_COMPONENT_ACTION="skip"
    LIBRECHAT_COMPONENT_ACTION="skip"
    if llama_requires_model_selection; then
        pass "llama_requires_model_selection forces a model when benchmarking"
    else
        fail "llama_requires_model_selection should require a model for llama-bench"
    fi

    LLM_DEFAULT_MODEL_CHOICE="5"
    if llama_should_launch_server; then
        fail "llama_should_launch_server should not launch on benchmark-only selections"
    else
        pass "llama_should_launch_server stays off for benchmark-only runs"
    fi

    INSTALL_LLAMA_SERVICE="y"
    if llama_should_launch_server; then
        pass "llama_should_launch_server launches when llama.cpp service is selected"
    else
        fail "llama_should_launch_server should launch when the llama.cpp service is selected"
    fi

    LLM_DEFAULT_MODEL_CHOICE="6"
    LLAMACPP_MODEL_REPO="org/repo:model.gguf"
    [ "$(build_llama_hf_args)" = "--hf-repo org/repo --hf-file model.gguf" ] &&
        pass "build_llama_hf_args parses custom repo:file selections" ||
        fail "build_llama_hf_args should split custom repo:file input into --hf-repo/--hf-file"
fi

# ─── 5b. OpenClaw & Settings Logic ──────────────────────────────
header "5b. OpenClaw & Settings Logic"

# --- 5b-i: .env.secrets → .openclaw/.env pipeline ---
# Simulates the filtering + ANTHROPIC_API_KEY alias logic
# that runs before the `su` call in install_openclaw().
mock_secrets=$(
    cat <<'MOCK'
export OPENAI_API_KEY=sk-openai-real
export CLAUDE_API_KEY=sk-ant-real
export EMPTY_KEY=""
export ANOTHER_EMPTY=''
export PARTIAL_KEY=
export HF_TOKEN=hf_real
export NOT_A_KEY=should-be-excluded
MOCK
)

env_content=$(printf '%s\n' "$mock_secrets" \
    | grep -E '^export [A-Z_]*(API_KEY|TOKEN)[^=]*=' \
    | sed 's/^export //' \
    | grep -v '=""$' \
    | grep -v "=''$" \
    | grep -vE '=[[:space:]]*$' \
    || true)

# Inject ANTHROPIC_API_KEY alias (mirrors the script logic)
if [[ "$env_content" == *'CLAUDE_API_KEY='* ]] && \
   [[ "$env_content" != *'ANTHROPIC_API_KEY='* ]]; then
    _cv=$(printf '%s\n' "$env_content" | grep '^CLAUDE_API_KEY=' | head -1 | cut -d'=' -f2-)
    env_content="${env_content}"$'\n'"ANTHROPIC_API_KEY=${_cv}"
fi

[[ "$env_content" != *'EMPTY_KEY='* ]] &&
    pass "env filter: empty double-quoted KEY=\"\" stripped" ||
    fail "env filter: KEY=\"\" was not filtered"

[[ "$env_content" != *'ANOTHER_EMPTY='* ]] &&
    pass "env filter: empty single-quoted KEY='' stripped" ||
    fail "env filter: KEY='' was not filtered"

[[ "$env_content" != *'PARTIAL_KEY'* ]] &&
    pass "env filter: no-value KEY= stripped" ||
    fail "env filter: KEY= was not filtered"

[[ "$env_content" != *'NOT_A_KEY='* ]] &&
    pass "env filter: non-API_KEY/TOKEN keys excluded" ||
    fail "env filter: unrelated key leaked into .env"

[[ "$env_content" == *'OPENAI_API_KEY=sk-openai-real'* ]] &&
    pass "env filter: non-empty API keys preserved" ||
    fail "env filter: real API key was incorrectly stripped"

[[ "$env_content" == *'HF_TOKEN=hf_real'* ]] &&
    pass "env filter: HF_TOKEN preserved" ||
    fail "env filter: HF_TOKEN was incorrectly stripped"

[[ "$env_content" == *'ANTHROPIC_API_KEY=sk-ant-real'* ]] &&
    pass "env filter: ANTHROPIC_API_KEY alias auto-created from CLAUDE_API_KEY" ||
    fail "env filter: ANTHROPIC_API_KEY alias missing when only CLAUDE_API_KEY present"

# Alias should NOT be added a second time if ANTHROPIC_API_KEY already exists
env_content2=$(printf '%s\n' "$mock_secrets" \
    | sed 's/CLAUDE_API_KEY/ANTHROPIC_API_KEY/' \
    | grep -E '^export [A-Z_]*(API_KEY|TOKEN)[^=]*=' \
    | sed 's/^export //' \
    | grep -v '=""$' \
    | grep -vE '=[[:space:]]*$' \
    || true)
alias_count=$(printf '%s\n' "$env_content2" | grep -c 'ANTHROPIC_API_KEY=' || true)
[ "$alias_count" -le 1 ] &&
    pass "env filter: ANTHROPIC_API_KEY not duplicated when already present" ||
    fail "env filter: ANTHROPIC_API_KEY was added a second time"

# --- 5b-ii: OpenClaw jq security filter ---
if command -v jq &>/dev/null; then
    mock_oc_json='{"gateway":{"bind":"0.0.0.0","port":8082,"controlUi":{"enabled":true}}}'
    jq_sec_filter='.gateway.controlUi.allowInsecureAuth = false
        | .gateway.auth.rateLimit = {"maxAttempts":10,"windowMs":60000,"lockoutMs":300000}'
    jq_result=$(echo "$mock_oc_json" | jq "$jq_sec_filter" 2>/dev/null || true)

    [ "$(echo "$jq_result" | jq -r '.gateway.controlUi.allowInsecureAuth' 2>/dev/null)" = "false" ] &&
        pass "openclaw jq: allowInsecureAuth set to false for LAN bind" ||
        fail "openclaw jq: allowInsecureAuth not set correctly"

    [ "$(echo "$jq_result" | jq -r '.gateway.auth.rateLimit.maxAttempts' 2>/dev/null)" = "10" ] &&
        pass "openclaw jq: auth.rateLimit.maxAttempts = 10" ||
        fail "openclaw jq: auth.rateLimit.maxAttempts not set"

    [ "$(echo "$jq_result" | jq -r '.gateway.auth.rateLimit.windowMs' 2>/dev/null)" = "60000" ] &&
        pass "openclaw jq: auth.rateLimit.windowMs = 60000 (1 min)" ||
        fail "openclaw jq: auth.rateLimit.windowMs not set"

    [ "$(echo "$jq_result" | jq -r '.gateway.auth.rateLimit.lockoutMs' 2>/dev/null)" = "300000" ] &&
        pass "openclaw jq: auth.rateLimit.lockoutMs = 300000 (5 min)" ||
        fail "openclaw jq: auth.rateLimit.lockoutMs not set"

    # Security fields must NOT be applied when bind_mode="loopback" (script skips that block)
    mock_lo_json='{"gateway":{"bind":"loopback","port":8082}}'
    # (loopback path skips the security block — no allowInsecureAuth key written)
    lo_result=$(echo "$mock_lo_json" | jq '.' 2>/dev/null || true)
    [ "$(echo "$lo_result" | jq -r '.gateway.controlUi.allowInsecureAuth // "absent"' 2>/dev/null)" = "absent" ] &&
        pass "openclaw jq: security fields not applied for loopback-only bind" ||
        fail "openclaw jq: security fields incorrectly applied to loopback bind"
else
    warn "jq not installed — skipping openclaw jq filter tests"
fi

# --- 5b-iii: save_ai_settings_file path regression ---
ai_settings_path=$(grep -A2 '^save_ai_settings_file()' "$SETUP_SCRIPT" \
    | grep 'out_file=' | head -1 || true)
if [[ "$ai_settings_path" == *'$HOME'* ]] && [[ "$ai_settings_path" != *'TARGET_USER_HOME'* ]]; then
    pass "save_ai_settings_file: output path is \$HOME (admin home, not target-user home)"
else
    fail "save_ai_settings_file: expected \$HOME path — got: $ai_settings_path"
fi

# ─── 6. Bats Unit Tests ──────────────────────────────────────────
header "6. Bats Unit Tests"
command -v bats &>/dev/null || try_install bats || true

BATS_DIR="$SCRIPT_DIR/tests"
if command -v bats &>/dev/null; then
    if [ -d "$BATS_DIR" ] && compgen -G "$BATS_DIR/*.bats" >/dev/null; then
        bats_output=$(bats "$BATS_DIR" 2>&1 || true)
        if echo "$bats_output" | tail -n 5 | grep -q "failure"; then
            fail "Bats reported failures"
            echo "$bats_output" | sed 's/^/    /'
        else
            test_count=$(echo "$bats_output" | grep -cE "^(ok|not ok)" || true)
            pass "$test_count bats test(s) passed"
        fi
    else
        warn "No .bats files found in $BATS_DIR"
    fi
else
    warn "bats not installed — run with --install or: sudo apt install bats"
fi

# ─── 7. Kcov Coverage (opt-in) ───────────────────────────────────
if [ "$RUN_COVERAGE" = true ]; then
    header "7. Kcov Coverage"
    command -v kcov &>/dev/null || try_install kcov || true

    if command -v kcov &>/dev/null && command -v bats &>/dev/null && [ -d "$BATS_DIR" ]; then
        COV_DIR="$SCRIPT_DIR/.coverage"
        rm -rf "$COV_DIR"
        kcov --include-path="$SETUP_SCRIPT" "$COV_DIR" bats "$BATS_DIR" >/dev/null 2>&1 || true
        cov_json="$COV_DIR/bats/coverage.json"
        if [ -f "$cov_json" ]; then
            percent=$(grep -o '"percent_covered":"[^"]*"' "$cov_json" | head -1 | cut -d'"' -f4)
            pass "Coverage: ${percent}% (report: $COV_DIR/index.html)"
        else
            warn "kcov produced no coverage report"
        fi
    else
        warn "kcov/bats missing — run with --install or: sudo apt install kcov bats"
    fi
fi

# ─── 8. Model Name Validation (network) ──────────────────────────
if [ "$QUICK_MODE" = true ]; then
    header "8. Model Name Validation (SKIPPED — quick mode)"
    echo "  Run without --quick to check Ollama + HuggingFace repos over the network."
else
    header "8. Ollama Model Validation (network)"

    # Deduplicate Ollama models
    OLLAMA_MODELS_RAW=""
    for vram in 8 16 24 32 48 72 96; do
        get_model_recommendations "ollama" "$vram"
        OLLAMA_MODELS_RAW="$OLLAMA_MODELS_RAW
$REC_MODEL_CHAT
$REC_MODEL_CODE
$REC_MODEL_MOE
$REC_MODEL_VISION"
    done
    OLLAMA_MODELS=$(echo "$OLLAMA_MODELS_RAW" | sort -u | grep -v '^$')
    OLLAMA_COUNT=$(echo "$OLLAMA_MODELS" | wc -l | awk '{print $1}')
    OLLAMA_ERRORS=0
    echo "  Checking $OLLAMA_COUNT unique models against ollama.com..."

    _oc_n=0
    while IFS= read -r model; do
        _oc_n=$(( _oc_n + 1 ))
        printf "  [%2d/%d] %-45s" "$_oc_n" "$OLLAMA_COUNT" "$model"
        status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://ollama.com/library/$(echo "$model" | cut -d':' -f1)")
        if [ "$status" -eq 200 ]; then
            echo -e " ${GREEN}✅${RESET}"
        else
            echo -e " ${RED}❌ HTTP $status${RESET}"
            TOTAL_ERRORS=$(( TOTAL_ERRORS + 1 ))
            OLLAMA_ERRORS=$(( OLLAMA_ERRORS + 1 ))
        fi
    done <<<"$OLLAMA_MODELS"
    echo "  ($OLLAMA_COUNT unique models checked)"

    header "9. HuggingFace Repo Validation (network)"

    # Grab HF_TOKEN if available
    HF_TOKEN=""
    if [ -f "$HOME/.env.secrets" ]; then
        HF_TOKEN=$(bash -c "source \"$HOME/.env.secrets\" 2>/dev/null && echo \"\$HF_TOKEN\"" | tr -d '\r')
    fi

    # Deduplicate HF repos
    HF_MODELS_RAW=""
    for vram in 8 16 24 32 48 72 96; do
        get_model_recommendations "llama" "$vram"
        HF_MODELS_RAW="$HF_MODELS_RAW
$REC_MODEL_CHAT
$REC_MODEL_CODE
$REC_MODEL_MOE
$REC_MODEL_VISION"
    done
    HF_MODELS=$(echo "$HF_MODELS_RAW" | sort -u | grep -v '^$')
    HF_COUNT=$(echo "$HF_MODELS" | wc -l | awk '{print $1}')
    HF_ERRORS=0
    echo "  Checking $HF_COUNT unique repos against huggingface.co..."

    _hf_n=0
    while IFS= read -r repo; do
        _hf_n=$(( _hf_n + 1 ))
        printf "  [%2d/%d] %-55s" "$_hf_n" "$HF_COUNT" "$repo"
        repo_name="${repo%:*}"
        curl_args=(-s -w "\n%{http_code}" --max-time 20)
        if [ -n "$HF_TOKEN" ]; then
            curl_args+=(-H "Authorization: Bearer $HF_TOKEN")
        fi
        curl_args+=("https://huggingface.co/api/models/$repo_name/tree/main")

        response=$(curl "${curl_args[@]}")
        status=$(echo "$response" | tail -n 1)
        body=$(echo "$response" | sed '$d')

        if [ "$status" -eq 200 ]; then
            if echo "$body" | grep -qi '\.gguf"'; then
                count=$(echo "$body" | grep -io '\.gguf"' | wc -l | awk '{print $1}')
                echo -e " ${GREEN}✅ ($count GGUFs)${RESET}"
            else
                echo -e " ${RED}❌ no .gguf files${RESET}"
                TOTAL_ERRORS=$(( TOTAL_ERRORS + 1 ))
                HF_ERRORS=$(( HF_ERRORS + 1 ))
            fi
        elif [ "$status" -eq 401 ] || [ "$status" -eq 403 ]; then
            echo -e " ${YELLOW}⚠️  gated (needs HF_TOKEN)${RESET}"
            TOTAL_WARNINGS=$(( TOTAL_WARNINGS + 1 ))
        else
            echo -e " ${RED}❌ HTTP $status${RESET}"
            TOTAL_ERRORS=$(( TOTAL_ERRORS + 1 ))
            HF_ERRORS=$(( HF_ERRORS + 1 ))
        fi
    done <<<"$HF_MODELS"
    echo "  ($HF_COUNT unique repos checked)"

    header "10. OpenClaw Compatibility Check (network)"

    if [ -f "$SCRIPT_DIR/tests/check-openclaw-compat.sh" ]; then
        start_heartbeat "  ⏳ querying npm registry"
        set +e
        bash "$SCRIPT_DIR/tests/check-openclaw-compat.sh"
        _oc_exit=$?
        set -e
        stop_heartbeat
        if [ $_oc_exit -eq 0 ]; then
            pass "OpenClaw npm package is compatible"
        else
            fail "OpenClaw compatibility check failed — review output above"
        fi
    else
        warn "tests/check-openclaw-compat.sh not found, skipping"
    fi
fi

# ─── Summary ─────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════${RESET}"
if [ $TOTAL_ERRORS -eq 0 ] && [ $TOTAL_WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✅ ALL TESTS PASSED${RESET}  ($(elapsed))"
elif [ $TOTAL_ERRORS -eq 0 ]; then
    echo -e "${YELLOW}⚠️  PASSED with $TOTAL_WARNINGS warning(s)${RESET}  ($(elapsed))"
else
    echo -e "${RED}❌ FAILED — $TOTAL_ERRORS error(s), $TOTAL_WARNINGS warning(s)${RESET}  ($(elapsed))"
fi
exit $TOTAL_ERRORS
