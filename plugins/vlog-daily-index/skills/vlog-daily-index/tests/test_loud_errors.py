"""Loud failures: missing frame rate, unreadable init sources, paused_error exit status."""
import contextlib, io, json, subprocess, sys, tempfile, unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import vlog_daily_index as cli
from vlog_index import media
from vlog_index.store import dump, read


class MissingFrameRate(unittest.TestCase):
    def test_zero_rates_fail_probe_without_25fps_fallback(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'no-fps.mp4'; path.write_bytes(b'synthetic')
            raw={'streams':[{'codec_type':'video','avg_frame_rate':'0/0','r_frame_rate':'0/0','duration':'1'}],'format':{'duration':'1'}}
            completed=subprocess.CompletedProcess(args=[],returncode=0,stdout=json.dumps(raw),stderr='')
            with patch.object(media,'command',return_value=completed):
                result=media.probe(path,'ffprobe',Path(td))
        self.assertEqual(result['status'],'failed')
        self.assertIn('frame rate',result['error'])

    def test_nominal_rate_is_used_when_average_is_zero(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'fallback.mp4'; path.write_bytes(b'synthetic')
            raw={'streams':[{'codec_type':'video','avg_frame_rate':'0/0','r_frame_rate':'30000/1001','duration':'1'}],'format':{'duration':'1'}}
            completed=subprocess.CompletedProcess(args=[],returncode=0,stdout=json.dumps(raw),stderr='')
            with patch.object(media,'command',return_value=completed):
                result=media.probe(path,'ffprobe',Path(td))
        self.assertEqual(result['status'],'ready')
        self.assertAlmostEqual(result['fps'],30000/1001,places=4)

    def test_zero_duration_fails_probe(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'zero-duration.mp4'; path.write_bytes(b'synthetic')
            raw={'streams':[{'codec_type':'video','avg_frame_rate':'30000/1001','r_frame_rate':'30000/1001','duration':'0'}],'format':{'duration':'0'}}
            completed=subprocess.CompletedProcess(args=[],returncode=0,stdout=json.dumps(raw),stderr='')
            with patch.object(media,'command',return_value=completed):
                result=media.probe(path,'ffprobe',Path(td))
        self.assertEqual(result['status'],'failed')
        self.assertIn('non-positive duration',result['error'])


class UnreadableInit(unittest.TestCase):
    def test_all_sources_failed_raises_runtime_error_listing_each(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); source=root/'source'; source.mkdir()
            (source/'a.mp4').write_bytes(b'a'); (source/'b.mov').write_bytes(b'b')
            args=Namespace(source=str(source),state=str(root/'state'),temp=str(root/'temp'),run_id=None,date='2030-01-02',ffmpeg='ffmpeg',ffprobe='ffprobe',service='http://example.test:80',vision_concurrency=6,host='codex',asr_model='synthetic',preview_lut_map=None)
            def failed(path,ffprobe,source_root):
                name=Path(path).name
                return {'relative_path':name,'status':'failed','error':'unreadable '+name}
            with patch.object(media,'probe',side_effect=failed):
                with self.assertRaises(RuntimeError) as caught: cli.init(args)
        message=str(caught.exception)
        self.assertIn('No readable sources',message)
        self.assertIn('a.mp4',message); self.assertIn('unreadable a.mp4',message)
        self.assertIn('unreadable b.mov',message)
        self.assertIn('state='+str(root/'state'),message)
        self.assertIn('remove this state before re-init',message)

    def test_empty_source_raises_runtime_error_naming_source(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); source=root/'source'; source.mkdir()
            args=Namespace(source=str(source),state=str(root/'state'),temp=str(root/'temp'),run_id=None,date='2030-01-02',ffmpeg='ffmpeg',ffprobe='ffprobe',service='http://example.test:80',vision_concurrency=6,host='codex',asr_model='synthetic',preview_lut_map=None)
            with self.assertRaises(RuntimeError) as caught: cli.init(args)
        message=str(caught.exception)
        self.assertIn('No source media',message)
        self.assertIn(str(source),message)
        self.assertIn('check the source path or mount',message)


class PausedErrorExit(unittest.TestCase):
    def run_cli(self, argv):
        output=io.StringIO()
        with patch.object(sys,'argv',argv), contextlib.redirect_stdout(output): cli.main()
        return output.getvalue()

    def test_status_reports_paused_error_and_exits_zero(self):
        with tempfile.TemporaryDirectory() as td:
            state=Path(td)/'state'; state.mkdir(); dump(state/'manifest.json',{'status':'paused_error'})
            with patch.object(cli,'load',lambda a:{'status':'paused_error'}), patch.object(cli.report,'coverage',lambda manifest:{'status':manifest['status']}):
                output=self.run_cli(['vlog_daily_index.py','status','--state',str(state)])
        self.assertIn('paused_error',output)

    def test_other_action_prints_result_then_exits_two(self):
        with tempfile.TemporaryDirectory() as td:
            state=Path(td)/'state'; state.mkdir(); dump(state/'manifest.json',{'status':'paused_error'})
            output=io.StringIO()
            argv=['vlog_daily_index.py','subject-targets','--state',str(state)]
            with patch.object(sys,'argv',argv), patch.object(cli,'subject_targets',lambda a:{'stub':'result'}), contextlib.redirect_stdout(output):
                with self.assertRaises(SystemExit) as caught: cli.main()
            self.assertEqual(caught.exception.code,2)
            self.assertIn('"stub"',output.getvalue())

    def test_running_manifest_does_not_exit(self):
        with tempfile.TemporaryDirectory() as td:
            state=Path(td)/'state'; state.mkdir(); dump(state/'manifest.json',{'status':'running'})
            argv=['vlog_daily_index.py','subject-targets','--state',str(state)]
            with patch.object(cli,'subject_targets',lambda a:{'stub':'result'}):
                self.assertIn('"stub"',self.run_cli(argv))


class PausedErrorRecovery(unittest.TestCase):
    def test_serial_continue_clears_paused_error_after_preflight(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); state=root/'state'; state.mkdir()
            protocol=root/'protocol.json'; dump(protocol,{'final_event':'done','text_field':'text'})
            itinerary={'title':'Synthetic fixture route','source_refs':[{'id':'s','kind':'local','reference':'synthetic-fixture','excerpt':'Fixture route'}],'entries':[{'id':'r','place':'Fixture region','source_refs':['s']}]}
            dump(state/'manifest.json',{'state_dir':str(state),'status':'paused_error','sources':[],'transcription':{},'frames':[],'temporary_artifacts':[],'config':{'asr_service':'http://example.test:80','asr_model':'synthetic'},'itinerary':{'data':itinerary}})
            class FakeState:
                def __init__(self,root): pass
                def close(self): pass
            class FakeClient:
                def __init__(self,*args,**kwargs): pass
                def preflight(self): pass
            args=Namespace(state=str(state),protocol=str(protocol),gps=None,garmin_companion=None)
            with patch.object(cli,'State',FakeState), patch.object(cli.asr,'ASRClient',FakeClient), patch.object(cli.report,'coverage',lambda m:{'status':m['status']}):
                result=cli._continue_day_serial(args)
            self.assertEqual(result['status'],'running')
            self.assertEqual(read(state/'manifest.json')['status'],'running')


if __name__=='__main__': unittest.main()
