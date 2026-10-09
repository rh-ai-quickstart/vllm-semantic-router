# Phase 4: CPU Management Policy

This implementation uses OpenShift MachineConfigPool and KubeletConfig.

## Generated objects

For each topology group, the operator generates:

```text
MachineConfigPool
KubeletConfig
```

The MachineConfigPool selects nodes by:

```text
cpu.example.com/topology-group=<group>
```

The KubeletConfig selects the MachineConfigPool by its pool label.

## Safe default

The example policy uses:

```yaml
phase4:
  enabled: true
  apply: false
```

This generates manifests into the ConfigMap only.

To apply real cluster changes:

```yaml
phase4:
  enabled: true
  apply: true
```

## Warning

Applying KubeletConfig may cause Machine Config Operator rollout and node reboot.

## Mixed CPU AMX GPU nodes

CPU Manager cannot reserve CPUs specifically for GPU pods. GPU pods should use integer Guaranteed CPU requests, for example:

```yaml
resources:
  requests:
    cpu: "12"
    nvidia.com/gpu: "1"
  limits:
    cpu: "12"
    nvidia.com/gpu: "1"
```

CPU Manager static policy then grants exclusive CPUs. With:

```yaml
cpuManagerPolicyOptions:
  distribute-cpus-across-numa: "true"
  full-pcpus-only: "true"
```

the exclusive CPUs are distributed across NUMA nodes in full-core chunks.

## CPU AMX nodes

For `cpu-amx`, the operator maps `otherPodsReservedCPUSet` to `reservedSystemCPUs`.

## Same NUMA first groups

For `cpu-only` and `gpu-only`, the operator uses:

```yaml
topologyManagerPolicy: single-numa-node
```
