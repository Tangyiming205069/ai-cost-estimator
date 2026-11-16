"""Explicit one-shot local history import; never runs automatically.
Only sanitized usage events are stored. Transcript lines are discarded locally.
"""
from __future__ import annotations
import argparse,collections,concurrent.futures,datetime as dt,hashlib,io,json,os,re,sqlite3,time
from pathlib import Path
from compression import zstd
import engine
KINDS=re.compile(rb'"type"\s*:\s*"(session_meta|turn_context|token_usage_record|event_msg)"')
EVENT_KIND=re.compile(rb'"type"\s*:\s*"(thread_settings_applied|token_count|model_rerouted)"')
MAX_LINE=8*1024*1024

def scrub_usage(record,at,model,tier,model_conflict=False):
    u=record.get('usage')
    if not isinstance(u,dict) or not isinstance(record.get('response_id'),str) or not record['response_id']:return None
    e=engine.codex_event({'hook_event_name':'PostModelRequest','response_id':record['response_id'],
        'model':model,'status':'completed','token_usage':u},received=at)
    e.update(source='Codex local history',time_basis='history_record',model_basis='turn_context',
        speed={'default':'normal','priority':'fast','fast':'fast','flex':'flex','ultrafast':'ultrafast'}.get(tier,'unknown'))
    thread=record.get('thread_id')
    if isinstance(thread,str) and 0<len(thread)<=512:
        e['conversation']=hashlib.sha256(('codex-thread:'+thread).encode()).hexdigest()[:12]
    if engine.integer(u.get('input_tokens')) is not None:e['context']='short' if u['input_tokens']<=272000 else 'long'
    if not at:e['issue']='历史记录缺少有效时间'
    if model_conflict:e['issue']='历史模型配置有冲突，未定价'
    # Unlike the in-memory Codex type's default, absent cache writes are unknown.
    p=engine.CATALOG['models'].get(model,{})
    if 'cache_write_input_tokens' not in u and p.get('cache_accounting')!='no_write_premium':
        e.update(write_total=None,write_short=None,write_long=None,input=None,issue='历史记录未提供缓存写入桶')
    return e

class HistoryCursor:
    """In-memory cursor. No transcript bytes or raw identities are persisted."""
    def __init__(self):
        self.reset()
    def reset(self):
        self.contexts={};self.settings={};self.own_thread=None
        self.offset=0;self.identity=None;self.signature=None;self.discarding=False;self.anchor=None
    def read(self,path,start='1970-01-01T00:00:00+00:00',end='9999-12-31T23:59:59+00:00',cancel=None):
        stat=path.stat();identity=(stat.st_dev,stat.st_ino)
        signature=(stat.st_dev,stat.st_ino,stat.st_size,stat.st_mtime_ns)
        if signature==self.signature:return [],{}
        compressed=path.suffix=='.zst'
        if compressed or self.identity!=identity or stat.st_size<self.offset or (self.signature and stat.st_size==self.offset):self.reset()
        if not compressed and self.anchor and self.offset:
            with path.open('rb') as probe:
                probe.seek(max(0,self.offset-64))
                if hashlib.sha256(probe.read(min(64,self.offset))).digest()!=self.anchor:self.reset()
        self.identity=identity
        diag=collections.Counter();events=[];legacy=0
        opener=zstd.open if compressed else open
        try:
            with opener(path,'rb') as f:
                if not compressed:f.seek(self.offset)
                while True:
                    if cancel and cancel():break
                    beginning=f.tell()
                    remaining=MAX_LINE if compressed else min(MAX_LINE,stat.st_size-beginning)
                    if remaining<=0:break
                    line=f.readline(remaining)
                    if not line:break
                    if self.discarding:
                        self.offset=f.tell()
                        if line.endswith(b'\n'):self.discarding=False
                        continue
                    if not line.endswith(b'\n'):
                        if len(line)>=MAX_LINE:
                            self.discarding=True;self.offset=f.tell();diag['oversize_or_incomplete_lines']+=1
                            continue
                        # Retry a partial final line after more bytes arrive. Do not retain its body.
                        self.offset=beginning;diag['incomplete_tail']+=1;break
                    self.offset=f.tell()
                    m=KINDS.search(line[:160])
                    if not m:continue
                    kind=m.group(1)
                    if kind==b'event_msg' and not EVENT_KIND.search(line[m.end():400]):continue
                    try:o=json.loads(line)
                    except (ValueError,UnicodeError):diag['invalid_metadata_lines']+=1;continue
                    q=o.get('payload',{})
                    if not isinstance(q,dict):continue
                    typ=o.get('type')
                    if typ=='session_meta':self.own_thread=q.get('id');continue
                    if typ=='event_msg':
                        if q.get('type')=='thread_settings_applied':
                            settings=q.get('thread_settings') or {}
                            if isinstance(settings,dict):
                                self.settings={'model':engine.safe_model(settings.get('model')),'tier':settings.get('service_tier')}
                        elif q.get('type')=='token_count':legacy+=1
                        elif q.get('type')=='model_rerouted':diag['reroute_events']+=1
                        continue
                    if typ=='turn_context':
                        tid=q.get('turn_id');model=engine.safe_model(q.get('model'))
                        if not isinstance(tid,str):continue
                        self.contexts[tid]={'model':model,'tier':self.settings.get('tier') if self.settings.get('model')==model else None,
                            'conflict':self.settings.get('model') not in (None,'unknown',model)}
                        continue
                    if typ!='token_usage_record':continue
                    at=engine.timestamp(o.get('timestamp'))
                    if not at:diag['missing_timestamp']+=1;continue
                    if not start<=at<end:continue
                    if self.own_thread and q.get('thread_id')!=self.own_thread:
                        diag['inherited_records_skipped']+=1;continue
                    c=self.contexts.get(q.get('turn_id'),{})
                    e=scrub_usage(q,at,c.get('model','unknown'),c.get('tier'),c.get('conflict',False))
                    if e:events.append(e)
                    else:diag['missing_usage_or_identity']+=1
        except Exception:
            self.reset();raise
        self.signature=signature
        if not compressed and self.offset:
            with path.open('rb') as probe:
                probe.seek(max(0,self.offset-64));self.anchor=hashlib.sha256(probe.read(min(64,self.offset))).digest()
        if legacy and not events:diag['files_without_selected_durable_records']+=1
        return events,dict(diag)

def records_from_file(path,start,end):
    return HistoryCursor().read(path,start,end)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--month',required=True);ap.add_argument('--data',required=True);args=ap.parse_args()
    year,mo=(1970,1) if args.month=='all' else map(int,args.month.split('-'))
    start=dt.datetime(year,mo,1,tzinfo=dt.timezone.utc)
    following=dt.datetime.max.replace(tzinfo=dt.timezone.utc) if args.month=='all' else dt.datetime(year+(mo==12),mo%12+1,1,tzinfo=dt.timezone.utc)
    cutoff=min(dt.datetime.now(dt.timezone.utc),following);begin=start.isoformat();end=cutoff.isoformat()
    data=Path(args.data);data.mkdir(parents=True,exist_ok=True);os.chmod(data,0o700)
    roots=[Path.home()/'.codex/sessions',Path.home()/'.codex/archived_sessions'];files=[];inventory=0
    for root in roots:
        if not root.exists():continue
        for p in root.rglob('*'):
            if p.is_symlink() or not p.is_file() or not (p.name.endswith('.jsonl') or p.name.endswith('.jsonl.zst')):continue
            inventory+=1;st=p.stat()
            # mtime adds old sessions continued this month; directory date adds newly created sessions.
            parts=p.relative_to(root).parts
            creation_month='/'.join(parts[:2]) if len(parts)>2 else ''
            if st.st_mtime>=start.timestamp() or creation_month==f'{year}/{mo:02}':files.append((p,st.st_size))
    files.sort(key=lambda x:x[1]);db=sqlite3.connect(data/'usage.sqlite3',timeout=30)
    db.execute('CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY,body TEXT NOT NULL)')
    report={'month':args.month,'timezone':'UTC','cutoff':end,'inventory_files':inventory,'candidate_files':len(files),
            'candidate_bytes':sum(s for _,s in files),'completed_files':0,'completed_bytes':0,'inserted':0,'duplicates':0,
            'diagnostics':{},'state':'running','source':'本机 Codex 历史（活跃及归档）','model_basis':'历史回合配置模型及已记录档位'}
    counters=collections.Counter();t=time.monotonic()
    def write_report():
        report['diagnostics']=dict(counters);report['elapsed_seconds']=round(time.monotonic()-t,1)
        tmp=data/'history-import-status.tmp';tmp.write_text(json.dumps(report,ensure_ascii=False));os.chmod(tmp,0o600);tmp.replace(data/'history-import-status.json')
    write_report()
    def work(pair):
        try:return pair,records_from_file(pair[0],begin,end),None
        except Exception as ex:return pair,([],{}),type(ex).__name__
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        # Bounded executor map avoids retaining thousands of large results in memory.
        for pair,(events,diag),error in pool.map(work,files,buffersize=8):
            counters.update(diag)
            if error:counters['file_errors_'+error]+=1
            before=db.total_changes
            db.executemany('INSERT OR IGNORE INTO events VALUES (?,?)',[(e['id'],json.dumps(e,separators=(',',':'),ensure_ascii=False)) for e in events]);db.commit()
            added=db.total_changes-before;report['inserted']+=added;report['duplicates']+=len(events)-added
            report['completed_files']+=1;report['completed_bytes']+=pair[1];write_report()
            if report['completed_files']%100==0:print(json.dumps({k:report[k] for k in ['completed_files','candidate_files','inserted','duplicates','elapsed_seconds']}) ,flush=True)
    report['state']='complete';write_report();db.close();print(json.dumps(report,ensure_ascii=False),flush=True)
if __name__=='__main__':main()
