# External Registry

Use this guide when storing images in an external registry such as Quay, Harbor, Artifactory, or another OCI registry.

## One-shot flow

Run from repo root.

```bash
set -euo pipefail

REGISTRY=quay.io/YOUR_ORG

podman login quay.io

podman build -t "$REGISTRY/node-topology-agent:dev" agent/
podman build -t "$REGISTRY/cpu-operator:dev" operator/

podman push "$REGISTRY/node-topology-agent:dev"
podman push "$REGISTRY/cpu-operator:dev"

oc apply -f crds.yaml
oc apply -f rbac.yaml

sed -i \
  "s|quay.io/YOUR_ORG/node-topology-agent:dev|$REGISTRY/node-topology-agent:dev|g" \
  agent/daemonset.yaml

sed -i \
  "s|quay.io/YOUR_ORG/cpu-operator:dev|$REGISTRY/cpu-operator:dev|g" \
  operator/deployment.yaml

# If switching from internal registry back to external:
sed -i \
  "s|image-registry.openshift-image-registry.svc:5000/cpu-operator-images/node-topology-agent:dev|$REGISTRY/node-topology-agent:dev|g" \
  agent/daemonset.yaml

sed -i \
  "s|image-registry.openshift-image-registry.svc:5000/cpu-operator-images/cpu-operator:dev|$REGISTRY/cpu-operator:dev|g" \
  operator/deployment.yaml

oc adm policy add-scc-to-user privileged \
  -z node-topology-agent \
  -n cpu-operator-system

oc apply -f agent/daemonset.yaml
oc apply -f operator/deployment.yaml
oc apply -f examples/cpu-placement-policy.yaml

./scripts/sanity-check.sh
```

## Private registry pull secret

Skip this if images are public.

```bash
oc create secret docker-registry external-registry-pull \
  --docker-server=quay.io \
  --docker-username='<your-user>' \
  --docker-password='<your-token>' \
  --docker-email='<your-email>' \
  -n cpu-operator-system

oc secrets link node-topology-agent external-registry-pull \
  --for=pull \
  -n cpu-operator-system

oc secrets link cpu-operator external-registry-pull \
  --for=pull \
  -n cpu-operator-system
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| ImagePullBackOff | Check image name and registry reachability |
| ImagePullBackOff auth error | Create/link pull secret |
| Rootless Podman UID/GID error | Use `sudo podman` for PoC |
