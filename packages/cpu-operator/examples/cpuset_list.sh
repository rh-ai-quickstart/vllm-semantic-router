oc exec gpu-cpu-placement-test -n default -- sh -c '
grep Cpus_allowed_list /proc/self/status
cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || true
ls -l /dev/nvidia* 2>/dev/null || true
'
oc exec cpu-manager-test -n default -- sh -c '
grep Cpus_allowed_list /proc/self/status
cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || true ' 
