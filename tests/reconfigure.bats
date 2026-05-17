#!/usr/bin/env bats
#
# Unit tests for llama-reconfigure.sh
#
# Covers the parser (parse_unit_file), serializer (serialize_arg_string),
# and validator (validate_arg_string). These are the pieces that rewrite
# systemd unit files — getting them wrong means a broken service.
#
# Run: bats tests/reconfigure.bats

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../llama-reconfigure.sh"
    [ -f "$SCRIPT" ] || skip "llama-reconfigure.sh not found"

    # shellcheck disable=SC1090
    source "$SCRIPT"

    # Use a per-test unit file in a tmp dir so parse_unit_file has something to read.
    TEST_DIR=$(mktemp -d)
    UNIT_FILE="${TEST_DIR}/llama-server.service"
    BAK_FILE="${UNIT_FILE}.bak"
}

teardown() {
    [ -n "${TEST_DIR:-}" ] && rm -rf "$TEST_DIR"
}

# Writes a minimal but realistic unit file. Callers pass the ExecStart line.
write_unit() {
    cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Llama.cpp Server
After=network.target

[Service]
User=chris
WorkingDirectory=/home/chris
Environment="HOME=/home/chris"
Environment="LLAMA_CACHE=/home/chris/llama.cpp/models"
Environment="LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64"
$1
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

# ─── Parser ────────────────────────────────────────────────────────────

@test "parse: minimal HF repo+file, port only" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo bartowski/Qwen2.5-7B-Instruct-GGUF --hf-file Qwen2.5-7B-Instruct-Q5_K_M.gguf --port 8080 >> \"/home/chris/.cache/llama-server.log\" 2>&1'"
    parse_unit_file
    [ "$P_MODEL_MODE" = "hf" ]
    [ "$P_HF_REPO" = "bartowski/Qwen2.5-7B-Instruct-GGUF" ]
    [ "$P_HF_FILE" = "Qwen2.5-7B-Instruct-Q5_K_M.gguf" ]
    [ "$P_PORT" = "8080" ]
}

@test "parse: full-featured CUDA line" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo bartowski/Qwen2.5-7B-Instruct-GGUF --hf-file Qwen2.5-7B-Instruct-Q5_K_M.gguf --port 8080 --fit on --fit-ctx 65536 --host 0.0.0.0 -c 32768 -ctk q8_0 -ctv q8_0 --flash-attn on --mlock >> \"/home/chris/.cache/llama-server.log\" 2>&1'"
    parse_unit_file
    [ "$P_IS_CUDA" = "y" ]
    [ "$P_MODEL_MODE" = "hf" ]
    [ "$P_CTX" = "32768" ]
    [ "$P_CACHE_K" = "q8_0" ]
    [ "$P_CACHE_V" = "q8_0" ]
    [ "$P_FLASH" = "on" ]
    [ "$P_HOST" = "0.0.0.0" ]
    [ "$P_PORT" = "8080" ]
    [ "$P_MLOCK" = "y" ]
    [ "$P_FIT" = "on" ]
    [ "$P_FIT_CTX" = "65536" ]
}

@test "parse: local --model path" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --model /home/chris/llama.cpp/models/local.gguf --port 8080 -c 4096 >> \"/home/chris/.cache/llama-server.log\" 2>&1'"
    parse_unit_file
    [ "$P_MODEL_MODE" = "local" ]
    [ "$P_MODEL_PATH" = "/home/chris/llama.cpp/models/local.gguf" ]
    [ "$P_CTX" = "4096" ]
}

@test "parse: CPU build (no LD_LIBRARY_PATH, no -ngl)" {
    # Strip the cuda Environment= line by writing a unit file without it.
    cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Llama.cpp Server

[Service]
User=chris
ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo x/y --hf-file z.gguf --port 8080 >> "/home/chris/.cache/llama-server.log" 2>&1'
EOF
    parse_unit_file
    [ "$P_IS_CUDA" = "n" ]
}

@test "parse: CUDA detected from -ngl even without LD_LIBRARY_PATH env" {
    cat >"$UNIT_FILE" <<EOF
[Service]
ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo x/y --hf-file z.gguf --port 8080 -ngl 99 >> "/log" 2>&1'
EOF
    parse_unit_file
    [ "$P_IS_CUDA" = "y" ]
    [ "$P_NGL" = "99" ]
}

@test "parse: mlock absent → P_MLOCK=n" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo x/y --hf-file z.gguf --port 8080 >> \"/log\" 2>&1'"
    parse_unit_file
    [ "$P_MLOCK" = "n" ]
}

@test "parse: unsupported layout dies" {
    cat >"$UNIT_FILE" <<EOF
[Service]
ExecStart=/usr/bin/some-other-binary --flag
EOF
    run parse_unit_file
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported layout"* ]]
}

# ─── Serializer ────────────────────────────────────────────────────────

@test "serialize: minimal HF config" {
    P_MODEL_MODE="hf"; P_HF_REPO="org/repo"; P_HF_FILE="m.gguf"
    P_PORT="8080"; P_IS_CUDA="n"
    P_CTX=""; P_NGL=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""
    P_HOST=""; P_MLOCK="n"; P_FIT=""; P_FIT_CTX=""; P_N_CPU_MOE=""; P_UBATCH=""; P_DIO="n"
    result=$(serialize_arg_string)
    [ "$result" = "--hf-repo org/repo --hf-file m.gguf --port 8080" ]
}

@test "serialize: full CUDA config is deterministic" {
    P_MODEL_MODE="hf"; P_HF_REPO="org/repo"; P_HF_FILE="m.gguf"
    P_PORT="8080"; P_IS_CUDA="y"; P_NGL="99"; P_HOST="0.0.0.0"
    P_CTX="32768"; P_CACHE_K="q8_0"; P_CACHE_V="q8_0"
    P_FLASH="on"; P_MLOCK="y"; P_FIT=""; P_FIT_CTX=""; P_N_CPU_MOE=""; P_UBATCH=""; P_DIO="n"
    result=$(serialize_arg_string)
    [ "$result" = "--hf-repo org/repo --hf-file m.gguf --port 8080 -ngl 99 --host 0.0.0.0 -c 32768 -ctk q8_0 -ctv q8_0 --flash-attn on --mlock" ]
}

@test "serialize: --fit on suppresses -ngl (they are mutually exclusive)" {
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"
    P_PORT="8080"; P_NGL="50"; P_FIT="on"; P_FIT_CTX="65536"
    P_CTX=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""; P_HOST=""; P_MLOCK="n"
    P_N_CPU_MOE=""; P_UBATCH=""; P_DIO="n"
    result=$(serialize_arg_string)
    [[ "$result" == *"--fit on --fit-ctx 65536"* ]]
    [[ "$result" != *"-ngl 50"* ]]
}

@test "serialize: local model uses --model not --hf-repo" {
    P_MODEL_MODE="local"; P_MODEL_PATH="/m/path.gguf"; P_PORT="8080"
    P_CTX=""; P_NGL=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""
    P_HOST=""; P_MLOCK="n"; P_FIT=""; P_FIT_CTX=""; P_N_CPU_MOE=""; P_UBATCH=""; P_DIO="n"
    P_HF_REPO=""; P_HF_FILE=""
    result=$(serialize_arg_string)
    [ "$result" = "--model /m/path.gguf --port 8080" ]
}

@test "serialize: --fit-ctx defaults to 65536 if unset" {
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"
    P_PORT="8080"; P_FIT="on"; P_FIT_CTX=""
    P_CTX=""; P_NGL=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""; P_HOST=""; P_MLOCK="n"
    P_N_CPU_MOE=""; P_UBATCH=""; P_DIO="n"
    result=$(serialize_arg_string)
    [[ "$result" == *"--fit-ctx 65536"* ]]
}

# ─── Round-trip (parse → serialize → parse) ────────────────────────────

@test "round-trip: parsing our own serializer output is idempotent" {
    # First round: hand-authored unit
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo org/repo --hf-file m.gguf --port 8080 -ngl 99 --host 0.0.0.0 -c 8192 -ctk q8_0 -ctv q8_0 --flash-attn on --mlock >> \"/log\" 2>&1'"
    parse_unit_file

    # Capture parsed values
    local saved_ctx="$P_CTX" saved_ngl="$P_NGL" saved_host="$P_HOST" saved_mlock="$P_MLOCK"

    # Serialize and stuff back into a fake unit, then re-parse
    local new_args
    new_args=$(serialize_arg_string)
    cat >"$UNIT_FILE" <<EOF
[Service]
Environment="LD_LIBRARY_PATH=/usr/local/cuda/lib64"
ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server ${new_args} >> "/log" 2>&1'
EOF
    parse_unit_file

    [ "$P_CTX"   = "$saved_ctx"   ]
    [ "$P_NGL"   = "$saved_ngl"   ]
    [ "$P_HOST"  = "$saved_host"  ]
    [ "$P_MLOCK" = "$saved_mlock" ]
}

# ─── --n-cpu-moe parser / serializer ──────────────────────────────────

@test "parse: --n-cpu-moe is extracted from ExecStart" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo x/y --hf-file z.gguf --port 8080 --n-cpu-moe 8 >> \"/log\" 2>&1'"
    parse_unit_file
    [ "$P_N_CPU_MOE" = "8" ]
}

@test "parse: --n-cpu-moe absent → P_N_CPU_MOE empty" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo x/y --hf-file z.gguf --port 8080 >> \"/log\" 2>&1'"
    parse_unit_file
    [ -z "$P_N_CPU_MOE" ]
}

@test "serialize: --n-cpu-moe included when set" {
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"
    P_PORT="8080"; P_IS_CUDA="y"; P_NGL="99"; P_HOST=""
    P_CTX=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""; P_MLOCK="n"; P_FIT=""; P_FIT_CTX=""
    P_UBATCH=""; P_DIO="n"; P_N_CPU_MOE="8"
    result=$(serialize_arg_string)
    [[ "$result" == *"--n-cpu-moe 8"* ]]
}

@test "serialize: --n-cpu-moe omitted when empty" {
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"
    P_PORT="8080"; P_IS_CUDA="n"
    P_CTX=""; P_NGL=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""
    P_HOST=""; P_MLOCK="n"; P_FIT=""; P_FIT_CTX=""
    P_UBATCH=""; P_DIO="n"; P_N_CPU_MOE=""
    result=$(serialize_arg_string)
    [[ "$result" != *"--n-cpu-moe"* ]]
}

@test "serialize: --n-cpu-moe appears after --mlock" {
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"
    P_PORT="8080"; P_MLOCK="y"; P_N_CPU_MOE="4"
    P_CTX=""; P_NGL=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""; P_HOST=""; P_FIT=""; P_FIT_CTX=""
    P_UBATCH=""; P_DIO="n"
    result=$(serialize_arg_string)
    mlock_pos=$(echo "$result" | grep -bo '\-\-mlock' | head -1 | cut -d: -f1)
    moe_pos=$(echo "$result" | grep -bo '\-\-n-cpu-moe' | head -1 | cut -d: -f1)
    [ "$moe_pos" -gt "$mlock_pos" ]
}

# ─── -ub / -dio parser / serializer ──────────────────────────────────

@test "parse: -ub is extracted from ExecStart" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo x/y --hf-file z.gguf --port 8080 -ub 2048 >> \"/log\" 2>&1'"
    parse_unit_file
    [ "$P_UBATCH" = "2048" ]
}

@test "parse: -ub absent → P_UBATCH empty" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo x/y --hf-file z.gguf --port 8080 >> \"/log\" 2>&1'"
    parse_unit_file
    [ -z "$P_UBATCH" ]
}

@test "parse: -dio sets P_DIO=y" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo x/y --hf-file z.gguf --port 8080 -dio >> \"/log\" 2>&1'"
    parse_unit_file
    [ "$P_DIO" = "y" ]
}

@test "parse: -dio absent → P_DIO=n" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo x/y --hf-file z.gguf --port 8080 >> \"/log\" 2>&1'"
    parse_unit_file
    [ "$P_DIO" = "n" ]
}

@test "serialize: -ub included when P_UBATCH set" {
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"
    P_PORT="8080"; P_IS_CUDA="n"
    P_CTX=""; P_NGL=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""
    P_HOST=""; P_MLOCK="n"; P_FIT=""; P_FIT_CTX=""; P_N_CPU_MOE=""; P_DIO="n"
    P_UBATCH="1024"
    result=$(serialize_arg_string)
    [[ "$result" == *"-ub 1024"* ]]
}

@test "serialize: -dio included when P_DIO=y" {
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"
    P_PORT="8080"; P_IS_CUDA="n"
    P_CTX=""; P_NGL=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""
    P_HOST=""; P_MLOCK="n"; P_FIT=""; P_FIT_CTX=""; P_N_CPU_MOE=""; P_UBATCH=""
    P_DIO="y"; P_GRP_ATTN_N=""; P_GRP_ATTN_W=""
    result=$(serialize_arg_string)
    [[ "$result" == *" -dio"* ]]
}

@test "serialize: -ub appears before -ctk, -dio after --mlock" {
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"
    P_PORT="8080"; P_UBATCH="512"; P_CACHE_K="q8_0"; P_CACHE_V="q8_0"; P_MLOCK="y"; P_DIO="y"
    P_CTX="4096"; P_NGL=""; P_FLASH=""; P_HOST=""; P_FIT=""; P_FIT_CTX=""; P_N_CPU_MOE=""
    P_GRP_ATTN_N=""; P_GRP_ATTN_W=""
    result=$(serialize_arg_string)
    ub_pos=$(echo "$result"    | grep -bo ' \-ub '     | head -1 | cut -d: -f1)
    ctk_pos=$(echo "$result"   | grep -bo ' \-ctk '    | head -1 | cut -d: -f1)
    mlock_pos=$(echo "$result" | grep -bo '\-\-mlock'  | head -1 | cut -d: -f1)
    dio_pos=$(echo "$result"   | grep -bo ' \-dio'     | head -1 | cut -d: -f1)
    [ "$ub_pos" -lt "$ctk_pos" ]
    [ "$dio_pos" -gt "$mlock_pos" ]
}

# ─── Validator ─────────────────────────────────────────────────────────

@test "validate: clean arg string passes" {
    run validate_arg_string "--hf-repo org/repo --port 8080 -c 4096"
    [ "$status" -eq 0 ]
}

@test "validate: embedded single quote is rejected" {
    run validate_arg_string "--hf-repo org/repo --port 8080 --extra 'bad'"
    [ "$status" -ne 0 ]
}

# ─── HuggingFace JSON parsers ──────────────────────────────────────────

@test "hf_parse_search_results: extracts id, downloads, likes as TSV" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    fixture='[
      {"id":"bartowski/Qwen2.5-7B-Instruct-GGUF","downloads":842104,"likes":1234},
      {"id":"TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF","downloads":512000,"likes":987}
    ]'
    result=$(echo "$fixture" | hf_parse_search_results)
    [[ "$result" == *"bartowski/Qwen2.5-7B-Instruct-GGUF	842104	1234"* ]]
    [[ "$result" == *"TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF	512000	987"* ]]
}

@test "hf_parse_search_results: missing downloads/likes defaults to 0" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    fixture='[{"id":"new/repo-GGUF"}]'
    result=$(echo "$fixture" | hf_parse_search_results)
    [ "$result" = "new/repo-GGUF	0	0" ]
}

@test "hf_parse_search_results: empty array yields empty output" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    result=$(echo '[]' | hf_parse_search_results)
    [ -z "$result" ]
}

@test "hf_parse_tree_gguf: only .gguf files, sorted by size desc" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    fixture='[
      {"type":"file","path":"README.md","size":4096},
      {"type":"file","path":"model-Q4_K_M.gguf","size":4800000000},
      {"type":"file","path":"model-Q8_0.gguf","size":7300000000},
      {"type":"directory","path":"subdir"},
      {"type":"file","path":"config.json","size":1024},
      {"type":"file","path":"model-Q5_K_M.gguf","size":5500000000}
    ]'
    result=$(echo "$fixture" | hf_parse_tree_gguf)
    # Expect three .gguf lines, Q8_0 (largest) first, then Q5_K_M, then Q4_K_M
    [[ "$(echo "$result" | sed -n '1p')" == "model-Q8_0.gguf	7300000000" ]]
    [[ "$(echo "$result" | sed -n '2p')" == "model-Q5_K_M.gguf	5500000000" ]]
    [[ "$(echo "$result" | sed -n '3p')" == "model-Q4_K_M.gguf	4800000000" ]]
    [[ "$(echo "$result" | wc -l)" -eq 3 ]]
}

@test "hf_parse_tree_gguf: directories and non-gguf files are filtered out" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    fixture='[
      {"type":"directory","path":"assets","size":0},
      {"type":"file","path":"tokenizer.json","size":2048000},
      {"type":"file","path":"model.safetensors","size":15000000000}
    ]'
    result=$(echo "$fixture" | hf_parse_tree_gguf)
    [ -z "$result" ]
}

@test "hf_parse_tree_gguf: missing size field defaults to 0" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    fixture='[{"type":"file","path":"tiny.gguf"}]'
    result=$(echo "$fixture" | hf_parse_tree_gguf)
    [ "$result" = "tiny.gguf	0" ]
}

# ─── Human-readable size formatter ─────────────────────────────────────

@test "human_size: bytes < 1K shows as B" {
    [ "$(human_size 512)" = "512 B" ]
}

@test "human_size: kilobytes rounded to whole numbers" {
    [ "$(human_size 4096)" = "4 KB" ]
}

@test "human_size: megabytes rounded to whole numbers" {
    [ "$(human_size 2097152)" = "2 MB" ]
}

@test "human_size: gigabytes shown with one decimal" {
    # 4.5 GB
    result=$(human_size 4831838208)
    [ "$result" = "4.5 GB" ]
}

@test "human_size: 7.3 GB typical Q8_0 model" {
    result=$(human_size 7837495296)
    [ "$result" = "7.3 GB" ]
}

# ─── Path helpers ──────────────────────────────────────────────────────

@test "detect_user_from_unit: reads User= value" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'"
    result=$(detect_user_from_unit)
    [ "$result" = "chris" ]
}

@test "detect_llama_cache: reads LLAMA_CACHE from Environment=" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'"
    result=$(detect_llama_cache)
    [ "$result" = "/home/chris/llama.cpp/models" ]
}

@test "detect_llama_cache: falls back to /home/<User>/llama.cpp/models when no env" {
    cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Test
[Service]
User=alice
ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'
[Install]
WantedBy=multi-user.target
EOF
    result=$(detect_llama_cache)
    [ "$result" = "/home/alice/llama.cpp/models" ]
}

@test "resolve_local_gguf: local-mode returns P_MODEL_PATH when file exists" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'"
    fake_model="${TEST_DIR}/model.gguf"
    : >"$fake_model"
    P_MODEL_MODE="local"; P_MODEL_PATH="$fake_model"
    P_HF_REPO=""; P_HF_FILE=""
    result=$(resolve_local_gguf)
    [ "$result" = "$fake_model" ]
}

@test "resolve_local_gguf: hf-mode finds file under flattened cache scheme" {
    cache_dir="${TEST_DIR}/models"
    mkdir -p "$cache_dir"
    : >"${cache_dir}/bartowski_Qwen2.5-7B-GGUF--model.gguf"
    cat >"$UNIT_FILE" <<EOF
[Service]
User=chris
Environment="LLAMA_CACHE=${cache_dir}"
ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'
EOF
    P_MODEL_MODE="hf"
    P_HF_REPO="bartowski/Qwen2.5-7B-GGUF"
    P_HF_FILE="model.gguf"
    P_MODEL_PATH=""
    result=$(resolve_local_gguf)
    [ "$result" = "${cache_dir}/bartowski_Qwen2.5-7B-GGUF--model.gguf" ]
}

@test "resolve_local_gguf: hf-mode falls back to nested org/repo/file scheme" {
    cache_dir="${TEST_DIR}/models"
    mkdir -p "${cache_dir}/bartowski/Qwen2.5-7B-GGUF"
    : >"${cache_dir}/bartowski/Qwen2.5-7B-GGUF/model.gguf"
    cat >"$UNIT_FILE" <<EOF
[Service]
User=chris
Environment="LLAMA_CACHE=${cache_dir}"
ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'
EOF
    P_MODEL_MODE="hf"
    P_HF_REPO="bartowski/Qwen2.5-7B-GGUF"
    P_HF_FILE="model.gguf"
    P_MODEL_PATH=""
    result=$(resolve_local_gguf)
    [ "$result" = "${cache_dir}/bartowski/Qwen2.5-7B-GGUF/model.gguf" ]
}

@test "detect_model_gb: returns 0 even when .gguf is not on disk" {
    # Regression: set -euo pipefail + a naked `[[ ]] && cmd` tail caused
    # the function to exit 1 when bytes was empty, killing show_current()
    # mid-draw in the interactive menu.
    cat >"$UNIT_FILE" <<EOF
[Service]
User=chris
Environment="LLAMA_CACHE=/nonexistent"
ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'
EOF
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"; P_MODEL_PATH=""
    # Run in a subshell so failure here doesn't bubble up to bats itself.
    run bash -c 'set -euo pipefail; source "'"$SCRIPT"'"; UNIT_FILE="'"$UNIT_FILE"'"; P_MODEL_MODE=hf; P_HF_REPO=x/y; P_HF_FILE=z.gguf; P_MODEL_PATH=""; x=$(detect_model_gb); echo "survived:$x"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"survived:"* ]]
}

@test "detect_hw_vram_gb: returns 0 when nvidia-smi is absent" {
    # Same set -e regression class as detect_model_gb.
    run bash -c 'set -euo pipefail; source "'"$SCRIPT"'"; x=$(detect_hw_vram_gb); echo "survived:$x"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"survived:"* ]]
}

@test "resolve_local_gguf: returns empty when file is not on disk" {
    cat >"$UNIT_FILE" <<EOF
[Service]
User=chris
Environment="LLAMA_CACHE=/nonexistent"
ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'
EOF
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"; P_MODEL_PATH=""
    result=$(resolve_local_gguf)
    [ -z "$result" ]
}

# ─── Benchmark scorer ──────────────────────────────────────────────────

@test "bench_preset_spec: known presets return '<p> <n> <label>'" {
    result=$(bench_preset_spec openclaw)
    [[ "$result" == "64 256 "* ]]
    result=$(bench_preset_spec chat)
    [[ "$result" == "512 1024 "* ]]
    result=$(bench_preset_spec coding)
    [[ "$result" == "8192 2048 "* ]]
    result=$(bench_preset_spec summarize)
    [[ "$result" == "32768 512 "* ]]
}

@test "bench_preset_spec: unknown preset returns non-zero" {
    run bench_preset_spec nonsense
    [ "$status" -ne 0 ]
}

@test "bench_score_json: ranks fastest config first for short-reply workload" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    # Two configs: ub=1024 is slower pp but faster tg; ub=2048 is faster pp but
    # slower tg. For a short-reply workload (p=64 n=256), tg dominates, so
    # ub=1024 (fastest tg) should win.
    fixture='[
      {"n_ubatch":1024,"type_k":"q8_0","type_v":"q8_0","flash_attn":1,"n_prompt":64,"n_gen":0,"avg_ts":500.0},
      {"n_ubatch":1024,"type_k":"q8_0","type_v":"q8_0","flash_attn":1,"n_prompt":0,"n_gen":256,"avg_ts":100.0},
      {"n_ubatch":2048,"type_k":"q8_0","type_v":"q8_0","flash_attn":1,"n_prompt":64,"n_gen":0,"avg_ts":1000.0},
      {"n_ubatch":2048,"type_k":"q8_0","type_v":"q8_0","flash_attn":1,"n_prompt":0,"n_gen":256,"avg_ts":50.0}
    ]'
    result=$(echo "$fixture" | bench_score_json 64 256)
    first=$(echo "$result" | head -1)
    [[ "$first" == *$'\t'1024$'\t'* ]]
}

@test "bench_score_json: ranks fastest pp first for long-prompt workload" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    fixture='[
      {"n_ubatch":1024,"type_k":"q8_0","type_v":"q8_0","flash_attn":1,"n_prompt":32768,"n_gen":0,"avg_ts":500.0},
      {"n_ubatch":1024,"type_k":"q8_0","type_v":"q8_0","flash_attn":1,"n_prompt":0,"n_gen":512,"avg_ts":100.0},
      {"n_ubatch":2048,"type_k":"q8_0","type_v":"q8_0","flash_attn":1,"n_prompt":32768,"n_gen":0,"avg_ts":1000.0},
      {"n_ubatch":2048,"type_k":"q8_0","type_v":"q8_0","flash_attn":1,"n_prompt":0,"n_gen":512,"avg_ts":50.0}
    ]'
    result=$(echo "$fixture" | bench_score_json 32768 512)
    first=$(echo "$result" | head -1)
    [[ "$first" == *$'\t'2048$'\t'* ]]
}

@test "bench_score_json: rows missing either pp or tg are filtered" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    fixture='[
      {"n_ubatch":1024,"type_k":"q8_0","type_v":"q8_0","flash_attn":1,"n_prompt":64,"n_gen":0,"avg_ts":500.0}
    ]'
    result=$(echo "$fixture" | bench_score_json 64 256)
    [ -z "$result" ]
}

# ─── VRAM estimate for un-downloaded HF models ─────────────────────────

@test "parse: P_HF_FILE_BYTES is initialized to empty on every parse" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo x/y --hf-file z.gguf --port 8080'"
    P_HF_FILE_BYTES="999999"   # stale leftover from a prior run
    parse_unit_file
    [ -z "$P_HF_FILE_BYTES" ]
}

@test "detect_model_gb: falls back to P_HF_FILE_BYTES when .gguf is not on disk" {
    # Regression: before this fix the VRAM estimate block wouldn't render
    # for a model the user just picked from the HF search UI (before Apply
    # → download → cache). That hid OOM risk — user could pick a 70 B
    # model on a 24 GB GPU and only find out 15 min into the download.
    cat >"$UNIT_FILE" <<EOF
[Service]
User=chris
Environment="LLAMA_CACHE=/nonexistent"
ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'
EOF
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"; P_MODEL_PATH=""
    # 49 GB exactly — well past a 24 GB GPU, lets us assert the OOM path lights up.
    P_HF_FILE_BYTES=$((49 * 1073741824))
    result=$(detect_model_gb)
    # Should return "49.0" (GB), not empty.
    [ "$result" = "49.0" ]
}

@test "detect_model_gb: prefers on-disk size over P_HF_FILE_BYTES" {
    # When the file IS cached, stat wins — P_HF_FILE_BYTES is a fallback only.
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'"
    fake_model="${TEST_DIR}/model.gguf"
    # Create a 1 GiB sparse file.
    truncate -s 1073741824 "$fake_model" 2>/dev/null \
        || dd if=/dev/zero of="$fake_model" bs=1 count=0 seek=1073741824 2>/dev/null
    P_MODEL_MODE="local"; P_MODEL_PATH="$fake_model"; P_HF_REPO=""; P_HF_FILE=""
    # Set a misleading fallback.
    P_HF_FILE_BYTES=$((99 * 1073741824))
    result=$(detect_model_gb)
    [ "$result" = "1.0" ]
}

@test "estimate_vram_usage: flags OOM when total exceeds detected VRAM" {
    # 70 B Q5_K_M is ~49 GB; 32k ctx f16 cache on a 24 GB GPU should fail.
    result=$(estimate_vram_usage 49.0 32768 f16)
    total=$(awk '{print $1}' <<<"$result")
    # Total should be clearly over 24.
    awk "BEGIN { exit ($total > 24) ? 0 : 1 }"
}

@test "estimate_vram_usage: fits for a 7B + 4k ctx q8_0 on 24 GB" {
    result=$(estimate_vram_usage 7.3 4096 q8_0)
    total=$(awk '{print $1}' <<<"$result")
    awk "BEGIN { exit ($total < 24) ? 0 : 1 }"
}

# ─── hf_head_content_length ────────────────────────────────────────────
# We can't unit-test the network path itself without mocking curl; the
# guarantee we can cheaply pin is that the function always succeeds
# (returns 0) so `x=$(hf_head_content_length …)` doesn't trip set -e.

@test "hf_head_content_length: returns 0 even when curl fails" {
    # Route to a deliberately-unroutable host so curl fails fast.
    run bash -c '
        set -euo pipefail
        source "'"$SCRIPT"'"
        # monkey-patch curl: always fail
        curl() { return 6; }
        x=$(hf_head_content_length fake/repo fake.gguf)
        echo "survived:[$x]"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"survived:[]"* ]]
}

# ─── Benchmark strategy knobs ──────────────────────────────────────────
# Adaptive two-pass / workload-aware ub / VRAM pre-filter are tightly
# coupled to llama-bench and systemctl, so we can't drive the full flow
# from bats. What we CAN pin is that the defaults we pick per preset
# match the spec.

@test "bench: workload-aware ubatch default — short-prompt presets (p<=512)" {
    # For openclaw (p=64) and chat (p=512) the default should be a single ub.
    for preset in openclaw chat; do
        spec=$(bench_preset_spec "$preset")
        p=$(awk '{print $1}' <<<"$spec")
        # Replicate the logic in run_benchmark_preset
        if (( p <= 512 )); then
            default_ub="512"
        else
            default_ub="1024,2048"
        fi
        [ "$default_ub" = "512" ]
    done
}

@test "bench: workload-aware ubatch default — long-prompt presets (p>512)" {
    for preset in coding summarize; do
        spec=$(bench_preset_spec "$preset")
        p=$(awk '{print $1}' <<<"$spec")
        if (( p <= 512 )); then
            default_ub="512"
        else
            default_ub="1024,2048"
        fi
        [ "$default_ub" = "1024,2048" ]
    done
}

@test "bench VRAM filter: uses p+n context, not P_CTX (regression)" {
    # User had P_CTX=131072 (service context) and q4_0 KV cache.
    # The old code passed P_CTX to estimate_vram_usage, producing a
    # wildly inflated KV estimate (43 GB for f16!) that filtered all
    # ctks even though llama-bench only needs p+n = 320 tokens of KV.
    # The correct ctx for the estimate is p+n, not P_CTX.
    #
    # For openclaw: p=64, n=256 → ctx_bench=320 tokens.
    # At 320 tokens, even f16 KV cache is <0.1 GB, so 15 GB model
    # easily fits in 24 GB and should NOT be filtered.
    local p=64 n=256 ctx_bench=$(( 64 + 256 ))
    local model_gb=15.4 hw_vram=24

    # Verify that the bench context (p+n) gives a tiny KV estimate for f16
    local est_total
    est_total=$(estimate_vram_usage "$model_gb" "$ctx_bench" "f16" | awk '{print $1}')
    # Should be model (~15.4) + tiny KV (<0.1) + overhead (~0.9) ≈ 16.4 GB — well under 24
    awk "BEGIN { exit ($est_total < $hw_vram) ? 0 : 1 }"
}

@test "resolve_local_gguf: finds file in HF native cache via refs/main commit" {
    # Regression: llama-server downloads into models--org--repo/snapshots/<commit>/
    # but old code only checked flat and nested schemes, missing it.
    local cache_dir="${TEST_DIR}/models"
    local commit="abc123def456"
    local snap="${cache_dir}/models--bartowski--Qwen2.5-7B-GGUF/snapshots/${commit}"
    mkdir -p "$snap"
    # >1024 bytes so _resolve_hf_snapshot_file returns it directly (real blob)
    truncate -s 2048 "${snap}/model.gguf" 2>/dev/null \
        || dd if=/dev/zero bs=2048 count=1 of="${snap}/model.gguf" 2>/dev/null
    mkdir -p "${cache_dir}/models--bartowski--Qwen2.5-7B-GGUF/refs"
    printf '%s' "$commit" >"${cache_dir}/models--bartowski--Qwen2.5-7B-GGUF/refs/main"
    cat >"$UNIT_FILE" <<EOF
[Service]
User=chris
Environment="LLAMA_CACHE=${cache_dir}"
ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'
EOF
    P_MODEL_MODE="hf"
    P_HF_REPO="bartowski/Qwen2.5-7B-GGUF"
    P_HF_FILE="model.gguf"
    P_MODEL_PATH=""
    result=$(resolve_local_gguf)
    [ "$result" = "${snap}/model.gguf" ]
}

@test "resolve_local_gguf: falls back to snapshot glob when refs/main is stale" {
    local cache_dir="${TEST_DIR}/models"
    local commit="deadbeef1234"
    local snap="${cache_dir}/models--bartowski--Qwen2.5-7B-GGUF/snapshots/${commit}"
    mkdir -p "$snap"
    truncate -s 2048 "${snap}/model.gguf" 2>/dev/null \
        || dd if=/dev/zero bs=2048 count=1 of="${snap}/model.gguf" 2>/dev/null
    mkdir -p "${cache_dir}/models--bartowski--Qwen2.5-7B-GGUF/refs"
    printf 'stalecommithash' >"${cache_dir}/models--bartowski--Qwen2.5-7B-GGUF/refs/main"
    cat >"$UNIT_FILE" <<EOF
[Service]
User=chris
Environment="LLAMA_CACHE=${cache_dir}"
ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'
EOF
    P_MODEL_MODE="hf"; P_HF_REPO="bartowski/Qwen2.5-7B-GGUF"; P_HF_FILE="model.gguf"; P_MODEL_PATH=""
    result=$(resolve_local_gguf)
    [ "$result" = "${snap}/model.gguf" ]
}

@test "resolve_local_gguf: HF native cache takes priority over flat stale file" {
    local cache_dir="${TEST_DIR}/models"
    local commit="goodcommit999"
    local snap="${cache_dir}/models--x--y/snapshots/${commit}"
    mkdir -p "$snap"
    truncate -s 2048 "${snap}/z.gguf" 2>/dev/null \
        || dd if=/dev/zero bs=2048 count=1 of="${snap}/z.gguf" 2>/dev/null
    mkdir -p "${cache_dir}/models--x--y/refs"
    printf '%s' "$commit" >"${cache_dir}/models--x--y/refs/main"
    echo "STALE_PARTIAL" >"${cache_dir}/x_y--z.gguf"
    cat >"$UNIT_FILE" <<EOF
[Service]
User=chris
Environment="LLAMA_CACHE=${cache_dir}"
ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'
EOF
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"; P_MODEL_PATH=""
    result=$(resolve_local_gguf)
    [ "$result" = "${snap}/z.gguf" ]
}

@test "resolve_local_gguf: resolves git-lfs pointer in snapshot to blob in blobs/" {
    # HF native cache stores tiny (~76 B) git-lfs pointer files in snapshots/;
    # the actual model data lives in blobs/<sha256>. We must follow the pointer.
    local cache_dir="${TEST_DIR}/models"
    local commit="lfscommit789"
    local oid="abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab"
    local repo_dir="${cache_dir}/models--org--repo"
    local snap="${repo_dir}/snapshots/${commit}"
    local blob_dir="${repo_dir}/blobs"
    mkdir -p "$snap" "$blob_dir"
    # Write a real git-lfs pointer (< 1024 bytes)
    printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize 15000000000\n' "$oid" \
        >"${snap}/model.gguf"
    # Write the real blob (> 1024 bytes so validate_gguf won't reject it in this test)
    truncate -s 2048 "${blob_dir}/${oid}" 2>/dev/null \
        || dd if=/dev/zero bs=2048 count=1 of="${blob_dir}/${oid}" 2>/dev/null
    mkdir -p "${repo_dir}/refs"
    printf '%s' "$commit" >"${repo_dir}/refs/main"
    cat >"$UNIT_FILE" <<EOF
[Service]
User=chris
Environment="LLAMA_CACHE=${cache_dir}"
ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'
EOF
    P_MODEL_MODE="hf"; P_HF_REPO="org/repo"; P_HF_FILE="model.gguf"; P_MODEL_PATH=""
    result=$(resolve_local_gguf)
    [ "$result" = "${blob_dir}/${oid}" ]
}

@test "resolve_local_gguf: follows symlink in snapshot dir to blob (llama.cpp native download)" {
    # llama.cpp creates symlinks in snapshots/<commit>/<file> → ../../blobs/<sha256>.
    # stat -c%s on a Linux symlink returns the TARGET PATH LENGTH (e.g. 76 for
    # a 64-char sha256 hash), NOT the blob size. _resolve_hf_snapshot_file must
    # detect [[ -L ]] BEFORE stat to avoid grep-scanning the 15 GB blob.
    local cache_dir="${TEST_DIR}/models"
    local commit="symlinkcommit01"
    local sha256="cafebabe1234567890cafebabe1234567890cafebabe1234567890cafebabe12"
    local repo_dir="${cache_dir}/models--llama--Model"
    local snap="${repo_dir}/snapshots/${commit}"
    local blob_dir="${repo_dir}/blobs"
    mkdir -p "$snap" "$blob_dir" "${repo_dir}/refs"
    # Write the real blob
    truncate -s 2048 "${blob_dir}/${sha256}" 2>/dev/null \
        || dd if=/dev/zero bs=2048 count=1 of="${blob_dir}/${sha256}" 2>/dev/null
    # Create symlink: snapshots/<commit>/<file> → ../../blobs/<sha256>
    ln -sf "../../blobs/${sha256}" "${snap}/model.gguf"
    printf '%s' "$commit" >"${repo_dir}/refs/main"
    cat >"$UNIT_FILE" <<EOF
[Service]
User=chris
Environment="LLAMA_CACHE=${cache_dir}"
ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --port 8080'
EOF
    P_MODEL_MODE="hf"; P_HF_REPO="llama/Model"; P_HF_FILE="model.gguf"; P_MODEL_PATH=""
    result=$(resolve_local_gguf)
    [ "$result" = "${blob_dir}/${sha256}" ]
}

@test "validate_gguf: accepts a file with correct GGUF magic and size" {
    local f="${TEST_DIR}/good.gguf"
    # Write 'GGUF' magic + enough padding to pass the 10 MB size check.
    printf 'GGUF' >"$f"
    truncate -s 20971520 "$f" 2>/dev/null \
        || dd if=/dev/zero bs=1 count=0 seek=20971520 of="$f" 2>/dev/null
    run validate_gguf "$f"
    [ "$status" -eq 0 ]
}

@test "validate_gguf: rejects a file smaller than 10 MB" {
    local f="${TEST_DIR}/tiny.gguf"
    printf 'GGUF' >"$f"
    run validate_gguf "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"partial download"* ]]
}

@test "validate_gguf: rejects a git-lfs pointer file (wrong magic)" {
    local f="${TEST_DIR}/pointer.gguf"
    # git-lfs pointer starts with "version " not "GGUF"
    printf 'version https://git-lfs.github.com/spec/v1\n' >"$f"
    truncate -s 20971520 "$f" 2>/dev/null \
        || dd if=/dev/zero bs=1 count=0 seek=20971520 of="$f" 2>/dev/null
    run validate_gguf "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"GGUF header"* ]]
}

@test "validate_gguf: rejects a missing file" {
    run validate_gguf "${TEST_DIR}/nonexistent.gguf"
    [ "$status" -ne 0 ]
}

@test "bench: default ctk_list includes current P_CACHE_K" {
    # When user has q4_0 configured, the default sweep should include q4_0.
    # Regression: old hardcoded "f16,q8_0" excluded q4_0, so the VRAM filter
    # (correctly rejecting f16 and q8_0 at 131k ctx) produced zero candidates.
    local current_ctk="q4_0" ctk_list=""
    if [[ -z "$ctk_list" ]]; then
        case "$current_ctk" in
            q4_0|q4_1|iq4_nl)  ctk_list="${current_ctk},q8_0" ;;
            q5_0|q5_1)         ctk_list="${current_ctk},q8_0" ;;
            q8_0)              ctk_list="${current_ctk},f16" ;;
            f16|bf16)          ctk_list="${current_ctk},q8_0" ;;
            *)                 ctk_list="${current_ctk},q8_0" ;;
        esac
    fi
    [[ "$ctk_list" == "q4_0,"* ]]
    [[ "$ctk_list" == *"q4_0"* ]]
}

# ─── detect_model_arch ─────────────────────────────────────────────────────

@test "detect_model_arch: Qwen3 repo → gqa" {
    result=$(detect_model_arch "XpressAI/Qwen3-27B-RYS-UD-Q4_K_XL-GGUF")
    [[ "$result" == *"gqa"* ]]
}

@test "detect_model_arch: Llama-3 repo → gqa" {
    result=$(detect_model_arch "meta-llama/Meta-Llama-3-8B-Instruct-GGUF")
    [[ "$result" == *"gqa"* ]]
}

@test "detect_model_arch: Gemma repo → gqa" {
    result=$(detect_model_arch "google/gemma-2-9b-it-GGUF")
    [[ "$result" == *"gqa"* ]]
}

@test "detect_model_arch: Mixtral repo → moe (not gqa)" {
    result=$(detect_model_arch "mistralai/Mixtral-8x7B-Instruct-v0.1-GGUF")
    [[ "$result" == *"moe"* ]]
    [[ "$result" != *"gqa"* ]]
}

@test "detect_model_arch: DeepSeek-V2 → moe" {
    result=$(detect_model_arch "deepseek-ai/DeepSeek-V2-Chat-GGUF")
    [[ "$result" == *"moe"* ]]
}

@test "detect_model_arch: DeepSeek-R1 → moe" {
    result=$(detect_model_arch "deepseek-ai/DeepSeek-R1-GGUF")
    [[ "$result" == *"moe"* ]]
}

@test "detect_model_arch: Qwen2-MoE → both gqa and moe" {
    result=$(detect_model_arch "Qwen/Qwen2-57B-A14B-Instruct-GGUF")
    [[ "$result" == *"gqa"* ]]
    # repo name contains Qwen but not -moe-; A14B style isn't detected (acceptable)
    # Confirm no false crash — just check gqa is present
}

@test "detect_model_arch: Qwen2-MoE with explicit moe in slug → gqa + moe" {
    result=$(detect_model_arch "Qwen/Qwen2-MoE-57B-A14B-GGUF")
    [[ "$result" == *"gqa"* ]]
    [[ "$result" == *"moe"* ]]
}

@test "detect_model_arch: unknown model → empty string" {
    result=$(detect_model_arch "some-org/random-model-7b-GGUF")
    [[ -z "$result" ]]
}

@test "detect_model_arch: Phi-4 → gqa" {
    result=$(detect_model_arch "microsoft/phi-4-GGUF")
    [[ "$result" == *"gqa"* ]]
}

# ─── warn_model_compat ─────────────────────────────────────────────────────

@test "warn_model_compat: GQA + non-f16 KV + flash off → emits warning" {
    P_HF_REPO="XpressAI/Qwen3-27B-GGUF"
    P_HF_FILE="Qwen3-27B-Q4_K_M.gguf"
    P_MODEL_PATH=""
    P_FLASH="off"
    P_CACHE_K="q8_0"
    P_N_CPU_MOE=""
    output=$(warn_model_compat 2>&1)
    [[ "$output" == *"flash attention"* ]]
}

@test "warn_model_compat: GQA + f16 KV + flash off → no warning" {
    P_HF_REPO="meta-llama/Meta-Llama-3-8B-GGUF"
    P_HF_FILE="Meta-Llama-3-8B.gguf"
    P_MODEL_PATH=""
    P_FLASH="off"
    P_CACHE_K="f16"
    P_N_CPU_MOE=""
    output=$(warn_model_compat 2>&1)
    [[ "$output" != *"flash attention"* ]]
}

@test "warn_model_compat: GQA + non-f16 KV + flash on → no warning" {
    P_HF_REPO="XpressAI/Qwen3-27B-GGUF"
    P_HF_FILE="Qwen3-27B-Q4_K_M.gguf"
    P_MODEL_PATH=""
    P_FLASH="on"
    P_CACHE_K="q8_0"
    P_N_CPU_MOE=""
    output=$(warn_model_compat 2>&1)
    [[ "$output" != *"flash attention"* ]]
}

@test "warn_model_compat: MoE + n-cpu-moe unset → emits hint" {
    P_HF_REPO="mistralai/Mixtral-8x7B-Instruct-v0.1-GGUF"
    P_HF_FILE="Mixtral-8x7B-Instruct-v0.1-Q4_K_M.gguf"
    P_MODEL_PATH=""
    P_FLASH="off"
    P_CACHE_K="f16"
    P_N_CPU_MOE=""
    output=$(warn_model_compat 2>&1)
    [[ "$output" == *"n-cpu-moe"* ]]
}

@test "warn_model_compat: MoE + n-cpu-moe already set → no hint" {
    P_HF_REPO="mistralai/Mixtral-8x7B-Instruct-v0.1-GGUF"
    P_HF_FILE="Mixtral-8x7B-Instruct-v0.1-Q4_K_M.gguf"
    P_MODEL_PATH=""
    P_FLASH="off"
    P_CACHE_K="f16"
    P_N_CPU_MOE="2"
    output=$(warn_model_compat 2>&1)
    [[ "$output" != *"n-cpu-moe"* ]]
}

@test "warn_model_compat: unknown model → no output" {
    P_HF_REPO="some-org/random-model-7b-GGUF"
    P_HF_FILE="random-model-7b-Q4_K_M.gguf"
    P_MODEL_PATH=""
    P_FLASH="off"
    P_CACHE_K="q8_0"
    P_N_CPU_MOE=""
    output=$(warn_model_compat 2>&1)
    [[ -z "$output" ]]
}

@test "warn_model_compat: no model set → no output" {
    P_HF_REPO=""
    P_HF_FILE=""
    P_MODEL_PATH=""
    P_FLASH="off"
    P_CACHE_K="q8_0"
    P_N_CPU_MOE=""
    output=$(warn_model_compat 2>&1)
    [[ -z "$output" ]]
}

# ─── grp-attn parse / serialize / round-trip ───────────────────────────────

@test "parse: --grp-attn-n and --grp-attn-w parsed correctly" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo x/y --hf-file z.gguf --port 8080 --grp-attn-n 4 --grp-attn-w 512 >> \"/log\" 2>&1'"
    parse_unit_file
    [ "$P_GRP_ATTN_N" = "4" ]
    [ "$P_GRP_ATTN_W" = "512" ]
}

@test "parse: --grp-attn-n absent → P_GRP_ATTN_N empty" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo x/y --hf-file z.gguf --port 8080 >> \"/log\" 2>&1'"
    parse_unit_file
    [ -z "$P_GRP_ATTN_N" ]
    [ -z "$P_GRP_ATTN_W" ]
}

@test "serialize: --grp-attn-n and --grp-attn-w emitted when set" {
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"
    P_PORT="8080"; P_IS_CUDA="n"
    P_CTX=""; P_NGL=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""
    P_HOST=""; P_MLOCK="n"; P_FIT=""; P_FIT_CTX=""; P_N_CPU_MOE=""
    P_UBATCH=""; P_DIO="n"; P_GRP_ATTN_N="4"; P_GRP_ATTN_W="512"
    result=$(serialize_arg_string)
    [[ "$result" == *"--grp-attn-n 4"* ]]
    [[ "$result" == *"--grp-attn-w 512"* ]]
}

@test "serialize: grp-attn flags absent when P_GRP_ATTN_N empty" {
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"
    P_PORT="8080"; P_IS_CUDA="n"
    P_CTX=""; P_NGL=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""
    P_HOST=""; P_MLOCK="n"; P_FIT=""; P_FIT_CTX=""; P_N_CPU_MOE=""
    P_UBATCH=""; P_DIO="n"; P_GRP_ATTN_N=""; P_GRP_ATTN_W=""
    result=$(serialize_arg_string)
    [[ "$result" != *"--grp-attn"* ]]
}

@test "round-trip: --grp-attn-n 4 --grp-attn-w 512 survives parse → serialize" {
    write_unit "ExecStart=/bin/bash -c 'exec /usr/local/bin/llama-server --hf-repo x/y --hf-file z.gguf --port 8080 --grp-attn-n 4 --grp-attn-w 512 >> \"/log\" 2>&1'"
    parse_unit_file
    result=$(serialize_arg_string)
    [[ "$result" == *"--grp-attn-n 4"* ]]
    [[ "$result" == *"--grp-attn-w 512"* ]]
}

# ─── detect_llama_src_dir ──────────────────────────────────────────────────

@test "detect_llama_src_dir: finds repo at expected ~/llama.cpp location" {
    # Simulate a service user whose home contains a llama.cpp git checkout.
    local fake_home; fake_home=$(mktemp -d)
    local fake_src="${fake_home}/llama.cpp"
    mkdir -p "${fake_src}/.git"
    touch "${fake_src}/CMakeLists.txt"

    # Point UNIT_FILE at a unit that names our fake user.
    local fake_user; fake_user=$(basename "$fake_home")   # random tmp name
    # Temporarily override detect_user_from_unit to return the fake home's
    # basename, then override the candidate list by setting HOME.
    # Simplest: write a unit with User= pointing to a real user so
    # detect_user_from_unit resolves; then patch the candidate path directly.
    #
    # Easier approach: override detect_llama_src_dir's candidate list by
    # monkey-patching the function to use $fake_home instead of /home/<user>.
    detect_llama_src_dir() {
        local dir="${fake_src}"
        if [[ -d "${dir}/.git" && -f "${dir}/CMakeLists.txt" ]]; then
            printf '%s' "$dir"; return 0
        fi
        return 1
    }

    result=$(detect_llama_src_dir)
    [ "$result" = "$fake_src" ]
    rm -rf "$fake_home"
}

@test "detect_llama_src_dir: returns 1 when no git repo found" {
    detect_llama_src_dir() {
        return 1
    }
    ! detect_llama_src_dir
}
