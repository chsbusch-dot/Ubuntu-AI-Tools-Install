#!/usr/bin/env bats
#
# Unit tests for miscellaneous helper functions in ubuntu-prep-setup.sh:
#   format_component_status_label
#   format_component_action_label
#   record_component_outcome
#   need_local_llm_work
#   need_frontend_backend_target
#   available_backend_count
#   get_llama_{repo,cache,runtime_pid,runtime_log}_path
#
# Run: bats tests/helpers.bats

extract_function() {
    local fn_name="$1"
    sed -n "/^${fn_name}() {/,/^}/p" "$SETUP_SCRIPT"
}

setup() {
    SETUP_SCRIPT="${BATS_TEST_DIRNAME}/../ubuntu-prep-setup.sh"
    [ -f "$SETUP_SCRIPT" ] || skip "ubuntu-prep-setup.sh not found"

    eval "$(extract_function format_component_status_label)"
    eval "$(extract_function format_component_action_label)"
    eval "$(extract_function record_component_outcome)"
    eval "$(extract_function need_local_llm_work)"
    eval "$(extract_function need_frontend_backend_target)"
    eval "$(extract_function available_backend_count)"
    eval "$(extract_function get_llama_repo_path)"
    eval "$(extract_function get_llama_cache_path)"
    eval "$(extract_function get_llama_runtime_pid_path)"
    eval "$(extract_function get_llama_runtime_log_path)"

    # Globals used by need_* and available_backend_count
    LLAMA_COMPONENT_ACTION="skip"
    OLLAMA_COMPONENT_ACTION="skip"
    OPENWEBUI_COMPONENT_ACTION="skip"
    LIBRECHAT_COMPONENT_ACTION="skip"
    OPENCLAW_COMPONENT_ACTION="skip"
    LLM_BACKEND_CHOICE=""
    LLAMA_COMPONENT_STATUS="missing"
    OLLAMA_COMPONENT_STATUS="missing"

    # Globals used by record_component_outcome
    INSTALLED_COMPONENTS=()
    REPAIRED_COMPONENTS=()
    FAILED_COMPONENTS=()

    # Globals used by get_llama_*_path
    TARGET_USER_HOME="/home/testuser"
}

# ─── format_component_status_label ────────────────────────────────────

@test "status_label: installed → installed" {
    [ "$(format_component_status_label installed)" = "installed" ]
}

@test "status_label: broken → broken" {
    [ "$(format_component_status_label broken)" = "broken" ]
}

@test "status_label: missing → missing" {
    [ "$(format_component_status_label missing)" = "missing" ]
}

@test "status_label: unknown string falls through to missing" {
    [ "$(format_component_status_label whatever)" = "missing" ]
}

@test "status_label: empty string falls through to missing" {
    [ "$(format_component_status_label "")" = "missing" ]
}

# ─── format_component_action_label ────────────────────────────────────

@test "action_label: install → install" {
    [ "$(format_component_action_label install)" = "install" ]
}

@test "action_label: repair → repair" {
    [ "$(format_component_action_label repair)" = "repair" ]
}

@test "action_label: skip → skip" {
    [ "$(format_component_action_label skip)" = "skip" ]
}

@test "action_label: unknown string falls through to skip" {
    [ "$(format_component_action_label bogus)" = "skip" ]
}

@test "action_label: empty string falls through to skip" {
    [ "$(format_component_action_label "")" = "skip" ]
}

# ─── record_component_outcome ──────────────────────────────────────────

@test "record_outcome: install+success adds to INSTALLED_COMPONENTS" {
    record_component_outcome "Docker" "install" "success"
    [[ " ${INSTALLED_COMPONENTS[*]} " == *" Docker "* ]]
}

@test "record_outcome: repair+success adds to REPAIRED_COMPONENTS" {
    record_component_outcome "Docker" "repair" "success"
    [[ " ${REPAIRED_COMPONENTS[*]} " == *" Docker "* ]]
}

@test "record_outcome: install+failed adds to FAILED_COMPONENTS" {
    record_component_outcome "Docker" "install" "failed"
    [[ " ${FAILED_COMPONENTS[*]} " == *" Docker "* ]]
}

@test "record_outcome: repair+failed adds to FAILED_COMPONENTS" {
    record_component_outcome "llama.cpp" "repair" "failed"
    [[ " ${FAILED_COMPONENTS[*]} " == *" llama.cpp "* ]]
}

@test "record_outcome: install+success does NOT touch REPAIRED_COMPONENTS" {
    record_component_outcome "Docker" "install" "success"
    [ "${#REPAIRED_COMPONENTS[@]}" -eq 0 ]
}

@test "record_outcome: repair+success does NOT touch INSTALLED_COMPONENTS" {
    record_component_outcome "Docker" "repair" "success"
    [ "${#INSTALLED_COMPONENTS[@]}" -eq 0 ]
}

@test "record_outcome: skip+success adds nothing to any list" {
    record_component_outcome "Docker" "skip" "success"
    [ "${#INSTALLED_COMPONENTS[@]}" -eq 0 ]
    [ "${#REPAIRED_COMPONENTS[@]}" -eq 0 ]
    [ "${#FAILED_COMPONENTS[@]}" -eq 0 ]
}

@test "record_outcome: multiple components accumulate correctly" {
    record_component_outcome "Ollama" "install" "success"
    record_component_outcome "Open-WebUI" "install" "success"
    [ "${#INSTALLED_COMPONENTS[@]}" -eq 2 ]
    [[ " ${INSTALLED_COMPONENTS[*]} " == *" Ollama "* ]]
    [[ " ${INSTALLED_COMPONENTS[*]} " == *" Open-WebUI "* ]]
}

@test "record_outcome: failed components accumulate across separate calls" {
    record_component_outcome "Ollama" "install" "failed"
    record_component_outcome "llama.cpp" "repair" "failed"
    [ "${#FAILED_COMPONENTS[@]}" -eq 2 ]
}

# ─── need_local_llm_work ───────────────────────────────────────────────

@test "need_llm_work: false when all component actions are skip" {
    run need_local_llm_work
    [ "$status" -eq 1 ]
}

@test "need_llm_work: true when LLAMA action is install" {
    LLAMA_COMPONENT_ACTION="install"
    run need_local_llm_work
    [ "$status" -eq 0 ]
}

@test "need_llm_work: true when OLLAMA action is repair" {
    OLLAMA_COMPONENT_ACTION="repair"
    run need_local_llm_work
    [ "$status" -eq 0 ]
}

@test "need_llm_work: true when OPENWEBUI action is install" {
    OPENWEBUI_COMPONENT_ACTION="install"
    run need_local_llm_work
    [ "$status" -eq 0 ]
}

@test "need_llm_work: true when LIBRECHAT action is install" {
    LIBRECHAT_COMPONENT_ACTION="install"
    run need_local_llm_work
    [ "$status" -eq 0 ]
}

# ─── need_frontend_backend_target ─────────────────────────────────────

@test "need_frontend: false when all frontend actions are skip" {
    run need_frontend_backend_target
    [ "$status" -eq 1 ]
}

@test "need_frontend: true when OPENWEBUI action is install" {
    OPENWEBUI_COMPONENT_ACTION="install"
    run need_frontend_backend_target
    [ "$status" -eq 0 ]
}

@test "need_frontend: true when LIBRECHAT action is repair" {
    LIBRECHAT_COMPONENT_ACTION="repair"
    run need_frontend_backend_target
    [ "$status" -eq 0 ]
}

@test "need_frontend: true when OPENCLAW action is install" {
    OPENCLAW_COMPONENT_ACTION="install"
    run need_frontend_backend_target
    [ "$status" -eq 0 ]
}

@test "need_frontend: false when only LLAMA action is non-skip" {
    LLAMA_COMPONENT_ACTION="install"
    run need_frontend_backend_target
    [ "$status" -eq 1 ]
}

@test "need_frontend: false when only OLLAMA action is non-skip" {
    OLLAMA_COMPONENT_ACTION="install"
    run need_frontend_backend_target
    [ "$status" -eq 1 ]
}

# ─── available_backend_count ───────────────────────────────────────────

@test "backend_count: 0 when no backend selected or installed" {
    [ "$(available_backend_count)" -eq 0 ]
}

@test "backend_count: 1 when llama_cpu selected" {
    LLM_BACKEND_CHOICE="llama_cpu"
    [ "$(available_backend_count)" -eq 1 ]
}

@test "backend_count: 1 when llama_cuda selected" {
    LLM_BACKEND_CHOICE="llama_cuda"
    [ "$(available_backend_count)" -eq 1 ]
}

@test "backend_count: 1 when ollama selected" {
    LLM_BACKEND_CHOICE="ollama"
    [ "$(available_backend_count)" -eq 1 ]
}

@test "backend_count: 1 when llama already installed with no new selection" {
    LLAMA_COMPONENT_STATUS="installed"
    [ "$(available_backend_count)" -eq 1 ]
}

@test "backend_count: 1 when ollama already installed with no new selection" {
    OLLAMA_COMPONENT_STATUS="installed"
    [ "$(available_backend_count)" -eq 1 ]
}

@test "backend_count: 2 when both backends already installed" {
    LLAMA_COMPONENT_STATUS="installed"
    OLLAMA_COMPONENT_STATUS="installed"
    [ "$(available_backend_count)" -eq 2 ]
}

@test "backend_count: 2 when llama_cpu selected and ollama already installed" {
    LLM_BACKEND_CHOICE="llama_cpu"
    OLLAMA_COMPONENT_STATUS="installed"
    [ "$(available_backend_count)" -eq 2 ]
}

@test "backend_count: broken llama still counts as a backend (not missing)" {
    LLAMA_COMPONENT_STATUS="broken"
    [ "$(available_backend_count)" -eq 1 ]
}

# ─── get_llama_*_path ─────────────────────────────────────────────────

@test "get_llama_repo_path returns TARGET_USER_HOME/llama.cpp" {
    [ "$(get_llama_repo_path)" = "/home/testuser/llama.cpp" ]
}

@test "get_llama_cache_path returns TARGET_USER_HOME/llama.cpp/models/models-user" {
    [ "$(get_llama_cache_path)" = "/home/testuser/llama.cpp/models/models-user" ]
}

@test "get_llama_runtime_pid_path returns TARGET_USER_HOME/.cache/llama-server.pid" {
    [ "$(get_llama_runtime_pid_path)" = "/home/testuser/.cache/llama-server.pid" ]
}

@test "get_llama_runtime_log_path returns TARGET_USER_HOME/.cache/llama-server.log" {
    [ "$(get_llama_runtime_log_path)" = "/home/testuser/.cache/llama-server.log" ]
}

@test "path functions all reflect a changed TARGET_USER_HOME" {
    TARGET_USER_HOME="/opt/myservice"
    [ "$(get_llama_repo_path)"         = "/opt/myservice/llama.cpp" ]
    [ "$(get_llama_cache_path)"        = "/opt/myservice/llama.cpp/models/models-user" ]
    [ "$(get_llama_runtime_pid_path)"  = "/opt/myservice/.cache/llama-server.pid" ]
    [ "$(get_llama_runtime_log_path)"  = "/opt/myservice/.cache/llama-server.log" ]
}
