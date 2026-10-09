CPU_POD=$(oc get pod -n ai-cpu-inference -l app=vllm-cpu \
  -o jsonpath='{.items[0].metadata.name}')

echo "CPU_POD=$CPU_POD"

oc exec -n ai-cpu-inference "$CPU_POD" -- sh -c '
echo "=== /proc/self/status ==="
grep Cpus_allowed_list /proc/self/status

echo
echo "=== cgroup effective cpuset ==="
cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || \
cat /sys/fs/cgroup/cpuset.cpus 2>/dev/null || true
'
