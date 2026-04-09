#!/bin/bash
#
# Script to log into an ESXi host via SSH and reset a VM to its last snapshot.
# 
# Note: This script assumes you have SSH keys set up for passwordless login 
# to the ESXi host. If not, it can pull ESXI_PASSWORD from ~/.env.secrets 
# (requires 'sshpass' to be installed) or it will prompt you.

if [ -f "$HOME/.env.secrets" ]; then
    source "$HOME/.env.secrets"
fi

if [ "$#" -eq 3 ]; then
    ESXI_HOST=$1
    ESXI_USER=$2
    TARGET_VM=$3
elif [ "$#" -eq 1 ]; then
    TARGET_VM=$1
    if [ -z "$ESXI_HOST" ] || [ -z "$ESXI_USER" ]; then
        echo "❌ Error: ESXI_HOST or ESXI_USER not set in ~/.env.secrets."
        echo "Usage: $0 <esxi_host> <esxi_user> <vm_name_or_ip>"
        echo "   Or: $0 <vm_name_or_ip> (if host and user are in ~/.env.secrets)"
        exit 1
    fi
elif [ "$#" -eq 0 ] && [ -n "$ESXI_GUEST" ] && [ -n "$ESXI_HOST" ] && [ -n "$ESXI_USER" ]; then
    TARGET_VM="$ESXI_GUEST"
else
    echo "Usage: $0 <esxi_host> <esxi_user> <vm_name_or_ip>"
    echo "   Or: $0 <vm_name_or_ip> (if host and user are in ~/.env.secrets)"
    echo "   Or: $0 (if host, user, and guest are in ~/.env.secrets)"
    echo "Example: $0 192.168.1.100 root my-test-vm"
    echo "         $0 10.0.0.52"
    exit 1
fi

echo "Connecting to $ESXI_HOST as $ESXI_USER to reset target: $TARGET_VM..."

if [ -n "$ESXI_PASSWORD" ]; then
    if ! command -v sshpass &> /dev/null; then
        echo "⚠️ 'sshpass' utility is not installed but required for password authentication."
        echo "Attempting to install 'sshpass' automatically..."
        if sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y sshpass; then
            echo "✅ 'sshpass' installed successfully."
        else
            echo "❌ Error: Failed to install 'sshpass'. Please install it manually by running: sudo apt-get install -y sshpass"
            exit 1
        fi
    fi
    export SSHPASS="$ESXI_PASSWORD"
    SSH_CMD="sshpass -e ssh -T -o StrictHostKeyChecking=accept-new"
else
    SSH_CMD="ssh -T"
fi

# Connect via SSH and pass the commands using a heredoc
$SSH_CMD "${ESXI_USER}@${ESXI_HOST}" << EOF
    # Check if target looks like an IP address
    if echo "$TARGET_VM" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "🔍 Target is an IP address. Searching VMware Tools for a match..."
        VMID=""
        VM_NAME=""
        for id in \$(vim-cmd vmsvc/getallvms | awk 'NR>1 {print \$1}' | grep -E '^[0-9]+$'); do
            if vim-cmd vmsvc/get.summary "\$id" 2>/dev/null | grep -q "ipAddress = \"$TARGET_VM\""; then
                VMID="\$id"
                VM_NAME=\$(vim-cmd vmsvc/get.summary "\$id" | grep "name = " | head -n 1 | cut -d'"' -f2)
                break
            fi
        done
    else
        echo "🔍 Target is a Name. Searching ESXi inventory..."
        VM_NAME="$TARGET_VM"
        VMID=\$(vim-cmd vmsvc/getallvms | awk -v vm="$TARGET_VM" '\$2 == vm {print \$1}' | head -n 1)
    fi

    if [ -z "\$VMID" ]; then
        echo "❌ Error: VM '$TARGET_VM' not found or IP is not reporting to host $ESXI_HOST."
        exit 1
    fi

    echo "✅ Found VM '\$VM_NAME' with ID: \$VMID"

    echo "🔍 Fetching snapshot ID..."
    SNAPSHOT_ID=\$(vim-cmd vmsvc/snapshot.get "\$VMID" | grep -i "Snapshot Id" | tail -n 1 | awk -F':' '{print \$2}' | awk '{print \$1}')

    if [ -z "\$SNAPSHOT_ID" ]; then
        echo "❌ Error: No snapshots found for VM '\$VM_NAME'."
        exit 1
    fi

    echo "🔄 Reverting VM to Snapshot ID: \$SNAPSHOT_ID and powering it on..."
    # The trailing '0' tells ESXi to automatically power on the VM after reverting
    vim-cmd vmsvc/snapshot.revert "\$VMID" "\$SNAPSHOT_ID" 0

    echo "🎉 VM '\$VM_NAME' successfully reset and ready."
EOF