"""Read Codex thread names via the official local app-server protocol.

Only thread/list is used after initialization. No turns, prompts, credentials,
thread mutations or model calls. Names and raw thread IDs never enter the ledger.
Source: https://learn.chatgpt.com/docs/app-server#list-threads-with-pagination--filters
"""
from __future__ import annotations
import hashlib
import json
import os
import re
import selectors
import subprocess
import threading
import time
import unicodedata

SOURCE_KINDS=['cli','vscode','exec','appServer','subAgent','subAgentReview',
              'subAgentCompact','subAgentThreadSpawn','subAgentOther','unknown']

def conversation_key(thread_id):
    if not isinstance(thread_id,str) or not 0<len(thread_id)<=512:return None
    return hashlib.sha256(('codex-thread:'+thread_id).encode()).hexdigest()[:12]

def clean_title(value):
    if not isinstance(value,str):return None
    # Display-only text, never interpreted as Markdown, URLs or instructions.
    value=' '.join(''.join(' ' if unicodedata.category(c).startswith('C') else c for c in value).split())
    return value[:500] or None

def read_titles(binary,wanted,cwd,cancel=None,timeout=20):
    """Return only requested hashes and explicit names. Discard all other fields."""
    if not wanted:return {}
    proc=subprocess.Popen([str(binary),'app-server','--listen','stdio://','-c','analytics.enabled=false'],
        cwd=str(cwd),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
        env=dict(os.environ,NO_COLOR='1'))
    selector=selectors.DefaultSelector();selector.register(proc.stdout,selectors.EVENT_READ)
    pending=b'';deadline=time.monotonic()+timeout
    def rpc(identity,method,params):
        nonlocal pending
        proc.stdin.write(json.dumps(dict(id=identity,method=method,params=params)).encode()+b'\n');proc.stdin.flush()
        while time.monotonic()<deadline:
            if cancel and cancel():raise InterruptedError()
            while b'\n' in pending:
                line,pending=pending.split(b'\n',1)
                obj=json.loads(line)
                if obj.get('id')==identity:
                    if 'error' in obj:raise ValueError('title_metadata_unavailable')
                    result=obj.get('result')
                    if not isinstance(result,dict):raise ValueError('invalid_title_metadata')
                    return result
            if not selector.select(.1):continue
            data=os.read(proc.stdout.fileno(),65536)
            if not data:raise ValueError('title_service_closed')
            pending+=data
            if len(pending)>8*1024*1024:raise ValueError('title_metadata_too_large')
        raise TimeoutError('title_metadata_timeout')
    try:
        rpc(1,'initialize',{'clientInfo':{'name':'ai_cost_estimator_titles','title':'AI Cost Estimator','version':'0.3'},'capabilities':{}})
        proc.stdin.write(b'{"method":"initialized"}\n');proc.stdin.flush()
        result={};identity=1
        # Resolve user-facing chats first, before potentially huge sub-agent catalogs.
        queries=[(sources,archived) for sources in (SOURCE_KINDS[:4]+['unknown'],SOURCE_KINDS[4:-1]) for archived in (False,True)]
        for sources,archived in queries:
            cursor=None;seen=set()
            for _ in range(100):
                identity+=1
                try:
                    response=rpc(identity,'thread/list',dict(limit=100,cursor=cursor,archived=archived,
                        sortKey='updated_at',sourceKinds=sources,modelProviders=[],useStateDbOnly=True))
                except TimeoutError:
                    if result:return result
                    raise
                rows=response.get('data')
                if not isinstance(rows,list):raise ValueError('invalid_title_metadata')
                for row in rows:
                    if not isinstance(row,dict):continue
                    key=conversation_key(row.get('id'))
                    if key in wanted:
                        title=clean_title(row.get('name'))
                        if title:result[key]=title
                    # preview, cwd, account and any history fields are discarded.
                cursor=response.get('nextCursor')
                if not cursor:break
                if not isinstance(cursor,str) or cursor in seen:raise ValueError('invalid_title_cursor')
                seen.add(cursor)
            if wanted<=result.keys():break
        return result
    finally:
        pending=b'';selector.close()
        proc.terminate()
        try:proc.wait(timeout=1)
        except subprocess.TimeoutExpired:proc.kill();proc.wait()
        proc.stdin.close();proc.stdout.close()

class TitleResolver:
    """An opt-in, bounded background lookup. The cache lives in memory only."""
    def __init__(self,cwd,find_binary,loader=read_titles,clock=time.monotonic):
        self.cwd=cwd;self.find_binary=find_binary;self.loader=loader;self.clock=clock
        self.lock=threading.RLock();self.stop_event=threading.Event();self.thread=None
        self.titles={};self.revision=0;self.next_refresh=0;self.attempted=set();self.requested=set()
        self.state='idle'
    def version(self):
        with self.lock:return self.revision
    def snapshot(self):
        with self.lock:return dict(self.titles),self.state
    def refresh(self,wanted,force=False):
        wanted={k for k in wanted if isinstance(k,str) and re.fullmatch(r'[0-9a-f]{12}',k)}
        with self.lock:
            self.requested|=wanted
            if self.stop_event.is_set() or not self.requested or (self.thread and self.thread.is_alive()):return
            if not force and self.clock()<self.next_refresh and self.requested<=self.attempted:return
            requested=set(self.requested);self.next_refresh=self.clock()+60;self.state='loading';self.revision+=1
            def run():
                try:
                    binary=self.find_binary()
                    if not binary:raise ValueError('codex_not_found')
                    titles=self.loader(binary,requested,self.cwd,cancel=self.stop_event.is_set)
                    titles={key:title for key,value in titles.items() if key in requested and (title:=clean_title(value))}
                    state='ready'
                except Exception:titles=None;state='unavailable'
                with self.lock:
                    if self.stop_event.is_set():return
                    if titles is not None:self.titles=titles
                    self.state=state;self.attempted=requested;self.revision+=1
            self.thread=threading.Thread(target=run,name='ai-cost-titles',daemon=True);self.thread.start()
    def close(self):
        self.stop_event.set()
        if self.thread and self.thread.is_alive():self.thread.join(timeout=1.5)
        with self.lock:self.titles.clear()
