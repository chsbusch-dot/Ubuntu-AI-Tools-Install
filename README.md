# Ubuntu Local AI, Ollama, Llama.cpp CUDA, LibreChat & OpenClaw with Nvidia vGPU driver & token and latest CUDA Prep and Installation Script

This script automates the setup and configuration of a fresh Ubuntu LTS system to run Ollama or Llama.cpp with CUDA, automatically selects and loads the best model for your hardware, and configures powerful Chat UIs (Open-WebUI and LibreChat). It provides an interactive menu to install essential developer tools, software stacks, and configurations, turning a new OS into a ready-to-use AI development environment.

It will download and install the Nvidia Enterprise vGPU drivers and the License token automatically. Then install latest CUDA and CUDNN.

At the end you have fully configured Ollama or Llama.CPP models. OpenWebUI, Librechat and OpenClaw pointing to the local model. Ready to go. 

## Interactive Menus

The script features intuitive, keyboard-driven menus to easily customize your installation without needing to edit configuration files.

**Goal Selection:**
```text
--- Ubuntu Prep Script Menu ---
Hardware: NVIDIA GPU/vGPU Detected
Target User: chris (/home/chris)
Use numbers [1-16] to toggle an option. Press 'a' to select all.
Press 'i' to install selected, or 'q' to quit.
---------------------------------
 [x] 1. Update System Packages (apt update && upgrade) (Required)
 [ ] 2. Install Oh My Zsh & Dev Tools (git, tmux, micro)
 [ ] 3. Install Python Environment
 [ ] 4. Install Docker and Docker Compose
 [ ] 5. Install NVM, Node.js & NPM
 [ ] 6. Install Homebrew
 [ ] 7. Install Google Gemini CLI

 [ ] 8. Install NVIDIA vGPU Driver
 [ ] 9. Install btop (System Monitor)
 [ ] 10. Install nvtop (GPU Monitor)
 [ ] 11. Install CUDA
 [✓] 12. Install gcc compiler
 [ ] 13. Install NVIDIA Container Toolkit
 [ ] 14. Install cuDNN

 [ ] 15. Install Local LLM Support (Ollama, llama.cpp, Open-WebUI, LibreChat)

 [ ] 16. Install OpenClaw
```

**Hardware-Aware Configuration:**
The script dynamically detects your system resources. For example:
- If no NVIDIA GPU is detected, the vGPU and CUDA options automatically disable themselves to prevent broken configurations. You need to rbring the driver and token.
- The **VRAM-Aware LLM Selection** measures your GPU VRAM (or System RAM) and automatically recommends models tailored exactly to your memory limits!
- A built-in disk space checker warns you if your selected options exceed your partition's available storage.

## Features

- **Interactive Menu**: Choose exactly what you want to install, with smart dependency auto-selection and detection of already installed tools `[✓]`.
- **Multi-User Support**: Install user-specific tools to your current user or seamlessly create and configure a new dedicated standard user (bypasses interactive prompts for fast creation).
- **System Initialization**: Updates and upgrades all system packages.
- **Zsh & Oh My Zsh**: Installs Zsh, Oh My Zsh, and essential plugins (`zsh-autosuggestions`, `zsh-syntax-highlighting`, `zsh-history-substring-search`).
- **Developer Tools**: Installs `git`, `tmux`, `curl`, `wget`, `micro`, and the `gcc` compiler.
- **Python Environment**: Sets up `python3`, `pip`, and `venv` along with necessary build tools.
- **Docker**: Installs the latest versions of Docker CE, Docker Compose, and configures user permissions.
- **Node.js Environment**: Installs `nvm` (Node Version Manager) and the latest LTS release of Node.js.
- **Homebrew**: Installs the Homebrew package manager for Linux.
- **NVIDIA Stack**:
    - Installs the NVIDIA vGPU guest drivers via direct download URL or Google Drive sharing link.
    - Optionally installs `btop` and `nvtop` for system and GPU monitoring.
    - Installs the latest CUDA, NVIDIA Container Toolkit, and cuDNN.
    - Dynamically detects GPU hardware and filters menu options accordingly (Multi-GPU compile, compuute verion)
- **AI/ML Tools**: Installs Google Gemini CLI and OpenClaw.
- **Local LLM Support**: 
    - Builds `llama.cpp` from source with CUDA support or installs `ollama`. Single or Multi-GPU comppile. 
    - Sets up **Open-WebUI** and **LibreChat** via Docker with optional automated daily updates and seamless backend integration (auto-generates `librechat.yaml` to connect local APIs).
    - Features a **VRAM-aware model recommendation engine** to automatically select and pull the best LLMs for your specific hardware tier. Also Check here: https://runthisllm.com
    - Automatically configures **CORS (Cross-Origin Resource Sharing)** for both Ollama (`OLLAMA_ORIGINS`) and llama.cpp (`--cors`) so external frontends can securely connect without browser policy errors.
    - Bulletproof model downloading with native progress bars and automatic error-handling/retries for Hugging Face and Ollama repositories.
    - Installs systemd services to run your LLM backend automatically on boot.
- **Security & Networking**: Automatically configures the UFW firewall to secure your exposed network services, LLM endpoints, and SSH.
- **Secure Configuration**: Helps create and manage API keys safely in a separate `.env.secrets` file, immune to special character injection.
- **Model Validation**: Includes a `check-models.sh` utility to automatically validate Hugging Face and Ollama model repositories, including deep `.gguf` file verification and API request deduplication to prevent rate-limiting.
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

The script will create a `~/.env.secrets` file to store your API keys securely. You will be prompted to add your keys either one-by-one or by editing the file directly with `nano`. This file is automatically sourced by your `.bashrc` and `.zshrc` but is ignored by Git to prevent accidental exposure.
 Focus right now is on getting up an running easily on a trusted LAN and qucikly, not security.

nano ~/.env.secrets

Example:

```bash
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
# export SYSTEM_TIMEZONE="America/Los_Angeles"
```

## Feedback &Commercial Use
Let me know if you find this useful.
Let me know if I should add other packages.
If you use this at work, please expense a sponsor payment by clicking the sponsor button above.. 

Here are some I am considering:

Tool	    Stars	    Category	Why
Qdrant	        29K	    Vector DB	Every RAG tool needs one. docker run qdrant/qdrant
SearXNG	        27K	    Web Search	Gives AI agents private web search, used by Open-WebUI
n8n	            183K	Automation	Self-hosted Zapier with native AI agent nodes
AnythingLLM	    54K	    RAG/UI	    Instant doc chat on top of Ollama, no extra setup
vLLM	        75K	    Inference	Production-grade multi-user GPU inference, OpenAI-compatible
faster-whisper	14K	    STT	        pip install speech-to-text, used by Open-WebUI STT
Kokoro TTS	    HF	    TTS	        Near-ElevenLabs quality, 82M params, Docker wrapper available
Aider	        42K	    Coding	    pip install aider-chat — terminal AI pair programmer
OpenHands	    70K	    Agent	    Autonomous coding agent, sandboxed Docker
ComfyUI	        108K	Image	    Node-graph Stable Diffusion/FLUX, GPU required
Tabby	        32K	    Coding	    Self-hosted GitHub Copilot server for VS Code/JetBrains

## License

This project is licensed under the MIT License. See the LICENSE file for details.