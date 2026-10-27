"""Whole-package/native lifecycle behavior, isolated synthetic state only."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_concurrency import fixture, invoke, native_capabilities, store
from vlog_index import vision_work
from test_vision_route import claude_agent


def setup(root, specs):
    m, state, _ = fixture(root)
    m['sources'] = []
    for i, (sid, directory, start, count) in enumerate(specs):
        if not any(s['id'] == sid for s in m['sources']):
            m['sources'].append({'id': sid})
        pid = f'p{i:03}'; result = root / (pid + '.result.json')
        frames = [{'id': f'{pid}-f{j}', 'source_id': sid, 'time': start + j,
                   'path': str(root / 'synthetic-never-opened.jpg')} for j in range(count)]
        payload = {'package_id': pid, 'result_path': str(result),
            'source': {'id': sid, 'relative_path': directory + '/' + sid + '.mp4', 'duration': 99999},
            'frames': frames, 'core_frame_ids': [f['id'] for f in frames], 'transcripts': [], 'gps': []}
        package = root / (pid + '.package.json'); store.dump(package, payload)
        m['packages'].append({'id': pid, 'path': str(package), 'result_path': str(result),
                              'source_id': sid, 'status': 'waiting_ai', 'core_frame_ids': payload['core_frame_ids']})
    store.dump(state / 'manifest.json', m)
    return state, native_capabilities(root)


def next_work(state, caps=None, *args, free=8):
    options = ['vision-work', '--state', state, '--available-workers', free]
    if caps: options += ['--native-capabilities', caps]
    return invoke(*options, *args)


def bind(state, action, native='native-1'):
    return next_work(state, None, '--group-id', action['group_id'], '--native-agent-id', native)


def report(state, action, outcome='complete'):
    return next_work(state, None, '--group-id', action['group_id'], '--outcome', outcome)


def result(member, valid=True):
    p = store.read(member['package_path']); frames = p['frames']
    store.dump(member['result_path'], {'package_id': p['package_id'],
        'analysed_frame_ids': [f['id'] for f in frames] if valid else [],
        'observations': [{'source_id': p['source']['id'], 'start': f['time'], 'end': f['time'],
                         'description': 'Synthetic fixture observation', 'evidence_ids': [f['id']]} for f in frames],
        'events': [], 'interest_points': [], 'supplemental_requests': [], 'summary': 'Synthetic only'})


def finish(state, caps, action):
    for p in action['members']: result(p)
    report(state, action)
    assert next_work(state, caps)['next_action'] == 'import_results'
    imported = invoke('import-results', '--state', state)
    assert not imported['errors']


class VisualWork(unittest.TestCase):
    def test_group_agent_route_and_followup_keep_declared_role_over_session_preference(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); state,_=setup(root, [('s','a',i*20,11) for i in range(2)])
            m=store.read(state/'manifest.json')
            m['config']['model_roles']={'vision':'vlog-daily-index:vlog-vision'}
            store.dump(state/'manifest.json',m)
            caps=claude_agent(root); snap=store.read(caps)
            snap['preferred_model']='unadvertised-session-default'; store.dump(caps,snap)
            first=next_work(state,caps)
            contract=first['native_contract']
            self.assertEqual((contract['route'],contract['selection_reason']),('agent','declared_vision_role'))
            self.assertEqual(contract['native_spawn_parameters'],{'subagent_type':'vlog-daily-index:vlog-vision'})
            self.assertIsNone(contract['requested_reasoning_effort'])
            bind(state,first); finish(state,caps,first)
            second=next_work(state,caps)
            self.assertEqual(second['next_action'],'followup')
            self.assertEqual(second['native_contract'],contract)

    def test_group_declared_luna_outweighs_preference_and_unavailable_role_fails_closed(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); state,caps=setup(root,[('s','a',0,11)])
            m=store.read(state/'manifest.json'); m['config']['model_roles']={'vision':'Luna'}
            store.dump(state/'manifest.json',m)
            snap=store.read(caps); snap['preferred_model']='not-the-run-role'; store.dump(caps,snap)
            first=next_work(state,caps)
            self.assertEqual(first['native_contract']['selection_reason'],'declared_vision_role')
            self.assertEqual(first['native_contract']['requested_model'],'gpt-6-luna')
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td),[('s','a',0,11)])
            m=store.read(state/'manifest.json'); m['config']['model_roles']={'vision':'missing:vision'}
            store.dump(state/'manifest.json',m)
            with self.assertRaises(ValueError): next_work(state,caps)
            self.assertFalse((state/'vision-dispatch/claims.json').exists())

    def test_same_model_role_tool_or_native_parameter_change_requires_new_worker(self):
        for change in ('role','tool','native_parameters'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as td:
                root=Path(td); state,caps=setup(root,[('s','a',i*20,11) for i in range(2)])
                m=store.read(state/'manifest.json'); m['config']['model_roles']={'vision':'Luna'}
                store.dump(state/'manifest.json',m)
                first=next_work(state,caps,'--model','gpt-6-luna'); bind(state,first); finish(state,caps,first)
                if change=='role':
                    m=store.read(state/'manifest.json'); m['config']['model_roles']['vision']='different:declared-role'
                    store.dump(state/'manifest.json',m)
                else:
                    snap=store.read(caps)
                    if change=='tool': snap['source']['tool']='another.native_tool'
                    else: snap['parameters'].pop('fork_turns')
                    store.dump(caps,snap)
                action=next_work(state,caps,'--model','gpt-6-luna')
                self.assertEqual((action['next_action'],action['reason']),('retire_worker','native_route_or_session_changed'))

    def test_soft_target_preserves_original_11_images_and_packages(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); state, caps = setup(root, [('s','a',0,11), ('s','a',20,3)])
            before = {p: p.read_bytes() for p in root.glob('*.package.json')}
            action = next_work(state, caps)
            self.assertEqual(action['next_action'], 'spawn')
            self.assertEqual(action['presented_images'], 11)
            self.assertEqual(len(action['members']), 1)
            self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_accumulates_whole_short_packages_counts_boundary_presentations(self):
        with tempfile.TemporaryDirectory() as td:
            state, caps = setup(Path(td), [('s','a',i*10,3) for i in range(5)])
            action = next_work(state, caps)
            self.assertEqual(action['presented_images'], 9)
            self.assertEqual(len(action['members']), 3)
            self.assertEqual(len(store.read(state/'vision-dispatch/claims.json')), 3)

    def test_small_ready_group_does_not_wait_to_fill(self):
        with tempfile.TemporaryDirectory() as td:
            state, caps = setup(Path(td), [('s','a',0,3)])
            self.assertEqual(next_work(state,caps)['presented_images'], 3)

    def test_source_time_order_then_directory_no_cross_directory(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',20,3),('t','b',0,3),('s','a',0,3),('u','a',0,3)])
            action=next_work(state,caps)
            self.assertEqual([p['package_id'] for p in action['members']], ['p002','p000','p003'])
            self.assertEqual(len({p['archive_directory'] for p in action['members']}),1)

    def test_pending_bind_is_recovered_not_respawned_even_after_arbitrary_wait(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',0,11)])
            first=next_work(state,caps)
            for _ in range(3):
                recovered=next_work(state,caps)
                self.assertEqual(recovered['next_action'],'recover_bind')
                self.assertEqual(recovered['group_id'], first['group_id'])
            bind(state,first)
            self.assertEqual(next_work(state,caps)['next_action'],'wait')

    def test_two_groups_then_retirement_and_new_native_identity(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',i*20,11) for i in range(3)])
            first=next_work(state,caps); bind(state,first); finish(state,caps,first)
            second=next_work(state,caps,free=0)
            self.assertEqual(second['next_action'],'followup')
            self.assertEqual(second['native_agent_id'],'native-1')
            finish(state,caps,second)
            retired=next_work(state,caps)
            self.assertEqual(retired['next_action'],'retire_worker')
            self.assertEqual(retired['reason'],'two_groups_completed')
            next_work(state,None,'--retire-confirmed', retired['worker_id'],'--reason','Native turn ended and worker closed')
            third=next_work(state,caps)
            self.assertEqual(third['next_action'],'spawn')
            with self.assertRaises(ValueError): bind(state,third,'native-1')
            bind(state,third,'native-2')

    def test_directory_change_retires_before_second_group(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',0,3),('t','b',0,3)])
            first=next_work(state,caps); bind(state,first); finish(state,caps,first)
            action=next_work(state,caps)
            self.assertEqual((action['next_action'],action['reason']),('retire_worker','archive_directory_changed'))

    def test_actual_slots_reserve_and_group_counts_not_member_counts(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',i*10,3) for i in range(12)])
            self.assertEqual(next_work(state,caps,free=1)['next_action'],'wait')
            first=next_work(state,caps,free=2); bind(state,first)
            second=next_work(state,caps,free=2)
            self.assertEqual(second['next_action'],'spawn')
            self.assertEqual(len(second['members']),3)
            self.assertTrue({p['package_id'] for p in first['members']}.isdisjoint({p['package_id'] for p in second['members']}))

    def test_live_legacy_claim_is_respected_and_caps_group_workers(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',i*20,11) for i in range(3)])
            m=store.read(state/'manifest.json'); m['config']['vision_concurrency']=1; store.dump(state/'manifest.json',m)
            store.dump(state/'vision-dispatch/claims.json', {'p000':{'worker':'legacy','package_id':'p000'}})
            action=next_work(state,caps)
            self.assertEqual(action['next_action'],'wait')
            self.assertEqual(action['legacy_claims'],['p000'])

    def test_legacy_queue_cannot_release_or_alias_group_worker(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',i*20,11) for i in range(3)])
            action=next_work(state,caps); bind(state,action)
            with self.assertRaises(ValueError): invoke('vision-queue','--state',state,'--available-workers',8,'--release','p000')
            with self.assertRaises(ValueError): invoke('vision-queue','--state',state,'--available-workers',8,'--claim-worker','native-1','--native-capabilities',caps)

    def test_partial_success_imports_once_only_missing_member_can_be_reassigned(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',i*10,3) for i in range(4)])
            action=next_work(state,caps); bind(state,action)
            result(action['members'][0]); report(state,action,'failed')
            self.assertEqual(next_work(state,caps)['next_action'],'import_results')
            invoke('import-results','--state',state)
            retired=next_work(state,caps)
            self.assertEqual(retired['next_action'],'retire_worker')
            next_work(state,None,'--retire-confirmed',retired['worker_id'],'--reason','Native failure confirmed')
            retry=next_work(state,caps)
            self.assertEqual({p['package_id'] for p in retry['members']},{'p001','p002','p003'})

    def test_invalid_result_keeps_old_full_frame_validator_and_requires_root(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',0,3)])
            action=next_work(state,caps); bind(state,action); result(action['members'][0],False)
            imported=invoke('import-results','--state',state)
            self.assertIn('Every supplied image', imported['errors'][0]['error'])
            bad_path=Path(action['members'][0]['result_path']); before=bad_path.read_bytes()
            with self.assertRaises(ValueError): invoke('retry-visual','--state',state,'--package-id','p000','--reason','Correction evidence')
            self.assertEqual(before,bad_path.read_bytes())
            report(state,action,'failed')
            retired=next_work(state,caps)
            next_work(state,None,'--retire-confirmed',retired['worker_id'],'--reason','Stopped')
            self.assertEqual(next_work(state,caps)['next_action'],'root_correction')

    def test_success_cache_and_manifest_and_source_bytes_never_modified_by_dispatch(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); state,caps=setup(root,[('s','a',0,11),('s','a',20,3)])
            m=store.read(state/'manifest.json'); m['packages'][0]['status']='success'; store.dump(state/'manifest.json',m)
            before=(state/'manifest.json').read_bytes(); raw=(root/'source.bin').read_bytes()
            action=next_work(state,caps)
            self.assertEqual([p['package_id'] for p in action['members']],['p001'])
            self.assertEqual(before,(state/'manifest.json').read_bytes()); self.assertEqual(raw,(root/'source.bin').read_bytes())

    def test_journal_recovery_is_atomic_idempotent_and_legacy_queue_observes_owner(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',0,11)])
            original=vision_work.recover
            with patch.object(vision_work,'recover',side_effect=[None,RuntimeError('simulated process crash')]):
                with self.assertRaises(RuntimeError): next_work(state,caps)
            self.assertTrue((state/'vision-dispatch/transaction.json').exists())
            q=invoke('vision-queue','--state',state,'--available-workers',8)
            self.assertEqual(q['unassigned_count'],0)
            self.assertEqual(next_work(state,caps)['next_action'],'recover_bind')
            self.assertFalse((state/'vision-dispatch/transaction.json').exists())

    def test_spawn_failure_requires_evidence_and_cannot_release_bound_running_worker(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',0,11)])
            action=next_work(state,caps)
            with self.assertRaises(ValueError): next_work(state,None,'--group-id',action['group_id'],'--spawn-failed')
            bind(state,action)
            with self.assertRaises(ValueError): next_work(state,None,'--group-id',action['group_id'],'--spawn-failed','--reason','Timeout is not proof')

    def test_current_native_contract_is_preserved_and_route_switch_retires(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',i*20,11) for i in range(2)])
            first=next_work(state,caps); bind(state,first)
            self.assertEqual(first['native_contract']['native_spawn_parameters'],{'model':'gpt-6-luna','reasoning_effort':'medium','fork_turns':'none'})
            finish(state,caps,first)
            snapshot=store.read(caps); snapshot['source']['session_id']='different-session'; store.dump(caps,snapshot)
            self.assertEqual(next_work(state,caps)['reason'],'native_route_or_session_changed')

    def test_owned_package_change_is_blocked(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',0,11)])
            action=next_work(state,caps); member=action['members'][0]
            p=store.read(member['package_path']); p['frames'][0]['time']+=1; store.dump(member['package_path'],p)
            with self.assertRaises(ValueError): next_work(state,caps)

    def test_dispatch_lock_prevents_competing_owner(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',0,11)])
            with store.RunLock(state/'vision-dispatch'):
                with self.assertRaises(RuntimeError): next_work(state,caps)
            self.assertEqual(next_work(state,caps)['next_action'],'spawn')

    def test_context_warning_rotates_after_success_without_repeating_cache(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',0,3)])
            action=next_work(state,caps); bind(state,action); result(action['members'][0]); report(state,action,'context_warning')
            invoke('import-results','--state',state)
            retired=next_work(state,caps)
            self.assertEqual(retired['reason'],'group_failure_or_warning')
            next_work(state,None,'--retire-confirmed',retired['worker_id'],'--reason','Native finished')
            self.assertEqual(next_work(state,caps)['next_action'],'visual_complete')

    def test_receipts_idempotent_do_not_dispatch_new_work(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',0,3)])
            action=next_work(state,caps)
            self.assertEqual(bind(state,action),bind(state,action))
            result(action['members'][0]); self.assertEqual(report(state,action),report(state,action))

    def test_success_files_and_import_without_native_completion_never_continue(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',i*20,11) for i in range(2)])
            m=store.read(state/'manifest.json'); m['config']['vision_concurrency']=1; store.dump(state/'manifest.json',m)
            action=next_work(state,caps); bind(state,action); result(action['members'][0])
            invoke('import-results','--state',state)
            waiting=next_work(state,caps)
            self.assertEqual(waiting['next_action'],'wait')
            self.assertEqual(waiting['running_native_agent_ids'],['native-1'])
            q=invoke('vision-queue','--state',state,'--available-workers',8)
            self.assertEqual(q['recommended_vision_workers'],0)

    def test_final_import_without_native_completion_never_marks_visual_complete(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',0,3)])
            action=next_work(state,caps); bind(state,action); result(action['members'][0])
            invoke('import-results','--state',state)
            self.assertEqual(next_work(state,caps)['next_action'],'wait')
            with self.assertRaisesRegex(ValueError,'Native visual turns'):
                invoke('daily-package','--state',state)
            with self.assertRaisesRegex(ValueError,'Native visual turns'):
                invoke('render','--state',state)
            with self.assertRaisesRegex(ValueError,'Native visual turns'):
                invoke('publish','--state',state)
            report(state,action)
            retired=next_work(state,caps)
            self.assertEqual(retired['reason'],'visual_queue_drained')
            next_work(state,None,'--retire-confirmed',retired['worker_id'],'--reason','Native completion verified')
            self.assertEqual(next_work(state,caps)['next_action'],'visual_complete')

    def test_idle_group_worker_still_consumes_legacy_concurrency_limit(self):
        with tempfile.TemporaryDirectory() as td:
            state,caps=setup(Path(td), [('s','a',i*20,11) for i in range(2)])
            m=store.read(state/'manifest.json'); m['config']['vision_concurrency']=1; store.dump(state/'manifest.json',m)
            action=next_work(state,caps); bind(state,action); finish(state,caps,action)
            # Reconciliation happens in a receipt-only call, leaving an idle worker.
            report(state,action)
            self.assertEqual(invoke('vision-queue','--state',state,'--available-workers',8)['recommended_vision_workers'],0)


if __name__=='__main__': unittest.main()
