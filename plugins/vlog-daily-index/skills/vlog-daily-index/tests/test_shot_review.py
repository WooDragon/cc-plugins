"""Synthetic protocol and extraction tests; never access user media or a model."""
import copy, importlib.util, json, os, subprocess, sys, tempfile, unittest
from pathlib import Path
SCRIPTS=Path(__file__).resolve().parents[1]/'scripts';sys.path.insert(0,str(SCRIPTS))
spec=importlib.util.spec_from_file_location('shot_review',SCRIPTS/'shot_review.py');shot=importlib.util.module_from_spec(spec);sys.modules[spec.name]=shot;spec.loader.exec_module(shot)

class ShotReview(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
  frames=[]
  for n in range(3):
   p=self.root/f'f{n}.jpg';p.write_bytes(b'synthetic image bytes '+bytes([n]));frames.append({'id':f'f{n}','source_id':'source-A','time':n*0.5,'path':str(p),'sha256':shot.file_hash(p)})
  identity={'source':{'id':'source-A','path':str(self.root/'source.mp4'),'relative_path':'source.mp4'},'interval':{'start':0,'end':1.1},'frames':frames,'sampling':{'actual_frames':3,'max_gap_seconds':0.5},'preview':{'status':'unspecified'}}
  self.task={'review_id':'review-A','input':identity,'input_digest':shot.digest(identity),'result_path':str(self.root/'result.json'),'request_route':{'reasoning_effort':'max'}}
  self.clip={'source_id':'source-A','start':0,'end':1,'precision':'sampled_frames','evidence_ids':['f0','f2']}
  self.value={'review_id':'review-A','input_digest':self.task['input_digest'],'observed_frame_ids':['f0','f1','f2'],'topic_status':{k:'uncertain' for k in shot.TOPICS},'changes':[{'topic':'composition','claim_type':'visible_change','description':'Synthetic relative position difference','clip':self.clip,'confidence':'medium','limits':['Sparse samples cannot prove continuous motion'],'needs_playback':True}],'candidate_ranges':[{'clip':self.clip.copy(),'reason':'Inspect synthetic sequence','confidence':'low','limits':['Not an edit point'],'needs_playback':True}],'summary':'Synthetic fixture only; source playback required'}
 def invalid(self,value):
  with self.assertRaises((ValueError,AssertionError)):shot.validate_value(self.task,value)
 def test_valid_provenance_and_readable_report(self):
  task=self.root/'task.json';task.write_text(json.dumps(self.task));result=Path(self.task['result_path']);result.write_text(json.dumps(self.value))
  a=shot.validate(task);self.assertEqual(a,shot.validate(task))
  out=self.root/'report.md';shot.report(a['accepted_path'],out);text=out.read_text(encoding='utf-8');self.assertIn('00:00:01.000',text);self.assertIn('source.mp4',text)
 def test_new_max_facts_cannot_extrapolate_past_their_own_frame_envelope(self):
  v=copy.deepcopy(self.value);observation={'source_id':'source-A','start':0,'end':0,'description':'Synthetic visible point','evidence_ids':['f0']};v['observations']=[observation]
  self.assertEqual(shot.validate_value(self.task,v)['observations'][0]['end'],0)
  for field,value in [('end',7),('start',-1),('end',float('inf')),('start',float('nan')),('description','   '),('source_id','other'),('evidence_ids',['f0','f0']),('evidence_ids',['missing'])]:
   bad=copy.deepcopy(v);bad['observations'][0][field]=value;self.invalid(bad)
  v['observations'][0].update(end=1,evidence_ids=['f0','f2']);self.assertEqual(shot.validate_value(self.task,v)['observations'][0]['end'],1)
 def test_adjacent_pair_facts_use_existing_schema_and_static_import_contract(self):
  from vlog_index import analysis
  self.task['input'].update(requires_facts=True,core_frame_ids=['f0','f1','f2']);self.task['input_digest']=shot.digest(self.task['input']);v=copy.deepcopy(self.value);v['input_digest']=self.task['input_digest'];v['observations']=[{'source_id':'source-A','start':0,'end':0,'description':'Visible baseline','evidence_ids':['f0']},{'source_id':'source-A','start':0,'end':0.5,'description':'Adjacent displayed comparison: no clear change in the tracked reference','evidence_ids':['f0','f1']},{'source_id':'source-A','start':0.5,'end':1,'description':'Adjacent displayed comparison: visible position difference; cause unknown','evidence_ids':['f1','f2']}]
  checked=shot.validate_value(self.task,v);package={'package_id':'pair-fixture','source':{'id':'source-A','duration':2},'core_frame_ids':['f0','f1','f2'],'frames':self.task['input']['frames'],'transcripts':[],'gps':[]};facts={'package_id':package['package_id'],'analysed_frame_ids':checked['observed_frame_ids'],'observations':checked['observations'],'events':[],'interest_points':[],'supplemental_requests':[],'summary':checked['summary']}
  self.assertEqual(analysis.validate_result(package,facts)['observations'],checked['observations'])
 def test_missing_observed_image_rejected(self):
  v=copy.deepcopy(self.value);v['observed_frame_ids'].pop();self.invalid(v)
 def test_duplicate_observed_image_rejected(self):
  v=copy.deepcopy(self.value);v['observed_frame_ids'].append('f0');self.invalid(v)
 def test_cross_source_rejected(self):
  v=copy.deepcopy(self.value);v['changes'][0]['clip']['source_id']='source-B';self.invalid(v)
 def test_unknown_evidence_rejected(self):
  v=copy.deepcopy(self.value);v['changes'][0]['clip']['evidence_ids']=['f0','missing'];self.invalid(v)
 def test_duplicate_evidence_cannot_fake_two_frames(self):
  v=copy.deepcopy(self.value);v['changes'][0]['clip']['evidence_ids']=['f0','f0'];self.invalid(v)
 def test_single_frame_dynamic_claim_rejected(self):
  v=copy.deepcopy(self.value);v['changes'][0]['clip']['evidence_ids']=['f0'];self.invalid(v)
 def test_candidate_outside_displayed_range_rejected(self):
  v=copy.deepcopy(self.value);v['candidate_ranges'][0]['clip']['end']=1.1;self.invalid(v)
 def test_frame_outside_claim_interval_rejected(self):
  v=copy.deepcopy(self.value);v['changes'][0]['clip']['end']=0.5;self.invalid(v)
 def test_unordered_evidence_rejected(self):
  v=copy.deepcopy(self.value);v['changes'][0]['clip']['evidence_ids']=['f2','f0'];self.invalid(v)
 def test_unassessed_not_silently_a_negative(self):
  v=copy.deepcopy(self.value);v['topic_status']['composition']='not_assessed';self.invalid(v)
  v['changes']=[];v['candidate_ranges']=[];r=shot.validate_value(self.task,v);self.assertEqual(r['topic_status']['composition'],'not_assessed')
 def test_missing_topic_and_false_playback_claim_rejected(self):
  v=copy.deepcopy(self.value);v['topic_status'].pop('lighting');self.invalid(v)
  v=copy.deepcopy(self.value);v['changes'][0]['needs_playback']=False;self.invalid(v)
 def test_changed_preview_or_frame_rejected(self):
  self.task['input']['preview']['status']='changed';self.invalid(self.value)
  self.task['input']['preview']['status']='unspecified';Path(self.task['input']['frames'][0]['path']).write_bytes(b'changed');self.invalid(self.value)
 def test_nan_rejected(self):
  v=copy.deepcopy(self.value);v['candidate_ranges'][0]['clip']['end']=float('nan');self.invalid(v)
 def test_error_never_overwrites_accepted_record(self):
  task=self.root/'task.json';task.write_text(json.dumps(self.task));result=Path(self.task['result_path']);result.write_text(json.dumps(self.value));a=shot.validate(task);old=Path(a['accepted_path']).read_bytes()
  v=copy.deepcopy(self.value);v['summary']='Different but structurally valid';result.write_text(json.dumps(v))
  with self.assertRaises(ValueError):shot.validate(task)
  self.assertEqual(old,Path(a['accepted_path']).read_bytes())
  v['observed_frame_ids']=[];result.write_text(json.dumps(v))
  with self.assertRaises(ValueError):shot.validate(task)
  self.assertEqual(old,Path(a['accepted_path']).read_bytes())
 def test_pilot_occlusion_claim_cannot_borrow_unreferenced_early_observed_frame(self):
  # Real pilot single03 failure times; synthetic IDs/files keep media private.
  times=[70.003267,74.507767,77.9779]
  for f,t in zip(self.task['input']['frames'],times):f['time']=t
  self.task['input']['interval']={'start':70,'end':78};self.task['input_digest']=shot.digest(self.task['input'])
  v=copy.deepcopy(self.value);v['input_digest']=self.task['input_digest']
  for c in [v['changes'][0],v['candidate_ranges'][0]]:c['clip'].update(start=times[0],end=times[-1])
  v['changes'][0]['clip']['evidence_ids']=['f1','f2']
  self.invalid(v)
  # Preserve the original full observed list; only this claim's own envelope changes.
  v['changes'][0]['clip']['start']=times[1]
  self.assertEqual(shot.validate_value(self.task,v)['changes'][0]['clip']['start'],times[1])
 def test_report_rechecks_entire_record_and_external_task_result_without_overwriting(self):
  task=self.root/'task.json';task.write_text(json.dumps(self.task));raw=Path(self.task['result_path']);raw.write_text(json.dumps(self.value));accepted=Path(shot.validate(task)['accepted_path'])
  record=json.loads(accepted.read_bytes());record['result']['observed_frame_ids']=[];record['result_sha256']='0'*64;edited=self.root/'edited.json';edited.write_text(json.dumps(record));report=self.root/'report.md';report.write_text('Existing report')
  with self.assertRaises(ValueError):shot.report(edited,report)
  self.assertEqual(report.read_text(),'Existing report')
  invalid=copy.deepcopy(self.value);invalid['changes'][0]['clip']['source_id']='different';raw.write_text(json.dumps(invalid))
  with self.assertRaises(ValueError):shot.report(accepted,report)
  self.assertEqual(report.read_text(),'Existing report')
 def test_observed_order_is_the_supplied_time_order(self):
  v=copy.deepcopy(self.value);v['observed_frame_ids'].reverse();self.invalid(v)
 def test_real_synthetic_extraction_binds_high_max_input_and_preserves_original(self):
  ff=os.environ.get('VLOG_TEST_FFMPEG')
  if not ff:self.skipTest('Explicit synthetic FFmpeg required')
  raw=self.root/'raw';raw.mkdir();video=raw/'synthetic.mp4'
  subprocess.run([ff,'-hide_banner','-loglevel','error','-f','lavfi','-i','testsrc2=size=160x90:rate=25:duration=3','-c:v','libx264','-an',str(video)],check=True,capture_output=True)
  st=video.stat();s={'id':'synthetic-A','path':str(video),'relative_path':video.name,'size':st.st_size,'mtime_ns':st.st_mtime_ns,'sidecars':[],'duration':3.0,'fps':25,'start_pts':0,'status':'ready','metadata':{},'color':{}}
  manifest=self.root/'manifest.json';manifest.write_text(json.dumps({'sources':[s],'config':{}}));old=manifest.read_bytes();video_hash=shot.file_hash(video)
  out=self.root/'cache';rec=shot.prepare(manifest,s['id'],0.2,2.2,9,out,ff,('max','high'))
  one,two=[json.loads(Path(p).read_bytes()) for p in rec['task_paths']]
  self.assertEqual(one['input']['instructions'],shot.INSTRUCTIONS);self.assertEqual(one['input']['prompt_version'],shot.VERSION);self.assertEqual(one['input'],two['input']);self.assertEqual(one['input_digest'],two['input_digest']);self.assertNotEqual(one['result_path'],two['result_path']);self.assertEqual(len(one['input']['frames']),9);self.assertEqual(one['input']['frames'][0]['boundary'],'start');self.assertEqual(one['input']['frames'][-1]['boundary'],'end')
  self.assertEqual(old,manifest.read_bytes());self.assertEqual(video_hash,shot.file_hash(video));self.assertEqual(one['input']['preview']['status'],'unspecified')
  with self.assertRaises(ValueError):shot.prepare(manifest,s['id'],0.2,2.2,9,out,ff)
if __name__=='__main__':unittest.main()
