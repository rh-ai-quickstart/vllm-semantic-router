# Node Classes, Placement Policies, and Outputs

This document summarizes the default node classification and CPU placement behavior implemented by the CPU Operator on the `new_design` branch. Values under `spec.profiles` can override the defaults shown here.

## Node class and placement policy

| Node class | Classification conditions | Placement policy | CPU allocation output | CPU Manager output | Topology Manager output | Phase 4 `reservedSystemCPUs` | Why |
|---|---|---|---|---|---|---|---|
| `mixed-cpu-amx-gpu` | GPU detected and both `amx_bf16` and `amx_int8` supported | `balanced-shared-cpu-and-gpu` | `gpuPodCPUSet`: 12 CPUs balanced across NUMA nodes by default; `cpuPodCPUSet`: all remaining CPUs | `static`; `distribute-cpus-across-numa=true`; `full-pcpus-only=true` | `restricted` | Not set | Allows CPU and GPU inference to share the node. GPU-support CPUs remain allocatable, while the remaining CPUs form the computed CPU-pod pool. |
| `cpu-amx` | No GPU; AMX BF16 and INT8 supported; and either `amxNodeSelector` matches or logical CPU count is at least `cpuAmxMinLogicalCPUs` (default: 64) | `balanced-reserved-other-pods` | `otherPodsReservedCPUSet`: 2 CPUs per NUMA node by default; `cpuPodCPUSet`: all remaining CPUs | `static`; `distribute-cpus-across-numa=true`; `full-pcpus-only=true` | `restricted` | Set to `otherPodsReservedCPUSet` when all nodes in the topology group have the same value | Reserves balanced capacity for system and shared workloads while assigning most CPU capacity to AMX inference. |
| `gpu-only` | GPU detected but required AMX capabilities are missing; `gpuOnlyNodeSelector` matches; or a valid manual override requests this class | `same-numa-node-first` | `numaLocalCPUSetByNuma`: CPUs grouped by NUMA node; `preferredNumaNode`: preferred local NUMA node | `static`; no default CPU Manager policy options | `single-numa-node` | Not set | Prioritizes NUMA-local CPU and memory placement for GPU-support work. |
| `cpu-only` | No GPU and the node does not qualify for `cpu-amx`; or an AMX-class override is rejected because AMX BF16/INT8 is missing | `same-numa-node-first` | `numaLocalCPUSetByNuma`: CPUs grouped by NUMA node; `preferredNumaNode`: preferred local NUMA node | `static`; no default CPU Manager policy options | `single-numa-node` | Not set | Provides NUMA-local placement for general CPU workloads that are not classified as AMX inference nodes. |

AMX support requires both `amx_bf16` and `amx_int8`. The operator can obtain these capabilities from the Node Topology Agent and merge in the corresponding Node Feature Discovery labels. GPU detection can come from allocatable resources, GPU-related node labels, or topology-agent PCI information.

## Classification order

| Priority | Input or condition | Result |
|---:|---|---|
| 1 | Valid manual override from `classification.overrideLabel` (default: `cpu.example.com/node-class-override`) | Requested class, subject to AMX validation |
| 2 | GPU detected and nonempty `gpuOnlyNodeSelector` matches | `gpu-only` |
| 3 | GPU detected and AMX BF16/INT8 supported | `mixed-cpu-amx-gpu` |
| 4 | GPU detected without AMX BF16/INT8 support | `gpu-only` |
| 5 | No GPU, AMX supported, and nonempty `amxNodeSelector` matches | `cpu-amx` |
| 6 | No GPU, AMX supported, and logical CPU count meets the configured minimum | `cpu-amx` |
| 7 | None of the preceding conditions match | `cpu-only` |

An override requesting `cpu-amx` or `mixed-cpu-amx-gpu` is rejected when AMX BF16/INT8 is missing. The operator falls back to `gpu-only` when a GPU is present and `cpu-only` otherwise.

## Generated node labels

The default label prefix is `cpu.example.com`. It can be changed through `spec.nodeLabels.prefix`.

| Generated label | Example or value | Purpose |
|---|---|---|
| `cpu.example.com/topology-ready` | `true` | Indicates topology information was available and processed. |
| `cpu.example.com/node-class` | `cpu-amx` | Records the selected node class. |
| `cpu.example.com/topology-group` | `cpu-amx-<stable-hash>` | Groups nodes that require compatible placement and Kubelet configuration. |
| `cpu.example.com/placement-strategy` | `balanced-reserved-other-pods` | Records the selected placement strategy. |
| `cpu.example.com/gpu-count` | `0`, `1`, `8`, and so on | Records the detected GPU count. |
| `cpu.example.com/gpu-local-numa` | `0,1` or `none` | Records the NUMA nodes local to detected GPUs. |
| `cpu.example.com/amx-supported` | `true` or `false` | True when both AMX BF16 and INT8 are supported. |
| `cpu.example.com/amx-bf16` | `true` or `false` | Records AMX BF16 support. |
| `cpu.example.com/amx-int8` | `true` or `false` | Records AMX INT8 support. |
| `cpu.example.com/placement-ready` | `true` | Indicates that placement was calculated. |
| `cpu.example.com/phase4-applied` | `true` or `false` | True only when Phase 4 manifests were successfully applied. |

## Computed policy outputs

The operator creates a ConfigMap named `<CPUPlacementPolicy-name>-computed-cpu-policy`.

| ConfigMap entry | Contents |
|---|---|
| `policyName` | Name of the source `CPUPlacementPolicy`. |
| `provider.yaml` | Normalized provider type and apply mode. |
| `providerStatus` | Provider reconciliation state, such as `recommendation-only`, `openshift-generated-only`, `managed-applied`, or `apply-failed`. |
| `phase4Status` | `disabled`, `generated-only`, `applied`, or `apply-failed`. |
| `phase4Error` | Phase 4 apply error, when present. |
| `targetNodeSelector.yaml` | Selector used to choose nodes for processing. |
| `nodeClassification.yaml` | Per-node class, classification reason, GPU and AMX details, profile, topology signature, topology group, and placement. |
| `topologyGroups.yaml` | Nodes grouped by compatible class, topology signature, policies, and placement strategy. |
| `cpuPlacementByNode.yaml` | Calculated CPU sets and placement policies for each node. |
| `reservedSystemCPUsByNode.yaml` | Legacy or recommended CPU set. This is not necessarily the value applied by Phase 4. |
| `generatedNodeLabels.yaml` | Exact node labels calculated by the operator. |
| `genericKubeletConfigs.yaml` | Per-node generic Kubernetes `KubeletConfiguration` YAML. |
| `genericApplyPlan.yaml` | Safe handoff plan for applying generic Kubernetes kubelet configuration. |
| `openshiftTuned.yaml` | Generated OpenShift `Tuned` resource when TuneD management is enabled. |
| `phase4MachineConfigPools.yaml` | Generated OpenShift `MachineConfigPool` manifests. |
| `phase4KubeletConfigs.yaml` | Generated OpenShift `KubeletConfig` manifests. |
| `kubeletConfigByTopologyClass.yaml` | Combined rendering of Phase 4 configuration by topology group. |

## Phase 4 resources

When Phase 4 is enabled, the operator generates one `MachineConfigPool` and one `KubeletConfig` for each topology group. A topology group accounts for the node class, CPUs per NUMA node, GPU-local NUMA nodes, AMX support, placement strategy, reservation settings, and CPU Manager options.

| Resource or behavior | Output |
|---|---|
| MachineConfigPool node selector | `cpu.example.com/topology-group: <group-name>` |
| KubeletConfig pool selector | `pools.operator.machineconfiguration.openshift.io/<MCP-name>: ""` |
| CPU Manager policy | Class/profile value; `static` by default for all four classes |
| CPU Manager policy options | NUMA distribution and full-core allocation for `mixed-cpu-amx-gpu` and `cpu-amx`; empty by default for `gpu-only` and `cpu-only` |
| Topology Manager policy | `restricted` for `mixed-cpu-amx-gpu` and `cpu-amx`; `single-numa-node` for `gpu-only` and `cpu-only` |
| Topology Manager scope | `pod` by default |
| `reservedSystemCPUs` | Included only when the topology group has exactly one consistent, nonempty reserved CPU-set value |

For `mixed-cpu-amx-gpu`, `gpuPodCPUSet` is a computed workload pool and is deliberately not mapped to `reservedSystemCPUs`. Reserving it at the kubelet level would remove those CPUs from the exclusive allocation pool needed by GPU pods. CPU Manager also does not independently enforce distinct CPU-pod and GPU-pod pools; the computed sets describe the intended placement design.

For generic Kubernetes, the operator also writes a separate output ConfigMap. Its default name is `<CPUPlacementPolicy-name>-generated-kubelet-config`; `spec.generic.outputConfigMap` can override it. The ConfigMap contains one `<node>.kubelet-config.yaml` entry per processed node plus `apply-plan.yaml`.

## Validate one real worker node

Run the live-node validation script from the repository root:

```bash
scripts/test-worker-node-output.sh <worker-node-name>
```

The script reads the node's single generated class first and applies only the assertions for that class. It then verifies the node's computed placement, generated labels, topology group, provider status, corresponding MachineConfigPool and KubeletConfig outputs, applied OpenShift resources when applicable, and generic Kubernetes output ConfigMap. Each assertion prints `[PASS]` or `[FAIL]`, and any failure produces a nonzero exit code.
