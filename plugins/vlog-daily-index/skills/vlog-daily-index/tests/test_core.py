"""Small tests of meaningful correctness boundaries; no remote media or ASR."""
import json, os, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import httpx
from vlog_index import asr,media,analysis,report
from vlog_index.store import dump,read,cleanup_registered
from fixture_helpers import final_context, root_review

class CoreBoundaries(unittest.TestCase):
    def test_tail_and_short_plan(self):
        short=media.sample_times(2,25)
        self.assertEqual(len(short),3); self.assertEqual(short[0],0); self.assertGreater(short[-1],1.9)
        times=media.sample_times(610.1,25)
        blocks=media.blocks_for(times,610.1)
        self.assertEqual([t for b in blocks for t in b['samples']],times)
        self.assertEqual(blocks[-1]['end'],610.1)

    def test_real_httpx_disconnect_is_durable_unknown(self):
        with tempfile.TemporaryDirectory() as td, patch.dict(os.environ,{'LOCALAPPDATA':td}):
            wav=Path(td)/'sample.wav'; wav.write_bytes(b'fake-local-test')
            calls=[]
            def request(req):
                calls.append(req)
                return httpx.Response(200,headers={'content-type':'application/x-ndjson'},content=b'{"type":"delta","text":"partial"}\n')
            protocol={'final_event':'done','text_field':'text'}
            client=asr.ASRClient('http://example.test:80',td,protocol); client.client=httpx.Client(transport=httpx.MockTransport(request))
            with self.assertRaises(asr.UnknownServerState): client.transcribe(wav,Path(td)/'raw.json')
            other=asr.ASRClient('HTTP://EXAMPLE.TEST',td+'other',protocol); other.client=httpx.Client(transport=httpx.MockTransport(request))
            with self.assertRaises(asr.UnknownServerState): other.transcribe(wav,Path(td)/'other.json')
            self.assertEqual(len(calls),1)
            self.assertEqual(read(client.gate)['status'],'unknown')

    def test_luna_requires_all_images_and_evidence(self):
        with tempfile.TemporaryDirectory() as td:
            source={'id':'s','path':'s.mp4','relative_path':'s.mp4','duration':20,'metadata':{},'role':'camera'}
            frames=[{'id':'f0','source_id':'s','time':0,'path':'0.jpg'},{'id':'f1','source_id':'s','time':10,'path':'1.jpg'}]
            p=analysis.make_packages(source,frames,[],td)[0]; package=read(p['path'])
            result={'package_id':p['id'],'analysed_frame_ids':['f0'],'observations':[{'source_id':'s','start':0,'end':10,'description':'test','evidence_ids':['f0']}],'events':[],'interest_points':[],'supplemental_requests':[],'summary':'test'}
            with self.assertRaises(ValueError): analysis.validate_result(package,result)
            result['analysed_frame_ids']=['f0','f1']; result['observations'][0]['evidence_ids']=['f0','f1']
            self.assertEqual(analysis.validate_result(package,result)['package_id'],p['id'])

    def test_publication_identity_and_cleanup_boundary(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); run=root/'run-1'; run.mkdir(); final=root/'final'; source=root/'sources'; source.mkdir()
            m={'run_id':'run-1','sources':[],'frames':[],'packages':[],'transcription':{},'config':{'source_root':str(source),'asr_model':asr.MODEL,'date':'2030-01-02'},'temporary_artifacts':[]}
            daily=final_context(m,root/'state')
            rendered=report.render(m,[],final,daily=daily); m['status']=rendered['status']
            report.approve_final(m,final,'ROOT','Local fixture quality review passed',root_review(m,daily))
            report.publish(m,final,source); self.assertTrue(m['published_verified'])
            media_file=run/'frame.jpg'; media_file.write_bytes(b'x'); m['temporary_artifacts']=[str(media_file)]
            self.assertEqual(cleanup_registered(run,m),[str(media_file)])
            outside=root/'original.mp4'; outside.write_bytes(b'original'); m['temporary_artifacts']=[str(outside)]
            with self.assertRaises(ValueError): cleanup_registered(run,m)
            self.assertEqual(outside.read_bytes(),b'original')
            (source/report.NAMES[0]).write_text('{}',encoding='utf-8')
            with self.assertRaises((ValueError,KeyError)): report.validate_group(source)

if __name__=='__main__': unittest.main()
