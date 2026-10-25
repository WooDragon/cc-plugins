"""Synthetic native capability contracts; no model/API/media calls."""
import argparse
from pathlib import Path
import tempfile
import unittest

from test_concurrency import cli, fixture, invoke, store
from vlog_index.vision import dispatch_contract


def snapshot(root, models, parameters, preferred=None, tool='collaboration.spawn_agent'):
    value = {'schema': 'native_vision_capabilities_v1',
             'source': {'kind': 'current_session_native_tool', 'session_id': 'synthetic-session',
                        'tool': tool, 'evidence': 'Synthetic native parameter enum and image-capable fixture'},
             'parameters': parameters, 'models': models}
    if preferred is not None: value['preferred_model'] = preferred
    path = Path(root) / 'native-capabilities.json'; store.dump(path, value)
    return path


def luna(root, **extra):
    return snapshot(root, [{'id': 'gpt-6-luna', 'family': 'luna', 'native_model': 'gpt-6-luna',
                            'image_input': True, 'reasoning_efforts': ['medium'], **extra}],
                    {'model': ['gpt-6-luna'], 'reasoning_effort': ['medium'], 'fork_turns': ['none', 'all']})


def haiku_native(root):
    """DeepSeek-style host exposing a short native alias instead of a full model id."""
    return snapshot(root, [{'id': 'claude-haiku-4-5', 'family': 'haiku', 'native_model': 'haiku', 'image_input': True}],
                    {'model': ['haiku']})


def claude_agent(root, models=None):
    """Claude Code Agent tool: agents own model and effort, so no model parameter is exposed."""
    return snapshot(root, models or [{'id': 'vlog-daily-index:vlog-vision', 'image_input': True}],
                    {'subagent_type': ['vlog-daily-index:vlog-vision', 'vlog-daily-index:vlog-semantic']},
                    tool='Agent')


class VisionRoute(unittest.TestCase):
    def queue(self, root):
        m, state, _ = fixture(root)
        m['packages'] = [{'id': f'p{i}', 'status': 'waiting_ai',
                          'result_path': str(root / f'p{i}.result.json')} for i in range(2)]
        store.dump(state / 'manifest.json', m)
        return m, state

    def test_luna_defaults_to_medium_and_persists_request_evidence(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); m, state = self.queue(root)
            path = luna(root); before = (state / 'manifest.json').read_bytes()
            result = invoke('vision-queue', '--state', state, '--available-workers', 2,
                            '--claim-worker', 'worker', '--native-capabilities', path)
            contract = result['assigned'][0]['dispatch_contract']
            self.assertEqual(contract['native_spawn_parameters'],
                             {'model': 'gpt-6-luna', 'reasoning_effort': 'medium', 'fork_turns': 'none'})
            self.assertEqual((contract['route'], contract['selection_reason']), ('model', 'first_eligible_advertised_model'))
            self.assertEqual(contract['capability_snapshot'], store.read(path))
            self.assertEqual((contract['capability_verification'], contract['runtime_verification']),
                             ('harness_supplied_snapshot', 'unverified'))
            self.assertEqual(store.read(state / 'vision-dispatch/claims.json')['p0'], result['assigned'][0]['claim'])
            self.assertEqual((state / 'manifest.json').read_bytes(), before)
            self.assertEqual(result['selected_vision_route'], contract)

    def test_codex_declared_role_luna_is_preferred_but_never_overrides_an_explicit_model(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); m, state = self.queue(root)
            m['config']['host'] = 'codex'; m['config']['model_roles'] = {'vision': 'Luna'}; store.dump(state / 'manifest.json', m)
            snap = store.read(luna(root))
            snap['parameters'].update(model=['gpt-6-luna', 'deepseek-flash'], reasoning_effort=['medium', 'low'])
            snap['models'].insert(0, {'id': 'deepseek-flash', 'family': 'deepseek', 'native_model': 'deepseek-flash',
                                      'image_input': True, 'reasoning_efforts': ['low']})
            path = root / 'mixed.json'; store.dump(path, snap)
            contract = dispatch_contract(snap, vision_role='Luna')
            self.assertEqual((contract['requested_model'], contract['route']), ('gpt-6-luna', 'model'))
            self.assertEqual(dispatch_contract(snap, 'deepseek-flash', vision_role='Luna')['selection_reason'], 'explicit_model')

    def test_claude_code_agent_route_uses_declared_role_and_takes_effort_from_frontmatter(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); m, state = self.queue(root)
            m['config']['host'] = 'claude-code'
            m['config']['model_roles'] = {'vision': 'vlog-daily-index:vlog-vision'}
            store.dump(state / 'manifest.json', m)
            path = claude_agent(root)
            contract = invoke('vision-queue', '--state', state, '--available-workers', 2,
                              '--claim-worker', 'worker', '--native-capabilities', path)['assigned'][0]['dispatch_contract']
            self.assertEqual((contract['route'], contract['selection_reason'], contract['family']),
                             ('agent', 'declared_vision_role', None))
            self.assertEqual(contract['native_spawn_parameters'], {'subagent_type': 'vlog-daily-index:vlog-vision'})
            self.assertIsNone(contract['requested_reasoning_effort'])
            with self.assertRaises(ValueError): dispatch_contract(store.read(path), reasoning_effort='high',
                                                                 vision_role='vlog-daily-index:vlog-vision')

    def test_agent_snapshot_cannot_silently_fall_back_to_an_unrelated_agent(self):
        with tempfile.TemporaryDirectory() as td:
            snap = store.read(claude_agent(Path(td), [
                {'id': 'vlog-daily-index:vlog-semantic', 'image_input': True},
                {'id': 'vlog-daily-index:vlog-vision', 'image_input': False}]))
            with self.assertRaises(ValueError): dispatch_contract(snap, vision_role='vlog-daily-index:vlog-vision')
            with self.assertRaises(ValueError): dispatch_contract(snap, 'vlog-daily-index:vlog-semantic',
                                                                  vision_role='vlog-daily-index:vlog-vision')
            with self.assertRaises(ValueError): dispatch_contract(snap)

    def test_declared_role_never_silently_falls_back_to_another_route_or_family(self):
        with tempfile.TemporaryDirectory() as td:
            # Claude Code: the declared agent is missing or cannot read images; a model exists beside it.
            for models in ([{'id': 'vlog-daily-index:vlog-vision', 'image_input': False},
                            {'id': 'claude-haiku-4-5', 'family': 'haiku', 'native_model': 'haiku', 'image_input': True}],
                           [{'id': 'claude-haiku-4-5', 'family': 'haiku', 'native_model': 'haiku', 'image_input': True}]):
                snap = store.read(snapshot(Path(td), models,
                    {'model': ['haiku'], 'subagent_type': ['vlog-daily-index:vlog-vision']}))
                with self.subTest(models=models), self.assertRaises(ValueError):
                    dispatch_contract(snap, vision_role='vlog-daily-index:vlog-vision')
            # Codex: Luna is advertised without medium, so the declared role fails instead of drifting.
            snap = store.read(snapshot(Path(td), [
                {'id': 'deepseek-flash', 'family': 'deepseek', 'native_model': 'deepseek-flash', 'image_input': True},
                {'id': 'gpt-6-luna', 'family': 'luna', 'native_model': 'gpt-6-luna', 'image_input': True}],
                {'model': ['deepseek-flash', 'gpt-6-luna']}))
            with self.assertRaises(ValueError): dispatch_contract(snap, vision_role='Luna')
            self.assertEqual(dispatch_contract(snap)['requested_model'], 'deepseek-flash')

    def test_family_mapped_role_literal_cannot_be_dispatched_as_an_agent(self):
        with tempfile.TemporaryDirectory() as td:
            # 'Luna' is a family-mapped literal; treating it as an agent id would escape the medium rule.
            snap = store.read(snapshot(Path(td), [{'id': 'Luna', 'image_input': True}], {'subagent_type': ['Luna']}))
            with self.assertRaises(ValueError): dispatch_contract(snap, vision_role='Luna')
            with self.assertRaises(ValueError): dispatch_contract(snap, 'Luna', vision_role='Luna')

    def test_haiku_matrix_route_never_invents_a_reasoning_parameter_but_agent_route_never_takes_a_model(self):
        with tempfile.TemporaryDirectory() as td:
            snap = store.read(haiku_native(Path(td)))
            self.assertEqual(dispatch_contract(snap)['native_spawn_parameters'], {'model': 'haiku'})
            with self.assertRaises(ValueError): dispatch_contract(snap, reasoning_effort='medium')
            snap['parameters']['subagent_type'] = ['vlog-daily-index:vlog-vision']
            snap['models'].append({'id': 'vlog-daily-index:vlog-vision', 'image_input': True})
            # A host advertising both channels still cannot pick an agent by model request, or a model by role.
            self.assertEqual(dispatch_contract(snap, vision_role='vlog-daily-index:vlog-vision')['route'], 'agent')
            self.assertEqual(dispatch_contract(snap, 'claude-haiku-4-5', vision_role='vlog-daily-index:vlog-vision')['route'], 'model')

    def test_deepseek_requires_native_image_capability_and_uses_only_supported_efforts(self):
        with tempfile.TemporaryDirectory() as td:
            snap = store.read(snapshot(Path(td), [{'id': 'deepseek-flash', 'family': 'deepseek',
                'native_model': 'deepseek-flash', 'image_input': True, 'reasoning_efforts': ['low'],
                'default_reasoning_effort': 'low'}], {'model': ['deepseek-flash'], 'reasoning_effort': ['low']}))
            self.assertEqual(dispatch_contract(snap)['native_spawn_parameters'],
                             {'model': 'deepseek-flash', 'reasoning_effort': 'low'})
            for image in (False, None, 'true'):
                snap['models'][0]['image_input'] = image
                with self.assertRaises(ValueError): dispatch_contract(snap)
            snap['models'][0].pop('image_input')
            with self.assertRaises(ValueError): dispatch_contract(snap)
            # An explicit null effort list is unsupported by the tool, not a TypeError.
            snap['models'][0]['image_input'] = True; snap['models'][0]['reasoning_efforts'] = None
            with self.assertRaises(ValueError): dispatch_contract(snap, reasoning_effort='low')

    def test_default_follows_advertised_order_or_preference_without_provider_ranking(self):
        with tempfile.TemporaryDirectory() as td:
            models = [{'id': 'gpt-6.1-sol', 'family': 'sol', 'native_model': 'gpt-6.1-sol', 'image_input': True},
                      {'id': 'deepseek-flash', 'family': 'deepseek', 'native_model': 'deepseek-flash', 'image_input': True},
                      {'id': 'claude-3-5-haiku-20241022', 'family': 'haiku', 'native_model': 'claude-3-5-haiku-20241022', 'image_input': True},
                      {'id': 'gpt-6-luna', 'family': 'luna', 'native_model': 'gpt-6-luna', 'image_input': True,
                       'reasoning_efforts': ['medium']}]
            snap = store.read(snapshot(Path(td), models, {'model': [m['native_model'] for m in models],
                                                          'reasoning_effort': ['medium']}))
            self.assertEqual(dispatch_contract(snap)['requested_model'], 'deepseek-flash')
            snap['preferred_model'] = 'claude-3-5-haiku-20241022'
            self.assertEqual(dispatch_contract(snap)['selection_reason'], 'session_preferred_model')
            snap['preferred_model'] = 'gpt-6.1-sol'
            with self.assertRaises(ValueError): dispatch_contract(snap)
            snap['preferred_model'] = 'unknown'
            with self.assertRaises(ValueError): dispatch_contract(snap)
            for requested in ('gpt-6.1-sol', 'Luna', 'unknown'):
                with self.assertRaises(ValueError): dispatch_contract(snap, requested)
            self.assertEqual(dispatch_contract(snap, 'gpt-6-luna')['selection_reason'], 'explicit_model')

    def test_identity_and_native_parameter_cannot_disguise_a_different_model_or_provider(self):
        with tempfile.TemporaryDirectory() as td:
            for identity, native, family in (
                ('deepseek/gpt-6.1-sol', 'gpt-6.1-sol', 'deepseek'),
                ('anthropic/deepseek-flash', 'deepseek-flash', 'deepseek'),
                ('deepseek/deepseek-flash', 'gpt-6.1-sol', 'deepseek'),
                ('claude-haiku-4-5', 'deepseek/claude-haiku-4-5', 'haiku'),
                ('claude-haiku-4-5', 'claude-3-5-haiku-20241022', 'haiku'),
                ('claude-haiku-sol', 'claude-haiku-sol', 'haiku'),
                ('deepseek-flash', 'deepseek-v4-pro', 'deepseek')):
                snap = store.read(snapshot(Path(td), [{'id': identity, 'family': family,
                    'native_model': native, 'image_input': True}], {'model': [native]}))
                with self.subTest(identity=identity, native=native), self.assertRaises(ValueError): dispatch_contract(snap)
            for identity, native, family in (
                ('anthropic/claude-haiku-4-5', 'claude-haiku-4-5', 'haiku'),
                ('deepseek/deepseek-flash', 'deepseek/deepseek-flash', 'deepseek')):
                snap = store.read(snapshot(Path(td), [{'id': identity, 'family': family,
                    'native_model': native, 'image_input': True}], {'model': [native]}))
                self.assertEqual(dispatch_contract(snap)['native_spawn_parameters'], {'model': native})

    def test_rejection_reason_names_the_first_actual_problem(self):
        with tempfile.TemporaryDirectory() as td:
            snap = store.read(snapshot(Path(td), [{'id': 'claude-haiku-4-5', 'family': 'haiku',
                'native_model': 'claude-haiku-4-5', 'image_input': False,
                'default_reasoning_effort': 'low'}], {'model': ['claude-haiku-4-5']}))
            with self.assertRaises(ValueError) as raised: dispatch_contract(snap)
            self.assertIn('image input is not explicitly supported', str(raised.exception))
            self.assertNotIn('default reasoning effort', str(raised.exception))

    def test_invalid_route_rejects_before_release_or_any_claim_write(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); m, state = self.queue(root); good = store.read(luna(root))
            path = state / 'vision-dispatch/claims.json'
            store.dump(path, {'p0': {'worker': 'legacy', 'package_id': 'p0', 'at': 'old'}}); before = path.read_bytes()
            for value in (None, {}, {**good, 'source': {}}, {**good, 'parameters': {}}, {**good, 'parameters': {'model': []}},
                          {**good, 'models': []}, {**good, 'models': [{'id': 'gpt-6.1-sol', 'family': 'deepseek'}]},
                          {**good, 'models': [{'id': 'deepseek-flash', 'family': 'deepseek', 'native_model': 'gpt-6-luna', 'image_input': True}]},
                          {**good, 'models': [{'id': 'gpt-6-luna', 'family': 'luna', 'native_model': 'gpt-6-luna', 'image_input': True}]},
                          {**good, 'models': [{**good['models'][0], 'reasoning_efforts': ['high']}]},
                          {**good, 'models': [good['models'][0], {'id': 'gpt-6-luna', 'image_input': True}]}):
                snap = root / 'variant.json'
                route = []
                if value is not None: store.dump(snap, value); route = ['--native-capabilities', snap]
                with self.subTest(value=value), self.assertRaises(ValueError):
                    invoke('vision-queue', '--state', state, '--available-workers', 3,
                           '--release', 'p0', '--claim-worker', 'new', *route)
                self.assertEqual(path.read_bytes(), before)
            store.dump(snap, good)
            for effort in ('low', 'high', 'xhigh', 'max', 'none', ''):
                with self.subTest(effort=effort), self.assertRaises(ValueError):
                    invoke('vision-queue', '--state', state, '--available-workers', 3, '--release', 'p0',
                           '--claim-worker', 'new', '--native-capabilities', snap, '--reasoning-effort', effort)
                self.assertEqual(path.read_bytes(), before)

    def test_python_entrypoint_cannot_bypass_capabilities_and_old_claims_are_unchanged(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); m, state = self.queue(root); path = state / 'vision-dispatch/claims.json'
            with self.assertRaises(ValueError):
                cli.vision_queue(argparse.Namespace(state=str(state), available_workers=2, reserve_sol=1,
                                                    claim_worker=['worker'], release=[]))
            self.assertFalse(path.exists())
            old = {'worker': 'legacy', 'package_id': 'p0', 'at': 'old', 'requested_model': 'gpt-6-luna',
                   'requested_reasoning_effort': 'high'}
            store.dump(path, {'p0': old}); before = path.read_bytes()
            invoke('vision-queue', '--state', state, '--available-workers', 2)
            self.assertEqual(path.read_bytes(), before)
            invoke('vision-queue', '--state', state, '--available-workers', 2,
                   '--claim-worker', 'new', '--native-capabilities', luna(root))
            self.assertEqual(store.read(path)['p0'], old)

    def test_release_only_needs_no_capability_snapshot(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); m, state = self.queue(root); path = state / 'vision-dispatch/claims.json'
            store.dump(path, {'p0': {'worker': 'finished', 'package_id': 'p0', 'at': 'old'}})
            result = invoke('vision-queue', '--state', state, '--available-workers', 2, '--release', 'p0')
            self.assertNotIn('p0', store.read(path))
            self.assertIsNone(result['selected_vision_route'])
            self.assertEqual(result['unassigned_count'], 2)


if __name__ == '__main__': unittest.main()
