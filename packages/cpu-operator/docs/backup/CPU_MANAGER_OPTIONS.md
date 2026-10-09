# CPU Manager Options

`distribute-cpus-across-numa` is configured as a CPU Manager static policy option.

It is not a valid `topologyManagerPolicy`.

## Balanced groups

For `mixed-cpu-amx-gpu` and `cpu-amx`:

```yaml
cpuManagerPolicy: static
cpuManagerPolicyOptions:
  distribute-cpus-across-numa: "true"
  full-pcpus-only: "true"
topologyManagerPolicy: restricted
```

## Same-NUMA-first groups

For `gpu-only` and `cpu-only`:

```yaml
cpuManagerPolicy: static
cpuManagerPolicyOptions: {}
topologyManagerPolicy: single-numa-node
```

## Phase 4 status

The package still does not apply a real OpenShift KubeletConfig or MachineConfigPool.
The generated ConfigMap is a recommendation and validation artifact only.
