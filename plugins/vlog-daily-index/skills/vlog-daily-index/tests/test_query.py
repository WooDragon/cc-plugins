"""Real DuckDB queries over synthetic published bytes and DIT tool output."""
import copy
import csv
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SKILL = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(SKILL/'scripts'))
from vlog_index.store import PUBLICATION_NAMES, digest, dump, file_hash, publication_snapshot
import query_index as query

try:
    import duckdb
except ImportError:
    duckdb = None


def publish(day, title='Waterfall', revision=1):
    day.mkdir(parents=True,exist_ok=True)
    common = dict(generator='vlog-daily-index',schema_version='1',run_id='same-local-run',revision=revision,
                  status='complete',itinerary_sha256='route',geography_sha256='geo')
    clip = dict(source_id='s',start=1,end=3,precision='sampled_frames',evidence_ids=['f1'])
    finding = dict(title=title,reason='Watching the river',clips=[clip,{**clip,'source_id':'unmatched','start':5,'end':7}])
    geo = {'finding_key':f'event:01:{digest(finding)[:16]}','status':'approximate','place_name':'Candidate valley',
           'subject_kind':'visible_subject','reason':'Map evidence','evidence_refs':['map-1']}
    transcript = {**common,'sources':{'s':{'segments':[dict(id='t1',source_id='s',start=0,end=30,precision='chunk',text='Hello river')]}}}
    dump(day/PUBLICATION_NAMES[0],transcript)
    index = {**common,'archival_date':'2030-01-02','sources':[
        dict(id='s',relative_path='clip.mp4',path='Z:/obsolete/clip.mp4',status='ready'),
        dict(id='unmatched',relative_path='unmatched.mp4',path='Z:/obsolete/unmatched.mp4',status='failed')],
        'events':[finding],'interest_points':[],'geography':{'associations':[geo]},
        'transcript_sha256':file_hash(day/PUBLICATION_NAMES[0])}
    dump(day/PUBLICATION_NAMES[1],index)
    (day/PUBLICATION_NAMES[2]).write_text(f'<!-- generator:vlog-daily-index; run_id:{common["run_id"]}; revision:{revision} -->\n{file_hash(day/PUBLICATION_NAMES[1])}\n',encoding='utf-8')


def dit_csv(path, rows):
    buffer = io.StringIO(newline=''); writer = csv.DictWriter(buffer,fieldnames=query.NAMING_INDEX_COLUMNS)
    writer.writeheader(); writer.writerows(rows); path.write_bytes(buffer.getvalue().encode('utf-8-sig'))


def row(relative, name, status='正常', notes=''):
    return dict(zip(query.NAMING_INDEX_COLUMNS,[relative,name,'卡:DCIM/'+name,'0','','仅改名及长度核对',status,'','',notes]))


@unittest.skipUnless(duckdb,'Install requirements-query.txt for real DuckDB regression')
class QueryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)/'library'; self.root.mkdir()
        self.day = self.root/'2030'/'day'; publish(self.day)
        self.csv = self.root/'index.csv'
        dit_csv(self.csv,[row('2030/day/clip.mp4','camera.mp4'),row('unanalysed.mp4','other.mp4',notes='Snow ridge'),row('','removed.mp4','已移除')])
        self.config = {'schema':1,'libraries':[{'root':str(self.root),'index':'index.csv','publications':['2030/day']}]}
        self.dbfile = Path(self.temp.name)/'cache.duckdb'; self.db = query.connect(self.dbfile)
    def tearDown(self):
        self.db.close(); self.temp.cleanup()
    def refresh(self):
        results = query.refresh(self.db,self.config)
        self.assertFalse(any(r['stale'] for r in results),results)
        return results
    def test_multi_clip_transcript_unanalysed_unmatched_and_deleted(self):
        self.refresh()
        results = query.search(self.db,'Waterfall')
        self.assertEqual(len(results),2)
        self.assertEqual([(r['start_s'],r['end_s']) for r in results],[(1,3),(5,7)])
        self.assertEqual(results[0]['geography']['status'],'approximate')
        self.assertEqual(results[0]['evidence'],['f1'])
        self.assertEqual(results[0]['original_path'],str(self.root)+'/2030/day/clip.mp4')
        self.assertNotIn('Z:',json.dumps(results))
        self.assertEqual(results[0]['publication'],str(self.day))
        self.assertEqual(results[0]['dit_index'],str(self.csv))
        self.assertEqual(len(query.search(self.db,'已移除')),1)
        self.assertEqual(len(query.search(self.db,'Snow ridge')),1)
        self.assertEqual(query.search(self.db,'removed.mp4')[0]['original_path'],None)
        self.assertEqual(len(query.search(self.db,status='已移除')),1)
        transcript = query.search(self.db,'Hello')[0]
        self.assertEqual((transcript['start_s'],transcript['end_s'],transcript['precision']),(0,30,'chunk'))
        self.assertEqual(self.db.execute('SELECT count(*) FROM media').fetchone()[0],4)
    def test_refresh_bytes_not_mtime_repeat_revision_and_rebuild(self):
        self.refresh(); self.assertTrue(all(not r['changed'] for r in self.refresh()))
        previous = (self.day/PUBLICATION_NAMES[1]).stat()
        publish(self.day,'Mountain!',2)
        os.utime(self.day/PUBLICATION_NAMES[1],ns=(previous.st_atime_ns,previous.st_mtime_ns))
        self.refresh(); self.assertFalse(query.search(self.db,'Waterfall')); self.assertEqual(len(query.search(self.db,'Mountain!')),2)
        self.assertEqual(self.db.execute('SELECT count(*) FROM clips').fetchone()[0],2)
        self.db.close(); self.dbfile.unlink(); self.db = query.connect(self.dbfile)
        self.refresh(); self.assertEqual(len(query.search(self.db,'Mountain!')),2)
    def test_half_publish_unknown_schema_and_offline_keep_old(self):
        self.refresh(); before = self.db.execute("SELECT last_success FROM snapshots WHERE kind='publication'").fetchone()
        broken = json.loads((self.day/PUBLICATION_NAMES[1]).read_text(encoding='utf-8'))
        broken['events'][0]['title']='Half written'; dump(self.day/PUBLICATION_NAMES[1],broken)
        results = query.refresh(self.db,self.config); self.assertTrue(any(r['stale'] for r in results))
        self.assertEqual(len(query.search(self.db,'Waterfall')),2); self.assertTrue(query.search(self.db,'Waterfall')[0]['stale'])
        self.assertEqual(self.db.execute("SELECT last_success FROM snapshots WHERE kind='publication'").fetchone(),before)
        publish(self.day); self.refresh()
        offline = self.root.with_name('offline'); self.root.rename(offline)
        try:
            self.assertTrue(all(r['stale'] for r in query.refresh(self.db,self.config)))
            self.assertEqual(len(query.search(self.db,'Waterfall')),2)
        finally: offline.rename(self.root)
        self.csv.write_text('unknown,columns\n',encoding='utf-8-sig')
        self.assertTrue(query.refresh(self.db,self.config)[0]['stale'])
        self.assertEqual(len(query.search(self.db,'Snow ridge')),1)
    def test_directory_labels_preserve_legitimate_history_theme(self):
        formal='20300102_示例区域_历史博物馆-游览'
        publish(self.root/'2030'/formal,'Museum visit')
        library=self.config['libraries'][0]
        library['publications']=['2030/'+formal]
        self.refresh()
        self.assertEqual(len(query.search(self.db,'Museum visit')),2)
        for label in ('历史博物馆','临时停靠','备份知识展览'):
            self.assertFalse(query.excluded(Path('2030')/('20300102_区域_'+label)))
        for label in ('备份','修订3','_revisions','day_backup','历史备份','day_修订_3'):
            with self.subTest(label=label):
                publish(self.root/'2030'/label,'Hidden copy')
                explicit=copy.deepcopy(self.config)
                explicit['libraries'][0]['publications']=['2030/'+label]
                with self.assertRaises(ValueError): query.configured_units(explicit)
        library.pop('publications');library['publication_globs']=['2030/*']
        self.refresh()
        self.assertEqual(len(query.search(self.db,'Museum visit')),2)
        self.assertEqual(query.search(self.db,'Hidden copy'),[])

    def test_windows_analysis_relative_path_joins_nested_dit_path(self):
        path=self.day/PUBLICATION_NAMES[1]
        index=json.loads(path.read_text(encoding='utf-8'))
        index['sources'][0]['relative_path']='nested\\clip.mp4'
        old=file_hash(path);dump(path,index)
        marker=self.day/PUBLICATION_NAMES[2]
        marker.write_text(marker.read_text(encoding='utf-8').replace(old,file_hash(path)),encoding='utf-8')
        dit_csv(self.csv,[row('2030/day/nested/clip.mp4','nested-original.mp4')])
        self.refresh()
        result=query.search(self.db,'Waterfall')[0]
        self.assertEqual(result['relative_path'],'2030/day/nested/clip.mp4')
        self.assertEqual(result['dit_index'],str(self.csv))
        self.assertEqual(self.db.execute("SELECT original_name FROM media WHERE source_id='s'").fetchone()[0],'nested-original.mp4')

    def test_invalid_revision_preserves_old_and_processes_later_units(self):
        self.refresh()
        later=self.root/'2030'/'later';publish(later,'Valid later')
        self.config['libraries'][0]['publications'].append('2030/later')
        publish(self.day,'Invalid revision','wrong')
        results=query.refresh(self.db,self.config)
        self.assertTrue(results[1]['stale']);self.assertFalse(results[2]['stale'])
        self.assertTrue(query.search(self.db,'Waterfall')[0]['stale'])
        self.assertEqual(len(query.search(self.db,'Valid later')),2)

    def test_paths_conflicting_scope_and_sql_parameters(self):
        self.refresh()
        self.assertEqual(query.search(self.db,"' OR 1=1 --"),[])
        for value in ('../outside','/absolute','C:/drive','bad\\path','a/./b','a//b'):
            with self.subTest(value=value),self.assertRaises(ValueError): query.within(self.root,value)
        other = self.root/'2030'/'another'; publish(other,'Second day')
        self.config['libraries'][0]['publications'].append('2030/another')
        self.refresh(); self.assertEqual(len(query.search(self.db,kind='event')),4)
        self.assertEqual(self.db.execute('SELECT count(distinct scope) FROM findings').fetchone()[0],2)
    def test_bounded_discovery_retains_disappeared_and_finds_new(self):
        lib=self.config['libraries'][0]; lib.pop('publications'); lib['publication_globs']=['2030/*']
        publish(self.root/'2030'/'backup'/'day','Hidden backup')
        self.refresh(); self.assertEqual(len(query.search(self.db,'Waterfall')),2)
        publish(self.root/'2030'/'later','New day'); self.refresh()
        self.assertEqual(len(query.search(self.db,'New day')),2)
        off=self.day.with_name('temp-offline'); self.day.rename(off)
        results=query.refresh(self.db,self.config)
        self.assertTrue(any(r['stale'] for r in results)); self.assertEqual(len(query.search(self.db,'Waterfall')),2)
        lib['publication_globs']=['**/day']
        with self.assertRaises(ValueError): query.refresh(self.db,self.config)
    def test_commit_marker_changes_and_unknown_publication_schema_rejected(self):
        original=Path.read_bytes; count=0
        def racing(path):
            nonlocal count
            value=original(path)
            if path==self.day/PUBLICATION_NAMES[2]:
                count+=1
                if count==2: return value+b'changed'
            return value
        with patch.object(Path,'read_bytes',racing),self.assertRaises(ValueError): publication_snapshot(self.day)
        index=json.loads((self.day/PUBLICATION_NAMES[1]).read_text(encoding='utf-8'));index['schema_version']='unknown'
        dump(self.day/PUBLICATION_NAMES[1],index)
        with self.assertRaises(ValueError): publication_snapshot(self.day)
    def test_query_is_independent_of_analysis_dependencies(self):
        config=Path(self.temp.name)/'config.json';dump(config,self.config)
        # -S removes all site packages, then expose only DuckDB; analysis imports fail explicitly.
        code = '''import importlib.abc,sys,runpy
class Block(importlib.abc.MetaPathFinder):
 def find_spec(self,name,path=None,target=None):
  if name.split('.')[0] in ('pydantic','httpx','PIL') or name in ('vlog_index.analysis','vlog_index.media'): raise RuntimeError('analysis dependency imported: '+name)
sys.meta_path.insert(0,Block());sys.path[:0]=sys.argv[1:3];sys.argv=sys.argv[3:];runpy.run_path(sys.argv[0],run_name='__main__')'''
        for arguments in (['--help'],['refresh','--db',str(Path(self.temp.name)/'isolated.duckdb'),'--config',str(config)]):
            result=subprocess.run([sys.executable,'-S','-X','utf8','-c',code,str(SKILL/'scripts'),str(Path(duckdb.__file__).parent.parent),str(SKILL/'scripts'/'query_index.py'),*arguments],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stderr)
    def test_dit_tool_generated_csv_roundtrip(self):
        tool = SKILL.parents[2]/'dit-media'/'skills'/'dit-media'/'scripts'/'dit_tools.py'
        if not tool.is_file(): self.skipTest('Cross-plugin DIT tool available in repository checkout only')
        spec=importlib.util.spec_from_file_location('dit_fixture_tool',tool);dit=importlib.util.module_from_spec(spec);spec.loader.exec_module(dit)
        media=self.root/'tool.mp4';media.write_bytes(b'')
        original=dit.read_csv(self.csv.read_bytes()); added=row('tool.mp4','tool.mp4',notes='Generated by DIT tool')
        plan=dit.make_plan(self.root,self.csv,[{'before':None,'after':added}]);dit.apply_plan(plan)
        self.refresh(); self.assertEqual(len(query.search(self.db,'Generated by DIT tool')),1)
        self.assertEqual(len(dit.read_csv(self.csv.read_bytes())),len(original)+1)


if __name__=='__main__': unittest.main()
