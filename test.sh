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
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1
    elif command -v brew &>/dev/null; then
        brew install "$pkg" >/dev/null 2>&1
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
header() { echo -e "\n${BLUE}=== $1 ===${RESET}"; }

echo -e "${CYAN}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║   ubuntu-prep-setup.sh  —  Test Suite             ║${RESET}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════╝${RESET}"

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

# Model size lookup: returns "weight_gb kv_gb" for Q4_K_M weights + KV cache at 8K context (fp16)
get_model_size() {
    local model="$1"
    case "$model" in
        # --- Ollama models ---
        "gemma4:e4b") echo "5 0.5" ;;
        "gemma4:e2b") echo "3 0.3" ;;
        "gemma4:26b") echo "17 1.5" ;;
        "gemma4:31b") echo "18 2.0" ;;
        "gemma3:4b") echo "3 0.3" ;;
        "gemma3:12b") echo "7 0.8" ;;
        "gemma3:27b") echo "17 1.5" ;;
        "qwen2.5:7b") echo "5 0.5" ;;
        "qwen2.5:14b") echo "9 1.0" ;;
        "qwen2.5:32b") echo "20 2.0" ;;
        "qwen2.5:72b") echo "47 3.5" ;;
        "qwen2.5-coder:3b") echo "2 0.3" ;;
        "qwen2.5-coder:7b") echo "5 0.5" ;;
        "qwen2.5-coder:14b") echo "9 1.0" ;;
        "qwen2.5-coder:32b") echo "20 2.0" ;;
        "mixtral:8x7b") echo "26 2.0" ;;
        "mixtral:8x22b") echo "86 5.0" ;;
        "command-r-plus") echo "63 4.0" ;;
        "llama3.1:8b") echo "5 0.5" ;;
        "llama3.3:70b") echo "43 3.5" ;;
        "llava:7b") echo "5 0.5" ;;
        "llava:13b") echo "8 1.0" ;;
        "llava:34b") echo "20 2.0" ;;
        "minicpm-v") echo "5 0.5" ;;
        "qwen2.5vl:3b") echo "2 0.3" ;;
        "qwen2.5vl:7b") echo "5 0.5" ;;
        "qwen2.5vl:32b") echo "20 2.0" ;;
        "qwen2.5vl:72b") echo "47 3.5" ;;
        "deepseek-r1:14b") echo "9 1.0" ;;
        "deepseek-r1:32b") echo "20 2.0" ;;
        "deepseek-r1:70b") echo "43 3.5" ;;
        "devstral:24b") echo "14 1.5" ;;
        "mistral-small:24b") echo "14 1.5" ;;
        "mistral-nemo") echo "7 0.8" ;;
        "phi4:14b") echo "9 1.0" ;;
        # --- HuggingFace GGUF repos ---
        "unsloth/gemma-4-E4B-it-GGUF") echo "5 0.5" ;;
        "unsloth/gemma-4-E2B-it-GGUF") echo "3 0.3" ;;
        "unsloth/gemma-4-26B-A4B-it-GGUF") echo "17 1.5" ;;
        "unsloth/gemma-4-31B-it-GGUF") echo "18 2.0" ;;
        "bartowski/Qwen2.5-7B-Instruct-GGUF") echo "5 0.5" ;;
        "bartowski/Qwen2.5-14B-Instruct-GGUF") echo "9 1.0" ;;
        "bartowski/Qwen2.5-32B-Instruct-GGUF") echo "20 2.0" ;;
        "bartowski/Qwen2.5-72B-Instruct-GGUF") echo "47 3.5" ;;
        "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF") echo "5 0.5" ;;
        "bartowski/Qwen2.5-Coder-14B-Instruct-GGUF") echo "9 1.0" ;;
        "bartowski/Qwen2.5-Coder-32B-Instruct-GGUF") echo "20 2.0" ;;
        "bartowski/Llama-3.3-70B-Instruct-GGUF") echo "43 3.5" ;;
        "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF") echo "5 0.5" ;;
        "TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF") echo "26 2.0" ;;
        "MaziyarPanahi/Mixtral-8x22B-v0.1-GGUF") echo "86 5.0" ;;
        "bartowski/c4ai-command-r-plus-08-2024-GGUF") echo "63 4.0" ;;
        "cjpais/llava-1.6-mistral-7b-gguf") echo "4 0.5" ;;
        "cjpais/llava-v1.6-vicuna-13b-gguf") echo "8 1.0" ;;
        "cjpais/llava-v1.6-34B-gguf") echo "20 2.0" ;;
        "unsloth/Qwen2.5-VL-7B-Instruct-GGUF") echo "5 0.5" ;;
        "unsloth/Qwen2.5-VL-32B-Instruct-GGUF") echo "20 2.0" ;;
        "unsloth/Qwen2.5-VL-72B-Instruct-GGUF") echo "47 3.5" ;;
        "unsloth/DeepSeek-R1-Distill-Qwen-14B-GGUF") echo "9 1.0" ;;
        "unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF") echo "20 2.0" ;;
        "bartowski/DeepSeek-R1-Distill-Llama-70B-GGUF") echo "43 3.5" ;;
        "unsloth/Devstral-Small-2505-GGUF") echo "14 1.5" ;;
        "unsloth/Mistral-Small-3.1-24B-Instruct-2503-GGUF") echo "14 1.5" ;;
        "bartowski/Mistral-Nemo-Instruct-2407-GGUF") echo "7 0.8" ;;
        "MaziyarPanahi/phi-4-GGUF") echo "9 1.0" ;;
        *) echo "0 0" ;;
    esac
}

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

            size_info=$(get_model_size "$model")
            weight_gb=$(echo "$size_info" | awk '{print $1}')
            kv_gb=$(echo "$size_info" | awk '{print $2}')

            if [ "$weight_gb" = "0" ]; then
                warn "${label} ${vram}GB ${category}: $model — size unknown (add to lookup)"
                VRAM_WARNINGS=$((VRAM_WARNINGS + 1))
                continue
            fi

            needed=$(echo "$weight_gb $kv_gb $RUNTIME_OVERHEAD" | awk '{printf "%.1f", $1 + $2 + $3}')
            fits=$(echo "$needed $vram" | awk '{print ($1 <= $2) ? "yes" : "no"}')

            if [ "$fits" = "no" ]; then
                fail "${label} ${vram}GB ${category}: $model — needs ~${needed}GB (${weight_gb}+${kv_gb}+${RUNTIME_OVERHEAD}) > ${vram}GB"
                VRAM_ERRORS=$((VRAM_ERRORS + 1))
            fi
        done
    done
done

if [ $VRAM_ERRORS -eq 0 ] && [ $VRAM_WARNINGS -eq 0 ]; then
    pass "All $VRAM_CHECKS model/tier combinations fit (weights + KV@8K + ${RUNTIME_OVERHEAD}GB runtime)"
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

    while IFS= read -r model; do
        base_model=$(echo "$model" | cut -d':' -f1)
        status=$(curl -s -o /dev/null -w "%{http_code}" "https://ollama.com/library/$base_model")
        if [ "$status" -eq 200 ]; then
            pass "$model"
        else
            fail "$model (HTTP $status)"
            OLLAMA_ERRORS=$((OLLAMA_ERRORS + 1))
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

    while IFS= read -r repo; do
        repo_name="${repo%:*}"
        curl_args=(-s -w "\n%{http_code}")
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
                pass "$repo ($count GGUF files)"
            else
                fail "$repo (no .gguf files in repo)"
                HF_ERRORS=$((HF_ERRORS + 1))
            fi
        elif [ "$status" -eq 401 ] || [ "$status" -eq 403 ]; then
            warn "$repo (gated — needs HF_TOKEN + license)"
        else
            fail "$repo (HTTP $status)"
            HF_ERRORS=$((HF_ERRORS + 1))
        fi
    done <<<"$HF_MODELS"
    echo "  ($HF_COUNT unique repos checked)"
fi

# ─── Summary ─────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════${RESET}"
if [ $TOTAL_ERRORS -eq 0 ] && [ $TOTAL_WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✅ ALL TESTS PASSED${RESET}"
elif [ $TOTAL_ERRORS -eq 0 ]; then
    echo -e "${YELLOW}⚠️  PASSED with $TOTAL_WARNINGS warning(s)${RESET}"
else
    echo -e "${RED}❌ FAILED — $TOTAL_ERRORS error(s), $TOTAL_WARNINGS warning(s)${RESET}"
fi
exit $TOTAL_ERRORS
