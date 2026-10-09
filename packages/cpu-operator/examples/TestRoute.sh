#!/usr/bin/env bash
set -uo pipefail

GPU_NS="ai-inference"
CPU_NS="ai-cpu-inference"

GPU_SVC="vllm-gpu"
CPU_SVC="vllm-cpu"


GPU_HOST=$(oc get route "$GPU_SVC" -n "$GPU_NS" -o jsonpath='{.spec.host}')
CPU_HOST=$(oc get route "$CPU_SVC" -n "$CPU_NS" -o jsonpath='{.spec.host}')

# Export env vars
export GPU_URL="http://${GPU_HOST}"
export CPU_URL="http://${CPU_HOST}"
export GPU_MODEL="Qwen/Qwen2.5-32B-Instruct-AWQ"
echo
echo "=== Result ==="
echo "GPU_URL=${GPU_URL}"
echo "CPU_URL=${CPU_URL}"

echo
echo "=== Test ==="
curl ${GPU_URL}/v1/models
echo "------"
curl ${CPU_URL}/v1/models
