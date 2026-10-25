"""One centralized, interprocess-locked ASR queue with durable unknown-state stop."""
from __future__ import annotations
import json, time
from pathlib import Path
import httpx
from httpx_sse import EventSource
from .store import ServiceLock, dump, read, digest, host_data_root

MODEL='mlx-community/Qwen3-ASR-1.7B-8bit'

class UnknownServerState(RuntimeError): pass

def parse_events(events, protocol):
    """Protocol is explicitly discovered from saved samples, never guessed on EOF."""
    final=None; raw=[]; finished=False; deltas=[]
    for event,data in events:
        raw.append({'event':event,'data':data})
        if data=='[DONE]' and protocol.get('done_sentinel'):
            finished=True; continue
        obj=json.loads(data)
        kind=obj.get(protocol.get('event_field','type')) or event
        if protocol.get('terminal_field'):
            terminal=obj.get(protocol['terminal_field'])==protocol.get('terminal_value',True)
        else:
            terminal=kind==protocol.get('final_event') and kind not in ('message','delta','')
        if terminal:
            final=obj; finished=True
        elif protocol.get('text_mode')=='deltas_before_final':
            if finished: raise UnknownServerState('Received text after terminal record')
            text=obj.get(protocol.get('text_field','text'))
            if not isinstance(text,str): raise UnknownServerState('Delta lacks verified text field')
            deltas.append(text)
    if not finished or final is None: raise UnknownServerState('Stream ended without verified final event')
    field=protocol.get('text_field','text')
    if field not in final: raise UnknownServerState('Final event lacks verified text field')
    text=''.join(deltas) if protocol.get('text_mode')=='deltas_before_final' else final[field]
    return {'text':text, 'raw_final':final,'events':raw,'precision':protocol.get('precision','chunk')}

class ASRClient:
    def __init__(self,service,state_root,protocol=None,concurrency=1,total_timeout=900,model=MODEL):
        if concurrency not in (1,2): raise ValueError('ASR concurrency must be 1 or 2')
        if not isinstance(model,str) or not model.strip(): raise ValueError('ASR model must be nonempty')
        self.model=model
        # Current implementation intentionally serializes even an allowed upper bound of 2.
        from urllib.parse import urlsplit
        parsed=urlsplit(service.rstrip('/')); port=parsed.port or (443 if parsed.scheme=='https' else 80)
        self.service=f'{parsed.scheme.lower()}://{parsed.hostname.lower()}:{port}{parsed.path.rstrip("/")}'
        self.root=host_data_root()/'services'; self.protocol=protocol
        self.gate=self.root/('service-'+digest(self.service)[:16]+'.json'); self.total_timeout=total_timeout
        self.client=httpx.Client(timeout=httpx.Timeout(connect=10,write=120,read=180,pool=10),trust_env=False)
    def preflight(self):
        r=self.client.get(self.service+'/v1/models'); r.raise_for_status()
        if self.model not in {m['id'] for m in r.json()['data']}: raise RuntimeError('Required ASR model is absent: '+self.model)
        return r.json()
    def transcribe(self,wav,raw_output,discover=False,stream=True):
        with ServiceLock(self.root,self.service):
            gate=read(self.gate) if self.gate.exists() else {}
            if gate.get('status') in ('unknown','inflight'): raise UnknownServerState('ASR paused: prior server task state is unknown; inspect service before explicit recovery')
            dump(self.gate,{'status':'inflight','wav':str(wav),'started':time.time()})
            started=time.monotonic(); events=[]
            try:
                with open(wav,'rb') as audio:
                    with self.client.stream('POST',self.service+'/v1/audio/transcriptions',files={'file':(Path(wav).name,audio,'audio/wav')},data={'model':self.model,'stream':str(stream).lower()}) as response:
                        code=response.status_code
                        if code in (400,401,403,404,413,422,429):
                            response.read(); dump(self.gate,{'status':'rejected','http_status':code})
                            raise ValueError(f'ASR rejected configuration/request: HTTP {code}: '+response.text[:2000])
                        response.raise_for_status()
                        content_type=response.headers.get('content-type','').split(';')[0]
                        if not stream and content_type=='application/json': incoming=(('json',response.read().decode('utf-8')),)
                        elif content_type=='text/event-stream': incoming=((item.event,item.data) for item in EventSource(response).iter_sse())
                        elif content_type in ('application/x-ndjson','application/ndjson'): incoming=(('message',line) for line in response.iter_lines() if line.strip())
                        else: raise UnknownServerState('Unsupported streaming content type: '+content_type)
                        for event,data in incoming:
                            if time.monotonic()-started>self.total_timeout: raise UnknownServerState('Total ASR request deadline exceeded')
                            events.append((event,data))
                            dump(raw_output,{'events':events,'content_type':content_type,'complete':False})
                dump(raw_output,{'events':events,'content_type':content_type,'complete':False,'seconds':time.monotonic()-started})
                if not stream:
                    final=json.loads(events[0][1])
                    if not isinstance(final.get('text'),str): raise UnknownServerState('JSON response does not have a complete text field')
                    if len(events)!=1: raise UnknownServerState('Non-stream sample returned multiple records; inspect full saved response')
                    result={'text':final['text'],'raw_final':final,'events':events,'precision':'chunk','transport':'json','content_type':content_type}
                    dump(raw_output,{**result,'complete':True,'seconds':time.monotonic()-started})
                    dump(self.gate,{'status':'idle','completed':time.time()})
                    return result
                if discover:
                    # A discovery must be inspected; no next request until its actual terminal semantics are confirmed.
                    dump(self.gate,{'status':'unknown','reason':'protocol discovery awaiting explicit terminal verification','raw_output':str(raw_output)})
                    return {'discovery':True,'events':events,'content_type':content_type,'raw_output':str(raw_output)}
                result=parse_events(events,self.protocol or {})
                dump(raw_output,{**result,'complete':True,'seconds':time.monotonic()-started})
                dump(self.gate,{'status':'idle','completed':time.time()})
                return result
            except ValueError: raise
            except (httpx.ConnectError,httpx.ConnectTimeout) as e:
                dump(self.gate,{'status':'not_accepted','error':str(e)}); raise
            except Exception as e:
                dump(raw_output,{'events':events,'complete':False,'error':str(e)})
                dump(self.gate,{'status':'unknown','error':str(e),'raw_output':str(raw_output)})
                raise UnknownServerState(str(e)) from e
    def acknowledge_terminal(self,evidence):
        if not evidence.strip(): raise ValueError('Recovery requires evidence that the old server request ended')
        with ServiceLock(self.root,self.service): dump(self.gate,{'status':'idle','recovery_evidence':evidence,'at':time.time()})

def audio_plan(source,chunk_seconds=30,overlap=1):
    if source['role']=='drone': return {'status':'skipped_drone','chunks':[]}
    if not source['audio']: return {'status':'no_audio','chunks':[]}
    if source['role']=='unknown': return {'status':'blocked_unknown_role','chunks':[]}
    duration=source['duration']; chunks=[]; start=0
    while start<duration:
        end=min(start+chunk_seconds,duration)
        chunks.append({'index':len(chunks),'core_start':start,'core_end':end,'start':max(0,start-overlap if start else 0),'end':min(duration,end+overlap if end<duration else end)})
        start=end
    return {'status':'pending','precision':'chunk','chunks':chunks}
