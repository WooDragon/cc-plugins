#!/usr/bin/env python3
"""DIT bookkeeping only. Python 3.10+, standard library; never copies media."""
import argparse
import csv
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import tempfile

FIELDS = '路径 原名 来源 大小 SHA256 校验 状态 配套 关联 备注'.split()


def require(ok, message):
    if not ok:
        raise ValueError(message)


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def save_json(path, data):
    # Never overwrite a manifest/plan left by a prior run.
    with Path(path).open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2)
        stream.write('\n')


def digest(data):
    return hashlib.sha256(data).hexdigest()  # Small metadata only, not media.


def key(path):
    return os.path.normcase(str(Path(path).resolve()))


def relative(root, value):
    require(isinstance(value, str) and value, 'Empty relative path')
    parts = value.split('/')
    require(not PurePosixPath(value).is_absolute() and
            all(p not in ('', '.', '..') and not p.endswith((' ', '.')) for p in parts)
            and not any(c in value for c in '\\:*?"<>|\r\n\0'),
            f'Unsafe or noncanonical relative path: {value}')
    dest = root.joinpath(*parts).resolve()
    require(dest.is_relative_to(root.resolve()), f'Path escapes root: {value}')
    return dest


def snapshot(root):
    root = Path(root).resolve(strict=True)
    require(root.is_dir(), 'Snapshot root must be a directory')
    def scan_error(error):
        raise error
    files = {}
    for base, directories, names in os.walk(root, onerror=scan_error):
        for name in directories + names:
            p = Path(base, name)
            require(not p.is_symlink() and not (getattr(p.lstat(), 'st_file_attributes', 0) & 1024)
                    and p.resolve().is_relative_to(root),
                    f'Linked path not supported: {p}')
        for name in names:
            p = Path(base, name)
            s = p.stat()
            files[p.relative_to(root).as_posix()] = {'size': s.st_size, 'mtime_ns': s.st_mtime_ns}
    return {'version': 1, 'root': str(root), 'files': dict(sorted(files.items()))}


def verify_snapshot(path):
    previous = read_json(path)
    require(snapshot(previous['root']) == previous, 'Source files/size/mtime changed')
    return {'unchanged_files': len(previous['files'])}


def verify_fastcopy(log_path, manifest, exit_code):
    require(exit_code == 0, 'FastCopy exit code is not zero')
    text = Path(log_path).read_text(encoding='utf-8-sig')
    require(len(re.findall(r'^fcp\(ver', text, re.M)) == 1,
            'Use one complete, unappended FastCopy 4.2.1 file log per receipt')
    require('fcp(ver4.2.1)' in text and '(with Verify)' in text, 'Unsupported log version/mode')
    results = re.findall(r'Result\s*:\s*\(ErrFiles\s*:\s*(\d+)\s*/\s*ErrDirs\s*:\s*(\d+)\)', text)
    require(results == [('0', '0')], 'Missing/failed completion summary')
    counts = [int(value.replace(',', '')) for value in re.findall(
        r'^VerifyFiles\s*=\s*(\d{1,3}(?:,\d{3})+|\d+)\s*$', text, re.M)]
    expected = {}
    for item in manifest:
        require(Path(item['path']).is_absolute(), 'Manifest paths must be absolute')
        k = key(item['path'])
        require(k not in expected, 'Duplicate manifest destination')
        require(type(item['size']) is int and item['size'] >= 0, 'Invalid manifest size')
        expected[k] = item
    require(counts == [len(expected)] and expected, 'Verified count does not match manifest')
    entries = {}
    pattern = r'^\+ (.+?)\s+<\d{8}-\d{6}\s+([\d,]+) sha256=([a-fA-F0-9]{64})>\s*$'
    for match in re.finditer(pattern, text, re.M):
        path, size, sha = match.groups()
        k = key(path)
        require(k not in entries, 'Duplicate verification record')
        entries[k] = {'path': str(Path(path).resolve()), 'size': int(size.replace(',', '')),
                      'sha256': sha.upper()}
    require(entries.keys() == expected.keys(), 'Missing/extra SHA-256 records (skips are not verification)')
    for k, entry in entries.items():
        require(entry['size'] == expected[k]['size'], 'Log size differs from manifest')
        stat = Path(entry['path']).stat()
        require(stat.st_size == entry['size'], 'Verified file has changed size')
        entry['mtime_ns'] = stat.st_mtime_ns
    return {'version': 1, 'kind': 'fastcopy-sha256', 'log_sha256': digest(text.encode()),
            'files': list(entries.values())}


def read_csv(raw):
    reader = csv.DictReader(io.StringIO(raw.decode('utf-8-sig'), newline=''))
    require(reader.fieldnames == FIELDS, 'Unsupported index schema: adapt the shared tool, do not silently migrate')
    rows = list(reader)
    require(all(set(r) == set(FIELDS) and all(isinstance(v, str) for v in r.values()) for r in rows), 'Malformed CSV')
    return rows


def csv_bytes(rows):
    buf = io.StringIO(newline='')
    writer = csv.DictWriter(buf, FIELDS, lineterminator='\r\n')
    writer.writeheader()
    writer.writerows(rows)
    return buf.getvalue().encode('utf-8-sig')


def validate_rows(root, rows, touched, separator=None):
    paths = set()
    for number, row in enumerate(rows):
        require(set(row) == set(FIELDS) and all(isinstance(v, str) for v in row.values()), 'Invalid row fields')
        path = row['路径']
        if path:
            dest = relative(root, path)
            k = key(dest)
            require(k not in paths, f'Duplicate indexed path: {path}')
            paths.add(k)
        if number not in touched:
            continue
        require(not row['SHA256'] or re.fullmatch(r'[a-fA-F0-9]{64}', row['SHA256']), 'Invalid SHA256')
        require(not row['来源'] or row['来源'].startswith(('卡:', '素材:')), 'Unknown source prefix')
        if row['来源']:
            relative(root, row['来源'].split(':', 1)[1])  # Syntax only; source need not exist here.
        if path:
            require(row['大小'].isdigit() and dest.is_file() and dest.stat().st_size == int(row['大小']),
                    f'Current file missing/size mismatch: {path}')
        if re.search(r'SHA.?256|哈希一致', row['校验'], re.I):
            require(bool(row['SHA256']), 'Hash verification claim requires SHA256')
        for field in ('配套', '关联'):
            for ref in (row[field].split(separator) if separator else [row[field]]):
                if ref:
                    target = relative(root, ref)
                    require(target.exists(), f'Missing {field}: {ref}')


def check_evidence(root, operation, before, after):
    if not after['SHA256']:
        require(not before or not before['SHA256'], 'Do not discard a historical hash')
        return
    if before and all(before[f] == after[f] for f in ('大小', 'SHA256', '校验')):
        return  # Historical verification retained; this is not a new hash comparison.
    proof = operation.get('evidence')
    require(proof, 'New/changed SHA256 or verification claim requires a verified receipt')
    receipt = read_json(proof['receipt'])
    require(receipt.get('kind') == 'fastcopy-sha256', 'Unsupported evidence type')
    candidates = [f for f in receipt['files'] if key(f['path']) == key(proof['path'])]
    require(len(candidates) == 1, 'Receipt path missing or duplicated')
    entry = candidates[0]
    require(entry['sha256'].upper() == after['SHA256'].upper() and entry['size'] == int(after['大小']),
            'Receipt hash/size does not match indexed file')
    require(after['路径'] and relative(root, after['路径']).stat().st_mtime_ns == entry['mtime_ns'],
            'Current file timestamp differs from verified receipt')


def merge(root, rows, operations, separator=None):
    result = [dict(r) for r in rows]
    touched, used, moves = set(), set(), {}
    for operation in operations:
        before, after = operation['before'], operation['after']
        require(set(after) == set(FIELDS), 'Provide a complete after row')
        if before is None:
            if after in result:
                continue  # Exact re-application is harmless.
            target = len(result)
        else:
            found = [i for i, r in enumerate(rows) if r == before]
            require(len(found) == 1, 'Expected before row missing/ambiguous; re-read index')
            target = found[0]
            require(target not in used, 'Multiple edits to one row')
            used.add(target)
            require(all(before[f] == after[f] for f in ('原名', '来源')), 'Historical original/source must remain unchanged')
            if before['路径'] != after['路径']:
                require(before['路径'] and not relative(root, before['路径']).exists(),
                        'Complete the authorized media move/removal before changing index')
                moves[before['路径']] = after['路径']
                require(before['大小'] == after['大小'], 'Move/removal cannot change recorded size')
        check_evidence(root, operation, before, after)
        if target == len(result):
            result.append(dict(after))
        else:
            result[target] = dict(after)
        touched.add(target)
    for i, row in enumerate(result):
        for field in ('配套', '关联'):
            refs = row[field].split(separator) if separator else [row[field]]
            replaced = [moves.get(r, r) for r in refs]
            if replaced != refs:
                row[field] = separator.join(replaced) if separator else replaced[0]
                touched.add(i)
    validate_rows(root, result, touched, separator)
    return result, touched


def make_plan(root, index, operations, separator=None):
    root, index = Path(root).resolve(strict=True), Path(index).resolve(strict=True)
    require(index.is_relative_to(root), 'Index must reside within library root')
    original = index.read_bytes()
    rows, touched = merge(root, read_csv(original), operations, separator)
    return {'version': 1, 'root': str(root), 'index': str(index), 'separator': separator,
            'base_sha256': digest(original), 'result_sha256': digest(csv_bytes(rows)),
            'operations': operations, 'affected_rows': len(touched), 'total_rows': len(rows)}


def apply_plan(plan):
    root, index = Path(plan['root']).resolve(strict=True), Path(plan['index']).resolve(strict=True)
    require(index.is_relative_to(root), 'Index outside root')
    lock = index.with_name('.' + index.name + '.dit-lock')
    # Cooperating writers lock the same index. Unrelated programs must not edit it during publication.
    with lock.open('x', encoding='utf-8') as stream:
        stream.write(str(os.getpid()))
    temp = None
    try:
        raw = index.read_bytes()
        if digest(raw) == plan['result_sha256']:
            return {'already_applied': True}
        require(digest(raw) == plan['base_sha256'], 'Index changed since planning; regenerate plan')
        rows, touched = merge(root, read_csv(raw), plan['operations'], plan.get('separator'))
        result = csv_bytes(rows)
        require(digest(result) == plan['result_sha256'], 'Plan no longer reproducible')
        fd, name = tempfile.mkstemp(prefix='.' + index.name + '.', suffix='.tmp', dir=index.parent)
        temp = Path(name)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(result)
            stream.flush()
            os.fsync(stream.fileno())
        require(read_csv(temp.read_bytes()) == rows, 'CSV roundtrip failed')
        validate_rows(root, rows, touched, plan.get('separator'))
        require(index.read_bytes() == raw, 'Concurrent change detected; index not overwritten')
        os.replace(temp, index)
        require(index.read_bytes() == result, 'Published index changed unexpectedly')
        return {'affected_rows': len(touched), 'total_rows': len(rows)}
    finally:
        if temp is not None and temp.exists():
            temp.unlink()
        lock.unlink()


def file_identity(path):
    stat = path.stat()
    return {'size': stat.st_size, 'mtime_ns': stat.st_mtime_ns,
            'device': stat.st_dev, 'inode': stat.st_ino}


def scoped(root, value):
    p = Path(value)
    require(p.is_absolute(), 'Relocation paths must be absolute')
    require(not p.is_symlink(), 'Symlink media is not supported')
    resolved = p.resolve()
    require(resolved.is_relative_to(root) and resolved != root, 'Relocation escapes library root')
    relative(root, p.relative_to(root).as_posix())
    return resolved


def relocation_plan(root, mapping, receipt=None):
    root = Path(root).resolve(strict=True)
    proof = {}
    if receipt:
        data = read_json(receipt)
        require(data.get('kind') == 'fastcopy-sha256', 'Unsupported receipt')
        proof = {key(f['path']): f for f in data['files']}
        require(len(proof) == len(data['files']), 'Duplicate receipt path')
    entries, sources, targets = [], set(), set()
    for item in mapping:
        src, dest = scoped(root, item['source']), scoped(root, item['destination'])
        require(src.is_file() and not dest.exists(), 'Source missing or destination already exists')
        identity = file_identity(src)
        require(key(src) not in sources and key(dest) not in targets, 'Duplicate relocation path')
        sources.add(key(src)); targets.add(key(dest))
        ancestor = dest.parent
        while not ancestor.exists(): ancestor = ancestor.parent
        require(src.anchor.casefold() == dest.anchor.casefold() and
                identity['device'] == ancestor.stat().st_dev, 'Cross-volume/share relocation forbidden')
        if receipt:
            verified = proof.get(key(src))
            require(verified and all(verified[k] == identity[k] for k in ('size', 'mtime_ns')),
                    'Receipt missing or staged file changed')
        entries.append({'source': str(src), 'destination': str(dest), 'identity': identity})
    require(not sources.intersection(targets), 'Overlapping/cyclic relocations are not supported')
    require(entries, 'Empty relocation mapping')
    return {'version': 1, 'kind': 'same-volume-relocation', 'root': str(root), 'files': entries}


def relocation_state(root, entry):
    src, dest = scoped(root, entry['source']), scoped(root, entry['destination'])
    expected = entry['identity']
    if src.exists():
        require(src.is_file() and file_identity(src) == expected, 'Source changed since planning')
        if dest.exists():
            require(dest.samefile(src), 'Destination conflict; no overwrite')
            return src, dest, 'linked'
        ancestor = dest.parent
        while not ancestor.exists(): ancestor = ancestor.parent
        require(src.anchor.casefold() == dest.anchor.casefold() and
                ancestor.stat().st_dev == expected['device'], 'Cross-volume move forbidden')
        return src, dest, 'pending'
    require(dest.is_file() and file_identity(dest) == expected,
            'Neither original nor matching relocated file exists; inspect manually')
    return src, dest, 'complete'


def apply_relocation(plan, plan_path):
    require(plan.get('kind') == 'same-volume-relocation', 'Wrong relocation plan')
    root = Path(plan['root']).resolve(strict=True)
    entries = plan['files']
    sources = [key(e['source']) for e in entries]
    targets = [key(e['destination']) for e in entries]
    require(len(set(sources)) == len(entries) == len(set(targets)) and
            not set(sources).intersection(targets), 'Duplicate/overlapping relocation paths')
    lock = Path(str(plan_path) + '.lock')
    with lock.open('x', encoding='utf-8') as stream: stream.write(str(os.getpid()))
    try:
        for entry in entries: relocation_state(root, entry)  # Full preflight before mutation.
        moved = 0
        for entry in entries:
            src, dest, state = relocation_state(root, entry)
            if state == 'complete': continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            src, dest, state = relocation_state(root, entry)
            if state == 'pending':
                if os.name == 'nt':
                    os.rename(src, dest)  # Windows fails when destination exists; never copies.
                else:
                    # Atomic no-clobber creation; restart handles an interruption before unlink.
                    os.link(src, dest, follow_symlinks=False)
                    src.unlink()
            elif state == 'linked': src.unlink()
            require(file_identity(dest) == entry['identity'] and not src.exists(), 'Relocation postcheck failed')
            moved += 1
        return {'moved': moved, 'complete': len(entries)}
    finally:
        lock.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('snapshot'); p.add_argument('--root', required=True); p.add_argument('--out', required=True)
    p = sub.add_parser('check-source'); p.add_argument('--snapshot', required=True)
    p = sub.add_parser('verify-fastcopy')
    for arg in ('log', 'manifest', 'out'): p.add_argument('--' + arg, required=True)
    p.add_argument('--exit-code', required=True, type=int)
    p = sub.add_parser('index-plan')
    for arg in ('root', 'index', 'changes', 'out'): p.add_argument('--' + arg, required=True)
    p.add_argument('--separator', help='Only supply the separator already used by this library')
    p = sub.add_parser('index-apply'); p.add_argument('--plan', required=True)
    p = sub.add_parser('index-check'); p.add_argument('--root', required=True); p.add_argument('--index', required=True); p.add_argument('--separator')
    p = sub.add_parser('relocate-plan')
    for arg in ('root', 'mapping', 'out'): p.add_argument('--' + arg, required=True)
    p.add_argument('--receipt')
    p = sub.add_parser('relocate-apply'); p.add_argument('--plan', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'snapshot':
            data = snapshot(args.root); save_json(args.out, data); result = {'files': len(data['files'])}
        elif args.command == 'check-source': result = verify_snapshot(args.snapshot)
        elif args.command == 'verify-fastcopy':
            data = verify_fastcopy(args.log, read_json(args.manifest), args.exit_code)
            save_json(args.out, data); result = {'verified_files': len(data['files'])}
        elif args.command == 'index-plan':
            data = make_plan(args.root, args.index, read_json(args.changes), args.separator)
            save_json(args.out, data); result = {k: data[k] for k in ('affected_rows', 'total_rows')}
        elif args.command == 'index-apply': result = apply_plan(read_json(args.plan))
        elif args.command == 'relocate-plan':
            data = relocation_plan(args.root, read_json(args.mapping), args.receipt)
            save_json(args.out, data); result = {'planned_files': len(data['files'])}
        elif args.command == 'relocate-apply': result = apply_relocation(read_json(args.plan), args.plan)
        else:
            rows = read_csv(Path(args.index).read_bytes())
            validate_rows(Path(args.root).resolve(strict=True), rows, set(range(len(rows))), args.separator)
            result = {'checked_rows': len(rows)}
        print(json.dumps(result, ensure_ascii=False))
    except (ValueError, OSError, KeyError, TypeError) as exc:
        parser.exit(1, f'ERROR: {exc}\n')


if __name__ == '__main__':
    main()
