# G7.12xlarge CPU Operator integration

This profile runs the semantic-router model tier as:

- Qwen3-8B: GPU
- Granite 3.1-8B: GPU
- Granite 3.1-2B: Intel Xeon CPU

CPU Operator remains responsible for node classification and kubelet CPU/Topology
Manager configuration. KServe remains responsible for the three model workloads.
The semantic-router backend service names do not change.

See [OpenShift AI and KServe installation](OPENSHIFT_AI_KSERVE.md) before deploying.

## Prerequisites

- CPU Operator already installed and reconciled on the target worker.
- The worker is labeled `cpu.example.com/node-class=mixed-cpu-amx-gpu` and
  `cpu.example.com/placement-ready=true`.
- CPU Manager is `static` on the worker.
- Two allocatable `nvidia.com/gpu` resources are present.
- `oc`, `helm`, `python3`, and PyYAML are installed.

Check the worker:

```bash
oc get nodes \
  -L cpu.example.com/node-class,cpu.example.com/placement-ready,cpu.example.com/phase4-applied
```

## 1. Generate dynamic values only

```bash
export NODE=<g7-worker>

OUTPUT=/tmp/values-g7-cpu-operator.generated.yaml \
./scripts/generate-g7-cpu-operator-values.sh

cat /tmp/values-g7-cpu-operator.generated.yaml
```

The generator reads CPU Operator's computed placement plus live scheduler state.
It follows the sizing approach used by
`cpu-operator/scripts/generate-vllm-cpu-gpu-serving-pods.sh`, with one important
extension: the total `gpuPodReservedCPUs` budget is split across the two GPU
model pods.

Defaults:

- GPU budget: read from `gpuPodReservedCPUs`.
- GPU split: 50/50 across Qwen and Granite-8B, aligned to SMT/full-core width.
- Xeon CPU policy target: `cpuPodCPUSet capacity - (1 CPU * NUMA count)`.
- Xeon scheduler cap: node allocatable CPU minus existing requests, both GPU
  requests, a per-model injected-sidecar allowance (`MODEL_SIDECAR_CPU_M`,
  default 1200 millicores for each of three models), and
  `EXTRA_SHARED_CPU_HEADROOM` (default 4 CPUs). This default accommodates the
  observed agent/proxy CPU limits if requests are raised to match them; adjust
  after inspecting actual sidecar settings. It does not change those settings.
- Existing model pods are excluded during upgrades so replacement workloads are
  not double-counted.

Useful overrides:

```bash
CPU_HEADROOM_PER_NUMA=1
EXTRA_SHARED_CPU_HEADROOM=4
RESEARCH_GPU_CPU_REQUEST=6
RAG_GPU_CPU_REQUEST=6
```

## 2. Deploy

```bash
export HF_TOKEN=<hugging-face-token>
export NODE=<g7-worker>

./scripts/deploy-g7-cpu-operator.sh
```

The deployment applies the base chart, `values-g7-cpu-operator.yaml`, and the
newly generated dynamic values. A Helm post-renderer pins the three
InferenceServices to the selected CPU Operator node. By default it also changes
the chart's Istio injection annotation to `false` for those three
InferenceServices to avoid an additional service-mesh sidecar. This alone does **not** guarantee
Guaranteed QoS: OpenShift AI also injects `agent` and `kube-rbac-proxy`.
Every container must have equal CPU and memory requests/limits. Inspect and
configure these sidecars as described in the installation guide before claiming
exclusive CPU allocation.

To keep Istio injection while testing:

```bash
CPU_OPERATOR_DISABLE_ISTIO=0 ./scripts/deploy-g7-cpu-operator.sh
```

Verify pod QoS and placement:

```bash
oc get pods -n vllm-semantic-router \
  -o custom-columns='POD:.metadata.name,QOS:.status.qosClass,NODE:.spec.nodeName'
```

Inspect CPU Manager assignments on the worker:

```bash
oc debug node/${NODE} --quiet -- \
  chroot /host cat /var/lib/kubelet/cpu_manager_state
```

If the CPU Operator repository is available locally, its grouped report is also useful:

```bash
LIVE=1 VIEW=both \
/path/to/cpu-operator/scripts/show-pod-cpus-grouped.sh "${NODE}" \
'qwen3|granite-3-1'
```

Expected high-level result:

```text
Qwen3-8B          -> 1 GPU + exclusive host CPUs
Granite-3.1-8B    -> 1 GPU + exclusive host CPUs
Granite-3.1-2B    -> 0 GPU + dynamically sized exclusive Xeon CPUs
```

Exact CPU IDs are chosen by kubelet CPU Manager. `gpuPodCPUSet` and
`cpuPodCPUSet` remain CPU Operator capacity/reference sets rather than named
cpusets passed directly to the KServe pods.

## Deployment overrides and upgrades

Use `EXTRA_VALUES=/path/to/overrides.yaml ./scripts/deploy-g7-cpu-operator.sh`
to override images while retaining the static and generated G7 profiles.
The script registers its dependency repository and falls back to writable Helm
directories if toolbox HOME is read-only. Keep explicit `HELM_*_HOME` settings
when running Helm commands manually in subsequent shells.

The post-renderer collapses identical duplicate resources from model aliases and
fails on conflicts. The deployment script also retains this release's previously
tracked shared Hugging Face secret and chat-template ConfigMap when dependency
`lookup` guards omit them on upgrades. Use this script for subsequent upgrades;
a direct Helm upgrade without the previous-manifest input does not provide that
protection. No resources from another release are adopted.
