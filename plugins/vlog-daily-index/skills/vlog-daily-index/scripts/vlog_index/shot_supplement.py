"""Upgrade the existing one-round supplement queue to single-pass max review."""
from pathlib import Path
import copy, math, datetime as dt
from . import analysis, media, shot_work, shot_review
from .store import digest, dump, read, file_hash

def accept_dynamic(manifest,reviewer,reason,source_ids=None):
    if reviewer!='ROOT' or not reason.strip():raise ValueError('Batch acceptance needs ROOT authorization evidence')
    if manifest['config'].get('supplement_mode')!='shot_v1':return {'accepted':[],'reason':'Existing run keeps its legacy supplement mode'}
    accepted=[];deferred=[]
    sources={s['id']:s for s in manifest['sources']}
    if source_ids and not set(source_ids)<=set(sources):raise ValueError('Unknown selected supplement source')
    for req in list(manifest.get('supplemental_pending',[])):
        rid=digest(req)
        if req.get('purpose')!='dynamic':continue
        if source_ids and req.get('source_id') not in source_ids:continue
        try:
            p=next((p for p in manifest['packages'] if p['id']==req.get('package_id')),None)
            if p is None or p['status']!='success':raise ValueError('Dynamic policy needs its original successfully imported initial package')
            payload=read(p['path'])
            if payload['source']['id'] not in {s['id'] for s in manifest['sources']}:raise ValueError('Unknown original source')
            analysis.validate_dynamic_request(payload,req,source=sources[req['source_id']])
        except (ValueError,KeyError,TypeError,OSError) as error:
            deferred.append({'request_id':rid,'error':str(error),'next_action':'decide-supplement','decision':'reject','reason':'Reject an unexecutable proposal explicitly; do not silently expand or fabricate coverage'});continue
        record=analysis.record_supplement_decision(manifest,rid,'accept','ROOT',reason+'; anchored_dynamic_v1')
        accepted.append(record['request_id'])
    return {'accepted':accepted,'deferred_to_existing_ROOT_review':deferred,'policy':'anchored_dynamic_v1'}

def prepare(manifest,source_ids=None,extraction_options=None):
    m=manifest;pending=[r for r in m.get('supplemental_pending',[]) if m.get('supplemental_decisions',{}).get(digest(r),{}).get('decision')=='accept' and (not source_ids or r['source_id'] in source_ids)]
    if source_ids and not set(source_ids)<={s['id'] for s in m['sources']}:raise ValueError('Unknown selected supplement source')
    if not pending:return {'packages':[],'awaiting_root_decision':len(m.get('supplemental_pending',[]))}
    # Freeze all proposals already present, including still-undecided geography.
    # Never migrate an older running round or accept proposals from a second round.
    m.setdefault('supplemental_round',{'number':1,'request_ids':[digest(r) for r in m.get('supplemental_pending',[])],'started':dt.datetime.now(dt.timezone.utc).isoformat()})
    created=[];errors=[]
    options=extraction_options if extraction_options is not None else ({'select_before_download':True} if m['config'].get('extraction_pipeline')=='select_first_v3' else {})
    for source in m['sources']:
        if source_ids and source['id'] not in source_ids:continue
        intervals=[]
        existing_plans=[p for p in m.get('supplemental_plans',{}).values() if p['source_id']==source['id']]
        planned_ids={rid for p in existing_plans for rid in p['request_ids']}
        for req in pending:
            if req['source_id']!=source['id'] or digest(req) in planned_ids:continue
            if req.get('purpose')=='dynamic':
                try:
                    original=next(p for p in m['packages'] if p['id']==req['package_id'])
                    analysis.validate_dynamic_request(read(original['path']),req,source=source)
                except (ValueError,KeyError,TypeError,OSError,StopIteration) as error:
                    errors.append({'source_id':source['id'],'request_ids':[digest(req)],'error':str(error),'next_action':'root_supplement_recovery'});continue
            before,after=(0,0) if req.get('purpose')=='dynamic' else (15,30)
            intervals.append([max(0,req['start']-before),min(source['duration'],req['end']+after),{digest(req)}])
        merged=[]
        for a,b,ids in sorted(intervals):
            if merged and a<=merged[-1][1]:merged[-1][1]=max(b,merged[-1][1]);merged[-1][2].update(ids)
            else:merged.append([a,b,ids])
        # Existing plans retain their own interval/member identity even when a
        # previously undecided request from this round is accepted later.
        merged += [[p['start'],p['end'],set(p['request_ids'])] for p in existing_plans if not p['extraction_complete']]
        for number,(a,b,ids) in enumerate(merged):
            try:
                preview=media.preview_spec(source,m['config'].get('preview_luts'));key=digest({'source':source['id'],'interval':[a,b],'preview':preview,'mode':'shot_v1'})[:16]
                plan=m.setdefault('supplemental_plans',{}).setdefault(key,{'source_id':source['id'],'start':a,'end':b,'request_ids':sorted(ids),'mode':'shot_v1','extraction_complete':False,'package_ids':[]})
                # A later authorized proposal in the same round may need exactly
                # this evidence. Associate it without touching any frozen task.
                plan['request_ids']=sorted(set(plan['request_ids'])|ids)
                if plan['extraction_complete']:continue
                # Closed analytical envelope; decoding may include one frame period
                # beyond its last endpoint solely to retrieve that endpoint image.
                anchors=[]
                for req in pending:
                    if digest(req) in ids and req.get('purpose')=='dynamic':
                        original=next(p for p in m['packages'] if p['id']==req['package_id'])
                        frame_map={f['id']:f for f in read(original['path'])['frames']}
                        anchors.extend(frame_map[fid]['time'] for fid in req['evidence_ids'])
                times=analysis.dynamic_sample_times(source,a,b,anchors)
                if not media.unchanged(source):raise ValueError('Supplement source/sidecar identity changed')
                frames=plan.get('extracted_frames')
                if frames is None:
                    frames=[]
                    for block in media.blocks_for(times,source['duration']):
                        block['start']=max(a,block['start']);block['end']=min(source['duration'],b+1/source['fps'],block['end']);block['index']+=20000+number*100
                        frames+=media.extract_block(m['config']['ffmpeg'],source,block,Path(m['temp_dir'])/'supplement'/key/f'b{block["index"]}',m['hardware']['selected'],preview=preview,**options)
                    actual=[f['time'] for f in frames]
                    if len(set(actual))<2 or any(f['source_id']!=source['id'] or not a-1e-6<=f['time']<=b+1e-6 for f in frames):raise ValueError('Actual dynamic extraction lacks two source times inside the requested closed interval')
                    if anchors and (min(actual)>min(anchors)+1e-6 or max(actual)<max(anchors)-1e-6):raise ValueError('Actual extraction does not cover its verified source anchor envelope')
                    for f in frames:f['sha256']=file_hash(f['path'])
                    plan['extracted_frames']=frames
                    dump(Path(m['state_dir'])/'manifest.json',m)
                elif any(file_hash(f['path'])!=f['sha256'] for f in frames):raise ValueError('Frozen supplemental images changed; restore original evidence')
                known={f['id'] for f in m.get('supplemental_frames',[])};m.setdefault('supplemental_frames',[]).extend(f for f in frames if f['id'] not in known);m['temporary_artifacts'] += [f['path'] for f in frames]
                packets=plan.get('packages')
                if packets is None:
                    frozen=[p for p in m['packages'] if p['id'] in plan['package_ids']]
                    if frozen:
                        covered={fid for p in frozen for fid in read(p['path'])['core_frame_ids']}
                        if covered!={f['id'] for f in frames}:raise ValueError('Restore the complete original frozen package list for this legacy partial plan; do not rebuild under a new contract')
                        packets=frozen
                    else:packets=analysis.make_packages(source,frames,[],Path(m['temp_dir'])/'packages',size=16,visual_mode='shot_review_v1')
                    plan['packages']=packets
                    dump(Path(m['state_dir'])/'manifest.json',m)
                for p in packets:
                    p.update(source_id=source['id'],supplemental=True,supplement_key=key,shot_review=True)
                    existing=next((old for old in m['packages'] if old['id']==p['id']),None)
                    if existing is None:m['packages'].append(p);existing=p
                    dump(Path(m['state_dir'])/'manifest.json',m)
                    payload=read(existing['path']);shot_work.add_packet(Path(m['state_dir'])/'shot-review',source,payload,existing)
                    if p['id'] not in plan['package_ids']:plan['package_ids'].append(p['id'])
                    created.append(p['id']);m['temporary_artifacts'] += [p['path'],p['result_path']]
                plan['extraction_complete']=True
                dump(Path(m['state_dir'])/'manifest.json',m)
            except (ValueError,KeyError,TypeError,OSError,RuntimeError) as error:
                errors.append({'source_id':source['id'],'request_ids':sorted(ids),'start':a,'end':b,'error':str(error),'next_action':'root_supplement_recovery'})
    dump(Path(m['state_dir'])/'manifest.json',m)
    return {'packages':created,'errors':errors,'mode':'shot_v1','coverage':'all accepted requests retained; errors remain explicitly unfinished'}

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
        record=records[item['review_id']]
        if item['change'] not in record['result']['changes']:raise ValueError('Daily visual change must exactly match an accepted canonical fact; narrative summary is separate')
    return entries
