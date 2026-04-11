# Project Context for Claude

## What this is
`ubuntu-prep-setup.sh` — a ~2,980-line bash script that automates Ubuntu server setup (ZSH, Docker, Node, NVIDIA/CUDA, Ollama, llama.cpp, OpenClaw, etc.).

## Recent work completed
1. **Shellcheck: 33 warnings → 0** — Fixed SC2155 (split local/assign), SC2024 (sudo redirects → `sudo tee`), SC2089/SC2090 (hf_args embedded quotes removed), SC1078 (systemd heredoc rewritten with `sudo tee`), SC2206/SC2207 (IFS splitting → `mapfile`), SC2076/SC2034 suppressed where intentional.

2. **Model recommendations updated** — All Ollama tags and HuggingFace GGUF repos verified to exist:
   - Fixed `gemma4:26b-a4b` → `gemma4:26b` (tag didn't exist)
   - Fixed `mixtral:8x7b` at 16GB tier (needs 28GB, moved to 32GB+)
   - Fixed `unsloth/Mixtral-8x7B-Instruct-v0.1-GGUF` → `TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF` (404)
   - Fixed `unsloth/c4ai-command-r-plus-GGUF` → `bartowski/c4ai-command-r-plus-08-2024-GGUF` (404)
   - Upgraded vision models at 32/48/72/96GB to `qwen2.5vl` and `Qwen2.5-VL` repos
   - All GGUF repos switched from `Qwen/` to `bartowski/` (verified)

3. **Validation test suite created:**
   - `check.sh` — Master runner (`--quick` for local-only, full run includes network checks)
   - `validate-vram-fit.sh` — Checks model weights + KV cache + runtime overhead ≤ VRAM tier
   - `check-models.sh` — Verifies all Ollama tags and HF repos exist via HTTP (pre-existing, enhanced)
   - All 3 scripts tested and passing on Ubuntu (chris@192.168.1.132)

4. **All checks passing on Ubuntu:**
   - Bash syntax: ✅
   - Shellcheck: ✅ (0 warnings) — needs `sudo apt install shellcheck` on target
   - VRAM fit (56 combos): ✅
   - Ollama models (16 unique): ✅
   - HuggingFace repos (16 unique): ✅

## SSH access
- Ubuntu box: `ssh chris@192.168.1.132` (hostname: openclaw, Ubuntu 24.04, bash 5.2)
- Scripts copied to `/tmp/` on that machine for testing

## Key architecture notes
- `get_model_recommendations()` at line ~53 — central model config (Ollama + llama.cpp, per VRAM tier)
- `hf_args` variable — used as a string inside `bash -c "..."` for sudo, NOT an array (by design)
- `EXPOSE_LLAMA_SERVER`, `TEST_LLAMACPP`, `AUTO_UPDATE_MODEL` — set but unused (reserved, suppressed)
- Env var `TZ` is the POSIX standard for timezone (not `SYSTEM_TIMEZONE`)
