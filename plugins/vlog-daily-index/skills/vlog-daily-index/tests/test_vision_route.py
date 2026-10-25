"""Synthetic native capability contracts; no model/API/media calls."""
import argparse
from pathlib import Path
import tempfile
import unittest

from test_concurrency import cli, fixture, invoke, native_capabilities, store
from vlog_index.vision import dispatch_contract


def candidate(model_id, family, native_model=None, **extra):
    return {'id': model_id, 'family': family, 'native_model': native_model or model_id,
            'image_input': True, **extra}


class VisionRoute(unittest.TestCase):
    def make_queue(self, root):
        m, state, _ = fixture(root)
        m['packages'] = [{'id': f'p{i}', 'status': 'waiting_ai',
                          'result_path': str(root / f'p{i}.result.json')} for i in range(2)]
        m['config']['model_roles'] = {'vision': 'gpt-6.1-sol', 'vision_reasoning_effort': 'high'}
        store.dump(state / 'manifest.json', m)
        return state, native_capabilities(root)

    def test_current_session_luna_defaults_to_medium_and_persists_request_evidence(self):
        with tempfile.TemporaryDirectory() as td:
            state, snapshot = self.make_queue(Path(td)); before = (state / 'manifest.json').read_bytes()
            result = invoke('vision-queue', '--state', state, '--available-workers', 2,
                            '--claim-worker', 'worker', '--native-capabilities', snapshot)
            assigned = result['assigned'][0]; contract = assigned['dispatch_contract']
            self.assertEqual(contract['native_spawn_parameters'],
                             {'model': 'gpt-6-luna', 'reasoning_effort': 'medium', 'fork_turns': 'none'})
            self.assertEqual(contract['selection_reason'], 'first_eligible_advertised_model')
            self.assertEqual(contract['capability_snapshot'], store.read(snapshot))
            self.assertEqual(contract['runtime_verification'], 'unverified')
            self.assertEqual(contract['capability_verification'], 'harness_supplied_snapshot')
            self.assertEqual(store.read(state / 'vision-dispatch/claims.json')['p0'], assigned['claim'])
            self.assertEqual((state / 'manifest.json').read_bytes(), before)

    def test_haiku_native_alias_has_no_invented_reasoning_parameter(self):
        with tempfile.TemporaryDirectory() as td:
            snap = store.read(native_capabilities(Path(td)))
            snap['parameters'] = {'model': ['haiku']}
            snap['models'] = [candidate('claude-haiku-4-5', 'haiku', 'haiku')]
            contract = dispatch_contract(snap)
            self.assertEqual(contract['native_spawn_parameters'], {'model': 'haiku'})
            self.assertIsNone(contract['requested_reasoning_effort'])
            with self.assertRaises(ValueError): dispatch_contract(snap, reasoning_effort='medium')

    def test_deepseek_requires_native_image_capability_and_uses_only_supported_efforts(self):
        with tempfile.TemporaryDirectory() as td:
            snap = store.read(native_capabilities(Path(td)))
            snap['parameters'] = {'model': ['deepseek-flash'], 'reasoning_effort': ['low']}
            snap['models'] = [candidate('deepseek-flash', 'deepseek',
                reasoning_efforts=['low'], default_reasoning_effort='low')]
            self.assertEqual(dispatch_contract(snap)['native_spawn_parameters'],
                             {'model': 'deepseek-flash', 'reasoning_effort': 'low'})
            for image in (False, None, 'true'):
                snap['models'][0]['image_input'] = image
                with self.assertRaises(ValueError): dispatch_contract(snap)
            snap['models'][0].pop('image_input')
            with self.assertRaises(ValueError): dispatch_contract(snap)

    def test_default_follows_advertised_order_or_preference_without_provider_ranking(self):
        with tempfile.TemporaryDirectory() as td:
            snap = store.read(native_capabilities(Path(td)))
            snap['parameters']['model'] += ['claude-3-5-haiku-20241022', 'deepseek-flash', 'gpt-6.1-sol']
            snap['models'] = [candidate('gpt-6.1-sol', 'sol'), candidate('deepseek-flash', 'deepseek'),
                              candidate('claude-3-5-haiku-20241022', 'haiku'), *snap['models']]
            self.assertEqual(dispatch_contract(snap)['requested_model'], 'deepseek-flash')
            snap['preferred_model'] = 'claude-3-5-haiku-20241022'
            self.assertEqual(dispatch_contract(snap)['selection_reason'], 'session_preferred_model')
            self.assertEqual(dispatch_contract(snap)['requested_model'], snap['preferred_model'])
            self.assertEqual(dispatch_contract(snap, 'gpt-6-luna')['selection_reason'], 'explicit_model')
            self.assertEqual(dispatch_contract(snap, 'gpt-6-luna')['requested_model'], 'gpt-6-luna')
            for requested in ('gpt-6.1-sol', 'Luna', 'unknown'):
                with self.assertRaises(ValueError): dispatch_contract(snap, requested)
            snap['preferred_model'] = 'unknown'
            with self.assertRaises(ValueError): dispatch_contract(snap)

    def test_identity_and_native_parameter_cannot_disguise_a_different_model_or_provider(self):
        with tempfile.TemporaryDirectory() as td:
            snap = store.read(native_capabilities(Path(td)))
            for identity, native, family in (
                ('deepseek/gpt-6.1-sol', 'gpt-6.1-sol', 'deepseek'),
                ('anthropic/deepseek-flash', 'deepseek-flash', 'deepseek'),
                ('deepseek/deepseek-flash', 'gpt-6.1-sol', 'deepseek'),
                ('claude-haiku-4-5', 'deepseek/claude-haiku-4-5', 'haiku'),
                ('claude-haiku-4-5', 'claude-3-5-haiku-20241022', 'haiku'),
                ('claude-haiku-sol', 'claude-haiku-sol', 'haiku'),
                ('deepseek-flash', 'deepseek-v4-pro', 'deepseek')):
                snap['parameters'] = {'model': [native]}
                snap['models'] = [candidate(identity, family, native)]
                with self.subTest(identity=identity, native=native), self.assertRaises(ValueError): dispatch_contract(snap)
            for identity, native, family in (
                ('anthropic/claude-haiku-4-5', 'claude-haiku-4-5', 'haiku'),
                ('deepseek/deepseek-flash', 'deepseek/deepseek-flash', 'deepseek')):
                snap['parameters'] = {'model': [native]}
                snap['models'] = [candidate(identity, family, native)]
                self.assertEqual(dispatch_contract(snap)['native_spawn_parameters'], {'model': native})

    def test_invalid_route_rejects_before_release_or_any_claim_write(self):
        with tempfile.TemporaryDirectory() as td:
            state, snapshot = self.make_queue(Path(td)); good = store.read(snapshot)
            path = state / 'vision-dispatch/claims.json'
            legacy = {'worker': 'legacy', 'package_id': 'p0', 'at': 'old'}
            store.dump(path, {'p0': legacy}); before = path.read_bytes()
            variants = [None, {}, {**good, 'source': {}}, {**good, 'parameters': {}},
                {**good, 'models': [candidate('gpt-6.1-sol', 'deepseek')]},
                {**good, 'models': [candidate('deepseek-flash', 'deepseek', 'gpt-6-luna')]},
                {**good, 'models': [candidate('gpt-6-luna', 'luna')]},
                {**good, 'models': [candidate('claude-haiku-4-5', 'haiku', reasoning_efforts=['high'])]}]
            for value in variants:
                route = []
                if value is not None:
                    store.dump(snapshot, value); route = ['--native-capabilities', snapshot]
                with self.subTest(value=value), self.assertRaises(ValueError):
                    invoke('vision-queue', '--state', state, '--available-workers', 3,
                           '--release', 'p0', '--claim-worker', 'new', *route)
                self.assertEqual(path.read_bytes(), before)
            store.dump(snapshot, good)
            for effort in ('low', 'high', 'xhigh', 'max', 'none', ''):
                with self.subTest(effort=effort), self.assertRaises(ValueError):
                    invoke('vision-queue', '--state', state, '--available-workers', 3,
                           '--release', 'p0', '--claim-worker', 'new', '--native-capabilities', snapshot,
                           '--reasoning-effort', effort)
                self.assertEqual(path.read_bytes(), before)

    def test_python_entrypoint_cannot_bypass_capabilities_and_old_claims_are_unchanged(self):
        with tempfile.TemporaryDirectory() as td:
            state, snapshot = self.make_queue(Path(td))
            args = argparse.Namespace(state=str(state), available_workers=2, reserve_sol=1,
                                      claim_worker=['worker'], release=[])
            with self.assertRaises(ValueError): cli.vision_queue(args)
            path = state / 'vision-dispatch/claims.json'
            self.assertFalse(path.exists())
            for effort in (None, 'low', 'high'):
                old = {'worker': 'legacy', 'package_id': 'p0', 'at': 'old'}
                if effort: old.update(requested_model='gpt-6-luna', requested_reasoning_effort=effort)
                store.dump(path, {'p0': old}); before = path.read_bytes()
                invoke('vision-queue', '--state', state, '--available-workers', 2)
                self.assertEqual(path.read_bytes(), before)
                invoke('vision-queue', '--state', state, '--available-workers', 2,
                       '--claim-worker', 'new', '--native-capabilities', snapshot)
                self.assertEqual(store.read(path)['p0'], old)


if __name__ == '__main__': unittest.main()
