import datetime as dt
import os
import tempfile
import time
import unittest
from unittest.mock import patch

from test_engine import engine, event


class Analytics(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.app = engine.Engine(self.temp.name)
        self.app.settings['timezone'] = 'UTC'

    def tearDown(self):
        self.app.close()
        self.temp.cleanup()

    def add(self, identifier, timestamp, **kwargs):
        e = event(id=identifier, timestamp=timestamp, **kwargs)
        self.app.live.add(e)
        return e

    def test_monthly_daily_totals_zero_fill_and_unpriced_gaps(self):
        known = self.add('known', '2026-10-02T00:00:00Z')
        self.add('unpriced', '2026-10-04T00:00:00Z', model='unknown-model')
        s = self.app.snapshot({'month': '2026-10'})
        self.assertEqual(len(s['daily']), 31)
        self.assertEqual(s['daily'][0]['count'], 0)
        self.assertEqual(s['daily'][0]['amount'], 0)
        self.assertIsNone(s['daily'][3]['amount'])
        self.assertEqual(s['daily'][3]['unpriced'], 1)
        self.assertEqual(s['active_days'], 2)
        self.assertAlmostEqual(sum(d['amount'] or 0 for d in s['daily']), s['amount'])
        self.assertEqual(sum(d['tokens'] for d in s['daily']), s['mix']['total'])
        self.assertAlmostEqual(s['daily'][-1]['cumulative'], engine.price(known)[0])

    def test_inclusive_cross_month_range_and_same_day(self):
        for identifier, timestamp in [('before','2026-09-29T23:59:59Z'),
                ('first','2026-09-30T00:00:00Z'),('last','2026-10-02T23:59:59Z'),
                ('after','2026-10-03T00:00:00Z')]:
            self.add(identifier,timestamp)
        query={'start_date':'2026-09-30','end_date':'2026-10-02'}
        s=self.app.snapshot(query)
        self.assertEqual(s['count'],2)
        self.assertEqual([d['date'] for d in s['daily']],['2026-09-30','2026-10-01','2026-10-02'])
        self.assertEqual(s['rows'][0]['count'],2)
        same=self.app.snapshot({'start_date':'2026-10-02','end_date':'2026-10-02'})
        self.assertEqual(same['count'],1)
        self.assertEqual(len(same['daily']),1)

    def test_filters_match_daily_model_and_tier_totals(self):
        self.add('normal','2026-10-01T00:00:00Z',agent='Codex',model='gpt-6.1-sol')
        fast=self.add('fast','2026-10-02T00:00:00Z',agent='Codex',model='gpt-6.1-sol',speed='fast')
        self.add('claude','2026-10-02T00:00:00Z')
        s=self.app.snapshot({'start_date':'2026-10-01','end_date':'2026-10-03',
            'agent':'Codex','model':'gpt-6.1-sol','speed':'fast'})
        self.assertEqual(s['agents'],['Claude Code','Codex'])
        self.assertEqual(s['count'],1)
        self.assertAlmostEqual(s['amount'],engine.price(fast)[0])
        self.assertAlmostEqual(s['daily'][1]['amount'],s['amount'])
        self.assertEqual(s['daily'][1]['write'],engine.token_mix([fast])['values']['write'])
        self.assertEqual(s['daily'][1]['tokens'],s['mix']['total'])

    def test_cache_writes_without_a_premium_are_not_double_counted(self):
        e=self.add('mini','2026-10-01T00:00:00Z',agent='Codex',model='gpt-5.4-mini')
        s=self.app.snapshot({'month':'2026-10'})
        self.assertEqual(s['daily'][0]['write'],0)
        self.assertEqual(s['daily'][0]['tokens'],engine.token_mix([e])['total'])

    def test_range_sources_exclude_agents_outside_period(self):
        self.add('codex','2026-10-01T00:00:00Z',agent='Codex',model='gpt-6.1-sol')
        self.add('claude','2026-09-01T00:00:00Z')
        self.assertEqual(self.app.snapshot({'start_date':'2026-10-01','end_date':'2026-10-02'})['agents'],['Codex'])

    def test_conversations_respect_filters_and_never_guess_missing_identity(self):
        first=self.add('one','2026-10-01T00:00:00Z',agent='Codex',model='gpt-6.1-sol',conversation='a'*12)
        second=self.add('two','2026-10-02T00:00:00Z',agent='Codex',model='gpt-6.1-sol',conversation='a'*12)
        self.add('other','2026-10-02T00:00:00Z',agent='Codex',model='unknown-model',conversation='b'*12)
        self.add('missing','2026-10-02T00:00:00Z',agent='Codex',model='gpt-6.1-sol')
        self.add('another-source','2026-10-02T00:00:00Z')
        result=self.app.snapshot({'month':'2026-10','agent':'Codex'})
        grouped={r['conversation']:r for r in result['conversations']}
        self.assertEqual(set(grouped),{'a'*12,'b'*12,None})
        self.assertEqual(grouped['a'*12]['count'],2)
        self.assertEqual(grouped['a'*12]['mix'],engine.token_mix([first,second]))
        self.assertEqual(grouped['a'*12]['models'],['gpt-6.1-sol'])
        self.assertEqual(grouped['b'*12]['unpriced'],1)
        self.assertTrue(all(row['title'] is None for row in grouped.values()))
        filtered=self.app.snapshot({'start_date':'2026-10-02','end_date':'2026-10-02',
            'agent':'Codex','model':'gpt-6.1-sol'})
        self.assertEqual(sum(row['count'] for row in filtered['conversations']),filtered['count'])
        self.assertEqual(sum(row['mix']['total'] for row in filtered['conversations']),filtered['mix']['total'])
        self.assertEqual(next(r for r in filtered['conversations'] if r['conversation']=='a'*12)['count'],1)
        self.assertTrue(all(row['title'] is None for row in filtered['activity']))

    def test_unassociated_usage_is_last_even_when_it_has_the_largest_value(self):
        self.add('known-chat','2026-10-01T00:00:00Z',agent='Codex',model='gpt-6.1-sol',conversation='a'*12)
        self.add('large-unassociated','2026-10-01T00:00:00Z',agent='Codex',model='gpt-6.1-sol',output=500000)
        s=self.app.snapshot({'month':'2026-10'})
        self.assertEqual([r['conversation'] for r in s['conversations']],['a'*12,None])
        self.assertGreater(s['conversations'][-1]['amount'],s['conversations'][0]['amount'])
        self.assertEqual(sum(r['count'] for r in s['conversations']),s['count'])
        self.assertAlmostEqual(sum(r['amount'] for r in s['conversations']),s['amount'])

    def test_cache_invalidates_on_append_and_deduplicates_across_restart(self):
        q={'start_date':'2026-10-01','end_date':'2026-10-03'}
        self.app.snapshot(q)
        e=self.add('append','2026-10-02T00:00:00Z')
        self.assertFalse(self.app.live.add(e))
        self.assertEqual(self.app.snapshot(q)['daily'][1]['count'],1)
        self.app.close();self.app=engine.Engine(self.temp.name)
        self.assertEqual(self.app.snapshot(q)['count'],1)

    def test_period_switches_and_outside_appends_do_not_reprice_history(self):
        for i in range(100):
            self.add(str(i),'2026-10-02T00:00:00Z',conversation=('a' if i%2 else 'b')*12)
        # The activity feed is independent of range aggregation.
        with patch.object(self.app.live,'recent',return_value=[]),patch.object(engine,'price',wraps=engine.price) as quote:
            first=self.app.snapshot({'month':'2026-10'})
            self.assertEqual(quote.call_count,100)
            quote.reset_mock()
            ranged=self.app.snapshot({'start_date':'2026-10-02','end_date':'2026-10-02'})
            self.assertEqual(quote.call_count,0)
            self.assertEqual(ranged['count'],first['count'])
            self.assertAlmostEqual(ranged['amount'],first['amount'])
            self.add('outside','2026-09-02T00:00:00Z')
            again=self.app.snapshot({'month':'2026-10'})
            self.assertEqual(quote.call_count,1)
            self.assertEqual(again['daily'],first['daily'])
            quote.reset_mock()
            self.add('inside','2026-10-02T00:00:00Z')
            updated=self.app.snapshot({'start_date':'2026-10-02','end_date':'2026-10-02'})
            self.assertEqual(quote.call_count,1)
            self.assertEqual(updated['count'],101)

    def test_incremental_summaries_match_request_level_reference(self):
        records=[]
        cases=[{},dict(speed='fast'),dict(speed='unknown'),dict(input=None),
            dict(agent='Codex',model='gpt-6-sol',input=300000,read=0,output=1000),
            dict(agent='Codex',model='gpt-6-sol',input=1000,read=0,output=1000),
            dict(model='claude-haiku-5-5',input=1000,read=150000),
            dict(model='unknown-model'),dict(issue='synthetic incomplete usage'),
            dict(agent='Codex',model='gpt-5.4-mini'),dict(agent='Codex',model='gpt-6.1-sol',speed='fast')]
        for i in range(110):
            records.append(self.add(str(i),f'2026-10-{1+i%8:02d}T12:00:00Z',
                conversation=('abcdef123456' if i%3 else 'invalid'),**cases[i%len(cases)]))
        q={'start_date':'2026-10-02','end_date':'2026-10-06'}
        selected=[e for e in records if '2026-10-02'<=e['timestamp'][:10]<='2026-10-06']
        actual=self.app.snapshot(q)
        expected=engine.daily_usage(selected,dt.date(2026,10,2),dt.date(2026,10,6),dt.timezone.utc)
        for got,want in zip(actual['daily'],expected):
            for key in want:
                if isinstance(want[key],float):self.assertAlmostEqual(got[key],want[key])
                else:self.assertEqual(got[key],want[key])
        self.assertEqual(actual['mix'],engine.token_mix(selected))
        expected_chats=engine.conversation_usage(selected)
        for got,want in zip(actual['conversations'],expected_chats):
            for key in want:
                if key=='amount':self.assertAlmostEqual(got[key],want[key])
                else:self.assertEqual(got[key],want[key])
        for row in actual['rows']:
            subset=[e for e in selected if e['model']==row['model'] and e['agent']==row['agent']]
            quotes=[engine.price(e) for e in subset]
            self.assertEqual(row['applied_rates'],engine.applied_rates(subset,quotes))
            self.assertEqual(row['mix'],engine.token_mix(subset))
            for key,value in engine.priced_components(subset).items():self.assertAlmostEqual(row['cost_buckets'][key],value)
            for got,want in zip(row['speeds'],engine.speed_breakdown(subset,quotes)):
                for key in want:
                    if isinstance(want[key],float):self.assertAlmostEqual(got[key],want[key])
                    else:self.assertEqual(got[key],want[key])

    def test_unpriced_only_and_incomplete_tokens_are_explicit(self):
        self.add('incomplete','2026-10-01T00:00:00Z',input=None)
        s=self.app.snapshot({'start_date':'2026-10-01','end_date':'2026-10-01'})
        d=s['daily'][0]
        self.assertIsNone(d['amount']);self.assertIsNone(d['cumulative'])
        self.assertTrue(d['incomplete']);self.assertGreater(d['tokens'],0)
        self.assertEqual(s['unpriced'],1)

    def test_invalid_ranges_and_unknown_month(self):
        for q in ({'start_date':'2026-10-01'},
                {'start_date':'bad','end_date':'2026-10-01'},
                {'start_date':'2026-10-02','end_date':'2026-10-01'},
                {'start_date':'2000-01-01','end_date':'2026-10-01'}):
            with self.assertRaises(ValueError):self.app.snapshot(q)
        self.add('undated',None)
        s=self.app.snapshot({'month':'未知月份'})
        self.assertEqual(s['count'],1);self.assertEqual(s['daily'],[])

    def test_current_month_future_dated_records_still_reconcile_with_daily_totals(self):
        class Clock(dt.datetime):
            @classmethod
            def now(cls,tz=None):
                value=cls(2026,11,15,12,tzinfo=dt.timezone.utc)
                return value.astimezone(tz) if tz else value.replace(tzinfo=None)
        self.add('past','2026-11-02T00:00:00Z')
        self.add('future','2026-11-30T00:00:00Z')
        with patch.object(engine.dt,'datetime',Clock):
            s=self.app.snapshot({'month':'2026-11'})
        self.assertEqual(s['period_end'],'2026-11-30')
        self.assertEqual(sum(d['count'] for d in s['daily']),s['count'])
        self.assertEqual(sum(d['tokens'] for d in s['daily']),s['mix']['total'])
        self.assertAlmostEqual(sum(d['amount'] or 0 for d in s['daily']),s['amount'])

    def test_calendar_extremes_and_leap_month(self):
        self.assertEqual(len(self.app.snapshot({'month':'2024-02'})['daily']),29)
        self.assertEqual(len(self.app.snapshot({'month':'9999-12'})['daily']),31)

    @unittest.skipUnless(hasattr(time,'tzset'),'tzset unavailable')
    def test_timezone_changes_day_and_range_boundaries(self):
        self.add('boundary','2026-09-30T18:00:00Z')
        q={'start_date':'2026-10-01','end_date':'2026-10-01'}
        self.assertEqual(self.app.snapshot(q)['count'],0)
        try:
            with patch.dict(os.environ,{'TZ':'Asia/Shanghai'}):
                time.tzset()
                self.app.settings['timezone']='本机时区'
                s=self.app.snapshot(q)
                self.assertEqual(s['count'],1)
                self.assertEqual(s['daily'][0]['date'],'2026-10-01')
        finally:time.tzset()


if __name__=='__main__':unittest.main()
