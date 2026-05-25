#!/bin/bash
#
# llama-reconfigure — menu-driven editor for an installed llama-server.service
#
# Lets you change the model and/or runtime flags on a running llama.cpp
# systemd service, then safely swaps the unit and restarts. Parses the
# existing ExecStart line in-place so hand edits and install-time choices
# are preserved; only the flags you touch change.
#
# Part of the ubuntu-prep project:
#   https://github.com/chsbusch-dot/Ubuntu-AI-Tools-Install
#
# This is a standalone script — it does NOT require ubuntu-prep-setup.sh
# to be present. Install once, then re-run whenever you want to retune.

set -euo pipefail

LLAMA_RECONFIGURE_VERSION="1.6.0"

UNIT_FILE="/etc/systemd/system/llama-server.service"
BAK_FILE="${UNIT_FILE}.bak"

# ─── Colours ───────────────────────────────────────────────────────────
C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'
C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
C_CYAN=$'\e[36m'

info()    { printf '%s➜%s %s\n'   "$C_CYAN"   "$C_RESET" "$*"; }
ok()      { printf '%s✓%s %s\n'   "$C_GREEN"  "$C_RESET" "$*"; }
warn()    { printf '%s⚠%s %s\n'   "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()     { printf '%s✗%s %s\n'   "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }

# ─── Usage ─────────────────────────────────────────────────────────────
show_usage() {
    cat <<USAGE
llama-reconfigure ${LLAMA_RECONFIGURE_VERSION} — edit an installed llama-server.service

Usage: llama-reconfigure [OPTION]

Runs an interactive menu by default. Each --flag below jumps straight
into that editor; after applying you're returned to the main menu or
you can cancel.

EDITOR JUMPS
  --model       HuggingFace repo/file (e.g. org/repo:file.gguf) or a local path
  --context     Context size (-c)
  --ngl         GPU layer offload (-ngl)
  --cache       KV cache quant (-ctk / -ctv)
  --flash       Toggle --flash-attn
  --ubatch      Ubatch (prompt-processing batch size, -ub)
  --listen      Listen address (--host / --port)
  --mlock       Toggle --mlock
  --dio         Toggle -dio (direct I/O to prevent tensor hang)
  --grp-attn    Edit --grp-attn-n / --grp-attn-w (context extension)
  --fit         Auto-fit (--fit / --fit-ctx)
  --n-cpu-moe   MoE expert layers on CPU (--n-cpu-moe)
  --raw         Raw ExecStart arg-string editor (advanced)

BENCHMARK
  --benchmark [PRESET]   Sweep ubatch × kv-cache × flash-attn with
                         llama-bench for a workload preset, rank by
                         total wall-clock time, offer to apply winner.
                         PRESET is one of: openclaw, chat (default),
                         coding, summarize.

READ-ONLY / MAINTENANCE
  --show        Print the parsed current configuration and exit
  --dry-run     Walk through the menu, print the would-be ExecStart, write nothing
  --rollback    Restore llama-server.service from the last .bak and restart

  --version, -V Print version and exit
  --help, -h    Show this help and exit

REQUIRES
  - /etc/systemd/system/llama-server.service (run ubuntu-prep-setup.sh first)
  - sudo (the script re-execs itself with sudo if run as a normal user)

SAFETY
  The current unit is copied to ${BAK_FILE} before every change.
  Use --rollback to restore it if something fails.
USAGE
}

# ─── Preconditions ─────────────────────────────────────────────────────

require_unit_file() {
    [[ -f "$UNIT_FILE" ]] || die "No llama-server service found at ${UNIT_FILE}. Run ubuntu-prep-setup.sh first."
}

ensure_root() {
    # Re-exec with sudo, preserving env so HF_TOKEN from the user's
    # ~/.env.secrets is available if something downstream sources it.
    if [[ $EUID -ne 0 ]]; then
        exec sudo --preserve-env=HF_TOKEN -- bash "$0" "$@"
    fi
}

# ─── Parser ────────────────────────────────────────────────────────────
#
# Populates globals from the current unit file:
#   P_EXEC_PREFIX   everything before the llama-server arg list
#   P_EXEC_SUFFIX   everything after the llama-server arg list
#   P_ARG_STRING    the raw arg list (hf-repo/file/model + runtime flags)
#   P_IS_CUDA       y/n — inferred from LD_LIBRARY_PATH or -ngl
#   P_MODEL_MODE    hf | local
#   P_HF_REPO       bartowski/Qwen2.5-…-GGUF       (if HF)
#   P_HF_FILE       Qwen2.5-…-Q5_K_M.gguf           (if HF)
#   P_MODEL_PATH    /home/.../model.gguf            (if local)
#   P_CTX           32768
#   P_NGL           99
#   P_CACHE_K       q8_0
#   P_CACHE_V       q8_0
#   P_FLASH         on / off
#   P_HOST          0.0.0.0 / 127.0.0.1 / (unset)
#   P_PORT          8080
#   P_MLOCK         y/n
#   P_FIT           on / off
#   P_FIT_CTX       65536
#   P_N_CPU_MOE     integer (MoE expert layers on CPU; empty = unset)
#   P_UBATCH        integer (-ub; empty = unset)
#   P_DIO           y/n
#   P_GRP_ATTN_N    integer (--grp-attn-n; empty = unset / disabled)
#   P_GRP_ATTN_W    integer (--grp-attn-w; empty = unset)
#   P_JINJA         y/n
#   P_REASONING     on / off / (empty = unset)
#   P_PARALLEL      integer (--parallel; empty = unset)
#
parse_unit_file() {
    local exec_line
    exec_line=$(grep -m1 '^ExecStart=' "$UNIT_FILE" || true)
    [[ -n "$exec_line" ]] || die "No ExecStart= in ${UNIT_FILE}"

    # Split on "llama-server " and ">>" — everything between is the arg list.
    local after_binary before_redir
    if [[ "$exec_line" == *"/usr/local/bin/llama-server "* ]]; then
        P_EXEC_PREFIX="${exec_line%%/usr/local/bin/llama-server *}/usr/local/bin/llama-server "
        after_binary="${exec_line#*/usr/local/bin/llama-server }"
    else
        die "ExecStart does not invoke /usr/local/bin/llama-server — unsupported layout."
    fi

    if [[ "$after_binary" == *">>"* ]]; then
        P_ARG_STRING="${after_binary%% >>*}"
        before_redir=" >>${after_binary#* >>}"
        P_EXEC_SUFFIX="$before_redir"
    else
        # No redirect — arg list runs to end of line (minus any trailing quote)
        P_ARG_STRING="${after_binary%\'}"
        P_EXEC_SUFFIX="${after_binary#"$P_ARG_STRING"}"
    fi

    # CUDA detection: LD_LIBRARY_PATH in Environment= or -ngl in arg string
    if grep -qE 'LD_LIBRARY_PATH.*cuda' "$UNIT_FILE" 2>/dev/null \
        || [[ "$P_ARG_STRING" == *"-ngl "* ]]; then
        P_IS_CUDA="y"
    else
        P_IS_CUDA="n"
    fi

    P_HF_REPO=""; P_HF_FILE=""; P_MODEL_PATH=""; P_MODEL_MODE=""
    P_RAW_OVERRIDE=""   # clear any raw-edit override so the parsed state is canonical
    # Byte size of the HF file when we've queried it via HEAD — used by
    # detect_model_gb() to show the VRAM estimate before the model is
    # downloaded to local disk. Reset on every parse.
    P_HF_FILE_BYTES=""
    if [[ "$P_ARG_STRING" == *"--hf-repo "* ]]; then
        P_MODEL_MODE="hf"
        P_HF_REPO=$(grep -oE -- '--hf-repo [^ ]+' <<<"$P_ARG_STRING" | awk '{print $2}' | head -1)
        P_HF_FILE=$(grep -oE -- '--hf-file [^ ]+' <<<"$P_ARG_STRING" | awk '{print $2}' | head -1)
    elif [[ "$P_ARG_STRING" == *"--model "* || "$P_ARG_STRING" == *" -m "* ]]; then
        P_MODEL_MODE="local"
        P_MODEL_PATH=$(grep -oE -- '--model [^ ]+' <<<"$P_ARG_STRING" | awk '{print $2}' | head -1)
        [[ -z "$P_MODEL_PATH" ]] && P_MODEL_PATH=$(grep -oE -- ' -m [^ ]+' <<<"$P_ARG_STRING" | awk '{print $2}' | head -1)
    fi

    P_CTX=$(grep -oE -- ' -c [0-9]+'    <<<"$P_ARG_STRING" | awk '{print $2}' | head -1 || true)
    P_NGL=$(grep -oE -- '-ngl [0-9]+'   <<<"$P_ARG_STRING" | awk '{print $2}' | head -1 || true)
    P_CACHE_K=$(grep -oE -- '-ctk [^ ]+' <<<"$P_ARG_STRING" | awk '{print $2}' | head -1 || true)
    P_CACHE_V=$(grep -oE -- '-ctv [^ ]+' <<<"$P_ARG_STRING" | awk '{print $2}' | head -1 || true)
    if [[ "$P_ARG_STRING" == *"--flash-attn on"* ]]; then P_FLASH="on"
    elif [[ "$P_ARG_STRING" == *"--flash-attn off"* ]]; then P_FLASH="off"
    else P_FLASH=""; fi
    P_HOST=$(grep -oE -- '--host [^ ]+'  <<<"$P_ARG_STRING" | awk '{print $2}' | head -1 || true)
    P_PORT=$(grep -oE -- '--port [0-9]+' <<<"$P_ARG_STRING" | awk '{print $2}' | head -1 || true)
    [[ "$P_ARG_STRING" == *"--mlock"* ]] && P_MLOCK="y" || P_MLOCK="n"
    P_FIT=$(grep -oE -- '--fit (on|off)' <<<"$P_ARG_STRING" | awk '{print $2}' | head -1 || true)
    P_FIT_CTX=$(grep -oE -- '--fit-ctx [0-9]+' <<<"$P_ARG_STRING" | awk '{print $2}' | head -1 || true)
    P_N_CPU_MOE=$(grep -oE -- '--n-cpu-moe [0-9]+' <<<"$P_ARG_STRING" | awk '{print $2}' | head -1 || true)
    P_UBATCH=$(grep -oE -- '(-ub|--ubatch) [0-9]+' <<<"$P_ARG_STRING" | awk '{print $2}' | head -1 || true)
    [[ "$P_ARG_STRING" =~ (^| )-dio( |$) ]] && P_DIO="y" || P_DIO="n"
    P_GRP_ATTN_N=$(grep -oE -- '--grp-attn-n [0-9]+' <<<"$P_ARG_STRING" | awk '{print $2}' | head -1 || true)
    P_GRP_ATTN_W=$(grep -oE -- '--grp-attn-w [0-9]+' <<<"$P_ARG_STRING" | awk '{print $2}' | head -1 || true)
    [[ "$P_ARG_STRING" == *"--jinja"* ]] && P_JINJA="y" || P_JINJA="n"
    if [[ "$P_ARG_STRING" == *"--reasoning on"* ]]; then P_REASONING="on"
    elif [[ "$P_ARG_STRING" == *"--reasoning off"* ]]; then P_REASONING="off"
    else P_REASONING=""; fi
    P_PARALLEL=$(grep -oE -- '--parallel [0-9]+' <<<"$P_ARG_STRING" | awk '{print $2}' | head -1 || true)
}

# ─── Serializer ────────────────────────────────────────────────────────
#
# Builds a fresh arg string from P_* globals. Flag order is fixed so
# the output is deterministic (easier to diff, easier to test).
#
serialize_arg_string() {
    local out=""

    case "$P_MODEL_MODE" in
        hf)
            out+="--hf-repo $P_HF_REPO"
            [[ -n "$P_HF_FILE" ]] && out+=" --hf-file $P_HF_FILE"
            ;;
        local)
            out+="--model $P_MODEL_PATH"
            ;;
    esac

    [[ -n "$P_PORT" ]]    && out+=" --port $P_PORT"
    [[ "$P_FIT" == "on" ]] && out+=" --fit on --fit-ctx ${P_FIT_CTX:-65536}"
    if [[ "$P_FIT" != "on" && -n "$P_NGL" ]]; then
        out+=" -ngl $P_NGL"
    fi
    [[ -n "$P_HOST" ]]       && out+=" --host $P_HOST"
    [[ -n "$P_CTX" ]]        && out+=" -c $P_CTX"
    [[ -n "$P_UBATCH" ]]     && out+=" -ub $P_UBATCH"
    [[ -n "$P_CACHE_K" ]]    && out+=" -ctk $P_CACHE_K"
    [[ -n "$P_CACHE_V" ]]    && out+=" -ctv $P_CACHE_V"
    # Emit both on and off explicitly — the parser records "off" from existing
    # units and a round-trip must preserve it; silence means "use server default".
    if [[ "$P_FLASH" == "on" ]]; then out+=" --flash-attn on"
    elif [[ "$P_FLASH" == "off" ]]; then out+=" --flash-attn off"; fi
    [[ "$P_MLOCK" == "y" ]]  && out+=" --mlock"
    [[ "$P_DIO" == "y" ]]        && out+=" -dio"
    [[ -n "$P_N_CPU_MOE" ]]     && out+=" --n-cpu-moe $P_N_CPU_MOE"
    [[ -n "${P_GRP_ATTN_N:-}" ]] && out+=" --grp-attn-n $P_GRP_ATTN_N"
    [[ -n "${P_GRP_ATTN_W:-}" ]] && out+=" --grp-attn-w $P_GRP_ATTN_W"
    [[ "${P_JINJA:-n}" == "y" ]]     && out+=" --jinja"
    if [[ "${P_REASONING:-}" == "on" ]]; then out+=" --reasoning on"
    elif [[ "${P_REASONING:-}" == "off" ]]; then out+=" --reasoning off"; fi
    [[ -n "${P_PARALLEL:-}" ]]       && out+=" --parallel $P_PARALLEL"

    printf '%s' "$out"
}

# Rejects a single quote in the arg string — would break the unit file.
validate_arg_string() {
    local s="$1"
    if [[ "$s" == *\'* ]]; then
        warn "Arg string contains a single quote; would break the systemd unit. Edit cancelled."
        return 1
    fi
}

# ─── Path helpers ──────────────────────────────────────────────────────
#
# The systemd unit runs as a non-root user and tells llama-server to cache
# HF downloads under $LLAMA_CACHE. We parse both out of the unit so the
# model-size / VRAM estimator and the hf_resolve_or_download helper can
# find pre-downloaded .gguf files on any user's machine (not just "chris").

detect_user_from_unit() {
    local u
    u=$(grep -oE '^User=[^[:space:]]+' "$UNIT_FILE" 2>/dev/null | head -1 | cut -d= -f2 || true)
    [[ -n "$u" ]] || u="${SUDO_USER:-${USER:-root}}"
    printf '%s' "$u"
}

detect_llama_cache() {
    local cache
    cache=$(grep -oE 'LLAMA_CACHE=[^"[:space:]]+' "$UNIT_FILE" 2>/dev/null | head -1 | cut -d= -f2 || true)
    if [[ -z "$cache" ]]; then
        local u; u=$(detect_user_from_unit)
        cache="/home/${u}/llama.cpp/models"
    fi
    printf '%s' "$cache"
}

# Resolve a file in an HF snapshot dir to the actual model blob.
#
# llama.cpp native downloads create a symlink:
#   snapshots/<commit>/<file>  →  ../../blobs/<sha256>
# The huggingface_hub Python library creates a git-lfs pointer text file
# (~120 bytes) instead of a symlink.
#
# IMPORTANT: stat -c%s on a Linux symlink returns the TARGET PATH LENGTH,
# not the blob size. For a 64-hex sha256 hash the path is exactly 76 chars
# ("../../blobs/<sha256>"). Calling grep on such an entry follows the
# symlink and scans the 15+ GB blob — causing a ~20 s hang.
# We always check for symlinks first.
#
# Usage: _resolve_hf_snapshot_file <snap_file> <hf_repo_dir>
# Prints the resolved path and returns 0; returns 1 if blob not found.
_resolve_hf_snapshot_file() {
    local snap_file="$1" hf_repo_dir="$2"

    # --- Case 1: symlink (llama.cpp native download) ---
    if [[ -L "$snap_file" ]]; then
        local link_target
        link_target=$(readlink "$snap_file" 2>/dev/null || true)
        # Target is always ../../blobs/<sha256>; extract the blob name.
        if [[ "$link_target" == *"blobs/"* ]]; then
            local blob_path="${hf_repo_dir}/blobs/${link_target##*/}"
            [[ -f "$blob_path" ]] && { printf '%s' "$blob_path"; return 0; }
        fi
        return 1
    fi

    # --- Case 2: regular file that is already the real blob (> 1 KB) ---
    local size
    size=$(stat -c%s "$snap_file" 2>/dev/null || stat -f%z "$snap_file" 2>/dev/null || echo 0)
    if [[ "${size:-0}" -gt 1024 ]]; then
        printf '%s' "$snap_file"
        return 0
    fi

    # --- Case 3: git-lfs pointer text file (huggingface_hub Python) ---
    local oid
    oid=$(grep -m1 '^oid sha256:' "$snap_file" 2>/dev/null | cut -d: -f2 | tr -d '[:space:]' || true)
    if [[ -n "$oid" ]]; then
        local blob
        for blob in "${hf_repo_dir}/blobs/${oid}" "${hf_repo_dir}/blobs/sha256:${oid}"; do
            [[ -f "$blob" ]] && { printf '%s' "$blob"; return 0; }
        done
    fi
    return 1
}

# Given P_* state, print the on-disk .gguf path if it can be located,
# otherwise print nothing. Search order:
#
#   1. HuggingFace native cache — this is where llama-server (--hf-repo)
#      downloads files. Layout:
#        $LLAMA_CACHE/models--<org>--<repo>/snapshots/<commit>/<file>
#      Snapshot entries are git-lfs pointer files; resolved to
#      blobs/<sha256> via _resolve_hf_snapshot_file.
#      We prefer the commit pinned in refs/main, then fall back to
#      globbing all snapshots (in case refs/main is stale).
#
#   2. Flat naming scheme ($LLAMA_CACHE/<org_repo>--<file>) — used by
#      older versions of this script. Files here may be partial/stale.
#
#   3. Nested org/repo/file and bare filename — additional fallbacks.
#
# IMPORTANT: we validate the file with validate_gguf before using it
# for anything destructive (benchmark, etc). The flat cache is searched
# second precisely because it can hold stale partial downloads.
resolve_local_gguf() {
    if [[ "${P_MODEL_MODE:-}" == "local" && -f "${P_MODEL_PATH:-}" ]]; then
        printf '%s' "$P_MODEL_PATH"
        return 0
    fi
    if [[ "${P_MODEL_MODE:-}" == "hf" && -n "${P_HF_FILE:-}" && -n "${P_HF_REPO:-}" ]]; then
        local cache candidate
        cache=$(detect_llama_cache)

        # 1. HF native cache (models--<org>--<repo>/snapshots/*)
        local hf_native_dir="${cache}/models--${P_HF_REPO//\//--}"
        if [[ -d "$hf_native_dir" ]]; then
            local resolved
            # Prefer the commit pinned in refs/main for determinism.
            local ref_file="${hf_native_dir}/refs/main"
            if [[ -f "$ref_file" ]]; then
                local commit
                commit=$(tr -d '[:space:]' <"$ref_file" 2>/dev/null || true)
                candidate="${hf_native_dir}/snapshots/${commit}/${P_HF_FILE}"
                if [[ -f "$candidate" ]]; then
                    if resolved=$(_resolve_hf_snapshot_file "$candidate" "$hf_native_dir"); then
                        printf '%s' "$resolved"; return 0
                    fi
                fi
            fi
            # Fallback: iterate every snapshot (handles stale refs/main).
            for candidate in "${hf_native_dir}/snapshots"/*/"${P_HF_FILE}"; do
                if [[ -f "$candidate" ]]; then
                    if resolved=$(_resolve_hf_snapshot_file "$candidate" "$hf_native_dir"); then
                        printf '%s' "$resolved"; return 0
                    fi
                fi
            done
        fi

        # 2–4. Legacy / manual cache naming schemes.
        for candidate in \
            "${cache}/${P_HF_REPO//\//_}--${P_HF_FILE}" \
            "${cache}/${P_HF_REPO}/${P_HF_FILE}" \
            "${cache}/${P_HF_FILE}"; do
            [[ -f "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
        done
    fi
    return 0
}

# Checks that a .gguf file is plausibly intact before we hand it to
# llama-bench (or any other consumer). Catches partial downloads
# (wrong size), git-lfs pointer files (not the actual blob), and
# obviously corrupted files (bad GGUF magic bytes).
validate_gguf() {
    local path="$1"
    [[ -f "$path" ]] || { warn "Model file not found: $path"; return 1; }
    [[ -r "$path" ]] || { warn "Model file not readable: $path"; return 1; }

    local size
    size=$(stat -c%s "$path" 2>/dev/null || stat -f%z "$path" 2>/dev/null || echo 0)
    if [[ "${size:-0}" -lt 10485760 ]]; then   # < 10 MB → pointer file or truncated
        local first_line
        first_line=$(head -1 "$path" 2>/dev/null || true)
        if [[ "$first_line" == "version https://git-lfs"* ]]; then
            warn "Model file is a git-lfs pointer ($(human_size "${size:-0}")) — blob not found in HF cache:"
            warn "  $path"
            warn "The real model lives in the repo's blobs/ dir. Try re-downloading via Apply."
        else
            warn "Model file is only $(human_size "${size:-0}") — likely a partial download:"
            warn "  $path"
        fi
        return 1
    fi

    # GGUF magic: first 4 bytes must be ASCII 'GGUF' (0x47 0x47 0x55 0x46).
    # git-lfs pointer files start with "version https://..." and fail here.
    local magic
    magic=$(head -c 4 "$path" 2>/dev/null || true)
    if [[ "$magic" != "GGUF" ]]; then
        warn "File does not have a valid GGUF header (got: '${magic:-<empty>}')."
        warn "It may be a git-lfs pointer or a corrupted/partial download:"
        warn "  $path"
        return 1
    fi
    return 0
}

# ─── VRAM estimation ───────────────────────────────────────────────────

cache_type_bytes() {
    case "$1" in
        f32)                   echo "4.0" ;;
        f16 | bf16)            echo "2.0" ;;
        q8_0)                  echo "1.0" ;;
        q5_0 | q5_1)           echo "0.625" ;;
        q4_0 | q4_1 | iq4_nl)  echo "0.5" ;;
        *)                     echo "2.0" ;;
    esac
}

estimate_vram_usage() {
    local model_gb="$1" ctx_size="$2" ctk="$3" n_layers="${4:-48}"
    local bytes_per overhead kv_gb total_gb
    bytes_per=$(cache_type_bytes "$ctk")
    overhead=$(awk "BEGIN { printf \"%.1f\", 0.6 + $model_gb * 0.020 }")
    kv_gb=$(awk "BEGIN { printf \"%.1f\", ($ctx_size / 1024.0) * $n_layers * $bytes_per / 512.0 * 1.12 }")
    total_gb=$(awk "BEGIN { printf \"%.1f\", $model_gb + $kv_gb + $overhead }")
    echo "$total_gb $model_gb $kv_gb $overhead"
}

detect_model_gb() {
    local path bytes=""
    path=$(resolve_local_gguf)
    if [[ -n "$path" && -f "$path" ]]; then
        bytes=$(stat -c%s "$path" 2>/dev/null || stat -f%z "$path" 2>/dev/null || true)
    fi
    # Fallback: if the file isn't on disk yet (user just picked it from
    # the HF search), use the size we captured from the Hub API / HEAD
    # request. Lets the VRAM estimate appear BEFORE the user commits to
    # the download at Apply time.
    if [[ -z "${bytes:-}" || "${bytes:-0}" -le 0 ]]; then
        if [[ "${P_HF_FILE_BYTES:-}" =~ ^[0-9]+$ ]] && (( P_HF_FILE_BYTES > 0 )); then
            bytes="$P_HF_FILE_BYTES"
        fi
    fi
    if [[ -n "${bytes:-}" && "$bytes" -gt 0 ]]; then
        awk "BEGIN { printf \"%.1f\", $bytes / 1073741824 }"
    fi
    # Always succeed — a failing `[[ ]] && cmd` tail-expression under set -e
    # would kill the script in show_current() when the .gguf isn't cached yet.
    return 0
}

detect_hw_vram_gb() {
    local mib
    mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || true)
    if [[ "${mib:-}" =~ ^[0-9]+$ ]]; then
        awk "BEGIN { printf \"%d\", $mib / 1024 + 0.5 }"
    fi
    return 0
}

# ─── Display ───────────────────────────────────────────────────────────

# menu_item_numbers — sets item-number variables used by both show_current
# and main_menu so the two never drift out of sync.
# Call with: eval "$(menu_item_numbers)"
menu_item_numbers() {
    if [[ "${P_IS_CUDA:-n}" == "y" ]]; then
        printf 'local mlock_item=7 dio_item=8 grp_item=9 jinja_item=10 reasoning_item=11 parallel_item=12'
    else
        printf 'local mlock_item=6 dio_item=7 grp_item=8 jinja_item=9 reasoning_item=10 parallel_item=11'
    fi
}

show_current() {
    local moe_disp fa_disp mlock_disp dio_disp ngl_disp jinja_disp reasoning_disp
    [[ -n "${P_N_CPU_MOE:-}" ]] && moe_disp="${P_N_CPU_MOE} layers" || moe_disp="off"
    [[ "${P_FLASH:-}" == "on" ]] && fa_disp="on"  || fa_disp="off"
    [[ "${P_MLOCK:-n}" == "y" ]] && mlock_disp="on" || mlock_disp="off"
    [[ "${P_DIO:-n}"   == "y" ]] && dio_disp="on"   || dio_disp="off"
    [[ "${P_JINJA:-n}" == "y" ]] && jinja_disp="on" || jinja_disp="off"
    reasoning_disp="${P_REASONING:-(unset)}"
    if [[ "${P_FIT:-}" == "on" ]]; then
        ngl_disp="auto-fit  --fit-ctx ${P_FIT_CTX:-${P_CTX:-}}"
    else
        ngl_disp="${P_NGL:-99}"
    fi

    eval "$(menu_item_numbers)"

    printf '\n'
    case "$P_MODEL_MODE" in
        hf)    printf ' Model:   %s%s%s : %s\n' \
                   "$C_BOLD" "$P_HF_REPO" "$C_RESET" "${P_HF_FILE:-(repo default)}" ;;
        local) printf ' Model:   %s%s%s\n' "$C_BOLD" "$P_MODEL_PATH" "$C_RESET" ;;
        *)     printf ' %sModel:   (not detected — use raw editor)%s\n' "$C_YELLOW" "$C_RESET" ;;
    esac
    printf ' Listen:  %s:%s\n' "${P_HOST:-127.0.0.1}" "${P_PORT:-8080}"
    printf ' Service: %s\n'    "$(systemctl is-active llama-server 2>/dev/null || echo 'inactive')"
    printf '\n'

    printf '%sContext & Memory:%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
    printf ' 1. Context size:       [%s] tokens\n'              "${P_CTX:-(unset)}"
    printf ' 2. KV cache type:      [%s]  (K and V matched)\n'  "${P_CACHE_K:-f16}"
    printf ' 3. CPU MoE offload:    [%s]\n'                      "$moe_disp"
    printf ' 4. Flash attention:    [%s]\n'                      "$fa_disp"
    printf ' 5. Ubatch size:        [%s]\n'                      "${P_UBATCH:-(unset)}"
    [[ "${P_IS_CUDA:-n}" == "y" ]] && \
        printf ' 6. GPU layers:         [%s]  (-ngl / --fit)\n'  "$ngl_disp"
    printf ' %s. Mem lock (--mlock): [%s]  (prevent idle swap)\n'   "$mlock_item" "$mlock_disp"
    printf ' %s. Direct I/O (-dio):  [%s]  (prevent tensor hang)\n' "$dio_item"   "$dio_disp"
    local grp_disp="off"
    if [[ -n "${P_GRP_ATTN_N:-}" ]]; then grp_disp="n=${P_GRP_ATTN_N} w=${P_GRP_ATTN_W:-512}"; fi
    printf ' %s. Group attention:    [%s]  (--grp-attn-n / --grp-attn-w)\n' "$grp_item"       "$grp_disp"
    printf ' %s. Jinja templates:    [%s]\n'                                  "$jinja_item"     "$jinja_disp"
    printf ' %s. Reasoning mode:     [%s]  (--reasoning on/off)\n'           "$reasoning_item" "$reasoning_disp"
    printf ' %s. Parallel slots:     [%s]  (--parallel)\n'                   "$parallel_item"  "${P_PARALLEL:-(unset)}"
    printf '\n'

    local model_gb hw_vram
    model_gb=$(detect_model_gb)
    hw_vram=$(detect_hw_vram_gb)
    if [[ -n "${model_gb:-}" && -n "${P_CTX:-}" ]]; then
        local estimate total_gb kv_gb overhead_gb fit_color fits
        estimate=$(estimate_vram_usage "$model_gb" "$P_CTX" "${P_CACHE_K:-f16}")
        total_gb=$(awk '{print $1}' <<<"$estimate")
        kv_gb=$(awk    '{print $3}' <<<"$estimate")
        overhead_gb=$(awk '{print $4}' <<<"$estimate")
        fit_color=""; fits="✅"
        if [[ -n "${hw_vram:-}" ]] && \
           awk "BEGIN { exit ($total_gb > $hw_vram) ? 0 : 1 }" 2>/dev/null; then
            fits="❌ OOM risk"; fit_color="\e[1;31m"
        fi
        printf ' Model weights:    %s GB\n'  "$model_gb"
        printf ' KV cache:         %s GB\n'  "$kv_gb"
        printf ' Runtime overhead: ~%s GB\n' "$overhead_gb"
        printf ' ───────────────\n'
        if [[ -n "$fit_color" ]]; then
            # shellcheck disable=SC2059
            printf " Estimated total:  ${fit_color}%s / %s GB  %s\e[0m\n" \
                "$total_gb" "${hw_vram:--}" "$fits"
        else
            printf ' Estimated total:  %s / %s GB  %s\n' \
                "$total_gb" "${hw_vram:--}" "$fits"
        fi
        printf '\n'
    fi
}

# ─── Editors ───────────────────────────────────────────────────────────
# Each editor mutates the P_* state in memory. Apply writes to disk.

edit_context() {
    local v
    read -rp "Context size (current: ${P_CTX:-unset}) [blank = keep]: " v
    [[ -n "$v" ]] || return 0
    [[ "$v" =~ ^[0-9]+$ ]] || { warn "Not a number."; return 0; }
    P_CTX="$v"
}

edit_gpu_layers() {
    if [[ "$P_IS_CUDA" != "y" ]]; then
        warn "GPU layer offload is CUDA-only — this build has no GPU."; return 0
    fi
    local cur_disp
    if [[ "${P_FIT:-}" == "on" ]]; then
        cur_disp="auto-fit  --fit-ctx ${P_FIT_CTX:-65536}"
    else
        cur_disp="-ngl ${P_NGL:-(default: all)}"
    fi
    echo ""
    printf '%sGPU layer offload — how much of the model lives on GPU vs CPU RAM:%s\n\n' \
        "$C_BOLD" "$C_RESET"
    printf '  1. %-14s  %s\n' "Manual (-ngl N)" \
        "Load exactly N layers on GPU. 99 = all (fastest)."
    printf '               %s  %s\n' "                " \
        "Lower values spill layers to CPU RAM (slower but fits more)."
    printf '  2. %-14s  %s\n' "Auto-fit" \
        "llama.cpp detects how many layers fit in VRAM at startup."
    printf '               %s  %s\n' "                " \
        "Safe for big models; adapts if GPU VRAM changes."
    printf '  3. %-14s  %s\n' "Auto-fit + ctx" \
        "Auto-fit with an explicit VRAM budget for the KV context."
    printf '               %s  %s\n' "                " \
        "Use when -c > 65536 so --fit doesn'\''t under-estimate VRAM."
    printf '  4. %-14s  %s\n' "CPU-only (-ngl 0)" \
        "Run entirely on CPU. Very slow; useful for debugging."
    printf '  q. Cancel\n\n'
    local choice v
    read -rp "  GPU layers (current: ${cur_disp}) [1-4 or q]: " choice
    case "$choice" in
        1)
            read -rp "  -ngl (number of layers, 99 = all on GPU): " v
            [[ "$v" =~ ^[0-9]+$ ]] || { warn "Not a number."; return 0; }
            P_NGL="$v"; P_FIT="off"
            ok "GPU layers → -ngl $v"
            ;;
        2)
            P_FIT="on"; P_FIT_CTX=""; P_NGL=""
            ok "GPU layers → auto-fit (--fit on)"
            ;;
        3)
            read -rp "  --fit-ctx (context tokens for VRAM budget, e.g. 131072 for 128k ctx): " v
            [[ "$v" =~ ^[0-9]+$ ]] || { warn "Not a number."; return 0; }
            P_FIT="on"; P_FIT_CTX="$v"; P_NGL=""
            ok "GPU layers → auto-fit (--fit on --fit-ctx $v)"
            ;;
        4)
            P_NGL="0"; P_FIT="off"
            ok "GPU layers → CPU-only (-ngl 0)"
            ;;
        q|Q|"") info "Cancelled — GPU layers unchanged." ;;
        *)      warn "Unknown option." ;;
    esac
}

# Legacy entry point — kept so --ngl CLI flag still works. Calls the
# unified sub-menu rather than the old bare-number prompt.
edit_ngl() { edit_gpu_layers; }

edit_cache() {
    # K and V cache types are always locked together — mixed types
    # disable GPU offload in llama.cpp, so there's no point offering
    # them separately.
    echo ""
    echo "KV cache quantisation (K and V locked together — mixed types disable GPU offload)."
    echo ""
    echo "  1. f16  — half-precision   (highest quality, most VRAM)"
    echo "  2. bf16 — bfloat16         (near-identical quality, slightly different numerics)"
    echo "  3. q8_0 — 8-bit quant      ★ recommended for CUDA + --flash-attn"
    echo "  4. q4_0 — 4-bit quant      (lowest VRAM, slight quality trade-off)"
    echo "  q. Cancel"
    echo ""
    local opt
    read -rp "  KV cache (current: ${P_CACHE_K:-f16}) [1-4, name, or q to cancel]: " opt
    local qt
    case "$opt" in
        1|f16)   qt="f16" ;;
        2|bf16)  qt="bf16" ;;
        3|q8_0)  qt="q8_0" ;;
        4|q4_0)  qt="q4_0" ;;
        q|Q|"")  info "Cancelled — KV cache unchanged."; return 0 ;;
        *)       warn "Unknown option. Choose 1-4 or type the name (f16, bf16, q8_0, q4_0)."; return 0 ;;
    esac
    P_CACHE_K="$qt"; P_CACHE_V="$qt"
    ok "KV cache → $qt"
}

edit_flash() {
    if [[ "$P_IS_CUDA" != "y" ]]; then warn "--flash-attn is CUDA-only."; return 0; fi
    case "${P_FLASH:-off}" in
        on)  P_FLASH="off"; ok "flash-attn → off" ;;
        *)   P_FLASH="on";  ok "flash-attn → on"  ;;
    esac
}

edit_listen() {
    echo ""
    printf '%sListen address — where the llama.cpp API server binds:%s\n\n' "$C_BOLD" "$C_RESET"
    printf '  1. %-13s  %s\n' "127.0.0.1" "Localhost only (secure default — not reachable from other machines)."
    printf '  2. %-13s  %s\n' "0.0.0.0"   "All interfaces — exposes the API to your LAN/WAN."
    printf '               %s\n'           "  ⚠ Ensure a firewall is in place before choosing this."
    printf '  3. %-13s  %s\n' "Custom"    "Enter any IP address or hostname."
    printf '  q. Cancel\n\n'
    local h_choice new_host
    read -rp "  Host (current: ${P_HOST:-127.0.0.1}) [1-3 or q]: " h_choice
    case "$h_choice" in
        1)      new_host="127.0.0.1" ;;
        2)      new_host="0.0.0.0" ;;
        3)      read -rp "  IP or hostname: " new_host
                [[ -n "$new_host" ]] || { info "Cancelled — host unchanged."; return 0; } ;;
        q|Q|"") info "Cancelled — host unchanged."; return 0 ;;
        *)      warn "Unknown option."; return 0 ;;
    esac
    P_HOST="$new_host"
    ok "Host → $new_host"

    local p
    read -rp "  Port (current: ${P_PORT:-8080}) [blank = keep]: " p
    if [[ -n "$p" ]]; then
        [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 && p < 65536 )) || { warn "Invalid port."; return 0; }
        P_PORT="$p"
    fi
}

edit_mlock() {
    case "$P_MLOCK" in
        y) P_MLOCK="n"; ok "--mlock → off" ;;
        *) P_MLOCK="y"; ok "--mlock → on"  ;;
    esac
}

edit_fit() { edit_gpu_layers; }

edit_n_cpu_moe() {
    local v
    echo "MoE expert layers to run on CPU (0 = all on GPU, unset = llama.cpp default)."
    echo "Useful for large MoE models (Mixtral, DeepSeek-MoE, Qwen-MoE) when VRAM is tight."
    echo
    echo "Typical values by architecture (start low, raise if OOM):"
    echo "  non-MoE models          → leave unset"
    echo "  Mixtral 8x7B / 8x22B    → 2-4   (8 experts, 2 active)"
    echo "  Qwen2/Qwen3-MoE (A14B)  → 4-8   (60 experts, 4 active)"
    echo "  DeepSeek-MoE / V2 / V3  → 8-16  (many fine-grained experts)"
    echo "  GPT-OSS / small MoE     → 1-2"
    echo
    echo "Options: (unset) / 2 / 4 / 8 / 16 / custom"
    read -rp "  --n-cpu-moe (current: ${P_N_CPU_MOE:-(unset)}) [number, 0 to clear, blank to keep]: " v
    if [[ -z "$v" ]]; then
        return 0
    elif [[ "$v" == "0" ]]; then
        P_N_CPU_MOE=""
        ok "--n-cpu-moe cleared"
    elif [[ "$v" =~ ^[0-9]+$ ]]; then
        P_N_CPU_MOE="$v"
        ok "--n-cpu-moe → $v"
    else
        warn "Not a non-negative integer."
    fi
}

edit_ubatch() {
    echo "Ubatch controls prompt-processing batch size."
    echo "Larger = faster prompt ingestion, more VRAM spikes during prefill."
    echo "Options: 512 / 1024 (recommended) / 2048 / 4096 / custom"
    local v
    read -rp "  -ub (current: ${P_UBATCH:-(unset)}) [blank = keep, 0 = clear]: " v
    if [[ -z "$v" ]]; then return 0; fi
    if [[ "$v" == "0" ]]; then
        P_UBATCH=""; ok "-ub cleared"
    elif [[ "$v" =~ ^[0-9]+$ && "$v" -ge 32 ]]; then
        P_UBATCH="$v"; ok "-ub → $v"
    else
        warn "Must be a number ≥ 32 (or 0 to clear)."
    fi
}

edit_dio() {
    case "${P_DIO:-n}" in
        y) P_DIO="n"; ok "-dio → off" ;;
        *) P_DIO="y"; ok "-dio → on"  ;;
    esac
}

edit_grp_attn() {
    echo ""
    echo "  Group attention context extension (--grp-attn-n / --grp-attn-w)"
    echo "  Multiplies effective context by n by grouping attention spans."
    echo "  Set n=1 (or blank when unset) to disable. Typical: n=4 w=512."
    echo ""
    echo "  Current: n=${P_GRP_ATTN_N:-(unset)}  w=${P_GRP_ATTN_W:-(unset)}"
    echo ""
    local vn vw
    read -rp "  --grp-attn-n (current: ${P_GRP_ATTN_N:-(unset)}) [number, 1 to disable, blank to keep]: " vn
    if [[ -n "$vn" ]]; then
        if [[ "$vn" == "1" ]]; then
            P_GRP_ATTN_N=""; P_GRP_ATTN_W=""
            ok "grp-attn disabled"
            return 0
        elif [[ "$vn" =~ ^[2-9][0-9]*$ || "$vn" =~ ^[1-9][0-9]+$ ]]; then
            P_GRP_ATTN_N="$vn"
        else
            warn "Invalid — must be an integer ≥ 2 (or 1 to disable)."; return 0
        fi
    fi
    read -rp "  --grp-attn-w (current: ${P_GRP_ATTN_W:-512}) [number, blank to keep]: " vw
    if [[ -n "$vw" ]]; then
        if [[ "$vw" =~ ^[0-9]+$ ]]; then
            P_GRP_ATTN_W="$vw"
        else
            warn "Invalid — must be a positive integer."; return 0
        fi
    fi
    if [[ -n "${P_GRP_ATTN_N:-}" ]]; then
        ok "grp-attn → n=${P_GRP_ATTN_N} w=${P_GRP_ATTN_W:-512}"
    fi
}

edit_jinja() {
    case "${P_JINJA:-n}" in
        y) P_JINJA="n"; ok "--jinja → off" ;;
        *) P_JINJA="y"; ok "--jinja → on"  ;;
    esac
}

edit_reasoning() {
    case "${P_REASONING:-}" in
        on)  P_REASONING="off"; ok "--reasoning → off" ;;
        off) P_REASONING="";    ok "--reasoning cleared (unset)" ;;
        *)   P_REASONING="on";  ok "--reasoning → on"  ;;
    esac
}

edit_parallel() {
    echo "  --parallel N: number of parallel request slots."
    echo "  Higher values allow more concurrent requests at the cost of VRAM."
    echo ""
    local v
    read -rp "  --parallel (current: ${P_PARALLEL:-(unset)}) [number, 0 to clear, blank to keep]: " v
    if [[ -z "$v" ]]; then
        : # keep current
    elif [[ "$v" == "0" ]]; then
        P_PARALLEL=""; ok "--parallel cleared"
    elif [[ "$v" =~ ^[0-9]+$ ]]; then
        P_PARALLEL="$v"; ok "--parallel → $v"
    else
        warn "Invalid — must be a positive integer."
    fi
}

# ─── HuggingFace Hub API ───────────────────────────────────────────────
#
# Public API, no token required for ungated repos. HF_TOKEN is passed
# through when set so gated repos (meta-llama, google/gemma) also work.
#
# Network-calling wrappers and JSON parsers are separated so the parsers
# can be unit-tested with fixture JSON.

hf_api_curl() {
    # Usage: hf_api_curl <url> [<extra-curl-args...>]
    local url="$1"; shift || true
    local -a auth=()
    [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${HF_TOKEN}")
    curl -fsSL --max-time 15 "${auth[@]}" "$@" "$url"
}

hf_api_search() {
    # Query the Hub for GGUF models, ranked by downloads. 20 results max.
    local query="$1"
    local q_enc; q_enc=$(printf '%s' "$query" | jq -sRr @uri)
    hf_api_curl "https://huggingface.co/api/models?search=${q_enc}&filter=gguf&sort=downloads&direction=-1&limit=20"
}

hf_api_tree() {
    # List files at the top level of a repo (main branch).
    local repo="$1"
    hf_api_curl "https://huggingface.co/api/models/${repo}/tree/main"
}

hf_parse_search_results() {
    # Input: Hub /api/models JSON on stdin.
    # Output (stdout): one result per line as "id\tdownloads\tlikes".
    jq -r '.[] | "\(.id)\t\(.downloads // 0)\t\(.likes // 0)"'
}

hf_parse_tree_gguf() {
    # Input: /api/models/<repo>/tree/main JSON on stdin.
    # Output (stdout): one file per line as "path\tsize_bytes", .gguf only,
    # sorted by size descending (largest = highest quality usually).
    jq -r '.[] | select(.type == "file") | select(.path | endswith(".gguf")) | "\(.path)\t\(.size // 0)"' \
        | sort -t $'\t' -k2 -nr
}

human_size() {
    # Input: bytes (integer). Output: "12.3 GB" / "845 MB" / "512 KB".
    local b="$1"
    awk -v b="$b" 'BEGIN {
        if (b >= 1073741824) { printf "%.1f GB", b / 1073741824 }
        else if (b >= 1048576)    { printf "%.0f MB", b / 1048576 }
        else if (b >= 1024)       { printf "%.0f KB", b / 1024 }
        else                      { printf "%d B", b }
    }'
}

require_jq() {
    command -v jq >/dev/null 2>&1 || {
        warn "jq is required for HF search. Install it: sudo apt install -y jq"
        return 1
    }
}

# Interactive search flow. Mutates P_HF_REPO / P_HF_FILE / P_MODEL_MODE.
edit_model_search_flow() {
    require_jq || return 1

    local query
    read -rp "Search HuggingFace for: " query
    [[ -n "$query" ]] || { info "Cancelled."; return 0; }

    info "Searching huggingface.co…"
    local raw; raw=$(hf_api_search "$query" || true)
    [[ -n "$raw" ]] || { warn "No response from HF API."; return 1; }

    # Parse into parallel arrays
    local -a ids=() downloads=() likes=()
    while IFS=$'\t' read -r id dls lks; do
        [[ -n "$id" ]] || continue
        ids+=("$id"); downloads+=("$dls"); likes+=("$lks")
    done < <(printf '%s' "$raw" | hf_parse_search_results)

    if [[ "${#ids[@]}" -eq 0 ]]; then
        warn "No GGUF repos matched \"$query\". Try different terms or use the direct-input option."
        return 0
    fi

    echo ""
    local i
    for i in "${!ids[@]}"; do
        printf '  %2d) %-55s  ⬇ %s   ★ %s\n' \
            "$((i+1))" "${ids[$i]}" "${downloads[$i]}" "${likes[$i]}"
    done
    echo ""
    local pick
    read -rp "Pick a repo [1-${#ids[@]}, blank = cancel]: " pick
    [[ -n "$pick" && "$pick" =~ ^[0-9]+$ ]] || { info "Cancelled."; return 0; }
    (( pick >= 1 && pick <= ${#ids[@]} )) || { warn "Out of range."; return 0; }
    local repo="${ids[$((pick-1))]}"

    info "Listing files for ${repo}…"
    local tree_raw; tree_raw=$(hf_api_tree "$repo" || true)
    if [[ -z "$tree_raw" ]]; then
        warn "Couldn't fetch file list. Repo may be gated — set HF_TOKEN in ~/.env.secrets."
        return 1
    fi

    local -a files=() sizes=()
    while IFS=$'\t' read -r path size; do
        [[ -n "$path" ]] || continue
        files+=("$path"); sizes+=("$size")
    done < <(printf '%s' "$tree_raw" | hf_parse_tree_gguf)

    if [[ "${#files[@]}" -eq 0 ]]; then
        warn "No .gguf files in ${repo}. Pick a different repo."
        return 0
    fi

    echo ""
    for i in "${!files[@]}"; do
        printf '  %2d) %-60s  %s\n' \
            "$((i+1))" "${files[$i]}" "$(human_size "${sizes[$i]}")"
    done
    echo ""
    read -rp "Pick a file [1-${#files[@]}, blank = cancel]: " pick
    [[ -n "$pick" && "$pick" =~ ^[0-9]+$ ]] || { info "Cancelled."; return 0; }
    (( pick >= 1 && pick <= ${#files[@]} )) || { warn "Out of range."; return 0; }

    P_MODEL_MODE="hf"
    P_HF_REPO="$repo"
    P_HF_FILE="${files[$((pick-1))]}"
    # Capture the file's byte size from the tree listing so the main menu
    # can show a VRAM estimate immediately — before the user hits Apply
    # and triggers a multi-GB download. Prevents the "I just picked a 70B
    # model that will crash the GPU" scenario.
    P_HF_FILE_BYTES="${sizes[$((pick-1))]}"
    P_MODEL_PATH=""
    ok "Queued: ${P_HF_REPO}:${P_HF_FILE} ($(human_size "${P_HF_FILE_BYTES}")) — download happens at Apply time if not cached."
    warn_model_compat
}

# ---------------------------------------------------------------------------
# detect_model_arch <identifier>
# Pattern-match a repo slug, filename, or path against known model families.
# Prints a space-separated list of tags: "gqa" and/or "moe".
#   gqa → requires --flash-attn on for non-f16 KV cache types.
#   moe → benefits from --n-cpu-moe when GPU VRAM is limited.
# ---------------------------------------------------------------------------
detect_model_arch() {
    local id
    id=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')  # case-insensitive matching
    local is_gqa=0 is_moe=0

    # GQA families — grouped-query attention requires flash-attn for non-f16 KV.
    if [[ "$id" =~ qwen|llama.?3|gemma|phi.?[34] ]]; then is_gqa=1; fi

    # MoE families — sparse expert layers benefit from --n-cpu-moe offload.
    if [[ "$id" =~ mixtral|olmoe|-moe-|deepseek.*(v[23]|moe|r1)|qwen.*moe ]]; then is_moe=1; fi

    local tags=""
    if [[ $is_gqa -eq 1 ]]; then tags="gqa"; fi
    if [[ $is_moe -eq 1 ]]; then
        if [[ -n "$tags" ]]; then tags+=" moe"; else tags="moe"; fi
    fi
    printf '%s' "$tags"
}

# ---------------------------------------------------------------------------
# warn_model_compat
# Reads current P_HF_REPO / P_HF_FILE / P_MODEL_PATH and P_ settings.
# Emits actionable warnings for known incompatible combinations:
#   GQA model + flash-attn off + non-f16 KV  →  hard failure at load time.
#   MoE model + --n-cpu-moe unset            →  VRAM pressure hint.
# Call after any model change and before benchmark / apply.
# ---------------------------------------------------------------------------
warn_model_compat() {
    local id="${P_HF_REPO:-}/${P_HF_FILE:-}/${P_MODEL_PATH:-}"
    # Nothing set — nothing to check.
    if [[ -z "${P_HF_REPO:-}" && -z "${P_HF_FILE:-}" && -z "${P_MODEL_PATH:-}" ]]; then
        return 0
    fi

    local arch
    arch=$(detect_model_arch "$id")
    [[ -z "$arch" ]] && return 0

    # Friendly display name: prefer filename, then repo basename, then path basename.
    local display_name
    if [[ -n "${P_HF_FILE:-}" ]]; then
        display_name="${P_HF_FILE}"
    elif [[ -n "${P_HF_REPO:-}" ]]; then
        display_name="${P_HF_REPO##*/}"
    else
        display_name="${P_MODEL_PATH##*/}"
    fi

    # GQA: non-f16 KV cache types require flash attention or the context
    # creation fails entirely. f16 KV is fine without FA — no warning needed.
    if [[ "$arch" == *"gqa"* && "${P_FLASH:-}" != "on" && "${P_CACHE_K:-f16}" != "f16" ]]; then
        echo ""
        warn "GQA model (${display_name}) with KV type ${P_CACHE_K} requires flash attention."
        warn "Without --flash-attn on, llama-server will fail to create the context."
        warn "Select [4] in the main menu to enable flash attention."
    fi

    # MoE: --n-cpu-moe offloads expert layers to CPU when VRAM is limited.
    # This is a soft suggestion, not a hard requirement.
    if [[ "$arch" == *"moe"* && -z "${P_N_CPU_MOE:-}" ]]; then
        echo ""
        info "MoE model (${display_name}) — if VRAM is tight, set --n-cpu-moe to"
        info "offload expert layers to CPU (Mixtral 8x7B: 2, DeepSeek-V2/V3: 8, Qwen-MoE: 4)."
        info "Select [3] in the main menu to configure."
    fi
}

edit_model() {
    case "$P_MODEL_MODE" in
        hf)    echo "Current: HF ${P_HF_REPO}:${P_HF_FILE:-(default)}" ;;
        local) echo "Current: local $P_MODEL_PATH" ;;
        *)     echo "Current: (not detected)" ;;
    esac
    echo ""
    echo "  1) Search HuggingFace (keyword → ranked list → pick file)"
    echo "  2) Enter HF slug directly (org/repo[:file.gguf])"
    echo "  3) Local .gguf path"
    echo "  q) Cancel"
    local choice; read -rp "> " choice
    case "$choice" in
        1) edit_model_search_flow ;;
        2)
            local v; read -rp "HF slug (org/repo or org/repo:file.gguf): " v
            [[ -n "$v" ]] || return 0
            if [[ "$v" == *":"* ]]; then
                P_MODEL_MODE="hf"; P_HF_REPO="${v%%:*}"; P_HF_FILE="${v#*:}"; P_MODEL_PATH=""
            else
                P_MODEL_MODE="hf"; P_HF_REPO="$v"; P_HF_FILE=""; P_MODEL_PATH=""
            fi
            # Probe the file's size so the VRAM estimate appears on the
            # main menu. Non-fatal — if the HEAD fails we just show the
            # menu without the estimate (user can still hit Apply).
            P_HF_FILE_BYTES=""
            if [[ -n "$P_HF_FILE" ]]; then
                info "Querying file size…"
                P_HF_FILE_BYTES=$(hf_head_content_length "$P_HF_REPO" "$P_HF_FILE")
                if [[ -n "$P_HF_FILE_BYTES" ]]; then
                    ok "Size: $(human_size "$P_HF_FILE_BYTES")"
                else
                    warn "Couldn't probe size (check slug / HF_TOKEN for gated repos)."
                fi
            fi
            info "Queued ${P_HF_REPO}${P_HF_FILE:+:$P_HF_FILE} (download at Apply time)."
            warn_model_compat
            ;;
        3)
            local v; read -rp "Absolute path to .gguf: " v
            [[ -n "$v" ]] || return 0
            [[ "$v" == /* ]] || { warn "Must be an absolute path."; return 0; }
            [[ -r "$v" ]] || { warn "File not readable: $v"; return 0; }
            P_MODEL_MODE="local"; P_MODEL_PATH="$v"; P_HF_REPO=""; P_HF_FILE=""
            P_HF_FILE_BYTES=""
            info "Queued local model $v."
            warn_model_compat
            ;;
        q|Q|"") info "Cancelled." ;;
        *)      warn "Unknown option." ;;
    esac
}

edit_raw() {
    local tmp
    tmp=$(mktemp -t llama-args.XXXXXX)
    printf '%s\n' "$P_ARG_STRING" >"$tmp"
    ${EDITOR:-vi} "$tmp"
    local new; new=$(<"$tmp"); rm -f "$tmp"
    # Strip trailing newline
    new="${new%$'\n'}"
    validate_arg_string "$new" || return 1
    P_ARG_STRING="$new"
    warn "Raw-edit mode bypasses the structured editors — 'Apply' will use this string verbatim."
    P_RAW_OVERRIDE=1
}

# ─── HuggingFace reachability check ────────────────────────────────────
#
# Lightweight reachability pre-flight; the full download is done by
# hf_download() below when the model is not already in the local cache.

hf_check_reachable() {
    local repo="$1" file="$2"
    local url="https://huggingface.co/${repo}/resolve/main/${file}"
    local -a auth=()
    [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${HF_TOKEN}")

    local status
    status=$(curl -fsSL --max-time 15 -o /dev/null -w '%{http_code}' -I "${auth[@]}" "$url" 2>/dev/null || true)
    if [[ "$status" == "200" || "$status" == "302" ]]; then
        return 0
    fi

    warn "HF model not reachable (HTTP ${status:-no-response})."
    warn "URL: $url"
    case "$status" in
        401|403) warn "Gated repo — set HF_TOKEN in ~/.env.secrets." ;;
        404)     warn "Check the repo slug and file name." ;;
    esac
    return 1
}

# HEAD-only probe that returns the Content-Length of an HF file in bytes,
# or empty on failure. Used to show a VRAM estimate for a model the user
# just *picked* but hasn't *downloaded* yet — we need the size to compute
# "Model weights" without waiting for a 49 GB download.
#
# HF redirects /resolve/main/… to an LFS CDN URL, so we need -L to follow
# redirects, then read Content-Length from the final response header.
hf_head_content_length() {
    local repo="$1" file="$2"
    local url="https://huggingface.co/${repo}/resolve/main/${file}"
    local -a auth=()
    [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${HF_TOKEN}")

    # -sI follows -L redirects and prints every response's headers.
    # We take the LAST Content-Length we see (the real one on the CDN).
    local bytes
    bytes=$(curl -fsSLI --max-time 15 "${auth[@]}" "$url" 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {v=$2} END {gsub(/\r/,"",v); print v}' \
        || true)
    if [[ "${bytes:-}" =~ ^[0-9]+$ ]] && (( bytes > 0 )); then
        printf '%s' "$bytes"
    fi
    return 0
}

# Download a model file from HuggingFace directly into the native HF cache
# layout so both llama-server (--hf-repo) and llama-bench (via
# resolve_local_gguf) can find it without a second download.
#
# Design: we download first, THEN compute sha256 from the actual bytes.
# This is more reliable than fetching it from the API (the field location
# varies across HF API versions: .oid vs .lfs.sha256 vs .blob_id).
#
# Writes to: $LLAMA_CACHE/models--<org>--<repo>/blobs/<sha256>
# Also creates refs/main + a snapshot symlink so llama-server's own cache
# check finds the blob and skips re-downloading.
#
# Usage:   hf_download <repo> <file>
# Returns: 0 on success, 1 on failure.
hf_download() {
    local repo="$1" file="$2"
    local cache; cache=$(detect_llama_cache)
    local repo_dir="${cache}/models--${repo//\//--}"
    local blob_dir="${repo_dir}/blobs"
    local -a auth=()
    [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${HF_TOKEN}")

    # --- 1. Download to a temp file ---
    mkdir -p "$blob_dir"
    local tmp; tmp=$(mktemp "${blob_dir}/.dl.XXXXXX")
    local url="https://huggingface.co/${repo}/resolve/main/${file}"
    info "Downloading ${file} from ${repo}…"
    if ! curl -L --progress-bar --max-time 7200 "${auth[@]}" -o "$tmp" "$url"; then
        rm -f "$tmp"
        warn "Download failed."
        return 1
    fi
    info "Verifying GGUF header…"
    if ! validate_gguf "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    # --- 2. Compute sha256 from the downloaded bytes ---
    # sha256sum on a 16 GB file takes ~20s — give the user a spinner so
    # they know the script isn't hung.
    local oid
    printf '➜ Computing SHA-256'
    oid=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}' \
        || shasum -a 256 "$tmp" 2>/dev/null | awk '{print $1}' \
        || true)
    printf ' done.\n'

    local blob_path
    if [[ -n "$oid" ]]; then
        blob_path="${blob_dir}/${oid}"
        mv "$tmp" "$blob_path"
    else
        # sha256 unavailable — fall back to flat cache (llama-server will
        # re-download when started with --hf-repo, but llama-bench works).
        blob_path="${cache}/${repo//\//_}--${file}"
        mv "$tmp" "$blob_path"
        warn "sha256sum not available; saved to ${blob_path}."
        warn "llama-server may re-download the model on next start."
        local _svc; _svc=$(detect_user_from_unit)
        if [[ "$_svc" != "root" ]]; then chown "${_svc}:" "$blob_path"; fi
        ok "Downloaded → ${blob_path}"
        return 0
    fi
    ok "Downloaded → ${blob_path}"

    # --- 3. Fetch commit hash (lightweight — just .sha, no siblings) ---
    info "Fetching repo commit hash…"
    local commit
    if command -v jq >/dev/null 2>&1; then
        commit=$(curl -fsSL --max-time 10 "${auth[@]}" \
            "https://huggingface.co/api/models/${repo}" 2>/dev/null \
            | jq -r '.sha // empty' 2>/dev/null | tr -d '[:space:]' || true)
    fi
    [[ -z "${commit:-}" ]] && commit="$oid"

    # --- 4. Create HF native cache skeleton so llama-server finds the blob ---
    local snap_dir="${repo_dir}/snapshots/${commit}"
    mkdir -p "$snap_dir" "${repo_dir}/refs"
    # Symlink matches what llama.cpp itself creates:
    #   snapshots/<commit>/<file>  →  ../../blobs/<sha256>
    [[ -e "${snap_dir}/${file}" ]] || ln -sf "../../blobs/${oid}" "${snap_dir}/${file}"
    [[ -f "${repo_dir}/refs/main" ]] || printf '%s' "$commit" >"${repo_dir}/refs/main"

    # --- 5. Fix ownership ---
    # llama-reconfigure runs as root; mktemp creates files with mode 0600;
    # mv preserves that mode.  The service user gets Permission denied unless
    # we hand the whole repo dir back to them.
    local svc_user
    svc_user=$(detect_user_from_unit)
    if [[ "$svc_user" != "root" ]]; then
        info "Setting cache ownership to ${svc_user}…"
        chown -R "${svc_user}:" "$repo_dir"
    fi

    return 0
}

# ─── Benchmark & optimize ──────────────────────────────────────────────
#
# Sweep ubatch × kv-cache-type × flash-attn with `llama-bench`, score each
# combination by the wall-clock time it would take to handle a workload
# preset (p prompt tokens + n generation tokens), then let the user apply
# the winner. The scoring formula
#
#     total_time = p / pp_toks_s + n / tg_toks_s
#
# naturally favours different settings for different shapes of work: a
# short-prompt / short-reply workload like OpenClaw's router prioritises
# tg throughput, while a 32k-prompt summarisation workload is dominated
# by pp throughput.
#
# K and V cache are locked to the same type (mixed types disable GPU
# offload in llama.cpp), so we run one llama-bench invocation per cache
# type and merge the results.

BENCH_DIR="/var/lib/llama-reconfigure"

# preset name | p tokens | n tokens | description
bench_preset_spec() {
    case "$1" in
        openclaw)  echo "64 256 OpenClaw routing (short system prompt, short reply)" ;;
        chat)      echo "512 1024 Interactive chat (moderate prompt + reply)" ;;
        coding)    echo "8192 2048 Coding assistant (large context, medium output)" ;;
        summarize) echo "32768 512 Long-document summarisation (huge prompt, short output)" ;;
        *)         return 1 ;;
    esac
}

# Print each Environment= line from the unit file as bare KEY=VALUE pairs
# (for `env KEY=VAL …` prefixing).
extract_unit_env() {
    grep -E '^Environment=' "$UNIT_FILE" 2>/dev/null \
        | sed -E 's/^Environment=//; s/^"(.*)"$/\1/'
}

# Runs llama-bench for one cache type, writing JSON to $1. Returns 0 on
# success, non-zero on failure. Silently tolerates failures so the outer
# sweep can continue.
bench_run_one() {
    local out="$1" model="$2" p="$3" n="$4" ub_list="$5" ctk="$6" fa_list="$7" ngl="$8"
    local reps="${9:-${BENCH_REPS:-2}}"

    local -a env_pairs=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && env_pairs+=("$line")
    done < <(extract_unit_env)

    # stdout → JSON file (parsed by scorer); stderr → terminal so the
    # user sees llama-bench's native progress (model load, per-cell
    # timings, flash-attn/cache banners) instead of a silent GPU pegged
    # in nvtop. llama-bench writes a new table row to stderr for every
    # (ub × fa) combination as it completes.
    env "${env_pairs[@]}" \
        llama-bench -m "$model" -p "$p" -n "$n" \
            -ub "$ub_list" -ctk "$ctk" -ctv "$ctk" -fa "$fa_list" \
            -ngl "$ngl" -r "$reps" -o json >"$out"
}

# Rough runtime estimate for the sweep, in whole minutes. Used only to warn
# the user upfront so they don't wonder whether the script has hung.
# Assumes pp ≈ 250 t/s and tg ≈ 25 t/s on a mid-range GPU; with --fit
# offloading to CPU the real time can be 2-5× this. We err on the low side.
bench_estimate_minutes() {
    local p="$1" n="$2" cells="$3" reps="$4"
    awk "BEGIN {
        per_run = ($p/250.0) + ($n/25.0);
        total_s = $cells * $reps * per_run;
        mins = total_s / 60.0;
        if (mins < 1) mins = 1;
        printf \"%d\", mins + 0.5
    }"
}

# ─── Benchmark cleanup on interrupt ────────────────────────────────────
#
# Ctrl+C during a 20-minute sweep should kill llama-bench AND restart the
# llama-server we paused, not dump the user at the shell with a stopped
# service. These globals let the trap find what to clean up.

BENCH_STOPPED_SERVICE=0

_bench_cleanup_on_interrupt() {
    trap - INT TERM
    printf '\n' >&2
    warn "Interrupted — killing llama-bench and restoring llama-server…"
    pkill -TERM -f '(^|/)llama-bench( |$)' 2>/dev/null || true
    sleep 1
    pkill -KILL -f '(^|/)llama-bench( |$)' 2>/dev/null || true
    if [[ "${BENCH_STOPPED_SERVICE:-0}" -eq 1 ]]; then
        info "Starting llama-server with its previous config…"
        systemctl start llama-server 2>/dev/null || true
        BENCH_STOPPED_SERVICE=0
    fi
    exit 130
}

# Ranks bench rows. Input JSON on stdin (array from llama-bench), plus p/n.
# Output: one row per config, sorted ascending by total_time.
#   total_s  ub=…  ctk=…  fa=0/1  pp=…t/s  tg=…t/s
bench_score_json() {
    local p="$1" n="$2"
    jq -r --argjson p "$p" --argjson n "$n" '
        [.[] | {ub: .n_ubatch, ctk: .type_k, ctv: .type_v, fa: .flash_attn,
                is_pp: (.n_prompt > 0), ts: .avg_ts}]
        | group_by([.ub, .ctk, .ctv, .fa])
        | map({
            ub: .[0].ub, ctk: .[0].ctk, ctv: .[0].ctv, fa: .[0].fa,
            pp: (map(select(.is_pp))     | map(.ts) | .[0] // null),
            tg: (map(select(.is_pp|not)) | map(.ts) | .[0] // null)
          })
        | map(select(.pp != null and .tg != null))
        | map(. + {total_s: (($p / .pp) + ($n / .tg))})
        | sort_by(.total_s)
        | .[] | "\(.total_s)\t\(.ub)\t\(.ctk)\t\(.fa)\t\(.pp)\t\(.tg)"
    '
}

# Prints a human-readable ranked table from the scored TSV on stdin.
# Accepts the current winner (first row) and returns the winning config
# via the global BENCH_WINNER_* vars.
bench_display_table() {
    local first=1 total ub ctk fa pp tg
    BENCH_WINNER_UB=""; BENCH_WINNER_CTK=""; BENCH_WINNER_FA=""
    printf '\n  %-6s  %-8s  %-6s  %-4s  %-12s  %-12s\n' \
        "total" "ubatch" "kv" "fa" "prompt (t/s)" "gen (t/s)"
    printf '  %s\n' "─────────────────────────────────────────────────────────────"
    while IFS=$'\t' read -r total ub ctk fa pp tg; do
        [[ -z "$total" ]] && continue
        local mark=" "
        if [[ $first -eq 1 ]]; then
            mark="★"
            BENCH_WINNER_UB="$ub"
            BENCH_WINNER_CTK="$ctk"
            BENCH_WINNER_FA="$fa"
            first=0
        fi
        printf '  %s %-5.2fs  %-8s  %-6s  %-4s  %-12.1f  %-12.1f\n' \
            "$mark" "$total" "$ub" "$ctk" "$fa" "$pp" "$tg"
    done
    printf '\n'
}

# Runs one llama-bench cell with a background heartbeat ticker, a visible
# start/finish timestamp, and a 1-line result summary. Returns 0 on success
# and echoes nothing (the partial JSON path is passed in as $1). Used by
# both passes of run_benchmark_preset so the UX is identical.
bench_run_cell() {
    local tmp="$1" model="$2" p="$3" n="$4" ub_list="$5" ctk="$6"
    local fa_list="$7" ngl="$8" reps="$9" idx="${10}" total="${11}"
    local cell_start cell_end elapsed _hb_pid=0 rc

    info "  → [${idx}/${total}] sweeping ctk=ctv=$ctk (r=$reps)  started $(date '+%H:%M:%S')"
    printf '     %s\n' "──────────────────────────────────────────" >&2
    cell_start=$SECONDS

    # Background heartbeat: prints "  ⏱ Xs…" on a single updating line
    # so the terminal shows something is alive during model load / long
    # pp runs. Killed as soon as llama-bench exits.
    {
        local t=0
        while :; do
            sleep 5
            t=$((t + 5))
            printf '  \e[90m⏱ %dm%02ds elapsed (llama-bench running…)\e[0m\r' \
                $((t/60)) $((t%60)) >&2
        done
    } &
    _hb_pid=$!

    rc=0
    bench_run_one "$tmp" "$model" "$p" "$n" "$ub_list" "$ctk" "$fa_list" "$ngl" "$reps" || rc=$?

    kill "$_hb_pid" 2>/dev/null || true
    wait "$_hb_pid" 2>/dev/null || true
    printf '                                                         \r' >&2
    cell_end=$SECONDS
    elapsed=$((cell_end - cell_start))
    printf '     %s\n' "──────────────────────────────────────────" >&2
    if [[ $rc -eq 0 ]]; then
        ok "  [${idx}/${total}] ctk=$ctk done in $((elapsed/60))m$((elapsed%60))s"
        return 0
    else
        warn "  [${idx}/${total}] llama-bench failed for ctk=$ctk after $((elapsed/60))m$((elapsed%60))s — skipping."
        rm -f "$tmp"
        return 1
    fi
}

# Full sweep for one preset. Writes merged JSON to $BENCH_DIR, prints
# ranked table, sets BENCH_WINNER_* globals for apply.
#
# Three optimizations vs. a naïve "run everything at r=2" sweep:
#
#   1. Adaptive two-pass: pass-1 runs every candidate ctk at r=1 (fast
#      triage), then pass-2 re-runs just the winning ctk at r=3 for
#      a confident number. Cuts ~40% vs running everything at r=2.
#
#   2. VRAM pre-filter: before starting, estimate VRAM use for each
#      ctk (model + kv cache + overhead) and drop candidates that
#      wouldn't fit in detected hw_vram. A q4_0 cache type might fit
#      where f16 won't; skip the f16 run instead of OOMing 10 min in.
#
#   3. Workload-aware ubatch default: for p≤512 (openclaw, chat) ub
#      doesn't move the needle, so fix it at 512 (llama.cpp default).
#      For p>512 (coding, summarize) sweep 1024,2048. Halves cell count
#      for short-prompt presets.
run_benchmark_preset() {
    local preset="$1"
    local spec p n label
    spec=$(bench_preset_spec "$preset") || { warn "Unknown preset: $preset"; return 1; }
    p=$(awk '{print $1}' <<<"$spec")
    n=$(awk '{print $2}' <<<"$spec")
    label=$(cut -d' ' -f3- <<<"$spec")

    command -v llama-bench >/dev/null 2>&1 || {
        warn "llama-bench not found in PATH. Install it with ubuntu-prep-setup.sh (llama.cpp component)."
        return 1
    }
    command -v jq >/dev/null 2>&1 || { warn "jq required for benchmark scoring."; return 1; }

    local model
    model=$(resolve_local_gguf)
    if [[ -z "$model" ]] || ! validate_gguf "$model" 2>/dev/null; then
        if [[ "${P_MODEL_MODE:-}" == "hf" && -n "${P_HF_REPO:-}" && -n "${P_HF_FILE:-}" ]]; then
            local _hint=""
            [[ "${P_HF_FILE_BYTES:-}" =~ ^[0-9]+$ ]] && (( P_HF_FILE_BYTES > 0 )) && \
                _hint=" ($(human_size "$P_HF_FILE_BYTES"))"
            echo ""
            local _dl
            read -rp "  Model not yet cached${_hint}. Download now to run benchmark? [y/N]: " _dl
            if [[ "$_dl" != [yY] ]]; then
                info "Benchmark cancelled — model must be on disk."
                return 1
            fi
            hf_download "$P_HF_REPO" "$P_HF_FILE" || return 1
            model=$(resolve_local_gguf)
            if [[ -z "$model" ]] || ! validate_gguf "$model"; then
                warn "Cannot locate valid model file after download."
                return 1
            fi
        else
            warn "Cannot locate the .gguf file on disk."
            [[ -n "$model" ]] && warn "Invalid model file: $model"
            return 1
        fi
    fi

    warn_model_compat

    # Workload-aware ubatch default (optimization #3): ub sweep only
    # matters when pp is the bottleneck, i.e. long-prompt workloads.
    local default_ub
    if (( p <= 512 )); then
        default_ub="512"
    else
        default_ub="1024,2048"
    fi
    local ub_list="${BENCH_UBATCH:-$default_ub}"
    local fa_list ngl
    if [[ "${P_IS_CUDA:-n}" == "y" ]]; then
        # GQA models (Qwen, Llama 3, etc.) require flash-attn for non-f16 KV types.
        # If the service already runs with FA on, only bench FA=1 — FA=0 would
        # fail to create the context for every non-f16 row and waste ~60 s each.
        if [[ "${P_FLASH:-}" == "on" ]]; then
            fa_list="1"
        else
            fa_list="0,1"
        fi
        ngl="${P_NGL:-99}"
    else
        fa_list="0"
        ngl="0"
    fi

    # Default ctk sweep: always include the currently-configured cache
    # type (P_CACHE_K) plus one comparison point one quality tier above.
    # This ensures the sweep is never vacuously empty because the user's
    # current type wasn't in the hardcoded list. The VRAM filter below
    # removes anything that doesn't actually fit.
    local current_ctk="${P_CACHE_K:-f16}"
    local ctk_list="${BENCH_CTK:-}"
    if [[ -z "$ctk_list" ]]; then
        case "$current_ctk" in
            q4_0|q4_1|iq4_nl)  ctk_list="${current_ctk},q8_0" ;;
            q5_0|q5_1)         ctk_list="${current_ctk},q8_0" ;;
            q8_0)              ctk_list="${current_ctk},f16" ;;
            f16|bf16)          ctk_list="${current_ctk},q8_0" ;;
            *)                 ctk_list="${current_ctk},q8_0" ;;
        esac
    fi

    # VRAM pre-filter (optimization #2): estimate whether each ctk would
    # fit in GPU VRAM before committing a 10-minute run to it.
    #
    # IMPORTANT: use (p + n) as the context size, NOT P_CTX (the service's
    # running context). llama-bench allocates a KV cache of only p+n tokens
    # for its benchmark runs — it doesn't re-use or match the service's full
    # context window. Using P_CTX here (e.g. 131072) would produce a wildly
    # inflated KV estimate and incorrectly filter out types that fit fine.
    local model_gb hw_vram ctx_bench
    model_gb=$(detect_model_gb)
    hw_vram=$(detect_hw_vram_gb)
    ctx_bench=$(( p + n ))

    IFS=',' read -ra _ctk_arr <<<"$ctk_list"
    local -a candidates=()
    local ctk
    for ctk in "${_ctk_arr[@]}"; do
        if [[ -n "${model_gb:-}" && -n "${hw_vram:-}" ]]; then
            local est_total
            est_total=$(estimate_vram_usage "$model_gb" "$ctx_bench" "$ctk" | awk '{print $1}')
            if awk "BEGIN { exit ($est_total > $hw_vram) ? 0 : 1 }" 2>/dev/null; then
                warn "  ⊘ ctk=$ctk skipped (estimated ${est_total} GB > ${hw_vram} GB VRAM at bench ctx=${ctx_bench})"
                continue
            fi
        fi
        candidates+=("$ctk")
    done
    if [[ "${#candidates[@]}" -eq 0 ]]; then
        warn "All candidate cache types exceed available VRAM even at bench context ${ctx_bench} tokens."
        warn "This is unusual — check that llama-bench and the GPU driver are healthy."
        warn "Override candidates with: export BENCH_CTK=q4_0"
        return 1
    fi

    # Time estimate: pass-1 is $n_pass1 ctks at r=1; pass-2 is 1 ctk at
    # r=3. bench_estimate_minutes takes (cells, reps), so pass the total
    # rep-equivalents.
    local n_pass1 rep_equivs est_min
    n_pass1=${#candidates[@]}
    rep_equivs=$((n_pass1 + 3))
    est_min=$(bench_estimate_minutes "$p" "$n" "$rep_equivs" 1)

    info "Benchmark preset: ${C_BOLD}${preset}${C_RESET} — ${label}"
    info "Sweep: ubatch=[$ub_list] ctk=ctv=[$(IFS=,; echo "${candidates[*]}")] fa=[$fa_list] ngl=$ngl"
    info "Strategy: pass-1 triage (r=1, ${n_pass1} ctks) → rank → pass-2 winner (r=3)"
    info "Estimated runtime: ~${est_min} min (2-5× longer with --fit on)"
    if [[ -n "${model_gb:-}" ]]; then
        info "Model: $model (${model_gb} GB)${hw_vram:+  GPU: ${hw_vram} GB VRAM}"
        info "VRAM filter used bench KV ctx=${ctx_bench} tokens (p+n), not service ctx ${P_CTX:-(unset)}"
    else
        info "Model: $model"
    fi
    info "Press Ctrl+C at any time to abort — llama-server will be restored."
    echo
    read -rp "Start sweep? [y/N]: " yn
    [[ "$yn" == [yY] ]] || { info "Cancelled."; return 0; }

    BENCH_STOPPED_SERVICE=0
    if systemctl is-active --quiet llama-server; then
        warn "llama-server is running and holds the GPU. Stopping it for the sweep."
        systemctl stop llama-server
        BENCH_STOPPED_SERVICE=1
    fi
    trap _bench_cleanup_on_interrupt INT TERM

    mkdir -p "$BENCH_DIR"
    local ts; ts=$(date +%s)
    local out="$BENCH_DIR/bench-${preset}-${ts}.json"

    # ── Pass 1: triage every candidate at r=1 ─────────────────────────
    printf '\n%s── Pass 1 — triage (r=1) ──%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
    local -a pass1_partials=()
    local tmp rc=0 cell_idx=0 cell_total="${#candidates[@]}"
    for ctk in "${candidates[@]}"; do
        cell_idx=$((cell_idx + 1))
        tmp=$(mktemp -t llama-bench-p1.XXXXXX.json)
        if bench_run_cell "$tmp" "$model" "$p" "$n" "$ub_list" "$ctk" \
                          "$fa_list" "$ngl" 1 "$cell_idx" "$cell_total"; then
            pass1_partials+=("$tmp")
        else
            rc=1
        fi
    done

    if [[ "${#pass1_partials[@]}" -eq 0 ]]; then
        trap - INT TERM
        warn "All pass-1 runs failed. Check 'llama-bench -h' and your GPU/driver."
        [[ $BENCH_STOPPED_SERVICE -eq 1 ]] && { systemctl start llama-server || true; BENCH_STOPPED_SERVICE=0; }
        return 1
    fi

    local pass1_merged; pass1_merged=$(mktemp -t llama-bench-p1-merged.XXXXXX.json)
    jq -s 'add' "${pass1_partials[@]}" >"$pass1_merged"

    local pass1_scored; pass1_scored=$(bench_score_json "$p" "$n" <"$pass1_merged")
    if [[ -z "$pass1_scored" ]]; then
        trap - INT TERM
        warn "No scorable rows from pass 1."
        rm -f "${pass1_partials[@]}" "$pass1_merged"
        [[ $BENCH_STOPPED_SERVICE -eq 1 ]] && { systemctl start llama-server || true; BENCH_STOPPED_SERVICE=0; }
        return 1
    fi

    printf '%sPass 1 ranked (triage, r=1 — rough, winner gets confirmed next):%s\n' \
        "$C_BOLD$C_CYAN" "$C_RESET"
    bench_display_table <<<"$pass1_scored"
    local top_ctk="$BENCH_WINNER_CTK"

    # ── Pass 2: re-run only the winning ctk at r=3 ────────────────────
    printf '\n%s── Pass 2 — winner confirmation (r=3, ctk=%s) ──%s\n' \
        "$C_BOLD$C_CYAN" "$top_ctk" "$C_RESET"
    local pass2_tmp; pass2_tmp=$(mktemp -t llama-bench-p2.XXXXXX.json)
    local pass2_ok=1
    if ! bench_run_cell "$pass2_tmp" "$model" "$p" "$n" "$ub_list" "$top_ctk" \
                        "$fa_list" "$ngl" 3 1 1; then
        pass2_ok=0
        rc=1
    fi

    # Sweep finished (or all cells failed) — drop the interrupt trap; from
    # here on Ctrl+C is just a normal prompt escape.
    trap - INT TERM

    # Merge into the final archived JSON. For the winner ctk, pass-2
    # rows replace pass-1 rows entirely (the scorer uses .[0] within a
    # group, so mixing r=1 and r=3 runs would sometimes surface the
    # less-accurate number). Losing ctks keep their pass-1 rows so the
    # user can see the full ranking context.
    if [[ $pass2_ok -eq 1 ]]; then
        jq -s --arg top "$top_ctk" '
            (.[0] | map(select(.type_k != $top)))
            + (.[1])
        ' "$pass1_merged" "$pass2_tmp" >"$out"
        rm -f "$pass2_tmp"
    else
        cp "$pass1_merged" "$out"
    fi
    rm -f "${pass1_partials[@]}" "$pass1_merged"
    ok "Raw results saved to $out"

    local scored; scored=$(bench_score_json "$p" "$n" <"$out")
    if [[ -z "$scored" ]]; then
        warn "No scorable rows after merging passes."
        [[ $BENCH_STOPPED_SERVICE -eq 1 ]] && { systemctl start llama-server || true; BENCH_STOPPED_SERVICE=0; }
        return 1
    fi

    if [[ $pass2_ok -eq 1 ]]; then
        printf '%sFinal ranking (★ = fastest; winner ctk measured at r=3):%s\n' \
            "$C_BOLD$C_CYAN" "$C_RESET"
    else
        printf '%sFinal ranking (pass-2 failed — showing pass-1 triage only):%s\n' \
            "$C_BOLD$C_CYAN" "$C_RESET"
    fi
    bench_display_table <<<"$scored"

    if [[ $BENCH_STOPPED_SERVICE -eq 1 ]]; then
        info "Restarting llama-server with its previous config…"
        systemctl start llama-server || warn "Restart failed — use --rollback if needed."
        BENCH_STOPPED_SERVICE=0
    fi

    [[ $rc -eq 0 ]] || warn "Some cells failed — winner may be skewed."

    if [[ -n "$BENCH_WINNER_UB" ]]; then
        echo
        printf 'Winner: ub=%s  ctk=ctv=%s  fa=%s\n' \
            "$BENCH_WINNER_UB" "$BENCH_WINNER_CTK" "$BENCH_WINNER_FA"
        read -rp "Apply this configuration to the service? [y/N]: " yn
        if [[ "$yn" == [yY] ]]; then
            P_UBATCH="$BENCH_WINNER_UB"
            P_CACHE_K="$BENCH_WINNER_CTK"
            P_CACHE_V="$BENCH_WINNER_CTK"
            if [[ "$BENCH_WINNER_FA" == "1" ]]; then P_FLASH="on"; else P_FLASH="off"; fi
            apply_changes
        else
            info "Winner not applied. Re-run 'llama-reconfigure' later to revisit."
        fi
    fi
}

bench_history() {
    [[ -d "$BENCH_DIR" ]] || { info "No benchmarks run yet."; return 0; }
    local -a files=()
    while IFS= read -r f; do files+=("$f"); done < <(ls -1t "$BENCH_DIR"/bench-*.json 2>/dev/null | head -10)
    if [[ "${#files[@]}" -eq 0 ]]; then
        info "No benchmark history in $BENCH_DIR."
        return 0
    fi
    echo
    printf '%sRecent benchmarks (newest first):%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
    local f base preset ts date
    for f in "${files[@]}"; do
        base=$(basename "$f" .json)
        preset=$(cut -d- -f2 <<<"$base")
        ts=$(cut -d- -f3 <<<"$base")
        date=$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$ts")
        printf '  [%s] %-10s  %s\n' "$date" "$preset" "$f"
    done
    echo
}

bench_menu() {
    while true; do
        clear
        printf '%s── Benchmark & optimize ────────────────────────────────────%s\n\n' \
            "$C_BOLD$C_CYAN" "$C_RESET"
        printf '  Presets (pick one to sweep, or [h] for history):\n\n'
        local name key spec p n label
        for name in openclaw chat coding summarize; do
            case "$name" in
                openclaw)  key="o" ;;
                chat)      key="c" ;;
                coding)    key="d" ;;
                summarize) key="s" ;;
            esac
            spec=$(bench_preset_spec "$name")
            p=$(awk '{print $1}' <<<"$spec")
            n=$(awk '{print $2}' <<<"$spec")
            label=$(cut -d' ' -f3- <<<"$spec")
            printf '   [%s]  p=%-5s n=%-5s  %s\n' "$key" "$p" "$n" "$label"
        done
        printf '\n   [h] History   [q] Back to main menu\n\n'
        local c; read -rp '> ' c
        case "$c" in
            o|O) run_benchmark_preset openclaw  || true; read -rp 'Press enter to continue…' _ ;;
            c|C) run_benchmark_preset chat      || true; read -rp 'Press enter to continue…' _ ;;
            d|D) run_benchmark_preset coding    || true; read -rp 'Press enter to continue…' _ ;;
            s|S) run_benchmark_preset summarize || true; read -rp 'Press enter to continue…' _ ;;
            h|H) bench_history ; read -rp 'Press enter to continue…' _ ;;
            q|Q|"") return 0 ;;
            *) warn "Unknown option." ;;
        esac
    done
}

# ─── Apply / rollback ──────────────────────────────────────────────────

apply_changes() {
    local dry="${1:-}"

    # For HF mode: only verify reachability. llama-server handles the
    # actual download into its native $LLAMA_CACHE layout on first start
    # — downloading ourselves to a different path wastes disk because
    # llama-server won't recognise it.
    if [[ "$dry" != "dry" && "$P_MODEL_MODE" == "hf" && -n "$P_HF_FILE" ]]; then
        if ! hf_check_reachable "$P_HF_REPO" "$P_HF_FILE"; then
            warn "Aborting apply — model not reachable."
            return 1
        fi
        ok "Model reachable on HuggingFace."

        local _cached; _cached=$(resolve_local_gguf)
        if [[ -z "$_cached" ]] || ! validate_gguf "$_cached" 2>/dev/null; then
            local _hint=""
            [[ "${P_HF_FILE_BYTES:-}" =~ ^[0-9]+$ ]] && (( P_HF_FILE_BYTES > 0 )) && \
                _hint=" ($(human_size "$P_HF_FILE_BYTES"))"
            echo ""
            local _dl
            read -rp "  Model not yet cached${_hint}. Download now so the service starts immediately? [y/N]: " _dl
            if [[ "$_dl" == [yY] ]]; then
                hf_download "$P_HF_REPO" "$P_HF_FILE" || return 1
            else
                info "Skipped — llama-server will download on first start."
                info "Watch: journalctl -u llama-server -f"
            fi
        else
            ok "Model already cached: ${_cached}"
        fi
    fi

    local new_args
    if [[ -n "${P_RAW_OVERRIDE:-}" ]]; then
        new_args="$P_ARG_STRING"
    else
        new_args=$(serialize_arg_string)
    fi
    validate_arg_string "$new_args" || return 1

    local new_exec="${P_EXEC_PREFIX}${new_args}${P_EXEC_SUFFIX}"
    # systemd-analyze verify requires a .service suffix to identify the unit type.
    local new_unit; new_unit=$(mktemp --suffix=.service)
    # Swap the ExecStart= line, keep everything else as-is
    awk -v newline="$new_exec" '
        /^ExecStart=/ { print newline; next }
        { print }
    ' "$UNIT_FILE" >"$new_unit"

    printf '\n%s── Proposed ExecStart ──%s\n  %s\n\n' "$C_BOLD$C_CYAN" "$C_RESET" "$new_exec"

    if [[ "$dry" == "dry" ]]; then
        info "(dry run — no changes written)"
        rm -f "$new_unit"
        return 0
    fi

    read -rp "Apply and restart? [y/N]: " ans
    if [[ "$ans" != [yY] ]]; then
        rm -f "$new_unit"
        info "Cancelled — nothing written."
        return 0
    fi

    info "Validating unit with systemd-analyze…"
    systemd-analyze verify "$new_unit" 2>/dev/null || true

    info "Stopping llama-server…"
    systemctl stop llama-server 2>/dev/null || true

    info "Backing up current unit → ${BAK_FILE}"
    cp -a "$UNIT_FILE" "$BAK_FILE"

    info "Installing new unit…"
    install -m 644 "$new_unit" "$UNIT_FILE"
    rm -f "$new_unit"

    info "Reloading daemon and restarting…"
    systemctl daemon-reload
    # Snapshot restart counter BEFORE we poke the service — if it climbs
    # during our watch window, we're in a crash loop even though is-active
    # may flicker "active" between exits.
    local baseline_restarts
    baseline_restarts=$(systemctl show -p NRestarts --value llama-server 2>/dev/null || echo 0)
    [[ "$baseline_restarts" =~ ^[0-9]+$ ]] || baseline_restarts=0

    if ! systemctl restart llama-server; then
        warn "Restart failed — inspect with: journalctl -u llama-server -n 100"
        warn "Rollback available: llama-reconfigure --rollback"
        return 1
    fi

    # Model load can take 10-15s for big GGUFs. Wait, then check both
    # is-active AND that the restart counter hasn't climbed (systemd's
    # Restart=always mask transient crashes from a single is-active probe).
    info "Watching service for 15s to confirm it stays up…"
    sleep 15

    local active restarts_now
    active=$(systemctl is-active llama-server 2>/dev/null || true)
    restarts_now=$(systemctl show -p NRestarts --value llama-server 2>/dev/null || echo 0)
    [[ "$restarts_now" =~ ^[0-9]+$ ]] || restarts_now=0

    if [[ "$active" != "active" ]] || (( restarts_now > baseline_restarts )); then
        warn "Service is unstable (active=$active, $((restarts_now - baseline_restarts)) crash-restarts in 15s)."
        warn "Last 40 journal lines:"
        journalctl -u llama-server -n 40 --no-pager >&2 || true
        local logp
        logp="/home/$(detect_user_from_unit)/.cache/llama-server.log"
        if [[ -f "$logp" ]]; then
            warn "Tail of $logp:"
            tail -n 30 "$logp" >&2 || true
        fi
        warn "Rollback available: llama-reconfigure --rollback"
        return 1
    fi

    ok "llama-server is stable (no crash-restarts in 15s after apply)."
    ok "Applied. Run 'journalctl -u llama-server -f' to watch startup."
}

# ---------------------------------------------------------------------------
# detect_llama_src_dir
# Find the llama.cpp git repository that produced the installed binary.
# Checks the service user's home dir and common fallback locations.
# Prints the source directory path on success; returns 1 if not found.
# ---------------------------------------------------------------------------
detect_llama_src_dir() {
    local svc_user
    svc_user=$(detect_user_from_unit)

    local -a candidates=(
        "/home/${svc_user}/llama.cpp"
        "/opt/llama.cpp"
        "/usr/local/src/llama.cpp"
        "/root/llama.cpp"
    )

    local dir
    for dir in "${candidates[@]}"; do
        if [[ -d "${dir}/.git" && -f "${dir}/CMakeLists.txt" ]]; then
            printf '%s' "$dir"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# update_llama_cpp
# Pull latest from the upstream git remote, rebuild with CMake (incremental —
# only changed translation units are recompiled), install, and restart the
# service.  On a typical update touching a handful of files, the build takes
# 1–5 minutes; updates to core files (ggml, llama.cpp) can take 15+ minutes.
# ---------------------------------------------------------------------------
update_llama_cpp() {
    local src_dir svc_user
    svc_user=$(detect_user_from_unit)

    if ! src_dir=$(detect_llama_src_dir); then
        warn "Cannot find llama.cpp git repository."
        warn "Expected at ~/llama.cpp, /opt/llama.cpp, or /usr/local/src/llama.cpp."
        return 1
    fi

    local build_dir="${src_dir}/build"
    if [[ ! -f "${build_dir}/CMakeCache.txt" ]]; then
        warn "No CMake build cache at ${build_dir} — cannot determine build config."
        return 1
    fi

    # git 2.35.2+ refuses to operate on repos owned by a different user.
    # The script runs as root; the repo is owned by the service user — so
    # all git commands must run as that user via sudo -u.
    local _git="sudo -u ${svc_user} git -C ${src_dir}"

    # --- Current state ---
    local old_ver
    old_ver=$(${_git} describe --tags --always 2>/dev/null \
              || ${_git} rev-parse --short HEAD 2>/dev/null \
              || echo "unknown")

    printf '\n%s── llama.cpp update ──%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
    printf '  Source : %s\n' "$src_dir"
    printf '  Version: %s\n\n' "$old_ver"

    # --- Fetch and check ---
    info "Checking upstream…"
    if ! ${_git} fetch --quiet 2>/dev/null; then
        warn "git fetch failed — check network connectivity."
        return 1
    fi

    local behind
    behind=$(${_git} rev-list "HEAD..@{u}" --count 2>/dev/null || echo "?")

    if [[ "$behind" == "0" ]]; then
        ok "Already up to date (${old_ver})."
        return 0
    fi

    local new_ver
    new_ver=$(${_git} describe --tags --always "@{u}" 2>/dev/null \
              || ${_git} rev-parse --short "@{u}" 2>/dev/null \
              || echo "newer")

    printf '  Available: %s  (%s new commits)\n\n' "$new_ver" "$behind"
    warn "This stops llama-server, rebuilds (several minutes), then restarts."
    echo ""
    read -rp "  Pull and rebuild? [y/N]: " ans
    [[ "$ans" == [yY] ]] || { info "Cancelled."; return 0; }

    # --- Stop service ---
    info "Stopping llama-server…"
    systemctl stop llama-server 2>/dev/null || true

    # --- Pull ---
    info "Pulling latest…"
    if ! ${_git} pull --ff-only; then
        warn "git pull failed — local modifications may be blocking the merge."
        warn "Fix manually, then: systemctl start llama-server"
        return 1
    fi

    # --- Rebuild (CMake incremental — only recompiles changed TUs) ---
    # cmake runs as root so it can install to /usr/local, but cmake's
    # internal git calls (used to embed the version string) also hit the
    # "dubious ownership" block because the repo belongs to the service
    # user.  Add a transient safe.directory exception for root, cleaned
    # up via trap whether the build succeeds or fails.
    git config --global --add safe.directory "$src_dir"
    # shellcheck disable=SC2064
    trap "git config --global --unset-all safe.directory '${src_dir}' 2>/dev/null || true" RETURN

    local ncpu
    ncpu=$(nproc 2>/dev/null || echo 4)
    info "Building with ${ncpu} cores…"
    echo ""
    if ! cmake --build "$build_dir" --config Release -j"$ncpu"; then
        warn "Build failed. Service remains stopped."
        warn "To restore: systemctl start llama-server  (runs the old binary)"
        return 1
    fi
    ok "Build complete."

    # --- Install ---
    info "Installing binaries to /usr/local…"
    if ! cmake --install "$build_dir"; then
        warn "cmake --install failed — binaries not updated on disk."
        return 1
    fi
    ok "Installed."

    # --- Restart and verify ---
    info "Restarting llama-server…"
    systemctl start llama-server
    sleep 8
    if systemctl is-active --quiet llama-server; then
        local new_actual
        new_actual=$(${_git} describe --tags --always 2>/dev/null || echo "updated")
        ok "Service running — now at ${new_actual}."
    else
        warn "Service failed to start after update."
        warn "Check: journalctl -u llama-server -n 50"
    fi

    # Refresh parsed state so the main menu reflects the actual unit file
    # (the service may have been restarted with a different config than what
    # was loaded at session start).
    parse_unit_file
}

rollback_unit() {
    [[ -f "$BAK_FILE" ]] || die "No backup at ${BAK_FILE} — nothing to roll back to."
    info "Stopping llama-server…"
    systemctl stop llama-server 2>/dev/null || true
    info "Restoring ${UNIT_FILE} from ${BAK_FILE}"
    cp -a "$BAK_FILE" "$UNIT_FILE"
    systemctl daemon-reload
    systemctl restart llama-server
    ok "Rolled back. Service status:"
    systemctl --no-pager status llama-server || true
}

# ─── Menu ──────────────────────────────────────────────────────────────

main_menu() {
    while true; do
        clear
        printf '%s── llama-reconfigure %s ─────────────────────────────────────────%s\n' \
            "$C_BOLD$C_CYAN" "$LLAMA_RECONFIGURE_VERSION" "$C_RESET"
        show_current

        local mlock_item=6 dio_item=7 grp_item=8 jinja_item=9 reasoning_item=10 parallel_item=11
        if [[ "${P_IS_CUDA:-n}" == "y" ]]; then mlock_item=7; dio_item=8; grp_item=9; jinja_item=10; reasoning_item=11; parallel_item=12; fi

        printf ' [m] Model   [l] Listen   [0] Raw editor   [b] Benchmark & optimize\n'
        printf ' [a] Apply and restart   [d] Dry-run   [r] Rollback   [u] Update llama.cpp   [q] Quit\n'
        printf ' [1-%s] Change\n' "$parallel_item"
        printf '\n'

        local choice; read -rp '> ' choice
        case "$choice" in
            1) edit_context    ;;
            2) edit_cache      ;;
            3) edit_n_cpu_moe  ;;
            4) edit_flash      ;;
            5) edit_ubatch     ;;
            6)
                if [[ "${P_IS_CUDA:-n}" == "y" ]]; then edit_gpu_layers
                else edit_mlock; fi ;;
            7)
                if [[ "${P_IS_CUDA:-n}" == "y" ]]; then edit_mlock
                else edit_dio; fi ;;
            8)
                if [[ "${P_IS_CUDA:-n}" == "y" ]]; then edit_dio
                else edit_grp_attn; fi ;;
            9)
                if [[ "${P_IS_CUDA:-n}" == "y" ]]; then edit_grp_attn
                else edit_jinja; fi ;;
            10)
                if [[ "${P_IS_CUDA:-n}" == "y" ]]; then edit_jinja
                else edit_reasoning; fi ;;
            11)
                if [[ "${P_IS_CUDA:-n}" == "y" ]]; then edit_reasoning
                else edit_parallel; fi ;;
            12)
                if [[ "${P_IS_CUDA:-n}" == "y" ]]; then edit_parallel
                else warn "Unknown option."; fi ;;
            m|M) edit_model    ;;
            l|L) edit_listen   ;;
            0)   edit_raw      ;;
            b|B) bench_menu    ;;
            a|A) apply_changes && return 0 ;;
            d|D) apply_changes dry ;;
            r|R) rollback_unit && return 0 ;;
            u|U) update_llama_cpp ;;
            q|Q) info "Exit — no changes written."; return 0 ;;
            *)   warn "Unknown option." ;;
        esac
    done
}

# ─── Entry point ───────────────────────────────────────────────────────

main() {
    # No args = interactive menu
    if [[ $# -eq 0 ]]; then
        ensure_root "$@"
        require_unit_file
        parse_unit_file
        main_menu
        return
    fi

    case "$1" in
        --help|-h)    show_usage; return 0 ;;
        --version|-V) echo "llama-reconfigure ${LLAMA_RECONFIGURE_VERSION}"; return 0 ;;
    esac

    ensure_root "$@"
    require_unit_file
    parse_unit_file

    case "$1" in
        --show)       show_current ;;
        --dry-run)    main_menu; apply_changes dry ;;
        --rollback)   rollback_unit ;;
        --model)      edit_model;   apply_changes ;;
        --context)    edit_context; apply_changes ;;
        --ngl)        edit_ngl;     apply_changes ;;
        --cache)      edit_cache;   apply_changes ;;
        --flash)      edit_flash;   apply_changes ;;
        --listen)     edit_listen;  apply_changes ;;
        --mlock)      edit_mlock;      apply_changes ;;
        --dio)        edit_dio;        apply_changes ;;
        --fit)        edit_fit;        apply_changes ;;
        --ubatch)     edit_ubatch;     apply_changes ;;
        --n-cpu-moe)  edit_n_cpu_moe;  apply_changes ;;
        --grp-attn)   edit_grp_attn;   apply_changes ;;
        --jinja)      edit_jinja;      apply_changes ;;
        --reasoning)  edit_reasoning;  apply_changes ;;
        --parallel)   edit_parallel;   apply_changes ;;
        --raw)        edit_raw && apply_changes ;;
        --benchmark)
            local preset="${2:-chat}"
            bench_preset_spec "$preset" >/dev/null 2>&1 \
                || die "Unknown preset '$preset'. Use: openclaw, chat, coding, summarize."
            run_benchmark_preset "$preset" || true
            ;;
        *)
            warn "Unknown option: $1"
            show_usage
            return 2
            ;;
    esac
}

# Only run main when executed directly, not when sourced for testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
