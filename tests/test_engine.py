import copy
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import urllib.request
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'LMCost'))
import engine

def event(**kw):
    e=dict(id='synthetic',timestamp='2026-11-01T00:00:00+00:00',agent='Claude Code',
        model='claude-opus-5-5',input=1000,read=4000,write_short=3000,write_long=4000,
        write_total=7000,output=2000,speed='normal',context='request',issue='')
    e.update(kw); return e

def payload(**kw):
    a={'event.name':'api_request','event.timestamp':'2026-11-01T00:00:00Z',
       'model':'claude-opus-5-5','input_tokens':1000,'output_tokens':2000,
       'cache_read_tokens':4000,'cache_creation_tokens':7000,
       'cache_creation_5m_tokens':3000,'cache_creation_1h_tokens':4000,
       'request_id':'req_synthetic_one','speed':'normal',
       'user.email':'DO-NOT-SAVE@example.invalid','prompt':'DO-NOT-SAVE-PROMPT'}
    a.update(kw)
    attrs=[{'key':k,'value':{'stringValue':v} if isinstance(v,str) else {'intValue':str(v)}} for k,v in a.items() if v is not None]
    return {'resourceLogs':[{'resource':{'attributes':[{'key':'account','value':{'stringValue':'DO-NOT-SAVE-ACCOUNT'}}]},
              'scopeLogs':[{'logRecords':[{'body':{'stringValue':'claude_code.api_request'},'attributes':attrs}]}]}]}

class Pricing(unittest.TestCase):
    def test_anthropic_disjoint_and_ttls(self):
        self.assertAlmostEqual(engine.price(event())[0],0.0918)
        self.assertAlmostEqual(engine.price(event(speed='fast'))[0],0.1836)
    def test_openai_official_cache_example(self):
        # Official worked example: 12,000 inclusive input, 4,000 read,
        # 3,000 30m writes, 4,000 12h writes. Test its stated $1 / $0.10 rates.
        p={'provider':'openai','input':1,'read':0.1,'write_short':1.25,'write_long':2.5,'output':5,'context':'short'}
        with patch.dict(engine.CATALOG['models'],{'test-official-example':p}):
            e=event(agent='Codex',model='test-official-example',context='short',output=0)
            self.assertAlmostEqual(engine.price(e)[0],0.01515)
        # Actual Terra cached-read rate is $0.05, so it must differ.
        self.assertAlmostEqual(engine.price(event(agent='Codex',model='gpt-6.1-terra',context='short',output=0))[0],0.01495)
    def test_full_context_haiku_threshold(self):
        e=event(model='claude-haiku-5-5',input=1000,read=99000,write_short=0,write_long=0,output=0)
        self.assertAlmostEqual(engine.price(e)[0],0.00109)
        e['read']+=1
        self.assertAlmostEqual(engine.price(e)[0],0.00545005)
    def test_missing_unknown_fast_long(self):
        for changes in ({'input':None},{'output':-1},{'read':True},{'model':'claude-opus-5-5-new'},
                        {'speed':'unknown'},{'model':'claude-sonnet-5-5','speed':'fast'},
                        {'agent':'Codex','model':'gpt-6.1-sol','input':None}):
            self.assertIsNone(engine.price(event(**changes))[0])
    def test_openai_long_context_entire_request_and_components(self):
        e=event(agent='Codex',model='gpt-6-sol',input=2000,read=270000,write_short=0,write_long=0,write_total=0,output=1000,context='unknown')
        # The inclusive input exactly at the boundary is short; no separate context label is necessary.
        self.assertAlmostEqual(engine.price(e)[0],.068)
        e['input']+=1
        self.assertAlmostEqual(engine.price(e)[0],.131004)
        costs=engine.priced_components([e])
        self.assertAlmostEqual(costs['input'],.008004)
        self.assertAlmostEqual(costs['read'],.108)
        self.assertAlmostEqual(costs['output'],.015)
        self.assertAlmostEqual(sum(costs.values()),engine.price(e)[0])
        e['speed']='fast';self.assertAlmostEqual(engine.price(e)[0],.262008)
    def test_reasoning_never_added(self):
        a=event(); b=event(reasoning_output_tokens=1900)
        self.assertEqual(engine.price(a),engine.price(b))

class Parser(unittest.TestCase):
    def test_fields_and_privacy(self):
        e=list(engine.otlp_events(payload()))[0]
        self.assertEqual(e['input'],1000)
        self.assertEqual(e['write_short']+e['write_long'],e['write_total'])
        self.assertNotIn('DO-NOT-SAVE',json.dumps(e))
        self.assertNotIn('req_synthetic',json.dumps(e))
        self.assertAlmostEqual(engine.price(e)[0],0.0918)
    def test_missing_ttl_is_unpriced(self):
        for kwargs in ({'cache_creation_5m_tokens':None,'cache_creation_1h_tokens':None},
                       {'cache_creation_5m_tokens':0,'cache_creation_1h_tokens':0},
                       {'cache_creation_tokens':6000}):
            e=list(engine.otlp_events(payload(**kwargs)))[0]
            self.assertIsNone(engine.price(e)[0])
    def test_zero_writes_without_ttls(self):
        e=list(engine.otlp_events(payload(cache_creation_tokens=0,cache_creation_5m_tokens=None,cache_creation_1h_tokens=None)))[0]
        self.assertIsNotNone(engine.price(e)[0])
    def test_missing_speed_and_request(self):
        for kwargs in ({'speed':None},{'request_id':None},{'input_tokens':None}):
            self.assertIsNone(engine.price(list(engine.otlp_events(payload(**kwargs)))[0])[0])
    def test_invalid_time_and_other_events(self):
        missing=list(engine.otlp_events(payload(**{'event.timestamp':'bad'})))[0]
        self.assertIsNone(missing['timestamp'])
        self.assertIsNone(engine.price(missing)[0])
        p=payload(**{'event.name':'user_prompt'})
        p['resourceLogs'][0]['scopeLogs'][0]['logRecords'][0]['body']={'stringValue':'claude_code.user_prompt'}
        self.assertEqual(list(engine.otlp_events(p)),[])

class Integration(unittest.TestCase):
    def test_restart_dedup(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'ledger.sqlite3'
            e=list(engine.otlp_events(payload()))[0]
            ledger=engine.Ledger(p)
            self.assertTrue(ledger.add(e)); self.assertFalse(ledger.add(e));ledger.close()
            ledger=engine.Ledger(p)
            self.assertFalse(ledger.add(e)); self.assertEqual(len(ledger.events()),1)
            ledger.close()
            self.assertNotIn(b'DO-NOT-SAVE',p.read_bytes())
    def test_cross_month_and_no_auto_connect(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(d)
            self.assertIsNone(app.receiver)
            app.mode='live';app.settings['timezone']='UTC'
            app.live.add(event(id='oct',timestamp='2026-11-01T00:30:00+01:00'))
            app.live.add(event(id='nov',timestamp='2026-11-01T00:30:00+00:00'))
            self.assertEqual(app.snapshot({'month':'2026-10'})['count'],1)
            self.assertEqual(app.snapshot({'month':'2026-11'})['count'],1)
            app.command({'action':'preferences','plans':{'Codex':200,'Claude Code':100},'timezone':'UTC'})
            app.close();app=engine.Engine(d)
            self.assertIsNone(app.receiver)
            self.assertEqual(app.settings['plans']['Codex'],200)
            app.close()
    def test_receiver_http_dedup_and_privacy(self):
        with tempfile.TemporaryDirectory() as d:
            ledger=engine.Ledger(Path(d)/'ledger.sqlite3')
            receiver=engine.Receiver(ledger)
            try:
                for _ in range(2):
                    req=urllib.request.Request(receiver.endpoint,json.dumps(payload()).encode(),{'Content-Type':'application/json'})
                    self.assertEqual(urllib.request.urlopen(req,timeout=3).status,200)
                self.assertEqual(receiver.accepted,1)
                self.assertEqual(len(ledger.events()),1)
                with self.assertRaises(Exception):
                    urllib.request.urlopen(urllib.request.Request(receiver.endpoint+'wrong',b'{}',{'Content-Type':'application/json'}),timeout=3)
            finally:
                receiver.stop();ledger.close()
            self.assertNotIn(b'DO-NOT-SAVE',(Path(d)/'ledger.sqlite3').read_bytes())
    def test_no_connection_for_missing_binary(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(d)
            with self.assertRaises(ValueError):app.connect('/nonexistent/claude',d)
            self.assertIsNone(app.receiver);app.close()
    def test_missing_timestamp_has_own_bucket(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(d);app.mode='live';app.settings['timezone']='UTC'
            app.live.add(list(engine.otlp_events(payload(**{'event.timestamp':None})))[0])
            result=app.snapshot({'month':'未知月份'})
            self.assertEqual(result['count'],1)
            self.assertEqual(result['unpriced'],1)
            self.assertEqual(result['current_count'],0)
            app.close()
    def test_controlled_launcher_and_disconnect(self):
        with tempfile.TemporaryDirectory() as d:
            binary=Path(d)/'synthetic-claude'
            binary.write_text('#!/bin/sh\nprintf "2.1.300 (synthetic test only)\\n"\n')
            binary.chmod(0o700)
            app=engine.Engine(Path(d)/'app')
            with patch.dict(os.environ,{},clear=True):
                launcher=Path(app.connect(str(binary),d))
            settings=json.loads((app.data/'session-settings.json').read_text())['env']
            self.assertEqual(settings['OTEL_LOG_USER_PROMPTS'],'0')
            self.assertEqual(settings['OTEL_LOG_RAW_API_BODIES'],'0')
            self.assertTrue(settings['OTEL_EXPORTER_OTLP_LOGS_ENDPOINT'].startswith('http://127.0.0.1:'))
            self.assertIn("--setting-sources ''",launcher.read_text())
            self.assertIn('Existing telemetry environment detected',launcher.read_text())
            self.assertEqual(app.live.events(),[])
            app.disconnect()
            self.assertFalse(launcher.exists());self.assertIsNone(app.receiver)
            self.assertFalse((app.data/'session-settings.json').exists())
            app.close()
    def test_refuse_existing_telemetry(self):
        with tempfile.TemporaryDirectory() as d:
            binary=Path(d)/'synthetic-claude';binary.write_text('#!/bin/sh\n');binary.chmod(0o700)
            app=engine.Engine(Path(d)/'app')
            with patch.dict(os.environ,{'OTEL_LOGS_EXPORTER':'existing'}):
                with self.assertRaises(ValueError):app.connect(str(binary),d)
            self.assertIsNone(app.receiver);app.close()

if __name__=='__main__':unittest.main(verbosity=2)
