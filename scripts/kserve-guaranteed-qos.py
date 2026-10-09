#!/usr/bin/env python3
"""Check or explicitly configure KServe sidecars for Guaranteed model pods."""
import argparse
import json
import subprocess
from decimal import Decimal
from pathlib import Path


def oc(*args):
    return subprocess.check_output(['oc', *args], text=True)


def cpu_m(value):
    value = str(value)
    amount = Decimal(value[:-1]) if value.endswith('m') else Decimal(value) * 1000
    if amount != amount.to_integral_value() or amount <= 0:
        raise ValueError(f'Expected positive whole millicores, got {value}')
    return int(amount)


def settings(cm):
    result = {}
    for key in ('agent', 'oauthProxy'):
        s = json.loads(cm['data'][key])
        for resource in ('cpu', 'memory'):
            if not s.get(resource + 'Limit') or not s.get(resource + 'Request'):
                raise ValueError(f'{key}: missing {resource} request/limit')
        cpu_m(s['cpuLimit'])
        result[key] = s
    return result


def patch_for(cm):
    data = {}
    for key, s in settings(cm).items():
        for resource in ('cpu', 'memory'):
            s[resource + 'Request'] = s[resource + 'Limit']
        data[key] = json.dumps(s)
    return {'metadata': {'annotations': {'opendatahub.io/managed': 'false'}}, 'data': data}


def check(cm):
    values = settings(cm)
    for key, s in values.items():
        for resource in ('cpu', 'memory'):
            a, b = s[resource + 'Request'], s[resource + 'Limit']
            equal = cpu_m(a) == cpu_m(b) if resource == 'cpu' else a == b
            if not equal:
                raise ValueError(f'{key}: {resource} request={a}, limit={b}; '
                                 'run scripts/kserve-guaranteed-qos.py --apply --backup FILE first')
    return sum(cpu_m(s['cpuRequest']) for s in values.values())


def expand_cpuset(value):
    result = set()
    for part in value.split(','):
        if '-' in part:
            first, last = map(int, part.split('-'))
            result.update(range(first, last + 1))
        elif part:
            result.add(int(part))
    return result


def verify_assignments(pods, state):
    if state.get('policyName') != 'static':
        raise ValueError('CPU Manager policy is not static')
    seen = set()
    shared = expand_cpuset(state['defaultCpuSet'])
    for pod in pods:
        entries = state.get('entries', {}).get(pod['metadata']['uid'], {})
        for container in pod['spec']['containers']:
            request = cpu_m(container['resources']['requests']['cpu'])
            if request % 1000:
                continue
            assigned = expand_cpuset(entries.get(container['name'], ''))
            if len(assigned) != request // 1000 or assigned & (seen | shared):
                raise ValueError(f"{pod['metadata']['name']}/{container['name']}: missing, wrong-sized or overlapping exclusive assignment")
            seen.update(assigned)
    print(f'[OK] CPU Manager: {len(seen)} exclusive CPUs, no overlap between tested containers or default pool')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--namespace', default='redhat-ods-applications')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--apply', action='store_true', help='Explicitly change cluster-wide sidecar defaults')
    mode.add_argument('--restore', metavar='BACKUP')
    mode.add_argument('--verify', metavar='MODEL_NAMESPACE')
    parser.add_argument('--node', help='With --verify, also check CPU Manager checkpoint on this worker')
    parser.add_argument('--backup', help='Required new backup path for --apply; never overwritten')
    args = parser.parse_args()
    if args.verify:
        pods = json.loads(oc('get', 'pods', '-n', args.verify, '-o', 'json'))['items']
        selected = []
        for model in ('granite-3-1-2b-instruct', 'granite-3-1-8b-instruct', 'qwen3-8b'):
            active = [p for p in pods if p['metadata'].get('labels', {}).get('serving.kserve.io/inferenceservice') == model
                      and not p['metadata'].get('deletionTimestamp')
                      and p['status'].get('phase') not in ('Failed', 'Succeeded')]
            if len(active) != 1:
                raise ValueError(f'{model}: expected one active pod, found {len(active)}; finish rollout first')
            p = active[0]
            if p['status'].get('qosClass') != 'Guaranteed' or not any(
                    c['type'] == 'Ready' and c['status'] == 'True' for c in p['status'].get('conditions', [])):
                raise ValueError(f"{p['metadata']['name']}: must be Ready and Guaranteed")
            print(f"[OK] {p['metadata']['name']}: Ready, Guaranteed")
            selected.append(p)
        if args.node:
            if any(p['spec'].get('nodeName') != args.node for p in selected):
                raise ValueError('Model pods are not all on the requested worker')
            daemons = json.loads(oc('get', 'pods', '-n', 'openshift-machine-config-operator',
                                    '--field-selector', f'spec.nodeName={args.node}', '-o', 'json'))['items']
            daemons = [p for p in daemons if p['metadata']['name'].startswith('machine-config-daemon-')
                       and p['status'].get('phase') == 'Running']
            if len(daemons) != 1:
                raise ValueError('Expected one running machine-config-daemon on worker')
            state = json.loads(oc('exec', '-n', 'openshift-machine-config-operator', daemons[0]['metadata']['name'],
                                  '-c', 'machine-config-daemon', '--', 'chroot', '/rootfs',
                                  'cat', '/var/lib/kubelet/cpu_manager_state'))
            verify_assignments(selected, state)
        return
    cm = json.loads(oc('get', 'cm', 'inferenceservice-config', '-n', args.namespace, '-o', 'json'))
    if args.restore:
        before = json.loads(Path(args.restore).read_text())
        if before['metadata']['namespace'] != args.namespace or before['metadata']['name'] != 'inferenceservice-config':
            raise ValueError('Backup namespace/name does not match target')
        patch = {'metadata': {'annotations': {'opendatahub.io/managed': before['metadata'].get('annotations', {}).get('opendatahub.io/managed')}},
                 'data': {k: before['data'][k] for k in ('agent', 'oauthProxy')}}
        print(oc('patch', 'cm', 'inferenceservice-config', '-n', args.namespace, '--type=merge', '-p', json.dumps(patch)).strip())
        return
    if args.apply:
        if not args.backup:
            parser.error('--apply requires --backup FILE')
        patch = patch_for(cm)
        with Path(args.backup).open('x') as f:
            Path(args.backup).chmod(0o600)
            json.dump(cm, f, indent=2)
        print(oc('patch', 'cm', 'inferenceservice-config', '-n', args.namespace, '--type=merge', '-p', json.dumps(patch)).strip())
        cm = json.loads(oc('get', 'cm', 'inferenceservice-config', '-n', args.namespace, '-o', 'json'))
    # A bare integer permits the values generator to consume this check safely.
    print(check(cm))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'[FAIL] {error}')
