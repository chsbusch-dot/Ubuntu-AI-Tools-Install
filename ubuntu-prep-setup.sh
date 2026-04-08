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

# Global array to track post-installation actions
POST_INSTALL_ACTIONS=()

# Global vars for target user
TARGET_USER=""
TARGET_USER_HOME=""
IS_DIFFERENT_USER=false
HAS_NVIDIA_GPU=false
GPU_STATUS=""
LLM_BACKEND_CHOICE=""

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

# Function to configure API keys for either bash or zsh
setup_env_secrets() {
    print_header "Configuring API Keys"
    if [ ! -f "$TARGET_USER_HOME/.env.secrets" ]; then
        print_info "Creating ~/.env.secrets template for API keys..."
        cat <<'EOF' | sudo -u "$TARGET_USER" tee "$TARGET_USER_HOME/.env.secrets" > /dev/null
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
# export NVIDIA_VGPU_DRIVER_URL="ftp://192.168.1.31/shared/.../nvidia.deb"
# export NVIDIA_VGPU_FTP_AUTH="admin:password"
EOF
        sudo chmod 600 "$TARGET_USER_HOME/.env.secrets"
    fi

    if [ -f "$TARGET_USER_HOME/.bashrc" ] && ! sudo grep -q ".env.secrets" "$TARGET_USER_HOME/.bashrc"; then
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
                        "NVIDIA_VGPU_DRIVER_URL" "NVIDIA_VGPU_FTP_AUTH"
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
}

# 0a. Install Oh My Zsh and related tools
install_zsh() {
    print_header "Installing Zsh, Oh My Zsh, and Plugins"
    print_info "Installing packages: zsh, tmux, micro"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y zsh tmux micro

    if [ ! -d "$TARGET_USER_HOME/.oh-my-zsh" ]; then
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
    if [ ! -d "${ZSH_CUSTOM}/plugins/zsh-autosuggestions" ]; then
        sudo -u "$TARGET_USER" -H git clone https://github.com/zsh-users/zsh-autosuggestions "${ZSH_CUSTOM}/plugins/zsh-autosuggestions"
    fi
    # zsh-syntax-highlighting
    if [ ! -d "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting" ]; then
        sudo -u "$TARGET_USER" -H git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting"
    fi
    # zsh-history-substring-search
    if [ ! -d "${ZSH_CUSTOM}/plugins/zsh-history-substring-search" ]; then
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

    print_success "Zsh and plugins installed."
    POST_INSTALL_ACTIONS+=("zsh")
}

# 0. Update system
update_system() {
    print_header "Updating System Packages"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    print_success "System updated and upgraded."
    sleep 2 # Pause briefly so the user can see that it executed
}

# 1. Install Python
install_python() {
    print_header "Installing Python and Virtual Environment Tools"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python-is-python3 python3-pip python3-dev python3-venv libssl-dev libffi-dev python3-setuptools
    print_success "Python environment installed."
}

# 2. Install Docker
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

    print_success "Docker installed successfully."
    POST_INSTALL_ACTIONS+=("docker")
}

# 3, 4, 5. Install NVM, Node, and NPM
install_nvm_node() {
    print_header "Installing NVM, Node.js (LTS), and NPM"
    print_info "Running the NVM installation script silently..."
    # This runs the installer as the target user, which updates their .bashrc/.zshrc.
    # Use -s for curl to silence progress bar, and redirect bash output to /dev/null.
    sudo -u "$TARGET_USER" bash -c "cd \"$TARGET_USER_HOME\" && curl -s -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash > /dev/null 2>&1"

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
    if [ -f "$TARGET_USER_HOME/.zshrc" ] && ! sudo grep -q 'NVM_DIR' "$TARGET_USER_HOME/.zshrc"; then
        print_info "Adding NVM configuration to ~/.zshrc"
        echo -e "\n# NVM Configuration\n${nvm_config_str}" | sudo tee -a "$TARGET_USER_HOME/.zshrc" > /dev/null
    fi
    if [ -f "$TARGET_USER_HOME/.bashrc" ] && ! sudo grep -q 'NVM_DIR' "$TARGET_USER_HOME/.bashrc"; then
        print_info "Adding NVM configuration to ~/.bashrc"
        echo -e "\n# NVM Configuration\n${nvm_config_str}" | sudo tee -a "$TARGET_USER_HOME/.bashrc" > /dev/null
    fi

    local node_version=$(sudo -u "$TARGET_USER" bash -c "$nvm_cmd; node -v")
    local npm_version=$(sudo -u "$TARGET_USER" bash -c "$nvm_cmd; npm -v")

    print_success "NVM, Node.js, and NPM installed."
    print_info "Node version: $node_version, NPM version: $npm_version"
    POST_INSTALL_ACTIONS+=("nvm")
}

# 5. Install NVIDIA vGPU Driver
install_vgpu_driver_from_link() {
    print_header "Installing NVIDIA vGPU Driver from Direct Link"
    read -p "Do you want to install the vGPU guest driver from a direct link? [y/N]: " confirm_vgpu
    if [[ "$confirm_vgpu" != "y" && "$confirm_vgpu" != "Y" ]]; then
        print_info "Skipping vGPU driver installation."
        return 0 # Exit the function gracefully
    fi

    local vgpu_driver_url=""
    local ftp_auth=""

    # Read secrets file if it exists to retrieve URL and Auth, using sudo to bypass strict home directory permissions
    if sudo test -f "$TARGET_USER_HOME/.env.secrets"; then
        vgpu_driver_url=$(sudo bash -c "source \"$TARGET_USER_HOME/.env.secrets\" 2>/dev/null && echo \"\$NVIDIA_VGPU_DRIVER_URL\"" | tr -d '\r')
        ftp_auth=$(sudo bash -c "source \"$TARGET_USER_HOME/.env.secrets\" 2>/dev/null && echo \"\$NVIDIA_VGPU_FTP_AUTH\"" | tr -d '\r')
    fi

    if [[ -z "$vgpu_driver_url" ]]; then
        print_info "Please provide the direct download URL OR a Google Drive sharing link for the vGPU driver."
        print_info "Example FTP link: ftp://192.168.1.31/shared/.../nvidia.deb"
        read -p "Enter the download URL: " vgpu_driver_url
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
        if [[ -n "$ftp_auth" ]]; then
            curl_cmd+=("-u" "$ftp_auth")
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
        print_info "Installing driver from ${downloaded_file_path}..."
        # Pre-install dkms to prevent scary dpkg dependency errors during unpacking
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y dkms
        # Use `dpkg -i` which runs as root and avoids the `_apt` user permission
        # issues that `apt install` can have with local files.
        sudo dpkg -i "$downloaded_file_path" || sudo apt-get -f install -y
        print_success "vGPU driver installed successfully."
        POST_INSTALL_ACTIONS+=("reboot")
    else
        echo "❌ Downloaded file not found at ${downloaded_file_path}."
    fi

    trap - EXIT
    rm -rf -- "$tmp_dir"
}

# 5a. Install System and GPU Monitors
install_monitors() {
    print_header "Installing System & GPU Monitors (btop, nvtop)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y btop nvtop
    print_success "btop and nvtop installed successfully."
}

# 6. Install CUDA Toolkit
install_cuda_toolkit() {
    print_info "Installing CUDA Toolkit..."
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
    if [ -f "$TARGET_USER_HOME/.zshrc" ] && ! sudo grep -q 'CUDA_HOME' "$TARGET_USER_HOME/.zshrc"; then
        print_info "Adding CUDA path to ~/.zshrc"
        echo -e "\n# Add NVIDIA CUDA Toolkit to path\n${cuda_env_str}" | sudo tee -a "$TARGET_USER_HOME/.zshrc" > /dev/null
    fi
    if [ -f "$TARGET_USER_HOME/.bashrc" ] && ! sudo grep -q 'CUDA_HOME' "$TARGET_USER_HOME/.bashrc"; then
        print_info "Adding CUDA path to ~/.bashrc"
        echo -e "\n# Add NVIDIA CUDA Toolkit to path\n${cuda_env_str}" | sudo tee -a "$TARGET_USER_HOME/.bashrc" > /dev/null
    fi
    
    export CUDA_HOME="/usr/local/cuda"
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$CUDA_HOME/extras/CUPTI/lib64:$LD_LIBRARY_PATH"

    print_success "CUDA Toolkit installed."
    POST_INSTALL_ACTIONS+=("nvm") # Re-use 'nvm' flag to trigger the "new terminal" message
}

# 7. Install NVIDIA Container Toolkit
install_container_toolkit() {
    print_info "Installing NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit

    print_info "Configuring Docker to use NVIDIA runtime..."
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker

    print_info "Testing NVIDIA Container Toolkit (this may download a container image)..."
    sudo docker run --rm --gpus all ubuntu:22.04 nvidia-smi || \
        echo "⚠️ Docker NVIDIA test failed. A reboot is likely required to load the NVIDIA drivers."
}

# 8. Install cuDNN
install_cudnn() {
    print_info "Installing cuDNN..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y zlib1g
    # This will install the latest cuDNN compatible with the installed CUDA toolkit
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y install cudnn9-cuda-13 # As requested, for CUDA 13.x
    POST_INSTALL_ACTIONS+=("reboot")
}

# 9. Install Google Gemini CLI
install_gemini_cli_only() {
    print_header "Installing Google Gemini CLI"

    local nvm_cmd="export NVM_DIR=\"$TARGET_USER_HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\""

    # Check if nvm is installed for the target user.
    if ! sudo -u "$TARGET_USER" bash -c "$nvm_cmd; command -v nvm" &> /dev/null; then
        echo "❌ NVM is not installed for user '$TARGET_USER'. Please run the 'Install NVM' option first."
        return 1
    fi

    print_info "Updating npm to the latest version (globally for the current Node version)..."
    sudo -u "$TARGET_USER" bash -c "cd \"$TARGET_USER_HOME\" && $nvm_cmd; npm install -g npm@latest"

    print_info "Installing Google Gemini CLI..."
    print_info "(Note: npm may show deprecation warnings for sub-dependencies, which are generally safe to ignore)"
    sudo -u "$TARGET_USER" bash -c "cd \"$TARGET_USER_HOME\" && $nvm_cmd; npm install -g @google/gemini-cli@latest"
    
    print_success "Google Gemini CLI installed."
    POST_INSTALL_ACTIONS+=("nvm") # Depends on nvm path
}

# 11. Install OpenClaw
install_openclaw() {
    print_header "Installing OpenClaw"

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
    if [ -f "$TARGET_USER_HOME/.zshrc" ] && ! sudo grep -q 'DBUS_SESSION_BUS_ADDRESS' "$TARGET_USER_HOME/.zshrc"; then
        echo -e "\n${systemd_env_str}" | sudo tee -a "$TARGET_USER_HOME/.zshrc" > /dev/null
    fi
    if [ -f "$TARGET_USER_HOME/.bashrc" ] && ! sudo grep -q 'DBUS_SESSION_BUS_ADDRESS' "$TARGET_USER_HOME/.bashrc"; then
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
    if [ -f "$openclaw_config" ]; then
        print_info "Updating OpenClaw gateway configuration..."
        # Use jq to safely update the JSON config file
        local tmp_json_file
        tmp_json_file=$(mktemp)
        sudo jq '.gateway.bind = "0.0.0.0" | .gateway.port = 18789 | .gateway.controlUi.enabled = true' "$openclaw_config" > "$tmp_json_file" && \
        sudo mv "$tmp_json_file" "$openclaw_config" && sudo chown "$TARGET_USER":"$TARGET_USER" "$openclaw_config"
        print_success "OpenClaw gateway configured to bind to 0.0.0.0:18789."
    else
        echo "⚠️  OpenClaw config file not found at ${openclaw_config}. Skipping gateway configuration."
    fi

    print_info "Configuring firewall rules for OpenClaw (UFW)..."
    sudo ufw default deny incoming
    sudo ufw allow 22/tcp # Ensure SSH access is not blocked
    sudo ufw allow 18789/tcp # Allow OpenClaw gateway access
    print_success "UFW rules configured."

    print_success "OpenClaw installation complete."
    POST_INSTALL_ACTIONS+=("nvm" "ufw") # Modifies path, needs same action as nvm
}

# 12. Install Local LLM Support (Ollama, llama.cpp, Open-WebUI)
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

    read -p "Install Open-WebUI (requires Docker & NVIDIA CTK)? [y/N]: " install_openwebui

    if [[ "$install_llamacpp_cpu" == "y" || "$install_llamacpp_cuda" == "y" ]]; then
        print_info "Installing build dependencies for llama.cpp..."
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential git cmake
        
        local cmake_flags="-DGGML_NATIVE=OFF"
        local export_cmd=""

        if [[ "$install_llamacpp_cuda" == "y" ]]; then
            echo -e "\n\e[1;33m1. Lookup the Compute Capability of your NVIDIA devices:\e[0m"
            echo "   CUDA: Lookup Your GPU Compute > https://developer.nvidia.com/cuda-gpus and enter as digits without separator (8.6 -> 86)"
            read -p "Enter compute capability as integer [86]: " compute_cap
            compute_cap=${compute_cap:-86}
            cmake_flags="-DGGML_CUDA=ON -DGGML_NATIVE=OFF -DCMAKE_CUDA_ARCHITECTURES=\"$compute_cap\""
            export_cmd="export CUDA_HOME=\"/usr/local/cuda\"; export PATH=\"\$CUDA_HOME/bin:\$PATH\"; export LD_LIBRARY_PATH=\"\$CUDA_HOME/lib64:\$CUDA_HOME/extras/CUPTI/lib64:\$LD_LIBRARY_PATH\";"
            print_info "Cloning and building llama.cpp with CUDA support..."
        else
            print_info "Cloning and building llama.cpp with CPU support..."
        fi

        sudo -u "$TARGET_USER" bash -c "
            cd \"$TARGET_USER_HOME\"
            if [ ! -d llama.cpp ]; then
                git clone https://github.com/ggerganov/llama.cpp
            fi
            cd llama.cpp
            $export_cmd
            cmake -B build $cmake_flags
            cmake --build build --config Release -j $(nproc)
        "
        print_success "llama.cpp built successfully."
        
        print_info "Installing llama.cpp globally for all users..."
        sudo bash -c "cd \"$TARGET_USER_HOME/llama.cpp\" && cmake --install build --prefix /usr/local"
        print_success "llama.cpp installed globally to /usr/local/bin."

        echo ""
        read -p "Do you want to test llama.cpp with a small model (TinyStories)? [y/N]: " test_llama
        if [[ "$test_llama" == "y" || "$test_llama" == "Y" ]]; then
            print_info "Downloading and running TinyStories model..."
            sudo -u "$TARGET_USER" bash -c "llama-cli --hf-repo raincandy-u/TinyStories-656K-Q8_0-GGUF --hf-file tinystories-656k-q8_0.gguf -p \"Once upon a time,\" -n 128"
        fi

        echo ""
        if [[ "$install_llamacpp_cuda" == "y" ]]; then
            print_info "To run the server, use a command like this (hiding the first compute device if needed):"
            echo 'CUDA_VISIBLE_DEVICES="-0" llama-server --model /srv/models/llama.gguf --port 8081'
        else
            print_info "To run the server, use a command like this:"
            echo 'llama-server --model /srv/models/llama.gguf --port 8081'
        fi
    fi

    if [[ "$install_ollama" == "y" || "$install_ollama" == "Y" ]]; then
        print_info "Installing Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh

        read -p "Do you want to allow external access to Ollama (bind to 0.0.0.0)? [y/N]: " allow_ext
        if [[ "$allow_ext" == "y" || "$allow_ext" == "Y" ]]; then
            print_info "Configuring Ollama for external access..."
            sudo mkdir -p /etc/systemd/system/ollama.service.d
            echo -e "[Service]\nEnvironment=\"OLLAMA_HOST=0.0.0.0\"" | sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null
            sudo systemctl daemon-reload
            sudo systemctl restart ollama
            print_success "Ollama configured for external access."
        fi

        print_info "Verifying Ollama service listening ports..."
        ss -antp | grep :11434 || true
        print_info "Testing Ollama local API..."
        curl http://localhost:11434 -v || true

        print_info "Locally installed Ollama models:"
        ollama list || echo "No models installed yet."
        echo ""
        read -p "Enter a model name to pull (e.g., 'llama3', 'mistral', or press Enter to skip): " ollama_model
        if [[ -n "$ollama_model" ]]; then
            print_info "Pulling $ollama_model..."
            ollama pull "$ollama_model"
            print_success "$ollama_model pulled successfully."
        fi
    fi

    if [[ "$install_openwebui" == "y" || "$install_openwebui" == "Y" ]]; then
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
            docker_cmd+=(-e OLLAMA_BASE_URL=http://127.0.0.1:11434 -v open-webui:/app/backend/data --name open-webui ghcr.io/open-webui/open-webui:main)
            
            "${docker_cmd[@]}"
            print_success "Open-WebUI installed and running on network host."
        fi
    fi
}

# 11. Install Homebrew
install_homebrew() {
    print_header "Installing Homebrew"
    # Note: build-essential is installed as part of base_dependencies

    # Homebrew installs under /home/linuxbrew/.linuxbrew, which is shared, but we check as the target user.
    if ! sudo -u "$TARGET_USER" -i bash -c 'command -v brew' &> /dev/null; then
        print_info "Installing Homebrew non-interactively..."
        # Pre-create the entire directory structure with correct ownership.
        # This entirely bypasses the Homebrew installer's internal sudo checks for standard users.
        sudo mkdir -p /home/linuxbrew/.linuxbrew/{bin,etc,include,lib,sbin,share,var,opt,share/zsh,share/zsh/site-functions,var/homebrew,var/homebrew/linked,Cellar,Caskroom,Frameworks}
        sudo chown -R "$TARGET_USER":"$TARGET_USER" /home/linuxbrew
        # The official non-interactive method. This will also install dependencies.
        sudo -u "$TARGET_USER" -i bash -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    else
        print_info "Homebrew executable found for user '$TARGET_USER'."
    fi

    # The installer should add the path to .profile, but we'll ensure it's in zshrc/bashrc for non-login shells.
    print_info "Verifying Homebrew shell environment in shell configuration..."
    local brew_shellenv_str='eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
    if [ -f "$TARGET_USER_HOME/.zshrc" ] && ! sudo grep -Fq "$brew_shellenv_str" "$TARGET_USER_HOME/.zshrc"; then
        print_info "Adding Homebrew shellenv to ~/.zshrc"
        echo -e "\n# Add Homebrew to PATH\n${brew_shellenv_str}" | sudo tee -a "$TARGET_USER_HOME/.zshrc" > /dev/null
    fi
    if [ -f "$TARGET_USER_HOME/.bashrc" ] && ! sudo grep -Fq "$brew_shellenv_str" "$TARGET_USER_HOME/.bashrc"; then
        print_info "Adding Homebrew shellenv to ~/.bashrc"
        echo -e "\n# Add Homebrew to PATH\n${brew_shellenv_str}" | sudo tee -a "$TARGET_USER_HOME/.bashrc" > /dev/null
    fi

    # No need to source for the current script session, as all brew commands would need to be run via `sudo -u` anyway.

    print_success "Homebrew installation process finished."
    POST_INSTALL_ACTIONS+=("nvm") # Re-use 'nvm' flag to trigger the "new terminal" message
}

# --- Installation Checks ---
check_installations() {
    print_header "Checking for Existing Installations"

    # Note: selections[0] is for 'update_system' and is not pre-checked.

    # 1. Zsh (index 1)
    if [ -d "$TARGET_USER_HOME/.oh-my-zsh" ]; then
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
    if sudo find "$TARGET_USER_HOME/.nvm" -name "gemini" 2>/dev/null | grep -q .; then
        print_info "Found existing Gemini CLI installation."
        MASTER_INSTALLED_STATE[6]=1
    fi

    # 7. vGPU Driver (index 7)
    if command -v nvidia-smi &> /dev/null; then
        print_info "Found existing NVIDIA driver (nvidia-smi)."
        MASTER_INSTALLED_STATE[7]=1
    fi

    # 8. btop & nvtop (index 8)
    if command -v btop &> /dev/null && command -v nvtop &> /dev/null; then
        print_info "Found existing btop and nvtop installations."
        MASTER_INSTALLED_STATE[8]=1
    fi

    # 9. CUDA Toolkit (index 9)
    if [ -f "/usr/local/cuda/bin/nvcc" ]; then
        print_info "Found existing CUDA Toolkit."
        MASTER_INSTALLED_STATE[9]=1
    fi

    # 10. NVIDIA Container Toolkit (index 10)
    if dpkg -l | grep -q 'nvidia-container-toolkit'; then
        print_info "Found existing NVIDIA Container Toolkit."
        MASTER_INSTALLED_STATE[10]=1
    fi

    # 11. cuDNN (index 11)
    if dpkg -l | grep -q 'cudnn9-cuda-13'; then
        print_info "Found existing cuDNN installation."
        MASTER_INSTALLED_STATE[11]=1
    fi

    # 12. Local LLM Stack (index 12)
    local llm_installed=1
    if ! command -v llama-server &> /dev/null; then llm_installed=0; fi
    if ! command -v ollama &> /dev/null; then llm_installed=0; fi
    if ! sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^open-webui$'; then llm_installed=0; fi
    if [[ $llm_installed -eq 1 ]]; then
        print_info "Found existing Local LLM Stack (Ollama, llama.cpp, Open-WebUI)."
        MASTER_INSTALLED_STATE[12]=1
    fi

    # 13. OpenClaw (index 13)
    if [ -f "$TARGET_USER_HOME/.local/bin/openclaw" ]; then
        print_info "Found existing OpenClaw installation."
        MASTER_INSTALLED_STATE[13]=1
    fi
}

# --- Final Summary ---

print_final_summary() {
    # Ensure newly installed binaries are in the script's PATH for verification
    [ -d "/usr/local/cuda/bin" ] && export PATH="/usr/local/cuda/bin:$PATH"

    # Make array unique by converting to a string, sorting, and converting back
    local unique_actions
    unique_actions=$(echo "${POST_INSTALL_ACTIONS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')

    print_header "Installation Verification & Versions"

    if command -v nvidia-smi &> /dev/null; then
        print_info "NVIDIA GPU/vGPU Driver:"
        nvidia-smi
        echo ""
    fi

    if command -v nvcc &> /dev/null; then
        print_info "CUDA Toolkit:"
        nvcc --version
        echo ""
    fi

    if command -v nvidia-ctk &> /dev/null; then
        print_info "NVIDIA Container Toolkit:"
        nvidia-ctk --version
        echo ""
    fi

    if dpkg -l | grep -q libcudnn; then
        print_info "cuDNN Library:"
        dpkg -l | grep libcudnn
        echo ""
    fi

    if [[ -z "$unique_actions" ]]; then
        return
    fi

    print_header "Next Steps & Important Information"

    local shell_changed=0
    if [[ "$unique_actions" == *"zsh"* ]]; then shell_changed=1; fi

    local path_changed=0
    if [[ "$unique_actions" == *"nvm"* ]]; then path_changed=1; fi

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
        if [ -f "$TARGET_USER_HOME/.zshrc" ]; then
            rc_file="$TARGET_USER_HOME/.zshrc"
        elif [ -f "$TARGET_USER_HOME/.bashrc" ]; then
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
        # Hide NVIDIA options (indices 7 to 11) if no GPU is detected
        if [[ "$HAS_NVIDIA_GPU" == false ]] && [[ $master_index -ge 7 && $master_index -le 11 ]]; then
            continue
        fi

        # Visual grouping
        if [[ $master_index -eq 7 && "$HAS_NVIDIA_GPU" == true ]]; then menu_body+="\n"; fi
        if [[ $master_index -eq 12 || $master_index -eq 13 ]]; then menu_body+="\n"; fi

        local line=""
        if [[ ${MASTER_INSTALLED_STATE[$master_index]} -eq 1 ]]; then
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
    echo -e "\n\e[1;35m--- Ubuntu Prep Script Menu ---\e[0m"
    echo -e "Hardware: $GPU_STATUS"
    echo -e "Target User: \e[1;36m$TARGET_USER\e[0m ($TARGET_USER_HOME)"
    echo "Use numbers [1-$((ui_num-1))] to toggle an option. Press 'a' to select all."
    echo "Press 'i' to install selected, or 'q' to quit."
    echo "---------------------------------"
    echo -e -n "$menu_body"
    echo "---------------------------------"
}

main() {
    check_not_root
    check_sudo_privileges
    check_os
    determine_target_user
    detect_gpu

    local MASTER_OPTIONS=(
        "Update System Packages (apt update && upgrade)"
        "Install Oh My Zsh & Dev Tools (git, tmux, micro)"
        "Install Python Environment"
        "Install Docker and Docker Compose"
        "Install NVM, Node.js & NPM"
        "Install Homebrew"
        "Install Google Gemini CLI"
        "Install NVIDIA vGPU Driver"
        "Install btop & nvtop (System/GPU Monitors)"
        "Install CUDA Toolkit"
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
        install_gemini_cli_only
        install_vgpu_driver_from_link
        install_monitors
        install_cuda_toolkit
        install_container_toolkit
        install_cudnn
        install_local_llm
        install_openclaw
    )

    local MASTER_SELECTIONS=(0 0 0 0 0 0 0 0 0 0 0 0 0 0)
    local MASTER_INSTALLED_STATE=(0 0 0 0 0 0 0 0 0 0 0 0 0 0)
    local ACTIVE_INDICES=()
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

    if [[ ${GOAL_SELECTIONS[0]} -eq 1 ]]; then ACTIVE_INDICES+=(0 1 2 3 4 5 6 13); fi
    if [[ ${GOAL_SELECTIONS[1]} -eq 1 ]]; then ACTIVE_INDICES+=(7 8 9 10 11); fi
    if [[ ${GOAL_SELECTIONS[2]} -eq 1 ]]; then ACTIVE_INDICES+=(12); fi

    IFS=$'\n' ACTIVE_INDICES=($(sort -n <<<"${ACTIVE_INDICES[*]}"))
    unset IFS

    check_installations

    while true; do
        show_menu
        read -p "Your choice: " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#UI_TO_MASTER[@]} ]; then
            local master_index=${UI_TO_MASTER[$choice]}
            
            if [[ ${MASTER_INSTALLED_STATE[$master_index]} -eq 1 ]]; then
                echo -e "\nOption $((choice)) is already installed." && sleep 1
            else
                # Sub-menu for Local LLM Stack (index 12)
                if [[ $master_index -eq 12 && ${MASTER_SELECTIONS[12]} -eq 0 ]]; then
                    echo -e "\n\e[1;36mSelect Local LLM Backend (Exclusive):\e[0m"
                    echo "  1. Ollama"
                    echo "  2. llama.cpp with CPU"
                    echo "  3. llama.cpp with CUDA"
                    read -p "Your choice [1-3]: " llm_choice
                    case "$llm_choice" in
                        1) LLM_BACKEND_CHOICE="ollama" ;;
                        2) LLM_BACKEND_CHOICE="llama_cpu" ;;
                        3) LLM_BACKEND_CHOICE="llama_cuda" ;;
                        *) echo -e "\nInvalid choice. Cancelling option." && sleep 1; continue ;;
                    esac
                fi

                MASTER_SELECTIONS[$master_index]=$((1 - MASTER_SELECTIONS[$master_index]))

                if [[ $master_index -eq 12 && ${MASTER_SELECTIONS[12]} -eq 0 ]]; then
                    LLM_BACKEND_CHOICE=""
                fi

                # Dependency logic: Gemini CLI (index 6) and OpenClaw (index 13) require NVM (index 4)
                if [[ ($master_index -eq 6 || $master_index -eq 13) && ${MASTER_SELECTIONS[$master_index]} -eq 1 && ${MASTER_INSTALLED_STATE[4]} -eq 0 ]]; then
                    if [[ ${MASTER_SELECTIONS[4]} -eq 0 ]]; then
                        MASTER_SELECTIONS[4]=1
                        ensure_active_index 4
                        echo -e "\n[Auto-selected] NVM/Node.js is required for this installation." && sleep 1.5
                    fi
                elif [[ $master_index -eq 4 && ${MASTER_SELECTIONS[4]} -eq 0 ]]; then
                    local unselected_deps=0
                    if [[ ${MASTER_SELECTIONS[6]} -eq 1 ]]; then MASTER_SELECTIONS[6]=0; unselected_deps=1; fi
                    if [[ ${MASTER_SELECTIONS[13]} -eq 1 ]]; then MASTER_SELECTIONS[13]=0; unselected_deps=1; fi
                    if [[ $unselected_deps -eq 1 ]]; then
                        echo -e "\n[Auto-unselected] Gemini and/or OpenClaw were unselected because they require NVM." && sleep 2
                    fi
                fi

                # Dependency logic for Local LLM Stack (index 12)
                if [[ $master_index -eq 12 && ${MASTER_SELECTIONS[12]} -eq 1 ]]; then
                    local auto_selected=""
                    if [[ ${MASTER_SELECTIONS[3]} -eq 0 && ${MASTER_INSTALLED_STATE[3]} -eq 0 ]]; then MASTER_SELECTIONS[3]=1; ensure_active_index 3; auto_selected+="Docker, "; fi
                    if [[ "$LLM_BACKEND_CHOICE" == "llama_cuda" && "$HAS_NVIDIA_GPU" == true && ${MASTER_SELECTIONS[9]} -eq 0 && ${MASTER_INSTALLED_STATE[9]} -eq 0 ]]; then MASTER_SELECTIONS[9]=1; ensure_active_index 9; auto_selected+="CUDA Toolkit, "; fi
                    if [[ "$HAS_NVIDIA_GPU" == true && ${MASTER_SELECTIONS[10]} -eq 0 && ${MASTER_INSTALLED_STATE[10]} -eq 0 ]]; then MASTER_SELECTIONS[10]=1; ensure_active_index 10; auto_selected+="NVIDIA CTK, "; fi
                    if [[ -n "$auto_selected" ]]; then
                        echo -e "\n[Auto-selected] ${auto_selected%, } required for Local LLM Stack components." && sleep 2
                    fi
                fi
            fi
        elif [[ "$choice" == "a" || "$choice" == "A" ]]; then
            for master_index in "${ACTIVE_INDICES[@]}"; do 
                if [[ ${MASTER_INSTALLED_STATE[$master_index]} -eq 0 ]]; then 
                    MASTER_SELECTIONS[$master_index]=1
                    if [[ $master_index -eq 11 && -z "$LLM_BACKEND_CHOICE" ]]; then LLM_BACKEND_CHOICE="ollama"; fi
                fi
            done
        elif [[ "$choice" == "i" || "$choice" == "I" ]]; then
            break
        elif [[ "$choice" == "q" || "$choice" == "Q" ]]; then
            echo -e "\nExiting."; exit 0
        else
            echo -e "\nInvalid option." && sleep 1
        fi
    done

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
        print_final_summary
        
        if [[ "${POST_INSTALL_ACTIONS[*]}" == *"ufw"* ]]; then
            echo -e "\n\e[1;33mIMPORTANT: Firewall rules for OpenClaw have been configured, but UFW is NOT enabled by default.\e[0m"
            read -p "Do you want to enable the UFW firewall now? (WARNING: Ensure SSH access is allowed if remote) [y/N]: " enable_ufw
            if [[ "$enable_ufw" == "y" || "$enable_ufw" == "Y" ]]; then
                sudo ufw --force enable
                print_success "UFW firewall enabled."
            else
                print_info "UFW remains disabled. You can enable it later with: sudo ufw enable"
            fi
        fi

        echo -e "\n\e[1;32m================================================================\e[0m"
        echo -e "\e[1;32mINSTALLATION COMPLETE!\e[0m"
        if [[ "$IS_DIFFERENT_USER" == true ]]; then
            echo -e "\e[1;33mPlease switch to your new user (\e[1;36m$TARGET_USER\e[1;33m) and run the following command to activate your environment:\e[0m"
            echo -e "\e[1;36msu - $TARGET_USER\e[0m"
        else
            echo -e "\e[1;33mPlease run the following command to activate your new environment:\e[0m"
        fi
        if [ -f "$TARGET_USER_HOME/.zshrc" ] && [[ "$SHELL" == *"zsh"* || "${MASTER_SELECTIONS[1]}" == "1" || "${MASTER_INSTALLED_STATE[1]}" == "1" ]]; then
            echo -e "\e[1;36msource ~/.zshrc\e[0m"
        else
            echo -e "\e[1;36msource ~/.bashrc\e[0m"
        fi
        echo -e "\e[1;32m================================================================\e[0m\n"
    else
        print_info "No options were selected for installation."
    fi
}

# --- Script Entry Point ---
main
