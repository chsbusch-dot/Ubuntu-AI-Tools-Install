#!/bin/bash
#
# macOS (Apple Silicon) Preparation Script
#
# Automates setup of a new macOS system on Apple Silicon (M1–M5):
# Homebrew, developer tools, OrbStack, Node, and local LLM stacks
# (llama.cpp with Metal, Ollama, OpenWebUI, LibreChat, OpenClaw).
#
# Featured default model from 24 GB UMA upward: Jackrong/Qwopus3.5-27B-v3-GGUF
#
# Companion scripts:
#   - macos-llama-reconfigure.sh  — menu-driven editor for llama-server plist
#   - check-macos.sh              — validation suite

MACOS_PREP_VERSION="1.0.0"

# Exit immediately if a command exits with a non-zero status.
set -e

# Sudo keepalive PID — set by start_sudo_keepalive(), killed on exit
SUDO_KEEPALIVE_PID=""

# Master cleanup — called on both error and normal exit
global_cleanup() {
    # Kill the sudo keepalive loop if running
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true # process may already be gone
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        SUDO_KEEPALIVE_PID=""
    fi
    # Remove temporary sudoers file if present.
    # macOS also honors /etc/sudoers.d/ when `includedir /private/etc/sudoers.d`
    # is present in /etc/sudoers (default on macOS 11+).
    if [[ -n "${TARGET_USER:-}" && -f "/etc/sudoers.d/99-temp-$TARGET_USER" ]]; then
        sudo rm -f "/etc/sudoers.d/99-temp-$TARGET_USER"
        echo "Revoked temporary sudo privileges for $TARGET_USER."
    fi
}

# Global error handler
cleanup_on_error() {
    local exit_code=$?
    local line_no=$1
    printf "%b\n" "\n\e[1;31m❌ ERROR: Script failed unexpectedly at line $line_no (Exit code: $exit_code)\e[0m"
    printf "%b\n" "\e[1;33mPerforming emergency cleanup...\e[0m"
    global_cleanup
    printf "%b\n" "Please check the error message above to troubleshoot."
}
trap 'cleanup_on_error ${LINENO}' ERR
trap 'global_cleanup' EXIT

start_sudo_keepalive() {
    # Refresh sudo credentials every 50 seconds to prevent timeout during
    # long installs (Homebrew bottles, Metal-linked llama.cpp build,
    # model downloads, etc.)
    (while true; do
        sudo -v
        sleep 50
    done) &
    SUDO_KEEPALIVE_PID=$!
}

# Global array to track post-installation actions
POST_INSTALL_ACTIONS=()

# ── Resume-after-reboot state ─────────────────────────────────────────────────
# macOS equivalent of /var/lib/<app>/ — we use ~/Library/Application Support
# (per-user, no sudo required to write) because macOS reboots don't require
# kernel-module rebuilds (no NVIDIA stack), and the main reason to resume is
# for Xcode Command Line Tools GUI installs that open a modal installer.
RESUME_MODE=false
RESUME_STATE_FILE="$HOME/Library/Application Support/macos-prep/resume.env"
# These three are global so save_resume_state() can access them from main()
MASTER_SELECTIONS=()
MASTER_INSTALLED_STATE=()
ACTIVE_INDICES=(0)

# Global vars for target user
TARGET_USER=""
TARGET_USER_HOME=""
IS_DIFFERENT_USER=false
# Apple Silicon: unified memory (CPU+GPU share one pool). Populated by
# detect_unified_memory(). UMA_TIER is UNIFIED_MEMORY_GB snapped to one of
# our supported tiers (24/32/48/64/96/128).
APPLE_SILICON_CHIP=""      # e.g. "Apple M3 Max"
UNIFIED_MEMORY_GB=0        # raw hw.memsize in GB
# shellcheck disable=SC2034  # reserved for downstream consumers / debug output
UMA_TIER=0                 # snapped tier: 24, 32, 48, 64, 96, or 128
IOGPU_WIRED_LIMIT_MB=0     # current sysctl iogpu.wired_limit_mb (0 = unset/default)
LLM_BACKEND_CHOICE=""
LLAMA_COMPONENT_STATUS="missing"
OLLAMA_COMPONENT_STATUS="missing"
OPENWEBUI_COMPONENT_STATUS="missing"
LIBRECHAT_COMPONENT_STATUS="missing"
OPENCLAW_COMPONENT_STATUS="missing"
LLAMA_COMPONENT_ACTION="skip"
OLLAMA_COMPONENT_ACTION="skip"
OPENWEBUI_COMPONENT_ACTION="skip"
LIBRECHAT_COMPONENT_ACTION="skip"
OPENCLAW_COMPONENT_ACTION="skip"
LLAMA_BUILD_VARIANT=""
FRONTEND_BACKEND_TARGET=""
INSTALL_OPENWEBUI="n"
INSTALL_LIBRECHAT="n"
EXPOSE_LLM_ENGINE="n"
EXPOSE_OPENCLAW="n"
OPENCLAW_RELEASE_CHANNEL="latest"
OPENCLAW_PORT="18789"
LIBRECHAT_PORT="3080"
OLLAMA_PULL_MODEL=""
LLAMACPP_MODEL_REPO=""
REPAIRED_COMPONENTS=()
INSTALLED_COMPONENTS=()
FAILED_COMPONENTS=()
RUN_LLAMA_BENCH="n"
LOAD_DEFAULT_MODEL="n"
LLM_DEFAULT_MODEL_CHOICE=""
SELECTED_MODEL_REPO=""
LLAMA_CTX_SIZE=""
LLAMA_CACHE_TYPE_K=""
LLAMA_CACHE_TYPE_V=""
LLAMA_CPU_MOE="y"
LLAMA_FLASH_ATTN="n"
LLAMA_UBATCH=""
LLAMA_VRAM_TIER=""
LLAMA_NGL=""     # GPU layers (0–99); empty = 99 for Metal (default offload all)
LLAMA_FIT="n"    # --fit on: auto-calculate ngl to fill unified-memory budget
LLAMA_FIT_CTX="" # --fit-ctx N: minimum ctx --fit will not shrink below
LLAMA_MLOCK="n"  # --mlock: pin model in RAM (wires Metal pages; respects iogpu.wired_limit_mb)
LLAMA_DIO="n"    # -dio: direct I/O, reduces page-cache pressure on large GGUFs

# ─── Local mirror mode ───────────────────────────────────────────────────────
# When --local-mirror BASE_URL is passed, git clone uses the local bare mirror
# instead of GitHub. Only llama.cpp and LibreChat are affected.
# Example: --local-mirror chris@192.168.1.135:/home/chris
LOCAL_MIRROR_BASE=""

# ─── Headless Mode ────────────────────────────────────────────────
# Run non-interactively with sensible defaults.
#
# Usage:
#   bash macos-prep-setup.sh --headless
HEADLESS_MODE=false
DRY_RUN=false
show_usage() {
    cat <<'USAGE'
Usage: macos-prep-setup.sh [OPTIONS]

OPTIONS
  --dry-run, -n            Show what would be installed and exit. No changes made.
  --local-mirror BASE_URL  Clone llama.cpp and LibreChat from a local bare mirror
                           instead of GitHub, and scp GGUF models from BASE_URL/models/.
                           BASE_URL is an scp-compatible path prefix.
                           Example: --local-mirror chris@192.168.1.135:/Users/chris
                           Models go in:  chris@192.168.1.135:/Users/chris/models/
                           Security: the mirror host's SSH fingerprint is accepted on
                           first use (StrictHostKeyChecking=accept-new). This is
                           trust-on-first-use — only pass --local-mirror when you
                           control the mirror host and the network path to it. The
                           mirror can serve arbitrary model weights and repo contents.
  --resume                 Resume after Xcode Command Line Tools install completes.
  --headless               Run non-interactively with env-var defaults.
  --version, -V            Print version and exit.
  --help, -h               Show this help and exit.

EXAMPLES
  macos-prep-setup.sh                                              # Interactive install
  macos-prep-setup.sh --dry-run                                    # Preview — no changes
  macos-prep-setup.sh --local-mirror chris@192.168.1.135:/Users/chris  # Use LAN mirror

FEATURED MODEL
  From 24 GB unified memory upward, the default chat model for the llama.cpp
  backend is Jackrong/Qwopus3.5-27B-v3-GGUF. The tier-specific quant is picked
  by qwopus_default_gguf_file():
    24 GB → Q3_K_M    32 GB → Q4_K_M    48 GB → Q5_K_M
    64 GB → Q6_K      96 GB → Q8_0     128 GB → BF16

For configuration details, see README.md or
https://github.com/chsbusch-dot/Ubuntu-AI-Tools-Install
USAGE
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --headless)
            HEADLESS_MODE=true
            shift
            ;;
        --resume)
            RESUME_MODE=true
            shift
            ;;
        --dry-run | -n)
            DRY_RUN=true
            shift
            ;;
        --local-mirror)
            if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
                LOCAL_MIRROR_BASE="$2"
                shift 2
            else
                echo "Error: --local-mirror requires a BASE_URL argument." >&2
                echo "Example: --local-mirror chris@192.168.1.135:/home/chris" >&2
                exit 2
            fi
            ;;
        --local-mirror=*)
            LOCAL_MIRROR_BASE="${1#--local-mirror=}"
            shift
            ;;
        --help | -h)
            show_usage
            exit 0
            ;;
        --version | -V)
            echo "macos-prep-setup.sh ${MACOS_PREP_VERSION}"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            show_usage >&2
            exit 2
            ;;
        *) shift ;;
    esac
done

HEADLESS_CTX_SIZE="${HEADLESS_CTX_SIZE:-}"         # empty = auto from VRAM tier
HEADLESS_CACHE_TYPE_K="${HEADLESS_CACHE_TYPE_K:-}" # empty = auto; f16|q8_0|q4_0|bf16|turbo3|turbo4|...
HEADLESS_CPU_MOE="${HEADLESS_CPU_MOE:-y}"          # y|n — offload MoE expert layers to CPU (default: on)
HEADLESS_UBATCH="${HEADLESS_UBATCH:-}"             # empty = auto from VRAM tier; e.g. 1024

reset_local_ai_component_state() {
    LLAMA_COMPONENT_ACTION="skip"
    OLLAMA_COMPONENT_ACTION="skip"
    OPENWEBUI_COMPONENT_ACTION="skip"
    LIBRECHAT_COMPONENT_ACTION="skip"
    LLAMA_BUILD_VARIANT=""
    LLM_BACKEND_CHOICE=""
    INSTALL_OPENWEBUI="n"
    INSTALL_LIBRECHAT="n"
    EXPOSE_LLM_ENGINE="n"
    LIBRECHAT_PORT="3080"
    LOAD_DEFAULT_MODEL="n"
    RUN_LLAMA_BENCH="n"
    LLM_DEFAULT_MODEL_CHOICE=""
    SELECTED_MODEL_REPO=""
    OLLAMA_PULL_MODEL=""
    LLAMACPP_MODEL_REPO=""
    INSTALL_LLAMA_SERVICE="n"
    LLAMA_CTX_SIZE=""
    LLAMA_CACHE_TYPE_K=""
    LLAMA_CACHE_TYPE_V=""
    LLAMA_CPU_MOE="y"
    LLAMA_FLASH_ATTN="n"
    LLAMA_MLOCK="n"
    LLAMA_DIO="n"
    LLAMA_UBATCH=""
    LLAMA_VRAM_TIER=""
}

derive_component_status() {
    local fully_present="$1"
    local partial_present="$2"
    local healthy="${3:-true}"

    if [[ "$fully_present" == "true" ]]; then
        if [[ "$healthy" == "false" ]]; then
            echo "broken"
        else
            echo "installed"
        fi
    elif [[ "$partial_present" == "true" ]]; then
        echo "broken"
    else
        echo "missing"
    fi
}

derive_component_action() {
    local status="$1"
    local selected="$2"

    if [[ "$selected" != "1" ]]; then
        echo "skip"
    elif [[ "$status" == "missing" ]]; then
        echo "install"
    else
        echo "repair"
    fi
}

format_component_status_label() {
    local status="$1"

    case "$status" in
        installed) echo "installed" ;;
        broken) echo "broken" ;;
        *) echo "missing" ;;
    esac
}

format_component_action_label() {
    local action="$1"

    case "$action" in
        install) echo "install" ;;
        repair) echo "repair" ;;
        *) echo "skip" ;;
    esac
}

record_component_outcome() {
    local component="$1"
    local action="$2"
    local result="$3"

    case "$result" in
        success)
            if [[ "$action" == "repair" ]]; then
                REPAIRED_COMPONENTS+=("$component")
            elif [[ "$action" == "install" ]]; then
                INSTALLED_COMPONENTS+=("$component")
            fi
            ;;
        failed)
            FAILED_COMPONENTS+=("$component")
            ;;
    esac
}

need_frontend_backend_target() {
    [[ "$OPENWEBUI_COMPONENT_ACTION" != "skip" || "$LIBRECHAT_COMPONENT_ACTION" != "skip" || "$OPENCLAW_COMPONENT_ACTION" != "skip" ]]
}

# Prompt for a yes/no answer, looping until y/Y/n/N or Enter is received.
# Usage:  if ask_yn "Prompt [y/N]: " "n"; then ...
# Arg 1: prompt string (including bracket hint)
# Arg 2: default — "y" or "n" (default: "n")
# Redirects (e.g. </dev/tty) are forwarded to the inner read.
# Returns 0 for yes, 1 for no.
ask_yn() {
    local prompt="$1"
    local default="${2:-n}"
    local reply
    while true; do
        read -r -p "$prompt" reply
        case "${reply:-$default}" in
            y | Y) return 0 ;;
            n | N) return 1 ;;
            *) echo "  Please enter y or n." ;;
        esac
    done
}

llama_variant_to_model_backend() {
    local variant="$1"

    case "$variant" in
        llama_cpu | llama_cuda) echo "llama" ;;
        *) echo "llama" ;;
    esac
}

available_backend_count() {
    local count=0

    if [[ "$LLM_BACKEND_CHOICE" == "llama_cpu" || "$LLM_BACKEND_CHOICE" == "llama_cuda" || "$LLAMA_COMPONENT_STATUS" != "missing" ]]; then
        count=$((count + 1))
    fi
    if [[ "$LLM_BACKEND_CHOICE" == "ollama" || "$OLLAMA_COMPONENT_STATUS" != "missing" ]]; then
        count=$((count + 1))
    fi

    echo "$count"
}

ensure_frontend_backend_target() {
    local backend_count

    if ! need_frontend_backend_target; then
        return 0
    fi

    if [[ -n "$FRONTEND_BACKEND_TARGET" ]]; then
        return 0
    fi

    backend_count=$(available_backend_count)
    if [[ "$LLM_BACKEND_CHOICE" == "llama_cpu" || "$LLM_BACKEND_CHOICE" == "llama_cuda" ]]; then
        FRONTEND_BACKEND_TARGET="llama"
        return 0
    fi
    if [[ "$LLM_BACKEND_CHOICE" == "ollama" ]]; then
        FRONTEND_BACKEND_TARGET="ollama"
        return 0
    fi

    if [[ "$backend_count" -le 1 ]]; then
        if [[ "$LLAMA_COMPONENT_STATUS" != "missing" ]]; then
            FRONTEND_BACKEND_TARGET="llama"
        elif [[ "$OLLAMA_COMPONENT_STATUS" != "missing" ]]; then
            FRONTEND_BACKEND_TARGET="ollama"
        fi
        return 0
    fi

    while true; do
        echo ""
        printf "%b\n" "\e[1;36mSelect which backend the frontends should target for this run:\e[0m"
        echo "  1. llama.cpp"
        echo "  2. Ollama"
        read -p "Your choice [1/2]: " backend_choice
        case "$backend_choice" in
            1)
                FRONTEND_BACKEND_TARGET="llama"
                break
                ;;
            2)
                FRONTEND_BACKEND_TARGET="ollama"
                break
                ;;
            *)
                printf "%b\n" "❌ \e[1;31mInvalid choice.\e[0m Please enter 1 or 2."
                ;;
        esac
    done
}

# --- Model Recommendations Configuration ---
# Edit this function to quickly update the default models offered in the menu.
get_model_recommendations() {
    # Backend × unified-memory-tier → four recommended model slots (chat, code,
    # MoE, vision). `vram` is kept as the argument name for parity with the
    # Ubuntu script and call sites; on macOS it represents the unified-memory
    # tier in GB (24/32/48/64/96/128), snapped from hw.memsize by
    # detect_unified_memory().
    local backend="$1"
    local vram="$2"

    REC_MODEL_CHAT=""
    REC_MODEL_CODE=""
    REC_MODEL_MOE=""
    REC_MODEL_VISION=""

    if [[ "$backend" == "ollama" ]]; then
        case "$vram" in
            8)
                REC_MODEL_CHAT="qwen2.5:7b"
                REC_MODEL_CODE="qwen2.5-coder:7b"
                REC_MODEL_MOE=""
                REC_MODEL_VISION="qwen2.5vl:7b"
                ;;
            16)
                REC_MODEL_CHAT="qwen2.5:14b"
                REC_MODEL_CODE="qwen2.5-coder:14b"
                REC_MODEL_MOE=""
                REC_MODEL_VISION="qwen2.5vl:7b"
                ;;
            24)
                REC_MODEL_CHAT="qwen3:32b"
                REC_MODEL_CODE="qwen2.5-coder:32b"
                REC_MODEL_MOE="qwen3:30b-a3b"
                REC_MODEL_VISION="qwen2.5vl:32b"
                ;;
            32)
                REC_MODEL_CHAT="qwen3:32b"
                REC_MODEL_CODE="qwen2.5-coder:32b"
                REC_MODEL_MOE="qwen3:30b-a3b"
                REC_MODEL_VISION="qwen2.5vl:32b"
                ;;
            48)
                REC_MODEL_CHAT="llama3.3:70b"
                REC_MODEL_CODE="qwen2.5-coder:32b"
                REC_MODEL_MOE="qwen3:30b-a3b"
                REC_MODEL_VISION="qwen2.5vl:32b"
                ;;
            64|72)
                REC_MODEL_CHAT="llama3.3:70b"
                REC_MODEL_CODE="qwen2.5-coder:32b"
                REC_MODEL_MOE="mixtral:8x7b"
                REC_MODEL_VISION="qwen2.5vl:72b"
                ;;
            96)
                REC_MODEL_CHAT="qwen2.5:72b"
                REC_MODEL_CODE="qwen2.5-coder:32b"
                REC_MODEL_MOE="mixtral:8x22b"
                REC_MODEL_VISION="qwen2.5vl:72b"
                ;;
            128)
                REC_MODEL_CHAT="qwen2.5:72b"
                REC_MODEL_CODE="qwen2.5-coder:32b"
                REC_MODEL_MOE="mixtral:8x22b"
                REC_MODEL_VISION="qwen2.5vl:72b"
                ;;
        esac
    else
        # llama.cpp (Metal) defaults for Apple Silicon UMA tiers.
        # From 24 GB upward the featured chat model is Jackrong/Qwopus3.5-27B-v3-GGUF
        # (Qwen3.5-27B LoRA fine-tune tuned for reasoning/code).
        case "$vram" in
            8)
                REC_MODEL_CHAT="bartowski/Qwen2.5-7B-Instruct-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-7B-Instruct-GGUF"
                REC_MODEL_MOE=""
                REC_MODEL_VISION="unsloth/Qwen2.5-VL-7B-Instruct-GGUF"
                ;;
            16)
                REC_MODEL_CHAT="bartowski/Qwen2.5-14B-Instruct-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-14B-Instruct-GGUF"
                REC_MODEL_MOE=""
                REC_MODEL_VISION="unsloth/Qwen2.5-VL-7B-Instruct-GGUF"
                ;;
            24)
                REC_MODEL_CHAT="Jackrong/Qwopus3.5-27B-v3-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF"
                REC_MODEL_VISION="unsloth/Qwen2.5-VL-32B-Instruct-GGUF"
                ;;
            32)
                REC_MODEL_CHAT="Jackrong/Qwopus3.5-27B-v3-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF"
                REC_MODEL_VISION="unsloth/Qwen2.5-VL-32B-Instruct-GGUF"
                ;;
            48)
                REC_MODEL_CHAT="Jackrong/Qwopus3.5-27B-v3-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF"
                REC_MODEL_VISION="unsloth/Qwen2.5-VL-32B-Instruct-GGUF"
                ;;
            64|72)
                REC_MODEL_CHAT="Jackrong/Qwopus3.5-27B-v3-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF"
                REC_MODEL_VISION="unsloth/Qwen2.5-VL-72B-Instruct-GGUF"
                ;;
            96)
                REC_MODEL_CHAT="Jackrong/Qwopus3.5-27B-v3-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="MaziyarPanahi/Mixtral-8x22B-v0.1-GGUF"
                REC_MODEL_VISION="unsloth/Qwen2.5-VL-72B-Instruct-GGUF"
                ;;
            128)
                REC_MODEL_CHAT="Jackrong/Qwopus3.5-27B-v3-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="MaziyarPanahi/Mixtral-8x22B-v0.1-GGUF"
                REC_MODEL_VISION="unsloth/Qwen2.5-VL-72B-Instruct-GGUF"
                ;;
        esac
    fi
}

# Qwopus3.5-27B-v3-GGUF tier → quant filename. Used by the HF downloader when
# the chat model is Qwopus (default on all macOS UMA tiers). The quant is
# chosen to leave headroom for kv-cache + runtime overhead at each tier.
qwopus_default_gguf_file() {
    local tier="$1"
    case "$tier" in
        24)  echo "Qwopus3.5-27B-v3-Q3_K_M.gguf" ;;
        32)  echo "Qwopus3.5-27B-v3-Q4_K_M.gguf" ;;
        48)  echo "Qwopus3.5-27B-v3-Q5_K_M.gguf" ;;
        64)  echo "Qwopus3.5-27B-v3-Q6_K.gguf"   ;;
        96)  echo "Qwopus3.5-27B-v3-Q8_0.gguf"   ;;
        128) echo "Qwopus3.5-27B-v3-BF16.gguf"   ;;
        *)   echo "Qwopus3.5-27B-v3-Q4_K_M.gguf" ;;
    esac
}

# --- Helper Functions ---

# Function to print colored headings
print_header() {
    printf "%b\n" "\n\e[1;34m===== $1 =====\e[0m"
}

# Function to print success messages
print_success() {
    printf "%b\n" "\e[1;32m✅ $1\e[0m"
}

# Function to print info messages
print_info() {
    printf "%b\n" "\e[1;36mℹ️ $1\e[0m"
}

# Function to print the persistent status header
print_status_header() {
    printf "%b\n" "\n\e[1;35m--- macOS Prep Script Menu ---\e[0m"
    local chip_disp="${APPLE_SILICON_CHIP:-unknown chip}"
    local uma_disp="unknown"
    [[ "${UNIFIED_MEMORY_GB:-0}" -gt 0 ]] && uma_disp="${UNIFIED_MEMORY_GB} GB"
    printf "%b\n" "Hardware: \e[1;36m${chip_disp}\e[0m | Unified Memory: \e[1;36m${uma_disp}\e[0m"
    printf "%b\n" "Target User: \e[1;36m$TARGET_USER\e[0m ($TARGET_USER_HOME)"
    # Show llama.cpp model + key parameters if the LaunchDaemon is currently loaded.
    # `launchctl print system/<label>` returns 0 when the job is bootstrapped.
    local llama_label llama_plist
    llama_label="$(get_llama_plist_label)"
    llama_plist="$(get_llama_plist_path)"
    if sudo launchctl print "system/$llama_label" >/dev/null 2>&1; then
        local prog_args llama_args model_path model_name ctx_val ctk_val ngl_val params
        # ProgramArguments is multi-line; pull the last <string> which holds
        # the bash -c payload, then grep out the llama-server invocation.
        prog_args=$(sudo awk '/<key>ProgramArguments<\/key>/,/<\/array>/' "$llama_plist" 2>/dev/null || true)
        llama_args=$(echo "$prog_args" | grep -oE 'llama-server[^<]*' | head -1 || true)
        model_path=$(echo "$llama_args" | grep -oE -- '--model [^[:space:]]+' | awk '{print $2}' || true)
        [[ -z "$model_path" ]] && model_path=$(echo "$llama_args" | grep -oE -- '-m [^[:space:]]+' | awk '{print $2}' || true)
        [[ -z "$model_path" ]] && model_path=$(echo "$llama_args" | grep -oE -- '--hf-file [^[:space:]]+' | awk '{print $2}' || true)
        [[ -n "$model_path" ]] && model_name=$(basename "$model_path" 2>/dev/null || true)
        ctx_val=$(echo "$llama_args" | grep -oE -- '-c [0-9]+' | awk '{print $2}' || true)
        ctk_val=$(echo "$llama_args" | grep -oE -- '-ctk [^[:space:]]+' | awk '{print $2}' || true)
        ngl_val=$(echo "$llama_args" | grep -oE -- '-ngl [0-9]+' | awk '{print $2}' || true)
        params=""
        [[ -n "$model_name" ]] && params+=" · \e[1;36m${model_name}\e[0m"
        [[ -n "$ctx_val" ]] && params+=" · ctx ${ctx_val}"
        [[ -n "$ctk_val" ]] && params+=" · ctk ${ctk_val}"
        [[ -n "$ngl_val" ]] && params+=" · ngl ${ngl_val}"
        printf "%b\n" "llama.cpp: \e[1;32m●\e[0m running${params}"
    fi
}

# Function to check if running as root
check_not_root() {
    if [[ $EUID -eq 0 ]]; then
        echo "❌ This script should not be run as root. It will use 'sudo' when necessary."
        exit 1
    fi
}

# Function to check if the current user has sudo privileges
check_sudo_privileges() {
    print_info "Verifying sudo privileges..."
    if ! sudo -v; then
        echo "❌ The current user does not have sudo privileges. Please run this script as a user with sudo access."
        exit 1
    fi
    print_success "Sudo privileges verified."
}

# Verify we're on macOS + Apple Silicon. We gate on `uname -s` for the OS and
# `uname -m` for the arch — Intel Macs are explicitly out of scope because the
# model sizing math, Metal backend assumptions, and UMA tiers only apply to
# Apple Silicon. macOS 13 (Ventura) is the minimum we support; older releases
# ship Homebrew versions that can't resolve newer casks like OrbStack.
check_os() {
    print_info "Verifying operating system..."
    local uname_s uname_m macos_version
    uname_s="$(uname -s)"
    uname_m="$(uname -m)"
    if [[ "$uname_s" != "Darwin" ]]; then
        echo "❌ This script is intended for macOS only. Detected OS: $uname_s."
        exit 1
    fi
    if [[ "$uname_m" != "arm64" ]]; then
        echo "❌ Apple Silicon (arm64) required. Detected arch: $uname_m."
        echo "    Intel Macs are out of scope — the Metal backend and UMA sizing math do not apply."
        exit 1
    fi
    macos_version="$(sw_vers -productVersion 2>/dev/null || echo 0)"
    local major="${macos_version%%.*}"
    if [[ -n "$major" && "$major" =~ ^[0-9]+$ && "$major" -lt 13 ]]; then
        echo "❌ macOS 13 (Ventura) or newer required. Detected: $macos_version."
        exit 1
    fi
    print_success "OS check passed: Running on macOS $macos_version (Apple Silicon)."
}

# Check for pending macOS software updates. Xcode CLT installers are
# version-matched to the OS; installing on a stale system often fails or
# installs a mismatched SDK. Called only when CLT is actually missing.
#
# Robustness notes:
#   - softwareupdate -l queries Apple servers and can hang indefinitely on
#     VMs or restricted networks. We background it and kill after 30s.
#   - On timeout / empty output / server error we proceed rather than exit —
#     the update check is advisory, not a gate.
#   - Default answer is "continue" (not "exit") so pressing Enter never
#     silently aborts the install.
_warn_if_macos_updates_pending() {
    print_info "Checking for pending macOS updates (30s timeout)..."
    local _su_tmp _pid _waited=0
    _su_tmp=$(mktemp /tmp/softwareupdate.XXXXXX)

    softwareupdate -l >"$_su_tmp" 2>&1 &
    _pid=$!
    while kill -0 "$_pid" 2>/dev/null; do
        if [[ $_waited -ge 30 ]]; then
            kill "$_pid" 2>/dev/null; wait "$_pid" 2>/dev/null || true
            rm -f "$_su_tmp"
            printf "%b\n" "\e[1;33m⚠️  Update check timed out (no Apple server access?) — proceeding.\e[0m"
            return 0
        fi
        sleep 1
        ((_waited++)) || true
    done

    local _su_out
    _su_out=$(cat "$_su_tmp" 2>/dev/null || true)
    rm -f "$_su_tmp"

    # Can't reach server, or no updates found — proceed silently.
    if [[ -z "$_su_out" ]] || echo "$_su_out" | grep -q "No new software available"; then
        [[ -n "$_su_out" ]] && print_success "macOS is up to date — safe to install Xcode CLT."
        return 0
    fi
    # Server error (e.g. "Couldn't connect") — proceed with a note.
    if echo "$_su_out" | grep -qiE "error|couldn.t|unavailable|failed"; then
        printf "%b\n" "\e[1;33m⚠️  Could not check for macOS updates — proceeding with CLT install.\e[0m"
        return 0
    fi

    # Updates found — warn but default to continuing.
    printf "%b\n" "\n\e[1;33m⚠️  Pending macOS updates detected:\e[0m"
    echo "$_su_out" | grep -E "^\*|Title:|Version:" | head -20
    printf "%b\n" "\n\e[1;33mXcode CLT is version-matched to your OS — mismatched installs can fail.\e[0m"
    echo ""
    printf "%b\n" "  1. Continue anyway  (default)"
    printf "%b\n" "  2. Exit now — update with: sudo softwareupdate -i -a --restart"
    printf "%b\n" "     then re-run: sudo ./macos-prep-setup.sh --resume"
    read -rp "Your choice [1/2, default=1]: " _upd_choice
    case "${_upd_choice:-1}" in
        2)
            printf "%b\n" "\nRun:  sudo softwareupdate -i -a --restart"
            printf "%b\n" "Then: sudo ./macos-prep-setup.sh --resume"
            exit 0
            ;;
        *)
            printf "%b\n" "\e[1;33m⚠️  Continuing without updates — proceed with caution.\e[0m"
            ;;
    esac
}

# Ensure Xcode Command Line Tools are installed. macOS's Homebrew, git, and
# most compile-from-source workflows require the CLT SDK. If missing, we
# trigger the GUI installer (which opens a modal dialog) and then poll until
# `xcode-select -p` returns a valid path, with an escape hatch after the
# timeout so headless runs can't hang forever.
ensure_xcode_clt() {
    if xcode-select -p &>/dev/null; then
        print_success "Xcode Command Line Tools already installed at $(xcode-select -p)."
        return 0
    fi
    print_info "Xcode Command Line Tools not detected — launching installer..."
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[dry-run] Would run: xcode-select --install"
        return 0
    fi
    _warn_if_macos_updates_pending
    # `xcode-select --install` exits non-zero if the modal dialog is
    # dismissed by the user, so we tolerate failure and re-check the path.
    xcode-select --install 2>/dev/null || true
    local waited=0 timeout_s=600
    while ! xcode-select -p &>/dev/null; do
        if [[ $waited -ge $timeout_s ]]; then
            echo "❌ Timed out waiting for Xcode Command Line Tools after ${timeout_s}s." >&2
            echo "    Install manually with: xcode-select --install, then rerun this script." >&2
            exit 1
        fi
        sleep 10
        waited=$((waited + 10))
        printf "  [%3ds] waiting for CLT install to complete...\n" "$waited"
    done
    print_success "Xcode Command Line Tools are installed."
}

# macOS replacement for apt-based install_base_dependencies(). Homebrew pulls
# most of our base deps in one shot; curl/file/sed/grep/awk come preinstalled.
# We keep jq/wget/gnupg/coreutils because downstream code uses GNU-isms that
# BSD tools don't support (see `brew install gnu-sed coreutils` notes in the
# Homebrew docs — we prefer keeping PATH unchanged and calling gjq/gsed where
# needed).
install_base_dependencies() {
    print_header "Ensuring Base Dependencies are Installed"
    ensure_xcode_clt
    ensure_homebrew
    # Brew is idempotent: `brew install` on an already-installed formula exits 0.
    brew_run install jq wget gnupg coreutils >/dev/null
    print_success "Base dependencies are present."
}

# Network download wrapper — retries up to 3 times on failure with a 5-second delay.
# Drop-in replacement for curl: passes all arguments through unchanged.
# Do NOT use for health-check probes or JSON API subshell calls.
curl_with_retry() {
    local n=0
    local max=3
    until curl "$@"; do
        n=$((n + 1))
        if [[ $n -ge $max ]]; then
            echo "❌ curl failed after $max attempts." >&2
            return 1
        fi
        echo "⚠️  curl attempt $n/$max failed, retrying in 5s..." >&2
        sleep 5
    done
}

# --- Installation Functions ---

# Function to determine the target user for the installation.
# macOS port notes:
#   - getent passwd doesn't exist on macOS. We use `dscl . -read` against
#     Directory Services to read the NFSHomeDirectory attribute.
#   - `adduser` doesn't exist either. Creating a new user is a 6-step dscl
#     dance (and requires an admin); we gate the 2nd-user branch on the user
#     either pre-existing or on the user confirming they want the dscl path.
#   - Default home on macOS is /Users/<name>, not /home/<name>.
determine_target_user() {
    printf "%b\n" "\n\e[1;36mSelect Target User for Installation:\e[0m"
    echo "This script runs system-wide installations (like Homebrew casks) using 'sudo'."
    echo "User-specific tools (like NVM and OpenClaw) will be installed for the user you select below."
    echo "  1. Sudo user ($USER)  — install everything for the user running this script"
    echo "  2. A different/new user (e.g., a dedicated 'openclaw' user — recommended for OpenClaw)"
    printf "%b\n" "     \e[0;33mNote: the new user will be created as an administrator — required by Homebrew.\e[0m"
    local choice
    while true; do
        read -rp "Your choice [1/2]: " choice
        case "$choice" in
            1) break ;;
            2) break ;;
            *) printf "%b\n" "❌ \e[1;31mInvalid choice '$choice'.\e[0m Please enter 1 or 2." ;;
        esac
    done
    if [[ "$choice" == "2" ]]; then
        IS_DIFFERENT_USER=true
        local username
        while true; do
            read -rp "Enter the target username [openclaw]: " username
            TARGET_USER=${username:-openclaw}

            if [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                break
            else
                printf "%b\n" "❌ \e[1;31mInvalid username format.\e[0m Usernames must start with a lowercase letter or underscore, and only contain lowercase letters, numbers, dashes, or underscores."
            fi
        done

        if id "$TARGET_USER" &>/dev/null; then
            print_info "Target user '$TARGET_USER' already exists."
        elif [[ "$DRY_RUN" == "true" ]]; then
            print_info "Dry run: would create standard user '$TARGET_USER' via sysadminctl."
        else
            print_info "User '$TARGET_USER' does not exist — creating a standard account."
            local _full_name _password _confirm
            read -rp "Full name for '$TARGET_USER' [${TARGET_USER}]: " _full_name
            _full_name="${_full_name:-$TARGET_USER}"
            while true; do
                read -rsp "Password for '$TARGET_USER': " _password; echo
                if [[ -z "$_password" ]]; then
                    printf "%b\n" "❌ \e[1;31mPassword cannot be empty for an administrator account.\e[0m Try again."
                    continue
                fi
                read -rsp "Confirm password: " _confirm; echo
                if [[ "$_password" == "$_confirm" ]]; then
                    break
                fi
                printf "%b\n" "❌ \e[1;31mPasswords do not match.\e[0m Try again."
            done
            # sysadminctl always emits a FileVault (FDE) diagnostic on stderr when
            # a password is supplied non-interactively — this is expected and harmless.
            # The account is still created; FDE enrolment can be done later via
            # System Settings → Privacy & Security → FileVault.
            if sudo sysadminctl -addUser "$TARGET_USER" \
                    -fullName "$_full_name" -password "$_password" -admin 2>/dev/null; then
                print_success "User '$TARGET_USER' created."
                # Materialise the home directory if the system hasn't yet.
                if [[ ! -d "/Users/$TARGET_USER" ]]; then
                    sudo createhomedir -c -u "$TARGET_USER" >/dev/null 2>&1 || true
                fi
            else
                printf "%b\n" "❌ \e[1;31msysadminctl failed to create '$TARGET_USER'.\e[0m" >&2
                exit 1
            fi
        fi
        # macOS replacement for getent. dscl returns "NFSHomeDirectory: /Users/foo".
        TARGET_USER_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null |
            awk '/^NFSHomeDirectory:/ { print $2 }')
        if [[ -z "$TARGET_USER_HOME" ]]; then
            TARGET_USER_HOME="/Users/$TARGET_USER"
        fi
    else
        TARGET_USER=$USER
        TARGET_USER_HOME=$HOME
    fi
    # Defensive: every downstream sudo/launchd/path operation interpolates
    # TARGET_USER, so reject obvious junk (spaces, shell metacharacters, empty)
    # no matter which branch set it. macOS allows uppercase in usernames but
    # our launchd plist labels and path fragments assume lowercase; enforce
    # the stricter rule to keep downstream code simple.
    if [[ ! "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        echo "❌ TARGET_USER '$TARGET_USER' is not a valid POSIX username (^[a-z_][a-z0-9_-]{0,31}\$)." >&2
        exit 1
    fi
    print_info "All user-specific files will be installed for user '$TARGET_USER' in '$TARGET_USER_HOME'."
}

# Apple Silicon has unified memory — the CPU and GPU share one physical pool,
# so "system RAM" and "VRAM" are the same number. We:
#   1. Read hw.memsize (bytes) → GB.
#   2. Read machdep.cpu.brand_string (e.g. "Apple M3 Max").
#   3. Snap the raw GB value to one of the supported UMA tiers
#      (24/32/48/64/96/128) used by get_model_recommendations() and the
#      sizing math. The ranges are chosen to include the stock Apple-Silicon
#      memory configurations and round conservatively downward so the sizing
#      math doesn't overcommit.
# SYSTEM_RAM_GB and GPU_VRAM_GB are kept as aliases for UNIFIED_MEMORY_GB so
# the rest of the Ubuntu-derived script continues to work without renames.
detect_unified_memory() {
    local bytes
    bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
        UNIFIED_MEMORY_GB=$(awk -v b="$bytes" 'BEGIN { printf "%d", b / 1024 / 1024 / 1024 + 0.5 }')
    else
        UNIFIED_MEMORY_GB=0
    fi
    APPLE_SILICON_CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")"

    # Snap to supported tier. Ranges are conservative (round down near a
    # boundary): the sizing math must not overcommit the pool.
    # shellcheck disable=SC2034  # exported for downstream scripts / debug
    if   [[ $UNIFIED_MEMORY_GB -ge 120 ]]; then UMA_TIER=128
    elif [[ $UNIFIED_MEMORY_GB -ge  88 ]]; then UMA_TIER=96
    elif [[ $UNIFIED_MEMORY_GB -ge  56 ]]; then UMA_TIER=64
    elif [[ $UNIFIED_MEMORY_GB -ge  44 ]]; then UMA_TIER=48
    elif [[ $UNIFIED_MEMORY_GB -ge  28 ]]; then UMA_TIER=32
    elif [[ $UNIFIED_MEMORY_GB -ge  20 ]]; then UMA_TIER=24
    else                                        UMA_TIER=0
    fi

    # Current iogpu.wired_limit_mb (Metal wired-memory cap). 0 means the
    # kernel default (~67% of RAM) is in effect. suggest_iogpu_limit() uses
    # this to decide whether to offer raising the cap.
    IOGPU_WIRED_LIMIT_MB="$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
    [[ "$IOGPU_WIRED_LIMIT_MB" =~ ^[0-9]+$ ]] || IOGPU_WIRED_LIMIT_MB=0

    # Back-compat aliases (ubuntu-origin code paths still read these names).
    SYSTEM_RAM_GB=$UNIFIED_MEMORY_GB
    GPU_VRAM_GB=$UNIFIED_MEMORY_GB

    # Apple Silicon never has a discrete NVIDIA GPU. Ubuntu-origin branches
    # that gate on `$HAS_NVIDIA_GPU == true` (e.g. Container Toolkit prompts)
    # must therefore take the false branch.
    HAS_NVIDIA_GPU=false
    NVIDIA_DRIVER_TYPE=""
}

# Backwards-compatibility shim: ubuntu script calls `detect_gpu`. We keep the
# name so the main() call site continues to work, and delegate.
detect_gpu() { detect_unified_memory; }

# Offer to raise the Metal wired-memory cap so llama.cpp can park more of the
# model resident in GPU-visible memory. Default on macOS is ~67% of RAM, which
# on 24 GB systems caps at ~16 GB and evicts pages under memory pressure.
# Target: min(85% of RAM, RAM - 6 GB) — leaves headroom for the rest of the
# OS while lifting the cap above the default. Persists via /etc/sysctl.conf
# if requested (macOS reads this on boot when `sysctl.conf` exists — note this
# is a legacy path that Apple may remove; we warn accordingly).
suggest_iogpu_limit() {
    if [[ "$UNIFIED_MEMORY_GB" -eq 0 ]]; then
        return 0
    fi
    local target_85 target_headroom target_mb
    target_85=$((UNIFIED_MEMORY_GB * 1024 * 85 / 100))
    target_headroom=$(((UNIFIED_MEMORY_GB - 6) * 1024))
    target_mb=$target_85
    [[ $target_headroom -lt $target_mb ]] && target_mb=$target_headroom
    [[ $target_mb -lt 0 ]] && target_mb=0

    local current_display="default (~67% of RAM)"
    if [[ "$IOGPU_WIRED_LIMIT_MB" -gt 0 ]]; then
        current_display="${IOGPU_WIRED_LIMIT_MB} MB"
    fi

    print_info "Metal wired-memory cap (iogpu.wired_limit_mb):"
    echo "  Current : $current_display"
    echo "  Suggest : ${target_mb} MB  (min of 85% RAM, RAM-6GB on ${UNIFIED_MEMORY_GB} GB)"
    if ! ask_yn "Raise iogpu.wired_limit_mb to ${target_mb} MB for this session?" "y"; then
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[dry-run] Would run: sudo sysctl iogpu.wired_limit_mb=${target_mb}"
    else
        sudo sysctl "iogpu.wired_limit_mb=${target_mb}" >/dev/null
        IOGPU_WIRED_LIMIT_MB=$target_mb
        print_success "Metal wired cap raised to ${target_mb} MB (this session only)."
    fi

    if ask_yn "Persist this across reboots via /etc/sysctl.conf?" "y"; then
        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[dry-run] Would append iogpu.wired_limit_mb=${target_mb} to /etc/sysctl.conf"
        else
            sudo touch /etc/sysctl.conf
            # Remove any previous line, then append current value.
            sudo sed -i '' '/^iogpu\.wired_limit_mb=/d' /etc/sysctl.conf 2>/dev/null || true
            echo "iogpu.wired_limit_mb=${target_mb}" | sudo tee -a /etc/sysctl.conf >/dev/null
            print_success "Persisted to /etc/sysctl.conf."
            print_info "Note: /etc/sysctl.conf is legacy on macOS. If Apple removes support, rerun this helper."
        fi
    fi
}

# Function to configure API keys for either bash or zsh
setup_env_secrets() {
    print_header "Configuring API Keys"
    if ! sudo test -f "$TARGET_USER_HOME/.env.secrets"; then
        print_info "Creating ~/.env.secrets template for API keys..."
        cat <<EOF | sudo -u "$TARGET_USER" tee "$TARGET_USER_HOME/.env.secrets" >/dev/null
# This file is for storing secrets and API keys.
# It is sourced by your shell configuration if it exists.
# Make sure this file is NOT committed to version control.

# --- API Key Placeholders ---
# Uncomment and fill in the values for the services you use.
#Set Your path to llama.cpp model custom folder
export LLAMA_CACHE="$HOME/llama.cpp/models"

# Uncomment these as needed.
# export GITHUB_TOKEN="your_github_token"
# export AWS_SECRET_ACCESS_KEY="your_aws_secret"
# export OPENAI_API_KEY="your_openai_key"
# export GOOGLE_API_KEY="your_google_api_key"
# export CLAUDE_API_KEY="your_claude_key"
# export NVIDIA_API_KEY="your_nvidia_api_key"
# export NVIDIA_NGC_API_KEY="your_nvidia_api_key"
# export HF_TOKEN="hf_your_token_here"
# export FIRECRAWL_API_KEY=""
# export TAVILI_API_KEY=""
# export NVIDIA_VGPU_DRIVER_URL="ftp://192.168.1.31/shared/.../nvidia.deb"
# export NVIDIA_VGPU_TOKEN_URL="ftp://192.168.1.31/shared/.../token.tok"
# export NVIDIA_VGPU_DOWNLOAD_AUTH="admin:password" # Works for FTP, HTTP Basic Auth, and SMB
# export ESXI_HOST="192.168.1.100"
# export ESXI_USER="root"
# export ESXI_PASSWORD="your_esxi_password"
# export OLLAMA_ALLOWED_ORIGINS="https://chat.yourdomain.com,http://localhost:8081"

EOF
        sudo chmod 600 "$TARGET_USER_HOME/.env.secrets"
    fi

    if sudo test -f "$TARGET_USER_HOME/.bashrc" && ! sudo grep -q ".env.secrets" "$TARGET_USER_HOME/.bashrc"; then
        printf "%b\n" '\n# Source secrets file if it exists\nif [[ -f ~/.env.secrets ]]; then\n  source ~/.env.secrets\nfi' | sudo tee -a "$TARGET_USER_HOME/.bashrc" >/dev/null
    fi

    # Interactive prompt for API keys
    print_info "API keys configuration file is ready at $TARGET_USER_HOME/.env.secrets"
    if ask_yn "Do you want to edit your API keys for '$TARGET_USER' now? [y/N]: " "n"; then
        PS3="Please choose how to add your keys: "
        options=("Enter keys one-by-one" "Edit file manually with nano" "Skip")
        select opt in "${options[@]}"; do
            case $opt in
                "Enter keys one-by-one")
                    print_info "Please enter the value for each key. Press Enter to skip a key."
                    keys_to_prompt=(
                        "GITHUB_TOKEN" "AWS_SECRET_ACCESS_KEY" "OPENAI_API_KEY"
                        "GOOGLE_API_KEY" "CLAUDE_API_KEY" "NVIDIA_API_KEY"
                        "NVIDIA_VGPU_DRIVER_URL" "NVIDIA_VGPU_DOWNLOAD_AUTH"
                        "ESXI_HOST" "ESXI_USER" "ESXI_PASSWORD"
                    )
                    for key_name in "${keys_to_prompt[@]}"; do
                        while true; do
                            read -p "Enter value for ${key_name} (blank to skip): " key_value
                            # Trim leading/trailing whitespace
                            key_value="${key_value#"${key_value%%[![:space:]]*}"}"
                            key_value="${key_value%"${key_value##*[![:space:]]}"}"
                            # Strip surrounding single or double quotes (common paste artifact)
                            if [[ "$key_value" =~ ^\"(.*)\"$ ]] || [[ "$key_value" =~ ^\'(.*)\'$ ]]; then
                                key_value="${BASH_REMATCH[1]}"
                            fi

                            if [[ -z "$key_value" ]]; then
                                break # blank = skip this key
                            fi

                            # Format checks for keys with well-known shapes
                            local format_ok=true format_hint=""
                            case "$key_name" in
                                NVIDIA_VGPU_DRIVER_URL | NVIDIA_VGPU_TOKEN_URL)
                                    if [[ ! "$key_value" =~ ^(https?|ftp|smb):// ]]; then
                                        format_ok=false
                                        format_hint="Expected a URL starting with http://, https://, ftp:// or smb://"
                                    fi
                                    ;;
                                GITHUB_TOKEN)
                                    if [[ ! "$key_value" =~ ^(ghp_|github_pat_|gho_|ghu_|ghs_|ghr_) ]]; then
                                        format_ok=false
                                        format_hint="GitHub tokens usually start with 'ghp_' or 'github_pat_'"
                                    fi
                                    ;;
                                OPENAI_API_KEY)
                                    if [[ ! "$key_value" =~ ^sk- ]]; then
                                        format_ok=false
                                        format_hint="OpenAI API keys start with 'sk-'"
                                    fi
                                    ;;
                                CLAUDE_API_KEY)
                                    if [[ ! "$key_value" =~ ^sk-ant- ]]; then
                                        format_ok=false
                                        format_hint="Anthropic API keys start with 'sk-ant-'"
                                    fi
                                    ;;
                                ESXI_HOST)
                                    if [[ ! "$key_value" =~ ^[A-Za-z0-9._-]+$ ]]; then
                                        format_ok=false
                                        format_hint="ESXi host should be a hostname or IP (letters, digits, dots, dashes only)"
                                    fi
                                    ;;
                            esac

                            if [[ "$format_ok" != true ]]; then
                                printf "%b\n" "⚠️  \e[1;33m${format_hint}\e[0m"
                                local accept_anyway
                                read -p "Use this value anyway? [y/N/r=re-enter]: " accept_anyway
                                case "$accept_anyway" in
                                    y | Y) ;;          # accept as-is, fall through to save
                                    r | R) continue ;; # re-prompt
                                    *) continue ;;     # default re-prompt
                                esac
                            fi

                            # Use awk for replacement — immune to all sed metacharacters
                            # (backslashes, pipes, ampersands, slashes in the value).
                            # We also escape the four chars that matter inside a bash
                            # double-quoted string (\ " $ `) so the written line is safe
                            # when `.env.secrets` is sourced.
                            local secrets_file="$TARGET_USER_HOME/.env.secrets"
                            local tmp_secrets
                            tmp_secrets=$(sudo mktemp)
                            sudo awk -v key="$key_name" -v val="$key_value" '
                                BEGIN {
                                    gsub(/\\/, "\\\\", val)
                                    gsub(/"/,  "\\\"", val)
                                    gsub(/\$/, "\\$",  val)
                                    gsub(/`/,  "\\`",  val)
                                }
                                $0 ~ "^# export " key "=" { print "export " key "=\"" val "\""; next }
                                { print }
                            ' "$secrets_file" | sudo tee "$tmp_secrets" >/dev/null
                            sudo mv "$tmp_secrets" "$secrets_file"
                            sudo chown "$TARGET_USER":staff "$secrets_file"
                            break
                        done
                    done
                    print_success "API keys have been saved to $TARGET_USER_HOME/.env.secrets."
                    break
                    ;;
                "Edit file manually with nano")
                    print_info "Opening $TARGET_USER_HOME/.env.secrets with nano. Save with Ctrl+X, then Y, then Enter."
                    sudo -u "$TARGET_USER" nano "$TARGET_USER_HOME/.env.secrets"
                    print_success "Finished editing secrets file."
                    break
                    ;;
                "Skip")
                    break
                    ;;
                *) echo "Invalid option $REPLY" ;;
            esac
        done
    fi

    print_info "Securing API keys file permissions..."
    sudo chown "$TARGET_USER":staff "$TARGET_USER_HOME/.env.secrets"
    sudo chmod 600 "$TARGET_USER_HOME/.env.secrets"
}


# 0. Update System Packages — brew update/upgrade on macOS. macOS itself is
# updated via System Settings / softwareupdate(8); we don't trigger OS updates
# from an install script because they can force reboots mid-run.
update_system() {
    print_header "Updating System Packages (Homebrew)"
    ensure_homebrew
    brew_run update
    brew_run upgrade || true  # a single broken formula shouldn't abort the rest
    brew_run upgrade --cask || true
    print_success "Homebrew formulae/casks updated."
    sleep 2
}

# 2. Install Python Environment (Homebrew).
# macOS ships `python3`, but it's tracked by Xcode CLT and moves around
# between OS releases. The brew-managed python@3.12 is more predictable for
# development work and is what downstream tools (llama.cpp venv, asitop,
# huggingface-cli) expect.
install_python() {
    print_header "Installing Python and Virtual Environment Tools"
    ensure_homebrew
    brew_run install python@3.12 >/dev/null
    # virtualenv comes bundled with modern python; the Ubuntu-side libssl-dev
    # / libffi-dev packages are not needed on macOS because the brew python
    # bottles already ship with openssl/libffi linked.
    print_success "Python environment installed."
}

# 3. Install OrbStack (Docker replacement for macOS).
# OrbStack is a fast, lightweight Docker Desktop alternative that runs on
# Apple Silicon natively and integrates with the system without the resource
# overhead of Docker Desktop. On macOS there's no docker group and no
# usermod — the Docker socket is per-user.
install_docker() {
    print_header "Installing OrbStack (Docker runtime for macOS)"
    ensure_homebrew
    if brew list --cask orbstack &>/dev/null; then
        print_info "OrbStack already installed."
    else
        print_info "Installing OrbStack via Homebrew cask..."
        brew_run install --cask orbstack
    fi
    print_info "Launching OrbStack once to initialize the Docker socket..."
    # Open the app so it registers the /usr/local/bin/docker shim and starts
    # the engine. The -g flag prevents stealing focus; the app self-closes
    # once the engine is warm, so we don't need to tear it down.
    open -g -a OrbStack 2>/dev/null || true

    print_success "OrbStack installed. Run 'orbctl status' to verify."
    POST_INSTALL_ACTIONS+=("orbstack")
}

# 4. Install NVM, Node.js & NPM.
# NVM itself works identically on macOS — it's a pure-bash shell-function
# installer. For the "system Node" role that OpenClaw's launchd service uses
# (analogous to Ubuntu's NodeSource deb), on macOS we install `brew install
# node` — that's the idiomatic macOS equivalent of a stable system Node and
# lands binaries at /opt/homebrew/bin/node where launchd plists can reference
# them without depending on a per-user NVM PATH setup.
install_nvm_node() {
    print_header "Installing NVM, Node.js (LTS), and NPM"
    print_info "Running the NVM installation script..."
    local latest_nvm
    latest_nvm=$(curl -sL https://api.github.com/repos/nvm-sh/nvm/releases/latest | jq -r .tag_name 2>/dev/null || echo "v0.39.7")
    # -H sets HOME to TARGET_USER's home so npm/nvm write to the right place.
    # cd /tmp gives a world-readable CWD (parent dir of this script may be root-owned).
    ( cd /tmp && sudo -u "$TARGET_USER" -H bash -c \
        "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${latest_nvm}/install.sh | bash" )
    # Abort early if the installer didn't create nvm.sh — nothing below will work.
    if ! sudo test -f "$TARGET_USER_HOME/.nvm/nvm.sh"; then
        print_warning "NVM install appears to have failed (nvm.sh not found). Aborting."
        return 1
    fi

    print_info "Installing the latest LTS version of Node.js..."
    local nvm_cmd
    nvm_cmd=$(nvm_env_prelude)
    ( cd /tmp && sudo -u "$TARGET_USER" -H bash -c "$nvm_cmd; nvm install --lts; nvm install-latest-npm" )

    print_info "Verifying NVM configuration in shell files..."
    local nvm_config_str
    nvm_config_str=$(
        cat <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
EOF
    )
    if sudo test -f "$TARGET_USER_HOME/.zshrc" && ! sudo grep -q 'NVM_DIR' "$TARGET_USER_HOME/.zshrc"; then
        print_info "Adding NVM configuration to ~/.zshrc"
        printf '\n# NVM Configuration\n%s\n' "$nvm_config_str" | sudo tee -a "$TARGET_USER_HOME/.zshrc" >/dev/null
    fi
    if sudo test -f "$TARGET_USER_HOME/.bashrc" && ! sudo grep -q 'NVM_DIR' "$TARGET_USER_HOME/.bashrc"; then
        print_info "Adding NVM configuration to ~/.bashrc"
        printf '\n# NVM Configuration\n%s\n' "$nvm_config_str" | sudo tee -a "$TARGET_USER_HOME/.bashrc" >/dev/null
    fi

    local node_version
    node_version=$(sudo -u "$TARGET_USER" -H bash -c "$nvm_cmd; node -v" 2>/dev/null || echo "unknown")
    local npm_version
    npm_version=$(sudo -u "$TARGET_USER" -H bash -c "$nvm_cmd; npm -v" 2>/dev/null || echo "unknown")

    print_success "NVM, Node.js, and NPM installed."
    print_info "Node version: $node_version, NPM version: $npm_version"

    # Idiomatic macOS replacement for NodeSource: brew install node gives us
    # a stable system-ish binary at /opt/homebrew/bin/node that plists can
    # reference without a shell init.
    print_info "Installing system Node.js via Homebrew (for launchd-managed services)..."
    if brew_run install node >/dev/null 2>&1; then
        print_success "System Node.js installed: $(/opt/homebrew/bin/node --version 2>/dev/null || echo 'see brew bin')"
    else
        print_info "System Node.js install skipped (brew unavailable — NVM-only is fine)."
    fi

    POST_INSTALL_ACTIONS+=("nvm")
}

# 5. Install Homebrew (Apple Silicon).
# Two separate entry points share the body below:
#   - ensure_homebrew()   — idempotent guard used by other installers. Writes
#                           no shell-init files. Safe to call repeatedly.
#   - install_homebrew()  — full menu-driven install + shell-init wiring.
ensure_homebrew() {
    if command -v brew &>/dev/null; then
        return 0
    fi
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        return 0
    fi
    print_info "Homebrew not found — installing (NONINTERACTIVE)..."
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[dry-run] Would install Homebrew via the official script."
        return 0
    fi
    # Homebrew requires the installing user to be in the admin group.
    # This may not be the case if the user pre-existed before this script
    # added the -admin flag to sysadminctl. Ensure membership now.
    if ! dseditgroup -o checkmember -m "$TARGET_USER" admin &>/dev/null; then
        print_info "Adding '$TARGET_USER' to the admin group (required by Homebrew)..."
        sudo dseditgroup -o edit -a "$TARGET_USER" -t user admin
    fi
    # The Homebrew installer calls `sudo` internally to create /opt/homebrew.
    # When run via `sudo -u $TARGET_USER`, there is no TTY available for a
    # password prompt, so the sudo call inside the installer fails even for
    # admin users. Grant temporary passwordless sudo for the install only,
    # then remove the rule immediately afterwards.
    local _sudoers_tmp="/etc/sudoers.d/99-homebrew-${TARGET_USER}"
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TARGET_USER" | sudo tee "$_sudoers_tmp" >/dev/null
    sudo chmod 0440 "$_sudoers_tmp"
    # Run the official installer as the target user (brew refuses to run as
    # root). NONINTERACTIVE=1 skips the confirmation prompt.
    # We cd to /tmp first so the subprocess inherits a world-readable CWD —
    # the CWD of this script (e.g. /root or a root-owned dir) would cause
    # getcwd() to fail when the Homebrew script runs as the target user.
    ( cd /tmp && sudo -u "$TARGET_USER" -H bash -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' )
    sudo rm -f "$_sudoers_tmp"
    # Bring brew into the current shell so later installers can call it.
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
}

# Run any brew command as the user who owns /opt/homebrew ($TARGET_USER).
# brew refuses to run as root and all Homebrew files are owned by TARGET_USER,
# so bare `brew install` calls from this root-context script would fail with
# "not writable by your user". We cd to /tmp for a world-readable CWD.
brew_run() {
    ( cd /tmp && sudo -u "$TARGET_USER" -H /opt/homebrew/bin/brew "$@" )
}

install_homebrew() {
    print_header "Installing Homebrew (Apple Silicon)"
    ensure_homebrew
    # Wire shellenv into the target user's rc files. On Apple Silicon the
    # brew prefix is /opt/homebrew (on Intel it's /usr/local). We hardcode
    # the Apple Silicon path because check_os() already gated on arm64.
    local brew_env_str='# Homebrew Configuration
eval "$(/opt/homebrew/bin/brew shellenv)"'
    if sudo test -f "$TARGET_USER_HOME/.zshrc" && ! sudo grep -q '/opt/homebrew/bin/brew shellenv' "$TARGET_USER_HOME/.zshrc"; then
        printf '\n%s\n' "$brew_env_str" | sudo tee -a "$TARGET_USER_HOME/.zshrc" >/dev/null
    fi
    if sudo test -f "$TARGET_USER_HOME/.bashrc" && ! sudo grep -q '/opt/homebrew/bin/brew shellenv' "$TARGET_USER_HOME/.bashrc"; then
        printf '\n%s\n' "$brew_env_str" | sudo tee -a "$TARGET_USER_HOME/.bashrc" >/dev/null
    fi
    print_success "Homebrew installed and wired into shell init."
    POST_INSTALL_ACTIONS+=("brew")
}

# 6. Install Google Gemini CLI.
# Same NVM-based install as Ubuntu; the /usr/local/bin/gemini wrapper is
# portable because it just sources NVM and execs the real binary.
install_gemini_cli() {
    print_header "Installing Google Gemini CLI"
    local nvm_cmd
    nvm_cmd=$(nvm_env_prelude)

    print_info "Installing Gemini CLI via NPM..."
    # -H ensures HOME is TARGET_USER's home so npm cache/prefix resolve correctly.
    ( cd /tmp && sudo -u "$TARGET_USER" -H bash -c "$nvm_cmd; npm install -g @google/gemini-cli" )

    print_info "Making Gemini CLI globally available to all users..."
    sudo mkdir -p /usr/local/bin
    # The wrapper sources NVM (from the absolute NVM_DIR) so `gemini` lands on PATH
    # regardless of who calls /usr/local/bin/gemini (root, launchd, etc.).
    sudo tee /usr/local/bin/gemini >/dev/null <<EOF
#!/bin/bash
export NVM_DIR="${TARGET_USER_HOME}/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && source "\$NVM_DIR/nvm.sh"
exec gemini "\$@"
EOF
    sudo chmod +x /usr/local/bin/gemini

    print_success "Google Gemini CLI installed globally."
}

# 8. Install btop (System Monitor)
install_btop() {
    print_header "Installing btop (System Monitor)"
    ensure_homebrew
    brew_run install btop >/dev/null
    print_success "btop installed successfully."
}

# 9. Install asitop (Apple Silicon performance monitor — nvtop replacement).
# asitop reads Apple's powermetrics(8) output to show CPU/GPU/ANE utilization,
# power draw, and memory bandwidth in a top-like TUI. It's the closest
# equivalent to nvtop on Apple Silicon. Installed via pipx for isolation
# (asitop's powermetrics sampler runs with sudo).
install_asitop() {
    print_header "Installing asitop (Apple Silicon Monitor)"
    ensure_homebrew
    brew_run install pipx >/dev/null
    sudo -u "$TARGET_USER" pipx ensurepath >/dev/null 2>&1 || true
    sudo -u "$TARGET_USER" pipx install asitop >/dev/null 2>&1 || \
        sudo -u "$TARGET_USER" pipx upgrade asitop >/dev/null 2>&1 || true
    print_info "asitop requires sudo to run (it reads powermetrics)."
    print_success "asitop installed. Run with: sudo asitop"
}

# Back-compat shim: call sites in main() / menu still say install_nvtop.
# Delegating keeps the menu diff surgical until the full refactor lands.
install_nvtop() { install_asitop; }


# 14. Install Local LLM Support (Ollama, llama.cpp, Open-WebUI)
get_llama_repo_path() {
    echo "$TARGET_USER_HOME/llama.cpp"
}

get_llama_cache_path() {
    echo "$TARGET_USER_HOME/llama.cpp/models"
}

get_llama_runtime_pid_path() {
    echo "$TARGET_USER_HOME/.cache/llama-server.pid"
}

get_llama_runtime_log_path() {
    echo "$TARGET_USER_HOME/.cache/llama-server.log"
}

# ── launchd path helpers ──────────────────────────────────────────────────
# We use a system LaunchDaemon (not a per-user LaunchAgent) so llama-server
# starts at boot regardless of login — matching the Ubuntu systemd unit's
# behavior. The daemon runs as TARGET_USER via the plist's UserName key.
#
# Reverse-DNS label per Apple convention. The label is also the file's
# basename (minus .plist) by strong convention, and `launchctl print` uses
# <domain>/<label> addressing (e.g. `system/com.macos-prep.llama-server`).
get_llama_plist_label() {
    echo "com.macos-prep.llama-server"
}

get_llama_plist_path() {
    echo "/Library/LaunchDaemons/$(get_llama_plist_label).plist"
}

# Same helpers for ollama — used when we manage ollama via launchd rather
# than relying on the brew cask's bundled service.
get_ollama_plist_label() { echo "com.macos-prep.ollama"; }
get_ollama_plist_path()  { echo "/Library/LaunchDaemons/$(get_ollama_plist_label).plist"; }

# Launchd plists parse XML — unlike systemd's ExecStart single-quoted shell
# body, a plist <string> value cannot host shell metachars safely. We still
# validate that values injected into <string> elements don't contain XML
# special characters (&, <, >) we aren't escaping, and single quotes in
# case the value is later shuttled through a `bash -c` invocation.
validate_plist_program_argument() {
    local name="$1" value="$2"
    if [[ "$value" == *\<* || "$value" == *\>* || "$value" == *\&* ]]; then
        echo "❌ Refusing to write launchd plist: ${name} contains XML-reserved characters (<, >, &)." >&2
        echo "   Value: ${value}" >&2
        return 1
    fi
    if [[ "$value" == *\'* ]]; then
        echo "❌ Refusing to write launchd plist: ${name} contains a single quote." >&2
        echo "   Value: ${value}" >&2
        return 1
    fi
    return 0
}

# Back-compat alias for existing callers.
validate_systemd_execstart_args() { validate_plist_program_argument "$@"; }

# Find an openclaw LaunchAgent plist for the target user. `openclaw daemon
# install` drops a plist under ~/Library/LaunchAgents — the exact label
# depends on the openclaw release, so we glob for *openclaw*.plist and
# return the first match (or empty if none).
find_openclaw_launchagent() {
    local agents_dir="$TARGET_USER_HOME/Library/LaunchAgents"
    sudo test -d "$agents_dir" || return 1
    sudo find "$agents_dir" -maxdepth 1 -name '*openclaw*.plist' -print -quit 2>/dev/null
}

# Derive a launchd service-target string (gui/<uid>/<label>) for a plist file
# owned by the target user. Returns empty on miss — callers should guard.
openclaw_launchd_target() {
    local plist_path="$1"
    [[ -z "$plist_path" ]] && return 1
    local uid label
    uid=$(id -u "$TARGET_USER" 2>/dev/null)
    label=$(sudo /usr/libexec/PlistBuddy -c 'Print :Label' "$plist_path" 2>/dev/null || basename "$plist_path" .plist)
    [[ -z "$uid" || -z "$label" ]] && return 1
    echo "gui/$uid/$label"
}

# Kick the openclaw LaunchAgent (if installed) so config changes take effect.
# Mirrors the Ubuntu `systemctl --user restart openclaw-gateway.service` step.
restart_openclaw_agent() {
    local plist target
    plist=$(find_openclaw_launchagent) || return 0
    [[ -z "$plist" ]] && return 0
    target=$(openclaw_launchd_target "$plist") || return 0
    [[ -z "$target" ]] && return 0
    sudo -u "$TARGET_USER" launchctl kickstart -k "$target" 2>/dev/null || true
}

# Emits the `source ~/.nvm/nvm.sh` prelude for the target user so Node-based
# tooling (openclaw, npm, npx) is on PATH inside `sudo -u "$TARGET_USER" bash -c`.
# Centralising this avoids 8+ copies of the same literal scattered through the
# script and keeps the TARGET_USER_HOME interpolation in one place.
nvm_env_prelude() {
    # shellcheck disable=SC2016  # $NVM_DIR is intentionally unexpanded — the caller's shell resolves it.
    printf 'export NVM_DIR=%q; [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"' \
        "$TARGET_USER_HOME/.nvm"
}

get_librechat_port() {
    local configured_port="${LIBRECHAT_PORT:-3080}"

    if sudo test -f "$TARGET_USER_HOME/LibreChat/.env"; then
        local detected_port
        detected_port=$(sudo grep "^PORT=" "$TARGET_USER_HOME/LibreChat/.env" | head -n 1 | cut -d'=' -f2 | tr -d '\r')
        if [[ -n "$detected_port" ]]; then
            configured_port="$detected_port"
        fi
    fi

    echo "$configured_port"
}

get_openclaw_port() {
    local configured_port="${OPENCLAW_PORT:-18789}"

    if sudo test -f "$TARGET_USER_HOME/.openclaw/openclaw.json"; then
        local detected_port
        detected_port=$(sudo jq -r '.gateway.port // 18789' "$TARGET_USER_HOME/.openclaw/openclaw.json" 2>/dev/null)
        if [[ -n "$detected_port" && "$detected_port" != "null" ]]; then
            configured_port="$detected_port"
        fi
    fi

    echo "$configured_port"
}

wait_for_http_200() {
    local url="$1"
    local attempts="${2:-30}"
    local delay="${3:-2}"
    local status=""

    for ((i = 0; i < attempts; i++)); do
        status=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
        if [[ "$status" == "200" ]]; then
            return 0
        fi
        sleep "$delay"
    done

    return 1
}

wait_for_http_bound() {
    local url="$1"
    local attempts="${2:-30}"
    local delay="${3:-2}"
    local status=""

    for ((i = 0; i < attempts; i++)); do
        status=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
        if [[ "$status" != "000" ]]; then
            return 0
        fi
        sleep "$delay"
    done

    return 1
}

# macOS port: CUDA/cuDNN/NVIDIA Container Toolkit are Linux-only. The
# corresponding menu items (7, 9, 10, 12, 13) are hidden on Apple Silicon and
# these helpers are stubs so call sites that were written for the Ubuntu build
# can still reference them without needing case-by-case removal.
#
# On Apple Silicon, Metal acceleration is built into the OS — nothing to
# detect, install, or add to PATH/LD_LIBRARY_PATH. `ensure_cuda_env_for_current_shell`
# and `require_nvidia_module_loaded` therefore succeed unconditionally when
# called from the Metal ("llama_cuda" backend choice) build path.

get_cuda_nvcc_path() { return 1; }

require_nvidia_module_loaded() {
    # Metal is always available on Apple Silicon; no kernel module to check.
    return 0
}

ensure_cuda_env_for_current_shell() {
    # No CUDA env vars needed for Metal builds.
    return 0
}

get_nvidia_ctk_path() { return 1; }
ensure_nvidia_ctk_for_current_shell() { return 1; }

get_cudnn_library_path() { return 1; }
has_cudnn_available() { return 1; }
ensure_cudnn_env_for_current_shell() { return 0; }

detect_local_ai_components() {
    local llama_repo_present=false
    local llama_binary_present=false
    local llama_partial=false
    local llama_plist_path
    llama_plist_path="$(get_llama_plist_path)"
    if sudo test -d "$(get_llama_repo_path)"; then llama_repo_present=true; fi
    if command -v llama-server &>/dev/null; then llama_binary_present=true; fi
    # A stale plist at /Library/LaunchDaemons counts as a "partial install"
    # the same way a stray llama-server.service file did on Ubuntu.
    if [[ "$llama_repo_present" == true || "$llama_binary_present" == true ]] || sudo test -f "$llama_plist_path"; then
        llama_partial=true
    fi
    LLAMA_COMPONENT_STATUS=$(derive_component_status "$([[ "$llama_repo_present" == true && "$llama_binary_present" == true ]] && echo true || echo false)" "$llama_partial")

    local ollama_binary_present=false
    local ollama_partial=false
    local ollama_plist_path
    ollama_plist_path="$(get_ollama_plist_path)"
    if command -v ollama &>/dev/null; then ollama_binary_present=true; fi
    if [[ "$ollama_binary_present" == true ]] || sudo test -f "$ollama_plist_path"; then
        ollama_partial=true
    fi
    OLLAMA_COMPONENT_STATUS=$(derive_component_status "$ollama_binary_present" "$ollama_partial")

    local openwebui_container=false
    local openwebui_healthy=true
    if command -v docker &>/dev/null && sudo docker ps -aq -f name=^open-webui$ 2>/dev/null | grep -q .; then
        openwebui_container=true
        if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^open-webui$'; then
            if ! wait_for_http_200 "http://127.0.0.1:8081/health" 1 1 && ! wait_for_http_200 "http://127.0.0.1:8081/" 1 1; then
                openwebui_healthy=false
            fi
        else
            openwebui_healthy=false
        fi
    fi
    OPENWEBUI_COMPONENT_STATUS=$(derive_component_status "$openwebui_container" "$openwebui_container" "$openwebui_healthy")

    local librechat_dir=false
    local librechat_partial=false
    local librechat_healthy=true
    if sudo test -d "$TARGET_USER_HOME/LibreChat"; then librechat_dir=true; fi
    if [[ "$librechat_dir" == true ]]; then librechat_partial=true; fi
    if command -v docker &>/dev/null && sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qi 'librechat'; then
        librechat_partial=true
        if ! wait_for_http_200 "http://127.0.0.1:$(get_librechat_port)/" 1 1; then
            librechat_healthy=false
        fi
    fi
    LIBRECHAT_COMPONENT_STATUS=$(derive_component_status "$librechat_dir" "$librechat_partial" "$librechat_healthy")

    local openclaw_binary=false
    local openclaw_config=false
    local openclaw_partial=false
    # Binary lives in the NVM bin directory, not ~/.local/bin
    local oc_bin_detected
    oc_bin_detected=$(sudo -u "$TARGET_USER" bash -c \
        "$(nvm_env_prelude); command -v openclaw 2>/dev/null || true" 2>/dev/null || true)
    if [[ -n "$oc_bin_detected" ]] || sudo test -f "$TARGET_USER_HOME/.local/bin/openclaw"; then openclaw_binary=true; fi
    if sudo test -d "$TARGET_USER_HOME/.openclaw"; then openclaw_config=true; fi
    if [[ "$openclaw_binary" == true || "$openclaw_config" == true ]]; then openclaw_partial=true; fi
    OPENCLAW_COMPONENT_STATUS=$(derive_component_status "$([[ "$openclaw_binary" == true && "$openclaw_config" == true ]] && echo true || echo false)" "$openclaw_partial")
}

cleanup_llama_component() {
    print_info "Hard-resetting llama.cpp before rerun..."
    local plist_path plist_label
    plist_path="$(get_llama_plist_path)"
    plist_label="$(get_llama_plist_label)"
    # `launchctl bootout system/<label>` is the modern replacement for
    # `launchctl unload` and matches the bootstrap command we use at install.
    # Both tolerate the daemon not existing; we still || true for safety.
    sudo launchctl bootout "system/$plist_label" 2>/dev/null || true
    # Legacy fallback (macOS <12, or when bootstrap wasn't used at install).
    sudo launchctl unload "$plist_path" 2>/dev/null || true
    local llama_pid_file
    llama_pid_file=$(get_llama_runtime_pid_path)
    if sudo test -f "$llama_pid_file"; then
        local llama_pid
        llama_pid=$(sudo cat "$llama_pid_file" 2>/dev/null || true)
        if [[ "$llama_pid" =~ ^[0-9]+$ ]]; then
            sudo kill "$llama_pid" 2>/dev/null || true
        fi
        sudo rm -f "$llama_pid_file"
    fi
    sudo rm -f "$(get_llama_runtime_log_path)"
    sudo rm -f "$plist_path"
    # launchd has no `daemon-reload` — bootout already unregistered the job.
    sudo rm -rf "$(get_llama_repo_path)"
}

cleanup_ollama_component() {
    print_info "Hard-resetting Ollama before rerun..."
    local ollama_plist_path ollama_plist_label
    ollama_plist_path="$(get_ollama_plist_path)"
    ollama_plist_label="$(get_ollama_plist_label)"
    # Stop any launchd daemon we previously installed.
    sudo launchctl bootout "system/$ollama_plist_label" 2>/dev/null || true
    sudo launchctl unload "$ollama_plist_path" 2>/dev/null || true
    sudo rm -f "$ollama_plist_path"
    # If ollama was installed via brew cask, it also ships its own launchd
    # plist at ~/Library/LaunchAgents — brew handles that via `brew services`,
    # so we defer to the cask uninstaller there.
    brew_run services stop ollama >/dev/null 2>&1 || true
    brew_run uninstall --cask ollama >/dev/null 2>&1 || true
    # Defensive: remove any stray binaries/data directories.
    sudo rm -f /usr/local/bin/ollama /opt/homebrew/bin/ollama
    sudo rm -rf "$TARGET_USER_HOME/.ollama"
}

cleanup_openwebui_component() {
    print_info "Hard-resetting Open-WebUI before rerun..."
    # Docker on macOS = OrbStack (no sudo needed — per-user socket).
    docker stop open-webui &>/dev/null || true
    docker rm open-webui &>/dev/null || true
    docker volume rm open-webui &>/dev/null || true
    # Auto-update LaunchDaemon (created by install_local_llm on macOS).
    sudo launchctl bootout "system/com.macos-prep.open-webui-update" 2>/dev/null || true
    sudo rm -f /Library/LaunchDaemons/com.macos-prep.open-webui-update.plist /usr/local/bin/update-open-webui.sh
}

cleanup_librechat_component() {
    print_info "Hard-resetting LibreChat before rerun..."
    if sudo test -d "$TARGET_USER_HOME/LibreChat"; then
        sudo -u "$TARGET_USER" bash -c "cd \"$TARGET_USER_HOME/LibreChat\" && docker compose down -v" >/dev/null 2>&1 || true
    fi
    sudo rm -rf "$TARGET_USER_HOME/LibreChat"
    sudo rm -f /usr/local/bin/update-librechat.sh
}

cleanup_openclaw_component() {
    print_info "Hard-resetting OpenClaw before rerun..."
    # macOS per-user LaunchAgent (no DBUS/XDG dance — launchd uses gui/<uid>).
    local uid
    uid="$(id -u "$TARGET_USER" 2>/dev/null || echo 0)"
    sudo -u "$TARGET_USER" launchctl bootout "gui/$uid/com.macos-prep.openclaw" 2>/dev/null || true
    sudo -u "$TARGET_USER" launchctl unload "$TARGET_USER_HOME/Library/LaunchAgents/com.macos-prep.openclaw.plist" 2>/dev/null || true
    sudo rm -rf "$TARGET_USER_HOME/.openclaw" "$TARGET_USER_HOME/.config/openclaw" "$TARGET_USER_HOME/.local/share/openclaw"
    sudo rm -f "$TARGET_USER_HOME/.local/bin/openclaw"
    sudo rm -f "$TARGET_USER_HOME/Library/LaunchAgents/com.macos-prep.openclaw.plist"
}

verify_llama_component() {
    if ! command -v llama-server &>/dev/null; then
        echo "❌ llama.cpp verification failed: llama-server binary is missing."
        return 1
    fi

    # If the LaunchDaemon exists, wait for the HTTP endpoint to come up.
    if sudo test -f "$(get_llama_plist_path)"; then
        print_info "Waiting for llama.cpp server to initialize (timeout 5m)..."
        if ! wait_for_llama_server_ready "service" 150 2 "$(get_llama_runtime_log_path)"; then
            return 1
        fi
    fi

    print_success "llama.cpp verification passed."
    return 0
}

verify_ollama_component() {
    if ! command -v ollama &>/dev/null; then
        echo "❌ Ollama verification failed: ollama binary is missing."
        return 1
    fi

    print_info "Waiting for Ollama API to respond (timeout 60s)..."
    if ! wait_for_http_200 "http://127.0.0.1:11434/api/tags" 30 2; then
        echo "❌ Ollama verification failed: API did not return HTTP 200."
        return 1
    fi

    print_success "Ollama verification passed."
    return 0
}

verify_openwebui_component() {
    if ! command -v docker &>/dev/null; then
        echo "❌ Open-WebUI verification failed: Docker is not installed."
        return 1
    fi
    if ! sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^open-webui$'; then
        echo "❌ Open-WebUI verification failed: container 'open-webui' does not exist."
        return 1
    fi

    print_info "Waiting for Open-WebUI to initialize (timeout 60s)..."
    if ! wait_for_http_200 "http://127.0.0.1:8081/health" 30 2 && ! wait_for_http_200 "http://127.0.0.1:8081/" 30 2; then
        echo "❌ Open-WebUI verification failed: HTTP endpoint did not return 200."
        return 1
    fi

    print_success "Open-WebUI verification passed."
    return 0
}

verify_librechat_component() {
    local lc_port

    lc_port=$(get_librechat_port)
    if ! sudo test -d "$TARGET_USER_HOME/LibreChat"; then
        echo "❌ LibreChat verification failed: repo directory is missing."
        return 1
    fi

    print_info "Waiting for LibreChat to initialize (timeout 60s)..."
    if ! wait_for_http_200 "http://127.0.0.1:${lc_port}/" 30 2; then
        echo "❌ LibreChat verification failed: frontend did not return HTTP 200 on port ${lc_port}."
        return 1
    fi

    print_success "LibreChat verification passed."
    return 0
}

verify_openclaw_component() {
    local oc_port

    oc_port=$(get_openclaw_port)
    local oc_bin
    oc_bin=$(sudo -u "$TARGET_USER" bash -c "$(nvm_env_prelude); command -v openclaw 2>/dev/null || true")
    if [[ -z "$oc_bin" ]] && ! sudo test -f "$TARGET_USER_HOME/.local/bin/openclaw"; then
        echo "❌ OpenClaw verification failed: binary is missing."
        return 1
    fi
    if ! sudo test -f "$TARGET_USER_HOME/.openclaw/openclaw.json"; then
        echo "❌ OpenClaw verification failed: config file is missing."
        return 1
    fi

    print_info "Waiting for OpenClaw gateway to initialize (timeout 60s)..."
    if ! wait_for_http_bound "http://127.0.0.1:${oc_port}/" 30 2; then
        echo "❌ OpenClaw verification failed: gateway did not bind on port ${oc_port}."
        return 1
    fi

    print_success "OpenClaw verification passed."
    return 0
}

llama_requires_model_selection() {
    if [[ "$LLAMA_COMPONENT_ACTION" == "skip" ]]; then
        return 1
    fi

    if [[ "$RUN_LLAMA_BENCH" == "y" || "$LOAD_DEFAULT_MODEL" == "y" || "$INSTALL_LLAMA_SERVICE" == "y" || "$EXPOSE_LLM_ENGINE" == "y" ]]; then
        return 0
    fi

    if [[ "$FRONTEND_BACKEND_TARGET" == "llama" && ("$OPENWEBUI_COMPONENT_ACTION" != "skip" || "$LIBRECHAT_COMPONENT_ACTION" != "skip") ]]; then
        return 0
    fi

    return 1
}

llama_should_launch_server() {
    [[ "$LLAMA_COMPONENT_ACTION" == "skip" ]] && return 1

    # Service install doesn't require a pre-selected model — llama-server will pull on first start
    if [[ "$INSTALL_LLAMA_SERVICE" == "y" ]]; then
        return 0
    fi

    # Transient run modes need a model choice to know what to launch
    [[ -z "$LLM_DEFAULT_MODEL_CHOICE" ]] && return 1

    if [[ "$LOAD_DEFAULT_MODEL" == "y" || "$EXPOSE_LLM_ENGINE" == "y" ]]; then
        return 0
    fi

    if [[ "$FRONTEND_BACKEND_TARGET" == "llama" && ("$OPENWEBUI_COMPONENT_ACTION" != "skip" || "$LIBRECHAT_COMPONENT_ACTION" != "skip") ]]; then
        return 0
    fi

    return 1
}

build_llama_hf_args() {
    local hf_args=""

    case "$LLM_DEFAULT_MODEL_CHOICE" in
        5)
            hf_args="--hf-repo raincandy-u/TinyStories-656K-Q8_0-GGUF --hf-file tinystories-656k-q8_0.gguf"
            ;;
        1 | 2 | 3 | 4)
            if [[ -n "$SELECTED_MODEL_REPO" ]]; then
                hf_args="--hf-repo $SELECTED_MODEL_REPO"
            fi
            ;;
        6)
            if [[ -n "$LLAMACPP_MODEL_REPO" ]]; then
                if [[ "$LLAMACPP_MODEL_REPO" == *:* ]]; then
                    local custom_repo="${LLAMACPP_MODEL_REPO%%:*}"
                    local custom_file="${LLAMACPP_MODEL_REPO#*:}"
                    hf_args="--hf-repo $custom_repo --hf-file $custom_file"
                else
                    hf_args="--hf-repo $LLAMACPP_MODEL_REPO"
                fi
            fi
            ;;
    esac

    echo "$hf_args"
}

# Downloads a HuggingFace GGUF model with a curl progress bar.
# Parses --hf-repo / --hf-file from the hf_args string.
# Prints the local GGUF path on success; empty if skipped or failed.
download_hf_model_with_progress() {
    local hf_args_str="$1"
    local cache_dir="$2"
    local hf_repo="" hf_file=""

    # Parse --hf-repo and --hf-file out of the args string
    if [[ "$hf_args_str" =~ --hf-repo[[:space:]]+([^[:space:]]+) ]]; then
        hf_repo="${BASH_REMATCH[1]}"
    fi
    if [[ "$hf_args_str" =~ --hf-file[[:space:]]+([^[:space:]]+) ]]; then
        hf_file="${BASH_REMATCH[1]}"
    fi

    # Not an HF repo download (e.g. bare --model /path)
    [[ -z "$hf_repo" ]] && return 0

    # Resolve HF token if available (needed before API query)
    local hf_token=""
    if sudo test -f "$TARGET_USER_HOME/.env.secrets"; then
        hf_token=$(sudo bash -c "source \"$TARGET_USER_HOME/.env.secrets\" 2>/dev/null && echo \"\$HF_TOKEN\"" | tr -d '\r')
    fi

    # If no specific file, query HF API — prefer Q4_K_M, fall back to first gguf.
    # We capture the HTTP status so we can give a useful hint when the repo is
    # gated (401/403) or missing (404) instead of silently falling through.
    if [[ -z "$hf_file" ]]; then
        print_info "Querying HuggingFace API for GGUF files in '$hf_repo'..." >&2
        local api_response="" api_http=""
        local api_url="https://huggingface.co/api/models/$hf_repo"
        local curl_args=(-s -L -o /dev/null -w '%{http_code}')
        [[ -n "$hf_token" ]] && curl_args+=(-H "Authorization: Bearer $hf_token")
        api_http=$(curl "${curl_args[@]}" "$api_url" 2>/dev/null || echo "000")
        if [[ "$api_http" == "200" ]]; then
            if [[ -n "$hf_token" ]]; then
                api_response=$(curl -sfL -H "Authorization: Bearer $hf_token" "$api_url" 2>/dev/null || true)
            else
                api_response=$(curl -sfL "$api_url" 2>/dev/null || true)
            fi
        fi
        hf_file=$(echo "$api_response" | jq -r '.siblings[].rfilename | select(endswith(".gguf"))' 2>/dev/null | grep -i "q4_k_m" | head -1 || true)
        if [[ -z "$hf_file" ]]; then
            hf_file=$(echo "$api_response" | jq -r '.siblings[].rfilename | select(endswith(".gguf"))' 2>/dev/null | head -1 || true)
        fi
    fi

    if [[ -z "$hf_file" ]]; then
        case "${api_http:-}" in
            401 | 403)
                if [[ -n "$hf_token" ]]; then
                    echo "❌ HuggingFace returned HTTP ${api_http} for '$hf_repo' — token lacks access to this gated/private repo." >&2
                else
                    echo "❌ '$hf_repo' is gated or private — set HF_TOKEN in ~/.env.secrets and accept the repo's licence on huggingface.co." >&2
                fi
                return 1
                ;;
            404)
                echo "❌ HuggingFace returned 404 for '$hf_repo' — repo does not exist." >&2
                return 1
                ;;
        esac
        echo "⚠️  Could not resolve GGUF filename — llama.cpp will download automatically on first start." >&2
        return 0
    fi

    sudo -u "$TARGET_USER" mkdir -p "$cache_dir"
    local dest_path="$cache_dir/$hf_file"

    # Check if the exact file is already cached and non-empty — skip download if so.
    # We match on the resolved filename, not just any .gguf, so switching models
    # (e.g. gemma → qwen) correctly triggers a fresh download of the new file.
    if sudo test -s "$dest_path"; then
        print_info "Model already cached: $(basename "$dest_path") — skipping download." >&2
        echo "$dest_path"
        return 0
    fi

    # Try LAN mirror first (scp from LOCAL_MIRROR_BASE/models/<filename>)
    if [[ -n "${LOCAL_MIRROR_BASE:-}" ]]; then
        local mirror_src="${LOCAL_MIRROR_BASE}/models/${hf_file}"
        print_info "Trying LAN mirror: ${mirror_src}" >&2
        if sudo -u "$TARGET_USER" scp -q -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$mirror_src" "$dest_path" 2>/dev/null; then
            print_success "Copied from LAN mirror: $(basename "$dest_path")" >&2
            echo "$dest_path"
            return 0
        fi
        print_info "Not found on LAN mirror — falling back to HuggingFace." >&2
    fi

    local download_url="https://huggingface.co/$hf_repo/resolve/main/$hf_file"

    print_info "Downloading model (this may take several minutes)..." >&2
    printf "%b\n" "  Repo : \e[1;36m$hf_repo\e[0m" >&2
    printf "%b\n" "  File : \e[1;36m$hf_file\e[0m" >&2

    # Pass token via env + URLs via positional args so no user-controlled
    # string ever undergoes shell evaluation. Prevents command injection via
    # malicious HF_TOKEN / repo / filename.
    local dl_status=0
    if [[ -n "$hf_token" ]]; then
        sudo -u "$TARGET_USER" env HF_TOKEN="$hf_token" bash -c \
            'curl -L --progress-bar --fail -H "Authorization: Bearer $HF_TOKEN" -o "$1" "$2"' \
            _ "$dest_path" "$download_url" ||
            dl_status=$?
    else
        sudo -u "$TARGET_USER" bash -c \
            'curl -L --progress-bar --fail -o "$1" "$2"' \
            _ "$dest_path" "$download_url" ||
            dl_status=$?
    fi
    echo "" >&2

    if [[ $dl_status -ne 0 ]]; then
        sudo -u "$TARGET_USER" rm -f "$dest_path" 2>/dev/null || true
        echo "❌ Model download failed (exit $dl_status). llama.cpp will retry on first start." >&2
        return 0
    fi

    print_success "Downloaded: $(basename "$dest_path")" >&2
    echo "$dest_path"
    return 0
}

# Print a one-line unified-memory progress bar to stderr (overwrites previous
# line). On Apple Silicon the GPU shares system RAM — there's no discrete VRAM
# counter to poll, so this is a compatibility shim that shows elapsed time
# only. Target is passed for API compatibility with the Ubuntu callers.
# Usage: print_vram_progress <baseline_mb> <target_mb> <elapsed_s>
print_vram_progress() {
    local target_mb="$2" elapsed="$3"
    local target_gb
    target_gb=$(awk "BEGIN { printf \"%.1f\", $target_mb / 1024.0 }")
    printf "\r\e[1;36mℹ️  Loading model (target ~%s GB unified memory)... %ds elapsed\e[0m\e[K" \
        "$target_gb" "$elapsed" >&2
}

wait_for_llama_server_ready() {
    local run_mode="${1:-service}"
    local attempts="${2:-45}"
    local delay="${3:-2}"
    local log_file="${4:-$(get_llama_runtime_log_path)}"
    local health_status=""
    local models_status=""
    local root_status=""
    local last_progress=""
    local elapsed=0

    # Unified memory load progress: compute target size for the progress label.
    # Apple Silicon has no discrete VRAM counter — print_vram_progress falls
    # back to an elapsed-time message with the target GB.
    local baseline_mb=0 target_mb=0 vram_progress=false
    local _model_gb
    _model_gb=$(get_model_weight_gb "${LLAMA_VRAM_TIER:-16}")
    if [[ -n "$_model_gb" ]]; then
        target_mb=$(awk "BEGIN { printf \"%d\", $_model_gb * 1024 }")
        vram_progress=true
    fi

    for ((i = 0; i < attempts; i++)); do
        health_status=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/health" 2>/dev/null || echo "000")
        models_status=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/v1/models" 2>/dev/null || echo "000")
        root_status=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/" 2>/dev/null || echo "000")

        if [[ "$health_status" == "200" || "$models_status" == "200" || "$root_status" == "200" ]]; then
            printf "\r\e[K"
            return 0
        fi

        # When running as a LaunchDaemon, detect a crashed/exited job early
        # instead of waiting the full timeout. `launchctl print system/<label>`
        # returns non-zero if the job isn't bootstrapped; when bootstrapped,
        # its output contains `state = running` while the process is alive.
        if [[ "$run_mode" == "service" ]] && sudo launchctl print "system/$(get_llama_plist_label)" >/dev/null 2>&1; then
            local _llama_state
            _llama_state=$(sudo launchctl print "system/$(get_llama_plist_label)" 2>/dev/null | awk -F '=' '/state = / {gsub(/[[:space:]]/,"",$2); print $2; exit}')
            if [[ -n "$_llama_state" && "$_llama_state" != "running" ]]; then
                printf "\r\e[K"
                echo "❌ llama.cpp verification failed: LaunchDaemon state is '$_llama_state'."
                sudo launchctl print "system/$(get_llama_plist_label)" 2>/dev/null | head -n 60 || true # display-only diagnostics
                return 1
            fi
        fi

        if [[ -f "$log_file" ]]; then
            local download_progress
            download_progress=$(grep -oE '([0-9]{1,3}(\.[0-9]+)?)%' "$log_file" | tail -n 1 || true) # optional: log may not have progress yet
            if [[ -n "$download_progress" ]]; then
                if [[ "$download_progress" != "$last_progress" ]]; then
                    printf "\r\e[1;36mℹ️  llama.cpp model download: %s\e[0m\e[K" "$download_progress"
                    last_progress="$download_progress"
                fi
            elif [[ "$vram_progress" == true ]]; then
                print_vram_progress "$baseline_mb" "$target_mb" "$elapsed"
            else
                printf "\r\e[1;36mℹ️  llama.cpp server starting... %ds elapsed\e[0m\e[K" "$elapsed" >&2
            fi
        else
            if [[ "$vram_progress" == true ]]; then
                print_vram_progress "$baseline_mb" "$target_mb" "$elapsed"
            else
                printf "\r\e[1;36mℹ️  llama.cpp server starting... %ds elapsed\e[0m\e[K" "$elapsed" >&2
            fi
        fi

        sleep "$delay"
        elapsed=$((elapsed + delay))
    done

    printf "\r\e[K"
    echo "❌ llama.cpp verification failed: server did not become ready on port 8080."
    if [[ -f "$log_file" ]]; then
        echo "Last log lines:"
        sudo tail -n 40 "$log_file" 2>/dev/null || true # display-only: file may be gone
    elif [[ "$run_mode" == "service" ]]; then
        # launchd writes to the StandardOutPath/StandardErrorPath set on the plist.
        # Fall back to `launchctl print` so the user sees the job's last state.
        sudo launchctl print "system/$(get_llama_plist_label)" 2>/dev/null | head -n 60 || true # display-only diagnostics
    fi
    return 1
}

start_llama_server_transient() {
    local hf_args="$1"
    local llama_host_args="$2"
    # $3 (build_variant) retained for API compatibility with the Ubuntu caller
    # but unused on macOS — Metal is ubiquitous and needs no env setup.
    local llama_cache_dir
    local llama_pid_file
    local llama_log_file
    local shell_prefix

    llama_cache_dir=$(get_llama_cache_path)
    llama_pid_file=$(get_llama_runtime_pid_path)
    llama_log_file=$(get_llama_runtime_log_path)

    sudo mkdir -p "$TARGET_USER_HOME/.cache"
    sudo chown "$TARGET_USER":"staff" "$TARGET_USER_HOME/.cache"
    sudo -u "$TARGET_USER" mkdir -p "$llama_cache_dir"

    if sudo test -f "$llama_pid_file"; then
        local existing_pid
        existing_pid=$(sudo cat "$llama_pid_file" 2>/dev/null || true)
        if [[ "$existing_pid" =~ ^[0-9]+$ ]]; then
            sudo kill "$existing_pid" 2>/dev/null || true
        fi
        sudo rm -f "$llama_pid_file"
    fi
    sudo rm -f "$llama_log_file"

    shell_prefix="cd \"$TARGET_USER_HOME\"; export TARGET_USER_HOME=\"$TARGET_USER_HOME\"; [ -f \"$TARGET_USER_HOME/.env.secrets\" ] && source \"$TARGET_USER_HOME/.env.secrets\"; export HOME=\"$TARGET_USER_HOME\"; export LLAMA_CACHE=\"$llama_cache_dir\";"
    sudo -u "$TARGET_USER" bash -c "$shell_prefix nohup /usr/local/bin/llama-server $hf_args $llama_host_args > \"$llama_log_file\" 2>&1 < /dev/null & echo \$! > \"$llama_pid_file\""

    print_success "llama.cpp started in the background on port 8080."
    print_info "Waiting for llama.cpp to finish loading the selected model (timeout 5m)..."
    if ! wait_for_llama_server_ready "transient" 150 2 "$llama_log_file"; then
        return 1
    fi

    return 0
}

# ─── Context & Memory Configuration ──────────────────────────────

# Approximate model weight sizes (GB) per Apple Silicon UMA tier. The featured
# chat model from 24 GB upward is Jackrong/Qwopus3.5-27B-v3-GGUF — the quant
# level scales up with UMA headroom (see get_qwopus_quant_filename above).
# Used to estimate remaining unified memory for KV cache; conservative.
get_model_weight_gb() {
    local vram_tier="${1:-24}"
    case "$vram_tier" in
        24)  echo "13" ;;  # Qwopus3.5-27B Q3_K_M (~12.5 GB)
        32)  echo "16" ;;  # Qwopus3.5-27B Q4_K_M (~16 GB)
        48)  echo "19" ;;  # Qwopus3.5-27B Q5_K_M (~19 GB)
        64)  echo "22" ;;  # Qwopus3.5-27B Q6_K  (~22 GB)
        96)  echo "29" ;;  # Qwopus3.5-27B Q8_0  (~29 GB)
        128) echo "54" ;;  # Qwopus3.5-27B BF16  (~54 GB)
        *)   echo "16" ;;
    esac
}

# n_layers per default tier model — used in the KV-cache formula. Qwopus3.5-27B
# shares the Qwen3-27B architecture (64 layers) across all tiers; the fallback
# uses a conservative 48 for off-tier or test models.
get_model_n_layers() {
    local vram_tier="${1:-24}"
    case "$vram_tier" in
        24|32|48|64|96|128) echo "64" ;;
        *) echo "48" ;;
    esac
}

# Smart defaults for context size and cache type per Apple Silicon UMA tier.
# Minimum context = 65536 for all tiers (OpenClaw needs ≥65K). KV cache is
# q4_0 everywhere — Metal handles quantized KV cache natively and it keeps
# long-context runs resident without blowing the wired-memory cap. Ubatch
# scales with available UMA for faster prompt ingest at higher tiers.
get_context_defaults() {
    local vram_tier="${1:-24}"
    case "$vram_tier" in
        24)
            CTX_DEFAULT=65536
            CTK_DEFAULT="q4_0"
            UBATCH_DEFAULT=1024
            ;;
        32)
            CTX_DEFAULT=65536
            CTK_DEFAULT="q4_0"
            UBATCH_DEFAULT=2048
            ;;
        48)
            CTX_DEFAULT=131072
            CTK_DEFAULT="q4_0"
            UBATCH_DEFAULT=2048
            ;;
        64)
            CTX_DEFAULT=131072
            CTK_DEFAULT="q4_0"
            UBATCH_DEFAULT=2048
            ;;
        96)
            CTX_DEFAULT=262144
            CTK_DEFAULT="q4_0"
            UBATCH_DEFAULT=4096
            ;;
        128)
            CTX_DEFAULT=262144
            CTK_DEFAULT="q4_0"
            UBATCH_DEFAULT=4096
            ;;
        *)
            CTX_DEFAULT=65536
            CTK_DEFAULT="q4_0"
            UBATCH_DEFAULT=1024
            ;;
    esac
}

# Bytes per KV cache element for a given cache type
cache_type_bytes() {
    case "$1" in
        f32) echo "4.0" ;;
        f16 | bf16) echo "2.0" ;;
        q8_0) echo "1.0" ;;
        q5_0 | q5_1) echo "0.625" ;;
        q4_0 | q4_1 | iq4_nl) echo "0.5" ;;
        turbo4) echo "0.5" ;;   # optimised 4-bit KV for high-context
        turbo3) echo "0.375" ;; # extreme 3-bit KV for maximum context
        *) echo "2.0" ;;
    esac
}

# Estimate total VRAM usage: model weights + KV cache + runtime overhead
# Returns: "total_gb model_gb kv_gb overhead_gb"
#
# KV cache formula (grounded in llama.cpp allocator):
#   kv_bytes = 2 * n_ctx * n_layers * n_kv_heads * head_dim * bytes_per_elem
# Modern GQA models use n_kv_heads * head_dim ≈ 1024, so:
#   kv_gb ≈ (n_ctx/1024) * n_layers * bytes_per / 512 * padding_factor
# Calibrated against real llama.cpp allocations on 32B @ 80K q4_0 = 5.6 GB.
estimate_vram_usage() {
    local model_gb="$1"
    local ctx_size="$2"
    local ctk="$3"
    local n_layers="${4:-48}"

    local bytes_per
    bytes_per=$(cache_type_bytes "$ctk")

    # Runtime overhead grows modestly with model size (compute buffers,
    # flash-attn workspace, graph tensors). ~0.8 GB for 7B, ~1.5 GB for 70B.
    local overhead
    overhead=$(awk "BEGIN { printf \"%.1f\", 0.6 + $model_gb * 0.020 }")

    # KV cache: base formula + 12% for llama.cpp buffer padding/alignment
    local kv_gb
    kv_gb=$(awk "BEGIN { printf \"%.1f\", ($ctx_size / 1024.0) * $n_layers * $bytes_per / 512.0 * 1.12 }")

    local total_gb
    total_gb=$(awk "BEGIN { printf \"%.1f\", $model_gb + $kv_gb + $overhead }")
    echo "$total_gb $model_gb $kv_gb $overhead"
}

# Interactive sub-menu for context size, KV cache type, CPU MoE offload,
# flash attention, and ubatch.  Shows a live VRAM estimate.
# K and V cache types are always kept identical (mixing disables GPU offload).
configure_context_memory() {
    local target_backend="$1"
    local vram_tier="${LLAMA_VRAM_TIER:-16}"

    # Only applies to llama.cpp backends
    if [[ "$target_backend" == "ollama" ]]; then
        return 0
    fi

    # Use actual detected hardware capacity for the OOM check.
    # For CUDA builds use GPU VRAM; for CPU-only use system RAM.
    # Fall back to the tier bucket if detection didn't run yet.
    local hw_capacity
    if [[ "$target_backend" == "llama_cuda" && "${GPU_VRAM_GB:-0}" -gt 0 ]]; then
        hw_capacity="$GPU_VRAM_GB"
    elif [[ "$target_backend" == "llama_cpu" && "${SYSTEM_RAM_GB:-0}" -gt 0 ]]; then
        hw_capacity="$SYSTEM_RAM_GB"
    else
        hw_capacity="$vram_tier"
    fi

    local model_gb n_layers
    model_gb=$(get_model_weight_gb "$vram_tier")
    n_layers=$(get_model_n_layers "$vram_tier")
    get_context_defaults "$vram_tier"

    # Apply headless defaults if set, otherwise use smart defaults
    local ctx="${LLAMA_CTX_SIZE:-$CTX_DEFAULT}"
    local ctk="${LLAMA_CACHE_TYPE_K:-$CTK_DEFAULT}"
    local cpu_moe="${LLAMA_CPU_MOE:-y}"
    local ubatch="${LLAMA_UBATCH:-$UBATCH_DEFAULT}"

    # Flash attention: on by default for CUDA, off for CPU-only
    local flash_attn="$LLAMA_FLASH_ATTN"
    if [[ "$target_backend" == "llama_cuda" && "$flash_attn" != "y" ]]; then
        flash_attn="y"
    fi

    local mlock="${LLAMA_MLOCK:-n}"
    local dio="${LLAMA_DIO:-n}"

    # GPU layers and auto-fit (CUDA only); pre-seeded from LLAMA_NGL/LLAMA_FIT globals
    local ngl="${LLAMA_NGL:-99}"
    local fit_mode="${LLAMA_FIT:-n}"
    local fit_ctx="${LLAMA_FIT_CTX:-}"

    if [[ "$HEADLESS_MODE" == true ]]; then
        [[ -n "$HEADLESS_CTX_SIZE" ]] && ctx="$HEADLESS_CTX_SIZE"
        [[ -n "$HEADLESS_CACHE_TYPE_K" ]] && ctk="$HEADLESS_CACHE_TYPE_K"
        [[ "$HEADLESS_CPU_MOE" == "y" ]] && cpu_moe="y"
        [[ -n "$HEADLESS_UBATCH" ]] && ubatch="$HEADLESS_UBATCH"
        LLAMA_CTX_SIZE="$ctx"
        LLAMA_CACHE_TYPE_K="$ctk"
        LLAMA_CACHE_TYPE_V="$ctk"
        LLAMA_CPU_MOE="$cpu_moe"
        LLAMA_FLASH_ATTN="$flash_attn"
        LLAMA_UBATCH="$ubatch"
        LLAMA_NGL="$ngl"
        return 0
    fi

    local ctx_options=("8192" "16384" "32768" "65536" "81920" "131072" "262144")
    local ctx_labels=("8K" "16K" "32K" "64K" "80K" "128K" "256K")

    local ctk_options=("f32" "f16" "bf16" "q8_0" "q5_1" "q5_0" "q4_1" "q4_0" "iq4_nl" "turbo4" "turbo3")
    local ctk_labels=(
        "f32     — Max precision, highest VRAM"
        "f16     — Standard balance of quality and speed"
        "bf16    — Like f16, preferred on Ampere/Hopper GPUs"
        "q8_0    — Near-lossless, ~2x context vs f16"
        "q5_1    — 5-bit quantization"
        "q5_0    — 5-bit quantization"
        "q4_1    — 4-bit quantization"
        "q4_0    — Aggressive 4-bit, ~3.6x context vs f16"
        "iq4_nl  — 4-bit non-linear quantization"
        "turbo4  — Optimised 4-bit for 100K+ context"
        "turbo3  — Extreme 3-bit for maximum context"
    )

    while true; do
        clear
        print_status_header

        # Calculate VRAM estimate
        local estimate
        estimate=$(estimate_vram_usage "$model_gb" "$ctx" "$ctk" "$n_layers")
        local total_gb model_disp kv_gb overhead_gb
        total_gb=$(echo "$estimate" | awk '{print $1}')
        model_disp=$(echo "$estimate" | awk '{print $2}')
        kv_gb=$(echo "$estimate" | awk '{print $3}')
        overhead_gb=$(echo "$estimate" | awk '{print $4}')

        local fits="✅"
        local fit_color=""
        if awk "BEGIN { exit ($total_gb > $hw_capacity) ? 0 : 1 }" 2>/dev/null; then
            fits="❌ OOM risk"
            fit_color="\e[1;31m"
        fi

        local moe_disp="off"
        [[ "$cpu_moe" == "y" ]] && moe_disp="on"
        local fa_disp="off"
        [[ "$flash_attn" == "y" ]] && fa_disp="on"
        local mlock_disp="off"
        [[ "$mlock" == "y" ]] && mlock_disp="on"
        local dio_disp="off"
        [[ "$dio" == "y" ]] && dio_disp="on"

        # Item numbers for mlock/dio depend on backend (CUDA has an extra GPU-layers item 6)
        local mlock_item=6 dio_item=7
        [[ "$target_backend" == "llama_cuda" ]] && mlock_item=7 && dio_item=8

        echo ""
        printf "%b\n" "\e[1;36mContext & Memory:\e[0m"
        echo " 1. Context size:     [$ctx] tokens"
        echo " 2. KV cache type:    [$ctk]  (K and V matched)"
        echo " 3. CPU MoE offload:  [$moe_disp]"
        echo " 4. Flash attention:  [$fa_disp]"
        echo " 5. Ubatch size:      [$ubatch]"
        if [[ "$target_backend" == "llama_cuda" ]]; then
            local ngl_disp
            if [[ "$fit_mode" == "y" ]]; then
                ngl_disp="auto-fit  --fit-ctx ${fit_ctx:-${ctx}}"
            else
                ngl_disp="$ngl"
            fi
            echo " 6. GPU layers:       [$ngl_disp]  (-ngl / --fit)"
        fi
        echo " ${mlock_item}. Mem lock (--mlock): [$mlock_disp]  (prevent idle swap)"
        echo " ${dio_item}. Direct I/O (-dio):  [$dio_disp]  (prevent tensor hang)"
        echo ""
        echo " Model weights:    ${model_disp} GB"
        echo " KV cache:         ${kv_gb} GB"
        echo " Runtime overhead: ~${overhead_gb} GB"
        echo " ───────────────"
        if [[ -n "$fit_color" ]]; then
            printf "%b\n" " Estimated total:  ${fit_color}${total_gb} / ${hw_capacity} GB  ${fits}\e[0m"
        else
            echo " Estimated total:  ${total_gb} / ${hw_capacity} GB  ${fits}"
        fi
        echo ""

        if [[ "$fits" == *"OOM"* ]]; then
            echo " ⚠️  Reduce context or switch to q4_0/turbo4/turbo3"
            echo ""
        fi

        echo " [c] Confirm  [1-${dio_item}] Change  [d] Defaults"
        echo ""
        read -p "Your choice: " mem_choice

        case "$mem_choice" in
            1)
                echo ""
                echo "  Context size options:"
                for i in "${!ctx_options[@]}"; do
                    local marker="  "
                    [[ "${ctx_options[$i]}" == "$ctx" ]] && marker="> "
                    echo "    ${marker}$((i + 1)). ${ctx_options[$i]} tokens  (${ctx_labels[$i]})"
                done
                echo "    $((${#ctx_options[@]} + 1)). Custom"
                local max_ctx_choice=$((${#ctx_options[@]} + 1))
                read -p "  Select [1-${max_ctx_choice}]: " ctx_choice
                if [[ "$ctx_choice" =~ ^[0-9]+$ ]] && [[ "$ctx_choice" -ge 1 && "$ctx_choice" -le ${#ctx_options[@]} ]]; then
                    ctx="${ctx_options[$((ctx_choice - 1))]}"
                elif [[ "$ctx_choice" == "$max_ctx_choice" ]]; then
                    read -p "  Enter custom context size: " custom_ctx
                    if [[ "$custom_ctx" =~ ^[0-9]+$ && "$custom_ctx" -ge 2048 ]]; then
                        ctx="$custom_ctx"
                    else
                        echo "  Invalid — must be a number ≥ 2048." && sleep 1
                    fi
                fi
                ;;
            2)
                echo ""
                echo "  KV cache type options (applied to both K and V):"
                echo ""
                echo "  Full Precision:"
                for i in 0 1 2; do
                    local marker="  "
                    [[ "${ctk_options[$i]}" == "$ctk" ]] && marker="> "
                    echo "    ${marker}$((i + 1)). ${ctk_labels[$i]}"
                done
                echo ""
                echo "  Quantized (VRAM Saving):"
                for i in 3 4 5 6 7 8; do
                    local marker="  "
                    [[ "${ctk_options[$i]}" == "$ctk" ]] && marker="> "
                    echo "    ${marker}$((i + 1)). ${ctk_labels[$i]}"
                done
                echo ""
                echo "  Experimental:"
                for i in 9 10; do
                    local marker="  "
                    [[ "${ctk_options[$i]}" == "$ctk" ]] && marker="> "
                    echo "    ${marker}$((i + 1)). ${ctk_labels[$i]}"
                done
                read -p "  Select [1-${#ctk_options[@]}]: " ctk_choice
                if [[ "$ctk_choice" =~ ^[0-9]+$ ]] && [[ "$ctk_choice" -ge 1 && "$ctk_choice" -le ${#ctk_options[@]} ]]; then
                    ctk="${ctk_options[$((ctk_choice - 1))]}"
                fi
                ;;
            3)
                if [[ "$cpu_moe" == "y" ]]; then cpu_moe="n"; else cpu_moe="y"; fi
                ;;
            4)
                if [[ "$flash_attn" == "y" ]]; then flash_attn="n"; else flash_attn="y"; fi
                if [[ "$target_backend" != "llama_cuda" && "$flash_attn" == "y" ]]; then
                    printf "%b\n" "\n  ⚠️  Flash attention requires CUDA. It may not work on CPU-only builds." && sleep 2
                fi
                ;;
            5)
                echo ""
                echo "  Ubatch size controls prompt processing batch size."
                echo "  Larger = faster prompt ingestion but more VRAM spikes."
                echo ""
                echo "    1.  512"
                echo "    2. 1024  (recommended)"
                echo "    3. 2048"
                echo "    4. 4096"
                echo "    5. Custom"
                read -p "  Select [1-5]: " ub_choice
                case "$ub_choice" in
                    1) ubatch="512" ;;
                    2) ubatch="1024" ;;
                    3) ubatch="2048" ;;
                    4) ubatch="4096" ;;
                    5)
                        read -p "  Enter custom ubatch size: " custom_ub
                        if [[ "$custom_ub" =~ ^[0-9]+$ && "$custom_ub" -ge 32 ]]; then
                            ubatch="$custom_ub"
                        else
                            echo "  Invalid — must be a number ≥ 32." && sleep 1
                        fi
                        ;;
                esac
                ;;
            6)
                if [[ "$target_backend" != "llama_cuda" ]]; then
                    # CPU: item 6 = mlock
                    if [[ "$mlock" == "y" ]]; then mlock="n"; else mlock="y"; fi
                elif [[ "$target_backend" == "llama_cuda" ]]; then
                    echo ""
                    echo "  -ngl N     offload N transformer layers to GPU (0–99, 99 = all)."
                    echo "  --fit on   auto-calculate optimal -ngl to fill VRAM without OOM."
                    echo "  --fit-ctx  minimum context size --fit will not shrink below."
                    echo ""
                    while true; do
                        read -rp "  GPU layers (0–99) [${ngl}], or 'f' to enable auto-fit: " ngl_input
                        if [[ "$ngl_input" == "f" || "$ngl_input" == "F" ]]; then
                            fit_mode="y"
                            local fc_default="${fit_ctx:-${ctx}}"
                            read -rp "  Minimum context floor [${fc_default}]: " fc_input
                            [[ -n "$fc_input" && "$fc_input" =~ ^[0-9]+$ ]] && fc_default="$fc_input"
                            fit_ctx="$fc_default"
                            printf "%b\n" "  \e[1;32m✅\e[0m Auto-fit on — --fit-ctx ${fit_ctx}"
                            sleep 1
                            break
                        elif [[ -z "$ngl_input" ]]; then
                            fit_mode="n"
                            break
                        elif [[ "$ngl_input" =~ ^[0-9]+$ ]] && [ "$ngl_input" -ge 0 ] && [ "$ngl_input" -le 99 ]; then
                            ngl="$ngl_input"
                            fit_mode="n"
                            break
                        else
                            echo "  Please enter 0–99 or 'f' for auto-fit."
                        fi
                    done
                fi
                ;;
            7)
                if [[ "$target_backend" != "llama_cuda" ]]; then
                    # CPU: item 7 = dio
                    if [[ "$dio" == "y" ]]; then dio="n"; else dio="y"; fi
                else
                    # CUDA: item 7 = mlock
                    if [[ "$mlock" == "y" ]]; then mlock="n"; else mlock="y"; fi
                fi
                ;;
            8)
                if [[ "$target_backend" == "llama_cuda" ]]; then
                    # CUDA: item 8 = dio
                    if [[ "$dio" == "y" ]]; then dio="n"; else dio="y"; fi
                fi
                ;;
            d | D)
                get_context_defaults "$vram_tier"
                ctx="$CTX_DEFAULT"
                ctk="$CTK_DEFAULT"
                cpu_moe="y"
                flash_attn="n"
                mlock="n"
                dio="n"
                ubatch="$UBATCH_DEFAULT"
                ngl=99
                fit_mode="n"
                fit_ctx=""
                if [[ "$target_backend" == "llama_cuda" ]]; then flash_attn="y"; fi
                ;;
            c | C)
                break
                ;;
            *)
                printf "%b\n" "\nInvalid option." && sleep 1
                ;;
        esac
    done

    LLAMA_CTX_SIZE="$ctx"
    LLAMA_CACHE_TYPE_K="$ctk"
    LLAMA_CACHE_TYPE_V="$ctk"
    LLAMA_CPU_MOE="$cpu_moe"
    LLAMA_FLASH_ATTN="$flash_attn"
    LLAMA_MLOCK="$mlock"
    LLAMA_DIO="$dio"
    LLAMA_UBATCH="$ubatch"
    LLAMA_NGL="$ngl"
    LLAMA_FIT="$fit_mode"
    LLAMA_FIT_CTX="$fit_ctx"
}

configure_llm_model_prompt() {
    local target_backend="$1"
    local detected_ram_vram=0
    local memory_type="VRAM"

    LOAD_DEFAULT_MODEL="y"
    LLM_DEFAULT_MODEL_CHOICE=""
    SELECTED_MODEL_REPO=""
    OLLAMA_PULL_MODEL=""
    LLAMACPP_MODEL_REPO=""

    if [[ "$target_backend" == "llama_cpu" ]]; then
        memory_type="System RAM"
        detected_ram_vram=${SYSTEM_RAM_GB:-0}
    else
        detected_ram_vram=${GPU_VRAM_GB:-0}
    fi

    while true; do
        local vram_tier="8"
        printf "%b\n" "\n\e[1;36mSelect a default model to load for ${target_backend} or choose your ${memory_type} tier:\e[0m"
        if [[ $detected_ram_vram -gt 0 ]]; then
            printf "%b\n" "Detected total ${memory_type}: \e[1;32m~${detected_ram_vram} GB\e[0m"
        fi
        echo "  1. Tiny Model (for quick testing)"
        echo "  2. Specify a different model to download"
        echo ""
        echo "  3.   8 GB  (VM / small config)"
        echo "  4.  16 GB  (VM / small config)"
        echo "  5.  24 GB  (M2/M3 base)"
        echo "  6.  32 GB  (M2/M3 Pro)"
        echo "  7.  48 GB  (M2/M3 Max)"
        echo "  8.  64 GB  (M2/M3 Ultra / M4 Max)"
        echo "  9.  96 GB  (M2/M3 Ultra)"
        echo " 10. 128 GB  (M2/M3 Ultra max / M4 Ultra)"
        read -rp "Your choice [1-10]: " vram_choice

        if [[ "$vram_choice" == "1" ]]; then
            LLM_DEFAULT_MODEL_CHOICE="5"
            break
        elif [[ "$vram_choice" == "2" ]]; then
            LLM_DEFAULT_MODEL_CHOICE="6"
            if [[ "$target_backend" == "ollama" ]]; then
                while true; do
                    read -rp "Enter an Ollama model name to pull (or 'b' to go back): " raw_input
                    if [[ "$raw_input" == "b" || "$raw_input" == "B" ]]; then
                        continue 2
                    fi
                    if [[ -z "$raw_input" ]]; then
                        echo "Input cannot be empty."
                        continue
                    fi
                    OLLAMA_PULL_MODEL="$raw_input"
                    break
                done
            else
                while true; do
                    read -rp "Enter Hugging Face repo or repo:file (or 'b' to go back): " raw_input
                    if [[ "$raw_input" == "b" || "$raw_input" == "B" ]]; then
                        continue 2
                    fi
                    if [[ -z "$raw_input" ]]; then
                        echo "Input cannot be empty."
                        continue
                    fi
                    LLAMACPP_MODEL_REPO="$raw_input"
                    break
                done
            fi
            break
        fi

        case "$vram_choice" in
             3) vram_tier=8   ;;
             4) vram_tier=16  ;;
             5) vram_tier=24  ;;
             6) vram_tier=32  ;;
             7) vram_tier=48  ;;
             8) vram_tier=64  ;;
             9) vram_tier=96  ;;
            10) vram_tier=128 ;;
            *)
                printf "%b\n" "\nInvalid choice. Please try again."
                sleep 1
                continue
                ;;
        esac

        get_model_recommendations "$(llama_variant_to_model_backend "$target_backend")" "$vram_tier"
        local m_chat="$REC_MODEL_CHAT"
        local m_code="$REC_MODEL_CODE"
        local m_moe="$REC_MODEL_MOE"
        local m_vision="$REC_MODEL_VISION"

        printf "%b\n" "\n\e[1;36mSelect a default model to load (${vram_tier}GB Tier):\e[0m"
        echo "  1. General Chat:    $m_chat"
        echo "  2. Coding:          $m_code"
        echo "  3. MoE:             $m_moe"
        echo "  4. Vision-Language: $m_vision"
        echo "  b. Back to tier selection"
        read -p "Your choice [1-4, b]: " sub_choice

        if [[ "$sub_choice" == "b" || "$sub_choice" == "B" ]]; then
            continue
        fi

        case "$sub_choice" in
            1)
                SELECTED_MODEL_REPO="$m_chat"
                LLM_DEFAULT_MODEL_CHOICE="1"
                ;;
            2)
                SELECTED_MODEL_REPO="$m_code"
                LLM_DEFAULT_MODEL_CHOICE="2"
                ;;
            3)
                SELECTED_MODEL_REPO="$m_moe"
                LLM_DEFAULT_MODEL_CHOICE="3"
                ;;
            4)
                SELECTED_MODEL_REPO="$m_vision"
                LLM_DEFAULT_MODEL_CHOICE="4"
                ;;
            *)
                printf "%b\n" "\nInvalid choice. Please try again."
                sleep 1
                continue
                ;;
        esac

        # Guard: the chosen category may be empty at this tier (e.g. MoE at 8 GB).
        if [[ -z "$SELECTED_MODEL_REPO" ]]; then
            printf "%b\n" "\n\e[1;33m⚠️  No model is available for that category at the ${vram_tier}GB tier.\e[0m"
            printf "%b\n" "Please choose a different category or go back to select a larger tier."
            sleep 2
            continue
        fi

        LLAMA_VRAM_TIER="$vram_tier"
        break
    done
}

configure_llm_launch_options() {
    local effective_backend_target="$1"

    local keys=() labels=() vals=()

    if [[ "$effective_backend_target" == "llama" ]]; then
        keys+=("expose")
        labels+=("Expose to LAN  (llama-server --host 0.0.0.0)")
        vals+=("${EXPOSE_LLM_ENGINE:-n}")
    elif [[ "$effective_backend_target" == "ollama" ]]; then
        keys+=("expose")
        labels+=("Expose to LAN  (Ollama bind 0.0.0.0:11434)")
        vals+=("${EXPOSE_LLM_ENGINE:-n}")
    fi

    if [[ "$LLAMA_COMPONENT_ACTION" != "skip" ]]; then
        keys+=("service")
        labels+=("Install llama-server as a system service")
        vals+=("${INSTALL_LLAMA_SERVICE:-n}")
        keys+=("bench")
        labels+=("Run llama-bench after install")
        vals+=("${RUN_LLAMA_BENCH:-n}")
    fi

    if [[ "$LIBRECHAT_COMPONENT_ACTION" != "skip" ]]; then
        local lc_val="n"
        [[ "${LIBRECHAT_PORT:-3080}" == "8083" ]] && lc_val="y"
        keys+=("lc_port")
        labels+=("Run LibreChat on port 8083  (default: 3080)")
        vals+=("$lc_val")
    fi

    local count=${#keys[@]}
    [[ $count -eq 0 ]] && return 0

    local first_render=true
    local menu_lines=$((count + 6))
    while true; do
        if [[ "$first_render" == true ]]; then
            first_render=false
        else
            printf '\e[%dA\e[J' "$menu_lines"
        fi
        echo ""
        printf "%b\n" "\e[1;36mLaunch Options:\e[0m"
        for ((i = 0; i < count; i++)); do
            local mark=" "
            [[ "${vals[$i]}" == "y" ]] && mark="x"
            printf " [%s] %d. %s\n" "$mark" "$((i + 1))" "${labels[$i]}"
        done
        echo ""
        echo " [c] Confirm   [1-${count}] Toggle"
        echo ""
        read -rp "Your choice: " opt_choice

        case "$opt_choice" in
            [cC]) break ;;
            [1-9])
                local idx=$((opt_choice - 1))
                if ((idx >= 0 && idx < count)); then
                    if [[ "${vals[$idx]}" == "y" ]]; then vals[$idx]="n"; else vals[$idx]="y"; fi
                fi
                ;;
        esac
    done

    for ((i = 0; i < count; i++)); do
        case "${keys[$i]}" in
            expose) EXPOSE_LLM_ENGINE="${vals[$i]}" ;;
            service) INSTALL_LLAMA_SERVICE="${vals[$i]}" ;;
            bench) RUN_LLAMA_BENCH="${vals[$i]}" ;;
            lc_port) [[ "${vals[$i]}" == "y" ]] && LIBRECHAT_PORT="8083" || LIBRECHAT_PORT="3080" ;;
        esac
    done
}

configure_local_llm_components() {
    local selected_backend=""
    local openwebui_selected=0
    local librechat_selected=0
    local effective_backend_target=""
    local force_llama_model_selection=false

    detect_local_ai_components
    reset_local_ai_component_state
    FRONTEND_BACKEND_TARGET=""

    while true; do
        clear
        print_status_header
        printf "%b\n" "\n\e[1;36mInstall local LLM Backend (Exclusive):\e[0m"
        echo "You may also toggle Open-WebUI and LibreChat below."
        echo "Selecting an installed or broken component will repair it with a hard reset."

        local ollama_action_label
        ollama_action_label=$(format_component_action_label "$(derive_component_action "$OLLAMA_COMPONENT_STATUS" "$([[ "$selected_backend" == "ollama" ]] && echo 1 || echo 0)")")
        local llama_action_label
        llama_action_label=$(format_component_action_label "$(derive_component_action "$LLAMA_COMPONENT_STATUS" "$([[ "$selected_backend" == "llama" ]] && echo 1 || echo 0)")")
        local openwebui_action_label
        openwebui_action_label=$(format_component_action_label "$(derive_component_action "$OPENWEBUI_COMPONENT_STATUS" "$openwebui_selected")")
        local librechat_action_label
        librechat_action_label=$(format_component_action_label "$(derive_component_action "$LIBRECHAT_COMPONENT_STATUS" "$librechat_selected")")

        if [[ "$selected_backend" == "ollama" ]]; then
            printf "%b\n" " \e[1;32m(*)\e[0m 1. Ollama [$(format_component_status_label "$OLLAMA_COMPONENT_STATUS")] -> ${ollama_action_label}"
        else
            printf "%b\n" " ( ) 1. Ollama [$(format_component_status_label "$OLLAMA_COMPONENT_STATUS")]"
        fi
        if [[ "$selected_backend" == "llama" ]]; then
            printf "%b\n" " \e[1;32m(*)\e[0m 2. llama.cpp [$(format_component_status_label "$LLAMA_COMPONENT_STATUS")] -> ${llama_action_label}"
        else
            printf "%b\n" " ( ) 2. llama.cpp [$(format_component_status_label "$LLAMA_COMPONENT_STATUS")]"
        fi
        if [[ $openwebui_selected -eq 1 ]]; then
            printf "%b\n" " \e[1;32m[x]\e[0m 3. Open-WebUI [$(format_component_status_label "$OPENWEBUI_COMPONENT_STATUS")] -> ${openwebui_action_label}"
        else
            printf "%b\n" " [ ] 3. Open-WebUI [$(format_component_status_label "$OPENWEBUI_COMPONENT_STATUS")]"
        fi
        if [[ $librechat_selected -eq 1 ]]; then
            printf "%b\n" " \e[1;32m[x]\e[0m 4. LibreChat [$(format_component_status_label "$LIBRECHAT_COMPONENT_STATUS")] -> ${librechat_action_label}"
        else
            printf "%b\n" " [ ] 4. LibreChat [$(format_component_status_label "$LIBRECHAT_COMPONENT_STATUS")]"
        fi
        echo "---------------------------------"
        echo "Use numbers [1-4] to toggle. Press 'c' to confirm, or 'q' to cancel."
        read -p "Your choice: " llm_choice
        case "$llm_choice" in
            1)
                if [[ "$selected_backend" == "ollama" ]]; then
                    selected_backend=""
                else
                    selected_backend="ollama"
                fi
                ;;
            2)
                if [[ "$selected_backend" == "llama" ]]; then
                    selected_backend=""
                else
                    selected_backend="llama"
                fi
                ;;
            3)
                openwebui_selected=$((1 - openwebui_selected))
                ;;
            4)
                librechat_selected=$((1 - librechat_selected))
                ;;
            c | C)
                if [[ -z "$selected_backend" && $openwebui_selected -eq 0 && $librechat_selected -eq 0 ]]; then
                    printf "%b\n" "\nPlease select at least one component."
                    sleep 1
                elif [[ -z "$selected_backend" && ($openwebui_selected -eq 1 || $librechat_selected -eq 1) && "$LLAMA_COMPONENT_STATUS" != "missing" && "$OLLAMA_COMPONENT_STATUS" != "missing" ]]; then
                    printf "%b\n" "\nBoth backends are currently present. Select which backend to keep before repairing the frontends."
                    sleep 2
                else
                    break
                fi
                ;;
            q | Q)
                return 1
                ;;
            *)
                printf "%b\n" "\nInvalid choice."
                sleep 1
                ;;
        esac
    done

    LLAMA_COMPONENT_ACTION=$(derive_component_action "$LLAMA_COMPONENT_STATUS" "$([[ "$selected_backend" == "llama" ]] && echo 1 || echo 0)")
    OLLAMA_COMPONENT_ACTION=$(derive_component_action "$OLLAMA_COMPONENT_STATUS" "$([[ "$selected_backend" == "ollama" ]] && echo 1 || echo 0)")
    OPENWEBUI_COMPONENT_ACTION=$(derive_component_action "$OPENWEBUI_COMPONENT_STATUS" "$openwebui_selected")
    LIBRECHAT_COMPONENT_ACTION=$(derive_component_action "$LIBRECHAT_COMPONENT_STATUS" "$librechat_selected")

    if [[ "$LLAMA_COMPONENT_ACTION" != "skip" ]]; then
        while true; do
            clear
            print_status_header
            printf "%b\n" "\n\e[1;36mChoose how to build llama.cpp:\e[0m"
            echo "  1. Apple Silicon GPU build (Metal — recommended)"
            echo "  2. NVIDIA eGPU build (Placeholder)"
            echo "  3. CPU-only build"
            read -rp "Your choice: " llama_variant_choice
            case "$llama_variant_choice" in
                1)
                    LLAMA_BUILD_VARIANT="llama_cuda"   # llama_cuda = Metal on macOS
                    break
                    ;;
                2)
                    printf "%b\n" "\n\e[1;33m⚠️  NVIDIA eGPU — TinyGPU Setup (Apple Silicon)\e[0m"
                    echo ""
                    echo "   Prerequisites:"
                    echo "   • Thunderbolt 4 / USB4 eGPU enclosure + supported NVIDIA card (e.g. RTX 5090)"
                    echo "   • macOS 14+ on Apple Silicon M-series"
                    echo "   • Docker Desktop (needed for the NVCC compiler step)"
                    echo ""
                    echo "   Step 1 — Install TinyGPU driver:"
                    echo "     curl -fsSL https://raw.githubusercontent.com/tinygrad/tinygrad/master/extra/setup_tinygpu_osx.sh | sh"
                    echo ""
                    echo "   Step 2 — Authorise the driver extension:"
                    echo "     System Settings → General → Login Items & Extensions"
                    echo "     → Driver Extensions → enable TinyGPU"
                    echo "     (Reboot may be required.)"
                    echo ""
                    echo "   Step 3 — Install NVCC compiler (requires Docker Desktop):"
                    echo "     curl -fsSL https://raw.githubusercontent.com/tinygrad/tinygrad/master/extra/setup_nvcc_osx.sh | sh"
                    echo ""
                    echo "   Step 4 — Test (run a model via tinygrad's LLM runner):"
                    echo "     DEV=NV python3 -m tinygrad.llm"
                    echo ""
                    printf "%b\n" "   \e[1;36mNote:\e[0m llama.cpp uses Metal (not CUDA) on macOS — TinyGPU is"
                    printf "%b\n" "   for tinygrad/custom compute workloads, not for llama.cpp inference."
                    printf "%b\n" "   This build will use \e[1;36mMetal\e[0m (same as option 1) for llama.cpp."
                    echo ""
                    read -rp "   Complete the TinyGPU steps above first, then press enter to continue..." _
                    LLAMA_BUILD_VARIANT="llama_cuda"   # Metal is the active llama.cpp backend
                    break
                    ;;
                3)
                    LLAMA_BUILD_VARIANT="llama_cpu"
                    break
                    ;;
            esac
            printf "%b\n" "\nInvalid choice."
            sleep 1
        done
        LLM_BACKEND_CHOICE="$LLAMA_BUILD_VARIANT"
    elif [[ "$OLLAMA_COMPONENT_ACTION" != "skip" ]]; then
        LLM_BACKEND_CHOICE="ollama"
    fi

    if need_frontend_backend_target; then
        ensure_frontend_backend_target
    fi

    if [[ "$LLM_BACKEND_CHOICE" == "llama_cpu" || "$LLM_BACKEND_CHOICE" == "llama_cuda" ]]; then
        effective_backend_target="llama"
    elif [[ "$LLM_BACKEND_CHOICE" == "ollama" ]]; then
        effective_backend_target="ollama"
    else
        effective_backend_target="$FRONTEND_BACKEND_TARGET"
    fi

    echo ""
    configure_llm_launch_options "$effective_backend_target"

    if llama_requires_model_selection; then
        force_llama_model_selection=true
    fi

    if [[ "$force_llama_model_selection" == true ]]; then
        echo ""
        print_info "A llama.cpp model is required for the options you selected. Choose the model to download for this run."
        if [[ "$INSTALL_LLAMA_SERVICE" == "y" || "$EXPOSE_LLM_ENGINE" == "y" || "$FRONTEND_BACKEND_TARGET" == "llama" ]]; then
            LOAD_DEFAULT_MODEL="y"
        fi
        configure_llm_model_prompt "${LLAMA_BUILD_VARIANT:-llama_cpu}"
        configure_context_memory "${LLAMA_BUILD_VARIANT:-llama_cpu}"
    elif [[ "$LLAMA_COMPONENT_ACTION" != "skip" || "$OLLAMA_COMPONENT_ACTION" != "skip" ]]; then
        echo ""
        if ask_yn "Load a default model during this run? [y/N]: " "n"; then
            if [[ "$LLAMA_COMPONENT_ACTION" != "skip" ]]; then
                configure_llm_model_prompt "${LLAMA_BUILD_VARIANT:-llama_cpu}"
                configure_context_memory "${LLAMA_BUILD_VARIANT:-llama_cpu}"
            else
                configure_llm_model_prompt "ollama"
            fi
        fi
    fi

    INSTALL_OPENWEBUI=$([[ "$OPENWEBUI_COMPONENT_ACTION" != "skip" ]] && echo "y" || echo "n")
    INSTALL_LIBRECHAT=$([[ "$LIBRECHAT_COMPONENT_ACTION" != "skip" ]] && echo "y" || echo "n")

    return 0
}

configure_openclaw_selection() {
    detect_local_ai_components

    if [[ "$IS_DIFFERENT_USER" == false ]]; then
        printf "%b\n" "\n❌ [Blocked] OpenClaw cannot be installed for the current sudo user."
        if ask_yn "Do you want to create/select a dedicated standard user now? [y/N]: " "n"; then
            echo ""
            determine_target_user
            detect_local_ai_components
            if [[ "$IS_DIFFERENT_USER" == false ]]; then
                return 1
            fi
        else
            return 1
        fi
    fi

    OPENCLAW_COMPONENT_ACTION=$(derive_component_action "$OPENCLAW_COMPONENT_STATUS" "1")

    # ── Release channel selection ────────────────────────────────────────
    # Prior stable version — update this when a new known-good stable lands.
    local oc_prior_stable="2026.2.2"

    echo ""
    printf "%b\n" "\e[1;36mOpenClaw Release Channel:\e[0m"
    printf "%b\n" "  1) \e[1;32mStable\e[0m  (latest)         — current npm release"
    printf "%b\n" "  2) \e[1;33mBeta\e[0m                     — pre-release with latest fixes"
    printf "%b\n" "  3) \e[1;34mPrior stable\e[0m ($oc_prior_stable)  — last known working release"
    echo ""
    local oc_channel_choice
    read -rp "Select release channel [1]: " oc_channel_choice
    case "${oc_channel_choice:-1}" in
        1) OPENCLAW_RELEASE_CHANNEL="latest" ;;
        2) OPENCLAW_RELEASE_CHANNEL="beta" ;;
        3) OPENCLAW_RELEASE_CHANNEL="$oc_prior_stable" ;;
        *) OPENCLAW_RELEASE_CHANNEL="latest" ;;
    esac
    printf "%b\n" "  → Using \e[1;32mopenclaw@${OPENCLAW_RELEASE_CHANNEL}\e[0m"

    # Expose/port/tailscale are configured in the post-install security menu
    # (after openclaw onboard). Defaults set here can be overridden there.
    EXPOSE_OPENCLAW="n"
    OPENCLAW_PORT="8082" # default; security menu item 7 can change to 18789

    if need_frontend_backend_target || [[ "$LLAMA_COMPONENT_STATUS" != "missing" || "$OLLAMA_COMPONENT_STATUS" != "missing" || "$LLAMA_COMPONENT_ACTION" != "skip" || "$OLLAMA_COMPONENT_ACTION" != "skip" ]]; then
        ensure_frontend_backend_target
    fi

    return 0
}

install_local_llm() {
    print_header "Installing Local LLM Stack"

    local install_llamacpp_cpu="n"
    local install_llamacpp_cuda="n"
    local install_ollama="n"
    local backend_target="${FRONTEND_BACKEND_TARGET:-}"
    local hf_args=""
    local llama_host_args="--port 8080"
    local llama_runtime_mode="none"

    case "$LLM_BACKEND_CHOICE" in
        "ollama") install_ollama="y" ;;
        "llama_cpu") install_llamacpp_cpu="y" ;;
        "llama_cuda") install_llamacpp_cuda="y" ;;
    esac

    if [[ "$LLAMA_COMPONENT_ACTION" != "skip" && "$OLLAMA_COMPONENT_STATUS" != "missing" ]]; then
        print_info "Removing existing Ollama install to keep a single backend on the machine..."
        cleanup_ollama_component
        OLLAMA_COMPONENT_STATUS="missing"
    elif [[ "$OLLAMA_COMPONENT_ACTION" != "skip" && "$LLAMA_COMPONENT_STATUS" != "missing" ]]; then
        print_info "Removing existing llama.cpp install to keep a single backend on the machine..."
        cleanup_llama_component
        LLAMA_COMPONENT_STATUS="missing"
    fi

    if [[ "$LLAMA_COMPONENT_ACTION" != "skip" ]]; then
        if [[ "$LLAMA_COMPONENT_ACTION" == "repair" ]]; then
            cleanup_llama_component
        fi
        if [[ "$LLM_BACKEND_CHOICE" == "llama_cuda" ]] && ! ensure_cuda_env_for_current_shell; then
            echo "❌ llama.cpp (${LLM_BACKEND_CHOICE}) requires CUDA, but nvcc is not available. Install or repair CUDA first."
            record_component_outcome "llama.cpp" "$LLAMA_COMPONENT_ACTION" "failed"
            return 1
        fi
    fi

    if [[ "$OLLAMA_COMPONENT_ACTION" != "skip" && "$OLLAMA_COMPONENT_ACTION" == "repair" ]]; then
        cleanup_ollama_component
    fi

    if [[ "$OPENWEBUI_COMPONENT_ACTION" != "skip" || "$LIBRECHAT_COMPONENT_ACTION" != "skip" ]]; then
        if ! command -v docker &>/dev/null; then
            echo "❌ Docker is required to manage Open-WebUI and LibreChat. Install or repair Docker first."
            if [[ "$OPENWEBUI_COMPONENT_ACTION" != "skip" ]]; then record_component_outcome "Open-WebUI" "$OPENWEBUI_COMPONENT_ACTION" "failed"; fi
            if [[ "$LIBRECHAT_COMPONENT_ACTION" != "skip" ]]; then record_component_outcome "LibreChat" "$LIBRECHAT_COMPONENT_ACTION" "failed"; fi
            return 1
        fi
    fi

    if [[ "$OPENWEBUI_COMPONENT_ACTION" != "skip" && "$HAS_NVIDIA_GPU" == true ]] && ! ensure_nvidia_ctk_for_current_shell; then
        echo "❌ Open-WebUI GPU mode requires NVIDIA Container Toolkit, but nvidia-ctk is not installed."
        record_component_outcome "Open-WebUI" "$OPENWEBUI_COMPONENT_ACTION" "failed"
        return 1
    fi

    if [[ "$LLM_BACKEND_CHOICE" == "llama_cuda" ]]; then
        if ! ensure_cudnn_env_for_current_shell >/dev/null 2>&1; then
            echo "⚠️  cuDNN environment could not be set up. CUDA build may fail."
        fi
    fi

    if [[ -z "$backend_target" ]]; then
        if [[ "$LLM_BACKEND_CHOICE" == "ollama" ]]; then
            backend_target="ollama"
        elif [[ "$LLM_BACKEND_CHOICE" == "llama_cpu" || "$LLM_BACKEND_CHOICE" == "llama_cuda" ]]; then
            backend_target="llama"
        fi
    fi

    if [[ "$install_llamacpp_cpu" == "y" || "$install_llamacpp_cuda" == "y" ]]; then
        print_info "Installing build dependencies for llama.cpp..."
        # On macOS, cmake/ninja/ccache come from Homebrew. git, clang, and
        # libcurl ship with the Xcode Command Line Tools (ensured earlier).
        # No build-essential/libssl-dev — the system toolchain provides them.
        if ! command -v brew >/dev/null 2>&1; then
            echo "❌ Homebrew is required to build llama.cpp. Install Homebrew first (menu option 5)."
            return 1
        fi
        sudo -u "$TARGET_USER" brew install cmake ninja ccache >/dev/null

        # Metal is always available on Apple Silicon — treat the "CUDA" option
        # as the Metal-backed GPU build and the "CPU" option as a Metal-less
        # reference build. -DGGML_NATIVE=ON lets the build pick up NEON/AMX
        # intrinsics for the host CPU.
        local cmake_flags="-DGGML_NATIVE=ON"
        local export_cmd=""

        if [[ "$install_llamacpp_cuda" == "y" ]]; then
            cmake_flags="$cmake_flags -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON"
            print_info "Cloning and building llama.cpp with Metal support..."
        else
            cmake_flags="$cmake_flags -DGGML_METAL=OFF"
            print_info "Cloning and building llama.cpp (CPU-only, no Metal)..."
        fi

        local _llama_clone_url="https://github.com/ggml-org/llama.cpp"
        if [[ -n "$LOCAL_MIRROR_BASE" ]]; then
            _llama_clone_url="${LOCAL_MIRROR_BASE}/llama.cpp.git"
            print_info "Local mirror mode — cloning llama.cpp from ${_llama_clone_url}"
        fi

        sudo -u "$TARGET_USER" bash -c "
            cd \"$TARGET_USER_HOME\"
            # If the directory exists but isn't a git repo (due to the previous mkdir bug), remove it
            if [ -d \"llama.cpp\" ] && [ ! -d \"llama.cpp/.git\" ]; then
                rm -rf llama.cpp
            fi
            if [ ! -d \"llama.cpp\" ]; then
                git clone \"$_llama_clone_url\"
            fi
            mkdir -p \"$(get_llama_cache_path)\"
            cd llama.cpp
            # Clean previous build to prevent CMake caching old NCCL configuration
            rm -rf build
            $export_cmd
            cmake -B build -G Ninja $cmake_flags
            cmake --build build --config Release -j $(sysctl -n hw.ncpu)
        "
        print_success "llama.cpp built successfully."

        print_info "Installing llama.cpp globally for all users..."
        sudo bash -c "cd \"$TARGET_USER_HOME/llama.cpp\" && cmake --install build --prefix /usr/local"
        print_success "llama.cpp installed globally to /usr/local/bin."

        echo ""
        hf_args=$(build_llama_hf_args)

        # TinyStories-656K is a sub-1MB test model with a tiny trained context
        # and no MoE. Advanced production flags (--cpu-moe, large -c, quantized
        # KV cache, flash-attn, -dio) SEGV on it. Apply only a minimal safe set.
        if [[ "$LLM_DEFAULT_MODEL_CHOICE" == "5" ]]; then
            llama_host_args=" -c 2048"
            [[ "$install_llamacpp_cuda" == "y" ]] && llama_host_args+=" -ngl 99"
            [[ "$EXPOSE_LLM_ENGINE" == "y" ]] && llama_host_args+=" --host 0.0.0.0"
        else
            if [[ "$install_llamacpp_cuda" == "y" ]]; then
                if [[ "$LLAMA_FIT" == "y" ]]; then
                    llama_host_args+=" --fit on --fit-ctx ${LLAMA_FIT_CTX:-${LLAMA_CTX_SIZE:-65536}}"
                else
                    llama_host_args+=" -ngl ${LLAMA_NGL:-99}"
                fi
            fi
            if [[ "$EXPOSE_LLM_ENGINE" == "y" ]]; then
                llama_host_args+=" --host 0.0.0.0"
            fi

            # Context & memory flags from configure_context_memory()
            if [[ -n "$LLAMA_CTX_SIZE" ]]; then
                llama_host_args+=" -c $LLAMA_CTX_SIZE"
            fi
            if [[ -n "$LLAMA_CACHE_TYPE_K" ]]; then
                llama_host_args+=" -ctk $LLAMA_CACHE_TYPE_K"
            fi
            if [[ -n "$LLAMA_CACHE_TYPE_V" ]]; then
                llama_host_args+=" -ctv $LLAMA_CACHE_TYPE_V"
            fi
            if [[ "$LLAMA_FLASH_ATTN" == "y" && "$install_llamacpp_cuda" == "y" ]]; then
                llama_host_args+=" --flash-attn on"
            fi
            if [[ -n "$LLAMA_UBATCH" ]]; then
                llama_host_args+=" --ubatch-size $LLAMA_UBATCH"
            fi
            if [[ "$LLAMA_CPU_MOE" == "y" ]]; then
                llama_host_args+=" --cpu-moe"
            fi
            if [[ "$LLAMA_MLOCK" == "y" ]]; then
                llama_host_args+=" --mlock"
            fi
            if [[ "$LLAMA_DIO" == "y" ]]; then
                llama_host_args+=" -dio"
            fi
        fi

        # Pre-download model with curl progress bar (if using HF repo).
        # On success, switch hf_args to --model <local_path> so bench and the
        # systemd service both use the cached file without re-downloading.
        if [[ "$hf_args" == *"--hf-repo"* && ("$RUN_LLAMA_BENCH" == "y" || "$LOAD_DEFAULT_MODEL" == "y" || "$INSTALL_LLAMA_SERVICE" == "y") ]]; then
            local downloaded_model
            # download_hf_model_with_progress returns 0 with empty stdout on failure;
            # no || true needed — a non-zero exit here is a genuine unexpected error
            downloaded_model=$(download_hf_model_with_progress "$hf_args" "$(get_llama_cache_path)")
            if [[ -n "$downloaded_model" ]]; then
                hf_args="--model $downloaded_model"
            fi
        fi

        if [[ "$RUN_LLAMA_BENCH" == "y" && -n "$LLM_DEFAULT_MODEL_CHOICE" ]]; then
            print_info "Running llama-bench performance test..."
            print_info "This measures prompt processing (pp512) and token generation (tg128) speed."

            local llama_cache_dir
            llama_cache_dir=$(get_llama_cache_path)
            sudo -u "$TARGET_USER" mkdir -p "$llama_cache_dir"
            local secrets_source="export TARGET_USER_HOME=\"$TARGET_USER_HOME\"; [ -f \"$TARGET_USER_HOME/.env.secrets\" ] && source \"$TARGET_USER_HOME/.env.secrets\";"
            local env_prefix="cd \"$TARGET_USER_HOME\"; $secrets_source export HOME=\"$TARGET_USER_HOME\"; export LLAMA_CACHE=\"$llama_cache_dir\";"

            local ngl_bench=0
            if [[ "$install_llamacpp_cuda" == "y" ]]; then ngl_bench=99; fi

            local bench_out
            bench_out=$(mktemp "${TMPDIR:-/tmp}/llama-bench.XXXXXX")
            local bench_status=0

            # Background ticker: shows unified-memory load progress during the silent
            # phase. On Apple Silicon the GPU shares system RAM, so we don't have a
            # separate "VRAM used" number — fall back to elapsed-time display. Exits
            # once llama-bench emits a table row or "warmup" line.
            (
                local elapsed=0
                while true; do
                    sleep 2
                    elapsed=$((elapsed + 2))
                    if grep -qE '^\||warmup' "$bench_out" 2>/dev/null; then
                        printf "\r\e[K" >&2
                        exit 0
                    fi
                    printf "\r\e[1;36mℹ️  Loading model... %ds elapsed\e[0m\e[K" "$elapsed" >&2
                done
            ) &
            local ticker_pid=$!

            set +e
            sudo -u "$TARGET_USER" bash -c \
                "$env_prefix llama-bench $hf_args -ngl $ngl_bench -r 3 --progress -o md" \
                2>&1 | tee "$bench_out"
            bench_status=${PIPESTATUS[0]}
            set -e

            kill "$ticker_pid" 2>/dev/null || true
            wait "$ticker_pid" 2>/dev/null || true
            printf "\r\e[K" >&2

            if [[ $bench_status -ne 0 ]]; then
                echo "❌ llama-bench failed while preparing or benchmarking the selected model."
                echo "Last output:"
                tail -n 40 "$bench_out" || true # display-only: show last output on failure
                rm -f "$bench_out"
                record_component_outcome "llama.cpp" "$LLAMA_COMPONENT_ACTION" "failed"
                return 1
            fi

            # Extract the markdown table from output
            local bench_table
            bench_table=$(grep -E '^\|' "$bench_out" || true) # may have no table rows

            if [[ -n "$bench_table" ]]; then
                # Pull pp (prompt) and tg (generation) t/s from the table
                local pp_speed tg_speed
                pp_speed=$(grep -i "pp" "$bench_out" | grep -oP '\|\s*\K[0-9]+\.[0-9]+(?=\s*±|\s*\|)' | head -1 || true) # optional metric extraction
                tg_speed=$(grep -i "tg" "$bench_out" | grep -oP '\|\s*\K[0-9]+\.[0-9]+(?=\s*±|\s*\|)' | head -1 || true) # optional metric extraction

                echo ""
                echo "$bench_table"
                echo ""
                if [[ -n "$pp_speed" && -n "$tg_speed" ]]; then
                    print_success "Benchmark complete — Prompt: ${pp_speed} t/s | Generation: ${tg_speed} t/s"
                else
                    print_success "Benchmark complete."
                fi
            else
                echo ""
                print_info "Benchmark output:"
                cat "$bench_out" || true # display-only: show raw output as fallback
            fi
            rm -f "$bench_out"
        fi

        # Recovery: model missing (e.g. resume with incomplete state) — ask now
        if [[ -z "$hf_args" && ("$LOAD_DEFAULT_MODEL" == "y" || "$INSTALL_LLAMA_SERVICE" == "y") ]]; then
            echo ""
            print_info "⚠️  No model was configured — a model is required to start llama-server."
            configure_llm_model_prompt "${LLAMA_BUILD_VARIANT:-llama_cpu}"
            hf_args=$(build_llama_hf_args)
            if [[ "$hf_args" == *"--hf-repo"* ]]; then
                local recovered_model
                recovered_model=$(download_hf_model_with_progress "$hf_args" "$(get_llama_cache_path)")
                [[ -n "$recovered_model" ]] && hf_args="--model $recovered_model"
            fi
        fi

        if llama_should_launch_server; then
            if [[ "$INSTALL_LLAMA_SERVICE" == "y" ]]; then
                print_info "Creating llama-server LaunchDaemon..."
                local llama_plist_path llama_plist_label llama_server_bin
                llama_plist_path="$(get_llama_plist_path)"
                llama_plist_label="$(get_llama_plist_label)"
                # llama-server installs to /usr/local/bin on both Apple Silicon
                # and Intel when we use `cmake --install --prefix /usr/local`.
                # Fall back to the brew-prefixed path if that's ever the only
                # thing on PATH.
                if [[ -x /usr/local/bin/llama-server ]]; then
                    llama_server_bin="/usr/local/bin/llama-server"
                elif [[ -x /opt/homebrew/bin/llama-server ]]; then
                    llama_server_bin="/opt/homebrew/bin/llama-server"
                else
                    llama_server_bin="$(command -v llama-server)"
                fi

                sudo launchctl bootout "system/$llama_plist_label" 2>/dev/null || true
                sudo rm -f "$(get_llama_runtime_log_path)"
                local llama_pid_file
                llama_pid_file=$(get_llama_runtime_pid_path)
                if sudo test -f "$llama_pid_file"; then
                    local transient_llama_pid
                    transient_llama_pid=$(sudo cat "$llama_pid_file" 2>/dev/null || true)
                    if [[ "$transient_llama_pid" =~ ^[0-9]+$ ]]; then
                        sudo kill "$transient_llama_pid" 2>/dev/null || true
                    fi
                    sudo rm -f "$llama_pid_file"
                fi

                if ! validate_plist_program_argument "hf_args" "$hf_args" ||
                    ! validate_plist_program_argument "llama_host_args" "$llama_host_args"; then
                    record_component_outcome "llama.cpp" "$LLAMA_COMPONENT_ACTION" "failed"
                    return 1
                fi

                # launchd LaunchDaemon. Unlike systemd, launchd doesn't parse
                # shell syntax in the command — we wrap with /bin/bash -c so
                # we can source .env.secrets, set env vars, and redirect logs
                # in a single plist <string> body, mirroring the Ubuntu unit.
                # KeepAlive=true is the systemd Restart=always equivalent;
                # ThrottleInterval=3 matches RestartSec=3.
                local llama_cache_path llama_log_path
                llama_cache_path="$(get_llama_cache_path)"
                llama_log_path="$(get_llama_runtime_log_path)"
                sudo tee "$llama_plist_path" >/dev/null <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>$llama_plist_label</string>
    <key>UserName</key>         <string>$TARGET_USER</string>
    <key>GroupName</key>        <string>staff</string>
    <key>WorkingDirectory</key> <string>$TARGET_USER_HOME</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>               <string>$TARGET_USER_HOME</string>
        <key>TARGET_USER_HOME</key>   <string>$TARGET_USER_HOME</string>
        <key>LLAMA_CACHE</key>        <string>$llama_cache_path</string>
    </dict>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>source $TARGET_USER_HOME/.env.secrets 2>/dev/null; export HOME="$TARGET_USER_HOME"; export LLAMA_CACHE="$llama_cache_path"; mkdir -p "$TARGET_USER_HOME/.cache"; exec $llama_server_bin $hf_args $llama_host_args</string>
    </array>
    <key>StandardOutPath</key>  <string>$llama_log_path</string>
    <key>StandardErrorPath</key><string>$llama_log_path</string>
    <key>KeepAlive</key>        <true/>
    <key>ThrottleInterval</key> <integer>3</integer>
    <key>RunAtLoad</key>        <true/>
</dict>
</plist>
PLISTEOF
                # Root-owned plists in /Library/LaunchDaemons need mode 644.
                sudo chmod 644 "$llama_plist_path"
                sudo chown root:wheel "$llama_plist_path"
                # `launchctl bootstrap` is the modern load verb (macOS 10.10+).
                # `kickstart` kicks the job so it starts immediately rather
                # than waiting for RunAtLoad on the next boot cycle.
                sudo launchctl bootstrap system "$llama_plist_path"
                sudo launchctl kickstart -k "system/$llama_plist_label" 2>/dev/null || true
                llama_runtime_mode="service"
                print_success "llama.cpp LaunchDaemon installed and started on port 8080."
                echo ""
                sudo launchctl print "system/$llama_plist_label" 2>/dev/null | head -40 || true
                echo ""
            else
                if start_llama_server_transient "$hf_args" "$llama_host_args" "$LLM_BACKEND_CHOICE"; then
                    llama_runtime_mode="transient"
                else
                    record_component_outcome "llama.cpp" "$LLAMA_COMPONENT_ACTION" "failed"
                    return 1
                fi
            fi
        fi

        if verify_llama_component; then
            if [[ "$llama_runtime_mode" == "transient" ]]; then
                print_info "Transient llama.cpp server is live on port 8080 for this session."
            fi
            record_component_outcome "llama.cpp" "$LLAMA_COMPONENT_ACTION" "success"
        else
            record_component_outcome "llama.cpp" "$LLAMA_COMPONENT_ACTION" "failed"
            return 1
        fi
    fi

    if [[ "$install_ollama" == "y" || "$install_ollama" == "Y" ]]; then
        print_info "Installing Ollama via Homebrew cask..."
        ensure_homebrew
        # The brew cask bundles its own LaunchAgent; `brew services start`
        # registers it and runs the daemon.
        brew_run install --cask ollama >/dev/null
        brew_run services start ollama >/dev/null 2>&1 || true

        if [[ "$EXPOSE_LLM_ENGINE" == "y" ]]; then
            print_info "Configuring Ollama for external access (launchctl setenv)..."
            local allowed_origins="*"
            if sudo test -f "$TARGET_USER_HOME/.env.secrets"; then
                local env_origins
                env_origins=$(sudo bash -c 'source "$1/.env.secrets" 2>/dev/null; printf "%s" "$OLLAMA_ALLOWED_ORIGINS"' _ "$TARGET_USER_HOME" | tr -d '\r')
                if [[ -n "$env_origins" ]]; then allowed_origins="$env_origins"; fi
            fi
            # Reject control characters — the value is passed through
            # launchctl setenv without shell-escaping.
            if [[ "$allowed_origins" == *\"* || "$allowed_origins" == *$'\n'* ]]; then
                echo "❌ OLLAMA_ALLOWED_ORIGINS contains an illegal character (\" or newline); using '*' instead." >&2
                allowed_origins="*"
            fi
            # launchctl setenv applies to all future launchd-spawned processes
            # in the current session. It's per-boot; for persistence we also
            # install a LaunchDaemon that re-applies it on boot.
            sudo launchctl setenv OLLAMA_HOST "0.0.0.0:11434"
            sudo launchctl setenv OLLAMA_ORIGINS "$allowed_origins"

            # Persist across reboots.
            local setenv_plist="/Library/LaunchDaemons/com.macos-prep.ollama-env.plist"
            sudo tee "$setenv_plist" >/dev/null <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.macos-prep.ollama-env</string>
    <key>RunAtLoad</key><true/>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>/bin/launchctl setenv OLLAMA_HOST 0.0.0.0:11434 ; /bin/launchctl setenv OLLAMA_ORIGINS "$allowed_origins"</string>
    </array>
</dict>
</plist>
PLISTEOF
            sudo chmod 644 "$setenv_plist"
            sudo chown root:wheel "$setenv_plist"
            sudo launchctl bootstrap system "$setenv_plist" 2>/dev/null || true

            # Restart ollama so it picks up the new env.
            brew_run services restart ollama >/dev/null 2>&1 || true
            print_info "macOS has no built-in firewall rule toggle like ufw."
            print_info "If Application Firewall is on, add /opt/homebrew/bin/ollama via System Settings."
            print_success "Ollama configured for external access."
        fi

        print_info "Locally installed Ollama models:"
        ollama list || echo "No models installed yet."
        echo ""
        if [[ "$LOAD_DEFAULT_MODEL" == "y" ]]; then
            while true; do
                print_info "Downloading and running default model..."

                (
                    local elapsed=0
                    while true; do
                        sleep 10
                        elapsed=$((elapsed + 10))
                        printf "%b\n" "\r\e[1;36mℹ️ Still downloading model... ($elapsed seconds elapsed)\e[0m"
                    done
                ) &
                local spinner_pid=$!

                local pull_tmp
                pull_tmp=$(mktemp)
                local ollama_status=0

                if [[ "$LLM_DEFAULT_MODEL_CHOICE" == "5" ]]; then
                    ollama run tinydolphin "Once upon a time," </dev/null >"$pull_tmp" 2>&1
                    ollama_status=$?
                elif [[ "$LLM_DEFAULT_MODEL_CHOICE" =~ ^[1-4]$ ]]; then
                    ollama run "$SELECTED_MODEL_REPO" "Hello, system check." </dev/null >"$pull_tmp" 2>&1
                    ollama_status=$?
                elif [[ "$LLM_DEFAULT_MODEL_CHOICE" == "6" && -n "$OLLAMA_PULL_MODEL" ]]; then
                    ollama pull "$OLLAMA_PULL_MODEL" </dev/null >"$pull_tmp" 2>&1
                    ollama_status=$?
                fi

                kill "$spinner_pid" 2>/dev/null || true
                wait "$spinner_pid" 2>/dev/null || true
                echo ""

                if [[ $ollama_status -eq 0 ]]; then
                    print_success "Model successfully downloaded and verified."
                    rm -f "$pull_tmp"
                    break
                else
                    cat "$pull_tmp"
                    rm -f "$pull_tmp"
                    printf "%b\n" "\n❌ \e[1;31mFailed to download or load the Ollama model.\e[0m"
                    read -p "Enter a valid Ollama model (e.g., 'llama3.2') or type 'skip': " fallback_repo
                    if [[ "$fallback_repo" == "skip" || "$fallback_repo" == "Skip" ]]; then
                        print_info "Skipping default model load."
                        break
                    elif [[ -n "$fallback_repo" ]]; then
                        LLM_DEFAULT_MODEL_CHOICE="6"
                        OLLAMA_PULL_MODEL="$fallback_repo"
                    fi
                fi
            done
        fi

        if verify_ollama_component; then
            record_component_outcome "Ollama" "$OLLAMA_COMPONENT_ACTION" "success"
        else
            record_component_outcome "Ollama" "$OLLAMA_COMPONENT_ACTION" "failed"
            return 1
        fi
    fi

    if [[ "$INSTALL_OPENWEBUI" == "y" || "$INSTALL_OPENWEBUI" == "Y" ]]; then
        print_info "Installing Open-WebUI via Docker..."
        if [[ "$OPENWEBUI_COMPONENT_ACTION" == "repair" ]]; then
            cleanup_openwebui_component
        fi

        print_info "Ensuring Docker is available via OrbStack..."
        # OrbStack registers its own LaunchAgent on install and exposes the
        # docker CLI on PATH. If the user hasn't launched it yet, open the app
        # and wait for the socket to come up — we don't manage a systemd unit.
        if ! docker info >/dev/null 2>&1; then
            open -a OrbStack 2>/dev/null || true
            local _orb_attempt=0
            while ! docker info >/dev/null 2>&1; do
                ((_orb_attempt++))
                [[ $_orb_attempt -gt 30 ]] && break
                sleep 2
            done
        fi

        print_info "Pulling Open-WebUI image..."
        sudo docker pull ghcr.io/open-webui/open-webui:main

        print_info "Starting Open-WebUI container..."
        # OrbStack on macOS runs containers rootlessly via the current user —
        # no sudo needed. `--network host` works on OrbStack's bridged stack
        # the same way it does on Linux; `--gpus all` is a no-op without
        # NVIDIA hardware and is omitted.
        local docker_cmd=(docker run -d --network host --restart always)
        docker_cmd+=(-e OLLAMA_BASE_URL=http://127.0.0.1:11434 -e PORT=8081)
        if [[ "$EXPOSE_LLM_ENGINE" == "y" ]]; then
            docker_cmd+=(-e HOST='0.0.0.0')
            # macOS firewall is managed via socketfilterfw per-binary, not per-port.
            # Exposing on 0.0.0.0 binds the socket; the user is responsible for
            # System Settings → Network → Firewall if they want to block it.
        fi
        if [[ "$backend_target" == "llama" ]]; then
            print_info "Configuring Open-WebUI to connect to llama.cpp backend..."
            docker_cmd+=(-e OPENAI_API_BASE_URL=http://127.0.0.1:8080/v1 -e OPENAI_API_KEY=sk-llamacpp)
        fi
        docker_cmd+=(-v open-webui:/app/backend/data --name open-webui ghcr.io/open-webui/open-webui:main)

        "${docker_cmd[@]}"
        print_success "Open-WebUI installed and running on network host."

        print_info "NOTE: When you first open Open-WebUI, it will say 'Model not selected'."
        print_info "You must click the dropdown at the top of the screen to select your loaded model."
        if [[ "$backend_target" == "llama" ]]; then
            print_info "If the model does not appear, verify the connection:"
            print_info "Go to Profile > Settings > Connections > OpenAI API."
            print_info "Ensure URL is 'http://127.0.0.1:8080/v1' and Key is 'sk-llamacpp'."
        fi

        if verify_openwebui_component; then
            record_component_outcome "Open-WebUI" "$OPENWEBUI_COMPONENT_ACTION" "success"
        else
            record_component_outcome "Open-WebUI" "$OPENWEBUI_COMPONENT_ACTION" "failed"
            return 1
        fi
    fi

    if [[ "$INSTALL_LIBRECHAT" == "y" || "$INSTALL_LIBRECHAT" == "Y" ]]; then
        print_info "Installing LibreChat via Docker..."
        if [[ "$LIBRECHAT_COMPONENT_ACTION" == "repair" ]]; then
            cleanup_librechat_component
        fi

        print_info "Ensuring Docker is available via OrbStack..."
        # OrbStack registers its own LaunchAgent on install and exposes the
        # docker CLI on PATH. If the user hasn't launched it yet, open the app
        # and wait for the socket to come up — we don't manage a systemd unit.
        if ! docker info >/dev/null 2>&1; then
            open -a OrbStack 2>/dev/null || true
            local _orb_attempt=0
            while ! docker info >/dev/null 2>&1; do
                ((_orb_attempt++))
                [[ $_orb_attempt -gt 30 ]] && break
                sleep 2
            done
        fi

        print_info "Cloning LibreChat repository..."
        local _librechat_public_url="https://github.com/danny-avila/LibreChat.git"
        local _librechat_clone_url="$_librechat_public_url"
        local _librechat_cloned=false
        if [[ -n "$LOCAL_MIRROR_BASE" ]]; then
            _librechat_clone_url="${LOCAL_MIRROR_BASE}/LibreChat.git"
            print_info "Local mirror mode — cloning LibreChat from ${_librechat_clone_url}"
            if sudo -u "$TARGET_USER" bash -c "cd \"$TARGET_USER_HOME\" && GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' git clone \"$_librechat_clone_url\"" 2>/dev/null; then
                _librechat_cloned=true
            else
                print_info "LAN mirror clone failed (likely no SSH key for $TARGET_USER) — falling back to GitHub."
                sudo -u "$TARGET_USER" rm -rf "$TARGET_USER_HOME/LibreChat" 2>/dev/null || true
            fi
        fi
        if [[ "$_librechat_cloned" != true ]]; then
            if ! sudo -u "$TARGET_USER" bash -c "cd \"$TARGET_USER_HOME\" && git clone \"$_librechat_public_url\""; then
                echo "❌ git clone failed for LibreChat from $_librechat_public_url"
                record_component_outcome "LibreChat" "$LIBRECHAT_COMPONENT_ACTION" "failed"
                return 1
            fi
        fi

        print_info "Configuring LibreChat environment..."
        sudo -u "$TARGET_USER" bash -c "cd \"$TARGET_USER_HOME/LibreChat\" && cp .env.example .env"

        if [[ "$LIBRECHAT_PORT" != "3080" ]]; then
            sudo -u "$TARGET_USER" sed -i "s/^PORT=.*/PORT=$LIBRECHAT_PORT/" "$TARGET_USER_HOME/LibreChat/.env"
        fi

        local lc_baseURL=""
        local lc_apiKey=""
        local lc_name=""
        if [[ "$backend_target" == "llama" ]]; then
            lc_baseURL="http://host.docker.internal:8080/v1"
            lc_apiKey="sk-llamacpp"
            lc_name="llama.cpp"
        elif [[ "$backend_target" == "ollama" ]]; then
            lc_baseURL="http://host.docker.internal:11434/v1"
            lc_apiKey="ollama"
            lc_name="Ollama"
        fi

        if [[ -n "$lc_baseURL" ]]; then
            sudo -u "$TARGET_USER" bash -c "cat <<EOF > \"$TARGET_USER_HOME/LibreChat/librechat.yaml\"
version: 1.1.5
cache: true
interface:
  defaultEndpoint: \"$lc_name\"
modelSpecs:
  enforce: false
  list:
    - name: \"$lc_name\"
      label: \"$lc_name\"
      default: true
      preset:
        endpoint: \"$lc_name\"
        model: \"default\"
endpoints:
  custom:
    - name: \"$lc_name\"
      apiKey: \"$lc_apiKey\"
      baseURL: \"$lc_baseURL\"
      models:
        default: [\"default\"]
        fetch: true
EOF"
        fi

        print_info "Configuring LibreChat docker-compose override..."
        local lc_uid lc_gid
        lc_uid=$(id -u "$TARGET_USER")
        lc_gid=$(id -g "$TARGET_USER")

        sudo -u "$TARGET_USER" bash -c "cat <<EOF > \"$TARGET_USER_HOME/LibreChat/docker-compose.override.yml\"
services:
  api:
    extra_hosts:
      - \"host.docker.internal:host-gateway\"
    volumes:
      - type: bind
        source: ./librechat.yaml
        target: /app/librechat.yaml
EOF"

        print_info "Starting LibreChat container (this may take a few minutes to download images)..."
        sudo bash -c "cd \"$TARGET_USER_HOME/LibreChat\" && UID=$lc_uid GID=$lc_gid docker compose up -d"
        print_success "LibreChat installed and running on port $LIBRECHAT_PORT."

        print_info "Creating LibreChat auto-update script..."
        sudo bash -c "cat <<EOF > /usr/local/bin/update-librechat.sh
#!/bin/bash
cd \"$TARGET_USER_HOME/LibreChat\"
UID_VAL=\$(id -u \"$TARGET_USER\")
GID_VAL=\$(id -g \"$TARGET_USER\")
sudo docker compose down
sudo docker images -a | grep \"librechat\" | awk '{print \\\$3}' | xargs -r sudo docker rmi || true
sudo -u \"$TARGET_USER\" git pull
sudo docker compose pull
UID=\$UID_VAL GID=\$GID_VAL sudo docker compose up -d
EOF"
        sudo chmod +x /usr/local/bin/update-librechat.sh

        if verify_librechat_component; then
            record_component_outcome "LibreChat" "$LIBRECHAT_COMPONENT_ACTION" "success"
        else
            record_component_outcome "LibreChat" "$LIBRECHAT_COMPONENT_ACTION" "failed"
            return 1
        fi
    fi

    if [[ "$install_llamacpp_cpu" == "y" || "$install_llamacpp_cuda" == "y" ]]; then
        echo ""
        if [[ "$llama_runtime_mode" == "service" ]]; then
            print_info "⚠️  NOTE: llama.cpp is currently running as a LaunchDaemon!"
            print_info "Before running manually, you MUST stop it to free up unified memory:"
            printf "%b\n" "\e[1;33msudo launchctl bootout system/$(get_llama_plist_label)\e[0m\n"
        elif [[ "$llama_runtime_mode" == "transient" ]]; then
            print_info "llama.cpp is currently running in the background for this user session."
            echo "To stop it cleanly: kill \$(cat $TARGET_USER_HOME/.cache/llama-server.pid)"
            echo ""
        fi

        if [[ "$install_llamacpp_cuda" == "y" ]]; then
            print_info "To run the server manually, use a command like this:"
            echo "source ~/.env.secrets 2>/dev/null; llama-server $hf_args $llama_host_args"
            print_info "To chat interactively in the CLI, use:"
            echo "source ~/.env.secrets 2>/dev/null; llama-cli $hf_args -ngl 99 -cnv"
        else
            print_info "To run the server manually, use a command like this:"
            echo "source ~/.env.secrets 2>/dev/null; llama-server $hf_args $llama_host_args"
            print_info "To chat interactively in the CLI, use:"
            echo "source ~/.env.secrets 2>/dev/null; llama-cli $hf_args -cnv"
        fi
    fi
}

# 15. Install OpenClaw
install_openclaw() {
    print_header "Installing OpenClaw"
    local backend_target="${FRONTEND_BACKEND_TARGET:-}"

    if [[ "$IS_DIFFERENT_USER" == false ]]; then
        echo "❌ OpenClaw cannot be installed for the current sudo user."
        echo "Please run the script again and select '2. A different/new user' to create a dedicated standard user for OpenClaw."
        return 1
    fi

    local nvm_cmd
    nvm_cmd=$(nvm_env_prelude)

    # Check if node is installed for the target user.
    if ! sudo -u "$TARGET_USER" bash -c "$nvm_cmd; command -v node" &>/dev/null; then
        echo "❌ Node.js is not installed for user '$TARGET_USER'. OpenClaw repair/install requires Node.js."
        echo "Please install or repair the 'Install NVM, Node.js & NPM' step first."
        record_component_outcome "OpenClaw" "$OPENCLAW_COMPONENT_ACTION" "failed"
        return 1
    fi

    if [[ "$OPENCLAW_COMPONENT_ACTION" == "repair" ]]; then
        cleanup_openclaw_component
    fi

    if [[ -z "$backend_target" ]]; then
        if [[ "$LLM_BACKEND_CHOICE" == "ollama" ]]; then
            backend_target="ollama"
        elif [[ "$LLM_BACKEND_CHOICE" == "llama_cpu" || "$LLM_BACKEND_CHOICE" == "llama_cuda" ]]; then
            backend_target="llama"
        else
            ensure_frontend_backend_target
            backend_target="${FRONTEND_BACKEND_TARGET:-}"
        fi
    fi

    print_info "Temporarily granting passwordless sudo to '$TARGET_USER' to allow OpenClaw to install dependencies..."
    echo "$TARGET_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/99-temp-$TARGET_USER" >/dev/null

    # macOS has no `loginctl enable-linger` equivalent — LaunchAgents in
    # gui/<uid>/ only run while the user is logged into a GUI session.
    # OpenClaw's `daemon install` writes a LaunchAgent plist under
    # ~/Library/LaunchAgents, so we don't need systemd --user at all.

    if [ -d "/opt/homebrew" ]; then
        # Homebrew on Apple Silicon is installed under /opt/homebrew. Ensure
        # the target user owns it (matches the Linuxbrew chown-back pattern).
        print_info "Ensuring Homebrew directories are writable by '$TARGET_USER'..."
        sudo chown -R "$TARGET_USER":staff /opt/homebrew
    fi

    local openclaw_command
    openclaw_command=$(
        cat <<'EOF'
        export NVM_DIR="$HOME/.nvm";
        [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh";

        # Remove any stale .openclaw/.env left by a previous run — its presence
        # causes openclaw to skip interactive onboarding entirely.
        rm -f "$HOME/.openclaw/.env";

        # Load Homebrew if it exists so OpenClaw can use it to install skills
        [ -f "/opt/homebrew/bin/brew" ] && eval "$(/opt/homebrew/bin/brew shellenv)";

        # Install openclaw directly via npm instead of their install.sh.
        # Their installer relies on gum + TTY for progress display; inside
        # "su -c" the npm install silently fails ("inappropriate ioctl for
        # device") and reports success with no package actually installed.
        # Direct npm install works reliably without TTY.
        # The release tag placeholder below is replaced with the user's
        # chosen channel (latest, beta, or a pinned version) before this
        # command runs.
        echo "Installing OpenClaw (__OC_TAG__) via npm...";
        npm install -g --no-fund --no-audit --progress=false "openclaw@__OC_TAG__";

        export PATH="$HOME/.local/bin:$PATH";

        # Unset all API key/token env vars that the login shell loaded via
        # .bashrc → .env.secrets.  If openclaw sees these it skips its
        # interactive onboarding menu and crashes on partial config data.
        while IFS='=' read -r _key _; do
            unset "$_key" 2>/dev/null || true;
        done < <(env | grep -E '^[A-Z_]*(API_KEY|TOKEN)=');

        # Also remove any stale openclaw config from a previous run
        rm -rf "$HOME/.openclaw";

        # Run onboard WITHOUT --install-daemon.  The combined
        # "onboard --install-daemon" calls .trim() on a config field that
        # can be undefined, crashing the entire process before the config
        # file is written.  Separating them lets onboard write the config
        # even if the daemon step fails.
        #
        # Capture onboard's exit code so we can surface it explicitly when
        # the config-file check below fails — the `|| true` keeps the
        # outer `set -e`/`su -c` from bailing before we inspect state.
        openclaw onboard;
        _onboard_rc=$?;

        # Only attempt daemon install if onboard actually wrote a config
        if [ -f "$HOME/.openclaw/openclaw.json" ]; then
            if [ "$_onboard_rc" -ne 0 ]; then
                echo "";
                echo "⚠️  openclaw onboard exited $_onboard_rc but wrote a config — continuing.";
            fi
            echo "";
            echo "✅ OpenClaw onboarding completed — config written.";
            echo "Installing OpenClaw daemon...";
            openclaw daemon install 2>/dev/null || {
                echo "⚠️  Daemon install returned an error — you can retry later with:";
                echo "   openclaw daemon install";
            };
        else
            echo "";
            echo "❌ OpenClaw onboarding did not write a config file (onboard exit $_onboard_rc).";
            echo "   Run 'openclaw onboard' manually later as the '$USER' user.";
            exit 1;
        fi;
EOF
    )

    # Inject the user's chosen release channel into the heredoc
    openclaw_command="${openclaw_command//__OC_TAG__/$OPENCLAW_RELEASE_CHANNEL}"

    print_info "Switching to '$TARGET_USER' to install and onboard OpenClaw."
    printf "%b\n" "\e[1;33mYou will be prompted for the password for user '$TARGET_USER'.\e[0m"

    printf "%b\n" "\n\e[1;35m=================================================================\e[0m"
    printf "%b\n" "\e[1;36m🤖 OPENCLAW ONBOARDING INSTRUCTIONS\e[0m"
    if [[ "$backend_target" == "llama" ]]; then
        printf "%b\n" "When asked for the Model/auth provider, select: \e[1;32mCustom Provider (Any OpenAI or Anthropic compatible endpoint)\e[0m"
        printf "%b\n" "When asked for the API Key, enter:              \e[1;32msk-llamacpp\e[0m"
        printf "%b\n" "When asked for the Base URL, enter:             \e[1;32mhttp://127.0.0.1:8080/v1\e[0m"
        printf "%b\n" "When asked for the Model Name, enter:           \e[1;32mllama\e[0m (or leave blank)"
    elif [[ "$backend_target" == "ollama" ]]; then
        printf "%b\n" "When asked for the Model/auth provider, select: \e[1;32mOllama\e[0m"
        printf "%b\n" "When asked for the Base URL, enter:             \e[1;32mhttp://127.0.0.1:11434\e[0m"
    else
        printf "%b\n" "Select your preferred cloud provider (e.g., OpenAI, Anthropic) and provide your API key."
    fi
    printf "%b\n" "\e[1;35m=================================================================\e[0m\n"

    while true; do
        # Temporarily disable exit-on-error for the su command.
        # Capture stderr so we can tell the difference between an su authentication
        # failure and an openclaw internal error (both exit non-zero).
        set +e
        local su_stderr_file
        su_stderr_file=$(mktemp)
        su - "$TARGET_USER" -c "$openclaw_command" 2> >(tee "$su_stderr_file" >&2)
        local su_exit_code=$?
        set -e

        if [ $su_exit_code -eq 0 ]; then
            rm -f "$su_stderr_file"
            break # Exit the loop on success
        fi

        # Differentiate: su auth failure vs openclaw crash
        if grep -qi "authentication failure\|incorrect password\|su: " "$su_stderr_file" 2>/dev/null; then
            rm -f "$su_stderr_file"
            read -rp "❌ Authentication failed — wrong password? Try again? [Y/n]: " retry_choice
            if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then
                echo "❌ Aborting OpenClaw installation."
                return 1
            fi
        else
            rm -f "$su_stderr_file"
            echo ""
            printf "%b\n" "\e[1;33m⚠️  OpenClaw setup exited with an error (code: $su_exit_code).\e[0m"
            echo "   Review the output above for details."
            echo "   If you see a TypeError, it may be a transient OpenClaw bug —"
            echo "   you can retry here, or press N and run 'openclaw onboard' manually later."
            echo ""
            read -rp "Retry OpenClaw setup? [Y/n]: " retry_choice
            if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then
                echo "⚠️  Skipping OpenClaw onboarding. Run 'openclaw onboard' manually when ready."
                return 1
            fi
        fi
    done

    print_info "Revoking temporary sudo privileges..."
    sudo rm -f "/etc/sudoers.d/99-temp-$TARGET_USER"

    local openclaw_config="$TARGET_USER_HOME/.openclaw/openclaw.json"
    if sudo test -f "$openclaw_config"; then

        # ── Auto-configure provider if onboard didn't write one ───────────────
        # 'openclaw onboard' run through 'su -c' loses TTY and silently skips
        # the provider-selection wizard.  Detect this and write the config
        # directly using the schema from a known-good onboard run.
        if ! sudo jq -e '.models.providers | length > 0' "$openclaw_config" >/dev/null 2>&1; then
            if [[ "$backend_target" == "llama" ]]; then
                print_info "No provider in config — writing llama.cpp provider directly..."
                local _prov_key="custom-127-0-0-1-8080"
                local _prov_ctx="${LLAMA_CTX_SIZE:-65536}"
                [[ "$_prov_ctx" -lt 16000 ]] && _prov_ctx=16000
                local _prov_tmp
                _prov_tmp=$(sudo mktemp)
                sudo jq \
                    --arg key "$_prov_key" \
                    --argjson ctx "$_prov_ctx" \
                    '. * {
                        "models": {
                            "mode": "merge",
                            "providers": {
                                ($key): {
                                    "baseUrl": "http://127.0.0.1:8080/v1",
                                    "api": "openai-completions",
                                    "apiKey": "sk-llamacpp",
                                    "models": [{
                                        "id": "llama",
                                        "name": "llama (Custom Provider)",
                                        "contextWindow": $ctx,
                                        "maxTokens": 4096,
                                        "input": ["text"],
                                        "cost": {"input":0,"output":0,"cacheRead":0,"cacheWrite":0},
                                        "reasoning": false
                                    }]
                                }
                            }
                        },
                        "agents": {
                            "defaults": {
                                "model": {"primary": ($key + "/llama")},
                                "models": {($key + "/llama"): {"alias": "llama"}}
                            }
                        }
                    }' "$openclaw_config" | sudo tee "$_prov_tmp" >/dev/null &&
                    sudo mv "$_prov_tmp" "$openclaw_config" &&
                    sudo chown "$TARGET_USER":staff "$openclaw_config"
                print_success "llama.cpp provider written (${_prov_key}/llama, ctx: ${_prov_ctx})."
            else
                echo "⚠️  No provider configured and backend is not llama — run 'openclaw configure --section model' manually as $TARGET_USER."
            fi
        fi

        # ── Combined: Configure & Secure OpenClaw ────────────────────────────
        # Items 1-5 : security hardening
        # Items 6-9 : gateway/network settings
        # Everything is applied in one pass after the user confirms.
        local sec_options=(
            "Disable mDNS (LAN discovery broadcasts)"
            "Enable Docker Sandboxing (Highly Recommended)"
            "Restrict Exec Tools (require approval; block shell & filesystem_delete)"
            "Lock Configuration Permissions (chmod 700/600)"
            "Run Deep Security Audit now"
            "Expose to LAN (bind 0.0.0.0)  *** WARNING: use firewall ***"
            "Use port 8082 (instead of default 18789)"
            "Allow Insecure Connections to Control UI"
            "Install Tailscale & use 'openclaw gateway --tailscale serve'"
        )
        # Defaults: security items on, expose off, port-8082 off (openclaw ignores it and stays on 18789), insecure off, tailscale off
        local sec_selections=(1 1 1 1 1 0 0 0 0)

        while true; do
            clear
            print_status_header
            printf "%b\n" "\n\e[1;36mConfigure & Secure OpenClaw:\e[0m"
            for i in "${!sec_options[@]}"; do
                [[ $i -eq 5 ]] && echo "  ─────────────────────────────────────── Gateway & Access"
                if [[ ${sec_selections[$i]} -eq 1 ]]; then
                    printf "%b\n" " \e[1;32m[x]\e[0m $((i + 1)). ${sec_options[$i]}"
                else
                    printf "%b\n" " [ ] $((i + 1)). ${sec_options[$i]}"
                fi
            done
            echo "---------------------------------"
            echo "Use numbers [1-9] to toggle.  'a' = select all,  'c' = confirm."
            read -rp "Your choice: " sec_choice
            if [[ "$sec_choice" =~ ^[0-9]+$ ]] &&
                [ "$sec_choice" -ge 1 ] && [ "$sec_choice" -le "${#sec_options[@]}" ]; then
                local idx=$((sec_choice - 1))
                sec_selections[$idx]=$((1 - sec_selections[$idx]))
            elif [[ "$sec_choice" == "a" || "$sec_choice" == "A" ]]; then
                for ((i = 0; i < ${#sec_options[@]}; i++)); do sec_selections[$i]=1; done
            elif [[ "$sec_choice" == "c" || "$sec_choice" == "C" ]]; then
                break
            else
                printf "%b\n" "\nInvalid option." && sleep 1
            fi
        done

        # ── Apply item 6 (expose) & item 7 (port) → update globals ──────────
        if [[ ${sec_selections[5]} -eq 1 ]]; then EXPOSE_OPENCLAW="y"; else EXPOSE_OPENCLAW="n"; fi
        if [[ ${sec_selections[6]} -eq 1 ]]; then OPENCLAW_PORT="8082"; else OPENCLAW_PORT="18789"; fi

        local bind_mode="loopback"
        [[ "$EXPOSE_OPENCLAW" == "y" ]] && bind_mode="lan"

        local oc_ctx="${LLAMA_CTX_SIZE:-65536}"
        [[ "$oc_ctx" -lt 65536 ]] && oc_ctx=65536

        local server_lan_ip
        # macOS has no `hostname -I`. Use the IPv4 on the default-route
        # interface (same approach as _render_summary).
        server_lan_ip=$(ifconfig "$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')" 2>/dev/null \
            | awk '/inet / {print $2; exit}' || true)

        # ── allowedOrigins prompt ────────────────────────────────────────────
        # allowedOrigins is the HTTP Origin header browsers send, which is
        # based on the URL the user typed — i.e. the SERVER URL, not the
        # client machine's IP.  We always include both the configured port
        # and openclaw's default port (18789) so a port mismatch in config
        # doesn't lock you out.
        local oc_origins_json
        # Build the baseline set: localhost + server LAN IP, both ports.
        local origins_list
        origins_list="\"http://localhost:${OPENCLAW_PORT}\", \"http://127.0.0.1:${OPENCLAW_PORT}\""
        origins_list+=", \"http://localhost:18789\", \"http://127.0.0.1:18789\""
        if [[ -n "$server_lan_ip" ]]; then
            origins_list+=", \"http://${server_lan_ip}:${OPENCLAW_PORT}\""
            # Also include port 18789 in case the service uses its own default
            [[ "${OPENCLAW_PORT}" != "18789" ]] && origins_list+=", \"http://${server_lan_ip}:18789\""
        fi

        echo ""
        print_info "OpenClaw Control UI access configuration"
        echo "  The Control UI will be at: http://${server_lan_ip:-<server-ip>}:${OPENCLAW_PORT}/chat"
        echo ""
        echo "  allowedOrigins controls which browser-facing URLs may open the Control UI."
        echo "  If you access openclaw via a different hostname, IP, or port, add it here."
        echo "  Examples: 192.168.1.50, myserver.local, 10.0.0.5"
        echo "  (Enter extra server IP/hostnames — comma-separated — or leave blank for none.)"
        echo ""
        local oc_extra_hosts_raw
        read -rp "  Extra host(s) to allow [blank = server IP only]: " oc_extra_hosts_raw
        if [[ -n "$oc_extra_hosts_raw" ]]; then
            IFS=',' read -ra _oc_hosts_arr <<<"$oc_extra_hosts_raw"
            for _host in "${_oc_hosts_arr[@]}"; do
                _host="${_host// /}"
                [[ -z "$_host" ]] && continue
                # Strip protocol/port if user pasted a full URL
                _host="${_host#http://}"
                _host="${_host#https://}"
                _host="${_host%%/*}"
                _host="${_host%%:*}"
                origins_list+=", \"http://${_host}:${OPENCLAW_PORT}\""
                [[ "${OPENCLAW_PORT}" != "18789" ]] && origins_list+=", \"http://${_host}:18789\""
            done
        fi
        oc_origins_json="[ $origins_list ]"
        print_info "allowedOrigins → $oc_origins_json"

        # ── Apply jq: bind / port / origins / rate-limit ────────────────────
        local tmp_json_file
        tmp_json_file=$(sudo mktemp)
        local oc_jq_filter
        oc_jq_filter=".gateway.bind = \"$bind_mode\" | .gateway.port = $OPENCLAW_PORT | .gateway.controlUi.enabled = true"
        oc_jq_filter="$oc_jq_filter | .gateway.controlUi.allowedOrigins = $oc_origins_json"
        if [[ "$bind_mode" != "loopback" ]]; then
            oc_jq_filter="$oc_jq_filter | .gateway.controlUi.allowInsecureAuth = false"
            oc_jq_filter="$oc_jq_filter | .gateway.auth.rateLimit = {\"maxAttempts\": 10, \"windowMs\": 60000, \"lockoutMs\": 300000}"
        fi
        oc_jq_filter="$oc_jq_filter | .agents.defaults.compaction.reserveTokensFloor = 20000"
        oc_jq_filter="$oc_jq_filter | (.models.providers // {}) as \$p | if (\$p | keys | map(select(startswith(\"custom-127\"))) | length) > 0 then (.models.providers[(.models.providers | keys | map(select(startswith(\"custom-127\"))))[0]].models[0].contextWindow = $oc_ctx) else . end"

        local _jq_out
        _jq_out=$(sudo jq "$oc_jq_filter" "$openclaw_config") || { echo "⚠️  jq filter failed — config not updated." >&2; }
        if [[ -n "$_jq_out" ]] && echo "$_jq_out" | jq empty 2>/dev/null; then
            echo "$_jq_out" | sudo tee "$tmp_json_file" >/dev/null &&
                sudo mv "$tmp_json_file" "$openclaw_config" && sudo chown "$TARGET_USER":staff "$openclaw_config"
            print_info "Restarting OpenClaw LaunchAgent to apply gateway configuration..."
            restart_openclaw_agent
        fi
        print_success "OpenClaw gateway configured (bind: $bind_mode, port: $OPENCLAW_PORT, context: $oc_ctx)."

        # Patch the LaunchAgent plist's ProgramArguments to pin the gateway
        # port — 'openclaw daemon install' may hardcode --port 18789 ignoring
        # gateway.port in the JSON config. BSD sed wants `-i ''`.
        local _oc_plist
        _oc_plist=$(find_openclaw_launchagent || true)
        if [[ -n "$_oc_plist" ]] && sudo test -f "$_oc_plist"; then
            sudo sed -i '' "s/gateway --port [0-9]*/gateway --port $OPENCLAW_PORT/g" "$_oc_plist"
            restart_openclaw_agent
            print_success "OpenClaw plist port patched to $OPENCLAW_PORT in $(basename "$_oc_plist")."
        fi

        # LAN exposure (item 6)
        if [[ "$EXPOSE_OPENCLAW" == "y" ]]; then
            # macOS firewall rules are per-binary (socketfilterfw) rather than
            # per-port; binding on 0.0.0.0 is enough for LAN exposure.
            print_info "OpenClaw will be reachable on LAN at port $OPENCLAW_PORT."
            print_info "If the macOS application firewall is on, allow incoming connections for node."
        fi

        # ── Apply security jq filters (items 1-3) ───────────────────────────
        local tmp_json_file2
        tmp_json_file2=$(sudo mktemp)
        local jq_filters="."
        if [[ ${sec_selections[0]} -eq 1 ]]; then jq_filters="$jq_filters | .discovery.mdns.mode = \"off\""; fi
        if [[ ${sec_selections[1]} -eq 1 ]]; then jq_filters="$jq_filters | .agents.defaults.sandbox.mode = \"all\""; fi
        if [[ ${sec_selections[2]} -eq 1 ]]; then
            jq_filters="$jq_filters | .tools.exec.ask = \"always\" | .tools.deny = ((.tools.deny // []) + [\"shell\", \"filesystem_delete\"] | unique)"
        fi

        if [ "$jq_filters" != "." ]; then
            print_info "Applying OpenClaw security configuration..."
            local validated_json
            validated_json=$(sudo jq "$jq_filters" "$openclaw_config") || {
                echo "⚠️  jq filter failed — security config not written."
                validated_json=""
            }
            if [[ -n "$validated_json" ]]; then
                echo "$validated_json" | sudo tee "$tmp_json_file2" >/dev/null &&
                    sudo mv "$tmp_json_file2" "$openclaw_config" && sudo chown "$TARGET_USER":staff "$openclaw_config"
                print_info "Restarting OpenClaw daemon to apply security settings..."
                restart_openclaw_agent
                print_success "OpenClaw security settings applied."
            fi
        fi

        # ── Item 8: Allow Insecure Connections ──────────────────────────────
        if [[ ${sec_selections[7]} -eq 1 ]]; then
            print_info "Enabling insecure auth for Control UI..."
            local _oc_nvm_env
            _oc_nvm_env="$(nvm_env_prelude); export PATH=\"$TARGET_USER_HOME/.local/bin:\$PATH\""
            sudo -u "$TARGET_USER" bash -c "$_oc_nvm_env; openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth true" 2>/dev/null || true
            sudo -u "$TARGET_USER" bash -c "$_oc_nvm_env; openclaw config set gateway.controlUi.allowInsecureAuth true" 2>/dev/null || true
            print_success "Insecure auth enabled (dangerouslyDisableDeviceAuth + allowInsecureAuth)."
        fi

        # ── Item 4: Lock permissions ─────────────────────────────────────────
        if [[ ${sec_selections[3]} -eq 1 ]]; then
            print_info "Locking OpenClaw configuration permissions..."
            sudo chmod 700 "$TARGET_USER_HOME/.openclaw"
            sudo chmod 600 "$openclaw_config"
            print_success "Permissions locked (700 for .openclaw, 600 for openclaw.json)."
        fi

        # ── Item 9: Install Tailscale & configure service ────────────────────
        if [[ ${sec_selections[8]} -eq 1 ]]; then
            print_info "Installing Tailscale (Mac App Store cask)..."
            # The official macOS Tailscale is a GUI app distributed via the
            # App Store or as a Homebrew cask. The Linux install script is
            # not supported on macOS.
            if command -v brew >/dev/null 2>&1; then
                sudo -u "$TARGET_USER" brew install --cask tailscale 2>/dev/null || true
            fi
            echo ""
            print_info "Open the Tailscale app from Applications to sign in."
            print_info "Once signed in you can run 'tailscale up' from the terminal."
            echo ""
            local _oc_plist_ts
            _oc_plist_ts=$(find_openclaw_launchagent || true)
            if [[ -n "$_oc_plist_ts" ]] && sudo test -f "$_oc_plist_ts"; then
                print_info "Patching OpenClaw plist to use 'openclaw gateway --tailscale serve'..."
                sudo sed -i '' 's/gateway --port [0-9]*/gateway --tailscale serve/' "$_oc_plist_ts"
                restart_openclaw_agent
                local _ts_ip
                _ts_ip=$(tailscale ip -4 2>/dev/null | head -1 || true)
                print_success "OpenClaw configured for Tailscale serve."
                [[ -n "$_ts_ip" ]] && print_info "Tailscale IP: ${_ts_ip}"
            else
                echo "⚠️  OpenClaw LaunchAgent not found — Tailscale patch skipped."
            fi
        fi

        # ── Item 5: Deep Security Audit ──────────────────────────────────────
        if [[ ${sec_selections[4]} -eq 1 ]]; then
            print_info "Running OpenClaw Deep Security Audit..."
            local _oc_audit_env
            _oc_audit_env="$(nvm_env_prelude); export PATH=\"$TARGET_USER_HOME/.local/bin:/opt/homebrew/bin:\$PATH\""
            sudo -u "$TARGET_USER" bash -c "$_oc_audit_env; openclaw security audit --deep" ||
                printf "%b\n" "⚠️ \e[1;33mAudit returned warnings/errors, please review.\e[0m"
            echo ""
            read -n 1 -s -r -p "Press any key to continue..."
            echo ""
        fi
    fi

    if verify_openclaw_component; then
        record_component_outcome "OpenClaw" "$OPENCLAW_COMPONENT_ACTION" "success"
        print_success "OpenClaw installation complete."
        POST_INSTALL_ACTIONS+=("openclaw")
    else
        record_component_outcome "OpenClaw" "$OPENCLAW_COMPONENT_ACTION" "failed"
        return 1
    fi
}

# --- Installation Checks ---
check_installations() {
    print_header "Checking for Existing Installations"
    detect_local_ai_components

    # Note: selections[0] is for 'update_system' and is not pre-checked.

    # 1. Xcode Command Line Tools (index 1)
    if xcode-select -p &>/dev/null; then
        print_info "Found existing Xcode Command Line Tools installation."
        MASTER_INSTALLED_STATE[1]=1
    fi

    # 2. Python (index 2)
    if command -v python3 &>/dev/null && command -v pip3 &>/dev/null; then
        print_info "Found existing Python installation."
        MASTER_INSTALLED_STATE[2]=1
    fi

    # 3. Docker (index 3)
    if command -v docker &>/dev/null && groups "$TARGET_USER" | grep -q '\bdocker\b'; then
        print_info "Found existing Docker installation and user configuration."
        MASTER_INSTALLED_STATE[3]=1
    fi

    # 4. NVM/Node (index 4)
    if sudo test -s "$TARGET_USER_HOME/.nvm/nvm.sh" && sudo find "$TARGET_USER_HOME/.nvm" -name "node" -type f -executable 2>/dev/null | grep -q .; then
        print_info "Found existing NVM and Node.js installation."
        MASTER_INSTALLED_STATE[4]=1
    fi

    # 5. Homebrew (index 5)
    if [ -f "/opt/homebrew/bin/brew" ]; then
        print_info "Found existing Homebrew installation."
        MASTER_INSTALLED_STATE[5]=1
    fi

    # 6. Gemini CLI (index 6)
    if command -v gemini &>/dev/null; then
        print_info "Found existing Google Gemini CLI installation."
        MASTER_INSTALLED_STATE[6]=1
    fi

    # Indices 7-13 (NVIDIA driver, btop, nvtop, CUDA, gcc, Container Toolkit,
    # cuDNN) are hidden on the macOS port — mark as "installed" so the final
    # summary treats them as complete rather than pending.
    MASTER_INSTALLED_STATE[7]=1
    MASTER_INSTALLED_STATE[8]=1
    MASTER_INSTALLED_STATE[9]=1
    MASTER_INSTALLED_STATE[10]=1
    MASTER_INSTALLED_STATE[11]=1
    MASTER_INSTALLED_STATE[12]=1
    MASTER_INSTALLED_STATE[13]=1

    # 14. Local LLM Stack (index 14)
    if [[ "$LLAMA_COMPONENT_STATUS" != "missing" || "$OLLAMA_COMPONENT_STATUS" != "missing" || "$OPENWEBUI_COMPONENT_STATUS" != "missing" || "$LIBRECHAT_COMPONENT_STATUS" != "missing" ]]; then
        print_info "Found existing Local AI components:"
        if [[ "$LLAMA_COMPONENT_STATUS" != "missing" ]]; then echo "  - llama.cpp (${LLAMA_COMPONENT_STATUS})"; fi
        if [[ "$OLLAMA_COMPONENT_STATUS" != "missing" ]]; then echo "  - Ollama (${OLLAMA_COMPONENT_STATUS})"; fi
        if [[ "$OPENWEBUI_COMPONENT_STATUS" != "missing" ]]; then echo "  - Open-WebUI (${OPENWEBUI_COMPONENT_STATUS})"; fi
        if [[ "$LIBRECHAT_COMPONENT_STATUS" != "missing" ]]; then echo "  - LibreChat (${LIBRECHAT_COMPONENT_STATUS})"; fi
        MASTER_INSTALLED_STATE[14]=1
    fi

    # 15. OpenClaw (index 15)
    if [[ "$OPENCLAW_COMPONENT_STATUS" != "missing" ]]; then
        print_info "Found existing OpenClaw installation (${OPENCLAW_COMPONENT_STATUS})."
        MASTER_INSTALLED_STATE[15]=1
    fi
}

# --- Verification ---
verify_installations() {
    print_header "Verifying Live Services & APIs"
    local services_checked=0

    # Verify each installed/repaired component. Failures are logged to
    # FAILED_COMPONENTS so the final summary reflects the real state.
    if [[ "$LLAMA_COMPONENT_ACTION" != "skip" || "$LLAMA_COMPONENT_STATUS" != "missing" ]]; then
        services_checked=1
        verify_llama_component || echo "⚠️  llama.cpp post-install verification reported issues."
    fi

    if [[ "$OLLAMA_COMPONENT_ACTION" != "skip" || "$OLLAMA_COMPONENT_STATUS" != "missing" ]]; then
        services_checked=1
        verify_ollama_component || echo "⚠️  Ollama post-install verification reported issues."
    fi

    if [[ "$OPENWEBUI_COMPONENT_ACTION" != "skip" || "$OPENWEBUI_COMPONENT_STATUS" != "missing" ]]; then
        services_checked=1
        verify_openwebui_component || echo "⚠️  Open-WebUI post-install verification reported issues."
    fi

    if [[ "$LIBRECHAT_COMPONENT_ACTION" != "skip" || "$LIBRECHAT_COMPONENT_STATUS" != "missing" ]]; then
        services_checked=1
        verify_librechat_component || echo "⚠️  LibreChat post-install verification reported issues."
    fi

    if [[ "$OPENCLAW_COMPONENT_ACTION" != "skip" || "$OPENCLAW_COMPONENT_STATUS" != "missing" ]]; then
        services_checked=1
        verify_openclaw_component || echo "⚠️  OpenClaw post-install verification reported issues."
    fi

    # cuDNN verification removed — cuDNN is NVIDIA-only and not applicable on
    # Apple Silicon. Metal acceleration (ggml-metal) is verified implicitly
    # via the llama.cpp component verifier above.

    if [[ $services_checked -eq 0 ]]; then
        print_info "No live background LLM services detected for API verification."
    fi
}

# --- Final Summary ---

# _render_summary <mode>
#   mode="terminal" - writes colored ANSI summary to stdout (used by print_final_summary)
#   mode="file"     - writes plain text to stdout; caller redirects to file
#
# Shared body used by both print_final_summary (interactive end-of-install banner)
# and save_ai_settings_file (~/AI-settings.txt dump, also triggered by 's' goal-menu key).
#
# File-mode adds: metadata header, Hardware section, llama-server runtime introspection,
# OpenClaw token URL, ufw rules in Next Steps, target-user footer.
# Terminal-mode uses colored helpers (print_info / print_header) and the more concise
# section layout the user sees during install.
_render_summary() {
    local mode="${1:-terminal}"
    local is_file=0
    [[ "$mode" == "file" ]] && is_file=1

    # ── Mode-aware output helpers ────────────────────────────────────
    _banner() { if [[ $is_file -eq 1 ]]; then echo "===== $1 ====="; else print_header "$1"; fi; }
    _section() { if [[ $is_file -eq 1 ]]; then echo "$1"; else printf "%b\n" "\e[1;36m$1\e[0m"; fi; }
    _item() { if [[ $is_file -eq 1 ]]; then echo "$1"; else print_info "$1"; fi; }
    _subheader() { if [[ $is_file -eq 1 ]]; then echo "  -> $1"; else printf "%b\n" "  \e[1;36m-> $1\e[0m"; fi; }

    local nvm_cmd
    nvm_cmd=$(nvm_env_prelude)
    local brew_cmd="[ -f /opt/homebrew/bin/brew ] && eval \"\$(/opt/homebrew/bin/brew shellenv)\""
    local lan_ip
    # `hostname -I` is a Linux idiom that doesn't exist on macOS. Prefer the
    # primary IPv4 reported by ifconfig for the default route interface.
    lan_ip=$(ifconfig "$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')" 2>/dev/null \
        | awk '/inet / {print $2; exit}' || true)

    local unique_actions=""
    if [[ ${#POST_INSTALL_ACTIONS[@]} -gt 0 ]]; then
        unique_actions=$(printf '%s\n' "${POST_INSTALL_ACTIONS[@]}" | sort -u | tr '\n' ' ')
    fi

    _banner "Installed Components & Verification"

    # File-only: metadata header
    if [[ $is_file -eq 1 ]]; then
        echo "Generated: $(date)"
        echo "Host:      $(hostname)  (${lan_ip:-<ip>})"
        echo ""
    fi

    # ── Installed Options ────────────────────────────────────────────
    _section "Installed Options:"
    local found_opt=0
    for i in "${!MASTER_OPTIONS[@]}"; do
        if [[ ${MASTER_INSTALLED_STATE[$i]:-0} -eq 1 || ${MASTER_SELECTIONS[$i]:-0} -eq 1 ]]; then
            echo "  - ${MASTER_OPTIONS[$i]}"
            found_opt=1
        fi
    done
    [[ $is_file -eq 1 && $found_opt -eq 0 ]] && echo "  (none recorded)"
    echo ""

    # ── Components lists ─────────────────────────────────────────────
    if [[ ${#INSTALLED_COMPONENTS[@]} -gt 0 ]]; then
        _section "Newly Installed Components:"
        printf '  - %s\n' "${INSTALLED_COMPONENTS[@]}"
        echo ""
    fi

    if [[ ${#REPAIRED_COMPONENTS[@]} -gt 0 ]]; then
        _section "Repaired Components:"
        printf '  - %s\n' "${REPAIRED_COMPONENTS[@]}"
        echo ""
    fi

    if [[ ${#FAILED_COMPONENTS[@]} -gt 0 ]]; then
        if [[ $is_file -eq 1 ]]; then
            echo "Failed Components:"
        else
            printf "%b\n" "\e[1;31mComponents That Failed Verification:\e[0m"
        fi
        printf '  - %s\n' "${FAILED_COMPONENTS[@]}"
        echo ""
    fi

    # File-only: Hardware section
    if [[ $is_file -eq 1 ]]; then
        echo "Hardware:"
        echo "  RAM:  ${SYSTEM_RAM_GB:-?} GB"
        echo "  VRAM: ${GPU_VRAM_GB:-?} GB"
        echo "  GPU:  ${GPU_STATUS:-unknown}"
        echo ""
    fi

    # ── Per-component software sections ──────────────────────────────
    if command -v python3 &>/dev/null; then
        _item "Python:"
        python3 --version
        echo ""
    fi

    if command -v docker &>/dev/null; then
        _item "Docker:"
        docker --version
        echo ""
    fi

    if sudo test -s "$TARGET_USER_HOME/.nvm/nvm.sh"; then
        _item "Node.js & NPM (via NVM):"
        sudo -u "$TARGET_USER" bash -c "$nvm_cmd; echo -n 'Node: '; node -v; echo -n 'NPM:  '; npm -v" 2>/dev/null ||
            echo "  (run as $TARGET_USER with NVM loaded)"
        echo ""
    fi

    if [ -f "/opt/homebrew/bin/brew" ]; then
        _item "Homebrew:"
        sudo -u "$TARGET_USER" bash -c "$brew_cmd; brew --version | head -n 1" 2>/dev/null ||
            echo "  Installed (source $TARGET_USER_HOME/.zshrc to activate)"
        echo ""
    fi

    if command -v gemini &>/dev/null; then
        _item "Google Gemini CLI:"
        echo "Installed at $(command -v gemini)"
        echo ""
    fi

    # macOS port: NVIDIA driver / nvtop / CUDA / Container Toolkit / cuDNN
    # summary blocks are intentionally omitted — none are installable on
    # Apple Silicon. Metal-accelerated llama.cpp is reported below under the
    # llama.cpp section. btop/asitop are optional and not part of the
    # current 8-item menu scope.

    if command -v ollama &>/dev/null; then
        _item "Ollama:"
        ollama --version 2>/dev/null || echo "Installed"
        if [[ $is_file -eq 1 ]]; then
            echo "API URL: http://127.0.0.1:11434"
            echo "Commands:"
            echo "  brew services start ollama"
            echo "  brew services stop  ollama"
        fi
        echo ""
    fi

    # ── llama.cpp ────────────────────────────────────────────────────
    if command -v llama-server &>/dev/null; then
        _item "llama.cpp:"
        echo "llama-server installed at $(command -v llama-server)"
        echo ""
        _subheader "LaunchDaemon commands:"
        local _llama_label
        _llama_label="$(get_llama_plist_label)"
        echo "     sudo launchctl bootstrap system $(get_llama_plist_path)"
        echo "     sudo launchctl bootout    system/$_llama_label"
        echo "     sudo launchctl kickstart -k system/$_llama_label   # restart"
        echo "     sudo launchctl print        system/$_llama_label   # status"
        echo "     tail -f $(get_llama_runtime_log_path 2>/dev/null || echo '/var/log/llama-server.log')  # live logs"

        if sudo launchctl print "system/$_llama_label" >/dev/null 2>&1; then
            # File-only: extract runtime params from the LaunchDaemon plist
            if [[ $is_file -eq 1 ]]; then
                local prog_args llama_args model_path model_name ctx_val ctk_val ngl_val
                prog_args=$(sudo awk '/<key>ProgramArguments<\/key>/,/<\/array>/' "$(get_llama_plist_path)" 2>/dev/null || true)
                llama_args=$(echo "$prog_args" | grep -oE 'llama-server[^<]*' | head -1 || true)
                model_path=$(echo "$llama_args" | grep -oE -- '--model [^[:space:]]+' | awk '{print $2}' || true)
                [[ -z "$model_path" ]] && model_path=$(echo "$llama_args" | grep -oE -- '--hf-file [^[:space:]]+' | awk '{print $2}' || true)
                [[ -n "$model_path" ]] && model_name=$(basename "$model_path" 2>/dev/null || true)
                ctx_val=$(echo "$llama_args" | grep -oE -- '-c [0-9]+' | awk '{print $2}' || true)
                ctk_val=$(echo "$llama_args" | grep -oE -- '-ctk [^[:space:]]+' | awk '{print $2}' || true)
                ngl_val=$(echo "$llama_args" | grep -oE -- '-ngl [0-9]+' | awk '{print $2}' || true)
                echo ""
                echo "  Running model: ${model_name:-unknown}"
                [[ -n "$ctx_val" ]] && echo "  Context:       $ctx_val tokens"
                [[ -n "$ctk_val" ]] && echo "  KV cache type: $ctk_val"
                [[ -n "$ngl_val" ]] && echo "  GPU layers:    $ngl_val"
                echo "  API URL:       http://127.0.0.1:8080/v1"
                echo "  API key:       sk-llamacpp"
            fi

            echo ""
            _subheader "To test your live API server from the terminal, run:"
            cat <<'CURLEOF'
     curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
       -H "Content-Type: application/json" \
       -H "Authorization: Bearer sk-llamacpp" \
       -d '{
         "messages": [
           {"role": "system", "content": "You are a helpful coding assistant."},
           {"role": "user", "content": "Write a quick haiku about the Linux command line."}
         ],
         "temperature": 0.7,
         "max_tokens": 150
       }' | jq -r '.choices[0].message.content'
CURLEOF
        fi
        echo ""
    fi

    # ── Open-WebUI ───────────────────────────────────────────────────
    if sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^open-webui$'; then
        _item "Open-WebUI (Docker):"
        local webui_status
        webui_status=$(sudo docker inspect -f '{{.State.Status}}' open-webui 2>/dev/null || echo "unknown")
        echo "Status: $webui_status"
        if command -v llama-server &>/dev/null; then
            _subheader "How to connect Open-WebUI to llama.cpp:"
            echo "     1. Open WebUI in your browser (e.g., http://localhost:8081)"
            echo "     2. Go to Profile (bottom left) -> Settings -> Connections"
            echo "     3. Under 'OpenAI API', verify the URL is 'http://127.0.0.1:8080/v1' and Key is 'sk-llamacpp'"
            echo "     4. Click the 'Verify Connection' icon. Your model should automatically load!"
        fi
        echo ""
    fi

    # ── LibreChat ────────────────────────────────────────────────────
    if sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qi 'librechat'; then
        _item "LibreChat (Docker):"
        local lc_status lc_port="${LIBRECHAT_PORT:-3080}"
        lc_status=$(sudo docker inspect -f '{{.State.Status}}' LibreChat-api 2>/dev/null || echo "Running")
        echo "Status: $lc_status"

        if sudo test -f "$TARGET_USER_HOME/LibreChat/.env"; then
            local real_port
            real_port=$(sudo grep "^PORT=" "$TARGET_USER_HOME/LibreChat/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '\r')
            [[ -n "$real_port" ]] && lc_port="$real_port"
        fi

        _subheader "How to access LibreChat:"
        if [[ $is_file -eq 1 ]]; then
            echo "     URL: http://${lan_ip:-localhost}:${lc_port}"
            echo "     1. Open LibreChat in your browser"
            echo "     2. Click 'Register' to create your admin account."
            echo "  Commands:"
            echo "     cd $TARGET_USER_HOME/LibreChat && docker compose up -d    # start"
            echo "     cd $TARGET_USER_HOME/LibreChat && docker compose down      # stop"
        else
            echo "     1. Open LibreChat in your browser (e.g., http://localhost:$lc_port)"
            echo "     2. Click 'Register' to create your admin account."
        fi
        echo ""
    fi

    # ── OpenClaw ─────────────────────────────────────────────────────
    local oc_bin
    oc_bin=$(sudo -u "$TARGET_USER" bash -c \
        "$nvm_cmd; command -v openclaw 2>/dev/null || true" 2>/dev/null || true)
    if [[ -n "$oc_bin" ]] || sudo test -f "$TARGET_USER_HOME/.local/bin/openclaw"; then
        _item "OpenClaw:"
        sudo -u "$TARGET_USER" bash -c \
            "$nvm_cmd; openclaw --version 2>/dev/null || echo 'Installed'" 2>/dev/null || echo "Installed"

        # File-only: detailed port / bind / token URL
        if [[ $is_file -eq 1 ]] && sudo test -f "$TARGET_USER_HOME/.openclaw/openclaw.json"; then
            local oc_port oc_bind
            oc_port=$(sudo jq -r '.gateway.port // 18789' "$TARGET_USER_HOME/.openclaw/openclaw.json" 2>/dev/null || echo "18789")
            oc_bind=$(sudo jq -r '.gateway.bind // "loopback"' "$TARGET_USER_HOME/.openclaw/openclaw.json" 2>/dev/null || echo "loopback")
            echo "  Port:   $oc_port"
            echo "  Bind:   $oc_bind"
            echo "  Config: $TARGET_USER_HOME/.openclaw/openclaw.json"
            echo ""
            echo "  -> LaunchAgent commands (as user $TARGET_USER):"
            local _oc_plist_show _oc_target_show
            _oc_plist_show=$(find_openclaw_launchagent 2>/dev/null || true)
            if [[ -n "$_oc_plist_show" ]]; then
                _oc_target_show=$(openclaw_launchd_target "$_oc_plist_show" 2>/dev/null || echo "gui/<uid>/<label>")
                echo "     launchctl bootstrap $_oc_target_show  # (once at login)"
                echo "     launchctl bootout   $_oc_target_show"
                echo "     launchctl kickstart -k $_oc_target_show   # restart"
                echo "     launchctl print        $_oc_target_show   # status"
            else
                echo "     (No openclaw LaunchAgent found under ~/Library/LaunchAgents)"
            fi
            echo ""
            echo "  -> Control UI access:"
            echo "     Direct (LAN): http://${lan_ip:-<server-ip>}:${oc_port}/"
            echo ""
            echo "     SSH tunnel (from a remote machine):"
            echo "     ssh -L ${oc_port}:localhost:${oc_port} [admin-user]@${lan_ip:-<server-ip>}"
            echo "     Then open:  http://localhost:${oc_port}/"
            echo ""
            # Try to extract the current session token from today's log
            local oc_log oc_token
            oc_log="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
            oc_token=""
            if sudo test -f "$oc_log" 2>/dev/null; then
                oc_token=$(sudo grep -oE '#token=[a-f0-9]+' "$oc_log" 2>/dev/null |
                    tail -1 | sed 's/#token=//' || true)
            fi
            if [[ -n "$oc_token" ]]; then
                echo "     Current session token URL:"
                echo "     http://localhost:${oc_port}/#token=${oc_token}"
                echo "     (Token changes on each service restart)"
            else
                echo "     Token: run the command below to get the current token:"
            fi
            echo "     sudo -u $TARGET_USER bash -c \\"
            echo "       'XDG_RUNTIME_DIR=/run/user/\$(id -u $TARGET_USER) openclaw status' | grep -i token"
        fi
        echo ""
    fi

    # ── Hostname resolution ──────────────────────────────────────────
    _item "System Hostname Resolution:"
    local current_hostname
    current_hostname=$(hostname)
    if hostname -i &>/dev/null; then
        if [[ $is_file -eq 1 ]]; then
            echo "  Hostname '$current_hostname' resolves correctly ($(hostname -i | awk '{print $1}' | head -n 1))."
        else
            print_success "Hostname '$current_hostname' resolves correctly ($(hostname -i | awk '{print $1}' | head -n 1))."
        fi
    else
        if [[ $is_file -eq 1 ]]; then
            echo "  WARNING: Hostname '$current_hostname' does not resolve."
            echo "  Add '127.0.1.1 $current_hostname' to /etc/hosts to prevent network and sudo delays."
        else
            printf "%b\n" "\e[1;31m⚠️  WARNING: Hostname '$current_hostname' does not resolve.\e[0m"
            echo "   Please add '127.0.1.1 $current_hostname' to your /etc/hosts file to prevent network and sudo delays."
        fi
    fi
    echo ""

    # File-only: target-user footer
    if [[ $is_file -eq 1 ]] && [[ -n "${TARGET_USER:-}" ]]; then
        echo "Target user: $TARGET_USER  ($TARGET_USER_HOME)"
        echo ""
    fi

    # If no post-install actions recorded, skip Next Steps entirely
    [[ -z "$unique_actions" ]] && return

    # ── Next Steps & Important Information ───────────────────────────
    _banner "Next Steps & Important Information"
    [[ $is_file -eq 1 ]] && echo ""

    local path_changed=0
    if [[ "$unique_actions" == *"nvm"* || "$unique_actions" == *"brew"* ||
        "$unique_actions" == *"cuda"* || "$unique_actions" == *"openclaw"* ]]; then
        path_changed=1
    fi

    if [[ "$unique_actions" == *"docker"* ]]; then
        if [[ $is_file -eq 1 ]]; then
            echo "Docker group change:"
            echo "  To use Docker without 'sudo' immediately: newgrp docker"
            echo "  Or log out and back in to apply the group change globally."
            echo "  Then test: docker run hello-world"
        else
            print_info "To use Docker without 'sudo' IMMEDIATELY in this terminal, run: newgrp docker"
            print_info "Otherwise, you must LOG OUT and LOG BACK IN to apply the group change globally."
            print_info "Then, test your installation with: docker run hello-world"
        fi
        echo ""
    fi

    if [[ $path_changed -eq 1 ]]; then
        local rc_file=""
        if sudo test -f "$TARGET_USER_HOME/.zshrc"; then
            rc_file="$TARGET_USER_HOME/.zshrc"
        elif sudo test -f "$TARGET_USER_HOME/.bashrc"; then
            rc_file="$TARGET_USER_HOME/.bashrc"
        fi
        if [[ $is_file -eq 1 ]]; then
            echo "To activate newly installed commands for '$TARGET_USER' (like nvm, node, gemini), they must either:"
            echo "  1. Open a NEW terminal window."
            if [[ -n "$rc_file" ]]; then
                echo "  2. OR, run the following command in your CURRENT terminal:"
                echo "source ${rc_file}"
            fi
        else
            printf "%b\n" "\e[1;33mTo activate newly installed commands for '$TARGET_USER' (like nvm, node, gemini), they must either:\e[0m"
            printf "%b\n" "  1. \e[1;32mOpen a NEW terminal window.\e[0m"
            if [[ -n "$rc_file" ]]; then
                printf "%b\n" "  2. OR, run the following command in your CURRENT terminal:"
                echo "source ${rc_file}"
            fi
        fi
        echo ""
    fi

    if [[ "$unique_actions" == *"reboot"* ]]; then
        if [[ $is_file -eq 1 ]]; then
            echo "Reboot recommended:"
            echo "  A system reboot is recommended to ensure all NVIDIA drivers are loaded correctly."
            echo ""
        else
            print_info "A system reboot is highly recommended to ensure all NVIDIA drivers are loaded correctly."
        fi
    fi
}

print_final_summary() {
    # Ensure newly installed binaries are in the script's PATH for verification
    [ -d "/usr/local/cuda/bin" ] && export PATH="/usr/local/cuda/bin:$PATH"
    _render_summary "terminal"
    # Save on-disk summary only when something was installed/repaired (matches
    # the pre-refactor behaviour — the old print_final_summary returned early
    # before reaching save_ai_settings_file when POST_INSTALL_ACTIONS was empty).
    if [[ ${#POST_INSTALL_ACTIONS[@]} -gt 0 ]]; then
        save_ai_settings_file
    fi
    echo ""
    printf "%b\n" "\e[2m  Using this at work? Commercial use requires a one-time \$10 license."
    printf "%b\n" "  → https://github.com/chsbusch-dot/Ubuntu-AI-Tools-Install\e[0m"
    echo ""
}

# Write a clean, plain-text AI-settings summary to ~/AI-settings.txt
# Called from print_final_summary (after install) and the 's' goal-menu key.
save_ai_settings_file() {
    local out_file="$HOME/AI-settings.txt"
    _render_summary "file" >"$out_file"
    print_success "Settings saved → $out_file"
}

# --- Edit llama.cpp Server Parameters ---
#
# Lets the user pick a new model and tune context/memory settings
# on a live LaunchDaemon installation.  On confirm:
#   1. Stops the running LaunchDaemon (launchctl bootout)
#   2. Rewrites /Library/LaunchDaemons/com.macos-prep.llama-server.plist
#   3. launchctl bootstrap + kickstart -k
#
edit_llama_server_parameters() {
    # On Apple Silicon the Metal backend is always present — treat it as the
    # llama_cuda equivalent (GPU layers + flash-attn prompts enabled) so the
    # existing menu flow works unmodified.
    local plist_path plist_label
    plist_path="$(get_llama_plist_path)"
    plist_label="$(get_llama_plist_label)"
    local backend_variant="llama_cuda"

    # Reset globals so configure_llm_model_prompt starts fresh.
    LLM_DEFAULT_MODEL_CHOICE=""
    SELECTED_MODEL_REPO=""
    LLAMACPP_MODEL_REPO=""
    OLLAMA_PULL_MODEL=""
    LLAMA_CTX_SIZE=""
    LLAMA_CACHE_TYPE_K=""
    LLAMA_CACHE_TYPE_V=""
    LLAMA_CPU_MOE="y"
    LLAMA_FLASH_ATTN="n"
    LLAMA_MLOCK="n"
    LLAMA_DIO="n"
    LLAMA_UBATCH=""
    LLAMA_VRAM_TIER=""
    LLAMA_NGL=999
    LLAMA_FIT="n"
    LLAMA_FIT_CTX=""
    LLAMA_COMPONENT_ACTION="repair" # needed so llama_requires_model_selection returns true

    # Pull the current ExecStart-equivalent out of the plist: it lives as the
    # last <string> inside <key>ProgramArguments</key>. We parse it so ngl,
    # --fit, --mlock, -dio are pre-filled in the menu.
    local cur_prog_args cur_exec_line
    cur_prog_args=$(sudo awk '/<key>ProgramArguments<\/key>/,/<\/array>/' "$plist_path" 2>/dev/null || true)
    cur_exec_line=$(echo "$cur_prog_args" | grep -oE 'llama-server[^<]*' | head -1 || true)
    if [[ -n "$cur_exec_line" ]]; then
        local cur_ngl_hint cur_fit_hint
        cur_ngl_hint=$(echo "$cur_exec_line" | grep -oE -- '-ngl [0-9]+' | awk '{print $2}' || true)
        cur_fit_hint=$(echo "$cur_exec_line" | grep -oE -- '--fit (on|off)' | awk '{print $2}' || true)
        [[ -n "$cur_ngl_hint" ]] && LLAMA_NGL="$cur_ngl_hint"
        [[ "$cur_fit_hint" == "on" ]] && LLAMA_FIT="y"
        echo "$cur_exec_line" | grep -q -- '--mlock' && LLAMA_MLOCK="y"
        echo "$cur_exec_line" | grep -q -- '-dio' && LLAMA_DIO="y"
    fi

    clear
    print_status_header
    printf "%b\n" "\n\e[1;36m── Edit llama.cpp Server Parameters ─────────────────────────\e[0m"
    printf "%b\n" "Current plist: \e[0;33m${plist_path}\e[0m"
    printf "%b\n" "Backend:       \e[0;33mMetal (Apple Silicon)\e[0m"
    echo ""

    # Step 1: model selection (re-uses the same prompt as initial install)
    configure_llm_model_prompt "$backend_variant"
    if [[ -z "$LLM_DEFAULT_MODEL_CHOICE" ]]; then
        echo "No model selected — edit cancelled."
        return 1
    fi

    # Step 2: context, memory, and GPU layers
    configure_context_memory "$backend_variant"

    # Step 3: build args from globals set by configure_context_memory
    local hf_args
    hf_args=$(build_llama_hf_args)

    local llama_host_args="--port 8080"
    if [[ "$LLAMA_FIT" == "y" ]]; then
        llama_host_args+=" --fit on --fit-ctx ${LLAMA_FIT_CTX}"
    else
        llama_host_args+=" -ngl ${LLAMA_NGL}"
    fi

    # Replicate the expose-LLM flag from the existing plist (keep --host if already set)
    if echo "$cur_exec_line" | grep -q -- '--host 0.0.0.0'; then
        llama_host_args+=" --host 0.0.0.0"
    fi

    [[ -n "$LLAMA_CTX_SIZE" ]] && llama_host_args+=" -c $LLAMA_CTX_SIZE"
    [[ -n "$LLAMA_CACHE_TYPE_K" ]] && llama_host_args+=" -ctk $LLAMA_CACHE_TYPE_K"
    [[ -n "$LLAMA_CACHE_TYPE_V" ]] && llama_host_args+=" -ctv $LLAMA_CACHE_TYPE_V"
    [[ "$LLAMA_FLASH_ATTN" == "y" ]] && llama_host_args+=" --flash-attn on"
    [[ -n "$LLAMA_UBATCH" ]] && llama_host_args+=" --ubatch-size $LLAMA_UBATCH"
    [[ "$LLAMA_CPU_MOE" == "y" ]] && llama_host_args+=" --cpu-moe"
    [[ "$LLAMA_MLOCK" == "y" ]] && llama_host_args+=" --mlock"
    [[ "$LLAMA_DIO" == "y" ]] && llama_host_args+=" -dio"

    # Download model if it's an HF repo that isn't already cached
    if [[ "$hf_args" == *"--hf-repo"* ]]; then
        print_info "Checking model cache…"
        local downloaded_model
        downloaded_model=$(download_hf_model_with_progress "$hf_args" "$(get_llama_cache_path)")
        if [[ -n "$downloaded_model" ]]; then
            hf_args="--model $downloaded_model"
        fi
    fi

    # Step 5: confirm before touching the live LaunchDaemon
    echo ""
    printf "%b\n" "\e[1;36m── Confirm new LaunchDaemon configuration ────────────────────\e[0m"
    printf "%b\n" "  Model args:  \e[0;33m${hf_args}\e[0m"
    printf "%b\n" "  Server args: \e[0;33m${llama_host_args}\e[0m"
    echo ""
    read -rp "Apply and restart llama-server? [y/N]: " apply_choice
    if [[ "$apply_choice" != "y" && "$apply_choice" != "Y" ]]; then
        echo "Edit cancelled — LaunchDaemon unchanged."
        return 0
    fi

    # Step 6: rewrite the LaunchDaemon plist
    print_info "Stopping llama-server…"
    sudo launchctl bootout "system/$plist_label" 2>/dev/null || true

    if ! validate_plist_program_argument "hf_args" "$hf_args" ||
        ! validate_plist_program_argument "llama_host_args" "$llama_host_args"; then
        return 1
    fi

    local llama_server_bin
    llama_server_bin="$(command -v llama-server || echo /opt/homebrew/bin/llama-server)"

    # shellcheck disable=SC2090
    sudo tee "$plist_path" >/dev/null <<EDITEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$plist_label</string>
    <key>UserName</key><string>$TARGET_USER</string>
    <key>GroupName</key><string>staff</string>
    <key>WorkingDirectory</key><string>$TARGET_USER_HOME</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>$TARGET_USER_HOME</string>
        <key>TARGET_USER_HOME</key><string>$TARGET_USER_HOME</string>
        <key>LLAMA_CACHE</key><string>$(get_llama_cache_path)</string>
    </dict>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>source $TARGET_USER_HOME/.env.secrets 2>/dev/null; export HOME="$TARGET_USER_HOME"; export LLAMA_CACHE="$(get_llama_cache_path)"; mkdir -p "$TARGET_USER_HOME/.cache"; exec $llama_server_bin $hf_args $llama_host_args &gt;&gt; "$(get_llama_runtime_log_path)" 2&gt;&amp;1</string>
    </array>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>3</integer>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EDITEOF
    sudo chmod 644 "$plist_path"
    sudo chown root:wheel "$plist_path"

    print_info "Bootstrapping LaunchDaemon and kicking it off…"
    sudo launchctl bootstrap system "$plist_path"
    sudo launchctl kickstart -k "system/$plist_label" 2>/dev/null || true
    echo ""
    sudo launchctl print "system/$plist_label" 2>/dev/null | head -n 30 || true
    echo ""

    # Update OpenClaw config to match new context size (if installed)
    local openclaw_config="$TARGET_USER_HOME/.openclaw/openclaw.json"
    if sudo test -f "$openclaw_config" && [[ -n "$LLAMA_CTX_SIZE" ]]; then
        local oc_ctx="$LLAMA_CTX_SIZE"
        [[ "$oc_ctx" -lt 65536 ]] && oc_ctx=65536
        local tmp_oc
        tmp_oc=$(sudo mktemp)
        local oc_jq=".agents.defaults.compaction.reserveTokensFloor = 20000"
        oc_jq="$oc_jq | (.models.providers // {}) as \$p | if (\$p | keys | map(select(startswith(\"custom-127\"))) | length) > 0 then (.models.providers[(.models.providers | keys | map(select(startswith(\"custom-127\"))))[0]].models[0].contextWindow = $oc_ctx) else . end"
        local oc_out
        oc_out=$(sudo jq "$oc_jq" "$openclaw_config") || true
        if [[ -n "$oc_out" ]] && echo "$oc_out" | jq empty 2>/dev/null; then
            echo "$oc_out" | sudo tee "$tmp_oc" >/dev/null &&
                sudo mv "$tmp_oc" "$openclaw_config" &&
                sudo chown "$TARGET_USER":staff "$openclaw_config"
            print_success "OpenClaw contextWindow updated to ${oc_ctx}."
        fi
    fi

    print_success "llama.cpp LaunchDaemon updated and running."
    return 0
}

# --- Main Menu ---

show_menu() {
    UI_TO_MASTER=()
    local ui_num=1
    local menu_body=""

    for master_index in "${ACTIVE_INDICES[@]}"; do
        # Menu scope on macOS: hide btop (8) and everything NVIDIA/CUDA-related
        # (7, 9–13); all other indices including Xcode CLT (1) are shown.
        case "$master_index" in
            7|8|9|10|11|12|13) continue ;;
        esac

        # Visual grouping between core tools, LLM, and OpenClaw.
        if [[ $master_index -eq 14 || $master_index -eq 15 ]]; then menu_body+="\n"; fi

        local line=""
        if [[ $master_index -eq 0 ]]; then
            line=" \e[1;32m[x]\e[0m ${ui_num}. ${MASTER_OPTIONS[$master_index]} (Required)"
        elif [[ ${MASTER_INSTALLED_STATE[$master_index]} -eq 1 ]]; then
            if [[ $master_index -eq 14 || $master_index -eq 15 ]]; then
                line=" \e[1;36m[✓]\e[0m ${ui_num}. ${MASTER_OPTIONS[$master_index]} (Selectable for repair)"
            else
                line=" \e[1;36m[✓]\e[0m ${ui_num}. ${MASTER_OPTIONS[$master_index]}"
            fi
        elif [[ ${MASTER_SELECTIONS[$master_index]} -eq 1 ]]; then
            line=" \e[1;32m[x]\e[0m ${ui_num}. ${MASTER_OPTIONS[$master_index]}"
        else
            line=" [ ] ${ui_num}. ${MASTER_OPTIONS[$master_index]}"
        fi
        menu_body+="$line\n"

        UI_TO_MASTER[$ui_num]=$master_index
        ((ui_num++))
    done

    clear
    print_status_header
    echo "Use numbers [1-$((ui_num - 1))] to toggle an option. Press 'a' to select all."
    echo "Press 'i' to install selected, or 'q' to quit."
    echo "---------------------------------"
    printf "%b" "$menu_body"
    echo "---------------------------------"
}

dry_run_plan_for() {
    case "$1" in
        0) echo "softwareupdate --install --all; brew update && brew upgrade" ;;
        1) echo "xcode-select --install (check for pending OS updates first; CLT is version-matched to macOS)" ;;
        2) echo "brew install python@3.12 pipx; pipx ensurepath" ;;
        3) echo "brew install --cask orbstack (Docker/Compose provided by OrbStack)" ;;
        4) echo "Install NVM (curl script) + Node LTS + npm for $TARGET_USER" ;;
        5) echo "Install Homebrew to /opt/homebrew (Apple Silicon prefix)" ;;
        6) echo "npm install -g @google/gemini-cli (requires NVM/Node)" ;;
        7) echo "(n/a on Apple Silicon — no discrete GPU drivers needed)" ;;
        8) echo "brew install btop" ;;
        9) echo "pipx install asitop (Apple Silicon power/memory monitor)" ;;
        10) echo "(n/a on Apple Silicon — Metal is built in, no CUDA)" ;;
        11) echo "Ensure Xcode Command Line Tools are installed (provides clang/gcc)" ;;
        12) echo "(n/a on Apple Silicon — no NVIDIA container toolkit)" ;;
        13) echo "(n/a on Apple Silicon — no cuDNN)" ;;
        14) echo "brew install --cask ollama and/or build llama.cpp with Metal; optionally run Open-WebUI / LibreChat via OrbStack; create LaunchDaemons" ;;
        15) echo "npm install -g openclaw@beta; run 'openclaw onboard'; install openclaw-gateway LaunchAgent; patch config to route to llama.cpp" ;;
        *) echo "(no plan available for index $1)" ;;
    esac
}

print_dry_run_plan() {
    local count=$1
    shift
    local labels=("$@")

    echo ""
    printf "%b\n" "\e[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
    printf "%b\n" "\e[1;36m  DRY RUN — no changes have been or will be made.\e[0m"
    printf "%b\n" "\e[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
    echo ""
    printf "%b\n" "Target user:  \e[1;33m${TARGET_USER:-<unknown>}\e[0m"
    printf "%b\n" "GPU detected: \e[1;33m${GPU_STATUS:-none}\e[0m"
    echo ""
    echo "Selected items (install order):"
    echo ""

    local i any=0
    for i in "${!MASTER_SELECTIONS[@]}"; do
        if [[ ${MASTER_SELECTIONS[$i]:-0} -eq 1 ]]; then
            any=1
            printf "%b\n" "  \e[1;32m[$i]\e[0m ${labels[$i]}"
            printf '       → %s\n' "$(dry_run_plan_for "$i")"
        fi
    done
    if [[ $any -eq 0 ]]; then
        echo "  (nothing selected)"
    fi

    echo ""
    echo "A real run would also:"
    echo "  • Prompt for API keys and write them to \$HOME/.env.secrets (chmod 600)"
    echo "  • Ensure command-line tools & Homebrew are available (xcode-select, /opt/homebrew)"
    echo "  • Install base CLI dependencies via Homebrew (curl, wget, jq, cmake, ninja, ccache)"
    echo ""
    printf "%b\n" "\e[1;36mTo actually install, re-run without --dry-run.\e[0m"
    echo ""
}

main() {
    check_not_root
    if [[ "$DRY_RUN" != "true" ]]; then
        check_sudo_privileges
        start_sudo_keepalive
    fi
    check_os

    # ── Detect an interrupted installation from a previous run ───────────────
    # If the state file exists but --resume wasn't passed, offer to pick up
    # where the last run left off (e.g. after a post-NVIDIA-driver reboot).
    if [[ "$RESUME_MODE" == false && -f "$RESUME_STATE_FILE" ]]; then
        echo ""
        printf "%b\n" "\e[1;36m🔄 Detected a previous interrupted installation.\e[0m"
        if ask_yn "Resume where it left off? [Y/n]: " "y"; then
            RESUME_MODE=true
        else
            printf "%b\n" "Starting fresh — discarding previous state."
            sudo rm -f "$RESUME_STATE_FILE" 2>/dev/null || true
        fi
    fi

    # ── Resume mode: restore state from before the reboot ────────────────────
    if [[ "$RESUME_MODE" == true ]]; then
        if [[ ! -f "$RESUME_STATE_FILE" ]]; then
            echo "❌ --resume specified but no state file found at $RESUME_STATE_FILE"
            exit 1
        fi
        echo ""
        printf "%b\n" "\e[1;36m🔄 Resuming ubuntu-prep-setup.sh after reboot...\e[0m"
        # shellcheck source=/dev/null
        # The state file is root-owned (chmod 600), so we must read it via
        # sudo and pipe into source through process substitution.
        source <(sudo cat "$RESUME_STATE_FILE")

        # Restore global arrays from space-separated strings
        read -ra MASTER_SELECTIONS <<<"$RESUME_SELECTIONS"
        read -ra MASTER_INSTALLED_STATE <<<"$RESUME_COMPLETED"
        read -ra ACTIVE_INDICES <<<"$RESUME_ACTIVE"

        # Restore config variables
        TARGET_USER="$RESUME_TARGET_USER"
        TARGET_USER_HOME="$RESUME_TARGET_USER_HOME"
        IS_DIFFERENT_USER="$RESUME_IS_DIFFERENT_USER"
        HAS_NVIDIA_GPU="$RESUME_HAS_NVIDIA_GPU"
        NVIDIA_DRIVER_TYPE="${RESUME_NVIDIA_DRIVER_TYPE:-}"
        LLM_BACKEND_CHOICE="${RESUME_LLM_BACKEND_CHOICE:-}"
        FRONTEND_BACKEND_TARGET="${RESUME_FRONTEND_BACKEND_TARGET:-}"
        LLAMA_COMPONENT_ACTION="${RESUME_LLAMA_COMPONENT_ACTION:-skip}"
        OLLAMA_COMPONENT_ACTION="${RESUME_OLLAMA_COMPONENT_ACTION:-skip}"
        OPENWEBUI_COMPONENT_ACTION="${RESUME_OPENWEBUI_COMPONENT_ACTION:-skip}"
        LIBRECHAT_COMPONENT_ACTION="${RESUME_LIBRECHAT_COMPONENT_ACTION:-skip}"
        OPENCLAW_COMPONENT_ACTION="${RESUME_OPENCLAW_COMPONENT_ACTION:-skip}"
        LLAMA_CTX_SIZE="${RESUME_LLAMA_CTX_SIZE:-65536}"
        LOAD_DEFAULT_MODEL="${RESUME_LOAD_DEFAULT_MODEL:-n}"
        RUN_LLAMA_BENCH="${RESUME_RUN_LLAMA_BENCH:-n}"
        INSTALL_LLAMA_SERVICE="${RESUME_INSTALL_LLAMA_SERVICE:-n}"
        EXPOSE_LLM_ENGINE="${RESUME_EXPOSE_LLM_ENGINE:-n}"
        INSTALL_OPENWEBUI="${RESUME_INSTALL_OPENWEBUI:-n}"
        INSTALL_LIBRECHAT="${RESUME_INSTALL_LIBRECHAT:-n}"
        LLAMACPP_MODEL_REPO="${RESUME_LLAMACPP_MODEL_REPO:-}"
        OLLAMA_PULL_MODEL="${RESUME_OLLAMA_PULL_MODEL:-}"
        LLM_DEFAULT_MODEL_CHOICE="${RESUME_LLM_DEFAULT_MODEL_CHOICE:-}"
        SELECTED_MODEL_REPO="${RESUME_SELECTED_MODEL_REPO:-}"
        LLAMA_BUILD_VARIANT="${RESUME_LLAMA_BUILD_VARIANT:-}"
        LLAMA_VRAM_TIER="${RESUME_LLAMA_VRAM_TIER:-}"
        LLAMA_NGL="${RESUME_LLAMA_NGL:-}"
        LLAMA_CACHE_TYPE_K="${RESUME_LLAMA_CACHE_TYPE_K:-}"
        LLAMA_CACHE_TYPE_V="${RESUME_LLAMA_CACHE_TYPE_V:-}"
        LLAMA_FLASH_ATTN="${RESUME_LLAMA_FLASH_ATTN:-n}"
        LLAMA_UBATCH="${RESUME_LLAMA_UBATCH:-}"
        LLAMA_CPU_MOE="${RESUME_LLAMA_CPU_MOE:-y}"
        LLAMA_FIT="${RESUME_LLAMA_FIT:-n}"
        LLAMA_FIT_CTX="${RESUME_LLAMA_FIT_CTX:-}"
        LLAMA_MLOCK="${RESUME_LLAMA_MLOCK:-n}"
        LLAMA_DIO="${RESUME_LLAMA_DIO:-n}"
        OPENCLAW_RELEASE_CHANNEL="${RESUME_OPENCLAW_RELEASE_CHANNEL:-latest}"
        EXPOSE_OPENCLAW="${RESUME_EXPOSE_OPENCLAW:-n}"
        OPENCLAW_PORT="${RESUME_OPENCLAW_PORT:-18789}"
        LOCAL_MIRROR_BASE="${RESUME_LOCAL_MIRROR_BASE:-}"

        printf "%b\n" "  Restored selections: [${MASTER_SELECTIONS[*]}]"
        printf "%b\n" "  Already completed:   [${MASTER_INSTALLED_STATE[*]}]"
        printf "%b\n" "  Target user:         $TARGET_USER"
        echo ""
        detect_gpu # re-detect GPU (now loaded after reboot)
        # Jump straight to installation — skip all menus
    else
        determine_target_user
        detect_gpu

        clear
        print_status_header
    fi

    # NB: indices 7, 8, 9, 10, 11, 12, 13 are filtered out of the UI by the
    # menu-rendering loop below (they carry the NVIDIA/CUDA stack and btop,
    # which are inapplicable on Apple Silicon). Their labels are kept here so
    # other index-based code paths (dependency map, resume state) continue to
    # address them by the same numbers as the Ubuntu script.
    # Index 1 is now visible as "Install Xcode Command Line Tools".
    local MASTER_OPTIONS=(
        "Update System Packages (softwareupdate + brew update)"
        "Install Xcode Command Line Tools (required by Homebrew, Python, LLM stack)"
        "Install Python Environment"
        "Install OrbStack (replaces Docker)"
        "Install NVM, Node.js & NPM"
        "Install Homebrew"
        "Install Google Gemini CLI"
        "Install NVIDIA eGPU Support (Placeholder)"
        "Install btop (hidden on macOS port)"
        "Install nvtop (n/a on Apple Silicon)"
        "Install CUDA (n/a on Apple Silicon)"
        "Install gcc compiler (hidden on macOS port)"
        "Install NVIDIA Container Toolkit (n/a on Apple Silicon)"
        "Install cuDNN (n/a on Apple Silicon)"
        "Install Local LLM Support (Ollama, llama.cpp, Open-WebUI)"
        "Install OpenClaw"
    )

    local MASTER_FUNCS=(
        update_system
        ensure_xcode_clt
        install_python
        install_docker
        install_nvm_node
        install_homebrew
        install_gemini_cli
        install_nvidia_driver
        install_btop
        install_nvtop
        install_cuda_toolkit
        install_gcc
        install_container_toolkit
        install_cudnn
        install_local_llm
        install_openclaw
    )

    local MENU_ITEM_COUNT=16
    # NB: MASTER_SELECTIONS, MASTER_INSTALLED_STATE, ACTIVE_INDICES are global
    # (declared at top of script) so save_resume_state() can access them.
    # In resume mode they were already populated from the state file above.
    if [[ "$RESUME_MODE" == false ]]; then
        MASTER_SELECTIONS=()
        MASTER_INSTALLED_STATE=()
        for ((i = 0; i < MENU_ITEM_COUNT; i++)); do
            MASTER_SELECTIONS+=(0)
            MASTER_INSTALLED_STATE+=(0)
        done
        MASTER_SELECTIONS[0]=1
        ACTIVE_INDICES=(0)
    fi
    local UI_TO_MASTER=()

    ensure_active_index() {
        local idx=$1
        # shellcheck disable=SC2076 # Intentional literal match, not regex
        if [[ ! " ${ACTIVE_INDICES[*]} " =~ " ${idx} " ]]; then
            ACTIVE_INDICES+=("$idx")
            # bash 3.2 on macOS has no `mapfile`; read-sort-assign in a loop.
            local _sorted=() _line
            while IFS= read -r _line; do _sorted+=("$_line"); done \
                < <(printf '%s\n' "${ACTIVE_INDICES[@]}" | sort -n)
            ACTIVE_INDICES=("${_sorted[@]}")
        fi
    }

    # Declarative dependency map: "required_idx dependent_idx [dependent_idx ...]"
    # Read as: required_idx must be installed whenever any listed dependent_idx is selected.
    # Also encodes reverse: deselecting required_idx cascades to deselect dependents.
    # Format per entry: "req dep1 dep2 ..."
    local -a DEP_MAP=(
        "1 2 3 4 5 6 14 15" # Xcode CLT(1) <- Python(2), OrbStack(3), NVM(4), Homebrew(5), Gemini(6), LLM(14), OpenClaw(15)
        "4 6 15"            # NVM(4)        <- Gemini(6), OpenClaw(15)
        "5 15"              # Homebrew(5)   <- OpenClaw(15)
        "3 12"              # Docker(3)     <- NVIDIA CTK(12)
        "7 10 12 13"        # NV driver(7)  <- CUDA(10), CTK(12), cuDNN(13)
        "10 13"             # CUDA(10)      <- cuDNN(13)
        "11 10"             # gcc(11)       <- CUDA(10)
    )

    # Dependency labels for user messages
    dep_label() {
        case "$1" in
            1) echo "Xcode Command Line Tools" ;;
            3) echo "OrbStack (Docker)" ;;
            4) echo "NVM/Node.js" ;;
            5) echo "Homebrew" ;;
            7) echo "NVIDIA GPU Driver" ;;
            10) echo "CUDA" ;;
            11) echo "gcc compiler" ;;
            *) echo "item $1" ;;
        esac
    }

    dep_label_for() {
        case "$1" in
            2) echo "Python" ;;
            3) echo "OrbStack (Docker)" ;;
            4) echo "NVM/Node.js" ;;
            5) echo "Homebrew" ;;
            6) echo "Gemini CLI" ;;
            10) echo "CUDA Toolkit" ;;
            12) echo "NVIDIA Container Toolkit" ;;
            13) echo "cuDNN" ;;
            14) echo "Local LLM Stack" ;;
            15) echo "OpenClaw" ;;
            *) echo "item $1" ;;
        esac
    }

    # Auto-add required deps when a dependent is selected; cascade-remove dependents
    # when a required dep is deselected. Call after any MASTER_SELECTIONS toggle.
    # $1 = index that was just toggled
    apply_deps() {
        local toggled=$1
        local entry req dependents added=() removed=()
        for entry in "${DEP_MAP[@]}"; do
            # shellcheck disable=SC2206
            local parts=($entry)
            req="${parts[0]}"
            dependents=("${parts[@]:1}")
            local dep_selected=0
            for dep in "${dependents[@]}"; do
                [[ ${MASTER_SELECTIONS[$dep]} -eq 1 ]] && dep_selected=1
            done

            # Required was deselected — cascade-remove its dependents
            if [[ "$toggled" -eq "$req" && ${MASTER_SELECTIONS[$req]} -eq 0 ]]; then
                for dep in "${dependents[@]}"; do
                    if [[ ${MASTER_SELECTIONS[$dep]} -eq 1 ]]; then
                        MASTER_SELECTIONS[$dep]=0
                        removed+=("$(dep_label_for "$dep")")
                    fi
                done
                if [[ ${#removed[@]} -gt 0 ]]; then
                    local joined
                    joined=$(printf '%s, ' "${removed[@]}")
                    printf "%b\n" "\n[Auto-unselected] ${joined%, } requires $(dep_label "$req")." && sleep 1.5
                fi
            fi

            # A dependent was selected — auto-add its required dep
            if [[ "$toggled" -ne "$req" && ${MASTER_SELECTIONS[$toggled]} -eq 1 ]]; then
                for dep in "${dependents[@]}"; do
                    [[ "$toggled" -eq "$dep" ]] || continue
                    if [[ "$dep_selected" -eq 1 && ${MASTER_INSTALLED_STATE[$req]} -eq 0 && ${MASTER_SELECTIONS[$req]} -eq 0 ]]; then
                        MASTER_SELECTIONS[$req]=1
                        ensure_active_index "$req"
                        added+=("$(dep_label "$req")")
                    fi
                done
            fi
        done
        if [[ ${#added[@]} -gt 0 ]]; then
            local joined
            joined=$(printf '%s, ' "${added[@]}")
            printf "%b\n" "\n[Auto-selected] ${joined%, } required by $(dep_label_for "$toggled")." && sleep 1.5
        fi
    }

    # Final validation pass — catches anything missed (e.g. goal-based presets, LLM stack)
    validate_deps() {
        local entry req dependents changed=0
        for entry in "${DEP_MAP[@]}"; do
            # shellcheck disable=SC2206
            local parts=($entry)
            req="${parts[0]}"
            dependents=("${parts[@]:1}")
            local dep_selected=0
            for dep in "${dependents[@]}"; do
                [[ ${MASTER_SELECTIONS[$dep]} -eq 1 ]] && dep_selected=1
            done
            if [[ $dep_selected -eq 1 && ${MASTER_INSTALLED_STATE[$req]} -eq 0 && ${MASTER_SELECTIONS[$req]} -eq 0 ]]; then
                MASTER_SELECTIONS[$req]=1
                ensure_active_index "$req"
                printf "%b\n" "\n\e[1;33m[Validation Fix]\e[0m $(dep_label "$req") auto-added (required dependency)."
                changed=1
            fi
        done
        return $changed
    }

    if [[ "$RESUME_MODE" == false ]]; then
        local GOAL_SELECTIONS=(0 0 0)
        local GOAL_OPTIONS=(
            "OpenClaw Server Setup (Core tools, Docker, Node.js, OpenClaw)"
            "NVIDIA GPU Setup (Driver, CUDA, Container Toolkit, cuDNN)"
            "Local LLM Setup (Ollama, llama.cpp, Open-WebUI)"
        )

        while true; do
            clear
            print_status_header
            printf "%b\n" "\n\e[1;36mSelect Installation Goals:\e[0m"
            for i in "${!GOAL_OPTIONS[@]}"; do
                if [[ ${GOAL_SELECTIONS[$i]} -eq 1 ]]; then
                    printf "%b\n" " \e[1;32m[x]\e[0m $((i + 1)). ${GOAL_OPTIONS[$i]}"
                else
                    printf "%b\n" " [ ] $((i + 1)). ${GOAL_OPTIONS[$i]}"
                fi
            done
            echo "---------------------------------"
            echo "Use numbers [1-3] to toggle a goal. Press 'a' to select all."
            echo "Press 'c' to continue to the detailed menu, or 'q' to quit."
            if sudo test -f "$(get_llama_plist_path)"; then
                echo "Press 'e' to edit llama.cpp server parameters."
            fi
            echo "Press 's' to save current settings to ~/AI-settings.txt."
            read -p "Your choice: " goal_choice

            if [[ "$goal_choice" =~ ^[1-3]$ ]]; then
                local index=$((goal_choice - 1))
                GOAL_SELECTIONS[$index]=$((1 - GOAL_SELECTIONS[$index]))
            elif [[ "$goal_choice" == "a" || "$goal_choice" == "A" ]]; then
                GOAL_SELECTIONS=(1 1 1)
            elif [[ "$goal_choice" == "s" || "$goal_choice" == "S" ]]; then
                save_ai_settings_file
                echo ""
                read -p "Press Enter to return to the menu…" _
            elif [[ "$goal_choice" == "e" || "$goal_choice" == "E" ]]; then
                if sudo test -f "$(get_llama_plist_path)"; then
                    edit_llama_server_parameters
                    echo ""
                    read -p "Press Enter to return to the menu…" _
                else
                    printf "%b\n" "\nllama-server LaunchDaemon is not installed." && sleep 1
                fi
            elif [[ "$goal_choice" == "c" || "$goal_choice" == "C" ]]; then
                if [[ ${GOAL_SELECTIONS[0]} -eq 0 && ${GOAL_SELECTIONS[1]} -eq 0 && ${GOAL_SELECTIONS[2]} -eq 0 ]]; then
                    printf "%b\n" "\nPlease select at least one goal before continuing." && sleep 1
                else
                    break
                fi
            elif [[ "$goal_choice" == "q" || "$goal_choice" == "Q" ]]; then
                printf "%b\n" "\nExiting."
                exit 0
            else
                printf "%b\n" "\nInvalid option." && sleep 1
            fi
        done

        if [[ ${GOAL_SELECTIONS[0]} -eq 1 ]]; then ACTIVE_INDICES+=(1 2 3 4 5 6 15); fi
        if [[ ${GOAL_SELECTIONS[1]} -eq 1 ]]; then ACTIVE_INDICES+=(1 7 8 9 10 11 12 13); fi
        if [[ ${GOAL_SELECTIONS[2]} -eq 1 ]]; then ACTIVE_INDICES+=(1 14); fi

        # bash 3.2 on macOS has no `mapfile`; read-sort-dedup-assign in a loop.
        # sort -nu removes duplicates — index 1 (Xcode CLT) appears in all three
        # goal blocks and must not be added to ACTIVE_INDICES more than once.
        _sorted_ai=()
        while IFS= read -r _line; do _sorted_ai+=("$_line"); done \
            < <(printf '%s\n' "${ACTIVE_INDICES[@]}" | sort -nu)
        ACTIVE_INDICES=("${_sorted_ai[@]}")
        unset _sorted_ai _line

        check_installations

        while true; do
            show_menu
            read -p "Your choice: " choice

            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#UI_TO_MASTER[@]} ]; then
                local master_index=${UI_TO_MASTER[$choice]}

                if [[ $master_index -eq 0 ]]; then
                    printf "%b\n" "\nSystem Update is required and cannot be deselected." && sleep 1.5
                    continue
                fi

                if [[ ${MASTER_INSTALLED_STATE[$master_index]} -eq 1 && $master_index -ne 14 && $master_index -ne 15 ]]; then
                    printf "%b\n" "\nOption $((choice)) is already installed." && sleep 1
                    continue
                fi

                if [[ $master_index -eq 14 ]]; then
                    if [[ ${MASTER_SELECTIONS[14]} -eq 1 ]]; then
                        MASTER_SELECTIONS[14]=0
                        reset_local_ai_component_state
                        detect_local_ai_components
                        if [[ "$LLAMA_COMPONENT_STATUS" != "missing" || "$OLLAMA_COMPONENT_STATUS" != "missing" || "$OPENWEBUI_COMPONENT_STATUS" != "missing" || "$LIBRECHAT_COMPONENT_STATUS" != "missing" ]]; then
                            MASTER_INSTALLED_STATE[14]=1
                        else
                            MASTER_INSTALLED_STATE[14]=0
                        fi
                        continue
                    fi

                    if configure_local_llm_components; then
                        MASTER_SELECTIONS[14]=1
                        MASTER_INSTALLED_STATE[14]=0
                    else
                        reset_local_ai_component_state
                        MASTER_SELECTIONS[14]=0
                        continue
                    fi
                elif [[ $master_index -eq 15 ]]; then
                    if [[ ${MASTER_SELECTIONS[15]} -eq 1 ]]; then
                        MASTER_SELECTIONS[15]=0
                        OPENCLAW_COMPONENT_ACTION="skip"
                        EXPOSE_OPENCLAW="n"
                        OPENCLAW_PORT="18789"
                        detect_local_ai_components
                        if [[ "$OPENCLAW_COMPONENT_STATUS" != "missing" ]]; then
                            MASTER_INSTALLED_STATE[15]=1
                        else
                            MASTER_INSTALLED_STATE[15]=0
                        fi
                        continue
                    fi

                    if configure_openclaw_selection; then
                        MASTER_SELECTIONS[15]=1
                        MASTER_INSTALLED_STATE[15]=0
                    else
                        MASTER_SELECTIONS[15]=0
                        OPENCLAW_COMPONENT_ACTION="skip"
                        EXPOSE_OPENCLAW="n"
                        OPENCLAW_PORT="18789"
                        continue
                    fi
                else
                    MASTER_SELECTIONS[$master_index]=$((1 - MASTER_SELECTIONS[$master_index]))
                fi

                # Apply dependency rules for the toggled item
                apply_deps "$master_index"

                # NVIDIA driver flavour must be decided up front (not deferred to
                # install time) so the user isn't interrupted mid-install.  This
                # fires whether item 7 was toggled directly or auto-added as a
                # dependency of CUDA/CTK/cuDNN.
                if [[ ${MASTER_SELECTIONS[7]} -eq 1 && ${MASTER_INSTALLED_STATE[7]} -eq 0 && -z "${NVIDIA_DRIVER_TYPE:-}" ]]; then
                    if ! select_nvidia_driver_type; then
                        MASTER_SELECTIONS[7]=0
                        apply_deps 7
                    fi
                elif [[ ${MASTER_SELECTIONS[7]} -eq 0 && -n "${NVIDIA_DRIVER_TYPE:-}" ]]; then
                    NVIDIA_DRIVER_TYPE=""
                fi

                # LLM Stack (14) has runtime-conditional deps based on chosen sub-options
                if [[ $master_index -eq 14 && ${MASTER_SELECTIONS[14]} -eq 1 ]]; then
                    local auto_selected=""
                    if [[ ("$OPENWEBUI_COMPONENT_ACTION" == "install" || "$LIBRECHAT_COMPONENT_ACTION" == "install") && ${MASTER_SELECTIONS[3]} -eq 0 && ${MASTER_INSTALLED_STATE[3]} -eq 0 ]]; then
                        MASTER_SELECTIONS[3]=1
                        ensure_active_index 3
                        auto_selected+="Docker, "
                    fi
                    if [[ "$LLAMA_COMPONENT_ACTION" == "install" && "$LLM_BACKEND_CHOICE" == "llama_cuda" && "$HAS_NVIDIA_GPU" == true && ${MASTER_SELECTIONS[10]} -eq 0 && ${MASTER_INSTALLED_STATE[10]} -eq 0 ]]; then
                        MASTER_SELECTIONS[10]=1
                        ensure_active_index 10
                        auto_selected+="CUDA, "
                    fi
                    if [[ (("$OPENWEBUI_COMPONENT_ACTION" == "install") || ("$LLAMA_COMPONENT_ACTION" == "install" && "$LLM_BACKEND_CHOICE" == "llama_cuda")) && "$HAS_NVIDIA_GPU" == true && ${MASTER_SELECTIONS[12]} -eq 0 && ${MASTER_INSTALLED_STATE[12]} -eq 0 ]]; then
                        MASTER_SELECTIONS[12]=1
                        ensure_active_index 12
                        auto_selected+="NVIDIA CTK, "
                    fi
                    if [[ -n "$auto_selected" ]]; then
                        printf "%b\n" "\n[Auto-selected] ${auto_selected%, } required for Local LLM Stack components." && sleep 2
                    fi
                    # Re-run dep map now that CUDA/CTK may have been added
                    apply_deps 10
                    apply_deps 12
                fi
            elif [[ "$choice" == "a" || "$choice" == "A" ]]; then
                for master_index in "${ACTIVE_INDICES[@]}"; do
                    if [[ ${MASTER_INSTALLED_STATE[$master_index]} -eq 0 ]]; then
                        if [[ $master_index -eq 15 && "$IS_DIFFERENT_USER" == false ]]; then
                            continue
                        fi
                        if [[ $master_index -eq 14 || $master_index -eq 15 ]]; then
                            continue
                        fi
                        MASTER_SELECTIONS[$master_index]=1
                    fi
                done
                # Resolve deps for all newly-selected items
                for master_index in "${!MASTER_SELECTIONS[@]}"; do
                    [[ ${MASTER_SELECTIONS[$master_index]} -eq 1 ]] && apply_deps "$master_index"
                done
                if [[ ${MASTER_SELECTIONS[7]} -eq 1 && ${MASTER_INSTALLED_STATE[7]} -eq 0 && -z "${NVIDIA_DRIVER_TYPE:-}" ]]; then
                    if ! select_nvidia_driver_type; then
                        MASTER_SELECTIONS[7]=0
                        apply_deps 7
                    fi
                fi
                printf "%b\n" "\n[Info] 'Select all' skips Local LLM Support and OpenClaw because they require explicit repair/install choices." && sleep 2
            elif [[ "$choice" == "i" || "$choice" == "I" ]]; then
                break
            elif [[ "$choice" == "q" || "$choice" == "Q" ]]; then
                printf "%b\n" "\nExiting."
                exit 0
            else
                printf "%b\n" "\nInvalid option." && sleep 1
            fi
        done

        # --- Final Pre-Installation Dependency Validation ---

        # LLM Stack (14) has runtime-conditional deps that depend on sub-choices
        # made inside the LLM config dialog — handle these before the static map pass.
        if [[ ${MASTER_SELECTIONS[14]} -eq 1 ]]; then
            if [[ ("$OPENWEBUI_COMPONENT_ACTION" == "install" || "$LIBRECHAT_COMPONENT_ACTION" == "install") && ${MASTER_SELECTIONS[3]} -eq 0 && ${MASTER_INSTALLED_STATE[3]} -eq 0 ]]; then
                MASTER_SELECTIONS[3]=1
                ensure_active_index 3
                printf "%b\n" "\n\e[1;33m[Validation Fix]\e[0m Docker auto-added as it is required by Open-WebUI/LibreChat."
            fi
            if [[ "$LLAMA_COMPONENT_ACTION" == "install" && "$LLM_BACKEND_CHOICE" == "llama_cuda" && "$HAS_NVIDIA_GPU" == true && ${MASTER_SELECTIONS[10]} -eq 0 && ${MASTER_INSTALLED_STATE[10]} -eq 0 ]]; then
                MASTER_SELECTIONS[10]=1
                ensure_active_index 10
                printf "%b\n" "\n\e[1;33m[Validation Fix]\e[0m CUDA auto-added as it is required by llama.cpp (CUDA backend)."
            fi
            if [[ (("$OPENWEBUI_COMPONENT_ACTION" == "install") || ("$LLAMA_COMPONENT_ACTION" == "install" && "$LLM_BACKEND_CHOICE" == "llama_cuda")) && "$HAS_NVIDIA_GPU" == true && ${MASTER_SELECTIONS[12]} -eq 0 && ${MASTER_INSTALLED_STATE[12]} -eq 0 ]]; then
                MASTER_SELECTIONS[12]=1
                ensure_active_index 12
                printf "%b\n" "\n\e[1;33m[Validation Fix]\e[0m NVIDIA Container Toolkit auto-added as it is required by your LLM/GPU setup."
            fi
        fi

        # Static dependency map pass — catches anything not resolved during menu interaction
        local validation_changed=0
        validate_deps && validation_changed=0 || validation_changed=1

        if [[ $validation_changed -eq 1 ]]; then
            printf "%b\n" "\e[1;36mDependencies resolved. Proceeding with installation...\e[0m"
            sleep 3
        fi

        # --- Disk Space Check ---
        print_info "Checking available disk space..."
        local required_gb=5                                                                                            # Base requirement for general system updates and basic tools
        if [[ ${MASTER_SELECTIONS[10]} -eq 1 ]]; then required_gb=$((required_gb + 5)); fi                             # CUDA Toolkit
        if [[ ${MASTER_SELECTIONS[12]} -eq 1 ]]; then required_gb=$((required_gb + 2)); fi                             # NVIDIA Container Toolkit & Docker usage
        if [[ ${MASTER_SELECTIONS[14]} -eq 1 ]]; then required_gb=$((required_gb + 10)); fi                            # LLM Models and UI images
        if [[ "$INSTALL_LIBRECHAT" == "y" || "$INSTALL_LIBRECHAT" == "Y" ]]; then required_gb=$((required_gb + 2)); fi # LibreChat Docker images

        local free_space_mb
        free_space_mb=$(df -m "$TARGET_USER_HOME" | awk 'NR==2 {print $4}')
        local free_space_gb=$((free_space_mb / 1024))

        if [[ "$free_space_gb" -lt "$required_gb" ]]; then
            printf "%b\n" "\n\e[1;31m⚠️  WARNING: Low Disk Space\e[0m"
            printf "%b\n" "You have selected options that require approximately \e[1;33m${required_gb}GB\e[0m of free space."
            printf "%b\n" "Your target partition ($TARGET_USER_HOME) only has \e[1;31m${free_space_gb}GB\e[0m available."
            if ! ask_yn "Do you want to proceed anyway? [y/N]: " "n"; then
                printf "%b\n" "\n❌ Aborting installation to prevent disk exhaustion."
                exit 1
            fi
        else
            print_success "Disk space check passed (Required: ~${required_gb}GB, Available: ${free_space_gb}GB)."
        fi

        # --- RAM / Memory Check ---
        if [[ ${MASTER_SELECTIONS[14]} -eq 1 ]]; then
            print_info "Checking available unified memory for LLM inference..."
            local total_ram_gb="${UNIFIED_MEMORY_GB:-0}"
            if [[ "$total_ram_gb" -eq 0 ]]; then
                local _bytes
                _bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
                total_ram_gb=$(awk -v b="$_bytes" 'BEGIN { printf "%d", b / 1024 / 1024 / 1024 + 0.5 }')
            fi

            if [[ "$total_ram_gb" -lt 16 ]]; then
                while true; do
                    printf "%b\n" "\n\e[1;31m⚠️  WARNING: Low System Memory\e[0m"
                    printf "%b\n" "You selected the Local LLM Stack, which generally requires at least \e[1;33m16GB\e[0m of RAM."
                    printf "%b\n" "Your system only has \e[1;31m${total_ram_gb}GB\e[0m of total memory."
                    printf "%b\n" "On a \e[1;33m${total_ram_gb}GB\e[0m device, models in the \e[1;33m${total_ram_gb}GB UMA tier\e[0m will run most comfortably."
                    echo ""
                    printf "%b\n" "  1. Proceed anyway  (performance may be degraded)"
                    printf "%b\n" "  2. Re-select model  (pick a smaller model for ${total_ram_gb}GB)"
                    printf "%b\n" "  3. Abort installation"
                    read -rp "Your choice [1-3]: " _mem_choice
                    case "${_mem_choice:-3}" in
                        1) break ;;
                        2)
                            if [[ "$LLM_BACKEND_CHOICE" == "ollama" ]]; then
                                configure_llm_model_prompt "ollama"
                            else
                                configure_llm_model_prompt "${LLAMA_BUILD_VARIANT:-llama_cpu}"
                                configure_context_memory  "${LLAMA_BUILD_VARIANT:-llama_cpu}"
                            fi
                            break
                            ;;
                        3)
                            printf "%b\n" "\n❌ Aborting installation."
                            exit 1
                            ;;
                        *)
                            echo "Invalid choice."
                            sleep 1
                            ;;
                    esac
                done
            else
                print_success "Memory check passed (${total_ram_gb}GB total RAM available)."
            fi
        fi
    fi # end: if [[ "$RESUME_MODE" == false ]]

    # Dry-run: show the plan for the current selections and exit before any
    # mutating work (setup_env_secrets writes to $HOME, installers touch the system).
    if [[ "$DRY_RUN" == "true" ]]; then
        print_dry_run_plan "$MENU_ITEM_COUNT" "${MASTER_OPTIONS[@]}"
        exit 0
    fi

    # Configure API keys after menu selection, before installation tasks begin.
    # Skipped on resume — keys were already configured in the original run.
    if [[ "$RESUME_MODE" == false ]]; then
        setup_env_secrets
    fi

    printf "%b\n" "\n--- Starting Installation ---"
    local something_installed=0
    for i in "${!MASTER_SELECTIONS[@]}"; do
        if [[ ${MASTER_SELECTIONS[$i]} -eq 1 && ${MASTER_INSTALLED_STATE[$i]} -eq 0 ]]; then
            something_installed=1
            break
        fi
    done

    if [[ $something_installed -eq 1 ]]; then
        install_base_dependencies

        for i in "${!MASTER_SELECTIONS[@]}"; do
            if [[ ${MASTER_SELECTIONS[$i]} -eq 1 && ${MASTER_INSTALLED_STATE[$i]} -eq 0 ]]; then
                # Use if/fi so a step that returns non-zero (e.g. CTK skipped because
                # NVIDIA module not yet loaded) doesn't abort the whole script.
                if ${MASTER_FUNCS[$i]}; then
                    MASTER_INSTALLED_STATE[$i]=1
                fi

                # No reboot checkpoint on Apple Silicon — Metal is built into
                # the kernel and needs no driver install.
            fi
        done

        # If we resumed and all pending steps are now done, clear the resume state.
        if [[ "$RESUME_MODE" == true ]]; then
            local _all_done=1
            for i in "${!MASTER_SELECTIONS[@]}"; do
                if [[ ${MASTER_SELECTIONS[$i]} -eq 1 && ${MASTER_INSTALLED_STATE[$i]} -eq 0 ]]; then
                    _all_done=0
                    break
                fi
            done
            [[ $_all_done -eq 1 ]] && clear_resume_state
        fi

        print_success "Selected installations are complete."
        verify_installations
        print_final_summary

        # --- Optional: demote target user back to standard account ---
        # The user was created as admin so Homebrew could install. Now that
        # everything is in place, offer to remove the admin privilege.
        # Exception: if the LLM stack is installed, the user needs admin to
        # manage the llama-server LaunchDaemon (sudo launchctl / plist writes).
        if [[ "$IS_DIFFERENT_USER" == true ]] && \
           dseditgroup -o checkmember -m "$TARGET_USER" admin &>/dev/null; then
            echo ""
            printf "%b\n" "\e[1;36m── Optional: Demote '$TARGET_USER' to Standard User ──\e[0m"
            if [[ ${MASTER_SELECTIONS[14]:-0} -eq 1 ]]; then
                printf "%b\n" "\e[1;33m⚠️  The LLM stack is installed.\e[0m"
                printf "%b\n" "'$TARGET_USER' needs admin to manage the llama-server service"
                printf "%b\n" "(sudo launchctl, macos-llama-reconfigure.sh). Demotion will"
                printf "%b\n" "break those workflows unless another admin account is used."
            else
                printf "%b\n" "The packages installed do not require admin privileges to run."
                printf "%b\n" "You can safely demote '$TARGET_USER' to a standard account."
            fi
            echo ""
            if ask_yn "Demote '$TARGET_USER' to standard user now? [y/N]: " "n"; then
                if sudo dseditgroup -o edit -d "$TARGET_USER" -t user admin 2>/dev/null; then
                    print_success "'$TARGET_USER' is now a standard (non-admin) user."
                else
                    printf "%b\n" "❌ \e[1;31mFailed to demote '$TARGET_USER'.\e[0m Run manually:"
                    printf "%b\n" "   sudo dseditgroup -o edit -d $TARGET_USER -t user admin"
                fi
            else
                print_info "Kept '$TARGET_USER' as administrator."
            fi
        fi

        # --- Expose Services Menu ---
        local EXPOSE_OPTIONS=()
        local EXPOSE_KEYS=()
        local EXPOSE_SELECTIONS=()

        local current_oc_port="${OPENCLAW_PORT:-18789}"
        if sudo test -f "$TARGET_USER_HOME/.openclaw/openclaw.json"; then current_oc_port=$(sudo jq -r '.gateway.port // 18789' "$TARGET_USER_HOME/.openclaw/openclaw.json" 2>/dev/null); fi

        if sudo test -f "$TARGET_USER_HOME/.openclaw/openclaw.json" && [[ "$EXPOSE_OPENCLAW" != "y" ]]; then
            EXPOSE_OPTIONS+=("OpenClaw Gateway (Port $current_oc_port)")
            EXPOSE_KEYS+=("openclaw")
            EXPOSE_SELECTIONS+=(0)
        fi

        local exposed_msg=""
        if [ ${#EXPOSE_OPTIONS[@]} -gt 0 ]; then
            while true; do
                clear
                print_status_header
                printf "%b\n" "\n\e[1;36mSelect Services to Expose to the Network (Bind to 0.0.0.0):\e[0m"
                for i in "${!EXPOSE_OPTIONS[@]}"; do
                    if [[ ${EXPOSE_SELECTIONS[$i]} -eq 1 ]]; then
                        printf "%b\n" " \e[1;32m[x]\e[0m $((i + 1)). ${EXPOSE_OPTIONS[$i]}"
                    else
                        printf "%b\n" " [ ] $((i + 1)). ${EXPOSE_OPTIONS[$i]}"
                    fi
                done
                echo "---------------------------------"
                echo "Use numbers [1-${#EXPOSE_OPTIONS[@]}] to toggle. Press 'a' to select all."
                echo "Press 'c' to confirm and continue."
                read -p "Your choice: " exp_choice

                if [[ "$exp_choice" =~ ^[0-9]+$ ]] && [ "$exp_choice" -ge 1 ] && [ "$exp_choice" -le ${#EXPOSE_OPTIONS[@]} ]; then
                    local idx=$((exp_choice - 1))
                    EXPOSE_SELECTIONS[$idx]=$((1 - EXPOSE_SELECTIONS[$idx]))
                elif [[ "$exp_choice" == "a" || "$exp_choice" == "A" ]]; then
                    for i in "${!EXPOSE_SELECTIONS[@]}"; do EXPOSE_SELECTIONS[$i]=1; done
                elif [[ "$exp_choice" == "c" || "$exp_choice" == "C" ]]; then
                    break
                else
                    printf "%b\n" "\nInvalid option." && sleep 1
                fi
            done

            local applied_exposures=0
            for i in "${!EXPOSE_KEYS[@]}"; do
                if [[ ${EXPOSE_SELECTIONS[$i]} -eq 1 ]]; then
                    if [[ $applied_exposures -eq 0 ]]; then print_info "Applying exposure settings..."; fi
                    applied_exposures=1

                    case "${EXPOSE_KEYS[$i]}" in
                        "openclaw")
                            local oc_conf="$TARGET_USER_HOME/.openclaw/openclaw.json"
                            local tmp_json
                            tmp_json=$(sudo mktemp)
                            # gateway.bind uses mode strings, not IP addresses
                            local _jq_out
                            _jq_out=$(sudo jq '.gateway.bind = "lan"' "$oc_conf") || { echo "⚠️  jq filter failed — config not updated." >&2; }
                            if [[ -n "$_jq_out" ]] && echo "$_jq_out" | jq empty 2>/dev/null; then
                                echo "$_jq_out" | sudo tee "$tmp_json" >/dev/null &&
                                    sudo mv "$tmp_json" "$oc_conf" && sudo chown "$TARGET_USER":staff "$oc_conf"
                            fi
                            exposed_msg+="  - OpenClaw Gateway is at IP:$current_oc_port\n"
                            ;;
                    esac
                fi
            done
            if [[ $applied_exposures -eq 1 ]]; then print_success "Exposure settings applied."; fi
        fi

        local exposed_llm_backend="$LLM_BACKEND_CHOICE"
        if [[ -z "$exposed_llm_backend" ]]; then
            if [[ "$FRONTEND_BACKEND_TARGET" == "ollama" ]]; then
                exposed_llm_backend="ollama"
            elif [[ "$FRONTEND_BACKEND_TARGET" == "llama" ]]; then
                exposed_llm_backend="llama_cpu"
            fi
        fi

        if [[ "$EXPOSE_OPENCLAW" == "y" ]]; then
            exposed_msg+="  - OpenClaw Gateway is at IP:$OPENCLAW_PORT\n"
        fi
        if [[ "$EXPOSE_LLM_ENGINE" == "y" ]]; then
            if [[ "$exposed_llm_backend" == "ollama" ]]; then
                exposed_msg+="  - Ollama is at IP:11434\n"
            else
                exposed_msg+="  - llama.cpp is at IP:8080\n"
            fi
        fi
        if [[ "$INSTALL_OPENWEBUI" == "y" ]]; then
            exposed_msg+="  - Open-WebUI is at IP:8081\n"
        fi
        if [[ "$INSTALL_LIBRECHAT" == "y" ]]; then
            exposed_msg+="  - LibreChat is at IP:$LIBRECHAT_PORT\n"
        fi


        printf "%b\n" "\n\e[1;32m================================================================\e[0m"
        printf "%b\n" "\e[1;32mINSTALLATION COMPLETE!\e[0m"
        if [[ -n "$exposed_msg" ]]; then
            printf "%b\n" "\n\e[1;36mNetwork Services Exposed:\e[0m"
            printf "%b\n" "$exposed_msg"
        fi
        if [[ "$IS_DIFFERENT_USER" == true ]]; then
            printf "%b\n" "\e[1;33mPlease switch to your new user (\e[1;36m$TARGET_USER\e[1;33m) and run the following command to activate your environment:\e[0m"
            printf "%b\n" "\e[1;36msu - $TARGET_USER\e[0m"
        else
            printf "%b\n" "\e[1;33mPlease run the following command to activate your new environment:\e[0m"
        fi
        if sudo test -f "$TARGET_USER_HOME/.zshrc" && [[ "$SHELL" == *"zsh"* || "${MASTER_SELECTIONS[1]}" == "1" || "${MASTER_INSTALLED_STATE[1]}" == "1" ]]; then
            printf "%b\n" "\e[1;36msource ~/.zshrc\e[0m"
        else
            printf "%b\n" "\e[1;36msource ~/.bashrc\e[0m"
        fi
        printf "%b\n" "\e[1;32m================================================================\e[0m\n"
    else
        print_info "No options were selected for installation."
    fi

    # macOS port: the Ubuntu script triggered a reboot after installing the
    # NVIDIA kernel module. None of the macOS-enabled menu items (1-6, 14-15)
    # need a reboot to take effect, so the post-install reboot gate is a no-op.
    # Leaving POST_INSTALL_ACTIONS untouched — nothing in the macOS path appends
    # "reboot" to it — keeps the surface API the same without prompting the user.
}

# ── Resume-after-reboot helpers ───────────────────────────────────────────────

# Write current installation state to disk so it can be restored after reboot.
# Also records all config variables that drive install functions.
save_resume_state() {
    sudo mkdir -p "$(dirname "$RESUME_STATE_FILE")"

    # Every persisted value is shell-quoted with printf %q so a value
    # containing spaces, quotes, backslashes, or $ survives a source-back
    # intact. Bare NAME="…" interpolation breaks if the value contains " or \.
    local tmp
    tmp=$(mktemp)
    {
        printf '# ubuntu-prep-setup.sh resume state — written %s\n' "$(date)"
        printf '# Sourced by the script when invoked with --resume.\n\n'

        printf 'RESUME_SELECTIONS=%q\n' "${MASTER_SELECTIONS[*]}"
        printf 'RESUME_COMPLETED=%q\n'  "${MASTER_INSTALLED_STATE[*]}"
        printf 'RESUME_ACTIVE=%q\n'     "${ACTIVE_INDICES[*]}"

        printf '\n# User / environment\n'
        printf 'RESUME_TARGET_USER=%q\n'           "${TARGET_USER}"
        printf 'RESUME_TARGET_USER_HOME=%q\n'      "${TARGET_USER_HOME}"
        printf 'RESUME_IS_DIFFERENT_USER=%q\n'     "${IS_DIFFERENT_USER}"
        printf 'RESUME_HAS_NVIDIA_GPU=%q\n'        "${HAS_NVIDIA_GPU}"
        printf 'RESUME_NVIDIA_DRIVER_TYPE=%q\n'    "${NVIDIA_DRIVER_TYPE:-}"

        printf '\n# LLM config\n'
        printf 'RESUME_LLM_BACKEND_CHOICE=%q\n'         "${LLM_BACKEND_CHOICE:-}"
        printf 'RESUME_FRONTEND_BACKEND_TARGET=%q\n'    "${FRONTEND_BACKEND_TARGET:-}"
        printf 'RESUME_LLAMA_COMPONENT_ACTION=%q\n'     "${LLAMA_COMPONENT_ACTION:-skip}"
        printf 'RESUME_OLLAMA_COMPONENT_ACTION=%q\n'    "${OLLAMA_COMPONENT_ACTION:-skip}"
        printf 'RESUME_OPENWEBUI_COMPONENT_ACTION=%q\n' "${OPENWEBUI_COMPONENT_ACTION:-skip}"
        printf 'RESUME_LIBRECHAT_COMPONENT_ACTION=%q\n' "${LIBRECHAT_COMPONENT_ACTION:-skip}"
        printf 'RESUME_OPENCLAW_COMPONENT_ACTION=%q\n'  "${OPENCLAW_COMPONENT_ACTION:-skip}"
        printf 'RESUME_LLAMA_CTX_SIZE=%q\n'             "${LLAMA_CTX_SIZE:-65536}"
        printf 'RESUME_LOAD_DEFAULT_MODEL=%q\n'         "${LOAD_DEFAULT_MODEL:-n}"
        printf 'RESUME_RUN_LLAMA_BENCH=%q\n'            "${RUN_LLAMA_BENCH:-n}"
        printf 'RESUME_INSTALL_LLAMA_SERVICE=%q\n'      "${INSTALL_LLAMA_SERVICE:-n}"
        printf 'RESUME_EXPOSE_LLM_ENGINE=%q\n'          "${EXPOSE_LLM_ENGINE:-n}"
        printf 'RESUME_INSTALL_OPENWEBUI=%q\n'          "${INSTALL_OPENWEBUI:-n}"
        printf 'RESUME_INSTALL_LIBRECHAT=%q\n'          "${INSTALL_LIBRECHAT:-n}"
        printf 'RESUME_LLAMACPP_MODEL_REPO=%q\n'        "${LLAMACPP_MODEL_REPO:-}"
        printf 'RESUME_OLLAMA_PULL_MODEL=%q\n'          "${OLLAMA_PULL_MODEL:-}"
        printf 'RESUME_LLM_DEFAULT_MODEL_CHOICE=%q\n'   "${LLM_DEFAULT_MODEL_CHOICE:-}"
        printf 'RESUME_SELECTED_MODEL_REPO=%q\n'        "${SELECTED_MODEL_REPO:-}"
        printf 'RESUME_LLAMA_BUILD_VARIANT=%q\n'        "${LLAMA_BUILD_VARIANT:-}"
        printf 'RESUME_LLAMA_VRAM_TIER=%q\n'            "${LLAMA_VRAM_TIER:-}"
        printf 'RESUME_LLAMA_NGL=%q\n'                  "${LLAMA_NGL:-}"
        printf 'RESUME_LLAMA_CACHE_TYPE_K=%q\n'         "${LLAMA_CACHE_TYPE_K:-}"
        printf 'RESUME_LLAMA_CACHE_TYPE_V=%q\n'         "${LLAMA_CACHE_TYPE_V:-}"
        printf 'RESUME_LLAMA_FLASH_ATTN=%q\n'           "${LLAMA_FLASH_ATTN:-n}"
        printf 'RESUME_LLAMA_UBATCH=%q\n'               "${LLAMA_UBATCH:-}"
        printf 'RESUME_LLAMA_CPU_MOE=%q\n'              "${LLAMA_CPU_MOE:-y}"
        printf 'RESUME_LLAMA_FIT=%q\n'                  "${LLAMA_FIT:-n}"
        printf 'RESUME_LLAMA_FIT_CTX=%q\n'              "${LLAMA_FIT_CTX:-}"
        printf 'RESUME_LLAMA_MLOCK=%q\n'                "${LLAMA_MLOCK:-n}"
        printf 'RESUME_LLAMA_DIO=%q\n'                  "${LLAMA_DIO:-n}"

        printf '\n# OpenClaw config\n'
        printf 'RESUME_OPENCLAW_RELEASE_CHANNEL=%q\n' "${OPENCLAW_RELEASE_CHANNEL:-latest}"
        printf 'RESUME_EXPOSE_OPENCLAW=%q\n'          "${EXPOSE_OPENCLAW:-n}"
        printf 'RESUME_OPENCLAW_PORT=%q\n'            "${OPENCLAW_PORT:-18789}"
        printf 'RESUME_LOCAL_MIRROR_BASE=%q\n'        "${LOCAL_MIRROR_BASE:-}"
    } > "$tmp"

    sudo install -m 600 "$tmp" "$RESUME_STATE_FILE"
    rm -f "$tmp"
    print_info "Resume state saved to $RESUME_STATE_FILE"
}

# Remove resume state file.
clear_resume_state() {
    if [[ -f "$RESUME_STATE_FILE" ]]; then
        sudo rm -f "$RESUME_STATE_FILE"
        print_info "Resume state cleared."
    fi
}

# --- Script Entry Point ---
main
