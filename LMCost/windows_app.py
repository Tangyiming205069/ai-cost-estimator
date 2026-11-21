"""Windows desktop preview. Uses the shared ledger; collection starts only on opt-in."""
import json, os, queue, subprocess, sys, threading, tkinter as tk
from pathlib import Path
from tkinter import ttk, messagebox

SPEEDS=['all','normal','fast','ultrafast','flex','unknown']
def amount(value): return '—' if value is None else f'${value:,.2f}'
def tokens(value): return '—' if value is None else f'{value:,}'

class Window:
    def __init__(self, root, data, start_backend=True):
        self.root=root; self.data=Path(data); self.data.mkdir(parents=True,exist_ok=True)
        self.prefs_file=self.data/'windows-ui.json'
        try: self.prefs=json.loads(self.prefs_file.read_text(encoding='utf-8'))
        except (OSError,ValueError): self.prefs={}
        self.lang=self.prefs.get('language','en'); self.expanded=False; self.snapshot={}; self.pending=False
        self.results=queue.Queue(); self.process=None; self.rows=[]
        self.month=tk.StringVar(); self.agent=tk.StringVar(value=self.t('All agents','全部')); self.model=tk.StringVar(value=self.t('All models','全部模型')); self.speed=tk.StringVar(value='all')
        root.title('AI Cost Estimator'); root.attributes('-topmost',True); root.protocol('WM_DELETE_WINDOW',self.close)
        root.configure(bg='#f5f6f8'); root.resizable(False,False)
        self.compact=ttk.Frame(root,padding=(12,6)); self.compact.pack(fill='both',expand=True)
        self.total=ttk.Button(self.compact,text='—',command=self.toggle);self.total.pack(side='left',fill='x',expand=True)
        ttk.Button(self.compact,text='↗',width=3,command=self.toggle).pack(side='right')
        self.body=ttk.Frame(root,padding=14)
        toolbar=ttk.Frame(self.body);toolbar.pack(fill='x')
        self.connect=ttk.Button(toolbar,command=self.connection);self.connect.pack(side='left')
        ttk.Button(toolbar,text='English / 中文',command=self.language).pack(side='left',padx=6)
        self.collapse=ttk.Button(toolbar,command=self.toggle);self.collapse.pack(side='right')
        self.status=ttk.Label(self.body);self.status.pack(anchor='w',pady=8)
        filters=ttk.Frame(self.body);filters.pack(fill='x')
        self.boxes=[]
        for variable,width in [(self.month,10),(self.agent,14),(self.model,22),(self.speed,12)]:
            box=ttk.Combobox(filters,textvariable=variable,width=width,state='readonly');box.pack(side='left',padx=(0,6));box.bind('<<ComboboxSelected>>',self.filter);self.boxes.append(box)
        self.boxes[3]['values']=SPEEDS
        self.summary=ttk.Label(self.body,font=('Segoe UI',22));self.summary.pack(anchor='w',pady=(12,4))
        self.note=ttk.Label(self.body,wraplength=660);self.note.pack(anchor='w',pady=(0,10))
        self.table=ttk.Treeview(self.body,columns=('model','requests','value'),show='headings',height=7)
        for key,width in [('model',300),('requests',100),('value',180)]: self.table.column(key,width=width,anchor='w')
        self.table.pack(fill='x');self.table.bind('<<TreeviewSelect>>',self.details)
        self.detail=tk.Text(self.body,height=10,wrap='word',font=('Segoe UI',10),relief='flat',bg='#f5f6f8');self.detail.pack(fill='both',expand=True,pady=8)
        self.footer=ttk.Label(self.body,wraplength=660);self.footer.pack(anchor='w')
        self.translate(); self.size()
        x,y=self.prefs.get('x',80),self.prefs.get('y',80)
        root.geometry(f'+{max(0,min(int(x),root.winfo_screenwidth()-260))}+{max(0,min(int(y),root.winfo_screenheight()-100))}')
        if start_backend:
            env=dict(os.environ,PYTHONUTF8='1',PYTHONDONTWRITEBYTECODE='1')
            self.process=subprocess.Popen([sys.executable,'-u',str(Path(__file__).with_name('engine.py')),str(self.data)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,encoding='utf-8',env=env,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            threading.Thread(target=self.read,daemon=True).start();self.send();root.after(150,self.poll)
    def t(self,en,zh): return zh if self.lang=='zh' else en
    def translate(self):
        self.collapse.configure(text=self.t('Collapse','收起'))
        for key,en,zh in [('model','Model','模型'),('requests','Requests','请求数'),('value','API value','API 等价值')]: self.table.heading(key,text=self.t(en,zh))
        self.footer.configure(text=self.t('API-equivalent estimate, not a bill. This device only. Windows preview: local Codex files; WSL and Claude Code are not connected. Minimize to the taskbar to hide.','API 等价估算，非账单；仅此设备。Windows 预览版仅接入本机 Codex 文件，尚未接入 WSL 和 Claude Code。最小化到任务栏可隐藏。'))
    def size(self): self.root.geometry('720x600' if self.expanded else '260x52')
    def toggle(self):
        self.expanded=not self.expanded
        if self.expanded:self.compact.pack_forget();self.body.pack(fill='both',expand=True)
        else:self.body.pack_forget();self.compact.pack(fill='both',expand=True)
        self.size()
    def language(self):
        self.lang='zh' if self.lang=='en' else 'en';self.translate();self.render(self.snapshot)
    def query(self): return dict(month=self.month.get(),agent='全部' if self.agent.get() in ('All agents','全部') else self.agent.get(),model='全部模型' if self.model.get() in ('All models','全部模型') else self.model.get(),speed=self.speed.get())
    def send(self,action='snapshot',**extra):
        if not self.process or self.process.poll() is not None:return
        q=dict(self.query(),action=action,**extra)
        try:self.process.stdin.write(json.dumps(q)+'\n');self.process.stdin.flush();self.pending=True
        except (OSError,ValueError):self.status.configure(text=self.t('Service disconnected. Reopen the tool.','服务断开，请重新打开工具。'))
    def read(self):
        for line in self.process.stdout:
            try:self.results.put(json.loads(line))
            except ValueError:pass
    def poll(self):
        while not self.results.empty():
            result=self.results.get();self.pending=False
            if 'snapshot' in result:
                s=result['snapshot'];q=self.query()
                if (not q['month'] or s['month']==q['month']) and all(s.get('selected_'+k)==q[k] for k in ('agent','model','speed')):self.render(s)
            if 'error' in result:self.status.configure(text=result['error'])
        if self.process.poll() is not None:self.status.configure(text=self.t('Service stopped. Reopen the tool.','服务已停止，请重新打开工具。'))
        elif not self.pending:self.send()
        self.root.after(1000,self.poll)
    def filter(self,event=None):
        if event and event.widget==self.boxes[0]:self.agent.set(self.t('All agents','全部'));self.model.set(self.t('All models','全部模型'))
        if event and event.widget==self.boxes[1]:self.model.set(self.t('All models','全部模型'))
        self.send()
    def connection(self):
        if self.snapshot.get('history_sync',{}).get('enabled'):self.send('disable-history-sync');return
        text=self.t('Read local Codex usage files on this Windows account every 5 seconds while open? Keep only usage metadata locally, never prompts or replies. No uploads or agent configuration changes. This choice is remembered. WSL/remote devices are not included.','打开期间每 5 秒读取此 Windows 账户的本地 Codex 用量文件？仅在本机保存用量字段，不保存对话、不上传、不修改 Agent 配置。此选择会记住，不含 WSL 或远程设备。')
        if messagebox.askyesno('AI Cost Estimator',text,parent=self.root):self.send('enable-history-sync',consent=True)
    def render(self,s):
        if not s:return
        self.snapshot=s;active=s.get('history_sync',{}).get('active',False)
        self.connect.configure(text=self.t('Pause sync' if active else 'Connect Codex','暂停同步' if active else '连接 Codex'))
        self.status.configure(text=self.t('Live · local Codex' if active else 'Not collecting','正在跟进 · 本机 Codex' if active else '未采集'))
        self.month.set(s['month']);self.boxes[0]['values']=s['months']
        agents=s.get('agents',[]);self.boxes[1]['values']=[self.t('All agents','全部')]+agents if len(agents)>1 else agents
        if len(agents)>1:self.boxes[1].pack(side='left',before=self.boxes[2],padx=(0,6))
        else:self.boxes[1].pack_forget()
        self.boxes[2]['values']=[self.t('All models','全部模型')]+s['models']
        self.total.configure(text=self.t('This month  ','本月  ')+amount(s['current_amount'] if s['current_count']>s['current_unpriced'] else None))
        self.summary.configure(text=amount(s['amount'] if s['count']>s['unpriced'] else None))
        mix=s.get('mix',{});counts=mix.get('values',{});total=mix.get('total',0)
        shares=' · '.join(f'{self.t(en,zh)} {counts.get(k,0)/total:.1%}' if total else f'{self.t(en,zh)} —' for k,en,zh in [('input','Input','输入'),('output','Output','输出'),('read','Cache read','缓存读'),('write','Cache write','缓存写')])
        self.note.configure(text=f"{s['count']:,} "+self.t('requests','次请求')+f" · {s['unpriced']:,} "+self.t('unpriced','未定价')+f" · {s.get('timezone','UTC')}\n"+shares)
        rows=s['rows']
        if rows!=self.rows:
            self.rows=rows;self.table.delete(*self.table.get_children())
            for i,r in enumerate(rows):self.table.insert('', 'end',iid=str(i),values=(r['model'],r['count'],amount(r['amount'] if r['count']>r['unpriced'] else None)))
            self.details()
    def details(self,event=None):
        selected=self.table.selection();lines=[]
        if selected:
            r=self.rows[int(selected[0])]
            for tier in r.get('speeds',[]):lines.append(f"{tier['speed']}: {tier['count']:,} · {amount(tier['amount'] if tier['count']>tier['unpriced'] else None)}"+(' · Standard reference' if tier.get('standard_fallback') else ''))
            for key in ('input','read','write_short','write_long','output'):
                rates=r.get('applied_rates',{}).get(key,[])
                lines.append(f"{key}: {tokens(r['buckets'].get(key))} | /1M: {', '.join(str(v) for v in rates) or '—'}")
            lines.extend([r.get('reason',''),r.get('source','')])
        self.detail.configure(state='normal');self.detail.delete('1.0','end');self.detail.insert('1.0','\n'.join(lines));self.detail.configure(state='disabled')
    def close(self):
        self.prefs_file.write_text(json.dumps(dict(language=self.lang,x=self.root.winfo_x(),y=self.root.winfo_y())),encoding='utf-8')
        if self.process:
            try:self.process.stdin.close();self.process.wait(timeout=8)
            except (OSError,subprocess.TimeoutExpired):self.process.terminate()
        self.root.destroy()

if __name__=='__main__':
    if sys.platform!='win32':raise SystemExit('This desktop entry point is for Windows.')
    root=tk.Tk();Window(root,Path(os.environ.get('LOCALAPPDATA',Path.home()))/'AI Cost Estimator');root.mainloop()
