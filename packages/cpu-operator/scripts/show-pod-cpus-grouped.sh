#!/usr/bin/env bash
set -euo pipefail

# Show how running containers on one worker node map to logical CPU IDs.
# Progress and diagnostic messages are printed to stderr.
#
# Usage:
#   ./show-pod-cpus-grouped.sh <worker-node> [pod/container-regex]
#
# Examples:
#   ./show-pod-cpus-grouped.sh pegasus
#   ./show-pod-cpus-grouped.sh pegasus vllm-cpu
#   LIVE=1 ./show-pod-cpus-grouped.sh pegasus vllm-cpu
#   DEBUG=1 LIVE=1 ./show-pod-cpus-grouped.sh pegasus vllm-cpu
#   SKIP_CHECKPOINT=1 LIVE=1 ./show-pod-cpus-grouped.sh pegasus vllm-cpu
#
# Environment:
#   CLI=oc                    Kubernetes CLI. Defaults to oc.
#   LIVE=1                    Read each process CPU affinity and compare it with CPU Manager.
#   EXPAND=1                  Print 0,1,2,3 instead of compact 0-3 notation.
#   DEBUG=1                   Print every external command and full error details.
#   NO_PROGRESS=1             Suppress progress messages.
#   SKIP_CHECKPOINT=1         Skip oc debug and use live container cpusets only.
#   LIST_TIMEOUT=30           Timeout for listing pods, in seconds.
#   DEBUG_TIMEOUT=60          Timeout for oc debug checkpoint read, in seconds.
#   EXEC_TIMEOUT=20           Timeout for each oc exec, in seconds.
#   HEARTBEAT_SECONDS=5        Progress heartbeat interval for long commands.
#   VIEW=grouped               Output view: grouped, detail, or both. Default: grouped.
#   SHOW_MEMBERS=1             List pods/containers inside each CPU-set group.
#   MAX_MEMBERS=0              Limit members per group; 0 means unlimited.

CLI="${CLI:-oc}"
NODE="${1:-}"
FILTER="${2:-.*}"

if [[ -z "$NODE" ]]; then
  echo "Usage: $0 <worker-node> [pod/container-regex]" >&2
  exit 2
fi

command -v "$CLI" >/dev/null 2>&1 || {
  echo "ERROR: CLI command '$CLI' was not found" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 was not found" >&2
  exit 1
}

exec python3 - "$CLI" "$NODE" "$FILTER" <<'PY'
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
import time
from typing import Any, Dict, Optional, Sequence

cli, node, filter_text = sys.argv[1:4]
try:
    pod_filter = re.compile(filter_text)
except re.error as exc:
    raise SystemExit(f"ERROR: invalid regex {filter_text!r}: {exc}")

want_live = os.environ.get("LIVE", "0") == "1"
want_expand = os.environ.get("EXPAND", "0") == "1"
debug_enabled = os.environ.get("DEBUG", "0") == "1"
progress_enabled = os.environ.get("NO_PROGRESS", "0") != "1"
skip_checkpoint = os.environ.get("SKIP_CHECKPOINT", "0") == "1"
list_timeout = int(os.environ.get("LIST_TIMEOUT", "30"))
debug_timeout = int(os.environ.get("DEBUG_TIMEOUT", "60"))
exec_timeout = int(os.environ.get("EXEC_TIMEOUT", "20"))
heartbeat_seconds = max(1, int(os.environ.get("HEARTBEAT_SECONDS", "5")))
view = os.environ.get("VIEW", "grouped").strip().lower()
if view not in {"grouped", "detail", "both"}:
    raise SystemExit("ERROR: VIEW must be grouped, detail, or both")
show_members = os.environ.get("SHOW_MEMBERS", "1") == "1"
max_members = max(0, int(os.environ.get("MAX_MEMBERS", "0")))


def timestamp() -> str:
    return datetime.datetime.now().strftime("%H:%M:%S")


def status(message: str) -> None:
    if progress_enabled:
        print(f"[{timestamp()}] {message}", file=sys.stderr, flush=True)


def debug(message: str) -> None:
    if debug_enabled:
        print(f"[{timestamp()}] DEBUG: {message}", file=sys.stderr, flush=True)


def format_command(args: Sequence[str]) -> str:
    return " ".join(shlex.quote(str(arg)) for arg in args)


def run(args, *, label: str, timeout: int, check: bool = True):
    debug(f"command: {format_command(args)}")
    started = time.monotonic()
    process = subprocess.Popen(
        args,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    stdout = ""
    stderr = ""
    while True:
        elapsed = time.monotonic() - started
        remaining = timeout - elapsed
        if remaining <= 0:
            process.kill()
            tail_out, tail_err = process.communicate()
            stdout += tail_out or ""
            stderr += tail_err or ""
            debug(f"partial stdout from timed-out {label}:\n{stdout.rstrip()}")
            debug(f"partial stderr from timed-out {label}:\n{stderr.rstrip()}")
            raise RuntimeError(
                f"{label} timed out after {elapsed:.1f}s. "
                f"Set a larger timeout or use SKIP_CHECKPOINT=1 LIVE=1."
            )

        try:
            out, err = process.communicate(timeout=min(heartbeat_seconds, remaining))
            stdout += out or ""
            stderr += err or ""
            break
        except subprocess.TimeoutExpired:
            elapsed = time.monotonic() - started
            status(f"{label} is still running ({elapsed:.0f}s elapsed)")

    elapsed = time.monotonic() - started
    proc = subprocess.CompletedProcess(
        args=args,
        returncode=process.returncode,
        stdout=stdout,
        stderr=stderr,
    )
    debug(f"{label}: rc={proc.returncode}, elapsed={elapsed:.2f}s")
    if debug_enabled and proc.stderr.strip():
        debug(f"{label} stderr:\n{proc.stderr.rstrip()}")
    if check and proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or "no diagnostic output"
        raise RuntimeError(f"{label} failed with rc={proc.returncode}: {detail}")
    return proc


def extract_json(text: str) -> Optional[Dict[str, Any]]:
    """Extract the first JSON object even if oc adds status text."""
    start = text.find("{")
    if start < 0:
        return None
    try:
        obj, _ = json.JSONDecoder().raw_decode(text[start:])
        return obj
    except json.JSONDecodeError:
        return None


def expand_cpuset(value: str) -> str:
    if not want_expand or not value or value.startswith("<"):
        return value
    cpus = []
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            first, last = part.split("-", 1)
            cpus.extend(range(int(first), int(last) + 1))
        else:
            cpus.append(int(part))
    return ",".join(str(cpu) for cpu in sorted(set(cpus)))


def parse_cpuset(value: str):
    """Return a sorted set of logical CPU IDs from Linux cpuset syntax."""
    if not value or value.startswith("<"):
        return set()
    cpus = set()
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            first, last = part.split("-", 1)
            try:
                start = int(first)
                end = int(last)
            except ValueError:
                return set()
            cpus.update(range(start, end + 1))
        else:
            try:
                cpus.add(int(part))
            except ValueError:
                return set()
    return cpus


def compact_cpus(cpus) -> str:
    values = sorted(set(cpus))
    if not values:
        return "<none>"
    ranges = []
    start = previous = values[0]
    for cpu in values[1:]:
        if cpu == previous + 1:
            previous = cpu
            continue
        ranges.append(str(start) if start == previous else f"{start}-{previous}")
        start = previous = cpu
    ranges.append(str(start) if start == previous else f"{start}-{previous}")
    return ",".join(ranges)


def normalize_cpuset(value: str) -> str:
    cpus = parse_cpuset(value)
    return compact_cpus(cpus) if cpus else value


def cpu_quantity(value: str) -> str:
    """Normalize a Kubernetes CPU quantity for display without implying usage."""
    value = str(value or "").strip()
    return value if value else "-"


def allocation_meaning(allocation: str) -> str:
    if allocation == "shared":
        return (
            "All members may run on any CPU in this shared pool. "
            "The cpuset is an allowed-CPU boundary, not CPU consumption; "
            "the Linux scheduler chooses where each thread runs and members may contend."
        )
    if allocation == "exclusive":
        return (
            "CPU Manager assigned this CPU set exclusively to the listed container(s). "
            "Other CPU Manager exclusive workloads should not use these CPUs."
        )
    if allocation == "unpinned":
        return (
            "CPU Manager did not pin these containers. The operating system scheduler "
            "may place their threads across the shown CPUs."
        )
    return (
        "The script could not determine a reliable CPU Manager allocation type. "
        "Use LIVE=1 and inspect the checkpoint diagnostics."
    )


status(f"Checking access to node {node!r}")
try:
    node_proc = run(
        [cli, "get", "node", node, "-o", "name"],
        label="node lookup",
        timeout=list_timeout,
    )
except RuntimeError as exc:
    raise SystemExit(f"ERROR: {exc}")
status(f"Node found: {node_proc.stdout.strip()}")

status("Listing running pods assigned to the node")
try:
    pods_proc = run(
        [
            cli,
            "get",
            "pods",
            "-A",
            "--field-selector",
            f"spec.nodeName={node},status.phase=Running",
            "-o",
            "json",
        ],
        label="pod listing",
        timeout=list_timeout,
    )
except RuntimeError as exc:
    raise SystemExit(f"ERROR: {exc}")

try:
    pods = json.loads(pods_proc.stdout)
except json.JSONDecodeError as exc:
    raise SystemExit(f"ERROR: could not parse pod list: {exc}")

all_pods = pods.get("items", [])
status(f"Found {len(all_pods)} running pod(s) on {node}")

state_proc = None
state = None
if skip_checkpoint:
    status("Skipping kubelet CPU Manager checkpoint because SKIP_CHECKPOINT=1")
    want_live = True
else:
    status(
        "Reading /var/lib/kubelet/cpu_manager_state via an OpenShift node debug pod; "
        "this is commonly the slowest step"
    )
    try:
        state_proc = run(
            [
                cli,
                "debug",
                f"node/{node}",
                "--quiet",
                "--",
                "chroot",
                "/host",
                "cat",
                "/var/lib/kubelet/cpu_manager_state",
            ],
            label="CPU Manager checkpoint read",
            timeout=debug_timeout,
            check=False,
        )
        state = extract_json(state_proc.stdout)
    except RuntimeError as exc:
        status(f"Checkpoint read did not complete: {exc}")
        status("Falling back to live container cpusets")
        want_live = True

if state is None:
    want_live = True
    policy = "unknown"
    default_cpuset = ""
    entries: Dict[str, Dict[str, str]] = {}
else:
    policy = str(state.get("policyName") or "unknown")
    default_cpuset = str(state.get("defaultCpuSet") or "")
    entries = state.get("entries") or {}
    status(
        f"Checkpoint parsed: policy={policy}, exclusive pod entries={len(entries)}, "
        f"default cpuset={default_cpuset or '<empty>'}"
    )

print(f"Node: {node}")
print(f"CPU Manager policy: {policy}")
if default_cpuset:
    print(f"Shared/default CPU set: {expand_cpuset(default_cpuset)}")
if state is None:
    reason = "checkpoint skipped" if skip_checkpoint else "checkpoint unavailable"
    if state_proc is not None:
        details = [line.strip() for line in state_proc.stderr.splitlines() if line.strip()]
        if details:
            reason = details[-1]
    print(f"Checkpoint: unavailable ({reason})")
print()

matched_containers = []
for pod in all_pods:
    meta = pod.get("metadata") or {}
    spec = pod.get("spec") or {}
    pod_status = pod.get("status") or {}
    namespace = meta.get("namespace", "default")
    pod_name = meta.get("name", "")
    pod_uid = meta.get("uid", "")

    status_by_container = {
        item.get("name"): item
        for item in (pod_status.get("containerStatuses") or [])
        if item.get("name")
    }

    for container in spec.get("containers") or []:
        container_name = container.get("name", "")
        container_status = status_by_container.get(container_name) or {}
        if not (container_status.get("state") or {}).get("running"):
            continue
        identity = f"{namespace}/{pod_name}/{container_name}"
        if pod_filter.search(identity):
            resources = container.get("resources") or {}
            requests = resources.get("requests") or {}
            limits = resources.get("limits") or {}
            matched_containers.append(
                (
                    namespace,
                    pod_name,
                    pod_uid,
                    container_name,
                    identity,
                    str(pod_status.get("qosClass") or "Unknown"),
                    cpu_quantity(requests.get("cpu")),
                    cpu_quantity(limits.get("cpu")),
                )
            )

status(
    f"Matched {len(matched_containers)} running container(s) using regex {filter_text!r}"
)
if not matched_containers:
    raise SystemExit(
        f"No running containers matched {filter_text!r} on node {node!r}"
    )

rows = []
for index, (
    namespace,
    pod_name,
    pod_uid,
    container_name,
    identity,
    qos_class,
    cpu_request,
    cpu_limit,
) in enumerate(matched_containers, start=1):
    assigned = (entries.get(pod_uid) or {}).get(container_name)
    if assigned:
        allocation = "exclusive"
        manager_cpuset = str(assigned)
    elif policy == "static" and default_cpuset:
        allocation = "shared"
        manager_cpuset = default_cpuset
    elif policy == "none":
        allocation = "unpinned"
        manager_cpuset = "<not assigned by CPU Manager>"
    else:
        allocation = "unknown"
        manager_cpuset = "<not recorded>"

    live_cpuset = ""
    live_error = ""
    if want_live:
        status(
            f"[{index}/{len(matched_containers)}] Reading live cpuset: {identity}"
        )
        # Use process affinity first. Privileged and host-integrated containers may
        # expose the host cgroup root at /sys/fs/cgroup. In those containers,
        # root cpuset.cpus.effective can be broader than the process affinity and
        # would create a false CPU Manager/live mismatch.
        live_cmd = r'''
if [ -r /proc/self/status ]; then
    awk '/^Cpus_allowed_list:/ {print $2; exit}' /proc/self/status
elif [ -r /sys/fs/cgroup/cpuset.cpus.effective ]; then
    cat /sys/fs/cgroup/cpuset.cpus.effective
elif [ -r /sys/fs/cgroup/cpuset.cpus ]; then
    cat /sys/fs/cgroup/cpuset.cpus
elif [ -r /sys/fs/cgroup/cpuset/cpuset.cpus ]; then
    cat /sys/fs/cgroup/cpuset/cpuset.cpus
else
    exit 1
fi
'''.strip()
        try:
            proc = run(
                [
                    cli,
                    "exec",
                    "-n",
                    namespace,
                    pod_name,
                    "-c",
                    container_name,
                    "--",
                    "sh",
                    "-c",
                    live_cmd,
                ],
                label=f"live cpuset read for {identity}",
                timeout=exec_timeout,
                check=False,
            )
            if proc.returncode == 0:
                values = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
                live_cpuset = values[-1] if values else ""
            if not live_cpuset:
                live_cpuset = "<unavailable>"
                errors = [line.strip() for line in proc.stderr.splitlines() if line.strip()]
                live_error = (
                    errors[-1]
                    if errors
                    else "container lacks sh/cat/awk or exec permission"
                )
        except RuntimeError as exc:
            live_cpuset = "<timeout>"
            live_error = str(exc)

    manager_compact = normalize_cpuset(manager_cpuset)
    live_compact = normalize_cpuset(live_cpuset)
    effective_compact = (
        live_compact
        if live_compact and not live_compact.startswith("<")
        else manager_compact
    )
    rows.append(
        {
            "identity": identity,
            "namespace": namespace,
            "pod": pod_name,
            "container": container_name,
            "qos": qos_class,
            "cpu_request": cpu_request,
            "cpu_limit": cpu_limit,
            "allocation": allocation,
            "manager_compact": manager_compact,
            "live_compact": live_compact,
            "effective_compact": effective_compact,
            "manager": expand_cpuset(manager_cpuset),
            "live": expand_cpuset(live_cpuset),
            "live_error": live_error,
        }
    )

status("Rendering CPU allocation report")


def render_grouped_report():
    groups = {}
    for row in rows:
        key = (row["allocation"], row["effective_compact"])
        groups.setdefault(key, []).append(row)

    ordered = sorted(
        groups.items(),
        key=lambda item: (
            0 if item[0][0] == "exclusive" else 1 if item[0][0] == "shared" else 2,
            min(parse_cpuset(item[0][1]) or {10**9}),
            item[0][1],
        ),
    )

    print("CPU-CENTRIC GROUPED VIEW")
    print("========================")
    print(
        "A CPU set shows where a container is allowed to run. It does not mean the "
        "container is actively using every CPU in the set."
    )
    print()

    group_records = []
    for group_index, ((allocation, cpuset), members) in enumerate(ordered, start=1):
        cpus = parse_cpuset(cpuset)
        pod_keys = {(row["namespace"], row["pod"]) for row in members}
        manager_live_matches = sum(
            1
            for row in members
            if row["live_compact"]
            and not row["live_compact"].startswith("<")
            and row["manager_compact"] == row["live_compact"]
        )
        manager_live_mismatches = sum(
            1
            for row in members
            if row["live_compact"]
            and not row["live_compact"].startswith("<")
            and not row["manager_compact"].startswith("<")
            and row["manager_compact"] != row["live_compact"]
        )
        group_records.append(
            {
                "id": f"G{group_index}",
                "allocation": allocation,
                "cpuset": cpuset,
                "cpus": cpus,
                "members": members,
                "pod_count": len(pod_keys),
                "container_count": len(members),
            }
        )

        title = {
            "shared": "SHARED CPU POOL",
            "exclusive": "EXCLUSIVE CPU ASSIGNMENT",
            "unpinned": "UNPINNED CPU SET",
            "unknown": "UNKNOWN CPU ASSIGNMENT",
        }.get(allocation, allocation.upper())
        print(f"[{group_records[-1]['id']}] {title}")
        print(f"  CPU IDs:       {cpuset}")
        print(f"  Logical CPUs:  {len(cpus) if cpus else 'unknown'}")
        print(f"  Pods:          {len(pod_keys)}")
        print(f"  Containers:    {len(members)}")
        if want_live:
            print(
                f"  Manager/live:  {manager_live_matches} match, "
                f"{manager_live_mismatches} mismatch, "
                f"{len(members) - manager_live_matches - manager_live_mismatches} unavailable"
            )
        print(f"  Meaning:       {allocation_meaning(allocation)}")

        if show_members:
            print("  Members:")
            pods_by_name = {}
            for row in sorted(members, key=lambda item: item["identity"]):
                key = (row["namespace"], row["pod"], row["qos"])
                pods_by_name.setdefault(key, []).append(row)

            pod_items = list(pods_by_name.items())
            display_items = pod_items
            if max_members and len(pod_items) > max_members:
                display_items = pod_items[:max_members]

            for (namespace, pod_name, qos), pod_rows in display_items:
                print(f"    - {namespace}/{pod_name}  [QoS={qos}]")
                container_parts = []
                for row in pod_rows:
                    container_parts.append(
                        f"{row['container']} (request={row['cpu_request']}, "
                        f"limit={row['cpu_limit']})"
                    )
                print(f"        containers: {', '.join(container_parts)}")

            if max_members and len(pod_items) > max_members:
                print(f"    ... {len(pod_items) - max_members} additional pod(s) hidden")
        print()

    # Collapse contiguous logical CPUs that have the same group membership.
    cpu_to_groups = {}
    for group in group_records:
        for cpu in group["cpus"]:
            cpu_to_groups.setdefault(cpu, []).append(group["id"])

    if cpu_to_groups:
        signatures = []
        for cpu in sorted(cpu_to_groups):
            signature = tuple(sorted(cpu_to_groups[cpu]))
            if signatures and cpu == signatures[-1][1] + 1 and signature == signatures[-1][2]:
                signatures[-1] = (signatures[-1][0], cpu, signature)
            else:
                signatures.append((cpu, cpu, signature))

        group_by_id = {group["id"]: group for group in group_records}
        print("CPU RANGE TO POD-GROUP MAP")
        print("==========================")
        print(
            f"{'CPU RANGE':<16} {'GROUPS':<14} {'TYPE':<12} "
            f"{'PODS':>6} {'CONTAINERS':>11}  INTERPRETATION"
        )
        print(
            f"{'-' * 16} {'-' * 14} {'-' * 12} "
            f"{'-' * 6} {'-' * 11}  {'-' * 34}"
        )
        for first, last, signature in signatures:
            cpu_range = str(first) if first == last else f"{first}-{last}"
            involved = [group_by_id[group_id] for group_id in signature]
            allocation_types = sorted({group["allocation"] for group in involved})
            pod_keys = {
                (row["namespace"], row["pod"])
                for group in involved
                for row in group["members"]
            }
            container_keys = {
                row["identity"] for group in involved for row in group["members"]
            }
            if len(signature) == 1 and involved[0]["allocation"] == "shared":
                interpretation = "shared scheduler pool; contention is possible"
            elif len(signature) == 1 and involved[0]["allocation"] == "exclusive":
                interpretation = "exclusive CPU Manager assignment"
            elif len(signature) > 1:
                interpretation = "overlapping CPU sets; inspect groups"
            else:
                interpretation = "scheduler-eligible CPUs"
            print(
                f"{cpu_range:<16} {','.join(signature):<14} "
                f"{','.join(allocation_types):<12} {len(pod_keys):>6} "
                f"{len(container_keys):>11}  {interpretation}"
            )
        print()

    exclusive_groups = [g for g in group_records if g["allocation"] == "exclusive"]
    shared_groups = [g for g in group_records if g["allocation"] == "shared"]
    print("HOW TO READ THIS REPORT")
    print("=======================")
    print("1. Shared: pods have the same allowed CPU pool and may run on the same CPUs at different times.")
    print("2. Exclusive: CPU Manager assigned a dedicated CPU set to an eligible Guaranteed container.")
    print("3. CPU IDs are affinity/eligibility, not instantaneous CPU utilization.")
    print("4. Use top, pidstat, perf, or metrics to measure actual CPU consumption over time.")
    print(
        f"5. This snapshot found {len(shared_groups)} shared group(s) and "
        f"{len(exclusive_groups)} exclusive group(s)."
    )


def render_detail_report():
    print("POD/CONTAINER DETAIL VIEW")
    print("=========================")
    identity_width = max(28, max(len(row["identity"]) for row in rows))
    print(f"{'POD/CONTAINER':<{identity_width}}  {'TYPE':<10}  CPU IDS")
    print(f"{'-' * identity_width}  {'-' * 10}  {'-' * 40}")
    for row in sorted(rows, key=lambda item: item["identity"]):
        cpu_text = row["manager"]
        if want_live:
            cpu_text = f"manager={row['manager']} live={row['live']}"
            if (
                row["live"] not in ("", "<unavailable>", "<timeout>")
                and not row["manager"].startswith("<")
                and row["manager"] != row["live"]
            ):
                cpu_text += "  [MISMATCH]"
        print(f"{row['identity']:<{identity_width}}  {row['allocation']:<10}  {cpu_text}")


if view in {"grouped", "both"}:
    render_grouped_report()
if view == "both":
    print("\n")
if view in {"detail", "both"}:
    render_detail_report()

live_failures = [row for row in rows if row["live_error"]]
if live_failures:
    print("\nLive cpuset could not be read for:", file=sys.stderr)
    for row in live_failures:
        print(f"  {row['identity']}: {row['live_error']}", file=sys.stderr)

status("Completed")
PY
