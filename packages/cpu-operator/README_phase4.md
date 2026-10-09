# CPU Operator Demo — Phase 4 CPU Management Policy

This package implements Phase 4 support using OpenShift CPU management policy through MachineConfigPool and KubeletConfig generation.

## What Phase 4 does

The CPU Operator now:

```text
1. Classifies worker nodes by topology group.
2. Labels nodes:
   cpu.example.com/topology-group=<group>
3. Generates one MachineConfigPool per topology group.
4. Generates one KubeletConfig per MachineConfigPool.
5. Optionally applies those objects when spec.phase4.apply=true.
```

## Safety default

The example policy uses:

```yaml
phase4:
  enabled: true
  apply: false
```

That means the operator generates Phase 4 manifests into the ConfigMap but does not apply them.

Set this only when you are ready for Machine Config Operator rollout and possible node reboot:

```yaml
phase4:
  enabled: true
  apply: true
```

## CPU Manager settings

For balanced groups:

```yaml
cpuManagerPolicy: static
cpuManagerPolicyOptions:
  distribute-cpus-across-numa: "true"
  full-pcpus-only: "true"
topologyManagerPolicy: restricted
```

For same-NUMA-first groups:

```yaml
cpuManagerPolicy: static
cpuManagerPolicyOptions: {}
topologyManagerPolicy: single-numa-node
```

## Important limitation

CPU Manager cannot create separate named CPU pools for GPU pods and CPU pods by itself.

For `mixed-cpu-amx-gpu`, the generated placement still shows:

```text
gpuPodCPUSet
cpuPodCPUSet
```

but Phase 4 KubeletConfig mainly enforces:

```text
cpuManagerPolicy=static
cpuManagerPolicyOptions=distribute-cpus-across-numa/full-pcpus-only
topologyManagerPolicy=restricted
```

Use Guaranteed Pods with integer CPU requests. For example, GPU pods should request/limit `cpu: "12"` to receive exclusive CPUs from CPU Manager.

## Output ConfigMap

```bash
oc get cm auto-vllm-cpu-policy-computed-cpu-policy \
  -n cpu-operator-system \
  -o yaml
```

Important keys:

```text
phase4Status
phase4MachineConfigPools.yaml
phase4KubeletConfigs.yaml
kubeletConfigByTopologyClass.yaml
cpuPlacementByNode.yaml
```

## Deploy

Build/push images using one registry guide:

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

oc get mcp
oc get kubeletconfig
oc get nodes -L cpu.example.com/node-class,cpu.example.com/topology-group,cpu.example.com/phase4-applied
```

## Apply Phase 4

Edit:

```bash
vi examples/cpu-placement-policy.yaml
```

Change:

```yaml
phase4:
  enabled: true
  apply: true
```

Apply:

```bash
oc apply -f examples/cpu-placement-policy.yaml
```

Watch rollout:

```bash
oc get mcp
oc describe mcp <generated-pool-name>
oc get nodes
```

Verify kubelet CPU manager state after rollout:

```bash
oc debug node/<worker-node>
chroot /host
cat /var/lib/kubelet/cpu_manager_state
```
