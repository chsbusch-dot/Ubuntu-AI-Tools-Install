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
    VM_NAME=$3
elif [ "$#" -eq 1 ]; then
    VM_NAME=$1
    if [ -z "$ESXI_HOST" ] || [ -z "$ESXI_USER" ]; then
        echo "❌ Error: ESXI_HOST or ESXI_USER not set in ~/.env.secrets."
        echo "Usage: $0 <esxi_host> <esxi_user> <vm_name>"
        echo "   Or: $0 <vm_name> (if host and user are in ~/.env.secrets)"
        exit 1
    fi
else
    echo "Usage: $0 <esxi_host> <esxi_user> <vm_name>"
    echo "   Or: $0 <vm_name> (if host and user are in ~/.env.secrets)"
    echo "Example: $0 192.168.1.100 root my-test-vm"
    echo "         $0 my-test-vm"
    exit 1
fi

echo "Connecting to $ESXI_HOST as $ESXI_USER to reset VM: $VM_NAME..."

if [ -n "$ESXI_PASSWORD" ]; then
    if ! command -v sshpass &> /dev/null; then
        echo "❌ Error: 'sshpass' utility is required when passing passwords via .env.secrets."
        echo "Please install it by running: sudo apt-get install -y sshpass"
        exit 1
    fi
    export SSHPASS="$ESXI_PASSWORD"
    SSH_CMD="sshpass -e ssh -T -o StrictHostKeyChecking=accept-new"
else
    SSH_CMD="ssh -T"
fi

# Connect via SSH and pass the commands using a heredoc
$SSH_CMD "${ESXI_USER}@${ESXI_HOST}" << EOF
    # Get the VM ID by matching the VM name exactly
    VMID=\$(vim-cmd vmsvc/getallvms | awk -v vm="\$VM_NAME" '\$2 == vm {print \$1}' | head -n 1)

    if [ -z "\$VMID" ]; then
        echo "❌ Error: VM '\$VM_NAME' not found on host \$ESXI_HOST."
        exit 1
    fi

    echo "✅ Found VM '\$VM_NAME' with ID: \$VMID"
    echo "🔄 Reverting VM to the current snapshot..."
    
    # Revert to the current active snapshot (0 0 targets the current state)
    vim-cmd vmsvc/snapshot.revert "\$VMID" 0 0

    # Check power state and power on if it is currently off
    if vim-cmd vmsvc/power.getstate "\$VMID" | grep -iq "Powered off"; then
        echo "⚡ Powering on the VM..."
        vim-cmd vmsvc/power.on "\$VMID" > /dev/null
    fi

    echo "🎉 VM '\$VM_NAME' successfully reset and ready."
EOF