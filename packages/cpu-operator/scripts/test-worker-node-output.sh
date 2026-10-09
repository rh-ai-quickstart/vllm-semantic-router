#!/usr/bin/env bash
set -uo pipefail

# Validate CPU Operator outputs for one real worker node.
#
# Usage:
#   scripts/test-worker-node-output.sh <worker-node>
#
# Optional environment variables:
#   NAMESPACE=cpu-operator-system
#   POLICY=auto-vllm-cpu-policy
#   CM_NAME=<policy>-computed-cpu-policy

NAMESPACE="${NAMESPACE:-cpu-operator-system}"
POLICY="${POLICY:-auto-vllm-cpu-policy}"
CM_NAME="${CM_NAME:-${POLICY}-computed-cpu-policy}"
NODE="${1:-${NODE:-}}"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    printf '[PASS] %s\n' "$*"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    printf '[FAIL] %s\n' "$*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

info() {
    printf '\n[INFO] %s\n' "$*"
}

finish() {
    printf '\n'
    if (( FAIL_COUNT > 0 )); then
        printf '[FAIL] summary: node=%s passed=%d failed=%d\n' "${NODE:-unknown}" "$PASS_COUNT" "$FAIL_COUNT" >&2
        exit 1
    fi
    printf '[PASS] summary: node=%s passed=%d failed=0\n' "$NODE" "$PASS_COUNT"
}

trap finish EXIT

if [[ -z "$NODE" ]]; then
    fail "worker node is required: $0 <worker-node>"
    exit 1
fi

command -v oc >/dev/null 2>&1 || { fail "oc command not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { fail "python3 command not found"; exit 1; }

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    fail "Python module PyYAML is required"
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"; finish' EXIT
NODE_JSON="$TMP_DIR/node.json"
CM_JSON="$TMP_DIR/computed-policy.json"

info "Checking node and CPU Operator output"
if ! oc get node "$NODE" -o json >"$NODE_JSON"; then
    fail "node $NODE does not exist or is not readable"
    exit 1
fi

if ! oc get configmap "$CM_NAME" -n "$NAMESPACE" -o json >"$CM_JSON"; then
    fail "ConfigMap $NAMESPACE/$CM_NAME does not exist or is not readable"
    exit 1
fi

if python3 - "$NODE_JSON" <<'PY'
import json, sys
node = json.load(open(sys.argv[1], encoding="utf-8"))
labels = node.get("metadata", {}).get("labels", {})
raise SystemExit(0 if "node-role.kubernetes.io/worker" in labels else 1)
PY
then
    pass "$NODE is labeled as a worker"
else
    fail "$NODE does not have node-role.kubernetes.io/worker"
fi

# The embedded validator writes discovered values for the shell checks below.
DISCOVERED="$TMP_DIR/discovered.env"
if python3 - "$NODE" "$NODE_JSON" "$CM_JSON" "$DISCOVERED" <<'PY'
import json
import shlex
import sys
import yaml

node_name, node_path, cm_path, output_path = sys.argv[1:]
node = json.load(open(node_path, encoding="utf-8"))
cm = json.load(open(cm_path, encoding="utf-8"))
node_labels = node.get("metadata", {}).get("labels", {})
data = cm.get("data", {})
errors = []
passes = []


def check(condition, message):
    (passes if condition else errors).append(message)


def load_yaml(key, default=None):
    if key not in data:
        errors.append(f"computed policy is missing {key}")
        return default
    try:
        value = yaml.safe_load(data[key])
        return default if value is None else value
    except Exception as exc:
        errors.append(f"cannot parse {key}: {exc}")
        return default


classes = load_yaml("nodeClassification.yaml", {}) or {}
placements = load_yaml("cpuPlacementByNode.yaml", {}) or {}
groups = load_yaml("topologyGroups.yaml", {}) or {}
generated = load_yaml("generatedNodeLabels.yaml", {}) or {}
mcps = load_yaml("phase4MachineConfigPools.yaml", {}) or {}
kcs = load_yaml("phase4KubeletConfigs.yaml", {}) or {}
provider = load_yaml("provider.yaml", {}) or {}

entry = classes.get(node_name)
placement = placements.get(node_name)
expected_labels = generated.get(node_name)
check(isinstance(entry, dict), f"{node_name} exists in nodeClassification.yaml")
check(isinstance(placement, dict), f"{node_name} exists in cpuPlacementByNode.yaml")
check(isinstance(expected_labels, dict), f"{node_name} exists in generatedNodeLabels.yaml")

if not isinstance(entry, dict) or not isinstance(placement, dict):
    for message in passes:
        print(f"[PASS] {message}")
    for message in errors:
        print(f"[FAIL] {message}")
    raise SystemExit(1)

node_class = entry.get("class", "")
group_name = entry.get("topologyGroup", "")
strategy = placement.get("strategy", "")
valid_classes = {"mixed-cpu-amx-gpu", "cpu-amx", "gpu-only", "cpu-only"}
check(node_class in valid_classes, f"node has one valid class: {node_class or '<empty>'}")
check(node_labels.get("cpu.example.com/node-class") == node_class, "live node-class label matches computed class")
check(node_labels.get("cpu.example.com/topology-group") == group_name, "live topology-group label matches computed group")
check(node_labels.get("cpu.example.com/placement-strategy") == strategy, "live placement-strategy label matches computed strategy")
check(node_labels.get("cpu.example.com/topology-ready") == "true", "live topology-ready label is true")
check(node_labels.get("cpu.example.com/placement-ready") == "true", "live placement-ready label is true")

if isinstance(expected_labels, dict):
    for key, expected in expected_labels.items():
        check(node_labels.get(key) == expected, f"live label {key}={expected}")

group = groups.get(group_name)
check(isinstance(group, dict), f"topology group {group_name} exists")
if isinstance(group, dict):
    check(node_name in (group.get("nodes") or []), "topology group contains the node")
    check(group.get("nodeClass") == node_class, "topology group class matches node class")
    check(node_name in (group.get("placementByNode") or {}), "topology group contains node placement")
    check(group.get("placementStrategy") == strategy, "topology group placement strategy matches")

check(placement.get("cpuManagerPolicy") == "static", "CPU Manager policy is static")

if node_class == "mixed-cpu-amx-gpu":
    opts = placement.get("cpuManagerPolicyOptions") or {}
    check(strategy == "balanced-shared-cpu-and-gpu", "mixed class uses balanced shared CPU/GPU placement")
    check(placement.get("topologyManagerPolicy") == "restricted", "mixed class uses restricted Topology Manager")
    check(opts.get("distribute-cpus-across-numa") == "true", "mixed class distributes CPUs across NUMA")
    check(opts.get("full-pcpus-only") == "true", "mixed class allocates full physical cores")
    check(bool(placement.get("gpuPodCPUSet")), "mixed class has gpuPodCPUSet")
    check(bool(placement.get("cpuPodCPUSet")), "mixed class has cpuPodCPUSet")
    check(not placement.get("systemReservedCPUSet"), "mixed class does not map GPU CPUs to system reservation")
elif node_class == "cpu-amx":
    opts = placement.get("cpuManagerPolicyOptions") or {}
    check(strategy == "balanced-reserved-other-pods", "cpu-amx uses balanced reserved placement")
    check(placement.get("topologyManagerPolicy") == "restricted", "cpu-amx uses restricted Topology Manager")
    check(opts.get("distribute-cpus-across-numa") == "true", "cpu-amx distributes CPUs across NUMA")
    check(opts.get("full-pcpus-only") == "true", "cpu-amx allocates full physical cores")
    check(bool(placement.get("otherPodsReservedCPUSet")), "cpu-amx has otherPodsReservedCPUSet")
    check(bool(placement.get("cpuPodCPUSet")), "cpu-amx has cpuPodCPUSet")
    check(placement.get("systemReservedCPUSet") == placement.get("otherPodsReservedCPUSet"), "cpu-amx system reservation matches other-pod reservation")
elif node_class in {"gpu-only", "cpu-only"}:
    check(strategy == "same-numa-node-first", f"{node_class} uses same-NUMA-first placement")
    check(placement.get("topologyManagerPolicy") == "single-numa-node", f"{node_class} uses single-numa-node Topology Manager")
    check(isinstance(placement.get("numaLocalCPUSetByNuma"), dict) and bool(placement.get("numaLocalCPUSetByNuma")), f"{node_class} has NUMA-local CPU pools")
    check(str(placement.get("preferredNumaNode", "")) != "", f"{node_class} has a preferred NUMA node")
    check(not placement.get("systemReservedCPUSet"), f"{node_class} has no system CPU reservation")

phase4_status = data.get("phase4Status", "")
provider_type = str(provider.get("type", ""))
check(phase4_status in {"disabled", "generated-only", "applied", "apply-failed"}, f"phase4Status is valid: {phase4_status}")

matching_mcp = ""
matching_kc = ""
if provider_type.lower() == "openshift" and phase4_status in {"generated-only", "applied"}:
    for name, manifest in mcps.items():
        selector = manifest.get("spec", {}).get("nodeSelector", {}).get("matchLabels", {})
        if selector.get("cpu.example.com/topology-group") == group_name:
            matching_mcp = name
            break
    check(bool(matching_mcp), "generated MachineConfigPool selects this topology group")
    if matching_mcp:
        pool_key = f"pools.operator.machineconfiguration.openshift.io/{matching_mcp}"
        for name, manifest in kcs.items():
            selector = manifest.get("spec", {}).get("machineConfigPoolSelector", {}).get("matchLabels", {})
            if pool_key in selector:
                matching_kc = name
                cfg = manifest.get("spec", {}).get("kubeletConfig", {})
                check(cfg.get("cpuManagerPolicy") == placement.get("cpuManagerPolicy"), "KubeletConfig CPU Manager policy matches placement")
                check(cfg.get("topologyManagerPolicy") == placement.get("topologyManagerPolicy"), "KubeletConfig Topology Manager policy matches placement")
                expected_reserved = placement.get("otherPodsReservedCPUSet", "") if node_class == "cpu-amx" else ""
                check(cfg.get("reservedSystemCPUs", "") == expected_reserved, "KubeletConfig reservedSystemCPUs matches class policy")
                break
        check(bool(matching_kc), "generated KubeletConfig selects the matching MachineConfigPool")

for message in passes:
    print(f"[PASS] {message}")
for message in errors:
    print(f"[FAIL] {message}")

with open(output_path, "w", encoding="utf-8") as stream:
    values = {
        "NODE_CLASS": node_class,
        "TOPOLOGY_GROUP": group_name,
        "PLACEMENT_STRATEGY": strategy,
        "PROVIDER_TYPE": provider_type,
        "PHASE4_STATUS": phase4_status,
        "MCP_NAME": matching_mcp,
        "KC_NAME": matching_kc,
    }
    for key, value in values.items():
        stream.write(f"{key}={shlex.quote(str(value))}\n")

raise SystemExit(1 if errors else 0)
PY
then
    pass "computed outputs are internally consistent for $NODE"
else
    fail "computed output validation failed for $NODE"
fi

if [[ -f "$DISCOVERED" ]]; then
    # Values were emitted with shell quoting by Python.
    # shellcheck disable=SC1090
    source "$DISCOVERED"
else
    fail "could not determine node class and topology group"
    exit 1
fi

info "Selected class and placement"
printf 'node=%s\nclass=%s\ntopologyGroup=%s\nplacementStrategy=%s\nprovider=%s\nphase4Status=%s\n' \
    "$NODE" "$NODE_CLASS" "$TOPOLOGY_GROUP" "$PLACEMENT_STRATEGY" "$PROVIDER_TYPE" "$PHASE4_STATUS"

if [[ "${PROVIDER_TYPE,,}" == "openshift" && "$PHASE4_STATUS" == "applied" ]]; then
    info "Checking applied OpenShift resources"
    if [[ -n "$MCP_NAME" ]] && oc get machineconfigpool "$MCP_NAME" >/dev/null 2>&1; then
        pass "applied MachineConfigPool/$MCP_NAME exists"
        MCP_JSON="$TMP_DIR/mcp.json"
        oc get machineconfigpool "$MCP_NAME" -o json >"$MCP_JSON"
        if python3 - "$MCP_JSON" <<'PY'
import json, sys
mcp = json.load(open(sys.argv[1], encoding="utf-8"))
conditions = mcp.get("status", {}).get("conditions", [])
degraded = any(c.get("type") in {"Degraded", "NodeDegraded", "RenderDegraded"} and c.get("status") == "True" for c in conditions)
raise SystemExit(1 if degraded else 0)
PY
        then
            pass "MachineConfigPool/$MCP_NAME is not degraded"
        else
            fail "MachineConfigPool/$MCP_NAME is degraded"
        fi
    else
        fail "applied MachineConfigPool/$MCP_NAME is missing"
    fi

    if [[ -n "$KC_NAME" ]] && oc get kubeletconfig "$KC_NAME" >/dev/null 2>&1; then
        pass "applied KubeletConfig/$KC_NAME exists"
    else
        fail "applied KubeletConfig/$KC_NAME is missing"
    fi
elif [[ "${PROVIDER_TYPE,,}" == "openshift" && "$PHASE4_STATUS" == "generated-only" ]]; then
    pass "OpenShift MCP/KubeletConfig were generated but intentionally not applied"
elif [[ "$PHASE4_STATUS" == "apply-failed" ]]; then
    fail "CPU Operator reports Phase 4 apply failure"
else
    pass "no applied OpenShift MCP/KubeletConfig expected for provider=$PROVIDER_TYPE phase4=$PHASE4_STATUS"
fi

info "Checking generic Kubernetes output"
GENERIC_CM="$(python3 - "$CM_JSON" <<'PY'
import json, sys, yaml
data = json.load(open(sys.argv[1], encoding="utf-8")).get("data", {})
plan = yaml.safe_load(data.get("genericApplyPlan.yaml", "{}")) or {}
print(plan.get("outputConfigMap", ""))
PY
)"

if [[ -n "$GENERIC_CM" ]] && oc get configmap "$GENERIC_CM" -n "$NAMESPACE" >/dev/null 2>&1; then
    pass "generic output ConfigMap $NAMESPACE/$GENERIC_CM exists"
    if oc get configmap "$GENERIC_CM" -n "$NAMESPACE" -o json | python3 -c '
import json, sys
node = sys.argv[1]
data = json.load(sys.stdin).get("data", {})
raise SystemExit(0 if f"{node}.kubelet-config.yaml" in data and "apply-plan.yaml" in data else 1)
' "$NODE"; then
        pass "generic output contains $NODE.kubelet-config.yaml and apply-plan.yaml"
    else
        fail "generic output is missing the node kubelet config or apply plan"
    fi
else
    fail "generic output ConfigMap could not be found"
fi
