import copy
import datetime as dt
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'LMCost'))
import engine
import codex_hook


def payload(**kw):
    p=dict(hook_event_name='PostModelRequest',model='gpt-5.4-mini',status='completed',error=None,
           response_id=None,thread_id='synthetic-thread',request_id='synthetic-generation',
           attempt_number=1,turn_id='same-turn',session_id='DO-NOT-SAVE-SESSION',
           transcript_path='/DO-NOT-READ/private-session',cwd='/DO-NOT-SAVE-project',kind='sampling',
           token_usage={'input_tokens':12000,'cached_input_tokens':4000,'output_tokens':2000,
                        'reasoning_output_tokens':1000,'total_tokens':14000},
           prompt='DO-NOT-SAVE-PROMPT',account='DO-NOT-SAVE-ACCOUNT')
    p.update(kw);return p

class CodexProjection(unittest.TestCase):
    def test_no_ttl_requirement_for_no_write_price_models(self):
        for model in ('gpt-5.4-mini','gpt-5.4-mini-2026-03-17','gpt-5.3-codex'):
            e=engine.codex_event(payload(model=model))
            self.assertEqual(e['issue'],'');self.assertEqual(e['input'],8000)
            self.assertIsNone(e['write_short']);self.assertIsNone(e['write_long'])
            # The hook itself cannot prove tier. Only this synthetic test supplies it.
            self.assertIn('档位',engine.price(e)[1]);e['speed']='normal'
            expected=.0153 if model.startswith('gpt-5.4') else .0427
            self.assertAlmostEqual(engine.price(e)[0],expected)
    def test_reasoning_is_subset(self):
        a=engine.codex_event(payload());a['speed']='normal'
        p=payload();p['token_usage']['reasoning_output_tokens']=0
        b=engine.codex_event(p);b['speed']='normal'
        self.assertEqual(engine.price(a),engine.price(b))
    def test_charged_write_requires_ttl_only_when_nonzero(self):
        p=payload(model='gpt-6.1-terra');p['token_usage']['cache_write_input_tokens']=2000
        e=engine.codex_event(p);self.assertIn('TTL',e['issue']);self.assertIsNone(engine.price(e)[0])
        p['token_usage']['cache_write_input_tokens']=0
        e=engine.codex_event(p);self.assertEqual(e['issue'],'')
        e.update(speed='normal',context='short')
        self.assertAlmostEqual(engine.price(e)[0],.0182)
    def test_identity_distinguishes_requests_and_retries(self):
        base=engine.codex_event(payload())
        self.assertEqual(base['id'],engine.codex_event(payload())['id'])
        self.assertNotEqual(base['id'],engine.codex_event(payload(attempt_number=2))['id'])
        self.assertNotEqual(base['id'],engine.codex_event(payload(request_id='second-generation'))['id'])
        for status in ('failed','cancelled'):
            self.assertEqual(engine.codex_event(payload(status=status))['id'],base['id'])
    def test_response_dedup_even_if_attempt_changes(self):
        a=engine.codex_event(payload(response_id='synthetic-response'))
        b=engine.codex_event(payload(response_id='synthetic-response',attempt_number=2))
        self.assertEqual(a['id'],b['id'])
    def test_old_schema_missing_identity_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'missing_attempt_identity'):
            engine.codex_event(payload(request_id=None,thread_id=None,attempt_number=None))
    def test_missing_usage_invalid_counts_and_no_content(self):
        self.assertIsNone(engine.price(engine.codex_event(payload(token_usage=None)))[0])
        p=payload();p['token_usage']['cached_input_tokens']=13000
        self.assertIsNone(engine.price(engine.codex_event(p))[0])
        e=engine.codex_event(payload())
        for forbidden in ('DO-NOT','same-turn','synthetic-thread','synthetic-generation','transcript_path','cwd'):
            self.assertNotIn(forbidden,json.dumps(e))
    def test_receipt_time_month_is_explicit(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(d);app.mode='live';app.settings['timezone']='UTC'
            a=engine.codex_event(payload(),received='2026-10-31T23:59:59Z')
            b=engine.codex_event(payload(attempt_number=2),received='2026-11-01T00:00:00Z')
            self.assertEqual(a['time_basis'],'hook_received')
            app.live.add(a);app.live.add(b)
            self.assertEqual(app.snapshot({'month':'2026-10'})['count'],1)
            self.assertEqual(app.snapshot({'month':'2026-11'})['count'],1)
            app.close()

class CodexReceiver(unittest.TestCase):
    def test_default_closed_without_reading_stdin(self):
        class Forbidden:
            def read(self,*a):raise AssertionError('must not read before consent')
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(codex_hook.receive(Path(d),Forbidden()),'disabled')
            self.assertFalse((Path(d)/'usage.sqlite3').exists())
    def test_expired_lease(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'codex-consent.json').write_text(json.dumps({'expires':time.time()-1}))
            self.assertEqual(codex_hook.receive(p,io.BytesIO(b'bad')),'disabled')
    def test_subprocess_restart_dedup_retries_and_rejection(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(d);app.command({'action':'enable-codex'})
            script=Path(codex_hook.__file__)
            for p in [payload(),payload(),payload(attempt_number=2),payload(request_id=None,attempt_number=None)]:
                run=subprocess.run([sys.executable,'-B',str(script),'--data',d],input=json.dumps(p),text=True,capture_output=True,timeout=3)
                self.assertEqual(run.returncode,0);self.assertEqual(run.stdout.strip(),'{}');self.assertEqual(run.stderr,'')
            snapshot=app.snapshot({})
            self.assertEqual(snapshot['codex_count'],2)
            self.assertEqual(snapshot['codex_rejected'],1)
            self.assertEqual(snapshot['count'],2);self.assertEqual(snapshot['unpriced'],2)
            self.assertNotIn(b'DO-NOT-SAVE',(Path(d)/'usage.sqlite3').read_bytes())
            app.close();self.assertFalse((Path(d)/'codex-consent.json').exists())
            restarted=engine.Engine(d)
            self.assertFalse(restarted.codex_enabled);self.assertEqual(len(restarted.live.events()),2)
            restarted.close()
    def test_prepare_is_inactive_and_simulation_never_writes_real_ledger(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(d)
            folder=Path(app.prepare_codex());self.assertTrue((folder/'hooks.fragment.json').is_file())
            self.assertFalse(app.codex_enabled);self.assertFalse((Path(d)/'codex-consent.json').exists())
            self.assertFalse((Path(d)/'.codex').exists())
            before=len(app.demo)
            for _ in range(2):app.command({'action':'demo-codex-hook'})
            self.assertEqual(len(app.demo),before+1);self.assertEqual(app.live.events(),[])
            app.close()

if __name__=='__main__':unittest.main(verbosity=2)
