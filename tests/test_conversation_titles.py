import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_engine import engine,event
from conversation_titles import TitleResolver,clean_title,conversation_key,read_titles


class Titles(unittest.TestCase):
    def test_demo_conversations_are_fictional_and_do_not_lookup_private_titles(self):
        with tempfile.TemporaryDirectory() as d,patch.object(engine.subscriptions,'find_binary') as find:
            app=engine.Engine(d);app.mode='demo';app.settings['conversation_titles_enabled']=True
            result=app.snapshot({})
            self.assertTrue(result['conversations'])
            self.assertTrue(all(r['title'] in engine.DEMO_NAMES for r in result['conversations']))
            self.assertIsNone(app.title_resolver.thread);find.assert_not_called();app.close()

    def test_hash_matches_existing_usage_identity(self):
        from history_import import scrub_usage
        from test_history import USAGE
        e=scrub_usage(dict(thread_id='synthetic-thread',response_id='synthetic-request',usage=USAGE),
            '2026-11-01T00:00:00Z','gpt-6.1-sol','default')
        self.assertEqual(conversation_key('synthetic-thread'),e['conversation'])
        self.assertIsNone(conversation_key(None))

    def test_names_are_plain_text_and_blank_values_are_not_titles(self):
        self.assertIsNone(clean_title(None));self.assertIsNone(clean_title(' \n\t'))
        self.assertEqual(clean_title('  合并修复\n进展\u202e  '),'合并修复 进展')
        self.assertEqual(clean_title('[title](https://example.invalid)'), '[title](https://example.invalid)')
        self.assertEqual(len(clean_title('x'*600)),500)

    @unittest.skipIf(os.name=='nt','POSIX fake executable')
    def test_official_metadata_protocol_pagination_archives_and_no_preview_fallback(self):
        with tempfile.TemporaryDirectory() as d:
            binary=Path(d,'synthetic-codex')
            binary.write_text('#!'+sys.executable+'\n'+'''
import json,sys
from pathlib import Path
assert sys.argv[1:]==['app-server','--listen','stdio://','-c','analytics.enabled=false']
for line in sys.stdin:
    q=json.loads(line)
    with Path('queries.jsonl').open('a') as log:log.write(json.dumps(q)+'\\n')
    method=q['method']
    if method=='initialized':continue
    if method=='initialize':r={}
    elif method=='thread/list':
        p=q['params'];assert p['useStateDbOnly'] is True
        assert p['modelProviders']==[]
        if 'subAgent' in p['sourceKinds']:r={'data':[],'nextCursor':None}
        elif p['archived']:
            r={'data':[{'id':'synthetic-archive','name':'Archived work','preview':'DO-NOT-USE-PREVIEW'}],'nextCursor':None}
        elif p['cursor'] is None:
            r={'data':[{'id':'synthetic-one','name':'费用明细修复','preview':'DO-NOT-USE-PREVIEW','account':'DO-NOT-SAVE-ACCOUNT','turns':['DO-NOT-SAVE-BODY']}],'nextCursor':'page-two'}
        else:
            assert p['cursor']=='page-two'
            r={'data':[{'id':'synthetic-unnamed','name':None,'preview':'DO-NOT-USE-PREVIEW'}],'nextCursor':None}
    else:raise RuntimeError('unapproved method')
    print(json.dumps({'id':q['id'],'result':r}),flush=True)
''')
            binary.chmod(0o700)
            wanted={conversation_key(k) for k in ('synthetic-one','synthetic-archive','synthetic-unnamed')}
            names=read_titles(binary,wanted,d)
            self.assertEqual(names,{conversation_key('synthetic-one'):'费用明细修复',conversation_key('synthetic-archive'):'Archived work'})
            self.assertNotIn('DO-NOT',json.dumps(names))
            self.assertFalse(any(k.startswith('synthetic') for k in names))
            queries=[json.loads(q) for q in Path(d,'queries.jsonl').read_text().splitlines()]
            self.assertEqual({q['method'] for q in queries},{'initialize','initialized','thread/list'})
            self.assertTrue(any(q.get('params',{}).get('archived') for q in queries))

    def test_refresh_is_bounded_and_picks_up_renamed_titles(self):
        clock=[0];names={conversation_key('synthetic-one'):'Old title'};calls=[]
        def loader(binary,wanted,cwd,**kwargs):calls.append(set(wanted));return dict(names)
        r=TitleResolver('.',lambda:'fake',loader=loader,clock=lambda:clock[0])
        try:
            r.refresh(set(names));r.thread.join(2)
            initial=r.version();self.assertEqual(r.snapshot()[0],names)
            for _ in range(20):r.refresh(set(names))
            self.assertEqual(len(calls),1)
            clock[0]=61;names[conversation_key('synthetic-one')]='Renamed title'
            r.refresh(set(names));r.thread.join(2)
            self.assertGreater(r.version(),initial);self.assertEqual(r.snapshot()[0],names)
            self.assertEqual(len(calls),2)
        finally:r.close()
        self.assertEqual(r.snapshot()[0],{})

    def test_failed_lookup_keeps_known_names_without_unsafe_fallback(self):
        key=conversation_key('synthetic-one')
        r=TitleResolver('.',lambda:'fake',loader=lambda *a,**kw:{key:'Known title'})
        try:
            r.refresh({key});r.thread.join(2)
            def failed(*args,**kwargs):raise ValueError('DO-NOT-EXPOSE-RAW-OUTPUT')
            r.loader=failed;r.refresh({key},force=True);r.thread.join(2)
            self.assertEqual(r.snapshot(),({key:'Known title'},'unavailable'))
        finally:r.close()

    def test_titles_are_opt_in_apply_to_both_views_and_never_enter_ledger(self):
        with tempfile.TemporaryDirectory() as d,patch.object(engine.subscriptions,'find_binary',return_value='fake'):
            app=engine.Engine(d);key=conversation_key('synthetic-one')
            e=event(id='synthetic-request',agent='Codex',model='gpt-6.1-sol',conversation=key)
            app.live.add(e)
            app.title_resolver.loader=lambda *args,**kwargs:{key:'合成测试对话'}
            q={'month':'2026-11'}
            first=app.snapshot(q)
            self.assertIsNone(first['conversations'][0]['title']);self.assertIsNone(app.title_resolver.thread)
            app.command({'action':'set-conversation-titles','enabled':True})
            self.assertIsNone(app.title_resolver.thread)
            app.command(dict(q,action='set-conversation-titles',enabled=True,consent=True))
            app.title_resolver.thread.join(2)
            named=app.snapshot(q)
            self.assertEqual(named['conversations'][0]['title'],'合成测试对话')
            self.assertEqual(named['activity'][0]['title'],'合成测试对话')
            for field in ('count','amount','mix','rows','daily'):
                self.assertEqual(first[field],named[field])
            self.assertNotIn('title',app.live.events()[0])
            self.assertNotIn('合成测试对话',Path(d,'preferences.json').read_text())
            self.assertNotIn('合成测试对话',Path(d,'usage.sqlite3').read_bytes().decode('utf-8',errors='ignore'))
            app.command(dict(q,action='set-conversation-titles',enabled=False))
            self.assertIsNone(app.snapshot(q)['conversations'][0]['title'])
            self.assertFalse(app.settings['conversation_titles_enabled']);app.close()

    def test_missing_identity_and_other_agents_never_get_a_codex_title(self):
        with tempfile.TemporaryDirectory() as d:
            app=engine.Engine(d);key=conversation_key('synthetic-one')
            app.live.add(event(id='without-identity',agent='Codex',model='gpt-6.1-sol'))
            app.live.add(event(id='other-agent',conversation=key))
            app.settings['conversation_titles_enabled']=True
            app.title_resolver.titles={key:'Wrong agent title'}
            result=app.snapshot({'month':'2026-11'})
            self.assertTrue(all(row['title'] is None for row in result['conversations']))
            self.assertTrue(all(row['title'] is None for row in result['activity']))
            self.assertIsNone(app.title_resolver.thread);app.close()


if __name__=='__main__':unittest.main()
