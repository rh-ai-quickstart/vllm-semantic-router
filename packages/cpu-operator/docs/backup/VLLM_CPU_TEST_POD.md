# vLLM CPU Test Pod Generator

This helper generates a vLLM CPU test pod whose CPU request and limit match the current `cpuPodCPUSet` computed by the `CPUPlacementPolicy` operator.

A static pod manifest can easily drift from the current policy. This generator reads the operator output ConfigMap, counts the CPUs in `cpuPodCPUSet`, and writes a Guaranteed-QoS pod manifest with matching `requests.cpu` and `limits.cpu`.

## Generate the test pod

```bash
./scripts/generate-vllm-cpu-test-pod.sh
```

By default, the script reads:

```text
Namespace: cpu-operator-system
Policy:    auto-vllm-cpu-policy
ConfigMap: auto-vllm-cpu-policy-computed-cpu-policy
```

It writes:

```text
examples/vllm-cpu-test-pod.generated.yaml
```

## Apply the generated pod

```bash
oc apply -f examples/vllm-cpu-test-pod.generated.yaml
```

Check the pod:

```bash
oc get pod vllm-cpu-test -n default -o wide
oc logs vllm-cpu-test -n default
```

The log prints the policy-recommended CPU set, the required CPU count, the
kubelet-assigned CPU set, the effective cgroup CPU set, and validation results.

## Example with current policy

If the computed policy contains:

```yaml
cpuPodCPUSet: 3-85,89-171,175-257,261-343
```

then the generated pod will request and limit:

```yaml
resources:
  requests:
    cpu: "332"
  limits:
    cpu: "332"
```

because the CPU set contains 332 logical CPUs.

## Useful overrides

Generate for a specific node:

```bash
NODE=luis.fm2aihpcsed.com ./scripts/generate-vllm-cpu-test-pod.sh
```

Change output path:

```bash
OUT=/tmp/vllm-cpu-test.yaml ./scripts/generate-vllm-cpu-test-pod.sh
```

Change pod namespace, pod name, image, or memory:

```bash
POD_NAMESPACE=default \
POD_NAME=vllm-cpu-test \
IMAGE=registry.access.redhat.com/ubi9/ubi \
MEMORY=256Gi \
./scripts/generate-vllm-cpu-test-pod.sh
```

Use a different policy:

```bash
POLICY=my-cpu-policy ./scripts/generate-vllm-cpu-test-pod.sh
```

Or explicitly set the ConfigMap:

```bash
CM_NAME=my-cpu-policy-computed-cpu-policy ./scripts/generate-vllm-cpu-test-pod.sh
```

## Expected validation behavior

The generated workload validates the properties that kubelet CPU Manager can
enforce from a normal Pod resource request:

- the Pod receives the requested number of exclusive logical CPUs;
- `/proc/self/status` matches the effective cgroup cpuset;
- the Pod remains available for checkpoint and topology inspection.

Example output:

```text
Policy-recommended CPU set: 3-23,27-47,51-71,75-95
Policy-required CPU count: 84
Kubelet-assigned exclusive CPU set: 1-21,24-44,49-69,72-92
Effective cgroup CPU set: 1-21,24-44,49-69,72-92
Actual exclusive CPU count: 84

[PASS] CPU count: expected=84 actual=84
[INFO] Exact CPU IDs differ from the policy recommendation
[INFO] This is valid when kubelet CPU Manager receives only an integer CPU request.
[PASS] Process affinity matches the effective cgroup cpuset
```

After the Pod starts, inspect the kubelet CPU Manager checkpoint:

```bash
oc debug node/<worker-node> --quiet -- \
  chroot /host \
  cat /var/lib/kubelet/cpu_manager_state
```

## Important limitation

This script makes the pod request the same **number of CPUs** as the computed `cpuPodCPUSet`.

Kubelet CPU Manager can allocate exclusive CPUs for a Guaranteed pod when `cpuManagerPolicy: static` is active. However, kubelet does not understand the operator's conceptual `cpuPodCPUSet` and `gpuPodCPUSet` pools by itself.

Therefore, the actual `Cpus_allowed_list` may not exactly match the recommended
`cpuPodCPUSet` unless additional cpuset enforcement is used. An exact-ID
difference is informational when all of the following are true:

- the assigned CPU count matches the requested CPU count;
- CPU Manager records an exclusive checkpoint entry for the container;
- exclusive and shared CPU sets do not overlap;
- the allocation satisfies the configured NUMA and full-core policy options.

Do not treat an exact-ID difference alone as a placement failure.
