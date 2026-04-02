#!/usr/bin/env bash
# Source this file:  source ansible-helpers.sh [inventory_file]
# Provides: ssh-vm, vm-info, ssh-hv

ANSIBLE_INVENTORY="${1:-$(dirname "${BASH_SOURCE[0]}")/inventory}"

if [[ ! -f "$ANSIBLE_INVENTORY" ]]; then
    echo "Error: inventory file not found: $ANSIBLE_INVENTORY" >&2
    return 1 2>/dev/null || exit 1
fi

_ansible_lookup() {
    local vm="$1"
    awk -v vm="$vm" '
        /^\[/ { next }
        /^$/ { next }
        $1 == vm {
            for (i = 2; i <= NF; i++) {
                split($i, kv, "=")
                vals[kv[1]] = kv[2]
            }
            print vals["ip"] "\t" vals["ansible_host"] "\t" vals["hv_ip"]
            exit
        }
    ' "$ANSIBLE_INVENTORY"
}

# 1) ssh-vm <vmname> — SSH to a VM by its IP
ssh-vm() {
    local vm="$1"
    if [[ -z "$vm" ]]; then
        echo "Usage: ssh-vm <vm_name>  (e.g. ssh-vm vm00001)" >&2
        return 1
    fi
    local result
    result=$(_ansible_lookup "$vm")
    if [[ -z "$result" ]]; then
        echo "Error: VM '$vm' not found in $ANSIBLE_INVENTORY" >&2
        return 1
    fi
    local ip
    ip=$(echo "$result" | cut -f1)
    echo "Connecting to $vm ($ip)..."
    ssh "$ip"
}

# 2) vm-info <vmname> — Print hypervisor and hv_ip for a VM
vm-info() {
    local vm="$1"
    if [[ -z "$vm" ]]; then
        echo "Usage: vm-info <vm_name>  (e.g. vm-info vm00001)" >&2
        return 1
    fi
    local result
    result=$(_ansible_lookup "$vm")
    if [[ -z "$result" ]]; then
        echo "Error: VM '$vm' not found in $ANSIBLE_INVENTORY" >&2
        return 1
    fi
    local hv hv_ip
    hv=$(echo "$result" | cut -f2)
    hv_ip=$(echo "$result" | cut -f3)
    echo "VM:         $vm"
    echo "Hypervisor: $hv"
    echo "HV IP:      $hv_ip"
}

# 3) ssh-hv <vmname> — SSH to the hypervisor that hosts a given VM
ssh-hv() {
    local vm="$1"
    if [[ -z "$vm" ]]; then
        echo "Usage: ssh-hv <vm_name>  (e.g. ssh-hv vm00001)" >&2
        return 1
    fi
    local result
    result=$(_ansible_lookup "$vm")
    if [[ -z "$result" ]]; then
        echo "Error: VM '$vm' not found in $ANSIBLE_INVENTORY" >&2
        return 1
    fi
    local hv_ip hv
    hv=$(echo "$result" | cut -f2)
    hv_ip=$(echo "$result" | cut -f3)
    echo "Connecting to hypervisor $hv ($hv_ip) for $vm..."
    ssh "$hv_ip"
}

echo "Loaded ansible-helpers from $ANSIBLE_INVENTORY"
echo "  ssh-vm <name>   — SSH to VM by name"
echo "  vm-info <name>  — Show hypervisor info for a VM"
echo "  ssh-hv <name>   — SSH to the VM's hypervisor"
