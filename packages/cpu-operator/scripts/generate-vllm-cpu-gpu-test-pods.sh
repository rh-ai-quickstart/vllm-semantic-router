#!/usr/bin/env bash
set -euo pipefail

# Generate paired Guaranteed-QoS CPU and GPU placement test pods for a
# mixed-cpu-amx-gpu worker.
#
# Defaults are intentionally policy-driven:
#   * GPU pod CPU request = all gpuPodReservedCPUs / gpuPodCPUSet capacity.
#   * CPU pod CPU request = cpuPodCPUSet capacity
#                           - (CPU_HEADROOM_PER_NUMA * NUMA_COUNT).
#
# Example sizing:
#   gpuPodCPUSet=0-11   -> GPU_CPU_REQUEST=12
#   cpuPodCPUSet=12-47  -> CPU_CAPACITY=36
#   CPU policy target   -> 36-(1*NUMA_COUNT)
# The default CPU request is additionally capped to live scheduler capacity
# after existing pod CPU requests and the paired GPU test are accounted for.
#
# The policy CPU sets are capacity/reference sets. Kubernetes CPU Manager gets
# integer CPU requests and may choose different exact CPU IDs.
#
# Required tools: oc, python3
# Existing helper: scripts/generate-vllm-cpu-test-pod.sh
#
# Optional environment overrides:
#   NAMESPACE               CPU Operator namespace
#   POLICY                  CPUPlacementPolicy name
#   CM_NAME                 Computed policy ConfigMap name
#   NODE                    Target worker node; defaults to first placement node
#   POD_NAMESPACE           Namespace for both test pods
#   CPU_POD_NAME            CPU test pod name
#   GPU_POD_NAME            GPU test pod name
#   IMAGE                   Test image
#   CPU_MEMORY              CPU test pod memory request/limit
#   GPU_MEMORY              GPU test pod memory request/limit
#   GPU_REQUEST             Number of GPUs requested by GPU test pod
#   CPU_HEADROOM_PER_NUMA   CPUs removed from cpuPodCPUSet capacity per NUMA node
#   CPU_REQUEST             Explicit CPU pod CPU override
#   GPU_CPU_REQUEST         Explicit GPU pod CPU override
#   CPU_OUT                 Generated CPU pod manifest path
#   GPU_OUT                 Generated GPU pod manifest path
#   CPU_GENERATOR           Path to generate-vllm-cpu-test-pod.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="${NAMESPACE:-cpu-operator-system}"
POLICY="${POLICY:-auto-vllm-cpu-policy}"
CM_NAME="${CM_NAME:-${POLICY}-computed-cpu-policy}"
NODE="${NODE:-}"
POD_NAMESPACE="${POD_NAMESPACE:-default}"
CPU_POD_NAME="${CPU_POD_NAME:-vllm-cpu-test}"
GPU_POD_NAME="${GPU_POD_NAME:-vllm-gpu-test}"
IMAGE="${IMAGE:-registry.access.redhat.com/ubi9/ubi}"
CPU_MEMORY="${CPU_MEMORY:-1Gi}"
GPU_MEMORY="${GPU_MEMORY:-1Gi}"
GPU_REQUEST="${GPU_REQUEST:-1}"
CPU_HEADROOM_PER_NUMA="${CPU_HEADROOM_PER_NUMA:-1}"
CPU_REQUEST="${CPU_REQUEST:-}"
GPU_CPU_REQUEST="${GPU_CPU_REQUEST:-}"
CPU_OUT="${CPU_OUT:-examples/vllm-cpu-test-pod.generated.yaml}"
GPU_OUT="${GPU_OUT:-examples/vllm-gpu-test-pod.generated.yaml}"
CPU_GENERATOR="${CPU_GENERATOR:-${SCRIPT_DIR}/generate-vllm-cpu-test-pod.sh}"

fail() { echo "[FAIL] $*" >&2; exit 1; }
warn() { echo "[WARN] $*" >&2; }
info() { echo "[INFO] $*"; }

command -v oc >/dev/null || fail "oc command not found"
command -v python3 >/dev/null || fail "python3 command not found"
[[ -x "${CPU_GENERATOR}" ]] || fail "CPU generator is not executable: ${CPU_GENERATOR}"

[[ "${GPU_REQUEST}" =~ ^[1-9][0-9]*$ ]] || fail "GPU_REQUEST must be a positive integer"
[[ "${CPU_HEADROOM_PER_NUMA}" =~ ^[0-9]+$ ]] || fail "CPU_HEADROOM_PER_NUMA must be a non-negative integer"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

CPU_PLACEMENT_FILE="${WORKDIR}/cpuPlacementByNode.yaml"
NODE_LABELS_FILE="${WORKDIR}/generatedNodeLabels.yaml"
TOPOLOGY_JSON="${WORKDIR}/nodecputopologies.json"
NODE_JSON="${WORKDIR}/node.json"
PODS_JSON="${WORKDIR}/pods-on-node.json"

info "Reading computed placement from ConfigMap ${NAMESPACE}/${CM_NAME}"
oc get cm "${CM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.cpuPlacementByNode\.yaml}' > "${CPU_PLACEMENT_FILE}"

oc get cm "${CM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.generatedNodeLabels\.yaml}' > "${NODE_LABELS_FILE}" 2>/dev/null || true

[[ -s "${CPU_PLACEMENT_FILE}" ]] \
  || fail "ConfigMap ${NAMESPACE}/${CM_NAME} does not contain data.cpuPlacementByNode.yaml"

# Resolve NODE before fetching its live Node object.
if [[ -z "${NODE}" ]]; then
  NODE="$(python3 - "${CPU_PLACEMENT_FILE}" <<'PY'
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if line and not line.startswith((" ", "\t")) and line.rstrip().endswith(":"):
        print(line.rstrip()[:-1].strip().strip('"\''))
        break
PY
)"
fi
[[ -n "${NODE}" ]] || fail "Could not determine target NODE from cpuPlacementByNode.yaml"

oc get node "${NODE}" -o json > "${NODE_JSON}"
oc get nodecputopologies.cpu.example.com -n "${NAMESPACE}" -o json > "${TOPOLOGY_JSON}"
oc get pods -A --field-selector "spec.nodeName=${NODE}" -o json > "${PODS_JSON}"

PY_OUT="$(python3 - \
  "${CPU_PLACEMENT_FILE}" \
  "${NODE_LABELS_FILE}" \
  "${TOPOLOGY_JSON}" \
  "${NODE_JSON}" \
  "${PODS_JSON}" \
  "${NODE}" \
  "${POD_NAMESPACE}" \
  "${CPU_POD_NAME}" \
  "${GPU_POD_NAME}" <<'PY'
import json
import re
import shlex
import sys
from pathlib import Path

placement_path, labels_path, topology_path, node_path, pods_path, node, pod_namespace, cpu_pod_name, gpu_pod_name = sys.argv[1:]
placement_text = Path(placement_path).read_text(encoding="utf-8")
labels_text = Path(labels_path).read_text(encoding="utf-8") if Path(labels_path).exists() else ""
topologies = json.load(open(topology_path, encoding="utf-8"))
node_json = json.load(open(node_path, encoding="utf-8"))
pods_json = json.load(open(pods_path, encoding="utf-8"))


def extract_scalar(text, node_name, key):
    in_node = False
    pattern = re.compile(rf"^\s{{2}}{re.escape(key)}:\s*(.*)$")
    for line in text.splitlines():
        if not line.strip():
            continue
        if not line.startswith((" ", "\t")) and line.rstrip().endswith(":"):
            current = line.rstrip()[:-1].strip().strip('"\'')
            in_node = current == node_name
            continue
        if in_node:
            match = pattern.match(line)
            if match:
                return match.group(1).strip().strip('"\'')
    return ""


def expand_cpuset(cpuset):
    out = []
    for part in str(cpuset or "").split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            start_s, end_s = part.split("-", 1)
            start, end = int(start_s), int(end_s)
            if end < start:
                raise SystemExit(f"Invalid CPU range: {part}")
            out.extend(range(start, end + 1))
        else:
            out.append(int(part))
    return sorted(set(out))


def cpu_quantity_to_millicores(value):
    value = str(value or "").strip()
    if not value:
        return 0
    if value.endswith("m"):
        return int(value[:-1])
    return int(float(value) * 1000)

cpu_set = extract_scalar(placement_text, node, "cpuPodCPUSet")
gpu_set = extract_scalar(placement_text, node, "gpuPodCPUSet")
gpu_reserved_raw = extract_scalar(placement_text, node, "gpuPodReservedCPUs")
node_class = (
    extract_scalar(labels_text, node, "cpu.example.com/node-class")
    or extract_scalar(placement_text, node, "nodeClass")
)
topology_group = extract_scalar(labels_text, node, "cpu.example.com/topology-group")
placement_strategy = extract_scalar(labels_text, node, "cpu.example.com/placement-strategy")
phase4_applied = extract_scalar(labels_text, node, "cpu.example.com/phase4-applied")

if not cpu_set:
    raise SystemExit(f"Node {node!r} does not have cpuPodCPUSet")
if not gpu_set:
    raise SystemExit(f"Node {node!r} does not have gpuPodCPUSet")

cpu_capacity = len(expand_cpuset(cpu_set))
gpu_capacity = len(expand_cpuset(gpu_set))
gpu_reserved = int(gpu_reserved_raw or gpu_capacity)

if gpu_reserved != gpu_capacity:
    raise SystemExit(
        f"gpuPodReservedCPUs={gpu_reserved} does not match gpuPodCPUSet capacity={gpu_capacity}"
    )

topo = None
for item in topologies.get("items", []):
    spec_name = (item.get("spec") or {}).get("nodeName")
    status_name = (item.get("status") or {}).get("nodeName")
    if spec_name == node or status_name == node:
        topo = item
        break
if topo is None:
    raise SystemExit(f"No NodeCPUTopology found for {node!r}")

status = topo.get("status") or {}
numa_nodes = status.get("numaNodes") or []
numa_count = len(numa_nodes)
if numa_count <= 0:
    raise SystemExit(f"NodeCPUTopology for {node!r} has no NUMA nodes")

gpu_local_numa = status.get("gpuLocalNumaNodes") or []
thread_siblings = status.get("threadSiblings") or {}
threads_per_core = 1
for siblings in thread_siblings.values():
    try:
        threads_per_core = max(threads_per_core, len(expand_cpuset(siblings)))
    except Exception:
        pass

alloc = (node_json.get("status") or {}).get("allocatable") or {}
alloc_cpu_raw = alloc.get("cpu", "0")
alloc_cpu_m = cpu_quantity_to_millicores(alloc_cpu_raw)
alloc_gpu = int(alloc.get("nvidia.com/gpu", 0) or 0)

# Scheduler capacity is allocatable minus CPU requests from pods already bound
# to this node. Exclude the generated test pod names so rerunning the generator
# while one of the tests is alive does not double-count that test request.
def container_cpu_request_m(container):
    requests = ((container.get("resources") or {}).get("requests") or {})
    return cpu_quantity_to_millicores(requests.get("cpu", "0"))

existing_cpu_request_m = 0
existing_request_pods = []
for pod in pods_json.get("items", []):
    meta = pod.get("metadata") or {}
    spec = pod.get("spec") or {}
    status_obj = pod.get("status") or {}
    if status_obj.get("phase") in {"Succeeded", "Failed"}:
        continue
    if meta.get("namespace") == pod_namespace and meta.get("name") in {cpu_pod_name, gpu_pod_name}:
        continue

    # Summing app + init requests is intentionally conservative. It may
    # slightly overestimate transient init-container demand, which is safer for
    # a stress-test generator than producing another unschedulable manifest.
    pod_request_m = sum(container_cpu_request_m(c) for c in (spec.get("containers") or []))
    pod_request_m += sum(container_cpu_request_m(c) for c in (spec.get("initContainers") or []))
    pod_request_m += cpu_quantity_to_millicores((spec.get("overhead") or {}).get("cpu", "0"))
    existing_cpu_request_m += pod_request_m
    if pod_request_m:
        existing_request_pods.append(
            f"{meta.get('namespace','default')}/{meta.get('name','?')}={pod_request_m}m"
        )

values = {
    "NODE": node,
    "CPUSET": cpu_set,
    "CPU_CAPACITY": cpu_capacity,
    "GPU_CPUSET": gpu_set,
    "GPU_CPU_CAPACITY": gpu_capacity,
    "GPU_RESERVED_CPUS": gpu_reserved,
    "NUMA_COUNT": numa_count,
    "GPU_LOCAL_NUMA_NODES": ",".join(map(str, gpu_local_numa)),
    "THREADS_PER_CORE": threads_per_core,
    "NODE_CLASS": node_class,
    "TOPOLOGY_GROUP": topology_group,
    "PLACEMENT_STRATEGY": placement_strategy,
    "PHASE4_APPLIED": phase4_applied,
    "NODE_ALLOCATABLE_CPU": alloc_cpu_raw,
    "NODE_ALLOCATABLE_CPU_M": alloc_cpu_m,
    "NODE_ALLOCATABLE_GPU": alloc_gpu,
    "EXISTING_NODE_CPU_REQUEST_M": existing_cpu_request_m,
    "EXISTING_NODE_CPU_REQUEST_PODS": ",".join(existing_request_pods),
}
for key, value in values.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
)"

# shellcheck disable=SC1090
source <(printf '%s\n' "${PY_OUT}")

[[ "${NODE_CLASS}" == "mixed-cpu-amx-gpu" ]] \
  || fail "Node ${NODE} class is ${NODE_CLASS:-unknown}; paired CPU/GPU test requires mixed-cpu-amx-gpu"

if (( NODE_ALLOCATABLE_GPU < GPU_REQUEST )); then
  fail "GPU_REQUEST=${GPU_REQUEST} exceeds node allocatable GPU=${NODE_ALLOCATABLE_GPU}"
fi

if [[ -z "${GPU_CPU_REQUEST}" ]]; then
  GPU_CPU_REQUEST="${GPU_RESERVED_CPUS}"
fi
[[ "${GPU_CPU_REQUEST}" =~ ^[1-9][0-9]*$ ]] || fail "GPU_CPU_REQUEST must be a positive integer"
if (( GPU_CPU_REQUEST > GPU_CPU_CAPACITY )); then
  fail "GPU_CPU_REQUEST=${GPU_CPU_REQUEST} exceeds gpuPodCPUSet capacity=${GPU_CPU_CAPACITY}"
fi

CPU_HEADROOM_TOTAL=$((CPU_HEADROOM_PER_NUMA * NUMA_COUNT))
CPU_POLICY_TARGET=$((CPU_CAPACITY - CPU_HEADROOM_TOTAL))
(( CPU_POLICY_TARGET > 0 )) \
  || fail "CPU policy target is not positive: capacity=${CPU_CAPACITY} headroom=${CPU_HEADROOM_TOTAL}"

# Keep the requested policy rule as the target, but do not generate a CPU pod
# that the Kubernetes scheduler can never place because other pods already
# consume part of node allocatable CPU. GPU_CPU_REQUEST is always reserved from
# the scheduler budget because the paired test is intended to run concurrently.
SCHEDULER_CPU_BUDGET_M=$((NODE_ALLOCATABLE_CPU_M - EXISTING_NODE_CPU_REQUEST_M - GPU_CPU_REQUEST * 1000))
SCHEDULER_CPU_CAP=$((SCHEDULER_CPU_BUDGET_M / 1000))

if [[ -z "${CPU_REQUEST}" ]]; then
  CPU_REQUEST="${CPU_POLICY_TARGET}"
  if (( CPU_REQUEST > SCHEDULER_CPU_CAP )); then
    warn "CPU policy target=${CPU_POLICY_TARGET} cannot co-schedule with the GPU test and existing pod requests"
    warn "Reducing CPU request to scheduler-safe cap=${SCHEDULER_CPU_CAP}"
    CPU_REQUEST="${SCHEDULER_CPU_CAP}"
  fi
fi
[[ "${CPU_REQUEST}" =~ ^[1-9][0-9]*$ ]] || fail "CPU_REQUEST must be a positive integer"
if (( CPU_REQUEST > CPU_CAPACITY )); then
  fail "CPU_REQUEST=${CPU_REQUEST} exceeds cpuPodCPUSet capacity=${CPU_CAPACITY}"
fi
if (( CPU_REQUEST > SCHEDULER_CPU_CAP )); then
  fail "CPU_REQUEST=${CPU_REQUEST} exceeds scheduler-safe cap=${SCHEDULER_CPU_CAP} after existing node requests and GPU test demand"
fi

if (( THREADS_PER_CORE > 1 )); then
  if (( CPU_REQUEST % THREADS_PER_CORE != 0 )); then
    fail "CPU_REQUEST=${CPU_REQUEST} is not aligned to THREADS_PER_CORE=${THREADS_PER_CORE}; full-pcpus-only may reject it"
  fi
  if (( GPU_CPU_REQUEST % THREADS_PER_CORE != 0 )); then
    fail "GPU_CPU_REQUEST=${GPU_CPU_REQUEST} is not aligned to THREADS_PER_CORE=${THREADS_PER_CORE}; full-pcpus-only may reject it"
  fi
fi

COMBINED_CPU_REQUEST=$((CPU_REQUEST + GPU_CPU_REQUEST))
COMBINED_CPU_REQUEST_M=$((COMBINED_CPU_REQUEST * 1000))
if (( COMBINED_CPU_REQUEST_M > NODE_ALLOCATABLE_CPU_M )); then
  fail "Combined CPU request=${COMBINED_CPU_REQUEST} exceeds node allocatable CPU=${NODE_ALLOCATABLE_CPU}"
fi

info "Selected node and derived test sizing"
echo "NODE=${NODE}"
echo "NODE_CLASS=${NODE_CLASS}"
echo "TOPOLOGY_GROUP=${TOPOLOGY_GROUP}"
echo "NUMA_COUNT=${NUMA_COUNT}"
echo "THREADS_PER_CORE=${THREADS_PER_CORE}"
echo "GPU_LOCAL_NUMA_NODES=${GPU_LOCAL_NUMA_NODES:-unknown}"
echo "NODE_ALLOCATABLE_CPU=${NODE_ALLOCATABLE_CPU}"
echo "NODE_ALLOCATABLE_GPU=${NODE_ALLOCATABLE_GPU}"
echo "EXISTING_NODE_CPU_REQUEST=${EXISTING_NODE_CPU_REQUEST_M}m"
if [[ -n "${EXISTING_NODE_CPU_REQUEST_PODS:-}" ]]; then
  echo "EXISTING_NODE_CPU_REQUEST_PODS=${EXISTING_NODE_CPU_REQUEST_PODS}"
fi
echo
echo "GPU policy: cpuset=${GPU_CPUSET} capacity=${GPU_CPU_CAPACITY} request=${GPU_CPU_REQUEST} gpu=${GPU_REQUEST}"
echo "CPU policy: cpuset=${CPUSET} capacity=${CPU_CAPACITY} headroom=${CPU_HEADROOM_PER_NUMA}x${NUMA_COUNT}=${CPU_HEADROOM_TOTAL} policyTarget=${CPU_POLICY_TARGET} schedulerCap=${SCHEDULER_CPU_CAP} request=${CPU_REQUEST}"
echo "Combined exclusive CPU request=${COMBINED_CPU_REQUEST}"

if (( COMBINED_CPU_REQUEST_M == NODE_ALLOCATABLE_CPU_M )); then
  warn "Combined test request consumes all node allocatable CPU; existing pod requests can make scheduling fail"
else
  HEADROOM_M=$((NODE_ALLOCATABLE_CPU_M - EXISTING_NODE_CPU_REQUEST_M - COMBINED_CPU_REQUEST_M))
  info "Scheduler CPU headroom after existing pod requests plus these two tests: ${HEADROOM_M}m"
fi
info "Existing pods on the node also consume scheduler CPU requests; inspect 'oc describe node ${NODE}' if either pod remains Pending"

# Reuse the existing CPU generator so CPU-only behavior remains in one place.
NAMESPACE="${NAMESPACE}" \
POLICY="${POLICY}" \
CM_NAME="${CM_NAME}" \
NODE="${NODE}" \
POD_NAMESPACE="${POD_NAMESPACE}" \
POD_NAME="${CPU_POD_NAME}" \
IMAGE="${IMAGE}" \
MEMORY="${CPU_MEMORY}" \
CPU_REQUEST="${CPU_REQUEST}" \
OUT="${CPU_OUT}" \
"${CPU_GENERATOR}"

mkdir -p "$(dirname "${GPU_OUT}")"
cat > "${GPU_OUT}" <<EOF_MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: ${GPU_POD_NAME}
  namespace: ${POD_NAMESPACE}
  labels:
    app: vllm-gpu-test
    workload: vllm-gpu
    cpu.example.com/generated-from-policy: ${POLICY}
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${NODE}
    cpu.example.com/placement-ready: "true"
    cpu.example.com/node-class: ${NODE_CLASS}
EOF_MANIFEST

if [[ -n "${TOPOLOGY_GROUP:-}" ]]; then
  cat >> "${GPU_OUT}" <<EOF_MANIFEST
    cpu.example.com/topology-group: ${TOPOLOGY_GROUP}
EOF_MANIFEST
fi

if [[ -n "${PHASE4_APPLIED:-}" ]]; then
  cat >> "${GPU_OUT}" <<EOF_MANIFEST
    cpu.example.com/phase4-applied: "${PHASE4_APPLIED}"
EOF_MANIFEST
fi

cat >> "${GPU_OUT}" <<EOF_MANIFEST
  containers:
    - name: vllm-gpu-test
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent
      command:
        - /bin/bash
        - -lc
        - |
          count_cpuset() {
            local cpuset="\$1"
            local total=0
            local part start end
            local -a parts
            IFS=',' read -r -a parts <<< "\${cpuset}"
            for part in "\${parts[@]}"; do
              part="\${part//[[:space:]]/}"
              [[ -z "\${part}" ]] && continue
              if [[ "\${part}" == *-* ]]; then
                start="\${part%%-*}"
                end="\${part##*-}"
                total=\$((total + end - start + 1))
              else
                total=\$((total + 1))
              fi
            done
            printf '%s\n' "\${total}"
          }

          POLICY_GPU_CPUSET="${GPU_CPUSET}"
          POLICY_GPU_CPU_CAPACITY="${GPU_CPU_CAPACITY}"
          REQUESTED_CPU_COUNT="${GPU_CPU_REQUEST}"
          REQUESTED_GPU_COUNT="${GPU_REQUEST}"
          ACTUAL_CPUSET="\$(awk '/^Cpus_allowed_list:/ {print \$2}' /proc/self/status)"
          EFFECTIVE_CPUSET="\$(cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null || true)"
          ACTUAL_CPU_COUNT="\$(count_cpuset "\${ACTUAL_CPUSET}")"

          echo "=== vLLM GPU placement test pod ==="
          echo "Node: \${NODE_NAME}"
          echo "Policy: ${POLICY}"
          echo "Policy GPU CPU set: \${POLICY_GPU_CPUSET}"
          echo "Policy GPU CPU capacity: \${POLICY_GPU_CPU_CAPACITY}"
          echo "Pod requested CPU count: \${REQUESTED_CPU_COUNT}"
          echo "Pod requested GPU count: \${REQUESTED_GPU_COUNT}"
          echo "Expected GPU-local NUMA nodes: ${GPU_LOCAL_NUMA_NODES:-unknown}"
          echo
          echo "Kubelet-assigned exclusive CPU set: \${ACTUAL_CPUSET}"
          if [[ -n "\${EFFECTIVE_CPUSET}" ]]; then
            echo "Effective cgroup CPU set: \${EFFECTIVE_CPUSET}"
          fi
          echo "Actual exclusive CPU count: \${ACTUAL_CPU_COUNT}"
          echo

          if [[ "\${ACTUAL_CPU_COUNT}" -eq "\${REQUESTED_CPU_COUNT}" ]]; then
            echo "[PASS] CPU count: requested=\${REQUESTED_CPU_COUNT} actual=\${ACTUAL_CPU_COUNT}"
          else
            echo "[FAIL] CPU count: requested=\${REQUESTED_CPU_COUNT} actual=\${ACTUAL_CPU_COUNT}"
            exit 1
          fi

          if [[ "\${REQUESTED_CPU_COUNT}" -eq "\${POLICY_GPU_CPU_CAPACITY}" && "\${ACTUAL_CPUSET}" == "\${POLICY_GPU_CPUSET}" ]]; then
            echo "[PASS] Exact CPU IDs match gpuPodCPUSet"
          else
            echo "[INFO] Exact CPU IDs differ from gpuPodCPUSet"
            echo "[INFO] gpuPodCPUSet is a capacity/reference set; CPU Manager receives an integer CPU request."
          fi

          if [[ -n "\${EFFECTIVE_CPUSET}" && "\${EFFECTIVE_CPUSET}" != "\${ACTUAL_CPUSET}" ]]; then
            echo "[WARN] /proc/self/status and cgroup effective cpuset differ"
          else
            echo "[PASS] Process affinity matches the effective cgroup cpuset"
          fi

          echo
          echo "=== GPU visibility ==="
          echo "NVIDIA_VISIBLE_DEVICES=\${NVIDIA_VISIBLE_DEVICES:-unset}"
          ls -l /dev/nvidia* 2>/dev/null || true
          if command -v nvidia-smi >/dev/null 2>&1; then
            nvidia-smi -L || true
          fi

          echo
          echo "Container will sleep for inspection."
          sleep infinity
      env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
      resources:
        requests:
          cpu: "${GPU_CPU_REQUEST}"
          memory: "${GPU_MEMORY}"
          nvidia.com/gpu: "${GPU_REQUEST}"
        limits:
          cpu: "${GPU_CPU_REQUEST}"
          memory: "${GPU_MEMORY}"
          nvidia.com/gpu: "${GPU_REQUEST}"
EOF_MANIFEST

info "Generated ${GPU_OUT}"
echo
echo "Recommended apply order (GPU first, then CPU):"
echo "  oc apply -f ${GPU_OUT}"
echo "  oc wait --for=condition=Ready pod/${GPU_POD_NAME} -n ${POD_NAMESPACE} --timeout=120s"
echo "  oc apply -f ${CPU_OUT}"
echo "  oc wait --for=condition=Ready pod/${CPU_POD_NAME} -n ${POD_NAMESPACE} --timeout=120s"
echo
echo "Validate both pods:"
echo "  oc get pod ${GPU_POD_NAME} ${CPU_POD_NAME} -n ${POD_NAMESPACE} -o wide"
echo "  oc logs ${GPU_POD_NAME} -n ${POD_NAMESPACE}"
echo "  oc logs ${CPU_POD_NAME} -n ${POD_NAMESPACE}"
printf "  LIVE=1 VIEW=both %q %q %q\n" \
  "${SCRIPT_DIR}/show-pod-cpus-grouped.sh" \
  "${NODE}" \
  "${CPU_POD_NAME}|${GPU_POD_NAME}"
echo
echo "If scheduling fails, inspect current node requests:"
echo "  oc describe node ${NODE} | sed -n '/Allocated resources:/,/Events:/p'"
