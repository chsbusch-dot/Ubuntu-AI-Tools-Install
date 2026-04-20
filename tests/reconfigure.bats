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
    P_HOST=""; P_MLOCK="n"; P_FIT=""; P_FIT_CTX=""
    result=$(serialize_arg_string)
    [ "$result" = "--hf-repo org/repo --hf-file m.gguf --port 8080" ]
}

@test "serialize: full CUDA config is deterministic" {
    P_MODEL_MODE="hf"; P_HF_REPO="org/repo"; P_HF_FILE="m.gguf"
    P_PORT="8080"; P_IS_CUDA="y"; P_NGL="99"; P_HOST="0.0.0.0"
    P_CTX="32768"; P_CACHE_K="q8_0"; P_CACHE_V="q8_0"
    P_FLASH="on"; P_MLOCK="y"; P_FIT=""; P_FIT_CTX=""
    result=$(serialize_arg_string)
    [ "$result" = "--hf-repo org/repo --hf-file m.gguf --port 8080 -ngl 99 --host 0.0.0.0 -c 32768 -ctk q8_0 -ctv q8_0 --flash-attn on --mlock" ]
}

@test "serialize: --fit on suppresses -ngl (they are mutually exclusive)" {
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"
    P_PORT="8080"; P_NGL="50"; P_FIT="on"; P_FIT_CTX="65536"
    P_CTX=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""; P_HOST=""; P_MLOCK="n"
    result=$(serialize_arg_string)
    [[ "$result" == *"--fit on --fit-ctx 65536"* ]]
    [[ "$result" != *"-ngl 50"* ]]
}

@test "serialize: local model uses --model not --hf-repo" {
    P_MODEL_MODE="local"; P_MODEL_PATH="/m/path.gguf"; P_PORT="8080"
    P_CTX=""; P_NGL=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""
    P_HOST=""; P_MLOCK="n"; P_FIT=""; P_FIT_CTX=""
    P_HF_REPO=""; P_HF_FILE=""
    result=$(serialize_arg_string)
    [ "$result" = "--model /m/path.gguf --port 8080" ]
}

@test "serialize: --fit-ctx defaults to 65536 if unset" {
    P_MODEL_MODE="hf"; P_HF_REPO="x/y"; P_HF_FILE="z.gguf"
    P_PORT="8080"; P_FIT="on"; P_FIT_CTX=""
    P_CTX=""; P_NGL=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""; P_HOST=""; P_MLOCK="n"
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
