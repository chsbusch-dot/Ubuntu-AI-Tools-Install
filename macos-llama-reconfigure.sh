#!/bin/bash
#
# macos-llama-reconfigure — menu-driven editor for an installed
# com.macos-prep.llama-server launchd LaunchDaemon.
#
# Lets you change the model and/or runtime flags on a running llama.cpp
# LaunchDaemon on macOS, then safely swaps the plist and restarts via
# launchctl bootstrap/bootout/kickstart. Parses the existing
# ProgramArguments array via PlistBuddy so hand edits and install-time
# choices are preserved; only the flags you touch change.
#
# Part of the ubuntu-prep project (macOS port):
#   https://github.com/chsbusch-dot/Ubuntu-AI-Tools-Install
#
# This is a standalone script — it does NOT require macos-prep-setup.sh
# to be present. Install once, then re-run whenever you want to retune.
#
# Apple Silicon only (M1-M5). Metal is always on; the unified memory pool
# doubles as the VRAM budget for fit-checks.

set -euo pipefail

LLAMA_RECONFIGURE_VERSION="1.5.0-macos"

PLIST_FILE="${LLAMA_PLIST_FILE:-/Library/LaunchDaemons/com.macos-prep.llama-server.plist}"
BAK_FILE="${PLIST_FILE}.bak"
# Parsed from the plist at runtime in parse_plist_file(); used by
# launchctl bootstrap/bootout. Falls back to the conventional value if
# the Label key is missing for some reason.
PLIST_LABEL=""

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
macos-llama-reconfigure ${LLAMA_RECONFIGURE_VERSION} — edit an installed llama-server LaunchDaemon

Usage: macos-llama-reconfigure [OPTION]

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
  --fit         Auto-fit (--fit / --fit-ctx)
  --n-cpu-moe   MoE expert layers on CPU (--n-cpu-moe)
  --raw         Raw ProgramArguments editor (advanced)

BENCHMARK
  --benchmark [PRESET]   Sweep ubatch × kv-cache × flash-attn with
                         llama-bench for a workload preset, rank by
                         total wall-clock time, offer to apply winner.
                         PRESET is one of: openclaw, chat (default),
                         coding, summarize.

READ-ONLY / MAINTENANCE
  --show        Print the parsed current configuration and exit
  --dry-run     Walk through the menu, print the would-be ProgramArguments, write nothing
  --rollback    Restore the LaunchDaemon plist from the last .bak and restart

  --version, -V Print version and exit
  --help, -h    Show this help and exit

REQUIRES
  - ${PLIST_FILE} (run macos-prep-setup.sh first)
  - sudo (the script re-execs itself with sudo if run as a normal user)
  - /usr/libexec/PlistBuddy (ships with macOS)

SAFETY
  The current plist is copied to ${BAK_FILE} before every change and
  validated with 'plutil -lint' before being installed. Use --rollback
  to restore it if something fails.
USAGE
}

# ─── Preconditions ─────────────────────────────────────────────────────

require_plist_file() {
    [[ -f "$PLIST_FILE" ]] || die "No llama-server LaunchDaemon found at ${PLIST_FILE}. Run macos-prep-setup.sh first."
}

require_plistbuddy() {
    [[ -x /usr/libexec/PlistBuddy ]] || die "/usr/libexec/PlistBuddy not found — is this really macOS?"
}

ensure_root() {
    # Re-exec with sudo, preserving env so HF_TOKEN from the user's
    # ~/.env.secrets is available if something downstream sources it.
    if [[ $EUID -ne 0 ]]; then
        exec sudo --preserve-env=HF_TOKEN -- bash "$0" "$@"
    fi
}

# ─── Plist helpers ─────────────────────────────────────────────────────
#
# All plist reads go through PlistBuddy so we correctly handle XML entities
# (&amp;, &lt;) and the binary/XML format variations. Each helper returns
# an empty string on a missing key rather than failing — the parser
# tolerates unset flags gracefully.

pb() {
    # Usage: pb <command> [<file>]. Defaults file to $PLIST_FILE.
    /usr/libexec/PlistBuddy -c "$1" "${2:-$PLIST_FILE}" 2>/dev/null
}

pb_count_program_arguments() {
    # Returns the number of entries in ProgramArguments, or 0 if the key
    # is unset. PlistBuddy's "Print :ProgramArguments" on an array prints
    # a multi-line indented block; counting entries from that is fragile,
    # so we probe :ProgramArguments:N in a loop until it errors out.
    local n=0
    while /usr/libexec/PlistBuddy -c "Print :ProgramArguments:$n" "$PLIST_FILE" >/dev/null 2>&1; do
        n=$((n + 1))
    done
    printf '%s' "$n"
}

# ─── Parser ────────────────────────────────────────────────────────────
#
# Populates globals from the current plist file:
#   P_PROGRAM       path to llama-server (ProgramArguments[0])
#   P_ARGV          array of all ProgramArguments entries (copy of argv)
#   P_IS_CUDA       y/n — always y on Apple Silicon (Metal is the CUDA equivalent)
#   P_MODEL_MODE    hf | local
#   P_HF_REPO       bartowski/Qwen2.5-…-GGUF       (if HF)
#   P_HF_FILE       Qwen2.5-…-Q5_K_M.gguf           (if HF)
#   P_MODEL_PATH    /Users/.../model.gguf           (if local)
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
#   PLIST_LABEL     com.macos-prep.llama-server (from the Label key)
#
parse_plist_file() {
    local label
    label=$(pb "Print :Label")
    PLIST_LABEL="${label:-com.macos-prep.llama-server}"

    local argc i arg
    argc=$(pb_count_program_arguments)
    (( argc > 0 )) || die "ProgramArguments array is empty in ${PLIST_FILE}"

    P_ARGV=()
    for (( i=0; i<argc; i++ )); do
        arg=$(pb "Print :ProgramArguments:$i")
        P_ARGV+=("$arg")
    done
    P_PROGRAM="${P_ARGV[0]}"

    # Metal is always on on Apple Silicon, so every knob that was gated
    # on "CUDA build" upstream (ngl, flash-attn, fit) is available here.
    # shellcheck disable=SC2034  # kept for parity with the Ubuntu script; read by debug dumps
    P_IS_CUDA="y"

    P_HF_REPO=""; P_HF_FILE=""; P_MODEL_PATH=""; P_MODEL_MODE=""
    P_HF_FILE_BYTES=""
    P_CTX=""; P_NGL=""; P_CACHE_K=""; P_CACHE_V=""; P_FLASH=""
    P_HOST=""; P_PORT=""; P_MLOCK="n"; P_FIT=""; P_FIT_CTX=""
    P_N_CPU_MOE=""; P_UBATCH=""; P_DIO="n"

    # Walk argv looking for flags we know about. Index 0 is the program
    # path so start from 1.
    for (( i=1; i<argc; i++ )); do
        arg="${P_ARGV[$i]}"
        case "$arg" in
            --hf-repo)   P_MODEL_MODE="hf";    P_HF_REPO="${P_ARGV[$((i+1))]:-}" ;;
            --hf-file)   P_HF_FILE="${P_ARGV[$((i+1))]:-}" ;;
            --model|-m)  P_MODEL_MODE="local"; P_MODEL_PATH="${P_ARGV[$((i+1))]:-}" ;;
            -c)          P_CTX="${P_ARGV[$((i+1))]:-}" ;;
            -ngl)        P_NGL="${P_ARGV[$((i+1))]:-}" ;;
            -ctk)        P_CACHE_K="${P_ARGV[$((i+1))]:-}" ;;
            -ctv)        P_CACHE_V="${P_ARGV[$((i+1))]:-}" ;;
            --flash-attn) P_FLASH="${P_ARGV[$((i+1))]:-}" ;;
            --host)      P_HOST="${P_ARGV[$((i+1))]:-}" ;;
            --port)      P_PORT="${P_ARGV[$((i+1))]:-}" ;;
            --mlock)     P_MLOCK="y" ;;
            --fit)       P_FIT="${P_ARGV[$((i+1))]:-}" ;;
            --fit-ctx)   P_FIT_CTX="${P_ARGV[$((i+1))]:-}" ;;
            --n-cpu-moe) P_N_CPU_MOE="${P_ARGV[$((i+1))]:-}" ;;
            -ub|--ubatch) P_UBATCH="${P_ARGV[$((i+1))]:-}" ;;
            -dio)        P_DIO="y" ;;
        esac
    done
}

# ─── Serializer ────────────────────────────────────────────────────────
#
# Builds a fresh argv (as a bash array) from P_* globals. Flag order is
# fixed so the output is deterministic (easier to diff, easier to test).
# The array is emitted via the global P_NEW_ARGV so the caller can feed
# it straight back into PlistBuddy.
#
serialize_argv() {
    P_NEW_ARGV=( "$P_PROGRAM" )

    case "$P_MODEL_MODE" in
        hf)
            P_NEW_ARGV+=( "--hf-repo" "$P_HF_REPO" )
            [[ -n "$P_HF_FILE" ]] && P_NEW_ARGV+=( "--hf-file" "$P_HF_FILE" )
            ;;
        local)
            P_NEW_ARGV+=( "--model" "$P_MODEL_PATH" )
            ;;
    esac

    [[ -n "$P_PORT" ]]    && P_NEW_ARGV+=( "--port" "$P_PORT" )
    if [[ "$P_FIT" == "on" ]]; then
        P_NEW_ARGV+=( "--fit" "on" "--fit-ctx" "${P_FIT_CTX:-65536}" )
    elif [[ -n "$P_NGL" ]]; then
        P_NEW_ARGV+=( "-ngl" "$P_NGL" )
    fi
    [[ -n "$P_HOST" ]]       && P_NEW_ARGV+=( "--host" "$P_HOST" )
    [[ -n "$P_CTX" ]]        && P_NEW_ARGV+=( "-c" "$P_CTX" )
    [[ -n "$P_UBATCH" ]]     && P_NEW_ARGV+=( "-ub" "$P_UBATCH" )
    [[ -n "$P_CACHE_K" ]]    && P_NEW_ARGV+=( "-ctk" "$P_CACHE_K" )
    [[ -n "$P_CACHE_V" ]]    && P_NEW_ARGV+=( "-ctv" "$P_CACHE_V" )
    [[ "$P_FLASH" == "on" ]] && P_NEW_ARGV+=( "--flash-attn" "on" )
    [[ "$P_MLOCK" == "y" ]]  && P_NEW_ARGV+=( "--mlock" )
    [[ "$P_DIO" == "y" ]]    && P_NEW_ARGV+=( "-dio" )
    [[ -n "$P_N_CPU_MOE" ]]  && P_NEW_ARGV+=( "--n-cpu-moe" "$P_N_CPU_MOE" )
}

# Pretty-print the serialized argv as a single command line, for display.
format_argv_line() {
    local out="" a
    for a in "${P_NEW_ARGV[@]}"; do
        if [[ -z "$out" ]]; then out="$a"
        else out+=" $a"
        fi
    done
    printf '%s' "$out"
}

# Reject XML metacharacters that would break a PlistBuddy 'Add' round-trip
# or get double-escaped. Users hitting this almost always mistyped.
validate_arg_string() {
    local s="$1"
    if [[ "$s" == *\'* || "$s" == *\<* || "$s" == *\>* || "$s" == *\&* ]]; then
        warn "Arg string contains a quote or XML metacharacter (' < > &); rejecting. Edit cancelled."
        return 1
    fi
}

# ─── Path helpers ──────────────────────────────────────────────────────
#
# The LaunchDaemon runs as a non-root user (UserName key) and tells
# llama-server to cache HF downloads under $LLAMA_CACHE. We parse both
# out of the plist so the model-size / VRAM estimator and the
# hf_resolve_or_download helper can find pre-downloaded .gguf files on
# any user's machine (not just "chris").

detect_user_from_plist() {
    local u
    u=$(pb "Print :UserName")
    [[ -n "$u" ]] || u="${SUDO_USER:-${USER:-root}}"
    printf '%s' "$u"
}

home_for_user() {
    local u="$1" home
    if [[ "$u" == "root" ]]; then
        printf '/var/root'
        return
    fi
    home=$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}' | head -1)
    [[ -n "$home" ]] || home="/Users/$u"
    printf '%s' "$home"
}

# Iterate :EnvironmentVariables and print each as "KEY=VAL" — used by
# both detect_llama_cache and the bench sweep's env prefix.
extract_plist_env() {
    # Probe for the EnvironmentVariables dict; no-op if absent.
    pb "Print :EnvironmentVariables" >/dev/null 2>&1 || return 0

    local keys_raw key val
    keys_raw=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables" "$PLIST_FILE" 2>/dev/null \
        | awk '/^    [A-Za-z_]+[A-Za-z0-9_]* =/ { gsub(/ *= */, ""); print $1 }')
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        val=$(pb "Print :EnvironmentVariables:$key")
        printf '%s=%s\n' "$key" "$val"
    done <<<"$keys_raw"
}

detect_llama_cache() {
    local cache
    cache=$(extract_plist_env | awk -F= '$1=="LLAMA_CACHE" { sub(/^[^=]*=/,""); print; exit }')
    if [[ -z "$cache" ]]; then
        local u home
        u=$(detect_user_from_plist)
        home=$(home_for_user "$u")
        cache="${home}/llama.cpp/models"
    fi
    printf '%s' "$cache"
}

# Given P_* state, print the on-disk .gguf path if it can be located,
# otherwise print nothing. Searches common HF cache naming schemes.
resolve_local_gguf() {
    if [[ "${P_MODEL_MODE:-}" == "local" && -f "${P_MODEL_PATH:-}" ]]; then
        printf '%s' "$P_MODEL_PATH"
        return 0
    fi
    if [[ "${P_MODEL_MODE:-}" == "hf" && -n "${P_HF_FILE:-}" && -n "${P_HF_REPO:-}" ]]; then
        local cache candidate
        cache=$(detect_llama_cache)
        for candidate in \
            "${cache}/${P_HF_REPO//\//_}--${P_HF_FILE}" \
            "${cache}/${P_HF_REPO}/${P_HF_FILE}" \
            "${cache}/${P_HF_FILE}"; do
            [[ -f "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
        done
    fi
    return 0
}

# ─── VRAM estimation ───────────────────────────────────────────────────
#
# Apple Silicon has a unified memory pool — there is no separate VRAM.
# We treat total installed RAM as the model+KV+overhead budget for the
# fit check. Users with a 64 GB Mac who have Chrome open will still OOM
# at "88% of memsize", but the estimator's job is to flag obvious
# disasters (a 70B Q8 model with 128k context on a 24 GB machine), not
# to model macOS's paging behaviour.

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
        # BSD stat first (macOS), GNU stat fallback (for unit tests on Linux)
        bytes=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || true)
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
    # Apple Silicon: unified memory, so hw.memsize is the VRAM budget.
    local bytes
    bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
    if [[ "${bytes:-}" =~ ^[0-9]+$ ]] && (( bytes > 0 )); then
        awk "BEGIN { printf \"%d\", $bytes / 1073741824 + 0.5 }"
    fi
    return 0
}

# ─── launchd helpers ───────────────────────────────────────────────────
#
# launchctl on modern macOS (Big Sur+) wants the domain-qualified
# "system/<label>" form; the older "load/unload" commands are
# deprecated. We use bootstrap/bootout for install/uninstall and
# kickstart -k for a clean restart.

llama_is_active() {
    # `launchctl print system/<label>` exits 0 if the service is loaded
    # (running or not) and non-zero if it's unknown. For the "is it
    # actively running?" check, look for "state = running" in the output.
    local out
    out=$(launchctl print "system/${PLIST_LABEL}" 2>/dev/null) || return 1
    [[ "$out" == *"state = running"* ]]
}

llama_exit_count() {
    # Pull the most recent "last exit reason" count equivalent. launchd
    # doesn't expose NRestarts the way systemd does, so instead we track
    # the "last exit status" line — if it changes between snapshots we
    # know a crash-restart cycle fired.
    launchctl print "system/${PLIST_LABEL}" 2>/dev/null \
        | awk '/last exit reason|last exit code/ { print; exit }' \
        | md5 2>/dev/null || printf '%s' "(unknown)"
}

llama_start() {
    # If unloaded, bootstrap. If loaded but stopped, kickstart.
    if launchctl print "system/${PLIST_LABEL}" >/dev/null 2>&1; then
        launchctl kickstart -k "system/${PLIST_LABEL}" 2>/dev/null || return 1
    else
        launchctl bootstrap system "$PLIST_FILE" 2>/dev/null || return 1
    fi
}

llama_stop() {
    if launchctl print "system/${PLIST_LABEL}" >/dev/null 2>&1; then
        launchctl bootout "system/${PLIST_LABEL}" 2>/dev/null || true
    fi
}

llama_restart() {
    launchctl kickstart -k "system/${PLIST_LABEL}" 2>/dev/null
}

llama_log_tail() {
    # The prep script configures StandardOutPath/StandardErrorPath; tail
    # whichever log exists. Fall back to `log show` for the unified log.
    local n="${1:-40}" stdout_log stderr_log
    stdout_log=$(pb "Print :StandardOutPath")
    stderr_log=$(pb "Print :StandardErrorPath")
    if [[ -n "$stderr_log" && -f "$stderr_log" ]]; then
        tail -n "$n" "$stderr_log" 2>/dev/null || true
    fi
    if [[ -n "$stdout_log" && -f "$stdout_log" && "$stdout_log" != "$stderr_log" ]]; then
        tail -n "$n" "$stdout_log" 2>/dev/null || true
    fi
}

# ─── Display ───────────────────────────────────────────────────────────

show_current() {
    local moe_disp fa_disp mlock_disp dio_disp ngl_disp
    [[ -n "${P_N_CPU_MOE:-}" ]] && moe_disp="${P_N_CPU_MOE} layers" || moe_disp="off"
    [[ "${P_FLASH:-}" == "on" ]] && fa_disp="on"  || fa_disp="off"
    [[ "${P_MLOCK:-n}" == "y" ]] && mlock_disp="on" || mlock_disp="off"
    [[ "${P_DIO:-n}"   == "y" ]] && dio_disp="on"   || dio_disp="off"
    if [[ "${P_FIT:-}" == "on" ]]; then
        ngl_disp="auto-fit  --fit-ctx ${P_FIT_CTX:-${P_CTX:-}}"
    else
        ngl_disp="${P_NGL:-99}"
    fi

    # Metal is always on → GPU row is always shown → mlock=7, dio=8.
    local mlock_item=7 dio_item=8

    local service_state="inactive"
    if llama_is_active; then service_state="active"
    elif launchctl print "system/${PLIST_LABEL}" >/dev/null 2>&1; then service_state="loaded (stopped)"
    fi

    printf '\n'
    case "$P_MODEL_MODE" in
        hf)    printf ' Model:   %s%s%s : %s\n' \
                   "$C_BOLD" "$P_HF_REPO" "$C_RESET" "${P_HF_FILE:-(repo default)}" ;;
        local) printf ' Model:   %s%s%s\n' "$C_BOLD" "$P_MODEL_PATH" "$C_RESET" ;;
        *)     printf ' %sModel:   (not detected — use raw editor)%s\n' "$C_YELLOW" "$C_RESET" ;;
    esac
    printf ' Listen:  %s:%s\n' "${P_HOST:-127.0.0.1}" "${P_PORT:-8080}"
    printf ' Service: %s  (%s)\n' "$service_state" "$PLIST_LABEL"
    printf '\n'

    printf '%sContext & Memory:%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
    printf ' 1. Context size:       [%s] tokens\n'              "${P_CTX:-(unset)}"
    printf ' 2. KV cache type:      [%s]  (K and V matched)\n'  "${P_CACHE_K:-f16}"
    printf ' 3. CPU MoE offload:    [%s]\n'                      "$moe_disp"
    printf ' 4. Flash attention:    [%s]\n'                      "$fa_disp"
    printf ' 5. Ubatch size:        [%s]\n'                      "${P_UBATCH:-(unset)}"
    printf ' 6. GPU layers:         [%s]  (-ngl / --fit, Metal)\n'  "$ngl_disp"
    printf ' %s. Mem lock (--mlock): [%s]  (prevent idle swap)\n'   "$mlock_item" "$mlock_disp"
    printf ' %s. Direct I/O (-dio):  [%s]  (prevent tensor hang)\n' "$dio_item"   "$dio_disp"
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
            printf " Estimated total:  ${fit_color}%s / %s GB (UMA)  %s\e[0m\n" \
                "$total_gb" "${hw_vram:--}" "$fits"
        else
            printf ' Estimated total:  %s / %s GB (UMA)  %s\n' \
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

edit_ngl() {
    local v
    read -rp "GPU layers -ngl (current: ${P_NGL:-unset}, 99 = all) [blank = keep]: " v
    [[ -n "$v" ]] || return 0
    [[ "$v" =~ ^[0-9]+$ ]] || { warn "Not a number."; return 0; }
    P_NGL="$v"
}

edit_cache() {
    local k v
    echo "KV cache quant. Options: f16 bf16 q8_0 q4_0 (q8_0 is a good default with --flash-attn)"
    read -rp "  -ctk (current: ${P_CACHE_K:-f16}) [blank = keep]: " k
    read -rp "  -ctv (current: ${P_CACHE_V:-f16}) [blank = keep]: " v
    [[ -n "$k" ]] && P_CACHE_K="$k"
    [[ -n "$v" ]] && P_CACHE_V="$v"
}

edit_flash() {
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

edit_n_cpu_moe() {
    local v
    echo "MoE expert layers to run on CPU (0 = all on GPU, unset = llama.cpp default)."
    echo "Useful for large MoE models (Mixtral, DeepSeek-MoE, Qwen-MoE) when UMA is tight."
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
    echo "Larger = faster prompt ingestion, more UMA spikes during prefill."
    echo "Options: 512 / 1024 (recommended) / 2048 / 4096 / custom"
    read -rp "  -ub (current: ${P_UBATCH:-(unset)}) [blank = keep, 0 = clear]: " v
    [[ -z "$v" ]] && return 0
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

# ─── HuggingFace Hub API ───────────────────────────────────────────────
#
# Public API, no token required for ungated repos. HF_TOKEN is passed
# through when set so gated repos (meta-llama, google/gemma) also work.

hf_api_curl() {
    local url="$1"; shift || true
    local -a auth=()
    [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${HF_TOKEN}")
    curl -fsSL --max-time 15 "${auth[@]}" "$@" "$url"
}

hf_api_search() {
    local query="$1"
    local q_enc; q_enc=$(printf '%s' "$query" | jq -sRr @uri)
    hf_api_curl "https://huggingface.co/api/models?search=${q_enc}&filter=gguf&sort=downloads&direction=-1&limit=20"
}

hf_api_tree() {
    local repo="$1"
    hf_api_curl "https://huggingface.co/api/models/${repo}/tree/main"
}

hf_parse_search_results() {
    jq -r '.[] | "\(.id)\t\(.downloads // 0)\t\(.likes // 0)"'
}

hf_parse_tree_gguf() {
    jq -r '.[] | select(.type == "file") | select(.path | endswith(".gguf")) | "\(.path)\t\(.size // 0)"' \
        | sort -t $'\t' -k2 -nr
}

human_size() {
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
        warn "jq is required for HF search. Install it: brew install jq"
        return 1
    }
}

edit_model_search_flow() {
    require_jq || return 1

    local query
    read -rp "Search HuggingFace for: " query
    [[ -n "$query" ]] || { info "Cancelled."; return 0; }

    info "Searching huggingface.co…"
    local raw; raw=$(hf_api_search "$query" || true)
    [[ -n "$raw" ]] || { warn "No response from HF API."; return 1; }

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
    P_HF_FILE_BYTES="${sizes[$((pick-1))]}"
    P_MODEL_PATH=""
    ok "Queued: ${P_HF_REPO}:${P_HF_FILE} ($(human_size "${P_HF_FILE_BYTES}")) — download happens at Apply time if not cached."
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
            ;;
        3)
            local v; read -rp "Absolute path to .gguf: " v
            [[ -n "$v" ]] || return 0
            [[ "$v" == /* ]] || { warn "Must be an absolute path."; return 0; }
            [[ -r "$v" ]] || { warn "File not readable: $v"; return 0; }
            P_MODEL_MODE="local"; P_MODEL_PATH="$v"; P_HF_REPO=""; P_HF_FILE=""
            P_HF_FILE_BYTES=""
            info "Queued local model $v."
            ;;
        q|Q|"") info "Cancelled." ;;
        *)      warn "Unknown option." ;;
    esac
}

# Raw editor — opens a temp file with every argv[i] on its own line.
# Save & close to replace ProgramArguments with the new list. Handy for
# one-off flags we don't have a dedicated editor for.
edit_raw() {
    local tmp a
    tmp=$(mktemp -t llama-args)
    for a in "${P_ARGV[@]}"; do
        printf '%s\n' "$a" >>"$tmp"
    done
    ${EDITOR:-vi} "$tmp"

    # Read back one-line-per-arg, strip trailing empty lines, validate.
    local -a new_argv=()
    while IFS= read -r a; do
        [[ -n "$a" ]] || continue
        validate_arg_string "$a" || { rm -f "$tmp"; return 1; }
        new_argv+=("$a")
    done <"$tmp"
    rm -f "$tmp"

    if [[ "${#new_argv[@]}" -lt 1 ]]; then
        warn "Raw editor produced an empty argv; edit cancelled."
        return 1
    fi

    P_ARGV=( "${new_argv[@]}" )
    P_PROGRAM="${P_ARGV[0]}"
    warn "Raw-edit mode bypasses the structured editors — 'Apply' will use this argv verbatim."
    P_RAW_OVERRIDE=1
}

# ─── HuggingFace reachability check ────────────────────────────────────

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

hf_head_content_length() {
    local repo="$1" file="$2"
    local url="https://huggingface.co/${repo}/resolve/main/${file}"
    local -a auth=()
    [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${HF_TOKEN}")

    local bytes
    bytes=$(curl -fsSLI --max-time 15 "${auth[@]}" "$url" 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {v=$2} END {gsub(/\r/,"",v); print v}' \
        || true)
    if [[ "${bytes:-}" =~ ^[0-9]+$ ]] && (( bytes > 0 )); then
        printf '%s' "$bytes"
    fi
    return 0
}

# ─── Benchmark & optimize ──────────────────────────────────────────────

BENCH_DIR="/var/db/macos-llama-reconfigure"

bench_preset_spec() {
    case "$1" in
        openclaw)  echo "64 256 OpenClaw routing (short system prompt, short reply)" ;;
        chat)      echo "512 1024 Interactive chat (moderate prompt + reply)" ;;
        coding)    echo "8192 2048 Coding assistant (large context, medium output)" ;;
        summarize) echo "32768 512 Long-document summarisation (huge prompt, short output)" ;;
        *)         return 1 ;;
    esac
}

# Runs llama-bench for one cache type, writing JSON to $1.
bench_run_one() {
    local out="$1" model="$2" p="$3" n="$4" ub_list="$5" ctk="$6" fa_list="$7" ngl="$8"
    local reps="${9:-${BENCH_REPS:-2}}"

    local -a env_pairs=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && env_pairs+=("$line")
    done < <(extract_plist_env)

    env "${env_pairs[@]}" \
        llama-bench -m "$model" -p "$p" -n "$n" \
            -ub "$ub_list" -ctk "$ctk" -ctv "$ctk" -fa "$fa_list" \
            -ngl "$ngl" -r "$reps" -o json >"$out"
}

# Rough runtime estimate for the sweep, in whole minutes. Apple Silicon
# tg ≈ 30-60 t/s for 7-13B Q4/Q5 models; we use pp=200, tg=40 as a
# conservative pair — real runs are usually faster.
bench_estimate_minutes() {
    local p="$1" n="$2" cells="$3" reps="$4"
    awk "BEGIN {
        per_run = ($p/200.0) + ($n/40.0);
        total_s = $cells * $reps * per_run;
        mins = total_s / 60.0;
        if (mins < 1) mins = 1;
        printf \"%d\", mins + 0.5
    }"
}

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
        llama_start 2>/dev/null || true
        BENCH_STOPPED_SERVICE=0
    fi
    exit 130
}

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

bench_run_cell() {
    local tmp="$1" model="$2" p="$3" n="$4" ub_list="$5" ctk="$6"
    local fa_list="$7" ngl="$8" reps="$9" idx="${10}" total="${11}"
    local cell_start cell_end elapsed _hb_pid=0 rc

    info "  → [${idx}/${total}] sweeping ctk=ctv=$ctk (r=$reps)  started $(date '+%H:%M:%S')"
    printf '     %s\n' "──────────────────────────────────────────" >&2
    cell_start=$SECONDS

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

run_benchmark_preset() {
    local preset="$1"
    local spec p n label
    spec=$(bench_preset_spec "$preset") || { warn "Unknown preset: $preset"; return 1; }
    p=$(awk '{print $1}' <<<"$spec")
    n=$(awk '{print $2}' <<<"$spec")
    label=$(cut -d' ' -f3- <<<"$spec")

    command -v llama-bench >/dev/null 2>&1 || {
        warn "llama-bench not found in PATH. Install it with macos-prep-setup.sh (llama.cpp component)."
        return 1
    }
    command -v jq >/dev/null 2>&1 || { warn "jq required for benchmark scoring (brew install jq)."; return 1; }

    local model
    model=$(resolve_local_gguf)
    if [[ -z "$model" ]]; then
        warn "Cannot locate the .gguf file on disk. Start the service once to download it, or switch to a local model."
        return 1
    fi

    local default_ub
    if (( p <= 512 )); then
        default_ub="512"
    else
        default_ub="1024,2048"
    fi
    local ub_list="${BENCH_UBATCH:-$default_ub}"
    # Metal is always on — always sweep flash-attn 0 and 1.
    local fa_list="0,1"
    # When --fit is active P_NGL is unset; bench uses full offload (ngl=99).
    local ngl="${P_NGL:-99}"

    # Build ctk candidate list smartly: always include the service's current
    # P_CACHE_K so the sweep is never vacuously empty because the user's
    # running config wasn't in a hard-coded list. Add one comparison point
    # one quality tier above/below so the ranking is meaningful.
    local current_ctk="${P_CACHE_K:-f16}"
    local ctk_list="${BENCH_CTK:-}"
    if [[ -z "$ctk_list" ]]; then
        case "$current_ctk" in
            q4_0|q4_1|iq4_nl)  ctk_list="${current_ctk},q8_0" ;;
            q5_0|q5_1)          ctk_list="${current_ctk},q8_0" ;;
            q8_0)               ctk_list="${current_ctk},f16"  ;;
            f16|bf16)           ctk_list="${current_ctk},q8_0" ;;
            *)                  ctk_list="${current_ctk},q8_0" ;;
        esac
    fi

    # VRAM pre-filter: llama-bench allocates a KV cache of only (p+n) tokens,
    # NOT the service's full P_CTX. Using P_CTX (e.g. 131072) would produce a
    # wildly inflated estimate and incorrectly filter types that fit fine.
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
                warn "  ⊘ ctk=$ctk skipped (estimated ${est_total} GB > ${hw_vram} GB UMA at bench ctx=${ctx_bench})"
                continue
            fi
        fi
        candidates+=("$ctk")
    done
    if [[ "${#candidates[@]}" -eq 0 ]]; then
        warn "All candidate cache types exceed available unified memory even at bench context ${ctx_bench} tokens."
        warn "This is unusual — check that llama-bench and the Metal driver are healthy."
        warn "Override candidates with: export BENCH_CTK=q4_0"
        return 1
    fi

    local n_pass1 rep_equivs est_min
    n_pass1=${#candidates[@]}
    rep_equivs=$((n_pass1 + 3))
    est_min=$(bench_estimate_minutes "$p" "$n" "$rep_equivs" 1)

    # Warn about service config flags that bench ignores — not blockers, just
    # informational so the user knows what the sweep actually measures.
    if [[ "${P_FIT:-}" == "on" ]]; then
        warn "Note: --fit is active in the service but bench uses ngl=${ngl} (full offload)."
    fi

    info "Benchmark preset: ${C_BOLD}${preset}${C_RESET} — ${label}"
    info "Sweep: ubatch=[$ub_list] ctk=ctv=[$(IFS=,; echo "${candidates[*]}")] fa=[$fa_list] ngl=$ngl"
    info "Strategy: pass-1 triage (r=1, ${n_pass1} ctks) → rank → pass-2 winner (r=3)"
    info "Estimated runtime: ~${est_min} min"
    if [[ -n "${model_gb:-}" ]]; then
        info "Model: $model (${model_gb} GB)${hw_vram:+  Mac: ${hw_vram} GB UMA}"
        info "UMA filter used bench KV ctx=${ctx_bench} tokens (p+n), not service ctx ${P_CTX:-(unset)}"
    else
        info "Model: $model"
    fi
    info "Press Ctrl+C at any time to abort — llama-server will be restored."
    echo
    read -rp "Start sweep? [y/N]: " yn
    [[ "$yn" == [yY] ]] || { info "Cancelled."; return 0; }

    BENCH_STOPPED_SERVICE=0
    if llama_is_active; then
        warn "llama-server is running and holds the GPU. Stopping it for the sweep."
        llama_stop
        BENCH_STOPPED_SERVICE=1
    fi
    trap _bench_cleanup_on_interrupt INT TERM

    mkdir -p "$BENCH_DIR"
    local ts; ts=$(date +%s)
    local out="$BENCH_DIR/bench-${preset}-${ts}.json"

    printf '\n%s── Pass 1 — triage (r=1) ──%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
    local -a pass1_partials=()
    local tmp rc=0 cell_idx=0 cell_total="${#candidates[@]}"
    for ctk in "${candidates[@]}"; do
        cell_idx=$((cell_idx + 1))
        tmp=$(mktemp -t llama-bench-p1)
        if bench_run_cell "$tmp" "$model" "$p" "$n" "$ub_list" "$ctk" \
                          "$fa_list" "$ngl" 1 "$cell_idx" "$cell_total"; then
            pass1_partials+=("$tmp")
        else
            rc=1
        fi
    done

    if [[ "${#pass1_partials[@]}" -eq 0 ]]; then
        trap - INT TERM
        warn "All pass-1 runs failed. Check 'llama-bench -h' and your Metal build."
        [[ $BENCH_STOPPED_SERVICE -eq 1 ]] && { llama_start || true; BENCH_STOPPED_SERVICE=0; }
        return 1
    fi

    local pass1_merged; pass1_merged=$(mktemp -t llama-bench-p1-merged)
    jq -s 'add' "${pass1_partials[@]}" >"$pass1_merged"

    local pass1_scored; pass1_scored=$(bench_score_json "$p" "$n" <"$pass1_merged")
    if [[ -z "$pass1_scored" ]]; then
        trap - INT TERM
        warn "No scorable rows from pass 1."
        rm -f "${pass1_partials[@]}" "$pass1_merged"
        [[ $BENCH_STOPPED_SERVICE -eq 1 ]] && { llama_start || true; BENCH_STOPPED_SERVICE=0; }
        return 1
    fi

    printf '%sPass 1 ranked (triage, r=1 — rough, winner gets confirmed next):%s\n' \
        "$C_BOLD$C_CYAN" "$C_RESET"
    bench_display_table <<<"$pass1_scored"
    local top_ctk="$BENCH_WINNER_CTK"

    printf '\n%s── Pass 2 — winner confirmation (r=3, ctk=%s) ──%s\n' \
        "$C_BOLD$C_CYAN" "$top_ctk" "$C_RESET"
    local pass2_tmp; pass2_tmp=$(mktemp -t llama-bench-p2)
    local pass2_ok=1
    if ! bench_run_cell "$pass2_tmp" "$model" "$p" "$n" "$ub_list" "$top_ctk" \
                        "$fa_list" "$ngl" 3 1 1; then
        pass2_ok=0
        rc=1
    fi

    trap - INT TERM

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
        [[ $BENCH_STOPPED_SERVICE -eq 1 ]] && { llama_start || true; BENCH_STOPPED_SERVICE=0; }
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
        llama_start || warn "Restart failed — use --rollback if needed."
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
            info "Winner not applied. Re-run 'macos-llama-reconfigure' later to revisit."
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
    local f base preset ts date_str
    for f in "${files[@]}"; do
        base=$(basename "$f" .json)
        preset=$(cut -d- -f2 <<<"$base")
        ts=$(cut -d- -f3 <<<"$base")
        # BSD date (macOS) uses -r; GNU date (Linux fallback) uses -d "@…".
        date_str=$(date -r "$ts" '+%Y-%m-%d %H:%M' 2>/dev/null \
                    || date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null \
                    || echo "$ts")
        printf '  [%s] %-10s  %s\n' "$date_str" "$preset" "$f"
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
            # `|| true` prevents set -e from exiting when run_benchmark_preset
            # returns 1 (e.g. all ctk candidates filtered, or user Ctrl+C).
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
#
# Rewriting ProgramArguments in-place with PlistBuddy: Delete the whole
# array, re-Add it as an array, then Add one :0 string, :1 string, …
# per argv entry. Doing this on a temp copy lets us plutil -lint before
# clobbering the live plist.

_append_args_to_plist() {
    local plist="$1"; shift
    local -a argv=("$@")
    local i
    /usr/libexec/PlistBuddy -c "Delete :ProgramArguments" "$plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$plist" >/dev/null
    for (( i=0; i<${#argv[@]}; i++ )); do
        /usr/libexec/PlistBuddy -c "Add :ProgramArguments:$i string ${argv[$i]}" "$plist" >/dev/null
    done
}

apply_changes() {
    local dry="${1:-}"

    if [[ "$dry" != "dry" && "$P_MODEL_MODE" == "hf" && -n "$P_HF_FILE" ]]; then
        if ! hf_check_reachable "$P_HF_REPO" "$P_HF_FILE"; then
            warn "Aborting apply — model not reachable."
            return 1
        fi
        ok "Model reachable on HuggingFace."
        info "llama-server will download on first start if not already cached. Watch logs with:"
        info "  tail -f $(pb 'Print :StandardErrorPath' 2>/dev/null || echo '<StandardErrorPath>')"
    fi

    # If edit_raw wrote directly into P_ARGV, use that; else serialize.
    if [[ -z "${P_RAW_OVERRIDE:-}" ]]; then
        serialize_argv
    else
        P_NEW_ARGV=( "${P_ARGV[@]}" )
    fi

    # Validate each arg — catches things like accidentally-embedded
    # angle brackets from a shell-glob or a pasted command line.
    local a
    for a in "${P_NEW_ARGV[@]}"; do
        validate_arg_string "$a" || return 1
    done

    printf '\n%s── Proposed command line ──%s\n  %s\n\n' \
        "$C_BOLD$C_CYAN" "$C_RESET" "$(format_argv_line)"

    if [[ "$dry" == "dry" ]]; then
        info "(dry run — no changes written)"
        return 0
    fi

    read -rp "Apply and restart? [y/N]: " ans
    if [[ "$ans" != [yY] ]]; then
        info "Cancelled — nothing written."
        return 0
    fi

    local new_plist; new_plist=$(mktemp -t llama-server-plist)
    cp -a "$PLIST_FILE" "$new_plist"
    _append_args_to_plist "$new_plist" "${P_NEW_ARGV[@]}"

    info "Validating plist with plutil -lint…"
    if ! plutil -lint "$new_plist" >/dev/null; then
        warn "plist failed validation — edit cancelled."
        rm -f "$new_plist"
        return 1
    fi

    info "Stopping llama-server…"
    llama_stop

    info "Backing up current plist → ${BAK_FILE}"
    cp -a "$PLIST_FILE" "$BAK_FILE"

    info "Installing new plist…"
    install -m 644 -o root -g wheel "$new_plist" "$PLIST_FILE"
    rm -f "$new_plist"

    info "Bootstrapping LaunchDaemon and kickstarting…"
    # Snapshot exit-reason fingerprint BEFORE we poke the service.
    local baseline_exit
    baseline_exit=$(llama_exit_count)

    if ! launchctl bootstrap system "$PLIST_FILE" 2>/dev/null; then
        warn "bootstrap failed — inspect with: launchctl print system/${PLIST_LABEL}"
        warn "Rollback available: macos-llama-reconfigure --rollback"
        return 1
    fi
    launchctl kickstart -k "system/${PLIST_LABEL}" 2>/dev/null || true

    # Model load can take 10-15s for big GGUFs. Wait, then confirm the
    # exit fingerprint hasn't rolled over (KeepAlive=true masks quick
    # crash-restart cycles from a single llama_is_active probe).
    info "Watching service for 15s to confirm it stays up…"
    sleep 15

    local active_state="inactive" exit_now
    if llama_is_active; then active_state="active"; fi
    exit_now=$(llama_exit_count)

    if [[ "$active_state" != "active" ]] || [[ "$exit_now" != "$baseline_exit" ]]; then
        warn "Service is unstable (active=$active_state, exit fingerprint rolled)."
        warn "Last 40 log lines:"
        llama_log_tail 40 >&2 || true
        warn "Rollback available: macos-llama-reconfigure --rollback"
        return 1
    fi

    ok "llama-server is stable (no crash-restarts in 15s after apply)."
    ok "Applied. Watch startup with:"
    ok "  tail -f $(pb 'Print :StandardErrorPath' 2>/dev/null || echo '<StandardErrorPath>')"
}

rollback_plist() {
    [[ -f "$BAK_FILE" ]] || die "No backup at ${BAK_FILE} — nothing to roll back to."
    info "Stopping llama-server…"
    llama_stop
    info "Restoring ${PLIST_FILE} from ${BAK_FILE}"
    install -m 644 -o root -g wheel "$BAK_FILE" "$PLIST_FILE"
    # Re-parse so PLIST_LABEL reflects the restored file (in case the
    # label itself was edited between backups).
    parse_plist_file
    info "Bootstrapping restored plist…"
    launchctl bootstrap system "$PLIST_FILE" 2>/dev/null || true
    launchctl kickstart -k "system/${PLIST_LABEL}" 2>/dev/null || true
    ok "Rolled back. Service status:"
    launchctl print "system/${PLIST_LABEL}" 2>/dev/null | head -20 || true
}

# ─── Menu ──────────────────────────────────────────────────────────────

main_menu() {
    while true; do
        clear
        printf '%s── macos-llama-reconfigure %s ─────────────────────────────%s\n' \
            "$C_BOLD$C_CYAN" "$LLAMA_RECONFIGURE_VERSION" "$C_RESET"
        show_current

        # Metal is always on → ngl=6, mlock=7, dio=8.
        printf ' [m] Model   [l] Listen   [0] Raw editor   [b] Benchmark & optimize\n'
        printf ' [a] Apply and restart   [d] Dry-run   [r] Rollback   [q] Quit\n'
        printf ' [1-8] Change\n'
        printf '\n'

        local choice; read -rp '> ' choice
        case "$choice" in
            1) edit_context    ;;
            2) edit_cache      ;;
            3) edit_n_cpu_moe  ;;
            4) edit_flash      ;;
            5) edit_ubatch     ;;
            6) edit_ngl        ;;
            7) edit_mlock      ;;
            8) edit_dio        ;;
            m|M) edit_model    ;;
            l|L) edit_listen   ;;
            0)   edit_raw      ;;
            b|B) bench_menu    ;;
            a|A) apply_changes && return 0 ;;
            d|D) apply_changes dry ;;
            r|R) rollback_plist && return 0 ;;
            q|Q) info "Exit — no changes written."; return 0 ;;
            *)   warn "Unknown option." ;;
        esac
    done
}

# ─── Entry point ───────────────────────────────────────────────────────

main() {
    require_plistbuddy

    if [[ $# -eq 0 ]]; then
        ensure_root "$@"
        require_plist_file
        parse_plist_file
        main_menu
        return
    fi

    case "$1" in
        --help|-h)    show_usage; return 0 ;;
        --version|-V) echo "macos-llama-reconfigure ${LLAMA_RECONFIGURE_VERSION}"; return 0 ;;
    esac

    ensure_root "$@"
    require_plist_file
    parse_plist_file

    case "$1" in
        --show)       show_current ;;
        --dry-run)    main_menu; apply_changes dry ;;
        --rollback)   rollback_plist ;;
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
