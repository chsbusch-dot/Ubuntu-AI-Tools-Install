# tests/test_helper.bash
#
# Shared helpers for the BATS test suite covering ubuntu-prep-setup.sh.
#
# The script defines both top-level functions (get_model_recommendations,
# llama_variant_to_model_backend, ...) and nested functions inside main()
# (apply_deps, validate_deps, dep_label, dep_label_for, ensure_active_index).
#
# Nested functions only come into existence when main() runs — but main()
# is interactive and has side effects. To test them in isolation we extract
# each function body with sed and eval it at the top level. This is the same
# pattern used by the pre-existing tests in this directory.
#
# Usage: `load test_helper` from a .bats file after setting SETUP_SCRIPT.

# Extract a top-level function (one whose definition starts in column 0).
# Returns the text of the function so caller can `eval` it.
extract_function() {
    local fn_name="$1"
    sed -n "/^${fn_name}() {/,/^}/p" "$SETUP_SCRIPT"
}

# Extract a nested function defined inside main(). These are indented by
# exactly four spaces in the source file, and their closing `}` is also
# at four-space indent.
extract_nested_function() {
    local fn_name="$1"
    sed -n "/^    ${fn_name}() {/,/^    }$/p" "$SETUP_SCRIPT"
}

# Extract the DEP_MAP array definition from inside main() and strip the
# `local -a` prefix. Without stripping, the array would be scoped to the
# eval (which runs inside setup()) and disappear before the test body runs.
extract_dep_map() {
    sed -n '/^    local -a DEP_MAP=(/,/^    )$/p' "$SETUP_SCRIPT" \
        | sed 's/local -a DEP_MAP=/DEP_MAP=/'
}

# Source the minimum scaffolding needed to exercise the nested dependency
# functions. Call this from setup() after `SETUP_SCRIPT` has been set.
#
# Stubs print_info / print_success / ensure_active_index so the dep logic
# can run silently without needing a terminal or populated ACTIVE_INDICES.
load_dep_functions() {
    print_info() { :; }
    print_success() { :; }
    # ensure_active_index is called by apply_deps/validate_deps. The real
    # implementation mutates ACTIVE_INDICES; for selection-logic tests we
    # don't care about that array, so stub it as a no-op.
    ensure_active_index() { :; }

    eval "$(extract_dep_map)"
    eval "$(extract_nested_function dep_label)"
    eval "$(extract_nested_function dep_label_for)"
    eval "$(extract_nested_function apply_deps)"
    eval "$(extract_nested_function validate_deps)"
}

# Reset MASTER_SELECTIONS and MASTER_INSTALLED_STATE to 16 zeros — the
# same initial state main() sets up before the menu loop runs.
reset_master_arrays() {
    MASTER_SELECTIONS=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
    MASTER_INSTALLED_STATE=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
}
