#!/usr/bin/env python3

import glob
import hashlib
import json
import os
import re
import time
from typing import Dict, List, Optional

from kubernetes import client, config
from kubernetes.client.rest import ApiException

GROUP = "cpu.example.com"
VERSION = "v1alpha1"
PLURAL = "nodecputopologies"
HOST_SYS = os.environ.get("HOST_SYS", "/host-sys")
HOST_PROC = os.environ.get("HOST_PROC", "/host-proc")
DEFAULT_GPU_VENDOR_ALLOWLIST = "0x10de"  # NVIDIA by default; avoids counting BMC VGA devices as AI GPUs.


def normalized_gpu_vendor_allowlist() -> List[str]:
    raw = os.environ.get("GPU_VENDOR_ALLOWLIST", DEFAULT_GPU_VENDOR_ALLOWLIST)
    vendors = []
    for item in raw.split(","):
        vendor = item.strip().lower()
        if vendor:
            vendors.append(vendor)
    return vendors or [DEFAULT_GPU_VENDOR_ALLOWLIST]


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()


def read_text_optional(path: str) -> Optional[str]:
    try:
        return read_text(path)
    except (FileNotFoundError, PermissionError):
        return None


def parse_meminfo(path: str) -> int:
    text = read_text_optional(path)
    if not text:
        return 0
    match = re.search(r"MemTotal:\s+(\d+)\s+kB", text)
    return int(match.group(1)) // 1024 if match else 0


def read_numa_nodes() -> List[Dict]:
    out = []
    for node_path in sorted(glob.glob(f"{HOST_SYS}/devices/system/node/node[0-9]*")):
        node_id = int(os.path.basename(node_path).replace("node", ""))
        cpulist = read_text_optional(os.path.join(node_path, "cpulist"))
        if cpulist:
            out.append({
                "id": node_id,
                "cpus": cpulist,
                "memoryMiB": parse_meminfo(os.path.join(node_path, "meminfo")),
            })
    return out


def read_thread_siblings() -> Dict[str, str]:
    siblings = {}
    for topo_path in glob.glob(f"{HOST_SYS}/devices/system/cpu/cpu[0-9]*/topology/thread_siblings_list"):
        cpu_id = topo_path.split("/")[-3].replace("cpu", "")
        value = read_text_optional(topo_path)
        if value:
            siblings[cpu_id] = value
    return siblings


def read_cpu_online() -> str:
    return read_text_optional(f"{HOST_SYS}/devices/system/cpu/online") or ""


def read_cpu_flags() -> List[str]:
    cpuinfo = read_text_optional(f"{HOST_PROC}/cpuinfo") or ""
    for line in cpuinfo.splitlines():
        if line.lower().startswith("flags"):
            return sorted(set(line.split(":", 1)[1].strip().split()))
    return []


def read_amx_capabilities() -> Dict:
    flags = read_cpu_flags()
    fs = set(flags)
    return {
        "source": "/proc/cpuinfo flags",
        "flags": sorted([f for f in flags if f.startswith("amx")]),
        "amx_bf16": "amx_bf16" in fs,
        "amx_int8": "amx_int8" in fs,
        "amx_tile": "amx_tile" in fs,
        "amx_fp16": "amx_fp16" in fs,
        "amx_supported": ("amx_bf16" in fs and "amx_int8" in fs),
        "requiredForAI": ["amx_bf16", "amx_int8"],
    }


def read_pci_gpus() -> List[Dict]:
    """Return PCI devices that should be treated as AI accelerator GPUs.

    PCI class 0x0300/0x0302 means VGA/3D controller, but many servers also have
    an onboard BMC VGA controller such as ASPEED 0x1a03:0x2000. That device is
    useful for console display, but it is not a GPU for LLM inference placement.

    Therefore the default detection requires both:
      * GPU/display PCI class, and
      * an allowed accelerator vendor, default NVIDIA 0x10de.

    Additional vendors can be enabled with GPU_VENDOR_ALLOWLIST, for example:
      GPU_VENDOR_ALLOWLIST=0x10de,0x1002,0x8086
    """
    out = []
    allowed_vendors = normalized_gpu_vendor_allowlist()
    for dev_path in sorted(glob.glob(f"{HOST_SYS}/bus/pci/devices/*")):
        address = os.path.basename(dev_path)
        vendor = read_text_optional(os.path.join(dev_path, "vendor"))
        device = read_text_optional(os.path.join(dev_path, "device")) or ""
        pci_class = read_text_optional(os.path.join(dev_path, "class"))
        numa_raw = read_text_optional(os.path.join(dev_path, "numa_node"))
        if not vendor or not pci_class:
            continue
        vendor_l = vendor.lower()
        class_l = pci_class.lower()
        is_gpu_class = class_l.startswith("0x0300") or class_l.startswith("0x0302")
        is_allowed_vendor = vendor_l in allowed_vendors
        is_nvidia = vendor_l == "0x10de"
        if not (is_gpu_class and is_allowed_vendor):
            continue
        try:
            numa = int(numa_raw) if numa_raw is not None else -1
        except ValueError:
            numa = -1
        out.append({
            "pciAddress": address,
            "vendor": vendor,
            "device": device,
            "class": pci_class,
            "numaNode": numa,
            "isNvidia": is_nvidia,
            "detection": "pci-class-and-allowed-vendor",
        })
    return out


def topology_hash(payload: Dict) -> str:
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode("utf-8")).hexdigest()


def ensure_object(api: client.CustomObjectsApi, namespace: str, name: str, node_name: str):
    body = {
        "apiVersion": f"{GROUP}/{VERSION}",
        "kind": "NodeCPUTopology",
        "metadata": {"name": name, "namespace": namespace},
        "spec": {"nodeName": node_name},
    }
    try:
        api.get_namespaced_custom_object(GROUP, VERSION, namespace, PLURAL, name)
    except ApiException as e:
        if e.status == 404:
            api.create_namespaced_custom_object(GROUP, VERSION, namespace, PLURAL, body)
        else:
            raise


def patch_status(api: client.CustomObjectsApi, namespace: str, name: str, status: Dict):
    api.patch_namespaced_custom_object_status(GROUP, VERSION, namespace, PLURAL, name, {"status": status})


def main():
    namespace = os.environ.get("NAMESPACE", "cpu-operator-system")
    node_name = os.environ["NODE_NAME"]
    object_name = node_name.lower().replace("_", "-")
    interval_seconds = int(os.environ.get("INTERVAL_SECONDS", "60"))

    config.load_incluster_config()
    api = client.CustomObjectsApi()
    last_hash = None

    while True:
        numa_nodes = read_numa_nodes()
        gpus = read_pci_gpus()
        amx = read_amx_capabilities()
        status = {
            "nodeName": node_name,
            "topologyReady": bool(numa_nodes),
            "onlineCPUs": read_cpu_online(),
            "numaNodes": numa_nodes,
            "threadSiblings": read_thread_siblings(),
            "gpus": gpus,
            "gpuCountFromPCI": len(gpus),
            "gpuLocalNumaNodes": sorted({
                g["numaNode"] for g in gpus
                if isinstance(g.get("numaNode"), int) and g["numaNode"] >= 0
            }),
            "gpuVendorAllowlist": normalized_gpu_vendor_allowlist(),
            "amx": amx,
            "conditions": [
                {"type": "TopologyReady", "status": "True" if numa_nodes else "False"},
                {"type": "GPUDiscoveryReady", "status": "True"},
                {"type": "AMXReady", "status": "True" if amx.get("amx_supported") else "False"},
            ],
        }
        status["topologyHash"] = topology_hash(status)
        try:
            ensure_object(api, namespace, object_name, node_name)
            if status["topologyHash"] != last_hash:
                patch_status(api, namespace, object_name, status)
                print(
                    f"Updated NodeCPUTopology/{object_name}: numa={len(numa_nodes)} "
                    f"pci_gpus={len(gpus)} amx_supported={amx.get('amx_supported')} "
                    f"hash={status['topologyHash']}",
                    flush=True,
                )
                last_hash = status["topologyHash"]
            else:
                print(f"No topology change for {node_name}", flush=True)
        except Exception as exc:
            print(f"ERROR: failed to publish topology for {node_name}: {exc}", flush=True)
        time.sleep(interval_seconds)


if __name__ == "__main__":
    main()
