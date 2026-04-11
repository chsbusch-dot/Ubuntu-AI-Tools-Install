#!/bin/bash


# Source ESXi variables from .env.secrets if available
if [ -f "$HOME/.env.secrets" ]; then
    source "$HOME/.env.secrets"
fi

# --- ESXi Configuration ---
ESXI_HOST=${ESXI_HOST:-"192.168.1.60"}
ESXI_USER=${ESXI_USER:-"root"}
VMID="290"
SNAPID="5"

# --- Guest VM Configuration ---
GUEST_IP=${ESXI_GUEST:-"192.168.1.132"}
GUEST_USER="chris"
GUEST_PASS="99Marlboro"

# Require sshpass and nc
for cmd in sshpass nc; do
    if ! command -v $cmd &> /dev/null; then
        echo "❌ Required command '$cmd' is missing. Install with: brew install sshpass netcat"
        exit 1
    fi
done

if [ -n "$ESXI_PASSWORD" ]; then
    export SSHPASS="$ESXI_PASSWORD"
    ESXI_SSH_CMD="sshpass -e ssh -T -o StrictHostKeyChecking=accept-new"
else
    ESXI_SSH_CMD="ssh -T"
fi




echo "What would you like to do?"
echo "1. Revert VM and upload new ubuntu-prep-setup.sh"
echo "2. Just upload new ubuntu-prep-setup.sh (skip revert)"
read -p "Your choice [1/2]: " choice

if [[ "$choice" == "1" ]]; then
    echo "🛑 Gracefully shutting down VM $VMID..."
    $ESXI_SSH_CMD "${ESXI_USER}@${ESXI_HOST}" "vim-cmd vmsvc/power.shutdown $VMID" >/dev/null 2>&1 || true

    echo "⏳ Waiting for VM to power off..."
    POWERED_OFF=0
    for i in {1..30}; do
        POWER_STATE=$($ESXI_SSH_CMD "${ESXI_USER}@${ESXI_HOST}" "vim-cmd vmsvc/power.getstate $VMID")
        if echo "$POWER_STATE" | grep -q "Powered off"; then
            POWERED_OFF=1
            break
        fi
        sleep 2
    done

    if [ $POWERED_OFF -eq 0 ]; then
        echo "⚠️ Graceful shutdown timed out. Forcing power off..."
        $ESXI_SSH_CMD "${ESXI_USER}@${ESXI_HOST}" "vim-cmd vmsvc/power.off $VMID" >/dev/null 2>&1 || true
        sleep 3
    fi

    echo "🔄 Resetting VM $VMID to snapshot $SNAPID..."
    $ESXI_SSH_CMD "${ESXI_USER}@${ESXI_HOST}" "vim-cmd vmsvc/snapshot.revert $VMID $SNAPID 0 && sleep 5 && vim-cmd vmsvc/power.on $VMID"

    echo "⏳ Waiting for VM to boot and SSH to become available..."
    sleep 10
    SSH_UP=0
    for i in {1..30}; do
        if nc -z -w 1 "$GUEST_IP" 22 2>/dev/null; then
            echo "✅ SSH is up!"
            sleep 5 # Give the OS a few more seconds to start background services
            SSH_UP=1
            break
        fi
        sleep 2
    done

    if [ $SSH_UP -eq 0 ]; then
        echo "❌ VM failed to boot in time."
        exit 1
    fi
fi

echo "📤 Copying ubuntu-prep-setup.sh to guest..."
sshpass -p "$GUEST_PASS" scp -o StrictHostKeyChecking=accept-new ubuntu-prep-setup.sh "${GUEST_USER}@${GUEST_IP}:/home/${GUEST_USER}/"

echo "📤 Copying test.sh and validate-vram-fit.sh to guest..."
sshpass -p "$GUEST_PASS" scp -o StrictHostKeyChecking=accept-new test.sh validate-vram-fit.sh "${GUEST_USER}@${GUEST_IP}:/home/${GUEST_USER}/"

echo "📤 Copying tests/ directory to guest..."
sshpass -p "$GUEST_PASS" scp -r -o StrictHostKeyChecking=accept-new tests "${GUEST_USER}@${GUEST_IP}:/home/${GUEST_USER}/"

echo "⚙️ Making scripts executable..."
sshpass -p "$GUEST_PASS" ssh -o StrictHostKeyChecking=accept-new "${GUEST_USER}@${GUEST_IP}" "chmod +x /home/${GUEST_USER}/ubuntu-prep-setup.sh /home/${GUEST_USER}/test.sh /home/${GUEST_USER}/validate-vram-fit.sh"

echo "📤 Copying .env.secrets.template to ~/.env.secrets on guest..."
sshpass -p "$GUEST_PASS" scp -o StrictHostKeyChecking=accept-new .env.secrets.template "${GUEST_USER}@${GUEST_IP}:/home/${GUEST_USER}/.env.secrets"

echo "⚙️ Securing .env.secrets permissions on guest..."
sshpass -p "$GUEST_PASS" ssh -o StrictHostKeyChecking=accept-new "${GUEST_USER}@${GUEST_IP}" "chmod 600 /home/${GUEST_USER}/.env.secrets"

echo "📦 Installing shellcheck, shfmt, bats, kcov on guest..."
sshpass -p "$GUEST_PASS" ssh -o StrictHostKeyChecking=accept-new "${GUEST_USER}@${GUEST_IP}" "echo \"$GUEST_PASS\" | sudo -S bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y shellcheck shfmt bats'"



echo "🧪 Running test.sh on guest (full run: syntax + lint + VRAM + network)..."
sshpass -p "$GUEST_PASS" ssh -o StrictHostKeyChecking=accept-new "${GUEST_USER}@${GUEST_IP}" "cd /home/${GUEST_USER} && bash test.sh --install"

echo "🎉 Files are copied! Logging you in now..."
sshpass -p "$GUEST_PASS" ssh -o StrictHostKeyChecking=accept-new "${GUEST_USER}@${GUEST_IP}"

