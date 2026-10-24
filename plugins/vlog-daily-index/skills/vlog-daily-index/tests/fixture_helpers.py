"""Small preconditions for publication unit tests, unrelated to source media."""
from vlog_index import analysis
from vlog_index.store import digest
from vlog_index.store import dump
from pathlib import Path


def final_context(manifest, state_dir):
    manifest['state_dir'] = str(state_dir)
    daily = {'summary': 'Synthetic empty-run publication fixture', 'summary_evidence_ids': [], 'events': [], 'interest_points': []}
    itinerary = {'title': 'Synthetic fixture route', 'source_refs': [
        {'id': 's', 'kind': 'local', 'reference': 'synthetic-fixture', 'excerpt': 'Fixture route'}],
        'entries': [{'id': 'r', 'date': None, 'place': 'Fixture region', 'source_refs': ['s']}]}
    manifest['itinerary'] = {'data': itinerary, 'sha256': digest(itinerary)}
    manifest['map_evidence'] = {'records': [], 'sha256': digest([])}
    manifest['geography_package'] = {'package_id': 'empty-fixture'}
    data = {'package_id': 'empty-fixture', 'associations': []}
    manifest['geography'] = {'data': data, 'sha256': digest(data), 'package_id': 'empty-fixture',
                             'input_digests': analysis.geography_bindings(manifest, daily)}
    return daily


def root_review(manifest, daily):
    package = {'package_id': 'synthetic-root-review', 'input_digests': analysis.final_review_bindings(manifest, daily)}
    path = Path(manifest['state_dir']) / 'synthetic-review.package.json'; dump(path, package)
    manifest['final_review_package'] = {'package_id': package['package_id'], 'path': str(path)}
    return {'reviewer': 'ROOT', 'package_id': package['package_id'], 'conclusion': 'approved',
            'reason': 'Synthetic empty-media fixture reviewed for publication boundary tests',
            'checked_dimensions': sorted(analysis.REVIEW_DIMENSIONS), 'issues': [], 'remaining_unknowns': [], 'blocking_remaining': 0}
