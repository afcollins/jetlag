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

# Normalize input: accept "vm00123", "00123", "123", or just "123"
_pad5() {
    local input="${1#vm}"
    input="${input#standard-}"
    printf "%05d" "$((10#$input))"
}

# 1) ssh-vm <vmname> — SSH to a VM by its IP
ssh-vm() {
    local vm="$1"
    if [[ -z "$vm" ]]; then
        echo "Usage: ssh-vm <vm>  (e.g. ssh-vm 1 or ssh-vm vm00001)" >&2
        return 1
    fi
    vm="vm$(_pad5 "$vm")"
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
        echo "Usage: vm-info <vm>  (e.g. vm-info 1 or vm-info vm00001)" >&2
        return 1
    fi
    vm="vm$(_pad5 "$vm")"
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
        echo "Usage: ssh-hv <vm>  (e.g. ssh-hv 1 or ssh-hv vm00001)" >&2
        return 1
    fi
    vm="vm$(_pad5 "$vm")"
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

# _make_oc_helpers generates a family of functions for an oc resource type.
#
# Usage: _make_oc_helpers <alias> <oc_resource> <filter_col>
#
# Given alias "ci", resource "clusterinstance", filter column 4, creates:
#   ci                  → oc get clusterinstance -A
#   cis [filter]        → no arg: unique state counts; "val": include; "-val": exclude
#   ci-get <N> [fmt]    → oc get -o <fmt> -n standard-N standard-N  (fmt defaults to wide)
#   ci-describe <N>     → oc describe -n standard-N standard-N
_make_oc_helpers() {
    local alias="$1" resource="$2" col="$3"

    # <alias> — raw list
    eval "${alias}() { oc get ${resource} -A \"\$@\"; }"

    # <alias>s [filter] — count / filter / exclude
    eval "${alias}s() {
        local filter=\"\$1\"
        if [[ -z \"\$filter\" ]]; then
            ${alias} | awk '{ print \$${col} }' | sort | uniq -c
        elif [[ \"\$filter\" == -* ]]; then
            local exclude=\"\${filter#-}\"
            ${alias} --no-headers | awk -v ex=\"\$exclude\" '\$${col} != ex' | column -t
        else
            ${alias} --no-headers | awk -v st=\"\$filter\" '\$${col} == st' | column -t
        fi
    }"

    # <alias>-get <N> [output_format] — get by cluster number
    eval "${alias}g() {
        local num=\"\$1\" output=\"\${2:-wide}\"
        if [[ -z \"\$num\" ]]; then
            echo \"Usage: ${alias}-get <number> [format]  (e.g. ${alias}-get 1 yaml)\" >&2
            return 1
        fi
        local name=\"standard-\$(_pad5 \"\$num\")\"
        echo \"# oc get ${resource} -o \$output -n \$name \$name\"
        oc get ${resource} -o \"\$output\" -n \"\$name\" \"\$name\"
    }"

    # <alias>-describe <N> — describe by cluster number
    eval "${alias}d() {
        local num=\"\$1\"
        if [[ -z \"\$num\" ]]; then
            echo \"Usage: ${alias}-describe <number>  (e.g. ${alias}-describe 1)\" >&2
            return 1
        fi
        local name=\"standard-\$(_pad5 \"\$num\")\"
        echo \"# oc describe ${resource} -n \$name \$name\"
        oc describe ${resource} -n \"\$name\" \"\$name\"
    }"
}

#              alias   oc resource       filter column
_make_oc_helpers bmh   bmh               3
_make_oc_helpers ci    clusterinstance   3
_make_oc_helpers aci   aci               4

# BMH overrides: name is vmXXXXX, namespace must be discovered
_bmh_lookup() {
    local vm="$1"
    local vmname="vm$(_pad5 "$vm")"
    local ns
    ns=$(oc get bmh -A --no-headers 2>/dev/null | awk -v name="$vmname" '$2 == name { print $1; exit }')
    if [[ -z "$ns" ]]; then
        echo "Error: BMH '$vmname' not found on cluster" >&2
        return 1
    fi
    echo "$ns $vmname"
}

bmhg() {
    local vm="$1" output="${2:-wide}"
    if [[ -z "$vm" ]]; then
        echo "Usage: bmhg <vm> [format]  (e.g. bmhg 1 yaml)" >&2
        return 1
    fi
    local result ns vmname
    result=$(_bmh_lookup "$vm") || return 1
    ns="${result% *}" vmname="${result#* }"
    echo "# oc get bmh -o $output -n $ns $vmname"
    oc get bmh -o "$output" -n "$ns" "$vmname"
}

bmhd() {
    local vm="$1"
    if [[ -z "$vm" ]]; then
        echo "Usage: bmhd <vm>  (e.g. bmhd 1)" >&2
        return 1
    fi
    local result ns vmname
    result=$(_bmh_lookup "$vm") || return 1
    ns="${result% *}" vmname="${result#* }"
    echo "# oc describe bmh -n $ns $vmname"
    oc describe bmh -n "$ns" "$vmname"
}

# --- cross-reference helpers ---

# ci-info <N> — show cluster → VMs → hypervisors mapping
#   Chains: clusterinstance → bmh (namespace) → inventory (HV)
ci-info() {
    local num="$1"
    if [[ -z "$num" ]]; then
        echo "Usage: ci-info <number>  (e.g. ci-info 1)" >&2
        return 1
    fi
    local padded ns
    padded=$(_pad5 "$num")
    ns="standard-${padded}"

    echo "Cluster: $ns"
    echo "---"

    # Get clusterinstance status
    local ci_line
    ci_line=$(oc get clusterinstance -n "$ns" "$ns" --no-headers 2>/dev/null)
    if [[ -n "$ci_line" ]]; then
        echo "Status:  $(echo "$ci_line" | awk '{ print $3, $4 }')"
    else
        echo "Status:  (clusterinstance not found)"
    fi

    # Get ACI state
    local aci_line
    aci_line=$(oc get aci -n "$ns" "$ns" --no-headers 2>/dev/null)
    if [[ -n "$aci_line" ]]; then
        echo "ACI:     $(echo "$aci_line" | awk '{ print $4 }')"
    fi

    echo "---"

    # Get BMHs in this namespace → VM names → inventory HV lookup
    local bmh_lines
    bmh_lines=$(oc get bmh -n "$ns" --no-headers 2>/dev/null)
    if [[ -z "$bmh_lines" ]]; then
        echo "No BMHs found in namespace $ns"
        return
    fi

    printf "%-12s %-16s %-14s %-50s %s\n" "VM" "IP" "STATE" "HYPERVISOR" "HV_IP"
    echo "$bmh_lines" | while read -r vmname state _rest; do
        local inv
        inv=$(_ansible_lookup "$vmname")
        local vm_ip hv hv_ip
        if [[ -n "$inv" ]]; then
            vm_ip=$(echo "$inv" | cut -f1)
            hv=$(echo "$inv" | cut -f2)
            hv_ip=$(echo "$inv" | cut -f3)
        else
            vm_ip="?" hv="(not in inventory)" hv_ip="?"
        fi
        printf "%-12s %-16s %-14s %-50s %s\n" "$vmname" "$vm_ip" "$state" "$hv" "$hv_ip"
    done
}

# hv-info <hv_name_or_ip> — show all VMs and clusters on a given hypervisor
hv-info() {
    local query="$1"
    if [[ -z "$query" ]]; then
        echo "Usage: hv-info <hostname_or_ip>  (e.g. hv-info e34-h01 or hv-info 198.18.0.8)" >&2
        return 1
    fi
    # Search inventory for all VMs matching this HV (partial match supported)
    printf "%-12s %-16s %-50s %-16s %s\n" "VM" "VM_IP" "HYPERVISOR" "HV_IP" "CLUSTER_NS"
    awk -v q="$query" '
        /^\[/ { next }
        /^$/ { next }
        {
            for (i = 2; i <= NF; i++) {
                split($i, kv, "=")
                vals[kv[1]] = kv[2]
            }
            if (vals["ansible_host"] ~ q || vals["hv_ip"] == q) {
                printf "%-12s %-16s %-50s %s\n", $1, vals["ip"], vals["ansible_host"], vals["hv_ip"]
            }
            delete vals
        }
    ' "$ANSIBLE_INVENTORY"
}

echo "Loaded ansible-helpers from $ANSIBLE_INVENTORY"
echo "  ssh-vm <name>        — SSH to VM by name"
echo "  vm-info <name>       — Show hypervisor info for a VM"
echo "  ssh-hv <name>        — SSH to the VM's hypervisor"
echo "  ---"
echo "  For each resource (bmh, ci, aci):"
echo "    <r>                — oc get <resource> -A"
echo "    <r>s               — count unique states"
echo "    <r>s <state>       — filter to state"
echo "    <r>s -<state>      — exclude state"
echo "    <r>g <N> [fmt]     — oc get by cluster/vm number (fmt: wide, yaml, json)"
echo "    <r>d <N>           — oc describe by number"
echo "  bmh-get uses vm name and auto-discovers namespace"
echo "  ---"
echo "  ci-info <N>          — full cluster map: status, VMs, hypervisors"
echo "  hv-info <host|ip>    — all VMs on a hypervisor (partial match ok)"

