"""Validated shot evidence engine; no hidden model calls or original-media writes."""
from __future__ import annotations
import argparse, hashlib, json, time, math
from pathlib import Path
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field
from . import media
from .analysis import Evidence, Observation
from .store import digest, read, file_hash

VERSION='6'
TOPICS=('composition','subject_action','lighting','occlusion','edit_cue')
INSTRUCTIONS=('独立镜头复看：按实际time顺序打开全部frames（含首尾），observed_frame_ids完整同序对账。只分析本source与显示范围，这是采样图片，不是完整视频观看；时间用源文件播放秒，未知倍率不换算现实速度。'
'observations是可核查的画面事实，不是内部思维过程：首帧写基线；其后每个相邻帧对各写一条，description记录当前帧可见内容、比较状态（可见变化/未见明确变化/不可比）及相对差异。每条同时引用前后帧ID，start/end为这两帧实际time；首帧只引自身ID，时间为同一点。不要用整段概述替代逐对事实，覆盖全部core_frame_ids。'
'逐对追踪同一对象、区域或固定参照的位置、姿态、形状、明暗、遮挡；追踪失败写不可比，不强行对应。不同可追踪区域能互证时记录显示的同步或不同步变化，不把取景、对象或preview更换当作同一区域亮暗变化。可见变化与原因分开：显示变亮/变暗可以确认而原因仍未知，不能因未知原因抹掉显示变化。'
'再根据已记录相邻差异的出现、持续、转折、恢复合并changes，有证据才划阶段，不凑类别或变化。相机方向须由多处固定参照相对画框的位置变化支持，另列camera_motion_inference；不能只凭主体位移推相机运动，平移/转动无法区分就写未知。'
'逐项填composition/subject_action/lighting/occlusion/edit_cue的assessed/uncertain/not_assessed；允许未见明确变化或无法判断，未观察不等于无运动。'
'candidate_ranges按有证据的阶段与用途选回看段，在reason说明条件性保留或重点检查理由；未连续观看不能成为省略已显示阶段的理由。同质整段可整段、无依据可无候选，不强拆多个区间。候选不是已批准可用段或精确剪点，needs_playback必须true。'
'每条变化/推断/候选引用2+本source不同实际帧，证据按时序；clip用sampled_frames，start/end等于该条evidence_ids首尾实际time，不能借observed全表补未引用端点。逐条写confidence及具体limits，summary保留采样限制。'
'不从未显示帧断言连续平滑、无抖动、无切镜、曝光原因、精确动作峰值或剪点，不给默认审美可用性；同轮不另派medium重复看图。'
'按result_schema写完整JSON到result_path，不把模板当分析；不读其他模型结果、旧索引、其他source/目录，不递归、不调用ASR、不改图片/task/业务状态。正常只回review_id和结果路径，无法读全帧立即报阻塞，不伪称看完；不输出内部推理过程。')

class Strict(BaseModel):
    model_config=ConfigDict(extra='forbid',allow_inf_nan=False)
class Clip(Evidence):
    precision:Literal['sampled_frames']
    evidence_ids:list[str]=Field(min_length=2)
class Change(Strict):
    topic:Literal['composition','subject_action','lighting','occlusion','edit_cue']
    claim_type:Literal['visible_change','camera_motion_inference']
    description:str=Field(min_length=1)
    clip:Clip
    confidence:Literal['high','medium','low']
    limits:list[str]=Field(min_length=1)
    needs_playback:Literal[True]
class Candidate(Strict):
    clip:Clip
    reason:str=Field(min_length=1)
    confidence:Literal['high','medium','low']
    limits:list[str]=Field(min_length=1)
    needs_playback:Literal[True]
class Result(Strict):
    review_id:str
    input_digest:str
    observed_frame_ids:list[str]=Field(min_length=2)
    topic_status:dict[str,Literal['assessed','uncertain','not_assessed']]
    observations:list[Observation]=[]
    changes:list[Change]
    candidate_ranges:list[Candidate]
    summary:str=Field(min_length=1)

def write_new(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    data=(json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode('utf-8')
    with path.open('xb') as f:f.write(data)

def source_identity(source):
    return {k:source.get(k) for k in ('id','relative_path','size','mtime_ns','sidecars','duration','fps','start_pts','color')}

def verify_input(payload):
    identity=payload['input']
    if digest(identity)!=payload['input_digest']:raise ValueError('Input digest changed')
    frames=identity['frames']; times=[f['time'] for f in frames]
    if len(frames)<2 or times!=sorted(set(times)):raise ValueError('Frame times must be strictly increasing')
    if len({f['id'] for f in frames})!=len(frames):raise ValueError('Duplicate frame ID')
    sid=identity['source']['id'];interval=identity['interval']
    for frame in frames:
        if frame['source_id']!=sid:raise ValueError('Frame/source mismatch')
        if not interval['start']<=frame['time']<interval['end']:raise ValueError('Frame outside requested source interval')
        if file_hash(frame['path'])!=frame['sha256']:raise ValueError('Image bytes changed: '+frame['id'])
    return identity

def prepare(manifest,source_id,start,end,count,output,ffmpeg,efforts=('max',)):
    began=time.monotonic();original_bytes=Path(manifest).read_bytes();m=json.loads(original_bytes)
    s=next(s for s in m['sources'] if s['id']==source_id)
    if s['status']!='ready' or not 0<=start<end<=s['duration']:raise ValueError('Explicit interval outside readable source')
    if not 2<=count<=120:raise ValueError('Frame count must be 2..120')
    if end-start<2/s['fps'] or count>(end-start)*s['fps']:raise ValueError('Not enough distinct source frames')
    if not media.unchanged(s):raise ValueError('Source/sidecar identity changed since completed index')
    out=Path(output).resolve()
    if str(out).startswith('\\\\') or any(p.lower()=='onedrive' for p in out.parts):raise ValueError('Active shot cache must be local and nonsync')
    if out.is_relative_to(Path(s['path']).resolve().parent):raise ValueError('Output cannot be inside original-media directory')
    if out.exists():raise ValueError('Output exists; use frozen existing task or choose a new review output')
    out.mkdir(parents=True)
    # New review never changes the existing coarse frame cache or block identities.
    preview=media.preview_spec(s,m['config'].get('preview_luts'))
    last=end-1/s['fps'];times=[round(start+(last-start)*n/(count-1),6) for n in range(count)]
    block={'index':0,'start':start,'end':end,'samples':times}
    frames=media.extract_block(ffmpeg,s,block,out/'frames',{'backend':'cpu','adapter':None},preview=preview,diagnostics=out/'extract.log')
    for n,f in enumerate(frames):
        f['id']='shot-'+digest({'source':s['id'],'interval':[start,end],'index':n,'time':f['time'],'preview':preview})[:20]
        f['sha256']=file_hash(f['path']);f['boundary']='start' if n==0 else 'end' if n==len(frames)-1 else None
    source={**source_identity(s),'path':s['path'],'clock':{k:s.get('metadata',{}).get(k) for k in ('time_verified','playback_rate_verified','captured_at_utc','capture_fps','format_fps')}}
    identity={'schema':'shot_review_input_v1','prompt_version':VERSION,'source':source,'interval':{'start':start,'end':end,'time_basis':'source_file_playback_seconds'},'frames':frames,'preview':preview,'sampling':{'requested_frames':count,'actual_frames':len(frames),'max_gap_seconds':max(b['time']-a['time'] for a,b in zip(frames,frames[1:])),'first_time':frames[0]['time'],'last_time':frames[-1]['time'],'coverage':'sampled_sequence_not_continuous_video'},'instructions':INSTRUCTIONS,'result_schema':Result.model_json_schema()}
    from . import pixel_cues
    identity['program_pixel_cues']=pixel_cues.build(identity)
    input_digest=digest(identity);review_id='shot-'+input_digest[:24]
    tasks=[]
    for effort in efforts:
        if effort not in ('high','max'):raise ValueError('This explicitly authorized pilot uses high/max only')
        run=out/effort;run.mkdir()
        task={'schema':'shot_review_task_v1','review_id':review_id,'input_digest':input_digest,'input':identity,'result_path':str(run/'result.json'),'request_route':{'stage':'shot_review','model':'gpt-6-luna','reasoning_effort':effort,'authority':'authorized_shot_review','runtime_model_verified':False}}
        verify_input(task);write_new(run/'task.json',task)
        write_new(run/'result.template.json',{'review_id':review_id,'input_digest':input_digest,'observed_frame_ids':[],'topic_status':{k:'not_assessed' for k in TOPICS},'changes':[],'candidate_ranges':[],'summary':''})
        tasks.append(str(run/'task.json'))
    if Path(manifest).read_bytes()!=original_bytes or not media.unchanged(s):raise ValueError('Original changed during preparation; do not dispatch')
    record={'review_id':review_id,'source_id':source_id,'source_path':s['path'],'interval':[start,end],'frames':len(frames),'input_digest':input_digest,'task_paths':tasks,'preparation_seconds':time.monotonic()-began,'ffmpeg_sha256':file_hash(ffmpeg),'manifest_sha256':hashlib.sha256(original_bytes).hexdigest(),'token_cost':None,'model_reasoning_seconds':None,'model_calls':0}
    write_new(out/'preparation.json',record)
    return record

def validate_value(task,value):
    identity=verify_input(task);v=Result.model_validate(value).model_dump()
    if v['review_id']!=task['review_id'] or v['input_digest']!=task['input_digest']:raise ValueError('Result belongs to a different frozen review input')
    frames={f['id']:f for f in identity['frames']}
    observed=v['observed_frame_ids']
    if observed!=[f['id'] for f in identity['frames']]:raise ValueError('Every supplied image must be observed exactly once in actual time order')
    if set(v['topic_status'])!=set(TOPICS):raise ValueError('Every topic needs explicit assessment status')
    def clipcheck(clip):
        if clip['source_id']!=identity['source']['id']:raise ValueError('Cross-source clip')
        if not identity['frames'][0]['time']<=clip['start']<=clip['end']<=identity['frames'][-1]['time']:raise ValueError('Clip outside displayed source interval')
        ids=clip['evidence_ids']
        if len(ids)!=len(set(ids)) or any(e not in frames for e in ids):raise ValueError('Unknown or duplicate frame evidence')
        times=[frames[e]['time'] for e in ids]
        if times!=sorted(times):raise ValueError('Evidence must follow actual time order')
        if abs(clip['start']-min(times))>0.000001 or abs(clip['end']-max(times))>0.000001:
            raise ValueError('Clip must exactly envelope its own cited frame times')
        if any(t<clip['start']-0.000001 or t>clip['end']+0.000001 for t in times):raise ValueError('Evidence outside claimed clip')
    observed_facts=set()
    for observation in v['observations']:
        if observation['source_id']!=identity['source']['id']:raise ValueError('Cross-source observation')
        ids=observation['evidence_ids']
        if not observation['description'].strip() or any(not math.isfinite(observation[k]) for k in ('start','end')):raise ValueError('Factual observations need finite times and nonblank descriptions')
        if len(ids)!=len(set(ids)) or any(fid not in frames for fid in ids):raise ValueError('Unknown or duplicate factual observation evidence')
        times=[frames[fid]['time'] for fid in ids]
        if times!=sorted(times) or abs(observation['start']-min(times))>1e-6 or abs(observation['end']-max(times))>1e-6:raise ValueError('Observation must exactly envelope its own cited actual frame times; a single frame is a point')
        observed_facts.update(ids)
    if identity.get('requires_facts') and not set(identity['core_frame_ids'])<=observed_facts:raise ValueError('All core frames need visible facts in the same max pass')
    for change in v['changes']:
        clipcheck(change['clip'])
        if v['topic_status'][change['topic']]=='not_assessed':raise ValueError('Unassessed topic cannot contain a claim')
        if any(not s.strip() for s in change['limits']):raise ValueError('Concrete limits cannot be empty')
    for candidate in v['candidate_ranges']:
        clipcheck(candidate['clip'])
        if any(not s.strip() for s in candidate['limits']):raise ValueError('Concrete limits cannot be empty')
    return v

def validated_record(task_path,result_path=None):
    task_path=Path(task_path).resolve();task_bytes=task_path.read_bytes();task=json.loads(task_bytes)
    result=Path(result_path or task['result_path']).resolve();result_bytes=result.read_bytes()
    v=validate_value(task,json.loads(result_bytes))
    return {'schema':'shot_review_record_v1','validator_version':2,'review_id':task['review_id'],'input_digest':task['input_digest'],
        'task_path':str(task_path),'result_path':str(result),'task_sha256':hashlib.sha256(task_bytes).hexdigest(),
        'result_sha256':hashlib.sha256(result_bytes).hexdigest(),'source':task['input']['source'],'interval':task['input']['interval'],
        'sampling':task['input']['sampling'],'preview':task['input']['preview'],'frames':task['input']['frames'],
        'requested_route':task['request_route'],'runtime_model_verified':False,'result':v,
        'validation':'mechanical_provenance_only_requires_semantic_review'}

def validate(task_path,result_path=None):
    record=validated_record(task_path,result_path);accepted=Path(record['result_path']).parent/'accepted.json'
    if accepted.exists():
        if read(accepted)!=record:raise ValueError('An accepted record exists; retain it and create a new isolated review for changes')
    else:write_new(accepted,record)
    return {'accepted_path':str(accepted),'review_id':record['review_id'],'result_sha256':record['result_sha256']}


def timecode(t):
    ms=round(t*1000);h,ms=divmod(ms,3600000);m,ms=divmod(ms,60000);s,ms=divmod(ms,1000)
    return f'{h:02}:{m:02}:{s:02}.{ms:03}'

def report(record_path,output):
    record=read(record_path)
    if record.get('schema')!='shot_review_record_v1' or not record.get('task_path') or not record.get('result_path'):
        raise ValueError('Report requires a bound validated record; revalidate older records into an isolated directory')
    expected=validated_record(record['task_path'],record['result_path'])
    if record!=expected:raise ValueError('Accepted record differs from current validated task/result')
    v=record['result'];s=record['source'];sampling=record['sampling']
    source_link=Path(s['path']).as_posix()
    lines=[f'# 镜头复看 {record["review_id"]}','状态：结构校验通过；仍需原片回看。此报告本身不代表语义批准。',f'原片：[打开](<{source_link}>)',f'源文件：`{s["relative_path"]}`；源秒范围 {timecode(record["interval"]["start"])}–{timecode(record["interval"]["end"])}',f'实际采样 {sampling["actual_frames"]} 张，最大间隔 {sampling["max_gap_seconds"]:.3f} 秒；不是完整视频观看。',v['summary'],'','## 画面变化与推断']
    for c in v['changes']:
        clip=c['clip'];lines.append(f'- [{c["topic"]}/{c["claim_type"]}] {timecode(clip["start"])}–{timecode(clip["end"])}：{c["description"]}（{c["confidence"]}；须回看）。限制：'+ '；'.join(c['limits'])+'；证据：'+', '.join(clip['evidence_ids']))
    lines+=['','## 待回看候选区间']
    for c in v['candidate_ranges']:
        clip=c['clip'];lines.append(f'- {timecode(clip["start"])}–{timecode(clip["end"])}：{c["reason"]}；不是精确剪点。限制：'+'；'.join(c['limits'])+'；证据：'+', '.join(clip['evidence_ids']))
    lines+=['','评估状态：'+json.dumps(v['topic_status'],ensure_ascii=False),'请求档位：'+record['requested_route']['reasoning_effort']+'；此记录不证明实际运行模型。','时间基准始终为源文件播放秒；未知慢放倍率不换算真实动作速度。','原片链接与身份来自准备时快照；报告阶段不探测NAS或声称当前链接文件已核验。']
    p=Path(output);content='\n\n'.join(lines)+'\n'
    if p.exists() and p.read_text(encoding='utf-8')!=content:raise ValueError('Report exists with different content')
    p.parent.mkdir(parents=True,exist_ok=True);p.write_text(content,encoding='utf-8')
    return {'report':str(p),'review_id':record['review_id']}
