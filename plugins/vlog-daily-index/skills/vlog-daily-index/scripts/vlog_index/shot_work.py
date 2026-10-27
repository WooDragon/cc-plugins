"""Bounded shot bundles using one atomic ledger; ROOT bridges native tools."""
from __future__ import annotations
import argparse, copy, json, uuid
from pathlib import Path
from . import shot_review as shot, vision
from .store import RunLock, dump, read, digest, file_hash

MAX_SEGMENTS=2
MAX_IMAGES=34

def local_root(output):
    root=Path(output).resolve()
    if str(root).startswith('\\\\') or any(p.lower()=='onedrive' for p in root.parts):raise ValueError('Active shot state must be local and nonsync')
    return root

def _ledger(root):
    p=Path(root)/'work.json'
    return read(p) if p.exists() else {'schema':'shot_work_v1','jobs':{},'bundles':{}}
def _save(root,data):dump(Path(root)/'work.json',data)
def _check(job):
    if file_hash(job['task_path'])!=job['task_sha256']:raise ValueError('Frozen shot task changed')
    shot.verify_input(read(job['task_path']))
    if job.get('origin'):
        origin=job['origin']
        if file_hash(origin['package_path'])!=origin['package_sha256']:raise ValueError('Original supplemental package changed')

def add_packet(root,source,package,manifest_record):
    """Register already extracted supplement images; never make another medium claim."""
    root=local_root(root);root.mkdir(parents=True,exist_ok=True)
    with RunLock(root):
        data=_ledger(root);jid=package['package_id']
        if jid in data['jobs']:_check(data['jobs'][jid]);return jid
        frames=copy.deepcopy(package['frames'])
        for f in frames:f['sha256']=file_hash(f['path'])
        times=[f['time'] for f in frames]
        identity={'schema':'shot_review_input_v1','prompt_version':shot.VERSION,'source':{**shot.source_identity(source),'path':source['path'],'clock':{k:source.get('metadata',{}).get(k) for k in ('time_verified','playback_rate_verified','captured_at_utc','capture_fps','format_fps')}},'interval':{'start':min(times),'end':min(source['duration'],max(times)+1/source['fps']),'time_basis':'source_file_playback_seconds'},'frames':frames,'core_frame_ids':package['core_frame_ids'],'requires_facts':True,'preview':frames[0].get('preview',{}),'sampling':{'actual_frames':len(frames),'max_gap_seconds':max((b-a for a,b in zip(times,times[1:])),default=0),'coverage':'sampled_sequence_not_continuous_video'},'instructions':shot.INSTRUCTIONS,'result_schema':shot.Result.model_json_schema()}
        task={'schema':'shot_review_task_v1','review_id':'shot-'+digest(identity)[:24],'input_digest':digest(identity),'input':identity,'result_path':str(root/'jobs'/jid/'unused.result.json'),'request_route':{'stage':'shot_review','model':'gpt-6-luna','reasoning_effort':'max','runtime_model_verified':False}}
        task_path=root/'jobs'/jid/'task.json';shot.write_new(task_path,task)
        data['jobs'][jid]={'id':jid,'task_path':str(task_path),'task_sha256':file_hash(task_path),'status':'queued','source_id':source['id'],'directory':str(Path(source['path']).parent),'start':min(times),'images':len(frames),'provenance':[{'kind':'supplement','package_id':jid}],'origin':{'package_id':jid,'package_path':manifest_record['path'],'result_path':manifest_record['result_path'],'package_sha256':file_hash(manifest_record['path'])}}
        _save(root,data);return jid

def plan_query(candidates,selected,output,ffmpeg,start=None,end=None):
    """Consume real query rows; titles/AI aliases never become media paths."""
    import query_index as query
    rows=read(candidates);root=local_root(output)
    if not isinstance(rows,list) or not selected:raise ValueError('Select explicit 1-based query candidate numbers')
    if (start is None)!=(end is None) or (start is not None and len(selected)!=1):raise ValueError('An explicit narrowed interval requires exactly one candidate')
    normalized=[];needs=[];existing_reviews=[]
    for number in selected:
        if type(number) is not int or not 1<=number<=len(rows):raise ValueError('Candidate number outside query output')
        row=rows[number-1]
        if row.get('stale') is not False or not row.get('source_id'):raise ValueError('Candidate needs current publication source identity, not a DIT/title alias')
        library=Path(row['library']).resolve();publication=Path(row['publication']).resolve()
        if not publication.is_relative_to(library):raise ValueError('Publication outside candidate library')
        snap,(index,_,sources)=query.publication_rows(library,publication)
        if row.get('run_id')!=index['run_id'] or row.get('revision')!=index.get('revision',1) or row['source_id'] not in sources:raise ValueError('Query candidate publication identity is stale or ambiguous')
        source,relative=sources[row['source_id']];source=copy.deepcopy(source);actual=query.within(library,relative)
        if row.get('relative_path')!=relative or not row.get('original_path') or Path(row['original_path']).resolve()!=actual:raise ValueError('Candidate original path lacks an exact source mapping')
        source['path']=str(actual)
        if row.get('kind')=='visual_change':
            existing_reviews.append({'candidate':number,'source_id':source['id'],'start':row.get('start_s'),'end':row.get('end_s'),'reason':'Already reviewed; needs_playback means play the original, not recursively reanalyse'})
            continue
        if any(k not in source for k in ('fps','duration','size','mtime_ns','sidecars','metadata','start_pts')):raise ValueError('Published source lacks verified media preparation metadata')
        if not shot.media.unchanged(source):raise ValueError('Original media identity changed; cached shot cannot be silently reused')
        a,b=row.get('start_s'),row.get('end_s')
        if start is not None:
            if a is not None and not a<=start<end<=b:raise ValueError('Narrowed interval must stay inside selected candidate')
            a,b=start,end
        if not isinstance(a,(int,float)) or not isinstance(b,(int,float)) or not 0<=a<b<=source['duration']:raise ValueError('Candidate requires an explicit unambiguous source-file interval')
        if b-a>8:needs.append({'candidate':number,'source_id':source['id'],'start':a,'end':b,'reason':'Choose an explicit <=8s interval; no part was silently selected','covered':False});continue
        preview=source.get('preview',{});luts={}
        if preview.get('applied'):
            lut=preview.get('lut_path')
            if not lut or file_hash(lut)!=preview.get('lut_sha256'):raise ValueError('Original preview LUT is unavailable/changed')
            luts[preview['device']+':'+preview['log_token']]=lut
        key=digest({'source':shot.source_identity(source),'path':source['path'],'interval':[a,b],'frames':17,'preview':preview,'prompt':shot.VERSION})[:24]
        normalized.append((key,source,a,b,luts,{'kind':'query','candidate':number,'publication':str(publication),'publication_digest':snap,'original_interval':[row.get('start_s'),row.get('end_s')]}))
    if needs:return {'next_action':'select_interval','requests':needs,'prepared':0,'reason':'No extraction until every selected candidate has an executable interval'}
    if not normalized:return {'next_action':'use_existing_review','existing_reviews':existing_reviews,'prepared':0,'native_calls':0}
    hits=0
    root.mkdir(parents=True,exist_ok=True)
    with RunLock(root):
        data=_ledger(root)
        for key,source,a,b,luts,provenance in normalized:
            if key in data['jobs']:
                _check(data['jobs'][key]);hits+=data['jobs'][key]['status']=='success'
                if provenance not in data['jobs'][key]['provenance']:data['jobs'][key]['provenance'].append(provenance)
                continue
            manifest=root/'inputs'/(key+'.json');dump(manifest,{'sources':[source],'config':{'preview_luts':luts}})
            prepared=shot.prepare(manifest,source['id'],a,b,17,root/'jobs'/key,ffmpeg,('max',))
            task=Path(prepared['task_paths'][0]);data['jobs'][key]={'id':key,'task_path':str(task),'task_sha256':file_hash(task),'status':'queued','source_id':source['id'],'directory':str(Path(source['path']).parent),'start':a,'images':17,'provenance':[provenance]}
        _save(root,data)
    return {'next_action':'next','output':str(root),'selected':len(normalized),'cache_hits':hits,'existing_reviews':existing_reviews,'native_calls':0}

def _brief(job,task,result_path):
    i=task['input']
    return {'job_id':job['id'],'review_id':task['review_id'],'input_digest':task['input_digest'],'source_id':i['source']['id'],'time_basis':'source_file_playback_seconds','time_precision':'decoded_frame_pts','clock':{**i['source'].get('clock',{}),'source_fps':i['source'].get('fps')},'interval':i['interval'],'core_frame_ids':i.get('core_frame_ids',[f['id'] for f in i['frames']]),'requires_facts':i.get('requires_facts',False),'preview':{k:i.get('preview',{}).get(k) for k in ('status','normalized','applied','warning')},'sampling':i['sampling'],'frames':[{k:f[k] for k in ('id','time','path')} for f in i['frames']],'result_path':str(result_path)}
BUNDLE_INSTRUCTIONS='按members逐段独立完成，不能跨source推运动。每段落结果；全部完成后只回报一次bundle_id和清单，异常立即报已完成/未开始并停止，不续派、不递归。'

def _bundle_task(bundle,data):
    jobs=[data['jobs'][jid] for jid in bundle['jobs']];tasks=[read(j['task_path']) for j in jobs]
    common=tasks[0]['input']
    if any(t['input']['instructions']!=common['instructions'] or t['input']['result_schema']!=common['result_schema'] for t in tasks):raise ValueError('Bundle members require the same frozen prompt/schema')
    return {'schema':'shot_bundle_v1','bundle_id':bundle['id'],'native_contract_digest':digest(bundle['contract']),'instructions':common['instructions']+BUNDLE_INSTRUCTIONS,'result_schema':common['result_schema'],'members':[_brief(j,t,bundle['results'][j['id']]) for j,t in zip(jobs,tasks)]}

def _check_bundle(bundle,data):
    if not bundle.get('task_sha256') or file_hash(bundle['task_path'])!=bundle['task_sha256']:raise ValueError('Frozen thin bundle changed or lacks a pre-dispatch digest; restore its original input')
    if read(bundle['task_path'])!=_bundle_task(bundle,data):raise ValueError('Thin bundle no longer matches its original members/contract')
    if len(bundle['jobs'])>MAX_SEGMENTS or bundle['images']!=sum(data['jobs'][j]['images'] for j in bundle['jobs']) or bundle['images']>MAX_IMAGES:raise ValueError('Bundle exceeds its frozen worker budget')
    if vision.shot_dispatch_contract(bundle['contract']['capability_snapshot'])!=bundle['contract']:raise ValueError('Frozen native max contract changed')

def _action(bundle):
    return {'bundle_id':bundle['id'],'task_path':bundle['task_path'],'native_agent_id':bundle.get('native_agent_id'),'jobs':bundle['jobs'],'images':bundle['images'],'native_contract':{k:v for k,v in bundle['contract'].items() if k!='capability_snapshot'}}
def _ingest(data):
    errors=[]
    for bundle in data['bundles'].values():
        try:_check_bundle(bundle,data)
        except Exception as error:
            errors.append({'bundle_id':bundle['id'],'error':str(error),'task_path':bundle['task_path'],'expected_sha256':bundle.get('task_sha256')});continue
        for jid in bundle['jobs']:
            job=data['jobs'][jid]
            if job.get('bundle_id')!=bundle['id']:continue
            try:
                _check(job)
                if job['status']=='invalid':job['status']='running'
                path=Path(bundle['results'][jid])
                if job['status']=='success':
                    record=read(job['accepted_path'])
                    if shot.validated_record(record['task_path'],record['result_path'])!=record:raise ValueError('Cached accepted shot result changed')
                elif path.exists():
                    result=shot.validate(job['task_path'],path);job.update(status='success',accepted_path=result['accepted_path'])
                elif bundle.get('turn_finished') and bundle.get('outcome')=='complete':
                    raise ValueError('Native reported complete but this member result is missing; recover the original result, do not redispatch')
            except Exception as error:
                job['status']='invalid'
                errors.append({'job_id':jid,'error':str(error),'task_path':job['task_path']})
        if bundle.get('turn_finished'):
            bundle['status']='finished'
            for jid in bundle['jobs']:
                job=data['jobs'][jid]
                if bundle.get('outcome')=='failed' and job.get('bundle_id')==bundle['id'] and job['status'] not in ('success','invalid'):job['status']='queued';job.pop('bundle_id',None)
    return errors

def next_action(output,capabilities=None,available=0,reserve=1,bundle_id=None,native_agent_id=None,outcome=None,reason=None):
    root=local_root(output);root.mkdir(parents=True,exist_ok=True)
    with RunLock(root):
        data=_ledger(root)
        # Native facts commit independently, before any task/image/other-job inspection.
        if bundle_id is not None:
            b=data['bundles'][bundle_id]
            if native_agent_id is not None:
                if b.get('native_agent_id') not in (None,native_agent_id):raise ValueError('Cannot replace native owner')
                if any(x['id']!=b['id'] and x.get('native_agent_id')==native_agent_id for x in data['bundles'].values()):raise ValueError('A new bundle needs a fresh native worker; do not alias/reuse beyond budget')
                b.update(native_agent_id=native_agent_id,status='running')
            if outcome is not None:
                if not b.get('native_agent_id') or not reason or not reason.strip():raise ValueError('Completion requires exact bound native ID and actual turn evidence')
                if b.get('outcome') not in (None,outcome):raise ValueError('Conflicting native completion receipt')
                b.update(turn_finished=True,outcome=outcome,completion_evidence=reason)
            _save(root,data);return {'next_action':'next','receipt_saved':bundle_id}
        errors=_ingest(data);_save(root,data)
        if errors:return {'next_action':'root_correction','errors':errors,'active_bundles':[_action(b) for b in data['bundles'].values() if not b.get('turn_finished')]}
        active=[b for b in data['bundles'].values() if not b.get('turn_finished')]
        for b in active:
            if not b.get('native_agent_id'):return {'next_action':'recover_bind',**_action(b),'rule':'Recover actual spawn receipt; unknown dispatch must not be sent again'}
        queued=[j for j in data['jobs'].values() if j['status']=='queued' and not j.get('bundle_id')]
        queued.sort(key=lambda j:(j['directory'],j['source_id'],j['start'],j['id']))
        if queued and max(0,available-reserve)>0:
            if not capabilities:return {'next_action':'blocked','reason':'Current native Luna max/image capability snapshot required'}
            contract=vision.shot_dispatch_contract(capabilities);selected=[];images=0;directory=queued[0]['directory']
            for j in queued:
                if j['directory']!=directory:continue
                if len(selected)>=MAX_SEGMENTS or images+j['images']>MAX_IMAGES:break
                _check(j);selected.append(j);images+=j['images']
            if not selected:raise ValueError('A whole segment exceeds the conservative 34-image worker budget')
            bid='bundle-'+uuid.uuid4().hex[:16];folder=root/'bundles'/bid;results={j['id']:str(folder/j['id']/'result.json') for j in selected}
            b={'id':bid,'task_path':str(folder/'task.json'),'contract':contract,'jobs':[j['id'] for j in selected],'images':images,'results':results,'status':'reserved','turn_finished':False}
            shot.write_new(folder/'task.json',_bundle_task(b,data));b['task_sha256']=file_hash(b['task_path'])
            data['bundles'][bid]=b
            for j in selected:j.update(bundle_id=bid,status='running')
            _save(root,data);return {'next_action':'spawn',**_action(b)}
        if active:return {'next_action':'wait','active_bundles':[_action(b) for b in active],'rule':'Only actual matching native FINAL closes a turn; no timeout requeue'}
        if queued:return {'next_action':'wait_slots','queued_segments':len(queued)}
        return {'next_action':'complete','segments':len(data['jobs']),'cache_successes':sum(j['status']=='success' for j in data['jobs'].values())}

def require_finished(root):
    root=Path(root)
    if not (root/'work.json').exists():return
    with RunLock(root):
        data=_ledger(root)
        if any(not b.get('turn_finished') for b in data['bundles'].values()):raise ValueError('Native shot turn is unresolved')
        errors=_ingest(data)
        if errors or any(j['status']!='success' for j in data['jobs'].values()):raise ValueError('Shot evidence/results require recovery before downstream stages')

def main():
    p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest='action',required=True)
    q=sub.add_parser('prepare');q.add_argument('--manifest',required=True);q.add_argument('--source-id',required=True);q.add_argument('--start',type=float,required=True);q.add_argument('--end',type=float,required=True);q.add_argument('--frames',type=int,default=17);q.add_argument('--output',required=True);q.add_argument('--ffmpeg',required=True);q.add_argument('--effort',choices=('max',),default='max',action='append')
    q=sub.add_parser('validate');q.add_argument('--task',required=True);q.add_argument('--result')
    q=sub.add_parser('report');q.add_argument('--record',required=True);q.add_argument('--output',required=True)
    q=sub.add_parser('plan');q.add_argument('--candidates',required=True);q.add_argument('--select',type=int,action='append',required=True);q.add_argument('--start',type=float);q.add_argument('--end',type=float);q.add_argument('--output',required=True);q.add_argument('--ffmpeg',required=True)
    q=sub.add_parser('next');q.add_argument('--output',required=True);q.add_argument('--native-capabilities');q.add_argument('--available-workers',type=int,default=0);q.add_argument('--reserve-sol',type=int,default=1);q.add_argument('--bundle-id');q.add_argument('--native-agent-id');q.add_argument('--outcome',choices=('complete','failed'));q.add_argument('--reason')
    a=p.parse_args()
    if a.action=='prepare':v=shot.prepare(a.manifest,a.source_id,a.start,a.end,a.frames,a.output,a.ffmpeg,('max',))
    elif a.action=='validate':v=shot.validate(a.task,a.result)
    elif a.action=='report':v=shot.report(a.record,a.output)
    elif a.action=='plan':v=plan_query(a.candidates,a.select,a.output,a.ffmpeg,a.start,a.end)
    else:v=next_action(a.output,read(a.native_capabilities) if a.native_capabilities else None,a.available_workers,a.reserve_sol,a.bundle_id,a.native_agent_id,a.outcome,a.reason)
    print(json.dumps(v,ensure_ascii=False,indent=2))
