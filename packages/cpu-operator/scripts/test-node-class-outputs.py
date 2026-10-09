#!/usr/bin/env python3
"""Validate the default output contract for every CPU Operator node class.

Run from the repository root:

    python3 scripts/test-node-class-outputs.py

The test imports the real operator/operator.py implementation. Kubernetes and
kopf are stubbed because this test exercises pure classification/rendering
functions and does not contact a cluster.
"""

from __future__ import annotations

import importlib.util
import sys
import types
from pathlib import Path


def install_import_stubs() -> None:
    class On:
        @staticmethod
        def _decorator(*_args, **_kwargs):
            return lambda fn: fn

        startup = _decorator
        create = _decorator
        update = _decorator

    kopf = types.ModuleType("kopf")
    kopf.on = On()
    kopf.OperatorSettings = object

    kubernetes = types.ModuleType("kubernetes")
    client = types.ModuleType("kubernetes.client")
    config = types.ModuleType("kubernetes.config")
    rest = types.ModuleType("kubernetes.client.rest")

    class ApiException(Exception):
        pass

    rest.ApiException = ApiException
    kubernetes.client = client
    kubernetes.config = config

    sys.modules.setdefault("kopf", kopf)
    sys.modules.setdefault("kubernetes", kubernetes)
    sys.modules.setdefault("kubernetes.client", client)
    sys.modules.setdefault("kubernetes.config", config)
    sys.modules.setdefault("kubernetes.client.rest", rest)


def load_operator():
    repo_root = Path(__file__).resolve().parents[1]
    operator_path = repo_root / "operator" / "operator.py"
    if not operator_path.is_file():
        raise RuntimeError(f"operator implementation not found: {operator_path}")
    install_import_stubs()
    spec = importlib.util.spec_from_file_location("cpu_operator_impl", operator_path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


NUMA_NODES = [
    {"id": 0, "cpus": "0-15"},
    {"id": 1, "cpus": "16-31"},
    {"id": 2, "cpus": "32-47"},
    {"id": 3, "cpus": "48-63"},
]


def topology(*, amx: bool, gpu_count: int = 0) -> dict:
    return {
        "numaNodes": NUMA_NODES,
        "amx": {
            "amx_bf16": amx,
            "amx_int8": amx,
            "amx_tile": amx,
        },
        "gpuCountFromPCI": gpu_count,
        "gpus": [{"index": i, "numaNode": i % 2} for i in range(gpu_count)],
        "gpuLocalNumaNodes": [0, 1] if gpu_count else [],
    }


def node(*, gpu_count: int = 0) -> dict:
    allocatable = {"cpu": "64"}
    if gpu_count:
        allocatable["nvidia.com/gpu"] = str(gpu_count)
    return {
        "metadata": {"labels": {"node-role.kubernetes.io/worker": ""}},
        "status": {"allocatable": allocatable},
    }


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def cpus(operator, value: str) -> set[int]:
    return set(operator.expand_cpuset(value))


def validate_common(operator, case: dict, actual_class: str, placement: dict) -> None:
    expected_class = case["class"]
    expect(actual_class == expected_class, f"class={actual_class}, expected {expected_class}")
    expect(placement["strategy"] == case["strategy"], "unexpected placement strategy")
    expect(placement["cpuManagerPolicy"] == "static", "CPU Manager must be static")
    expect(
        placement["topologyManagerPolicy"] == case["topology_policy"],
        "unexpected Topology Manager policy",
    )

    labels = operator.build_node_labels(
        actual_class,
        case["gpu_count"],
        case["topology"],
        f"{actual_class}-test",
        placement,
        {"prefix": "cpu.example.com"},
        False,
    )
    expect(labels["cpu.example.com/node-class"] == actual_class, "wrong node-class label")
    expect(labels["cpu.example.com/placement-strategy"] == case["strategy"], "wrong strategy label")
    expect(labels["cpu.example.com/placement-ready"] == "true", "placement-ready must be true")
    expect(labels["cpu.example.com/phase4-applied"] == "false", "phase4-applied must be false")
    expect(labels["cpu.example.com/gpu-count"] == str(case["gpu_count"]), "wrong GPU count label")
    expect(
        labels["cpu.example.com/amx-supported"] == str(case["amx"]).lower(),
        "wrong AMX label",
    )


def validate_mixed(operator, placement: dict) -> None:
    all_cpus = set(range(64))
    gpu_cpus = cpus(operator, placement["gpuPodCPUSet"])
    cpu_cpus = cpus(operator, placement["cpuPodCPUSet"])
    expect(len(gpu_cpus) == 12, "mixed class must reserve 12 GPU-pod CPUs")
    expect(gpu_cpus.isdisjoint(cpu_cpus), "GPU and CPU pod sets must not overlap")
    expect(gpu_cpus | cpu_cpus == all_cpus, "GPU and CPU pod sets must cover all CPUs")
    expect(placement["systemReservedCPUSet"] == "", "mixed class must not reserve system CPUs")
    expect(operator.phase4_reserved_system_cpus("mixed-cpu-amx-gpu", placement) == "", "Phase 4 must not reserve GPU-pod CPUs")
    for numa in NUMA_NODES:
        expect(len(gpu_cpus & cpus(operator, numa["cpus"])) == 3, "GPU CPUs must be NUMA-balanced")


def validate_cpu_amx(operator, placement: dict) -> None:
    all_cpus = set(range(64))
    reserved = cpus(operator, placement["otherPodsReservedCPUSet"])
    cpu_cpus = cpus(operator, placement["cpuPodCPUSet"])
    expect(len(reserved) == 8, "cpu-amx must reserve 2 CPUs on each of 4 NUMA nodes")
    expect(reserved.isdisjoint(cpu_cpus), "reserved and CPU-pod sets must not overlap")
    expect(reserved | cpu_cpus == all_cpus, "reserved and CPU-pod sets must cover all CPUs")
    expect(placement["systemReservedCPUSet"] == placement["otherPodsReservedCPUSet"], "system reservation mismatch")
    expect(operator.phase4_reserved_system_cpus("cpu-amx", placement) == placement["otherPodsReservedCPUSet"], "Phase 4 reservation mismatch")
    for numa in NUMA_NODES:
        expect(len(reserved & cpus(operator, numa["cpus"])) == 2, "reservation must be NUMA-balanced")


def validate_local(operator, node_class: str, placement: dict) -> None:
    pools = placement["numaLocalCPUSetByNuma"]
    expect(placement["preferredNumaNode"] == "0", "first populated NUMA node must be preferred")
    expect(set(pools) == {"0", "1", "2", "3"}, "all NUMA pools must be present")
    combined: set[int] = set()
    for value in pools.values():
        pool = cpus(operator, value)
        expect(combined.isdisjoint(pool), "NUMA pools must not overlap")
        combined |= pool
    expect(combined == set(range(64)), "NUMA pools must cover all CPUs")
    expect(operator.phase4_reserved_system_cpus(node_class, placement) == "", "local class must not reserve system CPUs")


def main() -> int:
    try:
        operator = load_operator()
    except Exception as exc:
        print(f"[FAIL] setup: {exc}")
        return 1

    cases = [
        {
            "class": "mixed-cpu-amx-gpu",
            "amx": True,
            "gpu_count": 2,
            "topology": topology(amx=True, gpu_count=2),
            "strategy": "balanced-shared-cpu-and-gpu",
            "topology_policy": "restricted",
            "validate": validate_mixed,
        },
        {
            "class": "cpu-amx",
            "amx": True,
            "gpu_count": 0,
            "topology": topology(amx=True),
            "strategy": "balanced-reserved-other-pods",
            "topology_policy": "restricted",
            "validate": validate_cpu_amx,
        },
        {
            "class": "gpu-only",
            "amx": False,
            "gpu_count": 2,
            "topology": topology(amx=False, gpu_count=2),
            "strategy": "same-numa-node-first",
            "topology_policy": "single-numa-node",
            "validate": lambda op, p: validate_local(op, "gpu-only", p),
        },
        {
            "class": "cpu-only",
            "amx": False,
            "gpu_count": 0,
            "topology": topology(amx=False),
            "strategy": "same-numa-node-first",
            "topology_policy": "single-numa-node",
            "validate": lambda op, p: validate_local(op, "cpu-only", p),
        },
    ]

    failures = 0
    policy_spec = {"classification": {"cpuAmxMinLogicalCPUs": 64}}
    for case in cases:
        try:
            actual_class, _reason = operator.classify_node(
                node(gpu_count=case["gpu_count"]), case["topology"], policy_spec
            )
            profile = operator.profile_for_class(policy_spec, actual_class)
            placement = operator.compute_placement_for_node(case["topology"], actual_class, profile)
            validate_common(operator, case, actual_class, placement)
            case["validate"](operator, placement)
            print(f"[PASS] {case['class']}")
        except Exception as exc:
            failures += 1
            print(f"[FAIL] {case['class']}: {exc}")

    if failures:
        print(f"[FAIL] summary: {failures}/{len(cases)} node classes failed")
        return 1
    print(f"[PASS] summary: {len(cases)}/{len(cases)} node classes passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
