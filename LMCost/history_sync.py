"""Opt-in local history sync. No vendor settings, hooks, network, or login items."""
from __future__ import annotations
import argparse,collections,datetime as dt,json,os,sqlite3,threading,time
from pathlib import Path
from history_import import HistoryCursor

def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()

class HistorySync:
    def __init__(self,data,roots=None,interval=5):
        self.data=Path(data)
        self.roots=list(roots) if roots is not None else [Path.home()/'.codex/sessions',Path.home()/'.codex/archived_sessions']
        self.interval=interval;self.stop_event=threading.Event();self.thread=None
        self.wake_event=threading.Event()
        self.cursors={};self.signatures={};self.pending=set();self.initial=True
        self.lock=threading.RLock();self.run_lock=threading.Lock()
        self.report_path=self.data/'history-sync-status.json'
        previous=self.saved_status(self.data)
        try:historical=json.loads((self.data/'history-import-status.json').read_text())
        except (OSError,ValueError):historical={}
        cutoff=previous.get('last_scan') or (historical.get('cutoff') if historical.get('state')=='complete' else None)
        try:self.anchor=dt.datetime.fromisoformat(cutoff).timestamp()-120
        except (TypeError,ValueError):self.anchor=None
        self.status=dict(state='stopped',active=False,interval_seconds=interval,last_scan=previous.get('last_scan'),
                         last_event=previous.get('last_event'),added_this_run=0,last_added=0,files_seen=0,
                         files_read=0,pending_files=0,diagnostics={},error='',poll_seconds=0)
    @staticmethod
    def saved_status(data):
        try:return json.loads((Path(data)/'history-sync-status.json').read_text())
        except (OSError,ValueError):return {}
    def snapshot(self):
        with self.lock:return dict(self.status)
    def publish(self,**updates):
        with self.lock:
            self.status.update(updates)
            tmp=self.report_path.with_suffix('.tmp')
            tmp.write_text(json.dumps(self.status,ensure_ascii=False));tmp.chmod(0o600);tmp.replace(self.report_path)
    def inventory(self):
        found={};errors=0
        def failed(_):
            nonlocal errors
            errors+=1
        for root in self.roots:
            if root.is_symlink():errors+=1;continue
            if not root.exists():continue
            for folder,dirs,names in os.walk(root,followlinks=False,onerror=failed):
                dirs[:]=[name for name in dirs if not (Path(folder)/name).is_symlink()]
                for name in names:
                    if not (name.endswith('.jsonl') or name.endswith('.jsonl.zst')):continue
                    p=Path(folder)/name
                    try:
                        if p.is_symlink() or not p.is_file():continue
                        s=p.stat();found[p]=(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns)
                    except OSError:errors+=1
        return found,errors
    def poll(self):
        with self.run_lock:
            started=time.monotonic();scan_started=now();found,errors=self.inventory()
            counters=collections.Counter(self.status.get('diagnostics',{}))
            if errors:counters['inventory_errors']+=errors
            if self.initial:
                self.pending.update(p for p,s in found.items() if self.anchor is None or s[3]/1e9>=self.anchor)
                self.initial=False
            else:self.pending.update(p for p,s in found.items() if self.signatures.get(p)!=s)
            self.signatures=found
            self.pending.intersection_update(found)
            for p in set(self.cursors)-set(found):self.cursors.pop(p,None)
            self.publish(state='syncing',pending_files=len(self.pending),files_seen=len(found),error='')
            db=sqlite3.connect(self.data/'usage.sqlite3',timeout=30)
            db.execute('CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY,body TEXT NOT NULL)')
            added=0;read=0;last_event=self.status.get('last_event')
            try:
                for p in sorted(self.pending,key=lambda p:found[p][2]):
                    if self.stop_event.is_set():break
                    try:
                        cursor=self.cursors.setdefault(p,HistoryCursor());events,diag=cursor.read(p,cancel=self.stop_event.is_set)
                        if self.stop_event.is_set():break
                        counters.update(diag);read+=1
                        received=now()
                        for e in events:e['received_at']=received
                        before=db.total_changes
                        db.executemany('INSERT OR IGNORE INTO events VALUES (?,?)',
                            [(e['id'],json.dumps(e,ensure_ascii=False,separators=(',',':'))) for e in events])
                        db.commit();added+=db.total_changes-before
                        for e in events:
                            if e.get('timestamp') and (last_event is None or e['timestamp']>last_event):last_event=e['timestamp']
                        self.pending.discard(p)
                    except (OSError,ValueError,sqlite3.Error) as ex:
                        counters['file_errors_'+type(ex).__name__]+=1
                        self.cursors.pop(p,None)
                    except Exception as ex:
                        # zstd may reject a file while the writer is still finalizing it; retry next poll.
                        counters['file_errors_'+type(ex).__name__]+=1;self.cursors.pop(p,None)
                if not last_event:
                    last_event=db.execute("SELECT max(json_extract(body,'$.timestamp')) FROM events").fetchone()[0]
            finally:db.close()
            complete=not self.pending and not errors
            state='watching' if self.status['active'] else 'idle'
            if not complete:state='retrying'
            self.publish(state=state,last_scan=scan_started if complete else self.status.get('last_scan'),
                last_event=last_event,last_added=added,added_this_run=self.status['added_this_run']+added,
                files_read=self.status['files_read']+read,pending_files=len(self.pending),diagnostics=dict(counters),
                poll_seconds=round(time.monotonic()-started,3),
                error='' if complete else '部分文件尚未读完或暂时不可读，将在下次检查重试。')
            return self.snapshot()
    def start(self):
        if self.thread and self.thread.is_alive():return
        self.stop_event.clear();self.publish(active=True,state='starting')
        def run():
            try:
                while not self.stop_event.is_set():
                    try:self.poll()
                    except Exception:self.publish(state='error',error='本机同步暂时失败；未修改来源，下次检查重试。')
                    self.wake_event.wait(self.interval);self.wake_event.clear()
            finally:self.publish(active=False,state='stopped')
        self.thread=threading.Thread(target=run,name='lm-history-sync',daemon=True);self.thread.start()
    def stop(self):
        self.stop_event.set();self.wake_event.set()
        self.publish(active=False,state='stopping' if self.thread and self.thread.is_alive() else 'stopped')
    def wake(self):
        if not self.stop_event.is_set():self.wake_event.set()

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--data',required=True);ap.add_argument('--once',action='store_true',required=True)
    args=ap.parse_args();os.umask(0o077)
    sync=HistorySync(args.data);print(json.dumps(sync.poll(),ensure_ascii=False),flush=True)

if __name__=='__main__':main()
