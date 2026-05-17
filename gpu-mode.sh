#!/bin/bash
#
# gpu-mode — switch a single-GPU box between two competing workloads.
#
#   llm  → llama.cpp owns the full VRAM (e.g. for local inference / agents).
#   av   → TTS + STT containers (Magpie NIM, Parakeet NIM, Fish OSS, …)
#          own the VRAM (e.g. for voice agents).
#
# These two stacks together exceed a 24 GB card, so they have to be
# exclusive. This script makes the swap one command, idempotent, and
# verifiable — stops the inactive side, starts the active side, prints
# nvidia-smi so you can confirm VRAM moved.
#
# Reboot behavior: this script does NOT change `systemctl enable` /
# compose-restart policies. The mode you're in lasts until you reboot
# or run the script again. If your boot defaults bring up the wrong
# stack, fix that with `systemctl disable` on whichever side or remove
# `restart: always` from compose; document the chosen default
# elsewhere. Keeping this script policy-free means it's safe to run
# repeatedly without surprising side effects.
#
# Secrets: llama-server.service and the AV containers each handle
# their own secret injection (systemd EnvironmentFile / drop-ins for
# the unit; compose env_file: for containers, optionally rendered by
# bws). This script just starts / stops them — it does NOT wrap
# commands in `bws run --`. If you add a new launch path that needs
# bws, put the wrapping in that path's launcher, not here.
#
# Part of the ubuntu-prep project:
#   https://github.com/chsbusch-dot/Ubuntu-AI-Tools-Install

set -euo pipefail

GPU_MODE_VERSION="1.0.0"

# ─── Configurable knobs (env-overridable) ──────────────────────────────
# Set these in /etc/default/gpu-mode or your shell rc if defaults don't
# match your install. Defaults assume the layout produced by
# ubuntu-prep-setup.sh + a mentorbot AV stack under ~/mentorbot.
LLAMA_SERVICE="${LLAMA_SERVICE:-llama-server}"
AV_COMPOSE_FILE="${AV_COMPOSE_FILE:-$HOME/mentorbot/stt-backend/remote/infra/docker-compose.yml}"
# Comma-separated list of compose profiles to activate in AV mode.
# Empty string = no --profile flag (uses default profile only).
AV_COMPOSE_PROFILES="${AV_COMPOSE_PROFILES:-nim}"
# How long to wait for llama-server / NIM ports to come up before
# giving up and just printing status. Tuned for typical NIM cold
# starts (TensorRT engine load can take 90-180s on first boot;
# subsequent starts with cached engines are <30s).
LLAMA_READY_TIMEOUT_S="${LLAMA_READY_TIMEOUT_S:-30}"
AV_READY_TIMEOUT_S="${AV_READY_TIMEOUT_S:-180}"

# ─── Colours / log helpers ─────────────────────────────────────────────
C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'
C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
C_CYAN=$'\e[36m'

info()    { printf '%s➜%s %s\n'   "$C_CYAN"   "$C_RESET" "$*"; }
ok()      { printf '%s✓%s %s\n'   "$C_GREEN"  "$C_RESET" "$*"; }
warn()    { printf '%s⚠%s %s\n'   "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()     { printf '%s✗%s %s\n'   "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }

# ─── Privilege helper ──────────────────────────────────────────────────
# Only systemctl needs root. Docker uses the user's group membership.
# Re-execing the whole script under sudo would force the user to
# enter their password even for `gpu-mode status` (read-only), so we
# wrap per-call instead.
sudo_if_needed() {
    if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# ─── Compose invocation ────────────────────────────────────────────────
# Builds the right --profile flags from AV_COMPOSE_PROFILES. Empty
# string → no flag, so users with a single-profile compose file don't
# need to set anything.
compose() {
    local -a profile_flags=()
    if [[ -n "$AV_COMPOSE_PROFILES" ]]; then
        local IFS=','
        for p in $AV_COMPOSE_PROFILES; do
            [[ -n "$p" ]] && profile_flags+=("--profile" "$p")
        done
    fi
    docker compose -f "$AV_COMPOSE_FILE" "${profile_flags[@]}" "$@"
}

# ─── Mode predicates ───────────────────────────────────────────────────
llama_is_active() {
    systemctl is-active --quiet "$LLAMA_SERVICE" 2>/dev/null
}

av_compose_present() {
    [[ -f "$AV_COMPOSE_FILE" ]]
}

# ─── Subcommands ───────────────────────────────────────────────────────
cmd_llm() {
    info "Switching to LLM mode (llama.cpp owns the GPU)…"

    if av_compose_present; then
        info "Stopping AV containers (compose down)…"
        # `down` removes containers entirely so VRAM is fully released.
        # `stop` would leave them around with VRAM still pinned in some
        # NIM images that keep a handle in the stopped state.
        if ! compose down --remove-orphans; then
            warn "compose down returned non-zero — some containers may still hold VRAM."
            warn "Inspect with: docker ps  and  nvidia-smi"
        fi
    else
        warn "AV compose file not found at $AV_COMPOSE_FILE — nothing to tear down."
    fi

    info "Starting $LLAMA_SERVICE…"
    sudo_if_needed systemctl start "$LLAMA_SERVICE" \
        || die "systemctl start $LLAMA_SERVICE failed. Inspect: journalctl -u $LLAMA_SERVICE -n 50"

    local waited=0
    while (( waited < LLAMA_READY_TIMEOUT_S )); do
        if llama_is_active; then
            ok "$LLAMA_SERVICE is active (${waited}s)."
            break
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    if ! llama_is_active; then
        warn "$LLAMA_SERVICE did not become active within ${LLAMA_READY_TIMEOUT_S}s."
        warn "Tail logs: journalctl -u $LLAMA_SERVICE -f"
    fi

    cmd_status
}

cmd_av() {
    info "Switching to AV mode (TTS + STT own the GPU)…"

    if systemctl list-unit-files --no-legend 2>/dev/null | grep -q "^${LLAMA_SERVICE}\.service"; then
        if llama_is_active; then
            info "Stopping $LLAMA_SERVICE…"
            sudo_if_needed systemctl stop "$LLAMA_SERVICE" \
                || warn "systemctl stop returned non-zero — VRAM may not have been released."
        else
            info "$LLAMA_SERVICE already inactive — skipping stop."
        fi
    else
        warn "$LLAMA_SERVICE not installed on this host — nothing to stop."
    fi

    av_compose_present \
        || die "AV compose file not found: $AV_COMPOSE_FILE  (override with AV_COMPOSE_FILE=… )"

    info "Starting AV containers… first run can take 60-180s for NIM TensorRT load."
    compose up -d \
        || die "compose up failed. Inspect: docker compose -f $AV_COMPOSE_FILE logs"

    # Best-effort readiness — just poll `compose ps` for "Up" lines.
    # We don't probe each container's HTTP port because the set is
    # configurable (which profiles → which services); the compose
    # health checks (if defined in the compose file) are the source
    # of truth for "ready".
    local waited=0
    while (( waited < AV_READY_TIMEOUT_S )); do
        local total running
        total=$(compose ps --quiet 2>/dev/null | wc -l | tr -d ' ')
        running=$(compose ps --quiet --status running 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$total" -gt 0 && "$running" -eq "$total" ]]; then
            ok "All ${running} AV containers running (${waited}s)."
            break
        fi
        sleep 3
        waited=$(( waited + 3 ))
    done

    cmd_status
}

cmd_status() {
    printf '\n%s── GPU mode status ──%s\n' "$C_BOLD$C_CYAN" "$C_RESET"

    # systemd / llama side
    local llama_state
    llama_state="$(systemctl is-active "$LLAMA_SERVICE" 2>/dev/null || echo 'inactive')"
    printf '  %-22s %s\n' "$LLAMA_SERVICE:" "$llama_state"

    # docker / AV side
    if av_compose_present; then
        printf '  AV containers:\n'
        # Trailing `|| true` so an empty stack doesn't break set -e.
        local ps_out
        ps_out="$(compose ps --format 'table {{.Name}}\t{{.Service}}\t{{.Status}}' 2>/dev/null || true)"
        if [[ -n "$ps_out" ]]; then
            printf '%s\n' "$ps_out" | sed 's/^/    /'
        else
            printf '    (no containers up)\n'
        fi
    else
        printf '  AV compose:            (not found at %s)\n' "$AV_COMPOSE_FILE"
    fi

    # GPU side — only if nvidia-smi is on PATH (skip on CPU-only test boxes)
    if command -v nvidia-smi >/dev/null 2>&1; then
        printf '  GPU:\n'
        nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu \
                   --format=csv,noheader 2>/dev/null \
            | sed 's/^/    /'
    fi

    # Best-guess mode label so the operator gets a one-word answer.
    local mode=""
    if [[ "$llama_state" == "active" ]]; then
        mode="LLM"
    elif av_compose_present && compose ps --quiet --status running 2>/dev/null | grep -q .; then
        mode="AV"
    else
        mode="idle (neither side running)"
    fi
    printf '\n  %sCurrent mode%s: %s\n\n' "$C_BOLD" "$C_RESET" "$mode"
}

# ─── Usage ─────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${C_BOLD}gpu-mode ${GPU_MODE_VERSION}${C_RESET} — switch a single-GPU box between llama.cpp and TTS/STT.

${C_BOLD}USAGE${C_RESET}
  $(basename "$0") <command>

${C_BOLD}COMMANDS${C_RESET}
  llm       Stop AV containers, start ${LLAMA_SERVICE}. Idempotent.
  av        Stop ${LLAMA_SERVICE}, start AV containers. Idempotent.
  status    Print which side is up + nvidia-smi summary.
  --help    Show this help.
  --version Print version.

${C_BOLD}CONFIG${C_RESET} (env vars; defaults shown)
  LLAMA_SERVICE=${LLAMA_SERVICE}
  AV_COMPOSE_FILE=${AV_COMPOSE_FILE}
  AV_COMPOSE_PROFILES=${AV_COMPOSE_PROFILES}
  LLAMA_READY_TIMEOUT_S=${LLAMA_READY_TIMEOUT_S}
  AV_READY_TIMEOUT_S=${AV_READY_TIMEOUT_S}

${C_BOLD}EXAMPLES${C_RESET}
  $(basename "$0") llm                            # switch to llama.cpp
  $(basename "$0") av                             # switch to TTS+STT
  $(basename "$0") status                         # what's running?
  AV_COMPOSE_PROFILES=nim,fish $(basename "$0") av   # extra compose profile

${C_BOLD}NOTES${C_RESET}
  - Does NOT change boot defaults (systemctl enable / compose restart
    policies). The mode lasts until reboot or the next invocation.
  - Run \`status\` after \`llm\`/\`av\` to confirm VRAM moved correctly.
  - First AV start after a host reboot can take 60-180s for NIM
    TensorRT engine load; AV_READY_TIMEOUT_S=${AV_READY_TIMEOUT_S} accounts for this.
EOF
}

# ─── Entrypoint ────────────────────────────────────────────────────────
case "${1:-}" in
    llm)              cmd_llm ;;
    av)               cmd_av ;;
    status)           cmd_status ;;
    -v|--version)     printf 'gpu-mode %s\n' "$GPU_MODE_VERSION" ;;
    -h|--help)        usage ;;
    "")               usage; exit 2 ;;
    *)                warn "Unknown command: $1"; usage; exit 2 ;;
esac
