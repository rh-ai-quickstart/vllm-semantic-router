# New Design Implementation Notes

This implementation keeps the existing PoC structure and adds the new provider-oriented design without breaking the original OpenShift Phase 4 flow.

## Implemented changes

- Added provider selection through `spec.provider.type` and `spec.provider.applyMode`.
- Kept backward compatibility with the original `spec.phase4` OpenShift flow.
- Added OpenShift provider outputs:
  - `phase4MachineConfigPools.yaml`
  - `phase4KubeletConfigs.yaml`
  - `openshiftTuned.yaml`
- Added generic Kubernetes handoff outputs:
  - `genericKubeletConfigs.yaml`
  - `genericApplyPlan.yaml`
  - separate `<policy>-generated-kubelet-config` ConfigMap containing one kubelet config per node plus `apply-plan.yaml`.
- Added NFD label merge logic:
  - NFD AMX labels can override/fill Node Topology Agent AMX fields.
  - Node Topology Agent remains the placement-grade topology source.
- Added optional TuneD CR generation and apply path for OpenShift through Node Tuning Operator.
- Updated RBAC for optional `tuned.openshift.io/tuneds` management.
- Added a generic Kubernetes example policy.

## Provider behavior

### OpenShift

`provider.type: OpenShift` generates OpenShift-native `MachineConfigPool` and `KubeletConfig` manifests. If `provider.applyMode: Managed`, the operator attempts to apply those objects and optional `Tuned` CRs.

### Generic Kubernetes / kubeadm

`provider.type: GenericKubernetes` or `Kubeadm` renders kubelet configuration artifacts only. The operator does not automatically mutate worker nodes. The generated apply plan documents the required flow: cordon/drain, stop kubelet, update kubelet config, remove `/var/lib/kubelet/cpu_manager_state`, start kubelet, wait Ready, and uncordon.

## Key ConfigMap outputs

The computed policy ConfigMap contains:

- `provider.yaml`
- `providerStatus`
- `nodeClassification.yaml`
- `topologyGroups.yaml`
- `cpuPlacementByNode.yaml`
- `generatedNodeLabels.yaml`
- `genericKubeletConfigs.yaml`
- `genericApplyPlan.yaml`
- `openshiftTuned.yaml`
- `phase4MachineConfigPools.yaml`
- `phase4KubeletConfigs.yaml`

The generic handoff ConfigMap contains:

- `<node>.kubelet-config.yaml`
- `apply-plan.yaml`
