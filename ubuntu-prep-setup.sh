#!/bin/bash
#
# Ubuntu Preparation Script
#
# This script automates the setup of a new Ubuntu system, including
# system updates, developer tools, and specific software stacks.
#
# Reference: https://discourse.ubuntu.com/t/my-powerful-zsh-profile/47395
#

# Exit immediately if a command exits with a non-zero status.
set -e

# Global array to track post-installation actions
POST_INSTALL_ACTIONS=()

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
    # These are required by various installation functions
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y jq build-essential procps curl file git wget unzip lsb-release gnupg ca-certificates
    print_success "Base dependencies are present."
}
# --- Installation Functions ---

# Function to prompt for new user creation
prompt_for_new_user() {
    read -p "Do you want to create a new dedicated user for this setup? [y/N]: " confirm_new_user
    if [[ "$confirm_new_user" == "y" || "$confirm_new_user" == "Y" ]]; then
        local username
        read -p "Enter the new username [openclawuser]: " username
        username=${username:-openclawuser}

        if id "$username" &>/dev/null; then
            print_info "User '$username' already exists. Skipping creation."
        else
            print_info "Creating user '$username'..."
            sudo adduser "$username"
            print_success "Standard user '$username' created successfully."
        fi

        echo -e "\n\e[1;33mIMPORTANT: To continue setup as the new user, you must log in as them.\e[0m"
        print_info "Exiting script. Please run 'su - $username' and then re-run this setup script."
        exit 0
    fi
}

# 0. Update system
update_system() {
    print_header "Updating System Packages"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    print_success "System updated and upgraded."
}

# 0a. Install Oh My Zsh and related tools
install_zsh() {
    print_header "Installing Zsh, Oh My Zsh, and Plugins"
    print_info "Installing packages: zsh, tmux, micro"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y zsh tmux micro

    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        print_info "Installing Oh My Zsh..."
        # The --unattended flag prevents the installer from trying to change the shell, so we do it manually.
        sh -c "$(wget https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)" "" --unattended
    else
        print_info "Oh My Zsh is already installed."
    fi

    print_info "Setting Zsh as the default shell for the current user..."
    sudo chsh -s "$(which zsh)" "$USER"

    # Define Zsh custom plugins directory
    ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

    print_info "Cloning Zsh plugins..."
    # zsh-autosuggestions
    if [ ! -d "${ZSH_CUSTOM}/plugins/zsh-autosuggestions" ]; then
        git clone https://github.com/zsh-users/zsh-autosuggestions "${ZSH_CUSTOM}/plugins/zsh-autosuggestions"
    fi
    # zsh-syntax-highlighting
    if [ ! -d "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting" ]; then
        git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting"
    fi
    # zsh-history-substring-search
    if [ ! -d "${ZSH_CUSTOM}/plugins/zsh-history-substring-search" ]; then
        git clone https://github.com/zsh-users/zsh-history-substring-search "${ZSH_CUSTOM}/plugins/zsh-history-substring-search"
    fi

    print_info "Configuring .zshrc..."
    # Replace the default plugins line with the new one
    sed -i 's/^plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search)/' ~/.zshrc

    print_info "Creating ~/.zshenv_secrets template for API keys..."
    cat <<'EOF' > ~/.zshenv_secrets
# This file is for storing secrets and API keys.
# It is sourced by ~/.zshrc if it exists.
# Make sure this file is NOT committed to version control.

# --- API Key Placeholders ---
# Uncomment and fill in the values for the services you use.

# export GITHUB_TOKEN="your_github_token"
# export AWS_SECRET_ACCESS_KEY="your_aws_secret"
# export OPENAI_API_KEY="your_openai_key"
# export GOOGLE_API_KEY="your_google_api_key"
# export CLAUDE_API_KEY="your_claude_key"
# export NVIDIA_NGC_ORG_ID="your_ngc_org_id"
# export NVIDIA_NGC_API_KEY="your_ngc_key"
EOF

    # Add sourcing of .zshenv_secrets to .zshrc
    if ! grep -q ".zshenv_secrets" ~/.zshrc; then
        echo -e '\n# Source secrets file if it exists\nif [[ -f ~/.zshenv_secrets ]]; then\n  source ~/.zshenv_secrets\nfi' >> ~/.zshrc
    fi

    print_info "Enabling true color support for modern terminals..."
    echo -e '\n# Set COLORTERM to advertise true color support to modern CLI tools\nexport COLORTERM=truecolor' >> ~/.zshrc

    print_info "Adding custom Zsh prompt..."
    # Add custom prompt to override the theme default. Using a heredoc for clarity.
    cat <<'EOP' >> ~/.zshrc

# Custom prompt showing user@host > path >
PROMPT="%{$fg_bold[yellow]%}%n@%m%{$reset_color%} > %{$fg[cyan]%}%/%{$reset_color%} > "
EOP

    # Interactive prompt for API keys
    read -p "Do you want to add API keys now? [y/N]: " add_keys_now
    if [[ "$add_keys_now" == "y" || "$add_keys_now" == "Y" ]]; then
        PS3="Please choose how to add your keys: "
        options=("Enter keys one-by-one" "Edit file manually with nano" "Skip")
        select opt in "${options[@]}"; do
            case $opt in
                "Enter keys one-by-one")
                    print_info "Please enter the value for each key. Press Enter to skip a key."
                    keys_to_prompt=(
                        "GITHUB_TOKEN" "AWS_SECRET_ACCESS_KEY" "OPENAI_API_KEY"
                        "GOOGLE_API_KEY" "CLAUDE_API_KEY" "NVIDIA_NGC_ORG_ID" "NVIDIA_NGC_API_KEY"
                    )
                    for key_name in "${keys_to_prompt[@]}"; do
                        read -p "Enter value for ${key_name}: " key_value
                        if [[ -n "$key_value" ]]; then
                            sed -i "s|# export ${key_name}=.*|export ${key_name}=\"${key_value}\"|" ~/.zshenv_secrets
                        fi
                    done
                    print_success "API keys have been saved to ~/.zshenv_secrets."
                    break
                    ;;
                "Edit file manually with nano")
                    print_info "Opening ~/.zshenv_secrets with nano. Save with Ctrl+X, then Y, then Enter."
                    nano ~/.zshenv_secrets
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

    print_success "Zsh and plugins installed."
    POST_INSTALL_ACTIONS+=("zsh")
}

# 1. Install Python
install_python() {
    print_header "Installing Python and Virtual Environment Tools"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-pip python3-dev python3-venv libssl-dev libffi-dev python3-setuptools
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
    sudo usermod -aG docker $USER

    print_success "Docker installed successfully."
    POST_INSTALL_ACTIONS+=("docker")
}

# 3, 4, 5. Install NVM, Node, and NPM
install_nvm_node() {
    print_header "Installing NVM, Node.js (LTS), and NPM"
    print_info "Running the NVM installation script silently..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash > /dev/null 2>&1
    print_info "NVM installation script executed. Sourcing NVM to continue..."

    # Source NVM for the current script session
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    print_info "Installing the latest LTS version of Node.js..."
    nvm install --lts

    print_success "NVM, Node.js, and NPM installed."
    print_info "Node version: $(node -v), NPM version: $(npm -v)"
    POST_INSTALL_ACTIONS+=("nvm")
}

# 5. Install NVIDIA vGPU Driver
install_nvidia_vgpu() {
    print_header "Installing NVIDIA vGPU Driver"
    print_info "Checking NVIDIA NGC CLI installation..."

    # A correct installation is the presence of the executable in /opt/ngc-cli
    if [[ -f "/opt/ngc-cli/ngc" ]]; then
        print_info "NGC CLI is already installed in /opt/ngc-cli."
    else
        print_info "NGC CLI not found. Performing fresh installation..."

        local tmp_dir
        tmp_dir=$(mktemp -d)

        # Use a trap to ensure the temp directory is cleaned up on exit or error
        trap 'rm -rf -- "$tmp_dir"' EXIT

        local ngc_zip_path="${tmp_dir}/ngccli_linux.zip"
        local ngc_cli_url="https://api.ngc.nvidia.com/v2/resources/nvidia/ngc-apps/ngc_cli/versions/4.16.0/files/ngccli_linux.zip"
        local ngc_cli_sha256="ce6a54a60c0adf78347fd9851cffefe6b5d8a0b7a2d7134e1b52646f0fd6ff11"

        print_info "Downloading NGC CLI from NVIDIA..."
        wget "$ngc_cli_url" -qO "$ngc_zip_path"

        print_info "Verifying SHA256 checksum of the downloaded file..."
        echo "$ngc_cli_sha256  $ngc_zip_path" | sha256sum --check --status
        print_success "SHA256 checksum is valid."

        print_info "Unzipping the NGC CLI..."
        unzip -o -q "$ngc_zip_path" -d "$tmp_dir"

        print_info "Verifying MD5 checksums of the unzipped files..."
        (cd "$tmp_dir" && find ngc-cli/ -type f -exec md5sum {} + | LC_ALL=C sort | md5sum -c ngc-cli.md5)
        print_success "MD5 checksums are valid."

        print_info "Installing NGC CLI to /opt/ngc-cli..."
        sudo rm -rf /opt/ngc-cli # Clean up any previous installation
        sudo mv "${tmp_dir}/ngc-cli" /opt/

        # The trap will handle cleanup, but we can be explicit
        rm -rf -- "$tmp_dir"
        trap - EXIT # Clear the trap

        print_success "NVIDIA NGC CLI installed and verified."
    fi

    # Always ensure the user's shell config files are correctly set up.
    # This makes the script idempotent and self-healing.
    print_info "Verifying NGC CLI path in shell configuration..."
    local ngc_path_str='export PATH="/opt/ngc-cli:$PATH"'
    if [ -f "$HOME/.zshrc" ] && ! grep -qE '^[[:space:]]*export[[:space:]]+PATH=.*"/opt/ngc-cli"' "$HOME/.zshrc"; then
        print_info "Adding NGC CLI path to ~/.zshrc"
        echo -e "\n# Add NVIDIA NGC CLI to path\n${ngc_path_str}" >> "$HOME/.zshrc"
    fi
    if [ -f "$HOME/.bashrc" ] && ! grep -qE '^[[:space:]]*export[[:space:]]+PATH=.*"/opt/ngc-cli"' "$HOME/.bashrc"; then
        print_info "Adding NGC CLI path to ~/.bashrc"
        echo -e "\n# Add NVIDIA NGC CLI to path\n${ngc_path_str}" >> "$HOME/.bashrc"
    fi

    # Add the path for the current script session so we can run 'ngc' immediately
    export PATH="/opt/ngc-cli:$PATH"
    POST_INSTALL_ACTIONS+=("nvm") # Re-use 'nvm' flag to trigger the "new terminal" message

    read -p "Do you want to configure NGC CLI now? (requires API key) [y/N]: " confirm_ngc
    if [[ "$confirm_ngc" != "y" && "$confirm_ngc" != "Y" ]]; then
        print_info "Skipping NGC configuration."
        return 0 # Exit the function gracefully
    fi

    # --- Start NGC Configuration ---
    print_info "Launching interactive NGC configuration..."
    
    local ngc_api_key_found=false
    local ngc_org_id_found=false
    
    if [ -f "$HOME/.zshenv_secrets" ]; then
        # Check if a key has been set in the secrets file to provide a helpful message.
        if grep -qE '^[[:space:]]*export[[:space:]]+NVIDIA_NGC_API_KEY=' "$HOME/.zshenv_secrets"; then ngc_api_key_found=true; fi
        if grep -qE '^[[:space:]]*export[[:space:]]+NVIDIA_NGC_ORG_ID=' "$HOME/.zshenv_secrets"; then ngc_org_id_found=true; fi
    fi

    echo -e "\e[1;33mIMPORTANT: You will be prompted for your NGC CLI configuration.\e[0m"
    echo -e "\e[1;36mFollow these steps carefully:\e[0m"
    
    if [[ "$ngc_api_key_found" == true ]]; then
        print_info "1. An API key was found in ~/.zshenv_secrets. Please copy it from there and paste it when prompted."
    else
        print_info "1. No API key was found in your secrets file. Please have your key ready to paste when prompted."
    fi

    if [[ "$ngc_org_id_found" == true ]]; then
        print_info "2. An Org ID was found in ~/.zshenv_secrets. Please copy it from there."
        print_info "   When prompted for 'Enter org [no-org]. Choices: [...]', you MUST type or paste your Org ID. Pressing Enter will NOT work."
    else
        print_info "2. No Org ID was found in your secrets file."
        print_info "   When prompted for 'Enter org [no-org]. Choices: [...]', you MUST type or paste one of the provided choices. Pressing Enter will NOT work."
    fi
    
    print_info "3. For 'Enter team [no-team]', you can usually press Enter to accept the default ('no-team')."
    print_info "4. For 'Enter ace [no-ace]', you can usually press Enter to accept the default ('no-ace')."
    print_info "5. For 'Enter CLI output format type [ascii]', you can usually press Enter to accept the default ('ascii')."
    echo ""

    # Run the interactive setup and let the user handle it.
    # This is the most reliable method given the tool's complex interactivity.
    if ngc config set; then
        print_success "NGC CLI configured successfully."
        print_info "(A 'grpc_wait_for_shutdown' error may appear, but it is generally safe to ignore if the config was saved.)"
    else
        echo "❌ Failed to configure NGC CLI. Please try manually with 'ngc config set'."
    fi

    # --- Start vGPU Driver Install ---
    read -p "Attempt automatic install of latest vGPU guest driver? (For VMware ESXi) [y/N]: " confirm_vgpu
    if [[ "$confirm_vgpu" == "y" || "$confirm_vgpu" == "Y" ]]; then
        print_info "Searching for the latest vGPU guest driver for your OS..."
        
        # Get Ubuntu version code like '2204' from '22.04'
        os_version_code=$(lsb_release -rs | tr -d '.')

        # Find the latest driver resource from NGC.
        # We query for drivers matching our OS, sort them by version (-V), and get the last one (latest).
        latest_driver_resource=$(ngc registry resource list "nvidia/vgpu/vgpu-for-compute-guest-driver-*-ubuntu${os_version_code}" | \
                                    grep "vgpu-for-compute-guest-driver" | \
                                    tr -d '\r' | \
                                    sort -V | \
                                    tail -n 1)

        if [[ -z "$latest_driver_resource" ]]; then
            echo "❌ Could not automatically find a vGPU driver for Ubuntu ${os_version_code}."
            print_info "To find the vGPU driver manually, run:"
            echo 'ngc registry resource list "nvidia/vgpu/vgpu-for-compute-guest-driver-*"'
        else
            print_info "Found latest driver resource: ${latest_driver_resource}"
            print_info "Downloading... (This may take a while)"

            local driver_tmp_dir
            driver_tmp_dir=$(mktemp -d)
            if ngc registry resource download-version "${latest_driver_resource}" --dest "$driver_tmp_dir"; then
                local zip_file
                zip_file=$(find "$driver_tmp_dir" -name '*.zip' | head -n 1)
                if [[ -n "$zip_file" ]]; then
                    print_info "Unzipping ${zip_file}..."
                    unzip -o -q "$zip_file" -d "$driver_tmp_dir"

                    local deb_file
                    deb_file=$(find "$driver_tmp_dir" -name '*.deb' | head -n 1)
                    if [[ -n "$deb_file" ]]; then
                        print_info "Installing ${deb_file}..."
                        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb_file"
                        print_success "vGPU driver installed successfully."
                    else
                        echo "❌ Could not find a .deb file in the downloaded archive."
                    fi
                else
                    echo "❌ Could not find a .zip file in the downloaded resource."
                fi
            else
                echo "❌ Failed to download driver from NGC."
            fi
            rm -rf "$driver_tmp_dir"
        fi
    fi
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
    local cuda_path_str='export PATH="/usr/local/cuda/bin:$PATH"'
    if [ -f "$HOME/.zshrc" ] && ! grep -qE '^[[:space:]]*export[[:space:]]+PATH=.*"/usr/local/cuda/bin"' "$HOME/.zshrc"; then
        print_info "Adding CUDA path to ~/.zshrc"
        echo -e "\n# Add NVIDIA CUDA Toolkit to path\n${cuda_path_str}" >> "$HOME/.zshrc"
    fi
    if [ -f "$HOME/.bashrc" ] && ! grep -qE '^[[:space:]]*export[[:space:]]+PATH=.*"/usr/local/cuda/bin"' "$HOME/.bashrc"; then
        print_info "Adding CUDA path to ~/.bashrc"
        echo -e "\n# Add NVIDIA CUDA Toolkit to path\n${cuda_path_str}" >> "$HOME/.bashrc"
    fi

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
    # Ensure NVM and NPM are available by sourcing NVM if it exists
    if ! command -v nvm &> /dev/null; then
        print_info "NVM not found. Attempting to source it for this session..."
        export NVM_DIR="$HOME/.nvm"
        if [ -s "$NVM_DIR/nvm.sh" ]; then
            # shellcheck source=/dev/null
            \. "$NVM_DIR/nvm.sh"
        else
            echo "❌ NVM is not installed. Please run the 'Install NVM' option first."
            return 1 # Use return to avoid exiting the whole script
        fi
    fi

    if ! command -v npm &> /dev/null; then
        echo "❌ Node.js/NPM is not installed via NVM. Please run option 5 'Install NVM, Node.js & NPM' first."
        return 1
    fi

    print_info "Updating npm to the latest version (globally for the current Node version)..."
    # Using npm with nvm does not require sudo for global packages
    npm install -g npm@latest

    print_info "Installing Google Gemini CLI..."
    print_info "(Note: npm may show deprecation warnings for sub-dependencies, which are generally safe to ignore)"
    # Using npm with nvm does not require sudo for global packages
    npm install -g @google/gemini-cli@latest
    print_success "Google Gemini CLI installed."
    POST_INSTALL_ACTIONS+=("nvm") # Depends on nvm path
}

# 10. Install OpenClaw
install_openclaw() {
    print_header "Installing OpenClaw"

    print_info "Enabling user lingering to allow services to run after logout..."
    sudo loginctl enable-linger "$(whoami)"

    print_info "Installing OpenClaw..."
    curl -fsSL https://openclaw.ai/install.sh | bash

    print_info "Onboarding OpenClaw and installing daemon..."
    # The OpenClaw install script adds ~/.local/bin to the PATH in your shell profile.
    # We add it to the current session's PATH to run the next command.
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export PATH="$HOME/.local/bin:$PATH"
    openclaw onboard --install-daemon

    local openclaw_config="$HOME/.openclaw/openclaw.json"
    if [ -f "$openclaw_config" ]; then
        print_info "Updating OpenClaw gateway configuration..."
        # Use jq to safely update the JSON config file
        jq '.gateway.bind = "0.0.0.0" | .gateway.port = 18789 | .gateway.controlUi.enabled = true' "$openclaw_config" > "${openclaw_config}.tmp" && \
        mv "${openclaw_config}.tmp" "$openclaw_config"
        print_success "OpenClaw gateway configured to bind to 0.0.0.0:18789."
    else
        echo "⚠️  OpenClaw config file not found at ${openclaw_config}. Skipping gateway configuration."
    fi

    print_info "Configuring firewall rules for OpenClaw (UFW)..."
    sudo ufw default deny incoming
    sudo ufw allow 22/tcp # Ensure SSH access is not blocked
    sudo ufw allow 18789/tcp # Allow OpenClaw gateway access
    print_success "UFW rules configured."
    echo -e "\e[1;33mIMPORTANT: The firewall has been configured but is NOT enabled by default.\e[0m"
    print_info "To enable the firewall, you can run: sudo ufw enable"

    print_success "OpenClaw installation complete."
    POST_INSTALL_ACTIONS+=("nvm") # Modifies path, needs same action as nvm
}

# 11. Install Homebrew
install_homebrew() {
    print_header "Installing Homebrew"
    # Note: build-essential is installed as part of base_dependencies

    # Check for brew command existence in the standard Linux location
    if [ ! -f "/home/linuxbrew/.linuxbrew/bin/brew" ]; then
        print_info "Installing Homebrew non-interactively..."
        # The official non-interactive method. This will also install dependencies.
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
        print_info "Homebrew executable found."
    fi

    # The installer adds the path to .profile, but we'll ensure it's in zshrc/bashrc for non-login shells.
    print_info "Verifying Homebrew shell environment in shell configuration..."
    local brew_shellenv_str='eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
    if [ -f "$HOME/.zshrc" ] && ! grep -Fq "$brew_shellenv_str" "$HOME/.zshrc"; then
        print_info "Adding Homebrew shellenv to ~/.zshrc"
        echo -e "\n# Add Homebrew to PATH\n${brew_shellenv_str}" >> "$HOME/.zshrc"
    fi
    if [ -f "$HOME/.bashrc" ] && ! grep -Fq "$brew_shellenv_str" "$HOME/.bashrc"; then
        print_info "Adding Homebrew shellenv to ~/.bashrc"
        echo -e "\n# Add Homebrew to PATH\n${brew_shellenv_str}" >> "$HOME/.bashrc"
    fi

    print_info "Sourcing Homebrew for the current script session..."
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

    print_success "Homebrew installation process finished."
    POST_INSTALL_ACTIONS+=("nvm") # Re-use 'nvm' flag to trigger the "new terminal" message
}

# --- Final Summary ---

print_final_summary() {
    # Make array unique by converting to a string, sorting, and converting back
    local unique_actions
    unique_actions=$(echo "${POST_INSTALL_ACTIONS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')

    if [[ -z "$unique_actions" ]]; then
        return
    fi

    print_header "Next Steps & Important Information"

    local shell_changed=0
    if [[ "$unique_actions" == *"zsh"* ]]; then shell_changed=1; fi

    local path_changed=0
    if [[ "$unique_actions" == *"nvm"* ]]; then path_changed=1; fi

    if [[ "$unique_actions" == *"docker"* ]]; then
        print_info "To use Docker without 'sudo', you must LOG OUT and LOG BACK IN."
        print_info "After logging back in, you can test your installation with: docker run hello-world"
        echo "" # Newline for spacing
    fi

    if [[ $shell_changed -eq 1 ]]; then
        echo -e "\e[1;33mYour default shell has been changed to Zsh.\e[0m"
        echo -e "To start using Zsh and activate all newly installed commands (like nvm, node, gemini), you must either:"
        echo -e "  1. \e[1;32mOpen a NEW terminal window.\e[0m (Recommended)"
        echo -e "  2. OR, paste the following command into your current terminal:"
        echo "source $HOME/.zshrc"
        echo "" # Newline for spacing
    elif [[ $path_changed -eq 1 ]]; then
        # Determine the correct rc file based on the user's default shell
        local rc_file=""
        if [[ "$SHELL" == */zsh ]]; then
            rc_file="$HOME/.zshrc"
        elif [[ "$SHELL" == */bash ]]; then
            rc_file="$HOME/.bashrc"
        fi
        echo -e "\e[1;33mTo activate newly installed commands (like nvm, node, gemini), you must either:\e[0m"
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
    # This function takes the selection array by reference to display the state
    local options=(
        "Install Oh My Zsh & Dev Tools (git, tmux, micro)"
        "Install Python Environment"
        "Install Docker and Docker Compose"
        "Install NVM, Node.js & NPM"
        "Install NVIDIA vGPU Driver"
        "Install CUDA Toolkit"
        "Install NVIDIA Container Toolkit"
        "Install cuDNN"
        "Install Google Gemini CLI"
        "Install OpenClaw"
        "Install Homebrew"
    )

    clear
    echo -e "\n\e[1;35m--- Ubuntu Prep Script Menu ---\e[0m"
    echo "Use numbers [1-11] to toggle an option. Press 'a' to select all."
    echo "Press 'i' to install selected, or 'q' to quit."
    echo "---------------------------------"

    for i in "${!options[@]}"; do
        if [[ ${selections[i]} -eq 1 ]]; then
            echo -e " \e[1;32m[x]\e[0m $((i+1)). ${options[$i]}"
        else
            echo -e " [ ] $((i+1)). ${options[$i]}"
        fi
    done
    echo "---------------------------------"
}

main() {
    check_not_root
    prompt_for_new_user
    check_os
    update_system
    install_base_dependencies

    local selections=(0 0 0 0 0 0 0 0 0 0 0)
    local funcs=(
        install_zsh
        install_python
        install_docker
        install_nvm_node
        install_nvidia_vgpu
        install_cuda_toolkit
        install_container_toolkit
        install_cudnn
        install_gemini_cli_only
        install_openclaw
        install_homebrew
    )

    while true; do
        show_menu
        read -p "Your choice: " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#funcs[@]} ]; then
            local index=$((choice - 1))
            selections[index]=$((1 - selections[index]))
        elif [[ "$choice" == "a" || "$choice" == "A" ]]; then
            for i in "${!selections[@]}"; do selections[i]=1; done
        elif [[ "$choice" == "i" || "$choice" == "I" ]]; then
            break
        elif [[ "$choice" == "q" || "$choice" == "Q" ]]; then
            echo -e "\nExiting."; exit 0
        else
            echo -e "\nInvalid option." && sleep 1
        fi
    done

    echo -e "\n--- Starting Installation ---"
    local something_installed=0
    for i in "${!selections[@]}"; do
        if [[ ${selections[$i]} -eq 1 ]]; then
            something_installed=1
            ${funcs[$i]}
        fi
    done

    if [[ $something_installed -eq 1 ]]; then
        print_success "Selected installations are complete."
        print_final_summary
    else
        print_info "No options were selected for installation."
    fi
}

# --- Script Entry Point ---
main
