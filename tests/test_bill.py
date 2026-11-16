import sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'LMCost'))
import engine
from test_engine import event

class Bill(unittest.TestCase):
    def test_agent_choices_come_only_from_recorded_month_sources(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(d)
            self.assertEqual(app.snapshot({'month':'2026-11'})['agents'],[])
            app.live.add(event(id='codex',agent='Codex',model='gpt-6.1-sol'))
            app.live.add(event(id='claude',timestamp='2026-10-01T00:00:00+00:00'))
            self.assertEqual(app.snapshot({'month':'2026-11'})['agents'],['Codex'])
            self.assertEqual(app.snapshot({'month':'2026-10'})['agents'],['Claude Code'])
            app.live.add(event(id='claude-current'))
            self.assertEqual(app.snapshot({'month':'2026-11'})['agents'],['Claude Code','Codex'])
            self.assertEqual(app.snapshot({'month':'2026-11','agent':'Codex'})['count'],1)
            app.close()
    def test_applied_unit_rates_match_fast_long_context_and_standard_fallback(self):
        normal=event(agent='Codex',model='gpt-6.1-sol')
        fast=event(agent='Codex',model='gpt-6.1-sol',speed='fast')
        long_fast=event(agent='Codex',model='gpt-6.1-sol',speed='fast',input=300000)
        rows=[normal,fast,long_fast]
        rates=engine.applied_rates(rows,[engine.price(e) for e in rows])
        self.assertEqual(rates['input'],[2,4,8])
        self.assertEqual(rates['read'],[.1,.2,.4])
        self.assertEqual(rates['output'],[10,20,30])
        for e in rows:
            single=engine.applied_rates([e],[engine.price(e)])
            self.assertAlmostEqual(sum(e[k]*single[k][0] for k in engine.BUCKETS)/1000000,engine.price(e)[0])
        fallback=event(model='claude-sonnet-5-5',speed='fast')
        self.assertEqual(engine.applied_rates([fallback],[engine.price(fallback)])['input'],[2])
    def test_fast_without_verified_fast_rate_uses_exact_model_standard_reference(self):
        normal=event(model='claude-sonnet-5-5')
        fast=event(model='claude-sonnet-5-5',speed='fast')
        self.assertAlmostEqual(engine.price(fast)[0],engine.price(normal)[0])
        self.assertFalse(engine.standard_fallback(normal))
        split=engine.speed_breakdown([normal,fast])
        self.assertEqual([r['standard_fallback'] for r in split],[0,1])
        self.assertEqual(engine.token_mix([normal]),engine.token_mix([fast]))
        self.assertIsNone(engine.price(event(model='unknown-model',speed='fast'))[0])
        self.assertIsNone(engine.price(event(model='claude-sonnet-5-5',speed='fast',input=None))[0])
    def test_speed_filter_totals_cache_append_and_recent_selection(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(d)
            normal=event(id='n',speed='normal',timestamp='2026-11-20T00:00:00+00:00')
            fast=event(id='f',speed='fast',timestamp='2026-11-02T00:00:00+00:00')
            fallback=event(id='b',model='claude-sonnet-5-5',speed='fast')
            unknown=event(id='u',speed=None)
            for e in (normal,fast,fallback,unknown):app.live.add(e)
            all_rows=app.snapshot({'month':'2026-11'})
            fast_rows=app.snapshot({'month':'2026-11','speed':'fast'})
            standard=app.snapshot({'month':'2026-11','speed':'normal'})
            self.assertEqual(fast_rows['count'],2)
            self.assertEqual(fast_rows['standard_fallback'],1)
            self.assertAlmostEqual(all_rows['amount'],fast_rows['amount']+standard['amount'])
            self.assertEqual(fast_rows['mix']['total'],28000)
            self.assertEqual({a['id'] for a in fast_rows['activity']},{'f','b'})
            self.assertEqual(app.live.recent(limit=1,speed='fast')[0]['id'],'f')
            self.assertEqual([a['id'] for a in app.live.recent(speed='unknown')],['u'])
            filtered=app.snapshot({'month':'2026-11','speed':'fast','model':'claude-sonnet-5-5','agent':'Claude Code'})
            self.assertEqual(filtered['count'],1)
            self.assertAlmostEqual(filtered['amount'],engine.price(fallback)[0])
            app.live.add(event(id='f2',speed='fast'))
            self.assertEqual(app.snapshot({'month':'2026-11','speed':'fast'})['count'],3)
            self.assertEqual(app.snapshot({'month':'2026-11'})['count'],5)
            self.assertEqual(app.snapshot({'month':'2026-11','speed':'normal'})['count'],1)
            app.close()
    def test_speed_split_preserves_tokens_and_prices_exactly_once(self):
        events=[event(agent='Codex',model='gpt-6.1-sol',speed=s) for s in ('normal','fast','fast','unknown')]
        rows=engine.speed_breakdown(events)
        self.assertEqual([r['speed'] for r in rows],['normal','fast','unknown'])
        self.assertEqual([r['count'] for r in rows],[1,2,1])
        self.assertEqual([r['request_share'] for r in rows],[.25,.5,.25])
        self.assertEqual([r['mix']['total'] for r in rows],[14000,28000,14000])
        self.assertEqual(sum(r['mix']['total'] for r in rows),engine.token_mix(events)['total'])
        self.assertAlmostEqual(rows[1]['amount'],rows[0]['amount']*4)
        self.assertAlmostEqual(sum(r['amount'] for r in rows),sum(engine.price(e)[0] or 0 for e in events))
        self.assertEqual(rows[2]['unpriced'],1)
        self.assertEqual(engine.speed_breakdown([]),[])
    def test_speed_split_survives_dedup_restart_and_month_filter(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(d)
            events=[event(id='standard',speed='normal'),event(id='fast',speed='fast'),
                    event(id='old',speed='fast',timestamp='2026-10-01T00:00:00+00:00')]
            for e in events:app.live.add(e)
            self.assertFalse(app.live.add(events[1]))
            first=app.snapshot({'month':'2026-11'})
            self.assertEqual([(s['speed'],s['count']) for s in first['rows'][0]['speeds']],[('normal',1),('fast',1)])
            self.assertEqual({e['id']:e['speed'] for e in first['activity']},{e['id']:e['speed'] for e in events})
            app.close();app=engine.Engine(d)
            again=app.snapshot({'month':'2026-11'})
            self.assertEqual(again['rows'][0]['speeds'],first['rows'][0]['speeds'])
            self.assertAlmostEqual(again['amount'],first['amount'])
            old=app.snapshot({'month':'2026-10'})
            self.assertEqual([(s['speed'],s['count']) for s in old['rows'][0]['speeds']],[('fast',1)])
            app.close()
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
