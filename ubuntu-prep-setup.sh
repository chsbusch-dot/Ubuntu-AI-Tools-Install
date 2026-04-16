#!/bin/bash
#
# Ubuntu Preparation Script
#
# This script automates the setup of a new Ubuntu system, including
# system updates, developer tools, and specific software stacks.
#
# Reference: https://discourse.ubuntu.com/t/my-powerful-zsh-profile/47395
#
# 4/6/2026 Release 1.0 - Initial version with core functionality.

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
    # Remove temporary sudoers file if present
    if [[ -n "${TARGET_USER:-}" && -f "/etc/sudoers.d/99-temp-$TARGET_USER" ]]; then
        sudo rm -f "/etc/sudoers.d/99-temp-$TARGET_USER"
        echo "Revoked temporary sudo privileges for $TARGET_USER."
    fi
}

# Global error handler
cleanup_on_error() {
    local exit_code=$?
    local line_no=$1
    echo -e "\n\e[1;31m❌ ERROR: Script failed unexpectedly at line $line_no (Exit code: $exit_code)\e[0m"
    echo -e "\e[1;33mPerforming emergency cleanup...\e[0m"
    global_cleanup
    echo -e "Please check the error message above to troubleshoot."
}
trap 'cleanup_on_error ${LINENO}' ERR
trap 'global_cleanup' EXIT

start_sudo_keepalive() {
    # Refresh sudo credentials every 50 seconds to prevent timeout during
    # long installs (CUDA compilation, model downloads, etc.)
    (while true; do
        sudo -v
        sleep 50
    done) &
    SUDO_KEEPALIVE_PID=$!
}

# Global array to track post-installation actions
POST_INSTALL_ACTIONS=()

# ── Resume-after-reboot state ─────────────────────────────────────────────────
RESUME_MODE=false
RESUME_STATE_FILE="/var/lib/ubuntu-prep/resume.env"
# These three are global so save_resume_state() can access them from main()
MASTER_SELECTIONS=()
MASTER_INSTALLED_STATE=()
ACTIVE_INDICES=(0)

# Global vars for target user
TARGET_USER=""
TARGET_USER_HOME=""
IS_DIFFERENT_USER=false
HAS_NVIDIA_GPU=false
GPU_STATUS=""
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
AUTO_UPDATE_OPENWEBUI="n"
REPAIRED_COMPONENTS=()
INSTALLED_COMPONENTS=()
FAILED_COMPONENTS=()
# shellcheck disable=SC2034 # Reserved for future use
EXPOSE_LLAMA_SERVER="n"
RUN_LLAMA_BENCH="n"
LOAD_DEFAULT_MODEL="n"
LLM_DEFAULT_MODEL_CHOICE=""
SELECTED_MODEL_REPO=""
ENABLE_UFW_AUTOMATICALLY="n"
LLAMA_CTX_SIZE=""
LLAMA_CACHE_TYPE_K=""
LLAMA_CACHE_TYPE_V=""
LLAMA_CPU_MOE="y"
LLAMA_FLASH_ATTN="n"
LLAMA_UBATCH=""
LLAMA_VRAM_TIER=""
LLAMA_NGL=""     # GPU layers (0–99); empty = 99 for CUDA, 0 for CPU
LLAMA_FIT="n"    # --fit on: auto-calculate ngl to fill VRAM
LLAMA_FIT_CTX="" # --fit-ctx N: minimum ctx --fit will not shrink below

# ─── Headless Mode ────────────────────────────────────────────────
# Run non-interactively with sensible defaults. Every HEADLESS_* var
# can be set as an environment variable before invocation.
#
# Usage:
#   bash ubuntu-prep-setup.sh --headless
#   HEADLESS_GOALS=llm HEADLESS_VRAM=24 bash ubuntu-prep-setup.sh --headless
HEADLESS_MODE=false
for arg in "$@"; do
    case "$arg" in
        --headless) HEADLESS_MODE=true ;;
        --resume) RESUME_MODE=true ;;
    esac
done

HEADLESS_USER="${HEADLESS_USER:-}" # empty = current user
HEADLESS_TIMEZONE="${HEADLESS_TIMEZONE:-America/Los_Angeles}"
HEADLESS_GOALS="${HEADLESS_GOALS:-openclaw,llm}"           # subset of: openclaw,vgpu,llm
HEADLESS_LLM_BACKEND="${HEADLESS_LLM_BACKEND:-ollama}"     # ollama | llama_cpu | llama_cuda
HEADLESS_VRAM="${HEADLESS_VRAM:-16}"                       # 8|16|24|32|48|72|96
HEADLESS_MODEL_CATEGORY="${HEADLESS_MODEL_CATEGORY:-chat}" # chat|code|moe|vision
HEADLESS_INSTALL_OPENWEBUI="${HEADLESS_INSTALL_OPENWEBUI:-y}"
HEADLESS_INSTALL_LIBRECHAT="${HEADLESS_INSTALL_LIBRECHAT:-n}"
HEADLESS_EXPOSE_LLM="${HEADLESS_EXPOSE_LLM:-n}"
HEADLESS_EXPOSE_OPENCLAW="${HEADLESS_EXPOSE_OPENCLAW:-n}"
HEADLESS_LOAD_DEFAULT_MODEL="${HEADLESS_LOAD_DEFAULT_MODEL:-y}"
HEADLESS_INSTALL_LLAMA_SERVICE="${HEADLESS_INSTALL_LLAMA_SERVICE:-n}"
HEADLESS_ENABLE_UFW="${HEADLESS_ENABLE_UFW:-n}"
HEADLESS_INSTALL_VGPU="${HEADLESS_INSTALL_VGPU:-n}"
HEADLESS_REBOOT="${HEADLESS_REBOOT:-n}"
HEADLESS_SECURITY_OPTS="${HEADLESS_SECURITY_OPTS:-c}" # "a"=all, "c"=confirm none, or "1,2,5"
HEADLESS_CTX_SIZE="${HEADLESS_CTX_SIZE:-}"            # empty = auto from VRAM tier
HEADLESS_CACHE_TYPE_K="${HEADLESS_CACHE_TYPE_K:-}"    # empty = auto; f16|q8_0|q4_0|bf16|turbo3|turbo4|...
HEADLESS_CPU_MOE="${HEADLESS_CPU_MOE:-y}"             # y|n — offload MoE expert layers to CPU (default: on)
HEADLESS_UBATCH="${HEADLESS_UBATCH:-}"                # empty = auto from VRAM tier; e.g. 1024

# ask — drop-in replacement for `read -p`.
# Interactive: reads from user; if input is empty, applies $default.
# Headless:    echoes the default and assigns without prompting.
# Usage: ask "Prompt text: " VARNAME "default"
ask() {
    local prompt="$1"
    local var="$2"
    local default="$3"

    if [ "$HEADLESS_MODE" = true ]; then
        echo -e "  \e[2m[headless] ${prompt}${default}\e[0m"
        printf -v "$var" '%s' "$default"
    else
        read -rp "$prompt" "${var?}"
        if [ -z "${!var}" ]; then
            printf -v "$var" '%s' "$default"
        fi
    fi
}

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
    ENABLE_UFW_AUTOMATICALLY="n"
    LLAMA_CTX_SIZE=""
    LLAMA_CACHE_TYPE_K=""
    LLAMA_CACHE_TYPE_V=""
    LLAMA_CPU_MOE="y"
    LLAMA_FLASH_ATTN="n"
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

need_local_llm_work() {
    [[ "$LLAMA_COMPONENT_ACTION" != "skip" || "$OLLAMA_COMPONENT_ACTION" != "skip" || "$OPENWEBUI_COMPONENT_ACTION" != "skip" || "$LIBRECHAT_COMPONENT_ACTION" != "skip" ]]
}

need_frontend_backend_target() {
    [[ "$OPENWEBUI_COMPONENT_ACTION" != "skip" || "$LIBRECHAT_COMPONENT_ACTION" != "skip" || "$OPENCLAW_COMPONENT_ACTION" != "skip" ]]
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
        echo -e "\e[1;36mSelect which backend the frontends should target for this run:\e[0m"
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
                echo -e "❌ \e[1;31mInvalid choice.\e[0m Please enter 1 or 2."
                ;;
        esac
    done
}

# --- Model Recommendations Configuration ---
# Edit this function to quickly update the default models offered in the menu.
get_model_recommendations() {
    local backend="$1"
    local vram="$2"

    REC_MODEL_CHAT=""
    REC_MODEL_CODE=""
    REC_MODEL_MOE=""
    REC_MODEL_VISION=""
    # Edit this function to quickly update the default models offered for Ollama

    if [[ "$backend" == "ollama" ]]; then
        case "$vram" in
            8)
                REC_MODEL_CHAT="gemma4:e4b"
                REC_MODEL_CODE="qwen2.5-coder:7b"
                REC_MODEL_MOE="gemma4:e4b"
                REC_MODEL_VISION="gemma4:e4b"
                ;;
            16)
                REC_MODEL_CHAT="qwen2.5:14b"
                REC_MODEL_CODE="qwen2.5-coder:14b"
                REC_MODEL_MOE="gemma4:e4b"
                REC_MODEL_VISION="minicpm-v"
                ;;
            24)
                REC_MODEL_CHAT="gemma4:26b"
                REC_MODEL_CODE="qwen2.5-coder:32b"
                REC_MODEL_MOE="gemma4:26b"
                REC_MODEL_VISION="llava:34b"
                ;;
            32)
                REC_MODEL_CHAT="qwen2.5:32b"
                REC_MODEL_CODE="qwen2.5-coder:32b"
                REC_MODEL_MOE="mixtral:8x7b"
                REC_MODEL_VISION="qwen2.5vl:32b"
                ;;
            48)
                REC_MODEL_CHAT="llama3.3:70b"
                REC_MODEL_CODE="qwen2.5-coder:32b"
                REC_MODEL_MOE="mixtral:8x7b"
                REC_MODEL_VISION="qwen2.5vl:32b"
                ;;
            72)
                REC_MODEL_CHAT="qwen2.5:72b"
                REC_MODEL_CODE="qwen2.5-coder:32b"
                REC_MODEL_MOE="command-r-plus:104b"
                REC_MODEL_VISION="qwen2.5vl:72b"
                ;;
            96)
                REC_MODEL_CHAT="qwen2.5:72b"
                REC_MODEL_CODE="qwen2.5-coder:32b"
                REC_MODEL_MOE="mixtral:8x22b"
                REC_MODEL_VISION="qwen2.5vl:72b"
                ;;
        esac
    else

        # Edit this function to quickly update the default models offered for LLama.CPP
        case "$vram" in
            8)
                REC_MODEL_CHAT="unsloth/gemma-4-E4B-it-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-7B-Instruct-GGUF"
                REC_MODEL_MOE="unsloth/gemma-4-E4B-it-GGUF"
                REC_MODEL_VISION="unsloth/gemma-4-E4B-it-GGUF"
                ;;
            16)
                REC_MODEL_CHAT="bartowski/Qwen2.5-14B-Instruct-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-14B-Instruct-GGUF"
                REC_MODEL_MOE="unsloth/gemma-4-E4B-it-GGUF"
                REC_MODEL_VISION="cjpais/llava-v1.6-vicuna-13b-gguf"
                ;;
            24)
                REC_MODEL_CHAT="unsloth/gemma-4-26B-A4B-it-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="unsloth/gemma-4-26B-A4B-it-GGUF"
                REC_MODEL_VISION="cjpais/llava-v1.6-34B-gguf"
                ;;
            32)
                REC_MODEL_CHAT="bartowski/Qwen2.5-32B-Instruct-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF"
                REC_MODEL_VISION="unsloth/Qwen2.5-VL-32B-Instruct-GGUF"
                ;;
            48)
                REC_MODEL_CHAT="bartowski/Llama-3.3-70B-Instruct-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF"
                REC_MODEL_VISION="unsloth/Qwen2.5-VL-32B-Instruct-GGUF"
                ;;
            72)
                REC_MODEL_CHAT="bartowski/Qwen2.5-72B-Instruct-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="bartowski/c4ai-command-r-plus-08-2024-GGUF"
                REC_MODEL_VISION="unsloth/Qwen2.5-VL-72B-Instruct-GGUF"
                ;;
            96)
                REC_MODEL_CHAT="bartowski/Qwen2.5-72B-Instruct-GGUF"
                REC_MODEL_CODE="bartowski/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="MaziyarPanahi/Mixtral-8x22B-v0.1-GGUF"
                REC_MODEL_VISION="unsloth/Qwen2.5-VL-72B-Instruct-GGUF"
                ;;
        esac
    fi
}

# --- Helper Functions ---

# Function to print colored headings
print_header() {
    echo -e "\n\e[1;34m===== $1 =====\e[0m"
}

# Function to print success messages
print_success() {
    echo -e "\e[1;32m✅ $1\e[0m"
}

# Function to print info messages
print_info() {
    echo -e "\e[1;36mℹ️ $1\e[0m"
}

# Function to print the persistent status header
print_status_header() {
    echo -e "\n\e[1;35m--- Ubuntu Prep Script Menu ---\e[0m"
    echo -e "Hardware: $GPU_STATUS"
    local ram_disp="unknown"
    local vram_disp="unknown"
    [[ "${SYSTEM_RAM_GB:-0}" -gt 0 ]] && ram_disp="${SYSTEM_RAM_GB} GB"
    [[ "${GPU_VRAM_GB:-0}" -gt 0 ]] && vram_disp="${GPU_VRAM_GB} GB"
    echo -e "RAM: \e[1;36m${ram_disp}\e[0m | VRAM: \e[1;36m${vram_disp}\e[0m"
    echo -e "Target User: \e[1;36m$TARGET_USER\e[0m ($TARGET_USER_HOME)"
    # Show llama.cpp model + key parameters if the service is currently active
    if systemctl is-active --quiet llama-server 2>/dev/null; then
        local exec_line llama_args model_path model_name ctx_val ctk_val ngl_val params
        exec_line=$(sudo grep -m1 '^ExecStart=' /etc/systemd/system/llama-server.service 2>/dev/null || true)
        llama_args=$(echo "$exec_line" | grep -oE 'llama-server.*' | head -1 || true)
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
        echo -e "llama.cpp: \e[1;32m●\e[0m running${params}"
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

# Function to check if the OS is Ubuntu
check_os() {
    print_info "Verifying operating system..."
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        if [[ "$ID" == "ubuntu" ]]; then
            print_success "OS check passed: Running on Ubuntu."
        else
            echo "❌ This script is intended for Ubuntu only. Detected OS: $ID."
            exit 1
        fi
    else
        echo "❌ Cannot determine the operating system. /etc/os-release not found."
        exit 1
    fi
}

# Function to install base dependencies for the script to run properly
install_base_dependencies() {
    print_header "Ensuring Base Dependencies are Installed"
    # Quietly update package lists to ensure install doesn't fail on a fresh system
    sudo apt-get update -qq
    # These are required by various installation functions
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y jq build-essential procps curl file git wget unzip lsb-release gnupg ca-certificates

    print_info "Configuring Landscape sysinfo display..."
    sudo mkdir -p /etc/landscape
    if ! sudo grep -q "^\[sysinfo\]" /etc/landscape/client.conf 2>/dev/null; then
        echo -e "\n[sysinfo]\nshow_memory = True\nshow_cpu_cores = True" | sudo tee -a /etc/landscape/client.conf >/dev/null
    else
        if ! sudo grep -q "^show_memory" /etc/landscape/client.conf 2>/dev/null; then
            sudo sed -i '/^\[sysinfo\]/a show_memory = True' /etc/landscape/client.conf
        fi
        if ! sudo grep -q "^show_cpu_cores" /etc/landscape/client.conf 2>/dev/null; then
            sudo sed -i '/^\[sysinfo\]/a show_cpu_cores = True' /etc/landscape/client.conf
        fi
    fi

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

# Function to determine the target user for the installation
determine_target_user() {
    echo -e "\n\e[1;36mSelect Target User for Installation:\e[0m"
    echo "This script runs system-wide installations (like Docker, Python, CUDA) using 'sudo'."
    echo "User-specific tools (like NVM, Oh My Zsh, OpenClaw) will be installed for the user you select below."
    echo "  1. Current user ($USER)"
    echo "  2. A different/new user (e.g., a dedicated 'openclaw' user)"
    local choice
    while true; do
        read -p "Your choice [1/2]: " choice
        case "$choice" in
            1) break ;;
            2) break ;;
            *) echo -e "❌ \e[1;31mInvalid choice '$choice'.\e[0m Please enter 1 or 2." ;;
        esac
    done
    if [[ "$choice" == "2" ]]; then
        IS_DIFFERENT_USER=true
        local username
        while true; do
            read -p "Enter the target username [openclaw]: " username
            TARGET_USER=${username:-openclaw}

            if [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                break
            else
                echo -e "❌ \e[1;31mInvalid username format.\e[0m Usernames must start with a lowercase letter or underscore, and only contain lowercase letters, numbers, dashes, or underscores."
            fi
        done

        if id "$TARGET_USER" &>/dev/null; then
            print_info "Target user '$TARGET_USER' already exists."
        else
            print_info "Creating user '$TARGET_USER'..."
            sudo adduser --gecos "" "$TARGET_USER"
            print_success "Standard user '$TARGET_USER' created successfully."
        fi
        # Get home directory path correctly, even for non-standard home dirs
        TARGET_USER_HOME=$(eval echo "~$TARGET_USER")
    else
        TARGET_USER=$USER
        TARGET_USER_HOME=$HOME
    fi
    print_info "All user-specific files will be installed for user '$TARGET_USER' in '$TARGET_USER_HOME'."
}

# Function to detect NVIDIA GPU presence
detect_gpu() {
    if command -v lspci &>/dev/null; then
        if lspci | grep -iq 'nvidia'; then
            GPU_STATUS="\e[1;32mNVIDIA GPU/vGPU Detected\e[0m"
            HAS_NVIDIA_GPU=true
        else
            GPU_STATUS="\e[1;33mNo NVIDIA GPU/vGPU Detected\e[0m"
            HAS_NVIDIA_GPU=false
        fi
    else
        GPU_STATUS="\e[1;33mNVIDIA GPU status unknown (pciutils missing)\e[0m"
        HAS_NVIDIA_GPU=false
    fi

    # System RAM (total, in GB, rounded)
    if [[ -f /proc/meminfo ]]; then
        SYSTEM_RAM_GB=$(awk '/^MemTotal:/ { printf "%d", $2/1024/1024 + 0.5 }' /proc/meminfo)
    else
        SYSTEM_RAM_GB=0
    fi

    # VRAM: try nvidia-smi first, fall back to 0 if unavailable
    if command -v nvidia-smi &>/dev/null && nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits &>/dev/null; then
        GPU_VRAM_GB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null |
            awk 'NR==1 { printf "%d", $1/1024 + 0.5 }')
    else
        GPU_VRAM_GB=0
    fi
}

# Function to configure system timezone
configure_timezone() {
    print_header "System Timezone Configuration"
    local env_file="$TARGET_USER_HOME/.env.secrets"
    local tz="America/Los_Angeles"

    # Check if already defined in .env.secrets
    if sudo test -f "$env_file"; then
        local env_tz
        env_tz=$(sudo bash -c "source \"$env_file\" 2>/dev/null && echo \"\$SYSTEM_TIMEZONE\"" | tr -d '\r')
        if [[ -n "$env_tz" ]]; then
            tz="$env_tz"
        fi
    fi

    local user_tz candidate_tz
    while true; do
        read -p "Enter timezone (Continent/City) or press Enter to keep default [$tz]: " user_tz
        candidate_tz="${user_tz:-$tz}"

        print_info "Setting timezone to '$candidate_tz' and enabling NTP..."
        if sudo timedatectl set-timezone "$candidate_tz" 2>/dev/null; then
            tz="$candidate_tz"
            sudo timedatectl set-ntp true 2>/dev/null || true # best-effort: NTP sync is non-critical
            print_success "Timezone set to $tz and NTP synced."
            export GLOBAL_SYSTEM_TIMEZONE="$tz"

            # If the secrets file already exists, update or append it
            if sudo test -f "$env_file"; then
                if sudo grep -q "SYSTEM_TIMEZONE" "$env_file"; then
                    sudo -u "$TARGET_USER" sed -i "s|^.*export SYSTEM_TIMEZONE=.*|export SYSTEM_TIMEZONE=\"$tz\"|" "$env_file"
                else
                    echo "export SYSTEM_TIMEZONE=\"$tz\"" | sudo -u "$TARGET_USER" tee -a "$env_file" >/dev/null
                fi
            fi
            break
        else
            echo -e "❌ \e[1;31mInvalid timezone '$candidate_tz'.\e[0m Use a valid IANA format like 'America/Los_Angeles' or 'Europe/Berlin'."
            echo -e "   (Run 'timedatectl list-timezones' in another terminal to see valid values.)"
        fi
    done
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
export LLAMA_CACHE="$HOME/llama.cpp/models/models-user"

# Export timezone
export TZ="${GLOBAL_SYSTEM_TIMEZONE:-America/Los_Angeles}"

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
        echo -e '\n# Source secrets file if it exists\nif [[ -f ~/.env.secrets ]]; then\n  source ~/.env.secrets\nfi' | sudo tee -a "$TARGET_USER_HOME/.bashrc" >/dev/null
    fi

    # Interactive prompt for API keys
    print_info "API keys configuration file is ready at $TARGET_USER_HOME/.env.secrets"
    read -p "Do you want to edit your API keys for '$TARGET_USER' now? [y/N]: " add_keys_now
    if [[ "$add_keys_now" == "y" || "$add_keys_now" == "Y" ]]; then
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
                                echo -e "⚠️  \e[1;33m${format_hint}\e[0m"
                                local accept_anyway
                                read -p "Use this value anyway? [y/N/r=re-enter]: " accept_anyway
                                case "$accept_anyway" in
                                    y | Y) ;;          # accept as-is, fall through to save
                                    r | R) continue ;; # re-prompt
                                    *) continue ;;     # default re-prompt
                                esac
                            fi

                            # Use awk for replacement — immune to all sed metacharacters
                            # (backslashes, pipes, ampersands, slashes in the value)
                            local secrets_file="$TARGET_USER_HOME/.env.secrets"
                            local tmp_secrets
                            tmp_secrets=$(sudo mktemp)
                            sudo awk -v key="$key_name" -v val="$key_value" '
                                $0 ~ "^# export " key "=" { print "export " key "=\"" val "\""; next }
                                { print }
                            ' "$secrets_file" | sudo tee "$tmp_secrets" >/dev/null
                            sudo mv "$tmp_secrets" "$secrets_file"
                            sudo chown "$TARGET_USER":"$TARGET_USER" "$secrets_file"
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
    sudo chown "$TARGET_USER":"$TARGET_USER" "$TARGET_USER_HOME/.env.secrets"
    sudo chmod 600 "$TARGET_USER_HOME/.env.secrets"
}

# 1. Install Oh My Zsh & Dev Tools (git, tmux, micro)
install_zsh() {
    print_header "Installing Zsh, Oh My Zsh, and Plugins"
    print_info "Installing packages: zsh, tmux, micro"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y zsh tmux micro

    if ! sudo test -d "$TARGET_USER_HOME/.oh-my-zsh"; then
        print_info "Installing Oh My Zsh..."
        # We must cd to the target user's home directory first. Otherwise, the installer starts in the current user's
        # home directory and throws a permission error when it tries to cd back to its starting path at the end.
        sudo -u "$TARGET_USER" -H bash -c "cd \"$TARGET_USER_HOME\" && sh -c \"\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\" \"\" --unattended"
    else
        print_info "Oh My Zsh is already installed."
    fi

    print_info "Setting Zsh as the default shell for the current user..."
    sudo chsh -s "$(command -v zsh)" "$TARGET_USER"

    # Define Zsh custom plugins directory
    local ZSH_CUSTOM="${TARGET_USER_HOME}/.oh-my-zsh/custom"

    print_info "Cloning Zsh plugins..."
    # zsh-autosuggestions
    if ! sudo test -d "${ZSH_CUSTOM}/plugins/zsh-autosuggestions"; then
        sudo -u "$TARGET_USER" -H git clone https://github.com/zsh-users/zsh-autosuggestions "${ZSH_CUSTOM}/plugins/zsh-autosuggestions"
    fi
    # zsh-syntax-highlighting
    if ! sudo test -d "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting"; then
        sudo -u "$TARGET_USER" -H git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting"
    fi
    # zsh-history-substring-search
    if ! sudo test -d "${ZSH_CUSTOM}/plugins/zsh-history-substring-search"; then
        sudo -u "$TARGET_USER" -H git clone https://github.com/zsh-users/zsh-history-substring-search "${ZSH_CUSTOM}/plugins/zsh-history-substring-search"
    fi

    print_info "Configuring .zshrc..."
    # Replace the default plugins line with the new one
    sudo sed -i 's/^plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search)/' "$TARGET_USER_HOME/.zshrc"

    # Add sourcing of .env.secrets to .zshrc
    if ! sudo grep -q ".env.secrets" "$TARGET_USER_HOME/.zshrc"; then
        echo -e '\n# Source secrets file if it exists\nif [[ -f ~/.env.secrets ]]; then\n  source ~/.env.secrets\nfi' | sudo tee -a "$TARGET_USER_HOME/.zshrc" >/dev/null
    fi

    print_info "Enabling true color support for modern terminals..."
    echo -e '\n# Set COLORTERM to advertise true color support to modern CLI tools\nexport COLORTERM=truecolor' | sudo tee -a "$TARGET_USER_HOME/.zshrc" >/dev/null

    print_info "Adding custom Zsh prompt..."
    # Add custom prompt to override the theme default. Using a heredoc for clarity.
    cat <<'EOP' | sudo tee -a "${TARGET_USER_HOME}/.zshrc" >/dev/null

# Custom prompt showing user@host > path >
PROMPT="%{$fg_bold[yellow]%}%n@%m%{$reset_color%} > %{$fg[cyan]%}%/%{$reset_color%} > "
EOP

    print_info "Configuring systemd to auto-update Oh My Zsh and plugins on boot..."
    # Disable the native OMZ auto-update prompt so it doesn't interrupt terminal launches
    sudo sed -i 's/^# DISABLE_AUTO_UPDATE="true"/DISABLE_AUTO_UPDATE="true"/' "$TARGET_USER_HOME/.zshrc"

    sudo bash -c "cat <<EOF > /usr/local/bin/update-omz.sh
#!/bin/bash
export ZSH=\"$TARGET_USER_HOME/.oh-my-zsh\"

# Update Oh My Zsh core
sh \"\$ZSH/tools/upgrade.sh\" >/dev/null 2>&1 || true

# Update custom plugins
for plugin in \"\$ZSH/custom/plugins/\"*/; do
    if [ -d \"\${plugin}.git\" ]; then
        git -C \"\$plugin\" pull --quiet || true
    fi
done
EOF"
    sudo chmod +x /usr/local/bin/update-omz.sh

    sudo bash -c "cat <<EOF > /etc/systemd/system/omz-update.service
[Unit]
Description=Auto-update Oh My Zsh and Custom Plugins
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$TARGET_USER
ExecStart=/usr/local/bin/update-omz.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF"
    sudo systemctl daemon-reload
    sudo systemctl enable omz-update.service

    print_success "Zsh and plugins installed."
    POST_INSTALL_ACTIONS+=("zsh")
}

# 0. Update System Packages (apt update && upgrade)
update_system() {
    print_header "Updating System Packages"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    print_success "System updated and upgraded."
    sleep 2 # Pause briefly so the user can see that it executed
}

# 2. Install Python Environment
install_python() {
    print_header "Installing Python and Virtual Environment Tools"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python-is-python3 python3-pip python3-dev python3-venv libssl-dev libffi-dev python3-setuptools
    print_success "Python environment installed."
}

# 3. Install Docker and Docker Compose
install_docker() {
    print_header "Installing Docker"
    print_info "Removing any old Docker installations..."
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do sudo apt-get remove -y $pkg; done

    print_info "Setting up Docker's official GPG key and repository..."
    sudo apt-get update
    sudo install -m 0755 -d /etc/apt/keyrings # ca-certificates and curl are installed as base dependencies
    curl_with_retry -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
        sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update

    print_info "Installing Docker packages..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    print_info "Adding current user to the 'docker' group..."
    sudo usermod -aG docker "$TARGET_USER"

    if id -nG "$TARGET_USER" | grep -qw "docker"; then
        print_success "User '$TARGET_USER' successfully added to the 'docker' group."
    else
        echo -e "⚠️ \e[1;33mFailed to add '$TARGET_USER' to the 'docker' group. You may need to add it manually.\e[0m"
    fi

    print_success "Docker installed successfully."
    POST_INSTALL_ACTIONS+=("docker")
}

# 4. Install NVM, Node.js & NPM
install_nvm_node() {
    print_header "Installing NVM, Node.js (LTS), and NPM"
    print_info "Running the NVM installation script silently..."
    # This runs the installer as the target user, which updates their .bashrc/.zshrc.
    # Use -s for curl to silence progress bar, and redirect bash output to /dev/null.
    local latest_nvm
    latest_nvm=$(curl -sL https://api.github.com/repos/nvm-sh/nvm/releases/latest | jq -r .tag_name 2>/dev/null || echo "v0.39.7")
    sudo -u "$TARGET_USER" bash -c "cd \"$TARGET_USER_HOME\" && curl -s -o- https://raw.githubusercontent.com/nvm-sh/nvm/${latest_nvm}/install.sh | bash > /dev/null 2>&1"

    print_info "Installing the latest LTS version of Node.js..."
    # Explicitly set NVM_DIR using the exact target path and source nvm.sh within the subshell.
    # We use double quotes to inject TARGET_USER_HOME directly, avoiding any $HOME resolution issues with sudo.
    local nvm_cmd="export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\""
    sudo -u "$TARGET_USER" bash -c "cd \"$TARGET_USER_HOME\" && $nvm_cmd; nvm install --lts; nvm install-latest-npm"

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
        echo -e "\n# NVM Configuration\n${nvm_config_str}" | sudo tee -a "$TARGET_USER_HOME/.zshrc" >/dev/null
    fi
    if sudo test -f "$TARGET_USER_HOME/.bashrc" && ! sudo grep -q 'NVM_DIR' "$TARGET_USER_HOME/.bashrc"; then
        print_info "Adding NVM configuration to ~/.bashrc"
        echo -e "\n# NVM Configuration\n${nvm_config_str}" | sudo tee -a "$TARGET_USER_HOME/.bashrc" >/dev/null
    fi

    local node_version
    node_version=$(sudo -u "$TARGET_USER" bash -c "$nvm_cmd; node -v")
    local npm_version
    npm_version=$(sudo -u "$TARGET_USER" bash -c "$nvm_cmd; npm -v")

    print_success "NVM, Node.js, and NPM installed."
    print_info "Node version: $node_version, NPM version: $npm_version"

    # Also install system-wide Node 22 LTS so OpenClaw's gateway service
    # uses a stable binary instead of NVM (prevents breakage after nvm upgrades).
    print_info "Installing system Node.js 22 LTS (recommended by openclaw doctor)..."
    if curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null 2>&1 &&
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs >/dev/null 2>&1; then
        print_success "System Node.js installed: $(node --version 2>/dev/null || echo 'see /usr/bin/node')"
    else
        print_info "System Node.js install skipped (NodeSource unavailable — NVM-only is fine)."
    fi

    POST_INSTALL_ACTIONS+=("nvm")
}

# 5. Install Homebrew
install_homebrew() {
    print_header "Installing Homebrew"

    print_info "Preparing Homebrew directory permissions for standard user..."
    sudo mkdir -p /home/linuxbrew/.linuxbrew
    sudo chown -R "$TARGET_USER":"$TARGET_USER" /home/linuxbrew

    print_info "Running Homebrew installation script..."
    sudo -u "$TARGET_USER" bash -c "NONINTERACTIVE=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

    local brew_env_str
    brew_env_str=$(
        cat <<'EOF'
# Homebrew Configuration
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
EOF
    )
    if sudo test -f "$TARGET_USER_HOME/.zshrc" && ! sudo grep -q 'linuxbrew' "$TARGET_USER_HOME/.zshrc"; then
        echo -e "\n${brew_env_str}" | sudo tee -a "$TARGET_USER_HOME/.zshrc" >/dev/null
    fi
    if sudo test -f "$TARGET_USER_HOME/.bashrc" && ! sudo grep -q 'linuxbrew' "$TARGET_USER_HOME/.bashrc"; then
        echo -e "\n${brew_env_str}" | sudo tee -a "$TARGET_USER_HOME/.bashrc" >/dev/null
    fi
    print_success "Homebrew installed."
    POST_INSTALL_ACTIONS+=("brew")
}

# 6. Install Google Gemini CLI
install_gemini_cli() {
    print_header "Installing Google Gemini CLI"
    local nvm_cmd="export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\""

    print_info "Installing Gemini CLI via NPM..."
    sudo -u "$TARGET_USER" bash -c "$nvm_cmd; npm install -g @google/gemini-cli"

    print_info "Making Gemini CLI globally available to all users..."
    sudo bash -c "cat <<EOF > /usr/local/bin/gemini
#!/bin/bash
export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"
[ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\"
exec gemini \"\$@\"
NODE_BIN=\$(dirname \$(command -v node 2>/dev/null) 2>/dev/null)
if [ -x \"\$NODE_BIN/gemini\" ]; then
    exec \"\$NODE_BIN/gemini\" \"\$@\"
else
    # Fallback to npx to guarantee execution if path resolution fails
    exec npx -y @google/gemini-cli \"\$@\"
fi
EOF"
    sudo chmod +x /usr/local/bin/gemini

    print_success "Google Gemini CLI installed globally."
}

# 7. Install NVIDIA GPU Driver (consumer RTX or vGPU/custom .deb)
install_nvidia_driver() {
    print_header "Installing NVIDIA GPU Driver"

    echo ""
    echo -e "\e[1;36mWhat type of NVIDIA driver do you need?\e[0m"
    echo "  1) Consumer GPU  (GeForce RTX / GTX) — install from Ubuntu driver repository"
    echo "  2) vGPU / special drivers            — install from a custom .deb file via URL"
    echo ""
    local _gpu_drv_type
    read -rp "Your choice [1/2]: " _gpu_drv_type

    if [[ "$_gpu_drv_type" == "1" ]]; then
        # ── Consumer GPU: .run installer (works for native and PCIe passthrough) ──
        #
        # Why not ubuntu-drivers?  ubuntu-drivers works fine for bare-metal but
        # produces "udevadm hwdb is deprecated" spam and can fail on ESXi
        # passthrough VMs where the hypervisor CPUID is visible.  The .run
        # installer is more reliable across both cases.

        # Detect if running inside a hypervisor (ESXi passthrough likely)
        local _is_vm=false
        if systemd-detect-virt --quiet 2>/dev/null; then
            _is_vm=true
        fi

        # Driver URL — use NVIDIA_RTX_DRIVER_URL from .env.secrets if set,
        # otherwise fall back to the hardcoded production version.
        # To update: get the full .run URL from https://www.nvidia.com/en-us/drivers/unix/
        # and set it in .env.secrets:
        #   export NVIDIA_RTX_DRIVER_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/595.58.03/NVIDIA-Linux-x86_64-595.58.03.run"
        local _drv_url="${NVIDIA_RTX_DRIVER_URL:-https://us.download.nvidia.com/XFree86/Linux-x86_64/595.58.03/NVIDIA-Linux-x86_64-595.58.03.run}"
        local _drv_ver
        _drv_ver=$(basename "$_drv_url" .run | grep -oP '[\d.]+$')
        local _drv_file
        _drv_file="/tmp/$(basename "$_drv_url")"

        if [[ -n "${NVIDIA_RTX_DRIVER_URL:-}" ]]; then
            print_info "Using driver URL from .env.secrets: $_drv_url"
        else
            print_info "Using hardcoded driver version $_drv_ver (set NVIDIA_RTX_DRIVER_URL in .env.secrets to override)"
        fi

        print_info "Installing prerequisites..."
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
            build-essential "linux-headers-$(uname -r)" \
            pkg-config libvulkan1 dkms wget

        # Blacklist Nouveau — required for passthrough VMs, harmless on bare-metal
        if lsmod | grep -q "nouveau" 2>/dev/null; then
            print_info "Blacklisting Nouveau driver..."
            sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null <<'NOUVEOF'
blacklist nouveau
options nouveau modeset=0
NOUVEOF
            sudo update-initramfs -u
            print_info "Nouveau blacklisted — a reboot will be required before the driver binds."
        else
            print_info "Nouveau is not loaded — skipping blacklist step."
        fi

        # Download the .run installer
        if [[ ! -f "$_drv_file" ]]; then
            print_info "Downloading NVIDIA driver ${_drv_ver}..."
            wget -q --show-progress -O "$_drv_file" "$_drv_url"
            chmod +x "$_drv_file"
        else
            print_info "Installer already present: $_drv_file"
        fi

        # Run unattended install
        print_info "Running NVIDIA installer (silent)..."
        sudo "$_drv_file" \
            --silent \
            --accept-license \
            --no-questions \
            --no-x-check \
            --no-wine-files \
            --dkms

        print_success "NVIDIA driver ${_drv_ver} installed."

        # ── ESXi PCIe passthrough reminder ───────────────────────────────────
        if [[ "$_is_vm" == true ]]; then
            echo ""
            echo -e "\e[1;43m\e[30m ⚠️  ESXi / Hypervisor detected — PCIe passthrough VM settings required \e[0m"
            echo -e "\e[1;33m"
            echo "  Add these to your VM's Advanced Parameters in vSphere before rebooting:"
            echo ""
            echo "    pciPassthru.use64bitMMIO    = \"TRUE\""
            echo "    pciPassthru.64bitMMIOSizeGB = \"64\"   (must exceed total VRAM — e.g. 64 for a 24 GB A5000)"
            echo "    hypervisor.cpuid.v0         = \"FALSE\""
            echo ""
            echo "  Without these settings nvidia-smi will fail with 'No devices found'."
            echo -e "\e[0m"
        fi

        POST_INSTALL_ACTIONS+=("reboot")
        return 0
    fi

    if [[ "$_gpu_drv_type" != "2" ]]; then
        echo "❌ Invalid choice. Skipping NVIDIA driver installation."
        return 1
    fi

    # --- vGPU / custom driver path ---
    print_header "Installing NVIDIA vGPU / Custom Driver and Token"

    local vgpu_driver_url=""
    local vgpu_token_url=""
    local download_auth=""
    local env_driver_url=""
    local env_token_url=""

    # Read secrets file if it exists to retrieve URL and Auth, using sudo to bypass strict home directory permissions
    if sudo test -f "$TARGET_USER_HOME/.env.secrets"; then
        env_driver_url=$(sudo bash -c "source \"$TARGET_USER_HOME/.env.secrets\" 2>/dev/null && echo \"\$NVIDIA_VGPU_DRIVER_URL\"" | tr -d '\r')
        env_token_url=$(sudo bash -c "source \"$TARGET_USER_HOME/.env.secrets\" 2>/dev/null && echo \"\$NVIDIA_VGPU_TOKEN_URL\"" | tr -d '\r')
        download_auth=$(sudo bash -c "source \"$TARGET_USER_HOME/.env.secrets\" 2>/dev/null && echo \"\$NVIDIA_VGPU_DOWNLOAD_AUTH\"" | tr -d '\r')
    fi

    # Probe the driver URL early: if reachable, proceed automatically — no prompt needed.
    # Google Drive links cannot be range-probed (they return HTML), so treat them as reachable.
    if [[ -n "$env_driver_url" ]]; then
        if [[ "$env_driver_url" =~ drive\.google\.com ]]; then
            print_success "Driver: Google Drive URL configured — will proceed."
            vgpu_driver_url="$env_driver_url"
        else
            print_info "Testing driver URL reachability..."
            local probe_args=(curl --max-time 15 --silent --fail --range "0-0" -o /dev/null -L)
            [[ -n "$download_auth" ]] && probe_args+=(-u "$download_auth")
            probe_args+=("$env_driver_url")
            if "${probe_args[@]}" 2>/dev/null; then
                print_success "Driver URL is reachable — proceeding automatically."
                vgpu_driver_url="$env_driver_url"
            else
                echo "⚠️  Driver URL from .env.secrets is not reachable."
            fi
        fi
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    # Compose with global EXIT trap — add local cleanup without clobbering
    # shellcheck disable=SC2064
    trap "rm -rf -- '$tmp_dir'; global_cleanup" EXIT

    local downloaded_file_path="${tmp_dir}/nvidia-vgpu-driver.deb"

    # Retry loop: re-prompt for URL on download failure or HTML error page
    while true; do
        if [[ -z "$vgpu_driver_url" ]]; then
            print_info "No reachable driver URL configured. Paste a direct download URL for the vGPU driver."
            print_info "Supported: http://, https://, ftp://, smb://, Google Drive share link  (leave blank to skip)"
            read -p "Driver URL: " vgpu_driver_url
        fi

        if [[ -z "$vgpu_driver_url" ]]; then
            echo "❌ No URL provided. Skipping vGPU driver installation."
            return 1
        fi

        print_info "Downloading vGPU driver from your provided link..."
        rm -f "$downloaded_file_path"
        local dl_failed=false

        if [[ "$vgpu_driver_url" =~ drive\.google\.com/file/d/([a-zA-Z0-9_-]+) ]]; then
            local file_id="${BASH_REMATCH[1]}"
            print_info "Google Drive share link detected. Extracting file ID: $file_id"
            print_info "Bypassing Google Drive virus scan warning for large files..."

            local confirm_token
            confirm_token=$(curl -sc "${tmp_dir}/cookies.txt" "https://drive.google.com/uc?export=download&id=${file_id}" | grep -o 'confirm=[^&"'\'' ]*' | sed 's/confirm=//' | head -n 1)

            if [[ -n "$confirm_token" ]]; then
                curl_with_retry -L -# -b "${tmp_dir}/cookies.txt" -o "$downloaded_file_path" "https://drive.google.com/uc?export=download&id=${file_id}&confirm=${confirm_token}" || dl_failed=true
            else
                curl_with_retry -L -# -b "${tmp_dir}/cookies.txt" -o "$downloaded_file_path" "https://drive.google.com/uc?export=download&id=${file_id}" || dl_failed=true
            fi
        else
            local curl_cmd=(curl_with_retry -L -# -o "$downloaded_file_path")
            if [[ -n "$download_auth" ]]; then
                curl_cmd+=("-u" "$download_auth")
            fi
            curl_cmd+=("$vgpu_driver_url")

            if ! "${curl_cmd[@]}"; then
                echo "❌ Failed to download the driver. Please check the URL and authentication."
                dl_failed=true
            fi
        fi

        if [[ "$dl_failed" != true ]] && [[ -f "$downloaded_file_path" ]] && file -b --mime-type "$downloaded_file_path" | grep -q "text/html"; then
            echo "❌ Downloaded file is an HTML page, not a valid driver archive."
            echo "   This usually happens if the link is restricted or incorrect."
            dl_failed=true
        fi

        if [[ "$dl_failed" == true ]]; then
            local retry_dl
            read -p "Try another URL? [Y/n]: " retry_dl
            if [[ "$retry_dl" == "n" || "$retry_dl" == "N" ]]; then
                echo "Skipping vGPU driver installation."
                return 1
            fi
            vgpu_driver_url=""
            continue
        fi

        print_success "Download complete and verified."
        break
    done

    if [[ -f "$downloaded_file_path" ]]; then
        print_info "Installing driver from ${downloaded_file_path}... (DKMS compilation may take 5-10 minutes)"
        # Pre-install dkms to prevent scary dpkg dependency errors during unpacking
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y dkms

        # Start a background timer so the user knows it hasn't crashed
        (
            local elapsed=0
            while true; do
                sleep 15
                elapsed=$((elapsed + 15))
                echo -e "\r\e[1;36mℹ️ Still building DKMS module... ($elapsed seconds elapsed)\e[0m"
            done
        ) &
        local spinner_pid=$!

        print_info "Note: The 'Building initial module...' step takes about 200 seconds / 4 minutes to complete. Please wait..."
        sudo dpkg -i "$downloaded_file_path" || sudo apt-get -f install -y

        kill "$spinner_pid" 2>/dev/null || true
        wait "$spinner_pid" 2>/dev/null || true

        print_success "vGPU driver installed successfully."
        POST_INSTALL_ACTIONS+=("reboot")
    else
        echo "❌ Downloaded file not found at ${downloaded_file_path}."
    fi

    # --- Handle vGPU Token Installation ---
    # Probe the token URL; auto-use if reachable.  Token is optional — not all drivers need one.
    if [[ -n "$env_token_url" ]]; then
        if [[ "$env_token_url" =~ drive\.google\.com ]]; then
            print_success "Token: Google Drive URL configured — will proceed."
            vgpu_token_url="$env_token_url"
        else
            print_info "Testing token URL reachability..."
            local tok_probe_args=(curl --max-time 15 --silent --fail --range "0-0" -o /dev/null -L)
            [[ -n "$download_auth" ]] && tok_probe_args+=(-u "$download_auth")
            tok_probe_args+=("$env_token_url")
            if "${tok_probe_args[@]}" 2>/dev/null; then
                print_success "Token URL is reachable — proceeding automatically."
                vgpu_token_url="$env_token_url"
            else
                echo "⚠️  Token URL from .env.secrets is not reachable."
            fi
        fi
    fi

    local token_file_path="${tmp_dir}/client_configuration_token.tok"
    local token_ok=false

    # Retry loop: re-prompt for URL on download failure or HTML error page
    while true; do
        if [[ -z "$vgpu_token_url" ]]; then
            print_info "No reachable token URL configured. Paste a URL for the vGPU license token, or press Enter to skip."
            print_info "(Not all drivers require a token — skipping is fine if yours doesn't.)"
            read -p "Token URL (or Enter to skip): " vgpu_token_url
        fi

        if [[ -z "$vgpu_token_url" ]]; then
            print_info "Skipping vGPU token installation."
            break
        fi

        print_info "Downloading vGPU token..."
        rm -f "$token_file_path"
        local tok_failed=false

        if [[ "$vgpu_token_url" =~ drive\.google\.com/file/d/([a-zA-Z0-9_-]+) ]]; then
            local file_id="${BASH_REMATCH[1]}"
            local confirm_token
            confirm_token=$(curl -sc "${tmp_dir}/cookies.txt" "https://drive.google.com/uc?export=download&id=${file_id}" | grep -o 'confirm=[^&"'\'' ]*' | sed 's/confirm=//' | head -n 1)

            if [[ -n "$confirm_token" ]]; then
                curl_with_retry -L -# -b "${tmp_dir}/cookies.txt" -o "$token_file_path" "https://drive.google.com/uc?export=download&id=${file_id}&confirm=${confirm_token}" || tok_failed=true
            else
                curl_with_retry -L -# -b "${tmp_dir}/cookies.txt" -o "$token_file_path" "https://drive.google.com/uc?export=download&id=${file_id}" || tok_failed=true
            fi
        else
            local curl_cmd=(curl_with_retry -L -# -o "$token_file_path")
            if [[ -n "$download_auth" ]]; then
                curl_cmd+=("-u" "$download_auth")
            fi
            curl_cmd+=("$vgpu_token_url")

            if ! "${curl_cmd[@]}"; then
                echo "❌ Failed to download the token file."
                tok_failed=true
            fi
        fi

        if [[ "$tok_failed" != true ]] && [[ -f "$token_file_path" ]] && file -b --mime-type "$token_file_path" | grep -q "text/html"; then
            echo "❌ Downloaded token file is an HTML page. Ensure it's a direct download link."
            tok_failed=true
        fi

        if [[ "$tok_failed" == true ]] || [[ ! -f "$token_file_path" ]]; then
            local retry_tok
            read -p "Try another token URL? [Y/n]: " retry_tok
            if [[ "$retry_tok" == "n" || "$retry_tok" == "N" ]]; then
                print_info "Skipping vGPU token installation."
                break
            fi
            vgpu_token_url=""
            continue
        fi

        token_ok=true
        break
    done

    if [[ "$token_ok" == true ]]; then
        print_info "Installing vGPU token..."
        sudo mkdir -p /etc/nvidia/ClientConfigToken
        sudo chmod 755 /etc/nvidia/ClientConfigToken
        sudo cp "$token_file_path" /etc/nvidia/ClientConfigToken/client_configuration_token.tok
        sudo chmod 644 /etc/nvidia/ClientConfigToken/client_configuration_token.tok

        print_info "Verifying token installation:"
        sudo ls -l /etc/nvidia/ClientConfigToken/*.tok

        print_info "Configuring /etc/nvidia/gridd.conf for FeatureType=1..."
        if sudo test -f /etc/nvidia/gridd.conf.template && ! sudo test -f /etc/nvidia/gridd.conf; then
            sudo cp /etc/nvidia/gridd.conf.template /etc/nvidia/gridd.conf
        elif ! sudo test -f /etc/nvidia/gridd.conf; then
            sudo touch /etc/nvidia/gridd.conf
        fi

        if sudo grep -q "^FeatureType=" /etc/nvidia/gridd.conf; then
            sudo sed -i 's/^FeatureType=.*/FeatureType=1/' /etc/nvidia/gridd.conf
        else
            echo "FeatureType=1" | sudo tee -a /etc/nvidia/gridd.conf >/dev/null
        fi

        print_info "Restarting nvidia-gridd service..."
        sudo systemctl restart nvidia-gridd || echo "⚠️ Failed to restart nvidia-gridd. You may need to reboot first."

        print_success "vGPU token installed successfully."

        print_info "Checking vGPU License Status (waiting 10 seconds for service to start)..."
        sleep 10
        nvidia-smi -q | grep -i "License Status" || true # display-only: may not match
        nvidia-smi -q | grep -i "Feature" || true        # display-only: may not match
    fi

    # Restore global EXIT trap (remove local tmp_dir cleanup)
    trap 'global_cleanup' EXIT
    rm -rf -- "$tmp_dir"
}

# 8. Install btop (System Monitor)
install_btop() {
    print_header "Installing btop (System Monitor)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y btop
    print_success "btop installed successfully."
}

# 9. Install nvtop (GPU Monitor)
install_nvtop() {
    print_header "Installing nvtop (GPU Monitor)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvtop
    print_success "nvtop installed successfully."
}

# 10. Install CUDA
install_cuda_toolkit() {
    print_info "Installing CUDA..."
    # Make CUDA repo installation dynamic based on Ubuntu version
    UBUNTU_VERSION=$(lsb_release -sr | tr -d '.')
    wget "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VERSION}/x86_64/cuda-keyring_1.1-1_all.deb"
    sudo dpkg -i cuda-keyring_1.1-1_all.deb
    rm cuda-keyring_1.1-1_all.deb
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y install cuda-toolkit

    # The CUDA toolkit installs to /usr/local/cuda, which is not always in the PATH.
    # We will add it idempotently to the user's shell configuration.
    print_info "Verifying CUDA path in shell configuration..."
    local cuda_env_str
    cuda_env_str=$(
        cat <<'EOF'
export CUDA_HOME="/usr/local/cuda"
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$CUDA_HOME/extras/CUPTI/lib64:$LD_LIBRARY_PATH"
EOF
    )
    if sudo test -f "$TARGET_USER_HOME/.zshrc" && ! sudo grep -q 'CUDA_HOME' "$TARGET_USER_HOME/.zshrc"; then
        print_info "Adding CUDA path to ~/.zshrc"
        echo -e "\n# Add NVIDIA CUDA Toolkit to path\n${cuda_env_str}" | sudo tee -a "$TARGET_USER_HOME/.zshrc" >/dev/null
    fi
    if sudo test -f "$TARGET_USER_HOME/.bashrc" && ! sudo grep -q 'CUDA_HOME' "$TARGET_USER_HOME/.bashrc"; then
        print_info "Adding CUDA path to ~/.bashrc"
        echo -e "\n# Add NVIDIA CUDA Toolkit to path\n${cuda_env_str}" | sudo tee -a "$TARGET_USER_HOME/.bashrc" >/dev/null
    fi

    export CUDA_HOME="/usr/local/cuda"
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$CUDA_HOME/extras/CUPTI/lib64:$LD_LIBRARY_PATH"

    print_success "CUDA Toolkit installed."
    POST_INSTALL_ACTIONS+=("cuda")
}

# 11. Install gcc compiler
install_gcc() {
    print_info "Installing gcc compiler..."
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gcc
    print_success "gcc compiler installed."
}

# 12. Install NVIDIA Container Toolkit
install_container_toolkit() {
    # The CDI refresh service (nvidia-cdi-refresh) runs immediately after install
    # and talks to the GPU. If the kernel module isn't loaded it will fail.
    if ! require_nvidia_module_loaded "NVIDIA Container Toolkit"; then
        echo "⚠️  Skipping Container Toolkit install — reboot first, then re-run."
        record_component_outcome "NVIDIA Container Toolkit" "$CONTAINER_TOOLKIT_COMPONENT_ACTION" "failed"
        return 1
    fi

    print_info "Installing NVIDIA Container Toolkit..."
    curl_with_retry -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl_with_retry -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' |
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt-get update

    print_info "Auto-detecting latest NVIDIA Container Toolkit version..."
    local nct_version
    nct_version=$(apt-cache show nvidia-container-toolkit 2>/dev/null | awk '/^Version:/ {print $2}' | head -n 1)
    print_success "Latest version available: ${nct_version:-Unknown}"

    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit

    if command -v docker &>/dev/null; then
        print_info "Configuring Docker to use NVIDIA runtime..."
        sudo nvidia-ctk runtime configure --runtime=docker
        sudo systemctl restart docker || echo "⚠️ Could not restart Docker service."

        sleep 3 # Give Docker a moment to fully initialize its network bridges

        print_info "Testing NVIDIA Container Toolkit (this may download a container image)..."
        local ubuntu_version
        ubuntu_version=$(lsb_release -sr)
        sudo docker run --rm --gpus all "ubuntu:${ubuntu_version}" nvidia-smi ||
            echo "⚠️ Docker NVIDIA test failed. A reboot is likely required to load the NVIDIA drivers, or your network may be experiencing IPv6 routing issues."
    else
        print_info "Docker is not installed. Skipping Docker runtime configuration."
    fi
}

# 13. Install cuDNN
install_cudnn() {
    print_info "Installing cuDNN..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y zlib1g

    print_info "Auto-detecting CUDA major version..."
    local cuda_major="12" # Default fallback

    local detected_nvcc_path=""
    detected_nvcc_path=$(get_cuda_nvcc_path || true) # may not exist yet
    if [[ -n "$detected_nvcc_path" ]]; then
        cuda_major=$("$detected_nvcc_path" --version | sed -n 's/^.*release \([0-9]\+\)\..*$/\1/p')
    elif dpkg -l | grep -q "cuda-toolkit-[0-9]"; then
        cuda_major=$(dpkg -l | awk '/cuda-toolkit-[0-9]+/ {print $2}' | sed -n 's/.*cuda-toolkit-\([0-9]\+\).*/\1/p' | head -n 1)
    elif command -v nvidia-smi &>/dev/null; then
        cuda_major=$(nvidia-smi | grep -i "CUDA Version" | sed -n 's/.*CUDA Version: \([0-9]\+\).*/\1/p')
    fi

    if [[ -z "$cuda_major" ]]; then cuda_major="12"; fi

    print_success "Auto-detected CUDA major version: $cuda_major"
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y install "cudnn9-cuda-${cuda_major}"

    print_info "Auto-detecting cuDNN library path..."
    sudo ldconfig # Ensure cache is updated after installation
    local cudnn_lib_path=""
    cudnn_lib_path=$(get_cudnn_library_path || true) # may not be installed

    if [[ -n "$cudnn_lib_path" ]]; then
        print_success "cuDNN library path found at: $cudnn_lib_path"

        local cudnn_env_str="export LD_LIBRARY_PATH=\"$cudnn_lib_path:\$LD_LIBRARY_PATH\""
        if sudo test -f "$TARGET_USER_HOME/.zshrc" && ! sudo grep -q "$cudnn_lib_path" "$TARGET_USER_HOME/.zshrc"; then
            echo -e "\n# Add cuDNN to LD_LIBRARY_PATH\n${cudnn_env_str}" | sudo tee -a "$TARGET_USER_HOME/.zshrc" >/dev/null
        fi
        if sudo test -f "$TARGET_USER_HOME/.bashrc" && ! sudo grep -q "$cudnn_lib_path" "$TARGET_USER_HOME/.bashrc"; then
            echo -e "\n# Add cuDNN to LD_LIBRARY_PATH\n${cudnn_env_str}" | sudo tee -a "$TARGET_USER_HOME/.bashrc" >/dev/null
        fi
    else
        echo "⚠️ Could not auto-detect cuDNN library path for LD_LIBRARY_PATH export."
    fi

    POST_INSTALL_ACTIONS+=("reboot")
}

# 14. Install Local LLM Support (Ollama, llama.cpp, Open-WebUI)
get_llama_repo_path() {
    echo "$TARGET_USER_HOME/llama.cpp"
}

get_llama_cache_path() {
    echo "$TARGET_USER_HOME/llama.cpp/models/models-user"
}

get_llama_runtime_pid_path() {
    echo "$TARGET_USER_HOME/.cache/llama-server.pid"
}

get_llama_runtime_log_path() {
    echo "$TARGET_USER_HOME/.cache/llama-server.log"
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

get_cuda_nvcc_path() {
    if [[ -x "/usr/local/cuda/bin/nvcc" ]]; then
        echo "/usr/local/cuda/bin/nvcc"
        return 0
    fi

    local alt_nvcc=""
    alt_nvcc=$(find /usr/local -maxdepth 3 -path '/usr/local/cuda-*/bin/nvcc' -type f 2>/dev/null | sort -V | tail -n 1)
    if [[ -n "$alt_nvcc" ]]; then
        echo "$alt_nvcc"
        return 0
    fi

    if command -v nvcc &>/dev/null; then
        command -v nvcc
        return 0
    fi

    return 1
}

# Returns 0 if the NVIDIA kernel module is loaded (driver active after reboot).
# Returns 1 and prints a clear reboot warning if it is not.
# Call this at the start of any step that requires a live GPU.
require_nvidia_module_loaded() {
    local caller="${1:-this step}"
    if lsmod | grep -q "^nvidia "; then
        return 0
    fi
    # Module not loaded — check if driver is at least installed
    if command -v nvidia-smi &>/dev/null ||
        dpkg -l 'nvidia-*' 2>/dev/null | grep -q '^ii'; then
        echo ""
        echo -e "\e[1;41m\e[97m ⚠️  NVIDIA driver installed but kernel module not loaded \e[0m"
        echo -e "\e[1;33m"
        echo "  The NVIDIA driver was installed but the system has not been rebooted yet."
        echo "  $caller requires the GPU to be active — it will fail without a reboot."
        echo ""
        echo "  Please reboot now and re-run the script to continue:"
        echo "    sudo reboot"
        echo -e "\e[0m"
    fi
    return 1
}

ensure_cuda_env_for_current_shell() {
    local nvcc_path=""
    nvcc_path=$(get_cuda_nvcc_path) || return 1

    local detected_cuda_home=""
    detected_cuda_home=$(dirname "$(dirname "$nvcc_path")")

    if [[ -d "$detected_cuda_home" ]]; then
        export CUDA_HOME="$detected_cuda_home"
    elif [[ -d "/usr/local/cuda" ]]; then
        export CUDA_HOME="/usr/local/cuda"
    fi

    if [[ -n "$CUDA_HOME" && -d "$CUDA_HOME/bin" ]]; then
        case ":$PATH:" in
            *":$CUDA_HOME/bin:"*) ;;
            *) export PATH="$CUDA_HOME/bin:$PATH" ;;
        esac
    fi

    if [[ -n "$CUDA_HOME" && -d "$CUDA_HOME/lib64" ]]; then
        case ":$LD_LIBRARY_PATH:" in
            *":$CUDA_HOME/lib64:"*) ;;
            *) export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$CUDA_HOME/extras/CUPTI/lib64:${LD_LIBRARY_PATH:-}" ;;
        esac
    fi

    return 0
}

get_nvidia_ctk_path() {
    if [[ -x "/usr/bin/nvidia-ctk" ]]; then
        echo "/usr/bin/nvidia-ctk"
        return 0
    fi

    local pkg_ctk=""
    pkg_ctk=$(dpkg -L nvidia-container-toolkit 2>/dev/null | grep '/nvidia-ctk$' | head -n 1 || true)
    if [[ -n "$pkg_ctk" && -x "$pkg_ctk" ]]; then
        echo "$pkg_ctk"
        return 0
    fi

    if command -v nvidia-ctk &>/dev/null; then
        command -v nvidia-ctk
        return 0
    fi

    return 1
}

ensure_nvidia_ctk_for_current_shell() {
    local ctk_path=""
    ctk_path=$(get_nvidia_ctk_path) || return 1

    local ctk_dir=""
    ctk_dir=$(dirname "$ctk_path")

    case ":$PATH:" in
        *":$ctk_dir:"*) ;;
        *) export PATH="$ctk_dir:$PATH" ;;
    esac

    return 0
}

get_cudnn_library_path() {
    local cudnn_so=""

    cudnn_so=$(ldconfig -p 2>/dev/null | awk '/libcudnn\.so/ {print $NF; exit}')
    if [[ -n "$cudnn_so" ]]; then
        dirname "$cudnn_so"
        return 0
    fi

    cudnn_so=$(dpkg -L cudnn9-cuda-12 2>/dev/null | grep '/libcudnn\.so' | head -n 1 || true)
    if [[ -z "$cudnn_so" ]]; then
        cudnn_so=$(dpkg -L libcudnn9-cuda-12 2>/dev/null | grep '/libcudnn\.so' | head -n 1 || true)
    fi
    if [[ -z "$cudnn_so" ]]; then
        cudnn_so=$(dpkg -L cudnn9-cuda-13 2>/dev/null | grep '/libcudnn\.so' | head -n 1 || true)
    fi
    if [[ -z "$cudnn_so" ]]; then
        cudnn_so=$(dpkg -L libcudnn9-cuda-13 2>/dev/null | grep '/libcudnn\.so' | head -n 1 || true)
    fi
    if [[ -z "$cudnn_so" ]]; then
        cudnn_so=$(find /usr /usr/local -path '*libcudnn.so*' -type f 2>/dev/null | head -n 1 || true)
    fi

    if [[ -n "$cudnn_so" ]]; then
        dirname "$cudnn_so"
        return 0
    fi

    return 1
}

has_cudnn_available() {
    if get_cudnn_library_path >/dev/null 2>&1; then
        return 0
    fi

    if dpkg -l | grep -E -q 'cudnn[0-9]+-cuda|libcudnn'; then
        return 0
    fi

    return 1
}

ensure_cudnn_env_for_current_shell() {
    local cudnn_lib_path=""
    cudnn_lib_path=$(get_cudnn_library_path) || return 1

    case ":${LD_LIBRARY_PATH:-}:" in
        *":$cudnn_lib_path:"*) ;;
        *) export LD_LIBRARY_PATH="$cudnn_lib_path:${LD_LIBRARY_PATH:-}" ;;
    esac

    return 0
}

detect_local_ai_components() {
    local llama_repo_present=false
    local llama_binary_present=false
    local llama_partial=false
    if sudo test -d "$(get_llama_repo_path)"; then llama_repo_present=true; fi
    if command -v llama-server &>/dev/null; then llama_binary_present=true; fi
    if [[ "$llama_repo_present" == true || "$llama_binary_present" == true ]] || systemctl list-unit-files 2>/dev/null | grep -q '^llama-server.service'; then
        llama_partial=true
    fi
    LLAMA_COMPONENT_STATUS=$(derive_component_status "$([[ "$llama_repo_present" == true && "$llama_binary_present" == true ]] && echo true || echo false)" "$llama_partial")

    local ollama_binary_present=false
    local ollama_partial=false
    if command -v ollama &>/dev/null; then ollama_binary_present=true; fi
    if [[ "$ollama_binary_present" == true ]] || systemctl list-unit-files 2>/dev/null | grep -q '^ollama.service'; then
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
        "export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\"; command -v openclaw 2>/dev/null || true" 2>/dev/null || true)
    if [[ -n "$oc_bin_detected" ]] || sudo test -f "$TARGET_USER_HOME/.local/bin/openclaw"; then openclaw_binary=true; fi
    if sudo test -d "$TARGET_USER_HOME/.openclaw"; then openclaw_config=true; fi
    if [[ "$openclaw_binary" == true || "$openclaw_config" == true ]]; then openclaw_partial=true; fi
    OPENCLAW_COMPONENT_STATUS=$(derive_component_status "$([[ "$openclaw_binary" == true && "$openclaw_config" == true ]] && echo true || echo false)" "$openclaw_partial")
}

cleanup_llama_component() {
    print_info "Hard-resetting llama.cpp before rerun..."
    sudo systemctl stop llama-server 2>/dev/null || true    # may not exist on first run
    sudo systemctl disable llama-server 2>/dev/null || true # may not exist on first run
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
    sudo rm -f /etc/systemd/system/llama-server.service
    sudo systemctl daemon-reload
    sudo rm -rf "$(get_llama_repo_path)"
}

cleanup_ollama_component() {
    print_info "Hard-resetting Ollama before rerun..."
    # All || true in cleanup functions: idempotent teardown — may not exist yet
    sudo systemctl stop ollama 2>/dev/null || true
    sudo systemctl disable ollama 2>/dev/null || true
    sudo rm -rf /etc/systemd/system/ollama.service.d
    sudo rm -f /usr/local/bin/ollama /usr/bin/ollama
    sudo rm -rf /usr/share/ollama /var/lib/ollama "$TARGET_USER_HOME/.ollama"
    sudo systemctl daemon-reload
}

cleanup_openwebui_component() {
    print_info "Hard-resetting Open-WebUI before rerun..."
    # All || true in cleanup functions: idempotent teardown — may not exist yet
    sudo docker stop open-webui &>/dev/null || true
    sudo docker rm open-webui &>/dev/null || true
    sudo docker volume rm open-webui &>/dev/null || true
    sudo systemctl disable open-webui-update.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/open-webui-update.service /usr/local/bin/update-open-webui.sh
    sudo systemctl daemon-reload
}

cleanup_librechat_component() {
    print_info "Hard-resetting LibreChat before rerun..."
    if sudo test -d "$TARGET_USER_HOME/LibreChat"; then
        sudo bash -c "cd \"$TARGET_USER_HOME/LibreChat\" && docker compose down -v" >/dev/null 2>&1 || true
    fi
    sudo rm -rf "$TARGET_USER_HOME/LibreChat"
    sudo rm -f /usr/local/bin/update-librechat.sh
}

cleanup_openclaw_component() {
    print_info "Hard-resetting OpenClaw before rerun..."
    sudo -u "$TARGET_USER" bash -c "export XDG_RUNTIME_DIR=\"/run/user/\$(id -u)\"; export DBUS_SESSION_BUS_ADDRESS=\"unix:path=\${XDG_RUNTIME_DIR}/bus\"; systemctl --user stop openclaw.service 2>/dev/null || true; systemctl --user disable openclaw.service 2>/dev/null || true; systemctl --user daemon-reload 2>/dev/null || true"
    sudo rm -rf "$TARGET_USER_HOME/.openclaw" "$TARGET_USER_HOME/.config/openclaw" "$TARGET_USER_HOME/.local/share/openclaw"
    sudo rm -f "$TARGET_USER_HOME/.local/bin/openclaw"
    sudo rm -f "$TARGET_USER_HOME/.config/systemd/user/openclaw.service"
}

verify_llama_component() {
    if ! command -v llama-server &>/dev/null; then
        echo "❌ llama.cpp verification failed: /usr/local/bin/llama-server is missing."
        return 1
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q '^llama-server.service'; then
        print_info "Waiting for llama.cpp server to initialize (timeout 60s)..."
        if ! wait_for_llama_server_ready "service" 45 2 "$(get_llama_runtime_log_path)"; then
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
    oc_bin=$(sudo -u "$TARGET_USER" bash -c "export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\"; command -v openclaw 2>/dev/null || true")
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
    if [[ "$LLAMA_COMPONENT_ACTION" == "skip" || -z "$LLM_DEFAULT_MODEL_CHOICE" ]]; then
        return 1
    fi

    if [[ "$LOAD_DEFAULT_MODEL" == "y" || "$INSTALL_LLAMA_SERVICE" == "y" || "$EXPOSE_LLM_ENGINE" == "y" ]]; then
        return 0
    fi

    if [[ "$FRONTEND_BACKEND_TARGET" == "llama" && ("$OPENWEBUI_COMPONENT_ACTION" != "skip" || "$LIBRECHAT_COMPONENT_ACTION" != "skip") ]]; then
        return 0
    fi

    return 1
}

build_llama_hf_args() {
    local hf_args="--model /srv/models/llama.gguf"

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

    # If no specific file, query HF API — prefer Q4_K_M, fall back to first gguf
    if [[ -z "$hf_file" ]]; then
        print_info "Querying HuggingFace API for GGUF files in '$hf_repo'..." >&2
        local api_response=""
        if [[ -n "$hf_token" ]]; then
            api_response=$(curl -sf -H "Authorization: Bearer $hf_token" "https://huggingface.co/api/models/$hf_repo" 2>/dev/null || true)
        else
            api_response=$(curl -sf "https://huggingface.co/api/models/$hf_repo" 2>/dev/null || true)
        fi
        hf_file=$(echo "$api_response" | jq -r '.siblings[].rfilename | select(endswith(".gguf"))' 2>/dev/null | grep -i "q4_k_m" | head -1 || true)
        if [[ -z "$hf_file" ]]; then
            hf_file=$(echo "$api_response" | jq -r '.siblings[].rfilename | select(endswith(".gguf"))' 2>/dev/null | head -1 || true)
        fi
    fi

    if [[ -z "$hf_file" ]]; then
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

    local download_url="https://huggingface.co/$hf_repo/resolve/main/$hf_file"

    print_info "Downloading model (this may take several minutes)..." >&2
    echo -e "  Repo : \e[1;36m$hf_repo\e[0m" >&2
    echo -e "  File : \e[1;36m$hf_file\e[0m" >&2

    local dl_status=0
    if [[ -n "$hf_token" ]]; then
        sudo -u "$TARGET_USER" bash -c \
            "curl -L --progress-bar --fail -H 'Authorization: Bearer $hf_token' -o '$dest_path' '$download_url'" ||
            dl_status=$?
    else
        sudo -u "$TARGET_USER" bash -c \
            "curl -L --progress-bar --fail -o '$dest_path' '$download_url'" ||
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

    for ((i = 0; i < attempts; i++)); do
        health_status=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/health" 2>/dev/null || echo "000")
        models_status=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/v1/models" 2>/dev/null || echo "000")
        root_status=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/" 2>/dev/null || echo "000")

        if [[ "$health_status" == "200" || "$models_status" == "200" || "$root_status" == "200" ]]; then
            printf "\r\e[K"
            return 0
        fi

        if [[ "$run_mode" == "service" ]] && systemctl list-unit-files 2>/dev/null | grep -q '^llama-server.service'; then
            if ! systemctl is-active --quiet llama-server 2>/dev/null; then
                printf "\r\e[K"
                echo "❌ llama.cpp verification failed: systemd service is not active."
                sudo systemctl --no-pager --full status llama-server || true # display-only diagnostics
                sudo journalctl -u llama-server -n 40 --no-pager || true     # display-only diagnostics
                return 1
            fi
        fi

        if [[ -f "$log_file" ]]; then
            local download_progress
            download_progress=$(grep -oE '([0-9]{1,3}(\.[0-9]+)?)%' "$log_file" | tail -n 1 || true) # optional: log may not have progress yet
            if [[ -n "$download_progress" ]]; then
                if [[ "$download_progress" != "$last_progress" ]]; then
                    printf "\r\e[1;36mℹ️  llama.cpp model download: %s\e[0m" "$download_progress"
                    last_progress="$download_progress"
                fi
            else
                printf "\r\e[1;36mℹ️  llama.cpp server starting... %ds elapsed\e[0m" "$elapsed"
            fi
        else
            printf "\r\e[1;36mℹ️  llama.cpp server starting... %ds elapsed\e[0m" "$elapsed"
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
        sudo journalctl -u llama-server -n 40 --no-pager || true # display-only diagnostics
    fi
    return 1
}

start_llama_server_transient() {
    local hf_args="$1"
    local llama_host_args="$2"
    local build_variant="$3"
    local llama_cache_dir
    local llama_pid_file
    local llama_log_file
    local ld_library_prefix=""
    local shell_prefix

    llama_cache_dir=$(get_llama_cache_path)
    llama_pid_file=$(get_llama_runtime_pid_path)
    llama_log_file=$(get_llama_runtime_log_path)

    if [[ "$build_variant" == "llama_cuda" ]]; then
        ld_library_prefix='export LD_LIBRARY_PATH="/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64:$LD_LIBRARY_PATH"; '
    fi

    sudo mkdir -p "$TARGET_USER_HOME/.cache"
    sudo chown "$TARGET_USER":"$TARGET_USER" "$TARGET_USER_HOME/.cache"
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

    shell_prefix="cd \"$TARGET_USER_HOME\"; export TARGET_USER_HOME=\"$TARGET_USER_HOME\"; [ -f \"$TARGET_USER_HOME/.env.secrets\" ] && source \"$TARGET_USER_HOME/.env.secrets\"; export HOME=\"$TARGET_USER_HOME\"; export LLAMA_CACHE=\"$llama_cache_dir\"; ${ld_library_prefix}"
    sudo -u "$TARGET_USER" bash -c "$shell_prefix nohup /usr/local/bin/llama-server $hf_args $llama_host_args > \"$llama_log_file\" 2>&1 < /dev/null & echo \$! > \"$llama_pid_file\""

    print_success "llama.cpp started in the background on port 8080."
    print_info "Waiting for llama.cpp to finish loading the selected model..."
    if ! wait_for_llama_server_ready "transient" 45 2 "$llama_log_file"; then
        return 1
    fi

    return 0
}

# ─── Context & Memory Configuration ──────────────────────────────

# Approximate model weight sizes (GB) per VRAM tier for Q4_K_M quantization.
# Used to estimate remaining VRAM for KV cache. Conservative estimates.
get_model_weight_gb() {
    local vram_tier="${1:-16}"
    case "$vram_tier" in
        8) echo "4" ;;   # ~4GB for 7B Q4_K_M
        16) echo "8" ;;  # ~8GB for 14B Q4_K_M
        24) echo "14" ;; # ~14GB for 26B Q4_K_M
        32) echo "18" ;; # ~18GB for 32B Q4_K_M
        48) echo "40" ;; # ~40GB for 70B Q4_K_M
        72) echo "40" ;; # ~40GB for 72B Q4_K_M
        96) echo "40" ;; # ~40GB for 72B Q4_K_M (bigger tier, same model)
        *) echo "8" ;;
    esac
}

# Smart defaults for context size and cache type based on available VRAM
get_context_defaults() {
    local vram_tier="${1:-16}"
    # Minimum context = 65536 for all tiers (OpenClaw needs ≥65K).
    # KV cache default = q4_0 for ≤24GB (aggressive compression to fit),
    # q4_0 for 32GB+ (comfortable headroom with large models).
    # Ubatch default = 1024 for ≤24GB, scales up with VRAM.
    case "$vram_tier" in
        8)
            CTX_DEFAULT=65536
            CTK_DEFAULT="q4_0"
            UBATCH_DEFAULT=512
            ;;
        16)
            CTX_DEFAULT=65536
            CTK_DEFAULT="q4_0"
            UBATCH_DEFAULT=1024
            ;;
        24)
            CTX_DEFAULT=81920
            CTK_DEFAULT="q4_0"
            UBATCH_DEFAULT=1024
            ;;
        32)
            CTX_DEFAULT=81920
            CTK_DEFAULT="q4_0"
            UBATCH_DEFAULT=2048
            ;;
        48)
            CTX_DEFAULT=131072
            CTK_DEFAULT="q4_0"
            UBATCH_DEFAULT=2048
            ;;
        72)
            CTX_DEFAULT=131072
            CTK_DEFAULT="q4_0"
            UBATCH_DEFAULT=2048
            ;;
        96)
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
estimate_vram_usage() {
    local model_gb="$1"
    local ctx_size="$2"
    local ctk="$3"

    local bytes_per
    bytes_per=$(cache_type_bytes "$ctk")
    local overhead="0.5"

    # Heuristic: KV cache ≈ ctx_size * bytes_per_elem * scaling_factor
    # Uses sqrt(model_gb/7) because KV cache depends on n_layers × n_kv_heads × head_dim,
    # which grows sublinearly vs total params (GQA, MoE reduce KV heads).
    # Calibrated: 7B@4K f16 ≈ 0.2GB; 26B@80K q4_0 ≈ 3GB (confirmed on 24GB GPU).
    local kv_gb
    kv_gb=$(awk "BEGIN { printf \"%.1f\", ($ctx_size / 1024.0) * ($bytes_per / 2.0) * sqrt($model_gb / 7.0) * 0.10 }")

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

    local model_gb
    model_gb=$(get_model_weight_gb "$vram_tier")
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

    local width=56

    while true; do
        clear
        print_status_header

        # Calculate VRAM estimate
        local estimate
        estimate=$(estimate_vram_usage "$model_gb" "$ctx" "$ctk")
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

        echo ""
        echo "┌──────────────────────────────────────────────────────────┐"
        printf "│ %-${width}s │\n" " 1. Context size:     [$ctx] tokens"
        printf "│ %-${width}s │\n" " 2. KV cache type:    [$ctk]  (K and V matched)"
        printf "│ %-${width}s │\n" " 3. CPU MoE offload:  [$moe_disp]"
        printf "│ %-${width}s │\n" " 4. Flash attention:  [$fa_disp]"
        printf "│ %-${width}s │\n" " 5. Ubatch size:      [$ubatch]"
        if [[ "$target_backend" == "llama_cuda" ]]; then
            local ngl_disp
            if [[ "$fit_mode" == "y" ]]; then
                ngl_disp="auto-fit  --fit-ctx ${fit_ctx:-${ctx}}"
            else
                ngl_disp="$ngl"
            fi
            printf "│ %-${width}s │\n" " 6. GPU layers:       [$ngl_disp]  (-ngl / --fit)"
        fi
        printf "│ %-${width}s │\n" ""
        printf "│ %-${width}s │\n" " Model weights:    ${model_disp} GB"
        printf "│ %-${width}s │\n" " KV cache:         ${kv_gb} GB"
        printf "│ %-${width}s │\n" " Runtime overhead: ~${overhead_gb} GB"
        printf "│ %-${width}s │\n" " ───────────────"
        if [[ -n "$fit_color" ]]; then
            # OOM line with colour — use echo -e for ANSI
            echo -e "│ $(printf "%-${width}s" " Estimated total:  ${fit_color}${total_gb} / ${hw_capacity} GB  ${fits}\e[0m")   │"
        else
            printf "│ %-${width}s │\n" " Estimated total:  ${total_gb} / ${hw_capacity} GB  ${fits}"
        fi
        printf "│ %-${width}s │\n" ""

        if [[ "$fits" == *"OOM"* ]]; then
            printf "│ %-${width}s │\n" " ⚠️  Reduce context or switch to q4_0/turbo4/turbo3"
            printf "│ %-${width}s │\n" ""
        fi

        if [[ "$target_backend" == "llama_cuda" ]]; then
            printf "│ %-${width}s │\n" " [c] Confirm  [1-6] Change  [d] Defaults"
        else
            printf "│ %-${width}s │\n" " [c] Confirm  [1-5] Change  [d] Defaults"
        fi
        echo "└──────────────────────────────────────────────────────────┘"
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
                    echo -e "\n  ⚠️  Flash attention requires CUDA. It may not work on CPU-only builds." && sleep 2
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
                if [[ "$target_backend" == "llama_cuda" ]]; then
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
                            echo -e "  \e[1;32m✅\e[0m Auto-fit on — --fit-ctx ${fit_ctx}"
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
            d | D)
                get_context_defaults "$vram_tier"
                ctx="$CTX_DEFAULT"
                ctk="$CTK_DEFAULT"
                cpu_moe="y"
                ubatch="$UBATCH_DEFAULT"
                ngl=99
                fit_mode="n"
                fit_ctx=""
                if [[ "$target_backend" == "llama_cuda" ]]; then flash_attn="y"; else flash_attn="n"; fi
                ;;
            c | C)
                break
                ;;
            *)
                echo -e "\nInvalid option." && sleep 1
                ;;
        esac
    done

    LLAMA_CTX_SIZE="$ctx"
    LLAMA_CACHE_TYPE_K="$ctk"
    LLAMA_CACHE_TYPE_V="$ctk"
    LLAMA_CPU_MOE="$cpu_moe"
    LLAMA_FLASH_ATTN="$flash_attn"
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
        echo -e "\n\e[1;36mSelect a default model to load for ${target_backend} or choose your ${memory_type} tier:\e[0m"
        if [[ $detected_ram_vram -gt 0 ]]; then
            echo -e "Detected total ${memory_type}: \e[1;32m~${detected_ram_vram} GB\e[0m"
        fi
        echo "  1. Tiny Model (for quick testing)"
        echo "  2. Specify a different model to download"
        echo ""
        echo "  3. 8 GB"
        echo "  4. 16 GB"
        echo "  5. 24 GB"
        echo "  6. 32 GB"
        echo "  7. 48 GB"
        echo "  8. 72 GB"
        echo "  9. 96 GB"
        read -p "Your choice [1-9]: " vram_choice

        if [[ "$vram_choice" == "1" ]]; then
            LLM_DEFAULT_MODEL_CHOICE="5"
            break
        elif [[ "$vram_choice" == "2" ]]; then
            LLM_DEFAULT_MODEL_CHOICE="6"
            if [[ "$target_backend" == "ollama" ]]; then
                while true; do
                    read -p "Enter an Ollama model name to pull (or 'b' to go back): " raw_input
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
                    read -p "Enter Hugging Face repo or repo:file (or 'b' to go back): " raw_input
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
            3) vram_tier=8 ;;
            4) vram_tier=16 ;;
            5) vram_tier=24 ;;
            6) vram_tier=32 ;;
            7) vram_tier=48 ;;
            8) vram_tier=72 ;;
            9) vram_tier=96 ;;
            *)
                echo -e "\nInvalid choice. Please try again."
                sleep 1
                continue
                ;;
        esac

        get_model_recommendations "$(llama_variant_to_model_backend "$target_backend")" "$vram_tier"
        local m_chat="$REC_MODEL_CHAT"
        local m_code="$REC_MODEL_CODE"
        local m_moe="$REC_MODEL_MOE"
        local m_vision="$REC_MODEL_VISION"

        echo -e "\n\e[1;36mSelect a default model to load (${vram_tier}GB Tier):\e[0m"
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
                echo -e "\nInvalid choice. Please try again."
                sleep 1
                continue
                ;;
        esac
        LLAMA_VRAM_TIER="$vram_tier"
        break
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
        echo -e "\n\e[1;36mInstall local LLM Backend (Exclusive):\e[0m"
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
            echo -e " \e[1;32m(*)\e[0m 1. Ollama [$(format_component_status_label "$OLLAMA_COMPONENT_STATUS")] -> ${ollama_action_label}"
        else
            echo -e " ( ) 1. Ollama [$(format_component_status_label "$OLLAMA_COMPONENT_STATUS")]"
        fi
        if [[ "$selected_backend" == "llama" ]]; then
            echo -e " \e[1;32m(*)\e[0m 2. llama.cpp [$(format_component_status_label "$LLAMA_COMPONENT_STATUS")] -> ${llama_action_label}"
        else
            echo -e " ( ) 2. llama.cpp [$(format_component_status_label "$LLAMA_COMPONENT_STATUS")]"
        fi
        if [[ $openwebui_selected -eq 1 ]]; then
            echo -e " \e[1;32m[x]\e[0m 3. Open-WebUI [$(format_component_status_label "$OPENWEBUI_COMPONENT_STATUS")] -> ${openwebui_action_label}"
        else
            echo -e " [ ] 3. Open-WebUI [$(format_component_status_label "$OPENWEBUI_COMPONENT_STATUS")]"
        fi
        if [[ $librechat_selected -eq 1 ]]; then
            echo -e " \e[1;32m[x]\e[0m 4. LibreChat [$(format_component_status_label "$LIBRECHAT_COMPONENT_STATUS")] -> ${librechat_action_label}"
        else
            echo -e " [ ] 4. LibreChat [$(format_component_status_label "$LIBRECHAT_COMPONENT_STATUS")]"
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
                    echo -e "\nPlease select at least one component."
                    sleep 1
                elif [[ -z "$selected_backend" && ($openwebui_selected -eq 1 || $librechat_selected -eq 1) && "$LLAMA_COMPONENT_STATUS" != "missing" && "$OLLAMA_COMPONENT_STATUS" != "missing" ]]; then
                    echo -e "\nBoth backends are currently present. Select which backend to keep before repairing the frontends."
                    sleep 2
                else
                    break
                fi
                ;;
            q | Q)
                return 1
                ;;
            *)
                echo -e "\nInvalid choice."
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
            echo -e "\n\e[1;36mChoose how to build llama.cpp:\e[0m"
            if [[ "$HAS_NVIDIA_GPU" == true ]]; then
                echo "  1. CUDA build"
            fi
            echo "  2. CPU build"
            read -p "Your choice: " llama_variant_choice
            case "$llama_variant_choice" in
                1)
                    if [[ "$HAS_NVIDIA_GPU" == true ]]; then
                        LLAMA_BUILD_VARIANT="llama_cuda"
                        break
                    fi
                    ;;
                2)
                    LLAMA_BUILD_VARIANT="llama_cpu"
                    break
                    ;;
            esac
            echo -e "\nInvalid choice."
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

    if [[ "$effective_backend_target" == "llama" ]]; then
        echo ""
        read -p "Allow external connections to Llama.CPP (add --host 0.0.0.0)? [y/N]: " expose_llm_choice
        if [[ "$expose_llm_choice" == "y" || "$expose_llm_choice" == "Y" ]]; then
            EXPOSE_LLM_ENGINE="y"
        fi
    elif [[ "$effective_backend_target" == "ollama" ]]; then
        echo ""
        read -p "Allow external connections to Ollama (bind 0.0.0.0:11434)? [y/N]: " expose_llm_choice
        if [[ "$expose_llm_choice" == "y" || "$expose_llm_choice" == "Y" ]]; then
            EXPOSE_LLM_ENGINE="y"
        fi
    fi

    if [[ "$LLAMA_COMPONENT_ACTION" != "skip" ]]; then
        echo ""
        read -p "Install llama.cpp as a system service? [y/N]: " llama_service_choice
        if [[ "$llama_service_choice" == "y" || "$llama_service_choice" == "Y" ]]; then
            INSTALL_LLAMA_SERVICE="y"
        fi

        echo ""
        read -p "Run llama.cpp benchmark after install? [y/N]: " llama_bench_choice
        if [[ "$llama_bench_choice" == "y" || "$llama_bench_choice" == "Y" ]]; then
            RUN_LLAMA_BENCH="y"
        fi
    fi

    if [[ "$LIBRECHAT_COMPONENT_ACTION" != "skip" ]]; then
        echo ""
        read -p "Run LibreChat on port 8083 instead of 3080? [y/N]: " lc_port_choice
        if [[ "$lc_port_choice" == "y" || "$lc_port_choice" == "Y" ]]; then
            LIBRECHAT_PORT="8083"
        fi
    fi

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
        read -p "Load a default model during this run? [y/N]: " load_model_choice
        if [[ "$load_model_choice" == "y" || "$load_model_choice" == "Y" ]]; then
            if [[ "$LLAMA_COMPONENT_ACTION" != "skip" ]]; then
                configure_llm_model_prompt "${LLAMA_BUILD_VARIANT:-llama_cpu}"
                configure_context_memory "${LLAMA_BUILD_VARIANT:-llama_cpu}"
            else
                configure_llm_model_prompt "ollama"
            fi
        fi
    fi

    echo ""
    read -p "Enable UFW automatically after this run if ports were opened? [y/N]: " ufw_choice
    if [[ "$ufw_choice" == "y" || "$ufw_choice" == "Y" ]]; then
        ENABLE_UFW_AUTOMATICALLY="y"
    fi

    INSTALL_OPENWEBUI=$([[ "$OPENWEBUI_COMPONENT_ACTION" != "skip" ]] && echo "y" || echo "n")
    INSTALL_LIBRECHAT=$([[ "$LIBRECHAT_COMPONENT_ACTION" != "skip" ]] && echo "y" || echo "n")

    return 0
}

configure_openclaw_selection() {
    detect_local_ai_components

    if [[ "$IS_DIFFERENT_USER" == false ]]; then
        echo -e "\n❌ [Blocked] OpenClaw cannot be installed for the current sudo user."
        read -p "Do you want to create/select a dedicated standard user now? [y/N]: " fix_user
        if [[ "$fix_user" == "y" || "$fix_user" == "Y" ]]; then
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
    echo -e "\e[1;36mOpenClaw Release Channel:\e[0m"
    echo -e "  1) \e[1;32mStable\e[0m  (latest)         — current npm release"
    echo -e "  2) \e[1;33mBeta\e[0m                     — pre-release with latest fixes"
    echo -e "  3) \e[1;34mPrior stable\e[0m ($oc_prior_stable)  — last known working release"
    echo ""
    local oc_channel_choice
    read -rp "Select release channel [1]: " oc_channel_choice
    case "${oc_channel_choice:-1}" in
        1) OPENCLAW_RELEASE_CHANNEL="latest" ;;
        2) OPENCLAW_RELEASE_CHANNEL="beta" ;;
        3) OPENCLAW_RELEASE_CHANNEL="$oc_prior_stable" ;;
        *) OPENCLAW_RELEASE_CHANNEL="latest" ;;
    esac
    echo -e "  → Using \e[1;32mopenclaw@${OPENCLAW_RELEASE_CHANNEL}\e[0m"

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
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential git cmake ccache libcurl4-openssl-dev libssl-dev

        local cmake_flags="-DGGML_NATIVE=OFF"
        local export_cmd=""

        if [[ "$install_llamacpp_cuda" == "y" ]]; then
            print_info "Detecting number of NVIDIA GPUs..."
            local gpu_count=1
            local nccl_flag="-DGGML_NCCL=OFF"
            if command -v nvidia-smi &>/dev/null; then
                gpu_count=$(nvidia-smi --list-gpus | wc -l)
            elif command -v lspci &>/dev/null; then
                gpu_count=$(lspci | grep -i 'nvidia' | grep -iE 'vga|3d|display' | wc -l)
            fi

            if [[ "$gpu_count" -gt 1 ]]; then
                print_info "Detected $gpu_count NVIDIA GPUs. Installing NCCL for multi-GPU optimization..."
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libnccl-dev
                nccl_flag=""
            else
                print_info "Detected $gpu_count NVIDIA GPU(s). Disabling NCCL to prevent single-GPU/vGPU conflicts."
            fi

            print_info "Auto-detecting GPU Compute Capability..."
            local compute_cap="86" # Default fallback (Ampere — covers RTX 3xxx/A-series)
            if ! require_nvidia_module_loaded "CUDA llama.cpp build"; then
                echo "⚠️  GPU not active — using default compute capability $compute_cap."
                echo "    After reboot, re-run to build with the correct architecture."
            elif command -v nvidia-smi &>/dev/null; then
                local detected_cap
                detected_cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '.')
                if [[ -n "$detected_cap" ]]; then
                    compute_cap="$detected_cap"
                    print_success "Auto-detected Compute Capability: $compute_cap"
                else
                    print_info "nvidia-smi returned no compute cap — defaulting to $compute_cap."
                fi
            fi
            cmake_flags="-DGGML_CUDA=ON -DGGML_NATIVE=OFF $nccl_flag -DCMAKE_CUDA_ARCHITECTURES=\"$compute_cap\""
            export_cmd="export CUDA_HOME=\"/usr/local/cuda\"; export PATH=\"\$CUDA_HOME/bin:\$PATH\"; export LD_LIBRARY_PATH=\"\$CUDA_HOME/lib64:\$CUDA_HOME/extras/CUPTI/lib64:\$LD_LIBRARY_PATH\";"
            print_info "Cloning and building llama.cpp with CUDA support..."
        else
            print_info "Cloning and building llama.cpp with CPU support..."
        fi

        sudo -u "$TARGET_USER" bash -c "
            cd \"$TARGET_USER_HOME\"
            # If the directory exists but isn't a git repo (due to the previous mkdir bug), remove it
            if [ -d \"llama.cpp\" ] && [ ! -d \"llama.cpp/.git\" ]; then
                rm -rf llama.cpp
            fi
            if [ ! -d \"llama.cpp\" ]; then
                git clone https://github.com/ggerganov/llama.cpp
            fi
            mkdir -p \"$(get_llama_cache_path)\"
            cd llama.cpp
            # Clean previous build to prevent CMake caching old NCCL configuration
            rm -rf build
            $export_cmd
            cmake -B build $cmake_flags
            cmake --build build --config Release -j $(nproc)
        "
        print_success "llama.cpp built successfully."

        print_info "Installing llama.cpp globally for all users..."
        sudo bash -c "cd \"$TARGET_USER_HOME/llama.cpp\" && cmake --install build --prefix /usr/local && ldconfig"
        print_success "llama.cpp installed globally to /usr/local/bin."

        echo ""
        hf_args=$(build_llama_hf_args)

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
            local env_prefix="cd \"$TARGET_USER_HOME\"; $secrets_source export HOME=\"$TARGET_USER_HOME\"; export LLAMA_CACHE=\"$llama_cache_dir\"; export LD_LIBRARY_PATH=\"/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64:\$LD_LIBRARY_PATH\";"

            local ngl_bench=0
            if [[ "$install_llamacpp_cuda" == "y" ]]; then ngl_bench=99; fi

            local bench_out
            bench_out=$(mktemp "${TMPDIR:-/tmp}/llama-bench.XXXXXX")
            local bench_status=0

            set +e
            sudo -u "$TARGET_USER" bash -c \
                "$env_prefix llama-bench $hf_args -ngl $ngl_bench -r 3 --progress -o md" \
                2>&1 | tee "$bench_out"
            bench_status=${PIPESTATUS[0]}
            set -e

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

        if llama_should_launch_server; then
            if [[ "$INSTALL_LLAMA_SERVICE" == "y" ]]; then
                print_info "Creating llama-server systemd service..."
                local env_cuda=""
                if [[ "$install_llamacpp_cuda" == "y" ]]; then
                    env_cuda="Environment=\"LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64\""
                fi

                sudo systemctl stop llama-server 2>/dev/null || true
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

                # shellcheck disable=SC2090
                sudo tee /etc/systemd/system/llama-server.service >/dev/null <<SERVICEEOF
[Unit]
Description=Llama.cpp Server
After=network.target

[Service]
User=$TARGET_USER
WorkingDirectory=$TARGET_USER_HOME
Environment="HOME=$TARGET_USER_HOME"
Environment="TARGET_USER_HOME=$TARGET_USER_HOME"
Environment="LLAMA_CACHE=$(get_llama_cache_path)"
$env_cuda
ExecStart=/bin/bash -c 'source $TARGET_USER_HOME/.env.secrets 2>/dev/null; export HOME="$TARGET_USER_HOME"; export LLAMA_CACHE="$(get_llama_cache_path)"; mkdir -p "$TARGET_USER_HOME/.cache"; exec /usr/local/bin/llama-server $hf_args $llama_host_args >> "$(get_llama_runtime_log_path)" 2>&1'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICEEOF
                sudo systemctl daemon-reload
                sudo systemctl enable --now llama-server
                llama_runtime_mode="service"
                print_success "llama.cpp service installed and started on port 8080."
                echo ""
                sudo systemctl status llama-server --no-pager || true # display-only: show service state
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
        print_info "Installing Ollama..."
        curl_with_retry -fsSL https://ollama.com/install.sh | sh

        if [[ "$EXPOSE_LLM_ENGINE" == "y" ]]; then
            print_info "Configuring Ollama for external access..."
            sudo mkdir -p /etc/systemd/system/ollama.service.d
            local allowed_origins="*"
            if sudo test -f "$TARGET_USER_HOME/.env.secrets"; then
                local env_origins
                env_origins=$(sudo bash -c "source \"$TARGET_USER_HOME/.env.secrets\" 2>/dev/null && echo \"\$OLLAMA_ALLOWED_ORIGINS\"" | tr -d '\r')
                if [[ -n "$env_origins" ]]; then allowed_origins="$env_origins"; fi
            fi
            echo -e "[Service]\nEnvironment=\"OLLAMA_HOST=0.0.0.0:11434\"\nEnvironment=\"OLLAMA_ORIGINS=$allowed_origins\"" | sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null
            sudo systemctl daemon-reload
            sudo systemctl restart ollama
            sudo ufw allow 11434/tcp &>/dev/null || true # ufw may not be installed
            POST_INSTALL_ACTIONS+=("ufw")
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
                        echo -e "\r\e[1;36mℹ️ Still downloading model... ($elapsed seconds elapsed)\e[0m"
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
                    echo -e "\n❌ \e[1;31mFailed to download or load the Ollama model.\e[0m"
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

        print_info "Ensuring Docker is enabled..."
        sudo systemctl is-enabled docker &>/dev/null || sudo systemctl enable --now docker

        print_info "Pulling Open-WebUI image..."
        sudo docker pull ghcr.io/open-webui/open-webui:main

        print_info "Starting Open-WebUI container..."
        local docker_cmd=(sudo docker run -d --network host --restart always)
        if [[ "$HAS_NVIDIA_GPU" == true ]]; then
            docker_cmd+=(--gpus all)
        fi
        docker_cmd+=(-e OLLAMA_BASE_URL=http://127.0.0.1:11434 -e PORT=8081)
        if [[ "$EXPOSE_LLM_ENGINE" == "y" ]]; then
            docker_cmd+=(-e HOST='0.0.0.0')
            sudo ufw allow 8081/tcp &>/dev/null || true # ufw may not be installed
        fi
        if [[ "$backend_target" == "llama" ]]; then
            print_info "Configuring Open-WebUI to connect to llama.cpp backend..."
            docker_cmd+=(-e OPENAI_API_BASE_URL=http://127.0.0.1:8080/v1 -e OPENAI_API_KEY=sk-llamacpp)
        fi
        docker_cmd+=(-v open-webui:/app/backend/data --name open-webui ghcr.io/open-webui/open-webui:main)

        "${docker_cmd[@]}"
        print_success "Open-WebUI installed and running on network host."

        if [[ "$AUTO_UPDATE_OPENWEBUI" == "y" ]]; then
            print_info "Configuring systemd to auto-update Open-WebUI on boot..."
            sudo bash -c "cat <<EOF > /usr/local/bin/update-open-webui.sh
#!/bin/bash
sudo docker pull ghcr.io/open-webui/open-webui:main
sudo docker stop open-webui 2>/dev/null || true
sudo docker rm open-webui 2>/dev/null || true
${docker_cmd[*]}
EOF"
            sudo chmod +x /usr/local/bin/update-open-webui.sh

            sudo bash -c "cat <<EOF > /etc/systemd/system/open-webui-update.service
[Unit]
Description=Auto-update Open-WebUI Docker Container
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-open-webui.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF"
            sudo systemctl daemon-reload
            sudo systemctl enable open-webui-update.service
            print_success "Open-WebUI auto-update service enabled."
        fi

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

        print_info "Ensuring Docker is enabled..."
        sudo systemctl is-enabled docker &>/dev/null || sudo systemctl enable --now docker

        print_info "Cloning LibreChat repository..."
        sudo -u "$TARGET_USER" bash -c "cd \"$TARGET_USER_HOME\" && git clone https://github.com/danny-avila/LibreChat.git"

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
        if [[ "$INSTALL_LLAMA_SERVICE" == "y" ]]; then
            print_info "⚠️  NOTE: llama.cpp is currently running as a background service!"
            print_info "Before running manually, you MUST stop the service to free up your VRAM:"
            echo -e "\e[1;33msudo systemctl stop llama-server\e[0m\n"
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

    local nvm_cmd="export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\""

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

    print_info "Enabling user lingering to allow services to run after logout..."
    sudo loginctl enable-linger "$TARGET_USER"

    print_info "Starting user systemd instance..."
    sudo systemctl start "user@$(id -u "$TARGET_USER").service"

    print_info "Configuring shell environment for systemd user services..."
    local systemd_env_str
    systemd_env_str=$(
        cat <<'EOF'
# Systemd User Service Environment (Fixes 'su -' DBus errors)
if [ -z "$XDG_RUNTIME_DIR" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
fi
EOF
    )
    if sudo test -f "$TARGET_USER_HOME/.zshrc" && ! sudo grep -q 'DBUS_SESSION_BUS_ADDRESS' "$TARGET_USER_HOME/.zshrc"; then
        echo -e "\n${systemd_env_str}" | sudo tee -a "$TARGET_USER_HOME/.zshrc" >/dev/null
    fi
    if sudo test -f "$TARGET_USER_HOME/.bashrc" && ! sudo grep -q 'DBUS_SESSION_BUS_ADDRESS' "$TARGET_USER_HOME/.bashrc"; then
        echo -e "\n${systemd_env_str}" | sudo tee -a "$TARGET_USER_HOME/.bashrc" >/dev/null
    fi

    if [ -d "/home/linuxbrew/.linuxbrew" ]; then
        print_info "Ensuring Homebrew directories are writable by '$TARGET_USER'..."
        sudo chown -R "$TARGET_USER":"$TARGET_USER" /home/linuxbrew
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
        [ -f "/home/linuxbrew/.linuxbrew/bin/brew" ] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)";

        # Load CUDA paths if they exist
        [ -d "/usr/local/cuda" ] && export CUDA_HOME="/usr/local/cuda";
        [ -d "/usr/local/cuda/bin" ] && export PATH="$CUDA_HOME/bin:$PATH";
        [ -d "/usr/local/cuda/lib64" ] && export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$CUDA_HOME/extras/CUPTI/lib64:$LD_LIBRARY_PATH";

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

        export XDG_RUNTIME_DIR="/run/user/$(id -u)";
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus";
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
        openclaw onboard || true;

        # Only attempt daemon install if onboard actually wrote a config
        if [ -f "$HOME/.openclaw/openclaw.json" ]; then
            echo "";
            echo "✅ OpenClaw onboarding completed — config written.";
            echo "Installing OpenClaw daemon...";
            openclaw daemon install 2>/dev/null || {
                echo "⚠️  Daemon install returned an error — you can retry later with:";
                echo "   openclaw daemon install";
            };
        else
            echo "";
            echo "❌ OpenClaw onboarding did not write a config file.";
            echo "   Run 'openclaw onboard' manually later as the '$USER' user.";
            exit 1;
        fi;
EOF
    )

    # Inject the user's chosen release channel into the heredoc
    openclaw_command="${openclaw_command//__OC_TAG__/$OPENCLAW_RELEASE_CHANNEL}"

    print_info "Switching to '$TARGET_USER' to install and onboard OpenClaw."
    echo -e "\e[1;33mYou will be prompted for the password for user '$TARGET_USER'.\e[0m"

    echo -e "\n\e[1;35m=================================================================\e[0m"
    echo -e "\e[1;36m🤖 OPENCLAW ONBOARDING INSTRUCTIONS\e[0m"
    if [[ "$backend_target" == "llama" ]]; then
        echo -e "When asked for the Model/auth provider, select: \e[1;32mCustom Provider (Any OpenAI or Anthropic compatible endpoint)\e[0m"
        echo -e "When asked for the API Key, enter:              \e[1;32msk-llamacpp\e[0m"
        echo -e "When asked for the Base URL, enter:             \e[1;32mhttp://127.0.0.1:8080/v1\e[0m"
        echo -e "When asked for the Model Name, enter:           \e[1;32mllama\e[0m (or leave blank)"
    elif [[ "$backend_target" == "ollama" ]]; then
        echo -e "When asked for the Model/auth provider, select: \e[1;32mOllama\e[0m"
        echo -e "When asked for the Base URL, enter:             \e[1;32mhttp://127.0.0.1:11434\e[0m"
    else
        echo -e "Select your preferred cloud provider (e.g., OpenAI, Anthropic) and provide your API key."
    fi
    echo -e "\e[1;35m=================================================================\e[0m\n"

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
            echo -e "\e[1;33m⚠️  OpenClaw setup exited with an error (code: $su_exit_code).\e[0m"
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
            echo -e "\n\e[1;36mConfigure & Secure OpenClaw:\e[0m"
            for i in "${!sec_options[@]}"; do
                [[ $i -eq 5 ]] && echo "  ─────────────────────────────────────── Gateway & Access"
                if [[ ${sec_selections[$i]} -eq 1 ]]; then
                    echo -e " \e[1;32m[x]\e[0m $((i + 1)). ${sec_options[$i]}"
                else
                    echo -e " [ ] $((i + 1)). ${sec_options[$i]}"
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
                echo -e "\nInvalid option." && sleep 1
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
        server_lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)

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
        oc_jq_filter="$oc_jq_filter | (.providers // {}) as \$p | if (\$p | keys | map(select(startswith(\"custom-127\"))) | length) > 0 then (.providers[(.providers | keys | map(select(startswith(\"custom-127\"))))[0]].models[0].contextWindow = $oc_ctx) else . end"

        local _jq_out
        _jq_out=$(sudo jq "$oc_jq_filter" "$openclaw_config") || { echo "⚠️  jq filter failed — config not updated." >&2; }
        if [[ -n "$_jq_out" ]] && echo "$_jq_out" | jq empty 2>/dev/null; then
            echo "$_jq_out" | sudo tee "$tmp_json_file" >/dev/null &&
                sudo mv "$tmp_json_file" "$openclaw_config" && sudo chown "$TARGET_USER":"$TARGET_USER" "$openclaw_config"
            print_info "Restarting OpenClaw to apply gateway configuration..."
            sudo -u "$TARGET_USER" bash -c "
                export XDG_RUNTIME_DIR=\"/run/user/\$(id -u)\"
                export DBUS_SESSION_BUS_ADDRESS=\"unix:path=\${XDG_RUNTIME_DIR}/bus\"
                systemctl --user restart openclaw-gateway.service 2>/dev/null || \
                systemctl --user restart openclaw.service 2>/dev/null || true"
        fi
        print_success "OpenClaw gateway configured (bind: $bind_mode, port: $OPENCLAW_PORT, context: $oc_ctx)."

        # UFW for LAN exposure (item 6)
        if [[ "$EXPOSE_OPENCLAW" == "y" ]]; then
            print_info "Configuring firewall rules for OpenClaw (UFW)..."
            sudo ufw allow "$OPENCLAW_PORT"/tcp &>/dev/null || true
            POST_INSTALL_ACTIONS+=("ufw")
            print_success "UFW rule for OpenClaw ($OPENCLAW_PORT) configured."
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
                    sudo mv "$tmp_json_file2" "$openclaw_config" && sudo chown "$TARGET_USER":"$TARGET_USER" "$openclaw_config"
                print_info "Restarting OpenClaw daemon to apply security settings..."
                sudo -u "$TARGET_USER" bash -c "
                    export XDG_RUNTIME_DIR=\"/run/user/\$(id -u)\"
                    export DBUS_SESSION_BUS_ADDRESS=\"unix:path=\${XDG_RUNTIME_DIR}/bus\"
                    systemctl --user restart openclaw-gateway.service 2>/dev/null || \
                    systemctl --user restart openclaw.service 2>/dev/null || true"
                print_success "OpenClaw security settings applied."
            fi
        fi

        # ── Item 8: Allow Insecure Connections ──────────────────────────────
        if [[ ${sec_selections[7]} -eq 1 ]]; then
            print_info "Enabling insecure auth for Control UI..."
            local _oc_nvm_env="export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\"; export PATH=\"$TARGET_USER_HOME/.local/bin:\$PATH\""
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
            print_info "Installing Tailscale..."
            if curl -fsSL https://tailscale.com/install.sh | sh; then
                print_success "Tailscale installed."
            else
                print_info "Tailscale install script failed — trying apt..."
                sudo apt-get update -qq
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale >/dev/null 2>&1 || true
            fi
            echo ""
            print_info "Connecting to Tailscale (you will be shown a login URL to authenticate)..."
            sudo tailscale up || true
            echo ""
            sudo ufw allow in on tailscale0 &>/dev/null || true
            local _oc_svc_file="$TARGET_USER_HOME/.config/systemd/user/openclaw-gateway.service"
            if sudo test -f "$_oc_svc_file"; then
                print_info "Patching OpenClaw service to use 'openclaw gateway --tailscale serve'..."
                sudo sed -i 's/gateway --port [0-9]*/gateway --tailscale serve/' "$_oc_svc_file"
                sudo -u "$TARGET_USER" bash -c "
                    export XDG_RUNTIME_DIR=\"/run/user/\$(id -u)\"
                    export DBUS_SESSION_BUS_ADDRESS=\"unix:path=\${XDG_RUNTIME_DIR}/bus\"
                    systemctl --user daemon-reload
                    systemctl --user restart openclaw-gateway.service 2>/dev/null || \
                    systemctl --user restart openclaw.service 2>/dev/null || true"
                local _ts_ip
                _ts_ip=$(tailscale ip -4 2>/dev/null | head -1 || true)
                print_success "OpenClaw configured for Tailscale serve."
                [[ -n "$_ts_ip" ]] && print_info "Tailscale IP: ${_ts_ip}"
            else
                echo "⚠️  OpenClaw service file not found — Tailscale patch skipped."
            fi
        fi

        # ── Item 5: Deep Security Audit ──────────────────────────────────────
        if [[ ${sec_selections[4]} -eq 1 ]]; then
            print_info "Running OpenClaw Deep Security Audit..."
            local _oc_audit_env="export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\"; export PATH=\"$TARGET_USER_HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:\$PATH\""
            sudo -u "$TARGET_USER" bash -c "$_oc_audit_env; openclaw security audit --deep" ||
                echo -e "⚠️ \e[1;33mAudit returned warnings/errors, please review.\e[0m"
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

    # 1. Zsh (index 1)
    if sudo test -d "$TARGET_USER_HOME/.oh-my-zsh"; then
        print_info "Found existing Oh My Zsh installation."
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
    if [ -f "/home/linuxbrew/.linuxbrew/bin/brew" ]; then
        print_info "Found existing Homebrew installation."
        MASTER_INSTALLED_STATE[5]=1
    fi

    # 6. Gemini CLI (index 6)
    if command -v gemini &>/dev/null; then
        print_info "Found existing Google Gemini CLI installation."
        MASTER_INSTALLED_STATE[6]=1
    fi

    # 7. NVIDIA GPU Driver (index 7)
    if command -v nvidia-smi &>/dev/null; then
        print_info "Found existing NVIDIA driver (nvidia-smi)."
        MASTER_INSTALLED_STATE[7]=1
    fi

    # 8. btop (index 8)
    if command -v btop &>/dev/null; then
        print_info "Found existing btop installation."
        MASTER_INSTALLED_STATE[8]=1
    fi

    # 9. nvtop (index 9)
    if command -v nvtop &>/dev/null; then
        print_info "Found existing nvtop installation."
        MASTER_INSTALLED_STATE[9]=1
    fi

    # 10. CUDA Toolkit (index 10)
    if [ -f "/usr/local/cuda/bin/nvcc" ]; then
        print_info "Found existing CUDA."
        MASTER_INSTALLED_STATE[10]=1
    fi

    # 11. gcc compiler (index 11)
    if command -v gcc &>/dev/null; then
        print_info "Found existing gcc compiler."
        MASTER_INSTALLED_STATE[11]=1
    fi

    # 12. NVIDIA Container Toolkit (index 12)
    if ensure_nvidia_ctk_for_current_shell >/dev/null 2>&1; then
        print_info "Found existing NVIDIA Container Toolkit."
        MASTER_INSTALLED_STATE[12]=1
    fi

    # 13. cuDNN (index 13)
    if has_cudnn_available; then
        print_info "Found existing cuDNN installation."
        MASTER_INSTALLED_STATE[13]=1
    fi

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

    # Verify cuDNN
    if has_cudnn_available; then
        services_checked=1
        print_info "Verifying cuDNN installation..."
        if get_cudnn_library_path >/dev/null 2>&1; then
            print_success "cuDNN shared libraries are loaded and accessible."
        else
            echo "⚠️ cuDNN packages are installed, but libraries are not yet in the ldconfig cache. A reboot may be required."
        fi
    fi

    if [[ $services_checked -eq 0 ]]; then
        print_info "No live background LLM services detected for API verification."
    fi
}

# --- Final Summary ---

print_final_summary() {
    # Ensure newly installed binaries are in the script's PATH for verification
    [ -d "/usr/local/cuda/bin" ] && export PATH="/usr/local/cuda/bin:$PATH"

    # Make array unique by converting to a string, sorting, and converting back
    local unique_actions
    unique_actions=$(echo "${POST_INSTALL_ACTIONS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')

    print_header "Installed Components & Verification"

    echo -e "\e[1;36mInstalled Options:\e[0m"
    for i in "${!MASTER_OPTIONS[@]}"; do
        if [[ ${MASTER_INSTALLED_STATE[$i]} -eq 1 || ${MASTER_SELECTIONS[$i]} -eq 1 ]]; then
            echo "  - ${MASTER_OPTIONS[$i]}"
        fi
    done
    echo ""

    if [[ ${#INSTALLED_COMPONENTS[@]} -gt 0 ]]; then
        echo -e "\e[1;36mNewly Installed Components:\e[0m"
        printf '  - %s\n' "${INSTALLED_COMPONENTS[@]}"
        echo ""
    fi

    if [[ ${#REPAIRED_COMPONENTS[@]} -gt 0 ]]; then
        echo -e "\e[1;36mRepaired Components:\e[0m"
        printf '  - %s\n' "${REPAIRED_COMPONENTS[@]}"
        echo ""
    fi

    if [[ ${#FAILED_COMPONENTS[@]} -gt 0 ]]; then
        echo -e "\e[1;31mComponents That Failed Verification:\e[0m"
        printf '  - %s\n' "${FAILED_COMPONENTS[@]}"
        echo ""
    fi

    # User environment helpers
    local nvm_cmd="export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\""
    local brew_cmd="[ -f /home/linuxbrew/.linuxbrew/bin/brew ] && eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\""

    if sudo test -d "$TARGET_USER_HOME/.oh-my-zsh"; then
        print_info "Zsh / Oh My Zsh:"
        zsh --version || echo "Installed"
        echo ""
    fi

    if command -v python3 &>/dev/null; then
        print_info "Python:"
        python3 --version
        echo ""
    fi

    if command -v docker &>/dev/null; then
        print_info "Docker:"
        docker --version
        echo ""
    fi

    if sudo test -s "$TARGET_USER_HOME/.nvm/nvm.sh"; then
        print_info "Node.js & NPM (via NVM):"
        sudo -u "$TARGET_USER" bash -c "$nvm_cmd; echo -n 'Node: '; node -v; echo -n 'NPM: '; npm -v"
        echo ""
    fi

    if [ -f "/home/linuxbrew/.linuxbrew/bin/brew" ]; then
        print_info "Homebrew:"
        sudo -u "$TARGET_USER" bash -c "$brew_cmd; brew --version | head -n 1"
        echo ""
    fi

    if command -v gemini &>/dev/null; then
        print_info "Google Gemini CLI:"
        echo "Installed at $(command -v gemini)"
        echo ""
    fi

    if command -v nvidia-smi &>/dev/null; then
        print_info "NVIDIA GPU Driver:"
        nvidia-smi --query-gpu=driver_version,name --format=csv,noheader || nvidia-smi
        nvidia-smi -q | grep -i "license" || true # display-only: may not match
        echo ""
    fi

    if command -v btop &>/dev/null; then
        print_info "btop (System Monitor):"
        btop --version | head -n 1
        echo ""
    fi

    if command -v nvtop &>/dev/null; then
        print_info "nvtop (GPU Monitor):"
        nvtop --version
        echo ""
    fi

    if command -v gcc &>/dev/null; then
        print_info "gcc Compiler:"
        gcc --version | head -n 1
        echo ""
    fi

    if command -v nvcc &>/dev/null; then
        print_info "CUDA:"
        nvcc --version
        echo ""
    fi

    if ensure_nvidia_ctk_for_current_shell >/dev/null 2>&1; then
        print_info "NVIDIA Container Toolkit:"
        nvidia-ctk --version
        echo ""
    fi

    if has_cudnn_available; then
        print_info "cuDNN Library:"
        dpkg -l | grep -E 'cudnn|libcudnn'
        echo ""
    fi

    if command -v ollama &>/dev/null; then
        print_info "Ollama:"
        ollama --version
        echo ""
    fi

    if command -v llama-server &>/dev/null; then
        print_info "llama.cpp:"
        echo "llama-server installed at $(command -v llama-server)"
        echo ""
        echo -e "  \e[1;36m-> Service commands:\e[0m"
        echo "     sudo systemctl start   llama-server"
        echo "     sudo systemctl stop    llama-server"
        echo "     sudo systemctl restart llama-server"
        echo "     sudo systemctl status  llama-server"
        echo "     sudo journalctl -u llama-server -f   # follow live logs"
        if systemctl is-active --quiet llama-server 2>/dev/null; then
            echo ""
            echo -e "  \e[1;36m-> To test your live API server from the terminal, run:\e[0m"
            cat <<'EOF'
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
EOF
        fi
        echo ""
    fi

    if sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^open-webui$'; then
        print_info "Open-WebUI (Docker):"
        local webui_status
        webui_status=$(sudo docker inspect -f '{{.State.Status}}' open-webui)
        echo "Status: $webui_status"
        if command -v llama-server &>/dev/null; then
            echo -e "  \e[1;36m-> How to connect Open-WebUI to llama.cpp:\e[0m"
            echo "     1. Open WebUI in your browser (e.g., http://localhost:8081)"
            echo "     2. Go to Profile (bottom left) -> Settings -> Connections"
            echo "     3. Under 'OpenAI API', verify the URL is 'http://127.0.0.1:8080/v1' and Key is 'sk-llamacpp'"
            echo "     4. Click the 'Verify Connection' icon. Your model should automatically load!"
        fi
        echo ""
    fi

    if sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qi 'librechat'; then
        print_info "LibreChat (Docker):"
        local lc_status
        lc_status=$(sudo docker inspect -f '{{.State.Status}}' LibreChat-api 2>/dev/null || echo "Running")
        echo "Status: $lc_status"

        local display_port="$LIBRECHAT_PORT"
        if sudo test -f "$TARGET_USER_HOME/LibreChat/.env"; then
            local real_port
            real_port=$(sudo grep "^PORT=" "$TARGET_USER_HOME/LibreChat/.env" | cut -d'=' -f2 | tr -d '\r')
            if [[ -n "$real_port" ]]; then display_port="$real_port"; fi
        fi

        echo -e "  \e[1;36m-> How to access LibreChat:\e[0m"
        echo "     1. Open LibreChat in your browser (e.g., http://localhost:$display_port)"
        echo "     2. Click 'Register' to create your admin account."
        echo ""
    fi

    local oc_status_bin
    oc_status_bin=$(sudo -u "$TARGET_USER" bash -c \
        "export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\"; command -v openclaw 2>/dev/null || true" 2>/dev/null || true)
    if [[ -n "$oc_status_bin" ]] || sudo test -f "$TARGET_USER_HOME/.local/bin/openclaw"; then
        print_info "OpenClaw:"
        sudo -u "$TARGET_USER" bash -c \
            "export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\"; openclaw --version 2>/dev/null || echo 'Installed'"
        echo ""
    fi

    print_info "System Hostname Resolution:"
    local current_hostname
    current_hostname=$(hostname)
    if hostname -i &>/dev/null; then
        print_success "Hostname '$current_hostname' resolves correctly ($(hostname -i | awk '{print $1}' | head -n 1))."
    else
        echo -e "\e[1;31m⚠️  WARNING: Hostname '$current_hostname' does not resolve.\e[0m"
        echo "   Please add '127.0.1.1 $current_hostname' to your /etc/hosts file to prevent network and sudo delays."
    fi
    echo ""

    if [[ -z "$unique_actions" ]]; then
        return
    fi

    print_header "Next Steps & Important Information"

    local shell_changed=0
    if [[ "$unique_actions" == *"zsh"* ]]; then shell_changed=1; fi

    local path_changed=0
    if [[ "$unique_actions" == *"nvm"* || "$unique_actions" == *"brew"* || "$unique_actions" == *"cuda"* || "$unique_actions" == *"openclaw"* ]]; then path_changed=1; fi

    if [[ "$unique_actions" == *"docker"* ]]; then
        print_info "To use Docker without 'sudo' IMMEDIATELY in this terminal, run: newgrp docker"
        print_info "Otherwise, you must LOG OUT and LOG BACK IN to apply the group change globally."
        print_info "Then, test your installation with: docker run hello-world"
        echo "" # Newline for spacing
    fi

    if [[ $shell_changed -eq 1 ]]; then
        echo -e "\e[1;33mYour default shell has been changed to Zsh.\e[0m"
        echo -e "To start using Zsh and activate all newly installed commands (like nvm, node, gemini), you must either:"
        echo -e "  1. \e[1;32mOpen a NEW terminal window.\e[0m (Recommended)"
        echo -e "  2. OR, if you are logged in as '$TARGET_USER', paste the following command into your current terminal:"
        echo "source $TARGET_USER_HOME/.zshrc"
        echo "" # Newline for spacing
    elif [[ $path_changed -eq 1 ]]; then
        # Determine the correct rc file based on the user's default shell
        local rc_file=""
        if sudo test -f "$TARGET_USER_HOME/.zshrc"; then
            rc_file="$TARGET_USER_HOME/.zshrc"
        elif sudo test -f "$TARGET_USER_HOME/.bashrc"; then
            rc_file="$TARGET_USER_HOME/.bashrc"
        fi
        echo -e "\e[1;33mTo activate newly installed commands for '$TARGET_USER' (like nvm, node, gemini), they must either:\e[0m"
        echo -e "  1. \e[1;32mOpen a NEW terminal window.\e[0m"
        if [[ -n "$rc_file" ]]; then
            echo -e "  2. OR, run the following command in your CURRENT terminal:"
            echo "source ${rc_file}"
        fi
        echo "" # Newline for spacing
    fi

    if [[ "$unique_actions" == *"reboot"* ]]; then
        print_info "A system reboot is highly recommended to ensure all NVIDIA drivers are loaded correctly."
    fi

    # Save clean summary to file at the end of every install run
    save_ai_settings_file
}

# Write a clean, plain-text AI-settings summary to ~/AI-settings.txt
# Called from print_final_summary (after install) and the 's' goal-menu key.
save_ai_settings_file() {
    local out_file="$HOME/AI-settings.txt"
    local _lan_ip
    _lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    local _nvm_cmd="export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\""
    local _brew_cmd="[ -f /home/linuxbrew/.linuxbrew/bin/brew ] && eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\""
    {
        echo "===== Installed Components & Verification ====="
        echo "Generated: $(date)"
        echo "Host:      $(hostname)  (${_lan_ip:-<ip>})"
        echo ""

        # --- Installed options ---
        if [[ ${#MASTER_OPTIONS[@]} -gt 0 ]]; then
            echo "Installed Options:"
            local _found_opt=0
            for _i in "${!MASTER_OPTIONS[@]}"; do
                if [[ ${MASTER_INSTALLED_STATE[$_i]:-0} -eq 1 || ${MASTER_SELECTIONS[$_i]:-0} -eq 1 ]]; then
                    echo "  - ${MASTER_OPTIONS[$_i]}"
                    _found_opt=1
                fi
            done
            [[ $_found_opt -eq 0 ]] && echo "  (none recorded)"
            echo ""
        fi

        if [[ ${#INSTALLED_COMPONENTS[@]} -gt 0 ]]; then
            echo "Newly Installed Components:"
            printf '  - %s\n' "${INSTALLED_COMPONENTS[@]}"
            echo ""
        fi

        if [[ ${#REPAIRED_COMPONENTS[@]} -gt 0 ]]; then
            echo "Repaired Components:"
            printf '  - %s\n' "${REPAIRED_COMPONENTS[@]}"
            echo ""
        fi

        if [[ ${#FAILED_COMPONENTS[@]} -gt 0 ]]; then
            echo "Failed Components:"
            printf '  - %s\n' "${FAILED_COMPONENTS[@]}"
            echo ""
        fi

        # --- Hardware ---
        echo "Hardware:"
        echo "  RAM:  ${SYSTEM_RAM_GB:-?} GB"
        echo "  VRAM: ${GPU_VRAM_GB:-?} GB"
        echo "  GPU:  ${GPU_STATUS:-unknown}"
        echo ""

        # --- Per-component software sections (mirrors print_final_summary) ---
        if sudo test -d "$TARGET_USER_HOME/.oh-my-zsh" && command -v zsh &>/dev/null; then
            echo "Zsh / Oh My Zsh:"
            zsh --version 2>/dev/null || echo "Installed"
            echo ""
        fi

        if command -v python3 &>/dev/null; then
            echo "Python:"
            python3 --version
            echo ""
        fi

        if command -v docker &>/dev/null; then
            echo "Docker:"
            docker --version
            echo ""
        fi

        if sudo test -s "$TARGET_USER_HOME/.nvm/nvm.sh"; then
            echo "Node.js & NPM (via NVM):"
            sudo -u "$TARGET_USER" bash -c "$_nvm_cmd; echo -n 'Node: '; node -v; echo -n 'NPM:  '; npm -v" 2>/dev/null ||
                echo "  (run as $TARGET_USER with NVM loaded)"
            echo ""
        fi

        if [ -f "/home/linuxbrew/.linuxbrew/bin/brew" ]; then
            echo "Homebrew:"
            sudo -u "$TARGET_USER" bash -c "$_brew_cmd; brew --version | head -n 1" 2>/dev/null ||
                echo "  Installed (source $TARGET_USER_HOME/.zshrc to activate)"
            echo ""
        fi

        if command -v gemini &>/dev/null; then
            echo "Google Gemini CLI:"
            echo "Installed at $(command -v gemini)"
            echo ""
        fi

        if command -v nvidia-smi &>/dev/null; then
            echo "NVIDIA GPU Driver:"
            nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>/dev/null || nvidia-smi
            nvidia-smi -q 2>/dev/null | grep -i "license" || true
            echo ""
        fi

        if command -v btop &>/dev/null; then
            echo "btop (System Monitor):"
            btop --version | head -n 1
            echo ""
        fi

        if command -v nvtop &>/dev/null; then
            echo "nvtop (GPU Monitor):"
            nvtop --version
            echo ""
        fi

        if command -v gcc &>/dev/null; then
            echo "gcc Compiler:"
            gcc --version | head -n 1
            echo ""
        fi

        if command -v nvcc &>/dev/null; then
            echo "CUDA:"
            nvcc --version
            echo ""
        fi

        if ensure_nvidia_ctk_for_current_shell >/dev/null 2>&1; then
            echo "NVIDIA Container Toolkit:"
            nvidia-ctk --version 2>/dev/null || echo "Installed"
            echo ""
        fi

        if has_cudnn_available; then
            echo "cuDNN Library:"
            dpkg -l 2>/dev/null | grep -E 'cudnn|libcudnn' || true
            echo ""
        fi

        if command -v ollama &>/dev/null; then
            echo "Ollama:"
            ollama --version 2>/dev/null || echo "Installed"
            echo "API URL: http://127.0.0.1:11434"
            echo "Commands:"
            echo "  sudo systemctl start ollama"
            echo "  sudo systemctl stop  ollama"
            echo ""
        fi

        if command -v llama-server &>/dev/null; then
            echo "llama.cpp:"
            echo "llama-server installed at $(command -v llama-server)"
            echo ""
            echo "  -> Service commands:"
            echo "     sudo systemctl start   llama-server"
            echo "     sudo systemctl stop    llama-server"
            echo "     sudo systemctl restart llama-server"
            echo "     sudo systemctl status  llama-server"
            echo "     sudo journalctl -u llama-server -f   # follow live logs"
            if systemctl is-active --quiet llama-server 2>/dev/null; then
                local _exec_line _llama_args _model_path _model_name _ctx_val _ctk_val _ngl_val
                _exec_line=$(sudo grep -m1 '^ExecStart=' /etc/systemd/system/llama-server.service 2>/dev/null || true)
                _llama_args=$(echo "$_exec_line" | grep -oE 'llama-server.*' | head -1 || true)
                _model_path=$(echo "$_llama_args" | grep -oE -- '--model [^[:space:]]+' | awk '{print $2}' || true)
                [[ -z "$_model_path" ]] && _model_path=$(echo "$_llama_args" | grep -oE -- '--hf-file [^[:space:]]+' | awk '{print $2}' || true)
                [[ -n "$_model_path" ]] && _model_name=$(basename "$_model_path" 2>/dev/null || true)
                _ctx_val=$(echo "$_llama_args" | grep -oE -- '-c [0-9]+' | awk '{print $2}' || true)
                _ctk_val=$(echo "$_llama_args" | grep -oE -- '-ctk [^[:space:]]+' | awk '{print $2}' || true)
                _ngl_val=$(echo "$_llama_args" | grep -oE -- '-ngl [0-9]+' | awk '{print $2}' || true)
                echo ""
                echo "  Running model: ${_model_name:-unknown}"
                [[ -n "$_ctx_val" ]] && echo "  Context:       $_ctx_val tokens"
                [[ -n "$_ctk_val" ]] && echo "  KV cache type: $_ctk_val"
                [[ -n "$_ngl_val" ]] && echo "  GPU layers:    $_ngl_val"
                echo "  API URL:       http://127.0.0.1:8080/v1"
                echo "  API key:       sk-llamacpp"
                echo ""
                echo "  -> To test your live API server from the terminal, run:"
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

        if sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^open-webui$'; then
            echo "Open-WebUI (Docker):"
            local _webui_status
            _webui_status=$(sudo docker inspect -f '{{.State.Status}}' open-webui 2>/dev/null || echo "unknown")
            echo "Status: $_webui_status"
            if command -v llama-server &>/dev/null; then
                echo "  -> How to connect Open-WebUI to llama.cpp:"
                echo "     1. Open WebUI in your browser (e.g., http://localhost:8081)"
                echo "     2. Go to Profile (bottom left) -> Settings -> Connections"
                echo "     3. Under 'OpenAI API', verify URL is 'http://127.0.0.1:8080/v1' and Key is 'sk-llamacpp'"
                echo "     4. Click the 'Verify Connection' icon. Your model should automatically load!"
            fi
            echo ""
        fi

        if sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qi 'librechat'; then
            echo "LibreChat (Docker):"
            local _lc_status _lc_port="${LIBRECHAT_PORT:-3080}"
            _lc_status=$(sudo docker inspect -f '{{.State.Status}}' LibreChat-api 2>/dev/null || echo "Running")
            echo "Status: $_lc_status"
            if sudo test -f "$TARGET_USER_HOME/LibreChat/.env"; then
                local _rp
                _rp=$(sudo grep "^PORT=" "$TARGET_USER_HOME/LibreChat/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '\r')
                [[ -n "$_rp" ]] && _lc_port="$_rp"
            fi
            echo "  -> How to access LibreChat:"
            echo "     URL: http://${_lan_ip:-localhost}:${_lc_port}"
            echo "     1. Open LibreChat in your browser"
            echo "     2. Click 'Register' to create your admin account."
            echo "  Commands:"
            echo "     cd $TARGET_USER_HOME/LibreChat && docker compose up -d    # start"
            echo "     cd $TARGET_USER_HOME/LibreChat && docker compose down      # stop"
            echo ""
        fi

        # --- OpenClaw ---
        local _oc_bin
        _oc_bin=$(sudo -u "$TARGET_USER" bash -c \
            "$_nvm_cmd; command -v openclaw 2>/dev/null || true" 2>/dev/null || true)
        if [[ -n "$_oc_bin" ]] || sudo test -f "$TARGET_USER_HOME/.local/bin/openclaw"; then
            echo "OpenClaw:"
            sudo -u "$TARGET_USER" bash -c \
                "$_nvm_cmd; openclaw --version 2>/dev/null || echo 'Installed'" 2>/dev/null || echo "Installed"

            if sudo test -f "$TARGET_USER_HOME/.openclaw/openclaw.json"; then
                local _oc_port _oc_bind
                _oc_port=$(sudo jq -r '.gateway.port // 18789' "$TARGET_USER_HOME/.openclaw/openclaw.json" 2>/dev/null || echo "18789")
                _oc_bind=$(sudo jq -r '.gateway.bind // "loopback"' "$TARGET_USER_HOME/.openclaw/openclaw.json" 2>/dev/null || echo "loopback")
                echo "  Port:   $_oc_port"
                echo "  Bind:   $_oc_bind"
                echo "  Config: $TARGET_USER_HOME/.openclaw/openclaw.json"
                echo ""
                echo "  -> Service commands (as user $TARGET_USER):"
                echo "     systemctl --user start  openclaw-gateway"
                echo "     systemctl --user stop   openclaw-gateway"
                echo "     systemctl --user status openclaw-gateway"
                echo ""
                echo "  -> Control UI access:"
                echo "     Direct (LAN): http://${_lan_ip:-<server-ip>}:${_oc_port}/"
                echo ""
                echo "     SSH tunnel (from a remote machine):"
                echo "     ssh -L ${_oc_port}:localhost:${_oc_port} [admin-user]@${_lan_ip:-<server-ip>}"
                echo "     Then open:  http://localhost:${_oc_port}/"
                echo ""
                # Try to extract the current session token from today's log
                local _oc_log _oc_token
                _oc_log="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
                _oc_token=""
                if sudo test -f "$_oc_log" 2>/dev/null; then
                    _oc_token=$(sudo grep -oE '#token=[a-f0-9]+' "$_oc_log" 2>/dev/null |
                        tail -1 | sed 's/#token=//' || true)
                fi
                if [[ -n "$_oc_token" ]]; then
                    echo "     Current session token URL:"
                    echo "     http://localhost:${_oc_port}/#token=${_oc_token}"
                    echo "     (Token changes on each service restart)"
                else
                    echo "     Token: run the command below to get the current token:"
                fi
                echo "     sudo -u $TARGET_USER bash -c \\"
                echo "       'XDG_RUNTIME_DIR=/run/user/\$(id -u $TARGET_USER) openclaw status' | grep -i token"
            fi
            echo ""
        fi

        # --- Hostname resolution ---
        echo "System Hostname Resolution:"
        local _hn
        _hn=$(hostname)
        if hostname -i &>/dev/null; then
            echo "  Hostname '$_hn' resolves correctly ($(hostname -i | awk '{print $1}' | head -n 1))."
        else
            echo "  WARNING: Hostname '$_hn' does not resolve."
            echo "  Add '127.0.1.1 $_hn' to /etc/hosts to prevent network and sudo delays."
        fi
        echo ""

        if [[ -n "${TARGET_USER:-}" ]]; then
            echo "Target user: $TARGET_USER  ($TARGET_USER_HOME)"
            echo ""
        fi

        # --- Next steps (mirrors print_final_summary post-install advice) ---
        local _ua=""
        if [[ ${#POST_INSTALL_ACTIONS[@]} -gt 0 ]]; then
            _ua=$(printf '%s\n' "${POST_INSTALL_ACTIONS[@]}" | sort -u | tr '\n' ' ')
        fi
        if [[ -n "$_ua" ]]; then
            echo "===== Next Steps & Important Information ====="
            echo ""
            if [[ "$_ua" == *"docker"* ]]; then
                echo "Docker group change:"
                echo "  To use Docker without 'sudo' immediately: newgrp docker"
                echo "  Or log out and back in to apply the group change globally."
                echo "  Then test: docker run hello-world"
                echo ""
            fi
            if [[ "$_ua" == *"zsh"* ]]; then
                echo "Shell change:"
                echo "  Your default shell was changed to Zsh."
                echo "  Open a new terminal, or run: source $TARGET_USER_HOME/.zshrc"
                echo ""
            elif [[ "$_ua" == *"nvm"* || "$_ua" == *"brew"* || "$_ua" == *"openclaw"* ]]; then
                local _rc=""
                sudo test -f "$TARGET_USER_HOME/.zshrc" && _rc="$TARGET_USER_HOME/.zshrc"
                sudo test -f "$TARGET_USER_HOME/.bashrc" && [[ -z "$_rc" ]] && _rc="$TARGET_USER_HOME/.bashrc"
                echo "To activate newly installed commands for '$TARGET_USER' (like nvm, node, gemini), they must either:"
                echo "  1. Open a NEW terminal window."
                [[ -n "$_rc" ]] && echo "  2. OR, run the following command in your CURRENT terminal:" &&
                    echo "source ${_rc}"
                echo ""
            fi
            if [[ "$_ua" == *"ufw"* ]]; then
                echo "IMPORTANT: Firewall rules have been configured, but UFW is NOT enabled by default."
                echo "The following UFW rules have been prepared:"
                sudo ufw status 2>/dev/null | grep -E 'ALLOW|DENY' | sed 's/^/  - /' || true
                echo "To enable UFW: sudo ufw enable"
                echo ""
            fi
            if [[ "$_ua" == *"reboot"* ]]; then
                echo "Reboot recommended:"
                echo "  A system reboot is recommended to ensure all NVIDIA drivers are loaded correctly."
                echo ""
            fi
        fi
    } >"$out_file"
    print_success "Settings saved → $out_file"
}

# --- Edit llama.cpp Service Parameters ---
#
# Lets the user pick a new model and tune context/memory settings
# on a live llama-server.service installation.  On confirm:
#   1. Stops the running service
#   2. Rewrites /etc/systemd/system/llama-server.service
#   3. systemctl daemon-reload && enable --now
#
edit_llama_server_parameters() {
    # Detect CUDA variant from the existing service unit so we know
    # whether to pass -ngl and --fit.  Check both the Environment= line
    # (newer units) and -ngl in ExecStart (older units that omit the env line).
    local unit_file="/etc/systemd/system/llama-server.service"
    local is_cuda="n"
    if sudo grep -qE 'LD_LIBRARY_PATH.*cuda|-ngl [0-9]' "$unit_file" 2>/dev/null; then
        is_cuda="y"
    fi

    local backend_variant="llama_cpu"
    [[ "$is_cuda" == "y" ]] && backend_variant="llama_cuda"

    # Reset globals so configure_llm_model_prompt starts fresh.
    # Pre-seed ngl/fit from the existing unit file so configure_context_memory
    # shows the current values as defaults in item 6.
    LLM_DEFAULT_MODEL_CHOICE=""
    SELECTED_MODEL_REPO=""
    LLAMACPP_MODEL_REPO=""
    OLLAMA_PULL_MODEL=""
    LLAMA_CTX_SIZE=""
    LLAMA_CACHE_TYPE_K=""
    LLAMA_CACHE_TYPE_V=""
    LLAMA_CPU_MOE="y"
    LLAMA_FLASH_ATTN="n"
    LLAMA_UBATCH=""
    LLAMA_VRAM_TIER=""
    LLAMA_NGL=99
    LLAMA_FIT="n"
    LLAMA_FIT_CTX=""
    LLAMA_COMPONENT_ACTION="repair" # needed so llama_requires_model_selection returns true

    # Pre-fill ngl/fit from the existing unit so the context menu shows current values
    if [[ "$is_cuda" == "y" ]]; then
        local cur_unit_line cur_ngl_hint cur_fit_hint
        cur_unit_line=$(sudo grep -m1 '^ExecStart=' "$unit_file" 2>/dev/null || true)
        cur_ngl_hint=$(echo "$cur_unit_line" | grep -oE -- '-ngl [0-9]+' | awk '{print $2}' || true)
        cur_fit_hint=$(echo "$cur_unit_line" | grep -oE -- '--fit (on|off)' | awk '{print $2}' || true)
        [[ -n "$cur_ngl_hint" ]] && LLAMA_NGL="$cur_ngl_hint"
        [[ "$cur_fit_hint" == "on" ]] && LLAMA_FIT="y"
    fi

    clear
    print_status_header
    echo -e "\n\e[1;36m── Edit llama.cpp Server Parameters ─────────────────────────\e[0m"
    echo -e "Current service unit: \e[0;33m${unit_file}\e[0m"
    echo -e "GPU mode detected:    \e[0;33m${backend_variant}\e[0m"
    echo ""

    # Step 1: model selection (re-uses the same prompt as initial install)
    configure_llm_model_prompt "$backend_variant"
    if [[ -z "$LLM_DEFAULT_MODEL_CHOICE" ]]; then
        echo "No model selected — edit cancelled."
        return 1
    fi

    # Step 2: context, memory, and GPU layers (item 6 in the box for CUDA)
    configure_context_memory "$backend_variant"

    # Step 3: build args from globals set by configure_context_memory
    local hf_args
    hf_args=$(build_llama_hf_args)

    local llama_host_args="--port 8080"
    if [[ "$is_cuda" == "y" ]]; then
        if [[ "$LLAMA_FIT" == "y" ]]; then
            llama_host_args+=" --fit on --fit-ctx ${LLAMA_FIT_CTX}"
        else
            llama_host_args+=" -ngl ${LLAMA_NGL}"
        fi
    fi

    # Replicate the expose-LLM flag from existing unit (keep --host if already set)
    if sudo grep -q -- '--host 0.0.0.0' "$unit_file" 2>/dev/null; then
        llama_host_args+=" --host 0.0.0.0"
    fi

    [[ -n "$LLAMA_CTX_SIZE" ]] && llama_host_args+=" -c $LLAMA_CTX_SIZE"
    [[ -n "$LLAMA_CACHE_TYPE_K" ]] && llama_host_args+=" -ctk $LLAMA_CACHE_TYPE_K"
    [[ -n "$LLAMA_CACHE_TYPE_V" ]] && llama_host_args+=" -ctv $LLAMA_CACHE_TYPE_V"
    [[ "$LLAMA_FLASH_ATTN" == "y" && "$is_cuda" == "y" ]] && llama_host_args+=" --flash-attn on"
    [[ -n "$LLAMA_UBATCH" ]] && llama_host_args+=" --ubatch-size $LLAMA_UBATCH"
    [[ "$LLAMA_CPU_MOE" == "y" ]] && llama_host_args+=" --cpu-moe"

    # Download model if it's an HF repo that isn't already cached
    if [[ "$hf_args" == *"--hf-repo"* ]]; then
        print_info "Checking model cache…"
        local downloaded_model
        downloaded_model=$(download_hf_model_with_progress "$hf_args" "$(get_llama_cache_path)")
        if [[ -n "$downloaded_model" ]]; then
            hf_args="--model $downloaded_model"
        fi
    fi

    # Step 5: confirm before touching the live service
    echo ""
    echo -e "\e[1;36m── Confirm new service configuration ─────────────────────────\e[0m"
    echo -e "  Model args:  \e[0;33m${hf_args}\e[0m"
    echo -e "  Server args: \e[0;33m${llama_host_args}\e[0m"
    echo ""
    read -rp "Apply and restart llama-server? [y/N]: " apply_choice
    if [[ "$apply_choice" != "y" && "$apply_choice" != "Y" ]]; then
        echo "Edit cancelled — service unchanged."
        return 0
    fi

    # Step 6: rewrite the systemd unit
    print_info "Stopping llama-server…"
    sudo systemctl stop llama-server 2>/dev/null || true

    local env_cuda=""
    [[ "$is_cuda" == "y" ]] && env_cuda="Environment=\"LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64\""

    # shellcheck disable=SC2090
    sudo tee "$unit_file" >/dev/null <<EDITEOF
[Unit]
Description=Llama.cpp Server
After=network.target

[Service]
User=$TARGET_USER
WorkingDirectory=$TARGET_USER_HOME
Environment="HOME=$TARGET_USER_HOME"
Environment="TARGET_USER_HOME=$TARGET_USER_HOME"
Environment="LLAMA_CACHE=$(get_llama_cache_path)"
$env_cuda
ExecStart=/bin/bash -c 'source $TARGET_USER_HOME/.env.secrets 2>/dev/null; export HOME="$TARGET_USER_HOME"; export LLAMA_CACHE="$(get_llama_cache_path)"; mkdir -p "$TARGET_USER_HOME/.cache"; exec /usr/local/bin/llama-server $hf_args $llama_host_args >> "$(get_llama_runtime_log_path)" 2>&1'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EDITEOF

    print_info "Reloading systemd daemon and restarting service…"
    sudo systemctl daemon-reload
    sudo systemctl enable --now llama-server
    echo ""
    sudo systemctl status llama-server --no-pager || true
    echo ""

    # Update OpenClaw config to match new context size (if installed)
    local openclaw_config="$TARGET_USER_HOME/.openclaw/openclaw.json"
    if sudo test -f "$openclaw_config" && [[ -n "$LLAMA_CTX_SIZE" ]]; then
        local oc_ctx="$LLAMA_CTX_SIZE"
        [[ "$oc_ctx" -lt 65536 ]] && oc_ctx=65536
        local tmp_oc
        tmp_oc=$(sudo mktemp)
        local oc_jq=".agents.defaults.compaction.reserveTokensFloor = 20000"
        oc_jq="$oc_jq | (.providers // {}) as \$p | if (\$p | keys | map(select(startswith(\"custom-127\"))) | length) > 0 then (.providers[(.providers | keys | map(select(startswith(\"custom-127\"))))[0]].models[0].contextWindow = $oc_ctx) else . end"
        local oc_out
        oc_out=$(sudo jq "$oc_jq" "$openclaw_config") || true
        if [[ -n "$oc_out" ]] && echo "$oc_out" | jq empty 2>/dev/null; then
            echo "$oc_out" | sudo tee "$tmp_oc" >/dev/null &&
                sudo mv "$tmp_oc" "$openclaw_config" &&
                sudo chown "$TARGET_USER":"$TARGET_USER" "$openclaw_config"
            print_success "OpenClaw contextWindow updated to ${oc_ctx}."
        fi
    fi

    print_success "llama.cpp service updated and running."
    return 0
}

# --- Main Menu ---

show_menu() {
    UI_TO_MASTER=()
    local ui_num=1
    local menu_body=""

    for master_index in "${ACTIVE_INDICES[@]}"; do
        # Always hide Oh My Zsh (index 1) — not used in server setup
        if [[ $master_index -eq 1 ]]; then continue; fi

        # Hide NVIDIA options (indices 7, 9 to 13) if no GPU is detected
        if [[ "$HAS_NVIDIA_GPU" == false ]] && [[ $master_index -eq 7 || ($master_index -ge 9 && $master_index -le 13) ]]; then
            continue
        fi

        # Visual grouping
        if [[ $master_index -eq 7 && "$HAS_NVIDIA_GPU" == true ]]; then menu_body+="\n"; fi
        if [[ $master_index -eq 8 && "$HAS_NVIDIA_GPU" == false ]]; then menu_body+="\n"; fi
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

main() {
    check_not_root
    check_sudo_privileges
    start_sudo_keepalive
    check_os

    # ── Detect an interrupted installation from a previous run ───────────────
    # If the state file exists but --resume wasn't passed, offer to pick up
    # where the last run left off (e.g. after a post-NVIDIA-driver reboot).
    if [[ "$RESUME_MODE" == false && -f "$RESUME_STATE_FILE" ]]; then
        echo ""
        echo -e "\e[1;36m🔄 Detected a previous interrupted installation.\e[0m"
        local _resume_choice
        read -p "Resume where it left off? [Y/n]: " _resume_choice
        if [[ "${_resume_choice:-Y}" == "Y" || "${_resume_choice:-Y}" == "y" ]]; then
            RESUME_MODE=true
        else
            echo -e "Starting fresh — discarding previous state."
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
        echo -e "\e[1;36m🔄 Resuming ubuntu-prep-setup.sh after reboot...\e[0m"
        # shellcheck source=/dev/null
        source "$RESUME_STATE_FILE"

        # Restore global arrays from space-separated strings
        read -ra MASTER_SELECTIONS <<<"$RESUME_SELECTIONS"
        read -ra MASTER_INSTALLED_STATE <<<"$RESUME_COMPLETED"
        read -ra ACTIVE_INDICES <<<"$RESUME_ACTIVE"

        # Restore config variables
        TARGET_USER="$RESUME_TARGET_USER"
        TARGET_USER_HOME="$RESUME_TARGET_USER_HOME"
        IS_DIFFERENT_USER="$RESUME_IS_DIFFERENT_USER"
        HAS_NVIDIA_GPU="$RESUME_HAS_NVIDIA_GPU"
        LLM_BACKEND_CHOICE="${RESUME_LLM_BACKEND_CHOICE:-}"
        FRONTEND_BACKEND_TARGET="${RESUME_FRONTEND_BACKEND_TARGET:-}"
        LLAMA_CTX_SIZE="${RESUME_LLAMA_CTX_SIZE:-65536}"
        LOAD_DEFAULT_MODEL="${RESUME_LOAD_DEFAULT_MODEL:-n}"
        RUN_LLAMA_BENCH="${RESUME_RUN_LLAMA_BENCH:-n}"
        INSTALL_LLAMA_SERVICE="${RESUME_INSTALL_LLAMA_SERVICE:-n}"
        EXPOSE_LLM_ENGINE="${RESUME_EXPOSE_LLM_ENGINE:-n}"
        INSTALL_OPENWEBUI="${RESUME_INSTALL_OPENWEBUI:-n}"
        INSTALL_LIBRECHAT="${RESUME_INSTALL_LIBRECHAT:-n}"
        LLAMACPP_MODEL_REPO="${RESUME_LLAMACPP_MODEL_REPO:-}"
        OLLAMA_PULL_MODEL="${RESUME_OLLAMA_PULL_MODEL:-}"
        OPENCLAW_RELEASE_CHANNEL="${RESUME_OPENCLAW_RELEASE_CHANNEL:-latest}"
        EXPOSE_OPENCLAW="${RESUME_EXPOSE_OPENCLAW:-n}"
        OPENCLAW_PORT="${RESUME_OPENCLAW_PORT:-18789}"

        echo -e "  Restored selections: [${MASTER_SELECTIONS[*]}]"
        echo -e "  Already completed:   [${MASTER_INSTALLED_STATE[*]}]"
        echo -e "  Target user:         $TARGET_USER"
        echo ""
        detect_gpu # re-detect GPU (now loaded after reboot)
        setup_env_secrets
        # Jump straight to installation — skip all menus
    else
        determine_target_user
        detect_gpu

        clear
        print_status_header
        configure_timezone
    fi

    local MASTER_OPTIONS=(
        "Update System Packages (apt update && upgrade)"
        "Install Oh My Zsh & Dev Tools (git, tmux, micro)"
        "Install Python Environment"
        "Install Docker and Docker Compose"
        "Install NVM, Node.js & NPM"
        "Install Homebrew"
        "Install Google Gemini CLI"
        "Install NVIDIA GPU Driver"
        "Install btop (System Monitor)"
        "Install nvtop (GPU Monitor)"
        "Install CUDA"
        "Install gcc compiler"
        "Install NVIDIA Container Toolkit"
        "Install cuDNN"
        "Install Local LLM Support (Ollama, llama.cpp, Open-WebUI)"
        "Install OpenClaw"
    )

    local MASTER_FUNCS=(
        update_system
        install_zsh
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
            mapfile -t ACTIVE_INDICES < <(printf '%s\n' "${ACTIVE_INDICES[@]}" | sort -n)
        fi
    }

    # Declarative dependency map: "required_idx dependent_idx [dependent_idx ...]"
    # Read as: required_idx must be installed whenever any listed dependent_idx is selected.
    # Also encodes reverse: deselecting required_idx cascades to deselect dependents.
    # Format per entry: "req dep1 dep2 ..."
    local -a DEP_MAP=(
        "4 6 15"     # NVM(4)      <- Gemini(6), OpenClaw(15)
        "5 15"       # Homebrew(5) <- OpenClaw(15)
        "3 12"       # Docker(3)   <- NVIDIA CTK(12)
        "7 10 12 13" # NV driver(7) <- CUDA(10), CTK(12), cuDNN(13)
        "10 13"      # CUDA(10)    <- cuDNN(13)
        "11 10"      # gcc(11)     <- CUDA(10)
    )

    # Dependency labels for user messages
    dep_label() {
        case "$1" in
            3) echo "Docker" ;;
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
            6) echo "Gemini CLI" ;;
            10) echo "CUDA Toolkit" ;;
            12) echo "NVIDIA Container Toolkit" ;;
            13) echo "cuDNN" ;;
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
                    echo -e "\n[Auto-unselected] ${joined%, } requires $(dep_label "$req")." && sleep 1.5
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
            echo -e "\n[Auto-selected] ${joined%, } required by $(dep_label_for "$toggled")." && sleep 1.5
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
                echo -e "\n\e[1;33m[Validation Fix]\e[0m $(dep_label "$req") auto-added (required dependency)."
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
            echo -e "\n\e[1;36mSelect Installation Goals:\e[0m"
            for i in "${!GOAL_OPTIONS[@]}"; do
                if [[ ${GOAL_SELECTIONS[$i]} -eq 1 ]]; then
                    echo -e " \e[1;32m[x]\e[0m $((i + 1)). ${GOAL_OPTIONS[$i]}"
                else
                    echo -e " [ ] $((i + 1)). ${GOAL_OPTIONS[$i]}"
                fi
            done
            echo "---------------------------------"
            echo "Use numbers [1-3] to toggle a goal. Press 'a' to select all."
            echo "Press 'c' to continue to the detailed menu, or 'q' to quit."
            if systemctl list-unit-files 2>/dev/null | grep -q '^llama-server.service'; then
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
                if systemctl list-unit-files 2>/dev/null | grep -q '^llama-server.service'; then
                    edit_llama_server_parameters
                    echo ""
                    read -p "Press Enter to return to the menu…" _
                else
                    echo -e "\nllama-server.service is not installed." && sleep 1
                fi
            elif [[ "$goal_choice" == "c" || "$goal_choice" == "C" ]]; then
                if [[ ${GOAL_SELECTIONS[0]} -eq 0 && ${GOAL_SELECTIONS[1]} -eq 0 && ${GOAL_SELECTIONS[2]} -eq 0 ]]; then
                    echo -e "\nPlease select at least one goal before continuing." && sleep 1
                else
                    break
                fi
            elif [[ "$goal_choice" == "q" || "$goal_choice" == "Q" ]]; then
                echo -e "\nExiting."
                exit 0
            else
                echo -e "\nInvalid option." && sleep 1
            fi
        done

        if [[ ${GOAL_SELECTIONS[0]} -eq 1 ]]; then ACTIVE_INDICES+=(2 3 4 5 6 15); fi
        if [[ ${GOAL_SELECTIONS[1]} -eq 1 ]]; then ACTIVE_INDICES+=(7 8 9 10 11 12 13); fi
        if [[ ${GOAL_SELECTIONS[2]} -eq 1 ]]; then ACTIVE_INDICES+=(14); fi

        mapfile -t ACTIVE_INDICES < <(printf '%s\n' "${ACTIVE_INDICES[@]}" | sort -n)

        check_installations

        while true; do
            show_menu
            read -p "Your choice: " choice

            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#UI_TO_MASTER[@]} ]; then
                local master_index=${UI_TO_MASTER[$choice]}

                if [[ $master_index -eq 0 ]]; then
                    echo -e "\nSystem Update is required and cannot be deselected." && sleep 1.5
                    continue
                fi

                if [[ ${MASTER_INSTALLED_STATE[$master_index]} -eq 1 && $master_index -ne 14 && $master_index -ne 15 ]]; then
                    echo -e "\nOption $((choice)) is already installed." && sleep 1
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
                        echo -e "\n[Auto-selected] ${auto_selected%, } required for Local LLM Stack components." && sleep 2
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
                echo -e "\n[Info] 'Select all' skips Local LLM Support and OpenClaw because they require explicit repair/install choices." && sleep 2
            elif [[ "$choice" == "i" || "$choice" == "I" ]]; then
                break
            elif [[ "$choice" == "q" || "$choice" == "Q" ]]; then
                echo -e "\nExiting."
                exit 0
            else
                echo -e "\nInvalid option." && sleep 1
            fi
        done

        # --- Final Pre-Installation Dependency Validation ---

        # LLM Stack (14) has runtime-conditional deps that depend on sub-choices
        # made inside the LLM config dialog — handle these before the static map pass.
        if [[ ${MASTER_SELECTIONS[14]} -eq 1 ]]; then
            if [[ ("$OPENWEBUI_COMPONENT_ACTION" == "install" || "$LIBRECHAT_COMPONENT_ACTION" == "install") && ${MASTER_SELECTIONS[3]} -eq 0 && ${MASTER_INSTALLED_STATE[3]} -eq 0 ]]; then
                MASTER_SELECTIONS[3]=1
                ensure_active_index 3
                echo -e "\n\e[1;33m[Validation Fix]\e[0m Docker auto-added as it is required by Open-WebUI/LibreChat."
            fi
            if [[ "$LLAMA_COMPONENT_ACTION" == "install" && "$LLM_BACKEND_CHOICE" == "llama_cuda" && "$HAS_NVIDIA_GPU" == true && ${MASTER_SELECTIONS[10]} -eq 0 && ${MASTER_INSTALLED_STATE[10]} -eq 0 ]]; then
                MASTER_SELECTIONS[10]=1
                ensure_active_index 10
                echo -e "\n\e[1;33m[Validation Fix]\e[0m CUDA auto-added as it is required by llama.cpp (CUDA backend)."
            fi
            if [[ (("$OPENWEBUI_COMPONENT_ACTION" == "install") || ("$LLAMA_COMPONENT_ACTION" == "install" && "$LLM_BACKEND_CHOICE" == "llama_cuda")) && "$HAS_NVIDIA_GPU" == true && ${MASTER_SELECTIONS[12]} -eq 0 && ${MASTER_INSTALLED_STATE[12]} -eq 0 ]]; then
                MASTER_SELECTIONS[12]=1
                ensure_active_index 12
                echo -e "\n\e[1;33m[Validation Fix]\e[0m NVIDIA Container Toolkit auto-added as it is required by your LLM/GPU setup."
            fi
        fi

        # Static dependency map pass — catches anything not resolved during menu interaction
        local validation_changed=0
        validate_deps && validation_changed=0 || validation_changed=1

        if [[ $validation_changed -eq 1 ]]; then
            echo -e "\e[1;36mDependencies resolved. Proceeding with installation...\e[0m"
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
            echo -e "\n\e[1;31m⚠️  WARNING: Low Disk Space\e[0m"
            echo -e "You have selected options that require approximately \e[1;33m${required_gb}GB\e[0m of free space."
            echo -e "Your target partition ($TARGET_USER_HOME) only has \e[1;31m${free_space_gb}GB\e[0m available."
            read -p "Do you want to proceed anyway? [y/N]: " proceed_space
            if [[ "$proceed_space" != "y" && "$proceed_space" != "Y" ]]; then
                echo -e "\n❌ Aborting installation to prevent disk exhaustion."
                exit 1
            fi
        else
            print_success "Disk space check passed (Required: ~${required_gb}GB, Available: ${free_space_gb}GB)."
        fi

        # --- RAM / Memory Check ---
        if [[ ${MASTER_SELECTIONS[14]} -eq 1 ]]; then
            print_info "Checking available system memory for LLM inference..."
            local total_ram_kb
            total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
            local total_ram_gb=$((total_ram_kb / 1024 / 1024))

            if [[ "$total_ram_gb" -lt 16 ]]; then
                echo -e "\n\e[1;31m⚠️  WARNING: Low System Memory\e[0m"
                echo -e "You selected the Local LLM Stack, which generally requires at least \e[1;33m16GB\e[0m of RAM."
                echo -e "Your system only has \e[1;31m${total_ram_gb}GB\e[0m of total memory."
                read -p "Do you want to proceed anyway? Performance may be degraded. [y/N]: " proceed_ram
                if [[ "$proceed_ram" != "y" && "$proceed_ram" != "Y" ]]; then
                    echo -e "\n❌ Aborting installation to prevent system instability."
                    exit 1
                fi
            else
                print_success "Memory check passed (${total_ram_gb}GB total RAM available)."
            fi
        fi
    fi # end: if [[ "$RESUME_MODE" == false ]]

    # Configure API keys after menu selection, before installation tasks begin
    setup_env_secrets

    echo -e "\n--- Starting Installation ---"
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

                # ── Reboot checkpoint after NVIDIA driver (index 7) ──────────────
                # CUDA (10), Container Toolkit (12), cuDNN (13), and LLM (14) all
                # need the kernel module loaded AND nvidia-smi functional. On
                # passthrough VMs the GPU is not visible until ESXi params are set
                # and the system reboots. Pause here and resume automatically.
                if [[ $i -eq 7 && "${POST_INSTALL_ACTIONS[*]}" == *"reboot"* ]]; then
                    local _gpu_pending=0
                    local _gpi
                    for _gpi in 10 12 13 14; do
                        if [[ ${MASTER_SELECTIONS[$_gpi]:-0} -eq 1 && ${MASTER_INSTALLED_STATE[$_gpi]:-0} -eq 0 ]]; then
                            _gpu_pending=1
                            break
                        fi
                    done
                    if [[ $_gpu_pending -eq 1 ]]; then
                        echo ""
                        echo -e "\e[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
                        echo -e "\e[1;33m  NVIDIA driver installed — reboot required before GPU stack.\e[0m"
                        echo -e "\e[1;36m  Remaining GPU components will resume automatically after reboot.\e[0m"
                        if systemd-detect-virt --quiet 2>/dev/null; then
                            echo -e "\e[1;33m  ⚠️  ESXi VM: configure PCIe passthrough params in vSphere FIRST.\e[0m"
                        fi
                        echo -e "\e[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
                        save_resume_state
                        echo -e "\e[1;36m  ✅ Progress saved. After reboot, just re-run this script — it will\e[0m"
                        echo -e "\e[1;36m     offer to continue automatically from where it left off.\e[0m"
                        local _rbc
                        read -p "Reboot now? [Y/n]: " _rbc
                        if [[ "${_rbc:-Y}" == "Y" || "${_rbc:-Y}" == "y" ]]; then
                            print_info "Rebooting..."
                            sudo reboot
                            exit 0
                        fi
                        echo -e "\e[1;33m⚠️  Skipping reboot — GPU installs may fail without the kernel module.\e[0m"
                    fi
                fi
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
                echo -e "\n\e[1;36mSelect Services to Expose to the Network (Bind to 0.0.0.0):\e[0m"
                for i in "${!EXPOSE_OPTIONS[@]}"; do
                    if [[ ${EXPOSE_SELECTIONS[$i]} -eq 1 ]]; then
                        echo -e " \e[1;32m[x]\e[0m $((i + 1)). ${EXPOSE_OPTIONS[$i]}"
                    else
                        echo -e " [ ] $((i + 1)). ${EXPOSE_OPTIONS[$i]}"
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
                    echo -e "\nInvalid option." && sleep 1
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
                                    sudo mv "$tmp_json" "$oc_conf" && sudo chown "$TARGET_USER":"$TARGET_USER" "$oc_conf"
                            fi
                            sudo ufw allow $current_oc_port/tcp &>/dev/null || true
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

        if [[ "${POST_INSTALL_ACTIONS[*]}" == *"ufw"* || -n "$exposed_msg" || "$ENABLE_UFW_AUTOMATICALLY" == "y" ]]; then
            echo -e "\n\e[1;33mIMPORTANT: Firewall rules have been configured, but UFW is NOT enabled by default.\e[0m"
            echo -e "\e[1;36mThe following UFW rules have been prepared:\e[0m"
            echo "  - ALLOW 22/tcp (SSH)"
            if [[ "$exposed_msg" == *"OpenClaw Gateway"* ]]; then echo "  - ALLOW $current_oc_port/tcp (OpenClaw Gateway)"; fi
            if [[ "$EXPOSE_LLM_ENGINE" == "y" ]]; then
                if [[ "$exposed_llm_backend" == "ollama" ]]; then echo "  - ALLOW 11434/tcp (Ollama API)"; else echo "  - ALLOW 8080/tcp (llama.cpp Server)"; fi
            fi
            if [[ "$INSTALL_OPENWEBUI" == "y" ]]; then echo "  - ALLOW 8081/tcp (Open-WebUI)"; fi
            if [[ "$INSTALL_LIBRECHAT" == "y" ]]; then echo "  - ALLOW $LIBRECHAT_PORT/tcp (LibreChat)"; fi
            echo ""

            local enable_ufw="n"
            if [[ "$ENABLE_UFW_AUTOMATICALLY" == "y" ]]; then
                print_info "Auto-enabling UFW firewall as selected in the configuration menu..."
                enable_ufw="y"
            else
                read -p "Do you want to enable the UFW firewall now? (WARNING: Ensure SSH access is allowed if remote) [y/N]: " enable_ufw </dev/tty
            fi

            if [[ "$enable_ufw" == "y" || "$enable_ufw" == "Y" ]]; then
                sudo ufw default deny incoming &>/dev/null || true                                                    # ufw may not be installed
                sudo ufw allow 22/tcp &>/dev/null || true                                                             # ufw may not be installed
                if [[ "$INSTALL_LIBRECHAT" == "y" ]]; then sudo ufw allow $LIBRECHAT_PORT/tcp &>/dev/null || true; fi # ufw may not be installed
                sudo ufw --force enable
                print_success "UFW firewall enabled."
            else
                print_info "UFW remains disabled. You can enable it later with: sudo ufw enable"
            fi
        fi

        echo -e "\n\e[1;32m================================================================\e[0m"
        echo -e "\e[1;32mINSTALLATION COMPLETE!\e[0m"
        if [[ -n "$exposed_msg" ]]; then
            echo -e "\n\e[1;36mNetwork Services Exposed:\e[0m"
            echo -e "$exposed_msg"
        fi
        if [[ "$IS_DIFFERENT_USER" == true ]]; then
            echo -e "\e[1;33mPlease switch to your new user (\e[1;36m$TARGET_USER\e[1;33m) and run the following command to activate your environment:\e[0m"
            echo -e "\e[1;36msu - $TARGET_USER\e[0m"
        else
            echo -e "\e[1;33mPlease run the following command to activate your new environment:\e[0m"
        fi
        if sudo test -f "$TARGET_USER_HOME/.zshrc" && [[ "$SHELL" == *"zsh"* || "${MASTER_SELECTIONS[1]}" == "1" || "${MASTER_INSTALLED_STATE[1]}" == "1" ]]; then
            echo -e "\e[1;36msource ~/.zshrc\e[0m"
        else
            echo -e "\e[1;36msource ~/.bashrc\e[0m"
        fi
        echo -e "\e[1;32m================================================================\e[0m\n"
    else
        print_info "No options were selected for installation."
    fi

    if [[ "${POST_INSTALL_ACTIONS[*]}" == *"reboot"* ]]; then
        # Determine whether any selected items still need to run after the reboot
        # (e.g. NVIDIA Container Toolkit was skipped because the kernel module wasn't loaded yet).
        local _pending_after_reboot=0
        for i in "${!MASTER_SELECTIONS[@]}"; do
            if [[ ${MASTER_SELECTIONS[$i]} -eq 1 && ${MASTER_INSTALLED_STATE[$i]} -eq 0 ]]; then
                _pending_after_reboot=1
                break
            fi
        done

        echo -e "\n\e[1;33mA system reboot is required to activate the NVIDIA kernel module.\e[0m"
        if [[ $_pending_after_reboot -eq 1 ]]; then
            echo -e "\e[1;36m  The following components need the NVIDIA module and will continue automatically after reboot:\e[0m"
            for i in "${!MASTER_SELECTIONS[@]}"; do
                if [[ ${MASTER_SELECTIONS[$i]} -eq 1 && ${MASTER_INSTALLED_STATE[$i]} -eq 0 ]]; then
                    echo -e "    • ${MASTER_OPTIONS[$i]}"
                fi
            done
            echo ""
        fi
        read -p "Do you want to reboot now? [y/N]: " reboot_choice
        if [[ "$reboot_choice" == "y" || "$reboot_choice" == "Y" ]]; then
            if [[ $_pending_after_reboot -eq 1 ]]; then
                save_resume_state
                echo -e "\e[1;32m✅ Progress saved. After reboot, re-run this script — it will offer to\e[0m"
                echo -e "\e[1;32m   continue from where it left off.\e[0m"
                sleep 2
            fi
            print_info "Rebooting system..."
            sudo reboot
        elif [[ $_pending_after_reboot -eq 1 ]]; then
            echo -e "\n\e[1;33m⚠️  Some components still need to be installed.\e[0m"
            echo -e "    Reboot when ready, then re-run this script to continue."
        fi
    fi
}

# ── Resume-after-reboot helpers ───────────────────────────────────────────────

# Write current installation state to disk so it can be restored after reboot.
# Also records all config variables that drive install functions.
save_resume_state() {
    sudo mkdir -p "$(dirname "$RESUME_STATE_FILE")"
    sudo tee "$RESUME_STATE_FILE" >/dev/null <<EOF
# ubuntu-prep-setup.sh resume state — written $(date)
# Sourced by the script when invoked with --resume.

RESUME_SELECTIONS="${MASTER_SELECTIONS[*]}"
RESUME_COMPLETED="${MASTER_INSTALLED_STATE[*]}"
RESUME_ACTIVE="${ACTIVE_INDICES[*]}"

# User / environment
RESUME_TARGET_USER="${TARGET_USER}"
RESUME_TARGET_USER_HOME="${TARGET_USER_HOME}"
RESUME_IS_DIFFERENT_USER="${IS_DIFFERENT_USER}"
RESUME_HAS_NVIDIA_GPU="${HAS_NVIDIA_GPU}"

# LLM config
RESUME_LLM_BACKEND_CHOICE="${LLM_BACKEND_CHOICE:-}"
RESUME_FRONTEND_BACKEND_TARGET="${FRONTEND_BACKEND_TARGET:-}"
RESUME_LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-65536}"
RESUME_LOAD_DEFAULT_MODEL="${LOAD_DEFAULT_MODEL:-n}"
RESUME_RUN_LLAMA_BENCH="${RUN_LLAMA_BENCH:-n}"
RESUME_INSTALL_LLAMA_SERVICE="${INSTALL_LLAMA_SERVICE:-n}"
RESUME_EXPOSE_LLM_ENGINE="${EXPOSE_LLM_ENGINE:-n}"
RESUME_INSTALL_OPENWEBUI="${INSTALL_OPENWEBUI:-n}"
RESUME_INSTALL_LIBRECHAT="${INSTALL_LIBRECHAT:-n}"
RESUME_LLAMACPP_MODEL_REPO="${LLAMACPP_MODEL_REPO:-}"
RESUME_OLLAMA_PULL_MODEL="${OLLAMA_PULL_MODEL:-}"

# OpenClaw config
RESUME_OPENCLAW_RELEASE_CHANNEL="${OPENCLAW_RELEASE_CHANNEL:-latest}"
RESUME_EXPOSE_OPENCLAW="${EXPOSE_OPENCLAW:-n}"
RESUME_OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"

# Script path (so the service can re-run the right file)
RESUME_SCRIPT_PATH="$(realpath "$0")"
EOF
    sudo chmod 600 "$RESUME_STATE_FILE"
    print_info "Resume state saved to $RESUME_STATE_FILE"
}

# Install a oneshot systemd service that re-runs this script with --resume
# once on the next boot, then disables itself.
install_resume_service() {
    local script_path
    script_path=$(realpath "$0")
    sudo tee /etc/systemd/system/ubuntu-prep-resume.service >/dev/null <<EOF
[Unit]
Description=Ubuntu Prep Setup — Resume after reboot
After=network-online.target
Wants=network-online.target
# Run once then disable
ConditionPathExists=${RESUME_STATE_FILE}

[Service]
Type=oneshot
# Run as root so sudo commands inside the script work
ExecStart=/bin/bash ${script_path} --resume
ExecStartPost=/bin/systemctl disable ubuntu-prep-resume.service
StandardOutput=journal+console
StandardError=journal+console
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable ubuntu-prep-resume.service
    print_info "Resume service installed — script will continue automatically after reboot."
}

# Remove resume state file and service after a successful full run.
clear_resume_state() {
    if [[ -f "$RESUME_STATE_FILE" ]]; then
        sudo rm -f "$RESUME_STATE_FILE"
        print_info "Resume state cleared."
    fi
    if systemctl list-unit-files ubuntu-prep-resume.service &>/dev/null; then
        sudo systemctl disable ubuntu-prep-resume.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/ubuntu-prep-resume.service
        sudo systemctl daemon-reload 2>/dev/null || true
    fi
}

# --- Script Entry Point ---
main
