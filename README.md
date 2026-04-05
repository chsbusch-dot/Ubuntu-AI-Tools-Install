# Ubuntu Prep Script

This script automates the setup and preparation of a fresh Ubuntu LTS system. It provides an interactive menu to install essential developer tools, software stacks, and configurations, turning a new OS into a ready-to-use development environment.

## Features

- **Interactive Menu**: Choose exactly what you want to install.
- **System Initialization**: Updates and upgrades all system packages.
- **Zsh & Oh My Zsh**: Installs Zsh, Oh My Zsh, and essential plugins (`zsh-autosuggestions`, `zsh-syntax-highlighting`, `zsh-history-substring-search`).
- **Developer Tools**: Installs `git`, `tmux`, `curl`, `wget`, and `micro`.
- **Python Environment**: Sets up `python3`, `pip`, and `venv` along with necessary build tools.
- **Docker**: Installs the latest versions of Docker CE, Docker Compose, and configures user permissions.
- **Node.js Environment**: Installs `nvm` (Node Version Manager) and the latest LTS release of Node.js.
- **NVIDIA Stack**:
    - Installs the NVIDIA NGC CLI.
    - Automatically detects and installs the latest NVIDIA vGPU guest drivers for VMware ESXi.
    - Installs the CUDA Toolkit, NVIDIA Container Toolkit, and cuDNN.
- **AI/ML Tools**: Installs the Google Gemini CLI and OpenClaw.
- **Secure Configuration**: Helps create and manage API keys in a separate `.zsh_secrets` file.
- **Pre-flight Checks**: Verifies the script is running on Ubuntu and not as the root user.

## Prerequisites

- A fresh installation of Ubuntu LTS (tested on 22.04 and later).
- Internet connection.

## Quick Start

To run the script, you can use the following one-liner command. It will download the script from your GitHub repository and execute it directly.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chsbusch-dot/ubuntu-prep/main/ubuntu-prep-setup.sh)"
```

## Manual Installation

Alternatively, you can clone the repository and run the script manually.

```bash
# 1. Clone the repository
git clone https://github.com/chsbusch-dot/ubuntu-prep.git

# 2. Navigate to the directory
cd ubuntu-prep

# 3. Make the script executable
chmod +x ubuntu-prep-setup.sh

# 4. Run the script
./ubuntu-prep-setup.sh
```

## Configuration

### API Keys

The script will create a `~/.zsh_secrets` file to store your API keys securely. You will be prompted to add your keys either one-by-one or by editing the file directly with `nano`. This file is automatically sourced by your `.zshrc` but is ignored by Git to prevent accidental exposure.

## License

This project is licensed under the MIT License. See the LICENSE file for details.