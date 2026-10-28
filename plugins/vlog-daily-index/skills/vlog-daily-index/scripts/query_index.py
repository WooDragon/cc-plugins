"""Optional, rebuildable DuckDB cache for explicit DIT and published day indexes."""
from __future__ import annotations
import argparse
import csv
import datetime as dt
import fnmatch
import hashlib
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import sys

from vlog_index.store import NAMING_INDEX_COLUMNS, digest, publication_snapshot, read

TABLES = ('dit', 'sources', 'findings', 'clips', 'transcripts')


def canonical_relative(value):
    if not isinstance(value, str) or not value:
        raise ValueError('Expected a nonempty relative POSIX path')
    parts = value.split('/')
    if (PurePosixPath(value).is_absolute() or any(p in ('', '.', '..') or p.endswith((' ', '.')) for p in parts)
            or any(c in value for c in '\\:*?"<>|\r\n\0')):
        raise ValueError('Unsafe or noncanonical relative path: ' + value)
    return value


def within(root, value):
    path = (root / canonical_relative(value)).resolve()
    if not path.is_relative_to(root):
        raise ValueError('Path escapes library root: ' + value)
    return path


def path_key(value):
    return os.path.normcase(value)


def connect(path, readonly=False):
    try:
        import duckdb
    except ImportError as exc:
        raise RuntimeError('Query mode needs only the optional requirements-query.txt dependency') from exc
    path = Path(path)
    if readonly and not path.is_file():
        raise ValueError('Cache does not exist; run refresh first')
    if not readonly:
        path.parent.mkdir(parents=True, exist_ok=True)
    db = duckdb.connect(str(path), read_only=readonly)
    if readonly:
        if db.execute('SELECT version FROM cache_schema').fetchall() != [(1,)]:
            db.close(); raise ValueError('Unsupported cache schema; rebuild using a new cache file')
        return db
    try:
        db.execute('CREATE TABLE IF NOT EXISTS cache_schema(version INTEGER)')
        versions = db.execute('SELECT version FROM cache_schema').fetchall()
        if not versions:
            db.execute('INSERT INTO cache_schema VALUES (1)')
        elif versions != [(1,)]:
            raise ValueError('Unsupported cache schema; rebuild using a new cache file')
        db.execute('''CREATE TABLE IF NOT EXISTS snapshots(
            scope VARCHAR PRIMARY KEY, library VARCHAR, kind VARCHAR, location VARCHAR,
            digest VARCHAR, last_success VARCHAR, checked_at VARCHAR, stale BOOLEAN, error VARCHAR);
        CREATE TABLE IF NOT EXISTS dit(scope VARCHAR, row_no INTEGER, library VARCHAR,
            relative_path VARCHAR, path_key VARCHAR, original_name VARCHAR, status VARCHAR,
            notes VARCHAR, sha256 VARCHAR, data VARCHAR);
        CREATE TABLE IF NOT EXISTS sources(scope VARCHAR, source_id VARCHAR, library VARCHAR,
            relative_path VARCHAR, path_key VARCHAR, status VARCHAR, archival_date VARCHAR,
            run_id VARCHAR, revision INTEGER, data VARCHAR);
        CREATE TABLE IF NOT EXISTS findings(scope VARCHAR, finding_id VARCHAR, kind VARCHAR,
            title VARCHAR, reason VARCHAR, geography VARCHAR, data VARCHAR);
        CREATE TABLE IF NOT EXISTS clips(scope VARCHAR, finding_id VARCHAR, clip_no INTEGER,
            source_id VARCHAR, start_s DOUBLE, end_s DOUBLE, precision VARCHAR, evidence VARCHAR);
        CREATE TABLE IF NOT EXISTS transcripts(scope VARCHAR, source_id VARCHAR, segment_no INTEGER,
            start_s DOUBLE, end_s DOUBLE, precision VARCHAR, text VARCHAR, evidence VARCHAR, data VARCHAR);
        CREATE OR REPLACE VIEW media AS SELECT
            s.scope AS analysis_scope, d.scope AS dit_scope, s.source_id,
            coalesce(s.library,d.library) AS library, coalesce(s.relative_path,d.relative_path) AS relative_path,
            CASE WHEN coalesce(s.relative_path,d.relative_path)<>'' THEN
                coalesce(s.library,d.library)||'/'||coalesce(s.relative_path,d.relative_path) ELSE NULL END AS original_path,
            d.original_name, d.status AS dit_status, d.notes, d.sha256, d.data AS dit_data,
            s.status AS analysis_status, s.archival_date, s.run_id, s.revision, s.data AS source_data,
            coalesce(ds.stale,false) OR coalesce(ss.stale,false) AS stale,
            ds.last_success AS dit_last_success, ss.last_success AS analysis_last_success,
            ds.location AS dit_index, ss.location AS publication
        FROM sources s FULL OUTER JOIN dit d ON s.library=d.library AND s.path_key=d.path_key AND d.path_key<>''
        LEFT JOIN snapshots ss ON ss.scope=s.scope LEFT JOIN snapshots ds ON ds.scope=d.scope;
        CREATE OR REPLACE VIEW events AS SELECT f.*, p.library, p.location AS publication,
            p.stale, p.last_success FROM findings f JOIN snapshots p USING(scope);
        CREATE OR REPLACE VIEW segments AS SELECT f.kind,f.title,f.reason,f.geography,c.*,
            m.library,m.relative_path,m.original_path,m.archival_date,m.run_id,m.revision,
            m.dit_status,m.analysis_status,m.stale,m.analysis_last_success AS last_success,
            m.publication,m.dit_index,m.analysis_last_success,m.dit_last_success
        FROM clips c JOIN findings f USING(scope,finding_id)
        JOIN media m ON m.analysis_scope=c.scope AND m.source_id=c.source_id;
        CREATE OR REPLACE VIEW transcriptions AS SELECT t.*,m.library,m.relative_path,m.original_path,
            m.archival_date,m.run_id,m.revision,m.dit_status,m.analysis_status,m.stale,
            m.analysis_last_success AS last_success,
            m.publication,m.dit_index,m.analysis_last_success,m.dit_last_success
        FROM transcripts t JOIN media m ON m.analysis_scope=t.scope AND m.source_id=t.source_id;''')
    except Exception:
        db.close(); raise
    return db


def configured_units(config, known=()):
    if config.get('schema') != 1 or not isinstance(config.get('libraries'), list) or not config['libraries']:
        raise ValueError('Config requires schema=1 and a nonempty libraries list')
    units = []; roots = set(); locations = set()
    for library in config['libraries']:
        root = Path(library['root'])
        if not root.is_absolute(): raise ValueError('Library root must be absolute')
        root = root.resolve(); key = os.path.normcase(str(root))
        if key in roots: raise ValueError('Duplicate library root')
        roots.add(key)
        entries = [('dit', library['index'])] if library.get('index') else []
        pubs = list(library.get('publications', []))
        patterns = library.get('publication_globs', [])
        if not isinstance(patterns,list): raise ValueError('publication_globs must be a list')
        for pattern in patterns:
            if not isinstance(pattern,str) or '**' in pattern or len(pattern.split('/'))>5:
                raise ValueError('Use fixed-depth publication globs (at most five levels; no **)')
            canonical_relative(pattern.replace('*','x'))
            units.append((digest([key,'discovery',pattern]),root,'discovery',root/pattern))
            for old_library,old_kind,old_location in known:
                if old_library!=str(root) or old_kind!='publication': continue
                relative = Path(old_location).relative_to(root).as_posix()
                if len(relative.split('/'))==len(pattern.split('/')) and all(fnmatch.fnmatchcase(a,b) for a,b in zip(relative.split('/'),pattern.split('/'))):
                    pubs.append(relative)
            try:
                pubs.extend(p.relative_to(root).as_posix() for p in discover(root,pattern))
            except OSError:
                pass  # A discovery unit records the error; known days remain readable/stale.
        pubs = list(dict.fromkeys(pubs))
        if not isinstance(library.get('publications',[]),list): raise ValueError('publications must be a list of exact day directories')
        entries += [('publication', value) for value in pubs]
        if not entries and not patterns: raise ValueError('Library needs an index or publication directory')
        for kind, relative in entries:
            location = within(root, relative)
            if excluded(Path(relative)):
                raise ValueError('Use formal publication/index locations, excluding backup/revision/temp paths')
            identity = (key, os.path.normcase(str(location)))
            if identity in locations: raise ValueError('Duplicate input location')
            locations.add(identity)
            units.append((digest([key, kind, identity[1]]), root, kind, location))
    return units


def excluded(path):
    # Match directory labels/version suffixes, not words inside a travel theme
    # such as 历史博物馆. Explicit paths and discovery share this boundary.
    labels=r'(revisions?|backups?|history|archive|temp|tmp|修订|备份|临时|历史|历史备份|历史版本|修订版本)'
    return any(part.startswith('.') or re.search(r'(^|[_ -])'+labels+r'(?:[_ -]?\d+)?($|[_ -])',part,re.I)
               for part in path.parts)


def discover(root, pattern):
    current = [root]
    for component in pattern.split('/'):
        following = []
        for parent in current:
            with os.scandir(parent) as entries:
                for entry in entries:
                    if fnmatch.fnmatchcase(entry.name,component) and entry.is_dir(follow_symlinks=False):
                        candidate = Path(entry.path)
                        if candidate.is_symlink() or (hasattr(candidate,'is_junction') and candidate.is_junction()):
                            continue
                        if not candidate.resolve().is_relative_to(root): raise ValueError('Discovery path escapes library')
                        if not excluded(candidate.relative_to(root)):
                            following.append(candidate)
        current = following
    return sorted(current)


def dit_rows(root, location):
    raw = location.read_bytes()
    if not raw.startswith(b'\xef\xbb\xbf'): raise ValueError('DIT index must use UTF-8 BOM')
    reader = csv.DictReader(io.StringIO(raw.decode('utf-8-sig'), newline=''))
    if tuple(reader.fieldnames or ()) != NAMING_INDEX_COLUMNS: raise ValueError('Unsupported DIT index schema')
    rows = list(reader); seen = set()
    for row in rows:
        if None in row or any(value is None for value in row.values()): raise ValueError('Malformed DIT CSV row')
        relative = row['路径']
        if relative:
            within(root, relative); key = path_key(relative)
            if key in seen: raise ValueError('Duplicate current DIT path')
            seen.add(key)
        if row['SHA256'] and not re.fullmatch('[a-fA-F0-9]{64}', row['SHA256']): raise ValueError('Invalid DIT SHA256')
        if row['大小'] and not row['大小'].isdigit(): raise ValueError('Invalid DIT size')
    if location.read_bytes() != raw: raise ValueError('DIT index changed during read')
    return hashlib.sha256(raw).hexdigest(), rows


def json_text(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def interval(value):
    start, end = value['start'], value['end']
    if any(isinstance(n, bool) or not isinstance(n, (int, float)) or not math.isfinite(n) for n in (start, end)) or start < 0 or end < start:
        raise ValueError('Invalid clip/transcript interval')
    if value.get('precision') not in ('sampled_frames', 'decoded_frame_pts', 'chunk', 'service_segment'):
        raise ValueError('Unsupported clip/transcript precision')
    return start, end, value['precision']


def publication_rows(root, location):
    snap = publication_snapshot(location); index = snap['index']; transcript = snap['transcript']
    if index.get('archival_date') is not None:
        if not isinstance(index['archival_date'],str): raise ValueError('Invalid publication date')
        dt.date.fromisoformat(index['archival_date'])
    if index.get('status') not in ('complete', 'terminal_with_gaps') or transcript.get('status') != index['status']:
        raise ValueError('Publication is incomplete or statuses conflict')
    if not isinstance(index.get('sources'), list) or not isinstance(transcript.get('sources'), dict):
        raise ValueError('Unsupported publication source structure')
    sources = {}; paths = set()
    for source in index['sources']:
        if not isinstance(source,dict) or not isinstance(source.get('status'),str): raise ValueError('Invalid publication source')
        sid = source['id']
        if not isinstance(sid,str) or not sid or sid in sources: raise ValueError('Duplicate/invalid local source ID')
        relative_source=source['relative_path']
        if not isinstance(relative_source,str): raise ValueError('Invalid analysis source path')
        # Schema 1 publishers on Windows used str(Path.relative_to(...)).
        # DIT remains strictly POSIX; normalize only this documented producer field.
        current = within(location, relative_source.replace('\\','/'))
        if not current.is_relative_to(root): raise ValueError('Analysis source escapes library')
        relative = current.relative_to(root).as_posix()
        if path_key(relative) in paths: raise ValueError('Duplicate analysis source path')
        paths.add(path_key(relative)); sources[sid] = (source, relative)
    for category in ('events', 'interest_points'):
        if not isinstance(index.get(category), list): raise ValueError('Unsupported finding structure')
        for finding in index[category]:
            if not isinstance(finding,dict) or any(not isinstance(finding.get(k),str) for k in ('title','reason')):
                raise ValueError('Invalid finding text')
            if not isinstance(finding.get('clips'), list) or not finding['clips']: raise ValueError('Finding requires clips')
            for clip in finding['clips']:
                if clip['source_id'] not in sources: raise ValueError('Unknown finding source')
                interval(clip)
                if not isinstance(clip.get('evidence_ids'), list): raise ValueError('Missing finding evidence')
    frame_rows=index.get('evidence_frames',[])
    if not isinstance(frame_rows,list) or any(not isinstance(f,dict) or not isinstance(f.get('id'),str) or not f['id'].strip() for f in frame_rows):raise ValueError('Invalid published frame evidence')
    evidence={f['id']:f for f in frame_rows}
    if len(evidence)!=len(frame_rows):raise ValueError('Duplicate published frame ID')
    for entry in index.get('visual_changes',[]):
        if not isinstance(entry,dict) or set(entry)!={'review_id','change'}:raise ValueError('Invalid published visual change')
        if not isinstance(entry['review_id'],str) or not entry['review_id'].strip():raise ValueError('Visual change requires a nonblank review ID')
        c=entry['change']
        if not isinstance(c,dict) or set(c)!={'topic','claim_type','description','clip','confidence','limits','needs_playback'}:raise ValueError('Invalid published visual change schema')
        if c['topic'] not in ('composition','subject_action','lighting','occlusion','edit_cue') or c['confidence'] not in ('high','medium','low'):raise ValueError('Invalid visual change topic/confidence')
        if not isinstance(c['description'],str) or not c['description'].strip() or not isinstance(c['limits'],list) or not c['limits'] or any(not isinstance(s,str) or not s.strip() for s in c['limits']):raise ValueError('Visual change needs nonblank facts and uncertainty limits')
        clip=c['clip']
        if not isinstance(clip,dict) or set(clip)!={'source_id','start','end','precision','evidence_ids'}:raise ValueError('Invalid visual change clip schema')
        a,b,precision=interval(clip);ids=clip.get('evidence_ids',[])
        if not isinstance(ids,list) or any(not isinstance(fid,str) or not fid.strip() for fid in ids):raise ValueError('Invalid visual frame IDs')
        if clip['source_id'] not in sources or precision!='sampled_frames' or len(ids)<2 or len(ids)!=len(set(ids)) or any(fid not in evidence or evidence[fid]['source_id']!=clip['source_id'] for fid in ids):raise ValueError('Invalid visual change source/frame evidence')
        times=[evidence[fid]['time'] for fid in ids]
        if any(type(t) not in (int,float) or not math.isfinite(t) for t in times):raise ValueError('Invalid actual visual evidence time')
        if times!=sorted(set(times)) or abs(a-min(times))>1e-6 or abs(b-max(times))>1e-6:raise ValueError('Visual change must envelope distinct actual sampled frame times')
        if c.get('claim_type') not in ('visible_change','camera_motion_inference') or c.get('needs_playback') is not True or not c.get('limits') or not isinstance(c.get('description'),str):raise ValueError('Missing visual change uncertainty/claim type')
    for sid, result in transcript['sources'].items():
        if sid not in sources: raise ValueError('Unknown transcript source')
        if not isinstance(result,dict) or not isinstance(result.get('segments',[]),list): raise ValueError('Invalid transcript result')
        for segment in result.get('segments', []):
            if not isinstance(segment,dict) or not isinstance(segment.get('text',''),str): raise ValueError('Invalid transcript text')
            if segment.get('source_id', sid) != sid: raise ValueError('Transcript source mismatch')
            interval(segment)
    geography=index.get('geography',{})
    if not isinstance(geography,dict) or not isinstance(geography.get('associations',[]),list): raise ValueError('Invalid geography structure')
    for association in geography.get('associations',[]):
        if not isinstance(association,dict) or not isinstance(association.get('finding_key'),str): raise ValueError('Invalid geography association')
    return snap['digest'], (index, transcript, sources)


def replace_unit(db, scope, root, kind, data):
    for table in TABLES:
        db.execute(f'DELETE FROM {table} WHERE scope=?', [scope])
    library = str(root)
    if kind == 'dit':
        for number, row in enumerate(data):
            db.execute('INSERT INTO dit VALUES (?,?,?,?,?,?,?,?,?,?)', [scope,number,library,row['路径'],path_key(row['路径']),
                row['原名'],row['状态'],row['备注'],row['SHA256'],json_text(row)])
        return
    index, transcript, sources = data
    for sid, (source, relative) in sources.items():
        db.execute('INSERT INTO sources VALUES (?,?,?,?,?,?,?,?,?,?)', [scope,sid,library,relative,path_key(relative),
            source.get('status'),index.get('archival_date'),index['run_id'],index.get('revision',1),json_text(source)])
    geography = {a['finding_key']: a for a in index.get('geography',{}).get('associations',[])}
    for category, kind in (('events','event'),('interest_points','interest_point')):
        for number, finding in enumerate(index[category], 1):
            fid = f'{kind}:{number}'
            matches = [a for key,a in geography.items() if key.startswith(f'{kind}:{number:02}:')]
            geo = matches[0] if len(matches)==1 else None
            db.execute('INSERT INTO findings VALUES (?,?,?,?,?,?,?)', [scope,fid,kind,finding['title'],finding['reason'],json_text(geo),json_text(finding)])
            for clip_no, clip in enumerate(finding['clips']):
                start,end,precision = interval(clip)
                db.execute('INSERT INTO clips VALUES (?,?,?,?,?,?,?,?)', [scope,fid,clip_no,clip['source_id'],start,end,precision,json_text(clip['evidence_ids'])])
    for number,entry in enumerate(index.get('visual_changes',[]),1):
        c=entry['change'];fid=f'visual_change:{number}';clip=c['clip'];start,end,precision=interval(clip)
        db.execute('INSERT INTO findings VALUES (?,?,?,?,?,?,?)',[scope,fid,'visual_change',c['topic']+': '+c['claim_type'],c['description'],json_text(None),json_text(entry)])
        db.execute('INSERT INTO clips VALUES (?,?,?,?,?,?,?,?)',[scope,fid,0,clip['source_id'],start,end,precision,json_text(clip['evidence_ids'])])
    for sid, result in transcript['sources'].items():
        for number, segment in enumerate(result.get('segments', [])):
            start,end,precision = interval(segment)
            db.execute('INSERT INTO transcripts VALUES (?,?,?,?,?,?,?,?,?)', [scope,sid,number,start,end,precision,segment.get('text',''),json_text([segment['id']] if segment.get('id') else []),json_text(segment)])


def refresh(db, config):
    known = db.execute('SELECT library,kind,location FROM snapshots').fetchall()
    units = configured_units(config,known); results = []
    for scope, root, kind, location in units:
        now = dt.datetime.now(dt.timezone.utc).isoformat()
        try:
            if kind=='discovery':
                discovered = discover(root,location.relative_to(root).as_posix())
                checksum,data = digest([str(p) for p in discovered]),None
            else:
                checksum, data = dit_rows(root, location) if kind == 'dit' else publication_rows(root, location)
            if kind=='publication':checksum=digest(['query-parser-visual-v2',checksum])
            old = db.execute('SELECT digest FROM snapshots WHERE scope=?', [scope]).fetchone()
            changed = not old or old[0] != checksum
            db.execute('BEGIN TRANSACTION')
            try:
                if changed and kind!='discovery': replace_unit(db, scope, root, kind, data)
                db.execute('INSERT OR REPLACE INTO snapshots VALUES (?,?,?,?,?,?,?,?,?)',
                    [scope,str(root),kind,str(location),checksum,now,now,False,None])
                db.execute('COMMIT')
            except Exception:
                db.execute('ROLLBACK'); raise
            results.append({'location':str(location),'changed':changed,'stale':False})
        except (OSError, ValueError, KeyError, TypeError) as exc:
            # Keep the last successful snapshot, including on disconnected NAS roots.
            old = db.execute('SELECT digest,last_success FROM snapshots WHERE scope=?', [scope]).fetchone()
            db.execute('INSERT OR REPLACE INTO snapshots VALUES (?,?,?,?,?,?,?,?,?)',
                [scope,str(root),kind,str(location),old[0] if old else None,old[1] if old else None,now,True,str(exc)])
            results.append({'location':str(location),'stale':True,'error':str(exc)})
    # Removing a configured input explicitly removes only its cache rows.
    active = {unit[0] for unit in units}
    for (scope,) in db.execute('SELECT scope FROM snapshots').fetchall():
        if scope not in active:
            db.execute('BEGIN TRANSACTION')
            try:
                for table in (*TABLES, 'snapshots'): db.execute(f'DELETE FROM {table} WHERE scope=?', [scope])
                db.execute('COMMIT')
            except Exception:
                db.execute('ROLLBACK'); raise
    return results


def search(db, keyword='', kind=None, library=None, path=None, status=None, date=None, limit=50):
    sql = '''SELECT * FROM (
        SELECT 'media' AS kind,source_id,coalesce(original_name,relative_path) AS title,notes AS text,
            library,relative_path,original_path,NULL::DOUBLE AS start_s,NULL::DOUBLE AS end_s,
            NULL::VARCHAR AS precision,NULL::VARCHAR AS evidence,NULL::VARCHAR AS geography,
            archival_date,dit_status,analysis_status,stale,run_id,revision,
            coalesce(dit_last_success,analysis_last_success) AS last_success,
            publication,dit_index,analysis_last_success,dit_last_success FROM media
        UNION ALL SELECT kind,source_id,title,reason,library,relative_path,original_path,start_s,end_s,precision,evidence,
            geography,archival_date,dit_status,analysis_status,stale,run_id,revision,last_success,
            publication,dit_index,analysis_last_success,dit_last_success FROM segments
        UNION ALL SELECT 'transcript',source_id,text,text,library,relative_path,original_path,start_s,end_s,precision,evidence,
            NULL,archival_date,dit_status,analysis_status,stale,run_id,revision,last_success,
            publication,dit_index,analysis_last_success,dit_last_success FROM transcriptions
        ) results WHERE TRUE'''
    params = []
    if keyword:
        sql += " AND contains(lower(coalesce(title,'')||' '||coalesce(text,'')||' '||coalesce(relative_path,'')||' '||coalesce(geography,'')||' '||coalesce(dit_status,'')||' '||coalesce(analysis_status,'')),lower(?))"; params.append(keyword)
    for column, value in (('kind',kind),('library',library),('archival_date',date)):
        if value is not None: sql += f' AND {column}=?'; params.append(value)
    if path is not None: sql += " AND contains(coalesce(relative_path,''),?)"; params.append(path)
    if status is not None: sql += ' AND (dit_status=? OR analysis_status=?)'; params += [status,status]
    if not 1 <= limit <= 10000: raise ValueError('limit must be 1..10000')
    result = db.execute(sql+' ORDER BY library,relative_path,kind,start_s LIMIT ?', params+[limit])
    columns = [c[0] for c in result.description]
    rows = [dict(zip(columns,row)) for row in result.fetchall()]
    for row in rows:
        for key in ('evidence','geography'):
            if row[key] is not None: row[key] = json.loads(row[key])
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for command in ('refresh','search','status'):
        child = sub.add_parser(command); child.add_argument('--db', required=True, type=Path)
        if command == 'refresh': child.add_argument('--config', required=True, type=Path)
        if command == 'search':
            child.add_argument('keyword', nargs='?', default='')
            child.add_argument('--kind', choices=('media','event','interest_point','visual_change','transcript'))
            for name in ('library','path','status','date'): child.add_argument('--'+name)
            child.add_argument('--limit', type=int, default=50)
    args = parser.parse_args()
    try:
        db = connect(args.db, readonly=args.command!='refresh')
        try:
            if args.command == 'refresh': result = refresh(db, read(args.config))
            elif args.command == 'search': result = search(db,args.keyword,args.kind,args.library,args.path,args.status,args.date,args.limit)
            else:
                cursor = db.execute('SELECT * FROM snapshots ORDER BY library,kind,location')
                result = [dict(zip([c[0] for c in cursor.description],row)) for row in cursor.fetchall()]
            print(json.dumps(result,ensure_ascii=False,indent=2))
            return 2 if args.command=='refresh' and any(r['stale'] for r in result) else 0
        finally: db.close()
    except Exception as exc:
        parser.exit(1, f'ERROR: {exc}\n')


if __name__ == '__main__': sys.exit(main())
