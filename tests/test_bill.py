import sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'LMCost'))
import engine
from test_engine import event

class Bill(unittest.TestCase):
    def test_disjoint_mix_and_missing_ttl(self):
        e=event()
        m=engine.token_mix([e]);self.assertEqual(m['total'],14000)
        self.assertEqual(m['values'],dict(input=1000,read=4000,write=7000,output=2000))
        e.update(write_short=None,write_long=None)
        self.assertEqual(engine.token_mix([e]),m)
        e['write_total']=None
        self.assertTrue(engine.token_mix([e])['incomplete'])
    def test_no_write_premium_does_not_double_count(self):
        e=event(agent='Codex',model='gpt-5.4-mini')
        self.assertEqual(engine.token_mix([e])['total'],7000)
        self.assertEqual(engine.token_mix([e])['values']['write'],0)
    def test_components_sum_to_price_including_tier(self):
        for e in [event(),event(speed='fast'),event(model='claude-haiku-5-5',input=120000),event(agent='Codex',model='gpt-5.4-mini')]:
            self.assertAlmostEqual(sum(engine.priced_components([e]).values()),engine.price(e)[0])
        self.assertEqual(sum(engine.priced_components([event(speed='unknown')]).values()),0)
    def test_snapshot_and_persistent_display(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(d)
            self.assertEqual(app.snapshot({})['mode'],'live')
            self.assertEqual(app.snapshot({})['rows'],[])
            app.command({'action':'mode','value':'demo'})
            snap=app.snapshot({})
            self.assertGreater(len(snap['rows']),0)
            self.assertAlmostEqual(sum(snap['cost_buckets'].values()),snap['amount'])
            for row in snap['rows']:
                self.assertAlmostEqual(sum(row['cost_buckets'].values()),row['amount'])
                self.assertEqual(sum(row['mix']['values'].values()),row['mix']['total'])
                self.assertTrue(row['source'].startswith('https://'))
            app.command({'action':'display-preferences','metric':'month_tokens'})
            app.close();app=engine.Engine(d)
            self.assertEqual(app.snapshot({})['mode'],'live')
            self.assertEqual(app.snapshot({})['rows'],[])
            self.assertEqual(app.snapshot({})['primary_metric'],'month_tokens')
            self.assertIsNone(app.receiver);self.assertFalse(app.codex_enabled)
            app.close()
if __name__=='__main__':unittest.main(verbosity=2)
