#!/usr/bin/env bats
#
# Unit tests for functions in ubuntu-prep-setup.sh
#
# Run directly:   bats tests/setup.bats
# Via test.sh:    ./test.sh           (runs bats section if installed)

setup() {
    SETUP_SCRIPT="${BATS_TEST_DIRNAME}/../ubuntu-prep-setup.sh"
    [ -f "$SETUP_SCRIPT" ] || skip "ubuntu-prep-setup.sh not found at $SETUP_SCRIPT"
    # Source only the function under test to avoid running the whole installer
    eval "$(sed -n '/^get_model_recommendations() {/,/^}/p' "$SETUP_SCRIPT")"
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
        [[ "$REC_MODEL_MOE"  == */* ]]
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
