import json,os,sys,tempfile,time,unittest
from pathlib import Path
from unittest.mock import patch
from compression import zstd
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'LMCost'))
import engine,history_import,history_sync
from test_history import fixture,line,USAGE

def usage(identity,at='2026-11-16T00:00:00Z'):
    return line('token_usage_record',dict(thread_id='fiction-thread',turn_id='fiction-turn',response_id=identity,usage=USAGE),at)

class IncrementalHistory(unittest.TestCase):
    def test_file_change_wake_ingests_before_periodic_deadline(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/'source';root.mkdir();data=Path(d)/'data';data.mkdir()
            p=root/'sample.jsonl';p.write_bytes(fixture())
            w=history_sync.HistorySync(data,[root],interval=60)
            w.start()
            try:
                deadline=time.monotonic()+3
                while w.snapshot()['state']!='watching' and time.monotonic()<deadline:time.sleep(.01)
                self.assertEqual(w.snapshot()['added_this_run'],2)
                with p.open('ab') as f:f.write(usage('wake-response'))
                started=time.monotonic();w.wake()
                while w.snapshot()['added_this_run']<3 and time.monotonic()-started<3:time.sleep(.01)
                self.assertEqual(w.snapshot()['added_this_run'],3)
                self.assertLess(time.monotonic()-started,3)
                ledger=engine.Ledger(data/'usage.sqlite3')
                events=ledger.events();ledger.close()
                self.assertTrue(all(engine.timestamp(e.get('received_at')) for e in events))
                self.assertNotIn('fiction-',json.dumps(events))
            finally:w.stop();w.thread.join(2)
            self.assertFalse(w.thread.is_alive())
    def test_activity_is_chronological_and_preserves_missing_buckets(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(d)
            try:
                new=history_import.scrub_usage(dict(thread_id='fiction-first',response_id='new',usage=USAGE),
                    '2026-11-16T00:00:00+00:00','gpt-6-sol','default')
                old=history_import.scrub_usage(dict(thread_id='fiction-other',response_id='old',usage=USAGE),
                    '2026-10-01T00:00:00+00:00','gpt-6-sol',None)
                old['read']=None
                app.live.add(new);app.live.add(old)
                activity=app.snapshot({'month':'2026-10'})['activity']
                self.assertEqual([e['id'] for e in activity],[new['id'],old['id']])
                self.assertNotEqual(activity[0]['conversation'],activity[1]['conversation'])
                self.assertEqual(len(activity[0]['conversation']),12)
                self.assertIsNone(activity[1]['read']);self.assertIsNone(activity[1]['amount'])
                self.assertTrue(activity[1]['mix']['incomplete'])
                self.assertNotIn('fiction-',json.dumps(activity))
            finally:app.close()
    def test_append_partial_tail_and_no_unchanged_reread(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'sample.jsonl';p.write_bytes(fixture());c=history_import.HistoryCursor()
            events,_=c.read(p);self.assertEqual(len(events),2)
            offset=c.offset;self.assertEqual(c.read(p),([],{}));self.assertEqual(c.offset,offset)
            new=usage('new-response')
            with p.open('ab') as f:f.write(new[:80])
            self.assertEqual(c.read(p)[0],[]);self.assertEqual(c.offset,offset)
            with p.open('ab') as f:f.write(new[80:])
            events,_=c.read(p);self.assertEqual(len(events),1)
            self.assertEqual(events[0]['model'],'gpt-6-sol');self.assertEqual(events[0]['speed'],'fast')
    def test_truncate_regrow_preserves_new_context_and_compressed_rotation(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'sample.jsonl';p.write_bytes(fixture());c=history_import.HistoryCursor();c.read(p)
            replacement=fixture().replace(b'gpt-6-sol',b'gpt-6-astra')+usage('after-rewrite')
            p.write_bytes(replacement);events,_=c.read(p)
            self.assertTrue(all(e['model']=='gpt-6-astra' for e in events));self.assertEqual(len(events),3)
            compressed=Path(d)/'sample.jsonl.zst';compressed.write_bytes(zstd.compress(replacement))
            self.assertEqual(c.read(compressed)[0],events)
    def test_poll_new_changed_files_restart_and_dedup(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/'source';root.mkdir();data=Path(d)/'data';data.mkdir()
            p=root/'sample.jsonl';p.write_bytes(fixture())
            w=history_sync.HistorySync(data,[root]);a=w.poll();self.assertEqual(a['last_added'],2)
            a=w.poll();self.assertEqual(a['last_added'],0);self.assertEqual(a['files_read'],1)
            with p.open('ab') as f:f.write(usage('new-response'))
            a=w.poll();self.assertEqual(a['last_added'],1)
            (root/'rotated.jsonl.zst').write_bytes(zstd.compress(p.read_bytes()))
            a=w.poll();self.assertEqual(a['last_added'],0)
            w=history_sync.HistorySync(data,[root]);self.assertEqual(w.poll()['last_added'],0)
            ledger=engine.Ledger(data/'usage.sqlite3');self.assertEqual(len(ledger.events()),3);ledger.close()
            status=(data/'history-sync-status.json').read_text()
            for private in ['fiction-','PRIVATE',str(root)]:self.assertNotIn(private,status)
    def test_stopped_poll_does_not_ingest_and_symlink_is_excluded(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/'source';root.mkdir();data=Path(d)/'data';data.mkdir()
            outside=Path(d)/'outside.jsonl';outside.write_bytes(fixture());(root/'link.jsonl').symlink_to(outside)
            w=history_sync.HistorySync(data,[root]);self.assertEqual(w.poll()['files_seen'],0)
            (root/'real.jsonl').write_bytes(fixture());w.stop();self.assertEqual(w.poll()['last_added'],0)
    def test_engine_consent_pause_resume_and_remembered_choice(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)/'source';root.mkdir();data=Path(d)/'data';data.mkdir()
            (root/'sample.jsonl').write_bytes(fixture())
            real=history_sync.HistorySync
            with patch.object(history_sync,'HistorySync',side_effect=lambda data:real(data,[root],.05)) as factory:
                factory.saved_status=real.saved_status
                app=engine.Engine(data)
                app.command({'action':'enable-history-sync'})
                self.assertIsNone(app.history_sync)
                app.command({'action':'enable-history-sync','consent':True})
                deadline=time.monotonic()+3
                while len(app.live.events())<2 and time.monotonic()<deadline:time.sleep(.02)
                self.assertEqual(len(app.live.events()),2)
                app.close();app.history_sync.thread.join(2)
                app=engine.Engine(data);self.assertIsNotNone(app.history_sync)
                app.command({'action':'disable-history-sync'});app.history_sync.thread.join(2)
                self.assertFalse(app.snapshot({})['history_sync']['active']);app.close()
                app=engine.Engine(data);self.assertIsNone(app.history_sync);app.close()
    def test_live_event_cache_and_month_totals_extend_after_external_append(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(d);q={'month':'2026-11'};first=app.snapshot(q)
            e=history_import.scrub_usage(dict(response_id='one',usage=USAGE),'2026-11-01T00:00:00+00:00','gpt-6-sol','default')
            writer=engine.Ledger(Path(d)/'usage.sqlite3');writer.add(e)
            self.assertEqual(app.snapshot(q)['count'],1)
            cached=app.live.events();writer.add(dict(e,id='two',timestamp='2026-11-02T00:00:00+00:00'))
            s=app.snapshot(q);self.assertEqual(s['count'],2);self.assertAlmostEqual(s['amount'],.0736)
            self.assertIs(app.live.events(),cached);writer.close();app.close()

if __name__=='__main__':unittest.main()
