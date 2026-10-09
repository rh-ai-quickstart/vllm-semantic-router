# Internal OpenShift Registry

Use this guide when storing images in the OpenShift integrated registry.

## Key rule

```text
Push from laptop:
  external default route

Pull from Pods:
  image-registry.openshift-image-registry.svc:5000
```

Do not use the external route in Pod YAML. Kubelet may fail with route certificate errors.

## One-shot flow

Run from repo root.

```bash
set -euo pipefail

IMAGE_NS=cpu-operator-images
INTERNAL_REGISTRY=image-registry.openshift-image-registry.svc:5000

oc apply -f crds.yaml
oc apply -f rbac.yaml

# Lab/PoC registry storage. Not persistent.
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type=merge \
  -p '{"spec":{"managementState":"Managed","defaultRoute":true,"storage":{"emptyDir":{}}}}'

oc wait co/image-registry \
  --for=condition=Available=True \
  --timeout=180s || true

EXTERNAL_REGISTRY=$(oc get route default-route \
  -n openshift-image-registry \
  -o jsonpath='{.spec.host}')

oc new-project "$IMAGE_NS" || true

export USER=$(id -un)
podman login \
  -u kubeadmin \
  -p "$(oc whoami -t)" \
  --tls-verify=false \
  "$EXTERNAL_REGISTRY"

podman build -t "$EXTERNAL_REGISTRY/$IMAGE_NS/node-topology-agent:dev" agent/
podman build -t "$EXTERNAL_REGISTRY/$IMAGE_NS/cpu-operator:dev" operator/

podman push --tls-verify=false "$EXTERNAL_REGISTRY/$IMAGE_NS/node-topology-agent:dev"
podman push --tls-verify=false "$EXTERNAL_REGISTRY/$IMAGE_NS/cpu-operator:dev"

sed -i \
  "s|quay.io/YOUR_ORG/node-topology-agent:dev|$INTERNAL_REGISTRY/$IMAGE_NS/node-topology-agent:dev|g" \
  agent/daemonset.yaml

sed -i \
  "s|quay.io/YOUR_ORG/cpu-operator:dev|$INTERNAL_REGISTRY/$IMAGE_NS/cpu-operator:dev|g" \
  operator/deployment.yaml

sed -i \
  "s|$EXTERNAL_REGISTRY/$IMAGE_NS/node-topology-agent:dev|$INTERNAL_REGISTRY/$IMAGE_NS/node-topology-agent:dev|g" \
  agent/daemonset.yaml

sed -i \
  "s|$EXTERNAL_REGISTRY/$IMAGE_NS/cpu-operator:dev|$INTERNAL_REGISTRY/$IMAGE_NS/cpu-operator:dev|g" \
  operator/deployment.yaml

oc policy add-role-to-group system:image-puller \
  system:serviceaccounts:cpu-operator-system \
  -n "$IMAGE_NS"

oc adm policy add-scc-to-user privileged \
  -z node-topology-agent \
  -n cpu-operator-system

oc apply -f agent/daemonset.yaml
oc apply -f operator/deployment.yaml
oc apply -f examples/cpu-placement-policy.yaml

./scripts/sanity-check.sh
```

## Rootless Podman workaround

If rootless Podman fails with UID/GID mapping errors, use `sudo podman` for build, login, and push.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `StorageNotConfigured` | Patch registry with `storage.emptyDir` for lab |
| `default-route not found` | Wait for `image-registry` Available=True |
| Pod pull TLS error from external route | Use internal registry service in Pod YAML |
| ImagePullBackOff permission error | Grant `system:image-puller` to `system:serviceaccounts:cpu-operator-system` |
