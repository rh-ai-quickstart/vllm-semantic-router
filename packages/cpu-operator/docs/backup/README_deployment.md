# Option A: Deploy CPU Operator with Public Quay.io Images

This guide describes how to build the CPU Operator images, push them to a public Quay.io registry, deploy them on OpenShift, and validate the deployment.

This option uses Quay.io as an external public registry. OpenShift worker nodes pull images directly from Quay, so you do **not** need to set up the OpenShift internal image registry.

---

## 1. Build and Push Images to Quay.io

From the repository root:

```bash
REGISTRY=quay.io
REGISTRY_NS=louie_tsai
TAG=dev

AGENT_IMAGE=$REGISTRY/$REGISTRY_NS/node-topology-agent:$TAG
OPERATOR_IMAGE=$REGISTRY/$REGISTRY_NS/cpu-operator:$TAG
```

Build images:

```bash
docker build -t $AGENT_IMAGE agent/
docker build -t $OPERATOR_IMAGE operator/
```

Log in to Quay:

```bash
docker login quay.io
```

Push images:

```bash
docker push $AGENT_IMAGE
docker push $OPERATOR_IMAGE
```

Verify local pull works without login if the repositories are public:

```bash
docker logout quay.io

docker pull quay.io/louie_tsai/node-topology-agent:dev
docker pull quay.io/louie_tsai/cpu-operator:dev
```

If `docker pull` returns `unauthorized`, make the Quay repositories public or configure an OpenShift image pull secret.

---

## 2. Update Deployment Manifests

Update the image fields in:

```text
agent/daemonset.yaml
operator/deployment.yaml
```

Expected image values:

```yaml
image: quay.io/louie_tsai/node-topology-agent:dev
```

```yaml
image: quay.io/louie_tsai/cpu-operator:dev
```

You can patch them with:

```bash
sed -i "s|image: .*node-topology-agent:.*|image: quay.io/louie_tsai/node-topology-agent:dev|g" agent/daemonset.yaml

sed -i "s|image: .*cpu-operator:.*|image: quay.io/louie_tsai/cpu-operator:dev|g" operator/deployment.yaml
```

Verify:

```bash
grep image agent/daemonset.yaml
grep image operator/deployment.yaml
```

Expected output:

```text
image: quay.io/louie_tsai/node-topology-agent:dev
image: quay.io/louie_tsai/cpu-operator:dev
```

---

## 3. Deploy on OpenShift

Apply CRDs. CRDs define the custom API types used by this operator, such as `NodeCPUTopology` and `CPUPlacementPolicy`, so OpenShift can store node topology discovery data and placement policy inputs.

```bash
oc apply -f crds.yaml
```

Apply RBAC. RBAC grants the `node-topology-agent` and `cpu-operator` service accounts the permissions required to read/write topology resources, update policy outputs, and reconcile cluster objects.

```bash
oc apply -f rbac.yaml
```

Grant privileged SCC to the node topology agent. OpenShift SCC is required because the agent reads host CPU/NUMA information through host paths such as `/sys` and `/proc`, which normal Pods cannot access by default.

```bash
oc adm policy add-scc-to-user privileged \
  -z node-topology-agent \
  -n cpu-operator-system
```

Deploy the node topology agent:

```bash
oc apply -f agent/daemonset.yaml
```

Deploy the CPU operator:

```bash
oc apply -f operator/deployment.yaml
```

Deploy the example CPU placement policy:

```bash
oc apply -f examples/cpu-placement-policy.yaml
```

---

## 4. Verify Pods Are Running

```bash
oc get pods -n cpu-operator-system
```

Expected output:

```text
NAME                            READY   STATUS    RESTARTS   AGE
cpu-operator-xxxxxxxxxx-xxxxx   1/1     Running   0          ...
node-topology-agent-xxxxx       1/1     Running   0          ...
```

Check rollout status:

```bash
oc rollout status ds/node-topology-agent -n cpu-operator-system
oc rollout status deploy/cpu-operator -n cpu-operator-system
```

---

## 5. Verify Quay Images Are Used

Check the image used by the node topology agent:

```bash
oc get ds node-topology-agent \
  -n cpu-operator-system \
  -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
```

Check the image used by the CPU operator:

```bash
oc get deploy cpu-operator \
  -n cpu-operator-system \
  -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
```

Expected output:

```text
quay.io/louie_tsai/node-topology-agent:dev
quay.io/louie_tsai/cpu-operator:dev
```

---

## 6. Check Logs

Agent logs:

```bash
oc logs -n cpu-operator-system ds/node-topology-agent
```

Operator logs:

```bash
oc logs -n cpu-operator-system deploy/cpu-operator
```

Look for successful discovery and reconciliation messages. There should be no errors related to:

```text
NodeCPUTopology
CPUPlacementPolicy
ConfigMap
MachineConfigPool
KubeletConfig
```

---

## 7. Validate Node CPU Topology Discovery

```bash
oc get nodecputopologies -n cpu-operator-system
```

Inspect details:

```bash
oc get nodecputopologies -n cpu-operator-system -o yaml
```

Expected useful status fields:

```yaml
status:
  onlineCPUs:
  numaNodes:
  threadSiblings:
  gpus:
  gpuLocalNumaNodes:
  amx:
```

---

## 8. Validate CPUPlacementPolicy

```bash
oc get cpuplacementpolicies -n cpu-operator-system
```

Inspect the example policy:

```bash
oc get cpuplacementpolicy auto-vllm-cpu-policy \
  -n cpu-operator-system \
  -o yaml
```

---

## 9. Validate Generated ConfigMap

List ConfigMaps:

```bash
oc get cm -n cpu-operator-system
```

Expected ConfigMap:

```text
auto-vllm-cpu-policy-computed-cpu-policy
```

Inspect it:

```bash
oc get cm auto-vllm-cpu-policy-computed-cpu-policy \
  -n cpu-operator-system \
  -o yaml
```

Important generated sections:

```text
provider.yaml
providerStatus
phase4Status
nodeClassification.yaml
topologyGroups.yaml
cpuPlacementByNode.yaml
reservedSystemCPUsByNode.yaml
generatedNodeLabels.yaml
phase4MachineConfigPools.yaml
phase4KubeletConfigs.yaml
genericKubeletConfigs.yaml
genericApplyPlan.yaml
```

---

## 10. Validate Node Labels

```bash
oc get nodes \
  -L cpu.example.com/node-class,cpu.example.com/placement-strategy,cpu.example.com/topology-group,cpu.example.com/phase4-applied
```

Expected result: nodes should have CPU operator labels generated by the policy reconciliation.

---

## 11. Optional Test Pod Validation

Apply a test workload if available:

```bash
oc apply -f examples/test-pod.yaml
```

Check the pod:

```bash
oc get pods -n cpu-operator-system -o wide
```

Check the assigned CPU set inside the pod:

```bash
oc exec -n cpu-operator-system -it <test-pod-name> -- \
  cat /sys/fs/cgroup/cpuset.cpus.effective
```

For CPU Manager exclusive CPU assignment, the test pod should use Guaranteed QoS:

```yaml
resources:
  requests:
    cpu: "8"
    memory: 16Gi
  limits:
    cpu: "8"
    memory: 16Gi
```

CPU request and limit must be equal and integer-valued.

---

## 12. Summary Flow

```bash
# Build and push images
REGISTRY=quay.io
REGISTRY_NS=louie_tsai
TAG=dev

docker build -t $REGISTRY/$REGISTRY_NS/node-topology-agent:$TAG agent/
docker build -t $REGISTRY/$REGISTRY_NS/cpu-operator:$TAG operator/

docker login quay.io

docker push $REGISTRY/$REGISTRY_NS/node-topology-agent:$TAG
docker push $REGISTRY/$REGISTRY_NS/cpu-operator:$TAG

# Update manifests
sed -i "s|image: .*node-topology-agent:.*|image: quay.io/louie_tsai/node-topology-agent:dev|g" agent/daemonset.yaml
sed -i "s|image: .*cpu-operator:.*|image: quay.io/louie_tsai/cpu-operator:dev|g" operator/deployment.yaml

# Deploy
oc apply -f crds.yaml
oc apply -f rbac.yaml

oc adm policy add-scc-to-user privileged \
  -z node-topology-agent \
  -n cpu-operator-system

oc apply -f agent/daemonset.yaml
oc apply -f operator/deployment.yaml
oc apply -f examples/cpu-placement-policy.yaml

# Validate
oc get pods -n cpu-operator-system
oc get nodecputopologies -n cpu-operator-system
oc get cpuplacementpolicies -n cpu-operator-system
oc get cm auto-vllm-cpu-policy-computed-cpu-policy -n cpu-operator-system -o yaml

oc get nodes \
  -L cpu.example.com/node-class,cpu.example.com/placement-strategy,cpu.example.com/topology-group,cpu.example.com/phase4-applied
```

---

## Result

This is the simplest deployment path:

```text
build images
push images to public Quay.io
apply OpenShift manifests
validate topology and generated CPU policy
```

