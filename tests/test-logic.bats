#!/usr/bin/env bats
#
# test-logic.bats — regression suite for the pure-logic functions in
# ubuntu-prep-setup.sh. Designed to guard a large refactoring pass
# (dead-code removal + deduplication).
#
# Run:  cd /Users/christian/VSCode/ubuntu-prep && bats tests/test-logic.bats
#
# Install bats if missing:
#   brew install bats-core        (macOS)
#   npm  install -g bats          (cross-platform)
#   sudo apt install bats         (Debian/Ubuntu)
#
# ─── Architecture note: testing nested functions ─────────────────────────
#
# The four dependency-resolution functions — apply_deps, validate_deps,
# dep_label, dep_label_for — are *nested* functions defined inside main().
# In bash, nested functions are only brought into scope when their enclosing
# function runs. That means we cannot simply source the script and call them:
# main() has to execute first, and main() is interactive and full of side
# effects (sudo, apt, etc.) that we absolutely do not want in a unit test.
#
# Approach used here (matches the pre-existing tests in this directory):
#   1. Locate each nested function body in the source with `sed` by matching
#      its 4-space-indented `name() {` line and the matching closing `}`.
#   2. `eval` the extracted text in the setup() function. This promotes the
#      nested function to a top-level function in the test process.
#   3. Similarly extract the `local -a DEP_MAP=(...)` literal, stripping the
#      `local -a` prefix so the array survives past setup().
#   4. Stub print_info / print_success / ensure_active_index so the dep
#      logic can run without terminal output or ACTIVE_INDICES plumbing.
#
# Top-level functions (get_model_recommendations, llama_variant_to_model_backend)
# are extracted with the simpler pattern: `sed -n '/^name() {/,/^}/p'`.
#
# Shared helpers live in tests/test_helper.bash.
#

load test_helper

setup() {
    SETUP_SCRIPT="${BATS_TEST_DIRNAME}/../ubuntu-prep-setup.sh"
    [ -f "$SETUP_SCRIPT" ] || skip "ubuntu-prep-setup.sh not found at $SETUP_SCRIPT"

    # Top-level functions — source directly.
    eval "$(extract_function get_model_recommendations)"
    eval "$(extract_function llama_variant_to_model_backend)"

    # Nested functions + DEP_MAP (defined inside main()). See header comment.
    load_dep_functions

    # Initialise the selection arrays the same way main() does before any
    # user interaction. Tests mutate these to exercise the logic.
    reset_master_arrays
}

# ═════════════════════════════════════════════════════════════════════════
# 1. get_model_recommendations — 7 VRAM tiers × 2 backends = 14 combos
# ═════════════════════════════════════════════════════════════════════════
#
# Contract: given (backend, vram_gb), the function sets four globals —
# REC_MODEL_CHAT, REC_MODEL_CODE, REC_MODEL_MOE, REC_MODEL_VISION — to
# non-empty strings matching the case/esac in the source.

# ─── All slots populated for every valid combo ───────────────────────────

@test "get_model_recommendations: ollama/8  sets all four slots" {
    get_model_recommendations "ollama" 8
    [ -n "$REC_MODEL_CHAT" ]
    [ -n "$REC_MODEL_CODE" ]
    [ -n "$REC_MODEL_MOE" ]
    [ -n "$REC_MODEL_VISION" ]
}

@test "get_model_recommendations: ollama/16 sets all four slots" {
    get_model_recommendations "ollama" 16
    [ -n "$REC_MODEL_CHAT" ]
    [ -n "$REC_MODEL_CODE" ]
    [ -n "$REC_MODEL_MOE" ]
    [ -n "$REC_MODEL_VISION" ]
}

@test "get_model_recommendations: ollama/24 sets all four slots" {
    get_model_recommendations "ollama" 24
    [ -n "$REC_MODEL_CHAT" ]
    [ -n "$REC_MODEL_CODE" ]
    [ -n "$REC_MODEL_MOE" ]
    [ -n "$REC_MODEL_VISION" ]
}

@test "get_model_recommendations: ollama/32 sets all four slots" {
    get_model_recommendations "ollama" 32
    [ -n "$REC_MODEL_CHAT" ]
    [ -n "$REC_MODEL_CODE" ]
    [ -n "$REC_MODEL_MOE" ]
    [ -n "$REC_MODEL_VISION" ]
}

@test "get_model_recommendations: ollama/48 sets all four slots" {
    get_model_recommendations "ollama" 48
    [ -n "$REC_MODEL_CHAT" ]
    [ -n "$REC_MODEL_CODE" ]
    [ -n "$REC_MODEL_MOE" ]
    [ -n "$REC_MODEL_VISION" ]
}

@test "get_model_recommendations: ollama/72 sets all four slots" {
    get_model_recommendations "ollama" 72
    [ -n "$REC_MODEL_CHAT" ]
    [ -n "$REC_MODEL_CODE" ]
    [ -n "$REC_MODEL_MOE" ]
    [ -n "$REC_MODEL_VISION" ]
}

@test "get_model_recommendations: ollama/96 sets all four slots" {
    get_model_recommendations "ollama" 96
    [ -n "$REC_MODEL_CHAT" ]
    [ -n "$REC_MODEL_CODE" ]
    [ -n "$REC_MODEL_MOE" ]
    [ -n "$REC_MODEL_VISION" ]
}

@test "get_model_recommendations: llama/8  sets all four slots" {
    get_model_recommendations "llama" 8
    [ -n "$REC_MODEL_CHAT" ]
    [ -n "$REC_MODEL_CODE" ]
    [ -n "$REC_MODEL_MOE" ]
    [ -n "$REC_MODEL_VISION" ]
}

@test "get_model_recommendations: llama/16 sets all four slots" {
    get_model_recommendations "llama" 16
    [ -n "$REC_MODEL_CHAT" ]
    [ -n "$REC_MODEL_CODE" ]
    [ -n "$REC_MODEL_MOE" ]
    [ -n "$REC_MODEL_VISION" ]
}

@test "get_model_recommendations: llama/24 sets all four slots" {
    get_model_recommendations "llama" 24
    [ -n "$REC_MODEL_CHAT" ]
    [ -n "$REC_MODEL_CODE" ]
    [ -n "$REC_MODEL_MOE" ]
    [ -n "$REC_MODEL_VISION" ]
}

@test "get_model_recommendations: llama/32 sets all four slots" {
    get_model_recommendations "llama" 32
    [ -n "$REC_MODEL_CHAT" ]
    [ -n "$REC_MODEL_CODE" ]
    [ -n "$REC_MODEL_MOE" ]
    [ -n "$REC_MODEL_VISION" ]
}

@test "get_model_recommendations: llama/48 sets all four slots" {
    get_model_recommendations "llama" 48
    [ -n "$REC_MODEL_CHAT" ]
    [ -n "$REC_MODEL_CODE" ]
    [ -n "$REC_MODEL_MOE" ]
    [ -n "$REC_MODEL_VISION" ]
}

@test "get_model_recommendations: llama/72 sets all four slots" {
    get_model_recommendations "llama" 72
    [ -n "$REC_MODEL_CHAT" ]
    [ -n "$REC_MODEL_CODE" ]
    [ -n "$REC_MODEL_MOE" ]
    [ -n "$REC_MODEL_VISION" ]
}

@test "get_model_recommendations: llama/96 sets all four slots" {
    get_model_recommendations "llama" 96
    [ -n "$REC_MODEL_CHAT" ]
    [ -n "$REC_MODEL_CODE" ]
    [ -n "$REC_MODEL_MOE" ]
    [ -n "$REC_MODEL_VISION" ]
}

# ─── Exact model-name assertions (ollama) ────────────────────────────────

@test "get_model_recommendations: ollama/8  exact model names" {
    get_model_recommendations "ollama" 8
    [ "$REC_MODEL_CHAT"   = "gemma4:e4b" ]
    [ "$REC_MODEL_CODE"   = "qwen2.5-coder:7b" ]
    [ "$REC_MODEL_MOE"    = "gemma4:e4b" ]
    [ "$REC_MODEL_VISION" = "gemma4:e4b" ]
}

@test "get_model_recommendations: ollama/16 exact model names" {
    get_model_recommendations "ollama" 16
    [ "$REC_MODEL_CHAT"   = "qwen2.5:14b" ]
    [ "$REC_MODEL_CODE"   = "qwen2.5-coder:14b" ]
    [ "$REC_MODEL_MOE"    = "gemma4:e4b" ]
    [ "$REC_MODEL_VISION" = "minicpm-v" ]
}

@test "get_model_recommendations: ollama/24 exact model names" {
    get_model_recommendations "ollama" 24
    [ "$REC_MODEL_CHAT"   = "gemma4:26b" ]
    [ "$REC_MODEL_CODE"   = "qwen2.5-coder:32b" ]
    [ "$REC_MODEL_MOE"    = "gemma4:26b" ]
    [ "$REC_MODEL_VISION" = "llava:34b" ]
}

@test "get_model_recommendations: ollama/32 exact model names" {
    get_model_recommendations "ollama" 32
    [ "$REC_MODEL_CHAT"   = "qwen2.5:32b" ]
    [ "$REC_MODEL_CODE"   = "qwen2.5-coder:32b" ]
    [ "$REC_MODEL_MOE"    = "mixtral:8x7b" ]
    [ "$REC_MODEL_VISION" = "qwen2.5vl:32b" ]
}

@test "get_model_recommendations: ollama/48 exact model names" {
    get_model_recommendations "ollama" 48
    [ "$REC_MODEL_CHAT"   = "llama3.3:70b" ]
    [ "$REC_MODEL_CODE"   = "qwen2.5-coder:32b" ]
    [ "$REC_MODEL_MOE"    = "mixtral:8x7b" ]
    [ "$REC_MODEL_VISION" = "qwen2.5vl:32b" ]
}

@test "get_model_recommendations: ollama/72 exact model names" {
    get_model_recommendations "ollama" 72
    [ "$REC_MODEL_CHAT"   = "qwen2.5:72b" ]
    [ "$REC_MODEL_CODE"   = "qwen2.5-coder:32b" ]
    [ "$REC_MODEL_MOE"    = "command-r-plus:104b" ]
    [ "$REC_MODEL_VISION" = "qwen2.5vl:72b" ]
}

@test "get_model_recommendations: ollama/96 exact model names" {
    get_model_recommendations "ollama" 96
    [ "$REC_MODEL_CHAT"   = "qwen2.5:72b" ]
    [ "$REC_MODEL_CODE"   = "qwen2.5-coder:32b" ]
    [ "$REC_MODEL_MOE"    = "mixtral:8x22b" ]
    [ "$REC_MODEL_VISION" = "qwen2.5vl:72b" ]
}

# ─── Exact model-name assertions (llama.cpp / HF repos) ──────────────────

@test "get_model_recommendations: llama/8  exact repo paths" {
    get_model_recommendations "llama" 8
    [ "$REC_MODEL_CHAT"   = "unsloth/gemma-4-E4B-it-GGUF" ]
    [ "$REC_MODEL_CODE"   = "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF" ]
    [ "$REC_MODEL_MOE"    = "unsloth/gemma-4-E4B-it-GGUF" ]
    [ "$REC_MODEL_VISION" = "unsloth/gemma-4-E4B-it-GGUF" ]
}

@test "get_model_recommendations: llama/16 exact repo paths" {
    get_model_recommendations "llama" 16
    [ "$REC_MODEL_CHAT"   = "bartowski/Qwen2.5-14B-Instruct-GGUF" ]
    [ "$REC_MODEL_CODE"   = "bartowski/Qwen2.5-Coder-14B-Instruct-GGUF" ]
    [ "$REC_MODEL_MOE"    = "unsloth/gemma-4-E4B-it-GGUF" ]
    [ "$REC_MODEL_VISION" = "cjpais/llava-v1.6-vicuna-13b-gguf" ]
}

@test "get_model_recommendations: llama/24 exact repo paths" {
    get_model_recommendations "llama" 24
    [ "$REC_MODEL_CHAT"   = "unsloth/gemma-4-26B-A4B-it-GGUF" ]
    [ "$REC_MODEL_CODE"   = "bartowski/Qwen2.5-Coder-32B-Instruct-GGUF" ]
    [ "$REC_MODEL_MOE"    = "unsloth/gemma-4-26B-A4B-it-GGUF" ]
    [ "$REC_MODEL_VISION" = "cjpais/llava-v1.6-34B-gguf" ]
}

@test "get_model_recommendations: llama/32 exact repo paths" {
    get_model_recommendations "llama" 32
    [ "$REC_MODEL_CHAT"   = "bartowski/Qwen2.5-32B-Instruct-GGUF" ]
    [ "$REC_MODEL_CODE"   = "bartowski/Qwen2.5-Coder-32B-Instruct-GGUF" ]
    [ "$REC_MODEL_MOE"    = "TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF" ]
    [ "$REC_MODEL_VISION" = "unsloth/Qwen2.5-VL-32B-Instruct-GGUF" ]
}

@test "get_model_recommendations: llama/48 exact repo paths" {
    get_model_recommendations "llama" 48
    [ "$REC_MODEL_CHAT"   = "bartowski/Llama-3.3-70B-Instruct-GGUF" ]
    [ "$REC_MODEL_CODE"   = "bartowski/Qwen2.5-Coder-32B-Instruct-GGUF" ]
    [ "$REC_MODEL_MOE"    = "TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF" ]
    [ "$REC_MODEL_VISION" = "unsloth/Qwen2.5-VL-32B-Instruct-GGUF" ]
}

@test "get_model_recommendations: llama/72 exact repo paths" {
    get_model_recommendations "llama" 72
    [ "$REC_MODEL_CHAT"   = "bartowski/Qwen2.5-72B-Instruct-GGUF" ]
    [ "$REC_MODEL_CODE"   = "bartowski/Qwen2.5-Coder-32B-Instruct-GGUF" ]
    [ "$REC_MODEL_MOE"    = "bartowski/c4ai-command-r-plus-08-2024-GGUF" ]
    [ "$REC_MODEL_VISION" = "unsloth/Qwen2.5-VL-72B-Instruct-GGUF" ]
}

@test "get_model_recommendations: llama/96 exact repo paths" {
    get_model_recommendations "llama" 96
    [ "$REC_MODEL_CHAT"   = "bartowski/Qwen2.5-72B-Instruct-GGUF" ]
    [ "$REC_MODEL_CODE"   = "bartowski/Qwen2.5-Coder-32B-Instruct-GGUF" ]
    [ "$REC_MODEL_MOE"    = "MaziyarPanahi/Mixtral-8x22B-v0.1-GGUF" ]
    [ "$REC_MODEL_VISION" = "unsloth/Qwen2.5-VL-72B-Instruct-GGUF" ]
}

# ─── Format sanity checks across all tiers ───────────────────────────────

@test "get_model_recommendations: ollama tags never contain slashes" {
    for vram in 8 16 24 32 48 72 96; do
        get_model_recommendations "ollama" "$vram"
        [[ "$REC_MODEL_CHAT"   != */* ]]
        [[ "$REC_MODEL_CODE"   != */* ]]
        [[ "$REC_MODEL_MOE"    != */* ]]
        [[ "$REC_MODEL_VISION" != */* ]]
    done
}

@test "get_model_recommendations: llama repos always use org/name format" {
    for vram in 8 16 24 32 48 72 96; do
        get_model_recommendations "llama" "$vram"
        [[ "$REC_MODEL_CHAT"   == */* ]]
        [[ "$REC_MODEL_CODE"   == */* ]]
        [[ "$REC_MODEL_MOE"    == */* ]]
        [[ "$REC_MODEL_VISION" == */* ]]
    done
}

@test "get_model_recommendations: unknown VRAM tier leaves all slots empty" {
    get_model_recommendations "ollama" 999
    [ -z "$REC_MODEL_CHAT" ]
    [ -z "$REC_MODEL_CODE" ]
    [ -z "$REC_MODEL_MOE" ]
    [ -z "$REC_MODEL_VISION" ]
}

@test "get_model_recommendations: unknown backend falls through to llama branch" {
    # The if/else only special-cases "ollama"; everything else goes to the
    # llama.cpp branch. Verify with a 24GB tier (arbitrary non-empty combo).
    get_model_recommendations "bogus" 24
    [ "$REC_MODEL_CHAT" = "unsloth/gemma-4-26B-A4B-it-GGUF" ]
}

# ═════════════════════════════════════════════════════════════════════════
# 2. apply_deps / validate_deps — dependency cascade & auto-add logic
# ═════════════════════════════════════════════════════════════════════════
#
# Index → menu item map (from MASTER_OPTIONS in main()):
#   0  Update System          8  btop
#   1  Oh My Zsh              9  nvtop
#   2  Python                10  CUDA
#   3  Docker                11  gcc
#   4  NVM                   12  NVIDIA CTK
#   5  Homebrew              13  cuDNN
#   6  Gemini CLI            14  Local LLM
#   7  NVIDIA Driver         15  OpenClaw
#
# DEP_MAP rules (req <- dep1 dep2 ...):
#   4  <- 6, 15       NVM needed by Gemini, OpenClaw
#   5  <- 15          Homebrew needed by OpenClaw
#   3  <- 12          Docker needed by NVIDIA CTK
#   7  <- 10, 12, 13  NVIDIA driver needed by CUDA, CTK, cuDNN
#   10 <- 13          CUDA needed by cuDNN
#   11 <- 10          gcc needed by CUDA

# ─── Auto-add: CUDA pulls in NVIDIA driver + gcc ─────────────────────────

@test "apply_deps: selecting CUDA(10) auto-adds NVIDIA driver(7) and gcc(11)" {
    MASTER_SELECTIONS[10]=1
    apply_deps 10
    [ "${MASTER_SELECTIONS[7]}"  -eq 1 ]   # NVIDIA driver auto-selected
    [ "${MASTER_SELECTIONS[11]}" -eq 1 ]   # gcc auto-selected
}

@test "validate_deps: CUDA(10) selected -> driver(7) and gcc(11) added" {
    # validate_deps is the 'belt-and-suspenders' final pass — it should
    # reach the same conclusion as apply_deps even when starting cold.
    MASTER_SELECTIONS[10]=1
    validate_deps || true   # nonzero return means "changes were made"
    [ "${MASTER_SELECTIONS[7]}"  -eq 1 ]
    [ "${MASTER_SELECTIONS[11]}" -eq 1 ]
}

# ─── Auto-add: OpenClaw pulls in NVM + Homebrew ──────────────────────────

@test "apply_deps: selecting OpenClaw(15) auto-adds NVM(4) and Homebrew(5)" {
    MASTER_SELECTIONS[15]=1
    apply_deps 15
    [ "${MASTER_SELECTIONS[4]}" -eq 1 ]    # NVM auto-selected
    [ "${MASTER_SELECTIONS[5]}" -eq 1 ]    # Homebrew auto-selected
}

@test "validate_deps: OpenClaw(15) selected -> NVM(4) and Homebrew(5) added" {
    MASTER_SELECTIONS[15]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[4]}" -eq 1 ]
    [ "${MASTER_SELECTIONS[5]}" -eq 1 ]
}

# ─── Cascade-remove: deselecting NVIDIA driver clears dependents ─────────

@test "apply_deps: deselecting NVIDIA driver(7) cascade-removes CUDA(10), CTK(12), cuDNN(13)" {
    # Set up a state where everything GPU-related is selected, then drop
    # the driver and expect all dependents to fall off.
    MASTER_SELECTIONS[7]=1
    MASTER_SELECTIONS[10]=1
    MASTER_SELECTIONS[12]=1
    MASTER_SELECTIONS[13]=1
    MASTER_SELECTIONS[7]=0
    apply_deps 7
    [ "${MASTER_SELECTIONS[10]}" -eq 0 ]   # CUDA removed
    [ "${MASTER_SELECTIONS[12]}" -eq 0 ]   # CTK removed
    [ "${MASTER_SELECTIONS[13]}" -eq 0 ]   # cuDNN removed
}

# ─── validate_deps fixes a broken state ──────────────────────────────────

@test "validate_deps: CUDA(10) selected without NVIDIA driver(7) -> driver auto-added" {
    # Simulate a user (or goal-preset) leaving the state inconsistent:
    # CUDA selected but its required driver not. validate_deps must fix it.
    MASTER_SELECTIONS[10]=1
    [ "${MASTER_SELECTIONS[7]}" -eq 0 ]    # precondition: driver NOT selected
    validate_deps || true
    [ "${MASTER_SELECTIONS[7]}" -eq 1 ]    # driver now selected
}

@test "validate_deps: fixes broken state AND adds gcc chain at the same time" {
    # Combined scenario — CUDA selected, nothing else. validate_deps should
    # pull in both driver(7) and gcc(11) in a single pass.
    MASTER_SELECTIONS[10]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[7]}"  -eq 1 ]   # NVIDIA driver added
    [ "${MASTER_SELECTIONS[11]}" -eq 1 ]   # gcc added
    [ "${MASTER_SELECTIONS[10]}" -eq 1 ]   # CUDA stays selected
}

@test "validate_deps: returns nonzero (changed=1) when it had to fix something" {
    # The function documents its contract via the return code:
    #   0 = nothing to change, 1 = changes were made.
    # Keep this behaviour pinned down for the refactor.
    MASTER_SELECTIONS[10]=1
    run validate_deps
    [ "$status" -eq 1 ]
}

@test "validate_deps: returns zero when state is already consistent" {
    MASTER_SELECTIONS[10]=1   # CUDA
    MASTER_SELECTIONS[7]=1    # driver (dep already satisfied)
    MASTER_SELECTIONS[11]=1   # gcc (dep already satisfied)
    run validate_deps
    [ "$status" -eq 0 ]
}

@test "validate_deps: does not re-add a dep already marked installed" {
    # If a dep is in MASTER_INSTALLED_STATE, it's already on the system —
    # no need to reinstall it. validate_deps must respect that flag.
    MASTER_SELECTIONS[10]=1          # CUDA selected
    MASTER_INSTALLED_STATE[7]=1      # driver already on disk
    validate_deps || true
    [ "${MASTER_SELECTIONS[7]}" -eq 0 ]    # should NOT get re-selected
    [ "${MASTER_SELECTIONS[11]}" -eq 1 ]   # gcc still gets added (not installed)
}

# ═════════════════════════════════════════════════════════════════════════
# 3. dep_label / dep_label_for — case/esac label lookups
# ═════════════════════════════════════════════════════════════════════════
#
# dep_label     covers the REQUIRED side of DEP_MAP (indices 3,4,5,7,10,11).
# dep_label_for covers the DEPENDENT side (indices 6,10,12,13,15).
# Both fall through to "item N" for unknown indices.

# ─── dep_label: known indices ────────────────────────────────────────────

@test "dep_label: 3 -> Docker" {
    [ "$(dep_label 3)" = "Docker" ]
}

@test "dep_label: 4 -> NVM/Node.js" {
    [ "$(dep_label 4)" = "NVM/Node.js" ]
}

@test "dep_label: 5 -> Homebrew" {
    [ "$(dep_label 5)" = "Homebrew" ]
}

@test "dep_label: 7 -> NVIDIA GPU Driver" {
    [ "$(dep_label 7)" = "NVIDIA GPU Driver" ]
}

@test "dep_label: 10 -> CUDA" {
    [ "$(dep_label 10)" = "CUDA" ]
}

@test "dep_label: 11 -> gcc compiler" {
    [ "$(dep_label 11)" = "gcc compiler" ]
}

@test "dep_label: unknown index falls through to 'item N'" {
    [ "$(dep_label 99)" = "item 99" ]
}

@test "dep_label: index 0 (Update System) is not a dep — falls through" {
    [ "$(dep_label 0)" = "item 0" ]
}

# ─── dep_label_for: known indices ────────────────────────────────────────

@test "dep_label_for: 6 -> Gemini CLI" {
    [ "$(dep_label_for 6)" = "Gemini CLI" ]
}

@test "dep_label_for: 10 -> CUDA Toolkit" {
    [ "$(dep_label_for 10)" = "CUDA Toolkit" ]
}

@test "dep_label_for: 12 -> NVIDIA Container Toolkit" {
    [ "$(dep_label_for 12)" = "NVIDIA Container Toolkit" ]
}

@test "dep_label_for: 13 -> cuDNN" {
    [ "$(dep_label_for 13)" = "cuDNN" ]
}

@test "dep_label_for: 15 -> OpenClaw" {
    [ "$(dep_label_for 15)" = "OpenClaw" ]
}

@test "dep_label_for: unknown index falls through to 'item N'" {
    [ "$(dep_label_for 42)" = "item 42" ]
}

@test "dep_label_for: index 4 (NVM) is a required dep, not a dependent — falls through" {
    # NVM is on the LEFT side of DEP_MAP, never the right. dep_label_for
    # only knows the dependents, so 4 should hit the default branch.
    [ "$(dep_label_for 4)" = "item 4" ]
}

# ═════════════════════════════════════════════════════════════════════════
# 4. llama_variant_to_model_backend — always returns "llama"
# ═════════════════════════════════════════════════════════════════════════
#
# Both case arms in the function body produce the same output, so this
# function currently just maps any input to "llama". The test pins that
# behaviour down — if it ever changes we want to know about it.

@test "llama_variant_to_model_backend: llama_cpu  -> llama" {
    [ "$(llama_variant_to_model_backend llama_cpu)" = "llama" ]
}

@test "llama_variant_to_model_backend: llama_cuda -> llama" {
    [ "$(llama_variant_to_model_backend llama_cuda)" = "llama" ]
}

@test "llama_variant_to_model_backend: unknown variant -> llama (default arm)" {
    [ "$(llama_variant_to_model_backend ollama)" = "llama" ]
}

@test "llama_variant_to_model_backend: empty input -> llama (default arm)" {
    [ "$(llama_variant_to_model_backend "")" = "llama" ]
}

@test "llama_variant_to_model_backend: arbitrary string -> llama (default arm)" {
    [ "$(llama_variant_to_model_backend foobar)" = "llama" ]
}
