#!/usr/bin/env bash
set -euo pipefail

REGISTRY="${REGISTRY:-quay.io/YOUR_ORG}"

podman build -t "${REGISTRY}/node-topology-agent:dev" agent/
podman build -t "${REGISTRY}/cpu-operator:dev" operator/

podman push "${REGISTRY}/node-topology-agent:dev"
podman push "${REGISTRY}/cpu-operator:dev"

echo "Pushed:"
echo "  ${REGISTRY}/node-topology-agent:dev"
echo "  ${REGISTRY}/cpu-operator:dev"
echo
echo "Now replace image names in:"
echo "  agent/daemonset.yaml"
echo "  operator/deployment.yaml"
