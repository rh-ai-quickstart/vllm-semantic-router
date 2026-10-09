#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="${CHART:-${ROOT_DIR}/deploy/helm/vllm-semantic-router}"
RELEASE="${RELEASE:-vllm-semantic-router}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-vllm-semantic-router}"
STATIC_VALUES="${STATIC_VALUES:-${CHART}/values-g7-cpu-operator.yaml}"
GENERATED_VALUES="${GENERATED_VALUES:-/tmp/values-g7-cpu-operator.generated.yaml}"
NODE="${NODE:-}"

fail() { echo "[FAIL] $*" >&2; exit 1; }
command -v oc >/dev/null || fail "oc command not found"
command -v helm >/dev/null || fail "helm command not found"
command -v python3 >/dev/null || fail "python3 command not found"
[[ -n "${HF_TOKEN:-}" ]] || fail "HF_TOKEN must be set"

if [[ -z "${NODE}" ]]; then
  NODE="$(oc get nodes -l 'cpu.example.com/node-class=mixed-cpu-amx-gpu,cpu.example.com/placement-ready=true' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
[[ -n "${NODE}" ]] || fail "No CPU Operator mixed-cpu-amx-gpu node found; set NODE explicitly"

# Fail before changing the release if the serving platform or node is unready.
oc get crd inferenceservices.serving.kserve.io servingruntimes.serving.kserve.io >/dev/null \
  || fail "Install OpenShift AI/KServe first; see docs/OPENSHIFT_AI_KSERVE.md"
oc wait --for=condition=Ready "datasciencecluster/${DSC_NAME:-default-dsc}" --timeout=60s \
  || fail "DataScienceCluster is not ready"
oc get node "${NODE}" -o json | python3 -c '
import json, sys
n = json.load(sys.stdin)
c = {x["type"]: x["status"] for x in n["status"].get("conditions", [])}
if c.get("Ready") != "True" or c.get("DiskPressure") != "False" or n.get("spec", {}).get("unschedulable"):
    raise SystemExit("Worker must be Ready, schedulable, and free of DiskPressure")
' || fail "Worker preflight failed; do not bypass disk-pressure taints"

# Toolbox HOME may be read-only. These overrides persist for this invocation.
export HELM_CONFIG_HOME="${HELM_CONFIG_HOME:-${XDG_CONFIG_HOME:-${HOME}/.config}/helm}"
export HELM_CACHE_HOME="${HELM_CACHE_HOME:-${XDG_CACHE_HOME:-${HOME}/.cache}/helm}"
export HELM_DATA_HOME="${HELM_DATA_HOME:-${XDG_DATA_HOME:-${HOME}/.local/share}/helm}"
for variable in HELM_CONFIG_HOME HELM_CACHE_HOME HELM_DATA_HOME; do
  directory="${!variable}"
  if ! mkdir -p "${directory}" 2>/dev/null || [[ ! -w "${directory}" ]]; then
    directory="${TMPDIR:-/tmp}/semantic-router-helm-${UID}/${variable}"
    mkdir -p "${directory}"
    export "${variable}=${directory}"
  fi
done
helm repo add ai-architecture-charts https://rh-ai-quickstart.github.io/ai-architecture-charts --force-update

oc explain inferenceservice.spec.predictor.deploymentStrategy >/dev/null \
  || fail "Installed KServe lacks predictor.deploymentStrategy; use the sequential update procedure in docs/OPENSHIFT_AI_KSERVE.md"
echo "[INFO] G7 model updates use maxSurge=0/maxUnavailable=1; each updated model briefly stops serving"

export NODE TARGET_NAMESPACE OUTPUT="${GENERATED_VALUES}"
"${ROOT_DIR}/scripts/generate-g7-cpu-operator-values.sh"

echo "[INFO] Generated dynamic values: ${GENERATED_VALUES}"
cat "${GENERATED_VALUES}"

echo "[INFO] Updating Helm dependencies"
helm dependency build "${CHART}"

export CPU_OPERATOR_NODE="${NODE}"
export CPU_OPERATOR_DISABLE_ISTIO="${CPU_OPERATOR_DISABLE_ISTIO:-1}"

oc get namespace "${TARGET_NAMESPACE}" >/dev/null 2>&1 || oc create namespace "${TARGET_NAMESPACE}"

# Keep lookup-suppressed shared resources in the upgrade manifest.
MANIFEST_DIR="$(mktemp -d)"
trap 'rm -rf "${MANIFEST_DIR}"' EXIT
export CPU_OPERATOR_PREVIOUS_MANIFEST="${MANIFEST_DIR}/previous.yaml"
if helm status "${RELEASE}" -n "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
  helm get manifest "${RELEASE}" -n "${TARGET_NAMESPACE}" > "${CPU_OPERATOR_PREVIOUS_MANIFEST}"
else
  : > "${CPU_OPERATOR_PREVIOUS_MANIFEST}"
fi

# A caller can supply image/storage overrides without replacing the G7 profile.
EXTRA_ARGS=()
if [[ -n "${EXTRA_VALUES:-}" ]]; then
  [[ -f "${EXTRA_VALUES}" ]] || fail "EXTRA_VALUES file does not exist"
  EXTRA_ARGS+=(-f "${EXTRA_VALUES}")
fi

helm upgrade --install "${RELEASE}" "${CHART}" \
  -n "${TARGET_NAMESPACE}" \
  -f "${CHART}/values.yaml" \
  -f "${STATIC_VALUES}" \
  -f "${GENERATED_VALUES}" \
  "${EXTRA_ARGS[@]}" \
  --set-string llm-service-research.secret.hf_token="${HF_TOKEN}" \
  --set-string llm-service-rag.secret.hf_token="${HF_TOKEN}" \
  --set-string llm-service-general.secret.hf_token="${HF_TOKEN}" \
  --set-string semanticRouter.hfToken="${HF_TOKEN}" \
  --post-renderer "${ROOT_DIR}/scripts/cpu-operator-kserve-post-renderer.py"

echo
oc get inferenceservice -n "${TARGET_NAMESPACE}" 2>/dev/null || true
oc get pods -n "${TARGET_NAMESPACE}" -o wide

for model in granite-3-1-2b-instruct granite-3-1-8b-instruct qwen3-8b; do
  oc wait --for=condition=Ready "inferenceservice/${model}" -n "${TARGET_NAMESPACE}" \
    --timeout="${MODEL_READY_TIMEOUT:-900s}" || fail "${model} is not ready; inspect pod resources/events"
  oc rollout status "deployment/${model}-predictor" -n "${TARGET_NAMESPACE}" \
    --timeout="${MODEL_READY_TIMEOUT:-900s}" || fail "${model} deployment rollout did not finish"
done
python3 "${ROOT_DIR}/scripts/kserve-guaranteed-qos.py" --verify "${TARGET_NAMESPACE}" --node "${NODE}"
echo "[INFO] Verify live CPU affinity with packages/cpu-operator/scripts/show-pod-cpus-grouped.sh; see docs/OPENSHIFT_AI_KSERVE.md"
