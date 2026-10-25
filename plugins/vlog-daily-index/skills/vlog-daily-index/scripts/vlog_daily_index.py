"""Small explicit CLI; the host session (ROOT) owns vision Agent dispatch, not this program."""
from __future__ import annotations
import argparse, datetime as dt, json, os, platform, sys, time
from pathlib import Path
deps=os.environ.get('VLOG_INDEX_DEPS')
if deps: sys.path.insert(0,str(Path(deps)))
from vlog_index.store import State,RunLock,dump,read,digest,cleanup_registered
from vlog_index import media,analysis,asr,report,store

HOST_MODEL_ROLES={
    'codex':{'vision':'Luna','semantic':'gpt-6.1-sol','semantic_reasoning_effort':'high','final_review':'ROOT_current_flagship','supplement_decision':'ROOT'},
    'claude-code':{'vision':'vlog-daily-index:vlog-vision','semantic':'vlog-daily-index:vlog-semantic','semantic_reasoning_effort':'high','final_review':'ROOT','supplement_decision':'ROOT'}}

def save(m): dump(Path(m['state_dir'])/'manifest.json',m)
def load(args): return read(Path(args.state)/'manifest.json')

def extraction_options(m,frame=None):
    pipeline=frame.get('extraction_pipeline') if frame is not None else m['config'].get('extraction_pipeline')
    return {'select_before_download':True} if pipeline=='select_first_v3' else {}

def init(args):
    if not 1<=args.vision_concurrency<=6: raise ValueError('vision_concurrency upper bound must be 1..6')
    source=Path(args.source).resolve()
    if not source.is_dir(): raise FileNotFoundError('Source root unavailable; pause, do not copy sources')
    run_id=args.run_id or dt.datetime.now().strftime('%Y%m%dT%H%M%S')+'-'+digest(str(source))[:8]
    state=Path(args.state).resolve(); temp=(Path(args.temp).resolve()/run_id)
    if state.exists() and (state/'manifest.json').exists(): raise ValueError('State already exists; resume existing run')
    for root in (state,temp):
        if source==root or source in root.parents or root==source.parent: raise ValueError('State/temp must be local and outside source tree')
        if str(root).startswith('\\\\') or any('onedrive' in p.lower() for p in root.parts): raise ValueError('State/temp must be local and outside synchronized folders')
        if os.name=='nt':
            import ctypes
            if ctypes.windll.kernel32.GetDriveTypeW(str(root.anchor))==4: raise ValueError('State/temp cannot use mapped network drives')
        root.mkdir(parents=True,exist_ok=True)
    files=sorted(p for p in source.rglob('*') if p.is_file() and p.suffix.lower() in ('.mp4','.mov','.mkv','.mts'))
    m={'run_id':run_id,'state_dir':str(state),'temp_dir':str(temp),'status':'running','temporary_artifacts':[],'frames':[],'packages':[],'transcription':{},'config':{'source_root':str(source),'date':args.date,'timezone':'Asia/Shanghai','ffmpeg':args.ffmpeg,'ffprobe':args.ffprobe,'asr_service':args.service,'asr_model':asr.MODEL,'asr_concurrency':1,'vision_concurrency':args.vision_concurrency,'sample_interval':10,'schema_version':analysis.SCHEMA_VERSION,'prompt_version':analysis.PROMPT_VERSION},'sources':[],'versions':{'python':platform.python_version()}}
    host=getattr(args,'host','codex'); m['config']['host']=host; m['config']['model_roles']=dict(HOST_MODEL_ROLES[host])
    m['config'].update(visual_package_mode='block_visual_v1',extraction_pipeline='select_first_v3',ready_package_limit=24,temp_limit_bytes=256*1024**3,min_free_bytes=5*1024**3)
    m['config']['asr_model']=getattr(args,'asr_model',asr.MODEL)
    if getattr(args,'preview_lut_map',None):
        map_file=Path(args.preview_lut_map).resolve(); mapping=read(map_file)
        if not isinstance(mapping,dict) or not all(isinstance(k,str) and isinstance(v,str) for k,v in mapping.items()): raise ValueError('Preview LUT map must contain device:token to local .cube path strings')
        m['config']['preview_luts']={k:str((map_file.parent/Path(v)).resolve()) for k,v in mapping.items()}
    for path in files:
        s=media.probe(path,args.ffprobe,source); m['sources'].append(s); save(m)
        print(json.dumps({'probed':s['relative_path'],'status':s['status'],'duration':s.get('duration'),'role':s.get('role')},ensure_ascii=False),flush=True)
    State(state).close(); save(m)
    return {'run_id':run_id,'state':str(state),'source_count':len(files),'planned_frames':sum(len(s.get('sample_times',[])) for s in m['sources'])}

def selected_sources(m,args):
    sources=[s for s in m['sources'] if s['status']=='ready']
    if getattr(args,'source_id',None): sources=[s for s in sources if s['id'] in args.source_id or s['relative_path'] in args.source_id]
    return sources

def hardware(args):
    m=load(args); source=selected_sources(m,args)[0]
    analysis.validate_itinerary(m.get('itinerary',{}).get('data'))
    result=media.select_hardware(m['config']['ffmpeg'],source['path'],Path(m['temp_dir'])/'hardware')
    profile_path=media.machine_profile_path()
    if m['config'].get('extraction_pipeline')=='select_first_v3' and profile_path.exists():
        profile=read(profile_path); slots=profile['validated_slots']
        if not 1<=len(slots)<=4: raise ValueError('Invalid local media-slot profile')
        media.check_slot_devices(slots); m['config']['media_slots']=slots
        m['config']['media_hardware_evidence']={'path':str(profile_path.resolve()),'sha256':digest(profile)}
        result['media_profile']={'path':str(profile_path.resolve()),'slots':len(slots)}
    m['hardware']=result; m['temporary_artifacts']+=list(map(str,(Path(m['temp_dir'])/'hardware').glob('*.jpg'))); save(m)
    dump(Path(m['state_dir'])/'hardware.json',result); return result

def hardware_benchmark(args):
    result=media.benchmark_summary(args.output) if args.summarize_only else media.hardware_benchmark(args.ffmpeg,args.ffprobe,args.output,args.source,args.start,args.seconds,args.tasks,args.compare_filter_order,[int(n) for n in args.profiles.split(',')],args.select_first_only)
    if args.save_profile:
        data=read(Path(args.output)/'hardware-benchmark.json'); media.check_slot_devices(data['validated_slots'])
        profile={'schema':1,'validated_slots':data['validated_slots'],'adapters':data['adapters'],'ffmpeg_version':data['ffmpeg_version'],
                 'evidence_report_sha256':digest(data),'registered_at':dt.datetime.now(dt.timezone.utc).isoformat(),
                 'measurements':[{'name':p['name'],'wall_seconds':p['wall_seconds'],'image_count':p.get('image_count')} for p in data['profiles']]}
        path=media.machine_profile_path(); dump(path,profile); result['machine_profile']=str(path.resolve())
    return result

def configure_concurrency(args):
    m=load(args); count=args.media_slots
    if count not in (1,2,3,4) or not 1<=args.vision_concurrency<=6: raise ValueError('Media slots 1..4; vision worker upper bound 1..6')
    evidence_path=Path(args.hardware_report) if args.hardware_report else media.machine_profile_path()
    report_data=read(evidence_path) if evidence_path.exists() else None
    if count>1:
        if not report_data or len(report_data.get('validated_slots',[]))<count: raise ValueError('Multiple media slots require a successful fixed hardware benchmark report')
        slots=report_data['validated_slots'][:count]
        if any(slot['backend']!='qsv' for slot in slots): raise ValueError('Expected benchmark-verified QSV device slots')
        media.check_slot_devices(slots)
        m['config']['media_hardware_evidence']={'path':str(evidence_path.resolve()),'sha256':digest(report_data)}
    else: slots=[m['hardware']['selected']]
    if args.ready_package_limit<1 or args.temp_limit_gib<=0 or args.min_free_gib<0: raise ValueError('Invalid queue/disk thresholds')
    m['config'].update(media_slots=slots,vision_concurrency=args.vision_concurrency,ready_package_limit=args.ready_package_limit,
                       temp_limit_bytes=int(args.temp_limit_gib*1024**3),min_free_bytes=int(args.min_free_gib*1024**3))
    save(m); return {'media_slots':slots,'vision_upper_bound':args.vision_concurrency,'visual_package_mode':m['config'].get('visual_package_mode','legacy'),'asr_concurrency':1}

def vision_queue(args):
    """Dispatch ledger uses its own lock: long media runs never lock out the host session."""
    root=Path(args.state)/'vision-dispatch'
    if args.available_workers<0 or args.reserve_sol<0: raise ValueError('Actual free workers and reserved workers must be nonnegative')
    with RunLock(root):
        m=load(args); path=root/'claims.json'; claims=read(path) if path.exists() else {}
        for pid in getattr(args,'release',[]) or []: claims.pop(pid,None)
        waiting=[p for p in m['packages'] if p['status']=='waiting_ai']
        awaiting_validation=[p for p in waiting if p.get('result_path') and Path(p['result_path']).exists()]
        ready=[p for p in waiting if p['id'] not in claims and p not in awaiting_validation]
        claimed=sum(p['id'] in claims for p in waiting)
        available=max(0,args.available_workers-args.reserve_sol)
        recommended=min(max(0,min(6,m['config'].get('vision_concurrency',2))-claimed),available,len(ready))
        workers=getattr(args,'claim_worker',[]) or []
        if len(workers)!=len(set(workers)) or len(workers)>recommended: raise ValueError('Claims exceed actual free host capacity or contain duplicate workers')
        assigned=[]
        for worker,package in zip(workers,ready):
            if any(c['worker']==worker and c['package_id'] in {p['id'] for p in waiting} for c in claims.values()): raise ValueError('Worker already owns an unfinished package')
            record={'worker':worker,'package_id':package['id'],'at':dt.datetime.now(dt.timezone.utc).isoformat()}
            claims[package['id']]=record; assigned.append({**package,'claim':record})
        if workers or getattr(args,'release',None): dump(path,claims)
        return {'ready_count':len(waiting),'awaiting_validation_count':len(awaiting_validation),'claimed_count':claimed+len(assigned),'unassigned_count':len(ready)-len(assigned),'recommended_vision_workers':recommended,
                'host_available_workers':args.available_workers,'reserved_for_sol':args.reserve_sol,'assigned':assigned,
                'unassigned_packages':[p for p in ready if p['id'] not in claims],'claims_path':str(path)}

def media_pressure(m):
    """Pause instead of deleting unpublished evidence or clipping coverage."""
    import shutil
    pending=sum(p['status']!='success' for p in m['packages'])
    total=sum(Path(p).stat().st_size for p in set(m.get('temporary_artifacts',[])) if Path(p).is_file())
    free=shutil.disk_usage(m['temp_dir']).free
    reason='ready_package_limit' if pending>=m['config'].get('ready_package_limit',24) else 'temp_limit_bytes' if total>=m['config'].get('temp_limit_bytes',256*1024**3) else 'min_free_bytes' if free<m['config'].get('min_free_bytes',5*1024**3) else None
    return {'reason':reason,'pending_packages':pending,'registered_temp_bytes':total,'free_bytes':free}

def stable_block_packages(m,source,block,gps_data):
    frames=sorted((f for f in m['frames'] if f['source_id']==source['id'] and f['id'].startswith(f'{source["id"]}-b{block["index"]:03}-')),key=lambda f:f['time'])
    if len(frames)!=len(block['samples']): raise ValueError('Only a fully committed stable block may publish visual packages')
    if any(p.get('source_id')==source['id'] and p.get('block_index')==block['index'] for p in m['packages']): return []
    from vlog_index.gps import locate_media
    md=source['metadata']; locations=[]
    for frame in frames:
        timestamp=(dt.datetime.fromisoformat(md['captured_at_utc'])+dt.timedelta(seconds=frame['time'])).isoformat() if md.get('captured_at_utc') else None
        loc=locate_media(gps_data or {},timestamp,time_mapping_verified=md.get('time_verified',False),playback_rate_verified=md.get('playback_rate_verified',False),device_with_garmin=bool(gps_data),drone_srt_points=md.get('location_points') if source['role']=='drone' else None,video_seconds=frame['time'])
        if loc: locations.append({'frame_id':frame['id'],**loc})
    created=analysis.make_packages(source,frames,[],Path(m['temp_dir'])/'packages',gps=locations,visual_mode='block_visual_v1')
    for package in created:
        package.update(source_id=source['id'],block_index=block['index'],visual_mode='block_visual_v1'); m['packages'].append(package)
        m['temporary_artifacts'] += [package['path'],package['result_path']]
    dump(Path(m['state_dir'])/'ready-packages.json',[p for p in m['packages'] if p['status']=='waiting_ai']); save(m)
    return created

def prepare(args):
    m=load(args)
    analysis.validate_itinerary(m.get('itinerary',{}).get('data'))
    if 'hardware' not in m: raise ValueError('Run hardware sample first')
    state=State(m['state_dir']); completed=0
    try:
        for source in selected_sources(m,args):
            preview=media.preview_spec(source,m['config'].get('preview_luts')); source['preview']=preview
            skip=asr.audio_plan(source)
            if skip['status'] in ('skipped_drone','no_audio'):
                m['transcription'][source['id']]={'status':skip['status'],'segments':[],'requests':0}
                save(m)
            for block in source['blocks']:
                key=media.extraction_key(source,block,preview,m['config'].get('extraction_pipeline'))
                cache=state.get(key)
                if cache and cache['status']=='success' and all(Path(f['path']).exists() for f in cache['payload']['frames']):
                    known={f['id'] for f in m['frames']}
                    m['frames'] += [f for f in cache['payload']['frames'] if f['id'] not in known]
                    save(m); continue
                state.put(key,'media','running',{'source_id':source['id'],'block':block})
                directory=Path(m['temp_dir'])/'frames'/source['id']/f'b{block["index"]:03}'
                candidates=media.hardware_candidates(m['hardware']['adapters']); current=m['hardware']['selected']
                begin=next((i for i,c in enumerate(candidates) if c==current),0); frames=None
                for candidate in candidates[begin:]:
                    try:
                        frames=media.extract_block(m['config']['ffmpeg'],source,block,directory,candidate,preview=preview,**extraction_options(m)); break
                    except Exception as e:
                        m.setdefault('media_errors',[]).append({'source':source['id'],'block':block['index'],'hardware':candidate,'error':str(e)}); save(m)
                        # Never persistently blacklist hardware for source corruption/NAS errors.
                if frames is None:
                    state.put(key,'media','failed',m['media_errors'][-1]); continue
                if not media.unchanged(source): raise RuntimeError('source changed during processing')
                m['frames']=[f for f in m['frames'] if not (f['source_id']==source['id'] and f['id'].split('-b')[-1].startswith(f'{block["index"]:03}-'))]+frames
                m['temporary_artifacts']+= [f['path'] for f in frames]
                state.put(key,'media','success',{'frames':frames}); save(m); completed+=1
                print(json.dumps({'source':source['relative_path'],'block':block['index'],'frames':len(frames)},ensure_ascii=False),flush=True)
                if args.blocks and completed>=args.blocks: return {'processed_blocks':completed,'paused_at_batch_boundary':True}
    finally: state.close()
    return {'processed_blocks':completed,'frames':len(m['frames'])}

def packages(args,manifest=None):
    m=manifest if manifest is not None else load(args); created=[]
    gps_data=read(args.gps) if args.gps else None
    if gps_data: m['gps']={'path':args.gps,'quality':gps_data.get('quality'),'stops':gps_data.get('stops'),'gaps':gps_data.get('gaps')}
    if m['config'].get('visual_package_mode')=='block_visual_v1':
        for source in selected_sources(m,args):
            for block in source['blocks']:
                matching=[f for f in m['frames'] if f['source_id']==source['id'] and f['id'].startswith(f'{source["id"]}-b{block["index"]:03}-')]
                if len(matching)==len(block['samples']): created+=stable_block_packages(m,source,block,gps_data)
        save(m); return created
    for source in selected_sources(m,args):
        frames=sorted((f for f in m['frames'] if f['source_id']==source['id']),key=lambda f:f['time'])
        if not frames: continue
        previous=[p for p in m['packages'] if p.get('source_id')==source['id'] and not p.get('supplemental')]
        if previous and m['config'].get('prompt_version','1')!=analysis.PROMPT_VERSION and not getattr(args,'refresh',False) and {fid for p in previous for fid in p['core_frame_ids']}=={f['id'] for f in frames}: continue
        if previous and getattr(args,'refresh',False): analysis.invalidate_downstream(m,'Explicit visual-prompt package refresh')
        if source['metadata'].get('location_points') and 'start_seconds' not in source['metadata']['location_points'][0] and not any(p.get('source_id')==source['id'] for p in m['packages']):
            source['metadata']=media.metadata(Path(source['path']))
        tr=m['transcription'].get(source['id'],{}).get('segments',[])
        locations=[]
        if gps_data or source['metadata'].get('location_points'):
            from vlog_index.gps import locate_media
            for frame in frames:
                md=source['metadata']; timestamp=None
                if md.get('captured_at_utc'): timestamp=(dt.datetime.fromisoformat(md['captured_at_utc'])+dt.timedelta(seconds=frame['time'])).isoformat()
                location=locate_media(gps_data or {},timestamp,time_mapping_verified=md['time_verified'],playback_rate_verified=md['playback_rate_verified'],device_with_garmin=bool(gps_data) or source['id'] in (args.garmin_companion or []),drone_srt_points=md['location_points'] if source['role']=='drone' else None,video_seconds=frame['time'])
                if location: locations.append({'frame_id':frame['id'],**location})
        new=analysis.make_packages(source,frames,tr,Path(m['temp_dir'])/'packages',gps=locations)
        existing={p['id']:p for p in m['packages']}
        valid={p['id'] for p in new}
        m['packages']=[p for p in m['packages'] if p.get('supplemental') or p.get('source_id')!=source['id'] or p['id'] in valid]
        for p in new:
            if p['id'] in existing: continue
            p['source_id']=source['id']
            m['packages'].append(p); m['temporary_artifacts'].append(p['path']); created.append(p)
    dump(Path(m['state_dir'])/'ready-packages.json',[p for p in m['packages'] if p['status']=='waiting_ai'])
    save(m); return created

def import_results(args,manifest=None):
    m=manifest if manifest is not None else load(args); state=State(m['state_dir']); imported=[]; errors=[]
    try:
        for p in m['packages']:
            if getattr(args,'source_id',None) and p.get('source_id') not in args.source_id: continue
            if p['status']=='invalid' and not getattr(args,'refresh',False): continue
            if (p['status']=='success' and not getattr(args,'refresh',False)) or not Path(p['result_path']).exists(): continue
            try:
                result=analysis.validate_result(read(p['path']),read(p['result_path']))
                state.put(p['id'],'analysis','success',result); p['status']='success'; imported.append(p['id'])
                if not p.get('supplemental'):
                    for req in result['supplemental_requests']:
                        candidate={'package_id':p['id'],**req}; request_id=digest(candidate)
                        rejected=m.get('supplemental_decisions',{}).get(request_id,{}).get('decision')=='reject'
                        if not rejected and not any(digest(r)==request_id for r in m.setdefault('supplemental_pending',[])): m['supplemental_pending'].append(candidate)
                dump(Path(m['state_dir'])/'analysis'/(p['id']+'.json'),result)
                if p['result_path'] not in m['temporary_artifacts']: m['temporary_artifacts'].append(p['result_path'])
            except Exception as e:
                p['status']='invalid'; p['error']=str(e); p['invalid_result_sha256']=store.file_hash(p['result_path'])
                errors.append({'package':p['id'],'error':str(e)})
        save(m)
    finally: state.close()
    return {'imported':imported,'errors':errors}

def retry_visual(args):
    """One explicit correction after coordinator pause; preserve the invalid evidence."""
    import shutil
    m=load(args); package=next((p for p in m['packages'] if p['id']==args.package_id),None)
    if not package or package['status']!='invalid' or not args.reason.strip(): raise ValueError('Correction requires an invalid package and ROOT evidence reason')
    if package.get('correction_attempts',0)>=1: raise ValueError('One visual correction already attempted; preserve invalid state for ROOT review')
    result=Path(package['result_path']); archived=None
    if result.exists():
        if package.get('invalid_result_sha256') and store.file_hash(result)!=package['invalid_result_sha256']: raise ValueError('Result changed after failure; explicitly import-results --refresh to validate it instead of discarding it')
        archived=Path(m['state_dir'])/'invalid-visual'/(package['id']+'.result.json'); archived.parent.mkdir(parents=True,exist_ok=True)
        if archived.exists(): raise ValueError('Previous correction archive already exists')
        shutil.copyfile(result,archived)
        if store.file_hash(archived)!=store.file_hash(result): raise ValueError('Invalid-result archive readback mismatch')
        result.unlink()
    root=Path(m['state_dir'])/'vision-dispatch'
    with RunLock(root):
        path=root/'claims.json'; claims=read(path) if path.exists() else {}; claims.pop(package['id'],None); dump(path,claims)
    package.update(status='waiting_ai',correction_attempts=1,correction_reason=args.reason,invalid_result_archive=str(archived) if archived else None)
    save(m); return {'package_id':package['id'],'status':'waiting_ai','correction_attempt':1,'archive':str(archived) if archived else None}

def continue_day(args):
    m=load(args)
    if m['config'].get('visual_package_mode')!='block_visual_v1' and len(m['config'].get('media_slots',[]))<=1:
        return _continue_day_serial(args)
    return _continue_day_parallel(args)

def _continue_day_parallel(args):
    """Bounded FFmpeg device slots, one ASR request, one manifest/SQLite writer."""
    from concurrent.futures import ThreadPoolExecutor,wait,FIRST_COMPLETED
    from types import SimpleNamespace
    m=load(args); protocol=read(args.protocol); analysis.validate_itinerary(m.get('itinerary',{}).get('data'))
    slots=m['config'].get('media_slots') or [m['hardware']['selected']]
    if not 1<=len(slots)<=4: raise ValueError('Configure one to four verified media slots')
    media.check_slot_devices(slots)
    client=asr.ASRClient(m['config']['asr_service'],m['state_dir'],protocol,concurrency=1,model=m['config']['asr_model']); client.preflight()
    state=State(m['state_dir']); pause=Path(m['state_dir'])/'pause-media.request'; gps_data=read(args.gps) if args.gps else None
    if gps_data: m['gps']={'path':args.gps,'quality':gps_data.get('quality'),'stops':gps_data.get('stops',[]),'gaps':gps_data.get('gaps',[]),'companion_confirmed':True}
    visual=m['config'].get('visual_package_mode')=='block_visual_v1'
    contexts=[]; media_jobs=[]; audio_jobs=[]; active={}; stopped=False; last_import=0
    analysed={fid for p in m['packages'] if p['status']=='success' for fid in p['core_frame_ids']}
    def ready_chunks(ctx):
        for job in list(ctx['waiting']):
            if media.cut_audio_blocks(ctx['audio_blocks'],job['chunk']['start'],job['chunk']['end'],job['wav']):
                audio_jobs.append(job); ctx['waiting'].remove(job)
    def extract(job,slot):
        source=job['source']; block=job['block']; errors=[]
        if not job['need_frames']:
            media.extract_audio(m['config']['ffmpeg'],source,block['start'],block['end'],job['audio_output']); return [],errors
        primary=slots[slot]; candidates=[primary]
        if primary['backend']=='qsv': candidates.append({'backend':'d3d11va','adapter':primary['adapter']})
        if primary['backend']!='cpu': candidates.append({'backend':'cpu','adapter':None})
        directory=Path(m['temp_dir'])/'frames'/source['id']/f'b{block["index"]:03}'
        for candidate in candidates:
            try: return media.extract_block(m['config']['ffmpeg'],source,block,directory,candidate,audio_output=job['audio_output'],preview=source.get('preview'),**extraction_options(m)),errors
            except media.SamplingPlanError: raise
            except Exception as error: errors.append({'source':source['id'],'block':block['index'],'hardware':candidate,'error':str(error)})
        raise RuntimeError(json.dumps(errors,ensure_ascii=False))
    try:
        for source in selected_sources(m,args):
            source['preview']=media.preview_spec(source,m['config'].get('preview_luts')); plan=asr.audio_plan(source)
            entry=m['transcription'].setdefault(source['id'],{'status':plan['status'],'precision':'chunk','segments':[]})
            blocks=m.setdefault('audio_blocks',{}).setdefault(source['id'],[])
            blocks[:]=[b for b in blocks if media.valid_audio(b['path'],b['end']-b['start'])]
            ctx={'source':source,'plan':plan,'entry':entry,'audio_blocks':blocks,'waiting':[],'media_remaining':0,'finished':False,'chunk_keys':set()}; contexts.append(ctx)
            if not plan['chunks']: entry.update(status=plan['status'],requests=0)
            for chunk in plan['chunks']:
                key=digest({'source':source['id'],'chunk':chunk,'model':m['config']['asr_model'],'protocol':protocol,'audio':{'sample_rate':16000,'channels':1,'pcm':'s16le','version':1}}); ctx['chunk_keys'].add(key)
                cache=state.get(key)
                if cache and cache['status']=='success':
                    if not any(s['id']==key for s in entry['segments']): entry['segments'].append(cache['payload'])
                    continue
                directory=Path(m['temp_dir'])/'audio'/source['id']; directory.mkdir(parents=True,exist_ok=True)
                wav=directory/(key+'.wav'); raw=directory/(key+'.stream.json'); m['temporary_artifacts']+=list(map(str,(wav,raw)))
                job={'ctx':ctx,'chunk':chunk,'key':key,'wav':wav,'raw':raw}
                (audio_jobs if media.valid_audio(wav,chunk['end']-chunk['start']) else ctx['waiting']).append(job)
            entry['segments'].sort(key=lambda s:(s['start'],s['end'],s['id']))
            for block in source['blocks']:
                key=media.extraction_key(source,block,source['preview'],m['config'].get('extraction_pipeline')); cache=state.get(key)
                reusable=cache and cache['status']=='success' and (all(Path(f['path']).exists() for f in cache['payload']['frames']) or all(f['id'] in analysed for f in cache['payload']['frames']))
                if reusable:
                    known={f['id'] for f in m['frames']}; m['frames'] += [f for f in cache['payload']['frames'] if f['id'] not in known]
                    if visual: stable_block_packages(m,source,block,gps_data)
                affected=[job['chunk'] for job in ctx['waiting'] if job['chunk']['start']<block['end'] and job['chunk']['end']>block['start']]
                work=dict(block); audio_output=None
                if affected:
                    if reusable: work.update(start=max(block['start'],min(c['start'] for c in affected)),end=min(block['end'],max(c['end'] for c in affected)))
                    audio_output=Path(m['temp_dir'])/'audio'/source['id']/f'block-{block["index"]}-{work["start"]:.6f}-{work["end"]:.6f}.wav'
                    audio_output.parent.mkdir(parents=True,exist_ok=True); m['temporary_artifacts'].append(str(audio_output))
                    if media.valid_audio(audio_output,work['end']-work['start']):
                        record={'path':str(audio_output),'start':work['start'],'end':work['end']}
                        if record not in blocks: blocks.append(record)
                        audio_output=None
                if not reusable or audio_output:
                    work_key=key if not reusable else digest({'audio_block':source['id'],'start':work['start'],'end':work['end'],'version':1})
                    media_jobs.append({'ctx':ctx,'source':source,'block':work,'original_block':block,'key':work_key,'need_frames':not reusable,'audio_output':audio_output}); ctx['media_remaining']+=1
            ready_chunks(ctx)
        m['status']='running'; m['queue_state']={'effective_media_slots':slots,'asr_concurrency':1}; save(m)
        with ThreadPoolExecutor(max_workers=len(slots)) as media_pool,ThreadPoolExecutor(max_workers=1) as asr_pool:
            while media_jobs or audio_jobs or any(c['waiting'] for c in contexts) or active:
                if time.monotonic()-last_import>=2:
                    if any(p['status']=='waiting_ai' and Path(p['result_path']).exists() for p in m['packages']):
                        import_results(SimpleNamespace(state=args.state,source_id=None,refresh=False),manifest=m)
                    last_import=time.monotonic()
                previous_status=m['status']
                if pause.exists(): stopped=True; m['status']='paused'
                pressure=media_pressure(m); m['queue_state'].update(pressure)
                if pressure['reason'] and not stopped: stopped=True; m['status']='paused_backpressure'
                if m['status']!=previous_status: save(m)
                # Existing local audio may drain during disk/ready backpressure, but never after explicit pause/error.
                audio_allowed=not stopped or m['status']=='paused_backpressure'
                if audio_allowed and audio_jobs and not any(kind=='audio' for kind,_,_ in active.values()):
                    job=audio_jobs.pop(0); state.put(job['key'],'asr','running',job['chunk']); active[asr_pool.submit(client.transcribe,job['wav'],job['raw'])]=('audio',job,None)
                busy={slot for kind,_,slot in active.values() if kind=='media'}
                for slot in range(len(slots)):
                    if not stopped and slot not in busy and media_jobs:
                        job=media_jobs.pop(0); state.put(job['key'],'media','running',{'source_id':job['source']['id'],'block':job['block'],'slot':slot}); active[media_pool.submit(extract,job,slot)]=('media',job,slot)
                if not active:
                    if any(c['waiting'] for c in contexts) and not stopped: raise RuntimeError('Local audio blocks do not cover remaining ASR chunks')
                    break
                done,_=wait(active,timeout=1,return_when=FIRST_COMPLETED)
                for future in done:
                    kind,job,slot=active.pop(future); ctx=job['ctx']; source=ctx['source']
                    try: result=future.result()
                    except Exception as error:
                        state.put(job['key'],'asr' if kind=='audio' else 'media','unknown' if isinstance(error,asr.UnknownServerState) else 'failed',{'error':str(error)})
                        m.setdefault('run_errors',[]).append({'source':source['id'],'stage':kind,'error':str(error)}); stopped=True; m['status']='paused_error'; save(m); continue
                    if kind=='audio':
                        chunk=job['chunk']; segment={'id':job['key'],'source_id':source['id'],'start':chunk['start'],'end':chunk['end'],'core_start':chunk['core_start'],'core_end':chunk['core_end'],'text':result['text'],'precision':'chunk','overlap_policy':'preserved; boundary repetitions not deleted'}
                        state.put(job['key'],'asr','success',segment)
                        if not any(s['id']==segment['id'] for s in ctx['entry']['segments']): ctx['entry']['segments'].append(segment)
                        ctx['entry']['segments'].sort(key=lambda s:(s['start'],s['end'],s['id']))
                    else:
                        frames,errors=result
                        if not media.unchanged(source): raise RuntimeError('Source changed during extraction')
                        ids={f['id'] for f in frames}; m['frames']=[f for f in m['frames'] if f['id'] not in ids]+frames
                        m['temporary_artifacts'] += [f['path'] for f in frames]; m.setdefault('media_errors',[]).extend(errors)
                        if job['audio_output']:
                            record={'path':str(job['audio_output']),'start':job['block']['start'],'end':job['block']['end']}
                            if record not in ctx['audio_blocks']: ctx['audio_blocks'].append(record)
                        state.put(job['key'],'media','success',{'frames':frames,'audio':str(job['audio_output']) if job['audio_output'] else None}); ctx['media_remaining']-=1
                        ready_chunks(ctx)
                        if visual and job['need_frames']:
                            created=stable_block_packages(m,source,job['original_block'],gps_data)
                            if created: print(json.dumps({'ready_packages':[p['id'] for p in created],'source':source['relative_path'],'block':job['block']['index']},ensure_ascii=False),flush=True)
                    save(m)
                finished_changed=False
                for ctx in contexts:
                    completed={s['id'] for s in ctx['entry']['segments']}
                    if not ctx['finished'] and ctx['media_remaining']==0 and ctx['chunk_keys']<=completed:
                        if ctx['plan']['chunks']: ctx['entry']['status']='success'
                        ctx['finished']=True; finished_changed=True
                        if not visual and not any(p.get('source_id')==ctx['source']['id'] for p in m['packages']):
                            packages(SimpleNamespace(state=args.state,source_id=[ctx['source']['id']],gps=args.gps,garmin_companion=getattr(args,'garmin_companion',None)),manifest=m)
                if finished_changed: save(m)
        for ctx in contexts:
            if not ctx['finished'] and ctx['media_remaining']==0 and ctx['chunk_keys']<={s['id'] for s in ctx['entry']['segments']}:
                if ctx['plan']['chunks']: ctx['entry']['status']='success'
                ctx['finished']=True
                if not visual and not any(p.get('source_id')==ctx['source']['id'] for p in m['packages']):
                    packages(SimpleNamespace(state=args.state,source_id=[ctx['source']['id']],gps=args.gps,garmin_companion=getattr(args,'garmin_companion',None)),manifest=m)
        import_results(SimpleNamespace(state=args.state,source_id=None,refresh=False),manifest=m)
        m['queue_state'].update(media_pending=len(media_jobs),asr_local_pending=len(audio_jobs),waiting_audio_chunks=sum(len(c['waiting']) for c in contexts)); save(m)
        return {'status':m['status'],'queue_state':m['queue_state'],'coverage':report.coverage(m)}
    finally: state.close()

def _continue_day_serial(args):
    """One coordinator commits state; local-WAV ASR overlaps one NAS media reader."""
    from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
    from types import SimpleNamespace
    m=load(args); protocol=read(args.protocol); state=State(m['state_dir'])
    analysis.validate_itinerary(m.get('itinerary',{}).get('data'))
    client=asr.ASRClient(m['config']['asr_service'],m['state_dir'],protocol,concurrency=1,model=m['config']['asr_model']); client.preflight()
    pause=Path(m['state_dir'])/'pause-media.request'
    def media_worker(source,job):
        block,_,need_frames,audio_output=job
        if not need_frames:
            media.extract_audio(m['config']['ffmpeg'],source,block['start'],block['end'],audio_output)
            return [],[]
        errors=[]; directory=Path(m['temp_dir'])/'frames'/source['id']/f'b{block["index"]:03}'
        candidates=media.hardware_candidates(m['hardware']['adapters']); current=m['hardware']['selected']
        begin=next((i for i,c in enumerate(candidates) if c==current),0)
        for candidate in candidates[begin:]:
            try: return media.extract_block(m['config']['ffmpeg'],source,block,directory,candidate,audio_output=audio_output,preview=source.get('preview'),**extraction_options(m)),errors
            except media.SamplingPlanError: raise
            except Exception as e: errors.append({'source':source['id'],'block':block['index'],'hardware':candidate,'error':str(e)})
        raise RuntimeError(json.dumps(errors,ensure_ascii=False))
    try:
        with ThreadPoolExecutor(max_workers=1) as media_pool, ThreadPoolExecutor(max_workers=1) as asr_pool:
            for source in selected_sources(m,args):
                source['preview']=media.preview_spec(source,m['config'].get('preview_luts'))
                if pause.exists(): m['status']='paused'; save(m); break
                plan=asr.audio_plan(source); entry=m['transcription'].setdefault(source['id'],{'status':plan['status'],'precision':'chunk','segments':[]})
                audio_jobs=[]; waiting_audio=[]; media_jobs=[]
                audio_blocks=m.setdefault('audio_blocks',{}).setdefault(source['id'],[])
                audio_blocks[:]=[b for b in audio_blocks if media.valid_audio(b['path'],b['end']-b['start'])]
                if not plan['chunks']: entry.update(status=plan['status'],requests=0)
                for chunk in plan['chunks']:
                    key=digest({'source':source['id'],'chunk':chunk,'model':m['config']['asr_model'],'protocol':protocol,'audio':{'sample_rate':16000,'channels':1,'pcm':'s16le','version':1}})
                    cached=state.get(key)
                    if cached and cached['status']=='success':
                        if not any(s['id']==key for s in entry['segments']): entry['segments'].append(cached['payload'])
                        continue
                    directory=Path(m['temp_dir'])/'audio'/source['id']; directory.mkdir(parents=True,exist_ok=True)
                    wav=directory/(key+'.wav'); raw=directory/(key+'.stream.json')
                    m['temporary_artifacts']+=list(map(str,(wav,raw))); save(m)
                    job=(chunk,key,wav,raw)
                    if media.valid_audio(wav,chunk['end']-chunk['start']): audio_jobs.append(job)
                    else: waiting_audio.append(job)
                for block in source['blocks']:
                    key=media.extraction_key(source,block,source['preview'],m['config'].get('extraction_pipeline'))
                    cached=state.get(key)
                    need_frames=not (cached and cached['status']=='success' and all(Path(f['path']).exists() for f in cached['payload']['frames']))
                    if not need_frames:
                        known={f['id'] for f in m['frames']}; m['frames'] += [f for f in cached['payload']['frames'] if f['id'] not in known]
                    affected=[job[0] for job in waiting_audio if job[0]['start']<block['end'] and job[0]['end']>block['start']]
                    audio_output=None; work_block=dict(block)
                    if affected:
                        if not need_frames:
                            work_block['start']=max(block['start'],min(c['start'] for c in affected)); work_block['end']=min(block['end'],max(c['end'] for c in affected))
                        audio_output=Path(m['temp_dir'])/'audio'/source['id']/f'block-{block["index"]}-{work_block["start"]:.6f}-{work_block["end"]:.6f}.wav'
                        audio_output.parent.mkdir(parents=True,exist_ok=True); m['temporary_artifacts'].append(str(audio_output))
                        if media.valid_audio(audio_output,work_block['end']-work_block['start']):
                            record={'path':str(audio_output),'start':work_block['start'],'end':work_block['end']}
                            if record not in audio_blocks: audio_blocks.append(record)
                            audio_output=None
                    if need_frames or audio_output:
                        work_key=key if need_frames else digest({'audio_block':source['id'],'start':work_block['start'],'end':work_block['end'],'version':1})
                        media_jobs.append((work_block,work_key,need_frames,audio_output))
                def ready_local_chunks():
                    for job in list(waiting_audio):
                        if media.cut_audio_blocks(audio_blocks,job[0]['start'],job[0]['end'],job[2]): audio_jobs.append(job); waiting_audio.remove(job)
                ready_local_chunks()
                save(m); active={}; stopped=False
                while audio_jobs or waiting_audio or media_jobs or active:
                    if pause.exists(): stopped=True
                    if not stopped and not any(kind=='audio' for kind,_ in active.values()) and audio_jobs:
                        job=audio_jobs.pop(0); state.put(job[1],'asr','running',job[0]); active[asr_pool.submit(client.transcribe,job[2],job[3])]=('audio',job)
                    if not stopped and not any(kind=='media' for kind,_ in active.values()) and media_jobs:
                        job=media_jobs.pop(0); state.put(job[1],'media','running',{'source_id':source['id'],'block':job[0]}); active[media_pool.submit(media_worker,source,job)]=('media',job)
                    if not active:
                        if waiting_audio and not stopped: raise RuntimeError('Local audio blocks do not cover remaining ASR chunks')
                        break
                    done,_=wait(active,timeout=1,return_when=FIRST_COMPLETED)
                    for future in done:
                        kind,job=active.pop(future)
                        try: result=future.result()
                        except Exception as e:
                            state.put(job[1],'asr' if kind=='audio' else 'media','unknown' if isinstance(e,asr.UnknownServerState) else 'failed',{'error':str(e)})
                            m.setdefault('run_errors',[]).append({'source':source['id'],'stage':kind,'error':str(e)}); stopped=True; entry['status']='paused'; m['status']='paused_error'; save(m); continue
                        if kind=='audio':
                            chunk,key,_,_=job
                            segment={'id':key,'source_id':source['id'],'start':chunk['start'],'end':chunk['end'],'core_start':chunk['core_start'],'core_end':chunk['core_end'],'text':result['text'],'precision':'chunk','overlap_policy':'preserved; boundary repetitions not deleted'}
                            state.put(key,'asr','success',segment)
                            if not any(s['id']==key for s in entry['segments']): entry['segments'].append(segment)
                            print(json.dumps({'asr_source':source['relative_path'],'chunk':chunk['index'],'complete':True},ensure_ascii=False),flush=True)
                        else:
                            frames,errors=result
                            if not media.unchanged(source): raise RuntimeError('source changed during processing')
                            known={f['id'] for f in frames}; m['frames']=[f for f in m['frames'] if f['id'] not in known]+frames
                            m['temporary_artifacts'] += [f['path'] for f in frames]; m.setdefault('media_errors',[]).extend(errors)
                            if job[3]:
                                record={'path':str(job[3]),'start':job[0]['start'],'end':job[0]['end']}
                                if record not in audio_blocks: audio_blocks.append(record)
                            state.put(job[1],'media','success',{'frames':frames,'audio':str(job[3]) if job[3] else None})
                            ready_local_chunks()
                            print(json.dumps({'media_source':source['relative_path'],'block':job[0]['index'],'frames_total':len(m['frames']),'audio_block':bool(job[3])},ensure_ascii=False),flush=True)
                        save(m)
                if stopped:
                    if m['status']!='paused_error': m['status']='paused'
                    save(m); break
                if plan['chunks']: entry['status']='success'
                save(m)
                ns=SimpleNamespace(state=m['state_dir'],source_id=[source['id']],gps=args.gps,garmin_companion=args.garmin_companion or [],refresh=False)
                existing=any(p.get('source_id')==source['id'] for p in m['packages'])
                if not existing:
                    created=packages(ns)
                    if created: print(json.dumps({'ready_packages':[p['id'] for p in created],'source':source['relative_path']},ensure_ascii=False),flush=True)
                import_results(SimpleNamespace(state=m['state_dir'],source_id=None,refresh=False))
                m=load(args)
    finally: state.close()
    return {'status':m['status'],'coverage':report.coverage(m)}

def decide_supplement(args):
    m=load(args); result=analysis.record_supplement_decision(m,args.request_id,args.decision,args.reviewer,args.reason); save(m); return result

def supplement(args):
    m=load(args); candidates=m.get('supplemental_pending',[]); created=[]
    decisions=m.get('supplemental_decisions',{})
    if getattr(args,'list_requests',False): return {'requests':[{'request_id':digest(r),'request':r,'decision':decisions.get(digest(r),{}).get('decision','undecided')} for r in candidates]}
    pending=[r for r in candidates if decisions.get(digest(r),{}).get('decision')=='accept']
    if not pending: return {'packages':[],'pending_requests':len(candidates),'awaiting_root_decision':len(candidates)}
    m.setdefault('supplemental_round',{'number':1,'request_ids':[digest(r) for r in pending],'started':dt.datetime.now(dt.timezone.utc).isoformat()}); save(m)
    for source in selected_sources(m,args):
        requests=[r for r in pending if r['source_id']==source['id']]
        if not requests: continue
        for n,(start,end) in enumerate(analysis.merge_intervals(requests,source['duration'])):
            preview=media.preview_spec(source,m['config'].get('preview_luts'))
            identity={'source':source['id'],'supplement':(start,end),'version':1,'preview_sha256':preview.get('lut_sha256')}
            if m['config'].get('extraction_pipeline'): identity['extraction_pipeline']=m['config']['extraction_pipeline']
            key=digest(identity)[:16]
            plan=m.setdefault('supplemental_plans',{}).setdefault(key,{'source_id':source['id'],'start':start,'end':end,'request_ids':[digest(r) for r in requests if max(0,r['start']-15)>=start and min(source['duration'],r['end']+30)<=end],'extraction_complete':False,'package_ids':[]})
            save(m)
            if plan['extraction_complete']: continue
            # A single supplement interval can be long; retain <=5-minute media blocks.
            times=sorted(set([float(t) for t in range(int(start),int(end)+1) if start<=t<end]+[start,max(start,end-1/source['fps'])]))
            frames=[]
            for block in media.blocks_for(times,source['duration']):
                block['start']=max(start,block['start']); block['end']=min(end,block['end']); block['index']+=10000+n*100
                frames+=media.extract_block(m['config']['ffmpeg'],source,block,Path(m['temp_dir'])/'supplement'/key/f'b{block["index"]}',m['hardware']['selected'],preview=preview,**extraction_options(m))
            m.setdefault('supplemental_frames',[]).extend(frames); m['temporary_artifacts'] += [f['path'] for f in frames]
            tr=m['transcription'].get(source['id'],{}).get('segments',[])
            for p in analysis.make_packages(source,frames,tr,Path(m['temp_dir'])/'packages'):
                p.update(source_id=source['id'],supplemental=True,supplement_key=key); m['packages'].append(p); created.append(p); m['temporary_artifacts'].append(p['path'])
                plan['package_ids'].append(p['id'])
            plan['extraction_complete']=True
            save(m)
    # A request stays outstanding until every package for its source has passed validation.
    return {'packages':created,'pending_requests':len(pending)}

def audio(args):
    m=load(args); protocol=read(args.protocol) if args.protocol else None
    analysis.validate_itinerary(m.get('itinerary',{}).get('data'))
    client=asr.ASRClient(m['config']['asr_service'],store.host_data_root()/'services',protocol,model=m['config']['asr_model'])
    if args.acknowledge: client.acknowledge_terminal(args.acknowledge); return {'acknowledged':True}
    client.preflight(); state=State(m['state_dir']); processed=0
    try:
        for source in selected_sources(m,args):
            plan=asr.audio_plan(source); entry=m['transcription'].setdefault(source['id'],{'status':plan['status'],'precision':'chunk','segments':[]})
            if not plan['chunks']: entry['status']=plan['status']; save(m); continue
            for chunk in plan['chunks']:
                key=digest({'source':source['id'],'chunk':chunk,'model':m['config']['asr_model'],'protocol':protocol,'audio':{'sample_rate':16000,'channels':1,'pcm':'s16le','version':1}})
                cached=state.get(key)
                if cached and cached['status']=='success':
                    if not any(s['id']==key for s in entry['segments']): entry['segments'].append(cached['payload'])
                    continue
                directory=Path(m['temp_dir'])/'audio'/source['id']; directory.mkdir(parents=True,exist_ok=True)
                wav=directory/(key+'.wav'); raw=directory/(key+'.stream.json')
                media.extract_audio(m['config']['ffmpeg'],source,chunk['start'],chunk['end'],wav)
                m['temporary_artifacts']+=list(map(str,(wav,raw))); save(m)
                state.put(key,'asr','running',chunk)
                try: result=client.transcribe(wav,raw,discover=args.discover)
                except Exception as e:
                    state.put(key,'asr','unknown' if isinstance(e,asr.UnknownServerState) else 'failed',{'error':str(e)}); entry['status']='paused'; save(m); raise
                if args.discover: state.put(key,'asr','protocol_pending',result); return result
                segment={'id':key,'source_id':source['id'],'start':chunk['start'],'end':chunk['end'],'core_start':chunk['core_start'],'core_end':chunk['core_end'],'text':result['text'],'precision':'chunk','overlap_policy':'preserved; boundary repetitions not deleted'}
                state.put(key,'asr','success',segment); entry['segments'].append(segment); save(m); processed+=1
                if args.chunks and processed>=args.chunks: return {'processed_chunks':processed,'paused_at_batch_boundary':True}
            entry['status']='success'; save(m)
    finally: state.close()
    return {'processed_chunks':processed}

def resolve_supplements(m):
    packages_by_id={p['id']:p for p in m['packages']}; resolved=set()
    for plan in m.get('supplemental_plans',{}).values():
        if plan['extraction_complete'] and plan['package_ids'] and all(packages_by_id.get(pid,{}).get('status')=='success' for pid in plan['package_ids']): resolved.update(plan['request_ids'])
    m['supplemental_pending']=[r for r in m.get('supplemental_pending',[]) if digest(r) not in resolved]

def daily_package(args):
    from types import SimpleNamespace
    import_results(SimpleNamespace(state=args.state,source_id=None,refresh=False))
    m=load(args); resolve_supplements(m); cov=report.coverage(m)
    if not cov['analysis_ready']: save(m); raise ValueError('Readable material still has unfinished extraction, ASR, analysis or accepted supplements')
    active=[p for p in m['packages'] if p['status']=='success']
    results=[read(Path(m['state_dir'])/'analysis'/(p['id']+'.json')) for p in active]
    source_context=[]
    for source in m['sources']:
        item={k:source.get(k) for k in ('id','relative_path','duration','status','error','role')}
        md=source.get('metadata',{}); item['clock']={k:md.get(k) for k in ('captured_at_utc','time_verified','playback_rate_verified','time_source','warnings')}
        item['clock']['usable_mapping']=bool(md.get('time_verified') and md.get('playback_rate_verified'))
        source_context.append(item)
    analysed={f for p in active for f in p['core_frame_ids']}
    payload={'run_id':m['run_id'],'stage':'readable_material_complete_awaiting_daily','archival_date':m['config']['date'],'timezone':m['config']['timezone'],'coverage':cov,'sources':source_context,'frames':[{k:f.get(k) for k in ('id','source_id','time','pts','precision')} for f in m['frames']+m.get('supplemental_frames',[]) if f['id'] in analysed],'validated_records':results,'transcriptions':m['transcription'],'gps_context':m.get('gps'),'root_review_decisions':m.get('root_review_decisions',[]),'sampling_adjustments':m.get('plan_adjustments',[]),'result_schema':analysis.DailyResult.model_json_schema(),'instructions':'仅依据已校验观察/原始转写做日摘要与跨文件语义合并；保留每个source片段及证据ID，不改原话，不猜山名/景物坐标，不把ASR文字当音频事件检测。跨来源画面相似不证明同一事件；语音回述不是现场正在发生的事实，chunk区间不当精确剪辑点或词时码。遵守本包有证据的root_review_decisions，不继承其他运行结论。时间仅按usable_mapping源的UTC+文件内秒换算，其余标未核实。源损坏独立保留，不宣称全部来源均已覆盖。'}
    payload['package_id']=digest(payload)[:24]
    path=Path(m['temp_dir'])/'daily.package.json'; result_path=Path(m['temp_dir'])/'daily.result.json'; payload['result_path']=str(result_path)
    dump(path,payload); m['temporary_artifacts'] += list(map(str,(path,result_path))); m['status']='awaiting_daily'; m['daily_package']={'id':payload['package_id'],'path':str(path),'result_path':str(result_path)}; save(m)
    return {**m['daily_package'],'bytes':path.stat().st_size,'validated_packages':len(active),'coverage':cov}

def build_gps_association(m,data,reason,validated_locations=()):
    """Deterministic association reused by first analysis and targeted revisions."""
    from vlog_index.gps import locate_media
    utc=lambda value:dt.datetime.fromisoformat(value.replace('Z','+00:00'))
    locations=[]; sources=[]; matches=[]
    seeds={p['frame_id']:p for p in validated_locations if p.get('frame_id') and p.get('source') in ('garmin_fit','drone_srt') and p.get('crs')=='EPSG:4326' and isinstance(p.get('latitude'),(int,float)) and isinstance(p.get('longitude'),(int,float)) and -90<=p['latitude']<=90 and -180<=p['longitude']<=180 and not (p['source']=='drone_srt' and p['latitude']==0 and p['longitude']==0)}
    for source in (s for s in m['sources'] if s['status']=='ready'):
        md=source['metadata']; frames=[f for f in m['frames'] if f['source_id']==source['id']]
        verified=bool(md.get('captured_at_utc') and md.get('time_verified') and md.get('playback_rate_verified'))
        origin=utc(md['captured_at_utc']) if verified else None
        source_locations=[]
        for frame in frames:
            timestamp=(origin+dt.timedelta(seconds=frame['time'])).isoformat() if origin else None
            location=locate_media(data,timestamp,time_mapping_verified=verified,playback_rate_verified=verified,device_with_garmin=True,drone_srt_points=md.get('location_points',[]) if source['role']=='drone' else None,video_seconds=frame['time'])
            if location is None and frame['id'] in seeds:
                seed=seeds[frame['id']]
                expected='drone_srt' if source['role']=='drone' else 'garmin_fit'
                missing_input=not md.get('location_points') if source['role']=='drone' else not data.get('points')
                if seed.get('source_id',source['id'])==source['id'] and seed['source']==expected and missing_input and (source['role']=='drone' or verified): location=seed
            if location:
                record={'frame_id':frame['id'],'source_id':source['id'],'video_seconds':frame['time'],**location}
                locations.append(record); source_locations.append(record)
        end=origin+dt.timedelta(seconds=source['duration']) if origin else None
        gaps=[g for g in data.get('gaps',[]) if origin and utc(g['start_utc'])<end and utc(g['end_utc'])>origin]
        windows=[]
        if origin and source['role']!='drone':
            for window in data.get('quality',{}).get('coverage_windows',[]):
                begin=max(origin,utc(window['start_utc'])); finish=min(end,utc(window['end_utc']))
                if finish>=begin: windows.append({'start':(begin-origin).total_seconds(),'end':(finish-origin).total_seconds(),'start_utc':begin.isoformat(),'end_utc':finish.isoformat()})
            for stop in data.get('stops',[]):
                begin=max(origin,utc(stop['start_utc'])); finish=min(end,utc(stop['end_utc']))
                if finish>begin:
                    matches.append({'stop_id':stop['stop_id'],'source_id':source['id'],'relative_path':source['relative_path'],'start':(begin-origin).total_seconds(),'end':(finish-origin).total_seconds(),'start_utc':begin.isoformat(),'end_utc':finish.isoformat(),'latitude':stop['latitude'],'longitude':stop['longitude'],'coordinate_source':stop['source'],'source_file':stop['source_file'],'meaning':'recorded_spatial_stop_overlaps_video_not_an_event_claim','gap_policy':'stop constructed within one valid segment; never bridge >120 seconds'})
        sources.append({'source_id':source['id'],'relative_path':source['relative_path'],'role':source['role'],'time_mapping_verified':verified,'frame_count':len(frames),'located_frames':len(source_locations),'location_source':'drone_srt' if source['role']=='drone' else 'garmin_fit' if verified else 'unverified_clock_or_rate','gap_count':len(gaps),'gaps':gaps,'covered_intervals':windows,'start_utc':origin.isoformat() if origin else None,'end_utc':end.isoformat() if end else None})
    summary={'all_frames':len(m['frames']),'located_frames':len(locations),'garmin_located_frames':sum(p['source']=='garmin_fit' for p in locations),'srt_located_frames':sum(p['source']=='drone_srt' for p in locations),'garmin_eligible_sources':sum(s['role']!='drone' and s['time_mapping_verified'] for s in sources),'garmin_sources_with_locations':sum(s['role']!='drone' and s['located_frames']>0 for s in sources),'matched_stops':len({p['stop_id'] for p in matches}),'stop_video_overlaps':len(matches)}
    return {'companion_confirmed':bool(data or any(p['source']=='garmin_fit' for p in locations)),'confirmation_evidence':reason,'coordinate_meaning':'recorder_or_drone_camera_position_not_distant_subject','max_gap_seconds':120,'summary':summary,'source_coverage':sources,'frame_locations':locations,'stop_video_matches':matches}

def gps_review_package(args):
    """Associate existing frame IDs only; never rebuild visual packages or read media."""
    m=load(args); data=read(args.gps); state=Path(m['state_dir'])
    if not report.coverage(m)['analysis_ready']: raise ValueError('GPS-only review requires completed readable material')
    if not args.reason.strip(): raise ValueError('Record the evidence confirming the supplied GPS accompanies the trip')
    association=build_gps_association(m,data,args.reason)
    summary=association['summary']; sources=association['source_coverage']; matches=association['stop_video_matches']
    prior=read(state/'daily.validated.json')
    revision=m.get('revision',1)+1
    if m.get('publication'):
        rollback=state/f'published-revision-{m.get("revision",1)}'; rollback.mkdir(exist_ok=True)
        import shutil
        for name in report.NAMES: shutil.copy2(state/'final'/name,rollback/name)
        shutil.copy2(state/'daily.validated.json',rollback/'daily.validated.json')
        m.setdefault('publication_history',[]).append({**m['publication'],'revision':m.get('revision',1),'rollback_directory':str(rollback)})
    m.update(revision=revision,gps_association=association,published_verified=False,status='awaiting_gps_review')
    m['gps']={'path':args.gps,'quality':data['quality'],'stops':data.get('stops',[]),'gaps':data.get('gaps',[]),'companion_confirmed':True,'confirmation_evidence':args.reason}
    active=[p for p in m['packages'] if p['status']=='success']; results=[read(state/'analysis'/(p['id']+'.json')) for p in active]
    source_context=[{'id':s['id'],'relative_path':s['relative_path'],'duration':s.get('duration'),'status':s['status'],'clock':{k:s.get('metadata',{}).get(k) for k in ('captured_at_utc','time_verified','playback_rate_verified','time_source')}} for s in m['sources']]
    result_path=state/'gps-review.result.json'
    payload={'run_id':m['run_id'],'revision':revision,'scope':'GPS-only targeted semantic revision; retain prior validated visual evidence','previous_daily':prior,'coverage':report.coverage(m),'sources':source_context,'frames':[{k:f.get(k) for k in ('id','source_id','time','pts','precision')} for f in m['frames']],'validated_records':results,'transcriptions':m['transcription'],'gps_context':m['gps'],'gps_association':association,'root_review_decisions':m.get('root_review_decisions',[]),'result_schema':analysis.DailyResult.model_json_schema(),'result_path':str(result_path),'instructions':'用户提供的Garmin为随行数据。仅定向更新受影响的时间/GPS/停留关联，复用既有视觉/ASR，不看图重审，不发ASR。停留相交不是活动事实，画面相似不证明跨来源同一事件，ASR回述不当现场事件，chunk不当精确剪辑点。未知时钟/速率不关联；不跨120秒缺口；SRT优先；坐标仅记录者/相机，非远景目标，不猜具体景物名。位置可逐字引用gps_association.frame_locations完整字典，clips须引用对应frame_id/source_id。遵守本包root_review_decisions中有证据的纠正，不继承其他运行的具体结论。输出完整DailyResult供ROOT重审，不直接发布。'}
    payload['package_id']=digest(payload)[:24]; path=state/'gps-review.package.json'
    dump(state/'gps-association.json',association); dump(path,payload)
    m['gps_review_package']={'path':str(path),'result_path':str(result_path),'package_id':payload['package_id']}; save(m)
    return {**m['gps_review_package'],'bytes':path.stat().st_size,'revision':revision,'summary':summary,'source_coverage':[{k:s[k] for k in ('source_id','relative_path','frame_count','located_frames','gap_count','location_source')} for s in sources if s['role']!='drone'],'stop_video_matches':matches}

def attach_itinerary(args):
    m=load(args); itinerary=analysis.validate_itinerary(read(args.itinerary))
    maps=analysis.validate_map_evidence(read(args.map_evidence) if args.map_evidence else [])
    m['itinerary']={'data':itinerary,'sha256':digest(itinerary),'source_file':str(Path(args.itinerary).resolve())}
    m['map_evidence']={'records':maps,'sha256':digest(maps)}
    m['published_verified']=False; m['status']='awaiting_geography'; save(m)
    dump(Path(m['state_dir'])/'itinerary.attached.json',itinerary); dump(Path(m['state_dir'])/'map-evidence.attached.json',maps)
    return {'itinerary_sha256':digest(itinerary),'entries':len(itinerary['entries']),'map_evidence_records':len(maps),'media_reprocessed':False}

def geography_package(args):
    m=load(args); state=Path(m['state_dir'])
    results=[read(state/'analysis'/(p['id']+'.json')) for p in m['packages'] if p['status']=='success']
    if 'gps_association' not in m:
        context=m.get('gps',{}); data=read(context['path']) if context.get('path') and Path(context['path']).is_file() else {k:context[k] for k in ('quality','stops','gaps') if k in context}
        seeds=[f['location'] for result in results for f in result['events']+result['interest_points'] if f.get('location')]
        for package in m['packages']:
            if package['status']=='success' and Path(package.get('path','')).is_file(): seeds.extend(read(package['path']).get('gps',[]))
        m['gps_association']=build_gps_association(m,data,context.get('confirmation_evidence','Existing verified frame positions and supplied companion track'),seeds)
        dump(state/'gps-association.json',m['gps_association'])
    association=m['gps_association']
    locations=association.get('frame_locations',[])
    removed=[p for p in locations if p.get('source')=='drone_srt' and p.get('latitude')==0 and p.get('longitude')==0]
    if removed:
        association['frame_locations']=[p for p in locations if p not in removed]
        for source in association.get('source_coverage',[]): source['located_frames']-=sum(p['source_id']==source['source_id'] for p in removed)
        association['summary']['located_frames']-=len(removed); association['summary']['srt_located_frames']-=len(removed)
        association['excluded_placeholder_frames']=removed
        dump(state/'gps-association.json',association)
    raw=read(args.daily); corrections=[]
    for finding in raw['events']+raw['interest_points']:
        point=finding.get('location')
        if point and point.get('source')=='drone_srt' and point.get('latitude')==0 and point.get('longitude')==0:
            corrections.append({'title':finding['title'],'correction':'invalid DJI SRT (0,0) placeholder location removed; event semantics unchanged'}); finding['location']=None
    daily=analysis.validate_daily(raw,m,results); bindings=analysis.geography_bindings(m,daily)
    findings=[{'finding_key':analysis.finding_key(category,n,item),'category':category,'number':n,'finding':item} for category,items in (('event',daily['events']),('interest_point',daily['interest_points'])) for n,item in enumerate(items,1)]
    gps_records=[{'id':'gps:'+p['frame_id'],**p} for p in association.get('frame_locations',[])]
    gps_records += [{'id':'stop:'+str(n),**p} for n,p in enumerate(association.get('stop_video_matches',[]),1)]
    maps=[dict(p) for p in m['map_evidence']['records']]
    # Link reverse query coordinates to nearby original GPS evidence, not to a returned POI label.
    import math
    for record in maps:
        query=record.get('original_coordinates',record['coordinates']); record['related_gps_ids']=[]
        if query.get('crs') not in ('EPSG:4326','WGS84'): continue
        for point in gps_records:
            distance=6371000*math.hypot(math.radians(query['latitude']-point['latitude']),math.radians(query['longitude']-point['longitude'])*math.cos(math.radians(query['latitude'])))
            if distance<=1000: record['related_gps_ids'].append(point['id'])
    path=state/'geography.package.json'; result_path=state/'geography.result.json'
    payload={'run_id':m['run_id'],'revision':m.get('revision',1),'input_digests':bindings,'daily':daily,'findings':findings,'itinerary':m['itinerary']['data'],'map_evidence':maps,'gps_records':gps_records,'gps_coverage':association,'sources':[{k:s.get(k) for k in ('id','relative_path','duration','status')} for s in m['sources']],'transcriptions':m['transcription'],'result_schema':analysis.GeographyResult.model_json_schema(),'result_path':str(result_path),'deterministic_corrections':corrections,'instructions':'专门地理Agent按时间/GPS确定记录者或相机坐标，结合已缓存的地图实际查询与有来源行程对全部事件与兴趣点做地点关联。保留原事件/兴趣点语义，不重写daily，不重抽图/ASR。每finding_key恰好一项，不确定也unresolved。不得将相机坐标当远景山峰坐标；地图返回名称/历史计划路线都是证据或候选，不能单独证明实际到访。resolved地图引用必须与本finding的GPS或明确行程项相连；没有该链条使用approximate/unresolved。itinerary_refs引用entry.id，gps_refs引用gps_records.id，map_evidence_ids引用map_evidence.id；evidence_ids只引用本finding已有clips证据。近似关联需说明依据、置信度和替代候选。SRT(0,0)占位已排除，媒体预览按帧内preview标记判断，未记录技术转换不能声称已归一化。输出完整GeographyResult供ROOT终审，不发布。'}
    if getattr(args,'research_evidence',None): payload['research_evidence']=read(args.research_evidence)
    payload['subject_review_targets']=m.get('subject_review_targets',[])
    payload['map_linkage_note']='related_gps_ids只表示查询坐标与原GPS证据相距不超过1公里，便于排除串区域引用，不代表地图POI身份已确认。跨来源兴趣点须用clip_associations逐源分区；部分GPS不能扩展给未定位片段。'
    payload['package_id']=digest(payload)[:24]; dump(path,payload); dump(state/'daily.validated.json',daily)
    template={'package_id':payload['package_id'],'associations':[analysis.GeographyAssociation(finding_key=f['finding_key'],status='unresolved',subject_kind='unknown',confidence='low',reason='TODO').model_dump() for f in findings],'notes':'TODO'}
    dump(state/'geography.template.json',template)
    m['semantic_daily']={'path':str(state/'daily.validated.json'),'sha256':digest(daily)}
    m['geography_package']={'path':str(path),'result_path':str(result_path),'package_id':payload['package_id'],'input_digests':bindings}; m['published_verified']=False; m['status']='awaiting_geography'; save(m)
    return {**m['geography_package'],'bytes':path.stat().st_size,'findings':len(findings),'gps_summary':association.get('summary'),'corrections':corrections}

def import_geography(args):
    m=load(args); state=Path(m['state_dir']); meta=m.get('geography_package')
    if not meta: raise ValueError('Create a geography package first')
    package=read(meta['path']); daily=read(state/'daily.validated.json')
    if package['input_digests']!=analysis.geography_bindings(m,daily) or package['package_id']!=meta['package_id']: raise ValueError('Geography package inputs changed; create a fresh targeted package')
    result=analysis.validate_geography(read(args.result),{**package,'subject_review_targets':m.get('subject_review_targets',package.get('subject_review_targets',[]))})
    m['geography']={'data':result,'sha256':digest(result),'package_id':package['package_id'],'input_digests':package['input_digests'],'subject_review_targets_sha256':digest(m.get('subject_review_targets',[]))}
    m['published_verified']=False; m['status']='awaiting_final_review'; dump(state/'geography.validated.json',m['geography']); save(m)
    return {'associations':len(result['associations']),'sha256':digest(result),'statuses':{status:sum(a['status']==status for a in result['associations']) for status in ('resolved','approximate','unresolved')}}

def review_frames(args):
    m=load(args)
    if args.reviewer!='ROOT' or not args.reason.strip(): raise ValueError('Targeted review retrieval requires a ROOT decision and reason')
    known={f['id']:f for f in m['frames']+m.get('supplemental_frames',[])}; sources={s['id']:s for s in m['sources']}; result=[]
    for frame_id in args.frame_id:
        if frame_id not in known: raise ValueError('Unknown existing frame id: '+frame_id)
        frame=known[frame_id]; source=sources[frame['source_id']]
        if Path(frame['path']).is_file(): result.append({'frame_id':frame_id,'path':frame['path'],'reused':True}); continue
        prior=next((r for r in m.get('review_evidence_retrieval',[]) if r['frame_id']==frame_id and Path(r['path']).is_file()),None)
        if prior: result.append(prior); continue
        directory=Path(m['temp_dir'])/'review-evidence'/frame_id
        block={'index':int(frame_id.split('-b')[-1].split('-')[0]),'start':max(0,frame['time']-2/source['fps']),'end':min(source['duration'],frame['time']+3/source['fps']),'samples':[frame['time']]}
        preview=frame.get('preview') or media.preview_spec(source,m['config'].get('preview_luts'))
        if preview.get('applied'):
            from vlog_index.store import file_hash
            lut=Path(preview.get('lut_path',''))
            if not lut.is_file() or file_hash(lut)!=preview['lut_sha256']:
                preview={**preview,'applied':False,'normalized':False,'filter':None,'status':'original_lut_unavailable','warning':'Original LUT missing or changed; technical color reproduction is not claimed'}
        retrieved=media.extract_block(m['config']['ffmpeg'],source,block,directory,m['hardware']['selected'],preview=preview,**extraction_options(m,frame))[0]
        if abs(retrieved['time']-frame['time'])>0.5/source['fps']: raise ValueError('Review retrieval did not reproduce the existing sampled frame')
        record={'frame_id':frame_id,'source_id':source['id'],'path':retrieved['path'],'original_time':frame['time'],'retrieved_time':retrieved['time'],'purpose':'review evidence retrieval, no sampling-plan/cache change','preview':preview,'reviewer':args.reviewer,'reason':args.reason}
        m.setdefault('review_evidence_retrieval',[]).append(record); m['temporary_artifacts'].append(retrieved['path']); result.append(record); save(m)
    return {'frames':result,'frames_or_analysis_invalidated':False,'asr_requests':0}

def map_lookup(args):
    m=load(args); records=analysis.map_lookup(read(args.requests),args.provider,Path(m['state_dir'])/'map-cache',retry_failed=args.retry_failed)
    dump(args.output,records)
    return {'output':str(args.output),'records':len(records),'failed':sum(r.get('status')=='failed' for r in records),'no_credentials_saved':True}

def subject_targets(args):
    m=load(args); state=Path(m['state_dir']); daily=read(state/'daily.validated.json')
    keys={analysis.finding_key(category,n,item) for category,items in (('event',daily['events']),('interest_point',daily['interest_points'])) for n,item in enumerate(items,1)}
    if args.template:
        dump(args.template,{'targets':[],'available_finding_keys':sorted(keys),'instructions':'List important visible landmark targets as {target_id,subject,finding_keys:[...]} for dedicated geography Agent analysis; identity may remain unresolved.'})
        return {'template':str(args.template)}
    if not args.targets: raise ValueError('Provide --targets or --template')
    data=read(args.targets); targets=data.get('targets',[]) if isinstance(data,dict) else data
    if not isinstance(targets,list) or len({t.get('target_id') for t in targets})!=len(targets): raise ValueError('Subject targets must have unique ids')
    for target in targets:
        if not target.get('target_id') or not target.get('subject') or not target.get('finding_keys') or not set(target['finding_keys'])<=keys: raise ValueError('Subject target needs subject and legal current finding keys')
    m['subject_review_targets']=targets; m['published_verified']=False; save(m); dump(state/'subject-review-targets.json',targets)
    return {'targets':len(targets),'required_finding_reviews':sum(len(t['finding_keys']) for t in targets)}

def gps_build(args):
    from vlog_index.gps import build_gps
    result=build_gps(args.fit_dir,args.output,timezone=args.timezone,date=args.date)
    return {'output':str(args.output),'quality':result['quality']}

def configure_source(args):
    m=load(args); sources=selected_sources(m,args)
    if not args.source_id or not args.reason.strip(): raise ValueError('Configure explicit sources with an evidence reason')
    for source in sources:
        md=source['metadata']
        if args.role: source['role']=args.role
        if args.capture_time:
            value=dt.datetime.fromisoformat(args.capture_time.replace('Z','+00:00'))
            if value.tzinfo is None: raise ValueError('Capture time must include a verified UTC offset')
            md.update(captured_at_utc=value.astimezone(dt.timezone.utc).isoformat(),time_verified=True,time_source='explicit source configuration: '+args.reason)
        if args.unverified_clock: md['time_verified']=False
        if args.normal_speed: md['playback_rate_verified']=True
        if args.unknown_speed: md['playback_rate_verified']=False
        source.setdefault('configuration_evidence',[]).append({'reason':args.reason,'at':dt.datetime.now(dt.timezone.utc).isoformat()})
    analysis.invalidate_downstream(m,'source clock/role configuration updated'); save(m)
    return {'sources':[s['id'] for s in sources],'media_reprocessed':False}

def asr_json_sample(args):
    m=load(args); analysis.validate_itinerary(m.get('itinerary',{}).get('data'))
    source=next((s for s in selected_sources(m,args) if asr.audio_plan(s)['chunks']),None)
    if source is None: raise ValueError('Choose a readable confirmed camera with audio')
    chunk=asr.audio_plan(source)['chunks'][0]; directory=Path(m['temp_dir'])/'asr-verification'; directory.mkdir(parents=True,exist_ok=True)
    previous=m.get('asr_json_sample',{})
    if previous.get('complete') and previous.get('source_id')==source['id'] and previous.get('model')==m['config']['asr_model'] and previous.get('chunk')==chunk and previous.get('service')==m['config']['asr_service']:
        return {'reused':True,'raw_output':str(Path(m['state_dir'])/'asr-json-sample.json'),'wav':previous['wav'],'source_id':source['id'],'complete':True,'asr_requests':0}
    wav=directory/'sample.wav'; raw=Path(m['state_dir'])/'asr-json-sample.json'
    if not media.valid_audio(wav,chunk['end']-chunk['start']): media.extract_audio(m['config']['ffmpeg'],source,chunk['start'],chunk['end'],wav)
    m['temporary_artifacts'].append(str(wav)); save(m)
    client=asr.ASRClient(m['config']['asr_service'],m['state_dir'],model=m['config']['asr_model']); client.preflight()
    result=client.transcribe(wav,raw,stream=False)
    m['asr_json_sample']={'source_id':source['id'],'chunk':chunk,'model':m['config']['asr_model'],'service':m['config']['asr_service'],'result':result,'wav':str(wav),'complete':True}; save(m)
    return {'raw_output':str(raw),'wav':str(wav),'source_id':source['id'],'complete':True,'adopt_after_stream_verification':True}

def adopt_json_sample(args):
    m=load(args); sample=m.get('asr_json_sample'); protocol=read(args.protocol)
    if not sample or not sample.get('complete') or not args.reason.strip(): raise ValueError('Adoption requires completed JSON sample and explicit verified stream-protocol evidence')
    key=digest({'source':sample['source_id'],'chunk':sample['chunk'],'model':sample['model'],'protocol':protocol,'audio':{'sample_rate':16000,'channels':1,'pcm':'s16le','version':1}})
    chunk=sample['chunk']; segment={'id':key,'source_id':sample['source_id'],'start':chunk['start'],'end':chunk['end'],'core_start':chunk['core_start'],'core_end':chunk['core_end'],'text':sample['result']['text'],'precision':'chunk','overlap_policy':'preserved; boundary repetitions not deleted'}
    state=State(m['state_dir']); state.put(key,'asr','success',segment); state.close()
    entry=m['transcription'].setdefault(sample['source_id'],{'status':'pending','segments':[]})
    if not any(s['id']==key for s in entry['segments']): entry['segments'].append(segment)
    sample['adoption_evidence']=args.reason; sample['adopted_cache_key']=key; save(m)
    return {'adopted':key,'asr_requests':0}

def attach_review_context(args):
    m=load(args); context=read(args.context)
    if not isinstance(context,dict) or not isinstance(context.get('public_notes',[]),list): raise ValueError('Review context must be sourced JSON with public_notes')
    base=Path(args.context).resolve().parent
    if context.get('supplemental_map_evidence_file'): context['supplemental_map_evidence']=read(base/context['supplemental_map_evidence_file'])
    if context.get('supplemental_map_evidence'): analysis.validate_map_evidence(context['supplemental_map_evidence'])
    context['evidence_documents']=[{'path':str((base/name).resolve()),'sha256':digest((base/name).read_text(encoding='utf-8')),'text':(base/name).read_text(encoding='utf-8')} for name in context.get('evidence_files',[])]
    m['final_review_context']=context; m['published_verified']=False; save(m)
    return {'context_sha256':digest(context),'public_notes':len(context.get('public_notes',[]))}

def final_review_package(args):
    m=load(args); state=Path(m['state_dir']); daily=read(state/'daily.validated.json')
    bindings=analysis.final_review_bindings(m,daily); cov=report.coverage(m)
    package={'run_id':m['run_id'],'revision':m.get('revision',1),'input_digests':bindings,'required_dimensions':sorted(analysis.REVIEW_DIMENSIONS),'itinerary':m['itinerary']['data'],'daily':daily,'geography':m['geography']['data'],'gps_quality':m.get('gps',{}).get('quality'),'all_spatial_stops':m.get('gps',{}).get('stops',[]),'gps_media_coverage':{k:v for k,v in m.get('gps_association',{}).items() if k!='frame_locations'},'supplement_candidates':m.get('supplemental_pending',[]),'supplement_decisions':m.get('supplemental_decisions',{}),'root_targeted_reviews':m.get('root_review_decisions',[]),'review_context':m.get('final_review_context',{}),'coverage':cov,'final_hashes':m.get('final',{}).get('hashes'),'instructions':'ROOT必须结合行程计划与实际、完整GPS路线/全部停留和媒体覆盖、时间地点矛盾、视觉与转写、主体地标候选、补采处置做实质审查。程序只校验记录完整与依赖摘要，不代替语义判断。所有blocking问题必须处置后才批准；未知可按证据作为限制保留，不编造无素材活动。'}
    package['package_id']=digest(package)[:24]; path=state/'final-review.package.json'; dump(path,package)
    template={'reviewer':'ROOT','package_id':package['package_id'],'conclusion':'pending','reason':'TODO','checked_dimensions':[],'issues':[],'remaining_unknowns':[],'blocking_remaining':None}
    dump(state/'final-review.template.json',template)
    m['final_review_package']={'path':str(path),'package_id':package['package_id'],'input_digests':bindings}; save(m)
    preview=['# 最终实质审查包','',f'运行：{m["run_id"]}；修订：{m.get("revision",1)}',f'覆盖：{cov["readable_sources"]}可读来源，{cov["analysed_frames"]}核心帧；失败{len(cov["failed_sources"])}。','',f'行程条目：{len(m["itinerary"]["data"]["entries"])}；事件{len(daily["events"])}/兴趣点{len(daily["interest_points"])}。',f'GPS全部空间停留{len(package["all_spatial_stops"])}，与媒体匹配{m.get("gps_association",{}).get("summary",{}).get("matched_stops",0)}；不能把无媒体停留编成活动。','','## 核查维度']+['- '+s for s in package['required_dimensions']]+['','## 已知路线、冲突与覆盖限制']+['- '+s for s in package['review_context'].get('public_notes',[])]+['','完整路线/停留、候选、行程冲突、补采处置与来源摘要见 final-review.package.json。审查结论按 final-review.template.json 填写，未决blocking必须为0。']
    (state/'final-review.preview.md').write_text('\n'.join(preview)+'\n',encoding='utf-8')
    return {'path':str(path),'package_id':package['package_id'],'bytes':path.stat().st_size,'preview':str(state/'final-review.preview.md'),'result_template':str(state/'final-review.template.json')}

def render(args):
    m=load(args)
    client=asr.ASRClient(m['config']['asr_service'],store.host_data_root()/'services',model=m['config']['asr_model'])
    m['asr_service_state']=read(client.gate) if client.gate.exists() else {'status':'not_started'}
    for source in m['sources']:
        if source['status']!='ready':
            m['transcription'].setdefault(source['id'],{'status':'unreadable_media','segments':[],'requests':0}); continue
        plan=asr.audio_plan(source)
        if plan['status'] in ('skipped_drone','no_audio'):
            m['transcription'][source['id']]={'status':plan['status'],'segments':[],'requests':0}
        else:
            pending='waiting_service_unknown' if m['asr_service_state']['status'] in ('unknown','inflight') else plan['status']
            m['transcription'].setdefault(source['id'],{'status':pending,'segments':[]})
    resolve_supplements(m)
    results=[read(Path(m['state_dir'])/'analysis'/(p['id']+'.json')) for p in m['packages'] if p['status']=='success']
    daily=analysis.validate_daily(read(args.daily),m,results) if args.daily else None
    if daily: dump(Path(m['state_dir'])/'daily.validated.json',daily)
    result=report.render(m,results,Path(m['state_dir'])/'final',daily=daily); m['status']=result['status']; m['final']=result; m['published_verified']=False; save(m); return result

def publish(args):
    m=load(args); result=report.publish(m,Path(m['state_dir'])/'final',m['config']['source_root']); save(m); return result

def approve_final(args):
    m=load(args); result=report.approve_final(m,Path(m['state_dir'])/'final',args.reviewer,args.reason,read(args.review_result)); save(m); return result

def cleanup(args):
    m=load(args); removed=cleanup_registered(m['temp_dir'],m); m['cleanup']={'removed':len(removed),'complete':True}; save(m); return m['cleanup']

def naming_plan(args):
    return store.naming_plan(load(args),read(args.config),args.library_root,args.index,args.state)

def naming_review(args):
    _,plan=store._naming_load(args.plan)
    if Path(plan['state_dir']).resolve()!=Path(args.state).resolve(): raise ValueError('Naming plan belongs to another state')
    return store.naming_review(args.plan,args.reviewer,args.reason)

def naming_apply(args):
    _,plan=store._naming_load(args.plan)
    if Path(plan['state_dir']).resolve()!=Path(args.state).resolve(): raise ValueError('Naming plan belongs to another state')
    return store.naming_apply(args.plan)

def main():
    parser=argparse.ArgumentParser(); sub=parser.add_subparsers(dest='action',required=True)
    p=sub.add_parser('init'); p.add_argument('--source',required=True); p.add_argument('--state',required=True); p.add_argument('--temp',default=str(Path(os.environ.get('TEMP','/tmp'))/'vlog-index')); p.add_argument('--run-id'); p.add_argument('--date'); p.add_argument('--ffmpeg',required=True); p.add_argument('--ffprobe',required=True); p.add_argument('--service',required=True); p.add_argument('--host',choices=tuple(HOST_MODEL_ROLES),default='codex',help='Host runtime that dispatches the Agents; selects model_roles'); p.add_argument('--vision-concurrency',type=int,default=6,help='Dynamic host vision upper bound; actual free host capacity still applies')
    p.add_argument('--asr-model',default=asr.MODEL,help='Exact service model id; also part of the ASR cache key'); p.add_argument('--preview-lut-map',help='JSON mapping device:Log-token to explicitly matched local .cube files')
    funcs={'init':init,'hardware':hardware,'prepare':prepare,'packages':packages,'import-results':import_results,'continue-day':continue_day,'decide-supplement':decide_supplement,'supplement':supplement,'audio':audio,'daily-package':daily_package,'gps-review-package':gps_review_package,'attach-itinerary':attach_itinerary,'geography-package':geography_package,'import-geography':import_geography,'review-frames':review_frames,'render':render,'approve-final':approve_final,'publish':publish,'cleanup':cleanup,'status':lambda a:report.coverage(load(a))}
    funcs.update({'map-lookup':map_lookup,'subject-targets':subject_targets,'gps-build':gps_build,'configure-source':configure_source,'asr-json-sample':asr_json_sample,'adopt-json-sample':adopt_json_sample})
    funcs.update({'attach-review-context':attach_review_context,'final-review-package':final_review_package})
    funcs.update({'naming-plan':naming_plan,'naming-review':naming_review,'naming-apply':naming_apply})
    funcs.update({'hardware-benchmark':hardware_benchmark})
    funcs.update({'configure-concurrency':configure_concurrency,'vision-queue':vision_queue})
    funcs.update({'retry-visual':retry_visual})
    for name in funcs:
        if name=='init': continue
        p=sub.add_parser(name); p.add_argument('--state',required=True); p.add_argument('--source-id',action='append')
        if name=='prepare': p.add_argument('--blocks',type=int,help='Process a bounded batch; full remaining plan stays pending')
        if name=='packages': p.add_argument('--gps'); p.add_argument('--garmin-companion',action='append',help='Explicit source id whose camera accompanies the Garmin recorder'); p.add_argument('--refresh',action='store_true',help='Explicitly rebuild legacy prompt packages; downstream semantic approvals become stale')
        if name=='render': p.add_argument('--daily',help='Semantic Agent merged daily JSON; citations are checked before rendering')
        if name=='decide-supplement':
            p.add_argument('--request-id',required=True); p.add_argument('--decision',choices=('accept','reject'),required=True); p.add_argument('--reviewer',choices=('ROOT',),required=True); p.add_argument('--reason',required=True)
        if name=='supplement': p.add_argument('--list-requests',action='store_true',help='Show candidate ids and ROOT decisions without extracting')
        if name=='approve-final': p.add_argument('--reviewer',choices=('ROOT',),required=True); p.add_argument('--reason',required=True); p.add_argument('--review-result',required=True)
        if name=='import-results': p.add_argument('--refresh',action='store_true',help='Revalidate an explicitly corrected existing result')
        if name=='continue-day': p.add_argument('--protocol',required=True); p.add_argument('--gps'); p.add_argument('--garmin-companion',action='append')
        if name=='gps-review-package': p.add_argument('--gps',required=True); p.add_argument('--reason',required=True,help='Evidence confirming the supplied Garmin track accompanies this trip')
        if name=='attach-itinerary': p.add_argument('--itinerary',required=True); p.add_argument('--map-evidence')
        if name=='geography-package': p.add_argument('--daily',required=True); p.add_argument('--research-evidence',help='Sourced research notes; candidates remain subject to dedicated geography Agent review')
        if name=='import-geography': p.add_argument('--result',required=True)
        if name=='review-frames': p.add_argument('--frame-id',action='append',required=True); p.add_argument('--reviewer',choices=('ROOT',),required=True); p.add_argument('--reason',required=True)
        if name=='map-lookup': p.add_argument('--requests',required=True); p.add_argument('--provider',choices=('photon','osm'),required=True); p.add_argument('--output',required=True); p.add_argument('--retry-failed',action='store_true')
        if name=='subject-targets': p.add_argument('--targets'); p.add_argument('--template')
        if name=='gps-build': p.add_argument('--fit-dir',required=True); p.add_argument('--output',required=True); p.add_argument('--date'); p.add_argument('--timezone',default='Asia/Shanghai')
        if name=='configure-source':
            p.add_argument('--role',choices=('camera','drone','unknown')); p.add_argument('--capture-time'); p.add_argument('--unverified-clock',action='store_true'); p.add_argument('--normal-speed',action='store_true'); p.add_argument('--unknown-speed',action='store_true'); p.add_argument('--reason',required=True)
        if name=='adopt-json-sample': p.add_argument('--protocol',required=True); p.add_argument('--reason',required=True)
        if name=='attach-review-context': p.add_argument('--context',required=True)
        if name=='naming-plan': p.add_argument('--config',required=True); p.add_argument('--library-root',required=True); p.add_argument('--index',required=True)
        if name=='hardware-benchmark':
            p.add_argument('--ffmpeg',required=True); p.add_argument('--ffprobe',required=True); p.add_argument('--output',required=True); p.add_argument('--source',action='append'); p.add_argument('--start',type=float,action='append'); p.add_argument('--seconds',type=float,default=12); p.add_argument('--tasks',type=int,default=3); p.add_argument('--compare-filter-order',action='store_true'); p.add_argument('--summarize-only',action='store_true'); p.add_argument('--profiles',default='1,2,3'); p.add_argument('--select-first-only',action='store_true'); p.add_argument('--save-profile',action='store_true')
        if name=='configure-concurrency':
            p.add_argument('--media-slots',type=int,required=True); p.add_argument('--hardware-report'); p.add_argument('--vision-concurrency',type=int,default=6); p.add_argument('--ready-package-limit',type=int,default=24); p.add_argument('--temp-limit-gib',type=float,default=256); p.add_argument('--min-free-gib',type=float,default=5)
        if name=='vision-queue':
            p.add_argument('--available-workers',type=int,required=True); p.add_argument('--reserve-sol',type=int,default=1); p.add_argument('--claim-worker',action='append'); p.add_argument('--release',action='append')
        if name=='retry-visual': p.add_argument('--package-id',required=True); p.add_argument('--reason',required=True)
        if name in ('naming-review','naming-apply'): p.add_argument('--plan',required=True)
        if name=='naming-review': p.add_argument('--reviewer',choices=('ROOT',),required=True); p.add_argument('--reason',required=True)
        if name=='audio': p.add_argument('--protocol'); p.add_argument('--discover',action='store_true'); p.add_argument('--chunks',type=int); p.add_argument('--acknowledge')
    args=parser.parse_args()
    if args.action=='vision-queue':
        print(json.dumps(vision_queue(args),ensure_ascii=False,indent=2),flush=True); return
    with RunLock(args.state): result=funcs[args.action](args)
    print(json.dumps(result,ensure_ascii=False,indent=2),flush=True)
if __name__=='__main__': main()
