#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-cpu-operator-system}"
POLICY="${POLICY:-auto-vllm-cpu-policy}"
CM_NAME="${CM_NAME:-${POLICY}-computed-cpu-policy}"

info() { echo -e "\n[INFO] $*"; }
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

command -v oc >/dev/null || fail "oc command not found"
command -v python3 >/dev/null || fail "python3 command not found"

info "Pods"
oc get pods -n "$NAMESPACE" -o wide
oc get pods -n "$NAMESPACE" -l app=node-topology-agent --no-headers | grep -q . || fail "No node-topology-agent pods"
oc get pods -n "$NAMESPACE" -l app=cpu-operator --no-headers | grep -q . || fail "No cpu-operator pod"

info "RBAC"
oc auth can-i patch nodes --as "system:serviceaccount:${NAMESPACE}:cpu-operator" | grep -qx yes || fail "cpu-operator cannot patch node labels"
oc auth can-i create machineconfigpools.machineconfiguration.openshift.io --as "system:serviceaccount:${NAMESPACE}:cpu-operator" | grep -qx yes || fail "cpu-operator cannot create MachineConfigPools"
oc auth can-i create kubeletconfigs.machineconfiguration.openshift.io --as "system:serviceaccount:${NAMESPACE}:cpu-operator" | grep -qx yes || fail "cpu-operator cannot create KubeletConfigs"
pass "RBAC ok"

TOPO_JSON="$(mktemp)"
CM_JSON="$(mktemp)"
trap 'rm -f "$TOPO_JSON" "$CM_JSON"' EXIT

oc get nodecputopologies -n "$NAMESPACE" -o json > "$TOPO_JSON"
oc get cm "$CM_NAME" -n "$NAMESPACE" -o json > "$CM_JSON"

python3 - "$TOPO_JSON" "$CM_JSON" <<'PY'
import json, sys, yaml

topo = json.load(open(sys.argv[1])).get("items", [])
cm = json.load(open(sys.argv[2]))
if not topo:
    raise SystemExit("[FAIL] No NodeCPUTopology objects")

data = cm.get("data", {})
for k in [
    "nodeClassification.yaml",
    "topologyGroups.yaml",
    "cpuPlacementByNode.yaml",
    "generatedNodeLabels.yaml",
    "phase4MachineConfigPools.yaml",
    "phase4KubeletConfigs.yaml",
    "phase4Status",
]:
    if k not in data:
        raise SystemExit(f"[FAIL] ConfigMap missing {k}")

classes = yaml.safe_load(data["nodeClassification.yaml"]) or {}
placements = yaml.safe_load(data["cpuPlacementByNode.yaml"]) or {}
mcps = yaml.safe_load(data["phase4MachineConfigPools.yaml"]) or {}
kcs = yaml.safe_load(data["phase4KubeletConfigs.yaml"]) or {}

if data.get("phase4Status") not in {"disabled", "generated-only", "applied", "apply-failed"}:
    raise SystemExit(f"[FAIL] invalid phase4Status: {data.get('phase4Status')}")
if data.get("phase4Status") in {"generated-only", "applied"} and (not mcps or not kcs):
    raise SystemExit("[FAIL] Phase 4 enabled but MCP/KubeletConfig manifests are empty")

for node, entry in classes.items():
    cls = entry.get("class")
    if node not in placements:
        raise SystemExit(f"[FAIL] {node}: missing placement")
    p = placements[node]
    if cls in {"mixed-cpu-amx-gpu", "cpu-amx"}:
        opts = p.get("cpuManagerPolicyOptions") or {}
        if opts.get("distribute-cpus-across-numa") != "true":
            raise SystemExit(f"[FAIL] {node}: expected distribute-cpus-across-numa=true")
        if p.get("topologyManagerPolicy") != "restricted":
            raise SystemExit(f"[FAIL] {node}: expected topologyManagerPolicy=restricted")
    if cls in {"gpu-only", "cpu-only"}:
        if p.get("topologyManagerPolicy") != "single-numa-node":
            raise SystemExit(f"[FAIL] {node}: expected topologyManagerPolicy=single-numa-node")

print("[PASS] Placement and Phase 4 manifest validation passed")
print(f"phase4Status={data.get('phase4Status')}")
print("\nMachineConfigPools:")
for name in sorted(mcps):
    print(f"  {name}")
print("\nKubeletConfigs:")
for name in sorted(kcs):
    print(f"  {name}")
PY

info "Node labels"
oc get nodes -L cpu.example.com/node-class,cpu.example.com/placement-strategy,cpu.example.com/phase4-applied,cpu.example.com/topology-group || true
pass "Sanity check completed"
