"""Three-file publication with shared run identity and verified dependency hashes."""
from __future__ import annotations
import datetime as dt, json, os, re, shutil, copy
from pathlib import Path
from zoneinfo import ZoneInfo
from .store import dump,read,file_hash,digest,publication_snapshot
from .media import unchanged
from . import analysis

TOOL='vlog-daily-index'; NAMES=['AI_音频转写.json','AI_事件与兴趣点.json','AI_每日索引.md']

def coverage(manifest):
    sources=manifest['sources']; frames=manifest.get('frames',[])
    analysed={f for p in manifest.get('packages',[]) if p['status']=='success' and not p.get('supplemental') for f in p['core_frame_ids']}
    failures=[{'source':s['relative_path'],'reason':s.get('error','probe failed')} for s in sources if s['status']=='failed']
    pending=[p['id'] for p in manifest.get('packages',[]) if p['status']!='success']
    planned=sum(len(s.get('sample_times',[])) for s in sources)
    audio=manifest.get('transcription',{})
    audio_pending=[s['id'] for s in sources if s['status']=='ready' and audio.get(s['id'],{}).get('status') not in ('success','skipped_drone','no_audio')]
    unresolved=manifest.get('supplemental_pending',[])
    accepted=[r for r in unresolved if manifest.get('supplemental_decisions',{}).get(digest(r),{}).get('decision')=='accept']
    missing=[]
    for source in sources:
        for block in source.get('blocks',[]):
            prefix=f'{source["id"]}-b{block["index"]:03}-'
            extracted=sum(f['id'].startswith(prefix) for f in frames)
            if extracted<len(block['samples']): missing.append({'source_id':source['id'],'source':source['relative_path'],'block':block['index'],'start':block['start'],'end':block['end'],'planned':len(block['samples']),'extracted':extracted})
    readable=sum(s['status']=='ready' for s in sources)
    analysis_ready=planned==len(frames)==len(analysed) and not missing and not pending and not audio_pending and not accepted
    readable_complete=analysis_ready and not unresolved
    return {'sources':len(sources),'readable_sources':readable,'planned_frames':planned,'extracted_frames':len(frames),'analysed_frames':len(analysed),'failed_sources':failures,'missing_extraction_intervals':missing,'pending_packages':pending,'pending_audio_sources':audio_pending,'pending_supplemental':unresolved,'analysis_ready':analysis_ready,'readable_complete':readable_complete,'complete':readable_complete and not failures}

def render(manifest,results,output_dir,daily=None):
    geography=analysis.require_geography(manifest,daily)
    output=Path(output_dir); output.mkdir(parents=True,exist_ok=True)
    cov=coverage(manifest)
    if cov['readable_complete'] and (daily is not None or not manifest['sources']): status='terminal_with_gaps' if cov['failed_sources'] else 'complete'
    else: status='partial'
    common={'generator':TOOL,'schema_version':'1','run_id':manifest['run_id'],'revision':manifest.get('revision',1),'status':status,'itinerary_sha256':manifest['itinerary']['sha256'],'geography_sha256':geography['sha256']}
    transcript={**common,'model':manifest['config']['asr_model'],'service_state':manifest.get('asr_service_state'),'sources':manifest.get('transcription',{})}
    dump(output/NAMES[0],transcript)
    events=copy.deepcopy(daily['events']) if daily else [e for r in results for e in r['events']]
    poi=copy.deepcopy(daily['interest_points']) if daily else [p for r in results for p in r['interest_points']]
    for correction in manifest.get('final_review_context',{}).get('finding_text_corrections',[]):
        items=events if correction['category']=='event' else poi
        item=items[correction['number']-1]
        if correction.get('reviewer')!='ROOT' or item['title']!=correction['expected_title']: raise ValueError('ROOT text correction no longer matches the finding')
        item['reason']=correction['reason']
    index={**common,'archival_date':manifest['config'].get('date'),'timezone':manifest['config'].get('timezone','Asia/Shanghai'),'coverage':cov,'events':events,'interest_points':poi,'sources':manifest['sources'],'gps':manifest.get('gps'),'hardware':manifest.get('hardware'),'versions':manifest.get('versions',{}),'config':manifest['config'],'transcript_sha256':file_hash(output/NAMES[0]),'limitations':['10秒均匀粗扫不代表逐帧观看，可能漏掉采样间短暂事件。','未提供行程；不凭画面猜具体山名。','拍摄时间或播放速度未验证的素材只提供文件内定位；位置表示拍摄者而非远处景物。']}
    dump(output/NAMES[1],index)
    index['source_failures']=cov['failed_sources']; index['sampling_adjustments']=manifest.get('plan_adjustments',[])
    index['evidence_frames']=[{k:f.get(k) for k in ('id','source_id','planned_time','time','pts','precision')} for f in manifest.get('frames',[])+manifest.get('supplemental_frames',[])]
    index['validated_records']=results
    index['validated_records_note']='原始视觉候选审计记录：仅表示覆盖和引用已校验，语义可能经ROOT纠正；最终事件、兴趣点与日摘要以语义Agent日包及ROOT复核决定为准。'
    index['root_review_decisions']=manifest.get('root_review_decisions',[])
    index['path_rebindings']=manifest.get('path_rebindings',[])
    index['itinerary']=manifest['itinerary']['data']; index['map_evidence']=manifest['map_evidence']['records']
    index['geography']=geography['data']; index['geography_input_digests']=geography['input_digests']
    index['analysis_daily']=daily
    index['analysis_daily_note']='地理关联输入阶段快照，仅作审计；最终叙述采用主events/interest_points、最终日摘要及ROOT定向文字纠偏。'
    index['subject_review_targets']=manifest.get('subject_review_targets',[])
    index['final_review_context']=manifest.get('final_review_context',{})
    index['limitations'][1]='行程与地图查询用于有依据的地点关联；近似地名和替代候选不等于已确认景物。'
    if manifest.get('gps_association'): index['gps_association']=manifest['gps_association']
    dump(output/NAMES[1],index)
    status_label=f'可读素材已完成，{len(cov["failed_sources"])}项损坏未覆盖' if status=='terminal_with_gaps' else '可读素材已完成' if status=='complete' else '处理中，覆盖尚未完成'
    lines=[f'<!-- generator:{TOOL}; run_id:{manifest["run_id"]}; revision:{common["revision"]} -->',f'# 每日事件与兴趣点索引（{status_label}）','',f'归档日期：{index["archival_date"]}；显示时区：{index["timezone"]}。',f'来源 {cov["sources"]} 个（可读 {cov["readable_sources"]}）；采样计划 {cov["planned_frames"]}，已提取 {cov["extracted_frames"]}，已分析 {cov["analysed_frames"]}。','',f'原片时码为文件内位置。完整证据见 `{NAMES[1]}`。']
    if daily:
        index['analysis_summary']=daily['summary']; index['daily_summary']=geography['data'].get('updated_summary') or daily['summary']; index['summary_evidence_ids']=daily['summary_evidence_ids']; dump(output/NAMES[1],index)
        sentences=[s for s in re.split(r'(?<=。)',index['daily_summary']) if s]
        lines += ['','## 日摘要','']+[''.join(sentences[n:n+2])+'\n' for n in range(0,len(sentences),2)]
    if status=='terminal_with_gaps': lines += ['',f'可读素材处理完成；{len(cov["failed_sources"])}项源损坏未覆盖。该结果不代表全部{cov["sources"]}个来源均已观看。','']
    levels={'high':'高','medium':'中','low':'低'}
    precision_labels={'sampled_frames':'采样画面','chunk':'约30秒转写片段','service_segment':'服务端转写片段','decoded_frame_pts':'实际解码帧'}
    def timecode(seconds):
        whole,millis=divmod(round(seconds*1000),1000); hours,rest=divmod(whole,3600); minutes,secs=divmod(rest,60)
        return f'{hours:02}:{minutes:02}:{secs:02}'+(f'.{millis:03}'.rstrip('0') if millis else '')
    geo_by_key={a['finding_key']:a for a in geography['data']['associations']}; shown_alternatives=set()
    def findings(items,category):
        for number,item in enumerate(items,1):
            yield f'- **{item["title"]}**：{item["reason"]}（可信度：{levels[item["confidence"]]}；优先级：{levels[item["priority"]]}）'
            raw_item=(daily['events'] if category=='event' else daily['interest_points'])[number-1]
            geo=geo_by_key[analysis.finding_key(category,number,raw_item)]
            place=' / '.join(p for p in (geo['region'],geo['place_name']) if p) or '未确定'
            label={'resolved':'地图证据支持','approximate':'近似关联','unresolved':'未确定'}[geo['status']]
            subject={'recording_camera':'相机位置','recording_person':'记录者位置','visible_subject':'画面主体','unknown':'对象未确定','recording':'记录者/相机位置','distant_subject':'远景主体'}[geo['subject_kind']]
            yield f'  - 地点：{place}（{label}；{subject}；可信度：{levels[geo["confidence"]]}）。{geo["reason"]}'
            alternatives=[]
            for candidate in geo.get('alternatives',[]):
                name=candidate if isinstance(candidate,str) else candidate.get('name') or candidate.get('place_name') or candidate.get('label')
                if name and name not in shown_alternatives: alternatives.append(name); shown_alternatives.add(name)
            if alternatives: yield '  - 其他候选（未确认）：'+'、'.join(alternatives)
            for landmark in geo.get('subject_landmarks',[]):
                status={'identified':'证据支持','candidate':'候选，未最终确认','unresolved':'尚未确定'}[landmark['identity_status']]
                yield f'  - 视觉主体：{landmark["subject"]}（{status}）。{landmark["reason"]}'
                if landmark.get('missing_evidence'):
                    missing=landmark['missing_evidence']; yield '    - 身份核验缺口：'+('；'.join(str(part) for part in missing) if isinstance(missing,list) else str(missing))
            for c in item['clips']:
                source=next(s for s in manifest['sources'] if s['id']==c['source_id'])
                md=source.get('metadata',{}); clock=''
                if md.get('time_verified') and md.get('playback_rate_verified') and md.get('captured_at_utc'):
                    origin=dt.datetime.fromisoformat(md['captured_at_utc']); zone=ZoneInfo(index['timezone'])
                    start=(origin+dt.timedelta(seconds=c['start'])).astimezone(zone); end=(origin+dt.timedelta(seconds=c['end'])).astimezone(zone)
                    clock=f'；已核实拍摄时刻 {start:%Y-%m-%d %H:%M:%S}–{end:%H:%M:%S}'
                yield f'  - `{source["relative_path"]}` 原片 {timecode(c["start"])}–{timecode(c["end"])}{clock}；精度：{precision_labels[c["precision"]]}；证据 {len(set(c["evidence_ids"]))} 项'
                shown_parts=set()
                for part in geo.get('clip_associations',[]):
                    identity=(part['source_id'],part['start'],part['end'],part.get('region'),part.get('place_name'))
                    if part['source_id']==c['source_id'] and abs(part['start']-c['start'])<=0.001 and abs(part['end']-c['end'])<=0.001 and identity not in shown_parts:
                        shown_parts.add(identity)
                        place=' / '.join(p for p in (part.get('region'),part.get('place_name')) if p) or '未确定'
                        yield f'    - 本片段地点：{place}；{part.get("reason","")}'
                        spans=part.get('gps_applicable_spans',[])
                        if spans: yield '    - 本片段GPS仅适用：'+'、'.join(timecode(p['start'])+'–'+timecode(p['end']) for p in spans)+'；其余缺口不外推。'
    lines+=['','## 事件','']+(list(findings(events,'event')) or ['尚无通过校验的事件。'])
    lines+=['','## 兴趣点']+(list(findings(poi,'interest_point')) or ['尚无通过校验的兴趣点。'])
    lines+=['','## 缺失与限制']+[f'- {s}' for s in index['limitations']]
    lines+=[f'- 未完成图片包：{len(cov["pending_packages"])}；未完成音频来源：{len(cov["pending_audio_sources"])}；失败来源：{len(cov["failed_sources"])}。']
    for fail in cov['failed_sources']:
        reason='缺少视频索引信息（moov），无法读取；详细错误保留在事件JSON。' if 'moov atom not found' in fail['reason'] else fail['reason']
        lines.append(f'- `{fail["source"]}`：{reason}')
    for block in cov['missing_extraction_intervals']: lines.append(f'- 待提取：`{block["source"]}` {block["start"]:.3f}–{block["end"]:.3f} 秒（{block["extracted"]}/{block["planned"]}帧）。')
    for adjustment in manifest.get('plan_adjustments',[]):
        source=next(s for s in manifest['sources'] if s['id']==adjustment['source_id'])
        lines.append(f'- 采样目标去重：`{source["relative_path"]}`；{adjustment["reason"]}。首尾仍有实际帧。')
    if manifest.get('root_review_decisions'):
        lines+=['','## 定向质量复核']+[f'- {decision["decision_note"]}' for decision in manifest['root_review_decisions']]
    if manifest.get('final_review_context',{}).get('public_notes'):
        lines+=['','## 路线、停留与覆盖说明']+['- '+note for note in manifest['final_review_context']['public_notes']]
    lines+=['','## 校验信息','',f'运行 ID：`{manifest["run_id"]}`；修订：{common["revision"]}',f'事件 JSON SHA256：`{file_hash(output/NAMES[1])}`',f'音频 JSON SHA256：`{index["transcript_sha256"]}`']
    (output/NAMES[2]).write_text('\n'.join(lines)+'\n',encoding='utf-8')
    validate_group(output)
    return {'status':status,'coverage':cov,'hashes':{n:file_hash(output/n) for n in NAMES}}

def validate_group(directory):
    return publication_snapshot(directory)['index']

def approve_final(manifest,output_dir,reviewer,reason,review_result=None):
    """Bind a human-authorized ROOT quality review to the exact three file hashes."""
    if reviewer!='ROOT' or not reason.strip(): raise ValueError('Final approval requires ROOT and a review reason')
    index=validate_group(output_dir); cov=coverage(manifest)
    daily=index.get('analysis_daily') or {**{k:index[k] for k in ('summary_evidence_ids','events','interest_points')},'summary':index.get('analysis_summary',index['daily_summary'])}
    geography=analysis.require_geography(manifest,daily)
    if index.get('itinerary_sha256')!=manifest['itinerary']['sha256'] or index.get('geography_sha256')!=geography['sha256']: raise ValueError('Rendered context is stale')
    meta=manifest.get('final_review_package',{})
    if not meta or not review_result: raise ValueError('ROOT must complete the substantive final-review package before approval')
    package=read(meta['path'])
    if package['input_digests']!=analysis.final_review_bindings(manifest,daily): raise ValueError('Final review evidence changed')
    assessed=analysis.validate_final_review(review_result,package)
    expected='terminal_with_gaps' if cov['failed_sources'] else 'complete'
    if not cov['readable_complete'] or manifest.get('status')!=expected or index.get('status')!=expected or index.get('coverage')!=cov:
        raise ValueError('Final approval requires matching complete coverage and final statuses')
    record={'approved':True,'reviewer':reviewer,'reason':reason,'hashes':{n:file_hash(Path(output_dir)/n) for n in NAMES},'at':dt.datetime.now(dt.timezone.utc).isoformat()}
    manifest['root_final_review']=record
    record['substantive_review']=assessed; record['review_package_id']=package['package_id']; record['input_digests']=package['input_digests']
    manifest['published_verified']=False
    return record

def publish(manifest,output_dir,target):
    output=Path(output_dir); target=Path(target); index=validate_group(output); cov=coverage(manifest)
    daily=index.get('analysis_daily') or {**{k:index[k] for k in ('summary_evidence_ids','events','interest_points')},'summary':index.get('analysis_summary',index['daily_summary'])}
    geography=analysis.require_geography(manifest,daily)
    if index.get('itinerary_sha256')!=manifest['itinerary']['sha256'] or index.get('geography_sha256')!=geography['sha256']: raise ValueError('Rendered context is stale')
    expected='terminal_with_gaps' if cov['failed_sources'] else 'complete'
    if not cov['readable_complete'] or manifest.get('status')!=expected or index.get('status')!=expected or index.get('coverage')!=cov:
        raise ValueError('Publication requires matching complete coverage and final statuses')
    review=manifest.get('root_final_review',{})
    if not review.get('approved') or review.get('reviewer')!='ROOT' or not review.get('reason','').strip() or review.get('hashes')!={n:file_hash(output/n) for n in NAMES}:
        raise ValueError('Publication requires ROOT quality approval of these exact final files')
    meta=manifest.get('final_review_package',{}); package=read(meta['path']) if meta else {}
    if review.get('input_digests')!=analysis.final_review_bindings(manifest,daily): raise ValueError('Substantive review inputs changed after approval')
    analysis.validate_final_review(review.get('substantive_review',{}),package)
    if target.resolve()!=Path(manifest['config']['source_root']).resolve(): raise ValueError('publish only to original source directory')
    for source in manifest['sources']:
        if not unchanged(source): raise RuntimeError('Source changed: '+source['path'])
    for name in NAMES:
        dest=target/name
        if dest.exists():
            if name.endswith('.json'):
                if read(dest).get('generator')!=TOOL: raise ValueError('Unknown existing output conflict: '+name)
            elif f'generator:{TOOL};' not in dest.read_text(encoding='utf-8'): raise ValueError('Unknown existing output conflict: '+name)
    for name in NAMES: # Markdown is the commit marker and is replaced last.
        dest=target/name; temporary=target/('.'+name+'.'+manifest['run_id']+'.tmp')
        shutil.copyfile(output/name,temporary)
        if file_hash(temporary)!=file_hash(output/name): raise IOError('NAS temporary hash mismatch')
        os.replace(temporary,dest)
        if file_hash(dest)!=file_hash(output/name): raise IOError('NAS readback hash mismatch')
    validate_group(target)
    manifest['published_verified']=True
    manifest['publication']={'target':str(target),'hashes':{n:file_hash(target/n) for n in NAMES},'at':dt.datetime.now(dt.timezone.utc).isoformat()}
    return manifest['publication']
