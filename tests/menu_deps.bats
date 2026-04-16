#!/usr/bin/env bats
#
# Menu dependency integration tests
#
# Verifies the DEP_MAP-driven dependency system end-to-end:
#   - Multi-hop auto-add (selecting X cascades to Y AND Z)
#   - apply_deps cascade-remove chains
#   - validate_deps does NOT add already-installed deps
#   - idempotency under repeated calls
#
# Index → menu item map (MASTER_OPTIONS order in main()):
#   0  Update System          8  btop
#   1  Oh My Zsh              9  nvtop
#   2  Python                10  CUDA
#   3  Docker                11  gcc
#   4  NVM                   12  CTK (Container Toolkit)
#   5  Homebrew              13  cuDNN
#   6  Gemini CLI            14  Local LLM
#   7  vGPU Driver           15  OpenClaw
#
# Run: bats tests/menu_deps.bats

extract_function() {
    local fn_name="$1"
    sed -n "/^${fn_name}() {/,/^}/p" "$SETUP_SCRIPT"
}

setup() {
    SETUP_SCRIPT="${BATS_TEST_DIRNAME}/../ubuntu-prep-setup.sh"
    [ -f "$SETUP_SCRIPT" ] || skip "ubuntu-prep-setup.sh not found"

    print_info()    { :; }
    print_success() { :; }
    ensure_active_index() { :; }   # no-op: ACTIVE_INDICES not needed for logic tests

    MASTER_SELECTIONS=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
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

# ─── Multi-hop: selecting one item adds ALL its transitive deps ───────

@test "CTK selection adds both Docker(3) and vGPU(7)" {
    MASTER_SELECTIONS[12]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[3]}"  -eq 1 ]  # Docker
    [ "${MASTER_SELECTIONS[7]}"  -eq 1 ]  # vGPU
}

@test "cuDNN selection adds vGPU(7) only (no direct Docker dep)" {
    MASTER_SELECTIONS[13]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[7]}"  -eq 1 ]  # vGPU
    [ "${MASTER_SELECTIONS[3]}"  -eq 0 ]  # Docker NOT added
}

@test "CUDA selection adds both vGPU(7) and gcc(11)" {
    MASTER_SELECTIONS[10]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[7]}"  -eq 1 ]  # vGPU
    [ "${MASTER_SELECTIONS[11]}" -eq 1 ]  # gcc
}

@test "OpenClaw selection adds both NVM(4) and Homebrew(5)" {
    MASTER_SELECTIONS[15]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[4]}" -eq 1 ]   # NVM
    [ "${MASTER_SELECTIONS[5]}" -eq 1 ]   # Homebrew
}

@test "Gemini selection adds NVM(4) but NOT Homebrew(5)" {
    MASTER_SELECTIONS[6]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[4]}" -eq 1 ]   # NVM
    [ "${MASTER_SELECTIONS[5]}" -eq 0 ]   # Homebrew NOT added
}

# ─── Selecting multiple items — union of all deps satisfied ──────────

@test "CUDA + CTK together add vGPU(7), gcc(11), Docker(3)" {
    MASTER_SELECTIONS[10]=1   # CUDA
    MASTER_SELECTIONS[12]=1   # CTK
    validate_deps || true
    [ "${MASTER_SELECTIONS[3]}"  -eq 1 ]  # Docker
    [ "${MASTER_SELECTIONS[7]}"  -eq 1 ]  # vGPU
    [ "${MASTER_SELECTIONS[11]}" -eq 1 ]  # gcc
}

@test "Gemini + OpenClaw together add NVM(4) and Homebrew(5)" {
    MASTER_SELECTIONS[6]=1    # Gemini
    MASTER_SELECTIONS[15]=1   # OpenClaw
    validate_deps || true
    [ "${MASTER_SELECTIONS[4]}" -eq 1 ]   # NVM
    [ "${MASTER_SELECTIONS[5]}" -eq 1 ]   # Homebrew
}

@test "CUDA + cuDNN + CTK adds Docker(3), vGPU(7), gcc(11)" {
    MASTER_SELECTIONS[10]=1   # CUDA
    MASTER_SELECTIONS[13]=1   # cuDNN
    MASTER_SELECTIONS[12]=1   # CTK
    validate_deps || true
    [ "${MASTER_SELECTIONS[3]}"  -eq 1 ]
    [ "${MASTER_SELECTIONS[7]}"  -eq 1 ]
    [ "${MASTER_SELECTIONS[11]}" -eq 1 ]
}

# ─── Already-installed deps skipped ──────────────────────────────────

@test "validate_deps skips Docker when already installed (CTK selected)" {
    MASTER_SELECTIONS[12]=1
    MASTER_INSTALLED_STATE[3]=1    # Docker already installed
    validate_deps || true
    [ "${MASTER_SELECTIONS[3]}"  -eq 0 ]   # should NOT be added to selections
    [ "${MASTER_SELECTIONS[7]}"  -eq 1 ]   # vGPU IS added (proves validate_deps ran)
}

@test "validate_deps skips vGPU when already installed (CUDA selected)" {
    MASTER_SELECTIONS[10]=1
    MASTER_INSTALLED_STATE[7]=1    # vGPU already installed
    validate_deps || true
    [ "${MASTER_SELECTIONS[7]}"  -eq 0 ]   # vGPU NOT added to selections
    [ "${MASTER_SELECTIONS[11]}" -eq 1 ]   # gcc IS added (proves validate_deps ran)
}

@test "validate_deps skips NVM when already installed (OpenClaw selected)" {
    MASTER_SELECTIONS[15]=1
    MASTER_INSTALLED_STATE[4]=1    # NVM already installed
    validate_deps || true
    [ "${MASTER_SELECTIONS[4]}" -eq 0 ]    # NVM NOT added to selections
    [ "${MASTER_SELECTIONS[5]}" -eq 1 ]    # Homebrew IS added (proves validate_deps ran)
}

@test "validate_deps skips Homebrew when already installed (OpenClaw selected)" {
    MASTER_SELECTIONS[15]=1
    MASTER_INSTALLED_STATE[5]=1    # Homebrew already installed
    validate_deps || true
    [ "${MASTER_SELECTIONS[5]}" -eq 0 ]    # Homebrew NOT added to selections
    [ "${MASTER_SELECTIONS[4]}" -eq 1 ]    # NVM IS added (proves validate_deps ran)
}

# ─── apply_deps cascade-remove chains ────────────────────────────────

@test "deselecting vGPU(7) removes CUDA(10), CTK(12), AND cuDNN(13)" {
    MASTER_SELECTIONS[7]=1
    MASTER_SELECTIONS[10]=1
    MASTER_SELECTIONS[12]=1
    MASTER_SELECTIONS[13]=1
    MASTER_SELECTIONS[7]=0
    apply_deps 7
    [ "${MASTER_SELECTIONS[10]}" -eq 0 ]  # CUDA removed
    [ "${MASTER_SELECTIONS[12]}" -eq 0 ]  # CTK removed
    [ "${MASTER_SELECTIONS[13]}" -eq 0 ]  # cuDNN removed
}

@test "deselecting Docker(3) removes CTK(12) but not CUDA(10)" {
    MASTER_SELECTIONS[3]=1
    MASTER_SELECTIONS[12]=1
    MASTER_SELECTIONS[10]=1
    MASTER_SELECTIONS[3]=0
    apply_deps 3
    [ "${MASTER_SELECTIONS[12]}" -eq 0 ]  # CTK removed (needs Docker)
    [ "${MASTER_SELECTIONS[10]}" -eq 1 ]  # CUDA untouched (doesn't need Docker)
}

@test "deselecting NVM(4) removes both Gemini(6) and OpenClaw(15)" {
    MASTER_SELECTIONS[4]=1
    MASTER_SELECTIONS[6]=1
    MASTER_SELECTIONS[15]=1
    MASTER_SELECTIONS[4]=0
    apply_deps 4
    [ "${MASTER_SELECTIONS[6]}"  -eq 0 ]  # Gemini removed
    [ "${MASTER_SELECTIONS[15]}" -eq 0 ]  # OpenClaw removed
}

@test "deselecting Homebrew(5) removes OpenClaw(15) but not Gemini(6)" {
    MASTER_SELECTIONS[5]=1
    MASTER_SELECTIONS[15]=1
    MASTER_SELECTIONS[6]=1
    MASTER_SELECTIONS[5]=0
    apply_deps 5
    [ "${MASTER_SELECTIONS[15]}" -eq 0 ]  # OpenClaw removed (needs Homebrew)
    [ "${MASTER_SELECTIONS[6]}"  -eq 1 ]  # Gemini untouched (doesn't need Homebrew)
}

# ─── Idempotency ──────────────────────────────────────────────────────

@test "validate_deps is idempotent when all deps already selected" {
    MASTER_SELECTIONS[10]=1   # CUDA
    MASTER_SELECTIONS[7]=1    # vGPU (dep already selected)
    MASTER_SELECTIONS[11]=1   # gcc  (dep already selected)
    local before="${MASTER_SELECTIONS[*]}"
    validate_deps || true
    validate_deps || true
    [ "${MASTER_SELECTIONS[*]}" = "$before" ]
}

@test "validate_deps called twice produces same result as once" {
    MASTER_SELECTIONS[12]=1   # CTK
    validate_deps || true
    local after_once="${MASTER_SELECTIONS[*]}"
    validate_deps || true
    [ "${MASTER_SELECTIONS[*]}" = "$after_once" ]
}

# ─── Unaffected items stay unchanged ─────────────────────────────────

@test "selecting CUDA does not affect btop(8) or nvtop(9)" {
    MASTER_SELECTIONS[10]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[8]}" -eq 0 ]   # btop untouched
    [ "${MASTER_SELECTIONS[9]}" -eq 0 ]   # nvtop untouched
}

@test "selecting OpenClaw does not affect Python(2) or Docker(3)" {
    MASTER_SELECTIONS[15]=1
    validate_deps || true
    [ "${MASTER_SELECTIONS[2]}" -eq 0 ]   # Python untouched
    [ "${MASTER_SELECTIONS[3]}" -eq 0 ]   # Docker untouched
}

@test "apply_deps on item with no dependents leaves all other items unchanged" {
    MASTER_SELECTIONS[2]=1    # Python — nothing depends on it
    MASTER_SELECTIONS[8]=1    # btop — nothing depends on it
    MASTER_SELECTIONS[2]=0
    apply_deps 2
    [ "${MASTER_SELECTIONS[8]}" -eq 1 ]   # btop untouched
}
