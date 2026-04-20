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

LLAMA_RECONFIGURE_VERSION="1.2.0"

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
  --listen      Listen address (--host / --port)
  --mlock       Toggle --mlock
  --fit         Auto-fit (--fit / --fit-ctx)
  --raw         Raw ExecStart arg-string editor (advanced)

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
    [[ -n "$P_HOST" ]]    && out+=" --host $P_HOST"
    [[ -n "$P_CTX" ]]     && out+=" -c $P_CTX"
    [[ -n "$P_CACHE_K" ]] && out+=" -ctk $P_CACHE_K"
    [[ -n "$P_CACHE_V" ]] && out+=" -ctv $P_CACHE_V"
    [[ "$P_FLASH" == "on" ]] && out+=" --flash-attn on"
    [[ "$P_MLOCK" == "y" ]]  && out+=" --mlock"

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

# ─── Display ───────────────────────────────────────────────────────────

show_current() {
    printf '\n%s── Current llama-server configuration ──%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
    printf '  Unit file    : %s\n' "$UNIT_FILE"
    printf '  GPU mode     : %s\n' "$([[ "$P_IS_CUDA" == "y" ]] && echo 'CUDA' || echo 'CPU')"
    case "$P_MODEL_MODE" in
        hf)    printf '  Model (HF)   : %s:%s\n' "$P_HF_REPO" "${P_HF_FILE:-(repo default)}" ;;
        local) printf '  Model (file) : %s\n'    "$P_MODEL_PATH" ;;
        *)     printf '  Model        : %s(not detected — check --raw)%s\n' "$C_YELLOW" "$C_RESET" ;;
    esac
    printf '  Context      : %s\n' "${P_CTX:-(unset)}"
    [[ "$P_IS_CUDA" == "y" ]] && printf '  GPU layers   : %s\n' "${P_NGL:-(unset)}"
    printf '  KV cache     : K=%s  V=%s\n' "${P_CACHE_K:-f16}" "${P_CACHE_V:-f16}"
    printf '  Flash attn   : %s\n' "${P_FLASH:-(unset)}"
    printf '  Listen       : %s:%s\n' "${P_HOST:-127.0.0.1}" "${P_PORT:-8080}"
    printf '  mlock        : %s\n' "$P_MLOCK"
    [[ "$P_IS_CUDA" == "y" ]] && printf '  --fit        : %s  (--fit-ctx %s)\n' "${P_FIT:-off}" "${P_FIT_CTX:-unset}"
    printf '  Service      : %s\n' "$(systemctl is-active llama-server 2>/dev/null || echo 'inactive')"
    printf '\n'
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

edit_ngl() {
    if [[ "$P_IS_CUDA" != "y" ]]; then warn "CPU-only build — -ngl not applicable."; return 0; fi
    local v
    read -rp "GPU layers -ngl (current: ${P_NGL:-unset}, 99 = all) [blank = keep]: " v
    [[ -n "$v" ]] || return 0
    [[ "$v" =~ ^[0-9]+$ ]] || { warn "Not a number."; return 0; }
    P_NGL="$v"
}

edit_cache() {
    local k v
    echo "KV cache quant. Options: f16 bf16 q8_0 q4_0 (q8_0 is a good default for CUDA + --flash-attn)"
    read -rp "  -ctk (current: ${P_CACHE_K:-f16}) [blank = keep]: " k
    read -rp "  -ctv (current: ${P_CACHE_V:-f16}) [blank = keep]: " v
    [[ -n "$k" ]] && P_CACHE_K="$k"
    [[ -n "$v" ]] && P_CACHE_V="$v"
}

edit_flash() {
    if [[ "$P_IS_CUDA" != "y" ]]; then warn "--flash-attn is CUDA-only."; return 0; fi
    case "${P_FLASH:-off}" in
        on)  P_FLASH="off"; ok "flash-attn → off" ;;
        *)   P_FLASH="on";  ok "flash-attn → on"  ;;
    esac
}

edit_listen() {
    local h p
    read -rp "Bind host (current: ${P_HOST:-127.0.0.1}; use 0.0.0.0 to expose on LAN) [blank = keep]: " h
    read -rp "Port (current: ${P_PORT:-8080}) [blank = keep]: " p
    [[ -n "$h" ]] && P_HOST="$h"
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

edit_fit() {
    if [[ "$P_IS_CUDA" != "y" ]]; then warn "--fit is CUDA-only."; return 0; fi
    local v c
    read -rp "Enable --fit (current: ${P_FIT:-off}) [on/off/blank]: " v
    case "$v" in
        on)  P_FIT="on"; read -rp "  --fit-ctx (current: ${P_FIT_CTX:-65536}) [blank = keep]: " c
             [[ -n "$c" && "$c" =~ ^[0-9]+$ ]] && P_FIT_CTX="$c" ;;
        off) P_FIT="off" ;;
        "")  return 0 ;;
        *)   warn "Expected on/off." ;;
    esac
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
    P_MODEL_PATH=""
    ok "Queued: ${P_HF_REPO}:${P_HF_FILE} (download happens at Apply time if not cached)."
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
            info "Queued ${P_HF_REPO}${P_HF_FILE:+:$P_HF_FILE} (download at Apply time)."
            ;;
        3)
            local v; read -rp "Absolute path to .gguf: " v
            [[ -n "$v" ]] || return 0
            [[ "$v" == /* ]] || { warn "Must be an absolute path."; return 0; }
            [[ -r "$v" ]] || { warn "File not readable: $v"; return 0; }
            P_MODEL_MODE="local"; P_MODEL_PATH="$v"; P_HF_REPO=""; P_HF_FILE=""
            info "Queued local model $v."
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

# ─── HuggingFace download with progress ────────────────────────────────
#
# Resolves an HF repo+file to a local cached path, downloading with a
# visible progress bar if it isn't already cached. Returns the local
# path via stdout.
#
hf_resolve_or_download() {
    local repo="$1" file="$2" cache_root="${3:-/root/.cache/llama.cpp}"
    mkdir -p "$cache_root"
    local dest="$cache_root/${repo//\//_}--${file:-model.gguf}"

    if [[ -f "$dest" ]]; then
        printf '%s' "$dest"
        return 0
    fi

    if [[ -z "$file" ]]; then
        warn "HF download requires an explicit file (--hf-file). Fetch manually or use org/repo:file.gguf."
        return 1
    fi

    local url="https://huggingface.co/${repo}/resolve/main/${file}"
    info "Downloading ${repo}/${file}…" >&2

    local -a auth=()
    [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${HF_TOKEN}")

    # curl's --progress-bar shows %, size, ETA — better than spinner
    if ! curl -fL --progress-bar "${auth[@]}" -o "$dest.part" "$url" >&2; then
        rm -f "$dest.part"
        warn "Download failed (check repo slug, file name, or HF_TOKEN for gated repos)."
        return 1
    fi
    mv "$dest.part" "$dest"
    printf '%s' "$dest"
}

# ─── Apply / rollback ──────────────────────────────────────────────────

apply_changes() {
    local dry="${1:-}"

    # If model is HF and not yet cached, download it BEFORE touching the unit
    # so we fail loud without disturbing the running service.
    if [[ "$P_MODEL_MODE" == "hf" && -n "$P_HF_FILE" ]]; then
        local resolved; resolved=$(hf_resolve_or_download "$P_HF_REPO" "$P_HF_FILE" "/root/.cache/llama.cpp" || true)
        if [[ -z "$resolved" ]]; then
            warn "Model not available — aborting apply."
            return 1
        fi
        ok "Model cached at $resolved"
        # Keep P_MODEL_MODE=hf so the ExecStart still uses --hf-repo/--hf-file;
        # llama-server will find the local cache on its own.
    fi

    local new_args
    if [[ -n "${P_RAW_OVERRIDE:-}" ]]; then
        new_args="$P_ARG_STRING"
    else
        new_args=$(serialize_arg_string)
    fi
    validate_arg_string "$new_args" || return 1

    local new_exec="${P_EXEC_PREFIX}${new_args}${P_EXEC_SUFFIX}"
    local new_unit; new_unit=$(mktemp -t llama-server-unit.XXXXXX)
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
    if ! systemd-analyze verify "$new_unit" 2>&1 | grep -v '^$' >&2; then
        : # some versions of systemd-analyze are chatty even on success; don't treat as failure
    fi

    info "Stopping llama-server…"
    systemctl stop llama-server 2>/dev/null || true

    info "Backing up current unit → ${BAK_FILE}"
    cp -a "$UNIT_FILE" "$BAK_FILE"

    info "Installing new unit…"
    install -m 644 "$new_unit" "$UNIT_FILE"
    rm -f "$new_unit"

    info "Reloading daemon and restarting…"
    systemctl daemon-reload
    if ! systemctl restart llama-server; then
        warn "Restart failed — inspect with: journalctl -u llama-server -n 100"
        warn "Rollback available: llama-reconfigure --rollback"
        return 1
    fi

    # Poll for up to 10s to catch obvious boot failures
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if systemctl is-active --quiet llama-server; then
            ok "llama-server is active (${i}s after restart)."
            break
        fi
        sleep 1
    done

    if ! systemctl is-active --quiet llama-server; then
        warn "Service did not come up within 10s. Last log lines:"
        journalctl -u llama-server -n 30 --no-pager >&2 || true
        warn "Rollback available: llama-reconfigure --rollback"
        return 1
    fi

    ok "Applied. Run 'journalctl -u llama-server -f' to watch startup."
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
        show_current
        cat <<MENU
  1) Model          2) Context        3) GPU layers      4) KV cache
  5) Flash-attn     6) Listen addr    7) mlock           8) --fit
  9) Raw editor
  a) Apply and restart     d) Dry-run preview
  r) Rollback to .bak      q) Quit
MENU
        local choice; read -rp "> " choice
        case "$choice" in
            1) edit_model   ;;
            2) edit_context ;;
            3) edit_ngl     ;;
            4) edit_cache   ;;
            5) edit_flash   ;;
            6) edit_listen  ;;
            7) edit_mlock   ;;
            8) edit_fit     ;;
            9) edit_raw     ;;
            a|A) apply_changes && return 0 ;;
            d|D) apply_changes dry ;;
            r|R) rollback_unit && return 0 ;;
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
        --mlock)      edit_mlock;   apply_changes ;;
        --fit)        edit_fit;     apply_changes ;;
        --raw)        edit_raw && apply_changes ;;
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
