# CPUPlacementPolicy Reference

This document explains how a `CPUPlacementPolicy` moves through the CPU Operator from user input to node configuration and workload validation.

The current defaults described here match `operator/operator.py` on `main`:

- `mixed-cpu-amx-gpu.placement.gpuPodReservedCPUs: 24`
- `cpu-amx.placement.reservedOtherPodsPerNuma: 1`

> **CPU-count terminology:** unless explicitly stated otherwise, CPU counts in the policy are **logical CPUs / Kubernetes vCPUs**, not physical-core counts. On an SMT2 system, two logical CPUs normally correspond to one physical core.

---

## 1. Policy processing overview

A `CPUPlacementPolicy` is the user-facing input to the CPU Operator.

The operator combines the policy with:

- Kubernetes or OpenShift Node objects;
- `NodeCPUTopology` data from the Node Topology Agent;
- optional Node Feature Discovery labels;
- optional GPU resource and locality information.

The lifecycle is:

```text
Policy inputs
  -> select target nodes
  -> classify each node
  -> choose the class profile
  -> calculate CPU/NUMA placement
  -> group nodes with compatible configuration
  -> generate labels, ConfigMaps, and provider resources
  -> schedule eligible workloads
  -> validate the resulting CPU assignment
```

The operator produces:

1. one selected class for every processed node;
2. one placement calculation for every processed node;
3. topology groups containing nodes that need compatible kubelet configuration;
4. generated node labels;
5. provider-specific configuration;
6. computed ConfigMaps for inspection and external consumption.

---

## 2. Complete policy skeleton

```yaml
apiVersion: cpu.example.com/v1alpha1
kind: CPUPlacementPolicy
metadata:
  name: auto-vllm-cpu-policy
  namespace: cpu-operator-system
spec:
  provider:
    type: OpenShift
    applyMode: Managed

  targetNodeSelector:
    node-role.kubernetes.io/worker: ""

  nodeLabels:
    enabled: true
    prefix: cpu.example.com

  classification:
    overrideLabel: cpu.example.com/node-class-override
    amxNodeSelector:
      node-role.kubernetes.io/inference: ""
    gpuOnlyNodeSelector:
      cpu.example.com/gpu-only: "true"
    cpuAmxMinLogicalCPUs: 64

  profiles:
    mixed-cpu-amx-gpu:
      cpuManagerPolicy: static
      cpuManagerPolicyOptions:
        distribute-cpus-across-numa: "true"
        full-pcpus-only: "true"
      topologyManagerPolicy: restricted
      placement:
        strategy: balanced-shared-cpu-and-gpu
        gpuPodReservedCPUs: 24
        gpuPodDistribution: balanced-across-numa
        cpuPodPool: all-remaining-balanced-across-numa

    cpu-amx:
      cpuManagerPolicy: static
      cpuManagerPolicyOptions:
        distribute-cpus-across-numa: "true"
        full-pcpus-only: "true"
      topologyManagerPolicy: restricted
      placement:
        strategy: balanced-reserved-other-pods
        reservedOtherPodsPerNuma: 1
        cpuPodPool: all-remaining-balanced-across-numa

    gpu-only:
      cpuManagerPolicy: static
      cpuManagerPolicyOptions: {}
      topologyManagerPolicy: single-numa-node
      placement:
        strategy: same-numa-node-first

    cpu-only:
      cpuManagerPolicy: static
      cpuManagerPolicyOptions: {}
      topologyManagerPolicy: single-numa-node
      placement:
        strategy: same-numa-node-first

  openshift:
    machineConfigPoolNamePrefix: cpu
    manageKubeletConfig: true
    manageTuned: false
    tunedProfile: openshift-node-llm-compute
    topologyManagerScope: pod

  generic:
    outputConfigMap: auto-vllm-cpu-policy-generated-kubelet-config

  phase4:
    enabled: true
    apply: true
    machineConfigPoolNamePrefix: cpu
    topologyManagerScope: pod
    pauseMachineConfigPool: false
```

---

# INPUTS

## 3. Target node selection

```yaml
spec:
  targetNodeSelector:
    node-role.kubernetes.io/worker: ""
```

The operator compares this selector with labels on each Kubernetes Node. An empty string means the label key must exist regardless of value.

Provider selection does not decide which nodes are classified. It only controls how the computed result is delivered.

---

## 4. Provider selection

```yaml
spec:
  provider:
    type: OpenShift
    applyMode: Managed
```

| Field | Current values | Meaning |
|---|---|---|
| `spec.provider.type` | `OpenShift` | Render OpenShift `MachineConfigPool`, `KubeletConfig`, and optional `Tuned` resources. |
| `spec.provider.type` | `GenericKubernetes` | Render per-node kubelet configuration and an external apply plan. |
| `spec.provider.applyMode` | `Managed` | Apply supported provider resources. Currently meaningful for OpenShift. |
| `spec.provider.applyMode` | `RecommendationOnly` | Render outputs without applying node configuration. |

The normalized provider is written to `provider.yaml` in the computed policy ConfigMap.

---

## 5. Classification settings

```yaml
spec:
  classification:
    overrideLabel: cpu.example.com/node-class-override
    amxNodeSelector:
      node-role.kubernetes.io/inference: ""
    gpuOnlyNodeSelector:
      cpu.example.com/gpu-only: "true"
    cpuAmxMinLogicalCPUs: 64
```

| Field | Purpose |
|---|---|
| `overrideLabel` | Allows a valid manual node-class request through a Node label. |
| `amxNodeSelector` | Explicitly identifies AMX-capable nodes intended for CPU inference. |
| `gpuOnlyNodeSelector` | Forces matching GPU nodes into `gpu-only`. |
| `cpuAmxMinLogicalCPUs` | Allows large AMX nodes to qualify for `cpu-amx` without an explicit selector. |

A manual override requesting an AMX class is rejected if AMX BF16 or AMX INT8 is missing.

---

## 6. Class profiles and CPU-count semantics

Each node class has one profile. The selected class determines which profile is passed into placement calculation.

### Supported node classes

| Class | Intended node |
|---|---|
| `mixed-cpu-amx-gpu` | GPU node that also supports AMX BF16 and AMX INT8 |
| `cpu-amx` | CPU inference node with AMX BF16 and AMX INT8 |
| `gpu-only` | GPU node that does not qualify for the mixed AMX class |
| `cpu-only` | General CPU node that does not qualify for `cpu-amx` |

### Important unit rule

The fields below are expressed in **logical CPUs / vCPUs**:

- `gpuPodReservedCPUs`
- `reservedOtherPodsPerNuma`
- generated `gpuPodCPUSet`
- generated `cpuPodCPUSet`
- generated `otherPodsReservedCPUSet`
- generated `systemReservedCPUSet`

`full-pcpus-only: "true"` does **not** change these fields into physical-core counts. It changes how kubelet CPU Manager satisfies an eligible pod's exclusive integer CPU request: on an SMT system, CPU Manager allocates complete physical cores rather than splitting sibling threads when the request can be admitted.

### `cpu-amx`: `reservedOtherPodsPerNuma`

Current default:

```yaml
cpu-amx:
  placement:
    strategy: balanced-reserved-other-pods
    reservedOtherPodsPerNuma: 1
```

`reservedOtherPodsPerNuma` means **logical CPUs reserved per NUMA node**.

For example, on a two-NUMA node:

```text
reservedOtherPodsPerNuma = 1 logical CPU
NUMA nodes               = 2
--------------------------------
planned reserved set      = 2 logical CPUs total
```

The operator calculates `otherPodsReservedCPUSet`, copies that value to `systemReservedCPUSet`, and for `cpu-amx` maps it to kubelet `reservedSystemCPUs`.

Therefore the `cpu-amx` reservation is a **real kubelet system/shared reservation**. Those CPUs are removed from CPU Manager's exclusive allocation pool.

Example on a 96-logical-CPU, two-NUMA worker:

```text
Capacity                     96 logical CPUs
reservedOtherPodsPerNuma      1
NUMA nodes                    2
reservedSystemCPUs            2 logical CPUs
exclusive-capable maximum    94 logical CPUs
```

The scheduler must also have enough allocatable headroom for existing pod requests. For example, if the node reports 94 allocatable CPUs and existing OpenShift pods request about 0.7 CPU, a 92-CPU Guaranteed vLLM pod can fit scheduler accounting while remaining below the CPU Manager exclusive-capacity limit.

After that 92-CPU exclusive allocation, the CPU Manager default/shared pool can contain four logical CPUs:

```text
2 explicitly reserved system/shared CPUs
+ 2 exclusive-capable CPUs not allocated to vLLM
= 4 CPUs visible in the default/shared pool
```

This distinction matters: **shared-pool size is not always equal to `reservedSystemCPUs` size**.

### `mixed-cpu-amx-gpu`: `gpuPodReservedCPUs`

Current default:

```yaml
mixed-cpu-amx-gpu:
  placement:
    strategy: balanced-shared-cpu-and-gpu
    gpuPodReservedCPUs: 24
    gpuPodDistribution: balanced-across-numa
```

`gpuPodReservedCPUs: 24` means **24 logical CPUs / vCPUs total**, balanced across NUMA nodes by the placement calculation.

For a two-NUMA node, the policy intent is approximately:

```text
24 logical CPUs total
  -> about 12 logical CPUs from NUMA 0
  -> about 12 logical CPUs from NUMA 1
```

On SMT2 hardware, 24 logical CPUs correspond to about 12 physical cores when allocated as complete cores.

Despite the field name, these GPU-support CPUs are **not** mapped to kubelet `reservedSystemCPUs`.

The operator deliberately leaves:

```yaml
systemReservedCPUSet: ""
```

for the mixed class because GPU workloads may still need those CPUs to remain allocatable for exclusive CPU Manager assignment. Mapping `gpuPodCPUSet` into `reservedSystemCPUs` would remove them from the exclusive allocation pool for all pods and defeat the GPU-workload use case.

### Reserved CPU vs GPU vCPU summary

| Setting/output | Class | Unit | Becomes `reservedSystemCPUs`? | Meaning |
|---|---|---:|---|---|
| `reservedOtherPodsPerNuma` | `cpu-amx` | logical CPUs per NUMA | **Yes, indirectly** | System/shared reservation for non-exclusive work. |
| `otherPodsReservedCPUSet` | `cpu-amx` | logical CPU IDs | **Yes** | Exact computed set mapped to kubelet reservation. |
| `gpuPodReservedCPUs` | `mixed-cpu-amx-gpu` | logical CPUs total | **No** | GPU-workload CPU capacity/placement intent. |
| `gpuPodCPUSet` | `mixed-cpu-amx-gpu` | logical CPU IDs | **No** | Reference set for GPU-support CPU placement. |
| `cpuPodCPUSet` | mixed or CPU class | logical CPU IDs | No direct named-pool enforcement | Policy capacity/reference set for CPU workloads. |

---

# PROCESSING

## 7. Node classification

The operator evaluates each selected node using:

- manual override label;
- GPU detection;
- AMX BF16 support;
- AMX INT8 support;
- explicit selectors;
- logical CPU count.

### Classification order

| Priority | Condition | Result |
|---:|---|---|
| 1 | Valid manual override | Requested class, subject to AMX validation |
| 2 | GPU present and `gpuOnlyNodeSelector` matches | `gpu-only` |
| 3 | GPU present and AMX BF16/INT8 supported | `mixed-cpu-amx-gpu` |
| 4 | GPU present without required AMX support | `gpu-only` |
| 5 | No GPU, AMX supported, and `amxNodeSelector` matches | `cpu-amx` |
| 6 | No GPU, AMX supported, and logical CPU count meets the minimum | `cpu-amx` |
| 7 | No earlier rule matches | `cpu-only` |

The GPU count is derived from Kubernetes/NFD/GPU Operator signals and placement-grade PCI discovery from `NodeCPUTopology`.

---

## 8. Placement calculation

Placement combines:

```text
NodeCPUTopology
  + selected node class
  + effective class profile
  = per-node placement result
```

### Default placement by class

| Class | Strategy | Important output |
|---|---|---|
| `mixed-cpu-amx-gpu` | `balanced-shared-cpu-and-gpu` | `gpuPodCPUSet`, `cpuPodCPUSet` |
| `cpu-amx` | `balanced-reserved-other-pods` | `otherPodsReservedCPUSet`, `cpuPodCPUSet` |
| `gpu-only` | `same-numa-node-first` | `numaLocalCPUSetByNuma`, `preferredNumaNode` |
| `cpu-only` | `same-numa-node-first` | `numaLocalCPUSetByNuma`, `preferredNumaNode` |

### Mixed CPU/GPU placement

For `mixed-cpu-amx-gpu`, the operator:

1. selects `gpuPodReservedCPUs` logical CPUs balanced across NUMA;
2. records them as `gpuPodCPUSet`;
3. records the remaining CPUs as `cpuPodCPUSet`;
4. leaves `systemReservedCPUSet` empty.

The resulting named sets describe **placement intent and policy capacity**. Standard kubelet CPU Manager does not understand an operator-defined "GPU CPU pool" or "CPU pod pool" by name.

A Guaranteed GPU pod still requests an integer CPU quantity. CPU Manager chooses exact logical CPU IDs according to CPU Manager and Topology Manager policy. Exact IDs can therefore differ from the operator's reference `gpuPodCPUSet` unless an additional enforcement mechanism is introduced.

### CPU AMX placement

For `cpu-amx`, the operator:

1. chooses `reservedOtherPodsPerNuma` logical CPUs from each NUMA node;
2. combines them into `otherPodsReservedCPUSet`;
3. removes those IDs from `cpuPodCPUSet`;
4. sets `systemReservedCPUSet` to the same other-pods set;
5. maps that set to kubelet `reservedSystemCPUs` during provider rendering.

### Why GPU CPUs are not system-reserved

Do not map `gpuPodCPUSet` to `reservedSystemCPUs`.

`reservedSystemCPUs` means CPUs reserved for OS/system/shared work and removed from the exclusive CPU Manager allocation pool. GPU workloads need their CPU capacity to remain allocatable, so mixed-class GPU CPU intent and system reservation are intentionally separate concepts.

---

## 9. Topology grouping

OpenShift `KubeletConfig` applies to a `MachineConfigPool`, not independently to each node. The operator therefore groups nodes that require compatible configuration.

Topology signature inputs include:

- node class;
- CPUs per NUMA node;
- GPU-local NUMA nodes;
- AMX support;
- placement strategy;
- `gpuPodReservedCPUs`;
- `reservedOtherPodsPerNuma`;
- CPU Manager policy options.

Changing either reservation setting can therefore produce a new topology-group hash and corresponding MCP/KubeletConfig names.

---

# OUTPUTS

## 10. Generated node labels

Typical labels include:

```text
cpu.example.com/topology-ready=true
cpu.example.com/node-class=cpu-amx
cpu.example.com/topology-group=cpu-amx-<hash>
cpu.example.com/placement-strategy=balanced-reserved-other-pods
cpu.example.com/gpu-count=0
cpu.example.com/gpu-local-numa=none
cpu.example.com/amx-supported=true
cpu.example.com/amx-bf16=true
cpu.example.com/amx-int8=true
cpu.example.com/placement-ready=true
cpu.example.com/phase4-applied=true
```

These labels expose computed state. They do not independently enforce a CPU set.

---

## 11. Provider-specific resources

### OpenShift

For each topology group, the operator can generate:

- one `MachineConfigPool`;
- one `KubeletConfig`;
- optional `Tuned` configuration.

For `cpu-amx`, a consistent `systemReservedCPUSet` across the topology group becomes:

```yaml
spec:
  kubeletConfig:
    reservedSystemCPUs: <computed CPU IDs>
```

For `mixed-cpu-amx-gpu`, `gpuPodCPUSet` is intentionally **not** written into `reservedSystemCPUs`.

### Generic Kubernetes

The operator renders per-node `KubeletConfiguration` data plus an external apply plan. Host mutation remains the responsibility of kubeadm, Cluster API, configuration management, or other automation.

---

## 12. Computed policy ConfigMaps

The main computed ConfigMap is:

```text
<policy-name>-computed-cpu-policy
```

Important keys include:

```text
provider.yaml
nodeClassification.yaml
cpuPlacementByNode.yaml
topologyGroups.yaml
generatedNodeLabels.yaml
reservedSystemCPUsByNode.yaml
genericKubeletConfigs.yaml
genericApplyPlan.yaml
phase4MachineConfigPools.yaml
phase4KubeletConfigs.yaml
```

`cpuPlacementByNode.yaml` is the best place to inspect the distinction between:

- `gpuPodCPUSet`;
- `cpuPodCPUSet`;
- `otherPodsReservedCPUSet`;
- `systemReservedCPUSet`.

---

# CONSUMPTION

## 13. Workload eligibility and CPU capacity

Exclusive CPU Manager allocation requires an eligible Guaranteed-QoS workload with integer CPU request equal to CPU limit.

Example:

```yaml
resources:
  requests:
    cpu: "92"
    memory: "256Gi"
  limits:
    cpu: "92"
    memory: "256Gi"
```

Two independent limits must be satisfied:

```text
Scheduler constraint:
workload CPU request + existing pod CPU requests
<= Node Allocatable CPU

CPU Manager constraint:
workload exclusive CPU request
<= logical CPUs not removed by reservedSystemCPUs
```

The policy's `cpuPodCPUSet` represents policy CPU capacity/reference data. A workload may request less than that capacity. The generator scripts support `CPU_REQUEST=<n>` for this reason.

### Shared pool versus reserved CPUs

Do not assume:

```text
shared pool size == reservedSystemCPUs size
```

With static CPU Manager, the default/shared pool also contains exclusive-capable CPUs that have not currently been assigned to Guaranteed integer-CPU workloads.

Example:

```text
96 logical CPUs total
2 reservedSystemCPUs
92 CPUs assigned exclusively to vLLM
------------------------------------
4 CPUs remain in default/shared pool
```

Only two of those four are explicitly system-reserved; the other two are simply unallocated.

---

## 14. Validation

Validate control-plane output first:

```bash
NODE=<worker-node-name>
scripts/test-worker-node-output.sh "${NODE}"
```

Inspect the live kubelet configuration:

```bash
oc debug "node/${NODE}" --quiet -- chroot /host sh -c '
  grep -E "cpuManagerPolicy|topologyManagerPolicy|reservedSystemCPUs" \
    /etc/kubernetes/kubelet.conf 2>/dev/null || true
  cat /var/lib/kubelet/cpu_manager_state
'
```

Inspect scheduler accounting:

```bash
oc get node "${NODE}" \
  -o jsonpath='capacity={.status.capacity.cpu}{"\n"}allocatable={.status.allocatable.cpu}{"\n"}'

oc describe node "${NODE}" | \
  sed -n '/Allocated resources:/,/Events:/p'
```

Inspect runtime shared/exclusive CPU sets:

```bash
LIVE=1 VIEW=both \
  scripts/show-pod-cpus-grouped.sh "${NODE}"
```

A CPU set is an allowed execution boundary; it does not mean every container is actively consuming every CPU in the set.

---

## 15. Legacy Phase 4 compatibility

The current provider model supersedes the original OpenShift-only Phase 4 design, but `spec.phase4` remains for backward compatibility.

For OpenShift, provider normalization can still use Phase 4 fields to determine managed apply behavior, MCP naming, topology-manager scope, and pause behavior.

---

# Final implementation notes

The current `main` policy intentionally separates two concepts that use similar words but have different enforcement semantics:

```text
cpu-amx
  reservedOtherPodsPerNuma
      -> logical CPU IDs selected per NUMA
      -> otherPodsReservedCPUSet
      -> systemReservedCPUSet
      -> kubelet reservedSystemCPUs
      -> removed from exclusive CPU Manager capacity

mixed-cpu-amx-gpu
  gpuPodReservedCPUs
      -> logical CPU count for GPU-workload placement/capacity intent
      -> gpuPodCPUSet balanced across NUMA
      -> NOT reservedSystemCPUs
      -> remains available for pod CPU requests
```

Current defaults:

```text
mixed-cpu-amx-gpu: gpuPodReservedCPUs = 24 logical CPUs total
cpu-amx:           reservedOtherPodsPerNuma = 1 logical CPU per NUMA
```

These values are defaults and can be overridden in `spec.profiles` when a platform needs different capacity or reservation sizing.
