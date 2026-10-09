#!/usr/bin/env bash
set -euo pipefail

oc apply -f crds.yaml
oc apply -f rbac.yaml
oc adm policy add-scc-to-user privileged -z node-topology-agent -n cpu-operator-system
oc apply -f agent/daemonset.yaml
oc apply -f operator/deployment.yaml
oc apply -f examples/cpu-placement-policy.yaml
./scripts/sanity-check.sh
