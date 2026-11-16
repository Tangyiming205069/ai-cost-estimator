import json,sys,tempfile,unittest
from pathlib import Path
from compression import zstd
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'LMCost'))
import engine,history_import

START='2026-11-01T00:00:00+00:00'
END='2026-12-01T00:00:00+00:00'
USAGE=dict(input_tokens=12000,cached_input_tokens=4000,cache_write_input_tokens=0,
           output_tokens=2000,reasoning_output_tokens=1500,total_tokens=14000)
def line(kind,payload,at='2026-11-05T00:00:00Z'):
    return json.dumps(dict(timestamp=at,type=kind,payload=payload)).encode()+b'\n'
def fixture():
    return b''.join([
        line('session_meta',dict(id='fiction-thread',cwd='PRIVATE-PATH',account='PRIVATE-IDENTITY')),
        line('event_msg',dict(type='thread_settings_applied',thread_id='fiction-thread',thread_settings=dict(model='gpt-6-sol',service_tier='priority'))),
        line('turn_context',dict(turn_id='fiction-turn',model='gpt-6-sol',developer_instructions='PRIVATE-INSTRUCTIONS')),
        line('response_item',dict(role='user',content='PRIVATE-PROMPT')),
        line('token_usage_record',dict(thread_id='fiction-thread',turn_id='fiction-turn',response_id='fiction-response',usage=USAGE,
                                     thread_token_usage=dict(input_tokens=999999999),turn_token_usage=dict(output_tokens=999999))),
        line('token_usage_record',dict(thread_id='inherited-thread',turn_id='fiction-turn',response_id='inherited-response',usage=USAGE)),
        line('token_usage_record',dict(thread_id='fiction-thread',turn_id='fiction-turn',response_id='prior-month',usage=USAGE),'2026-10-31T23:59:59Z')])

class History(unittest.TestCase):
    def test_plain_compressed_privacy_month_fork_and_restart(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'synthetic.jsonl';p.write_bytes(fixture())
            a,diag=history_import.records_from_file(p,START,END)
            pz=Path(d)/'synthetic.jsonl.zst';pz.write_bytes(zstd.compress(fixture()))
            b,other=history_import.records_from_file(pz,START,END)
            self.assertEqual(a,b);self.assertEqual(diag,other);self.assertEqual(len(a),1)
            self.assertEqual(diag['inherited_records_skipped'],1)
            e=a[0];self.assertEqual((e['input'],e['read'],e['output']),(8000,4000,2000))
            self.assertEqual(e['speed'],'fast');self.assertNotIn('PRIVATE',json.dumps(e))
            self.assertNotIn('fiction-',json.dumps(e));self.assertAlmostEqual(engine.price(e)[0],.0736)
            ledger=engine.Ledger(Path(d)/'ledger.db');self.assertTrue(ledger.add(e));ledger.close()
            ledger=engine.Ledger(Path(d)/'ledger.db');self.assertFalse(ledger.add(b[0]));self.assertEqual(len(ledger.events()),1);ledger.close()
    def test_missing_tier_and_model_conflict_are_unpriced(self):
        record=dict(response_id='fiction',usage=USAGE)
        e=history_import.scrub_usage(record,START,'gpt-6-sol',None)
        self.assertIsNone(engine.price(e)[0]);self.assertEqual(e['read'],4000)
        e=history_import.scrub_usage(record,START,'gpt-6-sol','default',True)
        self.assertIsNone(engine.price(e)[0])
    def test_only_models_with_write_premium_require_write_bucket(self):
        usage=dict(USAGE);usage.pop('cache_write_input_tokens')
        record=dict(response_id='fiction',usage=usage)
        e=history_import.scrub_usage(record,START,'gpt-6-sol','default')
        self.assertIsNone(engine.price(e)[0])
        e=history_import.scrub_usage(record,START,'gpt-5.4-mini','default')
        self.assertEqual(e['input'],8000);self.assertAlmostEqual(engine.price(e)[0],.0153)
    def test_external_import_invalidates_live_snapshot_without_restart(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(d);q={'month':'2026-11'}
            self.assertEqual(app.snapshot(q)['count'],0)
            e=history_import.scrub_usage(dict(response_id='fiction',usage=USAGE),START,'gpt-6-sol','default')
            other=engine.Ledger(Path(d)/'usage.sqlite3');other.add(e);other.close()
            snap=app.snapshot(q);self.assertEqual(snap['count'],1)
            self.assertAlmostEqual(snap['amount'],.0368)
            self.assertEqual(app.snapshot(q),snap)
            self.assertEqual(app.snapshot(dict(q,model='gpt-6-sol'))['count'],1)
            self.assertEqual(app.snapshot(dict(q,model='gpt-6-astra'))['count'],0)
            app.close()

if __name__=='__main__':unittest.main()
