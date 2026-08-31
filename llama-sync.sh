#!/usr/bin/env bash
# llama-sync — sync .gguf model files between two servers (flat, no folders).
#
# Runs on .135.  Models are stored as flat .gguf files in LOCAL_DIR.
#
# Usage:
#   llama-sync pull          # copy new .gguf files from .132 → .135 (one-shot)
#   llama-sync push          # copy all .gguf files from .135 → .132 (post-wipe)
#   llama-sync daemon        # pull every 60 s (run by systemd service)
#   llama-sync status        # list .gguf files on both servers
#   llama-sync install       # install & enable the systemd service
#
# Deploy (from your Mac):
#   scp llama-sync.sh chris@192.168.1.135:~/llama-sync.sh
#
# First-time setup on .135 (run as chris):
#   ssh-keygen -t ed25519 -f ~/.ssh/llama_sync -N ""
#   ssh-copy-id -i ~/.ssh/llama_sync.pub openclaw@192.168.1.132
#   sudo ~/llama-sync.sh install
#
# After wiping .132:
#   ssh-copy-id -i ~/.ssh/llama_sync.pub openclaw@192.168.1.132
#   llama-sync push

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────

SOURCE_HOST="192.168.1.132"
SOURCE_USER="openclaw"
SOURCE_DIR="/home/openclaw/llama.cpp/models"
LOCAL_DIR="/home/chris/models"
SSH_KEY="/home/chris/.ssh/llama_sync"
POLL_INTERVAL=60

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)

# ── Helpers ────────────────────────────────────────────────────────────────

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# List .gguf model files on the remote — returns full remote paths, one per line.
# Excludes ggml-vocab-* (default llama.cpp build artefacts, not downloaded models).
# -L follows symlinks so HF cache snapshot entries (symlinks → blobs) are included.
list_remote_gguf() {
    ssh "${SSH_OPTS[@]}" "${SOURCE_USER}@${SOURCE_HOST}" \
        "find -L ${SOURCE_DIR} -maxdepth 5 -name '*.gguf' ! -name 'ggml-vocab-*' -type f"
}

# ── Commands ───────────────────────────────────────────────────────────────

cmd_pull() {
    log "Checking ${SOURCE_HOST} for new models…"
    mkdir -p "$LOCAL_DIR"

    local remote_list
    if ! remote_list=$(list_remote_gguf); then
        log ".132 unreachable — will retry next cycle."
        return 0
    fi

    [[ -z "$remote_list" ]] && { log "No models on .132."; return 0; }

    local copied=0
    while IFS= read -r remote_path; do
        local fname; fname=$(basename "$remote_path")
        if [[ -f "${LOCAL_DIR}/${fname}" ]]; then
            log "Skipping ${fname} (already present)."
            continue
        fi

        # Show file size so the user knows what's coming.
        local remote_bytes
        remote_bytes=$(ssh "${SSH_OPTS[@]}" "${SOURCE_USER}@${SOURCE_HOST}" \
            "stat -c%s '${remote_path}'" 2>/dev/null || echo 0)
        local gb=$(( remote_bytes / 1073741824 ))

        log "Copying ${fname} (${gb} GB)…"
        # --partial keeps the incomplete file on failure so the next run
        # resumes rather than starting over.
        # nice -n 10 keeps the transfer from starving other processes.
        nice -n 10 rsync -a --copy-links --partial --progress \
            --no-owner --no-group \
            -e "ssh ${SSH_OPTS[*]}" \
            "${SOURCE_USER}@${SOURCE_HOST}:${remote_path}" \
            "${LOCAL_DIR}/${fname}" \
            && (( copied++ )) \
            || log "  ✗ failed — will retry next run (check: sudo chown openclaw: '${remote_path}' on .132)"
    done <<< "$remote_list"

    if (( copied > 0 )); then
        log "Done — copied ${copied} new model(s)."
    else
        log "Nothing new."
    fi
}

cmd_push() {
    log "Pushing all models from .135 → ${SOURCE_HOST}…"

    ssh "${SSH_OPTS[@]}" "${SOURCE_USER}@${SOURCE_HOST}" \
        "mkdir -p ${SOURCE_DIR}" || {
        log "ERROR: cannot reach ${SOURCE_HOST}"; return 1
    }

    local copied=0
    while IFS= read -r -d '' local_path; do
        local fname; fname=$(basename "$local_path")
        log "Pushing ${fname}…"
        rsync -a --progress --no-owner --no-group \
            -e "ssh ${SSH_OPTS[*]}" \
            "$local_path" \
            "${SOURCE_USER}@${SOURCE_HOST}:${SOURCE_DIR}/${fname}" \
            && (( copied++ )) \
            || log "  ✗ failed — skipping"
    done < <(find "$LOCAL_DIR" -maxdepth 1 -name '*.gguf' ! -name 'ggml-vocab-*' -type f -print0)

    log "Done — pushed ${copied} model(s)."
}

cmd_daemon() {
    log "llama-sync daemon started (interval: ${POLL_INTERVAL}s)."
    while true; do
        cmd_pull
        sleep "$POLL_INTERVAL"
    done
}

cmd_status() {
    printf '\n.135 (local) — %s\n' "$LOCAL_DIR"
    find "$LOCAL_DIR" -maxdepth 1 -name '*.gguf' ! -name 'ggml-vocab-*' -type f \
        -printf '  %-60f  %s bytes\n' \
        | awk '{printf "  %-60s  %5.1f GB\n", $1, $NF/1073741824}' \
        | sort || printf '  (none)\n'

    printf '\n.132 (remote) — %s\n' "$SOURCE_DIR"
    list_remote_gguf 2>/dev/null \
        | while IFS= read -r f; do printf '  %s\n' "$(basename "$f")"; done \
        | sort \
        || printf '  (unreachable)\n'
    printf '\n'
}

cmd_install() {
    local svc=/etc/systemd/system/llama-sync.service
    install -m 755 "$(readlink -f "$0")" /usr/local/bin/llama-sync
    printf 'Installed /usr/local/bin/llama-sync\n'

    cat >"$svc" <<EOF
[Unit]
Description=llama.cpp model sync from .132
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=chris
ExecStart=/usr/local/bin/llama-sync daemon
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now llama-sync
    printf 'Service enabled. Logs: journalctl -u llama-sync -f\n'
}

# ── Entry point ────────────────────────────────────────────────────────────

case "${1:-pull}" in
    pull)    cmd_pull    ;;
    push)    cmd_push    ;;
    daemon)  cmd_daemon  ;;
    status)  cmd_status  ;;
    install) cmd_install ;;
    *) printf 'Usage: %s [pull|push|daemon|status|install]\n' "$(basename "$0")" >&2; exit 1 ;;
esac
