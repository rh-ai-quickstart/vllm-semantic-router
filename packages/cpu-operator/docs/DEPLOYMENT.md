# Deployment Guide

This guide covers image preparation, OpenShift installation, generic Kubernetes deployment, provider selection, verification, upgrades, and cleanup.

## Choose a provider mode

| Cluster | Recommended starting mode | Result |
|---|---|---|
| OpenShift | `provider.type: OpenShift`, `applyMode: RecommendationOnly` | Generates MachineConfigPool, KubeletConfig, and optional Tuned manifests for review. |
| OpenShift after review | `provider.type: OpenShift`, `applyMode: Managed` | Applies provider resources and monitors the resulting state. |
| Generic Kubernetes or kubeadm | `provider.type: GenericKubernetes`, `applyMode: RecommendationOnly` | Produces per-node kubelet configuration and a safe external apply plan. |

The repository example `examples/cpu-placement-policy.yaml` uses OpenShift managed mode. The example `examples/cpu-placement-policy-generic.yaml` uses generic recommendation-only mode.

## Prerequisites

### Common

- Kubernetes API access with permission to create cluster-scoped CRDs and RBAC;
- worker nodes selected by `node-role.kubernetes.io/worker` or an edited selector;
- a registry accessible from every selected worker;
- `python3` for validation utilities;
- Docker or Podman when building images.

### OpenShift

- `oc` CLI;
- cluster-admin-equivalent permission for CRDs, RBAC, SCC, MachineConfigPool, KubeletConfig, and optional Tuned resources;
- healthy Machine Config Operator before managed apply;
- sufficient maintenance capacity for worker drains or reboots.

### Generic Kubernetes

- `kubectl` CLI;
- permission for hostPath mounts used by the topology agent;
- an external process for applying rendered kubelet configuration;
- a maintenance procedure that can cordon, drain, restart kubelet, and recover a node.

If generic worker nodes do not have the expected label, label them or edit the DaemonSet and policy selectors:

```bash
kubectl label node <worker-node> node-role.kubernetes.io/worker=""
```

## Choose container images

### Use the prebuilt Quay images first

The checked-in deployment manifests use these proof-of-concept images:

| Component | Quay repository page | Pull and deployment image reference |
|---|---|---|
| Node Topology Agent | <https://quay.io/repository/louie_tsai/node-topology-agent> | `quay.io/louie_tsai/node-topology-agent:dev` |
| CPU Operator | <https://quay.io/repository/louie_tsai/cpu-operator> | `quay.io/louie_tsai/cpu-operator:dev` |

The URL containing `/repository/` is a browser page for viewing tags and repository information. Docker, Podman, and Kubernetes require the image reference from the last column.

Verify that the images are pullable:

```bash
docker pull quay.io/louie_tsai/node-topology-agent:dev
docker pull quay.io/louie_tsai/cpu-operator:dev

# Podman equivalent
podman pull quay.io/louie_tsai/node-topology-agent:dev
podman pull quay.io/louie_tsai/cpu-operator:dev
```

Confirm the manifests use the expected images:

```bash
grep image agent/daemonset.yaml operator/deployment.yaml
```

Expected references:

```text
quay.io/louie_tsai/node-topology-agent:dev
quay.io/louie_tsai/cpu-operator:dev
```

The `dev` tag is intended for evaluating the current proof of concept. Controlled deployments should use a versioned immutable tag or image digest from a registry managed by the deploying organization.

### Optional: build and publish custom images

Build custom images when modifying the source or using an internal registry.

From the repository root:

```bash
REGISTRY=quay.io
REGISTRY_NS=<your-registry-namespace>
TAG=<version-or-development-tag>

AGENT_IMAGE=${REGISTRY}/${REGISTRY_NS}/node-topology-agent:${TAG}
OPERATOR_IMAGE=${REGISTRY}/${REGISTRY_NS}/cpu-operator:${TAG}

docker build -t "${AGENT_IMAGE}" agent/
docker build -t "${OPERATOR_IMAGE}" operator/
docker login "${REGISTRY}"
docker push "${AGENT_IMAGE}"
docker push "${OPERATOR_IMAGE}"
```

Replace Docker with Podman when appropriate.

Update the manifests:

```bash
sed -i "s|image: .*node-topology-agent:.*|image: ${AGENT_IMAGE}|" \
  agent/daemonset.yaml

sed -i "s|image: .*cpu-operator:.*|image: ${OPERATOR_IMAGE}|" \
  operator/deployment.yaml

grep image agent/daemonset.yaml operator/deployment.yaml
```

For private registries, create an image pull secret and attach it to both service accounts or add `imagePullSecrets` to the pod specifications. Confirm that a worker can pull the images before debugging operator behavior.

## OpenShift installation

### 1. Install namespace, accounts, and RBAC

`rbac.yaml` creates the `cpu-operator-system` namespace, service accounts, ClusterRoles, and ClusterRoleBindings:

```bash
oc apply -f rbac.yaml
```

### 2. Install CRDs

```bash
oc apply -f crds.yaml
```

Verify the API resources:

```bash
oc api-resources | grep -E 'CPUPlacementPolicy|NodeCPUTopology'
```

### 3. Grant host access to the topology agent

The agent mounts the host's `/sys` and `/proc` read-only. On OpenShift, grant the service account the privileged SCC:

```bash
oc adm policy add-scc-to-user privileged \
  -z node-topology-agent \
  -n cpu-operator-system
```

Review this permission in environments with stricter security requirements.

### 4. Deploy the agent and operator

```bash
oc apply -f agent/daemonset.yaml
oc apply -f operator/deployment.yaml

oc rollout status ds/node-topology-agent -n cpu-operator-system
oc rollout status deploy/cpu-operator -n cpu-operator-system
```

### 5. Review the policy

The example policy includes:

```yaml
provider:
  type: OpenShift
  applyMode: Managed
```

For a safer first reconciliation, change `applyMode` to `RecommendationOnly`, apply the policy, inspect generated resources in the computed ConfigMap, and then switch to `Managed`.

Important fields:

```yaml
targetNodeSelector:
  node-role.kubernetes.io/worker: ""

openshift:
  machineConfigPoolNamePrefix: cpu
  manageKubeletConfig: true
  manageTuned: false
  topologyManagerScope: pod
```

### 6. Apply the policy

```bash
oc apply -f examples/cpu-placement-policy.yaml
```

### 7. Verify discovery and reconciliation

```bash
oc get pods -n cpu-operator-system -o wide
oc get nodecputopologies -n cpu-operator-system
oc get cpuplacementpolicies -n cpu-operator-system

CM=auto-vllm-cpu-policy-computed-cpu-policy
oc get configmap "${CM}" -n cpu-operator-system -o yaml
```

Check generated node labels:

```bash
oc get nodes \
  -L cpu.example.com/node-class,cpu.example.com/placement-strategy,cpu.example.com/topology-group,cpu.example.com/phase4-applied
```

In managed mode, check provider objects and MCO rollout:

```bash
oc get mcp
oc get kubeletconfig
oc get nodes
```

Do not schedule validation workloads until the target pools are Updated and worker nodes are Ready.

## Generic Kubernetes deployment

### 1. Install shared resources

```bash
kubectl apply -f rbac.yaml
kubectl apply -f crds.yaml
```

The RBAC contains permissions for OpenShift API groups. Kubernetes accepts those RBAC rules even when the corresponding APIs are not installed; the generic provider does not use them.

### 2. Satisfy pod security requirements

The topology agent uses hostPath volumes. Configure Pod Security Admission or an equivalent policy so the `cpu-operator-system` namespace can run the agent. The exact command is cluster-specific and should follow the cluster's security policy.

### 3. Deploy runtime components

```bash
kubectl apply -f agent/daemonset.yaml
kubectl apply -f operator/deployment.yaml

kubectl rollout status ds/node-topology-agent -n cpu-operator-system
kubectl rollout status deploy/cpu-operator -n cpu-operator-system
```

### 4. Apply the generic policy

```bash
kubectl apply -f examples/cpu-placement-policy-generic.yaml
```

### 5. Retrieve rendered configuration

```bash
POLICY=generic-vllm-cpu-policy
CM=${POLICY}-computed-cpu-policy
OUTPUT_CM=${POLICY}-generated-kubelet-config

kubectl get configmap "${CM}" -n cpu-operator-system -o yaml
kubectl get configmap "${OUTPUT_CM}" -n cpu-operator-system -o yaml
```

The output ConfigMap contains one `<node>.kubelet-config.yaml` entry for each selected worker and `apply-plan.yaml`.

### 6. Apply configuration outside the operator

Use cluster maintenance automation to perform the generated plan:

1. cordon and drain the node;
2. stop kubelet;
3. back up the current kubelet configuration;
4. write the rendered configuration;
5. remove `/var/lib/kubelet/cpu_manager_state` when changing CPU Manager policy;
6. start kubelet;
7. wait for the node to become Ready;
8. uncordon the node;
9. run the validation sequence in [Testing and Validation](TESTING.md).

Applying kubelet configuration incorrectly can make a worker unavailable. Keep console or out-of-band recovery access.

## Logs and diagnostics

```bash
# OpenShift
oc logs -n cpu-operator-system ds/node-topology-agent
oc logs -n cpu-operator-system deploy/cpu-operator

# Generic Kubernetes
kubectl logs -n cpu-operator-system ds/node-topology-agent
kubectl logs -n cpu-operator-system deploy/cpu-operator
```

Useful resources:

```bash
oc get nodecputopologies -n cpu-operator-system -o yaml
oc get cpuplacementpolicies -n cpu-operator-system -o yaml
oc get events -n cpu-operator-system --sort-by=.lastTimestamp
```

Replace `oc` with `kubectl` on generic Kubernetes.

## Upgrade procedure

1. build and push new immutable image tags;
2. update `agent/daemonset.yaml` and `operator/deployment.yaml`;
3. apply CRD changes before deploying code that requires them;
4. apply RBAC changes;
5. roll out the agent and operator;
6. review generated policy changes before enabling managed apply;
7. validate one worker from each topology group.

```bash
oc apply -f crds.yaml
oc apply -f rbac.yaml
oc apply -f agent/daemonset.yaml
oc apply -f operator/deployment.yaml
```

Avoid reusing a mutable `dev` tag for controlled environments.

## Cleanup

Delete the policy first so the operator stops reconciling it:

```bash
oc delete -f examples/cpu-placement-policy.yaml
oc delete -f operator/deployment.yaml
oc delete -f agent/daemonset.yaml
```

Review generated MachineConfigPools, KubeletConfigs, Tuned resources, and node labels before deleting them. Removing these resources can trigger another MCO rollout.

Remove CRDs and RBAC only after their custom resources are no longer needed:

```bash
oc delete -f crds.yaml
oc delete -f rbac.yaml
```

Use `kubectl` and the generic example policy on generic Kubernetes.
