# OpenShift AI and KServe installation for the heterogeneous G7 lab

This guide records the working OpenShift 4.20 / OpenShift AI 3.5.1 setup for
three control-plane nodes and one `g7.12xlarge` worker. The application uses
KServe `InferenceService` and `ServingRuntime`, with two GPU models and one CPU
model. CPU Operator configures the worker; it does not install KServe.

## 1. Prerequisites and storage

Use an authenticated `oc` shell with cluster-admin privileges, Helm 3, Python 3
and PyYAML. From the AWS deployment bastion, `./container.sh oc ...` is the
wrapper equivalent of `oc ...` inside the toolbox.

```bash
oc whoami
oc get clusterversion version
oc get nodes
oc get storageclass
oc auth can-i create datascienceclusters.datasciencecluster.opendatahub.io
```

OpenShift AI 3.5 requires a supported OpenShift release and subscription. Check
the official requirements for your release. The one-worker lab is outside the
documented two-worker baseline; success here is not production support validation.
Use a dynamically provisioned default storage class, such as `gp3-csi`.

Allow access to Red Hat registries, application image registries and Hugging Face.
Install Node Feature Discovery and NVIDIA GPU Operator for GPU workloads. Confirm
hardware discovery and device allocation before starting model pods:

```bash
export NODE=<g7-worker-name>
oc get node "$NODE" -L node.kubernetes.io/instance-type,feature.node.kubernetes.io/pci-10de.present
oc get clusterpolicy
oc get node "$NODE" -o jsonpath='GPUs={.status.allocatable.nvidia\.com/gpu}{"\n"}'
```

Expected: `g7.12xlarge`, NVIDIA PCI discovery `true`, GPU policy ready and two GPUs.
Select a driver compatible with Blackwell and your OpenShift release; verify the
actual registry tag. The lab's initial driver tag returned `manifest unknown`.
Do not assume an arbitrary older driver supports this GPU.

Plan worker **root storage** separately from PVC storage. The lab's 120GiB root
disk repeatedly triggered DiskPressure while pulling images and downloading
models. A 500GiB root EBS volume is a lab sizing recommendation, not a product
minimum. Increasing MinIO or router PVC capacity does not expand container image
storage. The unmounted local NVMe disk is not used automatically by CRI-O.

```bash
oc get node "$NODE" -o json | jq '.status.conditions[] | select(.type=="DiskPressure")'
oc debug "node/$NODE" --quiet -- chroot /host df -h /var/lib/containers /var/lib/kubelet
```

Do not remove a disk-pressure taint to force scheduling. Expand the correct root
EBS volume, then its partition and XFS filesystem using the AWS instructions
linked below. Confirm device mapping first; this lab used `/dev/nvme0n1p4`,
mounted at `/var`. Other nodes can differ. A read-only composefs `/` showing
100% is not the writable container-storage filesystem.

## 2. Console and operators

Get the console URL with `oc whoami --show-console`. The initial login username
is `kubeadmin`; its password is the contents of
`<installation-directory>/auth/kubeadmin-password` on the installer host.
Do not publish this password. An identity-provider user is needed for AI dashboard
access; this CLI lab disables the dashboard.

In the console, open OperatorHub / Software Catalog:

1. Install **cert-manager Operator for Red Hat OpenShift**, using recommended
   settings. Wait for its installation and operand pods to be ready.
2. Install **Red Hat OpenShift AI**, using the recommended namespace
   `redhat-ods-operator`, All namespaces, and a channel supported for your OCP
   release. This guide's DataScienceCluster fields are for the installed 3.5.1
   operator. Do not apply them blindly to older v1 schemas.
3. Open Installed Operators (under Ecosystem on OCP 4.20), select OpenShift AI,
   and create or edit `default-dsc` in YAML view.

## 3. Minimal DataScienceCluster

The following configuration reached Ready in this lab. It enables KServe and
removes optional components to reduce demand on the only worker. Review an
existing cluster configuration before replacing it: this profile disables other
AI platform components.

```yaml
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
  labels:
    app.kubernetes.io/name: datasciencecluster
spec:
  components:
    kserve:
      managementState: Managed
      rawDeploymentServiceConfig: Headless
      wva: {managementState: Removed}
      nim: {airGapped: false, managementState: Removed}
      modelCache: {managementState: Removed}
      modelsAsService: {managementState: Removed}
    ogx: {managementState: Removed}
    sparkoperator: {managementState: Removed}
    modelregistry:
      registriesNamespace: rhoai-model-registries
      managementState: Removed
    feastoperator: {managementState: Removed}
    trustyai:
      eval:
        lmeval: {permitCodeExecution: deny, permitOnline: deny}
      mcpGuardrailsMode: false
      managementState: Removed
    aipipelines:
      argoWorkflowsControllers: {managementState: Removed}
      managementState: Removed
    ray: {managementState: Removed}
    kueue:
      autoCreateQueues: false
      defaultClusterQueueName: default
      defaultLocalQueueName: default
      managementState: Removed
    workbenches:
      workbenchNamespace: rhods-notebooks
      managementState: Removed
    mlflowoperator: {managementState: Removed}
    dashboard: {managementState: Removed}
    trainer: {managementState: Removed}
    llamastackoperator: {managementState: Removed}
    aigateway:
      modelsAsAService: {managementState: Removed}
    trainingoperator: {managementState: Removed}
```

Save this YAML as `minimal-dsc.yaml`, then apply and wait:

```bash
oc apply -f minimal-dsc.yaml
oc wait --for=condition=Ready datasciencecluster/default-dsc --timeout=600s
oc get pods -n redhat-ods-applications
oc get crd inferenceservices.serving.kserve.io servingruntimes.serving.kserve.io
```

CRD presence alone does not prove that the controllers and webhooks are ready.
An initial `no endpoints available` for `llmisvc-webhook-server-service` resolved
when its controller became ready in the lab. If waiting does not resolve it:

```bash
oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions}{"\n"}'
oc rollout status deployment/kserve-controller-manager -n redhat-ods-applications --timeout=300s
oc rollout status deployment/llmisvc-controller-manager -n redhat-ods-applications --timeout=300s
oc logs deployment/llmisvc-controller-manager -n redhat-ods-applications --tail=100
```

Connectivity Link and LeaderWorkerSet dependency conditions concern advanced
LLMInferenceService features. Their absence did not stop this minimal
InferenceService lab from reaching Ready. Install dependencies required by the
specific serving features you enable; this is not a complete advanced-serving
installation recipe.

## 4. CPU Operator and Guaranteed QoS

Continue with [G7 CPU Operator integration](G7_CPU_OPERATOR.md). Its managed
MachineConfigPool rollout can drain and reboot the only worker, temporarily
interrupting all applications. Wait until its pool is Updated, not Updating or
Degraded, and the worker is Ready and schedulable:

```bash
oc get mcp
oc get node "$NODE" -L cpu.example.com/node-class,cpu.example.com/placement-ready
oc debug "node/$NODE" --quiet -- chroot /host cat /var/lib/kubelet/cpu_manager_state
```

Expected class: `mixed-cpu-amx-gpu`; placement-ready: `true`; policy: `static`.
These labels and equal requests/limits on the vLLM container do not prove CPU
exclusivity. OpenShift AI injected these sidecars in this lab:

| Container | CPU request / limit | Memory request / limit |
| --- | --- | --- |
| agent | 100m / 1 | 100Mi / 1Gi |
| kube-rbac-proxy | 100m / 200m | 64Mi / 128Mi |

This makes the entire pod Burstable. Under the static policy, exclusive CPUs
require a Guaranteed pod and an integer CPU request on the eligible container.
Every container, including relevant init containers, needs equal CPU and memory
requests/limits for Guaranteed QoS. Fractional sidecars can stay in the shared
CPU pool when their requests equal their limits.

Inspect your actual operator configuration:

```bash
oc get cm inferenceservice-config -n redhat-ods-applications -o json |
  jq '.data | {agent:(.agent|fromjson?),oauthProxy:(.oauthProxy|fromjson?)}'
oc get pods -n vllm-semantic-router -o json |
  jq '.items[] | select(.metadata.name | contains("predictor-")) |
      {pod:.metadata.name,qos:.status.qosClass,containers:[.spec.containers[]|{name,resources}]}'
```

Configure sidecar equality through the settings supported by your installed
OpenShift AI release. Raising requests to the existing limits preserves sidecar
limits but adds **1 CPU and 988MiB per model pod** with the values above. Account
for all three models when sizing the single worker. Direct edits to generated
Deployments or operator-managed ConfigMaps may be overwritten; back up settings
and use a supported customization path. This patch does not silently change
cluster-wide sidecar resources or authentication.

After changing sidecar settings and recreating the serving pods, regenerate CPU
values with sufficient shared headroom, then verify `Guaranteed` and actual
entries in `cpu_manager_state`. Check scheduling during replacement: a one-worker
node with two occupied GPUs cannot run an extra GPU replica simultaneously.
Kubelet chooses CPU IDs; CPU Operator's reference cpusets do not guarantee named
GPU-versus-CPU partition assignment by themselves.

## 5. Helm, images and persistent volumes

For the router schema and API fixes, immutable image references, private registry
credentials and safe upgrades, see [Deployment repair and upgrades](DEPLOYMENT_REPAIR.md).

If HOME is read-only, set writable Helm paths in every shell used for Helm:

```bash
export HELM_CONFIG_HOME=/tmp/semantic-router-helm/config
export HELM_CACHE_HOME=/tmp/semantic-router-helm/cache
export HELM_DATA_HOME=/tmp/semantic-router-helm/data
mkdir -p "$HELM_CONFIG_HOME" "$HELM_CACHE_HOME" "$HELM_DATA_HOME"
helm repo add ai-architecture-charts https://rh-ai-quickstart.github.io/ai-architecture-charts
helm repo update
```

The deployment script handles repository registration and writable-path fallback.
Use the same explicit Helm paths for later manual commands.

The base chart points to published Chat UI and API images. You can use them when
they are accessible and compatible, but their `latest` tags do not prove a match
to your checkout. Follow README build-and-push instructions for a reproducible
branch build and set repositories plus immutable version tags in an override.

The dependency's `quay.io/minio/minio:latest` failed with `unauthorized` in this
lab. Do not assume changing it to an old tag or Docker Hub fixes it. Build or
obtain a compatible MinIO image in an accessible registry and verify worker pull
access (including any imagePullSecrets). The official community repository now
uses source-only distribution. No replacement image is assumed by this patch.

Example image override, after publishing your tested image:

```yaml
minio:
  image:
    repository: quay.io/YOUR_ORG/minio
    tag: YOUR_TESTED_VERSION
```

```bash
read -rsp 'Hugging Face token: ' HF_TOKEN; echo
export HF_TOKEN
export NODE=<g7-worker-name>
EXTRA_VALUES=/path/to/images.yaml ./scripts/deploy-g7-cpu-operator.sh
```

Keep a private copy of Helm values/manifests before changes: these may contain
credentials. Avoid uninstall/reinstall as troubleshooting; uninstall deletes
standalone router and Llama Stack PVCs, and a Delete reclaim policy can delete
the underlying EBS volumes. With WaitForFirstConsumer, newly created PVCs may
remain Pending until their pods can schedule.

To recover an accidentally missing claim, extract its definition from
`helm get manifest`, review that it is absent and not still terminating, then
apply only the missing PVC definition. This restores the claim, not deleted data.

## 6. Verify and diagnose

```bash
export NS=vllm-semantic-router
oc get pvc -n "$NS"
oc get inferenceservice -n "$NS"
oc get pods -n "$NS" -o wide
oc get events -n "$NS" --field-selector type=Warning --sort-by=.lastTimestamp
```

| Symptom | First check |
| --- | --- |
| Models 1/3 Running | vLLM container logs; downloads and warmup can take minutes |
| Healthy models become Error | Pod status and Events for eviction, OOM or disk pressure |
| Router / Llama Stack Pending | PVC existence, binding and FailedScheduling Events |
| API readiness 503 | Router health; current backend readiness depends on it |
| MinIO ImagePullBackOff | Exact registry error and configured image |
| HPA metrics warnings during startup | Model readiness before changing metrics configuration |
| Burstable model pod | All injected containers' resource requests and limits |

## References

- [OpenShift AI 3.5 installation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/installing_and_uninstalling_openshift_ai_self-managed/installing-and-deploying-openshift-ai_install)
- [Kubernetes CPU Manager](https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/)
- [Kubernetes node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
- [AWS EBS filesystem expansion](https://docs.aws.amazon.com/ebs/latest/userguide/recognize-expanded-volume-linux.html)
- [MinIO source distribution](https://github.com/minio/minio)

## Guaranteed QoS setup for the single-worker G7 profile

The CPU Operator enables static CPU management on the worker. Every container
in a predictor pod must have matching CPU and memory requests/limits for the
pod to be Guaranteed. KServe's injected agent and proxy count too. The G7
values generator now checks the installed defaults and reads their combined
CPU requests instead of assuming 1200m. Additional injected containers can
still prevent Guaranteed QoS; the post-deployment check catches that.

Run the read-only check inside the toolbox before deployment:

```bash
python3 scripts/kserve-guaranteed-qos.py
```

If it reports unequal resources, explicitly apply the lab configuration:

```bash
python3 scripts/kserve-guaranteed-qos.py --apply \
  --backup /tmp/kserve-before-guaranteed.json
./scripts/deploy-g7-cpu-operator.sh
```

The helper preserves limits and other settings, raises agent/proxy requests to
those limits, and sets `opendatahub.io/managed=false` in the same patch. The
backup path must be new; preserve that file for rollback. This changes defaults
for other KServe workloads in the cluster and takes manual ownership of this
ConfigMap. Review it after OpenShift AI upgrades. Existing pods retain their
old resources until recreated. The helper never deletes pods or disables auth.

The G7 post-renderer sets `spec.predictor.deploymentStrategy` to RollingUpdate
with `maxSurge: 0` and `maxUnavailable: 1` for its three models. This allows an
update without a third GPU or a second 25-CPU model replica. Updating a model
briefly interrupts its inference service; Helm may update multiple models at
once. The deployment script checks CRD support first and verifies the resulting
Deployment rollouts, Ready/Guaranteed pods, and exclusive CPU Manager checkpoint
assignments. The default three-GPU profile without `CPU_OPERATOR_NODE` retains
its existing rollout behavior.

For an installed release, changing only the ConfigMap does not recreate model
pods. Reconcile each InferenceService once with a predictor annotation, then
wait for its rollout before proceeding to the next model. If the installed
KServe cannot accept `deploymentStrategy`, inspect the replacement pod's QoS
and scheduling events, then delete only that model's old pod to release its
GPU/CPU capacity. Do not repeatedly annotate, force-delete pods, or edit
controller-owned Deployments as a persistent fix.

```bash
oc annotate inferenceservice granite-3-1-2b-instruct \
  -n vllm-semantic-router cpu-qos-reconcile="$(date -u +%Y%m%dT%H%M%SZ)" --overwrite
oc rollout status deployment/granite-3-1-2b-instruct-predictor \
  -n vllm-semantic-router --timeout=900s
# Repeat sequentially for granite-3-1-8b-instruct and qwen3-8b.

python3 scripts/kserve-guaranteed-qos.py --verify vllm-semantic-router --node "$NODE"
LIVE=1 VIEW=both bash packages/cpu-operator/scripts/show-pod-cpus-grouped.sh \
  "$NODE" 'vllm-semantic-router/.*(qwen3-8b|granite-3-1).*predictor'
```

The checkpoint check verifies exclusive counts and non-overlap; the grouped
report additionally verifies live affinity. Actual CPU IDs may differ from
`gpuPodCPUSet`/`cpuPodCPUSet`, which are reference ranges, not enforced pools.
An integer one-CPU agent gets its own exclusive CPU. A fractional proxy remains
in the shared pool even when its pod is Guaranteed.

Restore only the sidecar entries and original management annotation if needed:

```bash
python3 scripts/kserve-guaranteed-qos.py --restore /tmp/kserve-before-guaranteed.json
```

Restoration also requires replacement pods to take effect. Re-enabling operator
management allows the operator to reconcile this ConfigMap again.
