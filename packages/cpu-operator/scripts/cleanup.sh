#!/usr/bin/env bash
set -euo pipefail
oc delete -f examples/cpu-placement-policy.yaml --ignore-not-found=true
oc delete -f operator/deployment.yaml --ignore-not-found=true
oc delete -f agent/daemonset.yaml --ignore-not-found=true
oc delete -f rbac.yaml --ignore-not-found=true
oc delete -f crds.yaml --ignore-not-found=true
