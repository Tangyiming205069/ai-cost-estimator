import io,json,os,sys,tempfile,time,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'LMCost'))
import engine,subscriptions

class Subscriptions(unittest.TestCase):
    def test_codex_plus_projection(self):
        r=subscriptions.codex_plan({'account':{'type':'chatgpt','planType':'plus','email':'DO-NOT-SAVE','workspaceName':'DO-NOT-SAVE'}})
        self.assertEqual(r['reference_usd'],20);self.assertEqual(r['plan'],'plus')
        self.assertNotIn('DO-NOT-SAVE',json.dumps(r))
    def test_ambiguous_pro_does_not_guess_tier(self):
        for p in ('pro','prolite','promax','business','enterprise'):
            r=subscriptions.codex_plan({'account':{'type':'chatgpt','planType':p}})
            self.assertIsNone(r['reference_usd']);self.assertEqual(r['state'],'detected')
    def test_api_is_not_subscription(self):
        self.assertEqual(subscriptions.codex_plan({'account':{'type':'apiKey'}})['state'],'api')
        r=subscriptions.claude_plan({'loggedIn':True,'authMethod':'api_key','subscriptionType':'pro'})
        self.assertEqual(r['state'],'api');self.assertIsNone(r['reference_usd'])
    def test_claude_optional_fields_and_privacy(self):
        r=subscriptions.claude_plan({'loggedIn':True,'authMethod':'claude.ai','subscriptionType':'pro','email':'DO-NOT-SAVE','orgId':'DO-NOT-SAVE'})
        self.assertEqual(r['reference_usd'],20);self.assertNotIn('DO-NOT-SAVE',json.dumps(r))
        for p in ({'loggedIn':False},{'loggedIn':True,'authMethod':'oauth_token'}, {'loggedIn':True,'authMethod':'claude.ai','subscriptionType':'new-plan'}):
            self.assertIsNone(subscriptions.claude_plan(p)['reference_usd'])
    def test_no_automatic_query_or_fake_default(self):
        with tempfile.TemporaryDirectory() as d,patch.object(subscriptions,'find_binary') as find:
            app=engine.Engine(d)
            self.assertIsNone(app.snapshot({})['plan'])
            app.command({'action':'detect-plan','provider':'Codex'})
            app.command({'action':'demo-refresh'})
            find.assert_not_called();app.close()
    def test_legacy_twenty_is_not_detected_plan(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d,'preferences.json').write_text(json.dumps({'plans':{'Codex':20,'Claude Code':20},'timezone':'UTC'}))
            app=engine.Engine(d)
            self.assertIsNone(app.snapshot({})['plan']);self.assertEqual(app.settings['plans']['Codex'],20)
            app.close()
    def test_synthetic_detection_and_optional_override(self):
        with tempfile.TemporaryDirectory() as d,patch.object(subscriptions,'find_binary',return_value='/synthetic/codex'),patch.object(subscriptions,'codex_lookup',return_value=subscriptions.codex_plan({'account':{'type':'chatgpt','planType':'plus'}})):
            app=engine.Engine(d)
            app.command({'action':'detect-plan','provider':'Codex','consent':True})
            for _ in range(100):
                if app.snapshot({})['subscriptions']['Codex']['state']!='loading':break
                time.sleep(.005)
            self.assertEqual(app.snapshot({'agent':'Codex'})['plan'],20)
            self.assertIsNone(app.snapshot({})['plan'])
            app.command({'action':'preferences','plans':{'Codex':18},'timezone':'UTC'})
            self.assertEqual(app.snapshot({'agent':'Codex'})['plan'],18)
            app.command({'action':'preferences','plans':{'Codex':None},'timezone':'UTC'})
            self.assertEqual(app.snapshot({'agent':'Codex'})['plan'],20)
            app.command({'action':'preferences','plans':{'Codex':18},'timezone':'UTC'})
            app.command({'action':'reset-plan-overrides'})
            self.assertEqual(app.snapshot({'agent':'Codex'})['plan'],20)
            app.close()
            reopened=engine.Engine(d)
            self.assertEqual(reopened.snapshot({'agent':'Codex'})['plan'],20);reopened.close()
    def test_connection_detects_only_after_explicit_consent(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(Path(d)/'app')
            binary=Path(d,'synthetic-claude')
            binary.write_text('#!'+sys.executable+'\nprint("2.1.300 (synthetic test only)")\n')
            binary.chmod(0o700)
            with patch.object(app,'detect_plan') as detect,patch.dict(os.environ,{},clear=True):
                app.command({'action':'enable-codex'})
                detect.assert_not_called()
                app.command({'action':'enable-codex','detect_plan':True})
                detect.assert_called_once_with('Codex');detect.reset_mock()
                app.connect(str(binary),d)
                detect.assert_not_called()
                app.connect(str(binary),d,detect_plan=True)
                detect.assert_called_once_with('Claude Code',str(binary),d)
            app.close()
    def test_official_protocol_only_with_fake_process(self):
        with tempfile.TemporaryDirectory() as d:
            executable=Path(d,'synthetic-codex')
            executable.write_text('#!'+sys.executable+'\n'+'''import sys,json
for line in sys.stdin:
 q=json.loads(line)
 if q['method']=='initialize':
  print(json.dumps({'id':q['id'],'result':{}}),flush=True)
 elif q['method']=='initialized':pass
 elif q['method']=='account/read':
  assert q['params']=={'refreshToken':False}
  print(json.dumps({'id':q['id'],'result':{'account':{'type':'chatgpt','planType':'plus','email':'DO-NOT-SAVE'}}}),flush=True)
 else:raise RuntimeError('unexpected method')
''')
            executable.chmod(0o700)
            self.assertEqual(subscriptions.codex_lookup(executable,d)['reference_usd'],20)
    def test_claude_official_command_with_fake_binary(self):
        with tempfile.TemporaryDirectory() as d:
            executable=Path(d,'synthetic-claude')
            executable.write_text('#!'+sys.executable+'\n'+'''import sys,json
assert sys.argv[1:]==['auth','status']
print(json.dumps({'loggedIn':True,'authMethod':'claude.ai','subscriptionType':'pro'}))
''')
            executable.chmod(0o700)
            self.assertEqual(subscriptions.claude_lookup(executable,d)['reference_usd'],20)

if __name__=='__main__':unittest.main(verbosity=2)
