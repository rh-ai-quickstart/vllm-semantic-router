#!/usr/bin/env bash
set -euo pipefail

# Generate a real vLLM CPU serving Pod and ClusterIP Service whose Guaranteed
# QoS CPU request/limit is bounded by the CPU Operator computed placement.
# Optionally append an OpenShift Route for access from a bastion/VPC client.
#
# This script intentionally reuses generate-vllm-cpu-test-pod.sh to resolve the
# selected node, policy capacity, and requested CPU count so both workload
# generators follow identical CPU Operator placement semantics.
#
# Required tools: oc, python3 (used by generate-vllm-cpu-test-pod.sh)
#
# Optional environment overrides:
#   NAMESPACE              CPU Operator namespace
#   POLICY                 CPUPlacementPolicy name
#   CM_NAME                Computed policy ConfigMap name
#   NODE                   Target worker node
#   POD_NAMESPACE          Namespace for the serving workload
#   POD_NAME               vLLM pod name
#   SERVICE_NAME           ClusterIP Service name
#   IMAGE                  vLLM CPU serving image
#   MODEL                  Hugging Face model ID
#   MEMORY                 Pod memory request/limit
#   CPU_REQUEST            Requested exclusive CPUs; defaults to policy capacity
#   TP                     vLLM tensor-parallel size
#   PORT                   vLLM HTTP port
#   HF_TOKEN_SECRET        Secret containing the Hugging Face token; empty omits it
#   HF_TOKEN_SECRET_KEY    Key in HF_TOKEN_SECRET
#   SHM_SIZE               /dev/shm size
#   EXPOSE_ROUTE           1 to append an OpenShift Route, 0 otherwise
#   ROUTE_NAME             Route name
#   OUT                    Output manifest path

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_GENERATOR="${SCRIPT_DIR}/generate-vllm-cpu-test-pod.sh"

NAMESPACE="${NAMESPACE:-cpu-operator-system}"
POLICY="${POLICY:-auto-vllm-cpu-policy}"
CM_NAME="${CM_NAME:-${POLICY}-computed-cpu-policy}"
NODE="${NODE:-}"
POD_NAMESPACE="${POD_NAMESPACE:-default}"
POD_NAME="${POD_NAME:-vllm-cpu-serving}"
SERVICE_NAME="${SERVICE_NAME:-${POD_NAME}}"
IMAGE="${IMAGE:-vllm/vllm-openai-cpu:latest-x86_64}"
MODEL="${MODEL:-meta-llama/Llama-3.1-8B-Instruct}"
MEMORY="${MEMORY:-256Gi}"
CPU_REQUEST="${CPU_REQUEST:-}"
TP="${TP:-1}"
PORT="${PORT:-8000}"
HF_TOKEN_SECRET="${HF_TOKEN_SECRET-hf-token}"
HF_TOKEN_SECRET_KEY="${HF_TOKEN_SECRET_KEY:-token}"
SHM_SIZE="${SHM_SIZE:-16Gi}"
EXPOSE_ROUTE="${EXPOSE_ROUTE:-0}"
ROUTE_NAME="${ROUTE_NAME:-${SERVICE_NAME}}"
OUT="${OUT:-examples/vllm-cpu-serving.generated.yaml}"

fail() { echo "[FAIL] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }

command -v oc >/dev/null || fail "oc command not found"
[[ -f "${BASE_GENERATOR}" ]] || fail "Missing ${BASE_GENERATOR}"
[[ "${TP}" =~ ^[1-9][0-9]*$ ]] || fail "TP must be a positive integer"
[[ "${PORT}" =~ ^[1-9][0-9]*$ ]] || fail "PORT must be a positive integer"
[[ "${EXPOSE_ROUTE}" == "0" || "${EXPOSE_ROUTE}" == "1" ]] || fail "EXPOSE_ROUTE must be 0 or 1"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
BASE_OUT="${WORKDIR}/vllm-cpu-test-pod.yaml"

info "Resolving CPU Operator placement with ${BASE_GENERATOR}"
GEN_OUTPUT="$({
  NAMESPACE="${NAMESPACE}" \
  POLICY="${POLICY}" \
  CM_NAME="${CM_NAME}" \
  NODE="${NODE}" \
  POD_NAMESPACE="${POD_NAMESPACE}" \
  POD_NAME="${POD_NAME}-placement-resolver" \
  CPU_REQUEST="${CPU_REQUEST}" \
  OUT="${BASE_OUT}" \
  bash "${BASE_GENERATOR}"
} 2>&1)" || {
  printf '%s\n' "${GEN_OUTPUT}" >&2
  fail "Failed to resolve CPU Operator placement"
}

RESOLVED_NODE=""
CPUSET=""
CPU_CAPACITY=""
RESOLVED_CPU_REQUEST=""
CPU_COUNT_COMPAT=""
NODE_CLASS=""
TOPOLOGY_GROUP=""
while IFS='=' read -r key value; do
  case "${key}" in
    NODE) RESOLVED_NODE="${value}" ;;
    CPUSET) CPUSET="${value}" ;;
    CPU_CAPACITY) CPU_CAPACITY="${value}" ;;
    CPU_REQUEST) RESOLVED_CPU_REQUEST="${value}" ;;
    CPU_COUNT) CPU_COUNT_COMPAT="${value}" ;;
    NODE_CLASS) NODE_CLASS="${value}" ;;
    TOPOLOGY_GROUP) TOPOLOGY_GROUP="${value}" ;;
  esac
done <<< "${GEN_OUTPUT}"

[[ -n "${RESOLVED_NODE}" ]] || fail "Could not resolve target node"
[[ "${CPU_CAPACITY}" =~ ^[1-9][0-9]*$ ]] || fail "Could not resolve policy CPU capacity"

if [[ -z "${RESOLVED_CPU_REQUEST}" ]]; then
  RESOLVED_CPU_REQUEST="${CPU_COUNT_COMPAT}"
fi
[[ "${RESOLVED_CPU_REQUEST}" =~ ^[1-9][0-9]*$ ]] || fail "Could not resolve workload CPU request"

if (( RESOLVED_CPU_REQUEST > CPU_CAPACITY )); then
  fail "CPU request=${RESOLVED_CPU_REQUEST} exceeds policy CPU capacity=${CPU_CAPACITY}"
fi

if (( RESOLVED_CPU_REQUEST <= TP )); then
  fail "CPU_REQUEST=${RESOLVED_CPU_REQUEST} must be greater than TP=${TP} when reserving one CPU per vLLM rank"
fi

if [[ -n "${HF_TOKEN_SECRET}" ]]; then
  if ! oc get secret "${HF_TOKEN_SECRET}" -n "${POD_NAMESPACE}" >/dev/null 2>&1; then
    warn "Secret ${POD_NAMESPACE}/${HF_TOKEN_SECRET} does not exist."
    warn "The default ${MODEL} model requires Hugging Face authorization."
    warn "Create it before applying the manifest, for example:"
    warn "  oc create secret generic ${HF_TOKEN_SECRET} -n ${POD_NAMESPACE} --from-literal=${HF_TOKEN_SECRET_KEY}=\"\${HF_TOKEN}\""
  fi
fi

mkdir -p "$(dirname "${OUT}")"

cat > "${OUT}" <<EOF_MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${POD_NAMESPACE}
  labels:
    app: ${POD_NAME}
    workload: vllm-cpu
    cpu.example.com/generated-from-policy: ${POLICY}
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${RESOLVED_NODE}
    cpu.example.com/placement-ready: "true"
EOF_MANIFEST

if [[ -n "${NODE_CLASS}" ]]; then
  cat >> "${OUT}" <<EOF_MANIFEST
    cpu.example.com/node-class: ${NODE_CLASS}
EOF_MANIFEST
fi

if [[ -n "${TOPOLOGY_GROUP}" ]]; then
  cat >> "${OUT}" <<EOF_MANIFEST
    cpu.example.com/topology-group: ${TOPOLOGY_GROUP}
EOF_MANIFEST
fi

cat >> "${OUT}" <<EOF_MANIFEST
  containers:
    - name: vllm
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent
      args:
        - ${MODEL}
        - --tensor-parallel-size
        - "${TP}"
        - --dtype
        - bfloat16
        - --distributed-executor-backend
        - mp
        - --block-size
        - "128"
        - --max-num-batched-tokens
        - "2048"
        - --max-num-seqs
        - "256"
        - --disable-log-stats
        - --host
        - "0.0.0.0"
        - --port
        - "${PORT}"
      env:
        - name: VLLM_ALLOW_LONG_MAX_MODEL_LEN
          value: "1"
        - name: VLLM_ENGINE_ITERATION_TIMEOUT_S
          value: "120"
        - name: VLLM_CPU_SGL_KERNEL
          value: "1"
        - name: VLLM_CPU_KVCACHE_SPACE
          value: "40"
        - name: VLLM_CPU_OMP_THREADS_BIND
          value: auto
        - name: VLLM_CPU_NUM_OF_RESERVED_CPU
          value: "1"
        - name: VLLM_RPC_TIMEOUT
          value: "100000"
        - name: HOME
          value: /tmp
        - name: HF_HOME
          value: /model-cache/huggingface
        - name: XDG_CACHE_HOME
          value: /model-cache/xdg
EOF_MANIFEST

if [[ -n "${HF_TOKEN_SECRET}" ]]; then
  cat >> "${OUT}" <<EOF_MANIFEST
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: ${HF_TOKEN_SECRET}
              key: ${HF_TOKEN_SECRET_KEY}
EOF_MANIFEST
fi

cat >> "${OUT}" <<EOF_MANIFEST
      ports:
        - name: http
          containerPort: ${PORT}
          protocol: TCP
      resources:
        requests:
          cpu: "${RESOLVED_CPU_REQUEST}"
          memory: "${MEMORY}"
        limits:
          cpu: "${RESOLVED_CPU_REQUEST}"
          memory: "${MEMORY}"
      volumeMounts:
        - name: shm
          mountPath: /dev/shm
        - name: model-cache
          mountPath: /model-cache
  volumes:
    - name: shm
      emptyDir:
        medium: Memory
        sizeLimit: ${SHM_SIZE}
    - name: model-cache
      emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
  namespace: ${POD_NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: ${POD_NAME}
  ports:
    - name: http
      port: ${PORT}
      targetPort: http
      protocol: TCP
EOF_MANIFEST

if [[ "${EXPOSE_ROUTE}" == "1" ]]; then
  cat >> "${OUT}" <<EOF_MANIFEST
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${ROUTE_NAME}
  namespace: ${POD_NAMESPACE}
spec:
  to:
    kind: Service
    name: ${SERVICE_NAME}
  port:
    targetPort: http
EOF_MANIFEST
fi

info "Generated ${OUT}"
echo "NODE=${RESOLVED_NODE}"
echo "CPUSET=${CPUSET}"
echo "CPU_CAPACITY=${CPU_CAPACITY}"
echo "CPU_REQUEST=${RESOLVED_CPU_REQUEST}"
# Backward-compatible alias for callers that still consume CPU_COUNT.
echo "CPU_COUNT=${RESOLVED_CPU_REQUEST}"
echo "NODE_CLASS=${NODE_CLASS}"
echo "TOPOLOGY_GROUP=${TOPOLOGY_GROUP}"
echo "MODEL=${MODEL}"
echo "TP=${TP}"
echo "SERVICE=${POD_NAMESPACE}/${SERVICE_NAME}"
echo "ROUTE_ENABLED=${EXPOSE_ROUTE}"
echo
echo "Apply with:"
echo "  oc apply -f ${OUT}"
echo
echo "Watch startup:"
echo "  oc logs -f ${POD_NAME} -n ${POD_NAMESPACE}"
echo
echo "Validate CPU placement:"
printf "  LIVE=1 VIEW=both scripts/show-pod-cpus-grouped.sh %q '%s|vllm-cpu'\n" "${RESOLVED_NODE}" "${POD_NAME}"
echo
echo "Cluster-internal endpoint:"
echo "  http://${SERVICE_NAME}.${POD_NAMESPACE}.svc:${PORT}/v1/models"

if [[ "${EXPOSE_ROUTE}" == "1" ]]; then
  echo
  echo "After the Route is admitted, get its host with:"
  echo "  oc get route ${ROUTE_NAME} -n ${POD_NAMESPACE} -o jsonpath='{.spec.host}{\"\\n\"}'"
  echo "Then call it from a bastion that can reach the internal OpenShift ingress."
else
  echo
  echo "For a temporary bastion-side test without a Route:"
  echo "  oc port-forward pod/${POD_NAME} -n ${POD_NAMESPACE} ${PORT}:${PORT}"
  echo "  curl http://127.0.0.1:${PORT}/v1/models"
fi
