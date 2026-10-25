"""Single-writer state, immutable source identities, and bounded artifact cleanup."""
from __future__ import annotations
import csv, datetime, hashlib, io, json, os, re, sqlite3, time
from pathlib import Path

def host_data_root():
    return Path(os.environ.get('LOCALAPPDATA',Path.home()/'.local/share'))/'VlogIndex'

def dump(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
    os.replace(temporary, path)

def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))

def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()

def file_hash(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for data in iter(lambda:f.read(1048576), b''): h.update(data)
    return h.hexdigest()

class State:
    def __init__(self, root):
        self.root = Path(root).resolve(); self.root.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.root / 'state.sqlite3')
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('CREATE TABLE IF NOT EXISTS tasks (key TEXT PRIMARY KEY, stage TEXT, status TEXT, payload TEXT, updated REAL)')
        self.db.commit()
    def put(self, key, stage, status, payload):
        self.db.execute('INSERT OR REPLACE INTO tasks VALUES (?,?,?,?,?)',(key,stage,status,json.dumps(payload,ensure_ascii=False),time.time())); self.db.commit()
    def get(self,key):
        row=self.db.execute('SELECT status,payload FROM tasks WHERE key=?',(key,)).fetchone()
        return None if not row else {'status':row[0], 'payload':json.loads(row[1])}
    def close(self): self.db.close()

class ServiceLock:
    """OS lock held through the entire HTTP request; released on process death."""
    def __init__(self, root, service):
        from urllib.parse import urlsplit
        parsed=urlsplit(service.rstrip('/'))
        normalized=f'{parsed.scheme.lower()}://{parsed.hostname.lower()}:{parsed.port or (443 if parsed.scheme=="https" else 80)}{parsed.path.rstrip("/")}'
        global_root=host_data_root()/'services'
        self.path=global_root/('service-'+digest(normalized)[:16]+'.lock')
    def __enter__(self):
        self.path.parent.mkdir(parents=True,exist_ok=True)
        self.f=open(self.path,'a+b'); self.f.seek(0); self.f.write(b'0'); self.f.flush(); self.f.seek(0)
        try:
            if os.name=='nt':
                import msvcrt
                msvcrt.locking(self.f.fileno(),msvcrt.LK_NBLCK,1)
            else:
                import fcntl
                fcntl.flock(self.f,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except OSError:
            self.f.close(); raise RuntimeError('ASR service is already owned by another local process')
        return self
    def __exit__(self,*args): self.f.close()

class RunLock(ServiceLock):
    def __init__(self,root): self.path=Path(root).resolve()/'.coordinator.lock'

def cleanup_registered(run, manifest):
    root=Path(run).resolve()
    if root.name != manifest['run_id']: raise ValueError('run directory identity mismatch')
    if not manifest.get('published_verified') or manifest.get('status') not in ('complete','terminal_with_gaps'):
        raise ValueError('cleanup requires complete and verified publication')
    removed=[]
    for entry in manifest.get('temporary_artifacts',[]):
        original=Path(entry)
        if any(p.is_symlink() or (hasattr(p,'is_junction') and p.is_junction()) for p in [original,*original.parents] if p!=root): raise ValueError('artifact has link/reparse ancestor')
        path=original.resolve()
        if root not in path.parents: raise ValueError('artifact escapes run directory')
        if path.is_file(): path.unlink(); removed.append(str(path))
    return removed

# This migration deliberately supports only the documented ten-column DIT index.
NAMING_INDEX_COLUMNS=('路径','原名','来源','大小','SHA256','校验','状态','配套','关联','备注')

def _naming_bytes(value):
    return json.dumps(value,ensure_ascii=False,indent=2).encode('utf-8')

def _naming_tree(root):
    root=Path(root)
    if not root.is_dir(): raise ValueError('Naming source directory is unavailable')
    result=[]
    for path in [root,*sorted(root.rglob('*'))]:
        if path.is_symlink() or (hasattr(path,'is_junction') and path.is_junction()): raise ValueError('Naming refuses links/junctions')
        st=path.stat()
        result.append({'path':path.relative_to(root).as_posix(),'directory':path.is_dir(),'identity':[st.st_dev,st.st_ino],
                       'size':st.st_size if path.is_file() else None,'mtime_ns':st.st_mtime_ns if path.is_file() else None})
    return result

def _naming_index(raw,library,source,target):
    if not raw.startswith(b'\xef\xbb\xbf'): raise ValueError('Index must use documented UTF-8 BOM encoding')
    reader=csv.DictReader(io.StringIO(raw.decode('utf-8-sig'),newline=''))
    if tuple(reader.fieldnames or ())!=NAMING_INDEX_COLUMNS: raise ValueError('Unsupported naming index schema')
    rows=list(reader); changes=[]; seen=set()
    prefix=source.relative_to(library).as_posix(); replacement=target.relative_to(library).as_posix()
    for number,row in enumerate(rows,2):
        if None in row or any(v is None for v in row.values()): raise ValueError('Malformed index row')
        for column in ('路径','配套','关联'):
            value=row[column]
            if not value: continue
            parts=value.split('/')
            if '\\' in value or ':' in value or any(p in ('','..','.') for p in parts) or any(c in value for c in ';|\r\n'):
                raise ValueError('Unsupported current index reference; expected one relative POSIX path')
            if value==prefix or value.startswith(prefix+'/'):
                existing=library.joinpath(*parts)
                if not existing.exists(): raise ValueError('Affected current index reference is missing: '+value)
                if column=='路径' and row['大小'] and (not existing.is_file() or existing.stat().st_size!=int(row['大小'])):
                    raise ValueError('Affected indexed file size mismatch')
                updated=replacement+value[len(prefix):]
                row[column]=updated; changes.append({'row':number,'column':column,'before':value,'after':updated})
        if row['路径']:
            key=row['路径'].casefold()
            if key in seen: raise ValueError('Duplicate current index path')
            seen.add(key)
    output=io.StringIO(newline=''); writer=csv.DictWriter(output,fieldnames=NAMING_INDEX_COLUMNS,lineterminator='\r\n')
    writer.writeheader(); writer.writerows(rows)
    return output.getvalue().encode('utf-8-sig'),changes

def naming_plan(manifest,config,library_root,index_path,state_dir):
    """Read-only library dry run. The plan/config are persisted outside the library."""
    library=Path(library_root).resolve(); source=Path(manifest['config']['source_root']).resolve()
    state=Path(state_dir).resolve(); index=Path(index_path).resolve()
    if source==library or library not in source.parents or library not in index.parents: raise ValueError('Source/index outside library root')
    if state==library or library in state.parents: raise ValueError('Naming state must be outside library')
    if state!=Path(manifest['state_dir']).resolve(): raise ValueError('Naming state identity mismatch')
    date=datetime.date.fromisoformat(config['date'])
    if manifest['config'].get('date') and date.isoformat()!=manifest['config']['date']: raise ValueError('Naming date differs from run date')
    def token(value):
        if not isinstance(value,str) or not value.strip() or value!=value.strip() or re.search(r'[<>:"/\\|?*\x00-\x1f_-]',value) or value.endswith('.'):
            raise ValueError('Invalid naming region/theme token')
        return value
    region=token(config.get('main_region')); themes=config.get('themes')
    if not isinstance(themes,list) or len(themes) not in (2,3) or len(set(themes))!=len(themes): raise ValueError('Naming requires two or three distinct reviewed themes')
    name=date.strftime('%Y%m%d')+'_'+region+'_'+'-'.join(token(v) for v in themes)
    if len(name)>255: raise ValueError('Naming component exceeds filesystem name limit')
    target=source.with_name(name)
    if target==source or target.exists(): raise ValueError('Naming target already exists or is unchanged')
    if target.parent!=source.parent or target.anchor!=source.anchor: raise ValueError('Only same-parent directory rename is supported')
    for path in [source,index,*source.parents,*index.parents]:
        if path.is_symlink() or (hasattr(path,'is_junction') and path.is_junction()): raise ValueError('Naming path has link/junction ancestor')
    raw=index.read_bytes(); after,changes=_naming_index(raw,library,source,target)
    plan={'schema':1,'run_id':manifest['run_id'],'config':config,'source':str(source),'target':str(target),'library_root':str(library),
          'index_path':str(index),'state_dir':str(state),'manifest_sha256':file_hash(state/'manifest.json'),
          'tree':_naming_tree(source),'index_before_sha256':hashlib.sha256(raw).hexdigest(),
          'index_after_sha256':hashlib.sha256(after).hexdigest(),'index_changes':changes,'index_after_text':after.decode('utf-8-sig')}
    plan['plan_id']=digest(plan)[:24]; path=state/'naming'/(plan['plan_id']+'.json'); dump(path,plan)
    return {'plan_path':str(path),'plan_id':plan['plan_id'],'target':str(target),'changed_cells':len(changes),'changed_rows':len({c['row'] for c in changes}),'dry_run':True}

def _naming_load(plan_path):
    path=Path(plan_path).resolve(); plan=read(path)
    check={k:v for k,v in plan.items() if k!='plan_id'}
    if plan.get('schema')!=1 or digest(check)[:24]!=plan.get('plan_id') or path!=Path(plan['state_dir']).resolve()/'naming'/(plan['plan_id']+'.json'):
        raise ValueError('Naming plan identity/hash mismatch')
    return path,plan

def naming_review(plan_path,reviewer,reason):
    path,plan=_naming_load(plan_path)
    if reviewer!='ROOT' or not reason.strip(): raise ValueError('Naming requires ROOT review with evidence reason')
    record={'reviewer':reviewer,'reason':reason,'plan_sha256':digest(plan),'at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    dump(path.with_name(path.stem+'.review.json'),record); return record

def _naming_rebind(manifest,plan):
    m=json.loads(json.dumps(manifest)); old=Path(plan['source']); new=Path(plan['target'])
    def rebase(value):
        p=Path(value)
        try: return str(new/p.relative_to(old))
        except ValueError: return value
    m['config']['source_root']=str(new)
    for source in m['sources']:
        source.setdefault('original_path',source['path']); source['path']=rebase(source['path'])
        for sidecar in source.get('sidecars',[]):
            sidecar.setdefault('original_path',sidecar['path']); sidecar['path']=rebase(sidecar['path'])
        for point in source.get('metadata',{}).get('location_points',[]):
            if point.get('source_file'): point['source_file']=rebase(point['source_file'])
    m.setdefault('path_rebindings',[]).append({'plan_id':plan['plan_id'],'old_root':str(old),'current_root':str(new),'identity_policy':'Existing IDs, packages and cached evidence preserved; paths in old evidence are historical.'})
    history={key:m.pop(key) for key in ('publication','root_final_review','final_review_package','final') if key in m}
    if history: m.setdefault('naming_publication_history',[]).append(history)
    m['published_verified']=False; m['revision']=m.get('revision',1)+1; m['status']='renamed_needs_render'
    return m

def naming_apply(plan_path):
    """Recoverable same-parent rename + known CSV + state; never cross-resource atomic."""
    path,plan=_naming_load(plan_path); review_path=path.with_name(path.stem+'.review.json')
    if not review_path.exists(): raise ValueError('Naming plan has not been reviewed')
    review=read(review_path)
    if review.get('reviewer')!='ROOT' or not review.get('reason') or review.get('plan_sha256')!=digest(plan): raise ValueError('Naming approval does not bind current plan')
    source=Path(plan['source']); target=Path(plan['target']); library=Path(plan['library_root']); index=Path(plan['index_path']); state=Path(plan['state_dir'])
    if source.parent!=target.parent or source.anchor!=target.anchor or library not in source.parents or library not in index.parents: raise ValueError('Naming migration escapes controlled root')
    for entry in [source,target,index,*source.parents,*index.parents]:
        if entry.is_symlink() or (hasattr(entry,'is_junction') and entry.is_junction()): raise ValueError('Naming path acquired link/junction after planning')
    journal_path=path.with_name(path.stem+'.journal.json'); backup=path.with_name(path.stem+'.backup'); manifest_path=state/'manifest.json'
    if not journal_path.exists():
        if not source.is_dir() or target.exists() or _naming_tree(source)!=plan['tree']: raise ValueError('Naming source or target changed since plan')
        if file_hash(index)!=plan['index_before_sha256'] or file_hash(manifest_path)!=plan['manifest_sha256']: raise ValueError('Naming index/state changed since plan')
        # Save all recovery material locally before the first library mutation.
        backup.mkdir(exist_ok=True); (backup/'index.before.csv').write_bytes(index.read_bytes())
        (backup/'manifest.before.json').write_bytes(manifest_path.read_bytes())
        after=_naming_rebind(read(manifest_path),plan); (backup/'manifest.after.json').write_bytes(_naming_bytes(after))
        journal={'phase':'prepared','plan_sha256':digest(plan),'manifest_after_sha256':file_hash(backup/'manifest.after.json')}
        dump(journal_path,journal)
    journal=read(journal_path)
    if journal.get('plan_sha256')!=digest(plan): raise ValueError('Naming recovery journal mismatch')
    if file_hash(backup/'manifest.before.json')!=plan['manifest_sha256'] or file_hash(backup/'index.before.csv')!=plan['index_before_sha256'] or file_hash(backup/'manifest.after.json')!=journal['manifest_after_sha256']:
        raise ValueError('Naming recovery material changed')
    def verify_state():
        if file_hash(index) not in (plan['index_before_sha256'],plan['index_after_sha256']) or file_hash(manifest_path) not in (plan['manifest_sha256'],journal['manifest_after_sha256']): raise ValueError('External index/state change blocks naming recovery')
    verify_state()
    if source.exists() and not target.exists():
        if journal['phase']!='prepared' or _naming_tree(source)!=plan['tree']: raise ValueError('Source changed before rename')
        # os.rename refuses existing destinations on Windows; never use replace/copy here.
        if os.name!='nt': raise ValueError('Directory apply is supported on Windows only; plan is portable')
        os.rename(source,target)
    elif source.exists() or not target.is_dir(): raise ValueError('Ambiguous physical naming state; stop and reconcile')
    if _naming_tree(target)!=plan['tree']: raise ValueError('Renamed tree differs from planned source')
    journal['phase']='renamed'; dump(journal_path,journal); verify_state()
    if file_hash(index)==plan['index_before_sha256']:
        after=plan['index_after_text'].encode('utf-8-sig')
        if hashlib.sha256(after).hexdigest()!=plan['index_after_sha256']: raise ValueError('Index candidate hash mismatch')
        temporary=index.with_name(index.name+'.naming-'+plan['plan_id']+'.tmp')
        if temporary.exists():
            if temporary.is_symlink() or file_hash(temporary)!=plan['index_after_sha256']: raise ValueError('Unknown or incomplete naming index temporary file; reconcile explicitly')
        else:
            with temporary.open('xb') as stream: stream.write(after)
        if file_hash(index)!=plan['index_before_sha256']: raise ValueError('Index changed immediately before commit')
        os.replace(temporary,index)
    journal['phase']='indexed'; dump(journal_path,journal); verify_state()
    if file_hash(manifest_path)==plan['manifest_sha256']:
        temporary=manifest_path.with_suffix('.naming.tmp'); temporary.write_bytes((backup/'manifest.after.json').read_bytes()); os.replace(temporary,manifest_path)
    journal['phase']='state_updated'; dump(journal_path,journal)
    if source.exists() or _naming_tree(target)!=plan['tree'] or file_hash(index)!=plan['index_after_sha256'] or file_hash(manifest_path)!=journal['manifest_after_sha256']: raise ValueError('Naming final readback failed')
    journal['phase']='complete'; dump(journal_path,journal)
    return {'phase':'complete','target':str(target),'changed_cells':len(plan['index_changes']),'requires_render_and_root_review':True,'journal_path':str(journal_path)}
