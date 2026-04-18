# Ubuntu Local AI, Ollama, Llama.cpp CUDA, LibreChat & OpenClaw with Nvidia vGPU driver & token and latest CUDA Prep and Installation Script

This script automates the setup and configuration of a fresh Ubuntu LTS Server system to turn-key Openclaw, Open Web UI or Librechat UI with local models. 

It will download and install the Nvidia Enterprise vGPU drivers (or regular Nvidia GPU Drivers) and install the Nividia Enterprise License token automatically. Then install latest CUDA, Nvidia Container Toolkit and CuDNN.

It will install and run Ollama or compile Llama.cpp with CUDA (Single or Multi-GPU), automatically selects and loads and configure the best model for your hardware from 8Gb to 96GB VRAM, and configures powerful Chat UIs (Open-WebUI and LibreChat). It provides an interactive menu to install essential developer tools, software stacks, and configurations, turning a new OS into a ready-to-use AI development environment.

At the end you have working and configured Openclaw with Ollama or Llama.CPP models. OpenWebUI, Librechat and OpenClaw pointing to the local model. Ready to go. 

You still need to harden and secure all of them, especially Openclaw, if you are running all of this on a VPS. 

Once LLama.CPP is installed you can use the script to quickly reconfigure its parameters like context window (-ctx), MoE (), CPU Ram offloading (-ngl), Flash Attention, etc.

I know it's a big script. I wanted a single command, I can paste anywhere with zero dependencies, that's why I didnt use ansible or a modular script. :) 

## Quick Start

To run the script, you can use the following one-liner command. It will download the script from your GitHub repository and execute it directly.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chsbusch-dot/ubuntu-prep/main/ubuntu-prep-setup.sh)"
```

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


**Reconfigure LLama.CPP on the fly:**
```text
┌──────────────────────────────────────────────────────────┐
│  1. Context size:     [131072] tokens                    │
│  2. KV cache type:    [q4_0]  (K and V matched)          │
│  3. CPU MoE offload:  [on]                               │
│  4. Flash attention:  [on]                               │
│  5. Ubatch size:      [512]                              │
│  6. GPU layers:       [99]  (-ngl / --fit)               │
│                                                          │
│  Model weights:    4 GB                                  │
│  KV cache:         2.4 GB                                │
│  Runtime overhead: ~0.5 GB                               │
│  ───────────────                                         │
│  Estimated total:  6.9 / 8 GB  ✅                        │
│                                                          │
│  [c] Confirm  [1-6] Change  [d] Defaults                 │
└──────────────────────────────────────────────────────────┘
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
    - Features a **VRAM-aware model recommendation engine** to automatically select and pull the best LLMs for your specific hardware tier from 8GB VRam to 96GB VRam. Also Check here: https://runthisllm.com
    - Automatically configures **CORS (Cross-Origin Resource Sharing)** for both Ollama (`OLLAMA_ORIGINS`) and llama.cpp (`--cors`) so external frontends can securely connect without browser policy errors.
    - Bulletproof model downloading with native progress bars and automatic error-handling/retries for Hugging Face and Ollama repositories.
    - Installs systemd services to run your LLM backend automatically on boot.
- **Security & Networking**: Automatically configures the UFW firewall to secure your exposed network services, LLM endpoints, and SSH.
- **Secure Configuration**: Helps create and manage API keys safely in a separate `.env.secrets` file, immune to special character injection.
- **Model Validation**: Includes a `check-models.sh` utility to automatically validate Hugging Face and Ollama model repositories, including deep `.gguf` file verification and API request deduplication to prevent rate-limiting.
- **Pre-flight Checks**: Verifies the script is running on Ubuntu and not as the root user.

## Prerequisites

- A fresh installation of Ubuntu LTS Server (tested on 22.04 and later).
- Internet connection.


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

The script will create a `~/.env.secrets` file to store your API keys, locked to owner-only access (chmod 600) so no other user on the system can read them. You will be prompted to add your keys either one-by-one or by editing the file directly with `nano`. This file is automatically sourced by your `.bashrc` and `.zshrc` but is ignored by Git to prevent accidental exposure.
Focus right now is on getting up an running easily on a trusted LAN, not security. Install it on a VPS on your own risk.

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

## Feedback

Let me know if you find this useful and if you encounter any bugs or issues.

I am working on a private V2.0 with support for:

| Tool | Description |
|---|---|
| Nvidia NGC Support | CLI Driver and Model download, requires Nvidia Enterprise License |
| vLLM | Easy-to-use library for LLM inference and serving models |
| Manifest | Smart LLM Model Router |
| Infisical | Secure, Local API Key Secrets Management |

Let me know if you are interested.

Let me know if I should add other packages.
Here are some other packages thatI am considering:

| Tools | Stars | Category | Why |
|---|---:|---|---|
| Qdrant | 29K | Vector DB | Every RAG tool needs one |
| SearXNG | 27K | Web Search | Gives AI agents private web search, used by Open-WebUI |
| n8n | 183K | Automation | Self-hosted Zapier with native AI agent nodes |
| AnythingLLM | 54K | RAG/UI | Instant doc chat on top of Ollama, no extra setup |
| faster-whisper | 14K | STT | used by Open-WebUI STT |
| Kokoro TTS |  | HF TTS | Near-ElevenLabs quality, 82M params, Docker wrapper available |
| Aider | 42K | Coding | terminal AI pair programmer |
| OpenHands | 70K | Agent | Autonomous coding agent, sandboxed Docker |
| ComfyUI | 108K | Image | Node-graph Stable Diffusion/FLUX, GPU required |
| Tabby | 32K | Coding | Self-hosted GitHub Copilot server for VS Code/JetBrains |

## Testing

The repository includes a comprehensive test suite in `test.sh` to validate the `ubuntu-prep-setup.sh` script. It runs the following validations in order:

1. Bash syntax check
2. ShellCheck static analysis
3. `shfmt` formatting consistency
4. VRAM fit validation (model weights + KV cache + runtime overhead)
5. Repair helper logic validation
6. Bats unit tests (`tests/*.bats`)
7. Kcov coverage (opt-in via `--coverage`)
8. Ollama model name validation (network)
9. HuggingFace repo validation (network)
10. OpenClaw npm package compatibility (network)

**Usage:**
```bash
./test.sh              # Full run (includes network checks)
./test.sh --quick      # Local-only (skip network checks)
./test.sh --install    # Auto-install shellcheck / shfmt / bats / kcov if missing
./test.sh --coverage   # Also run kcov coverage on bats tests
```

## Test Report
=== 1. Bash Syntax Check ===
  ✅ No syntax errors

=== 2. ShellCheck Static Analysis ===
  ✅ No shellcheck warnings

=== 3. shfmt Formatting Consistency ===
  ✅ Formatting is consistent (shfmt -i 4 -ci)

=== 4. VRAM Fit Validation ===
  ✅ All 56 model/tier combinations fit (weights + KV@q4_0 + 0.5GB runtime)

=== 5. Repair Helper Logic ===
  ✅ derive_component_status marks healthy full installs as installed
  ✅ derive_component_status marks unhealthy installs as broken
  ✅ derive_component_status marks partial installs as broken
  ✅ derive_component_status marks empty state as missing
  ✅ derive_component_action maps selected missing components to install
  ✅ derive_component_action maps selected installed components to repair
  ✅ derive_component_action maps selected broken components to repair
  ✅ derive_component_action skips unselected components
  ✅ llama_requires_model_selection forces a model when benchmarking
  ✅ llama_should_launch_server stays off for benchmark-only runs
  ✅ llama_should_launch_server launches when llama.cpp service is selected
  ✅ build_llama_hf_args parses custom repo:file selections

=== 5b. OpenClaw & Settings Logic ===
  ✅ env filter: empty double-quoted KEY="" stripped
  ✅ env filter: empty single-quoted KEY='' stripped
  ✅ env filter: no-value KEY= stripped
  ✅ env filter: non-API_KEY/TOKEN keys excluded
  ✅ env filter: non-empty API keys preserved
  ✅ env filter: HF_TOKEN preserved
  ✅ env filter: ANTHROPIC_API_KEY alias auto-created from CLAUDE_API_KEY
  ✅ env filter: ANTHROPIC_API_KEY not duplicated when already present
  ✅ openclaw jq: allowInsecureAuth set to false for LAN bind
  ✅ openclaw jq: auth.rateLimit.maxAttempts = 10
  ✅ openclaw jq: auth.rateLimit.windowMs = 60000 (1 min)
  ✅ openclaw jq: auth.rateLimit.lockoutMs = 300000 (5 min)
  ✅ openclaw jq: security fields not applied for loopback-only bind
  ✅ save_ai_settings_file: output path is $HOME (admin home, not target-user home)

=== 6. Bats Unit Tests ===
  ✅ 161 bats test(s) passed

=== 8. Ollama Model Validation (network) ===
  ✅ command-r-plus:104b
  ✅ gemma4:26b
  ✅ gemma4:e4b
  ✅ llama3.3:70b
  ✅ llava:34b
  ✅ minicpm-v
  ✅ mixtral:8x22b
  ✅ mixtral:8x7b
  ✅ qwen2.5:14b
  ✅ qwen2.5:32b
  ✅ qwen2.5:72b
  ✅ qwen2.5-coder:14b
  ✅ qwen2.5-coder:32b
  ✅ qwen2.5-coder:7b
  ✅ qwen2.5vl:32b
  ✅ qwen2.5vl:72b
  (16 unique models checked)

=== 9. HuggingFace Repo Validation (network) ===
  ✅ bartowski/c4ai-command-r-plus-08-2024-GGUF (9 GGUF files)
  ✅ bartowski/Llama-3.3-70B-Instruct-GGUF (24 GGUF files)
  ✅ bartowski/Qwen2.5-14B-Instruct-GGUF (24 GGUF files)
  ✅ bartowski/Qwen2.5-32B-Instruct-GGUF (26 GGUF files)
  ✅ bartowski/Qwen2.5-72B-Instruct-GGUF (15 GGUF files)
  ✅ bartowski/Qwen2.5-Coder-14B-Instruct-GGUF (27 GGUF files)
  ✅ bartowski/Qwen2.5-Coder-32B-Instruct-GGUF (28 GGUF files)
  ✅ bartowski/Qwen2.5-Coder-7B-Instruct-GGUF (24 GGUF files)
  ✅ cjpais/llava-v1.6-34B-gguf (12 GGUF files)
  ✅ cjpais/llava-v1.6-vicuna-13b-gguf (8 GGUF files)
  ✅ MaziyarPanahi/Mixtral-8x22B-v0.1-GGUF (69 GGUF files)
  ✅ TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF (8 GGUF files)
  ✅ unsloth/gemma-4-26B-A4B-it-GGUF (24 GGUF files)
  ✅ unsloth/gemma-4-E4B-it-GGUF (24 GGUF files)
  ✅ unsloth/Qwen2.5-VL-32B-Instruct-GGUF (27 GGUF files)
  ✅ unsloth/Qwen2.5-VL-72B-Instruct-GGUF (19 GGUF files)
  (16 unique repos checked)

## License

[![License: PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/License-PolyForm--NC%201.0.0-blue.svg)](https://polyformproject.org/licenses/noncommercial/1.0.0/)

This project is dual-licensed:

- **Free for personal and noncommercial use** under the [PolyForm Noncommercial 1.0.0](LICENSE) license. Hobby projects, home labs, education, research, and nonprofit use are all covered — go wild.

- **Commercial use requires a one-time $10 license.** If you or your company use this at work, please purchase a commercial license. See [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md) for details, or click the **Sponsor** button above.

If you fork or redistribute this project, please keep the copyright notice and link back to this repo.

##
Last updated: 2026-04-17 — Full stack validated: CUDA 13 + cuDNN 9.21.0 + llama.cpp + OpenWebUI + LibreChat + OpenClaw on Ubuntu 24.04 with NVIDIA RTXA5000 passthrough using NVIDIA Consumer Ubuntu Drivers, and on ESXi 8.0 VM with Ubuntu 24.04 with NVIDIA RTXA5000-24Q Enterprise vGPU Drivers and licence token.