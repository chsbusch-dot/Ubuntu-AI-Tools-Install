#!/usr/bin/env bats
#
# Unit tests for curl_with_retry() in ubuntu-prep-setup.sh
#
# Strategy: mock `curl` and `sleep` so tests run instantly without
# touching the network.  The mock curl is a bash function that fails
# a configurable number of times then succeeds (or always fails).
#
# Run: bats tests/curl_retry.bats

extract_function() {
    local fn_name="$1"
    sed -n "/^${fn_name}() {/,/^}/p" "$SETUP_SCRIPT"
}

setup() {
    SETUP_SCRIPT="${BATS_TEST_DIRNAME}/../ubuntu-prep-setup.sh"
    [ -f "$SETUP_SCRIPT" ] || skip "ubuntu-prep-setup.sh not found"

    eval "$(extract_function curl_with_retry)"

    # sleep is a no-op so tests don't actually wait 5 s each
    sleep() { :; }

    # Reset shared state used by mock curl
    CURL_FAIL_COUNT=0   # how many more times mock curl should fail
    CURL_CALL_COUNT=0   # total invocations recorded
    CURL_LAST_ARGS=()   # arguments from the most recent call

    # Default mock curl: succeeds immediately
    curl() {
        CURL_CALL_COUNT=$((CURL_CALL_COUNT + 1))
        CURL_LAST_ARGS=("$@")
        if [[ $CURL_FAIL_COUNT -gt 0 ]]; then
            CURL_FAIL_COUNT=$((CURL_FAIL_COUNT - 1))
            return 1
        fi
        return 0
    }
}

# ─── Happy-path ────────────────────────────────────────────────────────

@test "succeeds immediately when curl succeeds on first attempt" {
    run curl_with_retry -fsSL https://example.com
    [ "$status" -eq 0 ]
}

@test "calls curl exactly once when it succeeds first time" {
    curl_with_retry -fsSL https://example.com
    [ "$CURL_CALL_COUNT" -eq 1 ]
}

@test "passes all arguments through to curl unchanged" {
    curl_with_retry -fsSL --output /tmp/out https://example.com/file
    [ "${CURL_LAST_ARGS[0]}" = "-fsSL" ]
    [ "${CURL_LAST_ARGS[1]}" = "--output" ]
    [ "${CURL_LAST_ARGS[2]}" = "/tmp/out" ]
    [ "${CURL_LAST_ARGS[3]}" = "https://example.com/file" ]
}

# ─── Retry behaviour ───────────────────────────────────────────────────

@test "succeeds after one failure (2 total calls)" {
    CURL_FAIL_COUNT=1
    curl_with_retry -fsSL https://example.com
    [ "$CURL_CALL_COUNT" -eq 2 ]
}

@test "succeeds after two failures (3 total calls)" {
    CURL_FAIL_COUNT=2
    curl_with_retry -fsSL https://example.com
    [ "$CURL_CALL_COUNT" -eq 3 ]
}

@test "retry emits a warning message to stderr on first failure" {
    CURL_FAIL_COUNT=1
    run curl_with_retry -fsSL https://example.com
    # bats captures stderr in $output when using `run`
    [[ "$output" == *"retrying"* ]] || [[ "$output" == *"attempt"* ]]
}

# ─── Failure after max retries ────────────────────────────────────────

@test "returns non-zero when curl always fails" {
    curl() { CURL_CALL_COUNT=$((CURL_CALL_COUNT + 1)); return 1; }
    run curl_with_retry -fsSL https://example.com
    [ "$status" -ne 0 ]
}

@test "stops retrying after 3 attempts (max=3) when always failing" {
    curl() { CURL_CALL_COUNT=$((CURL_CALL_COUNT + 1)); return 1; }
    curl_with_retry -fsSL https://example.com || true   # || true keeps bats from aborting
    [ "$CURL_CALL_COUNT" -eq 3 ]
}

@test "prints failure message to stderr after exhausting retries" {
    curl() { return 1; }
    run curl_with_retry -fsSL https://example.com
    [[ "$output" == *"failed"* ]]
}

@test "failure message mentions the attempt count" {
    curl() { return 1; }
    run curl_with_retry -fsSL https://example.com
    [[ "$output" == *"3"* ]]
}

# ─── sleep is called between retries ──────────────────────────────────

@test "sleep is called once when curl fails once then succeeds" {
    SLEEP_CALL_COUNT=0
    sleep() { SLEEP_CALL_COUNT=$((SLEEP_CALL_COUNT + 1)); }
    CURL_FAIL_COUNT=1
    curl_with_retry -fsSL https://example.com
    [ "$SLEEP_CALL_COUNT" -eq 1 ]
}

@test "sleep is called twice when curl fails twice then succeeds" {
    SLEEP_CALL_COUNT=0
    sleep() { SLEEP_CALL_COUNT=$((SLEEP_CALL_COUNT + 1)); }
    CURL_FAIL_COUNT=2
    curl_with_retry -fsSL https://example.com
    [ "$SLEEP_CALL_COUNT" -eq 2 ]
}

@test "sleep is NOT called when curl succeeds immediately" {
    SLEEP_CALL_COUNT=0
    sleep() { SLEEP_CALL_COUNT=$((SLEEP_CALL_COUNT + 1)); }
    curl_with_retry -fsSL https://example.com
    [ "$SLEEP_CALL_COUNT" -eq 0 ]
}

@test "sleep is called with a positive delay value" {
    SLEEP_ARG=""
    sleep() { SLEEP_ARG="$1"; }
    CURL_FAIL_COUNT=1
    curl_with_retry -fsSL https://example.com
    [ -n "$SLEEP_ARG" ]
    [ "$SLEEP_ARG" -gt 0 ]
}

# ─── Argument passthrough edge cases ──────────────────────────────────

@test "passes a single URL argument correctly" {
    curl_with_retry https://example.com
    [ "${CURL_LAST_ARGS[0]}" = "https://example.com" ]
    [ "${#CURL_LAST_ARGS[@]}" -eq 1 ]
}

@test "passes arguments with spaces when quoted correctly" {
    curl_with_retry -H "Authorization: Bearer token123" https://example.com
    [ "${CURL_LAST_ARGS[1]}" = "Authorization: Bearer token123" ]
}

@test "passes output flag and path as separate elements" {
    curl_with_retry -o /tmp/file.bin https://example.com/file.bin
    [ "${CURL_LAST_ARGS[0]}" = "-o" ]
    [ "${CURL_LAST_ARGS[1]}" = "/tmp/file.bin" ]
}
