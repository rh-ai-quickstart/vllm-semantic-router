# CPU Operator Demo — Placement Policy Semantics

This package adds explicit CPU placement semantics for each node group.

Node classes:

```text
mixed-cpu-amx-gpu
cpu-amx
cpu-only
gpu-only
```

AMX classes require both `amx_bf16` and `amx_int8`.

## Placement rules

### mixed-cpu-amx-gpu

Balanced CPU distribution among NUMA nodes for both CPU and GPU pods.

```text
Reserve 12 CPUs total for GPU pods.
Distribute those 12 CPUs across NUMA nodes.
Give all remaining CPUs to CPU pods.
Keep remaining CPU pool balanced across NUMA nodes.
```

Computed output fields:

```text
gpuPodCPUSet
gpuPodReservedCPUs
cpuPodCPUSet
```

### cpu-amx

```text
Reserve 2 CPUs per NUMA node for other pods.
Give all remaining CPUs to CPU pods.
Keep CPU pod pool balanced across NUMA nodes.
```

Computed output fields:

```text
otherPodsReservedCPUSet
reservedOtherPodsPerNuma
cpuPodCPUSet
```

### gpu-only and cpu-only

```text
Prefer CPUs from the same NUMA node first.
Equivalent placement intent: single-numa-node.
```

Computed output fields:

```text
numaLocalCPUSetByNuma
preferredNumaNode
```


## CPU Manager options vs Topology Manager policy

`distribute-cpus-across-numa` is a CPU Manager static policy option, not a Topology Manager policy.

For balanced groups, the generated policy uses:

```yaml
cpuManagerPolicy: static
cpuManagerPolicyOptions:
  distribute-cpus-across-numa: "true"
  full-pcpus-only: "true"
topologyManagerPolicy: restricted
```

This applies to:

```text
mixed-cpu-amx-gpu
cpu-amx
```

For same-NUMA-first groups, the generated policy uses:

```yaml
cpuManagerPolicy: static
cpuManagerPolicyOptions: {}
topologyManagerPolicy: single-numa-node
```

This applies to:

```text
gpu-only
cpu-only
```


## Phase 4 status

Phase 4 is **not implemented**. This package does not apply worker-node KubeletConfig, MachineConfigPool, or actual cpuset enforcement.

The computed ConfigMap contains:

```text
phase4Status: not-implemented
```

## Deploy

Build/push images using either:

```text
docs/README_internal_registry.md
docs/README_external_registry.md
```

Then:

```bash
./scripts/deploy.sh
```

## Validate

```bash
./scripts/sanity-check.sh
```

Manual checks:

```bash
oc get cm auto-vllm-cpu-policy-computed-cpu-policy \
  -n cpu-operator-system \
  -o yaml

oc get nodes \
  -L cpu.example.com/node-class,cpu.example.com/placement-strategy,cpu.example.com/phase4-applied,cpu.example.com/topology-group
```

## Important output keys

```text
cpuPlacementByNode.yaml
nodeClassification.yaml
topologyGroups.yaml
generatedNodeLabels.yaml
kubeletConfigByTopologyClass.yaml
```
