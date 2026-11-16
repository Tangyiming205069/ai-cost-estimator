"""AI Cost Estimator local-only ledger. History requires a separate explicit import."""
from __future__ import annotations
import datetime as dt
from decimal import Decimal
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import sqlite3
import subprocess
import sys
import threading
import time
import subscriptions

ROOT = Path(__file__).resolve().parent
CATALOG = json.loads((ROOT / 'pricing.json').read_text())
BUCKETS = ('input', 'read', 'write_short', 'write_long', 'output')
MAX_TOKEN = 2**53 - 1

def integer(v):
    if isinstance(v, str) and re.fullmatch(r'[0-9]{1,16}', v):
        v = int(v)
    return v if type(v) is int and 0 <= v <= MAX_TOKEN else None

def timestamp(value):
    try:
        if not isinstance(value, str) or len(value) > 64:
            return None
        t = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        if t.tzinfo is None:
            return None
        return t.astimezone(dt.timezone.utc).isoformat()
    except (ValueError, OverflowError):
        return None

def safe_model(v):
    return v if isinstance(v, str) and re.fullmatch(r'[A-Za-z0-9_.:-]{1,100}', v) else 'unknown'

def recorded_speed(event):
    value=event.get('speed')
    return value if value in ('normal','fast','flex','ultrafast') else 'unknown'

def standard_fallback(event):
    model=CATALOG['models'].get(event.get('model'))
    return bool(model and event.get('speed')=='fast' and not model.get('fast_factor'))

def price(event):
    """All or nothing per request: a partial number must never look fully priced."""
    if event.get('issue'):
        return None, event['issue']
    p = CATALOG['models'].get(event['model'])
    if not p:
        return None, '精确 model ID 未核价'
    expected = 'Claude Code' if p['provider'] == 'anthropic' else 'Codex'
    if event['agent'] != expected:
        return None, '来源与模型不匹配'
    buckets = ('input', 'read', 'output') if p.get('cache_accounting') == 'no_write_premium' else BUCKETS
    if any(integer(event.get(k)) is None for k in buckets):
        return None, '缺少或无效 token 桶'
    speed = event.get('speed')
    factor = Decimal(1)
    if speed in ('fast','flex','ultrafast') and p.get(speed+'_factor'):
        factor *= Decimal(str(p[speed+'_factor']))
    elif speed != 'normal' and not standard_fallback(event):
        return None, '档位缺失或未核价'
    prompt = sum(event[k] for k in buckets if k != 'output')
    if p['context'] == 'short' and event.get('context') != 'short':
        return None, '上下文档位无法确认'
    if p['context'] == 'threshold' and prompt > p['threshold']:
        factor *= Decimal(str(p['long_factor']))
    if p['provider'] == 'anthropic' and prompt > 1000000:
        return None, '超出已核验上下文范围'
    if p.get('max_context') and prompt + event['output'] > p['max_context']:
        return None, '超出已核验上下文范围'
    # Fixed reference: first-party, global, non-batch token rates, not actual billing.
    amount = sum(Decimal(event[k]) * Decimal(str(p[k])) * context_factor(p,prompt,k) for k in buckets)
    return float(amount * factor / Decimal(1000000)), ''

def context_factor(p,prompt,bucket):
    if p.get('context')=='split_threshold' and prompt>p['threshold']:
        return Decimal(str(p['long_output_factor'] if bucket=='output' else p['long_input_factor']))
    return Decimal(1)

def applied_rates(events,priced):
    values={k:set() for k in BUCKETS}
    for e,(amount,_) in zip(events,priced):
        if amount is None:continue
        p=CATALOG['models'][e['model']]
        keys=('input','read','output') if p.get('cache_accounting')=='no_write_premium' else BUCKETS
        prompt=sum(e[k] for k in keys if k!='output')
        factor=Decimal(str(p.get(e.get('speed','')+'_factor',1)))
        for k in keys:values[k].add(float(Decimal(str(p[k]))*factor*context_factor(p,prompt,k)))
    return {k:sorted(rates) for k,rates in values.items()}

def token_mix(events):
    """Disjoint known-token denominator; unknown portions are explicitly flagged."""
    values={'input':0,'read':0,'write':0,'output':0}
    incomplete=False
    for e in events:
        no_write=CATALOG['models'].get(e['model'],{}).get('cache_accounting')=='no_write_premium'
        write=0 if no_write else integer(e.get('write_total'))
        if write is None and all(integer(e.get(k)) is not None for k in ('write_short','write_long')):
            write=e['write_short']+e['write_long']
        for k,v in {'input':e.get('input'),'read':e.get('read'),'write':write,'output':e.get('output')}.items():
            if integer(v) is None:incomplete=True
            else:values[k]+=v
    return dict(values=values,total=sum(values.values()),incomplete=incomplete)

def priced_components(events):
    values={k:0.0 for k in BUCKETS}
    for e in events:
        amount,_=price(e)
        if amount is None:continue
        p=CATALOG['models'][e['model']]
        keys=('input','read','output') if p.get('cache_accounting')=='no_write_premium' else BUCKETS
        prompt=sum(e[k] for k in keys if k!='output')
        weights={k:Decimal(e[k])*Decimal(str(p[k]))*context_factor(p,prompt,k) for k in keys}
        total=sum(weights.values())
        if total:
            for k,w in weights.items():values[k]+=amount*float(w/total)
    return values

def speed_breakdown(events, priced=None):
    """Partition recorded requests; never scale token counts or price twice."""
    groups={}
    for e,quote in zip(events,priced if priced is not None else [price(e) for e in events]):
        speed=recorded_speed(e)
        group=groups.setdefault(speed,{'events':[],'prices':[]})
        group['events'].append(e);group['prices'].append(quote[0])
    return [dict(speed=speed,count=len(groups[speed]['events']),
                 request_share=len(groups[speed]['events'])/len(events),
                 mix=token_mix(groups[speed]['events']),
                 amount=sum(n for n in groups[speed]['prices'] if n is not None),
                 unpriced=sum(n is None for n in groups[speed]['prices']),
                 standard_fallback=sum(standard_fallback(e) and n is not None for e,n in zip(groups[speed]['events'],groups[speed]['prices'])))
            for speed in ('normal','fast','flex','ultrafast','unknown') if speed in groups]

def codex_event(payload, received=None):
    """Official PostModelRequest projection; no paths/content/identity retained.

    Current public main schema has attempt identity, but the installed release is
    only verified to recognize the hook. Missing identity is rejected, not guessed
    from turn_id or token counts (both can collide across real requests/retries).
    """
    if not isinstance(payload, dict) or payload.get('hook_event_name') != 'PostModelRequest':
        raise ValueError('unsupported_event')
    def identifier(v):
        return isinstance(v, str) and 0 < len(v) <= 512
    response = payload.get('response_id')
    request, thread = payload.get('request_id'), payload.get('thread_id')
    attempt = integer(payload.get('attempt_number'))
    if identifier(response):
        identity = ['codex-response', response]
    elif identifier(request) and identifier(thread) and attempt is not None and 0 < attempt <= 2**32-1:
        identity = ['codex-attempt', thread, request, attempt]
    else:
        raise ValueError('missing_attempt_identity')
    model = safe_model(payload.get('model'))
    p = CATALOG['models'].get(model, {})
    usage = payload.get('token_usage')
    u = usage if isinstance(usage, dict) else {}
    total_in, read, output = (integer(u.get(k)) for k in ('input_tokens','cached_input_tokens','output_tokens'))
    write = integer(u.get('cache_write_input_tokens', 0))
    issue = ''
    ordinary = ws = wl = None
    if usage is None:
        issue = '本次请求未提供 token_usage'
    elif total_in is None or read is None or output is None or read > total_in:
        issue = '缺少或无效 token 桶'
    elif p.get('cache_accounting') == 'no_write_premium':
        # Writes are already ordinary input for these exact models. No TTL needed.
        ordinary = total_in - read
    elif write is None or read + write > total_in:
        issue = '缓存总量与输入包含关系无效'
    elif write == 0:
        ordinary, ws, wl = total_in-read, 0, 0
    else:
        # Public hook schema has only the total; do not invent TTL details.
        ordinary = total_in-read-write
        issue = '此模型写入有 TTL 差价，但 hook 未提供分桶'
    reason = integer(u.get('reasoning_output_tokens'))
    total = integer(u.get('total_tokens'))
    if reason is not None and output is not None and reason > output:
        issue = '推理 token 超出输出 token'
    if total is not None and total_in is not None and output is not None and total != total_in+output:
        issue = '总 token 与输入、输出不一致'
    if payload.get('status') not in ('completed','failed','cancelled'):
        issue = '未知请求状态'
    # No tier/context-tier fields in the verified schema. Never infer from model.
    return dict(id=hashlib.sha256(json.dumps(identity,separators=(',',':')).encode()).hexdigest(),
        timestamp=timestamp(received) if received else dt.datetime.now(dt.timezone.utc).isoformat(),
        time_basis='hook_received', agent='Codex', model=model,input=ordinary,read=read,
        write_short=ws,write_long=wl,write_total=write,output=output,
        speed='unknown',context='unknown',issue=issue,source='PostModelRequest')

def attributes(items):
    out = {}
    allowed = {'event.name','event.timestamp','event.sequence','model','request_id',
               'input_tokens','output_tokens','cache_read_tokens','cache_creation_tokens',
               'cache_creation_5m_tokens','cache_creation_1h_tokens','speed'}
    for item in items if isinstance(items, list) else []:
        if not isinstance(item, dict) or item.get('key') not in allowed:
            continue
        v = item.get('value', {})
        if isinstance(v, dict):
            out[item['key']] = next((v[k] for k in ('stringValue','intValue','doubleValue') if k in v), None)
    return out

def claude_event(record):
    a = attributes(record.get('attributes'))
    name = a.get('event.name')
    body = record.get('body', {})
    if name != 'api_request' and body != {'stringValue':'claude_code.api_request'}:
        return None
    t = timestamp(a.get('event.timestamp'))
    model = safe_model(a.get('model'))
    req = a.get('request_id')
    issue = '' if t is not None else '缺少有效时间，未归属月份'
    if not isinstance(req, str) or not 1 <= len(req) <= 256:
        issue = '缺少可靠请求 ID'
        req = json.dumps([t, a.get('event.sequence'), model, [a.get(k) for k in
            ('input_tokens','output_tokens','cache_read_tokens','cache_creation_tokens')]])
    write = integer(a.get('cache_creation_tokens'))
    ws, wl = integer(a.get('cache_creation_5m_tokens')), integer(a.get('cache_creation_1h_tokens'))
    if write == 0 and ws is None and wl is None:
        ws, wl = 0, 0
    if write is None or ws is None or wl is None or ws + wl != write:
        issue = '缓存写入 TTL 缺失或分桶不一致'
    return dict(id=hashlib.sha256(('claude:'+req).encode()).hexdigest(), timestamp=t,
        agent='Claude Code', model=model, input=integer(a.get('input_tokens')),
        read=integer(a.get('cache_read_tokens')), write_short=ws, write_long=wl,
        write_total=write, output=integer(a.get('output_tokens')),
        speed=a.get('speed') if a.get('speed') in ('normal','fast') else 'unknown',
        context='request', issue=issue)

def otlp_events(obj):
    if not isinstance(obj, dict):
        return
    for resource in obj.get('resourceLogs', []):
        # resource identity attributes are never projected or retained.
        for scope in resource.get('scopeLogs', []):
            for record in scope.get('logRecords', []):
                if isinstance(record, dict):
                    e = claude_event(record)
                    if e:
                        yield e

class Ledger:
    def __init__(self, path):
        self.lock = threading.RLock()
        self.db = sqlite3.connect(str(path), check_same_thread=False)
        self.db.execute('CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, body TEXT NOT NULL)')
        self.db.execute('CREATE TABLE IF NOT EXISTS diagnostics (reason TEXT PRIMARY KEY, deliveries INTEGER NOT NULL)')
        self.db.execute("CREATE INDEX IF NOT EXISTS events_timestamp_idx ON events(json_extract(body,'$.timestamp'))")
        self.db.commit()
        self._events_key=None
        self._events=[]
        self._last_rowid=0
        self._hook_count=0
    def version(self):
        with self.lock:
            return (self.db.execute('PRAGMA data_version').fetchone()[0],self.db.total_changes)
    def add(self, e):
        with self.lock:
            cur = self.db.execute('INSERT OR IGNORE INTO events VALUES (?,?)',
                                  (e['id'], json.dumps(e, separators=(',',':'))))
            self.db.commit()
            return cur.rowcount == 1
    def events(self):
        with self.lock:
            key=self.version()
            if key!=self._events_key:
                # Production ledger is append-only. Import and hooks share the same primary ID.
                for rowid,body in self.db.execute('SELECT rowid,body FROM events WHERE rowid>? ORDER BY rowid',(self._last_rowid,)):
                    event=json.loads(body);self._events.append(event);self._last_rowid=rowid
                    if event.get('source')=='PostModelRequest':self._hook_count+=1
                self._events_key=key
            return self._events
    def close(self):
        self.db.close()
    def recent(self,limit=40,speed='all'):
        with self.lock:
            where='';params=[]
            if speed=='unknown':
                where=" WHERE COALESCE(json_extract(body,'$.speed'),'unknown') NOT IN ('normal','fast','flex','ultrafast')"
            elif speed in ('normal','fast','flex','ultrafast'):
                where=" WHERE json_extract(body,'$.speed')=?";params.append(speed)
            return [json.loads(r[0]) for r in self.db.execute("SELECT body FROM events"+where+" ORDER BY json_extract(body,'$.timestamp') DESC LIMIT ?",(*params,limit))]
    def reject(self, reason):
        with self.lock:
            self.db.execute('INSERT INTO diagnostics VALUES (?,1) ON CONFLICT(reason) DO UPDATE SET deliveries=deliveries+1', (reason,))
            self.db.commit()
    def diagnostics(self):
        with self.lock:
            return dict(self.db.execute('SELECT reason,deliveries FROM diagnostics'))

class Receiver:
    def __init__(self, ledger):
        self.ledger = ledger
        self.secret = secrets.token_hex(24)
        self.last = None
        self.accepted = 0
        self.rejected = 0
        self.lock = threading.RLock()
        self.active = True
        parent = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_POST(self):
                if self.path != '/v1/logs/'+parent.secret or self.headers.get('Origin'):
                    self.send_error(403); return
                try:
                    size = int(self.headers.get('Content-Length', '0'))
                    if not 0 < size <= 2*1024*1024:
                        self.send_error(413); return
                    if self.headers.get('Content-Encoding') or 'application/json' not in self.headers.get('Content-Type',''):
                        self.send_error(415); return
                    self.connection.settimeout(3)
                    payload = json.loads(self.rfile.read(size))
                    events = list(otlp_events(payload))
                    del payload
                    with parent.lock:
                        if not parent.active:
                            self.send_error(503); return
                        for e in events:
                            if parent.ledger.add(e):
                                parent.accepted += 1
                                parent.last = e['timestamp']
                    self.send_response(200)
                    self.send_header('Content-Type','application/json')
                    self.send_header('Content-Length','2')
                    self.end_headers(); self.wfile.write(b'{}')
                except Exception:
                    parent.rejected += 1
                    self.send_error(400)
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
    @property
    def endpoint(self):
        return f'http://127.0.0.1:{self.port}/v1/logs/{self.secret}'
    def stop(self):
        with self.lock:
            self.active = False
        self.server.shutdown(); self.server.server_close()

def demo_events():
    now = dt.datetime.now(dt.timezone.utc)
    first = now.replace(day=1,hour=10,minute=0,second=0,microsecond=0)
    previous = (first-dt.timedelta(days=1)).replace(day=12)
    models = list(CATALOG['models'])
    out = []
    for i in range(40):
        m = models[i % len(models)]
        e = dict(id='demo-'+str(i),timestamp=(first if i < 28 else previous).isoformat(),
                 agent='Codex' if m.startswith('gpt') else 'Claude Code',model=m,
                 input=12000+i*700,read=14000+i*1000,write_short=6000,write_long=2000,
                 write_total=8000,output=2500+i*300,speed='normal',context='short',issue='')
        out.append(e)
    out.append(dict(out[0],id='demo-unknown',model='unverified-model',input=5000))
    out.append(dict(out[5],id='demo-ttl',write_short=None,write_long=None,issue='缓存写入 TTL 缺失或分桶不一致'))
    return out

class Engine:
    def __init__(self, data):
        self.data = Path(data)
        self.data.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.data, 0o700)
        self.live = Ledger(self.data/'usage.sqlite3')
        self.demo = demo_events()
        self.mode = 'live'
        self.receiver = None
        self.codex_enabled = False
        self.subscription_lock=threading.RLock()
        self.subscriptions={k:subscriptions.result() for k in ('Codex','Claude Code')}
        self.closed=False
        (self.data/'codex-consent.json').unlink(missing_ok=True)
        self.settings_file = self.data/'preferences.json'
        try:
            self.settings = json.loads(self.settings_file.read_text())
        except (OSError, ValueError):
            self.settings = {'plans':{},'plan_overrides':{},'timezone':'本机时区'}
        self.message = '尚未连接真实来源 · 空账本不代表零消费'
        self._snapshot_cache={}
        self.history_sync=None
        self.history_once=None
        if self.settings.get('history_sync_enabled') is True:self.start_history_sync()
    def save_settings(self):
        tmp=self.settings_file.with_suffix('.tmp');tmp.write_text(json.dumps(self.settings));tmp.chmod(0o600);tmp.replace(self.settings_file)
    def start_history_sync(self):
        from history_sync import HistorySync
        if self.history_once and self.history_once.is_alive():raise ValueError('正在补录历史，请完成后再连接自动同步。')
        if self.history_sync and self.history_sync.thread and self.history_sync.thread.is_alive():return
        self.history_sync=HistorySync(self.data);self.history_sync.start()
    def sync_history_once(self):
        from history_sync import HistorySync
        if self.history_sync and self.history_sync.thread and self.history_sync.thread.is_alive():
            self.history_sync.wake();return
        if self.history_once and self.history_once.is_alive():return
        worker=HistorySync(self.data)
        def run():
            try:worker.poll()
            except Exception:worker.publish(state='error',error='本次补录失败；原始记录未修改，可重试。')
        self.history_once=threading.Thread(target=run,daemon=True);self.history_once.start()
    def snapshot(self, query):
        if self.codex_enabled:
            self.codex_lease()
        with self.subscription_lock:statuses=json.dumps(self.subscriptions,sort_keys=True)
        report=self.data/'history-import-status.json'
        report_version=report.stat().st_mtime_ns if report.exists() else 0
        sync_report=self.data/'history-sync-status.json'
        sync_version=sync_report.stat().st_mtime_ns if sync_report.exists() else 0
        key=(self.mode,self.live.version(),len(self.demo),query.get('month'),query.get('agent'),query.get('model'),query.get('speed'),
             json.dumps(self.settings,sort_keys=True),statuses,self.message,self.codex_enabled,
             self.receiver.accepted if self.receiver else None,self.receiver.rejected if self.receiver else None,
             dt.datetime.now().astimezone().date(),dt.datetime.now(dt.timezone.utc).date(),report_version,sync_version)
        if key not in self._snapshot_cache:
            if len(self._snapshot_cache)>24:self._snapshot_cache.clear()
            self._snapshot_cache[key]=self._snapshot(query)
        return self._snapshot_cache[key]
    def _snapshot(self, query):
        events = self.demo if self.mode == 'demo' else self.live.events()
        # UTC is explicit and stable across travel. Local timezone is available as a display choice.
        zone = dt.timezone.utc if self.settings.get('timezone') == 'UTC' else None
        def month(e):
            if not e.get('timestamp'):
                return '未知月份'
            d = dt.datetime.fromisoformat(e['timestamp'])
            return d.astimezone(zone).strftime('%Y-%m')
        now=dt.datetime.now(dt.timezone.utc).astimezone(zone)
        current=now.strftime('%Y-%m');today=now.date()
        index_key=(self.mode,self.settings.get('timezone'),today,id(events))
        if getattr(self,'_index_key',None)!=index_key:
            self._groups={};self._row_cache={};self._today=[]
            self._today_priced=[];self._hook_count=0;self._indexed_count=0
            self._index_key=index_key
        if len(events)>self._indexed_count:
            for e in events[self._indexed_count:]:
                mon=month(e)
                group=(mon,e['agent'],e['model'])
                self._groups.setdefault(group,[]).append(e)
                for tier in ('all','normal','fast','flex','ultrafast','unknown'):self._row_cache.pop((group,tier),None)
                if e.get('timestamp') and dt.datetime.fromisoformat(e['timestamp']).astimezone(zone).date()==today:
                    self._today.append(e);self._today_priced.append(price(e)[0])
                if e.get('source')=='PostModelRequest':self._hook_count+=1
            self._indexed_count=len(events)
        months=sorted({current,*(k[0] for k in self._groups)},reverse=True)
        selected=query.get('month') or current
        agents=sorted({k[1] for k in self._groups if k[0]==selected})
        agent=query.get('agent','全部');model=query.get('model','全部模型')
        speed=query.get('speed','all')
        if speed not in ('all','normal','fast','flex','ultrafast','unknown'):speed='all'
        def row(key,tier='all'):
            cache_key=(key,tier)
            if cache_key in self._row_cache:return self._row_cache[cache_key]
            sub=self._groups[key] if tier=='all' else [e for e in self._groups[key] if recorded_speed(e)==tier]
            m=key[2];priced=[price(e) for e in sub]
            p=CATALOG['models'].get(m,{})
            r=dict(model=m,agent=key[1],count=len(sub),amount=sum(n for n,_ in priced if n is not None),
                unpriced=sum(n is None for n,_ in priced),reason='；'.join(sorted({r for n,r in priced if n is None})),
                buckets={k:(None if any(e.get(k) is None for e in sub) else sum(e[k] for e in sub)) for k in BUCKETS},
                write_total=sum(e.get('write_total') or 0 for e in sub),
                cache_accounting=p.get('cache_accounting','separate_writes'),mix=token_mix(sub),
                cost_buckets=priced_components(sub),rates=p,applied_rates=applied_rates(sub,priced),speeds=speed_breakdown(sub,priced),
                standard_fallback=sum(standard_fallback(e) and n is not None for e,(n,_) in zip(sub,priced)),
                pricing_basis=CATALOG['reference_basis'],
                agent_price_source=CATALOG.get('agent_review',{}).get(key[1],{}).get('source',''),
                source=p.get('source',CATALOG['sources'].get('anthropic' if p.get('provider')=='anthropic' else 'openai','')))
            self._row_cache[cache_key]=r;return r
        def combine_mix(rows):
            values={k:sum(r['mix']['values'][k] for r in rows) for k in ('input','read','write','output')}
            return dict(values=values,total=sum(values.values()),incomplete=any(r['mix']['incomplete'] for r in rows))
        keys=[k for k in self._groups if k[0]==selected and (agent=='全部' or k[1]==agent)]
        models=sorted({k[2] for k in keys})
        rows=sorted([r for k in keys if (model=='全部模型' or k[2]==model) and (r:=row(k,speed))['count']],key=lambda r:r['amount'],reverse=True)
        current_rows=[row(k) for k in self._groups if k[0]==current]
        amount=sum(r['amount'] for r in rows)
        with self.subscription_lock: statuses={k:dict(v) for k,v in self.subscriptions.items()}
        overrides=self.settings.get('plan_overrides',{})
        plans={k:overrides.get(k,statuses[k].get('reference_usd')) for k in statuses}
        chosen=list(plans) if agent=='全部' else [agent]
        plan=sum(plans[k] for k in chosen) if all(plans[k] is not None for k in chosen) else None
        current_plan=sum(plans.values()) if all(v is not None for v in plans.values()) else None
        try:history=json.loads((self.data/'history-import-status.json').read_text()) if self.mode=='live' else {}
        except (OSError,ValueError):history={}
        from history_sync import HistorySync
        sync=HistorySync.saved_status(self.data)
        sync['active']=bool(self.history_sync and self.history_sync.thread and self.history_sync.thread.is_alive() and not self.history_sync.stop_event.is_set())
        sync['enabled']=self.settings.get('history_sync_enabled') is True
        activity=[]
        for e in (sorted([e for e in self.demo if speed=='all' or recorded_speed(e)==speed],key=lambda e:e.get('timestamp',''),reverse=True)[:40] if self.mode=='demo' else self.live.recent(speed=speed)):
            amount_event,reason=price(e)
            activity.append(dict(id=e['id'],timestamp=e.get('timestamp'),received_at=e.get('received_at'),
                model=e['model'],agent=e['agent'],conversation=e.get('conversation'),amount=amount_event,reason=reason,
                speed=recorded_speed(e),standard_fallback=standard_fallback(e) and amount_event is not None,
                input=e.get('input'),read=e.get('read'),write=e.get('write_total'),output=e.get('output'),mix=token_mix([e])))
        return dict(mode=self.mode,months=months,month=selected,agents=agents,selected_agent=agent,selected_model=model,selected_speed=speed,models=models,rows=rows,history=history,history_sync=sync,activity=activity,
            standard_fallback=sum(r['standard_fallback'] for r in rows),
            amount=amount,unpriced=sum(r['unpriced'] for r in rows),count=sum(r['count'] for r in rows),
            current=current,current_count=sum(r['count'] for r in current_rows),current_amount=sum(r['amount'] for r in current_rows),
            current_unpriced=sum(r['unpriced'] for r in current_rows),plan=plan,plans=plans,
            subscriptions=statuses,plan_overrides=overrides,current_plan=current_plan,
            mix=combine_mix(rows),cost_buckets={k:sum(r['cost_buckets'][k] for r in rows) for k in BUCKETS},
            current_mix=combine_mix(current_rows),today_count=len(self._today),
            today_amount=sum(n for n in self._today_priced if n is not None),today_unpriced=sum(n is None for n in self._today_priced),
            primary_metric=self.settings.get('primary_metric','month_cost'),
            timezone=self.settings.get('timezone','UTC'),message=(
                '接收中 · 已收到 API request 事件；仅覆盖连接后的本机会话'
                if self.receiver and self.receiver.accepted else self.message),
            receiving=self.receiver is not None,
            received=self.receiver.accepted if self.receiver else 0,
            last=self.receiver.last if self.receiver else None,
            rejected=self.receiver.rejected if self.receiver else 0,
            codex_enabled=self.codex_enabled,
            codex_count=(self.live.events() and self.live._hook_count) or 0,
            codex_rejected=sum(self.live.diagnostics().values()),
            checked=CATALOG['checked'])
    def detect_plan(self,agent,binary=None,project=None):
        if agent not in self.subscriptions:return
        with self.subscription_lock:
            if self.subscriptions[agent]['state']=='loading':return
            self.subscriptions[agent]=subscriptions.result('正在识别…',state='loading')
        def worker():
            try:
                executable=binary or subscriptions.find_binary(agent)
                if not executable:
                    status=subscriptions.result('未找到官方 CLI',state='unavailable')
                else:
                    fn=subscriptions.codex_lookup if agent=='Codex' else subscriptions.claude_lookup
                    status=fn(executable,str(project or self.data))
            except Exception:
                status=subscriptions.result('暂时无法识别',state='unavailable',detail='官方登录状态未返回可用信息；不会读取凭据文件补猜。')
            with self.subscription_lock:
                if not self.closed:self.subscriptions[agent]=status
        threading.Thread(target=worker,daemon=True).start()
    def codex_lease(self):
        f=self.data/'codex-consent.json'
        tmp=f.with_suffix('.tmp')
        tmp.write_text(json.dumps({'expires':time.time()+12}))
        os.chmod(tmp,0o600);tmp.replace(f)
    def prepare_codex(self):
        folder=self.data/'Codex Hook Setup'
        folder.mkdir(exist_ok=True,mode=0o700)
        command=' '.join(shlex.quote(v) for v in [sys.executable,'-B',str(ROOT/'codex_hook.py'),'--data',str(self.data)])
        config={'hooks':{'PostModelRequest':[{'hooks':[{'type':'command','command':command,'timeout':3}]}]}}
        (folder/'hooks.fragment.json').write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n')
        (folder/'请先阅读.txt').write_text(
            'AI Cost Estimator · Codex 接入准备（未安装、未信任、未开启）\n\n'
            '这里的 hooks.fragment.json 只是待合并片段，不会被 Codex 自动发现。\n'
            '如决定使用，将它的 PostModelRequest 条目合并到你选定的官方 hooks.json 中，保留全部现有条目。'
            '不要直接覆盖已有文件。CLI 用 /hooks，桌面用 Review hooks 或 Settings > Hooks 审阅并信任；'
            '不修改信任数据库、不使用绕过选项。现有会话能否热载入尚未验证，必要时新开会话。\n\n'
            '随后回到 AI Cost Estimator 点击“允许本次接收…”并同意。应用运行时每 3 秒续约，退出/停止或超过 12 秒无续约即拒收。'
            '不需要 API key，不读取 transcript_path/cwd，不上传。只保存散列去重 ID、接收时间、模型和 token 桶。\n\n'
            '兼容证据：本机 CLI 0.166.0-alpha.5.1 在隔离配置中识别该事件，未信任。'
            '未验证桌面真实事件。公开 main schema 提供 response_id 或 thread_id/request_id/attempt_number；'
            '本机实际字段仍待验证。缺这些字段的投递只累计拒收次数，不猜测去重，不进入金额。\n'
            'schema 没有档位，当前 hook 请求将显示未定价；有差价的缓存写入也缺 TTL。'
            'gpt-5.4-mini 系列与 gpt-5.3-codex 没有独立写入费，缺 TTL 不阻止其计价，但未知档位仍阻止。\n'
            '月份按本机收到 hook 的时间，非模型开始时间；不补历史，不涵盖其他设备/云端/断开期间。\n\n'
            '官方说明：https://learn.chatgpt.com/docs/hooks\n')
        return str(folder)
    def disconnect(self):
        if self.receiver:
            self.receiver.stop(); self.receiver=None
        for f in ('Start Claude.command','session-settings.json'):
            (self.data/f).unlink(missing_ok=True)
        self.message='已断开 · 已保存的本机用量仍可查看'
    def connect(self, binary, project, detect_plan=False):
        # Only called by the explicit native consent action. Never by start-up or refresh.
        p = Path(binary)
        if not p.is_file() or not os.access(p, os.X_OK):
            raise ValueError('没有找到可执行的 Claude Code；请先安装官方 CLI 或选择已安装的程序。')
        if not Path(project).is_dir():
            raise ValueError('工作目录无效')
        # Refuse existing telemetry rather than silently redirecting it. Contents aren't logged.
        keys = ('OTEL_', 'CLAUDE_CODE_ENABLE_TELEMETRY', 'BETA_TRACING', 'ENABLE_ENHANCED_TELEMETRY', 'CLAUDE_CODE_ENHANCED_TELEMETRY')
        if any(k.startswith(keys) for k in os.environ):
            raise ValueError('检测到已配置的遥测环境。为避免覆盖，本次连接已停止。')
        # Managed settings cannot be disabled by --setting-sources. Do not bypass them.
        managed = Path('/Library/Application Support/ClaudeCode')
        if (managed/'managed-settings.json').exists() or (managed/'managed-settings.d').exists():
            raise ValueError('检测到受管理 Claude 设置。需要管理员确认不会覆盖遥测后再接入。')
        version = subprocess.run([str(p),'--version'],capture_output=True,text=True,timeout=8)
        match = re.search(r'\b(\d+)\.(\d+)\.(\d+)\b', version.stdout)
        if version.returncode or not match or tuple(map(int,match.groups())) < (2,1,300):
            raise ValueError('需要 Claude Code 2.1.300 或更新版本以支持写入 TTL 分桶。')
        self.disconnect()
        self.receiver=Receiver(self.live)
        env = {
            'CLAUDE_CODE_ENABLE_TELEMETRY':'1','OTEL_LOGS_EXPORTER':'otlp',
            'OTEL_EXPORTER_OTLP_LOGS_PROTOCOL':'http/json',
            'OTEL_EXPORTER_OTLP_LOGS_ENDPOINT':self.receiver.endpoint,
            'OTEL_LOG_USER_PROMPTS':'0','OTEL_LOG_ASSISTANT_RESPONSES':'0',
            'OTEL_LOG_TOOL_DETAILS':'0','OTEL_LOG_TOOL_CONTENT':'0','OTEL_LOG_RAW_API_BODIES':'0',
            'OTEL_LOG_MANAGED_SETTINGS':'0','CLAUDE_CODE_ENHANCED_TELEMETRY_BETA':'0',
            'ENABLE_ENHANCED_TELEMETRY_BETA':'0','OTEL_METRICS_EXPORTER':'none',
            'OTEL_TRACES_EXPORTER':'none','OTEL_METRICS_INCLUDE_ACCOUNT_UUID':'false',
            'OTEL_METRICS_INCLUDE_SESSION_ID':'false','OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES':'false',
            'OTEL_METRICS_INCLUDE_REPOSITORY':'false','OTEL_LOGS_EXPORT_INTERVAL':'1000'}
        sf = self.data/'session-settings.json'
        sf.write_text(json.dumps({'env':env})); os.chmod(sf,0o600)
        # -f avoids shell startup files changing exporters. Settings apply to this new session only.
        cmd = ' '.join(shlex.quote(x) for x in [str(p),'--setting-sources','','--settings',str(sf)])
        launcher = self.data/'Start Claude.command'
        guard = "if /usr/bin/env | /usr/bin/cut -d= -f1 | /usr/bin/grep -Eq '^(OTEL_|CLAUDE_CODE_ENABLE_TELEMETRY|BETA_TRACING|ENABLE_ENHANCED_TELEMETRY|CLAUDE_CODE_ENHANCED_TELEMETRY)'; then\n  print 'Existing telemetry environment detected. AI Cost Estimator did not start a new session.'\n  exit 1\nfi\n"
        launcher.write_text('#!/bin/zsh -f\n'+guard+'cd '+shlex.quote(project)+' || exit 1\nexec '+cmd+'\n')
        os.chmod(launcher,0o700)
        self.mode='live'
        self.message='接收器已开启 · 等待新 Claude 会话的 API request；尚未验证真实接通'
        if detect_plan:self.detect_plan('Claude Code',binary,project)
        return str(launcher)
    def command(self, q):
        action=q.get('action','snapshot')
        result={}
        if action=='history-change':
            if self.history_sync:self.history_sync.wake()
            return {'ack':True}
        if action == 'enable-history-sync' and q.get('consent') is True:
            self.start_history_sync();self.settings['history_sync_enabled']=True;self.save_settings();self.mode='live'
        elif action == 'disable-history-sync':
            self.settings['history_sync_enabled']=False;self.save_settings()
            if self.history_sync:self.history_sync.stop()
        elif action == 'sync-history-once' and q.get('consent') is True:
            self.sync_history_once();self.mode='live'
        elif action == 'mode':
            self.mode='demo' if q.get('value')=='demo' else 'live'
        elif action == 'demo-refresh':
            self.mode='demo'
            e=dict(self.demo[0],id='refresh-'+secrets.token_hex(5),timestamp=dt.datetime.now(dt.timezone.utc).isoformat())
            self.demo.append(e)
        elif action == 'demo-codex-hook':
            self.mode='demo'
            e=codex_event({'hook_event_name':'PostModelRequest','response_id':'synthetic-ui-hook',
                'model':'gpt-5.4-mini','status':'completed','token_usage':{'input_tokens':12000,
                'cached_input_tokens':4000,'output_tokens':2000,'reasoning_output_tokens':1000,'total_tokens':14000}})
            if not any(x['id']==e['id'] for x in self.demo):self.demo.append(e)
            self.message='模拟 hook 已处理 · 重复点击不重复入账；未知档位保持未定价'
        elif action == 'prepare-codex':
            result['reveal']=self.prepare_codex()
        elif action == 'enable-codex':
            self.codex_enabled=True;self.codex_lease();self.mode='live'
            self.message='仅允许本次 Codex hook 接收 · 尚不代表桌面 hook 已安装或接通'
            if q.get('detect_plan') is True:self.detect_plan('Codex')
        elif action == 'disable-codex':
            self.codex_enabled=False;(self.data/'codex-consent.json').unlink(missing_ok=True)
        elif action == 'detect-plan':
            if q.get('consent') is True:self.detect_plan(q.get('provider'))
        elif action == 'reset-plan-overrides':
            self.settings['plan_overrides']={}
            self.settings_file.write_text(json.dumps(self.settings));os.chmod(self.settings_file,0o600)
        elif action == 'preferences':
            values=q.get('plans',{})
            for k in ('Codex','Claude Code'):
                v=values.get(k)
                if k in values and v is None:
                    self.settings.setdefault('plan_overrides',{}).pop(k,None)
                elif type(v) in (float,int) and 0 <= v <= 100000:
                    self.settings['plans'][k]=float(v)
                    self.settings.setdefault('plan_overrides',{})[k]=float(v)
            self.settings['timezone']='UTC' if q.get('timezone','UTC')=='UTC' else '本机时区'
            tmp=self.settings_file.with_suffix('.tmp')
            tmp.write_text(json.dumps(self.settings)); os.chmod(tmp,0o600); tmp.replace(self.settings_file)
        elif action == 'display-preferences':
            if q.get('metric') in ('month_cost','today_cost','month_tokens','plan_ratio'):
                self.settings['primary_metric']=q['metric']
                tmp=self.settings_file.with_suffix('.tmp')
                tmp.write_text(json.dumps(self.settings));os.chmod(tmp,0o600);tmp.replace(self.settings_file)
        elif action == 'connect':
            result['launcher']=self.connect(q.get('binary',''),q.get('project',''),q.get('detect_plan') is True)
        elif action == 'disconnect':
            self.disconnect()
        result['snapshot']=self.snapshot(q)
        return result
    def close(self):
        self.closed=True
        if self.history_sync:self.history_sync.stop()
        (self.data/'codex-consent.json').unlink(missing_ok=True)
        self.disconnect(); self.live.close()

def main():
    os.umask(0o077)
    engine=Engine(sys.argv[1])
    try:
        for line in sys.stdin:
            try:
                q=json.loads(line)
                response=engine.command(q)
            except Exception as e:
                # Only controlled errors, never a raw telemetry payload or subprocess output.
                response={'error':str(e) if isinstance(e, ValueError) else '本机服务操作失败；请检查应用运行权限。'}
            print(json.dumps(response,ensure_ascii=False),flush=True)
    finally:
        engine.close()

if __name__=='__main__':
    main()
