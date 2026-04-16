#!/usr/bin/env bats
#
# Model recommendation and hf_args tests
#
# Run: bats tests/models.bats
#

extract_function() {
    local fn_name="$1"
    sed -n "/^${fn_name}() {/,/^}/p" "$SETUP_SCRIPT"
}

setup() {
    SETUP_SCRIPT="${BATS_TEST_DIRNAME}/../ubuntu-prep-setup.sh"
    [ -f "$SETUP_SCRIPT" ] || skip "ubuntu-prep-setup.sh not found"
    eval "$(extract_function get_model_recommendations)"
    eval "$(extract_function build_llama_hf_args)"

    # Defaults used by build_llama_hf_args
    LLM_DEFAULT_MODEL_CHOICE=""
    SELECTED_MODEL_REPO=""
    LLAMACPP_MODEL_REPO=""
}

# ─── get_model_recommendations ──────────────────────────────────────

@test "ollama backend sets all four slots for every VRAM tier" {
    for vram in 8 16 24 32 48 72 96; do
        get_model_recommendations "ollama" "$vram"
        [ -n "$REC_MODEL_CHAT" ]
        [ -n "$REC_MODEL_CODE" ]
        [ -n "$REC_MODEL_MOE" ]
        [ -n "$REC_MODEL_VISION" ]
    done
}

@test "llama backend sets all four slots for every VRAM tier" {
    for vram in 8 16 24 32 48 72 96; do
        get_model_recommendations "llama" "$vram"
        [ -n "$REC_MODEL_CHAT" ]
        [ -n "$REC_MODEL_CODE" ]
        [ -n "$REC_MODEL_MOE" ]
        [ -n "$REC_MODEL_VISION" ]
    done
}

@test "ollama models contain no slash (tag style, not HF path)" {
    for vram in 8 16 24 32 48 72 96; do
        get_model_recommendations "ollama" "$vram"
        [[ "$REC_MODEL_CHAT"   != */* ]]
        [[ "$REC_MODEL_CODE"   != */* ]]
        [[ "$REC_MODEL_MOE"    != */* ]]
        [[ "$REC_MODEL_VISION" != */* ]]
    done
}

@test "llama backend returns org/repo paths for all slots" {
    for vram in 8 16 24 32 48 72 96; do
        get_model_recommendations "llama" "$vram"
        [[ "$REC_MODEL_CHAT"   == */* ]]
        [[ "$REC_MODEL_CODE"   == */* ]]
        [[ "$REC_MODEL_MOE"    == */* ]]
        [[ "$REC_MODEL_VISION" == */* ]]
    done
}

@test "unknown backend falls through to llama branch" {
    get_model_recommendations "bogus" 24
    [[ "$REC_MODEL_CHAT" == */* ]]
}

@test "unknown VRAM tier leaves all slots empty" {
    get_model_recommendations "ollama" 999
    [ -z "$REC_MODEL_CHAT" ]
    [ -z "$REC_MODEL_CODE" ]
    [ -z "$REC_MODEL_MOE" ]
    [ -z "$REC_MODEL_VISION" ]
}

@test "8GB ollama coder model is qwen2.5-coder:7b" {
    get_model_recommendations "ollama" 8
    [ "$REC_MODEL_CODE" = "qwen2.5-coder:7b" ]
}

@test "ollama MoE models contain a colon (tag separator)" {
    for vram in 8 16 24 32 48 72 96; do
        get_model_recommendations "ollama" "$vram"
        [[ "$REC_MODEL_MOE" == *:* ]]
    done
}

# ─── build_llama_hf_args ────────────────────────────────────────────

@test "build_llama_hf_args: choice 5 returns TinyStories repo and file" {
    LLM_DEFAULT_MODEL_CHOICE="5"
    result=$(build_llama_hf_args)
    [[ "$result" == *"--hf-repo raincandy-u/TinyStories-656K-Q8_0-GGUF"* ]]
    [[ "$result" == *"--hf-file"* ]]
}

@test "build_llama_hf_args: choice 1-4 uses SELECTED_MODEL_REPO" {
    LLM_DEFAULT_MODEL_CHOICE="3"
    SELECTED_MODEL_REPO="bartowski/Qwen2.5-7B-Instruct-GGUF"
    result=$(build_llama_hf_args)
    [ "$result" = "--hf-repo bartowski/Qwen2.5-7B-Instruct-GGUF" ]
}

@test "build_llama_hf_args: choice 6 splits repo:file on colon" {
    LLM_DEFAULT_MODEL_CHOICE="6"
    LLAMACPP_MODEL_REPO="org/repo:model-q4.gguf"
    result=$(build_llama_hf_args)
    [ "$result" = "--hf-repo org/repo --hf-file model-q4.gguf" ]
}

@test "build_llama_hf_args: choice 6 plain repo (no colon) uses --hf-repo only" {
    LLM_DEFAULT_MODEL_CHOICE="6"
    LLAMACPP_MODEL_REPO="bartowski/Llama-3.3-70B-Instruct-GGUF"
    result=$(build_llama_hf_args)
    [ "$result" = "--hf-repo bartowski/Llama-3.3-70B-Instruct-GGUF" ]
}

@test "build_llama_hf_args: empty choice returns fallback model path" {
    LLM_DEFAULT_MODEL_CHOICE=""
    result=$(build_llama_hf_args)
    [[ "$result" == "--model "* ]]
}
