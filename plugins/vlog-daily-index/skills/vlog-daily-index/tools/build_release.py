"""Build a small, deterministic source Skill archive; no runtime or user runs."""
from __future__ import annotations
import argparse
import hashlib
import json
import re
from pathlib import Path
import zipfile


def sha(data): return hashlib.sha256(data).hexdigest()


def selected_files(root):
    exact = {'SKILL.md', 'VERSION', 'requirements.lock', 'requirements-dev.txt'}
    suffixes = {'scripts': {'.py'}, 'tests': {'.py'}, 'tools': {'.py'},
                'references': {'.md'}, 'agents': {'.yaml'}}
    files = []
    for path in root.rglob('*'):
        if not path.is_file(): continue
        relative = path.relative_to(root)
        if any(part.startswith('.') or part == '__pycache__' for part in relative.parts): continue
        if str(relative).replace('\\', '/') in exact or (len(relative.parts) > 1 and
                path.suffix in suffixes.get(relative.parts[0], set())):
            if path.is_symlink(): raise ValueError('Refuse linked package source: ' + str(relative))
            files.append(path)
    if not exact <= {str(path.relative_to(root)).replace('\\', '/') for path in files}:
        raise ValueError('Required root files are missing')
    return sorted(files, key=lambda path: path.relative_to(root).as_posix())


def build(root, output):
    root = root.resolve(); output = output.resolve()
    if root == output or root in output.parents: raise ValueError('Distribution must be outside the Skill source')
    version = (root / 'VERSION').read_text(encoding='utf-8').strip()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version): raise ValueError('VERSION must be a numeric semantic version')
    files = {path.relative_to(root).as_posix(): path.read_bytes() for path in selected_files(root)}
    manifest = {'name': root.name, 'version': version, 'format': 'source-skill-zip',
                'hash_algorithm': 'SHA256', 'manifest_self_excluded': True,
                'files': {name: {'bytes': len(data), 'sha256': sha(data)} for name, data in files.items()}}
    files['release-manifest.json'] = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f'{root.name}-{version}.zip'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as result:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(root.name + '/' + name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED; entry.external_attr = 0o100644 << 16
            result.writestr(entry, data)
    checksum = sha(archive.read_bytes())
    (output / (archive.name + '.sha256')).write_text(checksum + '  ' + archive.name + '\n', encoding='ascii')
    (output / (root.name + '-' + version + '-manifest.json')).write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return {'archive': str(archive), 'sha256': checksum, 'source_files': len(files) - 1,
            'archive_bytes': archive.stat().st_size}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(build(Path(__file__).resolve().parents[1], args.output), ensure_ascii=False, indent=2))
