#!/usr/bin/env bats
#
# Component status / action helper tests
#
# Run: bats tests/components.bats
#

extract_function() {
    local fn_name="$1"
    sed -n "/^${fn_name}() {/,/^}/p" "$SETUP_SCRIPT"
}

setup() {
    SETUP_SCRIPT="${BATS_TEST_DIRNAME}/../ubuntu-prep-setup.sh"
    [ -f "$SETUP_SCRIPT" ] || skip "ubuntu-prep-setup.sh not found"
    eval "$(extract_function derive_component_status)"
    eval "$(extract_function derive_component_action)"
    eval "$(extract_function llama_requires_model_selection)"
    eval "$(extract_function llama_should_launch_server)"

    # Default state
    LLAMA_COMPONENT_ACTION="install"
    RUN_LLAMA_BENCH="n"
    LOAD_DEFAULT_MODEL="n"
    INSTALL_LLAMA_SERVICE="n"
    EXPOSE_LLM_ENGINE="n"
    FRONTEND_BACKEND_TARGET=""
    OPENWEBUI_COMPONENT_ACTION="skip"
    LIBRECHAT_COMPONENT_ACTION="skip"
    LLM_DEFAULT_MODEL_CHOICE=""
}

# ─── derive_component_status ─────────────────────────────────────────

@test "status: installed when fully present and healthy" {
    [ "$(derive_component_status true false true)" = "installed" ]
}

@test "status: broken when fully present but unhealthy" {
    [ "$(derive_component_status true true false)" = "broken" ]
}

@test "status: broken when partially present" {
    [ "$(derive_component_status false true true)" = "broken" ]
}

@test "status: missing when nothing is detected" {
    [ "$(derive_component_status false false true)" = "missing" ]
}

# ─── derive_component_action ─────────────────────────────────────────

@test "action: install for missing + selected" {
    [ "$(derive_component_action missing 1)" = "install" ]
}

@test "action: repair for installed + selected" {
    [ "$(derive_component_action installed 1)" = "repair" ]
}

@test "action: repair for broken + selected" {
    [ "$(derive_component_action broken 1)" = "repair" ]
}

@test "action: skip for installed + not selected" {
    [ "$(derive_component_action installed 0)" = "skip" ]
}

@test "action: skip for missing + not selected" {
    [ "$(derive_component_action missing 0)" = "skip" ]
}

# ─── llama_requires_model_selection ──────────────────────────────────

@test "requires_model: true when bench is on" {
    RUN_LLAMA_BENCH="y"
    run llama_requires_model_selection
    [ "$status" -eq 0 ]
}

@test "requires_model: true when load_default is on" {
    LOAD_DEFAULT_MODEL="y"
    run llama_requires_model_selection
    [ "$status" -eq 0 ]
}

@test "requires_model: true when service install is on" {
    INSTALL_LLAMA_SERVICE="y"
    run llama_requires_model_selection
    [ "$status" -eq 0 ]
}

@test "requires_model: true when expose is on" {
    EXPOSE_LLM_ENGINE="y"
    run llama_requires_model_selection
    [ "$status" -eq 0 ]
}

@test "requires_model: false when llama action is skip" {
    LLAMA_COMPONENT_ACTION="skip"
    run llama_requires_model_selection
    [ "$status" -eq 1 ]
}

@test "requires_model: false when no model-needing option is set" {
    run llama_requires_model_selection
    [ "$status" -eq 1 ]
}

@test "requires_model: true when frontend=llama and openwebui installing" {
    FRONTEND_BACKEND_TARGET="llama"
    OPENWEBUI_COMPONENT_ACTION="install"
    run llama_requires_model_selection
    [ "$status" -eq 0 ]
}

# ─── llama_should_launch_server ──────────────────────────────────────

@test "launch_server: false when action is skip" {
    LLAMA_COMPONENT_ACTION="skip"
    LLM_DEFAULT_MODEL_CHOICE="5"
    run llama_should_launch_server
    [ "$status" -eq 1 ]
}

@test "launch_server: false when no model choice made" {
    LLM_DEFAULT_MODEL_CHOICE=""
    run llama_should_launch_server
    [ "$status" -eq 1 ]
}

@test "launch_server: false for bench-only (no service, no load)" {
    LLM_DEFAULT_MODEL_CHOICE="5"
    RUN_LLAMA_BENCH="y"
    run llama_should_launch_server
    [ "$status" -eq 1 ]
}

@test "launch_server: true when load_default is on" {
    LLM_DEFAULT_MODEL_CHOICE="5"
    LOAD_DEFAULT_MODEL="y"
    run llama_should_launch_server
    [ "$status" -eq 0 ]
}

@test "launch_server: true when service install is on" {
    LLM_DEFAULT_MODEL_CHOICE="5"
    INSTALL_LLAMA_SERVICE="y"
    run llama_should_launch_server
    [ "$status" -eq 0 ]
}

@test "launch_server: true when expose is on" {
    LLM_DEFAULT_MODEL_CHOICE="5"
    EXPOSE_LLM_ENGINE="y"
    run llama_should_launch_server
    [ "$status" -eq 0 ]
}

@test "launch_server: true when frontend=llama and librechat installing" {
    LLM_DEFAULT_MODEL_CHOICE="3"
    FRONTEND_BACKEND_TARGET="llama"
    LIBRECHAT_COMPONENT_ACTION="install"
    run llama_should_launch_server
    [ "$status" -eq 0 ]
}
