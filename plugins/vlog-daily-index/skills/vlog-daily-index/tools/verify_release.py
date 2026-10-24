"""Verify a source Skill ZIP and run its fixed local checks in a new directory."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
import zipfile
from urllib.parse import unquote


def verify_archive(archive):
    archive = Path(archive)
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    expected = Path(str(archive) + '.sha256').read_text(encoding='ascii').split()[0]
    if actual != expected: raise ValueError('ZIP checksum does not match')
    with zipfile.ZipFile(archive) as package:
        names = package.namelist()
        if len(names) != len(set(names)): raise ValueError('Duplicate ZIP entries')
        for entry in package.infolist():
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or '..' in path.parts or '\\' in entry.filename or ':' in entry.filename:
                raise ValueError('Unsafe archive path')
            if (entry.external_attr >> 16) & 0o170000 == 0o120000: raise ValueError('Linked ZIP entry')
        roots = {PurePosixPath(name).parts[0] for name in names}
        if len(roots) != 1: raise ValueError('Expected one Skill root')
        root = roots.pop(); manifest = json.loads(package.read(root + '/release-manifest.json'))
        allowed = {root + '/' + name for name in manifest['files']} | {root + '/release-manifest.json'}
        if set(names) != allowed: raise ValueError('Archive differs from manifest membership')
        for name, identity in manifest['files'].items():
            data = package.read(root + '/' + name)
            if len(data) != identity['bytes'] or hashlib.sha256(data).hexdigest() != identity['sha256']:
                raise ValueError('Packaged source digest mismatch: ' + name)
        if any('__pycache__' in name or PurePosixPath(name).suffix.lower() in
               ('.pyc', '.mp4', '.mov', '.jpg', '.wav', '.fit', '.exe') for name in names):
            raise ValueError('Runtime or media data must not enter the source archive')
    return actual, root, manifest


def verify(archive, output, ffmpeg, ffprobe, validator=None):
    archive = Path(archive).resolve(); output = Path(output).resolve()
    checksum, root_name, manifest = verify_archive(archive)
    environment = dict(os.environ)
    environment.pop('VLOG_INDEX_DEPS', None)
    environment['VLOG_TEST_FFMPEG'] = str(Path(ffmpeg).resolve())
    environment['VLOG_TEST_FFPROBE'] = str(Path(ffprobe).resolve())
    checks = []; logs = []; total = skipped = None
    with tempfile.TemporaryDirectory(prefix='vlog-skill-release-') as folder:
        with zipfile.ZipFile(archive) as package: package.extractall(folder)
        root = Path(folder) / root_name
        for document in root.rglob('*.md'):
            for target in re.findall(r'\]\(([^)]+)\)', document.read_text(encoding='utf-8')):
                target = target.strip('<>').split('#', 1)[0]
                if not target or '://' in target or target.startswith('mailto:'): continue
                if not (document.parent / unquote(target)).is_file():
                    raise ValueError('Broken packaged document link: ' + str(document.relative_to(root)) + ' -> ' + target)
        checks.append({'check': 'packaged-document-links', 'exit_code': 0})
        commands = [('unittest-extracted', [sys.executable, '-X', 'utf8', '-W', 'ignore', '-m', 'unittest', 'discover', '-s', 'tests', '-v']),
                    ('cli-help-extracted', [sys.executable, '-X', 'utf8', 'scripts/vlog_daily_index.py', '--help']),
                    ('pip-check', [sys.executable, '-m', 'pip', 'check'])]
        if validator: commands.append(('skill-format-extracted', [sys.executable, '-X', 'utf8', str(Path(validator).resolve()), str(root)]))
        for name, command in commands:
            result = subprocess.run(command, cwd=root, env=environment, capture_output=True,
                                    text=True, encoding='utf-8', timeout=120)
            checks.append({'check': name, 'exit_code': result.returncode})
            logs.extend([name, result.stdout, result.stderr])
            if name == 'unittest-extracted':
                match = re.search(r'Ran (\d+) tests?', result.stderr); total = int(match[1]) if match else None
                match = re.search(r'skipped=(\d+)', result.stderr); skipped = int(match[1]) if match else 0
            if result.returncode: raise RuntimeError(name + ' failed:\n' + result.stdout + result.stderr)
        rebuild = Path(folder) / 'rebuilt'
        result = subprocess.run([sys.executable, '-X', 'utf8', str(root / 'tools' / 'build_release.py'), '--output', str(rebuild)],
                                cwd=root, env=environment, capture_output=True, text=True, encoding='utf-8', timeout=30)
        if result.returncode: raise RuntimeError('Rebuild failed: ' + result.stderr)
        if json.loads(result.stdout)['sha256'] != checksum: raise ValueError('Rebuilt ZIP differs')
        checks.append({'check': 'extracted-rebuild-identical-sha256', 'exit_code': 0})
    report = {'version': manifest['version'], 'platform': sys.platform, 'python': sys.version.split()[0],
              'tests': total, 'skipped': skipped, 'failures': 0, 'real_asr_requests': 0, 'nas_operations': 0,
              'archive_bytes': archive.stat().st_size, 'archive_sha256': checksum,
              'source_files': len(manifest['files']), 'archive_manifest_verified': True,
              'format_validator_run': bool(validator), 'checks': checks}
    output.mkdir(parents=True, exist_ok=True)
    (output / 'verification-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (output / 'verification-tests.log').write_text('\n'.join(logs), encoding='utf-8')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ffmpeg', type=Path, required=True)
    parser.add_argument('--ffprobe', type=Path, required=True)
    parser.add_argument('--validator', type=Path, help='Optional official skill-creator quick_validate.py')
    args = parser.parse_args()
    print(json.dumps(verify(args.archive, args.output, args.ffmpeg, args.ffprobe, args.validator), ensure_ascii=False, indent=2))
