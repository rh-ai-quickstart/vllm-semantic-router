#!/usr/bin/env bash
set -euo pipefail

# Generate paired real vLLM CPU and GPU serving workloads for one
# mixed-cpu-amx-gpu worker.
#
# Placement/sizing semantics:
#   * GPU serving CPU request defaults to all gpuPodReservedCPUs.
#   * CPU serving policy target defaults to:
#       cpuPodCPUSet capacity - (CPU_HEADROOM_PER_NUMA * NUMA_COUNT)
#   * CPU serving request is capped to the scheduler-safe whole-CPU capacity
#     after existing pod CPU requests and the GPU serving request are counted.
#   * Lightweight vllm-cpu-test/vllm-gpu-test pods are treated as replacement
#     workloads and excluded from existing scheduler demand by default.
#
# Exact CPU IDs are selected by kubelet CPU Manager. gpuPodCPUSet and
# cpuPodCPUSet are capacity/reference sets, not named cpusets passed to pods.
#
# This script reuses generate-vllm-cpu-serving-pod.sh for the CPU serving half
# and generates the GPU serving Pod/Service/optional Route itself.
#
# Required tools: oc, python3
#
# Common overrides:
#   NODE                    Target mixed-cpu-amx-gpu worker
#   POD_NAMESPACE           Namespace for both serving workloads (default: default)
#   CPU_HEADROOM_PER_NUMA   CPU policy headroom per NUMA node (default: 1)
#   CPU_REQUEST             Explicit CPU serving request; default is policy/scheduler derived
#   GPU_CPU_REQUEST         Explicit GPU-serving CPU request; default gpuPodReservedCPUs
#   GPU_REQUEST             GPUs requested by GPU serving pod (default: 1)
#   CPU_MEMORY              CPU pod memory request/limit (default: 96Gi)
#   GPU_MEMORY              GPU pod host-memory request/limit (default: 32Gi)
#   CPU_MODEL               CPU vLLM model
#   GPU_MODEL               GPU vLLM model
#   CPU_IMAGE               CPU vLLM image
#   GPU_IMAGE               GPU vLLM image
#   CPU_TP                  CPU vLLM tensor parallel size (default: 1)
#   GPU_TP                  GPU vLLM tensor parallel size (default: GPU_REQUEST)
#   GPU_EXTRA_ARGS          Additional GPU vLLM serve arguments
#   EXPOSE_ROUTES           1 to append OpenShift Routes for both services
#   REPLACE_PODS            Comma-separated namespace/name pods excluded from existing demand
#   CPU_OUT                 CPU serving manifest output
#   GPU_OUT                 GPU serving manifest output

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CPU_SERVING_GENERATOR="${CPU_SERVING_GENERATOR:-${SCRIPT_DIR}/generate-vllm-cpu-serving-pod.sh}"

NAMESPACE="${NAMESPACE:-cpu-operator-system}"
POLICY="${POLICY:-auto-vllm-cpu-policy}"
CM_NAME="${CM_NAME:-${POLICY}-computed-cpu-policy}"
NODE="${NODE:-}"
POD_NAMESPACE="${POD_NAMESPACE:-default}"

CPU_POD_NAME="${CPU_POD_NAME:-vllm-cpu-serving}"
GPU_POD_NAME="${GPU_POD_NAME:-vllm-gpu-serving}"
CPU_SERVICE_NAME="${CPU_SERVICE_NAME:-${CPU_POD_NAME}}"
GPU_SERVICE_NAME="${GPU_SERVICE_NAME:-${GPU_POD_NAME}}"
CPU_ROUTE_NAME="${CPU_ROUTE_NAME:-${CPU_SERVICE_NAME}}"
GPU_ROUTE_NAME="${GPU_ROUTE_NAME:-${GPU_SERVICE_NAME}}"

CPU_IMAGE="${CPU_IMAGE:-vllm/vllm-openai-cpu:latest-x86_64}"
GPU_IMAGE="${GPU_IMAGE:-vllm/vllm-openai:latest}"
CPU_MODEL="${CPU_MODEL:-meta-llama/Llama-3.1-8B-Instruct}"
GPU_MODEL="${GPU_MODEL:-Qwen/Qwen2.5-7B-Instruct}"

CPU_MEMORY="${CPU_MEMORY:-96Gi}"
GPU_MEMORY="${GPU_MEMORY:-32Gi}"
CPU_SHM_SIZE="${CPU_SHM_SIZE:-16Gi}"
GPU_SHM_SIZE="${GPU_SHM_SIZE:-8Gi}"
CPU_REQUEST="${CPU_REQUEST:-}"
GPU_CPU_REQUEST="${GPU_CPU_REQUEST:-}"
GPU_REQUEST="${GPU_REQUEST:-1}"
CPU_HEADROOM_PER_NUMA="${CPU_HEADROOM_PER_NUMA:-1}"
CPU_TP="${CPU_TP:-1}"
GPU_TP="${GPU_TP:-${GPU_REQUEST}}"
CPU_PORT="${CPU_PORT:-8001}"
GPU_PORT="${GPU_PORT:-8000}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"
GPU_MAX_MODEL_LEN="${GPU_MAX_MODEL_LEN:-4096}"
GPU_MAX_NUM_SEQS="${GPU_MAX_NUM_SEQS:-64}"
GPU_EXTRA_ARGS="${GPU_EXTRA_ARGS:-}"

HF_TOKEN_SECRET="${HF_TOKEN_SECRET-hf-token}"
HF_TOKEN_SECRET_KEY="${HF_TOKEN_SECRET_KEY:-token}"
EXPOSE_ROUTES="${EXPOSE_ROUTES:-0}"
CPU_OUT="${CPU_OUT:-examples/vllm-cpu-serving.generated.yaml}"
GPU_OUT="${GPU_OUT:-examples/vllm-gpu-serving.generated.yaml}"
REPLACE_PODS="${REPLACE_PODS:-${POD_NAMESPACE}/vllm-cpu-test,${POD_NAMESPACE}/vllm-gpu-test}"

fail() { echo "[FAIL] $*" >&2; exit 1; }
warn() { echo "[WARN] $*" >&2; }
info() { echo "[INFO] $*"; }

command -v oc >/dev/null || fail "oc command not found"
command -v python3 >/dev/null || fail "python3 command not found"
[[ -x "${CPU_SERVING_GENERATOR}" ]] || fail "CPU serving generator is not executable: ${CPU_SERVING_GENERATOR}"
[[ "${GPU_REQUEST}" =~ ^[1-9][0-9]*$ ]] || fail "GPU_REQUEST must be a positive integer"
[[ "${CPU_HEADROOM_PER_NUMA}" =~ ^[0-9]+$ ]] || fail "CPU_HEADROOM_PER_NUMA must be a non-negative integer"
[[ "${CPU_TP}" =~ ^[1-9][0-9]*$ ]] || fail "CPU_TP must be a positive integer"
[[ "${GPU_TP}" =~ ^[1-9][0-9]*$ ]] || fail "GPU_TP must be a positive integer"
[[ "${CPU_PORT}" =~ ^[1-9][0-9]*$ ]] || fail "CPU_PORT must be a positive integer"
[[ "${GPU_PORT}" =~ ^[1-9][0-9]*$ ]] || fail "GPU_PORT must be a positive integer"
[[ "${EXPOSE_ROUTES}" == "0" || "${EXPOSE_ROUTES}" == "1" ]] || fail "EXPOSE_ROUTES must be 0 or 1"
(( GPU_TP <= GPU_REQUEST )) || fail "GPU_TP=${GPU_TP} cannot exceed GPU_REQUEST=${GPU_REQUEST}"

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
[[ -n "${NODE}" ]] || fail "Could not determine target NODE"

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
  "${GPU_POD_NAME}" \
  "${REPLACE_PODS}" <<'PY'
import json
import re
import shlex
import sys
from pathlib import Path

(
    placement_path,
    labels_path,
    topology_path,
    node_path,
    pods_path,
    node,
    pod_namespace,
    cpu_pod_name,
    gpu_pod_name,
    replace_pods_raw,
) = sys.argv[1:]

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

replace_pods = set()
for entry in replace_pods_raw.split(","):
    entry = entry.strip()
    if entry:
        replace_pods.add(entry)
replace_pods.update({f"{pod_namespace}/{cpu_pod_name}", f"{pod_namespace}/{gpu_pod_name}"})


def container_cpu_request_m(container):
    requests = ((container.get("resources") or {}).get("requests") or {})
    return cpu_quantity_to_millicores(requests.get("cpu", "0"))

existing_cpu_request_m = 0
existing_request_pods = []
excluded_request_pods = []
for pod in pods_json.get("items", []):
    meta = pod.get("metadata") or {}
    spec = pod.get("spec") or {}
    status_obj = pod.get("status") or {}
    if status_obj.get("phase") in {"Succeeded", "Failed"}:
        continue

    pod_key = f"{meta.get('namespace', 'default')}/{meta.get('name', '?')}"
    app_request_m = sum(container_cpu_request_m(c) for c in (spec.get("containers") or []))
    init_request_m = max(
        [container_cpu_request_m(c) for c in (spec.get("initContainers") or [])] or [0]
    )
    overhead_m = cpu_quantity_to_millicores((spec.get("overhead") or {}).get("cpu", "0"))
    pod_request_m = max(app_request_m, init_request_m) + overhead_m

    if pod_key in replace_pods:
        if pod_request_m:
            excluded_request_pods.append(f"{pod_key}={pod_request_m}m")
        continue

    existing_cpu_request_m += pod_request_m
    if pod_request_m:
        existing_request_pods.append(f"{pod_key}={pod_request_m}m")

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
    "EXCLUDED_REPLACEMENT_PODS": ",".join(excluded_request_pods),
}
for key, value in values.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
)"

# shellcheck disable=SC1090
source <(printf '%s\n' "${PY_OUT}")

[[ "${NODE_CLASS}" == "mixed-cpu-amx-gpu" ]] \
  || fail "Node ${NODE} class is ${NODE_CLASS:-unknown}; paired serving requires mixed-cpu-amx-gpu"
(( NODE_ALLOCATABLE_GPU >= GPU_REQUEST )) \
  || fail "GPU_REQUEST=${GPU_REQUEST} exceeds node allocatable GPU=${NODE_ALLOCATABLE_GPU}"

if [[ -z "${GPU_CPU_REQUEST}" ]]; then
  GPU_CPU_REQUEST="${GPU_RESERVED_CPUS}"
fi
[[ "${GPU_CPU_REQUEST}" =~ ^[1-9][0-9]*$ ]] || fail "GPU_CPU_REQUEST must be a positive integer"
(( GPU_CPU_REQUEST <= GPU_CPU_CAPACITY )) \
  || fail "GPU_CPU_REQUEST=${GPU_CPU_REQUEST} exceeds gpuPodCPUSet capacity=${GPU_CPU_CAPACITY}"

CPU_HEADROOM_TOTAL=$((CPU_HEADROOM_PER_NUMA * NUMA_COUNT))
CPU_POLICY_TARGET=$((CPU_CAPACITY - CPU_HEADROOM_TOTAL))
(( CPU_POLICY_TARGET > 0 )) \
  || fail "CPU policy target is not positive: capacity=${CPU_CAPACITY} headroom=${CPU_HEADROOM_TOTAL}"

SCHEDULER_CPU_BUDGET_M=$((NODE_ALLOCATABLE_CPU_M - EXISTING_NODE_CPU_REQUEST_M - GPU_CPU_REQUEST * 1000))
SCHEDULER_CPU_CAP=$((SCHEDULER_CPU_BUDGET_M / 1000))
(( SCHEDULER_CPU_CAP > 0 )) \
  || fail "No whole CPU remains for CPU serving after existing requests plus GPU serving demand"

CPU_REQUEST_EXPLICIT=0
if [[ -n "${CPU_REQUEST}" ]]; then
  CPU_REQUEST_EXPLICIT=1
else
  CPU_REQUEST="${CPU_POLICY_TARGET}"
  if (( CPU_REQUEST > SCHEDULER_CPU_CAP )); then
    warn "CPU policy target=${CPU_POLICY_TARGET} cannot co-schedule with GPU serving and existing pod requests"
    warn "Reducing CPU serving request to scheduler-safe cap=${SCHEDULER_CPU_CAP}"
    CPU_REQUEST="${SCHEDULER_CPU_CAP}"
  fi
fi
[[ "${CPU_REQUEST}" =~ ^[1-9][0-9]*$ ]] || fail "CPU_REQUEST must be a positive integer"
(( CPU_REQUEST <= CPU_CAPACITY )) \
  || fail "CPU_REQUEST=${CPU_REQUEST} exceeds cpuPodCPUSet capacity=${CPU_CAPACITY}"
(( CPU_REQUEST <= SCHEDULER_CPU_CAP )) \
  || fail "CPU_REQUEST=${CPU_REQUEST} exceeds scheduler-safe cap=${SCHEDULER_CPU_CAP}"

if (( THREADS_PER_CORE > 1 )); then
  (( GPU_CPU_REQUEST % THREADS_PER_CORE == 0 )) \
    || fail "GPU_CPU_REQUEST=${GPU_CPU_REQUEST} is not aligned to THREADS_PER_CORE=${THREADS_PER_CORE}"
  if (( CPU_REQUEST % THREADS_PER_CORE != 0 )); then
    if (( CPU_REQUEST_EXPLICIT == 1 )); then
      fail "CPU_REQUEST=${CPU_REQUEST} is not aligned to THREADS_PER_CORE=${THREADS_PER_CORE}"
    fi
    ALIGNED_CPU_REQUEST=$((CPU_REQUEST / THREADS_PER_CORE * THREADS_PER_CORE))
    (( ALIGNED_CPU_REQUEST > 0 )) || fail "No full physical-core-aligned CPU serving request remains"
    warn "Reducing CPU serving request from ${CPU_REQUEST} to full-core-aligned ${ALIGNED_CPU_REQUEST}"
    CPU_REQUEST="${ALIGNED_CPU_REQUEST}"
  fi
fi

COMBINED_CPU_REQUEST=$((GPU_CPU_REQUEST + CPU_REQUEST))
HEADROOM_M=$((NODE_ALLOCATABLE_CPU_M - EXISTING_NODE_CPU_REQUEST_M - COMBINED_CPU_REQUEST * 1000))
(( HEADROOM_M >= 0 )) \
  || fail "Combined serving CPU request exceeds scheduler-safe node capacity"

info "Selected node and derived real-serving sizing"
echo "NODE=${NODE}"
echo "NODE_CLASS=${NODE_CLASS}"
echo "TOPOLOGY_GROUP=${TOPOLOGY_GROUP}"
echo "NUMA_COUNT=${NUMA_COUNT}"
echo "THREADS_PER_CORE=${THREADS_PER_CORE}"
echo "GPU_LOCAL_NUMA_NODES=${GPU_LOCAL_NUMA_NODES:-unknown}"
echo "NODE_ALLOCATABLE_CPU=${NODE_ALLOCATABLE_CPU}"
echo "NODE_ALLOCATABLE_GPU=${NODE_ALLOCATABLE_GPU}"
echo "EXISTING_NODE_CPU_REQUEST=${EXISTING_NODE_CPU_REQUEST_M}m"
[[ -n "${EXISTING_NODE_CPU_REQUEST_PODS:-}" ]] && echo "EXISTING_NODE_CPU_REQUEST_PODS=${EXISTING_NODE_CPU_REQUEST_PODS}"
[[ -n "${EXCLUDED_REPLACEMENT_PODS:-}" ]] && echo "EXCLUDED_REPLACEMENT_PODS=${EXCLUDED_REPLACEMENT_PODS}"
echo
echo "GPU serving: policySet=${GPU_CPUSET} capacity=${GPU_CPU_CAPACITY} cpuRequest=${GPU_CPU_REQUEST} gpuRequest=${GPU_REQUEST} tp=${GPU_TP}"
echo "CPU serving: policySet=${CPUSET} capacity=${CPU_CAPACITY} headroom=${CPU_HEADROOM_PER_NUMA}x${NUMA_COUNT}=${CPU_HEADROOM_TOTAL} policyTarget=${CPU_POLICY_TARGET} schedulerCap=${SCHEDULER_CPU_CAP} cpuRequest=${CPU_REQUEST} tp=${CPU_TP}"
echo "Combined serving exclusive CPU request=${COMBINED_CPU_REQUEST}"
echo "Scheduler CPU headroom after existing requests and serving pair=${HEADROOM_M}m"

if [[ -n "${HF_TOKEN_SECRET}" ]] && ! oc get secret "${HF_TOKEN_SECRET}" -n "${POD_NAMESPACE}" >/dev/null 2>&1; then
  warn "Secret ${POD_NAMESPACE}/${HF_TOKEN_SECRET} does not exist"
  warn "CPU model ${CPU_MODEL} may require Hugging Face authorization"
fi

# Reuse the existing CPU real-serving generator.
NAMESPACE="${NAMESPACE}" \
POLICY="${POLICY}" \
CM_NAME="${CM_NAME}" \
NODE="${NODE}" \
POD_NAMESPACE="${POD_NAMESPACE}" \
POD_NAME="${CPU_POD_NAME}" \
SERVICE_NAME="${CPU_SERVICE_NAME}" \
ROUTE_NAME="${CPU_ROUTE_NAME}" \
IMAGE="${CPU_IMAGE}" \
MODEL="${CPU_MODEL}" \
MEMORY="${CPU_MEMORY}" \
CPU_REQUEST="${CPU_REQUEST}" \
TP="${CPU_TP}" \
PORT="${CPU_PORT}" \
HF_TOKEN_SECRET="${HF_TOKEN_SECRET}" \
HF_TOKEN_SECRET_KEY="${HF_TOKEN_SECRET_KEY}" \
SHM_SIZE="${CPU_SHM_SIZE}" \
EXPOSE_ROUTE="${EXPOSE_ROUTES}" \
OUT="${CPU_OUT}" \
"${CPU_SERVING_GENERATOR}"

mkdir -p "$(dirname "${GPU_OUT}")"
cat > "${GPU_OUT}" <<EOF_MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: ${GPU_POD_NAME}
  namespace: ${POD_NAMESPACE}
  labels:
    app: ${GPU_POD_NAME}
    workload: vllm-gpu
    cpu.example.com/generated-from-policy: ${POLICY}
spec:
  restartPolicy: Never
  enableServiceLinks: false
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
    - name: vllm
      image: ${GPU_IMAGE}
      imagePullPolicy: IfNotPresent
      command:
        - /bin/bash
        - -lc
        - |
          set -e
          extra_args=()
          if [[ -n "\${GPU_EXTRA_ARGS:-}" ]]; then
            # GPU_EXTRA_ARGS is intentionally shell-split into vLLM CLI tokens.
            read -r -a extra_args <<< "\${GPU_EXTRA_ARGS}"
          fi
          exec vllm serve "\${MODEL}" \\
            --host 0.0.0.0 \\
            --port "${GPU_PORT}" \\
            --tensor-parallel-size "${GPU_TP}" \\
            --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}" \\
            --max-model-len "${GPU_MAX_MODEL_LEN}" \\
            --max-num-seqs "${GPU_MAX_NUM_SEQS}" \\
            "\${extra_args[@]}"
      env:
        - name: MODEL
          value: "${GPU_MODEL}"
        - name: GPU_EXTRA_ARGS
          value: >-
            ${GPU_EXTRA_ARGS}
        - name: HOME
          value: /tmp
        - name: HF_HOME
          value: /model-cache/huggingface
        - name: XDG_CACHE_HOME
          value: /model-cache/xdg
EOF_MANIFEST

if [[ -n "${HF_TOKEN_SECRET}" ]]; then
  cat >> "${GPU_OUT}" <<EOF_MANIFEST
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: ${HF_TOKEN_SECRET}
              key: ${HF_TOKEN_SECRET_KEY}
              optional: true
EOF_MANIFEST
fi

cat >> "${GPU_OUT}" <<EOF_MANIFEST
      ports:
        - name: http
          containerPort: ${GPU_PORT}
          protocol: TCP
      resources:
        requests:
          cpu: "${GPU_CPU_REQUEST}"
          memory: "${GPU_MEMORY}"
          nvidia.com/gpu: "${GPU_REQUEST}"
        limits:
          cpu: "${GPU_CPU_REQUEST}"
          memory: "${GPU_MEMORY}"
          nvidia.com/gpu: "${GPU_REQUEST}"
      volumeMounts:
        - name: shm
          mountPath: /dev/shm
        - name: model-cache
          mountPath: /model-cache
  volumes:
    - name: shm
      emptyDir:
        medium: Memory
        sizeLimit: ${GPU_SHM_SIZE}
    - name: model-cache
      emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${GPU_SERVICE_NAME}
  namespace: ${POD_NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: ${GPU_POD_NAME}
  ports:
    - name: http
      port: ${GPU_PORT}
      targetPort: http
      protocol: TCP
EOF_MANIFEST

if [[ "${EXPOSE_ROUTES}" == "1" ]]; then
  cat >> "${GPU_OUT}" <<EOF_MANIFEST
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${GPU_ROUTE_NAME}
  namespace: ${POD_NAMESPACE}
spec:
  to:
    kind: Service
    name: ${GPU_SERVICE_NAME}
  port:
    targetPort: http
EOF_MANIFEST
fi

info "Generated ${GPU_OUT}"
echo
echo "Transition from lightweight tests to real vLLM serving:"
echo "  LIVE=1 VIEW=both ${SCRIPT_DIR}/show-pod-cpus-grouped.sh ${NODE} 'vllm-cpu-test|vllm-gpu-test'"
echo "  oc delete pod vllm-cpu-test vllm-gpu-test -n ${POD_NAMESPACE} --ignore-not-found"
echo "  oc wait --for=delete pod/vllm-cpu-test -n ${POD_NAMESPACE} --timeout=120s 2>/dev/null || true"
echo "  oc wait --for=delete pod/vllm-gpu-test -n ${POD_NAMESPACE} --timeout=120s 2>/dev/null || true"
echo
echo "Apply GPU serving first, then CPU serving:"
echo "  oc apply -f ${GPU_OUT}"
echo "  oc wait --for=condition=Ready pod/${GPU_POD_NAME} -n ${POD_NAMESPACE} --timeout=600s"
echo "  oc apply -f ${CPU_OUT}"
echo "  oc wait --for=condition=Ready pod/${CPU_POD_NAME} -n ${POD_NAMESPACE} --timeout=600s"
echo
echo "Validate placement:"
echo "  LIVE=1 VIEW=both ${SCRIPT_DIR}/show-pod-cpus-grouped.sh ${NODE} '${CPU_POD_NAME}|${GPU_POD_NAME}'"
echo
echo "Cluster-internal endpoints:"
echo "  GPU: http://${GPU_SERVICE_NAME}.${POD_NAMESPACE}.svc:${GPU_PORT}/v1/models"
echo "  CPU: http://${CPU_SERVICE_NAME}.${POD_NAMESPACE}.svc:${CPU_PORT}/v1/models"
if [[ "${EXPOSE_ROUTES}" == "1" ]]; then
  echo
  echo "Route hosts:"
  echo "  oc get route ${GPU_ROUTE_NAME} ${CPU_ROUTE_NAME} -n ${POD_NAMESPACE}"
fi
