#!/usr/bin/env bash
set -euo pipefail

NS=cpu-operator-system
POLICY=auto-vllm-cpu-policy
CM=${POLICY}-computed-cpu-policy

echo
echo "=== CPU Operator Pods ==="
oc get pods -n "$NS" -o wide

echo
echo "=== CPUPlacementPolicy input ==="
oc get cpuplacementpolicy -n "$NS"
oc get cpuplacementpolicy "$POLICY" -n "$NS" -o yaml | sed -n '1,160p'

echo
echo "=== NodeCPUTopology input from Node Topology Agent ==="
oc get nodecputopologies -n "$NS"
oc get nodecputopologies -n "$NS" -o jsonpath='
{range .items[*]}
Node={.status.nodeName} Ready={.status.topologyReady} Online={.status.onlineCPUs} AMX={.status.amx.amx_supported} GPUs={.status.gpuCountFromPCI}{"\n"}
{range .status.numaNodes[*]}  NUMA{.id}={.cpus}{"\n"}{end}
{"\n"}
{end}'

echo
echo "=== Computed ConfigMap output keys ==="
oc get cm "$CM" -n "$NS" -o jsonpath='{.data}' | jq 'keys'

echo
echo "=== Node classification output ==="
oc get cm "$CM" -n "$NS" -o jsonpath='{.data.nodeClassification\.yaml}{"\n"}'

echo
echo "=== Topology groups output ==="
oc get cm "$CM" -n "$NS" -o jsonpath='{.data.topologyGroups\.yaml}{"\n"}'

echo
echo "=== Generated node labels output ==="
oc get cm "$CM" -n "$NS" -o jsonpath='{.data.generatedNodeLabels\.yaml}{"\n"}'

echo
echo "=== CPU placement by node output ==="
oc get cm "$CM" -n "$NS" -o jsonpath='{.data.cpuPlacementByNode\.yaml}{"\n"}'

echo
echo "=== Phase 4 status ==="
oc get cm "$CM" -n "$NS" -o jsonpath='phase4Status={.data.phase4Status}{"\n"}phase4Error={.data.phase4Error}{"\n"}'

echo
echo "=== Generated Phase 4 KubeletConfigs ==="
oc get cm "$CM" -n "$NS" -o jsonpath='{.data.phase4KubeletConfigs\.yaml}{"\n"}'

echo
echo "=== Generated Phase 4 MachineConfigPools ==="
oc get cm "$CM" -n "$NS" -o jsonpath='{.data.phase4MachineConfigPools\.yaml}{"\n"}'

echo
echo "=== Actual MCP / KubeletConfig objects ==="
oc get mcp | grep cpu- || true
oc get kubeletconfig | grep cpu- || true

echo
echo "=== Node labels applied ==="
oc get nodes \
  -L cpu.example.com/node-class,cpu.example.com/topology-ready,cpu.example.com/amx-supported,cpu.example.com/gpu-count,cpu.example.com/topology-group,cpu.example.com/phase4-applied

