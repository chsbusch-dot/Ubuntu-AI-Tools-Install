#!/usr/bin/env bats
#
# Dependency resolution tests for ubuntu-prep-setup.sh
#
# Tests the DEP_MAP / apply_deps / validate_deps logic by sourcing
# just enough scaffolding to exercise the functions in isolation.
#
# Run: bats tests/deps.bats
#

setup() {
    SETUP_SCRIPT="${BATS_TEST_DIRNAME}/../ubuntu-prep-setup.sh"
    [ -f "$SETUP_SCRIPT" ] || skip "ubuntu-prep-setup.sh not found"

    # Minimal stubs so sourcing partial functions doesn't blow up
    print_info()    { :; }
    print_success() { :; }
    ensure_active_index() { :; }   # no-op: ACTIVE_INDICES not needed here

    # Initialise arrays the same way main() does
    MASTER_SELECTIONS=(1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
    MASTER_INSTALLED_STATE=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)

    # Extract each piece individually.
    # Strip 'local -a' from DEP_MAP: `local` would scope it to setup() and
    # it would be gone before the test body runs. Functions survive fine.
    eval "$(sed -n '/^    local -a DEP_MAP=(/,/^    )$/p' "$SETUP_SCRIPT" | sed 's/local -a DEP_MAP=/DEP_MAP=/')"
    eval "$(sed -n '/^    dep_label() {/,/^    }$/p' "$SETUP_SCRIPT")"
    eval "$(sed -n '/^    dep_label_for() {/,/^    }$/p' "$SETUP_SCRIPT")"
    eval "$(sed -n '/^    apply_deps() {/,/^    }$/p' "$SETUP_SCRIPT")"
    eval "$(sed -n '/^    validate_deps() {/,/^    }$/p' "$SETUP_SCRIPT")"
}

# ─── DEP_MAP completeness ────────────────────────────────────────────

@test "DEP_MAP contains NVM<-Gemini rule" {
    local found=0
    for entry in "${DEP_MAP[@]}"; do
        [[ "$entry" == "4 "* && "$entry" == *" 6"* ]] && found=1
    done
    [ "$found" -eq 1 ]
}

@test "DEP_MAP contains NVM<-OpenClaw rule" {
    local found=0
    for entry in "${DEP_MAP[@]}"; do
        [[ "$entry" == "4 "* && "$entry" == *" 15"* ]] && found=1
    done
    [ "$found" -eq 1 ]
}

@test "DEP_MAP contains Homebrew<-OpenClaw rule" {
    local found=0
    for entry in "${DEP_MAP[@]}"; do
        [[ "$entry" == "5 "* && "$entry" == *" 15"* ]] && found=1
    done
    [ "$found" -eq 1 ]
}

@test "DEP_MAP contains Docker<-CTK rule" {
    local found=0
    for entry in "${DEP_MAP[@]}"; do
        [[ "$entry" == "3 "* && "$entry" == *" 12"* ]] && found=1
    done
    [ "$found" -eq 1 ]
}

@test "DEP_MAP contains vGPU<-CUDA rule" {
    local found=0
    for entry in "${DEP_MAP[@]}"; do
        [[ "$entry" == "7 "* && "$entry" == *" 10"* ]] && found=1
    done
    [ "$found" -eq 1 ]
}

@test "DEP_MAP contains vGPU<-CTK rule" {
    local found=0
    for entry in "${DEP_MAP[@]}"; do
        [[ "$entry" == "7 "* && "$entry" == *" 12"* ]] && found=1
    done
    [ "$found" -eq 1 ]
}

@test "DEP_MAP contains vGPU<-cuDNN rule" {
    local found=0
    for entry in "${DEP_MAP[@]}"; do
        [[ "$entry" == "7 "* && "$entry" == *" 13"* ]] && found=1
    done
    [ "$found" -eq 1 ]
}

@test "DEP_MAP contains gcc<-CUDA rule" {
    local found=0
    for entry in "${DEP_MAP[@]}"; do
        [[ "$entry" == "11 "* && "$entry" == *" 10"* ]] && found=1
    done
    [ "$found" -eq 1 ]
}

# ─── validate_deps auto-add ──────────────────────────────────────────

@test "validate_deps adds NVM when OpenClaw is selected" {
    MASTER_SELECTIONS[15]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[4]}" -eq 1 ]
}

@test "validate_deps adds Homebrew when OpenClaw is selected" {
    MASTER_SELECTIONS[15]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[5]}" -eq 1 ]
}

@test "validate_deps adds NVM when Gemini is selected" {
    MASTER_SELECTIONS[6]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[4]}" -eq 1 ]
}

@test "validate_deps adds Docker when CTK is selected" {
    MASTER_SELECTIONS[12]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[3]}" -eq 1 ]
}

@test "validate_deps adds vGPU when CUDA is selected" {
    MASTER_SELECTIONS[10]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[7]}" -eq 1 ]
}

@test "validate_deps adds vGPU when CTK is selected" {
    MASTER_SELECTIONS[12]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[7]}" -eq 1 ]
}

@test "validate_deps adds vGPU when cuDNN is selected" {
    MASTER_SELECTIONS[13]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[7]}" -eq 1 ]
}

@test "validate_deps adds gcc when CUDA is selected" {
    MASTER_SELECTIONS[10]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[11]}" -eq 1 ]
}

@test "validate_deps is idempotent — no change when deps already selected" {
    MASTER_SELECTIONS[15]=1
    MASTER_SELECTIONS[4]=1
    MASTER_SELECTIONS[5]=1
    local before="${MASTER_SELECTIONS[*]}"
    validate_deps || true
    [ "${MASTER_SELECTIONS[*]}" = "$before" ]
}

@test "validate_deps skips deps already marked installed" {
    MASTER_SELECTIONS[10]=1
    MASTER_INSTALLED_STATE[7]=1   # vGPU already installed
    validate_deps || true
    [ "${MASTER_SELECTIONS[7]}" -eq 0 ]  # should NOT be added to selections
}

# ─── apply_deps cascade-remove ───────────────────────────────────────

@test "apply_deps removes Gemini when NVM is deselected" {
    MASTER_SELECTIONS[4]=1
    MASTER_SELECTIONS[6]=1
    MASTER_SELECTIONS[4]=0
    apply_deps 4
    [ "${MASTER_SELECTIONS[6]}" -eq 0 ]
}

@test "apply_deps removes OpenClaw when NVM is deselected" {
    MASTER_SELECTIONS[4]=1
    MASTER_SELECTIONS[15]=1
    MASTER_SELECTIONS[4]=0
    apply_deps 4
    [ "${MASTER_SELECTIONS[15]}" -eq 0 ]
}

@test "apply_deps removes CUDA when vGPU is deselected" {
    MASTER_SELECTIONS[7]=1
    MASTER_SELECTIONS[10]=1
    MASTER_SELECTIONS[7]=0
    apply_deps 7
    [ "${MASTER_SELECTIONS[10]}" -eq 0 ]
}

@test "apply_deps removes CTK when vGPU is deselected" {
    MASTER_SELECTIONS[7]=1
    MASTER_SELECTIONS[12]=1
    MASTER_SELECTIONS[7]=0
    apply_deps 7
    [ "${MASTER_SELECTIONS[12]}" -eq 0 ]
}

@test "apply_deps removes cuDNN when vGPU is deselected" {
    MASTER_SELECTIONS[7]=1
    MASTER_SELECTIONS[13]=1
    MASTER_SELECTIONS[7]=0
    apply_deps 7
    [ "${MASTER_SELECTIONS[13]}" -eq 0 ]
}

@test "apply_deps removes CTK when Docker is deselected" {
    MASTER_SELECTIONS[3]=1
    MASTER_SELECTIONS[12]=1
    MASTER_SELECTIONS[3]=0
    apply_deps 3
    [ "${MASTER_SELECTIONS[12]}" -eq 0 ]
}
