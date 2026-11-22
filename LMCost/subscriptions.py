"""Explicit-consent plan lookup. Project only plan metadata; never retain identity."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import time

OPENAI_SOURCE='https://learn.chatgpt.com/docs/pricing'
CLAUDE_SOURCE='https://claude.com/pricing'
CHECKED='2026-11-15'

def result(label='连接后自动识别', plan=None, amount=None, state='pending', source='', detail=''):
    return dict(label=label,plan=plan,reference_usd=amount,state=state,source=source,checked=CHECKED,detail=detail)

def codex_plan(response):
    a=response.get('account') if isinstance(response,dict) else None
    if not isinstance(a,dict):return result('未登录或此来源未提供账户',state='unavailable',source=OPENAI_SOURCE)
    if a.get('type')=='apiKey':return result('API Key · 按量计费',state='api',source=OPENAI_SOURCE,detail='API 登录不能据此推断 ChatGPT 订阅。')
    if a.get('type')!='chatgpt':return result('外部提供商 · 未返回订阅',state='unavailable',source=OPENAI_SOURCE)
    code=a.get('planType')
    names={'free':'ChatGPT Free','go':'ChatGPT Go','plus':'ChatGPT Plus','pro':'ChatGPT Pro',
           'prolite':'ChatGPT Pro','promax':'ChatGPT Pro','team':'ChatGPT Team',
           'business':'ChatGPT Business','enterprise':'ChatGPT Enterprise','edu':'ChatGPT Edu'}
    if code not in names:return result('套餐类型暂不支持',state='unavailable',source=OPENAI_SOURCE)
    # Only map unambiguous documented public monthly references. No inference for Pro subtiers.
    amount={'free':0,'go':8,'plus':20}.get(code)
    return result(names[code],code,amount,'detected',OPENAI_SOURCE,
        '官网美元月付参考；税费、折扣和实际扣款未返回。' if amount is not None else '已识别套餐；具体价格档、席位或计费周期未确认。')

def claude_plan(response):
    if not isinstance(response,dict) or response.get('loggedIn') is not True:
        return result('未登录或无法识别',state='unavailable',source=CLAUDE_SOURCE)
    method=response.get('authMethod')
    if method in ('api_key','api_key_helper','third_party'):
        return result('API / 外部提供商 · 按量计费',state='api',source=CLAUDE_SOURCE)
    if method not in ('claude.ai','oauth_token'):
        return result('登录方式未确认',state='unavailable',source=CLAUDE_SOURCE)
    code=response.get('subscriptionType')
    names={'free':'Claude Free','pro':'Claude Pro','max':'Claude Max','ultra':'Claude Ultra','team':'Claude Team','enterprise':'Claude Enterprise'}
    if code not in names:return result('已登录 · CLI 未返回套餐类型',state='unavailable',source=CLAUDE_SOURCE,
        detail='不同 CLI / OAuth 方式可能不提供 subscriptionType；不读取凭据文件补猜。')
    # Max metadata may still describe a legacy tier. Do not map a broad name to an exact tier.
    amount={'free':0,'pro':20,'ultra':200}.get(code)
    return result(names[code],code,amount,'detected',CLAUDE_SOURCE,
        '官网美元月付参考；年付折算、税费和实际扣款未返回。' if amount is not None else '已识别套餐；具体档位或席位价格未返回。')

def codex_lookup(binary,cwd):
    """Official stdio account/read only. No login, refresh, thread or model request."""
    proc=subprocess.Popen([str(binary),'app-server','--listen','stdio://'],cwd=cwd,
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
        env=dict(os.environ,NO_COLOR='1'))
    sel=selectors.DefaultSelector();sel.register(proc.stdout,selectors.EVENT_READ)
    pending=b''
    deadline=time.monotonic()+8
    def send(obj):
        proc.stdin.write(json.dumps(obj).encode()+b'\n');proc.stdin.flush()
    def read(wanted):
        nonlocal pending
        while time.monotonic()<deadline:
            while b'\n' in pending:
                line,pending=pending.split(b'\n',1)
                obj=json.loads(line)
                if obj.get('id')==wanted:
                    if 'error' in obj:raise ValueError('unsupported')
                    return obj.get('result')
            if not sel.select(.2):continue
            data=os.read(proc.stdout.fileno(),65536)
            if not data:raise ValueError('closed')
            pending+=data
            if len(pending)>1024*1024:raise ValueError('oversize')
        raise TimeoutError()
    try:
        send({'id':1,'method':'initialize','params':{'clientInfo':{'name':'lm_cost_plan','version':'0.3'},'capabilities':{}}})
        read(1);send({'method':'initialized'})
        send({'id':2,'method':'account/read','params':{'refreshToken':False}})
        return codex_plan(read(2))
    finally:
        sel.close();proc.terminate()
        try:proc.wait(timeout=2)
        except subprocess.TimeoutExpired:proc.kill();proc.wait()
        proc.stdin.close();proc.stdout.close()

def claude_lookup(binary,cwd):
    # Official status command; raw stdout stays in memory and is never logged or stored.
    p=subprocess.run([str(binary),'auth','status'],cwd=cwd,capture_output=True,timeout=8)
    if len(p.stdout)>262144 or p.returncode not in (0,1):raise ValueError('unsupported')
    return claude_plan(json.loads(p.stdout))

def find_binary(agent):
    candidates=([ '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
        '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex',
        '/Applications/Codex.app/Contents/Resources/codex','/opt/homebrew/bin/codex'] if agent=='Codex' else
        [str(Path.home()/'.local/bin/claude'),'/opt/homebrew/bin/claude','/usr/local/bin/claude'])
    return next((p for p in candidates if Path(p).is_file() and os.access(p,os.X_OK)),None)
