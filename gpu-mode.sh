#!/bin/bash
#
# gpu-mode — switch a single-GPU box between two competing workloads.
#
#   llm  → llama.cpp owns the full VRAM (e.g. for local inference / agents).
#   av   → TTS + STT services (NIM Parakeet ASR, F5 / Magpie TTS, …)
#          own the VRAM (e.g. for voice agents).
#
# These two stacks together exceed a 24 GB card, so they have to be
# exclusive. This script makes the swap one command, idempotent, and
# verifiable — stops the inactive side, starts the active side, prints
# nvidia-smi so you can confirm VRAM moved.
#
# AV side is systemd-first. The default
#   AV_SYSTEMD_SERVICES="local-stt-nim,local-tts-backend"
# matches a mentorbot install where the NIM ASR docker container is
# managed by a systemd wrapper unit (so its `Restart=always` policy
# doesn't fight `docker compose down`), and the F5-TTS / voice-cloning
# backend runs as a native Python FastAPI process.
#
# AV_COMPOSE_FILE is an OPTIONAL secondary mechanism for installs that
# also have a separate compose stack on the AV side. Empty default.
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
# Comma-separated systemd units that own the AV side of the GPU.
# Default matches a mentorbot install: a NIM ASR wrapper unit (which
# in turn manages the parakeet docker container) plus a native
# Python FastAPI TTS backend. Add / remove units as your stack grows
# (e.g. when a Magpie TTS unit lands).
AV_SYSTEMD_SERVICES="${AV_SYSTEMD_SERVICES:-local-stt-nim,local-tts-backend}"
# Optional: a docker compose file whose services should ALSO be torn
# down/up. Empty by default — most installs run everything under
# systemd. Set to a path to opt in.
AV_COMPOSE_FILE="${AV_COMPOSE_FILE:-}"
# Comma-separated compose profiles when AV_COMPOSE_FILE is set.
# Empty = no --profile flag.
AV_COMPOSE_PROFILES="${AV_COMPOSE_PROFILES:-}"
# How long to wait for llama-server / AV services to come up before
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

# ─── Compose invocation (optional) ─────────────────────────────────────
# Used only when AV_COMPOSE_FILE is set. Builds the right --profile
# flags from AV_COMPOSE_PROFILES. Empty string → no flag.
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

# Robust "does this unit exist on this host" check. Uses `systemctl cat`
# which succeeds iff systemd can find + read the unit file. Earlier
# versions of this script grep'd `systemctl list-unit-files --no-legend`
# output, but that output format drifts across systemd versions and was
# missing some installed units on the openclaw box (false negatives).
unit_exists() {
    systemctl cat --no-pager "$1" >/dev/null 2>&1
}

av_compose_present() {
    [[ -n "$AV_COMPOSE_FILE" && -f "$AV_COMPOSE_FILE" ]]
}

# Split comma-separated AV_SYSTEMD_SERVICES into an array. Empty
# entries (from trailing commas / empty default) are filtered out.
av_systemd_units() {
    local IFS=','
    local u
    for u in $AV_SYSTEMD_SERVICES; do
        [[ -n "$u" ]] && printf '%s\n' "$u"
    done
}

av_any_running() {
    local u
    while read -r u; do
        [[ -z "$u" ]] && continue
        systemctl is-active --quiet "$u" 2>/dev/null && return 0
    done < <(av_systemd_units)
    if av_compose_present; then
        compose ps --quiet --status running 2>/dev/null | grep -q .
    else
        return 1
    fi
}

# ─── Subcommands ───────────────────────────────────────────────────────
cmd_llm() {
    info "Switching to LLM mode (llama.cpp owns the GPU)…"

    # Stop systemd-managed AV services. They each own their own docker
    # containers / Python processes; `systemctl stop` will tear those
    # down and free VRAM. Restart=always policies are honored on
    # explicit stop (only fires on crashes).
    local u stopped_any=0
    while read -r u; do
        [[ -z "$u" ]] && continue
        if unit_exists "$u"; then
            if systemctl is-active --quiet "$u" 2>/dev/null; then
                info "Stopping $u…"
                sudo_if_needed systemctl stop "$u" \
                    || warn "systemctl stop $u returned non-zero — VRAM may not have been released."
                stopped_any=1
            else
                info "$u already inactive — skipping."
            fi
        else
            warn "$u not installed — skipping."
        fi
    done < <(av_systemd_units)

    # Optional compose stack — only if explicitly configured.
    if av_compose_present; then
        info "Stopping compose AV containers (compose down)…"
        # `down` removes containers entirely so VRAM is fully released.
        # `stop` would leave them around with VRAM still pinned in some
        # NIM images that keep a handle in the stopped state.
        if ! compose down --remove-orphans; then
            warn "compose down returned non-zero — some containers may still hold VRAM."
            warn "Inspect with: docker ps  and  nvidia-smi"
        fi
        stopped_any=1
    fi

    if [[ "$stopped_any" == 0 ]]; then
        info "No AV services were running — proceeding to start llama-server."
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

    if unit_exists "$LLAMA_SERVICE"; then
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

    # Start systemd-managed AV services. First start of the NIM
    # ASR unit can take 60-180s while TensorRT compiles its engines;
    # subsequent starts with cached engines are <30s.
    local u started_any=0
    while read -r u; do
        [[ -z "$u" ]] && continue
        if unit_exists "$u"; then
            info "Starting $u…"
            sudo_if_needed systemctl start "$u" \
                || warn "systemctl start $u failed. Inspect: journalctl -u $u -n 50"
            started_any=1
        else
            warn "$u not installed on this host — skipping."
        fi
    done < <(av_systemd_units)

    # Optional compose stack.
    if av_compose_present; then
        info "Starting compose AV containers… first run can take 60-180s for NIM TensorRT load."
        compose up -d \
            || warn "compose up returned non-zero. Inspect: docker compose -f $AV_COMPOSE_FILE logs"
        started_any=1
    fi

    if [[ "$started_any" == 0 ]]; then
        die "No AV services configured. Set AV_SYSTEMD_SERVICES and/or AV_COMPOSE_FILE."
    fi

    # Best-effort readiness — poll until every configured systemd unit
    # is `active` and (if compose is configured) every container is
    # running, or AV_READY_TIMEOUT_S elapses.
    local waited=0
    while (( waited < AV_READY_TIMEOUT_S )); do
        local all_up=1
        local u
        while read -r u; do
            [[ -z "$u" ]] && continue
            if ! systemctl is-active --quiet "$u" 2>/dev/null; then
                all_up=0
                break
            fi
        done < <(av_systemd_units)
        if [[ "$all_up" == 1 ]] && av_compose_present; then
            local total running
            total=$(compose ps --quiet 2>/dev/null | wc -l | tr -d ' ')
            running=$(compose ps --quiet --status running 2>/dev/null | wc -l | tr -d ' ')
            [[ "$total" -gt 0 && "$running" -eq "$total" ]] || all_up=0
        fi
        if [[ "$all_up" == 1 ]]; then
            ok "All AV services running (${waited}s)."
            break
        fi
        sleep 3
        waited=$(( waited + 3 ))
    done

    cmd_status
}

cmd_status() {
    printf '\n%s── GPU mode status ──%s\n' "$C_BOLD$C_CYAN" "$C_RESET"

    # LLM side. `systemctl is-active` prints the state to stdout AND
    # exits non-zero for anything other than `active` — including
    # `activating`, `failed`, `inactive`. We want the stdout value
    # either way, so `|| true` swallows the exit code without
    # appending an extra word to the capture.
    local llama_state
    llama_state="$(systemctl is-active "$LLAMA_SERVICE" 2>/dev/null || true)"
    printf '  %-26s %s\n' "$LLAMA_SERVICE:" "${llama_state:-unknown}"

    # AV systemd units — same capture trick as above.
    local u state
    while read -r u; do
        [[ -z "$u" ]] && continue
        state="$(systemctl is-active "$u" 2>/dev/null || true)"
        printf '  %-26s %s\n' "$u:" "${state:-unknown}"
    done < <(av_systemd_units)

    # Optional compose stack
    if av_compose_present; then
        printf '  Compose AV containers:\n'
        local ps_out
        ps_out="$(compose ps --format 'table {{.Name}}\t{{.Service}}\t{{.Status}}' 2>/dev/null || true)"
        if [[ -n "$ps_out" ]]; then
            printf '%s\n' "$ps_out" | sed 's/^/    /'
        else
            printf '    (no containers up)\n'
        fi
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
    elif av_any_running; then
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
  llm       Stop AV services, start ${LLAMA_SERVICE}. Idempotent.
  av        Stop ${LLAMA_SERVICE}, start AV services. Idempotent.
  status    Print which side is up + nvidia-smi summary.
  --help    Show this help.
  --version Print version.

${C_BOLD}CONFIG${C_RESET} (env vars; defaults shown)
  LLAMA_SERVICE=${LLAMA_SERVICE}
  AV_SYSTEMD_SERVICES=${AV_SYSTEMD_SERVICES}
  AV_COMPOSE_FILE=${AV_COMPOSE_FILE:-(unset — systemd-only)}
  AV_COMPOSE_PROFILES=${AV_COMPOSE_PROFILES:-(unset)}
  LLAMA_READY_TIMEOUT_S=${LLAMA_READY_TIMEOUT_S}
  AV_READY_TIMEOUT_S=${AV_READY_TIMEOUT_S}

${C_BOLD}EXAMPLES${C_RESET}
  $(basename "$0") llm                                            # switch to llama.cpp
  $(basename "$0") av                                             # switch to TTS+STT
  $(basename "$0") status                                         # what's running?
  AV_SYSTEMD_SERVICES=local-stt-nim $(basename "$0") av           # narrower set
  AV_COMPOSE_FILE=/path/to/compose.yml $(basename "$0") av        # add compose stack

${C_BOLD}NOTES${C_RESET}
  - AV side is systemd-first. AV_SYSTEMD_SERVICES is the list of
    units (comma-separated) that own GPU on the AV side. Each unit
    can in turn manage a docker container, a Python process, etc.
  - AV_COMPOSE_FILE is optional and only used if explicitly set.
  - Does NOT change boot defaults (systemctl enable / compose restart
    policies). The mode lasts until reboot or the next invocation.
  - Restart=always on a unit is honored across explicit systemctl
    stop (only fires on crashes), so the switch is robust.
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
