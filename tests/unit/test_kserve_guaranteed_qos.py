import copy
import importlib.util
import json
import os
import subprocess
import sys
import unittest
import tempfile
from unittest.mock import patch
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('qos', ROOT / 'scripts/kserve-guaranteed-qos.py')
qos = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qos)


def config():
    return {'data': {
        'agent': json.dumps({'cpuRequest': '100m', 'cpuLimit': '1', 'memoryRequest': '100Mi', 'memoryLimit': '1Gi', 'image': 'keep'}),
        'oauthProxy': json.dumps({'cpuRequest': '100m', 'cpuLimit': '200m', 'memoryRequest': '64Mi', 'memoryLimit': '128Mi'})}}


def pod(uid):
    return {'metadata': {'name': uid, 'uid': uid}, 'spec': {'containers': [
        {'name': 'model', 'resources': {'requests': {'cpu': '2'}}},
        {'name': 'proxy', 'resources': {'requests': {'cpu': '200m'}}}]}}


class QoSTests(unittest.TestCase):
    def test_original_sidecars_rejected(self):
        with self.assertRaisesRegex(ValueError, 'agent: cpu'):
            qos.check(config())

    def test_atomic_patch_preserves_settings_and_budget(self):
        cm = config()
        before = copy.deepcopy(cm)
        patch = qos.patch_for(cm)
        self.assertEqual(cm, before)
        self.assertEqual(patch['metadata']['annotations']['opendatahub.io/managed'], 'false')
        self.assertEqual(json.loads(patch['data']['agent'])['image'], 'keep')
        self.assertEqual(qos.check(patch), 1200)

    def test_memory_mismatch_rejected(self):
        patch = qos.patch_for(config())
        agent = json.loads(patch['data']['agent'])
        agent['memoryRequest'] = '100Mi'
        patch['data']['agent'] = json.dumps(agent)
        with self.assertRaisesRegex(ValueError, 'agent: memory'):
            qos.check(patch)

    def test_budget_uses_installed_values(self):
        patch = qos.patch_for(config())
        agent = json.loads(patch['data']['agent'])
        agent.update(cpuRequest='2', cpuLimit='2')
        patch['data']['agent'] = json.dumps(agent)
        self.assertEqual(qos.check(patch), 2200)

    def test_checkpoint_assignments(self):
        qos.verify_assignments([pod('a'), pod('b')], {'policyName': 'static', 'defaultCpuSet': '0,5-7',
                                                   'entries': {'a': {'model': '1-2'}, 'b': {'model': '3-4'}}})

    def test_checkpoint_rejects_overlap_or_wrong_size(self):
        for second in ('2-3', '4-5', '', '3'):
            with self.subTest(second=second), self.assertRaises(ValueError):
                qos.verify_assignments([pod('a'), pod('b')], {'policyName': 'static', 'defaultCpuSet': '0,5-7',
                                                           'entries': {'a': {'model': '1-2'}, 'b': {'model': second}}})

    def test_apply_backup_and_restore(self):
        cm = config()
        cm['metadata'] = {'name': 'inferenceservice-config', 'namespace': 'redhat-ods-applications'}
        fixed = qos.patch_for(cm)
        with tempfile.TemporaryDirectory() as directory:
            backup = str(Path(directory) / 'before.json')
            with patch.object(sys, 'argv', ['qos', '--apply', '--backup', backup]), \
                 patch.object(qos, 'oc', side_effect=[json.dumps(cm), 'patched', json.dumps(fixed)]) as mocked:
                qos.main()
                applied = json.loads(mocked.call_args_list[1].args[-1])
                self.assertEqual(applied, fixed)
            self.assertEqual(json.loads(Path(backup).read_text()), cm)
            self.assertEqual(Path(backup).stat().st_mode & 0o777, 0o600)
            with patch.object(sys, 'argv', ['qos', '--restore', backup]), \
                 patch.object(qos, 'oc', side_effect=[json.dumps(fixed), 'restored']) as mocked:
                qos.main()
                restored = json.loads(mocked.call_args_list[1].args[-1])
                self.assertIsNone(restored['metadata']['annotations']['opendatahub.io/managed'])
                self.assertEqual(restored['data'], cm['data'])

    def test_rollout_strategy_only_for_g7(self):
        doc = {'apiVersion': 'serving.kserve.io/v1beta1', 'kind': 'InferenceService',
               'metadata': {'name': 'qwen3-8b'}, 'spec': {'predictor': {}}}
        for node in ('', 'worker'):
            env = dict(os.environ, CPU_OPERATOR_NODE=node)
            env.pop('CPU_OPERATOR_PREVIOUS_MANIFEST', None)
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/cpu-operator-kserve-post-renderer.py')],
                                    input=yaml.safe_dump(doc), capture_output=True, text=True, env=env, check=True)
            predictor = yaml.safe_load(result.stdout)['spec']['predictor']
            if node:
                self.assertEqual(predictor['deploymentStrategy']['rollingUpdate'], {'maxSurge': 0, 'maxUnavailable': 1})
            else:
                self.assertNotIn('deploymentStrategy', predictor)


if __name__ == '__main__':
    unittest.main()
