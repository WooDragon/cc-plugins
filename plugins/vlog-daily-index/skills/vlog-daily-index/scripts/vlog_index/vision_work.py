"""Deterministic whole-package groups and bounded native worker lifetimes.

Only the harness calls native tools. This ledger shares the legacy claim lock;
the small redo journal commits claims and groups together after process death.
No timeout is evidence that a native worker stopped.
"""
from __future__ import annotations
from pathlib import Path, PurePosixPath
from .store import RunLock, read, dump, digest
from .vision import dispatch_contract

TARGET_IMAGES = 10
GROUPS_PER_WORKER = 2


def recover(root):
    """Caller holds vision-dispatch's RunLock (including legacy callers)."""
    root = Path(root)
    journal = root / 'transaction.json'
    if journal.exists():
        tx = read(journal)
        dump(root / 'claims.json', tx['claims'])
        dump(root / 'groups.json', tx['ledger'])
        journal.unlink()


def commit(root, claims, ledger):
    dump(root / 'transaction.json', {'claims': claims, 'ledger': ledger})
    recover(root)


def require_finished_native_turns(state):
    """Results alone cannot open semantic/review/publication gates."""
    root = Path(state) / 'vision-dispatch'
    with RunLock(root):
        recover(root)
        if not (root / 'groups.json').exists(): return
        ledger = read(root / 'groups.json')
        unresolved = [g['id'] for g in ledger['groups'].values()
                      if g['status'] != 'dispatch_failed' and not g['turn_finished']]
        if unresolved:
            raise ValueError('Native visual turns are still running/unknown; record actual completion before downstream stages: ' + ', '.join(unresolved))
        # Completion receipts are saved without file I/O. A caller may go straight
        # from report to daily-package, so the gate must inspect current originals,
        # not rely on package_errors cached by an earlier `next` call.
        m = read(Path(state) / 'manifest.json')
        packages = {p['id']: p for p in m['packages']}
        blocked = [g['id'] for g in ledger['groups'].values()
                   if g['status'] not in ('success', 'partial', 'dispatch_failed')
                   and _group_package_errors(m, g, packages)]
        if blocked:
            raise ValueError('Original visual package recovery is required before downstream stages: ' + ', '.join(blocked))


def _directory(m, source):
    # Same archive directory is a scheduling hint, never scene evidence.
    parent = str(PurePosixPath(source['relative_path'].replace('\\', '/')).parent)
    return digest([m['run_id'], m['config'].get('source_root'), parent])[:16] + ':' + parent


def package_info(m, p):
    payload = read(p['path'])
    if payload['package_id'] != p['id'] or payload['result_path'] != p['result_path']:
        raise ValueError('Package identity/path changed: ' + p['id'])
    source = payload['source']
    if p.get('source_id', source['id']) != source['id']:
        raise ValueError('Package source identity mismatch: ' + p['id'])
    if not payload['frames']:
        raise ValueError('Cannot dispatch an empty visual package')
    return {'package_id': p['id'], 'package_path': p['path'],
            'result_path': p['result_path'], 'source_id': source['id'],
            'archive_directory': _directory(m, source),
            'start': min(f['time'] for f in payload['frames']),
            'presented_images': len(payload['frames']), 'package_digest': digest(payload), 'status': p['status'],
            'original_manifest_record': dict(p)}


def ordered_ready(m, claims, directory=None, source_id=None):
    rank = {s['id']: i for i, s in enumerate(m['sources'])}
    ready = [package_info(m, p) for p in m['packages']
             if p['status'] == 'waiting_ai' and p['id'] not in claims
             and not Path(p['result_path']).exists()]
    ready.sort(key=lambda p: (p['source_id'] != source_id,
        p['archive_directory'] != directory, rank.get(p['source_id'], len(rank)),
        p['start'], p['package_id']))
    return ready


def take_group(ready):
    """Never split or trim an original package, even when it contains 11 images."""
    if not ready: return []
    selected = []; images = 0; directory = ready[0]['archive_directory']
    for p in ready:
        if p['archive_directory'] != directory: continue
        if selected and images + p['presented_images'] > TARGET_IMAGES: break
        selected.append(p); images += p['presented_images']
        if images >= TARGET_IMAGES: break
    return selected


def _task(group, worker):
    return {'group_id': group['id'], 'worker_id': worker['id'],
            'native_agent_id': worker.get('native_agent_id'),
            'task_path': group['task_path'], 'members': group['members'],
            'presented_images': group['presented_images'],
            'native_contract': group['native_contract']}


def _contract(m, args):
    role = (m.get('config', {}).get('model_roles') or {}).get('vision')
    return dispatch_contract(read(args.native_capabilities) if args.native_capabilities else None,
        getattr(args, 'model', None), getattr(args, 'reasoning_effort', None), vision_role=role)


def _route_identity(contract):
    # An identical model can still belong to a different declared role, native
    # tool or agent/model route. None of those changes may reuse the old worker.
    return (contract['route'], contract['vision_role'], contract['native_tool'],
        contract['native_spawn_parameters'], contract['requested_model'],
        contract['requested_reasoning_effort'], contract['capability_snapshot']['source']['session_id'])


def _new_group(root, ledger, claims, members, worker, contract):
    gid = 'group-' + str(ledger['next_group']).zfill(6)
    ledger['next_group'] += 1
    task_path = root / 'tasks' / (gid + '.json')
    group = {'id': gid, 'worker_id': worker['id'], 'members': members,
             'presented_images': sum(p['presented_images'] for p in members),
             'native_contract': contract, 'task_path': str(task_path),
             'status': 'running', 'turn_finished': False}
    dump(task_path, {'schema': 'native_visual_group_v1', **group,
        'instructions': '按 members 顺序逐包读取原 package_path 和全部 frames 图片（含 boundary）；'
        '每包独立写原 result_path，严格遵守原 result_schema、逐帧观察及 evidence 校验。'
        'analysed_frame_ids必须逐字列出全部frames.id（包含boundary），不得只抄core_frame_ids；'
        'observations仍依原schema覆盖core。'
        '不能因同源/相邻/同目录认定同场景。不得写其他路径、改原包、请求ASR或递归委派。'
        '只在全部成员完成后回报一次 group_id 和逐包完成清单；遇到读图/写入/上下文问题立即回报'
        '已完成及未开始成员并停止，保留已写成功文件。不得空观察冒充识图。'})
    ledger['groups'][gid] = group
    worker.update(group_id=gid, directory=members[0]['archive_directory'],
                  last_source_id=members[-1]['source_id'])
    for p in members:
        claims[p['package_id']] = {'worker': worker['id'], 'package_id': p['package_id'],
            'group_id': gid, 'native_agent_id': worker.get('native_agent_id'),
            'dispatch_contract': contract,
            'requested_model': contract['requested_model'],
            'requested_reasoning_effort': contract['requested_reasoning_effort']}
    return group


def _group_package_errors(m, group, packages):
    errors = []
    for member in group['members']:
        try:
            p = packages.get(member['package_id'])
            if p is None: raise ValueError('An owned original package disappeared from manifest')
            original_record = member.get('original_manifest_record')
            source_changed = (p.get('source_id') != original_record.get('source_id') if original_record is not None
                              else p.get('source_id', member['source_id']) != member['source_id'])
            if (p.get('path') != member['package_path'] or p.get('result_path') != member['result_path']
                    or source_changed):
                raise ValueError('An owned original package manifest identity changed; restore package_path, result_path and source_id')
            if package_info(m, p)['package_digest'] != member['package_digest']:
                raise ValueError('An owned original package changed; restore its original digest')
        except Exception as exc:
            # Local package damage is a recoverable ROOT item, not a reason
            # to roll back another native worker's actual completion receipt.
            errors.append({'package_id': member['package_id'], 'error': str(exc),
                'expected_digest': member['package_digest'],
                'package_path': member['package_path'], 'result_path': member['result_path'],
                'original_manifest_record': member.get('original_manifest_record')})
    return errors


def _reconcile(m, ledger, claims):
    packages = {p['id']: p for p in m['packages']}
    for group in ledger['groups'].values():
        if group['status'] in ('success', 'partial', 'dispatch_failed'): continue
        errors = _group_package_errors(m, group, packages)
        if errors:
            group.update(status='blocked_package', package_errors=errors)
            worker = ledger['workers'][group['worker_id']]
            if group['turn_finished'] and worker['status'] != 'retired':
                worker.update(status='retire_required', retire_reason='original_package_recovery')
            continue
        group.pop('package_errors', None)
        if group['status'] == 'blocked_package': group['status'] = 'running'
        for member in group['members']: member['status'] = packages[member['package_id']]['status']
        if not group['turn_finished']: continue
        # Imported successes are reused; files awaiting the old validator hold the group.
        if any(p['status'] == 'waiting_ai' and Path(p['result_path']).exists()
               for p in (packages[x['package_id']] for x in group['members'])): continue
        worker = ledger['workers'][group['worker_id']]
        success = all(packages[x['package_id']]['status'] == 'success' for x in group['members'])
        group['status'] = 'success' if success else 'partial'
        for member in group['members']:
            claim = claims.get(member['package_id'], {})
            if claim.get('group_id') == group['id']: claims.pop(member['package_id'])
        worker['group_id'] = None
        if success:
            worker['completed_groups'] += 1
        if worker['status'] == 'retired': continue
        worker['status'] = ('retire_required' if not success or group.get('outcome') != 'complete'
                           or worker['completed_groups'] >= GROUPS_PER_WORKER else 'idle')
        if worker['status'] == 'retire_required':
            worker['retire_reason'] = 'group_failure_or_warning' if not success or group.get('outcome') != 'complete' else 'two_groups_completed'


def run(args):
    """One entry point: next action, bind a spawn receipt, or report a native turn."""
    state = Path(args.state).resolve(); root = state / 'vision-dispatch'
    if args.available_workers < 0 or args.reserve_sol < 0:
        raise ValueError('Actual native free slots/reserve must be nonnegative')
    with RunLock(root):
        recover(root)
        ledger_path = root / 'groups.json'
        ledger = read(ledger_path) if ledger_path.exists() else {
            'schema': 'native_visual_work_v1', 'next_group': 1, 'next_worker': 1,
            'groups': {}, 'workers': {}}
        claims = read(root / 'claims.json') if (root / 'claims.json').exists() else {}
        gid = getattr(args, 'group_id', None)
        native_id = getattr(args, 'native_agent_id', None)
        outcome = getattr(args, 'outcome', None)
        spawn_failed = getattr(args, 'spawn_failed', False)
        retired = getattr(args, 'retire_confirmed', None)
        followup_confirmed = getattr(args, 'followup_confirmed', False)
        if sum(bool(x) for x in (native_id, outcome, spawn_failed, retired, followup_confirmed)) > 1:
            raise ValueError('Choose one receipt operation per call')
        if native_id or outcome or spawn_failed or followup_confirmed:
            if gid not in ledger['groups']: raise ValueError('Receipt requires a known --group-id')
            group = ledger['groups'][gid]; worker = ledger['workers'][group['worker_id']]
            if native_id:
                if not native_id.strip(): raise ValueError('Native Agent ID is empty')
                if worker.get('native_agent_id') == native_id: pass  # idempotent receipt
                elif worker['status'] != 'pending_bind': raise ValueError('Worker is not awaiting a native spawn receipt')
                elif any(w.get('native_agent_id') == native_id for w in ledger['workers'].values()) or any(
                        c.get('native_agent_id', c.get('worker')) == native_id for c in claims.values()):
                    raise ValueError('Native ID already belongs to another worker; aliases do not add slots')
                else:
                    worker.update(native_agent_id=native_id, status='running')
                    for member in group['members']: claims[member['package_id']]['native_agent_id'] = native_id
            elif spawn_failed:
                if not getattr(args, 'reason', ''): raise ValueError('Explicit failed native dispatch needs evidence --reason')
                if group['status'] == 'dispatch_failed': pass
                elif worker['status'] != 'pending_bind': raise ValueError('Cannot release a possibly running native worker as spawn-failed')
                else:
                    group.update(status='dispatch_failed', reason=args.reason)
                    worker.update(status='retired', group_id=None)
                    for member in group['members']: claims.pop(member['package_id'], None)
            elif followup_confirmed:
                if not (getattr(args, 'reason', None) or '').strip():
                    raise ValueError('Followup acceptance requires actual native dispatch evidence --reason')
                if group.get('followup_confirmed'): pass
                elif worker['status'] != 'pending_followup' or worker['group_id'] != gid:
                    raise ValueError('Only the current pending followup can be acknowledged')
                else:
                    group.update(followup_confirmed=True, followup_evidence=args.reason)
                    worker['status'] = 'running'
            else:
                if group.get('outcome') == outcome: pass
                elif group['turn_finished'] or worker['status'] not in ('running', 'pending_followup'):
                    raise ValueError('Report needs a bound running worker and one confirmed native turn completion')
                elif worker['status'] == 'pending_followup' and not (getattr(args, 'reason', None) or '').strip():
                    raise ValueError('Pending followup outcome requires matching-group native completion evidence --reason')
                else:
                    group.update(turn_finished=True, outcome=outcome, report_reason=getattr(args, 'reason', None))
                    worker['status'] = 'awaiting_validation'
        if retired:
            worker = ledger['workers'].get(retired)
            if not worker or worker['status'] not in ('retire_required', 'retired'):
                raise ValueError('Only a finished worker can be retired')
            if not getattr(args, 'reason', ''): raise ValueError('Retirement requires native completion/closure evidence --reason')
            worker.update(status='retired', retire_evidence=args.reason)
        # Receipt calls are deliberately not combined with a new dispatch. A lost
        # response can be retried without accidentally spawning or claiming again.
        # Persist facts from native tools before reading any other group's files.
        if native_id or outcome or spawn_failed or retired or followup_confirmed:
            commit(root, claims, ledger)
            return {'next_action': 'next', 'receipt_recorded': True}
        m = read(state / 'manifest.json')
        _reconcile(m, ledger, claims)
        waiting = [p for p in m['packages'] if p['status'] == 'waiting_ai']
        awaiting = [p['id'] for p in waiting if Path(p['result_path']).exists()]
        result = {'target_presented_images': TARGET_IMAGES, 'groups_per_worker': GROUPS_PER_WORKER,
                  'unfinished_original_packages': sum(p['status'] != 'success' for p in m['packages']),
                  'host_available_workers': args.available_workers, 'reserved_for_sol': args.reserve_sol}
        blocked = next((g for g in ledger['groups'].values() if g.get('package_errors')), None)
        if blocked:
            action = {'next_action': 'root_package_recovery',
                **_task(blocked, ledger['workers'][blocked['worker_id']]),
                'native_turn_finished': blocked['turn_finished'],
                'package_errors': blocked['package_errors'],
                'note': 'Keep claims while native state is unknown; inspect this exact native turn/group and record actual completion only. Restore the original package and manifest identity to the expected paths/digest, then rerun vision-work and the original import-results validator. Unrecoverable originals remain incomplete; no abandon/adopt-changed-package permission is granted.'}
        elif awaiting:
            action = {'next_action': 'import_results', 'package_ids': awaiting,
                      'command': 'import-results', 'note': 'Use existing coordinator validator; wait if media holds the run lock.'}
        else:
            action = _next(root, m, ledger, claims, args)
        commit(root, claims, ledger)
        return {**result, **action}


def _next(root, m, ledger, claims, args):
    workers = ledger['workers']
    for worker in workers.values():
        if worker['status'] == 'pending_bind':
            return {'next_action': 'recover_bind', **_task(ledger['groups'][worker['group_id']], worker),
                    'note': 'Do not spawn again: bind the actual existing ID, or record explicit --spawn-failed evidence.'}
        if worker['status'] == 'pending_followup':
            return {'next_action': 'recover_followup', **_task(ledger['groups'][worker['group_id']], worker),
                    'note': 'Verify the exact native turn/group before acting. If accepted, record --followup-confirmed --reason EVIDENCE; if actually completed, record its outcome. Send this exact task once only with explicit evidence it was not sent. Unknown state means wait, never resend or release on timeout.'}
        if worker['status'] == 'retire_required':
            return {'next_action': 'retire_worker', 'worker_id': worker['id'],
                    'native_agent_id': worker['native_agent_id'], 'reason': worker['retire_reason'],
                    'note': 'Stop reusing this native worker; acknowledge actual native completion/closure, then re-read real free slots.'}
    invalid = [p['id'] for p in m['packages'] if p['status'] == 'invalid']
    if invalid: return {'next_action': 'root_correction', 'package_ids': invalid,
                        'note': 'Existing retry-visual / import-results --refresh rules apply; no automatic retry.'}
    ready = ordered_ready(m, claims)
    for worker in workers.values():
        if worker['status'] != 'idle': continue
        candidates = ordered_ready(m, claims, worker['directory'], worker['last_source_id'])
        if not candidates: continue
        if candidates[0]['archive_directory'] != worker['directory']:
            worker.update(status='retire_required', retire_reason='archive_directory_changed')
            return {'next_action': 'retire_worker', 'worker_id': worker['id'],
                    'native_agent_id': worker['native_agent_id'], 'reason': worker['retire_reason']}
        contract = _contract(m, args)
        previous = ledger['groups'][next(g for g in reversed(ledger['groups']) if ledger['groups'][g]['worker_id'] == worker['id'])]['native_contract']
        if _route_identity(contract) != _route_identity(previous):
            worker.update(status='retire_required', retire_reason='native_route_or_session_changed')
            return {'next_action': 'retire_worker', 'worker_id': worker['id'],
                    'native_agent_id': worker['native_agent_id'], 'reason': worker['retire_reason']}
        worker['status'] = 'pending_followup'
        group = _new_group(root, ledger, claims, take_group(candidates), worker, contract)
        return {'next_action': 'followup', **_task(group, worker)}
    unfinished = {p['id'] for p in m['packages'] if p['status'] != 'success'}
    legacy_workers = {c['worker'] for pid, c in claims.items() if pid in unfinished and not c.get('group_id')}
    active = sum(w['status'] != 'retired' for w in workers.values()) + len(legacy_workers)
    capacity = min(6, m['config'].get('vision_concurrency', 2)) - active
    if ready and capacity > 0 and args.available_workers > args.reserve_sol:
        contract = _contract(m, args)
        wid = 'visual-worker-' + str(ledger['next_worker']).zfill(6); ledger['next_worker'] += 1
        worker = {'id': wid, 'native_agent_id': None, 'completed_groups': 0, 'status': 'pending_bind'}
        workers[wid] = worker
        group = _new_group(root, ledger, claims, take_group(ready), worker, contract)
        return {'next_action': 'spawn', **_task(group, worker)}
    if unfinished or ready or any(w['status'] == 'running' for w in workers.values()):
        return {'next_action': 'wait', 'running_native_agent_ids': [w['native_agent_id'] for w in workers.values()
                if w['status'] == 'running'], 'legacy_claims': sorted(pid for pid in claims if pid in unfinished),
                'active_groups': [_task(ledger['groups'][w['group_id']], w) for w in workers.values()
                                  if w['status'] == 'running' and w.get('group_id')],
                'reason': 'owned_work_or_actual_native_slots', 'unassigned_original_packages': len(ready)}
    for worker in workers.values():
        if worker['status'] == 'idle':
            worker.update(status='retire_required', retire_reason='visual_queue_drained')
            return {'next_action': 'retire_worker', 'worker_id': worker['id'],
                    'native_agent_id': worker['native_agent_id'], 'reason': worker['retire_reason']}
    return {'next_action': 'visual_complete',
            'note': 'Visual packages complete; independent semantic, geography and ROOT gates still apply.'}
