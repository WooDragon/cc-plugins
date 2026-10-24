"""Read-only probing; actual-PTS uniform sampling; explicitly identified Intel devices."""
from __future__ import annotations
import ctypes, datetime as dt, json, math, os, re, subprocess, time, wave, xml.etree.ElementTree as ET
from pathlib import Path
from .store import digest, file_hash

class SamplingPlanError(RuntimeError): pass

def command(args, timeout=900):
    p=subprocess.run([str(a) for a in args],capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=timeout)
    if p.returncode: raise RuntimeError(p.stderr[-12000:] or p.stdout[-12000:])
    return p

def sample_times(duration, fps=25, interval=10):
    if duration<=0: return []
    tail=max(0,duration-1/max(fps,1))
    if duration<interval: return sorted(set(round(t,6) for t in (0,tail/2,tail)))
    regular=[round(n*interval,6) for n in range(math.floor(tail/interval)+1)]
    if len(regular)>1 and 0<tail-regular[-1]<1/max(fps,1)-0.00001: regular.pop()
    return sorted(set(regular+[round(tail,6)]))

def blocks_for(times, duration, seconds=300):
    blocks=[]
    for n in range(max(1,math.ceil(duration/seconds))):
        start=n*seconds; end=min(duration,(n+1)*seconds)
        points=[t for t in times if start<=t<end]
        if points: blocks.append({'index':n,'start':start,'end':end,'samples':points})
    return blocks

def parse_rate(raw):
    try:
        a,b=raw.split('/'); return float(a)/float(b) if float(b) else 0
    except (AttributeError,ValueError): return 0

def preview_spec(source,mapping=None):
    """Only trusted DIT device/token pairs select an explicit local technical LUT."""
    tokens=re.split(r'[_\s.\-]+',Path(source.get('relative_path',source.get('path',''))).stem.upper())
    device=next((name for name in ('ZVE1','OA5P','A3S') if name in tokens),'UNKNOWN')
    token='NO' if 'NO' in tokens else next((name for name in ('SLOG3CINE','DLOGM') if name in tokens),None)
    spec={'device':device,'log_token':token,'applied':False,'normalized':token=='NO','status':'ordinary_no_lut' if token=='NO' else 'unspecified' if token is None else 'missing_lut','filter':None,'lut_sha256':None,'warning':None}
    if token in (None,'NO'): return spec
    chosen=(mapping or {}).get(device+':'+token)
    if not chosen:
        spec['warning']='No explicit matching device/Log LUT; preview remains unnormalized'; return spec
    path=Path(chosen)
    if path.suffix.lower()!='.cube' or not path.is_file():
        spec['warning']='Configured matching .cube is unavailable; preview remains unnormalized'; return spec
    escaped=str(path.resolve()).replace('\\','/').replace(':','\\:').replace("'","'\\''")
    spec.update(applied=True,normalized=True,status='technical_rec709_preview',lut_path=str(path.resolve()),lut_sha256=file_hash(path),filter="format=gbrpf32le,lut3d=file='"+escaped+"':interp=tetrahedral",parameters={'interpolation':'tetrahedral','target':'Rec709','intent':'technical_preview_no_creative_grade'})
    return spec

def extraction_key(source,block,preview=None,pipeline=None):
    settings={'interval':10,'max_edge':960,'version':2}
    if pipeline is not None:
        if pipeline!='select_first_v3': raise ValueError('Unknown extraction pipeline')
        settings.update(version=3,pipeline=pipeline)
    if preview and preview.get('applied'):
        settings['preview']={k:preview[k] for k in ('device','log_token','lut_sha256','parameters')}
    return digest({'source':source['id'],'block':block,'extract':settings})

def sidecars(path):
    return sorted(p for p in path.parent.iterdir() if p.is_file() and p.stem.lower()==path.stem.lower() and p.suffix.lower() in ('.xml','.srt'))

def metadata(path):
    result={'captured_at_utc':None,'time_verified':False,'playback_rate_verified':False,'location_points':[],'warnings':[]}
    for side in sidecars(path):
        if side.suffix.lower()=='.xml':
            try:
                tree=ET.parse(side)
                for el in tree.iter():
                    name=el.tag.split('}')[-1]
                    if name=='CreationDate':
                        raw=el.attrib.get('value') or el.text
                        value=dt.datetime.fromisoformat(raw.replace('Z','+00:00'))
                        result['raw_creation_date']=raw
                        if value.tzinfo:
                            result.update(captured_at_utc=value.astimezone(dt.timezone.utc).isoformat(),time_verified=True,time_source='Sony XML CreationDate')
                    if name=='Device': result['device_model']=el.attrib.get('modelName')
                    if name=='VideoFrame': result['capture_fps']=el.attrib.get('captureFps'); result['format_fps']=el.attrib.get('formatFps')
                # Only explicitly equal capture/playback rates establish normal-time mapping.
                if result.get('capture_fps') and result.get('format_fps'):
                    result['playback_rate_verified']=result['capture_fps']==result['format_fps']
            except Exception as e: result['warnings'].append('XML: '+str(e))
        else:
            import pysubs2
            try:
                for sub in pysubs2.load(str(side),encoding='utf-8'):
                    txt=sub.plaintext
                    lat=re.search(r'latitude\s*:\s*([\d.+-]+)',txt,re.I); lon=re.search(r'longitude\s*:\s*([\d.+-]+)',txt,re.I)
                    if lat and lon and (float(lat[1])!=0 or float(lon[1])!=0): result['location_points'].append({'time':sub.start/1000,'start_seconds':sub.start/1000,'end_seconds':sub.end/1000,'latitude':float(lat[1]),'longitude':float(lon[1]),'source':'DJI SRT','trusted':True,'crs':'EPSG:4326','source_file':str(side)})
                    date=re.search(r'(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:\.\d+)?)',txt)
                    if date and 'srt_local_time' not in result: result['srt_local_time']=date[1]
            except Exception as e: result['warnings'].append('SRT: '+str(e))
    return result

def probe(path, ffprobe, source_root):
    path=Path(path); st=path.stat(); side=sidecars(path)
    identity={'relative_path':str(path.relative_to(source_root)),'size':st.st_size,'mtime_ns':st.st_mtime_ns,'sidecars':[{ 'path':str(p),'sha256':file_hash(p),'size':p.stat().st_size,'mtime_ns':p.stat().st_mtime_ns} for p in side]}
    base={**identity,'id':digest(identity)[:20],'path':str(path),'status':'failed'}
    try:
        raw=json.loads(command([ffprobe,'-v','error','-show_streams','-show_format','-of','json',path],120).stdout)
        video=next(s for s in raw['streams'] if s['codec_type']=='video'); audio=[s for s in raw['streams'] if s['codec_type']=='audio']
        duration=float(video.get('duration') or raw['format']['duration']); fps=parse_rate(video.get('avg_frame_rate')) or parse_rate(video.get('r_frame_rate')) or 25
        md=metadata(path)
        upper=path.name.upper(); model=(md.get('device_model') or '').upper()
        role='drone' if 'A3S' in upper or 'AIR 3' in model else 'camera' if any(s in upper for s in ('OA5P','ZVE1','ZV-E1')) or any(s in model for s in ('ZV-E1','OSMO ACTION')) else 'unknown'
        times=sample_times(duration,fps)
        base.update(status='ready',duration=duration,fps=fps,start_pts=float(video.get('start_time') or 0),codec=video.get('codec_name'),pixel_format=video.get('pix_fmt'),width=video.get('width'),height=video.get('height'),color={k:video.get(k) for k in ('color_space','color_transfer','color_primaries')},audio=bool(audio),role=role,metadata=md,probe=raw,sample_times=times,blocks=blocks_for(times,duration))
    except Exception as e: base['error']=str(e)
    return base

def enumerate_adapters():
    """DXGI order is the exact numeric device order consumed by D3D11VA."""
    from ctypes import wintypes as w
    class GUID(ctypes.Structure): _fields_=[('a',w.DWORD),('b',w.WORD),('c',w.WORD),('d',ctypes.c_ubyte*8)]
    class DESC(ctypes.Structure): _fields_=[('Description',w.WCHAR*128),('VendorId',w.UINT),('DeviceId',w.UINT),('SubSysId',w.UINT),('Revision',w.UINT),('DedicatedVideoMemory',ctypes.c_size_t),('DedicatedSystemMemory',ctypes.c_size_t),('SharedSystemMemory',ctypes.c_size_t),('LuidLow',w.DWORD),('LuidHigh',w.LONG),('Flags',w.UINT)]
    guid=GUID(0x770aae78,0xf26f,0x4dba,(ctypes.c_ubyte*8)(0xa8,0x29,0x25,0x3c,0x83,0xd1,0xb3,0x87))
    factory=ctypes.c_void_p(); hr=ctypes.windll.dxgi.CreateDXGIFactory1(ctypes.byref(guid),ctypes.byref(factory))
    if hr: raise OSError(hr)
    def method(obj,n,restype,*args): return ctypes.WINFUNCTYPE(restype,ctypes.c_void_p,*args)(ctypes.cast(obj,ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents[n])
    adapters=[]
    try:
        for i in range(16):
            adapter=ctypes.c_void_p()
            if method(factory,12,ctypes.c_long,w.UINT,ctypes.POINTER(ctypes.c_void_p))(factory,i,ctypes.byref(adapter)): break
            try:
                desc=DESC(); hr=method(adapter,10,ctypes.c_long,ctypes.POINTER(DESC))(adapter,ctypes.byref(desc))
                if not hr: adapters.append({'index':i,'name':desc.Description,'vendor_id':desc.VendorId,'device_id':desc.DeviceId,'dedicated_bytes':desc.DedicatedVideoMemory,'luid':f'0x{desc.LuidHigh & 0xffffffff:08x}_0x{desc.LuidLow:08x}'})
            finally: method(adapter,2,w.ULONG)(adapter)
    finally: method(factory,2,w.ULONG)(factory)
    return adapters

def hardware_candidates(adapters):
    intel=[a for a in adapters if a['vendor_id']==0x8086]
    intel.sort(key=lambda a:(0 if 'A380' in a['name'] else 1,a['index']))
    return [{'backend':backend,'adapter':a} for a in intel for backend in ('qsv','d3d11va')]+[{'backend':'cpu','adapter':None}]

def hardware_args(candidate):
    backend=candidate['backend']; adapter=candidate.get('adapter')
    if backend=='cpu': return [],''
    prefix=['-init_hw_device',f'd3d11va=dx:{adapter["index"]}']
    if backend=='qsv': prefix+=['-init_hw_device','qsv=qs@dx','-hwaccel','qsv','-hwaccel_device','qs','-hwaccel_output_format','qsv']
    else: prefix+=['-hwaccel','d3d11va','-hwaccel_device','dx','-hwaccel_output_format','d3d11']
    return prefix,'hwdownload,format=p010le,'

def check_slot_devices(slots):
    if not any(slot['backend']!='cpu' for slot in slots): return
    current=enumerate_adapters()
    for slot in slots:
        if slot['backend']=='cpu': continue
        expected=slot['adapter']
        if not any(all(adapter.get(k)==expected.get(k) for k in ('index','vendor_id','device_id')) for adapter in current):
            raise ValueError('Physical GPU identity changed; run the hardware benchmark before resuming multiple media slots')

def machine_profile_path():
    return Path(os.environ.get('LOCALAPPDATA',Path.home()/'.local/share'))/'VlogIndex'/'hardware-profile.json'

def verify_image(path):
    from PIL import Image
    with Image.open(path) as im: im.verify()

def select_hardware(ffmpeg, source, directory):
    directory=Path(directory); directory.mkdir(parents=True,exist_ok=True)
    attempts=[]
    try: adapters=enumerate_adapters()
    except Exception as e: adapters=[]; attempts.append({'backend':'enumeration','ok':False,'error':str(e)})
    for candidate in hardware_candidates(adapters):
        args,download=hardware_args(candidate); output=directory/(candidate['backend']+'-'+str(candidate.get('adapter'))[-12:].replace(':','')+'.jpg')
        output=directory/('test-'+str(len(attempts))+'.jpg')
        start=time.monotonic()
        try:
            log=command([ffmpeg,'-hide_banner','-loglevel','verbose',*args,'-i',source,'-frames:v','1','-vf',download+"scale=w='min(960,iw)':h='min(960,ih)':force_original_aspect_ratio=decrease",'-y',output],120).stderr
            verify_image(output)
            attempts.append({**candidate,'ok':True,'seconds':time.monotonic()-start,'log':log[-10000:]})
            return {'selected':candidate,'adapters':adapters,'attempts':attempts,'ffmpeg_version':command([ffmpeg,'-version']).stdout.splitlines()[0]}
        except Exception as e: attempts.append({**candidate,'ok':False,'seconds':time.monotonic()-start,'error':str(e)})
    raise RuntimeError(json.dumps(attempts,ensure_ascii=False))

def extract_block(ffmpeg, source, block, output_dir, candidate, audio_output=None,preview=None,diagnostics=None,select_before_download=False):
    output_dir=Path(output_dir); output_dir.mkdir(parents=True,exist_ok=True)
    offset=source['start_pts']; points=block['samples']; args,download=hardware_args(candidate)
    # Planned decimal rounding must not move an exact final-frame threshold past EOF.
    expressions=['eq(n,0)' if t==block['start'] else f'gte(t,{t+offset-0.00001:.9f})*lt(prev_pts*TB,{t+offset-0.00001:.9f})' for t in points]
    transform=(preview['filter']+',' if preview and preview.get('applied') else '')
    selection="select='"+'+'.join(expressions)+"',"
    vf=(selection+download if select_before_download else download+selection)+"showinfo,setpts=PTS-STARTPTS,"+transform+"scale=w='min(960,iw)':h='min(960,ih)':force_original_aspect_ratio=decrease"
    cmd=[ffmpeg,'-hide_banner','-loglevel','verbose' if diagnostics else 'info',*args,'-ss',block['start'],'-t',block['end']-block['start'],'-copyts','-i',source['path'],'-map','0:v:0','-an','-vf',vf,'-fps_mode','vfr','-q:v','3','-y',output_dir/'%04d.jpg']
    if audio_output:
        Path(audio_output).parent.mkdir(parents=True,exist_ok=True)
        cmd+=['-map','0:a:0','-vn','-af','asetpts=PTS-STARTPTS','-ac','1','-ar','16000','-c:a','pcm_s16le',audio_output]
    if diagnostics: cmd.insert(1,'-benchmark')
    process_start=time.monotonic(); pid=None
    if diagnostics:
        with subprocess.Popen([str(a) for a in cmd],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf-8',errors='replace') as process:
            pid=process.pid
            try: stdout,stderr=process.communicate(timeout=900)
            except subprocess.TimeoutExpired:
                process.kill(); process.communicate(); raise
            result=subprocess.CompletedProcess(cmd,process.returncode,stdout,stderr)
        if result.returncode:
            Path(diagnostics).write_text(result.stderr,encoding='utf-8'); raise RuntimeError(result.stderr[-12000:])
    else: result=command(cmd)
    process_end=time.monotonic()
    if diagnostics: Path(diagnostics).write_text(result.stderr,encoding='utf-8')
    if audio_output and not valid_audio(audio_output,block['end']-block['start']): raise RuntimeError('Incomplete combined WAV output')
    pts=[float(t) for t in re.findall(r'Parsed_showinfo[^\n]*\bn:\s*\d+[^\n]*pts_time:([\d.eE+-]+)',result.stderr)]
    images=sorted(output_dir.glob('*.jpg'))
    if len(images)!=len(pts) or len(pts)!=len(points): raise SamplingPlanError(f'Incomplete extraction: planned={len(points)}, images={len(images)}, pts={len(pts)}\n'+result.stderr[-5000:])
    frames=[]
    for n,(planned,actual,img) in enumerate(zip(points,pts,images)):
        verify_image(img); actual-=offset
        if abs(actual-planned)>max(0.25,2/source['fps']): raise RuntimeError(f'PTS mismatch {planned} -> {actual}')
        frames.append({'id':f'{source["id"]}-b{block["index"]:03}-f{n:03}','source_id':source['id'],'planned_time':planned,'time':actual,'pts':actual+offset,'path':str(img),'precision':'decoded_frame_pts'})
        if preview: frames[-1]['preview']=preview
        if select_before_download: frames[-1]['extraction_pipeline']='select_first_v3'
    if diagnostics:
        from .store import dump
        dump(str(diagnostics)+'.timing.json',{'pid':pid,'ffmpeg_seconds':process_end-process_start,'validation_seconds':time.monotonic()-process_end,'filter':vf,
             'ffmpeg_cpu_benchmark':re.findall(r'bench:.*',result.stderr)})
    return frames

def _benchmark_counters(stop,samples,status):
    """Optional Windows PDH samples; names retain LUID/engine/PID provenance."""
    if os.name!='nt': status['unavailable']='Windows PDH counters are unavailable on this platform'; return
    from ctypes import wintypes as w
    class ValueUnion(ctypes.Union): _fields_=[('doubleValue',ctypes.c_double),('longValue',w.LONG),('largeValue',ctypes.c_longlong)]
    class Value(ctypes.Structure): _fields_=[('CStatus',w.DWORD),('value',ValueUnion)]
    class Item(ctypes.Structure): _fields_=[('name',w.LPWSTR),('value',Value)]
    pdh=ctypes.WinDLL('pdh'); query=w.HANDLE(); counters={}
    pdh.PdhOpenQueryW.argtypes=[w.LPCWSTR,ctypes.c_size_t,ctypes.POINTER(w.HANDLE)]
    pdh.PdhAddEnglishCounterW.argtypes=[w.HANDLE,w.LPCWSTR,ctypes.c_size_t,ctypes.POINTER(w.HANDLE)]
    pdh.PdhCollectQueryData.argtypes=[w.HANDLE]
    pdh.PdhGetFormattedCounterArrayW.argtypes=[w.HANDLE,w.DWORD,ctypes.POINTER(w.DWORD),ctypes.POINTER(w.DWORD),ctypes.c_void_p]
    pdh.PdhCloseQuery.argtypes=[w.HANDLE]
    if pdh.PdhOpenQueryW(None,0,ctypes.byref(query)): status['unavailable']='PdhOpenQuery failed'; return
    try:
        for name,path in {'gpu':r'\GPU Engine(*)\Utilization Percentage','cpu':r'\Processor(_Total)\% Processor Time','disk_read':r'\PhysicalDisk(_Total)\Disk Read Bytes/sec','disk_write':r'\PhysicalDisk(_Total)\Disk Write Bytes/sec','network_receive':r'\Network Interface(*)\Bytes Received/sec'}.items():
            counter=w.HANDLE(); code=pdh.PdhAddEnglishCounterW(query,path,0,ctypes.byref(counter))
            if code: status.setdefault('unavailable_counters',{})[name]=hex(code & 0xffffffff)
            else: counters[name]=counter
        pdh.PdhCollectQueryData(query)
        while not stop.wait(1):
            pdh.PdhCollectQueryData(query); row={'monotonic':time.monotonic()}
            for name,counter in counters.items():
                size=w.DWORD(); count=w.DWORD(); pdh.PdhGetFormattedCounterArrayW(counter,0x200,ctypes.byref(size),ctypes.byref(count),None)
                if not size.value: continue
                buffer=ctypes.create_string_buffer(size.value)
                if pdh.PdhGetFormattedCounterArrayW(counter,0x200,ctypes.byref(size),ctypes.byref(count),buffer): continue
                values=ctypes.cast(buffer,ctypes.POINTER(Item)); data={}
                for index in range(count.value):
                    item=values[index]
                    if item.value.CStatus not in (0,1): continue
                    if name=='gpu' and not any(t in item.name.lower() for t in ('videodecode','copy','compute','videoprocessing')): continue
                    data[item.name]=item.value.value.doubleValue
                row[name]=data
            samples.append(row)
        status['sample_count']=len(samples)
    except Exception as error: status['unavailable']=str(error)
    finally: pdh.PdhCloseQuery(query)

def hardware_benchmark(ffmpeg,ffprobe,output_dir,sources=None,starts=None,seconds=12,tasks=3,compare_filter_order=False,profile_counts=None,select_first_only=False):
    """Bounded independent evidence; no business state, model calls or NAS writes."""
    from concurrent.futures import ThreadPoolExecutor
    from .store import dump
    output=Path(output_dir).resolve(); output.mkdir(parents=True,exist_ok=True)
    if not 1<=seconds<=120 or not 3<=tasks<=9: raise ValueError('Benchmark interval 1..120 seconds; fixed queue 3..9 tasks')
    profile_counts=profile_counts or [1,2,3]
    if len(set(profile_counts))!=len(profile_counts) or any(n not in (1,2,3,4) for n in profile_counts): raise ValueError('Benchmark profiles must be unique slot counts 1..4')
    if select_first_only and compare_filter_order: raise ValueError('Select-first-only cannot also compare the old filter order')
    adapters=enumerate_adapters()
    arc=next((a for a in adapters if a['vendor_id']==0x8086 and 'A380' in a['name']),None)
    igpu=next((a for a in adapters if a['vendor_id']==0x8086 and any(n in a['name'].upper() for n in ('UHD','IRIS'))),None)
    if not arc or not igpu or arc['index']==igpu['index']: raise ValueError('Cannot distinctly identify A380 and integrated Intel device')
    if not sources:
        synthetic=output/'synthetic-10bit.mp4'
        command([ffmpeg,'-hide_banner','-loglevel','error','-f','lavfi','-i','testsrc2=size=3840x2160:rate=12','-t',seconds,'-c:v','libx265','-preset','ultrafast','-pix_fmt','yuv420p10le','-x265-params','log-level=error','-an','-y',synthetic])
        sources=[synthetic]
    starts=starts or [0]*len(sources)
    if len(starts)!=len(sources): raise ValueError('Provide one start per benchmark source')
    samples=[]
    for path,start in zip(sources,starts):
        source=probe(Path(path),ffprobe,Path(path).parent)
        if source['status']!='ready' or start<0 or start>=source['duration']: raise ValueError('Invalid benchmark source/start')
        duration=min(seconds,source['duration']-start)
        block={'index':0,'start':start,'end':start+duration,'samples':[start+t for t in sample_times(duration,source['fps'])]}
        samples.append((source,block))
    slots=[{'backend':'qsv','adapter':arc},{'backend':'qsv','adapter':arc},{'backend':'qsv','adapter':igpu},{'backend':'qsv','adapter':igpu}]
    def run(profile,index,slot_index,select_first=False):
        source,block=samples[index%len(samples)]; directory=output/profile/str(index); directory.mkdir(parents=True,exist_ok=True)
        log=directory/'ffmpeg.log'; started=time.monotonic()
        frames=extract_block(ffmpeg,source,block,directory,slots[slot_index],diagnostics=log,select_before_download=select_first)
        timings=__import__('json').loads(Path(str(log)+'.timing.json').read_text(encoding='utf-8'))
        device=f'{slots[slot_index]["adapter"]["vendor_id"]:04x}:{slots[slot_index]["adapter"]["device_id"]:04x}'
        text=log.read_text(encoding='utf-8')
        if f'Using device {device}' not in text: raise RuntimeError('FFmpeg did not confirm the requested physical device: '+device)
        return {'task':index,'slot':slot_index,'candidate':slots[slot_index],'source':source['path'],'start':block['start'],'end':block['end'],
                'started_monotonic':started,'finished_monotonic':time.monotonic(),'seconds':time.monotonic()-started,'frames':frames,'device_confirmed':device,'log':str(log),'timings':timings}
    profiles=[]
    import threading
    stop=threading.Event(); counters=[]; counter_status={}; sampler=threading.Thread(target=_benchmark_counters,args=(stop,counters,counter_status),daemon=True); sampler.start()
    try:
        for select_first in ([True] if select_first_only else [False,True] if compare_filter_order else [False]):
            names={1:'sequential',2:'a380-dual',3:'a380-dual-igpu',4:'a380-dual-igpu-dual'}
            for count in profile_counts:
                base=names[count]
                name=base+('-select-first' if select_first else ''); begin=time.monotonic(); records=[]
                # A physical slot keeps its identity and immediately claims the next task.
                pending=list(range(tasks)); pending_lock=threading.Lock()
                def slot_worker(slot_index):
                    local=[]
                    while True:
                        with pending_lock:
                            if not pending: return local
                            index=pending.pop(0)
                        record=run(name,index,slot_index,select_first); local.append(record)
                        with pending_lock: dump(output/'active-task.json',{'profile':name,'last_completed_task':index,'remaining':len(pending),'seconds':record['seconds'],'ffmpeg_seconds':record['timings']['ffmpeg_seconds']})
                with ThreadPoolExecutor(max_workers=count) as pool:
                    for result in pool.map(slot_worker,range(count)): records.extend(result)
                records.sort(key=lambda r:r['task']); elapsed=time.monotonic()-begin; image_count=sum(len(r['frames']) for r in records)
                profiles.append({'name':name,'started_monotonic':begin,'finished_monotonic':time.monotonic(),'wall_seconds':elapsed,'processed_video_seconds':sum(r['end']-r['start'] for r in records),'image_count':image_count,'images_per_minute':image_count/elapsed*60,'jobs':records})
                dump(output/'benchmark.progress.json',profiles)
    finally:
        stop.set(); sampler.join(timeout=3)
        pids={r['timings']['pid'] for p in profiles for r in p['jobs']}
        for row in counters:
            row['gpu']={k:v for k,v in row.get('gpu',{}).items() if any(f'pid_{pid}_' in k for pid in pids)}
        dump(output/'performance-counters.json',{'status':counter_status,'samples':counters,'scope':'GPU counter names contain benchmark FFmpeg PID and LUID; CPU, disk and network are whole-host counters, not attributable solely to NAS.'})
    comparisons=[]
    if compare_filter_order or len(profiles)>1:
        from PIL import Image,ImageChops,ImageStat
        originals={p['name']:p for p in profiles if not p['name'].endswith('-select-first')}
        for profile in profiles:
            if compare_filter_order and not profile['name'].endswith('-select-first'): continue
            if not compare_filter_order and profile is profiles[0]: continue
            reference=originals[profile['name'].removesuffix('-select-first')] if compare_filter_order else profiles[0]
            for before,after in zip(reference['jobs'],profile['jobs']):
                if [f['time'] for f in before['frames']]!=[f['time'] for f in after['frames']]: raise RuntimeError('Filter-order experiment changed decoded frame PTS')
                for first,second in zip(before['frames'],after['frames']):
                    with Image.open(first['path']) as a,Image.open(second['path']) as b:
                        diff=ImageChops.difference(a.convert('RGB'),b.convert('RGB')); mean=max(ImageStat.Stat(diff).mean)
                        if mean>1: raise RuntimeError('Filter-order experiment changed image pixels')
                    comparisons.append({'profile':profile['name'],'task':before['task'],'time':first['time'],'maximum_channel_mean_absolute_difference':mean})
    report={'adapters':adapters,'validated_slots':slots[:max(profile_counts)],'profiles':profiles,'source_kind':'synthetic_local' if not sources or str(sources[0])==str(output/'synthetic-10bit.mp4') else 'supplied_read_only',
            'limitations':'Short-sample wall time includes decode/download/scale/JPEG/local writes. OS/NAS caches affect results; this is not measured network bandwidth or proof of linear speedup.',
            'ffmpeg_version':command([ffmpeg,'-version']).stdout.splitlines()[0],'filter_order_comparisons':comparisons,'counter_status':counter_status}
    dump(output/'hardware-benchmark.json',report); return {'report':str(output/'hardware-benchmark.json'),'validated_slots':report['validated_slots'],'profiles':[{'name':p['name'],'wall_seconds':p['wall_seconds'],'processed_video_seconds':p['processed_video_seconds']} for p in profiles]}

def benchmark_summary(output_dir):
    """Summarize captured evidence only; never rerun media or infer GPU identities."""
    from .store import read,dump
    output=Path(output_dir); report=read(output/'hardware-benchmark.json')
    captured=read(output/'performance-counters.json') if (output/'performance-counters.json').exists() else {'samples':[],'status':{'unavailable':'not captured'}}
    profiles=[]
    def stats(values): return {'mean':sum(values)/len(values) if values else None,'peak':max(values) if values else None,'samples':len(values)}
    for profile in report['profiles']:
        samples=[row for row in captured['samples'] if profile.get('started_monotonic',0)<=row['monotonic']<=profile.get('finished_monotonic',0)]
        pids={job.get('timings',{}).get('pid') for job in profile['jobs']}; engines={}
        for row in samples:
            for name,value in row.get('gpu',{}).items():
                if not any(f'pid_{pid}_' in name for pid in pids): continue
                match=re.search(r'luid_(0x[\da-f]+_0x[\da-f]+)_phys_\d+_eng_(\d+)_engtype_(\w+)',name,re.I)
                if not match: continue
                adapter=next((a for a in report['adapters'] if a.get('luid','').lower()==match[1].lower()),None)
                if not adapter: continue
                key=f'{adapter["name"]} / engine {match[2]} / {match[3]}'
                engines.setdefault(key,{})[row['monotonic']]=engines.get(key,{}).get(row['monotonic'],0)+value
        totals={key:stats([data.get(row['monotonic'],0) for row in samples]) for key,data in engines.items()}
        cpu_seconds=0
        for job in profile['jobs']:
            for line in job.get('timings',{}).get('ffmpeg_cpu_benchmark',[]):
                cpu_seconds+=sum(float(v) for v in re.findall(r'(?:utime|stime)=([\d.]+)s',line))
        profiles.append({'name':profile['name'],'wall_seconds':profile['wall_seconds'],'images':sum(len(j['frames']) for j in profile['jobs']),
                         'images_per_minute':sum(len(j['frames']) for j in profile['jobs'])/profile['wall_seconds']*60,
                         'sum_ffmpeg_process_seconds':sum(j.get('timings',{}).get('ffmpeg_seconds',j['seconds']) for j in profile['jobs']),
                         'sum_validation_seconds':sum(j.get('timings',{}).get('validation_seconds',0) for j in profile['jobs']),
                         'sum_ffmpeg_cpu_seconds':cpu_seconds,'gpu_engine_percent':totals,
                         'host_cpu_percent':stats([sum(row.get('cpu',{}).values()) for row in samples]),
                         'host_network_receive_bytes_per_second':stats([sum(row.get('network_receive',{}).values()) for row in samples]),
                         'host_disk_read_bytes_per_second':stats([sum(row.get('disk_read',{}).values()) for row in samples])})
    comparisons=report.get('filter_order_comparisons',[])
    result={'profiles':profiles,'filter_order_verified_frame_pairs':len(comparisons),'maximum_channel_mean_absolute_difference':max((c['maximum_channel_mean_absolute_difference'] for c in comparisons),default=None),
            'counter_status':captured['status'],'limitations':report['limitations'],'gpu_scope':'Per physical engine, summing only benchmark FFmpeg PIDs mapped through current DXGI LUID. Other counters are whole-host context, not attribution to this NAS operation.'}
    dump(output/'benchmark-summary.json',result)
    lines=['# 抽帧持续队列核验','',report['limitations'],'','同一任务集、相同采样计划；依次运行各组，后组可能受OS/SMB暖缓存影响。未修改原片或业务分析状态。','','|配置|总耗时（秒）|图片数|图片/分钟|图片校验合计（秒）|FFmpeg CPU合计（秒）|','|---|---:|---:|---:|---:|---:|']
    for p in profiles: lines.append(f'|{p["name"]}|{p["wall_seconds"]:.3f}|{p["images"]}|{p["images_per_minute"]:.2f}|{p["sum_validation_seconds"]:.3f}|{p["sum_ffmpeg_cpu_seconds"]:.3f}|')
    lines+=['',f'对应采样帧比较：{len(comparisons)}对帧，PTS逐帧一致；最大通道平均绝对像素差：{result["maximum_channel_mean_absolute_difference"]}。','','旧顺序：QSV解码→每帧hwdownload→select→仅选中帧CPU缩放/JPEG。优化顺序：QSV解码→select→仅选中帧hwdownload→CPU缩放/JPEG。CPU滤镜不声称硬件执行。','','FFmpeg进程计时包含打开/seek/驱动初始化；图片验证单独计时，ffprobe在各组计时之外。GPU引擎原始计数与逐任务进程、开始/结束、设备、PTS见JSON/日志，不以总体GPU百分比推断解码饱和。主机磁盘/网络计数含其他活动，不當作NAS独占带宽。']
    (output/'benchmark-summary.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    return {'summary_json':str(output/'benchmark-summary.json'),'summary_markdown':str(output/'benchmark-summary.md'),'profiles':profiles,'verified_frame_pairs':len(comparisons)}

def extract_audio(ffmpeg, source, start, end, output):
    # Consume interleaved video packets sequentially into the null muxer. No video
    # decode/output copy is created; this avoids sparse SMB reads for audio-only maps.
    command([ffmpeg,'-hide_banner','-loglevel','error','-ss',start,'-t',end-start,'-i',source['path'],'-map','0:a:0','-ac','1','-ar','16000','-c:a','pcm_s16le','-y',output,'-map','0:v:0','-c:v','copy','-an','-f','null',os.devnull])
    if not valid_audio(output,end-start): raise RuntimeError('Incomplete or invalid WAV output')

def valid_audio(path,duration):
    try:
        with wave.open(str(path),'rb') as wav:
            return wav.getnchannels()==1 and wav.getframerate()==16000 and wav.getsampwidth()==2 and abs(wav.getnframes()/16000-duration)<0.05 and Path(path).stat().st_size>=wav.getnframes()*2+44
    except (OSError,wave.Error,EOFError): return False

def cut_audio_blocks(blocks,start,end,output):
    """Cut only local PCM derivatives; never reread the original for ASR chunks."""
    cursor=start; pieces=[]
    for block in sorted(blocks,key=lambda b:b['start']):
        if block['end']<=cursor: continue
        if block['start']>cursor+0.001: return False
        stop=min(end,block['end'])
        with wave.open(block['path'],'rb') as wav:
            wav.setpos(min(wav.getnframes(),round((cursor-block['start'])*16000)))
            pieces.append(wav.readframes(round((stop-cursor)*16000)))
        cursor=stop
        if cursor>=end-0.00001: break
    if cursor<end-0.00001: return False
    Path(output).parent.mkdir(parents=True,exist_ok=True)
    with wave.open(str(output),'wb') as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16000); wav.writeframes(b''.join(pieces))
    if not valid_audio(output,end-start): raise RuntimeError('Incomplete local audio chunk')
    return True

def unchanged(source):
    path=Path(source['path']); st=path.stat()
    return st.st_size==source['size'] and st.st_mtime_ns==source['mtime_ns'] and all(Path(x['path']).stat().st_size==x['size'] and Path(x['path']).stat().st_mtime_ns==x['mtime_ns'] and file_hash(x['path'])==x['sha256'] for x in source['sidecars'])
