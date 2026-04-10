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

# Global error handler to clean up dangling temporary configurations if the script crashes
cleanup_on_error() {
    local exit_code=$?
    local line_no=$1
    echo -e "\n\e[1;31m❌ ERROR: Script failed unexpectedly at line $line_no (Exit code: $exit_code)\e[0m"
    echo -e "\e[1;33mPerforming emergency cleanup...\e[0m"
    
    if [[ -n "$TARGET_USER" && -f "/etc/sudoers.d/99-temp-$TARGET_USER" ]]; then
        sudo rm -f "/etc/sudoers.d/99-temp-$TARGET_USER"
        echo "Revoked temporary sudo privileges for $TARGET_USER."
    fi
    
    echo -e "Please check the error message above to troubleshoot."
}
trap 'cleanup_on_error ${LINENO}' ERR

# Global array to track post-installation actions
POST_INSTALL_ACTIONS=()

# Global vars for target user
TARGET_USER=""
TARGET_USER_HOME=""
IS_DIFFERENT_USER=false
HAS_NVIDIA_GPU=false
GPU_STATUS=""
LLM_BACKEND_CHOICE=""
INSTALL_OPENWEBUI="n"
EXPOSE_LLM_ENGINE="n"
EXPOSE_OPENCLAW="n"
OPENCLAW_PORT="18789"
EXPOSE_LLAMA_SERVER="n"
LOAD_DEFAULT_MODEL="n"
LLM_DEFAULT_MODEL_CHOICE=""
SELECTED_MODEL_REPO=""
ENABLE_UFW_AUTOMATICALLY="n"

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
            8)  REC_MODEL_CHAT="gemma4:e4b"
                REC_MODEL_CODE="qwen2.5-coder:7b"
                REC_MODEL_MOE="gemma4:e4b"
                REC_MODEL_VISION="gemma4:e4b" ;;
            16) REC_MODEL_CHAT="gemma4:e4b"
                REC_MODEL_CODE="qwen2.5-coder:14b"
                REC_MODEL_MOE="mixtral:8x7b"
                REC_MODEL_VISION="llava:13b" ;;
            24) REC_MODEL_CHAT="gemma4:26b-a4b"
                REC_MODEL_CODE="qwen2.5-coder:32b"
                REC_MODEL_MOE="gemma4:26b-a4b"
                REC_MODEL_VISION="llava:34b" ;;
            32) REC_MODEL_CHAT="gemma4:26b-a4b"
                REC_MODEL_CODE="qwen2.5-coder:32b"
                REC_MODEL_MOE="gemma4:26b-a4b"
                REC_MODEL_VISION="gemma4:31b" ;;
            48) REC_MODEL_CHAT="gemma4:31b"
                REC_MODEL_CODE="qwen2.5:72b"
                REC_MODEL_MOE="gemma4:26b-a4b"
                REC_MODEL_VISION="gemma4:31b" ;;
            72) REC_MODEL_CHAT="gemma4:31b"
                REC_MODEL_CODE="qwen2.5:72b"
                REC_MODEL_MOE="command-r-plus"
                REC_MODEL_VISION="llava:34b" ;;
            96) REC_MODEL_CHAT="gemma4:31b"
                REC_MODEL_CODE="qwen2.5-coder:32b"
                REC_MODEL_MOE="command-r-plus"
                REC_MODEL_VISION="llava:34b" ;;
        esac
    else

    # Edit this function to quickly update the default models offered for LLama.CPP
        case "$vram" in
            8)  REC_MODEL_CHAT="unsloth/gemma-4-E4B-it-GGUF"
                REC_MODEL_CODE="Qwen/Qwen2.5-Coder-7B-Instruct-GGUF"
                REC_MODEL_MOE="unsloth/gemma-4-E4B-it-GGUF"
                REC_MODEL_VISION="unsloth/gemma-4-E4B-it-GGUF" ;;
            16) REC_MODEL_CHAT="unsloth/gemma-4-E4B-it-GGUF"
                REC_MODEL_CODE="Qwen/Qwen2.5-Coder-14B-Instruct-GGUF"
                REC_MODEL_MOE="unsloth/Mixtral-8x7B-Instruct-v0.1-GGUF"
                REC_MODEL_VISION="cjpais/llava-v1.6-vicuna-13b-gguf" ;;
            24) REC_MODEL_CHAT="unsloth/gemma-4-26B-A4B-it-GGUF"
                REC_MODEL_CODE="Qwen/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="unsloth/gemma-4-26B-A4B-it-GGUF"
                REC_MODEL_VISION="cjpais/llava-v1.6-34B-gguf" ;;
            32) REC_MODEL_CHAT="unsloth/gemma-4-26B-A4B-it-GGUF"
                REC_MODEL_CODE="Qwen/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="unsloth/gemma-4-26B-A4B-it-GGUF"
                REC_MODEL_VISION="unsloth/gemma-4-31B-it-GGUF" ;;
            48) REC_MODEL_CHAT="unsloth/gemma-4-31B-it-GGUF"
                REC_MODEL_CODE="Qwen/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="unsloth/gemma-4-26B-A4B-it-GGUF"
                REC_MODEL_VISION="unsloth/gemma-4-31B-it-GGUF" ;;
            72) REC_MODEL_CHAT="unsloth/gemma-4-31B-it-GGUF"
                REC_MODEL_CODE="Qwen/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="unsloth/c4ai-command-r-plus-GGUF"
                REC_MODEL_VISION="cjpais/llava-v1.6-34B-gguf" ;;
            96) REC_MODEL_CHAT="unsloth/gemma-4-31B-it-GGUF"
                REC_MODEL_CODE="Qwen/Qwen2.5-Coder-32B-Instruct-GGUF"
                REC_MODEL_MOE="unsloth/c4ai-command-r-plus-GGUF"
                REC_MODEL_VISION="cjpais/llava-v1.6-34B-gguf" ;;
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
    echo -e "Target User: \e[1;36m$TARGET_USER\e[0m ($TARGET_USER_HOME)"
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
        echo -e "\n[sysinfo]\nshow_memory = True\nshow_cpu_cores = True" | sudo tee -a /etc/landscape/client.conf > /dev/null
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
# --- Installation Functions ---

# Function to determine the target user for the installation
determine_target_user() {
    echo -e "\n\e[1;36mSelect Target User for Installation:\e[0m"
    echo "This script runs system-wide installations (like Docker, Python, CUDA) using 'sudo'."
    echo "User-specific tools (like NVM, Oh My Zsh, OpenClaw) will be installed for the user you select below."
    echo "  1. Current user ($USER)"
    echo "  2. A different/new user (e.g., a dedicated 'openclaw' user)"
    read -p "Your choice [1/2]: " choice
    if [[ "$choice" == "2" ]]; then
        IS_DIFFERENT_USER=true
        local username
        while true; do
            read -p "Enter the target username [openclawuser]: " username
            TARGET_USER=${username:-openclawuser}
            
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
            sudo adduser "$TARGET_USER"
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
    if command -v lspci &> /dev/null; then
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
}

# Function to configure system timezone
configure_timezone() {
    print_header "System Timezone Configuration"
    local env_file="$TARGET_USER_HOME/.env.secrets"
    local tz="America/Los_Angeles"

    # Check if already defined in .env.secrets
    if sudo test -f "$env_file"; then
        local env_tz=$(sudo bash -c "source \"$env_file\" 2>/dev/null && echo \"\$SYSTEM_TIMEZONE\"" | tr -d '\r')
        if [[ -n "$env_tz" ]]; then
            tz="$env_tz"
        fi
    fi

    read -p "Enter timezone (Continent/City) or press Enter to keep default [$tz]: " user_tz

    if [[ -n "$user_tz" ]]; then
        tz="$user_tz"
    fi

    print_info "Setting timezone to '$tz' and enabling NTP..."
    if sudo timedatectl set-timezone "$tz" 2>/dev/null; then
        sudo timedatectl set-ntp true 2>/dev/null || true
        print_success "Timezone set to $tz and NTP synced."
        export GLOBAL_SYSTEM_TIMEZONE="$tz"
        
        # If the secrets file already exists, update or append it
        if sudo test -f "$env_file"; then
            if sudo grep -q "SYSTEM_TIMEZONE" "$env_file"; then
                sudo -u "$TARGET_USER" sed -i "s|^.*export SYSTEM_TIMEZONE=.*|export SYSTEM_TIMEZONE=\"$tz\"|" "$env_file"
            else
                echo "export SYSTEM_TIMEZONE=\"$tz\"" | sudo -u "$TARGET_USER" tee -a "$env_file" > /dev/null
            fi
        fi
    else
        echo -e "❌ \e[1;31mFailed to set timezone.\e[0m Ensure it is a valid format like 'America/Los_Angeles'."
        export GLOBAL_SYSTEM_TIMEZONE="America/Los_Angeles"
    fi
}

# Function to configure API keys for either bash or zsh
setup_env_secrets() {
    print_header "Configuring API Keys"
    if ! sudo test -f "$TARGET_USER_HOME/.env.secrets"; then
        print_info "Creating ~/.env.secrets template for API keys..."
        cat <<EOF | sudo -u "$TARGET_USER" tee "$TARGET_USER_HOME/.env.secrets" > /dev/null
# This file is for storing secrets and API keys.
# It is sourced by your shell configuration if it exists.
# Make sure this file is NOT committed to version control.

# --- API Key Placeholders ---
# Uncomment and fill in the values for the services you use.

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
export TZ="${GLOBAL_SYSTEM_TIMEZONE:-America/Los_Angeles}"
EOF
        sudo chmod 600 "$TARGET_USER_HOME/.env.secrets"
    fi

    if sudo test -f "$TARGET_USER_HOME/.bashrc" && ! sudo grep -q ".env.secrets" "$TARGET_USER_HOME/.bashrc"; then
        echo -e '\n# Source secrets file if it exists\nif [[ -f ~/.env.secrets ]]; then\n  source ~/.env.secrets\nfi' | sudo tee -a "$TARGET_USER_HOME/.bashrc" > /dev/null
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
                        read -p "Enter value for ${key_name}: " key_value
                        if [[ -n "$key_value" ]]; then
                            sudo -u "$TARGET_USER" sed -i "s|# export ${key_name}=.*|export ${key_name}=\"${key_value}\"|" "$TARGET_USER_HOME/.env.secrets"
                        fi
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
                *) echo "Invalid option $REPLY";;
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
    sudo chsh -s "$(which zsh)" "$TARGET_USER"

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
        echo -e '\n# Source secrets file if it exists\nif [[ -f ~/.env.secrets ]]; then\n  source ~/.env.secrets\nfi' | sudo tee -a "$TARGET_USER_HOME/.zshrc" > /dev/null
    fi

    print_info "Enabling true color support for modern terminals..."
    echo -e '\n# Set COLORTERM to advertise true color support to modern CLI tools\nexport COLORTERM=truecolor' | sudo tee -a "$TARGET_USER_HOME/.zshrc" > /dev/null

    print_info "Adding custom Zsh prompt..."
    # Add custom prompt to override the theme default. Using a heredoc for clarity.
    cat <<'EOP' | sudo tee -a "${TARGET_USER_HOME}/.zshrc" > /dev/null

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
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
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
    local latest_nvm=$(curl -sL https://api.github.com/repos/nvm-sh/nvm/releases/latest | jq -r .tag_name 2>/dev/null || echo "v0.39.7")
    sudo -u "$TARGET_USER" bash -c "cd \"$TARGET_USER_HOME\" && curl -s -o- https://raw.githubusercontent.com/nvm-sh/nvm/${latest_nvm}/install.sh | bash > /dev/null 2>&1"

    print_info "Installing the latest LTS version of Node.js..."
    # Explicitly set NVM_DIR using the exact target path and source nvm.sh within the subshell.
    # We use double quotes to inject TARGET_USER_HOME directly, avoiding any $HOME resolution issues with sudo.
    local nvm_cmd="export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\""
    sudo -u "$TARGET_USER" bash -c "cd \"$TARGET_USER_HOME\" && $nvm_cmd; nvm install --lts; nvm install-latest-npm"

    print_info "Verifying NVM configuration in shell files..."
    local nvm_config_str
    nvm_config_str=$(cat <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
EOF
)
    if sudo test -f "$TARGET_USER_HOME/.zshrc" && ! sudo grep -q 'NVM_DIR' "$TARGET_USER_HOME/.zshrc"; then
        print_info "Adding NVM configuration to ~/.zshrc"
        echo -e "\n# NVM Configuration\n${nvm_config_str}" | sudo tee -a "$TARGET_USER_HOME/.zshrc" > /dev/null
    fi
    if sudo test -f "$TARGET_USER_HOME/.bashrc" && ! sudo grep -q 'NVM_DIR' "$TARGET_USER_HOME/.bashrc"; then
        print_info "Adding NVM configuration to ~/.bashrc"
        echo -e "\n# NVM Configuration\n${nvm_config_str}" | sudo tee -a "$TARGET_USER_HOME/.bashrc" > /dev/null
    fi

    local node_version=$(sudo -u "$TARGET_USER" bash -c "$nvm_cmd; node -v")
    local npm_version=$(sudo -u "$TARGET_USER" bash -c "$nvm_cmd; npm -v")

    print_success "NVM, Node.js, and NPM installed."
    print_info "Node version: $node_version, NPM version: $npm_version"
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
    brew_env_str=$(cat <<'EOF'
# Homebrew Configuration
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
EOF
)
    if sudo test -f "$TARGET_USER_HOME/.zshrc" && ! sudo grep -q 'linuxbrew' "$TARGET_USER_HOME/.zshrc"; then
        echo -e "\n${brew_env_str}" | sudo tee -a "$TARGET_USER_HOME/.zshrc" > /dev/null
    fi
    if sudo test -f "$TARGET_USER_HOME/.bashrc" && ! sudo grep -q 'linuxbrew' "$TARGET_USER_HOME/.bashrc"; then
        echo -e "\n${brew_env_str}" | sudo tee -a "$TARGET_USER_HOME/.bashrc" > /dev/null
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
NODE_BIN=\$(dirname \$(which node 2>/dev/null) 2>/dev/null)
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

# 7. Install NVIDIA vGPU Driver
install_vgpu_driver_from_link() {
    print_header "Installing NVIDIA vGPU Driver and Token"
    read -p "Do you want to install the vGPU guest driver? [y/N]: " confirm_vgpu
    if [[ "$confirm_vgpu" != "y" && "$confirm_vgpu" != "Y" ]]; then
        print_info "Skipping vGPU driver installation."
        return 0 # Exit the function gracefully
    fi

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

    if [[ -n "$env_driver_url" ]]; then
        read -p "Found default driver URL in .env.secrets. Use this? [Y/n]: " use_default_driver
        if [[ "$use_default_driver" != "n" && "$use_default_driver" != "N" ]]; then
            vgpu_driver_url="$env_driver_url"
        fi
    fi

    if [[ -z "$vgpu_driver_url" ]]; then
        print_info "Please provide the direct download URL OR a Google Drive sharing link for the vGPU driver."
        print_info "Supported protocols: http://, https://, ftp://, smb://"
        read -p "Enter the driver download URL: " vgpu_driver_url
    fi

    if [[ -z "$vgpu_driver_url" ]]; then
        echo "❌ No URL provided. Skipping vGPU driver installation."
        return 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf -- "$tmp_dir"' EXIT

    local downloaded_file_path="${tmp_dir}/nvidia-vgpu-driver.deb"

    print_info "Downloading vGPU driver from your provided link..."
    
    if [[ "$vgpu_driver_url" =~ drive\.google\.com/file/d/([a-zA-Z0-9_-]+) ]]; then
        local file_id="${BASH_REMATCH[1]}"
        print_info "Google Drive share link detected. Extracting file ID: $file_id"
        print_info "Bypassing Google Drive virus scan warning for large files..."
        
        local confirm_token
        confirm_token=$(curl -sc "${tmp_dir}/cookies.txt" "https://drive.google.com/uc?export=download&id=${file_id}" | grep -o 'confirm=[^&"'\'' ]*' | sed 's/confirm=//' | head -n 1)
        
        if [[ -n "$confirm_token" ]]; then
            curl -L -# -b "${tmp_dir}/cookies.txt" -o "$downloaded_file_path" "https://drive.google.com/uc?export=download&id=${file_id}&confirm=${confirm_token}"
        else
            # Token not found, attempt downloading directly
            curl -L -# -b "${tmp_dir}/cookies.txt" -o "$downloaded_file_path" "https://drive.google.com/uc?export=download&id=${file_id}"
        fi
    else
        # Use curl for regular direct URLs and FTP
        local curl_cmd=(curl -L -# -o "$downloaded_file_path")
        if [[ -n "$download_auth" ]]; then
            curl_cmd+=("-u" "$download_auth")
        fi
        curl_cmd+=("$vgpu_driver_url")

        if ! "${curl_cmd[@]}"; then
            echo "❌ Failed to download the driver. Please check the URL and authentication."
            return 1
        fi
    fi

    # Safety check to ensure we didn't download an HTML error page
    if file -b --mime-type "$downloaded_file_path" | grep -q "text/html"; then
        echo "❌ Downloaded file is an HTML page, not a valid driver archive."
        echo "This usually happens if the link is restricted or incorrect."
        return 1
    fi
    print_success "Download complete and verified."

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
    if [[ -n "$env_token_url" ]]; then
        read -p "Found default token URL in .env.secrets. Use this? [Y/n]: " use_default_token
        if [[ "$use_default_token" != "n" && "$use_default_token" != "N" ]]; then
            vgpu_token_url="$env_token_url"
        fi
    fi

    if [[ -z "$vgpu_token_url" ]]; then
        print_info "Please provide the download URL for the vGPU license token file (leave blank to skip)."
        read -p "Enter the token download URL: " vgpu_token_url
    fi

    if [[ -n "$vgpu_token_url" ]]; then
        local token_file_path="${tmp_dir}/client_configuration_token.tok"
        print_info "Downloading vGPU token..."
        
        if [[ "$vgpu_token_url" =~ drive\.google\.com/file/d/([a-zA-Z0-9_-]+) ]]; then
            local file_id="${BASH_REMATCH[1]}"
            local confirm_token
            confirm_token=$(curl -sc "${tmp_dir}/cookies.txt" "https://drive.google.com/uc?export=download&id=${file_id}" | grep -o 'confirm=[^&"'\'' ]*' | sed 's/confirm=//' | head -n 1)
            
            if [[ -n "$confirm_token" ]]; then
                curl -L -# -b "${tmp_dir}/cookies.txt" -o "$token_file_path" "https://drive.google.com/uc?export=download&id=${file_id}&confirm=${confirm_token}"
            else
                curl -L -# -b "${tmp_dir}/cookies.txt" -o "$token_file_path" "https://drive.google.com/uc?export=download&id=${file_id}"
            fi
        else
            local curl_cmd=(curl -L -# -o "$token_file_path")
            if [[ -n "$download_auth" ]]; then
                curl_cmd+=("-u" "$download_auth")
            fi
            curl_cmd+=("$vgpu_token_url")

            if ! "${curl_cmd[@]}"; then
                echo "❌ Failed to download the token file."
            fi
        fi

        if [[ -f "$token_file_path" ]]; then
            if file -b --mime-type "$token_file_path" | grep -q "text/html"; then
                echo "❌ Downloaded token file is an HTML page. Ensure it's a direct download link."
            else
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
                nvidia-smi -q | grep -i "License Status" || true
                nvidia-smi -q | grep -i "Feature" || true
            fi
        else
            echo "❌ Token download failed or file not found."
        fi
    fi

    trap - EXIT
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
    cuda_env_str=$(cat <<'EOF'
export CUDA_HOME="/usr/local/cuda"
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$CUDA_HOME/extras/CUPTI/lib64:$LD_LIBRARY_PATH"
EOF
)
    if sudo test -f "$TARGET_USER_HOME/.zshrc" && ! sudo grep -q 'CUDA_HOME' "$TARGET_USER_HOME/.zshrc"; then
        print_info "Adding CUDA path to ~/.zshrc"
        echo -e "\n# Add NVIDIA CUDA Toolkit to path\n${cuda_env_str}" | sudo tee -a "$TARGET_USER_HOME/.zshrc" > /dev/null
    fi
    if sudo test -f "$TARGET_USER_HOME/.bashrc" && ! sudo grep -q 'CUDA_HOME' "$TARGET_USER_HOME/.bashrc"; then
        print_info "Adding CUDA path to ~/.bashrc"
        echo -e "\n# Add NVIDIA CUDA Toolkit to path\n${cuda_env_str}" | sudo tee -a "$TARGET_USER_HOME/.bashrc" > /dev/null
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
    print_info "Installing NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt-get update

    print_info "Auto-detecting latest NVIDIA Container Toolkit version..."
    local nct_version
    nct_version=$(apt-cache show nvidia-container-toolkit 2>/dev/null | awk '/^Version:/ {print $2}' | head -n 1)
    print_success "Latest version available: ${nct_version:-Unknown}"

    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit

    if command -v docker &> /dev/null; then
        print_info "Configuring Docker to use NVIDIA runtime..."
        sudo nvidia-ctk runtime configure --runtime=docker
        sudo systemctl restart docker || echo "⚠️ Could not restart Docker service."
        
        sleep 3 # Give Docker a moment to fully initialize its network bridges

        print_info "Testing NVIDIA Container Toolkit (this may download a container image)..."
        local ubuntu_version
        ubuntu_version=$(lsb_release -sr)
        sudo docker run --rm --gpus all "ubuntu:${ubuntu_version}" nvidia-smi || \
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
    
    if [ -f "/usr/local/cuda/bin/nvcc" ]; then
        cuda_major=$(/usr/local/cuda/bin/nvcc --version | sed -n 's/^.*release \([0-9]\+\)\..*$/\1/p')
    elif command -v nvcc &> /dev/null; then
        cuda_major=$(nvcc --version | sed -n 's/^.*release \([0-9]\+\)\..*$/\1/p')
    elif dpkg -l | grep -q "cuda-toolkit-[0-9]"; then
        cuda_major=$(dpkg -l | awk '/cuda-toolkit-[0-9]+/ {print $2}' | sed -n 's/.*cuda-toolkit-\([0-9]\+\).*/\1/p' | head -n 1)
    elif command -v nvidia-smi &> /dev/null; then
        cuda_major=$(nvidia-smi | grep -i "CUDA Version" | sed -n 's/.*CUDA Version: \([0-9]\+\).*/\1/p')
    fi
    
    if [[ -z "$cuda_major" ]]; then cuda_major="12"; fi
    
    print_success "Auto-detected CUDA major version: $cuda_major"
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y install "cudnn9-cuda-${cuda_major}"

    print_info "Auto-detecting cuDNN library path..."
    sudo ldconfig # Ensure cache is updated after installation
    local cudnn_so
    cudnn_so=$(ldconfig -p | grep 'libcudnn.so' | awk '{print $NF}' | head -n 1)
    if [[ -z "$cudnn_so" ]]; then
        cudnn_so=$(dpkg -L "cudnn9-cuda-${cuda_major}" 2>/dev/null | grep 'libcudnn.so' | head -n 1)
    fi

    if [[ -n "$cudnn_so" ]]; then
        local cudnn_lib_path
        cudnn_lib_path=$(dirname "$cudnn_so")
        print_success "cuDNN library path found at: $cudnn_lib_path"
        
        local cudnn_env_str="export LD_LIBRARY_PATH=\"$cudnn_lib_path:\$LD_LIBRARY_PATH\""
        if sudo test -f "$TARGET_USER_HOME/.zshrc" && ! sudo grep -q "$cudnn_lib_path" "$TARGET_USER_HOME/.zshrc"; then
            echo -e "\n# Add cuDNN to LD_LIBRARY_PATH\n${cudnn_env_str}" | sudo tee -a "$TARGET_USER_HOME/.zshrc" > /dev/null
        fi
        if sudo test -f "$TARGET_USER_HOME/.bashrc" && ! sudo grep -q "$cudnn_lib_path" "$TARGET_USER_HOME/.bashrc"; then
            echo -e "\n# Add cuDNN to LD_LIBRARY_PATH\n${cudnn_env_str}" | sudo tee -a "$TARGET_USER_HOME/.bashrc" > /dev/null
        fi
    else
        echo "⚠️ Could not auto-detect cuDNN library path for LD_LIBRARY_PATH export."
    fi

    POST_INSTALL_ACTIONS+=("reboot")
}

# 14. Install Local LLM Support (Ollama, llama.cpp, Open-WebUI)
install_local_llm() {
    print_header "Installing Local LLM Stack"
    
    local install_llamacpp_cpu="n"
    local install_llamacpp_cuda="n"
    local install_ollama="n"

    case "$LLM_BACKEND_CHOICE" in
        "ollama") install_ollama="y" ;;
        "llama_cpu") install_llamacpp_cpu="y" ;;
        "llama_cuda") install_llamacpp_cuda="y" ;;
        *) install_ollama="y" ;; # Default fallback
    esac

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
            if command -v nvidia-smi &> /dev/null; then
                gpu_count=$(nvidia-smi --list-gpus | wc -l)
            elif command -v lspci &> /dev/null; then
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
            local compute_cap="86" # Default fallback
            if command -v nvidia-smi &> /dev/null; then
                local detected_cap
                detected_cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '.')
                if [[ -n "$detected_cap" ]]; then
                    compute_cap="$detected_cap"
                    print_success "Auto-detected Compute Capability: $compute_cap"
                else
                    print_info "Detection failed. Defaulting to 86."
                fi
            fi
            cmake_flags="-DGGML_CUDA=ON -DGGML_NATIVE=OFF $nccl_flag -DCMAKE_CUDA_ARCHITECTURES=\"$compute_cap\""
            export_cmd="export CUDA_HOME=\"/usr/local/cuda\"; export PATH=\"\$CUDA_HOME/bin:\$PATH\"; export LD_LIBRARY_PATH=\"\$CUDA_HOME/lib64:\$CUDA_HOME/extras/CUPTI/lib64:\$LD_LIBRARY_PATH\";"
            print_info "Cloning and building llama.cpp with CUDA support..."
        else
            print_info "Cloning and building llama.cpp with CPU support..."
        fi

        sudo -u "$TARGET_USER" bash -c "
            mkdir -p \"$TARGET_USER_HOME/llama.cpp/models-user\"
            cd \"$TARGET_USER_HOME\"
            if [ ! -d llama.cpp ]; then
                git clone https://github.com/ggerganov/llama.cpp
            fi
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
        local hf_args="--model /srv/models/llama.gguf"
        if [[ "$LLM_DEFAULT_MODEL_CHOICE" == "5" ]]; then hf_args="--hf-repo raincandy-u/TinyStories-656K-Q8_0-GGUF --hf-file tinystories-656k-q8_0.gguf"; fi
        if [[ "$LLM_DEFAULT_MODEL_CHOICE" =~ ^[1-4]$ ]]; then hf_args="--hf-repo \"$SELECTED_MODEL_REPO\""; fi
        if [[ "$LLM_DEFAULT_MODEL_CHOICE" == "6" && -n "$LLAMACPP_MODEL_REPO" ]]; then hf_args="--hf-repo \"$LLAMACPP_MODEL_REPO\""; fi

        if [[ "$LOAD_DEFAULT_MODEL" == "y" ]]; then
            while true; do
                print_info "Pulling and verifying selected model (this will show native download progress)..."
                local secrets_source="[ -f \"$TARGET_USER_HOME/.env.secrets\" ] && source \"$TARGET_USER_HOME/.env.secrets\";"
                local env_prefix="$secrets_source export LD_LIBRARY_PATH=\"/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64:\$LD_LIBRARY_PATH\";"
                
                local pull_status=0
                # Force the CLI to exit immediately by piping '/exit' directly into it
                sudo -u "$TARGET_USER" bash -c "$env_prefix echo '/exit' | llama-cli $hf_args -ngl 0 -n 1 -p \"System Ready.\" < /dev/null" || pull_status=$?

                echo ""

                if [[ $pull_status -eq 0 ]]; then
                    print_success "Model successfully downloaded and verified."
                    break
                else
                    echo -e "\n❌ \e[1;31mFailed to download or load the model from Hugging Face.\e[0m"
                    echo "The repository might be gated, mistyped, or non-existent."
                    read -p "Enter a valid Hugging Face repository (e.g., 'bartowski/Qwen2.5-Coder-7B-Instruct-GGUF') or type 'skip': " fallback_repo
                    if [[ "$fallback_repo" == "skip" || "$fallback_repo" == "Skip" ]]; then
                        print_info "Skipping default model load."
                        break
                    elif [[ -n "$fallback_repo" ]]; then
                        local custom_repo="${fallback_repo%:*}"
                        local custom_file="${fallback_repo#*:}"
                        if [[ "$custom_repo" != "$custom_file" && -n "$custom_file" ]]; then
                            hf_args="--hf-repo \"$custom_repo\" --hf-file \"$custom_file\""
                        else
                            hf_args="--hf-repo \"$custom_repo\""
                        fi
                    fi
                fi
            done
        fi

        local llama_host_args="--port 8080"
        if [[ "$install_llamacpp_cuda" == "y" ]]; then
            llama_host_args+=" -ngl 99"
        fi
        if [[ "$EXPOSE_LLM_ENGINE" == "y" ]]; then
            llama_host_args+=" --host 0.0.0.0 --cors"
        fi

        if [[ "$INSTALL_LLAMA_SERVICE" == "y" ]]; then
                print_info "Creating llama-server systemd service..."
                
                local env_cuda=""
                if [[ "$install_llamacpp_cuda" == "y" ]]; then
                    env_cuda="Environment=\"LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64\""
                fi

                sudo bash -c "cat <<EOF > /etc/systemd/system/llama-server.service
[Unit]
Description=Llama.cpp Server
After=network.target

[Service]
User=$TARGET_USER
Environment=\"HOME=$TARGET_USER_HOME\"
$env_cuda
ExecStart=/bin/bash -c "source $TARGET_USER_HOME/.env.secrets 2>/dev/null; exec /usr/local/bin/llama-server $hf_args $llama_host_args"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF"
                sudo systemctl daemon-reload
                sudo systemctl enable --now llama-server
                print_success "llama.cpp service installed and started on port 8080."
        fi
    fi

    if [[ "$install_ollama" == "y" || "$install_ollama" == "Y" ]]; then
        print_info "Installing Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh

        if [[ "$EXPOSE_LLM_ENGINE" == "y" ]]; then
            print_info "Configuring Ollama for external access..."
            sudo mkdir -p /etc/systemd/system/ollama.service.d
            local allowed_origins="*"
            if sudo test -f "$TARGET_USER_HOME/.env.secrets"; then
                local env_origins=$(sudo bash -c "source \"$TARGET_USER_HOME/.env.secrets\" 2>/dev/null && echo \"\$OLLAMA_ALLOWED_ORIGINS\"" | tr -d '\r')
                if [[ -n "$env_origins" ]]; then allowed_origins="$env_origins"; fi
            fi
            echo -e "[Service]\nEnvironment=\"OLLAMA_HOST=0.0.0.0:11434\"\nEnvironment=\"OLLAMA_ORIGINS=$allowed_origins\"" | sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null
            sudo systemctl daemon-reload
            sudo systemctl restart ollama
            sudo ufw allow 11434/tcp &>/dev/null || true
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

                if [[ "$LLM_DEFAULT_MODEL_CHOICE" == "5" ]]; then ollama run tinydolphin "Once upon a time," < /dev/null > "$pull_tmp" 2>&1; ollama_status=$?
                elif [[ "$LLM_DEFAULT_MODEL_CHOICE" =~ ^[1-4]$ ]]; then ollama run "$SELECTED_MODEL_REPO" "Hello, system check." < /dev/null > "$pull_tmp" 2>&1; ollama_status=$?
                elif [[ "$LLM_DEFAULT_MODEL_CHOICE" == "6" && -n "$OLLAMA_PULL_MODEL" ]]; then ollama pull "$OLLAMA_PULL_MODEL" < /dev/null > "$pull_tmp" 2>&1; ollama_status=$?
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
    fi

    if [[ "$INSTALL_OPENWEBUI" == "y" || "$INSTALL_OPENWEBUI" == "Y" ]]; then
        print_info "Installing Open-WebUI via Docker..."
        if ! command -v docker &> /dev/null; then
            echo "❌ Docker is not installed. Skipping Open-WebUI."
        elif [[ "$HAS_NVIDIA_GPU" == true ]] && ! command -v nvidia-ctk &> /dev/null; then
            echo "❌ NVIDIA Container Toolkit is not installed. Open-WebUI with GPU requires it. Skipping."
        else
            print_info "Ensuring Docker is enabled..."
            sudo systemctl is-enabled docker &>/dev/null || sudo systemctl enable --now docker
            
            print_info "Pulling Open-WebUI image..."
            sudo docker pull ghcr.io/open-webui/open-webui:main

            if sudo docker ps -aq -f name=^open-webui$ | grep -q .; then
                print_info "Stopping and removing existing Open-WebUI container..."
                sudo docker stop open-webui &>/dev/null || true
                sudo docker rm open-webui &>/dev/null || true
            fi

            print_info "Starting Open-WebUI container..."
            local docker_cmd=(sudo docker run -d --network host --restart always)
            if [[ "$HAS_NVIDIA_GPU" == true ]]; then
                docker_cmd+=(--gpus all)
            fi
            docker_cmd+=(-e OLLAMA_BASE_URL=http://127.0.0.1:11434 -e PORT=8081)
            if [[ "$EXPOSE_LLM_ENGINE" == "y" ]]; then
                docker_cmd+=(-e HOST='0.0.0.0')
                sudo ufw allow 8081/tcp &>/dev/null || true
            fi
            if [[ "$LLM_BACKEND_CHOICE" == "llama_cpu" || "$LLM_BACKEND_CHOICE" == "llama_cuda" ]]; then
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
            if [[ "$LLM_BACKEND_CHOICE" == "llama_cpu" || "$LLM_BACKEND_CHOICE" == "llama_cuda" ]]; then
                print_info "If the model does not appear, verify the connection:"
                print_info "Go to Profile > Settings > Connections > OpenAI API."
                print_info "Ensure URL is 'http://127.0.0.1:8081/v1' and click the refresh icon."
            fi
        fi
    fi

    if [[ "$install_llamacpp_cpu" == "y" || "$install_llamacpp_cuda" == "y" ]]; then
        if [[ "$LOAD_DEFAULT_MODEL" == "y" ]]; then
            echo ""
            print_info "Running llama-bench performance test on the loaded model..."
            local secrets_source="[ -f \"$TARGET_USER_HOME/.env.secrets\" ] && source \"$TARGET_USER_HOME/.env.secrets\";"
            local env_prefix="$secrets_source export LD_LIBRARY_PATH=\"/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64:\$LD_LIBRARY_PATH\";"
            local tmp_out
            tmp_out=$(mktemp)
            
            local ngl_test_args="-ngl 99"
            if [[ "$install_llamacpp_cpu" == "y" ]]; then ngl_test_args="-ngl 0"; fi

            sudo -u "$TARGET_USER" bash -c "$env_prefix llama-bench $hf_args $ngl_test_args" > "$tmp_out" 2>&1 &
            local cli_pid=$!

            (
                local elapsed=0
                while true; do
                    if grep -qEi 'tg128.*±' "$tmp_out" 2>/dev/null; then
                        break
                    fi
                    if ! kill -0 $cli_pid 2>/dev/null; then
                        break
                    fi
                    sleep 5
                    elapsed=$((elapsed + 5))
                    echo -e "\r\e[1;36mℹ️ Still running llama-bench... ($elapsed seconds elapsed)\e[0m"
                done
                sudo pkill -P $cli_pid 2>/dev/null || true
                sudo kill $cli_pid 2>/dev/null || true
                sudo pkill -f "llama-bench" 2>/dev/null || true
            ) &
            local spinner_pid=$!

            wait "$spinner_pid" 2>/dev/null || true

            local prompt_speed=$(grep -i "pp512" "$tmp_out" | awk -F'|' '{print $8}' | awk '{print $1}')
            local gen_speed=$(grep -i "tg128" "$tmp_out" | awk -F'|' '{print $8}' | awk '{print $1}')

            echo ""
            if [[ -n "$prompt_speed" && -n "$gen_speed" ]]; then
                print_success "llama-bench test complete: [ Prompt: ${prompt_speed} t/s | Generation: ${gen_speed} t/s ]"
            else
                print_success "llama-bench test complete."
                grep "|" "$tmp_out" || true
            fi
            rm -f "$tmp_out"
        fi

        echo ""
        if [[ "$INSTALL_LLAMA_SERVICE" == "y" ]]; then
            print_info "⚠️  NOTE: llama.cpp is currently running as a background service!"
            print_info "Before running manually, you MUST stop the service to free up your VRAM:"
            echo -e "\e[1;33msudo systemctl stop llama-server\e[0m\n"
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

    if [[ "$IS_DIFFERENT_USER" == false ]]; then
        echo "❌ OpenClaw cannot be installed for the current sudo user."
        echo "Please run the script again and select '2. A different/new user' to create a dedicated standard user for OpenClaw."
        return 1
    fi

    local nvm_cmd="export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\""

    # Check if node is installed for the target user.
    if ! sudo -u "$TARGET_USER" bash -c "$nvm_cmd; command -v node" &> /dev/null; then
        echo "❌ Node.js is not installed for user '$TARGET_USER'. OpenClaw requires Node.js to install without sudo."
        echo "Please run the 'Install NVM, Node.js & NPM' option first."
        return 1
    fi

    print_info "Temporarily granting passwordless sudo to '$TARGET_USER' to allow OpenClaw to install dependencies..."
    echo "$TARGET_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/99-temp-$TARGET_USER" > /dev/null

    print_info "Enabling user lingering to allow services to run after logout..."
    sudo loginctl enable-linger "$TARGET_USER"

    print_info "Starting user systemd instance..."
    sudo systemctl start "user@$(id -u "$TARGET_USER").service"

    print_info "Configuring shell environment for systemd user services..."
    local systemd_env_str
    systemd_env_str=$(cat <<'EOF'
# Systemd User Service Environment (Fixes 'su -' DBus errors)
if [ -z "$XDG_RUNTIME_DIR" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
fi
EOF
)
    if sudo test -f "$TARGET_USER_HOME/.zshrc" && ! sudo grep -q 'DBUS_SESSION_BUS_ADDRESS' "$TARGET_USER_HOME/.zshrc"; then
        echo -e "\n${systemd_env_str}" | sudo tee -a "$TARGET_USER_HOME/.zshrc" > /dev/null
    fi
    if sudo test -f "$TARGET_USER_HOME/.bashrc" && ! sudo grep -q 'DBUS_SESSION_BUS_ADDRESS' "$TARGET_USER_HOME/.bashrc"; then
        echo -e "\n${systemd_env_str}" | sudo tee -a "$TARGET_USER_HOME/.bashrc" > /dev/null
    fi

    if [ -d "/home/linuxbrew/.linuxbrew" ]; then
        print_info "Ensuring Homebrew directories are writable by '$TARGET_USER'..."
        sudo chown -R "$TARGET_USER":"$TARGET_USER" /home/linuxbrew
    fi

    local openclaw_command
    openclaw_command=$(cat <<'EOF'
        export NVM_DIR="$HOME/.nvm";
        [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh";

        # Source secrets so OpenClaw automatically uses configured API keys
        [ -f "$HOME/.env.secrets" ] && source "$HOME/.env.secrets";

        # Load Homebrew if it exists so OpenClaw can use it to install skills
        [ -f "/home/linuxbrew/.linuxbrew/bin/brew" ] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)";

        # Load CUDA paths if they exist
        [ -d "/usr/local/cuda" ] && export CUDA_HOME="/usr/local/cuda";
        [ -d "/usr/local/cuda/bin" ] && export PATH="$CUDA_HOME/bin:$PATH";
        [ -d "/usr/local/cuda/lib64" ] && export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$CUDA_HOME/extras/CUPTI/lib64:$LD_LIBRARY_PATH";

        curl -fsSL https://openclaw.ai/install.sh | bash;

        export PATH="$HOME/.local/bin:$PATH";
        export XDG_RUNTIME_DIR="/run/user/$(id -u)";
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus";

        openclaw onboard --install-daemon;
EOF
)

    print_info "Switching to '$TARGET_USER' to install and onboard OpenClaw."
    echo -e "\e[1;33mYou will be prompted for the password for user '$TARGET_USER'.\e[0m"
    
    echo -e "\n\e[1;35m=================================================================\e[0m"
    echo -e "\e[1;36m🤖 OPENCLAW ONBOARDING INSTRUCTIONS\e[0m"
    if [[ "$LLM_BACKEND_CHOICE" == "llama_cpu" || "$LLM_BACKEND_CHOICE" == "llama_cuda" ]]; then
        echo -e "When asked for the Model/auth provider, select: \e[1;32mOpenAI\e[0m"
        echo -e "When asked for the API Key, enter:              \e[1;32msk-llamacpp\e[0m"
        echo -e "When asked for the Base URL, enter:             \e[1;32mhttp://127.0.0.1:8080/v1\e[0m"
        echo -e "When asked for the Model Name, enter:           \e[1;32mllama\e[0m (or leave blank)"
    elif [[ "$LLM_BACKEND_CHOICE" == "ollama" ]]; then
        echo -e "When asked for the Model/auth provider, select: \e[1;32mOllama\e[0m"
        echo -e "When asked for the Base URL, enter:             \e[1;32mhttp://127.0.0.1:11434\e[0m"
    else
        echo -e "Select your preferred cloud provider (e.g., OpenAI, Anthropic) and provide your API key."
    fi
    echo -e "\e[1;35m=================================================================\e[0m\n"

    while true; do
        # Temporarily disable exit-on-error for the su command
        set +e
        su - "$TARGET_USER" -c "$openclaw_command"
        local su_exit_code=$?
        set -e # Re-enable exit-on-error

        if [ $su_exit_code -eq 0 ]; then
            break # Exit the loop on success
        else
            read -p "Authentication failed. Do you want to try again? [Y/n]: " retry_choice
            if [[ "$retry_choice" == "n" || "$retry_choice" == "N" ]]; then
                echo "❌ Aborting OpenClaw installation."
                # The temporary sudoers file will be removed by the cleanup step after this function returns.
                return 1 # Exit the function with an error status
            fi
        fi
    done

    print_info "Revoking temporary sudo privileges..."
    sudo rm -f "/etc/sudoers.d/99-temp-$TARGET_USER"

    local openclaw_config="$TARGET_USER_HOME/.openclaw/openclaw.json"
    if sudo test -f "$openclaw_config"; then
        print_info "Updating OpenClaw gateway configuration..."
        # Use jq to safely update the JSON config file
        local tmp_json_file
        tmp_json_file=$(mktemp)
        local bind_ip="127.0.0.1"
        if [[ "$EXPOSE_OPENCLAW" == "y" ]]; then bind_ip="0.0.0.0"; fi
        sudo jq ".gateway.bind = \"$bind_ip\" | .gateway.port = $OPENCLAW_PORT | .gateway.controlUi.enabled = true" "$openclaw_config" > "$tmp_json_file" && \
        sudo mv "$tmp_json_file" "$openclaw_config" && sudo chown "$TARGET_USER":"$TARGET_USER" "$openclaw_config"
        print_success "OpenClaw gateway configured to bind to $bind_ip:$OPENCLAW_PORT."
    else
        echo "⚠️  OpenClaw config file not found at ${openclaw_config}. Skipping gateway configuration."
    fi

    if [[ "$EXPOSE_OPENCLAW" == "y" ]]; then
        print_info "Configuring firewall rules for OpenClaw (UFW)..."
        sudo ufw allow $OPENCLAW_PORT/tcp &>/dev/null || true
        POST_INSTALL_ACTIONS+=("ufw")
        print_success "UFW rule for OpenClaw ($OPENCLAW_PORT) configured."
    fi

    if sudo test -f "$openclaw_config"; then
        local sec_options=(
            "Disable mDNS (LAN discovery broadcasts)"
            "Enable Docker Sandboxing (Highly Recommended)"
            "Restrict High-Risk Tools (Require manual approval for exec, shell, filesystem_delete)"
            "Set DM Policy to 'locked' (Private access only)"
            "Lock Configuration Permissions (chmod 700/600)"
            "Run Deep Security Audit now"
        )
        local sec_selections=(1 1 1 1 1 1)

        while true; do
            clear
            print_status_header
            echo -e "\n\e[1;36mSecure OpenClaw Configuration:\e[0m"
            for i in "${!sec_options[@]}"; do
                if [[ ${sec_selections[$i]} -eq 1 ]]; then
                    echo -e " \e[1;32m[x]\e[0m $((i+1)). ${sec_options[$i]}"
                else
                    echo -e " [ ] $((i+1)). ${sec_options[$i]}"
                fi
            done
            echo "---------------------------------"
            echo "Use numbers [1-${#sec_options[@]}] to toggle. Press 'a' to select all, 'c' to confirm."
            read -p "Your choice: " sec_choice
            if [[ "$sec_choice" =~ ^[0-9]+$ ]] && [ "$sec_choice" -ge 1 ] && [ "$sec_choice" -le ${#sec_options[@]} ]; then
                local idx=$((sec_choice - 1))
                sec_selections[$idx]=$((1 - sec_selections[$idx]))
            elif [[ "$sec_choice" == "a" || "$sec_choice" == "A" ]]; then
                for ((i=0; i<${#sec_options[@]}; i++)); do sec_selections[$i]=1; done
            elif [[ "$sec_choice" == "c" || "$sec_choice" == "C" ]]; then
                break
            else
                echo -e "\nInvalid option." && sleep 1
            fi
        done

        local tmp_json_file2
        tmp_json_file2=$(mktemp)
        local jq_filters="."
        
        if [[ ${sec_selections[0]} -eq 1 ]]; then jq_filters="$jq_filters | .discovery.mdns.mode = \"off\""; fi
        if [[ ${sec_selections[1]} -eq 1 ]]; then jq_filters="$jq_filters | .agents.defaults.sandbox.mode = \"all\""; fi
        if [[ ${sec_selections[2]} -eq 1 ]]; then jq_filters="$jq_filters | .agents.defaults.tools.exec.requireApproval = true | .agents.defaults.tools.shell.requireApproval = true | .agents.defaults.tools.filesystem_delete.requireApproval = true"; fi
        if [[ ${sec_selections[3]} -eq 1 ]]; then jq_filters="$jq_filters | .channels.defaults.dmPolicy = \"locked\""; fi
        
        if [ "$jq_filters" != "." ]; then
            print_info "Applying OpenClaw security configuration..."
            sudo jq "$jq_filters" "$openclaw_config" > "$tmp_json_file2" && \
            sudo mv "$tmp_json_file2" "$openclaw_config" && sudo chown "$TARGET_USER":"$TARGET_USER" "$openclaw_config"
            
            print_info "Restarting OpenClaw daemon to apply security settings..."
            sudo -u "$TARGET_USER" bash -c "export XDG_RUNTIME_DIR=\"/run/user/\$(id -u)\"; export DBUS_SESSION_BUS_ADDRESS=\"unix:path=\${XDG_RUNTIME_DIR}/bus\"; systemctl --user restart openclaw.service 2>/dev/null || true"
            print_success "OpenClaw security settings applied."
        fi
        
        if [[ ${sec_selections[4]} -eq 1 ]]; then
            print_info "Locking OpenClaw configuration permissions..."
            sudo chmod 700 "$TARGET_USER_HOME/.openclaw"
            sudo chmod 600 "$openclaw_config"
            print_success "Permissions locked (700 for .openclaw, 600 for openclaw.json)."
        fi

        if [[ ${sec_selections[5]} -eq 1 ]]; then
            print_info "Running OpenClaw Deep Security Audit..."
            sudo -u "$TARGET_USER" bash -c "export PATH=\"$TARGET_USER_HOME/.local/bin:\$PATH\"; openclaw security audit --deep" || echo -e "⚠️ \e[1;33mAudit returned warnings/errors, please review.\e[0m"
            echo ""
            read -n 1 -s -r -p "Press any key to continue..."
            echo ""
        fi
    fi

    print_success "OpenClaw installation complete."
    POST_INSTALL_ACTIONS+=("openclaw")
}

# --- Installation Checks ---
check_installations() {
    print_header "Checking for Existing Installations"

    # Note: selections[0] is for 'update_system' and is not pre-checked.

    # 1. Zsh (index 1)
    if sudo test -d "$TARGET_USER_HOME/.oh-my-zsh"; then
        print_info "Found existing Oh My Zsh installation."
        MASTER_INSTALLED_STATE[1]=1
    fi

    # 2. Python (index 2)
    if command -v python3 &> /dev/null && command -v pip3 &> /dev/null; then
        print_info "Found existing Python installation."
        MASTER_INSTALLED_STATE[2]=1
    fi

    # 3. Docker (index 3)
    if command -v docker &> /dev/null && groups "$TARGET_USER" | grep -q '\bdocker\b'; then
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
    if command -v gemini &> /dev/null; then
        print_info "Found existing Google Gemini CLI installation."
        MASTER_INSTALLED_STATE[6]=1
    fi

    # 7. vGPU Driver (index 7)
    if command -v nvidia-smi &> /dev/null; then
        print_info "Found existing NVIDIA driver (nvidia-smi)."
        MASTER_INSTALLED_STATE[7]=1
    fi

    # 8. btop (index 8)
    if command -v btop &> /dev/null; then
        print_info "Found existing btop installation."
        MASTER_INSTALLED_STATE[8]=1
    fi

    # 9. nvtop (index 9)
    if command -v nvtop &> /dev/null; then
        print_info "Found existing nvtop installation."
        MASTER_INSTALLED_STATE[9]=1
    fi

    # 10. CUDA Toolkit (index 10)
    if [ -f "/usr/local/cuda/bin/nvcc" ]; then
        print_info "Found existing CUDA."
        MASTER_INSTALLED_STATE[10]=1
    fi

    # 11. gcc compiler (index 11)
    if command -v gcc &> /dev/null; then
        print_info "Found existing gcc compiler."
        MASTER_INSTALLED_STATE[11]=1
    fi

    # 12. NVIDIA Container Toolkit (index 12)
    if dpkg -l | grep -q 'nvidia-container-toolkit'; then
        print_info "Found existing NVIDIA Container Toolkit."
        MASTER_INSTALLED_STATE[12]=1
    fi

    # 13. cuDNN (index 13)
    if dpkg -l | grep -E -q 'cudnn[0-9]+-cuda'; then
        print_info "Found existing cuDNN installation."
        MASTER_INSTALLED_STATE[13]=1
    fi

    # 14. Local LLM Stack (index 14)
    local llm_installed=1
    if ! command -v llama-server &> /dev/null; then llm_installed=0; fi
    if ! command -v ollama &> /dev/null; then llm_installed=0; fi
    if ! sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^open-webui$'; then llm_installed=0; fi
    if [[ $llm_installed -eq 1 ]]; then
        print_info "Found existing Local LLM Stack (Ollama, llama.cpp, Open-WebUI)."
        MASTER_INSTALLED_STATE[14]=1
    fi

    # 15. OpenClaw (index 15)
    if sudo test -f "$TARGET_USER_HOME/.local/bin/openclaw"; then
        print_info "Found existing OpenClaw installation."
        MASTER_INSTALLED_STATE[15]=1
    fi
}

# --- Verification ---
verify_installations() {
    print_header "Verifying Live Services & APIs"
    local services_checked=0

    # Verify llama-server
    if systemctl is-active --quiet llama-server 2>/dev/null; then
        services_checked=1
        print_info "Waiting for llama.cpp server to initialize and load the model (timeout 60s)..."
        local api_up=0
        for i in {1..30}; do
            if [[ "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/health)" == "200" ]]; then
                api_up=1
                break
            fi
            sleep 2
        done

        if [[ $api_up -eq 1 ]]; then
            print_success "llama.cpp server API is reachable and ready."
            
            print_info "Testing llama.cpp /v1/chat/completions endpoint..."
            local response
            response=$(curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
                -H "Content-Type: application/json" \
                -d '{
                    "messages": [{"role": "user", "content": "Hello! Say hi."}],
                    "max_tokens": 15
                }')
            if echo "$response" | grep -q '"content"'; then
                print_success "llama.cpp completion test passed."
            else
                echo "⚠️ llama.cpp completion test failed or returned an unexpected response."
            fi
        else
            echo "⚠️ llama.cpp server API did not return HTTP 200 in time. It might still be loading the model."
        fi
    fi

    # Verify Ollama
    if systemctl is-active --quiet ollama 2>/dev/null; then
        services_checked=1
        print_info "Testing Ollama API..."
        if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:11434/api/tags | grep -q "200"; then
            print_success "Ollama API is reachable and ready."
        else
            echo "⚠️ Ollama API is not responding correctly."
        fi
    fi

    # Verify Open-WebUI
    if command -v docker &> /dev/null && sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^open-webui$'; then
        services_checked=1
        print_info "Waiting for Open-WebUI to initialize (timeout 60s)..."
        local webui_up=0
        for i in {1..30}; do
            # Check both the /health API endpoint and the root frontend route
            if [[ "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8081/health)" == "200" ]] || [[ "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8081/)" == "200" ]]; then
                webui_up=1
                break
            fi
            sleep 2
        done
        if [[ $webui_up -eq 1 ]]; then
            print_success "Open-WebUI frontend is reachable and ready on port 8081."
        else
            echo "⚠️ Open-WebUI did not return HTTP 200 in time. It might still be starting."
        fi
    fi

    # Verify OpenClaw
    if sudo test -f "$TARGET_USER_HOME/.local/bin/openclaw"; then
        services_checked=1
        local oc_port="18789"
        if sudo test -f "$TARGET_USER_HOME/.openclaw/openclaw.json"; then oc_port=$(sudo jq -r '.gateway.port // 18789' "$TARGET_USER_HOME/.openclaw/openclaw.json" 2>/dev/null); fi
        print_info "Waiting for OpenClaw Gateway to initialize (timeout 60s)..."
        local oc_up=0
        for i in {1..30}; do
            # A response other than 000 means the server is bound and successfully accepting HTTP requests
            if [[ "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$oc_port/)" != "000" ]]; then
                oc_up=1
                break
            fi
            sleep 2
        done
        if [[ $oc_up -eq 1 ]]; then
            print_success "OpenClaw Gateway is reachable and ready on port $oc_port."
        else
            echo "⚠️ OpenClaw Gateway is not responding on port $oc_port. It might still be starting."
        fi
    fi

    # Verify cuDNN
    if dpkg -l | grep -E -q 'cudnn|libcudnn'; then
        services_checked=1
        print_info "Verifying cuDNN installation..."
        if ldconfig -p | grep -E -q 'libcudnn'; then
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

    # User environment helpers
    local nvm_cmd="export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\""
    local brew_cmd="[ -f /home/linuxbrew/.linuxbrew/bin/brew ] && eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\""

    if sudo test -d "$TARGET_USER_HOME/.oh-my-zsh"; then
        print_info "Zsh / Oh My Zsh:"
        zsh --version || echo "Installed"
        echo ""
    fi

    if command -v python3 &> /dev/null; then
        print_info "Python:"
        python3 --version
        echo ""
    fi

    if command -v docker &> /dev/null; then
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

    if command -v gemini &> /dev/null; then
        print_info "Google Gemini CLI:"
        echo "Installed at $(which gemini)"
        echo ""
    fi

    if command -v nvidia-smi &> /dev/null; then
        print_info "NVIDIA GPU/vGPU Driver:"
        nvidia-smi --query-gpu=driver_version,name --format=csv,noheader || nvidia-smi
        nvidia-smi -q | grep -i "license" || true
        echo ""
    fi

    if command -v btop &> /dev/null; then
        print_info "btop (System Monitor):"
        btop --version | head -n 1
        echo ""
    fi

    if command -v nvtop &> /dev/null; then
        print_info "nvtop (GPU Monitor):"
        nvtop --version
        echo ""
    fi

    if command -v gcc &> /dev/null; then
        print_info "gcc Compiler:"
        gcc --version | head -n 1
        echo ""
    fi

    if command -v nvcc &> /dev/null; then
        print_info "CUDA:"
        nvcc --version
        echo ""
    fi

    if command -v nvidia-ctk &> /dev/null; then
        print_info "NVIDIA Container Toolkit:"
        nvidia-ctk --version
        echo ""
    fi

    if dpkg -l | grep -E -q 'cudnn|libcudnn'; then
        print_info "cuDNN Library:"
        dpkg -l | grep -E 'cudnn|libcudnn'
        echo ""
    fi

    if command -v ollama &> /dev/null; then
        print_info "Ollama:"
        ollama --version
        echo ""
    fi

    if command -v llama-server &> /dev/null; then
        print_info "llama.cpp:"
        echo "llama-server installed at $(which llama-server)"
        if systemctl is-active --quiet llama-server 2>/dev/null; then
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
        if command -v llama-server &> /dev/null; then
            echo -e "  \e[1;36m-> How to connect Open-WebUI to llama.cpp:\e[0m"
            echo "     1. Open WebUI in your browser (e.g., http://localhost:8081)"
            echo "     2. Go to Profile (bottom left) -> Settings -> Connections"
            echo "     3. Under 'OpenAI API', verify the URL is 'http://127.0.0.1:8080/v1' and Key is 'sk-llamacpp'"
            echo "     4. Click the 'Verify Connection' icon. Your model should automatically load!"
        fi
        echo ""
    fi

    if sudo test -f "$TARGET_USER_HOME/.local/bin/openclaw"; then
        print_info "OpenClaw:"
        sudo -u "$TARGET_USER" bash -c "export PATH=\"$TARGET_USER_HOME/.local/bin:\$PATH\"; openclaw --version 2>/dev/null || echo 'Installed'"
        echo ""
    fi

    print_info "System Hostname Resolution:"
    local current_hostname
    current_hostname=$(hostname)
    if hostname -i &> /dev/null; then
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
}

# --- Main Menu ---

show_menu() {
    UI_TO_MASTER=()
    local ui_num=1
    local menu_body=""

    for master_index in "${ACTIVE_INDICES[@]}"; do
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
            line=" \e[1;36m[✓]\e[0m ${ui_num}. ${MASTER_OPTIONS[$master_index]}"
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
    echo "Use numbers [1-$((ui_num-1))] to toggle an option. Press 'a' to select all."
    echo "Press 'i' to install selected, or 'q' to quit."
    echo "---------------------------------"
    printf "%b" "$menu_body"
    echo "---------------------------------"
}

main() {
    check_not_root
    check_sudo_privileges
    check_os
    determine_target_user
    detect_gpu
    
    clear
    print_status_header
    configure_timezone

    local MASTER_OPTIONS=(
        "Update System Packages (apt update && upgrade)"
        "Install Oh My Zsh & Dev Tools (git, tmux, micro)"
        "Install Python Environment"
        "Install Docker and Docker Compose"
        "Install NVM, Node.js & NPM"
        "Install Homebrew"
        "Install Google Gemini CLI"
        "Install NVIDIA vGPU Driver"
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
        install_vgpu_driver_from_link
        install_btop
        install_nvtop
        install_cuda_toolkit
        install_gcc
        install_container_toolkit
        install_cudnn
        install_local_llm
        install_openclaw
    )

    local MASTER_SELECTIONS=(1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
    local MASTER_INSTALLED_STATE=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
    local ACTIVE_INDICES=(0)
    local UI_TO_MASTER=()

    ensure_active_index() {
        local idx=$1
        if [[ ! " ${ACTIVE_INDICES[*]} " =~ " ${idx} " ]]; then
            ACTIVE_INDICES+=($idx)
            IFS=$'\n' ACTIVE_INDICES=($(sort -n <<<"${ACTIVE_INDICES[*]}"))
            unset IFS
        fi
    }

    local GOAL_SELECTIONS=(0 0 0)
    local GOAL_OPTIONS=(
        "OpenClaw Server Setup (Core tools, Docker, Node.js, OpenClaw)"
        "VGPU Setup (NVIDIA Driver, CUDA, Container Toolkit, cuDNN)"
        "Local LLM Setup (Ollama, llama.cpp, Open-WebUI)"
    )

    while true; do
        clear
        print_status_header
        echo -e "\n\e[1;36mSelect Installation Goals:\e[0m"
        for i in "${!GOAL_OPTIONS[@]}"; do
            if [[ ${GOAL_SELECTIONS[$i]} -eq 1 ]]; then
                echo -e " \e[1;32m[x]\e[0m $((i+1)). ${GOAL_OPTIONS[$i]}"
            else
                echo -e " [ ] $((i+1)). ${GOAL_OPTIONS[$i]}"
            fi
        done
        echo "---------------------------------"
        echo "Use numbers [1-3] to toggle a goal. Press 'a' to select all."
        echo "Press 'c' to continue to the detailed menu, or 'q' to quit."
        read -p "Your choice: " goal_choice
        
        if [[ "$goal_choice" =~ ^[1-3]$ ]]; then
            local index=$((goal_choice - 1))
            GOAL_SELECTIONS[$index]=$((1 - GOAL_SELECTIONS[$index]))
        elif [[ "$goal_choice" == "a" || "$goal_choice" == "A" ]]; then
            GOAL_SELECTIONS=(1 1 1)
        elif [[ "$goal_choice" == "c" || "$goal_choice" == "C" ]]; then
            if [[ ${GOAL_SELECTIONS[0]} -eq 0 && ${GOAL_SELECTIONS[1]} -eq 0 && ${GOAL_SELECTIONS[2]} -eq 0 ]]; then
                echo -e "\nPlease select at least one goal before continuing." && sleep 1
            else
                break
            fi
        elif [[ "$goal_choice" == "q" || "$goal_choice" == "Q" ]]; then
            echo -e "\nExiting."; exit 0
        else
            echo -e "\nInvalid option." && sleep 1
        fi
    done

    if [[ ${GOAL_SELECTIONS[0]} -eq 1 ]]; then ACTIVE_INDICES+=(1 2 3 4 5 6 15); fi
    if [[ ${GOAL_SELECTIONS[1]} -eq 1 ]]; then ACTIVE_INDICES+=(7 8 9 10 11 12 13); fi
    if [[ ${GOAL_SELECTIONS[2]} -eq 1 ]]; then ACTIVE_INDICES+=(14); fi

    IFS=$'\n' ACTIVE_INDICES=($(sort -n <<<"${ACTIVE_INDICES[*]}"))
    unset IFS

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

            if [[ ${MASTER_INSTALLED_STATE[$master_index]} -eq 1 ]]; then
                if [[ $master_index -eq 14 ]]; then
                    echo -e "\nLocal LLM Stack is already installed."
                    read -p "Do you want to reconfigure/switch your LLM backend? [y/N]: " reconf
                    if [[ "$reconf" == "y" || "$reconf" == "Y" ]]; then
                        MASTER_INSTALLED_STATE[$master_index]=0
                    else
                        continue
                    fi
                else
                    echo -e "\nOption $((choice)) is already installed." && sleep 1
                    continue
                fi
            fi

            if [[ ${MASTER_INSTALLED_STATE[$master_index]} -eq 0 ]]; then
                # Sub-menu for Local LLM Stack (index 14)
                if [[ $master_index -eq 14 && ${MASTER_SELECTIONS[14]} -eq 0 ]]; then
                    LLM_BACKEND_CHOICE=""
                    local cancel_llm=false
                    while true; do
                        clear
                        print_status_header
                        echo -e "\n\e[1;36mSelect Local LLM Backend (Exclusive):\e[0m"
                        if [[ "$LLM_BACKEND_CHOICE" == "ollama" ]]; then echo -e "  \e[1;32m(*)\e[0m 1. Ollama"; else echo "  ( ) 1. Ollama"; fi
                        if [[ "$LLM_BACKEND_CHOICE" == "llama_cpu" ]]; then echo -e "  \e[1;32m(*)\e[0m 2. llama.cpp with CPU"; else echo "  ( ) 2. llama.cpp with CPU"; fi
                        if [[ "$LLM_BACKEND_CHOICE" == "llama_cuda" ]]; then echo -e "  \e[1;32m(*)\e[0m 3. llama.cpp with CUDA"; else echo "  ( ) 3. llama.cpp with CUDA"; fi
                        echo "---------------------------------"
                        echo "Use numbers [1-3] to toggle. Press 'c' to confirm, 'q' to cancel."
                        read -p "Your choice: " llm_choice
                        case "$llm_choice" in
                            1) LLM_BACKEND_CHOICE="ollama" ;;
                            2) LLM_BACKEND_CHOICE="llama_cpu" ;;
                            3) LLM_BACKEND_CHOICE="llama_cuda" ;;
                            c|C) 
                                if [[ -z "$LLM_BACKEND_CHOICE" ]]; then echo -e "\nPlease select a backend." && sleep 1; else break; fi
                                ;;
                            q|Q) cancel_llm=true; break ;;
                            *) echo -e "\nInvalid choice." && sleep 1 ;;
                        esac
                    done

                    if [[ "$cancel_llm" == true ]]; then continue; fi

                INSTALL_OPENWEBUI="n"
                EXPOSE_LLM_ENGINE="n"
                LOAD_DEFAULT_MODEL="n"
                LLM_DEFAULT_MODEL_CHOICE=""
                INSTALL_LLAMA_SERVICE="n"
                ENABLE_UFW_AUTOMATICALLY="n"
                
                local opt_options=(
                    "Install open Web UI?"
                    "Allow external connections to ${LLM_BACKEND_CHOICE} (bind 0.0.0.0)?"
                    "Load default model?"
                )

                if [[ "$LLM_BACKEND_CHOICE" == "llama_cpu" || "$LLM_BACKEND_CHOICE" == "llama_cuda" ]]; then
                    opt_options+=("Install llama.cpp model as system service?")
                fi
                opt_options+=("Enable UFW firewall (automatically opens SSH and selected ports)?")

                local opt_selections=()
                for ((i=0; i<${#opt_options[@]}; i++)); do opt_selections+=(0); done

                while true; do
                    clear
                    print_status_header
                    echo -e "\n\e[1;36mConfigure Additional Options:\e[0m"
                    for i in "${!opt_options[@]}"; do
                        if [[ ${opt_selections[$i]} -eq 1 ]]; then
                            echo -e " \e[1;32m[x]\e[0m $((i+1)). ${opt_options[$i]}"
                        else
                            echo -e " [ ] $((i+1)). ${opt_options[$i]}"
                        fi
                    done
                    echo "---------------------------------"
                    echo "Use numbers [1-${#opt_options[@]}] to toggle. Press 'a' to select all, 'c' to confirm."
                    read -p "Your choice: " opt_choice
                    if [[ "$opt_choice" =~ ^[0-9]+$ ]] && [ "$opt_choice" -ge 1 ] && [ "$opt_choice" -le ${#opt_options[@]} ]; then
                        local idx=$((opt_choice - 1))
                        opt_selections[$idx]=$((1 - opt_selections[$idx]))
                    elif [[ "$opt_choice" == "a" || "$opt_choice" == "A" ]]; then
                        for ((i=0; i<${#opt_options[@]}; i++)); do opt_selections[$i]=1; done
                    elif [[ "$opt_choice" == "c" || "$opt_choice" == "C" ]]; then
                        break
                    else
                        echo -e "\nInvalid option." && sleep 1
                    fi
                done

                for i in "${!opt_options[@]}"; do
                    if [[ ${opt_selections[$i]} -eq 1 ]]; then
                        case "${opt_options[$i]}" in
                            "Install open Web UI?") INSTALL_OPENWEBUI="y" ;;
                            "Allow external connections to "*0.0.0.0?) EXPOSE_LLM_ENGINE="y" ;;
                            "Load default model?") LOAD_DEFAULT_MODEL="y" ;;
                            "Install llama.cpp model as system service?") INSTALL_LLAMA_SERVICE="y" ;;
                            "Enable UFW firewall (automatically opens SSH and selected ports)?") ENABLE_UFW_AUTOMATICALLY="y" ;;
                        esac
                    fi
                done

                if [[ "$LOAD_DEFAULT_MODEL" == "y" ]]; then
                    local detected_ram_vram=0
                    local memory_type="VRAM"
                    
                    if [[ "$LLM_BACKEND_CHOICE" == "llama_cpu" ]]; then
                        memory_type="System RAM"
                        detected_ram_vram=${SYSTEM_RAM_GB:-0}
                    else
                        detected_ram_vram=${GPU_VRAM_GB:-0}
                    fi
                    
                    while true; do
                        local vram_tier="8"
                        echo -e "\n\e[1;36mSelect a model to load or choose your ${memory_type} tier for recommendations:\e[0m"
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
                            if [[ "$LLM_BACKEND_CHOICE" == "ollama" ]]; then
                                while true; do
                                    read -p "Enter an Ollama model name to pull (e.g., 'llama3', 'mistral'): " raw_input
                                    if [[ -z "$raw_input" ]]; then
                                        echo "Input cannot be empty."
                                        continue
                                    fi
                                    
                                    local base_model=$(echo "$raw_input" | cut -d':' -f1)
                                    if command -v curl &> /dev/null; then
                                        if [[ "$base_model" =~ ^[A-Za-z0-9_.-]+$ ]]; then
                                            echo -e "🔍 Checking Ollama library for '\e[1;36m$base_model\e[0m'..."
                                            local status_code=$(curl -s -o /dev/null -w "%{http_code}" "https://ollama.com/library/$base_model")
                                            if [[ "$status_code" == "200" ]]; then echo -e "✅ \e[1;32mModel found.\e[0m"
                                            elif [[ "$status_code" == "404" ]]; then echo -e "❌ \e[1;31mModel not found in official library (HTTP 404).\e[0m Please check for typos."; continue;
                                            else echo -e "⚠️ \e[1;33mUnexpected HTTP status: $status_code\e[0m. Proceeding anyway."; fi
                                        else
                                            echo -e "⚠️ \e[1;33mCustom or external repository format detected.\e[0m Proceeding without verification."
                                        fi
                                    fi
                                    OLLAMA_PULL_MODEL="$raw_input"
                                    echo ""
                                    read -n 1 -s -r -t 5 -p "Press any key to continue (or wait 5s)..."
                                    echo ""
                                    break
                                done
                            elif [[ "$LLM_BACKEND_CHOICE" == "llama_cpu" || "$LLM_BACKEND_CHOICE" == "llama_cuda" ]]; then
                                echo -e "\n\e[1;36mThe llama-cli and llama-server tools can automatically download GGUF models from Hugging Face if you provide the repository name."
                                echo -e "Format: username/repository (e.g., 'Qwen/Qwen2.5-7B-Instruct-GGUF')"
                                echo -e "Or:     username/repository:filename (e.g., 'Qwen/Qwen2.5-7B-Instruct-GGUF:qwen2.5-7b-instruct-q4_k_m.gguf')\e[0m\n"
                                while true; do
                                    read -p "Enter HuggingFace string: " raw_input
                                    if [[ -z "$raw_input" ]]; then
                                        echo "Input cannot be empty."
                                        continue
                                    fi
                                    
                                    local hf_repo="${raw_input%:*}"
                                    
                                    if [[ ! "$hf_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
                                        echo -e "❌ \e[1;31mInvalid syntax.\e[0m Must be 'username/repository' (e.g., Qwen/Qwen2.5-7B-Instruct-GGUF)."
                                        continue
                                    fi

                                    if command -v curl &> /dev/null; then
                                        echo -e "🔍 Checking Hugging Face repository '\e[1;36m$hf_repo\e[0m'..."
                                        local status_code
                                        local hf_token_header="no"
                                        local curl_cmd=(curl -s -o /dev/null -w "%{http_code}")
                                        
                                        if sudo test -f "$TARGET_USER_HOME/.env.secrets"; then
                                            local detected_token=$(sudo bash -c "source \"$TARGET_USER_HOME/.env.secrets\" 2>/dev/null && echo \"\$HF_TOKEN\"" | tr -d '\r')
                                            if [[ -n "$detected_token" ]]; then 
                                                curl_cmd+=(-H "Authorization: Bearer $detected_token")
                                                hf_token_header="yes"
                                            fi
                                        fi

                                        curl_cmd+=("https://huggingface.co/api/models/$hf_repo")
                                        status_code=$("${curl_cmd[@]}")

                                        if [[ "$status_code" == "200" ]]; then 
                                            echo -e "✅ \e[1;32mRepository found and accessible.\e[0m"
                                            
                                            local custom_file="${raw_input#*:}"
                                            if [[ "$hf_repo" == "$custom_file" || -z "$custom_file" ]]; then
                                                echo -e "🔍 Auto-detecting optimal GGUF file..."
                                                local tree_cmd=(curl -s)
                                                if [[ "$hf_token_header" == "yes" ]]; then tree_cmd+=(-H "Authorization: Bearer $detected_token"); fi
                                                tree_cmd+=("https://huggingface.co/api/models/$hf_repo/tree/main")
                                                
                                                local files_json=$("${tree_cmd[@]}")
                                                local gguf_files=$(echo "$files_json" | grep -io '"path":"[^"]*\.gguf"' | cut -d'"' -f4 || true)
                                                
                                                if [[ -n "$gguf_files" ]]; then
                                                    local best_file=""
                                                    if echo "$gguf_files" | grep -qi 'Q4_K_M'; then best_file=$(echo "$gguf_files" | grep -i 'Q4_K_M' | head -n 1)
                                                    elif echo "$gguf_files" | grep -qi 'Q5_K_M'; then best_file=$(echo "$gguf_files" | grep -i 'Q5_K_M' | head -n 1)
                                                    elif echo "$gguf_files" | grep -qi 'Q4_0'; then best_file=$(echo "$gguf_files" | grep -i 'Q4_0' | head -n 1)
                                                    elif echo "$gguf_files" | grep -qi 'Q8_0'; then best_file=$(echo "$gguf_files" | grep -i 'Q8_0' | head -n 1)
                                                    else best_file=$(echo "$gguf_files" | head -n 1); fi
                                                    
                                                    if [[ -n "$best_file" ]]; then echo -e "✅ \e[1;32mAuto-selected file: $best_file\e[0m"; raw_input="${hf_repo}:${best_file}"; fi
                                                else echo -e "⚠️ \e[1;33mNo .gguf files detected in the root of this repository. You may need to specify the filename manually.\e[0m"; fi
                                            fi
                                        elif [[ "$status_code" == "401" ]]; then
                                            echo -e "🔒 \e[1;33mRepository is GATED.\e[0m"
                                            if [[ "$hf_token_header" == "no" ]]; then echo -e "❌ \e[1;31mNo HF_TOKEN found in ~/.env.secrets. You MUST add your Hugging Face token to download this model.\e[0m"; continue;
                                            else echo -e "✅ \e[1;32mHF_TOKEN detected. Ensure your token has access to this repository.\e[0m"; fi
                                        elif [[ "$status_code" == "404" ]]; then echo -e "❌ \e[1;31mRepository not found (HTTP 404).\e[0m Please check for typos."; continue;
                                        else echo -e "⚠️ \e[1;33mUnexpected HTTP status: $status_code\e[0m. Proceeding anyway, but download might fail."; fi
                                    fi
                                    LLAMACPP_MODEL_REPO="$raw_input"
                                    echo ""
                                    read -n 1 -s -r -t 5 -p "Press any key to continue (or wait 5s)..."
                                    echo ""
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
                            *) echo -e "\nInvalid choice. Please try again." && sleep 1; continue ;;
                        esac

                        if [[ "$detected_ram_vram" -gt 0 ]] && [[ "$vram_tier" -gt "$detected_ram_vram" ]]; then
                            echo -e "\n\e[1;33m⚠️ WARNING: Memory Limit Exceeded\e[0m"
                            echo -e "You selected the \e[1;36m${vram_tier}GB\e[0m tier, but only \e[1;31m~${detected_ram_vram}GB\e[0m of ${memory_type} was detected."
                            echo -e "Models from this tier will likely cause severe slowdowns (swapping/CPU offloading) or Out of Memory (OOM) crashes."
                            read -p "Are you sure you want to proceed? [y/N]: " override_mem
                            if [[ "$override_mem" != "y" && "$override_mem" != "Y" ]]; then
                                continue
                            fi
                        fi
                        
                        get_model_recommendations "$LLM_BACKEND_CHOICE" "$vram_tier"
                        local m_chat="$REC_MODEL_CHAT"
                        local m_code="$REC_MODEL_CODE"
                        local m_moe="$REC_MODEL_MOE"
                        local m_vision="$REC_MODEL_VISION"
                        
                        echo -e "\n\e[1;36mSelect a default model to load (${vram_tier}GB Tier):\e[0m"
                        echo "  1. General Chat:    $m_chat"
                        echo "  2. Coding:          $m_code"
                        echo "  3. MoE:             $m_moe"
                        echo "  4. Vision-Language: $m_vision"
                        echo "  b. Back to VRAM tier selection"
                        read -p "Your choice [1-4, b]: " sub_choice
                        
                        if [[ "$sub_choice" == "b" || "$sub_choice" == "B" ]]; then
                            continue
                        fi

                        if [[ "$sub_choice" == "1" ]]; then SELECTED_MODEL_REPO="$m_chat"; LLM_DEFAULT_MODEL_CHOICE="1";
                        elif [[ "$sub_choice" == "2" ]]; then SELECTED_MODEL_REPO="$m_code"; LLM_DEFAULT_MODEL_CHOICE="2";
                        elif [[ "$sub_choice" == "3" ]]; then SELECTED_MODEL_REPO="$m_moe"; LLM_DEFAULT_MODEL_CHOICE="3";
                        elif [[ "$sub_choice" == "4" ]]; then SELECTED_MODEL_REPO="$m_vision"; LLM_DEFAULT_MODEL_CHOICE="4";
                        else
                            echo -e "\nInvalid choice. Please try again." && sleep 1
                            continue
                        fi
                        break
                    done
                fi
                fi

                MASTER_SELECTIONS[$master_index]=$((1 - MASTER_SELECTIONS[$master_index]))

                if [[ $master_index -eq 15 && ${MASTER_SELECTIONS[15]} -eq 1 ]]; then
                    if [[ "$IS_DIFFERENT_USER" == false ]]; then
                        echo -e "\n❌ [Blocked] OpenClaw cannot be installed for the current sudo user."
                        read -p "Do you want to create/select a dedicated standard user now? [y/N]: " fix_user
                        if [[ "$fix_user" == "y" || "$fix_user" == "Y" ]]; then
                            echo ""
                            determine_target_user
                            if [[ "$IS_DIFFERENT_USER" == true ]]; then
                                echo -e "\n✅ Target user updated to '$TARGET_USER'. OpenClaw selected." && sleep 2
                            else
                                MASTER_SELECTIONS[15]=0
                                echo -e "\n❌ User remains '$TARGET_USER'. OpenClaw unselected." && sleep 2
                                continue
                            fi
                        else
                            MASTER_SELECTIONS[15]=0
                            echo -e "\n❌ OpenClaw unselected." && sleep 2
                            continue
                        fi
                    fi
                    
                    echo ""
                    echo -e "\e[1;33mWARNING: Do not expose OpenClaw on a VPS connected directly to the internet without proper security.\e[0m"
                    read -p "Do you want to expose OpenClaw to the network (bind to 0.0.0.0)? [y/N]: " expose_oc
                    if [[ "$expose_oc" == "y" || "$expose_oc" == "Y" ]]; then
                        EXPOSE_OPENCLAW="y"
                    else
                        EXPOSE_OPENCLAW="n"
                    fi
                    
                    echo ""
                    read -p "Do you want to run OpenClaw on port 8082 instead of the default 18789? [y/N]: " oc_port_choice
                    if [[ "$oc_port_choice" == "y" || "$oc_port_choice" == "Y" ]]; then
                        OPENCLAW_PORT="8082"
                    else
                        OPENCLAW_PORT="18789"
                    fi
                fi

                if [[ $master_index -eq 15 && ${MASTER_SELECTIONS[15]} -eq 0 ]]; then
                    EXPOSE_OPENCLAW="n"
                    OPENCLAW_PORT="18789"
                fi

                if [[ $master_index -eq 14 && ${MASTER_SELECTIONS[14]} -eq 0 ]]; then
                    LLM_BACKEND_CHOICE=""
                    INSTALL_OPENWEBUI="n"
                    EXPOSE_LLAMA_SERVER="n"
                    TEST_LLAMACPP="n"
                    OLLAMA_PULL_MODEL=""
                    SELECTED_MODEL_REPO=""
                    AUTO_UPDATE_MODEL="n"
                fi

                # Dependency logic: Gemini CLI (index 6) and OpenClaw (index 15) require NVM (index 4)
                if [[ ($master_index -eq 6 || $master_index -eq 15) && ${MASTER_SELECTIONS[$master_index]} -eq 1 && ${MASTER_INSTALLED_STATE[4]} -eq 0 ]]; then
                    if [[ ${MASTER_SELECTIONS[4]} -eq 0 ]]; then
                        MASTER_SELECTIONS[4]=1
                        ensure_active_index 4
                        echo -e "\n[Auto-selected] NVM/Node.js is required for this installation." && sleep 1.5
                    fi
                elif [[ $master_index -eq 4 && ${MASTER_SELECTIONS[4]} -eq 0 ]]; then
                    local unselected_deps=0
                    if [[ ${MASTER_SELECTIONS[6]} -eq 1 ]]; then MASTER_SELECTIONS[6]=0; unselected_deps=1; fi
                    if [[ ${MASTER_SELECTIONS[15]} -eq 1 ]]; then MASTER_SELECTIONS[15]=0; unselected_deps=1; fi
                    if [[ $unselected_deps -eq 1 ]]; then
                        echo -e "\n[Auto-unselected] Gemini and/or OpenClaw were unselected because they require NVM." && sleep 2
                    fi
                fi

                # Dependency logic for NVIDIA Container Toolkit (index 12) requiring Docker (index 3)
                if [[ $master_index -eq 12 && ${MASTER_SELECTIONS[12]} -eq 1 && ${MASTER_INSTALLED_STATE[3]} -eq 0 ]]; then
                    if [[ ${MASTER_SELECTIONS[3]} -eq 0 ]]; then
                        MASTER_SELECTIONS[3]=1
                        ensure_active_index 3
                        echo -e "\n[Auto-selected] Docker is required for NVIDIA Container Toolkit installation." && sleep 1.5
                    fi
                elif [[ $master_index -eq 3 && ${MASTER_SELECTIONS[3]} -eq 0 ]]; then
                    if [[ ${MASTER_SELECTIONS[12]} -eq 1 ]]; then
                        MASTER_SELECTIONS[12]=0
                        echo -e "\n[Auto-unselected] NVIDIA Container Toolkit was unselected because it requires Docker." && sleep 2
                    fi
                fi

                # Dependency logic for Local LLM Stack (index 14)
                if [[ $master_index -eq 14 && ${MASTER_SELECTIONS[14]} -eq 1 ]]; then
                    local auto_selected=""
                    if [[ ("$INSTALL_OPENWEBUI" == "y" || "$INSTALL_OPENWEBUI" == "Y") && ${MASTER_SELECTIONS[3]} -eq 0 && ${MASTER_INSTALLED_STATE[3]} -eq 0 ]]; then MASTER_SELECTIONS[3]=1; ensure_active_index 3; auto_selected+="Docker, "; fi
                    if [[ "$LLM_BACKEND_CHOICE" == "llama_cuda" && "$HAS_NVIDIA_GPU" == true && ${MASTER_SELECTIONS[10]} -eq 0 && ${MASTER_INSTALLED_STATE[10]} -eq 0 ]]; then MASTER_SELECTIONS[10]=1; ensure_active_index 10; auto_selected+="CUDA, "; fi
                    if [[ ("$INSTALL_OPENWEBUI" == "y" || "$INSTALL_OPENWEBUI" == "Y" || "$LLM_BACKEND_CHOICE" == "llama_cuda") && "$HAS_NVIDIA_GPU" == true && ${MASTER_SELECTIONS[12]} -eq 0 && ${MASTER_INSTALLED_STATE[12]} -eq 0 ]]; then MASTER_SELECTIONS[12]=1; ensure_active_index 12; auto_selected+="NVIDIA CTK, "; fi
                    if [[ -n "$auto_selected" ]]; then
                        echo -e "\n[Auto-selected] ${auto_selected%, } required for Local LLM Stack components." && sleep 2
                    fi
                fi
            fi
        elif [[ "$choice" == "a" || "$choice" == "A" ]]; then
            for master_index in "${ACTIVE_INDICES[@]}"; do 
                if [[ ${MASTER_INSTALLED_STATE[$master_index]} -eq 0 ]]; then 
                    if [[ $master_index -eq 15 && "$IS_DIFFERENT_USER" == false ]]; then
                        continue
                    fi
                    MASTER_SELECTIONS[$master_index]=1
                    if [[ $master_index -eq 14 && -z "$LLM_BACKEND_CHOICE" ]]; then LLM_BACKEND_CHOICE="ollama"; fi
                fi
            done
            if [[ ${MASTER_SELECTIONS[12]} -eq 1 && ${MASTER_INSTALLED_STATE[3]} -eq 0 && ${MASTER_SELECTIONS[3]} -eq 0 ]]; then
                MASTER_SELECTIONS[3]=1
                ensure_active_index 3
            fi
            if [[ (${MASTER_SELECTIONS[6]} -eq 1 || ${MASTER_SELECTIONS[15]} -eq 1) && ${MASTER_INSTALLED_STATE[4]} -eq 0 && ${MASTER_SELECTIONS[4]} -eq 0 ]]; then
                MASTER_SELECTIONS[4]=1
                ensure_active_index 4
            fi
        elif [[ "$choice" == "i" || "$choice" == "I" ]]; then
            break
        elif [[ "$choice" == "q" || "$choice" == "Q" ]]; then
            echo -e "\nExiting."; exit 0
        else
            echo -e "\nInvalid option." && sleep 1
        fi
    done

    # --- Final Pre-Installation Dependency Validation ---
    local validation_warnings=0

    # 1. Gemini (6) / OpenClaw (15) -> NVM (4)
    if [[ (${MASTER_SELECTIONS[6]} -eq 1 || ${MASTER_SELECTIONS[15]} -eq 1) && ${MASTER_INSTALLED_STATE[4]} -eq 0 && ${MASTER_SELECTIONS[4]} -eq 0 ]]; then
        MASTER_SELECTIONS[4]=1
        validation_warnings=1
        echo -e "\n\e[1;33m[Validation Fix]\e[0m NVM/Node.js auto-added as it is required by Gemini/OpenClaw."
    fi

    # 2. NVIDIA CTK (12) -> Docker (3)
    if [[ ${MASTER_SELECTIONS[12]} -eq 1 && ${MASTER_INSTALLED_STATE[3]} -eq 0 && ${MASTER_SELECTIONS[3]} -eq 0 ]]; then
        MASTER_SELECTIONS[3]=1
        validation_warnings=1
        echo -e "\n\e[1;33m[Validation Fix]\e[0m Docker auto-added as it is required by NVIDIA Container Toolkit."
    fi

    # 3. Local LLM Stack (14) -> Various
    if [[ ${MASTER_SELECTIONS[14]} -eq 1 ]]; then
        if [[ ("$INSTALL_OPENWEBUI" == "y" || "$INSTALL_OPENWEBUI" == "Y") && ${MASTER_SELECTIONS[3]} -eq 0 && ${MASTER_INSTALLED_STATE[3]} -eq 0 ]]; then
            MASTER_SELECTIONS[3]=1
            validation_warnings=1
            echo -e "\n\e[1;33m[Validation Fix]\e[0m Docker auto-added as it is required by Open-WebUI."
        fi
        if [[ "$LLM_BACKEND_CHOICE" == "llama_cuda" && "$HAS_NVIDIA_GPU" == true && ${MASTER_SELECTIONS[10]} -eq 0 && ${MASTER_INSTALLED_STATE[10]} -eq 0 ]]; then
            MASTER_SELECTIONS[10]=1
            validation_warnings=1
            echo -e "\n\e[1;33m[Validation Fix]\e[0m CUDA auto-added as it is required by llama.cpp (CUDA backend)."
        fi
        if [[ ("$INSTALL_OPENWEBUI" == "y" || "$INSTALL_OPENWEBUI" == "Y" || "$LLM_BACKEND_CHOICE" == "llama_cuda") && "$HAS_NVIDIA_GPU" == true && ${MASTER_SELECTIONS[12]} -eq 0 && ${MASTER_INSTALLED_STATE[12]} -eq 0 ]]; then
            MASTER_SELECTIONS[12]=1
            validation_warnings=1
            echo -e "\n\e[1;33m[Validation Fix]\e[0m NVIDIA Container Toolkit auto-added as it is required by your LLM/GPU setup."
        fi
    fi

    if [[ $validation_warnings -eq 1 ]]; then
        echo -e "\e[1;36mDependencies resolved. Proceeding with installation...\e[0m"
        sleep 3
    fi

    # --- Disk Space Check ---
    print_info "Checking available disk space..."
    local required_gb=5 # Base requirement for general system updates and basic tools
    if [[ ${MASTER_SELECTIONS[10]} -eq 1 ]]; then required_gb=$((required_gb + 5)); fi # CUDA Toolkit
    if [[ ${MASTER_SELECTIONS[12]} -eq 1 ]]; then required_gb=$((required_gb + 2)); fi # NVIDIA Container Toolkit & Docker usage
    if [[ ${MASTER_SELECTIONS[14]} -eq 1 ]]; then required_gb=$((required_gb + 10)); fi # LLM Models and Open-WebUI image
    
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
        local total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
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
                ${MASTER_FUNCS[$i]}
            fi
        done

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
                        echo -e " \e[1;32m[x]\e[0m $((i+1)). ${EXPOSE_OPTIONS[$i]}"
                    else
                        echo -e " [ ] $((i+1)). ${EXPOSE_OPTIONS[$i]}"
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
                            local tmp_json=$(mktemp)
                            sudo jq '.gateway.bind = "0.0.0.0"' "$oc_conf" > "$tmp_json" && \
                            sudo mv "$tmp_json" "$oc_conf" && sudo chown "$TARGET_USER":"$TARGET_USER" "$oc_conf"
                            sudo ufw allow $current_oc_port/tcp &>/dev/null || true
                            exposed_msg+="  - OpenClaw Gateway is at IP:$current_oc_port\n"
                            ;;
                    esac
                fi
            done
            if [[ $applied_exposures -eq 1 ]]; then print_success "Exposure settings applied."; fi
        fi

        if [[ "$EXPOSE_OPENCLAW" == "y" ]]; then
            exposed_msg+="  - OpenClaw Gateway is at IP:$OPENCLAW_PORT\n"
        fi
        if [[ "$EXPOSE_LLM_ENGINE" == "y" ]]; then
            if [[ "$LLM_BACKEND_CHOICE" == "ollama" ]]; then
                exposed_msg+="  - Ollama is at IP:11434\n"
            else
                exposed_msg+="  - llama.cpp is at IP:8080\n"
            fi
        fi
        if [[ "$INSTALL_OPENWEBUI" == "y" ]]; then
            exposed_msg+="  - Open-WebUI is at IP:8081\n"
        fi
        
        if [[ "${POST_INSTALL_ACTIONS[*]}" == *"ufw"* || -n "$exposed_msg" || "$ENABLE_UFW_AUTOMATICALLY" == "y" ]]; then
            echo -e "\n\e[1;33mIMPORTANT: Firewall rules have been configured, but UFW is NOT enabled by default.\e[0m"
            echo -e "\e[1;36mThe following UFW rules have been prepared:\e[0m"
            echo "  - ALLOW 22/tcp (SSH)"
            if [[ "$exposed_msg" == *"OpenClaw Gateway"* ]]; then echo "  - ALLOW $current_oc_port/tcp (OpenClaw Gateway)"; fi
            if [[ "$EXPOSE_LLM_ENGINE" == "y" ]]; then
                if [[ "$LLM_BACKEND_CHOICE" == "ollama" ]]; then echo "  - ALLOW 11434/tcp (Ollama API)"; else echo "  - ALLOW 8080/tcp (llama.cpp Server)"; fi
            fi
            if [[ "$INSTALL_OPENWEBUI" == "y" ]]; then echo "  - ALLOW 8081/tcp (Open-WebUI)"; fi
            echo ""
            
            local enable_ufw="n"
            if [[ "$ENABLE_UFW_AUTOMATICALLY" == "y" ]]; then
                print_info "Auto-enabling UFW firewall as selected in the configuration menu..."
                enable_ufw="y"
            else
                read -p "Do you want to enable the UFW firewall now? (WARNING: Ensure SSH access is allowed if remote) [y/N]: " enable_ufw < /dev/tty
            fi
            
            if [[ "$enable_ufw" == "y" || "$enable_ufw" == "Y" ]]; then
                sudo ufw default deny incoming &>/dev/null || true
                sudo ufw allow 22/tcp &>/dev/null || true
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
        echo -e "\n\e[1;33mA system reboot is highly recommended to ensure all drivers (like NVIDIA vGPU) are loaded correctly.\e[0m"
        read -p "Do you want to reboot now? [y/N]: " reboot_choice
        if [[ "$reboot_choice" == "y" || "$reboot_choice" == "Y" ]]; then
            print_info "Rebooting system..."
            sudo reboot
        fi
    fi
}

# --- Script Entry Point ---
main
