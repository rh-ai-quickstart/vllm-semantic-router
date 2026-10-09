#!/usr/bin/env bash
set -euo pipefail

# Generate a Helm values overlay for the semantic-router 2-GPU + 1-CPU layout
# from live CPU Operator state.
#
# The sizing model follows cpu-operator/scripts/generate-vllm-cpu-gpu-serving-pods.sh:
#   * read gpuPodReservedCPUs / gpuPodCPUSet / cpuPodCPUSet from the computed policy;
#   * account for current scheduler CPU requests on the selected node;
#   * keep NUMA headroom;
#   * align exclusive requests to full physical cores when SMT is enabled.
#
# Difference from the reference CPU Operator generator: the GPU CPU budget is
# split across two GPU InferenceServices instead of assigned to one GPU pod.

NAMESPACE="${NAMESPACE:-cpu-operator-system}"
POLICY="${POLICY:-auto-vllm-cpu-policy}"
CM_NAME="${CM_NAME:-${POLICY}-computed-cpu-policy}"
NODE="${NODE:-}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-vllm-semantic-router}"
OUTPUT="${OUTPUT:-/tmp/values-g7-cpu-operator.generated.yaml}"
CPU_HEADROOM_PER_NUMA="${CPU_HEADROOM_PER_NUMA:-1}"
EXTRA_SHARED_CPU_HEADROOM="${EXTRA_SHARED_CPU_HEADROOM:-4}"
# Read installed agent/proxy requests; the helper also checks Guaranteed eligibility.
MODEL_SIDECAR_CPU_M="${MODEL_SIDECAR_CPU_M:-}"
GPU_MEMORY="${GPU_MEMORY:-32Gi}"
CPU_MEMORY="${CPU_MEMORY:-64Gi}"
RESEARCH_GPU_CPU_REQUEST="${RESEARCH_GPU_CPU_REQUEST:-}"
RAG_GPU_CPU_REQUEST="${RAG_GPU_CPU_REQUEST:-}"
REPLACE_POD_REGEX="${REPLACE_POD_REGEX:-qwen3-8b|granite-3-1-8b-instruct|granite-3-1-2b-instruct}"

fail() { echo "[FAIL] $*" >&2; exit 1; }
info() { echo "[INFO] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }

command -v oc >/dev/null || fail "oc command not found"
command -v python3 >/dev/null || fail "python3 command not found"
python3 - <<'PY' >/dev/null 2>&1 || fail "PyYAML is required: python3 -m pip install pyyaml"
import yaml
PY

[[ "${CPU_HEADROOM_PER_NUMA}" =~ ^[0-9]+$ ]] || fail "CPU_HEADROOM_PER_NUMA must be a non-negative integer"
[[ "${EXTRA_SHARED_CPU_HEADROOM}" =~ ^[0-9]+$ ]] || fail "EXTRA_SHARED_CPU_HEADROOM must be a non-negative integer"

SIDECAR_CPU_M="$(python3 "$(dirname -- "${BASH_SOURCE[0]}")/kserve-guaranteed-qos.py" \
  --namespace "${KSERVE_NAMESPACE:-redhat-ods-applications}")"
MODEL_SIDECAR_CPU_M="${MODEL_SIDECAR_CPU_M:-${SIDECAR_CPU_M}}"
[[ "${MODEL_SIDECAR_CPU_M}" =~ ^[0-9]+$ ]] || fail "MODEL_SIDECAR_CPU_M must be non-negative millicores"
(( 10#${MODEL_SIDECAR_CPU_M} >= SIDECAR_CPU_M )) || fail "Sidecar allowance cannot be lower than installed requests"

if [[ -z "${NODE}" ]]; then
  NODE="$(oc get nodes -l 'cpu.example.com/node-class=mixed-cpu-amx-gpu,cpu.example.com/placement-ready=true' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
[[ -n "${NODE}" ]] || fail "No mixed-cpu-amx-gpu placement-ready node found; set NODE explicitly"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

PLACEMENT_FILE="${WORKDIR}/cpuPlacementByNode.yaml"
TOPOLOGY_FILE="${WORKDIR}/nodecputopologies.json"
NODE_FILE="${WORKDIR}/node.json"
PODS_FILE="${WORKDIR}/pods.json"

info "Reading CPU Operator policy for ${NODE}"
oc get cm "${CM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.cpuPlacementByNode\.yaml}' > "${PLACEMENT_FILE}"
oc get nodecputopologies.cpu.example.com -n "${NAMESPACE}" -o json > "${TOPOLOGY_FILE}"
oc get node "${NODE}" -o json > "${NODE_FILE}"
oc get pods -A --field-selector "spec.nodeName=${NODE}" -o json > "${PODS_FILE}"

python3 - \
  "${PLACEMENT_FILE}" "${TOPOLOGY_FILE}" "${NODE_FILE}" "${PODS_FILE}" \
  "${NODE}" "${TARGET_NAMESPACE}" "${CPU_HEADROOM_PER_NUMA}" \
  "${EXTRA_SHARED_CPU_HEADROOM}" "${GPU_MEMORY}" "${CPU_MEMORY}" \
  "${RESEARCH_GPU_CPU_REQUEST}" "${RAG_GPU_CPU_REQUEST}" "${REPLACE_POD_REGEX}" \
  "${OUTPUT}" "${MODEL_SIDECAR_CPU_M}" <<'PY'
import json
import math
import re
import sys
from pathlib import Path
import yaml

(
    placement_path, topology_path, node_path, pods_path, node, target_namespace,
    cpu_headroom_per_numa, extra_shared_headroom, gpu_memory, cpu_memory,
    research_override, rag_override, replace_regex, output_path, model_sidecar_cpu_m,
) = sys.argv[1:]

model_sidecar_cpu_m = int(model_sidecar_cpu_m)
cpu_headroom_per_numa = int(cpu_headroom_per_numa)
extra_shared_headroom = int(extra_shared_headroom)
placement = yaml.safe_load(Path(placement_path).read_text()) or {}
node_placement = placement.get(node) or {}
if not node_placement:
    raise SystemExit(f"Node {node!r} not found in cpuPlacementByNode.yaml")


def expand_cpuset(value):
    cpus = []
    for part in str(value or "").split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            cpus.extend(range(int(a), int(b) + 1))
        else:
            cpus.append(int(part))
    return sorted(set(cpus))


def cpu_m(value):
    s = str(value or "").strip()
    if not s:
        return 0
    if s.endswith("m"):
        return int(s[:-1])
    return int(float(s) * 1000)


gpu_set = expand_cpuset(node_placement.get("gpuPodCPUSet"))
cpu_set = expand_cpuset(node_placement.get("cpuPodCPUSet"))
gpu_budget = int(node_placement.get("gpuPodReservedCPUs") or len(gpu_set))
if not gpu_set or not cpu_set:
    raise SystemExit("Expected gpuPodCPUSet and cpuPodCPUSet for mixed-cpu-amx-gpu node")
if gpu_budget != len(gpu_set):
    raise SystemExit(
        f"gpuPodReservedCPUs={gpu_budget} does not match gpuPodCPUSet capacity={len(gpu_set)}"
    )

# Find the selected node topology and derive NUMA count + SMT width.
topologies = json.loads(Path(topology_path).read_text())
topo = None
for item in topologies.get("items", []):
    spec_name = (item.get("spec") or {}).get("nodeName")
    status_name = (item.get("status") or {}).get("nodeName")
    if node in (spec_name, status_name):
        topo = item
        break
if topo is None:
    raise SystemExit(f"No NodeCPUTopology found for {node!r}")
status = topo.get("status") or {}
numa_nodes = status.get("numaNodes") or []
numa_count = len(numa_nodes)
if numa_count < 1:
    raise SystemExit("NodeCPUTopology contains no NUMA nodes")
threads_per_core = 1
for siblings in (status.get("threadSiblings") or {}).values():
    threads_per_core = max(threads_per_core, len(expand_cpuset(siblings)))

# Split the total GPU workload CPU budget over the two GPU model pods.
def parse_override(value, name):
    if not value:
        return None
    n = int(value)
    if n <= 0:
        raise SystemExit(f"{name} must be positive")
    return n

research_cpu = parse_override(research_override, "RESEARCH_GPU_CPU_REQUEST")
rag_cpu = parse_override(rag_override, "RAG_GPU_CPU_REQUEST")
if research_cpu is None and rag_cpu is None:
    if gpu_budget % (2 * threads_per_core) != 0:
        raise SystemExit(
            f"gpuPodReservedCPUs={gpu_budget} cannot be evenly split across two GPU pods "
            f"while preserving THREADS_PER_CORE={threads_per_core}; set explicit overrides"
        )
    research_cpu = rag_cpu = gpu_budget // 2
elif research_cpu is None:
    research_cpu = gpu_budget - rag_cpu
elif rag_cpu is None:
    rag_cpu = gpu_budget - research_cpu

if research_cpu + rag_cpu > gpu_budget:
    raise SystemExit(
        f"GPU CPU requests {research_cpu}+{rag_cpu} exceed gpuPodReservedCPUs={gpu_budget}"
    )
for name, value in (("research", research_cpu), ("rag", rag_cpu)):
    if value <= 0 or value % threads_per_core:
        raise SystemExit(
            f"{name} GPU CPU request {value} must be positive and aligned to THREADS_PER_CORE={threads_per_core}"
        )

node_json = json.loads(Path(node_path).read_text())
alloc_cpu_m = cpu_m(((node_json.get("status") or {}).get("allocatable") or {}).get("cpu", "0"))
alloc_gpu = int(((node_json.get("status") or {}).get("allocatable") or {}).get("nvidia.com/gpu", 0) or 0)
if alloc_gpu < 2:
    raise SystemExit(f"Node {node} has allocatable nvidia.com/gpu={alloc_gpu}; 2 GPUs are required")

# Count current scheduler CPU requests, excluding the three model workloads that
# this Helm release replaces during upgrade.
pods = json.loads(Path(pods_path).read_text())
replace_re = re.compile(replace_regex)
existing_cpu_m = 0
excluded = []
for pod in pods.get("items", []):
    meta = pod.get("metadata") or {}
    spec = pod.get("spec") or {}
    status_obj = pod.get("status") or {}
    if status_obj.get("phase") in {"Succeeded", "Failed"}:
        continue
    namespace = meta.get("namespace", "default")
    name = meta.get("name", "")

    app_sum = sum(cpu_m((((c.get("resources") or {}).get("requests") or {}).get("cpu")))
                  for c in (spec.get("containers") or []))
    init_max = max([
        cpu_m((((c.get("resources") or {}).get("requests") or {}).get("cpu")))
        for c in (spec.get("initContainers") or [])
    ] or [0])
    overhead = cpu_m(((spec.get("overhead") or {}).get("cpu")))
    pod_request = max(app_sum, init_max) + overhead

    if namespace == target_namespace and replace_re.search(name):
        excluded.append(f"{namespace}/{name}={pod_request}m")
        continue
    existing_cpu_m += pod_request

# Same core policy as CPU Operator's serving generator, with additional shared
# headroom for a fresh semantic-router deployment whose non-model pods may not
# exist yet at sizing time.
policy_target = len(cpu_set) - cpu_headroom_per_numa * numa_count
if policy_target <= 0:
    raise SystemExit("CPU policy target is not positive")

gpu_total = research_cpu + rag_cpu
scheduler_budget_m = (
    alloc_cpu_m
    - existing_cpu_m
    - gpu_total * 1000
    - 3 * model_sidecar_cpu_m
    - extra_shared_headroom * 1000
)
scheduler_cap = scheduler_budget_m // 1000
if scheduler_cap <= 0:
    raise SystemExit("No whole CPU remains for the Xeon model after current demand and headroom")

cpu_request = min(policy_target, scheduler_cap, len(cpu_set))
if threads_per_core > 1:
    cpu_request = (cpu_request // threads_per_core) * threads_per_core
if cpu_request <= 0:
    raise SystemExit("No full-core-aligned CPU request remains for the Xeon model")

out = {
    "llm-service-research": {
        "models": {
            "qwen3-8b": {
                "resources": {
                    "requests": {"cpu": str(research_cpu), "memory": gpu_memory},
                    "limits": {"cpu": str(research_cpu), "memory": gpu_memory},
                }
            }
        }
    },
    "llm-service-rag": {
        "models": {
            "granite-3-1-8b-instruct": {
                "resources": {
                    "requests": {"cpu": str(rag_cpu), "memory": gpu_memory},
                    "limits": {"cpu": str(rag_cpu), "memory": gpu_memory},
                }
            }
        }
    },
    "llm-service-general": {
        "models": {
            "granite-3-1-2b-instruct": {
                "resources": {
                    "requests": {"cpu": str(cpu_request), "memory": cpu_memory},
                    "limits": {"cpu": str(cpu_request), "memory": cpu_memory},
                }
            }
        }
    },
}
Path(output_path).parent.mkdir(parents=True, exist_ok=True)
Path(output_path).write_text(yaml.safe_dump(out, sort_keys=False), encoding="utf-8")

print(f"[INFO] NODE={node}", file=sys.stderr)
print(f"[INFO] allocatableCPU={alloc_cpu_m}m allocatableGPU={alloc_gpu}", file=sys.stderr)
print(f"[INFO] gpuPodReservedCPUs={gpu_budget} split={research_cpu}+{rag_cpu}", file=sys.stderr)
print(f"[INFO] cpuPodCPUSetCapacity={len(cpu_set)} NUMA={numa_count} threadsPerCore={threads_per_core}", file=sys.stderr)
print(f"[INFO] existingCPURequests={existing_cpu_m}m extraSharedHeadroom={extra_shared_headroom}", file=sys.stderr)
if excluded:
    print(f"[INFO] excludedReplacementPods={','.join(excluded)}", file=sys.stderr)
print(f"[INFO] modelSidecarCPUAllowance={3 * model_sidecar_cpu_m}m", file=sys.stderr)
print(f"[INFO] Xeon policyTarget={policy_target} schedulerCap={scheduler_cap} cpuRequest={cpu_request}", file=sys.stderr)
print(f"[INFO] wrote {output_path}", file=sys.stderr)
PY
