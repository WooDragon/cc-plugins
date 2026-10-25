"""Harness task packages and strict evidence/coverage validation."""
from __future__ import annotations
from typing import Literal
import datetime as dt, re
from pathlib import Path
from pydantic import BaseModel, ConfigDict, Field, model_validator
from .store import digest, dump, read, file_hash

SCHEMA_VERSION='1'; PROMPT_VERSION='3'
VISION_INSTRUCTIONS=('实际打开并查看frames中的全部图片（包括边界上下文），analysed_frame_ids逐一完整对账。每个核心帧必须有可见内容观察和对应evidence_ids，无明显事件也记录；无法读取不得伪称已看完，应报告阻塞。'
    'observations只写可见事实；events/interest_points是候选。模糊细节降低置信，区分观察与推测，不凭文件名、行程或相似画面臆造动作、身份或地点。'
    '严格引用本包source_id、文件内时间和证据ID；GPS仅逐字引用提供的完整记录，拍摄位置不等于远景主体位置。若有转写，仅保留原文及原精度，chunk不是词时码，不做音频事件检测。'
    '补采只提候选区间及证据理由，不自行执行。按result_schema将完整JSON写入本包result_path，不能省略帧或伪造证据；不递归委派、不调用ASR、不操作状态库、不发布或删除文件。')

def invalidate_downstream(manifest,reason):
    manifest['published_verified']=False
    manifest.setdefault('downstream_invalidations',[]).append({'reason':reason,'at':dt.datetime.now(dt.timezone.utc).isoformat()})
    manifest.pop('geography',None); manifest.pop('root_final_review',None)
    if manifest.get('semantic_daily'): manifest['semantic_daily']['invalidated_by']=reason

def record_supplement_decision(manifest,request_id,decision,reviewer,reason):
    """Record the ROOT decision of the host session; model proposals never authorize extraction."""
    if reviewer!='ROOT' or not reason.strip(): raise ValueError('Supplement decisions require ROOT and an evidence-based reason')
    if decision not in ('accept','reject'): raise ValueError('Decision must be accept or reject')
    decisions=manifest.setdefault('supplemental_decisions',{})
    if request_id in decisions:
        if decisions[request_id]['decision']!=decision: raise ValueError('A recorded decision cannot be silently reversed')
        return decisions[request_id]
    request=next((r for r in manifest.get('supplemental_pending',[]) if digest(r)==request_id),None)
    if request is None: raise ValueError('Unknown pending supplement request')
    round_info=manifest.get('supplemental_round')
    if decision=='accept' and round_info and request_id not in round_info['request_ids']:
        raise ValueError('Only one supplement round is allowed; finish or review the existing round')
    record={'request_id':request_id,'request':dict(request),'decision':decision,'reviewer':reviewer,'reason':reason,'at':dt.datetime.now(dt.timezone.utc).isoformat()}
    decisions[request_id]=record
    if decision=='accept': invalidate_downstream(manifest,'ROOT accepted supplement '+request_id)
    if decision=='reject': manifest['supplemental_pending']=[r for r in manifest.get('supplemental_pending',[]) if digest(r)!=request_id]
    return record

def validate_itinerary(value):
    if not isinstance(value,dict) or not str(value.get('title','')).strip(): raise ValueError('Itinerary requires a title')
    refs=value.get('source_refs',[]); entries=value.get('entries',[])
    if not refs or not entries: raise ValueError('Itinerary and actual source references are mandatory')
    ids=[r.get('id') for r in refs]
    if len(ids)!=len(set(ids)) or not all(ids): raise ValueError('Itinerary source ids must be unique')
    for ref in refs:
        if not all(str(ref.get(k,'')).strip() for k in ('kind','reference','excerpt')): raise ValueError('Itinerary sources require kind, reference and excerpt')
    entry_ids=[e.get('id') for e in entries]
    if len(entry_ids)!=len(set(entry_ids)) or not all(entry_ids): raise ValueError('Itinerary entry ids must be unique')
    for entry in entries:
        if not str(entry.get('place','')).strip() or not entry.get('source_refs') or not set(entry['source_refs'])<=set(ids): raise ValueError('Itinerary entry requires a place and legal source references')
        if entry.get('date'): dt.date.fromisoformat(entry['date'])
    return value

def validate_map_evidence(records):
    if not isinstance(records,list): raise ValueError('Map evidence must be a list')
    ids=[]
    def no_secrets(value):
        if isinstance(value,dict):
            for key,item in value.items():
                if key.lower().replace('-','_') in ('key','api_key','apikey','token','access_token','authorization','password','secret','client_secret') and item not in (None,'','REDACTED','<redacted>'): raise ValueError('Map evidence must not contain API credentials')
                no_secrets(item)
        elif isinstance(value,list):
            for item in value: no_secrets(item)
        elif isinstance(value,str) and re.search(r'[?&](?:key|api_key|token|access_token)=(?!REDACTED(?:&|$)|%3Credacted%3E)[^&\s]+',value,re.I): raise ValueError('Map request URL contains credentials')
    for record in records:
        no_secrets(record); ids.append(record.get('id'))
        if record.get('status')=='failed': raise ValueError('Failed map lookup must be resolved or explicitly discussed before final publication')
        if not all(record.get(k) for k in ('id','provider','query_type','coordinates','queried_at','precision')) or 'response' not in record or 'request_sanitized' not in record: raise ValueError('Map evidence lacks query provenance')
        point=record['coordinates']
        if not point.get('crs') or not -90<=point.get('latitude',999)<=90 or not -180<=point.get('longitude',999)<=180 or (point['latitude']==0 and point['longitude']==0): raise ValueError('Map coordinates require valid values and CRS')
        original=record.get('original_coordinates')
        if original and original.get('crs')!=point['crs'] and not record.get('conversion_provenance'): raise ValueError('Coordinate conversion provenance is required')
    if len(ids)!=len(set(ids)): raise ValueError('Map evidence ids must be unique')
    return records

def map_lookup(requests,provider,cache_dir,client=None,retry_failed=False):
    """Fixed keyless Photon/OSM capture; caches successes, empty results and failures."""
    import httpx, math, time
    if provider not in ('photon','osm') or not isinstance(requests,list): raise ValueError('Use photon/osm and a JSON request list')
    cache_dir=Path(cache_dir); cache_dir.mkdir(parents=True,exist_ok=True)
    owned=client is None; client=client or httpx.Client(timeout=30,trust_env=False,headers={'User-Agent':'vlog-daily-index/0.2.0 (personal media indexing)'})
    records=[]; called=False
    try:
        for request in requests:
            point=request.get('coordinates',request)
            if point.get('crs') not in ('EPSG:4326','WGS84') or not -90<=point.get('latitude',999)<=90 or not -180<=point.get('longitude',999)<=180 or (point['latitude']==0 and point['longitude']==0): raise ValueError('Map lookup requires nonplaceholder WGS84 coordinates')
            if provider=='photon':
                params={'lat':point['latitude'],'lon':point['longitude'],'radius':request.get('radius_km',50),'limit':request.get('limit',5)}
                if not 0<params['radius']<=50 or not 1<=params['limit']<=5: raise ValueError('Photon lookup uses radius <=50 km and limit <=5')
                endpoint='https://photon.komoot.io/reverse'; kind='reverse_geocoding'
            else:
                object_type=request.get('object_type'); object_id=request.get('object_id')
                if object_type not in ('node','way','relation') or not isinstance(object_id,int) or object_id<=0: raise ValueError('OSM requires a positive node/way/relation object id')
                endpoint=f'https://www.openstreetmap.org/api/0.6/{object_type}/{object_id}'+('/full.json' if object_type!='node' else '.json'); params={}; kind='object_geometry'
            key=digest({'provider':provider,'endpoint':endpoint,'params':params,'reference_coordinates':point,'version':1}); path=cache_dir/(key+'.json')
            if path.exists():
                cached=__import__('json').loads(path.read_text(encoding='utf-8'))
                if cached.get('status')!='failed' or not retry_failed: records.append(cached); continue
            if called: time.sleep(1)
            called=True
            record={'id':provider+':'+key[:20],'provider':provider,'query_type':kind,'coordinates':{k:point[k] for k in ('latitude','longitude','crs')},'request_sanitized':{'endpoint':endpoint,'params':params},'queried_at':dt.datetime.now(dt.timezone.utc).isoformat(),'precision':'Map query evidence; returned label/geometry is not proof of visible subject identity','candidates':[]}
            try:
                response=client.get(endpoint,params=params); response.raise_for_status(); body=response.json(); record['response']=body
                for feature in body.get('features',[]):
                    geometry=feature.get('geometry',{}); props=feature.get('properties',{})
                    if geometry.get('type')!='Point': continue
                    lon,lat=geometry['coordinates']; distance=6371000*math.hypot(math.radians(lat-point['latitude']),math.radians(lon-point['longitude'])*math.cos(math.radians(point['latitude'])))
                    record['candidates'].append({'name':props.get('name'),'coordinates':{'latitude':lat,'longitude':lon,'crs':'EPSG:4326'},'label_distance_m':round(distance,3),'distance_meaning':'distance to label point, not shoreline/boundary distance','properties':props})
                record['status']='empty' if provider=='photon' and not body.get('features') else 'success'
            except Exception as exc:
                record.update(status='failed',response={'error':str(exc)},error=str(exc))
            dump(path,record); records.append(record)
    finally:
        if owned: client.close()
    return records

def finding_key(category,index,item):
    return f'{category}:{index:02}:{digest(item)[:16]}'

class GeographyAssociation(BaseModel):
    model_config=ConfigDict(extra='forbid')
    finding_key:str
    status:Literal['resolved','approximate','unresolved']
    region:str|None=None
    place_name:str|None=None
    subject_kind:Literal['recording_camera','recording_person','visible_subject','unknown','recording','distant_subject']
    confidence:Literal['high','medium','low']
    reason:str
    evidence_ids:list[str]=[]
    itinerary_refs:list[str]=[]
    gps_refs:list[str]=[]
    map_evidence_ids:list[str]=[]
    alternatives:list[dict|str]=[]
    clip_associations:list[dict]=[]
    subject_landmarks:list[dict]=[]

class GeographyResult(BaseModel):
    model_config=ConfigDict(extra='forbid')
    package_id:str
    associations:list[GeographyAssociation]
    notes:str=''
    updated_summary:str|None=None

def validate_geography(value,package):
    parsed=GeographyResult.model_validate(value).model_dump()
    if parsed['package_id']!=package['package_id']: raise ValueError('Geography result is stale or belongs to another package')
    findings={f['finding_key']:f for f in package['findings']}; keys=[a['finding_key'] for a in parsed['associations']]
    if len(keys)!=len(set(keys)) or set(keys)!=set(findings): raise ValueError('Every event and interest point requires one geography result, including unresolved')
    itineraries={e['id'] for e in package['itinerary']['entries']}
    gps={r['id']:r for r in package['gps_records']}; maps={r['id']:r for r in package['map_evidence']}
    for association in parsed['associations']:
        finding=findings[association['finding_key']]['finding']; clips=finding['clips']; evidence={e for c in clips for e in c['evidence_ids']}
        if not association['reason'].strip() or association['reason'].strip()=='TODO': raise ValueError('Geography reasoning is mandatory; an unfilled template is not analysis')
        if not set(association['evidence_ids'])<=evidence or not set(association['itinerary_refs'])<=itineraries or not set(association['map_evidence_ids'])<=maps.keys() or not set(association['gps_refs'])<=gps.keys(): raise ValueError('Geography contains unknown or cross-finding references')
        for ref in association['gps_refs']:
            point=gps[ref]
            if not any(point.get('source_id')==c['source_id'] and (point.get('frame_id') in c['evidence_ids'] if point.get('frame_id') else point['start']<=c['end'] and point['end']>=c['start']) for c in clips): raise ValueError('GPS reference does not belong to the finding clips')
        if association['status']!='unresolved' and (not association['evidence_ids'] or not association['itinerary_refs']): raise ValueError('A geographic inference requires finding evidence and itinerary references')
        if association['status']!='unresolved' and not (association['region'] or association['place_name']): raise ValueError('A geographic inference requires a nonempty place or region')
        if association['status']=='resolved' and not association['map_evidence_ids']: raise ValueError('A resolved place requires an actual map lookup; otherwise use approximate or unresolved')
        possible_gps={key for key,point in gps.items() if point.get('frame_id') in evidence}
        positive_maps=[maps[key] for key in association['map_evidence_ids'] if maps[key].get('status') not in ('failed','empty') and not (isinstance(maps[key].get('response'),dict) and maps[key]['response'].get('type')=='FeatureCollection' and not maps[key]['response'].get('features'))]
        if (association['status']=='resolved' or (association['status']=='approximate' and possible_gps)) and not positive_maps: raise ValueError('A place inference cannot use failed/empty lookups as positive map evidence')
        if association['status']!='unresolved' and possible_gps:
            if not association['map_evidence_ids']: raise ValueError('A GPS-backed inference requires an actual map lookup linked to this finding')
            for map_id in association['map_evidence_ids']:
                record=maps[map_id]
                if not (set(record.get('related_gps_ids',[])+record.get('gps_refs',[])) & (possible_gps|set(association['gps_refs'])) or set(record.get('itinerary_refs',[])) & set(association['itinerary_refs'])): raise ValueError('Map evidence is not linked to this finding GPS or itinerary')
        if association['status']=='unresolved' and (association['region'] or association['place_name']): raise ValueError('Unresolved geography cannot assert a place')
        for clip in association['clip_associations']:
            if not any(clip.get('source_id')==c['source_id'] and abs(c['start']-clip.get('start',-999))<=0.001 and abs(c['end']-clip.get('end',-999))<=0.001 for c in clips): raise ValueError('Per-clip geography must match the exact finding source interval')
            if not set(clip.get('gps_refs',[]))<=set(association['gps_refs']) or not set(clip.get('map_evidence_ids',[]))<=set(association['map_evidence_ids']): raise ValueError('Per-clip geography must cite the finding linked evidence')
        for landmark in association['subject_landmarks']:
            if not all(landmark.get(k) for k in ('target_id','subject','identity_status','reason')) or landmark['identity_status'] not in ('identified','candidate','unresolved'): raise ValueError('Subject landmarks require target, explicit identity status and reasoning')
            if landmark['identity_status']!='unresolved' and not landmark.get('evidence_ids'): raise ValueError('A landmark identity/candidate requires actual visual evidence')
            if not set(landmark.get('evidence_ids',[]))<=evidence or not set(landmark.get('camera_position_refs',[]))<=gps.keys() or not set(landmark.get('map_refs',[]))<=maps.keys(): raise ValueError('Subject landmark cites unknown evidence')
            for ref in landmark.get('camera_position_refs',[]):
                if gps[ref].get('frame_id') not in evidence: raise ValueError('Subject camera reference is outside this finding')
    for target in package.get('subject_review_targets',[]):
        required=set(target['finding_keys'])
        done={a['finding_key'] for a in parsed['associations'] if any(s['target_id']==target['target_id'] for s in a['subject_landmarks'])}
        if not required<=done: raise ValueError('Required visual subject target is unanalysed: '+target['target_id'])
    return parsed

def geography_bindings(manifest,daily):
    itinerary=manifest.get('itinerary',{}); maps=manifest.get('map_evidence',{})
    data=validate_itinerary(itinerary.get('data'))
    map_data=validate_map_evidence(maps.get('records',[]))
    if itinerary.get('sha256')!=digest(data) or maps.get('sha256')!=digest(map_data): raise ValueError('Itinerary or map evidence digest is stale')
    return {'daily_sha256':digest(daily),'itinerary_sha256':digest(data),'map_evidence_sha256':digest(map_data),'gps_association_sha256':digest(manifest.get('gps_association',{}))}

def require_geography(manifest,daily):
    if not daily: raise ValueError('Final rendering requires a validated daily result and mandatory itinerary/geography stage')
    expected=geography_bindings(manifest,daily); geography=manifest.get('geography',{})
    if geography.get('input_digests')!=expected or geography.get('sha256')!=digest(geography.get('data')) or geography.get('package_id')!=manifest.get('geography_package',{}).get('package_id'):
        raise ValueError('Geography is missing or stale; attach sourced itinerary and run the dedicated geography Agent review')
    if geography.get('subject_review_targets_sha256',digest([]))!=digest(manifest.get('subject_review_targets',[])): raise ValueError('Subject review targets changed after geography validation')
    for target in manifest.get('subject_review_targets',[]):
        done={a['finding_key'] for a in geography['data']['associations'] if any(s.get('target_id')==target['target_id'] for s in a.get('subject_landmarks',[]))}
        if not set(target['finding_keys'])<=done: raise ValueError('Required visual subject review is incomplete')
    return geography

def final_review_bindings(manifest,daily):
    geography=require_geography(manifest,daily)
    state=Path(manifest['state_dir']); records=[]
    for package in manifest.get('packages',[]):
        path=state/'analysis'/(package['id']+'.json')
        if package['status']=='success' and path.is_file(): records.append({'package_id':package['id'],'sha256':file_hash(path)})
    final_dir=state/'final'
    return {**geography_bindings(manifest,daily),'gps_context_sha256':digest(manifest.get('gps',{})),'source_context_sha256':digest([{k:s.get(k) for k in ('id','status','role','metadata','size','mtime_ns','sidecars')} for s in manifest.get('sources',[])]),'geography_sha256':geography['sha256'],'transcription_sha256':digest(manifest.get('transcription',{})),'visual_records_sha256':digest(records),'subject_targets_sha256':digest(manifest.get('subject_review_targets',[])),'supplement_decisions_sha256':digest({'pending':manifest.get('supplemental_pending',[]),'decisions':manifest.get('supplemental_decisions',{}),'plans':manifest.get('supplemental_plans',{})}),'review_context_sha256':digest(manifest.get('final_review_context',{})),'rendered_files_sha256':digest({p.name:file_hash(p) for p in final_dir.glob('AI_*') if p.is_file()})}

REVIEW_DIMENSIONS={'itinerary_vs_actual','gps_route_and_stops','time_place_consistency','visual_and_transcription','subject_landmarks','supplement_decisions'}

def validate_final_review(value,package):
    if value.get('reviewer')!='ROOT' or value.get('package_id')!=package['package_id'] or value.get('conclusion')!='approved' or not str(value.get('reason','')).strip(): raise ValueError('ROOT substantive final review is missing or belongs to another evidence package')
    if not REVIEW_DIMENSIONS<=set(value.get('checked_dimensions',[])): raise ValueError('Final review must address itinerary, GPS/stops, time/place, visual/ASR, subjects and supplements')
    issues=value.get('issues',[])
    if value.get('blocking_remaining')!=0 or any(i.get('blocking') and i.get('status') not in ('resolved','accepted_limitation') for i in issues): raise ValueError('Unresolved blocking issues prohibit publication')
    if any(not str(i.get('disposition','')).strip() for i in issues): raise ValueError('Every review issue needs an explicit disposition')
    return value

class Evidence(BaseModel):
    model_config=ConfigDict(extra='forbid')
    source_id:str; start:float=Field(ge=0); end:float=Field(ge=0)
    precision:Literal['sampled_frames','chunk','service_segment','decoded_frame_pts']
    evidence_ids:list[str]=Field(min_length=1)
    @model_validator(mode='after')
    def ordered(self):
        if self.end<self.start: raise ValueError('negative interval')
        return self

class Finding(BaseModel):
    model_config=ConfigDict(extra='forbid')
    title:str; type:str; reason:str
    confidence:Literal['high','medium','low']; priority:Literal['high','medium','low']
    needs_review:bool; clips:list[Evidence]=Field(min_length=1)
    location:dict|None=None

class Observation(BaseModel):
    model_config=ConfigDict(extra='forbid')
    source_id:str; start:float; end:float; description:str; evidence_ids:list[str]=Field(min_length=1)

class Result(BaseModel):
    model_config=ConfigDict(extra='forbid')
    package_id:str; analysed_frame_ids:list[str]; observations:list[Observation]=Field(min_length=1)
    events:list[Finding]; interest_points:list[Finding]
    supplemental_requests:list[dict]=[]
    summary:str

class DailyResult(BaseModel):
    model_config=ConfigDict(extra='forbid')
    summary:str
    summary_evidence_ids:list[str]=Field(min_length=1)
    events:list[Finding]
    interest_points:list[Finding]

def validate_daily(value,manifest,validated_results):
    """The semantic Agent supplies semantic merging; deterministic code checks provenance."""
    parsed=DailyResult.model_validate(value).model_dump()
    analysed={fid for p in manifest['packages'] if p['status']=='success' for fid in p['core_frame_ids']}
    evidence={f['id']:f for f in manifest.get('frames',[])+manifest.get('supplemental_frames',[]) if f['id'] in analysed}
    frame_ids=set(evidence)
    for entry in manifest.get('transcription',{}).values():
        evidence.update({s['id']:s for s in entry.get('segments',[])})
    sources={s['id']:s for s in manifest['sources']}
    if not set(parsed['summary_evidence_ids'])<=evidence.keys(): raise ValueError('Daily summary cites unknown or unanalysed evidence')
    locations=[f['location'] for r in validated_results for f in r['events']+r['interest_points'] if f.get('location')]
    locations+=manifest.get('gps_association',{}).get('frame_locations',[])
    for item in parsed['events']+parsed['interest_points']:
        if item['location'] and item['location'] not in locations: raise ValueError('Daily location must cite a previously validated location')
        if item['location'] and item['location'].get('frame_id'):
            frame_id=item['location']['frame_id']; source_id=evidence.get(frame_id,{}).get('source_id')
            if not source_id or item['location'].get('source_id',source_id)!=source_id or not any(frame_id in c['evidence_ids'] and c['source_id']==source_id for c in item['clips']):
                raise ValueError('Daily frame location requires its source frame among the cited clips')
        for c in item['clips']:
            if c['source_id'] not in sources or not 0<=c['start']<=c['end']<=sources[c['source_id']]['duration']: raise ValueError('Daily clip outside valid source')
            for eid in c['evidence_ids']:
                if eid not in evidence or evidence[eid]['source_id']!=c['source_id']: raise ValueError('Daily evidence/source mismatch')
                e=evidence[eid]
                if 'time' in e and not c['start']-0.25<=e['time']<=c['end']+0.25: raise ValueError('Daily frame outside clip')
                if 'start' in e and not (e['start']<=c['end'] and e['end']>=c['start']): raise ValueError('Daily transcript outside clip')
            cited=[evidence[eid] for eid in c['evidence_ids']]
            if not any(eid in frame_ids for eid in c['evidence_ids']):
                speech=[e for e in cited if 'start' in e and 'end' in e]
                if speech:
                    if c['precision'] in ('decoded_frame_pts','sampled_frames'): raise ValueError('ASR-only evidence cannot claim video-frame precision')
                    if any(e.get('precision','chunk')=='chunk' for e in speech) and c['precision']!='chunk': raise ValueError('Chunk transcription cannot be upgraded to service/word precision')
                    if abs(c['start']-min(e['start'] for e in speech))>0.001 or abs(c['end']-max(e['end'] for e in speech))>0.001:
                        raise ValueError('ASR-only clips must retain the cited transcription interval, not invented edit points')
    return parsed

def make_packages(source,frames,transcripts,output_dir,gps=None,size=10,visual_mode=None):
    output_dir=Path(output_dir); packages=[]
    for start in range(0,len(frames),size):
        core=frames[start:start+size]
        context=frames[max(0,start-max(1,8-len(core))):start]
        begin=max(0,core[0]['time']-5); end=min(source['duration'],core[-1]['time']+10)
        tr=[t for t in transcripts if t['start']<=end and t['end']>=begin]
        source_context={k:source[k] for k in ('id','path','relative_path','duration','role')}
        source_context['metadata']={k:v for k,v in source['metadata'].items() if k!='location_points'}
        frame_ids={f['id'] for f in context+core}
        locations=[p for p in (gps or []) if p.get('frame_id') in frame_ids]
        payload={'schema_version':SCHEMA_VERSION,'prompt_version':PROMPT_VERSION,'instructions':VISION_INSTRUCTIONS,'source':source_context,'core_frame_ids':[f['id'] for f in core],'frames':context+core,'transcripts':tr,'gps':locations,'interval':{'start':begin,'end':end},'image_warning':'技术预览以各帧preview记录为准；缺少已验证变换时不推断画面质量。','result_schema':Result.model_json_schema()}
        if visual_mode:
            payload['visual_package_mode']=visual_mode
            payload['transcript_policy']='Pure visible-content observations only; complete independent ASR is supplied to the semantic Agent in the daily package. Never infer speech or audio events.'
        payload['package_id']=digest(payload)[:24]
        payload['result_path']=str(output_dir/(payload['package_id']+'.result.json'))
        path=output_dir/(payload['package_id']+'.package.json'); dump(path,payload)
        packages.append({'id':payload['package_id'],'path':str(path),'result_path':payload['result_path'],'status':'waiting_ai','core_frame_ids':payload['core_frame_ids']})
    return packages

def validate_result(package,result):
    parsed=Result.model_validate(result); data=parsed.model_dump()
    if data['package_id']!=package['package_id']: raise ValueError('package id mismatch')
    all_frames={f['id']:f for f in package['frames']}; tr={t['id']:t for t in package['transcripts']}; allowed={**all_frames,**tr}
    analysed=data['analysed_frame_ids']
    if len(analysed)!=len(set(analysed)) or set(analysed)!=set(all_frames): raise ValueError('Every supplied image must be analysed, including boundary context')
    sid=package['source']['id']; duration=package['source']['duration']
    def check(clip):
        if clip['source_id']!=sid or not 0<=clip['start']<=clip['end']<=duration+0.001: raise ValueError('source/time outside package source')
        for eid in clip['evidence_ids']:
            if eid not in allowed: raise ValueError('unknown evidence '+eid)
            e=allowed[eid]
            if 'time' in e and not clip['start']-0.25<=e['time']<=clip['end']+0.25: raise ValueError('frame evidence lies outside claimed clip')
            if 'start' in e and not (e['start']<=clip['end'] and e['end']>=clip['start']): raise ValueError('transcript evidence lies outside claimed clip')
    observed=set()
    for o in data['observations']:
        check(o); observed.update(e for e in o['evidence_ids'] if e in all_frames)
    if not set(package['core_frame_ids'])<=observed: raise ValueError('observations must account for all core frames, even no event')
    for finding in data['events']+data['interest_points']:
        for clip in finding['clips']: check(clip)
        if finding['location']:
            permitted=package.get('gps') or []
            if finding['location'] not in permitted: raise ValueError('location must exactly cite a provided location record; visual guesses prohibited')
    for req in data['supplemental_requests']:
        if req.get('source_id')!=sid or not 0<=req.get('start',-1)<=req.get('end',-1)<=duration or not req.get('reason'): raise ValueError('invalid supplemental interval')
    return data

def merge_intervals(requests,duration,before=15,after=30):
    intervals=sorted((max(0,r['start']-before),min(duration,r['end']+after)) for r in requests)
    merged=[]
    for a,b in intervals:
        if merged and a<=merged[-1][1]: merged[-1][1]=max(b,merged[-1][1])
        else: merged.append([a,b])
    return merged
