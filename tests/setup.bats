#!/usr/bin/env bats
#
# Unit tests for functions in ubuntu-prep-setup.sh
#
# Run directly:   bats tests/setup.bats
# Via test.sh:    ./test.sh           (runs bats section if installed)

extract_function() {
    local fn_name="$1"
    sed -n "/^${fn_name}() {/,/^}/p" "$SETUP_SCRIPT"
}

setup() {
    SETUP_SCRIPT="${BATS_TEST_DIRNAME}/../ubuntu-prep-setup.sh"
    [ -f "$SETUP_SCRIPT" ] || skip "ubuntu-prep-setup.sh not found at $SETUP_SCRIPT"
    # Source only the functions under test to avoid running the whole installer.
    eval "$(extract_function get_model_recommendations)"
    eval "$(extract_function derive_component_status)"
    eval "$(extract_function derive_component_action)"
    eval "$(extract_function llama_requires_model_selection)"
    eval "$(extract_function llama_should_launch_server)"
    eval "$(extract_function build_llama_hf_args)"
}

# ─── get_model_recommendations ──────────────────────────────────────

@test "ollama backend sets all four model slots for every tier" {
    for vram in 8 16 24 32 48 72 96; do
        get_model_recommendations "ollama" "$vram"
        [ -n "$REC_MODEL_CHAT" ]
        [ -n "$REC_MODEL_CODE" ]
        [ -n "$REC_MODEL_MOE" ]
        [ -n "$REC_MODEL_VISION" ]
    done
}

@test "llama backend sets all four model slots for every tier" {
    for vram in 8 16 24 32 48 72 96; do
        get_model_recommendations "llama" "$vram"
        [ -n "$REC_MODEL_CHAT" ]
        [ -n "$REC_MODEL_CODE" ]
        [ -n "$REC_MODEL_MOE" ]
        [ -n "$REC_MODEL_VISION" ]
    done
}

@test "ollama models are tag-style (no slash)" {
    for vram in 8 16 24 32 48 72 96; do
        get_model_recommendations "ollama" "$vram"
        [[ "$REC_MODEL_CHAT" != */* ]]
        [[ "$REC_MODEL_CODE" != */* ]]
    done
}

@test "llama backend returns HuggingFace repo paths (org/name)" {
    for vram in 8 16 24 32 48 72 96; do
        get_model_recommendations "llama" "$vram"
        [[ "$REC_MODEL_CHAT" == */* ]]
        [[ "$REC_MODEL_CODE" == */* ]]
        [[ "$REC_MODEL_MOE" == */* ]]
        [[ "$REC_MODEL_VISION" == */* ]]
    done
}

@test "coder model at 8GB ollama is qwen2.5-coder:7b" {
    get_model_recommendations "ollama" 8
    [ "$REC_MODEL_CODE" = "qwen2.5-coder:7b" ]
}

@test "unknown backend falls through to llama branch" {
    get_model_recommendations "bogus" 24
    [[ "$REC_MODEL_CHAT" == */* ]]
}

@test "unknown vram tier leaves slots empty" {
    get_model_recommendations "ollama" 999
    [ -z "$REC_MODEL_CHAT" ]
    [ -z "$REC_MODEL_CODE" ]
}

# ─── repair helper logic ────────────────────────────────────────────

@test "derive_component_status returns installed for healthy full installs" {
    [ "$(derive_component_status true false true)" = "installed" ]
}

@test "derive_component_status returns broken for unhealthy full installs" {
    [ "$(derive_component_status true true false)" = "broken" ]
}

@test "derive_component_status returns broken for partial installs" {
    [ "$(derive_component_status false true true)" = "broken" ]
}

@test "derive_component_status returns missing when nothing is present" {
    [ "$(derive_component_status false false true)" = "missing" ]
}

@test "derive_component_action returns install for selected missing components" {
    [ "$(derive_component_action missing 1)" = "install" ]
}

@test "derive_component_action returns repair for selected installed components" {
    [ "$(derive_component_action installed 1)" = "repair" ]
}

@test "derive_component_action returns repair for selected broken components" {
    [ "$(derive_component_action broken 1)" = "repair" ]
}

@test "derive_component_action returns skip for unselected components" {
    [ "$(derive_component_action installed 0)" = "skip" ]
}

@test "llama_requires_model_selection returns true for benchmark runs" {
    LLAMA_COMPONENT_ACTION="install"
    RUN_LLAMA_BENCH="y"
    LOAD_DEFAULT_MODEL="n"
    INSTALL_LLAMA_SERVICE="n"
    EXPOSE_LLM_ENGINE="n"
    FRONTEND_BACKEND_TARGET=""
    OPENWEBUI_COMPONENT_ACTION="skip"
    LIBRECHAT_COMPONENT_ACTION="skip"
    run llama_requires_model_selection
    [ "$status" -eq 0 ]
}

@test "llama_should_launch_server stays false for benchmark-only runs" {
    LLAMA_COMPONENT_ACTION="install"
    RUN_LLAMA_BENCH="y"
    LOAD_DEFAULT_MODEL="n"
    INSTALL_LLAMA_SERVICE="n"
    EXPOSE_LLM_ENGINE="n"
    FRONTEND_BACKEND_TARGET=""
    OPENWEBUI_COMPONENT_ACTION="skip"
    LIBRECHAT_COMPONENT_ACTION="skip"
    LLM_DEFAULT_MODEL_CHOICE="5"
    run llama_should_launch_server
    [ "$status" -eq 1 ]
}

@test "llama_should_launch_server returns true when service install is selected" {
    LLAMA_COMPONENT_ACTION="install"
    RUN_LLAMA_BENCH="n"
    LOAD_DEFAULT_MODEL="n"
    INSTALL_LLAMA_SERVICE="y"
    EXPOSE_LLM_ENGINE="n"
    FRONTEND_BACKEND_TARGET=""
    OPENWEBUI_COMPONENT_ACTION="skip"
    LIBRECHAT_COMPONENT_ACTION="skip"
    LLM_DEFAULT_MODEL_CHOICE="5"
    run llama_should_launch_server
    [ "$status" -eq 0 ]
}

@test "build_llama_hf_args splits custom repo:file input" {
    LLM_DEFAULT_MODEL_CHOICE="6"
    LLAMACPP_MODEL_REPO="org/repo:model.gguf"
    [ "$(build_llama_hf_args)" = "--hf-repo org/repo --hf-file model.gguf" ]
}
