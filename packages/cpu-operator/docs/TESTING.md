# Testing and Validation

Use this guide to validate CPU Operator from computed policy through real CPU/GPU vLLM serving.

```text
1. Validate worker policy
2. Verify kubelet CPU Manager
3. Run Guaranteed-QoS workload tests
4. Validate live CPU assignments
```

## 1. Validate one worker

```bash
NODE=<worker-node-name>

scripts/test-worker-node-output.sh "${NODE}"
```

Inspect the computed placement when needed:

```bash
oc get cm auto-vllm-cpu-policy-computed-cpu-policy \
  -n cpu-operator-system \
  -o jsonpath='{.data.cpuPlacementByNode\.yaml}' |
sed -n "/^${NODE}:/,/^[^ ]/p"
```

For a mixed worker, expect `cpuManagerPolicy: static`, `gpuPodCPUSet`, `gpuPodReservedCPUs`, `cpuPodCPUSet`, and `topologyManagerPolicy: restricted`.

> `gpuPodCPUSet` and `cpuPodCPUSet` are capacity/reference sets. kubelet CPU Manager receives integer CPU requests and may assign different exact CPU IDs.

## 2. Verify kubelet state

On OpenShift, wait for the target MachineConfigPool and worker to be ready:

```bash
oc get mcp
oc get kubeletconfig
oc get node "${NODE}"
```

Check CPU Manager state:

```bash
oc debug "node/${NODE}" --quiet -- \
  chroot /host cat /var/lib/kubelet/cpu_manager_state
```

Continue only after the worker is Ready, the target MCP is Updated, and CPU Manager reports `static`.

## 3. Workload tests

### 3.1 CPU-only test

Generate one Guaranteed-QoS CPU pod:

```bash
NODE="${NODE}" \
CPU_REQUEST=<cpu-count> \
MEMORY=1Gi \
./scripts/generate-vllm-cpu-test-pod.sh

oc apply -f examples/vllm-cpu-test-pod.generated.yaml
oc wait --for=condition=Ready \
  pod/vllm-cpu-test -n default --timeout=120s
oc logs vllm-cpu-test -n default
```

`CPU_REQUEST` must be a positive integer no larger than the `cpuPodCPUSet` capacity.

### 3.2 Mixed CPU+GPU lightweight test

For `mixed-cpu-amx-gpu`, generate both test pods:

```bash
NODE="${NODE}" \
./scripts/generate-vllm-cpu-gpu-test-pods.sh
```

The generator uses:

```text
GPU CPU request = gpuPodReservedCPUs
CPU target      = cpuPodCPUSet capacity - 1 CPU per NUMA node
CPU request     = min(CPU target, scheduler-safe whole-CPU capacity)
```

Apply GPU first, then CPU:

```bash
oc apply -f examples/vllm-gpu-test-pod.generated.yaml
oc wait --for=condition=Ready \
  pod/vllm-gpu-test -n default --timeout=120s

oc apply -f examples/vllm-cpu-test-pod.generated.yaml
oc wait --for=condition=Ready \
  pod/vllm-cpu-test -n default --timeout=120s
```

Validate the pair:

```bash
LIVE=1 VIEW=both \
scripts/show-pod-cpus-grouped.sh \
  "${NODE}" \
  'vllm-cpu-test|vllm-gpu-test'
```

PASS requires both pods to be Guaranteed QoS, the requested exclusive CPU counts to be assigned without overlap, the GPU to be admitted, and `manager=live` for both containers.

Exact CPU IDs do not need to equal the policy reference sets.

### 3.3 Transition to real CPU+GPU vLLM serving

Use this after the lightweight mixed test passes.

#### 1. Create the Hugging Face secret

The default CPU model is `meta-llama/Llama-3.1-8B-Instruct`:

```bash
read -rsp "Hugging Face token: " HF_TOKEN
echo

oc create secret generic hf-token \
  -n default \
  --from-literal=token="${HF_TOKEN}" \
  --dry-run=client -o yaml | oc apply -f -

unset HF_TOKEN
```

#### 2. Generate serving manifests

```bash
NODE="${NODE}" \
EXPOSE_ROUTES=1 \
./scripts/generate-vllm-cpu-gpu-serving-pods.sh
```

This generates:

```text
examples/vllm-gpu-serving.generated.yaml
examples/vllm-cpu-serving.generated.yaml
```

Default models are GPU `Qwen/Qwen2.5-7B-Instruct` and CPU `meta-llama/Llama-3.1-8B-Instruct`.

#### 3. Replace the lightweight pods

Capture the lightweight result once before deletion:

```bash
LIVE=1 VIEW=both \
scripts/show-pod-cpus-grouped.sh \
  "${NODE}" \
  'vllm-cpu-test|vllm-gpu-test'
```

Delete the test pair:

```bash
oc delete pod vllm-cpu-test vllm-gpu-test \
  -n default --ignore-not-found
```

#### 4. Start GPU vLLM, then CPU vLLM

```bash
oc apply -f examples/vllm-gpu-serving.generated.yaml
oc wait --for=condition=Ready \
  pod/vllm-gpu-serving -n default --timeout=600s

oc apply -f examples/vllm-cpu-serving.generated.yaml
oc wait --for=condition=Ready \
  pod/vllm-cpu-serving -n default --timeout=600s
```

Check both pods:

```bash
oc get pod vllm-gpu-serving vllm-cpu-serving -n default -o wide
```

If startup fails:

```bash
oc describe pod vllm-gpu-serving -n default
oc describe pod vllm-cpu-serving -n default
oc logs vllm-gpu-serving -n default
oc logs vllm-cpu-serving -n default
```

#### 5. Test `/v1/models` inside the cluster

Use Kubernetes Service DNS only from a pod inside the cluster.

GPU:

```bash
oc run curl-test-gpu \
  -n default --rm -it --restart=Never \
  --image=curlimages/curl -- \
  curl -fsS http://vllm-gpu-serving.default.svc:8000/v1/models
```

CPU:

```bash
oc run curl-test-cpu \
  -n default --rm -it --restart=Never \
  --image=curlimages/curl -- \
  curl -fsS http://vllm-cpu-serving.default.svc:8001/v1/models
```

PASS: each command returns HTTP 200 and JSON containing the configured model ID.

#### 6. Test `/v1/models` from the bastion

Do **not** use `*.default.svc` from the bastion. Use the OpenShift Route hostnames.

```bash
GPU_HOST="$(oc get route vllm-gpu-serving \
  -n default -o jsonpath='{.spec.host}')"
CPU_HOST="$(oc get route vllm-cpu-serving \
  -n default -o jsonpath='{.spec.host}')"

curl -fsS "http://${GPU_HOST}/v1/models"
curl -fsS "http://${CPU_HOST}/v1/models"
```

PASS: both Route requests return HTTP 200 and the expected model list.

#### 7. Validate real serving CPU placement

```bash
LIVE=1 VIEW=both \
scripts/show-pod-cpus-grouped.sh \
  "${NODE}" \
  'vllm-cpu-serving|vllm-gpu-serving'
```

PASS requires:

- both vLLM pods are Running and Guaranteed QoS;
- GPU vLLM has its requested GPU and exclusive CPUs;
- CPU vLLM has its requested exclusive CPUs;
- the exclusive CPU sets do not overlap;
- `manager=live` for both containers;
- both in-cluster and Route `/v1/models` tests return HTTP 200.

## 4. Read the grouped CPU report

Recommended node-wide view:

```bash
LIVE=1 VIEW=both \
scripts/show-pod-cpus-grouped.sh "${NODE}"
```

Interpretation:

- **Shared**: listed containers may run on the same allowed CPU pool.
- **Exclusive**: CPU Manager assigned a dedicated CPU set to a Guaranteed container.
- `manager=<cpuset> live=<cpuset>` should match.
- CPU IDs represent affinity/eligibility, not instantaneous CPU utilization.

## Troubleshooting

### `Insufficient cpu`

```bash
oc describe pod -n default <pod-name>
oc describe node "${NODE}" | sed -n '/Allocated resources:/,/Events:/p'
```

Regenerate with the paired generator or reduce an explicit CPU request. Policy capacity can be larger than live scheduler-safe capacity after existing pod requests are counted.

### `secret "hf-token" not found`

Create `default/hf-token` with key `token` before starting the default CPU vLLM model.

### `.svc` does not resolve from the bastion

Expected. Test `.svc` from an in-cluster pod. Use the OpenShift Route hostname from the bastion.

### Service request fails

Check the Service and EndpointSlice:

```bash
oc get svc vllm-gpu-serving vllm-cpu-serving -n default
oc get endpointslice -n default \
  -l kubernetes.io/service-name=vllm-gpu-serving
oc get endpointslice -n default \
  -l kubernetes.io/service-name=vllm-cpu-serving
```

### CPU Manager reports `none`

The Phase 4 kubelet configuration is not active. Recheck MCP rollout and recreate the workload after CPU Manager becomes `static`.

### `oc exec` has kubelet TLS/certificate errors

Check:

```bash
oc get csr
oc get co kube-apiserver
oc get nodes
```

This is an API-server-to-kubelet streaming issue, not a CPU placement parser issue.

## End-to-end PASS criteria

```text
[PASS] worker classification and computed placement are correct
[PASS] OpenShift node configuration is applied
[PASS] CPU Manager static policy is active
[PASS] lightweight CPU/GPU pair gets non-overlapping exclusive CPUs
[PASS] real CPU/GPU vLLM pair is Running
[PASS] CPU Manager checkpoint matches live affinity
[PASS] in-cluster /v1/models returns HTTP 200 for CPU and GPU
[PASS] bastion Route /v1/models returns HTTP 200 for CPU and GPU
```

## Cleanup

```bash
oc delete pod \
  vllm-cpu-test vllm-gpu-test \
  vllm-cpu-serving vllm-gpu-serving \
  -n default --ignore-not-found

oc delete svc \
  vllm-cpu-serving vllm-gpu-serving \
  -n default --ignore-not-found

oc delete route \
  vllm-cpu-serving vllm-gpu-serving \
  -n default --ignore-not-found
```
