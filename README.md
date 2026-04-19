# Ubuntu Local AI — Ollama, llama.cpp, LibreChat, Open-WebUI & OpenClaw with NVIDIA vGPU and CUDA

A single `curl | bash` command that turns a fresh Ubuntu LTS Server into a fully configured local AI environment. NVIDIA vGPU or consumer GPU drivers, CUDA, cuDNN, llama.cpp, Ollama, Open-WebUI, LibreChat, and OpenClaw — all installed, wired up, and ready to go.

The script detects your GPU, selects the right models for your VRAM, configures CORS and firewall rules, and sets up systemd services so everything survives a reboot. No dependencies. No Ansible. No second script to explain the first one.

> **Security note:** The current focus is on ease of setup on a trusted LAN. If you are running this on a VPS, harden and secure all exposed services — especially OpenClaw — before going live.

## Interactive Menus

The script features keyboard-driven menus to customize your installation without editing any configuration files.

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

**Reconfigure llama.cpp on the fly:**
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

- If no NVIDIA GPU is detected, vGPU and CUDA options automatically disable themselves to prevent broken configurations. You will need to provide the driver and license token separately.
- The **VRAM-aware model selection** measures your GPU VRAM (or system RAM) and automatically recommends models that fit your hardware — from 8GB to 96GB.
- A built-in disk space checker warns you if your selected options exceed available partition storage.

## Features

- **Interactive Menu:** Choose exactly what to install, with smart dependency auto-selection and detection of already-installed tools `[✓]`.
- **Multi-User Support:** Install to your current user or create and configure a new dedicated user without interactive prompts.
- **System Initialization:** Updates and upgrades all system packages.
- **Zsh & Oh My Zsh:** Installs Zsh, Oh My Zsh, and essential plugins (`zsh-autosuggestions`, `zsh-syntax-highlighting`, `zsh-history-substring-search`).
- **Developer Tools:** Installs `git`, `tmux`, `curl`, `wget`, `micro`, and the `gcc` compiler.
- **Python Environment:** Sets up `python3`, `pip`, and `venv` with necessary build tools.
- **Docker:** Installs Docker CE, Docker Compose, and configures user permissions.
- **Node.js Environment:** Installs `nvm` and the latest LTS release of Node.js.
- **Homebrew:** Installs the Homebrew package manager for Linux.
- **NVIDIA Stack:**
    - Installs NVIDIA vGPU guest drivers via direct URL, Google Drive link, FTP, or HTTP.
    - Installs `btop` and `nvtop` for system and GPU monitoring.
    - Installs the latest CUDA, NVIDIA Container Toolkit, and cuDNN.
    - Dynamically detects GPU hardware and filters menu options accordingly (multi-GPU compile, compute version).
- **AI/ML Tools:** Installs Google Gemini CLI and OpenClaw.
- **Local LLM Support:**
    - Builds `llama.cpp` from source with CUDA (single or multi-GPU) or installs Ollama.
    - Sets up **Open-WebUI** and **LibreChat** via Docker with optional automated daily updates and auto-generated `librechat.yaml` connecting your local backend.
    - **VRAM-aware model recommendation engine** selects and pulls the best models for your hardware tier (8GB–96GB VRAM). See also: [runthisllm.com](https://runthisllm.com).
    - Configures **CORS** for both Ollama (`OLLAMA_ORIGINS`) and llama.cpp (`--cors`) so external frontends connect without browser policy errors.
    - Bulletproof model downloading with progress bars and automatic retries for Hugging Face and Ollama repositories.
    - Installs systemd services so your LLM backend starts automatically on boot.
- **Security & Networking:** Configures UFW firewall rules for all exposed services, LLM endpoints, and SSH.
- **Secure Configuration:** Creates and manages API keys in a `.env.secrets` file with protection against special character injection.
- **Model Validation:** Includes a `check-models.sh` utility to validate Hugging Face and Ollama repositories, including deep `.gguf` file verification and API request deduplication to prevent rate-limiting.
- **Pre-flight Checks:** Verifies the script is running on Ubuntu and not as root before doing anything.

## Prerequisites

- Fresh Ubuntu LTS Server installation (tested on 22.04 and later).
- Internet connection.

## Quick Start

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chsbusch-dot/Ubuntu-AI-Tools-Install/main/ubuntu-prep-setup.sh)"
```

## Manual Installation

```bash
# 1. Clone the repository
git clone https://github.com/chsbusch-dot/Ubuntu-AI-Tools-Install.git

# 2. Navigate to the directory
cd Ubuntu-AI-Tools-Install

# 3. Make the script executable
chmod +x ubuntu-prep-setup.sh

# 4. Run the script
./ubuntu-prep-setup.sh
```

## Configuration

### API Keys

The script creates a `~/.env.secrets` file for your API keys. You will be prompted to add keys one-by-one or edit the file directly with `nano`. The file is automatically sourced by `.bashrc` and `.zshrc` and is gitignored to prevent accidental exposure.

```bash
nano ~/.env.secrets
```

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
# export NVIDIA_NGC_API_KEY="your_nvidia_ngc_key"
# export HF_TOKEN="hf_your_token_here"
# export FIRECRAWL_API_KEY=""
# export TAVILY_API_KEY=""
# export NVIDIA_VGPU_DRIVER_URL="ftp://192.168.1.31/shared/.../nvidia.deb"
# export NVIDIA_VGPU_TOKEN_URL="ftp://192.168.1.31/shared/.../token.tok"
# export NVIDIA_VGPU_DOWNLOAD_AUTH="admin:password" # Works for FTP, HTTP Basic Auth, and SMB
# export ESXI_HOST="192.168.1.100"
# export ESXI_USER="root"
# export ESXI_PASSWORD="your_esxi_password"
# export OLLAMA_ALLOWED_ORIGINS="https://chat.yourdomain.com,http://localhost:8081"
# export SYSTEM_TIMEZONE="America/Los_Angeles"
```

## Testing

The repository includes a comprehensive test suite in `test.sh`. It runs the following validations in order:

1. Bash syntax check
2. ShellCheck static analysis
3. `shfmt` formatting consistency
4. VRAM fit validation (model weights + KV cache + runtime overhead)
5. Repair helper logic validation
6. Bats unit tests (`tests/*.bats`)
7. Kcov coverage (opt-in via `--coverage`)
8. Ollama model name validation (network)
9. Hugging Face repo validation (network)
10. OpenClaw npm package compatibility (network)

```bash
./test.sh              # Full run (includes network checks)
./test.sh --quick      # Local-only (skip network checks)
./test.sh --install    # Auto-install shellcheck / shfmt / bats / kcov if missing
./test.sh --coverage   # Also run kcov coverage on bats tests
```

## Test Report

```
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

=== 9. Hugging Face Repo Validation (network) ===
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
```

## What's Coming in V2.0

V2.0 is in private development and will add support for:

| Tool | Category | Description |
|---|---|---|
| [vLLM](https://github.com/vllm-project/vllm) | Inference | High-throughput LLM inference and serving |
| [NVIDIA NGC](https://catalog.ngc.nvidia.com) | Drivers & Models | CLI driver and model download with NVIDIA Enterprise License |
| [Manifest](https://github.com/mnfst/manifest) | Routing | Smart LLM model router |
| [Infisical](https://github.com/infisical/infisical) | Secrets | Secure, self-hosted API key management |

[Let me know](https://github.com/chsbusch-dot/Ubuntu-AI-Tools-Install/issues) if you're interested.

## Tools Under Consideration

Feedback welcome on which of these to prioritize:

| Tool | Stars | Category | Why |
|---|---:|---|---|
| Qdrant | 29K | Vector DB | Every RAG pipeline needs one |
| SearXNG | 27K | Web Search | Private web search for AI agents; used by Open-WebUI |
| n8n | 183K | Automation | Self-hosted Zapier with native AI agent nodes |
| AnythingLLM | 54K | RAG/UI | Instant document chat on top of Ollama |
| faster-whisper | 14K | STT | Used by Open-WebUI speech-to-text |
| Kokoro TTS | — | TTS | Near-ElevenLabs quality, 82M params, Docker-ready |
| Aider | 42K | Coding | Terminal AI pair programmer |
| OpenHands | 70K | Agent | Autonomous coding agent in sandboxed Docker |
| ComfyUI | 108K | Image | Node-graph Stable Diffusion/FLUX (GPU required) |
| Tabby | 32K | Coding | Self-hosted GitHub Copilot for VS Code/JetBrains |

## Feedback

If you find this useful or run into issues, open an issue or start a discussion.

If you use this at work, please consider picking up a [commercial license](COMMERCIAL-LICENSE.md) — it's $10 one-time and takes 30 seconds via the Sponsor button above.

## License

[![License: PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/License-PolyForm--NC%201.0.0-blue.svg)](https://polyformproject.org/licenses/noncommercial/1.0.0/)

Free for personal, hobby, and noncommercial use under [PolyForm Noncommercial 1.0.0](LICENSE). Commercial use requires a [one-time $10 license](COMMERCIAL-LICENSE.md).

---

*Last validated: 2026-04-17 — CUDA 13 + cuDNN 9.21.0 + llama.cpp + Open-WebUI + LibreChat + OpenClaw on Ubuntu 24.04 with NVIDIA RTX A5000 passthrough (consumer drivers) and ESXi 8.0 with NVIDIA RTX A5000-24Q Enterprise vGPU drivers and license token.*
