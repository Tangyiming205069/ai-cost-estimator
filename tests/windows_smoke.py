"""Run on a Windows runner with synthetic data only; no user history access."""
import json,sys,tempfile,tkinter as tk
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'LMCost'))
from engine import Engine
from windows_app import Window
with tempfile.TemporaryDirectory() as d:
    engine=Engine(d);engine.mode='demo'
    root=tk.Tk();ui=Window(root,Path(d)/'ui',start_backend=False)
    snapshot=engine.snapshot({});ui.render(snapshot);ui.toggle();root.update()
    assert len(ui.table.get_children())==len(snapshot['rows'])
    ui.table.selection_set('0');ui.details();assert ui.detail.get('1.0','end').strip()
    fast=engine.snapshot({'month':snapshot['month'],'speed':'fast'});ui.render(fast);root.update()
    assert not ui.table.get_children()
    ui.language();ui.toggle();root.update();ui.close();engine.close()
    assert json.loads((Path(d)/'ui/windows-ui.json').read_text())['language']=='zh'
print('Windows Tk window, filters, details, language and close passed with synthetic data.')

# Exercise the production UTF-8 pipe and shutdown, without enabling collection.
import time
with tempfile.TemporaryDirectory() as d:
    root=tk.Tk();ui=Window(root,d)
    deadline=time.monotonic()+20
    while not ui.snapshot and time.monotonic()<deadline:
        root.update();time.sleep(.02)
    assert ui.snapshot and not ui.snapshot['history_sync'].get('enabled')
    assert ui.snapshot['count']==0
    ui.send('mode',value='demo')
    while ui.snapshot.get('mode')!='demo' and time.monotonic()<deadline:
        root.update();time.sleep(.02)
    assert ui.snapshot['mode']=='demo' and ui.snapshot['count']>0
    child=ui.process;ui.close();assert child.poll() is not None
print('Windows production bridge and explicit demo mode passed; collection stayed off.')
