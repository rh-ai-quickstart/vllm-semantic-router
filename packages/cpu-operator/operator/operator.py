#!/usr/bin/env python3

from typing import Dict, List, Any, Tuple, Optional
import hashlib
import re
import time

import kopf
import yaml
from kubernetes import client, config
from kubernetes.client.rest import ApiException

GROUP = "cpu.example.com"
VERSION = "v1alpha1"
TOPOLOGY_PLURAL = "nodecputopologies"
POLICY_PLURAL = "cpuplacementpolicies"

MCO_GROUP = "machineconfiguration.openshift.io"
MCO_VERSION = "v1"
MCP_PLURAL = "machineconfigpools"
KUBELETCONFIG_PLURAL = "kubeletconfigs"

TUNED_GROUP = "tuned.openshift.io"
TUNED_VERSION = "v1"
TUNED_PLURAL = "tuneds"
TUNED_NAMESPACE = "openshift-cluster-node-tuning-operator"

VALID_CLASSES = {"mixed-cpu-amx-gpu", "cpu-amx", "cpu-only", "gpu-only"}


def expand_cpuset(cpuset: str) -> List[int]:
    out: List[int] = []
    for part in str(cpuset or "").split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            out.extend(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    return sorted(set(out))


def compress_cpuset(cpus: List[int]) -> str:
    cpus = sorted(set(cpus))
    if not cpus:
        return ""
    ranges = []
    start = prev = cpus[0]
    for cpu in cpus[1:]:
        if cpu == prev + 1:
            prev = cpu
        else:
            ranges.append((start, prev))
            start = prev = cpu
    ranges.append((start, prev))
    return ",".join(str(s) if s == e else f"{s}-{e}" for s, e in ranges)


def subtract_cpuset(all_cpus: List[int], remove: List[int]) -> List[int]:
    remove_set = set(remove)
    return [c for c in sorted(set(all_cpus)) if c not in remove_set]


def split_cpuset_groups(cpuset: str) -> List[List[int]]:
    return [expand_cpuset(p.strip()) for p in str(cpuset or "").split(",") if p.strip()]


def choose_balanced_from_cpulist(cpulist: str, count: int, exclude: Optional[List[int]] = None) -> List[int]:
    if count <= 0:
        return []
    exclude_set = set(exclude or [])
    groups = [[c for c in g if c not in exclude_set] for g in split_cpuset_groups(cpulist)]
    groups = [g for g in groups if g]
    if not groups:
        return []
    if len(groups) == 1:
        return groups[0][:count]
    per = count // len(groups)
    rem = count % len(groups)
    out = []
    for idx, group in enumerate(groups):
        out.extend(group[: per + (1 if idx < rem else 0)])
    return sorted(out)


def choose_balanced_across_numa(numa_nodes: List[Dict], total_count: int, exclude: Optional[List[int]] = None) -> List[int]:
    if total_count <= 0 or not numa_nodes:
        return []
    exclude_set = set(exclude or [])
    sorted_numa = sorted(numa_nodes, key=lambda x: x.get("id", 0))
    per = total_count // len(sorted_numa)
    rem = total_count % len(sorted_numa)
    out = []
    for idx, numa in enumerate(sorted_numa):
        take = per + (1 if idx < rem else 0)
        out.extend(choose_balanced_from_cpulist(numa.get("cpus", ""), take, list(exclude_set | set(out))))
    return sorted(out)


def allocate_same_numa_first(numa_nodes: List[Dict], exclude: Optional[List[int]] = None) -> Dict[str, Any]:
    exclude_set = set(exclude or [])
    numa_pools = {}
    for numa in sorted(numa_nodes, key=lambda x: x.get("id", 0)):
        cpus = [c for c in expand_cpuset(numa.get("cpus", "")) if c not in exclude_set]
        numa_pools[str(numa.get("id"))] = compress_cpuset(cpus)
    preferred = next((k for k, v in numa_pools.items() if v), "")
    return {
        "strategy": "same-numa-node-first",
        "preferredNumaNode": preferred,
        "numaLocalCPUSetByNuma": numa_pools,
    }


def all_numa_cpus(numa_nodes: List[Dict]) -> List[int]:
    out = []
    for n in numa_nodes:
        out.extend(expand_cpuset(n.get("cpus", "")))
    return sorted(set(out))


def list_node_topologies(namespace: str) -> List[Dict]:
    api = client.CustomObjectsApi()
    return api.list_namespaced_custom_object(GROUP, VERSION, namespace, TOPOLOGY_PLURAL).get("items", [])


def list_cpu_placement_policies(namespace: str) -> List[Dict]:
    api = client.CustomObjectsApi()
    return api.list_namespaced_custom_object(GROUP, VERSION, namespace, POLICY_PLURAL).get("items", [])


def patch_cpu_placement_policy_status(namespace: str, name: str, status: Dict[str, Any], logger=None):
    api = client.CustomObjectsApi()
    try:
        api.patch_namespaced_custom_object_status(
            GROUP, VERSION, namespace, POLICY_PLURAL, name, {"status": status}
        )
    except ApiException as exc:
        # Keep compatibility with an older CRD that has no status subresource yet.
        if exc.status in (404, 405, 403):
            if logger:
                logger.warning("Could not patch CPUPlacementPolicy/%s status: %s", name, exc)
            return
        raise


def trigger_policy_reconcile(namespace: str, policy_name: str, reason: str):
    api = client.CustomObjectsApi()
    annotation_key = "cpu.example.com/reconcile-trigger"
    body = {
        "metadata": {
            "annotations": {
                annotation_key: f"{reason}-{int(time.time())}",
            }
        }
    }
    api.patch_namespaced_custom_object(GROUP, VERSION, namespace, POLICY_PLURAL, policy_name, body)


def list_nodes() -> Dict[str, Dict]:
    return {n.metadata.name: n.to_dict() for n in client.CoreV1Api().list_node().items}


def upsert_configmap(namespace: str, name: str, data: Dict[str, str]):
    core = client.CoreV1Api()
    body = client.V1ConfigMap(metadata=client.V1ObjectMeta(name=name, namespace=namespace), data=data)
    try:
        core.read_namespaced_config_map(name=name, namespace=namespace)
        core.patch_namespaced_config_map(name=name, namespace=namespace, body=body)
    except ApiException as e:
        if e.status == 404:
            core.create_namespaced_config_map(namespace=namespace, body=body)
        else:
            raise


def patch_node_labels(node_name: str, labels: Dict[str, str]):
    client.CoreV1Api().patch_node(node_name, {"metadata": {"labels": labels}})


def upsert_cluster_custom_object(group: str, version: str, plural: str, name: str, body: Dict):
    api = client.CustomObjectsApi()
    try:
        api.get_cluster_custom_object(group, version, plural, name)
        api.patch_cluster_custom_object(group, version, plural, name, body)
    except ApiException as e:
        if e.status == 404:
            api.create_cluster_custom_object(group, version, plural, body)
        else:
            raise


def upsert_namespaced_custom_object(group: str, version: str, namespace: str, plural: str, name: str, body: Dict):
    api = client.CustomObjectsApi()
    try:
        api.get_namespaced_custom_object(group, version, namespace, plural, name)
        api.patch_namespaced_custom_object(group, version, namespace, plural, name, body)
    except ApiException as e:
        if e.status == 404:
            api.create_namespaced_custom_object(group, version, namespace, plural, body)
        else:
            raise


def get_nested(d: Dict, path: List[str], default=None):
    cur = d
    for p in path:
        if not isinstance(cur, dict):
            return default
        cur = cur.get(p)
    return cur if cur is not None else default


def match_selector(labels: Dict[str, str], selector: Dict[str, str]) -> bool:
    if not selector:
        return True
    for key, expected in selector.items():
        if key not in labels:
            return False
        if expected not in ("", None) and str(labels.get(key)) != str(expected):
            return False
    return True


def get_gpu_count_from_node(node: Dict) -> int:
    alloc = get_nested(node, ["status", "allocatable"], {}) or {}
    gpu = alloc.get("nvidia.com/gpu")
    if gpu is not None:
        try:
            return int(gpu)
        except (TypeError, ValueError):
            return 0
    labels = get_nested(node, ["metadata", "labels"], {}) or {}
    if labels.get("nvidia.com/gpu.present") == "true" or labels.get("feature.node.kubernetes.io/pci-10de.present") == "true":
        return 1
    count = labels.get("nvidia.com/gpu.count")
    if count:
        try:
            return int(count)
        except ValueError:
            return 1
    return 0


def get_gpu_count(node: Dict, topo_status: Dict) -> int:
    return max(get_gpu_count_from_node(node), int(topo_status.get("gpuCountFromPCI") or 0), len(topo_status.get("gpus") or []))


def amx_supported(topo_status: Dict) -> bool:
    amx = topo_status.get("amx") or {}
    return bool(amx.get("amx_bf16")) and bool(amx.get("amx_int8"))


def amx_detail(topo_status: Dict) -> Dict[str, Any]:
    amx = topo_status.get("amx") or {}
    return {
        "amx_bf16": bool(amx.get("amx_bf16")),
        "amx_int8": bool(amx.get("amx_int8")),
        "amx_tile": bool(amx.get("amx_tile")),
        "amx_fp16": bool(amx.get("amx_fp16")),
        "amx_supported": amx_supported(topo_status),
        "flags": amx.get("flags") or [],
    }


def total_logical_cpus(numa_nodes: List[Dict]) -> int:
    return len(all_numa_cpus(numa_nodes))


def merge_topology_with_node_features(topo_status: Dict, node: Dict) -> Dict:
    """Merge NFD/GPU Operator node labels into topology status.

    NFD is the preferred source for generic feature labels when available.
    The Node Topology Agent remains the source for placement-grade NUMA/core/GPU locality.
    """
    merged = dict(topo_status or {})
    labels = get_nested(node, ["metadata", "labels"], {}) or {}
    amx = dict(merged.get("amx") or {})

    if labels.get("feature.node.kubernetes.io/cpu-cpuid.AMX_BF16") == "true":
        amx["amx_bf16"] = True
    if labels.get("feature.node.kubernetes.io/cpu-cpuid.AMX_INT8") == "true":
        amx["amx_int8"] = True
    if labels.get("feature.node.kubernetes.io/cpu-cpuid.AMX_TILE") == "true":
        amx["amx_tile"] = True
    if labels.get("feature.node.kubernetes.io/cpu-cpuid.AMX_FP16") == "true":
        amx["amx_fp16"] = True

    merged["amx"] = amx
    merged["featureSources"] = {
        "nfd": any(k.startswith("feature.node.kubernetes.io/") for k in labels),
        "nodeTopologyAgent": True,
        "gpuOperatorAllocatable": bool(get_nested(node, ["status", "allocatable"], {}) or {}),
    }
    return merged


def classify_node(node: Dict, topo_status: Dict, spec: Dict) -> Tuple[str, Dict[str, Any]]:
    labels = get_nested(node, ["metadata", "labels"], {}) or {}
    classification = spec.get("classification", {}) or {}
    # Use a separate manual override label so the operator does not treat its own
    # generated cpu.example.com/node-class label as an override on later reconciles.
    generated_node_class_label = "cpu.example.com/node-class"
    override_key = classification.get("overrideLabel", "cpu.example.com/node-class-override")
    allow_generated_override = bool(classification.get("allowGeneratedNodeClassAsOverride", False))
    override = labels.get(override_key)
    if override_key == generated_node_class_label and not allow_generated_override:
        override = None

    gpu_count = get_gpu_count(node, topo_status)
    cpu_count = total_logical_cpus(topo_status.get("numaNodes") or [])
    has_amx = amx_supported(topo_status)

    if override in VALID_CLASSES:
        if override in ("cpu-amx", "mixed-cpu-amx-gpu") and not has_amx:
            return ("gpu-only" if gpu_count else "cpu-only"), {
                "reason": f"override {override_key}={override} requested AMX class but amx_bf16/amx_int8 missing",
                "requestedOverride": override,
                "gpuCount": gpu_count,
                "logicalCPUs": cpu_count,
                "amx": amx_detail(topo_status),
            }
        return override, {"reason": f"override label {override_key}={override}", "gpuCount": gpu_count, "logicalCPUs": cpu_count, "amx": amx_detail(topo_status)}

    gpu_only_selector = classification.get("gpuOnlyNodeSelector", {}) or {}
    amx_selector = classification.get("amxNodeSelector", {}) or {}
    cpu_amx_min = int(classification.get("cpuAmxMinLogicalCPUs", 64))

    if gpu_count > 0 and match_selector(labels, gpu_only_selector) and gpu_only_selector:
        return "gpu-only", {"reason": "matched gpuOnlyNodeSelector", "gpuCount": gpu_count, "logicalCPUs": cpu_count, "amx": amx_detail(topo_status)}
    if gpu_count > 0 and has_amx:
        return "mixed-cpu-amx-gpu", {"reason": "GPU detected and amx_bf16/amx_int8 supported", "gpuCount": gpu_count, "logicalCPUs": cpu_count, "amx": amx_detail(topo_status)}
    if gpu_count > 0:
        return "gpu-only", {"reason": "GPU detected but amx_bf16/amx_int8 missing", "gpuCount": gpu_count, "logicalCPUs": cpu_count, "amx": amx_detail(topo_status)}
    if has_amx and match_selector(labels, amx_selector) and amx_selector:
        return "cpu-amx", {"reason": "matched amxNodeSelector and amx_bf16/amx_int8 supported", "gpuCount": gpu_count, "logicalCPUs": cpu_count, "amx": amx_detail(topo_status)}
    if has_amx and cpu_count >= cpu_amx_min:
        return "cpu-amx", {"reason": f"amx_bf16/amx_int8 supported and logical CPU count >= {cpu_amx_min}", "gpuCount": gpu_count, "logicalCPUs": cpu_count, "amx": amx_detail(topo_status)}
    return "cpu-only", {"reason": "default non-GPU/non-AMX worker", "gpuCount": gpu_count, "logicalCPUs": cpu_count, "amx": amx_detail(topo_status)}


def profile_for_class(spec: Dict, node_class: str) -> Dict:
    defaults = {
        "mixed-cpu-amx-gpu": {
            "placement": {
                "strategy": "balanced-shared-cpu-and-gpu",
                "gpuPodReservedCPUs": 24,
                "gpuPodDistribution": "balanced-across-numa",
                "cpuPodPool": "all-remaining-balanced-across-numa",
            },
            "cpuManagerPolicy": "static",
            "cpuManagerPolicyOptions": {
                "distribute-cpus-across-numa": "true",
                "full-pcpus-only": "true",
            },
            "topologyManagerPolicy": "restricted",
        },
        "cpu-amx": {
            "placement": {
                "strategy": "balanced-reserved-other-pods",
                "reservedOtherPodsPerNuma": 1,
                "cpuPodPool": "all-remaining-balanced-across-numa",
            },
            "cpuManagerPolicy": "static",
            "cpuManagerPolicyOptions": {
                "distribute-cpus-across-numa": "true",
                "full-pcpus-only": "true",
            },
            "topologyManagerPolicy": "restricted",
        },
        "cpu-only": {
            "placement": {"strategy": "same-numa-node-first"},
            "cpuManagerPolicy": "static",
            "cpuManagerPolicyOptions": {},
            "topologyManagerPolicy": "single-numa-node",
        },
        "gpu-only": {
            "placement": {"strategy": "same-numa-node-first"},
            "cpuManagerPolicy": "static",
            "cpuManagerPolicyOptions": {},
            "topologyManagerPolicy": "single-numa-node",
        },
    }
    user_profile = (spec.get("profiles", {}) or {}).get(node_class, {}) or {}
    merged = {**defaults[node_class], **user_profile}
    merged["placement"] = {**defaults[node_class].get("placement", {}), **user_profile.get("placement", {})}
    merged["cpuManagerPolicyOptions"] = {
        **defaults[node_class].get("cpuManagerPolicyOptions", {}),
        **user_profile.get("cpuManagerPolicyOptions", {}),
    }
    return merged


def compute_placement_for_node(topo_status: Dict, node_class: str, profile: Dict) -> Dict[str, Any]:
    numa_nodes = sorted(topo_status.get("numaNodes") or [], key=lambda x: x.get("id", 0))
    all_cpus = all_numa_cpus(numa_nodes)
    placement = profile.get("placement", {}) or {}
    strategy = placement.get("strategy", "")

    if node_class == "mixed-cpu-amx-gpu":
        gpu_count = int(topo_status.get("gpuCountFromPCI") or len(topo_status.get("gpus") or []) or 1)
        gpu_reserved = int(placement.get("gpuPodReservedCPUs", 12))
        gpu_pod_cpus = choose_balanced_across_numa(numa_nodes, gpu_reserved)
        cpu_pod_cpus = subtract_cpuset(all_cpus, gpu_pod_cpus)
        return {
            "strategy": strategy,
            "topologyManagerPolicy": profile.get("topologyManagerPolicy", "restricted"),
            "cpuManagerPolicy": profile.get("cpuManagerPolicy", "static"),
            "cpuManagerPolicyOptions": profile.get("cpuManagerPolicyOptions", {}),
            "gpuCount": gpu_count,
            "gpuPodCPUSet": compress_cpuset(gpu_pod_cpus),
            "gpuPodReservedCPUs": len(gpu_pod_cpus),
            "gpuPodDistribution": "balanced-across-numa",
            "cpuPodCPUSet": compress_cpuset(cpu_pod_cpus),
            "cpuPodDistribution": "remaining-balanced-across-numa",
            # Do not use reservedSystemCPUs for GPU pod CPUs. That would remove
            # those CPUs from the exclusive allocation pool for all pods.
            "systemReservedCPUSet": "",
            "note": "CPU Manager can enforce static CPU policy and balanced allocation. It does not create separate GPU-vs-CPU pod pools by itself.",
        }

    if node_class == "cpu-amx":
        per_numa = int(placement.get("reservedOtherPodsPerNuma", 2))
        other_reserved = []
        for numa in numa_nodes:
            other_reserved.extend(choose_balanced_from_cpulist(numa.get("cpus", ""), per_numa))
        cpu_pod_cpus = subtract_cpuset(all_cpus, other_reserved)
        return {
            "strategy": strategy,
            "topologyManagerPolicy": profile.get("topologyManagerPolicy", "restricted"),
            "cpuManagerPolicy": profile.get("cpuManagerPolicy", "static"),
            "cpuManagerPolicyOptions": profile.get("cpuManagerPolicyOptions", {}),
            "otherPodsReservedCPUSet": compress_cpuset(other_reserved),
            "reservedOtherPodsPerNuma": per_numa,
            "cpuPodCPUSet": compress_cpuset(cpu_pod_cpus),
            "cpuPodDistribution": "remaining-balanced-across-numa",
            "systemReservedCPUSet": compress_cpuset(other_reserved),
            "note": "reservedSystemCPUs maps to the other-pods reserved CPU set for this group.",
        }

    local = allocate_same_numa_first(numa_nodes)
    return {
        "strategy": "same-numa-node-first",
        "topologyManagerPolicy": profile.get("topologyManagerPolicy", "single-numa-node"),
        "cpuManagerPolicy": profile.get("cpuManagerPolicy", "static"),
        "cpuManagerPolicyOptions": profile.get("cpuManagerPolicyOptions", {}),
        **local,
        "systemReservedCPUSet": "",
        "note": "CPU Manager static plus Topology Manager single-numa-node is the Phase 4 target for same-NUMA-first groups.",
    }


def legacy_reserved_cpuset_from_placement(node_class: str, placement: Dict[str, Any]) -> str:
    if node_class == "mixed-cpu-amx-gpu":
        return placement.get("gpuPodCPUSet", "")
    if node_class == "cpu-amx":
        return placement.get("otherPodsReservedCPUSet", "")
    pools = placement.get("numaLocalCPUSetByNuma") or {}
    preferred = placement.get("preferredNumaNode", "")
    return pools.get(str(preferred), "")


def phase4_reserved_system_cpus(node_class: str, placement: Dict[str, Any]) -> str:
    """
    CPU Manager's reservedSystemCPUs means CPUs reserved for OS/system/shared
    work and removed from the exclusive allocation pool.

    Do not set reservedSystemCPUs to the GPU pod CPU set. GPU pods need those
    CPUs to remain allocatable.
    """
    if node_class == "cpu-amx":
        return placement.get("otherPodsReservedCPUSet", "")
    return placement.get("systemReservedCPUSet", "")


def topology_group_name(node_class: str, signature: str) -> str:
    """Return a stable DNS-safe group name for a topology signature.

    Do not use Python's built-in hash(); it is intentionally randomized
    per interpreter process and would rename MCP/KubeletConfig objects after
    every operator restart.
    """
    digest = hashlib.sha256(signature.encode("utf-8")).hexdigest()[:8]
    return dns_safe_name(f"{node_class}-{digest}", 63)


def topology_signature(topo_status: Dict, node_class: str, profile: Dict) -> str:
    numa_shapes = [f"{n.get('id')}:{len(expand_cpuset(n.get('cpus', '')))}" for n in sorted(topo_status.get("numaNodes") or [], key=lambda x: x.get("id", 0))]
    placement = profile.get("placement", {}) or {}
    return "|".join([
        f"class={node_class}",
        f"numa={';'.join(numa_shapes)}",
        f"gpuNuma={','.join(map(str, topo_status.get('gpuLocalNumaNodes') or []))}",
        f"amx={amx_supported(topo_status)}",
        f"strategy={placement.get('strategy')}",
        f"gpuPodReserved={placement.get('gpuPodReservedCPUs', '')}",
        f"otherPerNuma={placement.get('reservedOtherPodsPerNuma', '')}",
        f"cpuManagerOptions={profile.get('cpuManagerPolicyOptions', {})}",
    ])


def dns_safe_name(raw: str, max_len: int = 50) -> str:
    name = re.sub(r"[^a-z0-9-]+", "-", raw.lower()).strip("-")
    name = re.sub(r"-+", "-", name)
    if len(name) > max_len:
        name = name[:max_len].rstrip("-")
    return name or "cpu-placement"


def mcp_name_for_group(group_name: str, phase4: Dict) -> str:
    prefix = phase4.get("machineConfigPoolNamePrefix", "cpu")
    return dns_safe_name(f"{prefix}-{group_name}", 50)


def pool_label_key(mcp_name: str) -> str:
    return f"pools.operator.machineconfiguration.openshift.io/{mcp_name}"


def build_machine_config_pool(group_name: str, group: Dict, phase4: Dict) -> Dict:
    mcp_name = mcp_name_for_group(group_name, phase4)
    return {
        "apiVersion": f"{MCO_GROUP}/{MCO_VERSION}",
        "kind": "MachineConfigPool",
        "metadata": {
            "name": mcp_name,
            "labels": {
                pool_label_key(mcp_name): "",
                "cpu.example.com/topology-group": group_name,
                "cpu.example.com/node-class": group.get("nodeClass", ""),
            },
        },
        "spec": {
            "machineConfigSelector": {
                "matchExpressions": [
                    {
                        "key": "machineconfiguration.openshift.io/role",
                        "operator": "In",
                        "values": ["worker", mcp_name],
                    }
                ]
            },
            "nodeSelector": {
                "matchLabels": {
                    "cpu.example.com/topology-group": group_name,
                }
            },
            "paused": bool(phase4.get("pauseMachineConfigPool", False)),
        },
    }


def build_kubelet_config(group_name: str, group: Dict, phase4: Dict) -> Dict:
    mcp_name = mcp_name_for_group(group_name, phase4)
    kc_name = dns_safe_name(f"kubelet-{mcp_name}", 63)

    # Only include reservedSystemCPUs when every node in the group has the same value.
    # KubeletConfig applies to the whole MCP, not one node at a time.
    reserved_values = sorted({
        (p.get("systemReservedCPUSet") or "")
        for p in (group.get("placementByNode") or {}).values()
        if p.get("systemReservedCPUSet")
    })
    kubelet_config = kubelet_config_from_group(group, phase4)
    if len(reserved_values) == 1:
        kubelet_config["reservedSystemCPUs"] = reserved_values[0]
    elif len(reserved_values) > 1:
        kubelet_config["reservedSystemCPUsComment"] = "Not set because nodes in this MCP group have different reservedSystemCPUs values."

    return {
        "apiVersion": f"{MCO_GROUP}/{MCO_VERSION}",
        "kind": "KubeletConfig",
        "metadata": {
            "name": kc_name,
            "labels": {
                "cpu.example.com/topology-group": group_name,
                "cpu.example.com/node-class": group.get("nodeClass", ""),
            },
        },
        "spec": {
            "machineConfigPoolSelector": {
                "matchLabels": {
                    pool_label_key(mcp_name): "",
                }
            },
            "kubeletConfig": kubelet_config,
        },
    }


def build_phase4_manifests(topology_groups: Dict[str, Dict], phase4: Dict) -> Dict[str, Dict[str, Dict]]:
    manifests = {"machineConfigPools": {}, "kubeletConfigs": {}}
    for group_name, group in sorted(topology_groups.items()):
        mcp = build_machine_config_pool(group_name, group, phase4)
        kc = build_kubelet_config(group_name, group, phase4)
        manifests["machineConfigPools"][mcp["metadata"]["name"]] = mcp
        manifests["kubeletConfigs"][kc["metadata"]["name"]] = kc
    return manifests


def apply_phase4_manifests(manifests: Dict[str, Dict[str, Dict]]):
    for name, body in manifests.get("machineConfigPools", {}).items():
        upsert_cluster_custom_object(MCO_GROUP, MCO_VERSION, MCP_PLURAL, name, body)
    for name, body in manifests.get("kubeletConfigs", {}).items():
        upsert_cluster_custom_object(MCO_GROUP, MCO_VERSION, KUBELETCONFIG_PLURAL, name, body)


def build_node_labels(node_class: str, gpu_count: int, topo_status: Dict, group_name: str, placement: Dict[str, Any], labels_spec: Dict, phase4_applied: bool) -> Dict[str, str]:
    prefix = labels_spec.get("prefix", "cpu.example.com")
    amx = amx_detail(topo_status)
    return {
        f"{prefix}/topology-ready": "true",
        f"{prefix}/node-class": node_class,
        f"{prefix}/topology-group": group_name,
        f"{prefix}/placement-strategy": placement.get("strategy", "unknown")[:63],
        f"{prefix}/gpu-count": str(gpu_count),
        f"{prefix}/gpu-local-numa": ",".join(map(str, topo_status.get("gpuLocalNumaNodes") or [])) or "none",
        f"{prefix}/amx-supported": str(amx["amx_supported"]).lower(),
        f"{prefix}/amx-bf16": str(amx["amx_bf16"]).lower(),
        f"{prefix}/amx-int8": str(amx["amx_int8"]).lower(),
        f"{prefix}/placement-ready": "true",
        f"{prefix}/phase4-applied": str(phase4_applied).lower(),
    }


def normalize_provider(spec: Dict) -> Dict[str, Any]:
    provider = dict(spec.get("provider") or {})

    # Backward compatibility with the original phase4 OpenShift-only schema.
    phase4 = dict(spec.get("phase4") or {})
    if not provider:
        if phase4:
            provider = {
                "type": "OpenShift",
                "applyMode": "Managed" if phase4.get("apply", True) else "RecommendationOnly",
            }
        else:
            provider = {"type": "GenericKubernetes", "applyMode": "RecommendationOnly"}

    provider_type = str(provider.get("type", "GenericKubernetes"))
    default_apply_mode = "Managed" if provider_type.lower() == "openshift" else "RecommendationOnly"
    apply_mode = str(provider.get("applyMode", default_apply_mode))
    return {"type": provider_type, "applyMode": apply_mode}


def effective_phase4(spec: Dict, provider: Dict[str, Any]) -> Dict[str, Any]:
    phase4 = dict(spec.get("phase4") or {})
    if provider.get("type", "").lower() == "openshift":
        phase4.setdefault("enabled", True)
        phase4["apply"] = provider.get("applyMode") == "Managed" or bool(phase4.get("apply"))
        openshift = spec.get("openshift") or {}
        if openshift.get("machineConfigPoolNamePrefix"):
            phase4["machineConfigPoolNamePrefix"] = openshift.get("machineConfigPoolNamePrefix")
        if openshift.get("topologyManagerScope"):
            phase4["topologyManagerScope"] = openshift.get("topologyManagerScope")
    return phase4


def kubelet_config_from_group(group: Dict, phase4: Dict, reserved_system_cpus: str = "") -> Dict[str, Any]:
    cfg = {
        "cpuManagerPolicy": group.get("cpuManagerPolicy", "static"),
        "cpuManagerPolicyOptions": group.get("cpuManagerPolicyOptions", {}),
        "topologyManagerPolicy": group.get("topologyManagerPolicy", "restricted"),
        "topologyManagerScope": phase4.get("topologyManagerScope", "pod"),
    }
    if reserved_system_cpus:
        cfg["reservedSystemCPUs"] = reserved_system_cpus
    return cfg


def render_generic_kubelet_configs(node_classes: Dict[str, Dict], phase4: Dict) -> Dict[str, str]:
    rendered = {}
    for node_name, entry in sorted(node_classes.items()):
        placement = entry.get("placement") or {}
        reserved = phase4_reserved_system_cpus(entry.get("class", ""), placement)
        group = {
            "cpuManagerPolicy": placement.get("cpuManagerPolicy", "static"),
            "cpuManagerPolicyOptions": placement.get("cpuManagerPolicyOptions", {}),
            "topologyManagerPolicy": placement.get("topologyManagerPolicy", "restricted"),
        }
        cfg = kubelet_config_from_group(group, phase4, reserved)
        cfg = {"apiVersion": "kubelet.config.k8s.io/v1beta1", "kind": "KubeletConfiguration", **cfg}
        rendered[node_name] = yaml.safe_dump(cfg, sort_keys=False)
    return rendered


def render_generic_apply_plan(node_classes: Dict[str, Dict], output_configmap: str) -> str:
    plan = {
        "warning": "Generic Kubernetes has no MachineConfigPool/MCO equivalent. This plan must be applied by kubeadm, Cluster API, external automation, or an explicitly enabled privileged node-agent.",
        "outputConfigMap": output_configmap,
        "safeNodeUpdateFlow": [
            "cordon/drain node",
            "stop kubelet",
            "backup kubelet config",
            "write updated kubelet config",
            "remove /var/lib/kubelet/cpu_manager_state",
            "start kubelet",
            "wait for Node Ready",
            "uncordon node",
            "validate CPU Manager static policy",
        ],
        "nodes": {},
    }
    for node_name, entry in sorted(node_classes.items()):
        plan["nodes"][node_name] = {
            "nodeClass": entry.get("class"),
            "topologyGroup": entry.get("topologyGroup"),
            "kubeletConfigKey": f"{node_name}.kubelet-config.yaml",
            "reservedSystemCPUs": phase4_reserved_system_cpus(entry.get("class", ""), entry.get("placement") or {}),
        }
    return yaml.safe_dump(plan, sort_keys=False)


def build_tuned_cr(spec: Dict, labels_spec: Dict) -> Optional[Dict[str, Any]]:
    openshift = spec.get("openshift") or {}
    if not bool(openshift.get("manageTuned", False)):
        return None

    profile_name = openshift.get("tunedProfile", "openshift-node-llm-compute")
    recommend_label = openshift.get("tunedMachineConfigLabel", "worker")
    kernel_args = openshift.get("kernelArgs", ["intel_pstate=active"])
    include_profile = openshift.get("includeProfile", "network-latency")

    bootline = " ".join(f"+{arg}" for arg in kernel_args)
    tuned_data = f"""[main]\nsummary=Custom OpenShift node profile for CPU inference workloads\ninclude={include_profile}\n\n[bootloader]\ncmdline_cpu_operator={bootline}\n"""
    return {
        "apiVersion": f"{TUNED_GROUP}/{TUNED_VERSION}",
        "kind": "Tuned",
        "metadata": {"name": profile_name, "namespace": TUNED_NAMESPACE},
        "spec": {
            "profile": [{"name": profile_name, "data": tuned_data}],
            "recommend": [{
                "machineConfigLabels": {"machineconfiguration.openshift.io/role": recommend_label},
                "priority": int(openshift.get("tunedPriority", 20)),
                "profile": profile_name,
            }],
        },
    }


def apply_tuned_cr(tuned_cr: Optional[Dict[str, Any]]):
    if not tuned_cr:
        return
    meta = tuned_cr.get("metadata", {})
    upsert_namespaced_custom_object(TUNED_GROUP, TUNED_VERSION, meta.get("namespace", TUNED_NAMESPACE), TUNED_PLURAL, meta["name"], tuned_cr)


def render_kubelet_config_by_group(groups: Dict[str, Dict], phase4: Dict) -> str:
    manifests = build_phase4_manifests(groups, phase4)
    return yaml.safe_dump({
        "note": (
            "Example only unless spec.phase4.apply=true. "
            "KubeletConfig applies to a MachineConfigPool and may trigger MCO rollout/reboot. "
            "distribute-cpus-across-numa is a CPU Manager policy option."
        ),
        "phase4": phase4,
        "manifests": manifests,
    }, sort_keys=False)


@kopf.on.startup()
def configure(settings: kopf.OperatorSettings, **_):
    config.load_incluster_config()


@kopf.on.create(GROUP, VERSION, "cpuplacementpolicies")
@kopf.on.update(GROUP, VERSION, "cpuplacementpolicies")
def reconcile_cpu_placement_policy(spec, name, namespace, logger, **_):
    target_selector = spec.get("targetNodeSelector") or spec.get("nodeSelector") or {"node-role.kubernetes.io/worker": ""}
    labels_spec = spec.get("nodeLabels", {}) or {}
    provider = normalize_provider(spec)
    phase4 = effective_phase4(spec, provider)
    phase4_enabled = provider.get("type", "").lower() == "openshift" and bool(phase4.get("enabled", False))
    phase4_apply = phase4_enabled and provider.get("applyMode") == "Managed"

    topologies = list_node_topologies(namespace)
    nodes = list_nodes()

    node_classes, placement_by_node, legacy_reserved, topology_groups, labels_by_node = {}, {}, {}, {}, {}
    merged_topology_by_node = {}

    for topo in topologies:
        topo_status = topo.get("status", {}) or {}
        node_name = topo_status.get("nodeName") or topo.get("spec", {}).get("nodeName")
        if not node_name:
            continue
        node = nodes.get(node_name)
        if not node:
            logger.warning("Skipping topology %s: node object not found", node_name)
            continue
        labels = get_nested(node, ["metadata", "labels"], {}) or {}
        topo_status = merge_topology_with_node_features(topo_status, node)
        merged_topology_by_node[node_name] = topo_status
        if not match_selector(labels, target_selector):
            logger.info("Skipping node %s: does not match targetNodeSelector", node_name)
            continue

        node_class, reason = classify_node(node, topo_status, spec)
        profile = profile_for_class(spec, node_class)
        gpu_count = get_gpu_count(node, topo_status)
        placement = compute_placement_for_node(topo_status, node_class, profile)
        sig = topology_signature(topo_status, node_class, profile)
        group_name = topology_group_name(node_class, sig)

        placement_by_node[node_name] = placement
        legacy_reserved[node_name] = legacy_reserved_cpuset_from_placement(node_class, placement)
        node_classes[node_name] = {
            "class": node_class,
            "reason": reason,
            "gpuCount": gpu_count,
            "amx": amx_detail(topo_status),
            "gpuLocalNumaNodes": topo_status.get("gpuLocalNumaNodes") or [],
            "profile": profile,
            "topologySignature": sig,
            "topologyGroup": group_name,
            "placement": placement,
        }

        topology_groups.setdefault(group_name, {
            "nodeClass": node_class,
            "topologySignature": sig,
            "cpuManagerPolicy": profile.get("cpuManagerPolicy", "static"),
            "cpuManagerPolicyOptions": profile.get("cpuManagerPolicyOptions", {}),
            "topologyManagerPolicy": profile.get("topologyManagerPolicy", "restricted"),
            "placementStrategy": placement.get("strategy"),
            "nodes": [],
            "placementByNode": {},
        })
        topology_groups[group_name]["nodes"].append(node_name)
        topology_groups[group_name]["placementByNode"][node_name] = placement

    phase4_manifests = build_phase4_manifests(topology_groups, phase4) if phase4_enabled else {"machineConfigPools": {}, "kubeletConfigs": {}}
    tuned_cr = build_tuned_cr(spec, labels_spec) if provider.get("type", "").lower() == "openshift" else None
    phase4_status = "disabled"
    phase4_error = ""
    provider_status = "recommendation-only"

    if phase4_enabled and phase4_apply:
        try:
            apply_phase4_manifests(phase4_manifests)
            apply_tuned_cr(tuned_cr)
            phase4_status = "applied"
            provider_status = "managed-applied"
        except Exception as exc:
            phase4_status = "apply-failed"
            provider_status = "apply-failed"
            phase4_error = str(exc)
            logger.exception("Failed to apply OpenShift provider manifests")
    elif phase4_enabled:
        phase4_status = "generated-only"
        provider_status = "openshift-generated-only"

    enable_labels = bool(labels_spec.get("enabled", spec.get("enableNodeLabels", True)))
    for node_name, entry in node_classes.items():
        generated_labels = build_node_labels(
            entry["class"],
            entry["gpuCount"],
            merged_topology_by_node.get(node_name, {}),
            entry["topologyGroup"],
            entry["placement"],
            labels_spec,
            phase4_status == "applied",
        )
        labels_by_node[node_name] = generated_labels
        if enable_labels:
            patch_node_labels(node_name, generated_labels)

    output_configmap = (spec.get("generic") or {}).get("outputConfigMap", f"{name}-generated-kubelet-config")
    generic_kubelet_configs = render_generic_kubelet_configs(node_classes, phase4)
    generic_apply_plan = render_generic_apply_plan(node_classes, output_configmap)

    data = {
        "policyName": name,
        "provider.yaml": yaml.safe_dump(provider, sort_keys=True),
        "providerStatus": provider_status,
        "phase4Status": phase4_status,
        "phase4Error": phase4_error,
        "targetNodeSelector.yaml": yaml.safe_dump(target_selector, sort_keys=True),
        "nodeClassification.yaml": yaml.safe_dump(node_classes, sort_keys=True),
        "topologyGroups.yaml": yaml.safe_dump(topology_groups, sort_keys=True),
        "cpuPlacementByNode.yaml": yaml.safe_dump(placement_by_node, sort_keys=True),
        "reservedSystemCPUsByNode.yaml": yaml.safe_dump(legacy_reserved, sort_keys=True),
        "generatedNodeLabels.yaml": yaml.safe_dump(labels_by_node, sort_keys=True),
        "genericKubeletConfigs.yaml": yaml.safe_dump(generic_kubelet_configs, sort_keys=True),
        "genericApplyPlan.yaml": generic_apply_plan,
        "openshiftTuned.yaml": yaml.safe_dump(tuned_cr or {}, sort_keys=True),
        "phase4MachineConfigPools.yaml": yaml.safe_dump(phase4_manifests.get("machineConfigPools", {}), sort_keys=True),
        "phase4KubeletConfigs.yaml": yaml.safe_dump(phase4_manifests.get("kubeletConfigs", {}), sort_keys=True),
        "kubeletConfigByTopologyClass.yaml": render_kubelet_config_by_group(topology_groups, phase4),
    }
    upsert_configmap(namespace, f"{name}-computed-cpu-policy", data)

    # Generic Kubernetes handoff ConfigMap: one kubelet config per node plus an apply plan.
    generic_cm_data = {f"{node}.kubelet-config.yaml": cfg for node, cfg in generic_kubelet_configs.items()}
    generic_cm_data["apply-plan.yaml"] = generic_apply_plan
    upsert_configmap(namespace, output_configmap, generic_cm_data)

    patch_cpu_placement_policy_status(namespace, name, {
        "provider": provider,
        "providerStatus": provider_status,
        "phase4Status": phase4_status,
        "phase4Error": phase4_error,
        "observedNodeCount": len(placement_by_node),
        "observedTopologyGroupCount": len(topology_groups),
        "computedConfigMap": f"{name}-computed-cpu-policy",
        "genericOutputConfigMap": output_configmap,
        "lastReconcileTime": int(time.time()),
    }, logger=logger)

    logger.info("Reconciled CPUPlacementPolicy %s; provider=%s/%s nodes=%d groups=%d phase4=%s", name, provider.get("type"), provider.get("applyMode"), len(placement_by_node), len(topology_groups), phase4_status)


@kopf.on.create(GROUP, VERSION, "nodecputopologies")
@kopf.on.update(GROUP, VERSION, "nodecputopologies")
def on_node_topology_change(namespace, name, logger, **_):
    policies = list_cpu_placement_policies(namespace)
    for policy in policies:
        policy_name = policy.get("metadata", {}).get("name")
        if not policy_name:
            continue
        try:
            trigger_policy_reconcile(namespace, policy_name, f"topology-{name}")
        except Exception:
            logger.exception("Failed to trigger reconcile for CPUPlacementPolicy/%s after NodeCPUTopology/%s changed", policy_name, name)
    logger.info("NodeCPUTopology/%s changed in namespace %s; triggered %d CPUPlacementPolicy reconcile(s).", name, namespace, len(policies))
