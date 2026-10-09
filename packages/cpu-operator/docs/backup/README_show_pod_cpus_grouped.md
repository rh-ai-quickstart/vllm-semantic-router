# Group Pods and Containers by CPU Set

## Overview

`scripts/show-pod-cpus-grouped.sh` reports how running containers on one Kubernetes or OpenShift worker node map to logical CPU IDs.

The utility reads two sources:

1. kubelet CPU Manager checkpoint data from `/var/lib/kubelet/cpu_manager_state`;
2. optionally, each container's live effective cgroup cpuset through `oc exec` or `kubectl exec`.

The default report groups containers that have the same CPU set. This avoids repeating a long CPU list for every container and makes it easier to identify:

- pods sharing the same CPU pool;
- containers with exclusive CPU Manager assignments;
- CPU ranges used by the same pod groups;
- differences between CPU Manager state and live cgroup enforcement.

> A cpuset shows where a container is allowed to run. It does not show how many CPUs the container is actively consuming at a specific moment.

---

## Requirements

The system running the script needs:

- Bash;
- Python 3;
- `oc` for OpenShift, or `kubectl` selected with `CLI=kubectl`;
- permission to list nodes and pods;
- permission to create an OpenShift node debug pod when checkpoint inspection is enabled;
- permission to execute commands in containers when `LIVE=1` is enabled.

For OpenShift, verify access before running the complete report:

```bash
oc get nodes
oc get pods -A
```

Check that API-server-to-kubelet streaming works:

```bash
POD=$(oc get pod \
  -n cpu-operator-system \
  -l app=node-topology-agent \
  -o jsonpath='{.items[0].metadata.name}')

oc exec \
  -n cpu-operator-system \
  "$POD" \
  -c agent \
  -- true
```

---

## Installation

From the repository root:

```bash
chmod +x scripts/show-pod-cpus-grouped.sh
```

---

## Basic Usage

```bash
scripts/show-pod-cpus-grouped.sh <worker-node> [pod/container-regex]
```

Example:

```bash
NODE="ip-10-0-32-103.us-west-2.compute.internal"

scripts/show-pod-cpus-grouped.sh "$NODE"
```

Filter the report to vLLM workloads:

```bash
scripts/show-pod-cpus-grouped.sh "$NODE" 'vllm'
```

Filter multiple workload names:

```bash
scripts/show-pod-cpus-grouped.sh \
  "$NODE" \
  'vllm-cpu|vllm-gpu|node-topology-agent'
```

The optional filter is a Python regular expression matched against:

```text
namespace/pod/container
```

When the filter is omitted, all running containers on the selected worker are included.

---

## Recommended Commands

### Grouped CPU Manager view

This is the fastest report. It reads the kubelet checkpoint and does not execute into every container:

```bash
VIEW=grouped \
  scripts/show-pod-cpus-grouped.sh "$NODE"
```

### Grouped view with live cgroup validation

```bash
LIVE=1 VIEW=grouped \
  scripts/show-pod-cpus-grouped.sh "$NODE"
```

This compares the CPU Manager checkpoint with each container process's allowed CPU set (`Cpus_allowed_list`).

### Grouped and detailed views

```bash
LIVE=1 VIEW=both \
  scripts/show-pod-cpus-grouped.sh "$NODE"
```

### Detailed per-container view only

```bash
LIVE=1 VIEW=detail \
  scripts/show-pod-cpus-grouped.sh "$NODE"
```

### Limit the number of displayed pods per CPU group

```bash
LIVE=1 VIEW=grouped MAX_MEMBERS=10 \
  scripts/show-pod-cpus-grouped.sh "$NODE"
```

### Hide individual group members

```bash
LIVE=1 VIEW=grouped SHOW_MEMBERS=0 \
  scripts/show-pod-cpus-grouped.sh "$NODE"
```

### Skip the CPU Manager checkpoint

Use this when node debugging is unavailable but `exec` works:

```bash
SKIP_CHECKPOINT=1 LIVE=1 VIEW=grouped \
  scripts/show-pod-cpus-grouped.sh "$NODE"
```

---

## Output Views

## 1. CPU-Centric Grouped View

Containers are grouped by allocation type and effective CPU set.

Example:

```text
CPU-CENTRIC GROUPED VIEW
========================
A CPU set shows where a container is allowed to run. It does not mean the
container is actively using every CPU in the set.

[G1] SHARED CPU POOL
  CPU IDs:       0-95
  Logical CPUs:  96
  Pods:          31
  Containers:    67
  Manager/live:  67 match, 0 mismatch, 0 unavailable
  Meaning:       All members may run on any CPU in this shared pool.

  Members:
    - cpu-operator-system/cpu-operator-74fb44c99b-jdkrz  [QoS=Burstable]
        containers: operator (request=-, limit=-)

    - cpu-operator-system/node-topology-agent-kkpml  [QoS=BestEffort]
        containers: agent (request=-, limit=-)
```

Interpretation:

- `CPU IDs: 0-95` is an allowed CPU range.
- Every member in this group can be scheduled on any CPU from 0 through 95.
- The pods do not each receive 96 dedicated CPUs.
- Multiple threads and pods can use the same logical CPU at different times.
- The Linux scheduler selects the actual CPU used by each runnable thread.

## 2. CPU Range to Pod-Group Map

The inverse map collapses contiguous CPUs with identical group membership:

```text
CPU RANGE       GROUPS         TYPE           PODS  CONTAINERS  INTERPRETATION
---------------- -------------- ------------ ------ ----------- ----------------------------------
0-95             G1             shared           31          67  shared scheduler pool; contention is possible
```

This view answers:

> Which pod groups are allowed to use a particular CPU ID or range?

The report does not print 96 separate rows when CPUs 0 through 95 all have identical membership. It combines them into `0-95`.

## 3. Detailed View

The detailed view preserves one row per container:

```text
POD/CONTAINER                                      TYPE       CPU IDS
-------------------------------------------------  ---------- ----------------------------------------
cpu-operator-system/cpu-operator-.../operator      shared     manager=0-95 live=0-95
cpu-operator-system/node-topology-agent-.../agent  shared     manager=0-95 live=0-95
```

Use `VIEW=detail` for automation or when investigating one specific container.

---

## Allocation Types

### Shared

Example:

```text
TYPE=shared
CPU IDs=0-95
```

Meaning:

- The container has no exclusive CPU Manager entry.
- It is allowed to run in the CPU Manager default/shared pool.
- Other shared containers may run on the same CPUs.
- CPU time is controlled by Linux scheduling and cgroup CPU controls.

Shared does not mean the container continuously uses every CPU in the set.

### Exclusive

Example:

```text
TYPE=exclusive
CPU IDs=8-15
```

Meaning:

- kubelet CPU Manager assigned CPUs 8 through 15 to that container.
- Other CPU Manager exclusive workloads should not receive those CPUs.
- The container normally needs Guaranteed QoS with an integer CPU request equal to its CPU limit.

Example resource configuration:

```yaml
resources:
  requests:
    cpu: "8"
    memory: "8Gi"
  limits:
    cpu: "8"
    memory: "8Gi"
```

### Unpinned

This usually means CPU Manager policy is `none`. The operating system scheduler can place the container threads across the reported CPUs.

### Unknown

The script could not determine a reliable allocation type. Run with `DEBUG=1 LIVE=1` and inspect checkpoint or exec errors.

---

## Example with Shared and Exclusive Workloads

Assume the node has logical CPUs `0-95` and CPU Manager assigns:

```text
vllm-cpu-a: 8-15
vllm-cpu-b: 16-23
shared pool: 0-7,24-95
```

The grouped report would show:

```text
[G1] EXCLUSIVE CPU ASSIGNMENT
  CPU IDs:       8-15
  Pods:          1
  Containers:    1

[G2] EXCLUSIVE CPU ASSIGNMENT
  CPU IDs:       16-23
  Pods:          1
  Containers:    1

[G3] SHARED CPU POOL
  CPU IDs:       0-7,24-95
  Pods:          31
  Containers:    67
```

The CPU range map would show:

```text
CPU RANGE       GROUPS   TYPE        PODS  CONTAINERS  INTERPRETATION
0-7             G3       shared        31          67  shared scheduler pool; contention is possible
8-15            G1       exclusive      1           1  exclusive CPU Manager assignment
16-23           G2       exclusive      1           1  exclusive CPU Manager assignment
24-95           G3       shared        31          67  shared scheduler pool; contention is possible
```

---

## Manager and Live CPU Sets

With `LIVE=1`, the report compares:

- `manager`: the CPU set recorded by kubelet CPU Manager;
- `live`: the CPU affinity reported for the executed process by
  `/proc/self/status` as `Cpus_allowed_list`.

The process affinity is used as the primary live value because some privileged or
host-integrated containers expose the host cgroup root at `/sys/fs/cgroup`. The
root `cpuset.cpus.effective` can show every node CPU even when the container
process is correctly restricted. Cgroup cpuset files remain fallback sources when
`/proc/self/status` is unavailable.

Expected result:

```text
manager=8-15 live=8-15
```

A mismatch is marked in the detailed report:

```text
manager=8-15 live=0-95 [MISMATCH]
```

A mismatch can indicate:

- stale CPU Manager checkpoint state;
- kubelet or container runtime restart issues;
- unexpected cgroup hierarchy configuration;
- a pod created before CPU Manager policy changes were fully applied;
- a container runtime or node configuration problem.

---

## Environment Variables

| Variable | Default | Description |
|---|---:|---|
| `CLI` | `oc` | Kubernetes CLI. Set `CLI=kubectl` for Kubernetes. |
| `LIVE` | `0` | Read each matched container's effective cgroup cpuset. |
| `EXPAND` | `0` | In the detailed view, print `0,1,2,3` instead of `0-3`. |
| `DEBUG` | `0` | Print external commands and complete error details. |
| `NO_PROGRESS` | `0` | Suppress progress messages when set to `1`. |
| `SKIP_CHECKPOINT` | `0` | Skip `oc debug` checkpoint collection and force live inspection. |
| `LIST_TIMEOUT` | `30` | Timeout for node and pod listing operations, in seconds. |
| `DEBUG_TIMEOUT` | `60` | Timeout for reading the checkpoint through node debug. |
| `EXEC_TIMEOUT` | `20` | Timeout for each live container cpuset read. |
| `HEARTBEAT_SECONDS` | `5` | Progress heartbeat interval for long commands. |
| `VIEW` | `grouped` | Output mode: `grouped`, `detail`, or `both`. |
| `SHOW_MEMBERS` | `1` | Show pods and containers under each group. |
| `MAX_MEMBERS` | `0` | Maximum pods displayed per group; `0` means unlimited. |

---

## Troubleshooting

### `oc debug` times out

Test node debug directly:

```bash
oc debug "node/${NODE}" --quiet -- \
  chroot /host \
  cat /var/lib/kubelet/cpu_manager_state
```

If only node debugging is unavailable, use:

```bash
SKIP_CHECKPOINT=1 LIVE=1 \
  scripts/show-pod-cpus-grouped.sh "$NODE"
```

### `oc exec` reports a kubelet TLS error

Examples:

```text
error dialing backend: remote error: tls: internal error
```

```text
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

These errors indicate an OpenShift API-server-to-kubelet streaming or certificate problem, not a cgroup parsing problem in this script.

Check:

```bash
oc get csr
oc get co kube-apiserver
oc get kubeapiserver cluster -o yaml
```

Confirm all kube-apiserver static pods have converged on the same revision before retrying.

### Live cpuset is unavailable for one container

The container might not contain `sh`, `cat`, or `awk`, or the user might lack exec permission. The CPU Manager checkpoint view can still provide the manager assignment.

### Root-visible cgroup cpuset is broader than process affinity

Privileged and host-integrated containers can expose the host cgroup root inside
`/sys/fs/cgroup`. For example:

```text
manager=0,22-23,45-48,70-71,93-95
process_allowed=0,22-23,45-48,70-71,93-95
visible_cgroup_root=0-95
```

This is not a CPU isolation failure. The process affinity matches CPU Manager,
while the root-visible cgroup file describes a broader cgroup level. The script
uses `Cpus_allowed_list` first to avoid creating a false shared group from the
root-visible value.

### Every container is shown as shared on `0-95`

This means no running container currently has an exclusive CPU Manager checkpoint entry. Verify that the intended workload has:

- Guaranteed QoS;
- an integer CPU request;
- the same CPU request and CPU limit;
- been recreated after CPU Manager static policy was enabled.

Inspect the checkpoint:

```bash
oc debug "node/${NODE}" --quiet -- \
  chroot /host \
  cat /var/lib/kubelet/cpu_manager_state | jq .
```

A node with no exclusive allocations can look like:

```json
{
  "policyName": "static",
  "defaultCpuSet": "0-95",
  "checksum": 3074121769
}
```

---

## Measuring Actual CPU Consumption

This utility reports CPU affinity and eligibility, not utilization.

Use runtime monitoring tools to measure actual CPU consumption:

```bash
oc adm top pods -A
```

```bash
oc adm top pod -n <namespace> <pod-name> --containers
```

On the node, tools such as `top`, `pidstat`, `perf`, and Prometheus metrics can show utilization over time.
