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

# --- oc helpers (dynamic, queries the cluster) ---


# Normalize input: accept "vm00123", "00123", "123", or just "123"
# Returns the 5-digit zero-padded number
_pad5() {
    local input="${1#vm}"           # strip leading "vm" if present
    input="${input#standard-}"     # strip leading "standard-" if present
    printf "%05d" "$((10#$input))"
}

# bmh-get <vm> — oc get bmh -o yaml for a VM (looks up namespace dynamically)
bmh-get() {
    local vm="$1"
    if [[ -z "$vm" ]]; then
        echo "Usage: bmh-get <vm_name>           (e.g. bmh-get vm00001)" >&2
        echo "Usage: bmh-get <vm_name> <-o type> (e.g. bmh-get vm00001 yaml)" >&2
        return 1
    fi
    local output="$2"
    if [[ -z "$output" ]]; then
        output="wide"
    fi
    local num
    num=$(_pad5 "$vm")
    local vmname="vm${num}"
    local ns
    ns=$(oc get bmh -A --no-headers 2>/dev/null | awk -v name="$vmname" '$2 == name { print $1; exit }')
    if [[ -z "$ns" ]]; then
        echo "Error: BMH '$vmname' not found on cluster" >&2
        return 1
    fi
    echo "# oc get bmh -o $output -n $ns $vmname"
    oc get bmh -o $output -n "$ns" "$vmname"
}

bmh() {
    oc get bmh -A
}

# bmhs [state] — list clusterinstances, optionally filtered by ProvisionStatus
#   bmhs              → show all
#   bmhs provisioned  → show only provisioned
#   bmhs !provisioned → show everything except provisioned
bmhs() {
    local filter="$1"
    if [[ -z "$filter" ]]; then
        bmh | awk '{ print $3 }' | sort | uniq -c
    elif [[ "$filter" == !* ]]; then
        local exclude="${filter#!}"
        bmh --no-headers | awk -v ex="$exclude" '$3 != ex' | (echo "NAMESPACE NAME STATE CONSUMER ONLINE ERROR AGE" && cat) | column -t
    else
        bmh --no-headers | awk -v st="$filter" '$3 == st' | (echo "NAMESPACE NAME STATE CONSUMER ONLINE ERROR AGE" && cat) | column -t
    fi
}

ci() {
        oc get clusterinstance -A
}

# cis [state] — list clusterinstances, optionally filtered by ProvisionStatus
#   cis              → show all
#   cis Completed    → show only Completed
#   cis !Completed   → show everything except Completed
cis() {
    local filter="$1"
    if [[ -z "$filter" ]]; then
        ci | awk '{ print $4 }' | sort | uniq -c
    elif [[ "$filter" == !* ]]; then
        local exclude="${filter#!}"
	ci --no-headers | awk -v ex="$exclude" '$4 != ex' | (echo "NAMESPACE NAME PAUSED PROVISIONSTATUS PROVISIONDETAILS AGE" && cat) | column -t
    else
	ci --no-headers | awk -v st="$filter" '$4 == st' | (echo "NAMESPACE NAME PAUSED PROVISIONSTATUS PROVISIONDETAILS AGE" && cat) | column -t
    fi
}

aci() {
    oc get aci -A
}

# aci-state [state] — list ACIs, optionally filtered by state
#   aci-state               → show all
#   aci-state adding-hosts  → show only adding-hosts
#   aci-state !adding-hosts → show everything except adding-hosts
aci-state() {
    local filter="$1"
    if [[ -z "$filter" ]]; then
        aci | awk '{ print $4 }' | sort | uniq -c
    elif [[ "$filter" == !* ]]; then
        local exclude="${filter#!}"
        aci --no-headers | awk -v ex="$exclude" '$4 != ex' | (echo "NAMESPACE NAME CLUSTER STATE" && cat) | column -t
    else
        aci  --no-headers | awk -v st="$filter" '$4 == st' | (echo "NAMESPACE NAME CLUSTER STATE" && cat) | column -t
    fi
}

# aci-get <number> — oc get aci by 3-digit (or any) cluster number
#   aci-get 1   → oc get aci standard-00001 -n standard-00001 -o yaml
aci-get() {
    local num="$1"
    if [[ -z "$num" ]]; then
        echo "Usage: aci-get <number>  (e.g. aci-get 1, aci-get 042)" >&2
        return 1
    fi
    local padded
    padded=$(_pad5 "$num")
    local name="standard-${padded}"
    echo "# oc get aci -o yaml -n $name $name"
    oc get aci -o yaml -n "$name" "$name"
}

# aci-describe <number> — oc describe aci by cluster number
aci-describe() {
    local num="$1"
    if [[ -z "$num" ]]; then
        echo "Usage: aci-describe <number>  (e.g. aci-describe 1)" >&2
        return 1
    fi
    local padded
    padded=$(_pad5 "$num")
    local name="standard-${padded}"
    echo "# oc describe aci -n $name $name"
    oc describe aci -n "$name" "$name"
}

# ci-get <number> — oc get clusterinstance by cluster number
ci-get() {
    local num="$1"
    if [[ -z "$num" ]]; then
        echo "Usage: ci-get <number>  (e.g. ci-get 1)" >&2
        return 1
    fi
    local padded
    padded=$(_pad5 "$num")
    local name="standard-${padded}"
    echo "# oc get clusterinstance -o yaml -n $name $name"
    oc get clusterinstance -o yaml -n "$name" "$name"
}

echo "Loaded ansible-helpers from $ANSIBLE_INVENTORY"
echo "  ssh-vm <name>      — SSH to VM by name"
echo "  vm-info <name>     — Show hypervisor info for a VM"
echo "  ssh-hv <name>      — SSH to the VM's hypervisor"
echo "  bmh-get <vm>       — oc get bmh -o yaml (auto-discovers namespace)"
echo "  bmh-state [state]  — List bmh (filter by status, !status to exclude)"
echo "  bmhs               — List unique bmh states"
echo "  cis [state]        — List clusterinstances (filter by status, !status to exclude)"
echo "  ci-get <N>         — oc get clusterinstance -o yaml by number"
echo "  aci-state [state]  — List ACIs (filter by state, !state to exclude)"
echo "  acis               — List ACI unique states"
echo "  aci-get <N>        — oc get aci -o yaml by number"
echo "  aci-describe <N>   — oc describe aci by number"

