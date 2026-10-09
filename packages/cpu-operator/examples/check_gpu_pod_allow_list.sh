GPU_POD=$(oc get pod -n ai-inference -l app=vllm-gpu \
  -o jsonpath='{.items[0].metadata.name}')

echo "GPU_POD=$GPU_POD"

oc exec -n ai-inference "$GPU_POD" -- sh -c '
echo "=== /proc/self/status ==="
grep Cpus_allowed_list /proc/self/status

echo
echo "=== cgroup effective cpuset ==="
cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || \
cat /sys/fs/cgroup/cpuset.cpus 2>/dev/null || true

echo
'
