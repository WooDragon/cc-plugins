"""Real query/media plus isolated native receipts; no model/API calls."""
import argparse,copy,json,os,subprocess,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from test_concurrency import fixture,cli
from test_query import publish,query
from vlog_index import shot_work as work,shot_review as shot,shot_supplement as supplement,analysis,media,report
from vlog_index.store import read,dump,digest,file_hash,PUBLICATION_NAMES

def caps():
 return {'schema':'native_vision_capabilities_v1','source':{'kind':'current_session_native_tool','session_id':'synthetic','tool':'collaboration.spawn_agent','evidence':'synthetic model/effort/image enum'},'parameters':{'model':['gpt-6-luna'],'reasoning_effort':['medium','max'],'fork_turns':['none']},'models':[{'id':'gpt-6-luna','family':'luna','native_model':'gpt-6-luna','image_input':True,'reasoning_efforts':['medium','max']}]}
def result_for(task):
 i=task['input'];frames=i['frames'];sid=i['source']['id'];ids=[f['id'] for f in frames]
 clip={'source_id':sid,'start':frames[0]['time'],'end':frames[-1]['time'],'precision':'sampled_frames','evidence_ids':[ids[0],ids[-1]]}
 return {'review_id':task['review_id'],'input_digest':task['input_digest'],'observed_frame_ids':ids,'topic_status':{k:'uncertain' for k in shot.TOPICS},'observations':[{'source_id':sid,'start':f['time'],'end':f['time'],'description':'Synthetic visible frame','evidence_ids':[f['id']]} for f in frames],'changes':[{'topic':'composition','claim_type':'camera_motion_inference','description':'Synthetic change to inspect','clip':clip,'confidence':'low','limits':['Sampled only; inference is not a fact'],'needs_playback':True}],'candidate_ranges':[],'summary':'Synthetic fixture, no actual model analysis'}
def write_bundle(root,b,only=None):
 data=work._ledger(root)
 for jid in b['jobs']:
  if only is not None and jid not in only:continue
  task=read(data['jobs'][jid]['task_path']);dump(data['bundles'][b['bundle_id']]['results'][jid],result_for(task))
def fake_extract(ffmpeg,source,block,directory,candidate,**kwargs):
 folder=Path(directory);folder.mkdir(parents=True,exist_ok=True);frames=[]
 for n,t in enumerate(block['samples']):
  p=folder/f'{n:04d}.jpg';p.write_bytes(b'Synthetic image '+str(t).encode());frames.append({'id':f'{source["id"]}-b{block["index"]:03d}-f{n:03d}','source_id':source['id'],'time':t,'pts':t+source['start_pts'],'precision':'decoded_frame_pts','path':str(p),'preview':kwargs.get('preview',{})})
 return frames

class ShotPipeline(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
 def packets(self,count=3,directories=None,images=17):
  out=self.root/'work';raw=self.root/'raw';raw.mkdir(exist_ok=True)
  for n in range(count):
   source={'id':f's{n}','path':str(raw/((directories or ['same']*count)[n])/f'clip{n}.mp4'),'relative_path':f'clip{n}.mp4','size':1,'mtime_ns':1,'sidecars':[],'duration':20,'role':'camera','fps':25,'start_pts':0,'metadata':{}}
   frames=fake_extract('',source,{'samples':[i/2 for i in range(images)],'index':n},self.root/f'frames{n}',None)
   p=analysis.make_packages(source,frames,[],self.root/f'packets{n}',size=images)[0];work.add_packet(out,source,read(p['path']),p)
  return out
 def test_full_two_segment_budget_unknown_and_partial_completion_recovery(self):
  out=self.packets(2);b=work.next_action(out,caps(),2);self.assertEqual((b['next_action'],b['images'],len(b['jobs'])),('spawn',34,2))
  thin=read(b['task_path']);self.assertNotIn('result_schema',thin['members'][0]);self.assertNotIn('sha256',thin['members'][0]['frames'][0]);self.assertNotIn('preview',thin['members'][0]['frames'][0]);self.assertEqual(thin['members'][0]['requires_facts'],True)
  self.assertEqual(work.next_action(out,caps(),9)['next_action'],'recover_bind')
  work.next_action(out,bundle_id=b['bundle_id'],native_agent_id='synthetic-native-1');write_bundle(out,b,[b['jobs'][0]])
  self.assertEqual(work.next_action(out,caps(),9)['next_action'],'wait')
  work.next_action(out,bundle_id=b['bundle_id'],outcome='failed',reason='Synthetic actual final, second segment unstarted')
  c=work.next_action(out,caps(),2);self.assertEqual(c['jobs'],[b['jobs'][1]])
  with self.assertRaises(ValueError):work.next_action(out,bundle_id=c['bundle_id'],native_agent_id='synthetic-native-1')
  work.next_action(out,bundle_id=c['bundle_id'],native_agent_id='synthetic-native-2');write_bundle(out,c)
  self.assertEqual(work.next_action(out,caps(),9)['next_action'],'wait')
  with self.assertRaises(ValueError):work.require_finished(out)
  work.next_action(out,bundle_id=c['bundle_id'],outcome='complete',reason='Synthetic matching final');self.assertEqual(work.next_action(out)['next_action'],'complete');work.require_finished(out)
 def test_directories_slots_route_and_no_oversize_segment(self):
  out=self.packets(2,['one','two']);self.assertEqual(work.next_action(out,caps(),1)['next_action'],'wait_slots');b=work.next_action(out,caps(),2);self.assertEqual(len(b['jobs']),1)
  bad=caps();bad['models'][0]['reasoning_efforts']=['medium']
  with self.assertRaises(ValueError):work.vision.shot_dispatch_contract(bad)
  agent={'schema':bad['schema'],'source':bad['source'],'parameters':{'subagent_type':['vlog-daily-index:vlog-vision']},'models':[{'id':'vlog-daily-index:vlog-vision','image_input':True}]}
  with self.assertRaises(ValueError):work.vision.shot_dispatch_contract(agent)
 def test_completion_receipt_survives_other_corrupt_task_and_direct_gate_blocks(self):
  out=self.packets(3);a=work.next_action(out,caps(),2);work.next_action(out,bundle_id=a['bundle_id'],native_agent_id='native-a');b=work.next_action(out,caps(),2);work.next_action(out,bundle_id=b['bundle_id'],native_agent_id='native-b')
  task=Path(work._ledger(out)['jobs'][a['jobs'][0]]['task_path']);task.write_text('{}')
  work.next_action(out,bundle_id=b['bundle_id'],outcome='complete',reason='Actual B final, independent of A');self.assertTrue(work._ledger(out)['bundles'][b['bundle_id']]['turn_finished'])
  self.assertEqual(work.next_action(out)['next_action'],'root_correction')
  with self.assertRaises(ValueError):work.require_finished(out)
 def test_auto_candidate_to_one_max_pass_daily_publication_and_query(self):
  m,state,_=fixture(self.root,count=2);m['config']['supplement_mode']='shot_v1';s=m['sources'][0];s['fps']=25;s['blocks']=[{'index':0,'start':0,'end':20,'samples':[0,10]}]
  frames=fake_extract('',s,{'samples':[0,10],'index':0},self.root/'coarse',None);m['frames']=frames
  p=analysis.make_packages(s,frames,[],self.root/'coarse-packages')[0];m['packages']=[p];raw=read(p['path']);req={'source_id':'s','start':0,'end':10,'purpose':'dynamic','question':'Which part of the composition transition needs playback to choose a shot?','reason':'Specific two-frame transition','evidence_ids':[f['id'] for f in frames]}
  value={'package_id':p['id'],'analysed_frame_ids':[f['id'] for f in frames],'observations':[{'source_id':'s','start':f['time'],'end':f['time'],'description':'Synthetic static frame','evidence_ids':[f['id']]} for f in frames],'events':[],'interest_points':[],'supplemental_requests':[req],'summary':'Synthetic initial scan'}
  dump(p['result_path'],value);dump(state/'manifest.json',m);self.assertFalse(cli.import_results(argparse.Namespace(state=str(state),source_id=None,refresh=False))['errors']);m=read(state/'manifest.json')
  with self.assertRaisesRegex(ValueError,'accept-dynamic'):cli.daily_package(argparse.Namespace(state=str(state)))
  self.assertEqual(len(supplement.accept_dynamic(m,'ROOT','Explicit authorized dynamic policy')['accepted']),1)
  with patch.object(media,'extract_block',side_effect=fake_extract):supplement.prepare(m)
  self.assertEqual(len([p for p in m['packages'] if p.get('shot_review')]),2)
  self.assertFalse(work._ledger(state/'shot-review')['bundles'])
  b=work.next_action(state/'shot-review',caps(),2);work.next_action(state/'shot-review',bundle_id=b['bundle_id'],native_agent_id='synthetic-max');write_bundle(state/'shot-review',b)
  self.assertEqual(work.next_action(state/'shot-review')['next_action'],'wait')
  work.next_action(state/'shot-review',bundle_id=b['bundle_id'],outcome='complete',reason='Synthetic native final');self.assertEqual(work.next_action(state/'shot-review')['next_action'],'complete')
  self.assertTrue(supplement.import_successes(m));cli.import_results(argparse.Namespace(state=str(state),source_id=None,refresh=False),m);cli.resolve_supplements(m);self.assertEqual(m['supplemental_pending'],[])
  changes=supplement.daily_changes(m);daily={'summary':'Synthetic day','summary_evidence_ids':[frames[0]['id']],'events':[],'interest_points':[],'visual_changes':changes};self.assertEqual(analysis.validate_daily(daily,m,[]),daily)
  old={k:v for k,v in daily.items() if k!='visual_changes'};legacy=copy.deepcopy(m);legacy.pop('shot_records');self.assertNotIn('visual_changes',analysis.validate_daily(old,legacy,[]))
  m['itinerary']['sha256']=digest(m['itinerary']['data']);m['map_evidence']={'records':[],'sha256':digest([])};geo={'associations':[]};m['geography_package']={'package_id':'geo'};m['geography']={'data':geo,'sha256':digest(geo),'package_id':'geo','input_digests':analysis.geography_bindings(m,daily)};m['transcription']={'s':{'status':'no_audio','segments':[]}}
  final=self.root/'library/day';result=report.render(m,[],final,daily);self.assertEqual(result['status'],'complete');text=(final/PUBLICATION_NAMES[2]).read_text(encoding='utf-8');self.assertIn('相机运动推断',text)
  db=query.connect(self.root/'query.duckdb');self.addCleanup(db.close);config={'schema':1,'libraries':[{'root':str(final.parent),'publications':['day']}]};self.assertFalse(query.refresh(db,config)[0]['stale']);rows=query.search(db,'Synthetic change',kind='visual_change');self.assertTrue(rows)
  candidates=self.root/'changes.json';dump(candidates,rows);reuse=work.plan_query(candidates,[1],self.root/'no-recursion','unused-ffmpeg');self.assertEqual(reuse['next_action'],'use_existing_review');self.assertEqual(reuse['native_calls'],0)
 def test_long_auto_interval_complete_coverage_and_frozen_extraction_resume(self):
  m,state,_=fixture(self.root,count=4);m['config']['supplement_mode']='shot_v1';source=m['sources'][0];source['fps']=25
  anchors=fake_extract('',source,{'samples':[0,30],'index':0},self.root/'anchors',None);p=analysis.make_packages(source,anchors,[],self.root/'initial')[0];p['status']='success';m['packages']=[p]
  req={'package_id':p['id'],'source_id':'s','start':0,'end':30,'purpose':'dynamic','question':'Which transition needs playback?','reason':'Two observed anchors','evidence_ids':[f['id'] for f in anchors]};m['supplemental_pending']=[req]
  supplement.accept_dynamic(m,'ROOT','Authorized anchored policy')
  original=work.add_packet
  with patch.object(media,'extract_block',side_effect=fake_extract),patch.object(work,'add_packet',side_effect=RuntimeError('Simulated crash after frozen extraction')):
   with self.assertRaises(RuntimeError):supplement.prepare(m)
  m=read(state/'manifest.json')
  with patch.object(media,'extract_block',side_effect=AssertionError('Resume must not re-extract frozen images')):supplement.prepare(m)
  frames=m['supplemental_frames'];self.assertEqual((len(frames),min(f['time'] for f in frames),max(f['time'] for f in frames)),(61,0,29.96))
  data=work._ledger(state/'shot-review');self.assertEqual(len(data['jobs']),4);self.assertEqual(set(f['id'] for f in frames),{fid for j in data['jobs'].values() for fid in read(j['task_path'])['input']['core_frame_ids']})
  b=work.next_action(state/'shot-review',caps(),2);self.assertLessEqual(b['images'],34);self.assertEqual(len(b['jobs']),2)
  with self.assertRaises(ValueError):analysis.record_supplement_decision(m,'new-request','accept','ROOT','No recursive round')
 def test_restored_frozen_task_can_resume_but_never_succeeds_without_result(self):
  out=self.packets(1);b=work.next_action(out,caps(),2);work.next_action(out,bundle_id=b['bundle_id'],native_agent_id='native-a');task=Path(work._ledger(out)['jobs'][b['jobs'][0]]['task_path']);old=task.read_bytes();task.write_text('{}')
  work.next_action(out,bundle_id=b['bundle_id'],outcome='failed',reason='Actual failed FINAL');self.assertEqual(work.next_action(out)['next_action'],'root_correction');task.write_bytes(old)
  self.assertEqual(work.next_action(out)['next_action'],'wait_slots');self.assertNotEqual(work._ledger(out)['jobs'][b['jobs'][0]]['status'],'success')
 def test_oversized_whole_segment_and_synced_state_rejected(self):
  out=self.packets(1,images=35)
  with self.assertRaises(ValueError):work.next_action(out,caps(),2)
  forbidden=self.root/'OneDrive'/'active'
  with self.assertRaises(ValueError):work.next_action(forbidden,caps(),2)
  self.assertFalse(forbidden.exists())
 def test_complete_missing_result_keeps_owner_and_requires_original_result_recovery(self):
  out=self.packets(1);b=work.next_action(out,caps(),2);work.next_action(out,bundle_id=b['bundle_id'],native_agent_id='native-complete');work.next_action(out,bundle_id=b['bundle_id'],outcome='complete',reason='Actual matching FINAL claimed success')
  result=work.next_action(out,caps(),9);self.assertEqual(result['next_action'],'root_correction');data=work._ledger(out);self.assertEqual(len(data['bundles']),1);self.assertEqual(data['jobs'][b['jobs'][0]]['bundle_id'],b['bundle_id']);self.assertEqual(data['bundles'][b['bundle_id']]['native_agent_id'],'native-complete')
  with self.assertRaises(ValueError):work.require_finished(out)
  write_bundle(out,b);self.assertEqual(work.next_action(out,caps(),9)['next_action'],'complete');work.require_finished(out)
 def test_frozen_thin_bundle_must_match_sha_members_and_contract(self):
  out=self.packets(1);b=work.next_action(out,caps(),2);path=Path(b['task_path']);original=path.read_bytes();thin=read(path);thin['members'][0]['frames'][0]['path']='wrong-image.jpg';thin['members'][0]['frames'][0]['time']=9;thin['members'][0]['clock']['source_fps']=999;dump(path,thin)
  work.next_action(out,bundle_id=b['bundle_id'],native_agent_id='native-mutated');write_bundle(out,b);work.next_action(out,bundle_id=b['bundle_id'],outcome='complete',reason='Actual receipt must persist independently')
  self.assertTrue(work._ledger(out)['bundles'][b['bundle_id']]['turn_finished']);self.assertEqual(work.next_action(out,caps(),9)['next_action'],'root_correction')
  with self.assertRaises(ValueError):work.require_finished(out)
  # Matching an altered file hash alone cannot bypass the original full-task member map.
  data=work._ledger(out);data['bundles'][b['bundle_id']]['task_sha256']=file_hash(path);work._save(out,data);self.assertEqual(work.next_action(out)['next_action'],'root_correction')
  path.write_bytes(original);data=work._ledger(out);data['bundles'][b['bundle_id']]['task_sha256']=file_hash(path);work._save(out,data);self.assertEqual(work.next_action(out)['next_action'],'complete')
 def test_batch_revalidates_nonblank_question_source_interval_and_real_frame_anchors(self):
  m,_,_=fixture(self.root,count=2);m['config']['supplement_mode']='shot_v1';source=m['sources'][0];frames=fake_extract('',source,{'samples':[0,10],'index':0},self.root/'anchors',None);p=analysis.make_packages(source,frames,[],self.root/'initial')[0];p['status']='success';m['packages']=[p];package=read(p['path'])
  req={'package_id':p['id'],'source_id':'s','start':0,'end':10,'purpose':'dynamic','question':'Which visible transition needs playback?','reason':'Two observed anchors','evidence_ids':[f['id'] for f in frames]}
  for field,value in [('question','   '),('reason','   '),('question',3),('source_id','other'),('end',float('nan')),('evidence_ids',[frames[0]['id'],'missing'])]:
   with self.subTest(field=field,value=value):
    bad={**req,field:value}
    with self.assertRaises(ValueError):analysis.validate_dynamic_request(package,bad)
    m['supplemental_pending']=[bad];self.assertEqual(supplement.accept_dynamic(m,'ROOT','Authorized policy')['accepted'],[])
  m['supplemental_pending']=[req];self.assertEqual(len(supplement.accept_dynamic(m,'ROOT','Authorized policy')['accepted']),1)
 def test_generic_cloud_water_or_legacy_candidate_does_not_auto_upgrade(self):
  m,_,_=fixture(self.root,count=1);m['config']['supplement_mode']='shot_v1';m['supplemental_pending']=[{'source_id':'s','start':0,'end':8,'reason':'Clouds/water/drone category only'}]
  self.assertEqual(supplement.accept_dynamic(m,'ROOT','Authorized rule')['accepted'],[]);self.assertEqual(supplement.prepare(m)['packages'],[])
  m['config'].pop('supplement_mode');self.assertIn('legacy',supplement.accept_dynamic(m,'ROOT','rule')['reason'])

class QueryRangeBoundaries(unittest.TestCase):
 def test_long_candidate_requires_narrowing_and_unknown_time_never_extracts(self):
  with tempfile.TemporaryDirectory() as td:
   root=Path(td);library=root/'library';publication=library/'day';publication.mkdir(parents=True)
   source={'id':'s','fps':25,'duration':40,'size':1,'mtime_ns':1,'sidecars':[],'metadata':{},'start_pts':0}
   row={'stale':False,'source_id':'s','library':str(library),'publication':str(publication),'run_id':'r','revision':1,'relative_path':'day/original.mp4','original_path':str(publication/'original.mp4'),'kind':'event','start_s':0,'end_s':30};path=root/'candidates.json';dump(path,[row])
   with patch.object(query,'publication_rows',return_value=('snapshot',({'run_id':'r','revision':1},{},{'s':(source,'day/original.mp4')}))),patch.object(media,'unchanged',return_value=True),patch.object(shot,'prepare',side_effect=AssertionError('No implicit truncation/extraction')):
    result=work.plan_query(path,[1],root/'work','ffmpeg');self.assertEqual(result['next_action'],'select_interval');self.assertEqual((result['requests'][0]['start'],result['requests'][0]['end'],result['requests'][0]['covered']),(0,30,False))
    row['start_s']=None;dump(path,[row])
    with self.assertRaises(ValueError):work.plan_query(path,[1],root/'work','ffmpeg')

class RealQueryPipeline(unittest.TestCase):
 def test_real_query_alias_exact_cache_and_full_bundle(self):
  ff=os.environ.get('VLOG_TEST_FFMPEG');fp=os.environ.get('VLOG_TEST_FFPROBE')
  if not ff or not fp:self.skipTest('Explicit FFmpeg/ffprobe required')
  with tempfile.TemporaryDirectory() as td:
   root=Path(td);library=root/'library';day=library/'day';publish(day,'AI display alias, never a filename');video=day/'clip.mp4'
   subprocess.run([ff,'-hide_banner','-loglevel','error','-f','lavfi','-i','testsrc2=size=160x90:rate=25:duration=6','-c:v','libx264','-an',str(video)],check=True,capture_output=True)
   source=media.probe(video,fp,day);source['id']='s';source['role']='camera';index=read(day/PUBLICATION_NAMES[1]);index['sources'][0]=source;c=index['events'][0]['clips'][0];index['events'][0]['clips']=[c,{**c,'start':3,'end':5}];dump(day/PUBLICATION_NAMES[1],index);(day/PUBLICATION_NAMES[2]).write_text(f'<!-- generator:vlog-daily-index; run_id:same-local-run; revision:1 -->\n{file_hash(day/PUBLICATION_NAMES[1])}')
   db=query.connect(root/'query.duckdb')
   try:
    query.refresh(db,{'schema':1,'libraries':[{'root':str(library),'publications':['day']}]});rows=query.search(db,'AI display alias',kind='event')
   finally:db.close()
   self.assertEqual(len(rows),2);self.assertEqual(rows[0]['source_id'],'s');self.assertTrue(rows[0]['original_path'].endswith('clip.mp4'));candidates=root/'candidates.json';dump(candidates,rows);out=root/'work';original_hash=file_hash(video)
   planned=work.plan_query(candidates,[1,2],out,ff);self.assertEqual(planned['selected'],2);b=work.next_action(out,caps(),2);self.assertEqual((len(b['jobs']),b['images']),(2,34));work.next_action(out,bundle_id=b['bundle_id'],native_agent_id='synthetic-native');write_bundle(out,b);work.next_action(out,bundle_id=b['bundle_id'],outcome='complete',reason='Synthetic matching FINAL');self.assertEqual(work.next_action(out)['next_action'],'complete')
   data=work._ledger(out)
   for j in data['jobs'].values():shot.report(j['accepted_path'],root/(j['id']+'.md'))
   with patch.object(media,'extract_block',side_effect=AssertionError('Exact hit must not extract')):self.assertEqual(work.plan_query(candidates,[1,2],out,ff)['cache_hits'],2)
   self.assertEqual(file_hash(video),original_hash)
   changed=copy.deepcopy(rows);changed[0]['original_path']=str(day/'AI display alias.mp4');dump(candidates,changed)
   with self.assertRaises(ValueError):work.plan_query(candidates,[1],root/'bad-map',ff)
   changed=copy.deepcopy(rows);changed[0]['end_s']=6;changed[0]['start_s']=0;dump(candidates,changed)
   # Explicit source interval remains intact; this short source is executable, not clipped.
   changed[0]['end_s']=20;dump(candidates,changed)
   with self.assertRaises(ValueError):work.plan_query(candidates,[1],root/'bad-time',ff)
