"""Review regressions with synthetic sources; no private media or model calls."""
import argparse,copy,json,os,subprocess,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from test_concurrency import fixture,cli
import test_shot_pipeline as pipeline
from test_shot_pipeline import fake_extract,caps,result_for,write_bundle
from test_query import publish,query
from vlog_index import analysis,shot_review as shot,shot_supplement as sup,shot_work as work,vision_work,store,media
from vlog_index.store import read,dump,digest,file_hash,PUBLICATION_NAMES


class ReviewFixes(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
 def source(self,m,sid):
  source=copy.deepcopy(m['sources'][0]);source['id']=sid;source['fps']=25
  raw=self.root/(sid+'.bin');raw.write_bytes(b'Synthetic original '+sid.encode());source.update(path=str(raw),relative_path=raw.name,size=raw.stat().st_size,mtime_ns=raw.stat().st_mtime_ns)
  return source
 def proposal(self,m,source,times,start,end):
  frames=fake_extract('',source,{'samples':times,'index':0},self.root/source['id'],None)
  p=analysis.make_packages(source,frames,[],self.root/(source['id']+'-packets'))[0];p['status']='success';m['packages'].append(p)
  req={'package_id':p['id'],'source_id':source['id'],'start':start,'end':end,'purpose':'dynamic','question':'Which visible state changes between the supplied samples?','reason':'Two source-frame observations differ','evidence_ids':[f['id'] for f in frames]}
  m.setdefault('supplemental_pending',[]).append(req);return req,read(p['path'])
 def work_fixture(self,n=2):
  case=pipeline.ShotPipeline('runTest');case.setUp();self.addCleanup(case.doCleanups);return case.packets(n)

 def test_dynamic_closed_envelope_distinct_actual_times_and_legacy_proposal_import(self):
  m,_,_=fixture(self.root,count=2);s=self.source(m,'a');req,p=self.proposal(m,s,[0,10],0,10)
  self.assertEqual(analysis.dynamic_sample_times(s,0,10,[0,10])[-1],10)
  self.assertEqual(analysis.dynamic_sample_times(s,0,0.04,[0,0.04]),[0,0.04])
  analysis.validate_dynamic_request(p,req,source=s)
  self.assertEqual(analysis.dynamic_sample_times(s,0,0.051,[0,0.051]),[0,0.051])
  for start,end in [(0,0.01),(0,0.04),(0,float('nan'))]:
   with self.assertRaises(ValueError):analysis.dynamic_sample_times(s,start,end)
  for change in ('outside','same_time'):
   packet=copy.deepcopy(p)
   if change=='outside':packet['frames'][0]['time']=-0.1
   else:packet['frames'][1]['time']=packet['frames'][0]['time']
   with self.assertRaises(ValueError):analysis.validate_dynamic_request(packet,req,source=s)
  # The original old-package proposal contract is still importable; extraction
  # requires the new strict eligibility check before any new acceptance.
  legacy=copy.deepcopy(p);legacy.pop('dynamic_request_policy');legacy['prompt_version']='4';legacy['source'].pop('fps',None)
  old_request={**req,'start':0.1,'end':9.9}
  value={'package_id':legacy['package_id'],'analysed_frame_ids':[f['id'] for f in legacy['frames']],'observations':[{'source_id':s['id'],'start':f['time'],'end':f['time'],'description':'Synthetic fact','evidence_ids':[f['id']]} for f in legacy['frames']],'events':[],'interest_points':[],'supplemental_requests':[old_request],'summary':'Frozen legacy proposal'}
  analysis.validate_result(legacy,value)
  with self.assertRaises(ValueError):analysis.validate_dynamic_request(legacy,old_request,source=s)

 def test_bad_interval_does_not_block_good_source_and_selected_pipeline_is_used(self):
  m,state,_=fixture(self.root,count=2);a=self.source(m,'bad');b=self.source(m,'good');m['sources']=[a,b];m['config']['supplement_mode']='shot_v1'
  bad,_=self.proposal(m,a,[0,0.04],0,0.01);good,_=self.proposal(m,b,[0,1],0,1)
  outcome=sup.accept_dynamic(m,'ROOT','Authorized objective policy')
  self.assertEqual(outcome['accepted'],[digest(good)]);self.assertEqual(outcome['deferred_to_existing_ROOT_review'][0]['decision'],'reject')
  # Even a pre-existing accepted bad proposal must remain a local recovery item.
  m['supplemental_decisions'][digest(bad)]={'decision':'accept'}
  calls=[]
  def extract(ff,s,*args,**kwargs):
   calls.append((s['id'],kwargs.get('select_before_download')));return fake_extract(ff,s,*args,**kwargs)
  with patch.object(media,'extract_block',side_effect=extract):result=sup.prepare(m)
  self.assertTrue(result['errors']);self.assertTrue(result['packages']);self.assertEqual(calls,[('good',True)])
  self.assertIn(bad,m['supplemental_pending']);self.assertEqual({p['source_id'] for p in m['packages'] if p.get('shot_review')},{'good'})

 def test_round_keeps_preexisting_undecided_geography_and_rejects_new_round(self):
  m,_,_=fixture(self.root,count=2);s=self.source(m,'a');m['sources']=[s];m['config']['supplement_mode']='shot_v1';req,_=self.proposal(m,s,[0,1],0,1)
  geo={'source_id':'a','start':3,'end':4,'reason':'Resolve an occluded geographic reference'};m['supplemental_pending'].append(geo)
  sup.accept_dynamic(m,'ROOT','Authorized policy')
  with patch.object(media,'extract_block',side_effect=fake_extract):sup.prepare(m)
  analysis.record_supplement_decision(m,digest(geo),'accept','ROOT','Independent geography evidence')
  newcomer={**geo,'start':5};m['supplemental_pending'].append(newcomer)
  with self.assertRaises(ValueError):analysis.record_supplement_decision(m,digest(newcomer),'accept','ROOT','No recursive round')
  rejected={**geo,'start':6};m['supplemental_pending'].append(rejected);analysis.record_supplement_decision(m,digest(rejected),'reject','ROOT','Explicitly close deferred proposal');self.assertNotIn(rejected,m['supplemental_pending'])

 def test_daily_requires_entire_canonical_fact_including_description(self):
  canonical={'topic':'lighting','claim_type':'visible_change','description':'Synthetic display darkening','clip':{'source_id':'s','start':0,'end':1,'precision':'sampled_frames','evidence_ids':['a','b']},'confidence':'medium','limits':['Sampled only'],'needs_playback':True}
  record={'result':{'changes':[canonical]}}
  with patch.object(sup,'trusted_records',return_value={'review':record}):
   sup.validate_daily_changes({},[{'review_id':'review','change':copy.deepcopy(canonical)}])
   for field,value in [('description','Opposite brightening'),('topic','composition'),('claim_type','camera_motion_inference'),('confidence','high'),('clip',{**canonical['clip'],'evidence_ids':['b','c']})]:
    with self.subTest(field=field),self.assertRaises(ValueError):sup.validate_daily_changes({},[{'review_id':'review','change':{**canonical,field:value}}])

 def test_bad_and_oversized_queued_members_leave_good_work_dispatchable(self):
  for failure in ('corrupt','oversized'):
   out=self.work_fixture(3);data=work._ledger(out);job=next(iter(data['jobs'].values()))
   if failure=='corrupt':Path(job['task_path']).write_text('{}')
   else:job['images']=35;work._save(out,data)
   result=work.next_action(out,caps(),2)
   self.assertEqual(result['next_action'],'spawn');self.assertNotIn(job['id'],result['jobs']);self.assertTrue(result['recovery_required'])

 def test_mixed_frozen_contracts_dispatch_separately_and_legacy_result_survives(self):
  out=self.work_fixture();data=work._ledger(out);old=list(data['jobs'].values())[1];task=read(old['task_path'])
  task['input'].pop('output_policy');task['input']['instructions']='Frozen legacy instructions';task['input']['prompt_version']='6';task['input']['result_schema']=shot.Result.model_json_schema();task['input_digest']=digest(task['input']);task['review_id']='shot-'+task['input_digest'][:24]
  dump(old['task_path'],task);old['task_sha256']=file_hash(old['task_path']);work._save(out,data)
  first=work.next_action(out,caps(),2);self.assertEqual(len(first['jobs']),1);work.next_action(out,bundle_id=first['bundle_id'],native_agent_id='native-new');write_bundle(out,first);work.next_action(out,bundle_id=first['bundle_id'],outcome='complete',reason='Synthetic actual final')
  second=work.next_action(out,caps(),2);self.assertEqual(second['jobs'],[old['id']]);work.next_action(out,bundle_id=second['bundle_id'],native_agent_id='native-old')
  raw=result_for(task);raw['changes'][0]['topic']='edit_cue';raw['topic_status']['edit_cue']='assessed';raw['candidate_ranges']=[{'clip':copy.deepcopy(raw['changes'][0]['clip']),'reason':'Frozen old field','confidence':'low','limits':['Old contract'],'needs_playback':True}]
  dump(work._ledger(out)['bundles'][second['bundle_id']]['results'][old['id']],raw);work.next_action(out,bundle_id=second['bundle_id'],outcome='complete',reason='Legacy actual final');self.assertEqual(work.next_action(out)['next_action'],'complete')
  accepted=read(work._ledger(out)['jobs'][old['id']]['accepted_path']);self.assertEqual(accepted,shot.validated_record(accepted['task_path'],accepted['result_path']));shot.report(work._ledger(out)['jobs'][old['id']]['accepted_path'],self.root/'legacy.md')

 def test_new_objective_task_schema_result_and_report_have_no_recommendation_fields(self):
  out=self.work_fixture(1);job=next(iter(work._ledger(out)['jobs'].values()));task=read(job['task_path']);schema=task['input']['result_schema']
  self.assertNotIn('candidate_ranges',schema['properties']);self.assertNotIn('edit_cue',schema['$defs']['ObjectiveChange']['properties']['topic']['enum'])
  raw=result_for(task);shot.validate_value(task,raw)
  with self.assertRaises(ValueError):shot.validate_value(task,{**raw,'candidate_ranges':[]})
  dump(task['result_path'],raw);record=shot.validate(job['task_path']);shot.report(record['accepted_path'],self.root/'objective.md');text=(self.root/'objective.md').read_text(encoding='utf-8');self.assertNotIn('候选区间',text)

 def test_static_work_excludes_supplement_invalid_and_waiting(self):
  m,_,_=fixture(self.root,count=1)
  for status in ('invalid','waiting_ai'):
   m['packages']=[{'id':'shot','status':status,'shot_review':True}]
   result=vision_work._next(self.root,m,{'workers':{}},{},argparse.Namespace(available_workers=0,reserve_sol=1))
   self.assertEqual(result['next_action'],'visual_complete')

 def test_paths_reject_sync_and_original_before_query_writes(self):
  for path in (self.root/'OneDrive - Example'/'cache',self.root/'MY_onedrive_cache'):
   with self.assertRaises(ValueError):store.local_nonsync(path)
   self.assertFalse(path.exists())
  library=self.root/'library';day=library/'day';day.mkdir(parents=True);source={'id':'s','fps':25,'duration':20,'size':1,'mtime_ns':1,'sidecars':[],'metadata':{},'start_pts':0}
  row={'stale':False,'source_id':'s','library':str(library),'publication':str(day),'run_id':'r','revision':1,'relative_path':'day/original.mp4','original_path':str(day/'original.mp4'),'kind':'event','start_s':0,'end_s':1};path=self.root/'query.json';dump(path,[row]);before=set(day.iterdir())
  with patch.object(query,'publication_rows',return_value=('snap',({'run_id':'r','revision':1},{},{'s':(source,'day/original.mp4')}))),patch.object(media,'unchanged',return_value=True):
   with self.assertRaises(ValueError):work.plan_query(path,[1],day,'unused')
  self.assertEqual(set(day.iterdir()),before)
  row['kind']='visual_change';dump(path,[row])
  with patch.object(query,'publication_rows',return_value=('snap',({'run_id':'r','revision':1},{},{'s':(source,'day/original.mp4')}))):
   with self.assertRaises(ValueError):work.plan_query(path,[1],self.root/'work','unused')

 def test_query_validates_whole_visual_schema_and_retains_old_topic_reading(self):
  day=self.root/'library/day';publish(day);index=read(day/PUBLICATION_NAMES[1]);index['evidence_frames']=[{'id':'a','source_id':'s','time':0},{'id':'b','source_id':'s','time':1}]
  change={'topic':'edit_cue','claim_type':'visible_change','description':'Old objective visible change','clip':{'source_id':'s','start':0,'end':1,'precision':'sampled_frames','evidence_ids':['a','b']},'confidence':'medium','limits':['Sampled only'],'needs_playback':True};index['visual_changes']=[{'review_id':'old-review','change':change}]
  def write(value):
   dump(day/PUBLICATION_NAMES[1],value);(day/PUBLICATION_NAMES[2]).write_text('<!-- generator:vlog-daily-index; run_id:same-local-run; revision:1 -->\n'+file_hash(day/PUBLICATION_NAMES[1]))
  write(index);query.publication_rows(day.parent,day)
  for field,value in [('topic','unknown'),('confidence','certain'),('description','   '),('limits',['   ']),('limits','not a list'),('needs_playback',False)]:
   invalid=copy.deepcopy(index);invalid['visual_changes'][0]['change'][field]=value;write(invalid)
   with self.assertRaises(ValueError):query.publication_rows(day.parent,day)
  invalid=copy.deepcopy(index);invalid['evidence_frames'][1]['time']=0;invalid['visual_changes'][0]['change']['clip']['end']=0;write(invalid)
  with self.assertRaises(ValueError):query.publication_rows(day.parent,day)

 def test_source_filters_are_applied_or_explicitly_rejected(self):
  m,_,_=fixture(self.root,count=2);a=self.source(m,'a');b=self.source(m,'b');m['sources']=[a,b];m['config']['supplement_mode']='shot_v1';one,_=self.proposal(m,a,[0,1],0,1);two,_=self.proposal(m,b,[0,1],0,1)
  self.assertEqual(sup.accept_dynamic(m,'ROOT','Authorized',source_ids=['a'])['accepted'],[digest(one)]);self.assertNotIn(digest(two),m['supplemental_decisions'])
  m['supplemental_plans']={'old-unselected':{'source_id':'b','start':0,'end':1,'request_ids':[digest(two)],'mode':'shot_v1','extraction_complete':False,'package_ids':[]}}
  calls=[]
  def selected_extract(ff,s,*args,**kwargs):calls.append(s['id']);return fake_extract(ff,s,*args,**kwargs)
  with patch.object(media,'extract_block',side_effect=selected_extract):sup.prepare(m,source_ids=['a'])
  self.assertEqual(calls,['a']);self.assertFalse(m['supplemental_plans']['old-unselected']['extraction_complete'])
  with self.assertRaisesRegex(ValueError,'source-id'):cli.shot_work_action(argparse.Namespace(source_id=['a']))

 def test_same_plan_geography_reuses_validated_facts_without_changing_task(self):
  m,state,_=fixture(self.root,count=1);s=self.source(m,'a');s['duration']=5;m['sources']=[s];m['config']['supplement_mode']='shot_v1'
  initial,_=self.proposal(m,s,[0,4.96],0,5);geo={'source_id':'a','start':1,'end':2,'reason':'Resolve an occluded reference'};m['supplemental_pending'].append(geo)
  sup.accept_dynamic(m,'ROOT','Authorized objective policy')
  with patch.object(media,'extract_block',side_effect=fake_extract):sup.prepare(m)
  root=state/'shot-review';action=work.next_action(root,caps(),2);work.next_action(root,bundle_id=action['bundle_id'],native_agent_id='geo-evidence');write_bundle(root,action);work.next_action(root,bundle_id=action['bundle_id'],outcome='complete',reason='Synthetic actual final');self.assertEqual(work.next_action(root)['next_action'],'complete')
  self.assertTrue(sup.import_successes(m));cli.import_results(argparse.Namespace(state=str(state),source_id=None,refresh=False),m)
  before={j['task_path']:file_hash(j['task_path']) for j in work._ledger(root)['jobs'].values()}
  analysis.record_supplement_decision(m,digest(geo),'accept','ROOT','Independent geographic clarification')
  with patch.object(media,'extract_block',side_effect=AssertionError('Exact existing evidence must not re-extract')):self.assertFalse(sup.prepare(m)['errors'])
  self.assertEqual(before,{p:file_hash(p) for p in before});cli.resolve_supplements(m);self.assertNotIn(geo,m['supplemental_pending'])
  canonical=sup.daily_changes(m);self.assertTrue(canonical)
  record=next(iter(sup.trusted_records(m).values()));self.assertTrue(record['result']['observations'])
  self.assertEqual(canonical[0]['change'],record['result']['changes'][0])
  with self.assertRaises(ValueError):analysis.require_geography(m,{'summary':'Facts are not geography approval','events':[],'interest_points':[],'visual_changes':canonical})

 def test_explicit_legacy_round_recovery_uses_original_canonical_proposal(self):
  m,state,_=fixture(self.root,count=1);s=self.source(m,'a');m['sources']=[s];m['config']['supplement_mode']='shot_v1';first,payload=self.proposal(m,s,[0,1],0,1)
  geo={'package_id':first['package_id'],'source_id':'a','start':0.2,'end':0.8,'reason':'Original unresolved reference'};m['supplemental_pending'].append(geo);m['supplemental_round']={'number':1,'request_ids':[digest(first)],'started':'2030-01-01T00:00:00Z'}
  canonical={'package_id':payload['package_id'],'analysed_frame_ids':payload['core_frame_ids'],'observations':[{'source_id':'a','start':f['time'],'end':f['time'],'description':'Frozen initial fact','evidence_ids':[f['id']]} for f in payload['frames']],'events':[],'interest_points':[],'supplemental_requests':[{k:v for k,v in geo.items() if k!='package_id'}],'summary':'Original result'}
  path=state/'analysis'/(payload['package_id']+'.json');dump(path,canonical);original=file_hash(path);dump(state/'manifest.json',m)
  with self.assertRaises(ValueError):analysis.record_supplement_decision(m,digest(geo),'accept','ROOT','Default must preserve frozen list')
  script=Path(__file__).resolve().parents[1]/'scripts/vlog_daily_index.py'
  run=subprocess.run([sys.executable,'-X','utf8',str(script),'decide-supplement','--state',str(state),'--request-id',digest(geo),'--decision','accept','--restore-round-request','--reviewer','ROOT','--reason','Verified original-round proposal'],capture_output=True,text=True,encoding='utf-8')
  self.assertEqual(run.returncode,0,run.stderr);restored=read(state/'manifest.json');self.assertEqual(restored['supplemental_round']['request_ids'],[digest(first)]);self.assertEqual(file_hash(path),original)
  self.assertEqual(restored['supplemental_round']['restored_requests'][0]['original_result_sha256'],original)
  restored['packages'][0]['supplemental']=True
  with self.assertRaises(ValueError):analysis.restore_round_request(restored,digest(geo),'ROOT','Not an original initial source')


if __name__=='__main__':unittest.main()
