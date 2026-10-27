"""Upgrade the existing one-round supplement queue to single-pass max review."""
from pathlib import Path
import copy, math, datetime as dt
from . import analysis, media, shot_work, shot_review
from .store import digest, dump, read, file_hash

def accept_dynamic(manifest,reviewer,reason):
    if reviewer!='ROOT' or not reason.strip():raise ValueError('Batch acceptance needs ROOT authorization evidence')
    if manifest['config'].get('supplement_mode')!='shot_v1':return {'accepted':[],'reason':'Existing run keeps its legacy supplement mode'}
    accepted=[];deferred=[]
    for req in list(manifest.get('supplemental_pending',[])):
        rid=digest(req)
        if req.get('purpose')!='dynamic':continue
        try:
            p=next((p for p in manifest['packages'] if p['id']==req.get('package_id')),None)
            if p is None or p['status']!='success':raise ValueError('Dynamic policy needs its original successfully imported initial package')
            payload=read(p['path'])
            if payload['source']['id'] not in {s['id'] for s in manifest['sources']}:raise ValueError('Unknown original source')
            analysis.validate_dynamic_request(payload,req)
        except (ValueError,KeyError,TypeError,OSError) as error:
            deferred.append({'request_id':rid,'error':str(error)});continue
        record=analysis.record_supplement_decision(manifest,rid,'accept','ROOT',reason+'; anchored_dynamic_v1')
        accepted.append(record['request_id'])
    return {'accepted':accepted,'deferred_to_existing_ROOT_review':deferred,'policy':'anchored_dynamic_v1'}

def prepare(manifest):
    m=manifest;pending=[r for r in m.get('supplemental_pending',[]) if m.get('supplemental_decisions',{}).get(digest(r),{}).get('decision')=='accept']
    if not pending:return {'packages':[],'awaiting_root_decision':len(m.get('supplemental_pending',[]))}
    m.setdefault('supplemental_round',{'number':1,'request_ids':[digest(r) for r in pending],'started':dt.datetime.now(dt.timezone.utc).isoformat()})
    created=[]
    for source in m['sources']:
        intervals=[]
        for req in pending:
            if req['source_id']!=source['id']:continue
            before,after=(0,0) if req.get('purpose')=='dynamic' else (15,30)
            intervals.append([max(0,req['start']-before),min(source['duration'],req['end']+after),{digest(req)}])
        merged=[]
        for a,b,ids in sorted(intervals):
            if merged and a<=merged[-1][1]:merged[-1][1]=max(b,merged[-1][1]);merged[-1][2].update(ids)
            else:merged.append([a,b,ids])
        for number,(a,b,ids) in enumerate(merged):
            preview=media.preview_spec(source,m['config'].get('preview_luts'));key=digest({'source':source['id'],'interval':[a,b],'preview':preview,'mode':'shot_v1'})[:16]
            plan=m.setdefault('supplemental_plans',{}).setdefault(key,{'source_id':source['id'],'start':a,'end':b,'request_ids':sorted(ids),'mode':'shot_v1','extraction_complete':False,'package_ids':[]})
            if plan['extraction_complete']:continue
            if b-a<1/source['fps']:raise ValueError('Supplement interval too short for distinct frames')
            times=sorted(set([a+n/2 for n in range(math.ceil((b-a)*2)) if a+n/2<b-1/source['fps']]+[max(a,b-1/source['fps'])]))
            if not media.unchanged(source):raise ValueError('Supplement source/sidecar identity changed')
            frames=plan.get('extracted_frames')
            if frames is None:
                frames=[]
                for block in media.blocks_for(times,source['duration']):
                    block['start']=max(a,block['start']);block['end']=min(b,block['end']);block['index']+=20000+number*100
                    frames+=media.extract_block(m['config']['ffmpeg'],source,block,Path(m['temp_dir'])/'supplement'/key/f'b{block["index"]}',m['hardware']['selected'],preview=preview)
                for f in frames:f['sha256']=file_hash(f['path'])
                plan['extracted_frames']=frames
                dump(Path(m['state_dir'])/'manifest.json',m)
            elif any(file_hash(f['path'])!=f['sha256'] for f in frames):raise ValueError('Frozen supplemental images changed; restore original evidence')
            known={f['id'] for f in m.get('supplemental_frames',[])};m.setdefault('supplemental_frames',[]).extend(f for f in frames if f['id'] not in known);m['temporary_artifacts'] += [f['path'] for f in frames]
            for p in analysis.make_packages(source,frames,[],Path(m['temp_dir'])/'packages',size=16,visual_mode='shot_review_v1'):
                p.update(source_id=source['id'],supplemental=True,supplement_key=key,shot_review=True)
                existing=next((old for old in m['packages'] if old['id']==p['id']),None)
                if existing is None:m['packages'].append(p);existing=p
                dump(Path(m['state_dir'])/'manifest.json',m)
                payload=read(p['path']);shot_work.add_packet(Path(m['state_dir'])/'shot-review',source,payload,existing)
                if p['id'] not in plan['package_ids']:plan['package_ids'].append(p['id'])
                created.append(p['id']);m['temporary_artifacts'] += [p['path'],p['result_path']]
            plan['extraction_complete']=True
            dump(Path(m['state_dir'])/'manifest.json',m)
    return {'packages':created,'mode':'shot_v1','coverage':'all accepted intervals retained; no duration truncation'}

def import_successes(m):
    root=Path(m['state_dir'])/'shot-review'
    if not (root/'work.json').exists():return False
    data=read(root/'work.json');changed=False
    for job in data['jobs'].values():
        if job['status']!='success' or not job.get('origin'):continue
        origin=job['origin'];p=next(p for p in m['packages'] if p['id']==origin['package_id'])
        if p['path']!=origin['package_path'] or p['result_path']!=origin['result_path'] or file_hash(p['path'])!=origin['package_sha256']:raise ValueError('Original supplemental package identity changed')
        record=read(job['accepted_path'])
        if shot_review.validated_record(record['task_path'],record['result_path'])!=record:raise ValueError('Accepted max shot evidence changed')
        v=record['result'];facts={'package_id':p['id'],'analysed_frame_ids':v['observed_frame_ids'],'observations':v['observations'],'events':[],'interest_points':[],'supplemental_requests':[],'summary':v['summary']}
        analysis.validate_result(read(p['path']),facts)
        identity={'accepted_path':job['accepted_path'],'accepted_sha256':file_hash(job['accepted_path']),'review_id':record['review_id'],'result_sha256':record['result_sha256']}
        old=m.setdefault('shot_records',{}).get(p['id'])
        if old==identity:continue
        if old:raise ValueError('Previously imported shot record changed; use explicit targeted revision')
        dump(p['result_path'],facts);m['shot_records'][p['id']]=identity;analysis.invalidate_downstream(m,'new max supplement evidence');changed=True
    return changed

def trusted_records(m):
    records={}
    for item in m.get('shot_records',{}).values():
        record=read(item['accepted_path'])
        if file_hash(item['accepted_path'])!=item['accepted_sha256'] or shot_review.validated_record(record['task_path'],record['result_path'])!=record:raise ValueError('Shot accepted evidence changed')
        records[item['review_id']]=record
    return records

def daily_changes(m):
    values=[]
    for record in trusted_records(m).values():
        for c in record['result']['changes']:values.append({'review_id':record['review_id'],'change':c})
    return values

def validate_daily_changes(m,entries):
    records=trusted_records(m)
    for item in entries:
        if set(item)!={'review_id','change'} or item['review_id'] not in records:raise ValueError('Daily visual change needs a validated shot review')
        record=records[item['review_id']];task=read(record['task_path']);value=copy.deepcopy(record['result']);value['changes']=[item['change']];value['candidate_ranges']=[]
        shot_review.validate_value(task,value)
    return entries
