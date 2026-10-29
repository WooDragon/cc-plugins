"""Read-only historical package grouping; no native Agents, results or media reads."""
from __future__ import annotations
import argparse
from collections import Counter
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from vlog_index.store import read, dump, file_hash
from vlog_index.vision_work import package_info, take_group, TARGET_IMAGES, GROUPS_PER_WORKER


def replay(manifests, output):
    output = Path(output).resolve()
    if output.exists(): raise ValueError('Use a new isolated output directory')
    groups = []; runs = []; identities = {}; total_workers = 0; source_count = 0
    for manifest_path in map(Path, manifests):
        m = read(manifest_path)
        for protected in (manifest_path.parent, Path(m['state_dir']), Path(m['temp_dir'])):
            protected = protected.resolve()
            if output == protected or protected in output.parents:
                raise ValueError('Offline replay output must be outside original state/temp')
        identities[manifest_path] = file_hash(manifest_path)
        rank = {s['id']: i for i, s in enumerate(m['sources'])}
        ready = []
        for p in m['packages']:
            identities[Path(p['path'])] = file_hash(p['path'])
            ready.append(package_info(m, p))
        ready.sort(key=lambda p: (rank.get(p['source_id'], len(rank)), p['start'], p['package_id']))
        expected = Counter(p['package_id'] for p in ready); covered = Counter()
        worker = None; worker_groups = 0; previous_source = None; previous_dir = None
        run_groups = []; workers = set()
        while ready:
            if worker is None:
                total_workers += 1; worker = f'SIMULATED-worker-{total_workers:06}'; worker_groups = 0
            elif worker_groups >= GROUPS_PER_WORKER or not any(p['archive_directory'] == previous_dir for p in ready):
                worker = None; continue
            if worker_groups:
                ready.sort(key=lambda p: (p['source_id'] != previous_source,
                    p['archive_directory'] != previous_dir, rank.get(p['source_id'], len(rank)),
                    p['start'], p['package_id']))
            members = take_group(ready)
            if worker_groups and members[0]['archive_directory'] != previous_dir:
                worker = None; continue
            worker_groups += 1; workers.add(worker)
            group = {'run_id': m['run_id'], 'group_number': len(run_groups)+1,
                'simulation_worker': worker, 'worker_group_number': worker_groups,
                'presented_images': sum(p['presented_images'] for p in members), 'members': members}
            run_groups.append(group); groups.append(group)
            chosen = {p['package_id'] for p in members}; covered.update(chosen)
            ready = [p for p in ready if p['package_id'] not in chosen]
            previous_source = members[-1]['source_id']; previous_dir = members[0]['archive_directory']
        if expected != covered or any(n != 1 for n in covered.values()):
            raise ValueError('Original-package coverage mismatch')
        actual_sources = {p['source_id'] for g in run_groups for p in g['members']}
        source_count += len(m['sources'])
        runs.append({'run_id': m['run_id'], 'sources': len(m['sources']),
            'sources_with_packages': len(actual_sources), 'original_packages': sum(expected.values()),
            'existing_successful_packages': sum(p['status']=='success' for p in m['packages']),
            'groups': len(run_groups), 'simulated_workers': len(workers),
            'all_original_packages_once': expected == covered,
            'presented_images': sum(g['presented_images'] for g in run_groups)})
    if any(file_hash(path) != value for path, value in identities.items()):
        raise ValueError('Input metadata changed during replay')
    per_worker = Counter(g['simulation_worker'] for g in groups)
    if any(n > GROUPS_PER_WORKER for n in per_worker.values()): raise ValueError('Worker group bound exceeded')
    if any(len({p['archive_directory'] for p in g['members']}) != 1 for g in groups): raise ValueError('Cross-directory group')
    if any(g['presented_images'] > TARGET_IMAGES and len(g['members']) != 1 for g in groups): raise ValueError('Multi-package group exceeds target')
    report = {'mode': 'metadata_only_simulation_not_native_execution', 'model_calls': 0,
        'image_reads': 0, 'observation_results_written': 0, 'original_state_writes': 0,
        'original_input_hashes_unchanged': True, 'source_count': source_count,
        'original_package_count': sum(r['original_packages'] for r in runs),
        'group_count': len(groups), 'simulated_worker_count': total_workers,
        'presented_images': sum(g['presented_images'] for g in groups),
        'multi_source_groups': sum(len({p['source_id'] for p in g['members']}) > 1 for g in groups),
        'oversize_whole_package_groups': sum(g['presented_images']>TARGET_IMAGES for g in groups),
        'all_original_packages_once': all(r['all_original_packages_once'] for r in runs),
        'max_groups_per_simulated_worker': max(per_worker.values(), default=0), 'runs': runs,
        'limits': 'Historical metadata replay measures grouping only, not visual quality, actual native lifecycle, latency or account usage savings.'}
    dump(output / 'groups.json', groups); dump(output / 'report.json', report)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    import json
    print(json.dumps(replay(args.manifest, args.output), ensure_ascii=False, indent=2))
