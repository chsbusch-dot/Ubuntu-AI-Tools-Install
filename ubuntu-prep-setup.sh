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
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl git wget unzip lsb-release gnupg ca-certificates
    print_success "Base dependencies are present."
}
# --- Installation Functions ---

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

# Placeholders for API keys and secrets
export GITHUB_TOKEN=""
export AWS_SECRET_ACCESS_KEY=""
export OPENAI_API_KEY=""
export GEMINI_PRO_API_KEY=""
export CLAUDE_API_KEY=""
export NVIDIA_NGC_API_KEY=""
EOF

    # Add sourcing of .zshenv_secrets to .zshrc
    if ! grep -q ".zshenv_secrets" ~/.zshrc; then
        echo -e '\n# Source secrets file if it exists\nif [[ -f ~/.zshenv_secrets ]]; then\n  source ~/.zshenv_secrets\nfi' >> ~/.zshrc
    fi

    print_info "Adding custom Zsh prompt..."
    # Add custom prompt to override the robbyrussell theme default
    echo -e '\n# Custom prompt to show full path\nPROMPT="%{$fg_bold[yellow]%}%n@%m %{$reset_color%}> %{$fg[cyan]%}%/%{$reset_color%} "' >> ~/.zshrc

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
                        "GEMINI_PRO_API_KEY" "CLAUDE_API_KEY" "NVIDIA_NGC_API_KEY"
                    )
                    for key_name in "${keys_to_prompt[@]}"; do
                        read -p "Enter value for ${key_name}: " key_value
                        if [[ -n "$key_value" ]]; then
                            sed -i "s|export ${key_name}=\"\"|export ${key_name}=\"${key_value}\"|" ~/.zshenv_secrets
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
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-pip python3-dev python3-venv build-essential libssl-dev libffi-dev python3-setuptools
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
    print_info "Installing NVIDIA NGC CLI..."
    if ! command -v ngc &> /dev/null; then
        wget --content-disposition https://ngc.nvidia.com/downloads/ngccli_linux.zip && \
        unzip ngccli_linux.zip && \
        echo "y" | ./ngc-cli/ngc-cli/install
        export PATH="$PATH:$(pwd)/ngc-cli"
    else
        print_info "NGC CLI is already installed."
    fi

    read -p "Do you want to configure NGC CLI now? (requires API key) [y/N]: " confirm_ngc
    if [[ "$confirm_ngc" == "y" || "$confirm_ngc" == "Y" ]]; then
        ngc config set

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

                tmp_dir=$(mktemp -d)
                if ngc registry resource download-version "${latest_driver_resource}" --dest "$tmp_dir"; then
                    zip_file=$(find "$tmp_dir" -name '*.zip' | head -n 1)
                    if [[ -n "$zip_file" ]]; then
                        print_info "Unzipping ${zip_file}..."
                        unzip -o "$zip_file" -d "$tmp_dir"

                        deb_file=$(find "$tmp_dir" -name '*.deb' | head -n 1)
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
                rm -rf "$tmp_dir"
            fi
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

    print_info "Installing build essentials for native Node modules..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential python3 make g++

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
    print_info "Installing OpenClaw..."
    curl -fsSL https://openclaw.ai/install.sh | bash

    print_info "Onboarding OpenClaw and installing daemon..."
    # The OpenClaw install script adds ~/.local/bin to the PATH in your shell profile.
    # We add it to the current session's PATH to run the next command.
    export PATH="$HOME/.local/bin:$PATH"
    openclaw onboard --install-daemon

    print_success "OpenClaw installation complete."
    POST_INSTALL_ACTIONS+=("nvm") # Modifies path, needs same action as nvm
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
        echo -e "To start using Zsh and activate all newly installed commands (like nvm, node, gemini), you must:"
        echo -e "  \e[1;32mOpen a NEW terminal window.\e[0m"
        echo -e "(Or, log out and log back in)."
        echo ""
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
    )

    clear
    echo -e "\n\e[1;35m--- Ubuntu Prep Script Menu ---\e[0m"
    echo "Use numbers [1-10] to toggle an option. Press 'a' to select all."
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
    check_os
    update_system
    install_base_dependencies

    local selections=(0 0 0 0 0 0 0 0 0 0)
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
    )

    while true; do
        show_menu
        read -p "Your choice: " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#selections[@]} ]; then
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
